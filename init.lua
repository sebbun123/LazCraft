-- LazCraft - tradeskill automation for Project Lazarus
--   /lua run lazcraft                    crafter: window and engine
--   /lua run lazcraft worker <crafter>   worker: headless, answers the crafter
--   /lc show | hide | test | go | cancel | pause | resume | stop | log on|off | quit
local mq = require('mq')

-- Modules load from this script's own folder, so the layout never depends on MQ's search path.
local SCRIPT_DIR = (debug.getinfo(1, 'S').source:match('^@?(.*[\\/])')) or ''
package.path = SCRIPT_DIR .. '?.lua;' .. SCRIPT_DIR .. '?/init.lua;' .. package.path

local VERSION = '1.10.1'

local R      = require('core.result')
local Log    = require('core.log')
local Config = require('core.config')
local Jobs   = require('core.jobs')
local E3     = require('core.e3')
local Window = require('ui.window')
local Inventory = require('blocks.inventory')
local Windows   = require('blocks.windows')
local Cursor    = require('blocks.cursor')
local Spawns    = require('blocks.spawns')
local Nav       = require('blocks.nav')
local Merchant  = require('blocks.merchant')
local Combine   = require('blocks.combine')
local Kit       = require('blocks.kit')
local Station   = require('blocks.station')
local Bank      = require('blocks.bank')
local Travel    = require('blocks.travel')
local KitSlot   = require('blocks.kitslot')
local Cast      = require('blocks.cast')
local Peers     = require('blocks.peers')
local Ini       = require('core.ini')
local Crew      = require('engine.crew')
local Trade     = require('blocks.trade')
local Handoff   = require('engine.handoff')
local Supply    = require('engine.supply')
local Cleanup   = require('engine.cleanup')
local Planner   = require('engine.planner')
local Make      = require('engine.make')
local Stacks    = require('core.stacks')
local Gear      = require('blocks.gear')

local ARGS = { ... }
local ROLE = (tostring(ARGS[1] or ''):lower() == 'worker') and 'worker' or 'crafter'
local CRAFTER = (ROLE == 'worker') and tostring(ARGS[2] or '') or ''
local ME = mq.TLO.Me.CleanName() or 'Unknown'

Log.setup({ printer = print, clock = mq.gettime })

-- EVERYTHING LazCraft writes stays inside its own folder: settings/ and logs/ ship with the script.
-- If a folder was deleted it is recreated with LuaFileSystem when MQ has it; never by shelling out,
-- which freezes the client.
local SETTINGS_DIR = SCRIPT_DIR .. 'settings/'
local LOG_DIR = SCRIPT_DIR .. 'logs/'
local SETTINGS_PATH = string.format('%sLazCraft_%s.ini', SETTINGS_DIR, ME)
local LOG_PATH = string.format('%sLazCraft_%s.log', LOG_DIR, ME)

local function ensure_dir(dir)
    local hasLfs, lfs = pcall(require, 'lfs')
    if hasLfs and lfs and lfs.mkdir then lfs.mkdir((dir:gsub('[\\/]$', ''))) end
end

local settings = Config.load_settings(SETTINGS_PATH, mq.delay)

-- Settings from before this move sat in MQ's config folder. Bring them over once and remove the old file.
local OLD_SETTINGS = string.format('%s/LazCraft_%s.ini', mq.configDir, ME)
local movedOld = false
do
    local fh = io.open(OLD_SETTINGS, 'r')
    if fh then
        fh:close()
        local cur = io.open(SETTINGS_PATH, 'r')
        if cur then cur:close() else settings = Config.load_settings(OLD_SETTINGS, mq.delay) end
        movedOld = true
    end
end

-- Write the file on every start, so it always exists and always lists every setting with its value.
local function save_settings()
    local ok, err = Config.save_settings(SETTINGS_PATH, settings)
    if not ok then
        ensure_dir(SETTINGS_DIR)
        ok, err = Config.save_settings(SETTINGS_PATH, settings)
    end
    if not ok then Log.warn('Could not save settings to %s: %s', SETTINGS_PATH, tostring(err)) end
    return ok
end
if save_settings() and movedOld then os.remove(OLD_SETTINGS) end

Log.set_level(settings.LogLevel)
Log.set_file_level(settings.LogFileLevel)
local function open_log()
    local ok = Log.open_file(LOG_PATH)
    if not ok then
        ensure_dir(LOG_DIR)
        ok = Log.open_file(LOG_PATH)
    end
    if not ok then Log.warn('Could not open %s - is the logs folder there?', LOG_PATH) end
    return ok
end
if settings.LogToFile == '1' then open_log() end

-- data/ parsed once and kept in settings/data_cache.lua (core/datacache, 2.46.9): MQ runs a script turboNum
-- instructions a frame, so parsing ~150k lines took 149s on a client with turboNum 2000 (the 2.46.8 Shela log)
local cfg, problems = require('core.datacache').load({
    dataDir = SCRIPT_DIR .. 'data/', path = SETTINGS_DIR .. 'data_cache.lua', who = ME,
    code = { SCRIPT_DIR .. 'core/config.lua', SCRIPT_DIR .. 'core/ini.lua', SCRIPT_DIR .. 'core/datacache.lua' },
    log = Log, clock = mq.gettime,
    parse = function(onRead) return Config.load(SCRIPT_DIR .. 'data/', mq.delay, onRead) end,
})
for _, p in ipairs(problems) do Log.warn('Config: %s', p) end
Log.debug('Merchants: %d more from the Alla item pages (data/items.ini)', cfg.harvestMerchants or 0)

-- Building blocks. Pacing values come from settings and are used exactly as given.
local function item_pace() return math.max(0, tonumber(settings.ItemPaceMs) or 0) end
local blocks = {}
blocks.inventory = Inventory.new(mq)
blocks.windows = Windows.new(mq, Log)
blocks.cursor = Cursor.new({ mq = mq, inventory = blocks.inventory, windows = blocks.windows, itemPace = item_pace, log = Log })
-- a frame between inventory clicks, and a quiet window before each combine learned per character (core/pace, 2.46.7)
blocks.cursor.pace = require('core.pace').new({ log = Log,
    get = function(k) return settings[k] end,
    set = function(k, v) settings[k] = v; save_settings() end })
blocks.spawns = Spawns.new(mq, Log)
-- every spot nav wedged at, kept across runs (the old navstuck_persistent.ini): where a hub belongs next
local function nav_stuck(line)
    local fh = io.open(LOG_DIR .. 'navstuck.log', 'a')
    if not fh then ensure_dir(LOG_DIR); fh = io.open(LOG_DIR .. 'navstuck.log', 'a') end
    if fh then fh:write(line, '\n'); fh:close(); Log.debug('  wrote the spot to logs/navstuck.log') end
end
blocks.nav = Nav.new({ mq = mq, spawns = blocks.spawns, log = Log, nav = cfg.nav, stuck = nav_stuck, arrive = cfg.travel.arrive })
-- how many of an item fit in one slot: the shipped list, and what the game shows (learned, shared by every character)
local queue = require('core.queue').new({ path = string.format('%sLazCraft_%s_queue.ini', SETTINGS_DIR, ME), log = Log, sleep = mq.delay })
local paths = require('core.paths').new({ path = string.format('%sLazCraft_%s_paths.ini', SETTINGS_DIR, ME), log = Log, sleep = mq.delay })
local rates = require('core.rates').new({ shipped = SCRIPT_DIR .. 'data/rates.ini', learned = SETTINGS_DIR .. 'rates.ini', log = Log, sleep = mq.delay })
local stacks = Stacks.new({ shipped = SCRIPT_DIR .. 'data/stacks.ini', learned = SETTINGS_DIR .. 'stacks.ini', log = Log, sleep = mq.delay })
blocks.merchant = Merchant.new({ mq = mq, spawns = blocks.spawns, windows = blocks.windows, stacks = stacks,
    inventory = blocks.inventory, cursor = blocks.cursor, log = Log })
blocks.gear = Gear.new({ mq = mq, cursor = blocks.cursor, windows = blocks.windows, log = Log })
blocks.combine = Combine.new({ mq = mq, inventory = blocks.inventory, cursor = blocks.cursor, log = Log })
blocks.kit = Kit.new({ mq = mq, inventory = blocks.inventory, cursor = blocks.cursor, windows = blocks.windows,
    combine = blocks.combine, log = Log })
blocks.station = Station.new({ mq = mq, inventory = blocks.inventory, cursor = blocks.cursor, windows = blocks.windows,
    combine = blocks.combine, log = Log })
blocks.bank = Bank.new({ mq = mq, spawns = blocks.spawns, inventory = blocks.inventory, cursor = blocks.cursor,
    windows = blocks.windows, log = Log })
blocks.travel = Travel.new({ mq = mq, nav = blocks.nav, spawns = blocks.spawns, travel = cfg.travel, log = Log })
blocks.trade = Trade.new({ mq = mq, inventory = blocks.inventory, cursor = blocks.cursor, windows = blocks.windows,
    spawns = blocks.spawns, log = Log })
blocks.cast = Cast.new({ mq = mq, nav = blocks.nav, inventory = blocks.inventory, cursor = blocks.cursor, log = Log })
blocks.faction = require('blocks.faction').new({ mq = mq, spawns = blocks.spawns, log = Log })
blocks.kitslot = KitSlot.new({ mq = mq, cursor = blocks.cursor, windows = blocks.windows, log = Log,
    tsOnly = function(name) return (cfg.lists.tradeskillOnly or {})[(name or ''):lower()] == true end,
    isKit = function(name)
        local k = cfg.containerByBag[(name or ''):lower()]
        return k ~= nil and (cfg.containers[k] or {}).type == 'kit'
    end })
-- a kit in a top-level slot opens the kit's way, never as a bag (2.46.4)
blocks.kitslot.kit = blocks.kit
-- an item /autoinventory will not stow: clicked by hand into a bag that takes it (2.43.10); never nested
do
    local busy = false
    blocks.cursor.by_hand = function(ctx)
        if busy then return R.fail('busy', 'already putting something away by hand') end
        busy = true
        local r = blocks.kitslot:stow_by_hand(ctx)
        busy = false
        return r
    end
end

-- items the data says a merchant sells that its list in game did not (learned, shared; taken out of cfg.merchants)
local unsold = require('core.unsold').new({ path = SETTINGS_DIR .. 'unsold.ini', merchants = cfg.merchants, log = Log, sleep = mq.delay })
local planner = Planner.new(cfg)
do
    local n = 0; for _ in pairs(cfg.recipes or {}) do n = n + 1 end
    Log.info('%d recipes loaded', n)
end

-- What the planner needs to know about the game right now. Pure reads, nothing changes.
local crew, handoff, supply, books   -- made once the runner exists (below)
-- where we stand with each faction-zone merchant (2.42.0; the crafter's file, every character's standings)
local factions = require('core.factions').new({
    path = string.format('%sLazCraft_%s_factions.ini', SETTINGS_DIR, ME), log = Log, sleep = mq.delay })
-- who casts what, remembered across sessions (crafter; 2.41.9)
local casters = ROLE == 'crafter' and require('core.casters').new({
    path = string.format('%sLazCraft_%s_casters.ini', SETTINGS_DIR, ME), log = Log, sleep = mq.delay }) or nil
-- a caster the plan may start: not running, in a safe zone (DanNet's answer), and not one that failed to start
local function caster_ok(name)
    if not crew or name:lower() == ME:lower() or crew:running(name) then return false end
    if crew:is_driver(name) then return false end   -- another crafter (2.44.0)
    local z = crew.zones[name:lower()]
    if not z or not (cfg.travel.safe or {})[z] then return false end
    return not (supply and supply.wontStart[name:lower()])
end

local function plan_world(quiet)
    -- Bags and bank are read once, then looked up: asking item by item re-read every slot for every item
    -- (5.7s for a picnic). If the bank slots cannot be read, the client's own count is asked per item.
    local t0 = mq.gettime()
    local bags = blocks.inventory:snapshot()
    local bank, bankReadable = blocks.bank:snapshot()
    if not quiet then Log.debug('Plan: read bags and bank in %dms (bank slots %s)', mq.gettime() - t0, bankReadable and 'readable' or 'not readable') end
    return {
        zone = (mq.TLO.Zone.ShortName() or ''):lower(),
        bags = function(item) return bags[item:lower()] or 0 end,
        worn = function() return blocks.gear:worn('ammo') end,
        bank = function(item)
            if bankReadable then return bank[item:lower()] or 0 end
            return mq.TLO.FindItemBankCount('=' .. item)() or 0
        end,
        -- this character can make it by casting: the spell is scribed (the book, not the class)
        canCast = function(spell) return blocks.cast:has(spell) end,
        -- a worker that can cast it (its card says so and it is answering); idle ones first
        worker = function(item)
            if ROLE ~= 'crafter' or not crew then return nil end
            -- only one in a safe zone (2.43.9: a worker out playing in a dangerous zone is not sent anywhere)
            local list = {}
            for _, e in ipairs(crew:casters(item)) do
                if (cfg.travel.safe or {})[(e.zone or ''):lower()] then list[#list + 1] = e end
            end
            for _, e in ipairs(list) do if e.state == 'idle' then return e.name end end
            if list[1] then return list[1].name end
            -- none running (2.41.9): one that cast it before, or of a class that can (core/casters), in a safe
            -- zone - started by the Make, which checks its card lists the item
            local c = casters and casters:candidates(item, planner.producers[item:lower()], caster_ok)
            return c and c[1] and c[1].name or nil
        end,
        -- where a worker stands (its card while it answers, else DanNet's last answer): the route starts there when
        -- the Make goes to it first to collect (2.42.15)
        -- 2.43.3: only a worker sitting still in a safe zone (idle, or not running) says where to collect; one busy
        -- elsewhere is on its way somewhere (the log: Lunafeet in gfaydark on a called-off errand to Felwithe, and the
        -- route went there) -> nil, and the plan starts where we stand
        worker_zone = function(name)
            if not crew or not name then return nil end
            local e = crew.board and crew.board[name:lower()]
            local running = e and not e.gone
            if running and e.state ~= 'idle' then return nil end
            local z = (running and e.zone and e.zone ~= '') and e.zone or crew.zones[name:lower()]
            z = z and z:lower() or nil
            if z and not (cfg.travel.safe or {})[z] then return nil end
            return z
        end,
        -- a faction-zone merchant we were last too low with (core/factions): never planned
        barred = function(npc, zone)
            if not (cfg.travel.faction or {})[(zone or ''):lower()] then return nil end
            return factions:barred(ME, npc, zone)
        end,
        -- every merchant for an item barred for us (core/factions): a worker to buy it (2.42.4) - one known to have
        -- the faction with one of them first, then one running, then one that can be started; never one known too low
        -- with all of them. -> name, zone
        buyer = function(item, vendors)
            if ROLE ~= 'crafter' or not crew then return nil end
            local Factions = require('core.factions')
            local function fine(name)
                for _, v in ipairs(vendors) do if not factions:barred(name, v.npc, v.zone) then return true end end
                return false
            end
            local function good(name)
                for _, v in ipairs(vendors) do
                    local w = factions:get(name, v.npc, v.zone)
                    if w and Factions.can_buy(w) then return true end
                end
                return false
            end
            local list, seen = {}, {}
            for _, e in pairs(crew.board) do
                if crew:running(e.name) and e.name:lower() ~= ME:lower() then
                    seen[e.name:lower()] = true
                    -- only one in a safe zone (2.43.9 Lunafeet log: in sebilis, sent to Jaggedpine for a Frying Pan Mold)
                    if (cfg.travel.safe or {})[(e.zone or ''):lower()] then
                        list[#list + 1] = { name = e.name, zone = e.zone, running = true }
                    end
                end
            end
            for _, n in ipairs(crew.roster or {}) do
                if not seen[n:lower()] and caster_ok(n) then list[#list + 1] = { name = n, zone = crew.zones[n:lower()] } end
            end
            local best
            for _, c in ipairs(list) do
                if fine(c.name) then
                    c.good = good(c.name)
                    if not best or (c.good and not best.good) or (c.good == best.good and c.running and not best.running)
                       or (c.good == best.good and c.running == best.running and c.name:lower() < best.name:lower()) then best = c end
                end
            end
            return best and best.name, best and best.zone
        end,
        -- a merchant item dearer than this a unit (copper) is asked for on the network first (Settings; 0 = never)
        requestOver = (ROLE == 'crafter' and (tonumber(settings.RequestOverPP) or 0) > 0) and tonumber(settings.RequestOverPP) * 1000 or nil,
        -- who on the network holds an item (the last supply survey; crafter only)
        supply = function(item)
            if ROLE ~= 'crafter' or not supply then return nil end
            -- another crafter's bags are its own (2.44.0): never ordered from
            local list = supply:holders(item)
            if not list or not crew then return list end
            local out = {}
            for _, h in ipairs(list) do if not crew:is_driver(h.name) then out[#out + 1] = h end end
            return out
        end,
        -- who did not answer about it in the last survey (2.44.0: the plan names them, not "nobody has any")
        noAnswer = function(item)
            if ROLE ~= 'crafter' or not supply then return nil end
            return supply:no_answer(item)
        end,
        -- carried = in a top-level slot, or inside another bag (placing it comes later)
        kit = function(containerName)
            local c = cfg.containers[containerName]
            for _, bag in ipairs(c and c.accepts or { containerName }) do
                if blocks.kit:find(bag) or #blocks.inventory:find(bag) > 0 then return true end
            end
            return false
        end,
    }
end

-- Messages between characters. The crew (cards) is made once the runner exists; until then this is a no-op.
local peers = Peers.new({ mq = mq, log = Log, me = ME, choice = function() return settings.Network end })
-- Runs on every wait inside a job too, so a worker's card follows it while it travels or works.
-- A worker paused by hand (its window's Pause, 2.42.7): the job running holds at its next safe point - never in the
-- middle of a trade, it holds once the trade is done - and nothing new starts. Its crafter is told (card 'paused',
-- every heartbeat 'paused on <me>') and simply waits.
local workerHold = false
local runner
local quitting = false
local snapshot      -- core/snapshot, made once the runner exists
local status_top   -- set once the runner exists: who we are and what the job is doing, for the live status file
local function background()
    mq.doevents()
    if snapshot and status_top and settings.StatusFile ~= '0' then
        snapshot:status_tick(string.format('%sLazCraft_%s_status.txt', LOG_DIR, ME), status_top)
    end
    if crew and mq.TLO.EverQuest.GameState() == 'INGAME' then
        crew:tick(); if handoff then handoff:tick() end
        if books then books:tick() end
    end
    if workerHold and runner and runner.active and not runner.paused and not (handoff and handoff:giving()) then runner:pause() end
end

local e3 = E3.new(mq.cmd, Log)
runner = Jobs.new({ delay = mq.delay, now = mq.gettime, doevents = background, log = Log, e3 = e3,
    casting = function() return (mq.TLO.Me.Casting.ID() or 0) > 0 end, stopcast = function() mq.cmd('/stopcast') end })
-- the game as it stands, into the log: /lc snap, a failed job, a refused combine (2.43.11)
snapshot = require('core.snapshot').new({ mq = mq, log = Log, kitslot = blocks.kitslot, e3 = e3 })
status_top = function()
    local v = runner:view()
    local a = v.active
    local forWho = CRAFTER ~= '' and CRAFTER or 'nobody yet'
    if ROLE == 'worker' and crew and #crew:crafter_names() > 1 then forWho = table.concat(crew:crafter_names(), ', ') end
    local out = { string.format('LazCraft %s on %s (%s%s) - %s', VERSION, ME, ROLE, ROLE == 'worker' and (' for ' .. forWho) or '',
        os.date('%H:%M:%S')) }
    if a then
        out[#out + 1] = string.format('job: %s - %s%s%s%s', a.name, tostring(a.phase or '?'), (a.status or '') ~= '' and (', ' .. a.status) or '',
            (a.total or 0) > 0 and string.format(', %d of %d', a.done or 0, a.total) or '', v.paused and ', PAUSED' or '')
    else
        out[#out + 1] = 'job: none' .. (v.last and string.format(' (last: %s - %s)', v.last.name, v.last.ok and 'done' or tostring(v.last.why)) or '')
    end
    if v.queued > 0 then out[#out + 1] = string.format('queued: %d', v.queued) end
    return out
end
runner.on_fail = function(job, res) snapshot:dump(job.name .. ' failed: ' .. R.describe(res)) end

-- A job that walks through every phase without touching the game: proves the runner, Stop, Pause
-- and the window before any building block exists.
local function test_job()
    return {
        name = 'Test run',
        confirm = true,
        plan = function()
            return R.ok({ steps = 5 })
        end,
        preflight = function(_, plan)
            return {
                { level = 'ok', text = string.format('%d steps planned', plan.steps) },
                { level = 'warn', text = 'Test only: nothing happens in game' },
            }
        end,
        execute = function(ctx, plan)
            for i = 1, plan.steps do
                ctx:status(string.format('Step %d of %d', i, plan.steps))
                ctx:progress(i - 1, plan.steps)
                local w = ctx:wait(1000)
                if not w.ok then return w end
            end
            ctx:progress(plan.steps, plan.steps)
            return R.ok({ summary = string.format('%d steps', plan.steps) })
        end,
    }
end

-- In-game checks for the blocks, one small job each. They show what they will do and wait for Go.
local function check_inventory_job(item)
    return {
        name = 'Check inventory: ' .. item,
        execute = function()
            local inv = blocks.inventory
            local places = inv:find(item)
            local parts = {}
            for _, p in ipairs(places) do
                parts[#parts + 1] = p.slot and string.format('pack%d slot %d x%d', p.pack, p.slot, p.stack)
                    or string.format('pack%d x%d', p.pack, p.stack)
            end
            Log.info('%s: %d in bags%s; %d free slots', item, inv:count(item),
                #parts > 0 and (' (' .. table.concat(parts, ', ') .. ')') or '', inv:free_slots())
            return R.ok()
        end,
    }
end

local function check_pickup_job(item, n)
    return {
        name = string.format('Check pickup: %d %s', n, item),
        confirm = true, usesToon = true,
        plan = function() return R.ok({}) end,
        preflight = function()
            local checks = {}
            local held = blocks.cursor:item()
            if held then checks[#checks + 1] = { level = 'block', text = 'Cursor holds ' .. held.name .. ' - clear it first' } end
            for _, w in ipairs({ 'MerchantWnd', 'BigBankWnd' }) do
                if blocks.windows:is_open(w) then
                    checks[#checks + 1] = { level = 'block', text = w .. ' is open - items could not be put back' }
                end
            end
            local have = blocks.inventory:count(item)
            checks[#checks + 1] = { level = have >= n and 'ok' or 'block', text = string.format('%d %s in bags', have, item) }
            checks[#checks + 1] = { level = 'ok', text = 'Will pick up ' .. n .. ', hold it for a second, then put it back' }
            return checks
        end,
        execute = function(ctx, plan)
            local got = blocks.cursor:pick_up(ctx, item, n)
            plan.openedPack = got.ok and got.value.openedPack or got.openedPack
            if not got.ok then return got end
            Log.info('Cursor holds %s x%d', got.value.name, got.value.stack)
            local w = ctx:wait(1000)
            if not w.ok then return w end
            local s = blocks.cursor:stow(ctx)
            if not s.ok then return s end
            return R.ok({ summary = string.format('picked up %d and put it back', n) })
        end,
        -- However it ended (done, failed, stopped): nothing left in the split window, on the cursor, or open.
        cleanup = function(ctx, plan)
            local q = blocks.windows:close(ctx, 'QuantityWnd')
            local s = blocks.cursor:stow(ctx)
            if plan.openedPack and blocks.cursor:is_empty() then
                local c = blocks.windows:close_bag(ctx, plan.openedPack)
                if not c.ok then return c end
            end
            if not q.ok then return q end
            return s
        end,
    }
end

-- Shows both ways of reading whether a bag is open, so the right one can be confirmed in game.
local function check_bag_job(pack)
    return {
        name = 'Check bag ' .. pack,
        execute = function()
            local bag = blocks.inventory:bag(pack)
            if not bag then return R.fail('not a bag', 'pack' .. pack .. ' does not hold a bag') end
            Log.info('pack%d %s: %d/%d used; Window[Pack%d].Open=%s; item Open=%s', pack, tostring(bag.name),
                bag.used, bag.slots, pack, tostring(mq.TLO.Window('Pack' .. pack).Open()),
                tostring(mq.TLO.Me.Inventory('pack' .. pack).Open()))
            return R.ok()
        end,
    }
end

-- Repeats a split pickup from a CLOSED bag: close bag, pick up `amount`, put it back, close bag.
-- Logs each round and a summary, so lost clicks and timings can be compared across settings.
-- `gap` ms between rounds (0 = none). When a round's clicks are all ignored, it probes once every
-- PROBE_EVERY ms until clicks are taken again, and logs how long they were ignored.
local PROBE_EVERY, PROBE_MAX = 100, 20000
local function bag_stress_job(item, times, amount, gap)
    local stats = { ok = 0, failed = 0, extraClicks = 0, reopenRounds = 0, reopens = 0, ms = {}, locks = {} }
    local place
    return {
        name = string.format('Bag test: %d x pick up %d %s%s', times, amount, item, gap > 0 and (', ' .. gap .. 'ms apart') or ''),
        confirm = true, usesToon = true,
        preflight = function()
            local checks = {}
            local held = blocks.cursor:item()
            if held then checks[#checks + 1] = { level = 'block', text = 'Cursor holds ' .. held.name .. ' - clear it first' } end
            local places = blocks.inventory:find(item) or {}
            for _, p in ipairs(places) do if p.slot and p.stack > amount then place = p; break end end
            if not place then
                checks[#checks + 1] = { level = 'block', text = string.format('No bag stack of %s bigger than %d', item, amount) }
            else
                checks[#checks + 1] = { level = 'ok', text = string.format('Using pack%d slot %d (%d there)', place.pack, place.slot, place.stack) }
                checks[#checks + 1] = { level = 'ok', text = string.format('%d rounds: close bag, take %d, put back. Gap %dms, item pace %dms',
                    times, amount, gap, item_pace()) }
            end
            return checks
        end,
        execute = function(ctx)
            local moves = 0   -- item moves (pickups + stows) since the last lockout
            for i = 1, times do
                if not ctx:checkpoint() then return R.fail('stopped') end
                local c = blocks.windows:close_bag(ctx, place.pack)
                if not c.ok then return c end
                local t0 = mq.gettime()
                local got = blocks.cursor:pick_up(ctx, item, amount)
                local ms = mq.gettime() - t0
                if got.ok then
                    stats.ok = stats.ok + 1
                    stats.extraClicks = stats.extraClicks + (got.value.clicks - 1)
                    if got.value.reopens > 0 then
                        stats.reopenRounds, stats.reopens = stats.reopenRounds + 1, stats.reopens + got.value.reopens
                    end
                    stats.ms[#stats.ms + 1] = ms
                    Log.info('Round %d: ok in %dms, %d click(s), %d reopen(s)', i, ms, got.value.clicks, got.value.reopens)
                    local s = blocks.cursor:stow(ctx)
                    if not s.ok then return s end
                    moves = moves + 2
                else
                    stats.failed = stats.failed + 1
                    Log.warn('Round %d: %s', i, R.describe(got))
                    if got.why == 'stopped' then return got end
                    local s = blocks.cursor:stow(ctx)
                    if not s.ok then return s end
                    if got.why == 'pickup failed' then
                        local pr = blocks.cursor:probe(ctx, item, PROBE_EVERY, PROBE_MAX)
                        if pr.why == 'stopped' then return pr end
                        if pr.ok then
                            local lockMs = pr.value.at - t0   -- from the round's first ignored click to the click that took
                            Log.info('Round %d: clicks ignored for about %dms (after %d moves in a row); probe click %d took',
                                i, lockMs, moves, pr.value.clicks)
                            stats.locks[#stats.locks + 1] = string.format('%dms after %d moves', lockMs, moves)
                        else
                            local lockMs = mq.gettime() - t0
                            Log.warn('Round %d: clicks still ignored after %dms: %s', i, lockMs, R.describe(pr))
                            stats.locks[#stats.locks + 1] = string.format('over %dms after %d moves', lockMs, moves)
                        end
                        moves = 0
                    end
                end
                ctx:progress(i, times)
                if gap > 0 and i < times then
                    local p = ctx:pace(gap)
                    if not p.ok then return p end
                end
            end
            table.sort(stats.ms)
            local total = 0
            for _, v in ipairs(stats.ms) do total = total + v end
            local summary = string.format('%d/%d ok, %d lost click(s) re-sent, %d round(s) needed a reopen (%d reopens), pickup %s',
                stats.ok, times, stats.extraClicks, stats.reopenRounds, stats.reopens,
                #stats.ms > 0 and string.format('avg %dms, fastest %dms, slowest %dms',
                    math.floor(total / #stats.ms), stats.ms[1], stats.ms[#stats.ms]) or 'never worked')
            if #stats.locks > 0 then summary = summary .. '; clicks ignored ' .. table.concat(stats.locks, ', ') end
            if stats.failed > 0 then return R.fail('some rounds failed', summary) end
            return R.ok({ summary = summary })
        end,
        cleanup = function(ctx)
            blocks.windows:close(ctx, 'QuantityWnd')
            local s = blocks.cursor:stow(ctx)
            if place and blocks.cursor:is_empty() then return blocks.windows:close_bag(ctx, place.pack) end
            return s
        end,
    }
end

-- Travels between NPCs in turn: nav to each, measure the distance on arrival, open its merchant window,
-- confirm it is that merchant and its list arrived, close it. Logs each trip and a summary.
local function nav_test_job(names, trips, dist)
    local stats = { navOk = 0, openOk = 0, navMs = {}, openMs = {}, dists = {}, navRetries = 0, openRetries = 0, failed = 0 }
    local function avg(t) local n = 0; for _, v in ipairs(t) do n = n + v end; return #t > 0 and math.floor(n / #t) or 0 end
    return {
        name = string.format('Nav test: %d trips between %s', trips, table.concat(names, ' and ')),
        confirm = true, usesToon = true,
        preflight = function()
            local checks = {}
            for _, name in ipairs(names) do
                local s = blocks.spawns:find(name)
                if not s then
                    checks[#checks + 1] = { level = 'block', text = name .. ' is not in this zone' }
                elseif mq.TLO.Navigation.PathExists('id ' .. s.id)() ~= true then
                    checks[#checks + 1] = { level = 'block', text = string.format('%s: no nav path (id %d, %.0f away)', s.name, s.id, s.distance) }
                else
                    checks[#checks + 1] = { level = 'ok', text = string.format('%s: id %d, %.0f away', s.name, s.id, s.distance) }
                    if s.class ~= 'Merchant' then
                        checks[#checks + 1] = { level = 'warn', text = string.format('%s is a %s, not a merchant - opening will fail', s.name, tostring(s.class)) }
                    end
                end
            end
            checks[#checks + 1] = { level = 'ok', text = string.format('%d trips, stopping within %d of each', trips, dist) }
            return checks
        end,
        execute = function(ctx)
            for i = 1, trips do
                if not ctx:checkpoint() then return R.fail('stopped') end
                local name = names[(i - 1) % #names + 1]
                ctx:status(string.format('Trip %d of %d: %s', i, trips, name))
                local s = blocks.spawns:find(name)
                if not s then return R.fail('gone', name .. ' is no longer in the zone') end
                local n = blocks.nav:go_spawn(ctx, s.id, dist)
                if n.why == 'stopped' then return n end
                if not n.ok then
                    stats.failed = stats.failed + 1
                    Log.warn('Trip %d: %s: %s', i, name, R.describe(n))
                else
                    stats.navOk = stats.navOk + 1
                    stats.navRetries = stats.navRetries + math.max(0, n.value.tries - 1)
                    stats.navMs[#stats.navMs + 1] = n.value.ms
                    stats.dists[#stats.dists + 1] = n.value.distance
                    local o = blocks.merchant:open(ctx, s.id)
                    if o.why == 'stopped' then return o end
                    if not o.ok then
                        stats.failed = stats.failed + 1
                        Log.warn('Trip %d: %s: arrived %.1f away in %dms, but %s', i, name, n.value.distance, n.value.ms, R.describe(o))
                    else
                        stats.openOk = stats.openOk + 1
                        stats.openRetries = stats.openRetries + (o.value.tries - 1)
                        stats.openMs[#stats.openMs + 1] = o.value.openMs
                        Log.info('Trip %d: %s: arrived %.1f away in %dms (%d nav), opened in %dms (%d tr%s), %d items%s',
                            i, name, n.value.distance, n.value.ms, n.value.tries, o.value.openMs, o.value.tries,
                            o.value.tries == 1 and 'y' or 'ies', o.value.items, o.value.listReady and '' or ' (list incomplete)')
                        local c = blocks.merchant:close(ctx)
                        if not c.ok then return c end
                    end
                end
                ctx:progress(i, trips)
            end
            table.sort(stats.dists)
            local summary = string.format('%d/%d navs ok (avg %dms, %d re-sent), arrived %s away; %d/%d opens ok (avg %dms, %d re-sent)',
                stats.navOk, trips, avg(stats.navMs), stats.navRetries,
                #stats.dists > 0 and string.format('%.1f-%.1f', stats.dists[1], stats.dists[#stats.dists]) or '-',
                stats.openOk, trips, avg(stats.openMs), stats.openRetries)
            if stats.failed > 0 then return R.fail('some trips failed', summary) end
            return R.ok({ summary = summary })
        end,
        cleanup = function(ctx)
            local n = blocks.nav:stop(ctx)
            local c = blocks.merchant:close(ctx)
            if not n.ok then return n end
            return c
        end,
    }
end

-- Goes to a merchant, opens it, then buys `n` of an item and sells the same `n` back, `times` over.
-- Each step is confirmed by the bag count; the test ends with exactly what we started with.
local function buy_test_job(npc, item, n, times)
    local stats = { ok = 0, buyMs = {}, sellMs = {} }
    local start
    local function avg(t) local x = 0; for _, v in ipairs(t) do x = x + v end; return #t > 0 and math.floor(x / #t) or 0 end
    return {
        name = string.format('Buy test: %d x buy and sell %d %s at %s', times, n, item, npc),
        confirm = true, usesToon = true,
        preflight = function()
            local checks = {}
            local s = blocks.spawns:find(npc)
            if not s then checks[#checks + 1] = { level = 'block', text = npc .. ' is not in this zone' }
            else checks[#checks + 1] = { level = 'ok', text = string.format('%s: id %d, %.0f away', s.name, s.id, s.distance) } end
            local held = blocks.cursor:item()
            if held then checks[#checks + 1] = { level = 'block', text = 'Cursor holds ' .. held.name .. ' - clear it first' } end
            if blocks.inventory:free_slots() < 1 then checks[#checks + 1] = { level = 'block', text = 'No free bag slots' } end
            start = blocks.inventory:count(item)
            checks[#checks + 1] = { level = 'ok', text = string.format('%d %s in bags now; each round buys %d and sells %d back', start, item, n, n) }
            return checks
        end,
        execute = function(ctx)
            local s = blocks.spawns:find(npc)
            if not s then return R.fail('gone', npc .. ' is no longer in the zone') end
            local g = blocks.nav:go_spawn(ctx, s.id, 10)
            if not g.ok then return g end
            local o = blocks.merchant:open(ctx, s.id)
            if not o.ok then return o end
            Log.info('At %s (%.1f away), window open in %dms, %d items', s.name, g.value.distance, o.value.openMs, o.value.items)
            for i = 1, times do
                if not ctx:checkpoint() then return R.fail('stopped') end
                ctx:status(string.format('Round %d of %d', i, times))
                local b = blocks.merchant:buy(ctx, item, n)
                if not b.ok then return b end
                local sl = blocks.merchant:sell(ctx, item, n)
                if not sl.ok then return sl end
                stats.ok = stats.ok + 1
                stats.buyMs[#stats.buyMs + 1], stats.sellMs[#stats.sellMs + 1] = b.value.ms, sl.value.ms
                Log.info('Round %d: bought %d in %dms, sold %d in %dms, %d in bags', i, b.value.got, b.value.ms,
                    sl.value.sold, sl.value.ms, blocks.inventory:count(item))
                ctx:progress(i, times)
            end
            local now = blocks.inventory:count(item)
            local summary = string.format('%d/%d rounds ok, buy avg %dms, sell avg %dms, %d %s in bags (started with %d)',
                stats.ok, times, avg(stats.buyMs), avg(stats.sellMs), now, item, start)
            if now ~= start then return R.fail('count changed', summary) end
            return R.ok({ summary = summary })
        end,
        cleanup = function(ctx)
            local n1 = blocks.nav:stop(ctx)
            local m = blocks.merchant:close(ctx)   -- first: nothing can be stowed while it is open
            local c = blocks.cursor:stow(ctx)
            if not n1.ok then return n1 end
            if not m.ok then return m end
            return c
        end,
    }
end

-- Gives n platinum to a player standing next to us; they click Trade by hand (2.43.4: the steps for the worker
-- top-up, proved in a log first).
local function givepp_test_job(n, name)
    return {
        name = string.format('Platinum test: give %d pp to %s', n, name),
        confirm = true, usesToon = true,
        preflight = function()
            local checks = {}
            local s = blocks.spawns:find_pc(name)
            if not s then checks[#checks + 1] = { level = 'block', text = name .. ' is not in this zone' }
            elseif s.distance > Trade.DIST then
                checks[#checks + 1] = { level = 'block', text = string.format('%s is %.0f away - stand within %d', s.name, s.distance, Trade.DIST) }
            else checks[#checks + 1] = { level = 'ok', text = string.format('%s: id %d, %.0f away', s.name, s.id, s.distance) } end
            local pp = blocks.trade:pp()
            checks[#checks + 1] = { level = pp >= n and 'ok' or 'block', text = string.format('%d pp on us, giving %d', pp, n) }
            local held = blocks.cursor:item()
            if held then checks[#checks + 1] = { level = 'block', text = 'Cursor holds ' .. held.name .. ' - clear it first' } end
            checks[#checks + 1] = { level = 'ok', text = name .. ' clicks Trade by hand when the window opens (60s)' }
            return checks
        end,
        execute = function(ctx)
            local s = blocks.spawns:find_pc(name)
            if not s then return R.fail('gone', name .. ' is no longer in the zone') end
            ctx:status('Giving ' .. n .. ' pp to ' .. s.name)
            local r = blocks.trade:give_pp(ctx, s.id, n)
            if not r.ok then return r end
            return R.ok({ summary = string.format('gave %d pp to %s: purse %d -> %d', n, s.name, r.value.before, r.value.after) })
        end,
        cleanup = function(ctx)
            local t = blocks.trade:cancel(ctx)
            local p = blocks.trade:put_back_pp(ctx)
            local q = blocks.windows:close(ctx, 'QuantityWnd')
            if not t.ok then return t end
            if not p.ok then return p end
            return q
        end,
    }
end

-- Combines one recipe in a carried kit `times` over: open the kit, place each ingredient in its slot (in
-- the order given, one each), /combine, collect and stow what comes back, check the kit is empty.
local function combine_test_job(kitName, product, ings, times)
    local stats = { success = 0, failed = 0, placeMs = {}, combineMs = {} }
    local kit, wasOpen
    local function avg(t) local x = 0; for _, v in ipairs(t) do x = x + v end; return #t > 0 and math.floor(x / #t) or 0 end
    return {
        name = string.format('Combine test: %d x %s in %s', times, product, kitName),
        confirm = true, usesToon = true,
        preflight = function()
            local checks = {}
            local why
            kit, why = blocks.kit:find(kitName)
            if not kit then
                checks[#checks + 1] = { level = 'block', text = why }
            else
                checks[#checks + 1] = { level = 'ok', text = string.format('%s in pack%d (%d slots)', kitName, kit.pack, kit.slots) }
                local inside = blocks.kit:describe(kit.pack)
                if inside ~= 'empty' then checks[#checks + 1] = { level = 'block', text = kitName .. ' is not empty: ' .. inside } end
                if #ings > kit.slots then checks[#checks + 1] = { level = 'block', text = string.format('%d ingredients, %d kit slots', #ings, kit.slots) } end
            end
            local held = blocks.cursor:item()
            if held then checks[#checks + 1] = { level = 'block', text = 'Cursor holds ' .. held.name .. ' - clear it first' } end
            local need = {}
            for _, ing in ipairs(ings) do need[ing] = (need[ing] or 0) + times end
            for ing, n in pairs(need) do
                local have = blocks.inventory:count(ing, kit and kit.pack)
                checks[#checks + 1] = { level = have >= n and 'ok' or 'block', text = string.format('%s: have %d, need %d', ing, have, n) }
            end
            if blocks.inventory:free_slots() < 1 then checks[#checks + 1] = { level = 'block', text = 'No free bag slots for the result' } end
            return checks
        end,
        execute = function(ctx)
            wasOpen = blocks.kit:is_open()   -- an open kit is used as it is, and left open
            local o = blocks.kit:open(ctx, kit.pack)
            if not o.ok then return o end
            Log.info('%s open (%s)', kitName, o.value.how)
            for i = 1, times do
                if not ctx:checkpoint() then return R.fail('stopped') end
                ctx:status(string.format('Combine %d of %d', i, times))
                local t0 = mq.gettime()
                for slot, ing in ipairs(ings) do
                    local p = blocks.kit:place(ctx, kit.pack, slot, ing)
                    if not p.ok then return p end
                end
                local placeMs = mq.gettime() - t0
                local c = blocks.kit:combine(ctx, kit.pack, product)
                if not c.ok then return c end
                stats.placeMs[#stats.placeMs + 1], stats.combineMs[#stats.combineMs + 1] = placeMs, c.value.ms
                if c.value.result == 'success' then stats.success = stats.success + 1 else stats.failed = stats.failed + 1 end
                Log.info('Combine %d: %s - placed %d in %dms, answer in %dms, made %d %s%s', i, c.value.result, #ings, placeMs,
                    c.value.ms, c.value.made, product, #c.value.returned > 0 and (', back: ' .. table.concat(c.value.returned, ', ')) or '')
                if c.value.result == 'refused' then return R.fail('combine refused', c.value.line) end
                local left = blocks.kit:describe(kit.pack)
                if left ~= 'empty' then return R.fail('kit not empty', 'after the combine the kit still holds ' .. left) end
                ctx:progress(i, times)
            end
            local summary = string.format('%d/%d succeeded, %d failed; placing avg %dms, combine answer avg %dms',
                stats.success, times, stats.failed, avg(stats.placeMs), avg(stats.combineMs))
            return R.ok({ summary = summary })
        end,
        cleanup = function(ctx)
            local s1 = blocks.cursor:stow(ctx)
            local s2 = (kit and blocks.kit:is_open()) and blocks.kit:clear(ctx, kit.pack) or R.ok()
            blocks.kit:close_bags(ctx)
            local s3 = (kit and not wasOpen) and blocks.kit:close(ctx, kit.pack) or R.ok()
            if not s1.ok then return s1 end
            if not s2.ok then return s2 end
            return s3
        end,
    }
end

-- Combines one recipe at the nearest world station `times` over: find it (/itemtarget), go to it, open it,
-- place each ingredient in its slot (one each, in the order given), /combine enviro, stow what comes back,
-- check its slots are empty. A station that was already open is used as it is and left open.
local function station_test_job(stationName, product, ings, times)
    local stats = { success = 0, failed = 0, placeMs = {}, combineMs = {} }
    local wasOpen
    local function avg(t) local x = 0; for _, v in ipairs(t) do x = x + v end; return #t > 0 and math.floor(x / #t) or 0 end
    return {
        name = string.format('Station test: %d x %s at %s', times, product, stationName),
        confirm = true, usesToon = true,
        preflight = function()
            local checks = {}
            local held = blocks.cursor:item()
            if held then checks[#checks + 1] = { level = 'block', text = 'Cursor holds ' .. held.name .. ' - clear it first' } end
            local need = {}
            for _, ing in ipairs(ings) do need[ing] = (need[ing] or 0) + times end
            for ing, n in pairs(need) do
                local have = blocks.inventory:count(ing)
                checks[#checks + 1] = { level = have >= n and 'ok' or 'block', text = string.format('%s: have %d, need %d', ing, have, n) }
            end
            if blocks.inventory:free_slots() < 1 then checks[#checks + 1] = { level = 'block', text = 'No free bag slots for the result' } end
            checks[#checks + 1] = { level = 'ok', text = string.format('Will find the nearest %s and go to it', stationName) }
            return checks
        end,
        execute = function(ctx)
            wasOpen = blocks.station:is_open()
            if not wasOpen then
                local f = blocks.station:find(ctx, stationName)
                if not f.ok then return f end
                local g = blocks.nav:go_loc(ctx, f.value.y, f.value.x, f.value.z, 8)
                if not g.ok then return g end
                Log.info('At the %s (%.1f away) after %dms', stationName, g.value.distance, g.value.ms)
            end
            local o = blocks.station:open(ctx, stationName)
            if not o.ok then return o end
            Log.info('%s open (%s)', stationName, o.value.how)
            -- The old code claimed bag slots read blank while a station window is open. Check it, don't assume it.
            for _, ing in ipairs(ings) do
                local bySlot, client = blocks.inventory:count(ing), blocks.inventory:client_total(ing)
                if bySlot == client then
                    Log.info('With %s open, %s reads %d slot by slot and %d by the client: they agree', stationName, ing, bySlot, client)
                else
                    Log.warn('With %s open, %s reads %d slot by slot but %d by the client (%s)', stationName, ing, bySlot, client,
                        blocks.station:windows_state())
                end
            end
            for i = 1, times do
                if not ctx:checkpoint() then return R.fail('stopped') end
                ctx:status(string.format('Combine %d of %d', i, times))
                local t0 = mq.gettime()
                for slot, ing in ipairs(ings) do
                    local p = blocks.station:place(ctx, slot, ing)
                    if not p.ok then return p end
                end
                local placeMs = mq.gettime() - t0
                local c = blocks.station:combine(ctx, product)
                if not c.ok then return c end
                stats.placeMs[#stats.placeMs + 1], stats.combineMs[#stats.combineMs + 1] = placeMs, c.value.ms
                if c.value.result == 'success' then stats.success = stats.success + 1 else stats.failed = stats.failed + 1 end
                Log.info('Combine %d: %s - placed %d in %dms, answer in %dms, made %d %s%s', i, c.value.result, #ings, placeMs,
                    c.value.ms, c.value.made, product, #c.value.returned > 0 and (', back: ' .. table.concat(c.value.returned, ', ')) or '')
                if c.value.result == 'refused' then return R.fail('combine refused', c.value.line) end
                local left = blocks.station:describe()
                if left ~= 'empty' then return R.fail('station not empty', 'after the combine the station still holds ' .. left) end
                ctx:progress(i, times)
            end
            return R.ok({ summary = string.format('%d/%d succeeded, %d failed; placing avg %dms, combine answer avg %dms',
                stats.success, times, stats.failed, avg(stats.placeMs), avg(stats.combineMs)) })
        end,
        cleanup = function(ctx)
            local n = blocks.nav:stop(ctx)
            local s1 = blocks.cursor:stow(ctx)
            local s2 = blocks.station:is_open() and blocks.station:clear(ctx) or R.ok()
            blocks.station:close_bags(ctx)   -- first, so Esc finds the station's window on top
            local s3 = (wasOpen == false) and blocks.station:close(ctx, stationName) or R.ok()
            for _, r in ipairs({ n, s1, s2, s3 }) do if not r.ok then return r end end
            return R.ok()
        end,
    }
end

-- Goes to the nearest banker, opens the bank, then takes `n` of an item out and puts the same `n` back,
-- `times` over. Each move is confirmed by the counts; the test ends with the bags and bank as they were.
local function bank_test_job(item, n, times)
    local stats = { ok = 0, outMs = {}, inMs = {} }
    local startBags, startBank
    local function avg(t) local x = 0; for _, v in ipairs(t) do x = x + v end; return #t > 0 and math.floor(x / #t) or 0 end
    return {
        name = string.format('Bank test: %d x take out and put back %d %s', times, n, item),
        confirm = true, usesToon = true,
        preflight = function()
            local checks = {}
            local b = blocks.bank:banker()
            if not b then checks[#checks + 1] = { level = 'block', text = 'No banker in this zone' }
            else checks[#checks + 1] = { level = 'ok', text = string.format('%s: id %d, %.0f away', b.name, b.id, b.distance) } end
            local held = blocks.cursor:item()
            if held then checks[#checks + 1] = { level = 'block', text = 'Cursor holds ' .. held.name .. ' - clear it first' } end
            local banked, how = blocks.bank:count(item)
            checks[#checks + 1] = { level = banked >= n and 'ok' or 'block',
                text = string.format('%s in the bank: %d (%s), need %d', item, banked, how == 'slots' and 'read from its slots' or 'client count, includes the shared bank', n) }
            if blocks.inventory:free_slots() < 1 then checks[#checks + 1] = { level = 'block', text = 'No free bag slots' } end
            return checks
        end,
        execute = function(ctx)
            local b = blocks.bank:banker()
            if not b then return R.fail('no banker', 'no banker in this zone') end
            local o = blocks.bank:go_open(ctx, blocks.nav, b)
            if not o.ok then return o end
            startBags = blocks.inventory:count(item)
            local how
            startBank, how = blocks.bank:count(item)
            local here = blocks.spawns:get(b.id)
            Log.info('At %s (%.1f away), bank open in %dms; %s: %d in the bags, %d in the bank (%s)', b.name, here and here.distance or 0,
                o.value.ms, item, startBags, startBank, how)
            for i = 1, times do
                if not ctx:checkpoint() then return R.fail('stopped') end
                ctx:status(string.format('Round %d of %d', i, times))
                local w = blocks.bank:withdraw(ctx, item, n)
                if not w.ok then return w end
                local d = blocks.bank:deposit(ctx, item, n)
                if not d.ok then return d end
                stats.ok = stats.ok + 1
                stats.outMs[#stats.outMs + 1], stats.inMs[#stats.inMs + 1] = w.value.ms, d.value.ms
                Log.info('Round %d: took %d out in %dms, put %d back in %dms; bags %d, bank %d', i, w.value.got, w.value.ms,
                    d.value.put, d.value.ms, blocks.inventory:count(item), (blocks.bank:count(item)))
                ctx:progress(i, times)
            end
            local bags, bank = blocks.inventory:count(item), (blocks.bank:count(item))
            local summary = string.format('%d/%d rounds ok, out avg %dms, back avg %dms; bags %d (was %d), bank %d (was %d)',
                stats.ok, times, avg(stats.outMs), avg(stats.inMs), bags, startBags, bank, startBank)
            if bags ~= startBags or bank ~= startBank then return R.fail('counts changed', summary) end
            return R.ok({ summary = summary })
        end,
        cleanup = function(ctx)
            local n1 = blocks.nav:stop(ctx)
            local s1 = blocks.cursor:stow(ctx)
            blocks.bank:close_bags(ctx)
            local c = blocks.bank:close(ctx)
            local s2 = blocks.cursor:is_empty() and R.ok() or blocks.cursor:stow(ctx)
            for _, r in ipairs({ n1, c, s2 }) do if not r.ok then return r end end
            if not s1.ok and not blocks.cursor:is_empty() then return s1 end
            return R.ok()
        end,
    }
end

-- Plain bank moves: go to the nearest banker, open the bank, take out / put in, close.
local function bank_move_job(dir, item, n)
    return {
        name = string.format('%s %s %s', dir == 'out' and 'Withdraw' or 'Deposit', n == math.huge and 'all' or tostring(n), item),
        usesToon = true,
        execute = function(ctx)
            local b = blocks.bank:banker()
            if not b then return R.fail('no banker', 'no banker in this zone') end
            local o = blocks.bank:go_open(ctx, blocks.nav, b)
            if not o.ok then return o end
            local count = n
            if count == math.huge then count = dir == 'out' and (blocks.bank:count(item)) or blocks.inventory:count(item) end
            if count <= 0 then return R.ok({ summary = 'none to move' }) end
            local r = dir == 'out' and blocks.bank:withdraw(ctx, item, count) or blocks.bank:deposit(ctx, item, count)
            if not r.ok then return r end
            return R.ok({ summary = string.format('%d %s %s; bags %d, bank %d', count, item, dir == 'out' and 'taken out' or 'put in',
                blocks.inventory:count(item), (blocks.bank:count(item))) })
        end,
        cleanup = function(ctx)
            local s1 = blocks.cursor:stow(ctx)
            blocks.bank:close_bags(ctx)
            local c = blocks.bank:close(ctx)
            if not c.ok then return c end
            return s1
        end,
    }
end

-- Plans a make and shows it as the preflight: the recipe tree, bank pulls, purchases by zone and merchant,
-- the order of combines and the route. Nothing in game happens yet (making comes next).
local function plan_job(recipe, combines)
    return {
        name = string.format('Plan: %d x %s', combines, recipe.label),
        confirm = true,
        preflight = function()
            local t0 = mq.gettime()
            local plan = planner:plan(recipe.id, combines, plan_world())
            Log.debug('Plan: worked out in %dms', mq.gettime() - t0)
            local lines = Planner.describe(plan)
            -- printed in full too: a blocked plan ends at preflight, and every reason should be visible
            for _, l in ipairs(lines) do
                if l.level == 'block' then Log.warn('Plan: %s', l.text) else Log.info('Plan: %s', l.text) end
            end
            return lines
        end,
        execute = function() return R.ok({ summary = 'plan only - making it comes next' }) end,
    }
end

-- Travel to a zone over travel.ini's hops, each confirmed. The preflight shows the hops.
local function travel_job(to)
    return {
        name = 'Travel to ' .. to,
        confirm = true, usesToon = true,
        preflight = function()
            local path = blocks.travel:path(to)
            if not path then
                return { { level = 'block', text = string.format('travel.ini has no way from %s to %s', blocks.travel:zone(), to) } }
            end
            if #path == 0 then return { { level = 'ok', text = 'already in ' .. to } } end
            local lines = {}
            for i, h in ipairs(path) do
                local how = h.how == 'aa' and ('AA ' .. h.aa) or h.how == 'say' and string.format('%s, say "%s"', h.npc, h.say)
                    or string.format('door %s', h.door)
                lines[#lines + 1] = { level = 'ok', text = string.format('%d. %s -> %s: %s', i, h.from == '*' and 'here' or h.from, h.to, how) }
            end
            return lines
        end,
        execute = function(ctx)
            local r = blocks.travel:go(ctx, to)
            if not r.ok then return r end
            return R.ok({ summary = string.format('in %s, %d hop%s, %.1fs', to, r.value.hops, r.value.hops == 1 and '' or 's', r.value.ms / 1000) })
        end,
        cleanup = function(ctx) blocks.nav:stop(ctx); return R.ok() end,
    }
end

local function close_window_job(name)
    return { name = 'Close ' .. name, execute = function(ctx) return blocks.windows:close(ctx, name) end }
end

local function stow_job()
    return {
        name = 'Stow cursor', usesToon = true,
        execute = function(ctx)
            local s = blocks.cursor:stow(ctx)
            if s.ok then return R.ok({ summary = string.format('%d item(s) stowed', s.value) }) end
            return s
        end,
    }
end

-- The one place a setting changes: apply its effect now, then save the file. Used by the Settings tab
-- and by /lc log. Pacing needs no effect here: blocks read it fresh before every action.
local function apply_setting(key, value)
    value = tostring(value)
    if settings[key] == value then return end
    settings[key] = value
    if key == 'LogLevel' then Log.set_level(value)
    elseif key == 'LogFileLevel' then Log.set_file_level(value)
    elseif key == 'LogToFile' then
        if value == '1' then open_log() else Log.close_file() end
    elseif key == 'Network' then
        peers:reset()
    elseif key == 'Theme' and ROLE == 'crafter' and crew then
        -- workers working for us take the same look (2.43.0): every one running is told now, one that comes up later
        -- when its card comes (crew on_up)
        for _, e in pairs(crew.board) do
            if not e.gone then peers:send(e.name, 'theme', Peers.encode(value)) end
        end
    end
    Log.info('Setting %s = %s', key, value)
    save_settings()
end

crew = Crew.new({ peers = peers, log = Log, now = mq.gettime, role = ROLE, me = ME, crafter = CRAFTER,
    -- a worker started with no crafter named takes the first that says hello (2.42.10)
    on_adopt = function(name) CRAFTER = name; if handoff then handoff.crafter = name end end,
    version = VERSION, producers = cfg.producers, memo = casters,   -- who casts what (core/casters)
    class = function()
        local ok, v = pcall(function() return mq.TLO.Me.Class.Name() end)
        return ok and v or nil
    end,
    book = function(spell) return blocks.cast:has(spell) end,
    zone = function() return mq.TLO.Zone.ShortName() or '' end,
    busy = function() return runner.active ~= nil or #runner.queue > 0 end,
    paused = function() return workerHold end,
    known = function() return Ini.list(settings.Workers or '') end,
    -- a worker up (its first card): the window's theme goes to it (2.43.0)
    on_up = ROLE == 'crafter' and function(name) peers:send(name, 'theme', Peers.encode(settings.Theme or 'Midnight')) end or nil,
    remember = function(name)
        local list = Ini.list(settings.Workers or '')
        for _, n in ipairs(list) do if n:lower() == name:lower() then return end end
        list[#list + 1] = name
        apply_setting('Workers', table.concat(list, ','))
    end,
})

handoff = Handoff.new({ peers = peers, log = Log, now = mq.gettime, role = ROLE, me = ME, crafter = CRAFTER,
    serves_fn = function(name) return crew ~= nil and crew:serves(name) end,
    held = function() return workerHold end,
    runner = runner, trade = blocks.trade, nav = blocks.nav, spawns = blocks.spawns, cursor = blocks.cursor,
    travel = blocks.travel, zone = function() return mq.TLO.Zone.ShortName() or '' end,
    make = Make, makeEnv = { blocks = blocks, planner = planner, world = plan_world, cfg = cfg, log = Log, mq = mq, snapshot = snapshot,
        describe = Planner.describe, stacks = stacks, describe_money = Planner.money, factions = factions, me = ME,
        unsold = unsold,
        on_con = ROLE == 'worker' and function(npc, zone, word)
            peers:send(CRAFTER, 'faction', Peers.encode(npc), Peers.encode(zone), Peers.encode(word))
        end or nil } })

supply = ROLE == 'crafter' and Supply.new({ peers = peers, log = Log, now = mq.gettime, safe = cfg.travel.safe,
    zone_of = function(name)
        local e = crew.board[name:lower()]
        if e and not e.gone and e.zone and e.zone ~= '' then return e.zone end
        return crew.zones[name:lower()]
    end,
    running = function(name)
        local e = crew.board[name:lower()]
        return e ~= nil and not e.gone and crew:answering(e)
    end }) or nil

-- what each character on the network can summon, read from its spellbook over DanNet (2.42.12; crafter)
books = ROLE == 'crafter' and require('engine.books').new({ peers = peers, log = Log, now = mq.gettime, casters = casters,
    producers = cfg.producers,
    roster = function() return crew.roster or {} end,
    running = function(n) return crew:running(n) end,
    quiet = function() return supply and supply.surveying end }) or nil
if books then crew.asking_elsewhere = function(n) return books.pending[n:lower()] ~= nil end end

-- What the window's buttons do: every one of them only queues a job (or reads).
local makeEnv = { blocks = blocks, planner = planner, world = plan_world, cfg = cfg, log = Log, mq = mq, snapshot = snapshot,
    describe = Planner.describe, handoff = handoff, stacks = stacks, describe_money = Planner.money, rates = rates,
    supply = supply, crew = ROLE == 'crafter' and crew or nil, casters = casters, factions = factions, me = ME, unsold = unsold,
    books = books }
local myCasts   -- item -> true when this character has one of its spells; read once, again on request
local function my_casts()
    if not myCasts then
        myCasts = {}
        for item, p in pairs(cfg.producers or {}) do
            for _, t in ipairs(p.spells or { p }) do if blocks.cast:has(t.spell) then myCasts[item] = true; break end end
        end
    end
    return myCasts
end
-- BANK TRADESKILL GEAR (2.46.0; was Bank trophies): a button for when the crafting is done. Into this zone's bank
-- from the bags: every trophy and leveling aid (skills.ini Trophy=, Clicky=), every tool a recipe hands back
-- (recipes' Tools=: File, Smithy Hammer...), and every tradeskill kit (containers.ini kits) sitting inside a bag.
-- Never: a kit in a pack slot (1-10) - that is a bag in use; a kit with anything in it (named, left alone - every
-- kit of that name, so the wrong one is never taken); anything worn. A queue with entries still to run: nothing
-- happens - it may need them.
local gearTools   -- lower name -> name: every recipe's tools, read once
local function bank_trophies_job()
    local function tools()
        if gearTools then return gearTools end
        -- a tool is an item recipes hand back more often than they use up: Smithy Hammer (a tool 1298 times, used up
        -- once) is one; Empty Vial and Copper Sheet (a tool once, used up 53 and 10 times) are not
        gearTools = {}
        local asTool, asIn, names = {}, {}, {}
        for _, r in pairs(cfg.recipes or {}) do
            for _, t in ipairs(r.tools or {}) do local k = t.name:lower(); asTool[k] = (asTool[k] or 0) + 1; names[k] = t.name end
            for _, i in ipairs(r.ins or {}) do local k = i.name:lower(); asIn[k] = (asIn[k] or 0) + 1 end
        end
        for k, n in pairs(asTool) do if n > (asIn[k] or 0) then gearTools[k] = names[k] end end
        return gearTools
    end
    -- kits inside bags: name -> { n = empty ones, full = ones holding something }
    local function kits()
        local out = {}
        local Me = mq.TLO.Me
        for pk = 1, 10 do
            local bag = Me.Inventory('pack' .. pk)
            local cap = (tonumber(bag.ID()) or 0) > 0 and (tonumber(bag.Container()) or 0) or 0
            for i = 1, cap do
                local it = bag.Item(i)
                local nm = (tonumber(it.ID()) or 0) > 0 and it.Name() or nil
                local kit = nm and cfg.containerByBag[nm:lower()]
                if kit and cfg.containers[kit] and cfg.containers[kit].type == 'kit' then
                    local e = out[nm] or { n = 0, full = 0 }
                    if (tonumber(it.Items()) or 0) > 0 then e.full = e.full + 1 else e.n = e.n + 1 end
                    out[nm] = e
                end
            end
        end
        return out
    end
    local function held()
        local out, seen, skipped = {}, {}, {}
        local function add(item, n, what)
            if n > 0 and not seen[item:lower()] then
                seen[item:lower()] = true
                out[#out + 1] = { item = item, n = n, what = what }
            end
        end
        for _, list in pairs(cfg.modifiers or {}) do
            for _, m in ipairs(list) do add(m, blocks.inventory:count(m), 'trophy') end
        end
        for name, e in pairs(kits()) do
            seen[name:lower()] = seen[name:lower()] or false
            if e.full > 0 then
                skipped[#skipped + 1] = string.format('%s (%d with something in it)', name, e.full)
                seen[name:lower()] = true
            else add(name, e.n, 'kit') end
        end
        for k, name in pairs(tools()) do
            if seen[k] == nil then add(name, blocks.inventory:count(name), 'tool') end
        end
        table.sort(out, function(x, y) if x.what ~= y.what then return x.what > y.what end return x.item < y.item end)
        table.sort(skipped)
        return out, skipped
    end
    return {
        name = 'Bank tradeskill gear', confirm = true, usesToon = true,
        preflight = function()
            local list, skipped = held()
            local lines = {}
            local q = #queue:list()
            if q > 0 then
                lines[#lines + 1] = { level = 'block', text = string.format('The queue still has %d entr%s - run or clear it first (it may need this gear)',
                    q, q == 1 and 'y' or 'ies') }
            end
            if #list == 0 then lines[#lines + 1] = { level = 'block', text = 'No trophies, tools or empty kits in the bags' } end
            for _, it in ipairs(list) do lines[#lines + 1] = { level = 'ok', text = string.format('Bank %d %s (%s)', it.n, it.item, it.what) } end
            for _, sk in ipairs(skipped) do lines[#lines + 1] = { level = 'warn', text = 'Left in the bags: ' .. sk } end
            if not blocks.bank:banker() then lines[#lines + 1] = { level = 'block', text = 'No banker in this zone' } end
            return lines
        end,
        execute = function(ctx)
            local b, e = blocks.spawns:await(ctx, 'a banker', function() return blocks.bank:banker() end)
            if e then return e end
            if not b then return R.fail('no banker', 'no banker in this zone') end
            local o = blocks.bank:go_open(ctx, blocks.nav, b)
            if not o.ok then return o end
            local done = {}
            local list = held()
            local left = {}
            for _, it in ipairs(list) do
                if not ctx:checkpoint() then return R.fail('stopped') end
                if it.what == 'kit' then
                    -- a kit: one at a time into an empty top-level bank slot, never Auto Bank (Bank:deposit_container)
                    local put = 0
                    for _ = 1, it.n do
                        local d = blocks.bank:deposit_container(ctx, it.item)
                        if d.ok then put = put + 1; Log.info('Banked %s (%s)', it.item, d.value.where)
                        elseif d.why == 'no bank slot' then left[#left + 1] = it.item; Log.warn('%s', R.describe(d)); break
                        else return d end
                    end
                    if put > 0 then done[#done + 1] = string.format('%d %s', put, it.item) end
                else
                    local d = blocks.bank:deposit(ctx, it.item, it.n)
                    if not d.ok then return d end
                    done[#done + 1] = string.format('%d %s', it.n, it.item)
                    Log.info('Banked %d %s', it.n, it.item)
                end
            end
            if #left > 0 then Log.warn('No empty bank slot - left in the bags: %s', table.concat(left, ', ')) end
            blocks.bank:close_bags(ctx)
            local c = blocks.bank:close(ctx)
            if not c.ok then return c end
            return R.ok({ summary = #done > 0 and ('banked ' .. table.concat(done, ', ')) or 'nothing to bank' })
        end,
        cleanup = function(ctx)
            blocks.nav:stop(ctx)
            blocks.cursor:stow(ctx)
            if blocks.bank:is_open() then blocks.bank:close_bags(ctx); blocks.bank:close(ctx) end
            return R.ok()
        end,
    }
end

local estimateWorld, estimateAt, estimates = nil, 0, {}
local researchHeldCache = {}   -- item -> { n, at }: the Research tab's held counts
local unitCost = {}            -- recipe id -> { cost of one combine bought from scratch, some items have no price }
local pathEst = {}             -- skill -> { at, value }: the Leveling tab's path estimate   -- the window's cost estimates (actions.estimate)
-- Tradeskills this character can train (2.42.6): one whose skill cap reads 0 (Me.SkillCap - the class or race cannot:
-- Alchemy is shaman only, Make Poison rogue, Tinkering gnome) is left out of the Craft and Leveling lists and of Level
-- all. Read once a session; a cap the client does not answer counts as trainable.
local trainCache = {}
local function trainable(sk)
    local k = (sk or ''):lower()
    if trainCache[k] == nil then
        local def = cfg.skills[sk]
        local name = def and def.eqSkill or sk
        local ok, c = pcall(function() return mq.TLO.Me.SkillCap(name)() end)
        trainCache[k] = not (ok and tonumber(c) == 0)
    end
    return trainCache[k]
end
local function only_trainable(list)
    local out = {}
    for _, sk in ipairs(list or {}) do if trainable(sk) then out[#out + 1] = sk end end
    return out
end
do
    local hidden, seen = {}, {}
    for _, list in ipairs({ cfg.skillOrder or {}, cfg.skillNames or {} }) do
        for _, sk in ipairs(list) do
            if not seen[sk:lower()] then seen[sk:lower()] = true; if not trainable(sk) then hidden[#hidden + 1] = sk end end
        end
    end
    table.sort(hidden)
    if #hidden > 0 then Log.info('Tradeskills %s cannot train (skill cap 0), left out of the lists: %s', ME, table.concat(hidden, ', ')) end
end

-- RADIX (2.46.0): the Radix tab - the collection in skills.ini [Collection:Radix], made with care. Its products are
-- always kept (never sold or destroyed), every make shows its plan and waits for Go, and a recipe can have a
-- Draught of the Craftsman clicked before each of its combines: a failed combine then gives the ingredients back
-- (the Essence Fusion Chamber's Ancient Shield of Corrupted Tranquility is a drop). The Draught has a long
-- cooldown; a combine waits for it rather than going ahead unprotected, and none left stops the run there.
local radix = { on = {} }
function radix.opts() return (cfg.collectionOpts or {}).Radix or {} end
function radix.item() return radix.opts().Draught or 'Draught of the Craftsman' end
function radix.pre(name)
    for _, n in ipairs(Ini.list(radix.opts().Precombines)) do if n:lower() == name:lower() then return true end end
    return false
end
function radix.is_on(name)
    if radix.pre(name) then return false end   -- a precombine never takes a Draught
    local v = radix.on[name:lower()]
    if v ~= nil then return v end
    for _, n in ipairs(Ini.list(radix.opts().DraughtOn)) do if n:lower() == name:lower() then return true end end
    return false
end
-- the Draught now: how many, its cooldown, and whether what it gives is up
function radix.state()
    local item = radix.item()
    local st = { name = item, have = 0, ready = false, secs = 0, up = false }
    pcall(function()
        st.have = tonumber(mq.TLO.FindItemCount('=' .. item)()) or 0
        local it = mq.TLO.FindItem('=' .. item)
        if (tonumber(it.ID()) or 0) > 0 then
            st.secs = tonumber(it.TimerReady()) or 0
            st.ready = st.secs <= 0
            local sp = it.Spell.Name()
            if sp and sp ~= '' and sp ~= 'NULL' then st.spell = sp end
        end
        -- the buff by its own name (skills.ini DraughtBuff=), and by the item's spell in case they differ
        for _, b in ipairs({ radix.opts().DraughtBuff, st.spell }) do
            if b and b ~= '' and not st.up then
                st.up = (tonumber(mq.TLO.Me.Buff(b).ID()) or 0) > 0 or (tonumber(mq.TLO.Me.Song(b).ID()) or 0) > 0
                if st.up then st.buff = b end
            end
        end
    end)
    return st
end
-- before a combine of a ticked recipe: up already, or wait out the cooldown, close what is open, click it, see it land
function radix.guard(ctx, close, r)
    local st = radix.state()
    -- ONE ATTEMPT A DRAUGHT. Still up here means the last combine did not use it (a success may leave it): said,
    -- so a run or two shows which, and this combine goes ahead under it.
    if st.up then
        if radix.clicked then Log.info('%s: %s still up after the last combine - using it, no new click', r.label, st.buff or st.name) end
        return R.ok()
    end
    if st.have < 1 then
        return R.fail('no draught', string.format('no %s left - stopped so %s is not combined without one', st.name, r.name))
    end
    if not st.ready then
        Log.info('%s: waiting %ds for %s to come off cooldown', r.label, st.secs, st.name)
        ctx:status(string.format('Waiting %ds for %s', st.secs, st.name))
        local w = ctx:wait((st.secs + 5) * 1000, function() return radix.state().ready end)
        if not w.ok then
            if w.why == 'stopped' then return w end
            return R.fail('draught not ready', st.name .. ' did not come off cooldown')
        end
    end
    local c = close()
    if not c.ok then return c end
    mq.cmdf('/useitem "%s"', st.name)
    local w = ctx:wait(10000, function() local x = radix.state(); return x.up or not x.ready end)
    if not w.ok then
        if w.why == 'stopped' then return w end
        return R.fail('draught did not go off', string.format('clicked %s, nothing happened', st.name))
    end
    local after = radix.state()
    radix.clicked = true
    if after.up then Log.info('%s: %s clicked (%d left)', r.label, st.name, after.have)
    else Log.warn('%s: %s went on cooldown, but %s was not seen - going ahead', r.label, st.name, st.spell or 'its buff') end
    return R.ok()
end

function radix.make(recipe, n)
    runner:add(Make.job(makeEnv, recipe, n, {
        disposal = 'keep',
        name = string.format('Radix: %d %s', n, recipe.label or recipe.name),
        protect = function(r)
            if radix.is_on(r.name) then return function(ctx, close) return radix.guard(ctx, close, r) end end
        end,
        planned = function(plan)
            local want = 0
            for _, st in ipairs(plan.steps or {}) do
                if not st.cast and not st.order and not st.recipe.gather and radix.is_on(st.recipe.name) then
                    want = want + (st.combines or 0)
                end
            end
            if want == 0 then return R.ok() end
            local d = radix.state()
            if d.have < 1 and not d.up then
                return R.fail('no draught', string.format('the Draught is ticked for %d combine%s, and there is no %s in the bags',
                    want, want == 1 and '' or 's', d.name))
            end
            if d.have < want then
                Log.warn('%s: %d %s for up to %d combines - the run stops at the first combine without one', recipe.label,
                    d.have, d.name, want)
            end
            return R.ok()
        end,
    }))
    end

local actions
actions = {
    search = function(q, skill, range) return planner:search(q, skill and 300 or 50, skill, range) end,
    skills = function() return only_trainable(cfg.skillNames) end,
    plan = function(recipe, n) runner:add(plan_job(recipe, n)) end,
    make = function(recipe, n, opts) runner:add(Make.job(makeEnv, recipe, n, opts)) end,
    -- a leveling path: rows { recipe, n, disposal } with repeat to trivial, one Go (Make.chain)
    chain = function(rows, name) runner:add(Make.chain(makeEnv, rows, name)) end,
    levelAllOrder = function() return only_trainable(cfg.levelAll) end,
    -- Leveling: the skills in skills.ini order, and each one's path as rows { rung, recipes } (every recipe of
    -- that name and skill, harvested ones first; the first is the default pick)
    levelSkills = function() return only_trainable(cfg.skillOrder) end,
    -- with this character's own changes (core/paths): rungs taken off are left out; added recipes sit by their
    -- trivial, after the skills.ini rungs at or below it. Each row: { rung, recipes, key, added }
    levelRows = function(skill)
        local sk = cfg.skills[skill]
        local ch = paths:changes(skill)
        local rows = {}
        for _, rung in ipairs(sk and sk.rungs or {}) do
            if not ch.removed[rung.recipe:lower()] then
                local list = {}
                for _, r in ipairs(planner:find(rung.recipe)) do
                    if not r.skill or r.skill == skill then list[#list + 1] = r end
                end
                table.sort(list, function(a, b)
                    local ha, hb = a.id:sub(1, 1) == 'H', b.id:sub(1, 1) == 'H'
                    if ha ~= hb then return ha end
                    return a.id < b.id
                end)
                rows[#rows + 1] = { rung = rung, recipes = list, key = 'rung:' .. rung.recipe:lower() }
            end
        end
        for _, a in ipairs(ch.adds) do
            local r = cfg.recipes[a.id]
            if r then
                local row = { rung = { recipe = r.name, disposal = a.disposal }, recipes = { r }, key = 'add:' .. a.id:lower(), added = a.id }
                local at = #rows + 1
                for i, x in ipairs(rows) do
                    local t = x.recipes[1] and x.recipes[1].trivial
                    if t and r.trivial and t > r.trivial then at = i; break end
                end
                table.insert(rows, at, row)
            else
                Log.warn('Leveling %s: added recipe %s is not in the data - left out', skill, a.id)
            end
        end
        return rows
    end,
    levelAdd = function(skill, recipe)
        if paths:add(skill, recipe.id, 'sell') then Log.info('Leveling %s: added %s [%s] (trivial %s)', skill, recipe.label, recipe.id, tostring(recipe.trivial or '?')) end
    end,
    levelDrop = function(skill, row)
        if row.added then paths:forget(skill, row.added); Log.info('Leveling %s: took off %s (added)', skill, row.rung.recipe)
        else paths:remove(skill, row.rung.recipe); Log.info('Leveling %s: took off %s (skills.ini rung - Restore path brings it back)', skill, row.rung.recipe) end
    end,
    levelDisposal = function(skill, row, d) if row.added then paths:disposal(skill, row.added, d) end end,
    levelChanges = function(skill) return paths:count(skill) end,
    -- Research (research.ini): classes, levels, a class's rows { level, name, recipe }, held counts (bags + bank,
    -- read again every HELD_MS), a spell this character has scribed, and the make (Make.batch: counted in successes)
    researchClasses = function() return cfg.research.classes end,
    researchMyClass = function()
        local ok, c = pcall(function() return mq.TLO.Me.Class.Name() end)
        return ok and c and c:lower() or ''
    end,
    researchLevels = function(cls) return cfg.research.levels[cls] or {} end,
    researchRows = function(cls)
        local out = {}
        for _, lv in ipairs(cfg.research.levels[cls] or {}) do
            for _, e in ipairs(cfg.research.index[cls][lv]) do
                local r = cfg.recipes[e.id]
                if r then out[#out + 1] = { level = lv, name = e.name, recipe = r } end
            end
        end
        return out
    end,
    researchHeld = function(name)
        local t, c = mq.gettime(), researchHeldCache[name]
        if c and t - c.at < 3000 then return c.n end
        local n = (mq.TLO.FindItemCount('=' .. name)() or 0) + (mq.TLO.FindItemBankCount('=' .. name)() or 0)
        researchHeldCache[name] = { n = n, at = t }
        return n
    end,
    researchScribed = function(name)
        local spell = name:gsub('^Spell: ', ''):gsub('^Song: ', '')
        local ok, v = pcall(function() return mq.TLO.Me.Book(spell)() end)
        return ok and v ~= nil and v ~= 0
    end,
    researchMake = function(items, name) runner:add(Make.batch(makeEnv, items, name)) end,
    -- the queue (core/queue): shared by the Craft and Research tabs, run under one Go; a finished entry comes off
    queueList = function()
        local out = {}
        for _, e in ipairs(queue:list()) do
            out[#out + 1] = { id = e.id, kind = e.kind, n = e.n, disposal = e.disposal, recipe = cfg.recipes[e.recipe], recipeId = e.recipe }
        end
        return out
    end,
    queueAdd = function(kind, recipe, n, disposal)
        local e = queue:add(kind, recipe.id, n, disposal)
        if e then Log.info('Queue: %s x%d (%s) - %d in the queue', recipe.label, e.n, kind == 'craft' and 'combines' or 'in hand', #queue:list()) end
    end,
    queueRemove = function(id) queue:remove(id) end,
    queueMove = function(id, d) queue:move(id, d) end,
    queueSetN = function(id, n) queue:set_n(id, n) end,
    queueClear = function() queue:clear(); Log.info('Queue cleared') end,
    queueRun = function()
        local items = {}
        for _, e in ipairs(queue:list()) do
            local r = cfg.recipes[e.recipe]
            if r then items[#items + 1] = { recipe = r, qty = e.n, kind = e.kind, disposal = e.disposal, qid = e.id }
            else Log.warn('Queue: recipe %s is not in the data - left in the queue', e.recipe) end
        end
        if #items == 0 then return Log.info('The queue is empty') end
        runner:add(Make.batch(makeEnv, items, string.format('Queue: %d entr%s', #items, #items == 1 and 'y' or 'ies'), {
            done = function(it, ok) if ok then queue:remove(it.qid) end end,
        }))
    end,
    -- what each row of a path (as the tab shows it) takes to its trivial from the skill now, and the whole path:
    -- combines from core/rates (the skill-up model x your runs' factor, else this skill's, else K), coin from one
    -- combine bought from scratch.
    -- { rows = { [row key] = { combines, cost, source, unknown } }, total = { combines, cost, unknown, guess } }
    levelEstimate = function(skill, rows)
        local t = mq.gettime()
        local c = pathEst[skill]
        if c and t - c.at < 3000 and c.n == #rows then return c.value end
        local eqSkill, val, capv = actions.skillValue(skill)
        local s = val or 0
        local out = { rows = {}, total = { combines = 0, cost = 0 } }
        local empty = { zone = (mq.TLO.Zone.ShortName() or ''):lower(), bags = function() return 0 end, bank = function() return 0 end,
                        kit = function() return true end }
        for _, row in ipairs(rows) do
            local r = row.recipe
            local top = r.trivial and math.min(r.trivial, capv or r.trivial)
            if top and top > s then
                local n, source = rates:estimate(ME, eqSkill or skill, s, top, r.trivial)
                local u = unitCost[r.id]
                if not u then
                    local ok, p = pcall(function() return planner:plan(r.id, 10, empty) end)
                    u = { cost = ok and p and (p.cost or 0) / 10 or 0, unknown = not ok or not p or p.costUnknown or #p.problems > 0 }
                    unitCost[r.id] = u
                end
                out.rows[row.key] = { combines = n, cost = u.cost * n, source = source, unknown = u.unknown }
                out.total.combines = out.total.combines + n
                out.total.cost = out.total.cost + u.cost * n
                out.total.unknown = out.total.unknown or u.unknown
                out.total.guess = out.total.guess or source == 'guess'
                s = top
            end
        end
        pathEst[skill] = { at = t, n = #rows, value = out }
        return out
    end,
    levelRestore = function(skill) paths:restore(skill); Log.info('Leveling %s: path back to skills.ini', skill) end,
    -- one row's leftovers (engine/cleanup): what another row not at its trivial still needs is kept
    levelCleanup = function(skill, recipe)
        local eqSkill, val, capv = actions.skillValue(skill)
        local keep = {}
        for i, row in ipairs(actions.levelRows(skill) or {}) do
            for _, r in ipairs(row.recipes) do
                local open = r.trivial and not (val and val >= math.min(r.trivial, capv or r.trivial))
                if r.id ~= recipe.id and r.name:lower() ~= recipe.name:lower() and open then
                    -- all the way down its subcombines (2.43.1)
                    for k in pairs(Cleanup.needs(cfg, r)) do
                        keep[k] = keep[k] or string.format('row %d (%s) still needs it', i, r.label)
                    end
                end
            end
        end
        runner:add(Cleanup.job({ blocks = blocks, cfg = cfg, planner = planner, log = Log, mq = mq }, recipe, keep))
    end,
    -- every row at its trivial under one Go (2.43.5): `done` = { [row index] = recipe } as the tab shows them (the
    -- recipe picked in each row); what any other row not at its trivial needs stays, all the way down
    levelCleanupDone = function(skill, done)
        local recipes, keep = {}, {}
        local eqSkill, val, capv = actions.skillValue(skill)
        for i, row in ipairs(actions.levelRows(skill) or {}) do
            if done[i] then recipes[#recipes + 1] = done[i]
            else
                for _, r in ipairs(row.recipes) do
                    local open = r.trivial and not (val and val >= math.min(r.trivial, capv or r.trivial))
                    if open then
                        for k in pairs(Cleanup.needs(cfg, r)) do
                            keep[k] = keep[k] or string.format('row %d (%s) still needs it', i, r.label)
                        end
                    end
                end
            end
        end
        if #recipes == 0 then return Log.info('%s: no row is at its trivial yet - nothing to clean up', skill) end
        Log.info('Clean up %s: %d finished row%s - press Go', skill, #recipes, #recipes == 1 and '' or 's')
        runner:add(Cleanup.job_many({ blocks = blocks, cfg = cfg, planner = planner, log = Log, mq = mq },
            string.format('Clean up %s: %d finished row%s', skill, #recipes, #recipes == 1 and '' or 's'), recipes, keep))
    end,
    skillValue = function(skill)
        local sk = cfg.skills[skill]
        local name = sk and sk.eqSkill or skill
        local ok, v = pcall(function() return mq.TLO.Me.Skill(name)() end)
        return name, ok and tonumber(v) or nil, Make.skill_cap(mq, name)
    end,
    -- the skill a recipe raises: its game name and this character's value now
    skillOf = function(recipe)
        local sk = recipe.skill and cfg.skills[recipe.skill]
        local name = sk and sk.eqSkill or recipe.skill
        if not name then return nil end
        local ok, v = pcall(function() return mq.TLO.Me.Skill(name)() end)
        return name, ok and tonumber(v) or nil
    end,
    summon = function()
        local rows, mine = {}, my_casts()
        for _, item in ipairs(cfg.producerOrder or {}) do
            local p = cfg.producers[item]
            local names = {}
            if ROLE == 'crafter' then for _, e in ipairs(crew:casters(item)) do names[#names + 1] = e.name end end
            -- who could, not running (2.41.9): cast it before, or of its class; safe = can be started from here
            local could, lacking = {}, {}
            if casters then
                for _, c in ipairs(casters:candidates(item, p, function(n) return n:lower() ~= ME:lower() and not crew:running(n) end)) do
                    local z = crew.zones[c.name:lower()]
                    could[#could + 1] = { name = c.name, why = c.why, safe = z ~= nil and (cfg.travel.safe or {})[z] == true }
                end
                lacking = casters:lacking(item)
            end
            rows[#rows + 1] = { group = p.group, item = item, me = mine[item] == true, workers = names, could = could, lacking = lacking }
        end
        return rows
    end,
    refreshSummon = function() myCasts = nil end,
    cast = function(item, n) runner:add(Make.get_job(makeEnv, item, n, { confirm = true, name = string.format('Summon %d %s', n, item) })) end,
    order = function(worker, item, n) runner:add(handoff:order_job(worker, item, n)) end,
    startWorker = ROLE == 'crafter' and function(name) crew:start_worker(name) end or nil,
    -- a worker's Pause / Resume (its own window)
    held = function() return workerHold end,
    hold = function(on)
        workerHold = on and true or false
        if workerHold then
            Log.info('Paused by hand - %s waits until Resume%s', CRAFTER ~= '' and CRAFTER or 'the crafter',
                (handoff and handoff:giving()) and ' (once this trade is done)' or '')
            if runner.active and not handoff:giving() then runner:pause() end
        else
            runner:resume()
            Log.info('Resumed by hand')
        end
    end,
    -- the crafter's Close all (as AdventureTime's): LazCraft quits on every worker, then here
    closeAll = ROLE == 'crafter' and function()
        local names = {}
        for _, e in pairs(crew.board) do if not e.gone then names[#names + 1] = e.name end end
        table.sort(names)
        for _, n in ipairs(names) do peers:raw(n, '/lc quit') end
        Log.info('Close all: LazCraft quits on %s%s and here', #names > 0 and table.concat(names, ', ') or 'no worker',
            #names > 0 and '' or '')
        quitting = true
        runner:stop()
    end or nil,
    restartWorker = ROLE == 'crafter' and function(name) crew:restart_worker(name) end or nil,
    -- the Workers tab's Check spellbooks: every character on the network not running, asked again (engine/books)
    checkBooks = ROLE == 'crafter' and function()
        local n = 0
        for _, name in ipairs(crew.roster or {}) do
            if not crew:running(name) and books:check(name, 'Check spellbooks') then n = n + 1 end
        end
        Log.info('Spellbooks: checking %d character%s%s', n, n == 1 and '' or 's',
            n == 0 and ' (needs DanNet; a running worker\'s card already says what it casts)' or '')
    end or nil,
    bookBusy = ROLE == 'crafter' and function() return books:busy() end or nil,
    roster = ROLE == 'crafter' and function() return crew:roster_view(cfg.travel.safe) end or nil,
    -- open summon orders (ordered ahead at Go): worker, item, n, have, taken, status
    summons = ROLE == 'crafter' and function() return handoff and handoff:summon_view() or {} end or nil,
    zones = function()
        local seen, out = {}, {}
        for _, h in ipairs(cfg.travel.hops or {}) do
            if h.to ~= '*' and not seen[h.to] then seen[h.to] = true; out[#out + 1] = h.to end
        end
        table.sort(out)
        return out
    end,
    here = function() return blocks.travel:zone() end,
    travel = function(zone) runner:add(travel_job(zone)) end,
    bankTrophies = function() runner:add(bank_trophies_job()) end,
    -- the plan's cost for n combines of a recipe (Alla prices), and the coin carried, both in copper; the
    -- bags and bank are read at most every ESTIMATE_MS so the window can ask every frame
    estimate = function(recipe, n)
        local t = mq.gettime()
        -- not re-read while a job runs (it changes the bags every second; the estimate can wait)
        local busy = runner.active ~= nil or #runner.queue > 0
        if not estimateWorld or (t - estimateAt > 5000 and not busy) then estimateWorld, estimateAt = plan_world(true), t end
        local key = recipe.id .. '|' .. n .. '|' .. estimateAt
        if estimates[key] == nil then
            local ok, p = pcall(function() return planner:plan(recipe.id, n, estimateWorld) end)
            estimates[key] = ok and p and (p.cost or 0) or false
        end
        local Me = mq.TLO.Me
        local coin = (Me.Platinum() or 0) * 1000 + (Me.Gold() or 0) * 100 + (Me.Silver() or 0) * 10 + (Me.Copper() or 0)
        return estimates[key] or nil, coin
    end,
    money = function(c) return Planner.money(c) end,
    -- the Radix tab (2.46.0): its rows { name, recipe }, the Draught's state, the per-recipe tick, and the make
    radixRows = function()
        local out = {}
        for _, name in ipairs(cfg.collections.Radix or {}) do
            local list, r = planner:find(name), nil
            for _, x in ipairs(list) do if (x.name or ''):lower() == name:lower() then r = x; break end end
            out[#out + 1] = { name = name, recipe = r, pre = radix.pre(name) }
        end
        return out
    end,
    radixDraught = function() return radix.state() end,
    radixOneAtATime = function(name)
        for _, x in ipairs(Ini.list(radix.opts().OneAtATime)) do if x:lower() == name:lower() then return true end end
        return false
    end,
    radixDraughtOn = function(name, v)
        if v ~= nil then radix.on[name:lower()] = v and true or false end
        return radix.is_on(name)
    end,
    radixMake = function(recipe, n) radix.make(recipe, n) end,
    -- the Craft tab's ingredient table (2.43.0): for each ingredient and tool of n combines, what is needed, what
    -- is held (bags + bank) and where the rest comes from - the plan worked out quietly, on the same world read
    -- as the estimate (at most every 5s, not while a job runs). -> { { name, need, have, from, kind } } or nil
    preview = function(recipe, n)
        local t = mq.gettime()
        local busy = runner.active ~= nil or #runner.queue > 0
        if not estimateWorld or (t - estimateAt > 5000 and not busy) then estimateWorld, estimateAt = plan_world(true), t end
        local key = 'p|' .. recipe.id .. '|' .. n .. '|' .. estimateAt
        if estimates[key] ~= nil then return estimates[key] or nil end
        local w = estimateWorld
        local ok, p = pcall(function() return planner:plan(recipe.id, n, w) end)
        if not ok or not p or not p.tree then estimates[key] = false; return nil end
        -- who sells what this plan buys, by item (its merchant stops)
        local seller = {}
        for zone, stops in pairs(p.buys or {}) do
            for _, st in ipairs(stops) do
                for _, it in ipairs(st.items) do seller[it.item:lower()] = string.format('%s, %s', st.npc, zone) end
            end
        end
        local rows = {}
        local function add(node, tool)
            local name = node.item
            local have = (w.bags(name) or 0) + (w.bank(name) or 0)
            local parts, kind = {}, 'ok'
            if (node.bags or 0) > 0 then parts[#parts + 1] = 'bags' end
            if (node.bank or 0) > 0 then parts[#parts + 1] = 'bank ' .. node.bank end
            if node.make then parts[#parts + 1] = string.format('make (%d combine%s)', node.make.combines, node.make.combines == 1 and '' or 's') end
            if node.cast then parts[#parts + 1] = 'cast it' end
            if node.order then parts[#parts + 1] = node.order.worker .. ' casts it' end
            for _, o in ipairs(node.supply or {}) do parts[#parts + 1] = string.format('%s brings %d', o.worker, o.n) end
            if (node.buy or 0) > 0 then
                parts[#parts + 1] = string.format('buy %d%s', node.buy, seller[name:lower()] and (' - ' .. seller[name:lower()]) or '')
                kind = 'buy'
            end
            if (node.short or 0) > 0 then parts[#parts + 1] = string.format('short %d', node.short); kind = 'short' end
            if #parts == 0 and node.have then parts[1] = 'bags' end
            rows[#rows + 1] = { name = name .. (tool and ' (tool)' or ''), need = node.need or 1, have = have,
                                from = table.concat(parts, ', '), kind = kind }
        end
        for _, c in ipairs(p.tree.children) do add(c) end
        for _, tl in ipairs(p.tree.tools) do add(tl, true) end
        estimates[key] = rows
        return rows
    end,
}

local ui = Window.new({
    ImGui = require('ImGui'), runner = runner, log = Log, version = VERSION, role = ROLE, crew = crew,
    settings = settings, settingsMeta = Config.SETTINGS_META, onSetting = apply_setting, actions = actions,
    mq = mq, me = ME, logoPath = SCRIPT_DIR .. 'ui/emblem.png', logoAspect = 280 / 192,
    crafter = function() return CRAFTER end,
})

local USAGE = '/lc show | hide | test | go | cancel | pause | resume | stop | log on|off|debug|info | quit | closeall | radix <n> [draught|nodraught] <recipe>'
    .. ' | inv <item> | pickup <n> <item> | stow | close <window> | bag <n> | bagtest <times> [gap <ms>] <item>'
    .. ' | snap | navtest <trips> [dist <n>] <npc>, <npc> | buytest <times> <n> <npc>, <item> | givepp <n> <name>'
    .. ' | combinetest <times> <kit>, <product>, <ingredient>, <ingredient>...'
    .. ' | stationtest <times> <station>, <product>, <ingredient>, <ingredient>...'
    .. ' | banktest <times> <n> <item> | withdraw <n|all> <item> | deposit <n|all> <item>'
    .. ' | plan <combines> <recipe> | make <combines> <recipe> | bankcount <item> | travel <zone>'
    .. ' | workers | worker <name> | fetch <worker> <n> <item> | order <worker> <n> <item>'

-- Each command gets the words typed after it. Item and window names keep their case.
local function rest(words, from) return table.concat(words, ' ', from or 1) end

-- One recipe from a name, label or id. With several, lists them (pick by id); with none, suggests close names.
local function pick_recipe(query)
    local found = planner:find(query)
    if #found == 1 then return found[1] end
    if #found == 0 then
        local near = planner:suggest(query, 10)
        if #near == 0 then
            local longest = ''
            for word in query:gmatch('%S+') do if #word > #longest then longest = word end end
            near = planner:suggest(longest, 10)
        end
        if #near == 0 then Log.info('No recipe called "%s"', query)
        else Log.info('No recipe called "%s". Close: %s', query, table.concat(near, ', ')) end
        return nil
    end
    Log.info('"%s" has %d recipes - pick one by id:', query, #found)
    table.sort(found, function(a, b) return a.id < b.id end)
    for _, r in ipairs(found) do
        local ins = {}
        for _, i in ipairs(r.ins) do ins[#ins + 1] = i.n .. ' ' .. i.name end
        Log.info('  [%s] %s: %s (%s)', r.id, r.label, table.concat(ins, ', '), r.container)
    end
    return nil
end

-- The item a typed name means. One match is used (and said); several are listed to pick from.
-- `loose`: no match at all is sent as typed (a fetch can be any item in the worker's bags).
local function item_name(typed, loose)
    local name, list = planner:match_item(typed)
    if name then
        if name ~= typed then Log.info('"%s" = %s', typed, name) end
        return name
    end
    if #list == 0 then
        if loose then return typed end
        Log.info('No item called "%s" in the data', typed)
        return nil
    end
    Log.info('"%s" could be: %s - type the full name', typed, table.concat(list, ', '))
    return nil
end

local COMMANDS = {
    show   = function() ui.visible = true end,
    hide   = function() ui.visible = false end,
    test   = function() runner:add(test_job()) end,
    go     = function() runner:approve() end,
    cancel = function() runner:cancel() end,
    pause  = function() runner:pause() end,
    resume = function() runner:resume() end,
    stop   = function() runner:stop() end,
    quit   = function() quitting = true; runner:stop() end,
    closeall = function()
        if ROLE ~= 'crafter' then return Log.info('Close all is the crafter\'s (it closes every worker too)') end
        actions.closeAll()
    end,
    inv    = function(w)
        if #w > 0 then runner:add(check_inventory_job(rest(w))) else Log.info('/lc inv <item>') end
    end,
    pickup = function(w)
        local n = tonumber(w[1])
        if n and n >= 1 and #w > 1 then runner:add(check_pickup_job(rest(w, 2), math.floor(n)))
        else Log.info('/lc pickup <n> <item>') end
    end,
    stow   = function() runner:add(stow_job()) end,
    bagtest = function(w)
        local times, gap, from = tonumber(w[1]), 0, 2
        if (w[2] or ''):lower() == 'gap' and tonumber(w[3]) then gap, from = math.max(0, math.floor(tonumber(w[3]))), 4 end
        if times and times >= 1 and #w >= from then runner:add(bag_stress_job(rest(w, from), math.floor(times), 5, gap))
        else Log.info('/lc bagtest <times> [gap <ms>] <item>  (takes 5 each round from a closed bag)') end
    end,
    navtest = function(w)
        local trips, dist, from = tonumber(w[1]), 10, 2
        if (w[2] or ''):lower() == 'dist' and tonumber(w[3]) then dist, from = math.max(1, math.floor(tonumber(w[3]))), 4 end
        local names = {}
        for part in rest(w, from):gmatch('[^,]+') do
            local nm = part:match('^%s*(.-)%s*$')
            if nm ~= '' then names[#names + 1] = nm end
        end
        if trips and trips >= 1 and #names >= 1 then runner:add(nav_test_job(names, math.floor(trips), dist))
        else Log.info('/lc navtest <trips> [dist <n>] <npc>, <npc>  (default dist 10)') end
    end,
    snap = function() snapshot:dump('asked: /lc snap') end,
    buytest = function(w)
        local times, n = tonumber(w[1]), tonumber(w[2])
        local npc, item = rest(w, 3):match('^%s*(.-)%s*,%s*(.-)%s*$')
        if times and n and times >= 1 and n >= 1 and npc and npc ~= '' and item ~= '' then
            runner:add(buy_test_job(npc, item, math.floor(n), math.floor(times)))
        else Log.info('/lc buytest <times> <n> <npc>, <item>  (buys n and sells n back each time)') end
    end,
    givepp = function(w)
        local n, name = tonumber(w[1]), w[2]
        if n and n >= 1 and name and name ~= '' then runner:add(givepp_test_job(math.floor(n), name))
        else Log.info('/lc givepp <n> <name>  (gives n platinum; they click Trade by hand)') end
    end,
    combinetest = function(w)
        local times = tonumber(w[1])
        local parts = {}
        for part in rest(w, 2):gmatch('[^,]+') do
            local p = part:match('^%s*(.-)%s*$')
            if p ~= '' then parts[#parts + 1] = p end
        end
        if times and times >= 1 and #parts >= 3 then
            local ings = {}
            for i = 3, #parts do ings[#ings + 1] = parts[i] end
            runner:add(combine_test_job(parts[1], parts[2], ings, math.floor(times)))
        else Log.info('/lc combinetest <times> <kit>, <product>, <ingredient>, <ingredient>...  (one of each, in slot order)') end
    end,
    stationtest = function(w)
        local times = tonumber(w[1])
        local parts = {}
        for part in rest(w, 2):gmatch('[^,]+') do
            local p = part:match('^%s*(.-)%s*$')
            if p ~= '' then parts[#parts + 1] = p end
        end
        if times and times >= 1 and #parts >= 3 then
            local ings = {}
            for i = 3, #parts do ings[#ings + 1] = parts[i] end
            runner:add(station_test_job(parts[1], parts[2], ings, math.floor(times)))
        else Log.info('/lc stationtest <times> <station>, <product>, <ingredient>, <ingredient>...  (station = its clickable name: Forge, Oven, Brewing Barrel...)') end
    end,
    banktest = function(w)
        local times, n = tonumber(w[1]), tonumber(w[2])
        if times and n and times >= 1 and n >= 1 and #w > 2 then runner:add(bank_test_job(rest(w, 3), math.floor(n), math.floor(times)))
        else Log.info('/lc banktest <times> <n> <item>  (takes n out of the bank and puts n back each time)') end
    end,
    withdraw = function(w)
        local n = (w[1] or ''):lower() == 'all' and math.huge or tonumber(w[1])
        if n and n >= 1 and #w > 1 then runner:add(bank_move_job('out', rest(w, 2), n == math.huge and n or math.floor(n)))
        else Log.info('/lc withdraw <n|all> <item>') end
    end,
    deposit = function(w)
        local n = (w[1] or ''):lower() == 'all' and math.huge or tonumber(w[1])
        if n and n >= 1 and #w > 1 then runner:add(bank_move_job('in', rest(w, 2), n == math.huge and n or math.floor(n)))
        else Log.info('/lc deposit <n|all> <item>') end
    end,
    plan = function(w)
        local n = tonumber(w[1])
        if not n or n < 1 or #w < 2 then return Log.info('/lc plan <combines> <recipe name, label or id>') end
        local r = pick_recipe(rest(w, 2))
        if r then runner:add(plan_job(r, math.floor(n))) end
    end,
    -- /lc make <combines> [keep|sell|destroy] [trivial|repeat] <recipe>   (repeat = again until the trivial)
    make = function(w)
        local n = tonumber(w[1])
        local usage = '/lc make <combines> [keep|sell|destroy] [trivial|repeat] <recipe name, label or id>'
        if not n or n < 1 or #w < 2 then return Log.info(usage) end
        local from, opts = 2, {}
        while w[from] do
            local word = w[from]:lower()
            if word == 'keep' or word == 'sell' or word == 'destroy' then opts.disposal = word
            elseif word == 'trivial' then opts.stopAtTrivial = true
            elseif word == 'repeat' then opts.stopAtTrivial, opts.repeatToTrivial = true, true
            else break end
            from = from + 1
        end
        if not w[from] then return Log.info(usage) end
        local r = pick_recipe(rest(w, from))
        if r then runner:add(Make.job(makeEnv, r, math.floor(n), opts)) end
    end,
    -- /lc radix <combines> [draught|nodraught] <recipe> (2.46.0): a Radix make, as the Radix tab's Make; draught /
    -- nodraught ticks or unticks the Draught of the Craftsman for that recipe first
    radix = function(w)
        local n = tonumber(w[1])
        local usage = '/lc radix <combines> [draught|nodraught] <Radix recipe>'
        if not n or n < 1 or #w < 2 then return Log.info(usage) end
        local from, d = 2, nil
        local word = (w[2] or ''):lower()
        if word == 'draught' then d = true; from = 3 elseif word == 'nodraught' then d = false; from = 3 end
        if not w[from] then return Log.info(usage) end
        local r = pick_recipe(rest(w, from))
        if not r then return end
        local isRadix = false
        for _, x in ipairs(cfg.collections.Radix or {}) do if x:lower() == (r.name or ''):lower() then isRadix = true end end
        if not isRadix then return Log.warn('%s is not a Radix recipe (skills.ini [Collection:Radix])', r.name) end
        if d ~= nil and radix.pre(r.name) then Log.info('%s is a precombine - no Draught', r.name)
        elseif d ~= nil then radix.on[r.name:lower()] = d end
        for _, x in ipairs(Ini.list(radix.opts().OneAtATime)) do
            if x:lower() == r.name:lower() and n > 1 then Log.info('%s is made one at a time - 1 combine', r.name); n = 1 end
        end
        radix.make(r, math.floor(n))
    end,
    -- /lc have <n> <recipe>: end up holding n of its product, failures made again (Make.batch, as the Research tab)
    have = function(w)
        local n = tonumber(w[1])
        if not n or n < 1 or #w < 2 then return Log.info('/lc have <n> <recipe name, label or id>  (n in hand: what is held counts, a failure is made again)') end
        local r = pick_recipe(rest(w, 2))
        if r then runner:add(Make.batch(makeEnv, { { recipe = r, qty = math.floor(n) } }, string.format('Have %d %s', n, r.label))) end
    end,
    -- Crew: ask every worker for a fresh card (the Workers tab shows them), or start one.
    workers = function()
        if ROLE ~= 'crafter' then return Log.info('Working for %s', CRAFTER) end
        local rows = crew:view()
        if #rows == 0 then Log.info('No workers yet - /lc worker <name> starts one') end
        for _, r in ipairs(rows) do
            Log.info('  %s: %s%s', r.name, r.status,
                r.zone and string.format(' - %s, %s, casts %s', r.zone, r.state, #r.items > 0 and table.concat(r.items, ', ') or 'nothing') or '')
        end
        crew:hello()
    end,
    worker = function(w)
        if ROLE ~= 'crafter' then return Log.info('Only the crafter starts workers') end
        if #w ~= 1 then return Log.info('/lc worker <name>  (runs LazCraft on that character, working for you)') end
        crew:start_worker(w[1])
    end,
    fetch = function(w)
        if ROLE ~= 'crafter' then return Log.info('Only the crafter fetches from workers') end
        local n = tonumber(w[2])
        if #w < 3 or not n or n < 1 then return Log.info('/lc fetch <worker> <n> <item>  (the worker comes to you and trades them over)') end
        local item = item_name(rest(w, 3), true)
        if item then runner:add(handoff:fetch_job(w[1], item, math.floor(n))) end
    end,
    order = function(w)
        if ROLE ~= 'crafter' then return Log.info('Only the crafter orders from workers') end
        local n = tonumber(w[2])
        if #w < 3 or not n or n < 1 then return Log.info('/lc order <worker> <n> <item>  (the worker gets them - bags, bank, buy, make, cast - then brings them)') end
        local item = item_name(rest(w, 3), false)
        if item then runner:add(handoff:order_job(w[1], item, math.floor(n))) end
    end,
    travel = function(w)
        if #w ~= 1 then return Log.info('/lc travel <zone short name>  (e.g. poknowledge, freeporttemple, abysmal)') end
        runner:add(travel_job(w[1]:lower()))
    end,
    -- /lc level <skill> | all: the leveling path (skills.ini rungs, 10 combines a pass, the rung's product
    -- setting, its first recipe) row after row, each until its trivial. The Leveling tab's buttons use its rows.
    level = function(w)
        local function rows_for(sk)
            local out = {}
            for _, row in ipairs(actions.levelRows(sk) or {}) do
                if row.recipes[1] then out[#out + 1] = { recipe = row.recipes[1], n = 10, disposal = row.rung.disposal or 'keep' } end
            end
            return out
        end
        local which = table.concat(w, ' ')
        if which:lower() == 'all' then
            local rows = {}
            local all = only_trainable(cfg.levelAll)
            for _, sk in ipairs(all) do for _, r in ipairs(rows_for(sk)) do rows[#rows + 1] = r end end
            return runner:add(Make.chain(makeEnv, rows, 'Level all: ' .. table.concat(all, ', ')))
        end
        for name in pairs(cfg.skills) do
            if name:lower() == which:lower() then
                if not trainable(name) then return Log.info('%s cannot train %s (skill cap 0)', ME, name) end
                return runner:add(Make.chain(makeEnv, rows_for(name), 'Level ' .. name))
            end
        end
        Log.info('/lc level <skill> | all   (skills: %s)', table.concat(only_trainable(cfg.skillOrder), ', '))
    end,
    -- /lc banktrophies: every trophy and leveling aid in the bags (not the one worn) into the bank here
    banktrophies = function() runner:add(bank_trophies_job()) end,
    bankgear = function() runner:add(bank_trophies_job()) end,
    bankcount = function(w)
        if #w == 0 then return Log.info('/lc bankcount <item>') end
        local item = rest(w)
        local places, readable = blocks.bank:find(item)
        local bySlots = 0
        for _, p in ipairs(places) do bySlots = bySlots + p.stack end
        local client = mq.TLO.FindItemBankCount('=' .. item)() or 0
        Log.info('%s in the bank (bank %s): %d slot by slot (%s, %d stack%s), %d by FindItemBankCount (includes the shared bank)',
            item, blocks.bank:is_open() and 'open' or 'closed', bySlots, readable and 'slots readable' or 'slots NOT readable',
            #places, #places == 1 and '' or 's', client)
        for _, p in ipairs(places) do Log.info('  bank%d%s: %d', p.bank, p.slot and (' slot ' .. p.slot) or '', p.stack) end
    end,
    bag    = function(w)
        local n = tonumber(w[1])
        if n then runner:add(check_bag_job(math.floor(n))) else Log.info('/lc bag <pack number>') end
    end,
    close  = function(w)
        if #w > 0 then runner:add(close_window_job(rest(w))) else Log.info('/lc close <window>') end
    end,
    log    = function(w)
        local arg = (w[1] or ''):lower()
        if arg == 'on' then apply_setting('LogToFile', '1')
        elseif arg == 'off' then apply_setting('LogToFile', '0')
        elseif arg == 'debug' or arg == 'info' then apply_setting('LogLevel', arg)
        else return Log.info('/lc log on|off|debug|info') end
    end,
}

-- Commands only set flags or queue jobs; the main loop does the work.
mq.bind('/lc', function(cmd, ...)
    local f = COMMANDS[(cmd or ''):lower()]
    if f then f({ ... }) else Log.info(USAGE) end
end)

if ROLE == 'crafter' then
    mq.imgui.init('LazCraft', function() ui:draw() end)
else
    mq.imgui.init('LazCraft', function() ui:draw_worker(CRAFTER) end)
end

Log.info('LazCraft %s started on %s as %s%s', VERSION, ME, ROLE,
    CRAFTER ~= '' and (' for ' .. CRAFTER) or '')
-- A worker started with no crafter named (2.42.10; it used to quit, and in game it looked like a crash): it waits and
-- works for the first crafter whose hello comes (the crafter's start, or its Workers tab: Ask workers).
if ROLE == 'worker' and CRAFTER == '' then
    Log.info('No crafter named - waiting: this worker works for the first crafter that says hello (its Workers tab: Ask workers), or /lua run lazcraft worker <crafter name>')
end
do
    crew:start()
    handoff:start()
    -- a worker takes its crafter's theme (2.43.0): saved, so the window keeps it after a restart too
    if ROLE == 'worker' then
        peers:on('theme', function(from, name)
            name = Peers.decode(name or '')
            if CRAFTER ~= '' and from:lower() ~= CRAFTER:lower() then return end
            if not require('ui.theme').valid(name) then
                Log.warn('Theme from %s: %s is not a theme here (Midnight, Slate, Ember, Glass) - kept %s', from, name, tostring(settings.Theme))
                return
            end
            if settings.Theme ~= name then
                Log.info('Theme: %s from %s', name, from)
                apply_setting('Theme', name)
            end
        end)
    end
    -- a worker's con of a faction-zone merchant, told to its crafter: who to send next time (2.42.4)
    if ROLE == 'crafter' then
        peers:on('faction', function(from, npc, zone, word)
            npc, zone, word = Peers.decode(npc), Peers.decode(zone), Peers.decode(word)
            factions:set(from, npc, zone, word)
            Log.info('Faction: %s regards %s %s%s', npc, from, word, require('core.factions').can_buy(word) and '' or ' - too low to buy')
        end)
    end
end
Log.info('Settings: %s', SETTINGS_PATH)
if Log.file_path() then Log.info('Logging every step to %s', Log.file_path()) end

while not quitting do
    background()
    if mq.TLO.EverQuest.GameState() == 'INGAME' then
        -- paused by hand and nothing running: nothing new starts until Resume
        local ok, err = true, nil
        if not (workerHold and not runner.active) then ok, err = xpcall(function() runner:step() end, debug.traceback) end
        if not ok then runner:abort(err) end
    end
    mq.delay(50)
end

-- Leave the character as we found it.
runner:stop()
e3:release()
crew:stop()
mq.unbind('/lc')
Log.info('LazCraft stopped')
Log.close_file()
