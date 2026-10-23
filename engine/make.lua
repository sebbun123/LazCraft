-- Make: carries out a plan with the building blocks. One job: preflight = the plan; execute = bank, shop,
-- then every step in order (subcombines first), N combines each; report per step.
--
--   Make.job(env, recipe, combines)   env = { blocks, planner, world = function() -> world, cfg, log, mq }
--   Make.get_job(env, item, n, hooks) end up holding n of an item (a worker's order): no Go, no preflight;
--       hooks.planned(plan) -> R   called with the plan before anything happens (fail = do nothing)
--       hooks.confirm              show the plan and wait for Go (the Summon tab's Make)
--   Make.job hooks (both):
--       hooks.disposal             what happens to the recipe's product: 'keep' (default), 'sell', 'destroy'
--       hooks.stopAtTrivial        stop the recipe's combines once the skill reaches its trivial
--       hooks.repeatToTrivial      (leveling) after the combines, plan, buy and make again until the trivial - a
--                                  later pass sized to the points left (pass_size; implies stopAtTrivial)
--       hooks.name                 the job's name
--       hooks.protect(recipe)      -> nil, or guard(ctx, close) -> R run before each combine of that recipe (Radix:
--                                  click the Draught of the Craftsman); close() shuts what is open first. A failed
--                                  guard stops the step there, before the combine.
--
-- Rules it keeps:
--   * Nothing happens unless the plan is clean (no blocks) and Go is pressed. The plan is worked out again at
--     Go: if anything changed since the preflight that now blocks it, nothing is done.
--   * The route is walked zone by zone with the travel block: in each zone the bank trip if it is the bank
--     zone, then one stop per merchant there, each move confirmed by the counts. The route ends in the
--     zone where the crafting happens.
--   * A faction zone (travel.ini [Faction]: Thurgadin, Jaggedpine, Felwithe): every merchant on the zone's list is
--     conned on arrival - a con works from anywhere in the zone - and the standing saved (core/factions, and told
--     to the crafter by a worker). Any too low (worse than apprehensively): nothing is bought, the pass is planned
--     again without them - a worker with the faction buys it (world.buyer), or the plan says why not. After
--     shopping there - bought, or not - we Marr's Calling straight out (2.42.0).
--   * Steps in the plan's order. A container stays open while consecutive steps use it. A station in use is
--     never waited on: the next one here, then this zone's AFK mirror, then other zones (open_station).
--   * Every combine places one unit per slot (ingredients in recipe order, then tools). Before it is fired
--     the container must hold exactly those, slot for slot. It is confirmed by the game's message. "make N" is N attempts; a skill failure still counts as an attempt.
--   * If a step runs out of an ingredient (earlier failures, a tool a failure kept), it stops there and the
--     next steps make what they can; the report says what ran short.
--   * Anything on the cursor before a pickup is a late return from the last combine: stowed, logged, carry on.
--   * A kit inside a bag is moved into pack10 for its step (the kitslot block); at the end, done or not,
--     the inventory is put back: the original pack10 bag in pack10, every kit where it was found.
--   * A cast step (producers.ini, a spell this character has) runs through the cast block: nothing open, then
--     N casts, each confirmed by the product arriving.
--   * An item a worker casts (nobody here has the spell) is ordered from it at Go, before the route, so it
--     works while we do; just before the first step that needs it we wait for it, it comes, and trades
--     exactly what is needed (engine/handoff). Workers never travel after us: one in another zone is
--     collected in its zone (we go there first, travel.ini); one here, before the route leaves this zone.
--     An order still open when the job ends is called off.
--   * The product (the recipe asked for - never a subcombine, which the next step needs) is kept, sold or
--     destroyed. Destroy: off the cursor as each combine hands it back (the combine block only ever destroys
--     the product of a success, by name). Sell: what this run made, at a merchant in this zone (merchants.ini),
--     at the end - and before a combine when the bags are down to ROOM free slots; a stack of it worn in Ammo
--     (a throwing item /autoinventory topped up there) comes off into the bags first. Keep, or anything a merchant
--     will not take: it stays, and a run that fills the bags stops there with the reason.
--   * Stop at trivial (leveling): before each of the recipe's combines the skill is read; at the trivial it
--     stops - or at the character's cap for the skill when that is lower (Me.SkillCap, never above SKILL_CAP:
--     a class can cap a skill below 300, and combines past the cap raise nothing; the old LazCraft's rule).
--     stops. The skill is logged at the start and end of the recipe either way.
--   * Bags (2.24.0): before shopping, the plan's new bag slots are counted - each item bought or pulled from
--     the bank at its stack size (core/stacks; 1 = does not stack), plus a non-stacking subcombine product
--     that waits in the bags for the next step - against the free slots less ROOM. When the combines asked
--     for do not fit, the run makes as many as do (the most combines whose plan fits) and says so; repeat
--     to trivial carries on with the next pass. None fit = it stops with the reason, nothing bought. At each
--     merchant the real stack sizes are read: stackables are bought first, non-stacking items last, and a
--     buy that would not fit is cut to what does (said), so nothing is ever left on the cursor.
--   * Short of a held item (nobody sells it, the network has too few in safe zones): the run makes the most
--     combines what is on hand and on the network covers, and says so (2.39.4); none = it is passed.
--   * Repeat to trivial: the whole run (plan, bank, shop, combines, disposal) is one pass; passes go on until
--     the skill reaches the trivial (read before every combine and every pass). Each pass is planned fresh
--     and logged with its skill change. It stops early, with the reason, only when a pass makes no combines,
--     and never runs more than MAX_PASSES.
--   * Supply (2.34.0): an item no merchant sells and no recipe makes (ore, a drop) that we are short of is
--     asked for on the network (engine/supply: every character's bags, bank and zone, over DanNet) - at the
--     preflight and again at each pass. Someone in a safe zone who has it is ordered to bring it, like a
--     worker's cast (below); LazCraft is started on them as our worker first if it is not running there.
--     Nobody in a safe zone has it: the plan blocks and names who has it elsewhere.
--   * Cleanup closes whatever it opened and stows anything left on the cursor.
local R = require('core.result')

local Make = {}

Make.ROOM = 3   -- free bag slots kept for what a combine hands back
Make.SKILL_CAP = 300    -- tradeskills go no higher (the old LazCraft's HARD_SKILL_CAP)
Make.MAX_PASSES = 100   -- repeat to trivial: the most passes one job runs
Make.LATE_RESTARTS = 3  -- a placement where something landed late or an item would not go in: emptied, placed again
Make.REFUSED_TRIES = 3  -- a combine the game refused although everything showed placed: /cleanup, reopened, cleared,
                        -- placed again - twice (2.43.4)
Make.CLEANUP_MS = 2000  -- /cleanup closes every window within this
Make.REOPEN_WAITS = { 2000, 5000 }  -- after /cleanup, the station we stand at is clicked again after these (1.10.1)
-- station spots that refused a recipe twice with everything placed: left out for the rest of the session (1.10.1)
Make.refusing = {}
local function spot_key(container, st)
    return string.format('%s|%s|%.0f|%.0f', container, (st.zone or ''):lower(), st.y or 0, st.x or 0)
end
Make.WORKER_START_MS = 30000   -- supply: a holder started as our worker sends its card within this
Make.SUPPLIER_TRIES = 3        -- supply: holders that do not start are left out and the plan made again, this many times

local function lower(s) return (s or ''):lower() end

-- This character's cap for a skill (game name): Me.SkillCap, never above SKILL_CAP; SKILL_CAP if unreadable.
function Make.skill_cap(mq, name)
    local ok, c = pcall(function() return mq.TLO.Me.SkillCap(name)() end)
    c = ok and tonumber(c) or nil
    if not c or c <= 0 or c > Make.SKILL_CAP then return Make.SKILL_CAP end
    return c
end

-- The station spot in this zone closest to where we are (for its clickable name).
local function station_target(cfg, container, zone)
    local c = cfg.containers[container]
    for _, st in ipairs(c and c.stations or {}) do
        if st.zone:lower() == zone then return st.target end
    end
    return container
end

-- A recipe's skill now and its game name (skills.ini EQSkill=).
local function skill_of(env, r)
    local sk = r.skill and env.cfg and env.cfg.skills and env.cfg.skills[r.skill]
    local name = sk and sk.eqSkill or r.skill
    if not name or not env.mq then return nil, name end
    local ok, v = pcall(function() return env.mq.TLO.Me.Skill(name)() end)
    return ok and tonumber(v) or nil, name
end

-- Already at its trivial (or the skill's cap when lower)?
function Make.past_trivial(env, r)
    if not r.trivial then return false end
    local v, name = skill_of(env, r)
    if not v then return false end
    return v >= math.min(r.trivial, Make.skill_cap(env.mq, name))
end

Make.CLEAN_AFTER_ROW = true     -- a leveling path cleans up each row's leftovers before the next (2.42.16)
Make.ROW_TRIES = 2              -- a path row that failed on the way is made once more before the next row (2.43.1)
Make.CLEAN_MAX_PRICE = 20000    -- copper: an ingredient a merchant sells for less a unit is sold in that clean-up
Make.PASS_PAD = 1.10   -- a later repeat-to-trivial pass: the estimate for the points left, plus a tenth
Make.PASS_MIN = 10
Make.GATHER_TRIES = 3  -- a gathering trip that failed on the way is made again this often in all
Make.GATHER_FINAL = { ['cannot get it'] = true, ['plan changed'] = true, ['not enough money'] = true, ['bags full'] = true,
                      ['no faction'] = true }   -- a gathering failure another trip would not change
Make.BOOKS_MS = 30000  -- the longest a plan waits for spellbooks read again (engine/books)
Make.REPLANS = 3      -- a pass planned again this often when a merchant turned out not to sell an item
Make.MARR_ZONE = 'freeporttemple'   -- where Marr's Calling lands (travel.ini [*>freeporttemple])

-- Start a worker for an order and wait for its card (a hello first: one already running answers at once). A caster
-- (caster = true) must list the item on its card, else its spellbook lacks the spell: remembered and said.
function Make.start_for(env, ctx, worker, item, caster)
    local t0 = env.mq.gettime()
    ctx:status(string.format('Checking %s is working for us', worker))
    env.crew:start_worker(worker)
    local w = ctx:wait(Make.WORKER_START_MS, function() return env.crew:card_since(worker, t0) end)
    if not w.ok then
        if w.why ~= 'timeout' then return w end
        local f = R.fail('worker did not start', string.format('%s did not answer as our worker within %ds (for the %s)',
            worker, Make.WORKER_START_MS / 1000, item))
        f.worker = worker
        return f
    end
    if caster and not env.crew:can_make(worker, item) then
        if env.casters then env.casters:set_lacks(worker, item) end
        local pr = env.planner.producers and env.planner.producers[lower(item)]
        local spells = {}
        for _, t in ipairs(pr and (pr.spells or { pr }) or {}) do if t.spell then spells[#spells + 1] = t.spell end end
        local cls = env.casters and env.casters:class_of(worker)
        local f = R.fail('missing spell', string.format('%s%s cannot make %s - %s not in its spellbook: buy and scribe it there, or start another caster',
            worker, cls and (' (' .. cls .. ')') or '', item, #spells > 0 and (table.concat(spells, ' or ') .. ' is') or 'the spell is'))
        f.worker = worker
        env.log.warn('%s', f.detail)
        return f
    end
    return R.ok()
end

-- Order ahead (2.41.0): at Go, every summoned item (made by a worker's spell) the whole job will need is ordered
-- from its caster at once, 1:1 with the combines asked for - each row of a leveling path its Combines, each
-- queue entry its count, a Make its combines. The worker works them between everything else (engine/handoff);
-- each pass takes what it needs. list = { { recipe, n } } in the order they are made (a path: lowest first).
function Make.order_ahead(env, list, ctx)
    local h = env.handoff
    if not h or not h.place_summon then return end
    local world = env.world()
    local want, keys = {}, {}
    for _, it in ipairs(list) do
        if (it.n or 0) > 0 then
            local ok, p = pcall(function() return env.planner:plan(it.recipe.id, it.n, world) end)
            for _, o in ipairs(ok and p and p.orders or {}) do
                if not o.supply then
                    local k = lower(o.worker) .. '|' .. lower(o.item)
                    if not want[k] then want[k] = { worker = o.worker, item = o.item, n = 0 }; keys[#keys + 1] = k end
                    want[k].n = want[k].n + o.n
                end
            end
        end
    end
    if #keys == 0 then return end
    env.log.info('Ordering ahead: %d summoned item%s for the whole job', #keys, #keys == 1 and '' or 's')
    local ready = {}
    for _, k in ipairs(keys) do
        local w = want[k]
        -- a caster not running yet is started first (and must have the spell); one that cannot is left to the
        -- passes, which plan again without it
        local okW = ready[lower(w.worker)]
        if okW == nil then
            okW = true
            if ctx and env.crew and env.crew.running and not env.crew:running(w.worker) then
                env.log.info('%s is not running - starting it to cast %s', w.worker, w.item)
                local st = Make.start_for(env, ctx, w.worker, w.item, true)
                if st.why == 'stopped' then return st end
                okW = st.ok
                if not st.ok then env.log.warn('Ordering ahead: %s - not ordered from %s', R.describe(st), w.worker) end
            end
            ready[lower(w.worker)] = okW
        elseif okW and env.crew and env.crew.can_make and not env.crew:can_make(w.worker, w.item) then
            okW = false
            if env.casters then env.casters:set_lacks(w.worker, w.item) end
            env.log.warn('Ordering ahead: %s cannot make %s (not on its card) - not ordered', w.worker, w.item)
        end
        if okW and not h:summon_for(w.worker, w.item) then h:place_summon(w.worker, w.item, w.n) end
    end
end

function Make.job(env, recipe, combines, hooks)
    hooks = hooks or {}
    if hooks.repeatToTrivial then hooks.stopAtTrivial = true end
    local B, log, mq = env.blocks, env.log, env.mq
    local function make_plan(n, world)
        world = world or env.world()
        -- a gathering, or a worker's order planned with the orders queued behind it (one trip for all, 2.42.5)
        if hooks.items then return env.planner:plan_items(hooks.items, world) end
        if hooks.item then return env.planner:plan_item(hooks.item, hooks.fit and (hooks.fit.base + (n or combines)) or hooks.n, world) end
        return env.planner:plan(recipe.id, n or combines, world)
    end
    local plan
    local report = {}
    local open = {}   -- { kind = 'kit'|'station', name =, pack = } the container currently open
    -- A queue's entries one after another (hooks.keepOpen, shared by Make.batch): the container, its bags and the
    -- kit's slot are left as they are at the end, and the next entry carries on with them; the batch closes them
    -- when it changes container, goes shopping, or ends (2.41.6 log: bags and the kit closed and the kit swapped
    -- back after every spell of a research queue, then all of it again for the next).
    local keep = hooks.keepOpen
    local opened = {} -- containers this job opened (closed in cleanup)
    if keep and keep.open then open = keep.open; opened[open.name] = true; keep.open = nil end
    local orders = {} -- recipe id of an order step -> { id, r } placed with a worker, or { summon = s } (taken from one)
    local yielded     -- a summon round (hooks.yield) stopped between casts for what is waiting
    local aheadMine   -- this Make placed summon orders at Go (called off in cleanup)
    local disposal = hooks.disposal or 'keep'
    local sold = 0    -- of the product, sold so far this run
    local wornOn = 0  -- of the product, put on a worn slot by /autoinventory (not in the bags, never sold - 2.43.8)
    local fetching = {} -- the fetch in progress (for cleanup)
    local wornAtStart   -- what was in Ammo before this job put a trophy there (false = nothing); nil = untouched

    local function close_open(ctx)
        if not open.kind then return R.ok() end
        local r = R.ok()
        if open.kind == 'kit' and opened[open.name] then
            B.kit:close_bags(ctx)
            r = B.kit:close(ctx, open.pack)
        elseif open.kind == 'station' and opened[open.name] then
            B.station:close_bags(ctx)
            r = B.station:close(ctx, open.target)
        end
        open = {}
        return r
    end

    -- Open a station for a step (containers.ini At= lines). Here first: the one that worked last in this run,
    -- then nearest first. "Someone else is using that" is clicked once more (it also fires for a stale one
    -- with nobody there - the old LazCraft's finding), then the next one; nothing waits on a busy station.
    -- Every one here busy: the next place that has this station, fewest hops first - this zone's AFK mirror,
    -- then other zones (and their mirrors) - until one opens. None: it stops with the places it tried.
    local lastGood = {}   -- container -> the station spot that opened last
    local function try_here(ctx, container, target)
        local def = env.cfg.containers[container]
        local zone = B.travel:zone()
        local spots, listed = {}, 0
        for _, st in ipairs(def and def.stations or {}) do
            if lower(st.zone) == zone then
                listed = listed + 1
                if not Make.refusing[spot_key(container, st)] then spots[#spots + 1] = st end
            end
        end
        -- every listed one here refused this session: not "the nearest by name" (that finds the same one again)
        if #spots == 0 and listed > 0 then
            return R.fail('busy here', string.format('every %s listed in %s refused this session', container, zone))
        end
        if #spots == 0 then
            -- none listed here: the nearest by name
            local f = B.station:find(ctx, target)
            if not f.ok then return f end
            local g = B.nav:go_loc(ctx, f.value.y, f.value.x, f.value.z, 8)
            if not g.ok then return g end
            return B.station:open(ctx, target)
        end
        local mx, my, mz = B.nav:pos()
        local function away(st) return math.sqrt((st.x - mx) ^ 2 + (st.y - my) ^ 2 + (st.z - mz) ^ 2) end
        table.sort(spots, function(x, y)
            if (x == lastGood[container]) ~= (y == lastGood[container]) then return x == lastGood[container] end
            return away(x) < away(y)
        end)
        local last
        for i, st in ipairs(spots) do
            if not ctx:checkpoint() then return R.fail('stopped') end
            local where = string.format('%s at %.0f, %.0f', container, st.y, st.x)
            if #spots > 1 then log.debug('  %s (%d of %d)', where, i, #spots) end
            local g = B.nav:go_loc(ctx, st.y, st.x, st.z, 8)
            local o
            if not g.ok then
                if g.why == 'stopped' then return g end
                o = g
            else
                o = B.station:open(ctx, st.target or target)
                if not o.ok and o.why == 'in use' then
                    log.info('%s: "someone else is using that" - clicking once more (it also says so with nobody there)', where)
                    o = B.station:open(ctx, st.target or target)
                end
            end
            if o.ok then lastGood[container] = st; return o end
            if o.why == 'stopped' then return o end
            if o.why == 'in use' then log.info('%s is in use%s', where, i < #spots and ' - trying the next one' or '')
            else log.warn('%s: %s%s', where, R.describe(o), i < #spots and ' - trying the next one' or '') end
            last = o
        end
        return R.fail('busy here', last and R.describe(last) or 'none opened')
    end
    -- Other places with this station, fewest hops first: this zone's mirror, other zones, their mirrors.
    local function other_places(container)
        local def = env.cfg.containers[container]
        local here = B.travel:zone()
        local mirrors = (env.cfg.travel and env.cfg.travel.mirror) or {}
        local zones, out = {}, {}
        for _, st in ipairs(def and def.stations or {}) do zones[lower(st.zone)] = true end
        local inMirror = B.travel.in_mirror and B.travel:in_mirror() or B.travel.mirror
        if zones[here] and not inMirror and mirrors[here] then out[#out + 1] = { zone = here, mirror = true, cost = 0.5 } end
        for z in pairs(zones) do
            if z ~= here then
                local path = B.travel:path(z)
                if path then
                    out[#out + 1] = { zone = z, cost = #path }
                    if mirrors[z] then out[#out + 1] = { zone = z, mirror = true, cost = #path + 0.5 } end
                end
            end
        end
        table.sort(out, function(x, y) if x.cost ~= y.cost then return x.cost < y.cost end; return x.zone < y.zone end)
        return out
    end
    local function open_station(ctx, container, target)
        local o = try_here(ctx, container, target)
        if o.ok or o.why == 'stopped' then return o end
        local tried = { B.travel:where() }
        for _, place in ipairs(other_places(container)) do
            local name = place.zone .. (place.mirror and ' (AFK mirror)' or '')
            log.info('Every %s in %s is busy - trying %s', container, B.travel:where(), name)
            local c = close_open(ctx)
            if not c.ok then return c end
            local t = R.ok()
            if B.travel:zone() ~= place.zone then t = B.travel:go(ctx, place.zone) end
            if t.ok and place.mirror then t = B.travel:enter_mirror(ctx) end
            if not t.ok then
                if t.why == 'stopped' then return t end
                log.warn('Could not get to %s: %s', name, R.describe(t))
            else
                tried[#tried + 1] = name
                o = try_here(ctx, container, target)
                if o.ok or o.why == 'stopped' then return o end
            end
        end
        return R.fail('no station', string.format('every %s was busy or would not open (%s)', container, table.concat(tried, ', ')))
    end

    -- Open the container a step needs (keeping it if it is already the open one).
    local function use_container(ctx, container, names)
        -- what the step needs from inside a kit in a top-level slot comes out first, with nothing open (2.46.4)
        local inKits = names and B.kitslot and B.kitslot.in_kits and B.kitslot:in_kits(names) or {}
        if open.name == container and #inKits == 0 then return R.ok() end
        local c = close_open(ctx)
        if not c.ok then return c end
        if #inKits > 0 then
            local m = B.kitslot:unkit(ctx, inKits)
            if not m.ok then return m end
        end
        local def = env.cfg.containers[container]
        if def and def.type == 'station' then
            local target = station_target(env.cfg, container, plan.craftZone)
            -- A kit and a station share the combine window's name. If a carried kit is open, that window
            -- is the kit's: close the kit first, so "already open" can only mean the station.
            for pk = 1, 10 do
                local item = mq.TLO.Me.Inventory('pack' .. pk)
                local kitName = env.cfg.containerByBag[lower(item.Name())]
                local k = kitName and env.cfg.containers[kitName]
                if k and k.type == 'kit' and B.windows:is_open('Pack' .. pk) and B.kit:is_open() then
                    log.debug('  %s (pack%d) is open - closing it before using the %s', item.Name(), pk, container)
                    local kc = B.kit:close(ctx, pk)
                    if not kc.ok then return kc end
                end
            end
            local was = B.station:is_open()
            local o
            if was then o = B.station:open(ctx, target) else o = open_station(ctx, container, target) end
            if not o.ok then return o end
            open = { kind = 'station', name = container, target = target }
            if not was then opened[container] = true end
            log.info('%s open (%s)', container, o.value.how)
            return R.ok()
        end
        -- a kit: any bag that works as this kit, in a top-level slot - moved into pack10 if it is inside a bag
        local e = B.kitslot:ensure(ctx, def and def.accepts or { container })
        if not e.ok then return e end
        local pk = e.value.pack
        local slots = mq.TLO.Me.Inventory('pack' .. pk).Container() or 0
        local was = B.kit:is_open()
        local o = B.kit:open(ctx, pk)
        if not o.ok then return o end
        open = { kind = 'kit', name = container, pack = pk, slots = slots }
        if not was then opened[container] = true end
        log.info('%s open (%s)', container, o.value.how)
        return R.ok()
    end

    -- Something on the cursor before a pickup came back late from the last combine (salvage, or a return
    -- slower than the cap): stow it. During a placement it also marks the round (lateRound): the game may still
    -- hold more of that combine in the container, so the round is emptied and placed again (2.43.5).
    local lateRound = false
    local function stow_late(ctx)
        local c = B.cursor:item()
        if not c then return R.ok(false) end
        lateRound = true
        log.warn('%s x%d arrived on the cursor after the last combine was over - stowing it', c.name, c.stack)
        local st = B.cursor:stow(ctx)
        if not st.ok then return st end
        return R.ok(true)
    end
    local function place(ctx, slot, item)
        local p
        for _ = 1, 2 do   -- a second go when something landed on the cursor during the pickup
            local s = stow_late(ctx)
            if not s.ok then return s end
            if open.kind == 'kit' then p = B.kit:place(ctx, open.pack, slot, item) else p = B.station:place(ctx, slot, item) end
            if p.ok or p.why ~= 'cursor busy' then return p end
        end
        return p
    end
    local function do_combine(ctx, want)
        if open.kind == 'kit' then return B.kit:combine(ctx, open.pack, want) end
        return B.station:combine(ctx, want)
    end
    local function contents()
        if open.kind == 'kit' then return B.kit:describe(open.pack) end
        return B.station:describe()
    end
    -- The container holds exactly what was placed, slot for slot (nothing missing, nothing extra).
    local function holds(units)
        local c = open.kind == 'kit' and B.kit:contents(open.pack) or B.station:contents()
        for slot, it in pairs(c) do
            if lower(it.name) ~= lower(units[slot]) then return false end
        end
        for slot in ipairs(units) do if not c[slot] then return false end end
        return true
    end
    local function clear(ctx)
        if open.kind == 'kit' then return B.kit:clear(ctx, open.pack) end
        return B.station:clear(ctx)
    end

    local function bank_trip(ctx)
        if #plan.bankPulls == 0 then return R.ok() end
        local b, e = B.spawns:await(ctx, 'a banker', function() return B.bank:banker() end)
        if e then return e end
        if not b then return R.fail('no banker', 'the plan needs a bank trip and there is no banker in this zone') end
        local o = B.bank:go_open(ctx, B.nav, b)
        if not o.ok then return o end
        for _, p in ipairs(plan.bankPulls) do
            local w = B.bank:withdraw(ctx, p.item, p.n)
            if not w.ok then return w end
            log.info('Bank: took %d %s', p.n, p.item)
        end
        B.bank:close_bags(ctx)
        return B.bank:close(ctx)
    end

    -- The plan's buys not made yet: the slots its stackable ones take (unknown size = one slot), and how many
    -- non-stacking items are still to come (they are bought last and share what room is left).
    local done = {}
    local function still_to_buy()
        local slots, nonstack = 0, 0
        for _, stops in pairs(plan.buys or {}) do
            for _, stop in ipairs(stops) do
                for _, it in ipairs(stop.items) do
                    if not done[lower(it.item)] then
                        local size = env.stacks and env.stacks:size(it.item)
                        if size == 1 then nonstack = nonstack + it.n
                        elseif size then
                            local have = B.inventory:count(it.item)
                            slots = slots + math.ceil((have + it.n) / size) - math.ceil(have / size)
                        else slots = slots + 1 end
                    end
                end
            end
        end
        return slots, nonstack
    end
    -- Shopping in a zone: the plan's merchants, nearest first (read from where they stand now). A merchant who
    -- is not up, or does not sell an item after all, hands that item to another merchant here who sells it
    -- (one already on the list first, else the nearest that is up) - said in the log.
    local function shop(ctx, zone)
        local todo, order = {}, {}
        -- a faction zone (travel.ini [Faction]): each merchant conned before buying, the standing saved; one we
        -- were last too low with is never swapped in (2.42.0)
        local factionZone = ((env.cfg.travel or {}).faction or {})[zone] == true
        local function barred(npc) return factionZone and env.factions and env.factions:barred(env.me or '', npc, zone) end
        local function add(npc, item, n)
            local k = lower(npc)
            if not todo[k] then todo[k] = { npc = npc, items = {} }; order[#order + 1] = k end
            table.insert(todo[k].items, { item = item, n = n })
        end
        for _, stop in ipairs(plan.buys[zone] or {}) do
            for _, it in ipairs(stop.items) do add(stop.npc, it.item, it.n) end
        end
        local out = {}   -- lower npc -> visited or not up
        local learnedHere = false   -- a merchant's list did not have what the data says (core/unsold): a new plan helps
        local function reassign(item, n, why)
            local best, bestD
            for _, v in ipairs(env.planner:vendors(item)) do
                local k = lower(v.npc)
                if lower(v.zone) == zone and not out[k] and not barred(v.npc) then
                    if todo[k] then best = v; break end
                    local sp = B.spawns:find(v.npc)
                    if sp and (not bestD or sp.distance < bestD) then best, bestD = v, sp.distance end
                end
            end
            if not best then
                local f = R.fail('nobody sells it here', string.format('%s: %s, and no other merchant here that sells it is up', item, why))
                f.learned = learnedHere
                return f
            end
            log.info('%s: %s - buying it from %s instead', item, why, best.npc)
            add(best.npc, item, n)
            return R.ok()
        end
        -- Faction (2.42.0): a con works from anywhere in the zone, so every merchant on this zone's list is conned on
        -- arrival, before any walking (2.42.4) - each standing saved (and told to the crafter by a worker)
        local conned = {}
        local function con_npc(npc, id)
            ctx:status('Conning ' .. npc)
            local c = B.faction:con(ctx, id)
            if not c.ok then return c end
            conned[lower(npc)] = c.value.word
            if env.factions then env.factions:set(env.me or '', npc, zone, c.value.word) end
            if env.on_con then env.on_con(npc, zone, c.value.word) end
            log.info('Faction: %s regards us %s%s', npc, c.value.word, c.value.buy and '' or ' - too low to buy')
            return c
        end
        local function barred_fail(list)
            local f = R.fail('no faction', string.format('%s (%s) - too low to buy (apprehensively or better); saved, so the next plan leaves them out',
                table.concat(list, ', '), zone))
            f.learned = true
            return f
        end
        local function visit(stop, s)
            ctx:status('Buying from ' .. stop.npc)
            local g = B.nav:go_spawn(ctx, s.id, 10)
            if not g.ok then return g end
            -- a merchant handed this item here after the zone-in cons (not up then, or a reassign): conned now
            if factionZone and B.faction and not conned[lower(stop.npc)] then
                local c = con_npc(stop.npc, s.id)
                if not c.ok then return c end
                if not c.value.buy then return barred_fail({ string.format('%s regards us %s', stop.npc, c.value.word) }) end
            end
            local want = {}
            for _, it in ipairs(stop.items) do want[#want + 1] = it.item end
            local o = B.merchant:open(ctx, s.id, want)
            if not o.ok then return o end
            -- the data says it sells these and is nearly always right: one not on the list is the list not all
            -- there yet (2.43.6 log: Audri, 7 of her 153 items, said complete) - closed and opened once more first
            if #(o.value.missing or {}) > 0 then
                log.info('%s: %s not on the list yet (%d items) - closing and opening it again', stop.npc,
                    table.concat(o.value.missing, ', '), o.value.items or 0)
                local c0 = B.merchant:close(ctx)
                if not c0.ok then return c0 end
                o = B.merchant:open(ctx, s.id, want)
                if not o.ok then return o end
                if #(o.value.missing or {}) > 0 then
                    log.info('%s: still no %s after opening it again (%d items)', stop.npc, table.concat(o.value.missing, ', '), o.value.items or 0)
                end
            end
            -- an item saved as not sold here that this list does have: taken off (2.43.7)
            if env.unsold and env.unsold.items_for then
                for _, item in ipairs(env.unsold:items_for(stop.npc, zone)) do
                    if B.merchant:has(item) and env.unsold:remove(stop.npc, zone, item) then
                        log.info('%s: %s does sell it - taken off settings/unsold.ini', item, stop.npc)
                    end
                end
            end
            -- the real stack sizes, off this merchant: stackables first, non-stacking items last
            local list, moved = {}, {}
            for i, it in ipairs(stop.items) do
                local size = B.merchant:stack_size(it.item)
                if size then list[#list + 1] = { item = it.item, n = it.n, i = i, size = size }
                else moved[#moved + 1] = it end
            end
            table.sort(list, function(x, y)
                local sx, sy = x.size == 1 and 1 or 0, y.size == 1 and 1 or 0
                if sx ~= sy then return sx < sy end
                return x.i < y.i
            end)
            for _, it in ipairs(list) do
                -- a buy that would not fit is cut to what does (leaving a slot for each item still to buy):
                -- nothing may be left on the cursor
                local n = it.n
                done[lower(it.item)] = true
                local laterSlots, laterNonstack = still_to_buy()
                local room = math.max(0, B.inventory:free_slots() - Make.ROOM - laterSlots)
                local fits
                if it.size == 1 then
                    -- non-stacking items still to come share the room by how many each needs
                    fits = laterNonstack > 0 and math.floor(room * n / (n + laterNonstack)) or room
                else
                    local have = B.inventory:count(it.item)
                    local topup = have > 0 and ((it.size - have % it.size) % it.size) or 0
                    fits = room * it.size + topup
                end
                if n > fits then
                    local free = B.inventory:free_slots()
                    log.warn('Bags: buying %d of %d %s (%s, %d free slot%s, keeping %d spare)', fits, n, it.item,
                        it.size == 1 and 'does not stack' or ('stacks to ' .. it.size), free, free == 1 and '' or 's', Make.ROOM)
                    n = fits
                end
                if n > 0 then
                    local bo = B.merchant:buy(ctx, it.item, n)
                    if not bo.ok then B.merchant:close(ctx); return bo end
                    log.info('Bought %d %s from %s', n, it.item, stop.npc)
                end
            end
            local c = B.merchant:close(ctx)
            if not c.ok then return c end
            for _, it in ipairs(moved) do
                -- the data says it does, its complete list says not: learned for every character (core/unsold)
                if env.unsold and env.unsold:add(stop.npc, zone, it.item) then
                    learnedHere = true
                    log.warn('%s: %s here does not sell it after all (its list in game) - saved, no plan picks %s for it again',
                        it.item, stop.npc, stop.npc)
                end
                local r = reassign(it.item, it.n, string.format('%s does not have it on its list', stop.npc))
                if not r.ok then return r end
            end
            return R.ok()
        end
        -- standing here now: a planned merchant who is not up, or farther than another here who sells all the
        -- same items (merchants.ini), is swapped for the nearest such one that is up
        local planned0 = {}
        for i, k in ipairs(order) do planned0[i] = k end
        for _, k in ipairs(planned0) do
            local stop = todo[k]
            local planned = B.spawns:find(stop.npc)
            local best, bestS = nil, planned
            local sellers
            for _, it in ipairs(stop.items) do
                local here = {}
                for _, v in ipairs(env.planner:vendors(it.item)) do
                    if lower(v.zone) == zone and (not sellers or sellers[lower(v.npc)]) and not barred(v.npc) then here[lower(v.npc)] = v.npc end
                end
                sellers = here
            end
            for kk, npc in pairs(sellers or {}) do
                if kk ~= k and not todo[kk] then
                    local sp = B.spawns:find(npc)
                    if sp and (not bestS or sp.distance < bestS.distance) then best, bestS = npc, sp end
                end
            end
            if best then
                log.debug('  %s: %s sells the same here and is %s', stop.npc, best, planned and 'nearer' or 'up')
                todo[k] = nil
                for _, it in ipairs(stop.items) do add(best, it.item, it.n) end
            end
        end
        if factionZone and B.faction then
            local low = {}
            for _, k in ipairs(order) do
                local stop = todo[k]
                if stop and not conned[k] then
                    local sp, e = B.spawns:await(ctx, stop.npc, function() return B.spawns:find(stop.npc) end)
                    if e then return e end
                    if sp then
                        local c = con_npc(stop.npc, sp.id)
                        if not c.ok then return c end
                        if not c.value.buy then low[#low + 1] = string.format('%s regards us %s', stop.npc, c.value.word) end
                    end
                end
            end
            if #low > 0 then return barred_fail(low) end
        end
        while true do
            if not ctx:checkpoint() then return R.fail('stopped') end
            local nextK, nextS
            for _, k in ipairs(order) do
                if todo[k] then
                    local sp = B.spawns:find(todo[k].npc)
                    if sp and (not nextS or sp.distance < nextS.distance) then nextK, nextS = k, sp end
                end
            end
            if not nextK then
                -- nobody on the list stands here yet (just zoned in?): wait for the first; if never, hand its items on
                local first
                for _, k in ipairs(order) do if todo[k] then first = k; break end end
                if not first then break end
                local s, e = B.spawns:await(ctx, todo[first].npc, function() return B.spawns:find(todo[first].npc) end)
                if e then return e end
                if s then nextK, nextS = first, s
                else
                    local stop = todo[first]
                    todo[first], out[first] = nil, 'not up'
                    for _, it in ipairs(stop.items) do
                        local r = reassign(it.item, it.n, string.format('%s is not up (looked for %ds)', stop.npc, B.spawns.APPEAR_MS / 1000))
                        if not r.ok then return r end
                    end
                end
            end
            if nextK then
                local stop = todo[nextK]
                todo[nextK], out[nextK] = nil, 'visited'
                local v = visit(stop, nextS)
                if not v.ok then return v end
            end
        end
        return R.ok()
    end

    -- The skill a recipe raises, as the game names it (skills.ini EQSkill=), and its value now.
    local function skill_name(r)
        local sk = r.skill and env.cfg.skills and env.cfg.skills[r.skill]
        return sk and sk.eqSkill or r.skill
    end
    local function skill_now(r)
        local name = skill_name(r)
        if not name then return nil end
        local ok, v = pcall(function() return mq.TLO.Me.Skill(name)() end)
        return ok and tonumber(v) or nil
    end
    -- Coin carried, in copper (the bank's does not buy anything).
    local function coin()
        local Me = mq.TLO.Me
        local function n(f) local ok, v = pcall(function() return Me[f]() end); return ok and tonumber(v) or 0 end
        return n('Platinum') * 1000 + n('Gold') * 100 + n('Silver') * 10 + n('Copper')
    end
    local function money_line(p)
        if not p.cost or p.cost <= 0 then return nil end
        local have = coin()
        local short = have < p.cost
        return { level = short and 'block' or 'ok', short = short, text = string.format('Money: about %s to spend, you carry %s%s',
            env.describe_money(p.cost), env.describe_money(have), short and ' - not enough' or '') }
    end
    -- Where a recipe's leveling stops: its trivial, or the skill's cap when lower. -> value, 'trivial'|'cap'
    local function stop_at(r)
        if not r.trivial then return nil end
        local cap = Make.skill_cap(mq, skill_name(r))
        if cap < r.trivial then return cap, 'cap' end
        return r.trivial, 'trivial'
    end
    local function reached(r, sk)
        local at, kind = stop_at(r)
        if kind == 'cap' then
            return string.format('skill cap reached (%s %d, cap %d, trivial %d)', skill_name(r), sk, at, r.trivial)
        end
        return string.format('trivial reached (%s %d, trivial %d)', skill_name(r), sk, r.trivial)
    end
    -- Free bag slots a product can go into: an open kit's own (empty) slots do not count.
    local function room()
        local free = B.inventory:free_slots()
        if open.kind == 'kit' and open.slots then free = free - open.slots end
        return free
    end

    -- Sell `n` of the product at the nearest merchant in this zone that merchants.ini lists.
    local function sell_product(ctx, item, n)
        if n <= 0 then return R.ok(0) end
        local c = close_open(ctx)
        if not c.ok then return c end
        -- a stack of it worn in Ammo (where /autoinventory tops up a throwing item: 2.35.2, Shaded Kunai) comes
        -- off into the bags first - the merchant only takes what is in the bags. Only the product: anything
        -- else in Ammo is never touched. Not done (no room): said, and what is in the bags is sold.
        if B.gear and lower(B.gear:worn('ammo') or '') == lower(item) then
            local u = B.gear:unequip(ctx, 'ammo')
            if u.ok then log.info('Took the %s stack out of the Ammo slot to sell it', item)
            else log.warn('Could not take %s out of the Ammo slot (%s) - selling what is in the bags', item, R.describe(u)) end
        end
        -- only what is in the bags is sold: one /autoinventory put on (an empty face, neck, wrist... slot - 2.43.7
        -- log: a Veil, a Necklace and a Tiara each made 1 more than the bags held, "sold 82 of 83, none left", the
        -- row failed) stays worn, said, and is not counted as sold (2.43.8)
        local inBags = B.inventory:count(item)
        if inBags < n then
            log.info('%s: %d made, %d in the bags - %d went into a worn slot when stowed and stays there; selling the %d in the bags',
                item, n, inBags, n - inBags, inBags)
            wornOn = wornOn + (n - inBags)   -- not counted as to sell again on the next round
            n = inBags
            if n <= 0 then return R.ok(0) end
        end
        local zone = B.travel:zone()
        local function nearest()
            local best
            for _, npc in ipairs((env.cfg.merchantsByZone or {})[zone] or {}) do
                local sp = B.spawns:find(npc)
                if sp and (not best or sp.distance < best.distance) then best = sp end
            end
            return best
        end
        local best, e = B.spawns:await(ctx, 'a merchant', nearest)
        if e then return e end
        if not best then return R.fail('no merchant', 'no merchant from merchants.ini is in ' .. zone) end
        ctx:status(string.format('Selling %d %s to %s', n, item, best.name))
        local g = B.nav:go_spawn(ctx, best.id, 10)
        if not g.ok then return g end
        local o = B.merchant:open(ctx, best.id)
        if not o.ok then return o end
        local sl = B.merchant:sell(ctx, item, n)
        B.merchant:close(ctx)
        if not sl.ok then return sl end
        sold = sold + n
        log.info('Sold %d %s to %s', n, item, best.name)
        return R.ok(n)
    end

    -- an order's items: from its own order, or from the summon order placed at Go (fewer made than this pass
    -- needs and it ended: ordered for this pass instead)
    local function take_one(ctx, step, o)
        if o.summon then
            local f = env.handoff:take_summoned(ctx, o.summon, step.order.worker, step.recipe.name, step.combines, fetching)
            if f.ok then return f end
            -- it came with fewer than its order said it held (its count was behind): the rest ordered, as when short
            local ranOut = f.why == 'cancelled' and tostring(f.detail or ''):find('ran out', 1, true) ~= nil
            if f.why ~= 'summon short' and not ranOut then return f end
            local got = ranOut and (f.taken or 0) or 0
            if ranOut then o.summon.r.have = 0 end
            local rest = step.combines - got
            log.info('%s - ordering the %d%s for this pass', R.describe(f), rest, got > 0 and ' still missing' or '')
            local id, r = env.handoff:place_order(step.order.worker, step.recipe.name, rest)
            orders[step.recipe.id] = { id = id, r = r }
            local c = env.handoff:collect(ctx, id, r, step.order.worker, step.recipe.name, rest, fetching)
            if c.ok and got > 0 then c.value.taken = c.value.taken + got end
            return c
        end
        return env.handoff:collect(ctx, o.id, o.r, step.order.worker, step.recipe.name, step.combines, fetching)
    end
    -- Everything a worker brings this pass in one visit (2.41.2; the 2.40.2 log: Shela walked over twice in one
    -- pass, 30s apart, to two stations): having taken this step's item, every other item of this pass that the
    -- same worker has ready (made, or as many summoned as needed) is taken too, while it stands next to us.
    -- One not ready yet is collected before its own step, as before.
    local function ready(st, o)
        if o.summon then return (o.summon.r.have or 0) >= st.combines end
        return o.r and o.r.made ~= nil
    end
    local function take(ctx, step, o)
        local f = take_one(ctx, step, o)
        -- a worker sent to buy where our faction is too low found its own too low (2.42.4): saved (its con also
        -- came as a message), and the pass is planned again with another worker
        local d = not f.ok and tostring(f.detail or '') or ''
        if d:find('no faction', 1, true) or d:find('your faction is too low', 1, true) then
            local seen = {}
            local nl, nz = d:match('no faction %((.-) %((%S+)%) %- too low')
            for part in (nl or ''):gmatch('[^,]+') do
                local n1, w1 = part:match('^%s*(.-) regards us (.-)%s*$')
                if n1 then seen[#seen + 1] = { n1, nz, w1 } end
            end
            local list = d:match('your faction is too low with: (.-) %(apprehensively')
            for part in (list or ''):gmatch('[^,]+') do
                local n2, z2, w2 = part:match('^%s*(.-) %((%S+)%) (.-)%s*$')
                if n2 then seen[#seen + 1] = { n2, z2, w2 } end
            end
            for _, x in ipairs(seen) do
                if env.factions then env.factions:set(step.order.worker, x[1], x[2], x[3]) end
            end
            log.warn('%s cannot buy it either (faction%s) - asking another worker', step.order.worker,
                #seen > 0 and (': ' .. seen[1][1] .. ' ' .. seen[1][3]) or '')
            f.learned = true
            return f
        end
        if not f.ok or not plan then return f end
        local who = lower(step.order.worker)
        for _, st in ipairs(plan.steps) do
            local oo = st.order and not st.collected and st ~= step and lower(st.order.worker) == who and orders[st.recipe.id]
            if oo and ready(st, oo) then
                log.info('%s is here - taking the %d %s for a later step now too', step.order.worker, st.combines, st.recipe.name)
                local g = take_one(ctx, st, oo)
                orders[st.recipe.id] = nil
                if not g.ok then return g end
                st.collected = g.value.taken
            end
        end
        return f
    end
    local saidNoWear = {}   -- skill -> said that nothing to wear for it was found (once a job)
    -- One step: N combines of a recipe in its container.
    local function run_step(ctx, step, index, total)
        local r = step.recipe
        local entry = { recipe = r, wanted = step.combines, success = 0, failed = 0, made = 0 }
        report[#report + 1] = entry
        if step.order and step.collected then
            entry.wanted, entry.success, entry.made = 1, 1, step.collected   -- collected before the route left the zone
            return R.ok()
        end
        if step.order then
            -- brought by a worker: nothing open, nothing on the cursor, we stand still for the trade
            local c = close_open(ctx)
            if not c.ok then entry.stopped = R.describe(c); return c end
            entry.wanted = 1
            local o = orders[r.id]
            local f = take(ctx, step, o)
            orders[r.id] = nil
            if not f.ok then entry.stopped = R.describe(f); return f end
            entry.wanted, entry.success, entry.made = 1, 1, f.value.taken
            return R.ok()
        end
        if step.cast then
            -- made by casting: nothing open, nothing on the cursor
            local c = close_open(ctx)
            if not c.ok then entry.stopped = R.describe(c); return c end
            ctx:status(string.format('Step %d of %d: casting %s', index, total, step.cast.spell))
            local p = B.cast:produce(ctx, step.cast, step.combines, hooks.yield)
            if not p.ok then entry.stopped = R.describe(p); return p end
            entry.success, entry.made = p.value.casts, p.value.made
            if p.value.yielded then yielded = true end
            entry.failed = p.value.attempts - p.value.casts
            return R.ok()
        end
        -- the recipe asked for (not a subcombine): its product is disposed of; it may stop at trivial
        local final = r.id == recipe.id and not step.cast and not step.order
        if final then
            entry.skillFrom = skill_now(r)
            if entry.skillFrom then
                local at, kind = stop_at(r)
                log.info('%s: %s %d (trivial %s%s)', r.label, skill_name(r), entry.skillFrom, tostring(r.trivial or '?'),
                    kind == 'cap' and string.format(', your cap %d', at) or '')
            end
        end
        -- what to wear for this skill (skills.ini Trophy=/Clicky=, picked by the plan); a miss is said, never a stop
        local m = plan.modifiers and r.skill and plan.modifiers[r.skill]
        if m and m.item and B.gear and lower(B.gear:worn('ammo') or '') ~= lower(m.item) then
            if wornAtStart == nil then wornAtStart = B.gear:worn('ammo') or false end
            local e = B.gear:equip(ctx, m.item, 'ammo')
            if e.ok then log.info('Wearing %s for %s', m.item, r.skill)
            elseif e.why == 'stopped' then entry.stopped = 'stopped'; return e
            else log.warn('Could not wear %s for %s (%s) - carrying on without', m.item, r.skill, R.describe(e)) end
        elseif m and m.none and not saidNoWear[lower(r.skill)] then
            -- said in every run, not only in a preflight (2.42.11: a research queue never said why no quill went on)
            saidNoWear[lower(r.skill)] = true
            log.info('Wear for %s: none of yours in the bags, bank or Ammo slot (%s) - carrying on without', r.skill,
                table.concat(m.none, ', '))
        end
        local stepItems = {}
        for _, list in ipairs({ r.ins or {}, r.tools or {} }) do for _, x in ipairs(list) do stepItems[#stepItems + 1] = x.name end end
        local u = use_container(ctx, r.container, stepItems)
        if not u.ok then entry.stopped = R.describe(u); return u end
        -- leftovers in it before the first placement come out first (2.46.3 Vadar log: the Fletching Kit was already
        -- open with a Small Brick of Mithril in slot 1, and the run failed "slot taken" before a single click)
        if contents() ~= 'empty' then
            log.info('%s holds %s from before - emptying it first', r.container, contents())
            local cl = clear(ctx)
            if cl and cl.ok == false then entry.stopped = R.describe(cl); return cl end
            local st = B.cursor:stow(ctx)
            if not st.ok then entry.stopped = R.describe(st); return st end
        end
        local units = {}
        for _, i in ipairs(r.ins) do for _ = 1, i.n do units[#units + 1] = i.name end end
        for _, t in ipairs(r.tools) do for _ = 1, t.n do units[#units + 1] = t.name end end
        local seenDesyncs = B.cursor.desyncs or 0   -- desync lines already dealt with (2.46.5)
        -- the quiet window learns (core/pace, 2.46.7): any trouble in a combine widens it once; a combine with none counts
        -- towards narrowing it
        local troubled = false
        local function backoff(why)
            if troubled then return end
            troubled = true
            if B.cursor.pace then B.cursor.pace:hit(why) end
        end
        -- THE RESET (2.46.8): after a desync - or a refusal, or the kit's own window gone - nothing is combined again
        -- until the container has had the full reset: the desync lines waited out, what it shows taken out, /cleanup
        -- (every window and bag closed), the container opened again, and anything it still shows taken out. The user's
        -- rule: after a desync, /cleanup before combining again. 2.46.7 log: a desync on the kit's own slots (5813)
        -- closed its Pack10 window while the combine window stayed up; the recovery only cleared and placed again, and
        -- every /combine pack10 after got "Window 'pack10' not open" - three sends, then "no answer", twice.
        -- opts.otherStation: the station itself is what is wrong (it refuses this recipe) - no retry of the same one
        local function reset_container(ctx, opts)
            opts = opts or {}
            local prev = open
            log.info('%s: clearing, /cleanup and opening it again before the next combine', r.container)
            if (B.cursor.desyncs or 0) ~= seenDesyncs then
                local s = B.cursor:settle(ctx)
                if not s.ok then return s end
                seenDesyncs = B.cursor.desyncs
                log.info('%s after the desync settled: %s', r.container, contents())
            end
            local cl = clear(ctx)
            if cl and cl.ok == false then log.warn('Could not clear it before /cleanup (%s) - going on', R.describe(cl)) end
            local st = B.cursor:stow(ctx)
            if not st.ok and not B.cursor:is_empty() then return st end
            log.debug('  send: /cleanup')
            mq.cmd('/cleanup')
            local w = ctx:wait(Make.CLEANUP_MS, function() return not B.kit:is_open() and not B.station:is_open() end)
            if not w.ok and w.why ~= 'timeout' then return w end
            log.debug('  /cleanup: combine window %s after %dms', (B.kit:is_open() or B.station:is_open()) and 'still open' or 'closed', w.ms or 0)
            open = {}
            -- THE SAME STATION, AGAIN (1.10.1): clicked straight after /cleanup a world station did not answer (2.46.8
            -- and 1.10.0 Vadar logs, a PoK and a Freeport Forge: three clicks, 3s each, nothing) and the run left it as
            -- "busy" - for the AFK mirror, or a container that refuses the recipe. The same Forge opened on the first
            -- click once a new run came along. So the station we stand at gets a pause first, then a longer one.
            -- The user's question, and the log agrees: the SERVER still had something on its cursor. 1.10.0 Vadar log:
            -- /cleanup at 172.522, the Forge clicked at 172.670, and 0.25s later "Source slot 33 resyncronized.
            -- Destination slot 4417" - the bounced Plate Gorget Template Mold went from the server's cursor into pack3
            -- slot 8 after the click; the client's cursor read empty all along. A world container does not open for a
            -- click with something on the cursor. So before each click: /autoinventory (nothing happens if the server's
            -- cursor is empty too), then the resync lines it sets off are waited out.
            local reopened = false
            if prev.kind == 'station' and not opts.otherStation then
                for attempt = 1, #Make.REOPEN_WAITS do
                    log.debug('  send: /autoinventory (whatever the server may still hold on the cursor)')
                    mq.cmd('/autoinventory')
                    local p = ctx:pace(Make.REOPEN_WAITS[attempt])
                    if not p.ok then return p end
                    local s = B.cursor:settle(ctx)
                    if not s.ok then return s end
                    seenDesyncs = B.cursor.desyncs or seenDesyncs
                    local st2 = B.cursor:stow(ctx)   -- anything the resync put back on the cursor
                    if not st2.ok then return st2 end
                    local o = B.station:open(ctx, prev.target)
                    if o.ok then
                        open = { kind = 'station', name = prev.name, target = prev.target }
                        opened[prev.name] = true
                        log.info('%s open again after /cleanup (%.1fs wait%s)', r.container, Make.REOPEN_WAITS[attempt] / 1000,
                            attempt > 1 and string.format(', try %d', attempt) or '')
                        reopened = true
                        break
                    end
                    if o.why == 'stopped' then return o end
                    log.info('%s did not open %.1fs after /cleanup (%s)%s', r.container, Make.REOPEN_WAITS[attempt] / 1000,
                        R.describe(o), attempt < #Make.REOPEN_WAITS and ' - waiting longer' or ' - trying the others')
                end
            end
            if not reopened then
                local u3 = use_container(ctx, r.container)
                if not u3.ok then return u3 end
            end
            local left = contents()
            if left ~= 'empty' then
                log.info('%s open again; it still holds %s - taking it out', r.container, left)
                local cl2 = clear(ctx)
                if cl2 and cl2.ok == false then return cl2 end
            end
            return R.ok()
        end
        local cap = open.kind == 'kit' and open.slots or B.station.SLOTS
        if #units > cap then
            entry.stopped = string.format('needs %d slots, %s has %d', #units, r.container, cap)
            return R.fail('too many ingredients', entry.stopped)
        end
        for n = 1, step.combines do
            if not ctx:checkpoint() then entry.stopped = 'stopped'; return R.fail('stopped') end
            ctx:status(string.format('Step %d of %d: %s, combine %d of %d', index, total, r.label, n, step.combines))
            local late = stow_late(ctx)
            if not late.ok then entry.stopped = R.describe(late); return late end
            if final and hooks.stopAtTrivial and r.trivial then
                local sk = skill_now(r)
                -- each point said with what it took (2.42.1: the data to balance the Leveling estimates by)
                if sk and entry.skillFrom and sk > (entry.lastSkill or entry.skillFrom) then
                    log.info('%s: %s %d after combine %d (%d combine%s for that point)', r.label, skill_name(r), sk, n - 1,
                        n - 1 - (entry.lastSkillAt or 0), n - 1 - (entry.lastSkillAt or 0) == 1 and '' or 's')
                    entry.lastSkill, entry.lastSkillAt = sk, n - 1
                end
                if sk and sk >= stop_at(r) then
                    entry.stopped = reached(r, sk)
                    log.info('%s: %s after %d combine%s', r.label, entry.stopped, n - 1, n == 2 and '' or 's')
                    return R.ok()
                end
            end
            -- room for what comes back: sell what this run made, or stop with the reason
            if room() < Make.ROOM then
                local unsold = entry.made - sold - wornOn
                if final and disposal == 'sell' and unsold > 0 then
                    log.info('Bags down to %d free - selling the %d %s made so far', room(), unsold, r.name)
                    local sl = sell_product(ctx, r.name, unsold)
                    if not sl.ok then entry.stopped = 'bags full, and selling failed: ' .. R.describe(sl); return sl end
                    local u2 = use_container(ctx, r.container)
                    if not u2.ok then entry.stopped = R.describe(u2); return u2 end
                end
                if room() < Make.ROOM then
                    entry.stopped = string.format('bags full (%d free slots) after %d combine%s', room(), n - 1, n == 2 and '' or 's')
                    log.warn('%s: %s', r.label, entry.stopped)
                    return R.fail('bags full', entry.stopped)
                end
            end
            local again, tries, lates = true, 0, 0
            local refusedSpot   -- the station spot the last refusal of this combine came at (1.10.1)
            local guarded = false
            troubled = false
            while again do
                again = false
                -- everything for this combine on hand? (earlier failures, or a tool that did not come back, can
                -- leave a step short)
                local need = {}
                for _, name in ipairs(units) do need[lower(name)] = (need[lower(name)] or 0) + 1 end
                local short
                for _, name in ipairs(units) do
                    local k = lower(name)
                    if need[k] and B.inventory:count(name, open.pack) < need[k] then short = name; break end
                end
                if short then
                    entry.stopped = string.format('out of %s after %d combine%s', short, n - 1, n == 2 and '' or 's')
                    log.warn('%s: %s', r.label, entry.stopped)
                    return R.ok()
                end
                -- A PROTECTED COMBINE (2.46.0): once per combine, after the ingredients are known to be here (a
                -- Draught is never spent on a combine that cannot happen), and before anything is placed.
                if not guarded then
                    guarded = true
                    local guard = hooks.protect and hooks.protect(r)
                    if guard then
                        local g = guard(ctx, function() return close_open(ctx) end)
                        if not g.ok then
                            entry.stopped = string.format('%s, before combine %d', R.describe(g), n)
                            log.warn('%s: %s', r.label, entry.stopped)
                            return g
                        end
                        local u3 = use_container(ctx, r.container)
                        if not u3.ok then entry.stopped = R.describe(u3); return u3 end
                    end
                end
                -- 2.46.5 (2.46.3 Vadar log): the game said its inventory was out of step since the last look (during the
                -- last combine's returns, or a clear): its slot data is waited out before anything is clicked again, and
                -- whatever the container then shows comes out
                if (B.cursor.desyncs or 0) ~= seenDesyncs then
                    log.warn('%s %d/%d: the game resent its inventory (desync) - settling, clearing, /cleanup and opening %s again before placing',
                        r.label, n, step.combines, r.container)
                    backoff('desync')
                    local rs = reset_container(ctx)
                    if not rs.ok then entry.stopped = R.describe(rs); return rs end
                end
                -- 2.43.5 (2.43.1 log, both refusal spirals): salvage from a failed combine came back after the
                -- 300ms watch, landing while the next combine was placed; the game then refused it. Anything landing
                -- while placing, or an item that would not go in, empties the container and places it all again.
                -- 2.46.5: that includes what the cursor block put away itself mid-pickup ("not ours", a wrong pickup -
                -- the 2.46.3 Vadar log's late Bundled Arrow Shafts never marked the round) and any desync line meanwhile.
                lateRound = false
                local strays0, desyncs0 = B.cursor.strays or 0, B.cursor.desyncs or 0
                local misplaced
                for slot, name in ipairs(units) do
                    local p = place(ctx, slot, name)
                    if not p.ok then
                        if (p.why == 'not placed' or p.why == 'cursor busy' or p.why == 'slot taken') and lates < Make.LATE_RESTARTS then
                            misplaced = R.describe(p); break
                        end
                        entry.stopped = R.describe(p); clear(ctx); return p
                    end
                end
                local late2 = stow_late(ctx)
                if not late2.ok then entry.stopped = R.describe(late2); clear(ctx); return late2 end
                if mq.doevents then mq.doevents() end
                -- burst, then listen (2.46.7, core/pace): everything went in fast; the game now gets the quiet window
                -- to say it is out of step before the /combine is sent (not when the round is placed again anyway)
                if not (lateRound or misplaced) and (B.cursor.strays or 0) == strays0 and B.cursor.quiet then
                    local q = B.cursor:quiet(ctx)
                    if not q.ok then entry.stopped = R.describe(q); clear(ctx); return q end
                    local late3 = stow_late(ctx)   -- a late salvage can land while listening too
                    if not late3.ok then entry.stopped = R.describe(late3); clear(ctx); return late3 end
                end
                if (B.cursor.strays or 0) ~= strays0 then lateRound = true end
                local desynced = (B.cursor.desyncs or 0) ~= desyncs0
                if lateRound or misplaced or desynced then
                    backoff(desynced and 'desync' or misplaced and 'an item did not go in' or 'something landed on the cursor while placing')
                end
                if (lateRound or misplaced or desynced) and lates < Make.LATE_RESTARTS then
                    lates = lates + 1
                    log.warn('%s %d/%d: %s while placing - emptying %s and placing it all again (%d/%d)', r.label, n,
                        step.combines, desynced and 'the game resent its inventory (desync)'
                            or misplaced and ('an item did not go in (' .. misplaced .. ')') or 'something came back late from the last combine',
                        r.container, lates, Make.LATE_RESTARTS)
                    if desynced then
                        -- the full reset: settle, clear, /cleanup, open again (the kit's own window may be gone)
                        local rs = reset_container(ctx)
                        if not rs.ok then entry.stopped = R.describe(rs); return rs end
                    else
                        local cl = clear(ctx)
                        if cl and cl.ok == false then entry.stopped = R.describe(cl); return cl end
                    end
                    local st = stow_late(ctx)
                    if not st.ok then entry.stopped = R.describe(st); return st end
                    again = true
                elseif not holds(units) then
                    entry.stopped = 'the container does not hold what was placed: ' .. contents()
                    clear(ctx)
                    return R.fail('container mismatch', entry.stopped)
                end
                -- /combine packN needs the kit's own PackN window, not only the combine window (2.46.7 log: Pack10 shut
                -- by a desync on the kit's slots, the combine window still up; "Window 'pack10' not open"). Checked
                -- before sending: gone, the reset brings it back and the round is placed again (2.46.8).
                if not again and open.kind == 'kit' and not B.windows:is_open('Pack' .. open.pack) then
                    tries = tries + 1
                    backoff('the container window was gone')
                    if tries >= Make.REFUSED_TRIES then
                        entry.stopped = string.format('the kit\'s window (Pack%d) would not stay open', open.pack)
                        clear(ctx)
                        return R.fail('container closed', entry.stopped)
                    end
                    log.warn('%s %d/%d: the kit\'s own window (Pack%d) is shut although its combine window is up - clearing it, /cleanup, opening it again',
                        r.label, n, step.combines, open.pack)
                    local rs = reset_container(ctx)
                    if not rs.ok then entry.stopped = R.describe(rs); return rs end
                    again = true
                end
                if not again then
                    local c = do_combine(ctx, { product = r.name, yield = r.yield, tools = r.tools, ins = r.ins,
                        also = r.also, failBack = r.failBack, destroy = final and disposal == 'destroy' })
                    if not c.ok then entry.stopped = R.describe(c); clear(ctx); return c end
                    if c.value.result == 'success' then entry.success = entry.success + 1 elseif c.value.result == 'failed' then entry.failed = entry.failed + 1 end
                    if c.value.result == 'refused' then backoff('the game refused the combine')
                    elseif c.value.result == 'closed' then backoff('the container window was gone')
                    elseif not troubled and B.cursor.pace then B.cursor.pace:clean() end
                    entry.made = entry.made + c.value.made
                    entry.destroyed = (entry.destroyed or 0) + (c.value.destroyed or 0)
                    if c.value.result == 'success' and c.value.made ~= r.yield and #c.value.missing == 0 then
                        log.warn('%s [%s]: the data says Yield=%d, the game made %d - fix it in recipes_local.ini', r.label, r.id,
                            r.yield, c.value.made)
                    end
                    log.info('%s %d/%d: %s (%dms)%s', r.label, n, step.combines, c.value.result, c.value.ms,
                        c.value.result == 'failed' and (' - back: ' .. (#c.value.returned > 0 and table.concat(c.value.returned, ', ') or 'nothing')) or '')
                    if c.value.result == 'refused' or c.value.result == 'closed' then
                        -- 'closed' (2.46.8): MQ said "Window 'packN' not open" - the kit's own window was gone (a desync
                        -- on its slots closes it); the same reset brings it back
                        -- the client showed everything placed, the server did not have it all (2.35.4 log: a late
                        -- salvage stowed while placing, then "You cannot combine these items", with a slot empty after;
                        -- 2.43.1 log: the same twice in a row, the second time a whole stack came back - clicks from the
                        -- user's other computer bleeding over). As the old LazCraft did it (2.43.4): what is in it comes
                        -- out, /cleanup closes every window, the container is opened again, anything still in it comes
                        -- out, and it is placed again
                        tries = tries + 1
                        if env.snapshot then env.snapshot:dump(string.format('%s %d/%d refused: %s', r.label, n, step.combines, c.value.line)) end
                        -- A STATION THAT DOES NOT TAKE THE RECIPE (1.10.1; 1.10.0 Vadar log: a PoK "Forge", IT10804, refused
                        -- 9 of 9 with everything placed while the IT66 one made them): refused again at the same spot
                        -- after the full reset, it is left out for the session and the reset goes to another one
                        local otherStation = false
                        if c.value.result == 'refused' and open.kind == 'station' then
                            local spot = lastGood[r.container]
                            if spot and refusedSpot == spot then
                                Make.refusing[spot_key(r.container, spot)] = true
                                lastGood[r.container] = nil
                                log.warn('%s at %.0f, %.0f refused %s twice with everything placed - it does not take this recipe; left out this session, trying another',
                                    r.container, spot.y, spot.x, r.label)
                                tries, refusedSpot, otherStation = 0, nil, true
                            else
                                refusedSpot = spot
                            end
                        end
                        if tries < Make.REFUSED_TRIES then
                            log.warn('%s %d/%d: the game %s; the container now shows %s - clearing it, /cleanup, opening it again',
                                r.label, n, step.combines,
                                c.value.result == 'closed' and ('had no window for it (' .. c.value.line .. ')') or ('refused it (' .. c.value.line .. ')'),
                                contents())
                            local rs = reset_container(ctx, { otherStation = otherStation })
                            if not rs.ok then entry.stopped = R.describe(rs); return rs end
                            again = true
                        else
                            entry.stopped = (c.value.result == 'closed' and 'the container window would not stay open: '
                                or 'the game refused the combine: ') .. c.value.line
                            clear(ctx)
                            return R.fail(c.value.result == 'closed' and 'container closed' or 'combine refused', c.value.line)
                        end
                    end
                end   -- not again
            end
            local left = contents()
            if left ~= 'empty' then
                entry.stopped = 'container not empty after the combine: ' .. left
                return R.fail('container not empty', left)
            end
            ctx:progress(n, step.combines)
        end
        return R.ok()
    end

    local function summary()
        local parts = {}
        for _, e in ipairs(report) do
            local extra = ''
            if (e.destroyed or 0) > 0 then extra = extra .. string.format(', destroyed %d', e.destroyed) end
            if e.recipe.id == recipe.id and sold > 0 then extra = extra .. string.format(', sold %d', sold) end
            if e.skillFrom and e.skillTo then extra = extra .. string.format(', skill %d -> %d', e.skillFrom, e.skillTo) end
            parts[#parts + 1] = string.format('%s: %d/%d ok%s, made %d%s%s', e.recipe.label, e.success, e.wanted,
                e.failed > 0 and (', ' .. e.failed .. ' failed') or '', e.made, extra, e.stopped and (' (' .. e.stopped .. ')') or '')
        end
        return table.concat(parts, '; ')
    end

    -- ---------------------------------------------------------------- bags
    -- How many in one slot: what the game showed or the lists say; else a look at a stack in the bags.
    local function stack_size(item)
        local st = env.stacks
        local n = st and st:size(item)
        if n then return n end
        local ok, it = pcall(function() return mq.TLO.FindItem('=' .. item) end)
        if ok and it and st then return st:from_item(item, it, 'bags') end
        return nil
    end
    -- New bag slots a plan takes: its buys and bank pulls (topping up a stack already there first) and
    -- non-stacking subcombine products. -> slots, { item = true } that do not stack, { item = true } unknown
    local function slots_for(p)
        local add, order = {}, {}
        local function put(item, n)
            local k = lower(item)
            if not add[k] then add[k] = { item = item, n = 0 }; order[#order + 1] = k end
            add[k].n = add[k].n + n
        end
        for _, stops in pairs(p.buys or {}) do
            for _, stop in ipairs(stops) do for _, it in ipairs(stop.items) do put(it.item, it.n) end end
        end
        for _, b in ipairs(p.bankPulls or {}) do put(b.item, b.n) end
        for _, o in ipairs(p.orders or {}) do put(o.item, o.n) end   -- brought by a worker
        if hooks.fit then   -- a summon round: what the casts make stays in the bags
            for _, step in ipairs(p.steps or {}) do
                if step.cast then put(step.cast.item, step.combines * (step.cast.yield or 1)) end
            end
        end
        local need, nostack, unknown = 0, {}, {}
        for _, k in ipairs(order) do
            local a = add[k]
            local size = stack_size(a.item)
            if size == 1 then
                need = need + a.n; nostack[a.item] = true
            elseif size then
                local have = B.inventory:count(a.item)
                need = need + math.ceil((have + a.n) / size) - math.ceil(have / size)
            else
                need = need + 1; unknown[a.item] = true   -- checked at the merchant before buying
            end
        end
        for _, step in ipairs(p.steps or {}) do
            local r = step.recipe
            if r.id ~= recipe.id and not r.gather and not step.cast and not step.order and stack_size(r.name) == 1 then
                need = need + step.combines * (r.yield or 1); nostack[r.name] = true
            end
        end
        return need, nostack, unknown
    end
    local function names(set)
        local t = {}
        for k in pairs(set) do t[#t + 1] = k end
        table.sort(t)
        return table.concat(t, ', ')
    end
    -- Free slots a kit swap will take away (2.46.4; 2.46.3 Cadbane log: "needs 7 slots, 13 free", the buys filled
    -- every bag but pack10, then "no free slot in the other bags for The Scent of Marr from pack10"): a kit step whose
    -- kit is not in a top-level slot borrows pack10 (blocks/kitslot), so the plain bag there - and its free slots - go.
    local function kit_swap_loss(p)
        local top = {}
        for pk = 1, 10 do top[lower(mq.TLO.Me.Inventory('pack' .. pk).Name() or '')] = true end
        local containers, byBag = env.cfg.containers or {}, env.cfg.containerByBag or {}
        local bag = mq.TLO.Me.Inventory('pack' .. 10)
        local slots = bag.Container() or 0
        if slots == 0 or (containers[byBag[lower(bag.Name() or '')] or ''] or {}).type == 'kit' then return 0 end
        local used = 0
        for i = 1, slots do if (bag.Item(i).ID() or 0) > 0 then used = used + 1 end end
        for _, step in ipairs(p.steps or {}) do
            local c = step.recipe and step.recipe.container
            local def = c and containers[c]
            if def and def.type == 'kit' and not step.cast and not step.order then
                local placed = false
                for _, name in ipairs(def.accepts or { c }) do if top[lower(name)] then placed = true; break end end
                if not placed then return slots - used end
            end
        end
        return 0
    end
    -- The most combines (up to `combines`) whose plan fits the free slots. -> n, plan, info
    local function fit(world)
        local p = make_plan(combines, world)
        local okLoss, swapLoss = pcall(kit_swap_loss, p)
        if not okLoss then swapLoss = 0 end
        local room = B.inventory:free_slots() - Make.ROOM - swapLoss
        local need, nostack, unknown = slots_for(p)
        local info = { room = room, need = need, nostack = nostack, unknown = unknown, asked = combines, swapLoss = swapLoss }
        if #p.problems > 0 and not hooks.item and p.short then
            -- short of something held (no merchant sells it): the most combines what is on hand and on the network
            -- covers (2.39.3 log: 23 Blue Diamond here and 29 on Shela, 55 asked - the row was passed for want of 3)
            local lo, hi, best = 1, combines - 1, nil
            while lo <= hi do
                local mid = math.floor((lo + hi) / 2)
                local q = make_plan(mid, world)
                if #q.problems == 0 and slots_for(q) <= room then lo = mid + 1; best = { mid, q } else hi = mid - 1 end
            end
            if best then
                local names = {}
                for _, f in ipairs(p.short) do names[#names + 1] = f.item end
                info.n, info.shortOf = best[1], table.concat(names, ', ')
                info.need = slots_for(best[2])
                info.fullShort = p.short   -- what all the combines are short of: the network is asked for it (2.42.9)
                return best[1], best[2], info
            end
        end
        if (hooks.item and not hooks.fit) or need <= room or #p.problems > 0 then info.n = combines; return combines, p, info end
        local lo, hi, best = 0, combines - 1, nil
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            local q = mid > 0 and make_plan(mid, world) or nil
            if mid == 0 or slots_for(q) <= room then lo = mid + 1; if mid > 0 then best = { mid, q } end
            else hi = mid - 1 end
        end
        info.n = best and best[1] or 0
        return info.n, best and best[2] or p, info
    end
    -- Items to ask the network for: what the plan is short of, and what it already orders from someone (counts change).
    -- 2.42.9 (the Alloy Reinforced Bank Vault log: Cobalt and Tungsten Ore on hand for 1 of 20 combines - 1 was made,
    -- twice, while Antilerd and Shela had 708 and 772 Cobalt, 1389 and 4910 Tungsten in their banks): what the whole
    -- count is short of is asked for too, not only what the cut-down count is.
    local function supply_items(p, info)
        local out, seen = {}, {}
        local function add(item) if not seen[lower(item)] then seen[lower(item)] = true; out[#out + 1] = item end end
        for _, f in ipairs(p.short or {}) do add(f.item) end
        for _, f in ipairs(info and info.fullShort or {}) do add(f.item) end
        for _, f in ipairs(p.pricey or {}) do add(f.item) end   -- dear ones: asked before buying
        for _, o in ipairs(p.orders or {}) do if o.supply then add(o.item) end end
        return out
    end
    -- fit(), with a supply survey first when the plan needs a held item (ctx: the survey waits for answers).
    -- The preflight's survey is kept for the first pass after Go (engine/supply keep_for_go / take_for_go).
    local booksRechecked = false
    local function fit_supplied(ctx, preflight)
        local n, p, info = fit(env.world())
        local want = env.supply and ctx and supply_items(p, info) or {}
        -- the first pass after Go uses the kept answers or drops them (a later row asks afresh)
        local kept = not preflight and env.supply and env.supply:take_for_go(want)
        if #want > 0 and not kept then
            local sv = env.supply:survey(ctx, want)
            if not sv.ok then return nil, p, info, sv end
            if preflight then env.supply:keep_for_go(want) end
            n, p, info = fit(env.world())
        end
        -- short of something some characters answered nothing for: those characters are asked once more before
        -- the plan is taken as short (2.41.7 log: Shylain, 2162 Vial of Clear Mana in her bank, did not answer
        -- the first two surveys, and two leveling rows were passed)
        if env.supply and ctx and #want > 0 then
            local again, who = {}, {}
            local shortNow = {}
            for _, f in ipairs(p.short or {}) do shortNow[#shortNow + 1] = f end
            for _, f in ipairs(info and info.fullShort or {}) do shortNow[#shortNow + 1] = f end
            local seenAgain = {}
            for _, f in ipairs(shortNow) do
                local u = not seenAgain[lower(f.item)] and env.supply:unanswered(f.item)
                seenAgain[lower(f.item)] = true
                if u then
                    again[#again + 1] = f.item
                    for _, nm in ipairs(u) do who[lower(nm)] = true end
                end
            end
            if #again > 0 then
                local names = {}
                for nm in pairs(who) do names[#names + 1] = nm end
                table.sort(names)
                log.info('Supply: short of %s - asking %s again', table.concat(again, ', '), table.concat(names, ', '))
                local sv = env.supply:survey(ctx, again, who)
                if not sv.ok then return nil, p, info, sv end
                n, p, info = fit(env.world())
            end
        end
        -- a summoned item nobody can cast (2.42.12): the spellbooks of those whose class can are read again first
        -- - one may have scribed it since (engine/books) - and the plan made again; once a job
        if env.books and ctx and not booksRechecked and #p.problems > 0 then
            local items = {}
            for _, f in ipairs(p.short or {}) do
                if env.planner.producers and env.planner.producers[lower(f.item)] then items[#items + 1] = f.item end
            end
            for _, f in ipairs(info and info.fullShort or {}) do
                if env.planner.producers and env.planner.producers[lower(f.item)] then items[#items + 1] = f.item end
            end
            if #items > 0 then
                booksRechecked = true
                local k = env.books:recheck_for(items)
                if k > 0 then
                    log.info('Nobody running can cast %s - reading %d spellbook%s again first', table.concat(items, ', '), k, k == 1 and '' or 's')
                    local w = ctx:wait(Make.BOOKS_MS, function() return not env.books:busy() end)
                    if not w.ok and w.why ~= 'timeout' then return nil, p, info, w end
                    n, p, info = fit(env.world())
                end
            end
        end
        return n, p, info
    end
    -- Everyone the plan orders a held item from works for us before the order goes out: a hello, and
    -- LazCraft started there if no card comes back (engine/crew); a card since then is the proof.
    -- ... and a caster not running yet (2.41.9: one that cast it before, or of its class - core/casters): started,
    -- and its card must list the item, else it lacks the spell (said, remembered, the plan made again).
    local function start_suppliers(ctx)
        local asked = {}
        for _, step in ipairs(plan.steps) do
            local o = step.order
            local caster = o and not o.supply and env.crew and env.crew.running and not env.crew:running(o.worker)
            if o and (o.supply or caster) and not asked[lower(o.worker)] then
                asked[lower(o.worker)] = true
                if not env.crew then return R.fail('no workers', 'this plan needs ' .. o.worker .. ' to bring ' .. step.recipe.name .. ', and workers are not set up here') end
                local t0 = mq.gettime()
                if caster then log.info('%s is not running - starting it to cast %s', o.worker, step.recipe.name) end
                local st = Make.start_for(env, ctx, o.worker, step.recipe.name, caster)
                if not st.ok then return st end
                log.info('%s is working for us (%.1fs) - ordering %d %s', o.worker, (mq.gettime() - t0) / 1000, step.combines, step.recipe.name)
            end
        end
        return R.ok()
    end
    local function fit_text(info)
        if info.shortOf then
            return string.format('Only enough %s for %d of %d combines - making %d', info.shortOf, info.n, info.asked, info.n)
        end
        local why = next(info.nostack) and (' (' .. names(info.nostack) .. ' do' .. (next(info.nostack, next(info.nostack)) and '' or 'es') .. ' not stack)') or ''
        if (info.swapLoss or 0) > 0 then
            why = why .. string.format(' (not counting the %d free in pack10: the kit goes there)', info.swapLoss)
        end
        if info.n >= info.asked then
            return string.format('Bags: needs %d slot%s, %d free (keeping %d spare)%s', info.need, info.need == 1 and '' or 's',
                info.room + Make.ROOM, Make.ROOM, why)
        end
        if info.n == 0 then
            return string.format('Bags: not even 1 combine fits - %d combines need %d slots, %d free (keeping %d spare)%s',
                info.asked, info.need, info.room + Make.ROOM, Make.ROOM, why)
        end
        return string.format('Bags: %d of %d combines fit (%d combines need %d slots, %d free, keeping %d spare)%s',
            info.n, info.asked, info.asked, info.need, info.room + Make.ROOM, Make.ROOM, why)
    end

    -- One run: plan, workers, route (bank, shops), the steps, the product's disposal.
    local function one_pass(ctx)
        -- worked out again: the world may have changed while the preflight waited for Go (or since the last pass)
        local n, info, sv
        n, plan, info, sv = fit_supplied(ctx)
        if sv then return sv end
        done = {}
        local short = (not hooks.item and n < combines) and (info.shortOf and string.format('only enough %s for %d of %d combines; ', info.shortOf, n, combines)
            or string.format('bags held %d of %d combines; ', n, combines)) or ''
        if not hooks.item or hooks.fit then
            if n == 0 then return R.fail('bags full', fit_text(info)) end
            log[n < combines and 'info' or 'debug']('%s', fit_text(info))
            if next(info.unknown) then log.debug('  stack size not known yet (read at the merchant): %s', names(info.unknown)) end
        end
        if hooks.planned then
            for _, l in ipairs(env.describe(plan)) do log.debug('Plan: %s', l.text) end
            local p = hooks.planned(plan)
            if not p.ok then return p end
        end
        if #plan.problems > 0 then return R.fail(hooks.item and 'cannot get it' or 'plan changed', table.concat(plan.problems, '; ')) end
        -- where this pass goes and why (2.42.16: a PoK trip the logs could not explain)
        if plan.route and #plan.route > 0 then
            local stops = {}
            for z, list in pairs(plan.buys or {}) do
                for _, st in ipairs(list) do
                    local its = {}
                    for _, it in ipairs(st.items) do its[#its + 1] = it.n .. ' ' .. it.item end
                    stops[#stops + 1] = string.format('%s (%s): %s', st.npc, z, table.concat(its, ', '))
                end
            end
            table.sort(stops)
            log.info('Route: %s, craft in %s%s%s', table.concat(plan.route, ' -> '), tostring(plan.craftZone),
                plan.pickupZone and (' (starts in ' .. plan.pickupZone .. ': a worker there is collected from first)') or '',
                #stops > 0 and ('; buying from ' .. table.concat(stops, '; ')) or '')
        end
        if hooks.stopAtTrivial and recipe.trivial then
            local sk = skill_now(recipe)
            if sk and sk >= stop_at(recipe) then
                return R.ok({ summary = reached(recipe, sk) .. ' already - nothing made' })
            end
        end
        -- money: what this pass buys against the coin carried (Alla prices - a guide; the buy itself is the proof)
        local ml = (not hooks.item or hooks.fit or hooks.items) and money_line(plan)
        if ml then
            log[ml.short and 'warn' or 'debug']('%s', ml.text)
            if ml.short then return R.fail('not enough money', ml.text) end
        end
        -- workers start now, before any travel or shopping, and work while we bank, shop and craft. One that
        -- does not come up is left out and the plan is made again with the others (they may cover it)
        local su = start_suppliers(ctx)
        for _ = 1, Make.SUPPLIER_TRIES do
            if su.ok or not su.worker then break end
            if su.why == 'worker did not start' and env.supply then env.supply:wont_start(su.worker)
            elseif su.why ~= 'missing spell' then break end   -- remembered (core/casters): the plan picks another
            local sv
            n, plan, info, sv = fit_supplied(ctx)
            if sv then return sv end
            if #plan.problems > 0 then return R.fail(su.why, su.detail .. '; without it: ' .. table.concat(plan.problems, '; ')) end
            su = start_suppliers(ctx)
        end
        if not su.ok then return su end
        for _, step in ipairs(plan.steps) do
            if step.order then
                if not env.handoff then return R.fail('no workers', 'this plan needs a worker, and workers are not set up here') end
                -- summoned and ordered ahead at Go: taken from that order, nothing new asked
                local s = not step.order.supply and env.handoff.summon_for and (env.handoff:summon_for(step.order.worker, step.recipe.name)
                    or env.handoff:summon_for(nil, step.recipe.name))
                if s then
                    if lower(s.r.peer) ~= lower(step.order.worker) then
                        log.info('%s: ordered ahead from %s - taken from there, not from %s', step.recipe.name, s.r.peer, step.order.worker)
                        step.order.worker = s.r.peer
                    end
                    orders[step.recipe.id] = { summon = s }
                else
                    local id, r = env.handoff:place_order(step.order.worker, step.recipe.name, step.combines)
                    orders[step.recipe.id] = { id = id, r = r }
                end
            end
        end
        -- Workers never travel after us (2.39.1 log: Shela sent to Thurgadin, over its bridge, for 9 Black
        -- Sapphire). A worker in another zone: we go to its zone (travel.ini) and collect there, before the route.
        -- One here: collected now if the route leaves this zone, else just before the step that needs it (it
        -- works while we shop). A worker whose zone travel.ini cannot reach is asked to come, as before.
        local function worker_zone(o)
            local e = env.crew and env.crew.board and env.crew.board[lower(o.worker)]
            local z = (e and not e.gone and e.zone and e.zone ~= '') and e.zone or o.zone
            return z and lower(z) or nil
        end
        local function leaves_from(z)
            for _, rz in ipairs(plan.route) do if rz ~= z then return true end end
            return false
        end
        if env.handoff then
            for _, step in ipairs(plan.steps) do
                local o = step.order and orders[step.recipe.id]
                if o then
                    local here = B.travel:zone()
                    local wz = worker_zone(step.order)
                    -- not into a zone that is not safe (2.43.3: Lunafeet was in gfaydark on its way to Felwithe, and we
                    -- followed it there); it is collected at the step instead, wherever it is by then
                    local safe = (env.cfg and env.cfg.travel and env.cfg.travel.safe) or nil
                    if wz and wz ~= here and safe and not safe[wz] then
                        log.info('%s is in %s, not a safe zone (on its way somewhere) - collected when its step comes, not followed there',
                            step.order.worker, wz)
                        wz = nil
                    end
                    if wz and wz ~= here and B.travel.path and B.travel:path(wz) then
                        log.info('%s is in %s - going there for the %d %s before the route', step.order.worker, wz, step.combines, step.recipe.name)
                        local t = B.travel:go(ctx, wz)
                        if not t.ok then return t end
                        here = wz
                    end
                    if wz == here and leaves_from(here) then
                        log.info('Collecting %d %s from %s here in %s, before the route leaves the zone', step.combines, step.recipe.name,
                            step.order.worker, here)
                        local f = take(ctx, step, o)
                        orders[step.recipe.id] = nil
                        if not f.ok then return f end
                        step.collected = f.value.taken
                    end
                end
            end
        end
        local banked = #plan.bankPulls == 0
        for i, zone in ipairs(plan.route) do
            if i > 1 or B.travel:zone() ~= zone then
                local t = B.travel:go(ctx, zone)
                if not t.ok then return t end
            end
            if not banked and plan.bankZone == zone then
                ctx:status('Bank')
                local b = bank_trip(ctx)
                if not b.ok then return b end
                banked = true
            end
            ctx:status('Shopping in ' .. zone)
            local s = shop(ctx, zone)
            -- a faction zone is never stayed in: Marr's Calling out after buying there, or after a con too low to
            -- buy (2.42.0) - whatever the route does next, it goes from Marr's
            if s.why ~= 'stopped' and ((env.cfg.travel or {}).faction or {})[zone] and B.travel:zone() == zone then
                log.info('%s in %s - Marr\'s Calling out', s.ok and 'Bought' or 'Could not buy', zone)
                local m = B.travel:go(ctx, Make.MARR_ZONE)
                if not m.ok then
                    if s.ok then return m end
                    log.warn('Could not leave %s: %s', zone, R.describe(m))
                end
            end
            if not s.ok then return s end
        end
        if not banked then return R.fail('no bank trip', 'the route never reached the bank zone ' .. tostring(plan.bankZone)) end
        local real = 0   -- steps that do something (a gather step does nothing in game)
        for _, step in ipairs(plan.steps) do if not step.recipe.gather then real = real + 1 end end
        for i, step in ipairs(plan.steps) do
            if not step.recipe.gather and not yielded then
                local r = run_step(ctx, step, i, real)
                if not r.ok then
                    local f = R.fail(r.why, (r.detail or '') .. ' | ' .. summary())
                    f.learned = r.learned
                    return f
                end
            end
        end
        local cl = keep and R.ok() or close_open(ctx)
        if not cl.ok then return cl end
        for _, e in ipairs(report) do
            if e.recipe.id == recipe.id and e.skillFrom then
                e.skillTo = skill_now(e.recipe)
                -- what this run took a point (core/rates): the Leveling tab's estimates learn from it
                if env.rates and e.skillTo and e.skillTo >= e.skillFrom then
                    env.rates:add(recipe.id, e.success + e.failed, e.skillTo - e.skillFrom, e.skillFrom, e.skillTo,
                        { who = env.me, skill = skill_name(recipe), trivial = recipe.trivial })
                end
            end
        end
        if not hooks.item and disposal == 'sell' then
            local made = 0
            for _, e in ipairs(report) do if e.recipe.id == recipe.id then made = made + e.made end end
            local sl = sell_product(ctx, recipe.name, made - sold - wornOn)
            if not sl.ok then log.warn('Kept %d %s: selling failed - %s', made - sold, recipe.name, R.describe(sl)) end
        end
        local rs = keep and R.ok() or B.kitslot:restore(ctx)
        if not rs.ok then return rs end
        if hooks.items and hooks.item == '(gather)' then
            -- a gathering: what is short is said; each make buys what it still needs itself
            local short = {}
            for _, it in ipairs(hooks.items) do
                local have = B.inventory:count(it.name)
                if have < it.n then short[#short + 1] = string.format('%s %d/%d', it.name, have, it.n) end
            end
            return R.ok({ summary = #short == 0 and string.format('all %d items in the bags', #hooks.items)
                or ('short: ' .. table.concat(short, ', ') .. ' - each make gets the rest itself') })
        end
        if hooks.item then
            local have = B.inventory:count(hooks.item)
            local s = summary()
            s = string.format('holding %d %s%s', have, hooks.item, s ~= '' and ('; ' .. s) or '')
            -- a summon round makes what it makes (it may have stopped for what is waiting)
            if hooks.fit then return R.ok({ summary = s, have = have, yielded = yielded }) end
            if have < hooks.n then return R.fail('came up short', s) end
            return R.ok({ summary = s, have = have })
        end
        return R.ok({ summary = short .. summary() })
    end

    -- A pass whose shopping found a merchant without an item the data says it sells (learned, core/unsold) is
    -- planned again at once: the new plan buys it elsewhere (2.42.3 log: the Stein row ended at Borik Darkanvil -
    -- PoK's merchants sell Jar of Lacquer). What was bought already is in the bags and counts.
    local function pass_replanned(ctx)
        local r
        for _ = 1, Make.REPLANS do
            r = one_pass(ctx)
            if r.ok or not r.learned then return r end
            log.info('%s - planning again without that merchant', r.detail or r.why)
        end
        return r
    end

    -- A later pass is sized to the points left (2.42.1; 2.41.9 log: 564 combines took Unfired Idol (Emerald) 255 ->
    -- 281, then pass 2 asked 564 again - clay, vials and summoned emeralds - for the last point): the points left at
    -- the skill-up model x this character's factor (core/rates, which just learned from the pass before), plus
    -- PASS_PAD; at least PASS_MIN,
    -- never more than the row asked for.
    local rowCombines = combines
    local function pass_size(before)
        if not env.rates or not before or not recipe.trivial then return rowCombines end
        local left = stop_at(recipe) - before
        if left <= 0 then return rowCombines end
        local est, source, f = env.rates:estimate(env.me or '', skill_name(recipe) or '', before, stop_at(recipe), recipe.trivial)
        local n = math.ceil(est * Make.PASS_PAD)
        n = math.max(math.min(n, rowCombines), math.min(Make.PASS_MIN, rowCombines))
        log.info('%s: %d point%s left, ~%d combines (%.2f x the model, %s) - %d combines this pass', recipe.label, left,
            left == 1 and '' or 's', est, f, source == 'yours' and 'with your runs' or 'no runs yet', n)
        return n
    end

    -- Repeat to trivial: passes of one_pass until the skill reaches the trivial (see the rules above).
    local function repeat_passes(ctx)
        local first = skill_now(recipe)
        if not first or not recipe.trivial then
            return R.fail('no skill', string.format('cannot repeat to trivial: %s', not recipe.trivial and (recipe.label .. ' has no trivial in the data')
                or ('the skill ' .. tostring(skill_name(recipe)) .. ' could not be read')))
        end
        local passes, made, why = 0, 0, nil
        local lastSummary
        while true do
            local before = skill_now(recipe)
            if before and recipe.trivial and before >= stop_at(recipe) then
                why = reached(recipe, before)
                break
            end
            if passes >= Make.MAX_PASSES then why = string.format('stopped after %d passes (the most one job runs)', passes); break end
            if not ctx:checkpoint() then return R.fail('stopped', string.format('after %d pass%s', passes, passes == 1 and '' or 'es')) end
            passes = passes + 1
            log.info('%s: pass %d - %s %s, trivial %s', recipe.label, passes, tostring(skill_name(recipe)), tostring(before or '?'),
                tostring(recipe.trivial or '?'))
            if passes > 1 then combines = pass_size(before) end
            report, sold = {}, 0
            local r = pass_replanned(ctx)
            if not r.ok then
                return R.fail(r.why, string.format('%s | pass %d; %d made in the passes before', r.detail or '', passes, made))
            end
            lastSummary = r.value and r.value.summary
            local tries = 0
            for _, e in ipairs(report) do
                if e.recipe.id == recipe.id then made = made + e.made; tries = tries + e.success + e.failed end
            end
            local after = skill_now(recipe)
            log.info('%s: pass %d done - %d combine%s, %s %s -> %s', recipe.label, passes, tries, tries == 1 and '' or 's',
                tostring(skill_name(recipe)), tostring(before or '?'), tostring(after or '?'))
            if tries == 0 then
                why = string.format('pass %d made no combines%s', passes, lastSummary and (' (' .. lastSummary .. ')') or '')
                break
            end
        end
        local last = skill_now(recipe)
        local s = string.format('%d pass%s, made %d %s, skill %s -> %s (%s)', passes, passes == 1 and '' or 'es', made, recipe.name,
            tostring(first or '?'), tostring(last or '?'), why)
        log.info('%s: %s', recipe.label, s)
        return R.ok({ summary = s, passes = passes, made = made })
    end

    return {
        name = hooks.name or string.format('Make %d x %s%s', combines, recipe.label, hooks.repeatToTrivial and ' (repeat to trivial)' or ''),
        confirm = hooks.confirm or not hooks.item, usesToon = true,
        preflight = (hooks.confirm or not hooks.item) and function(ctx)
            local info
            if hooks.item then plan = make_plan()
            else
                local _n, sv
                _n, plan, info, sv = fit_supplied(ctx, true)
                if sv then return sv end
            end
            local lines = env.describe(plan)
            for _, o in ipairs(plan.orders or {}) do
                if o.supply then
                    lines[#lines + 1] = { level = 'ok', text = string.format('Supply: %s brings %d %s (started as your worker at Go if it is not one)', o.worker, o.n, o.item) }
                end
            end
            local ml = not hooks.item and money_line(plan)
            if ml then lines[#lines + 1] = { level = ml.level, text = ml.text } end
            if info then
                lines[#lines + 1] = { level = info.n == 0 and 'block' or (info.n < info.asked and 'warn' or 'ok'), text = fit_text(info)
                    .. ((info.n > 0 and info.n < info.asked) and (hooks.repeatToTrivial and ' - each pass makes what fits' or ' - makes what fits') or '') }
                if next(info.unknown) then
                    lines[#lines + 1] = { level = 'ok', text = 'Stack size read at the merchant (not known yet): ' .. names(info.unknown) }
                end
            end
            if not hooks.item then
                local what = ({ keep = 'kept', sell = 'sold to a merchant here when done (and whenever the bags fill)',
                                destroy = 'DESTROYED as each one is made' })[disposal] or disposal
                lines[#lines + 1] = { level = disposal == 'destroy' and 'warn' or 'ok', text = string.format('%s made by this run: %s', recipe.name, what) }
                if hooks.stopAtTrivial then
                    local sk = skill_now(recipe)
                    local at, kind = stop_at(recipe)
                    if sk and at and sk >= at then
                        -- nothing to do: block here, before any travel, shopping or walking
                        lines[#lines + 1] = { level = 'block', text = kind == 'cap'
                            and string.format('Your %s is %d - at your cap %d (%s\'s trivial is %d), nothing to make',
                                skill_name(recipe), sk, at, recipe.name, recipe.trivial)
                            or string.format('Your %s is %d - already at %s\'s trivial %d, nothing to make',
                                skill_name(recipe), sk, recipe.name, recipe.trivial) }
                    else
                        lines[#lines + 1] = { level = 'ok', text = string.format('Stops at %s%s', kind == 'cap'
                                and string.format('your cap %d (trivial %d)', at, recipe.trivial)
                                or ('trivial ' .. tostring(recipe.trivial or '?')),
                            sk and string.format(' (your %s: %d)', skill_name(recipe), sk) or '') }
                        if hooks.repeatToTrivial then
                            lines[#lines + 1] = { level = 'ok', text = string.format(
                                'Repeats until the trivial: later passes sized to the points left (up to %d passes)',
                                Make.MAX_PASSES) }
                        end
                    end
                end
            end
            return lines
        end or nil,
        execute = function(ctx)
            -- a Make on its own: its summoned items ordered from their casters now (1:1 with its combines)
            if not hooks.item and not hooks.noAhead and not (hooks.stopAtTrivial and Make.past_trivial(env, recipe)) then
                aheadMine = true
                Make.order_ahead(env, { { recipe = recipe, n = combines } }, ctx)
            end
            if not hooks.repeatToTrivial then return pass_replanned(ctx) end
            return repeat_passes(ctx)
        end,
        cleanup = function(ctx)
            if aheadMine and env.handoff and env.handoff.end_summons then env.handoff:end_summons('crafter done') end
            aheadMine = nil
            if env.handoff then
                for k, o in pairs(orders) do if o.id then env.handoff:drop_order(o.id, 'crafter stopped') end; orders[k] = nil end
                env.handoff:release(ctx, fetching)
            end
            B.nav:stop(ctx)
            if B.cast then B.cast:halt(ctx) end   -- stopped mid-cast: nothing may land on the cursor after we go
            if B.merchant:is_open() then B.merchant:close(ctx) end
            if B.bank:is_open() then B.bank:close_bags(ctx); B.bank:close(ctx) end
            if open.kind then clear(ctx) end
            local s = B.cursor:stow(ctx)
            if keep then keep.open = open.kind and open or nil else close_open(ctx) end
            if not s.ok and not B.cursor:is_empty() then return s end
            local rs = keep and R.ok() or B.kitslot:restore(ctx)
            if not rs.ok then return rs end
            -- what was worn in Ammo before this job goes back (a miss is said, not a failure)
            if wornAtStart ~= nil and B.gear then
                local now = B.gear:worn('ammo')
                if lower(now or '') ~= lower(wornAtStart or '') then
                    local g = wornAtStart and B.gear:equip(ctx, wornAtStart, 'ammo') or B.gear:unequip(ctx, 'ammo')
                    if g.ok then log.info('Ammo slot back as it was (%s)', wornAtStart or 'empty')
                    else log.warn('Could not put the Ammo slot back (%s): %s', wornAtStart or 'empty', R.describe(g)) end
                end
                wornAtStart = nil
            end
            return R.ok()
        end,
    }
end

-- A leveling path: each row { recipe, n, disposal } made with repeat to trivial, one after another, under one
-- Go. A row already past its trivial ends at once (the row says so); a row that cannot finish (nothing to buy,
-- a farmed item missing) is said and the path goes on to the next row - its skill-ups still count. Stop ends it.
function Make.chain(env, rows, name)
    local log = env.log
    local current
    return {
        name = name, confirm = true, usesToon = true,
        preflight = function(ctx)
            local lines = {}
            local world = env.world()
            -- held items any row is short of: asked on the network once, then every row planned with the answers
            if env.supply and ctx then
                local want, seen = {}, {}
                for _, row in ipairs(rows) do
                    local ok, p = pcall(function() return env.planner:plan(row.recipe.id, row.n, world) end)
                    for _, list in ipairs({ ok and p and p.short or {}, ok and p and p.pricey or {} }) do
                        for _, f in ipairs(list) do
                            if not seen[lower(f.item)] then seen[lower(f.item)] = true; want[#want + 1] = f.item end
                        end
                    end
                end
                if #want > 0 then
                    local sv = env.supply:survey(ctx, want)
                    if not sv.ok then return sv end
                    env.supply:keep_for_go(want)
                    world = env.world()
                end
            end
            for i, row in ipairs(rows) do
                lines[#lines + 1] = { level = 'ok', text = string.format('%d. %s [%s]: %d combines a pass, %s, until the trivial %s',
                    i, row.recipe.label, row.recipe.id, row.n, row.disposal, tostring(row.recipe.trivial or '?')) }
                -- a row that cannot be made as things stand (a farmed ingredient you do not have) is said now
                local ok, p = pcall(function() return env.planner:plan(row.recipe.id, row.n, world) end)
                if ok and p and #p.problems > 0 then
                    lines[#lines + 1] = { level = 'warn', text = string.format('   row %d: not enough for %d combines - a pass makes what is on hand covers, else the row is passed: %s', i, row.n, p.problems[1]) }
                end
                for _, o in ipairs(ok and p and p.orders or {}) do
                    if o.supply then
                        lines[#lines + 1] = { level = 'ok', text = string.format('   row %d: %s brings %d %s a pass', i, o.worker, o.n, o.item) }
                    end
                end
            end
            if #rows == 0 then lines[1] = { level = 'block', text = 'No rows to make' } end
            return lines
        end,
        execute = function(ctx)
            local parts, failed = {}, 0
            -- every row not at its trivial yet: its summoned items ordered from their casters now, lowest row
            -- first, 1:1 with the row's Combines
            local ahead = {}
            for _, row in ipairs(rows) do
                if not Make.past_trivial(env, row.recipe) then ahead[#ahead + 1] = { recipe = row.recipe, n = row.n } end
            end
            Make.order_ahead(env, ahead, ctx)
            for i, row in ipairs(rows) do
                if not ctx:checkpoint() then return R.fail('stopped') end
                ctx:status(string.format('Path %d of %d: %s', i, #rows, row.recipe.label))
                log.info('Path %d of %d: %s, %d combines a pass, %s', i, #rows, row.recipe.label, row.n, row.disposal)
                local r, c
                for try = 1, Make.ROW_TRIES do
                    local job = Make.job(env, row.recipe, row.n, { disposal = row.disposal, stopAtTrivial = true, repeatToTrivial = true, noAhead = true })
                    current = job
                    r = job.execute(ctx)
                    c = job.cleanup(ctx)
                    current = nil
                    if r.ok or r.why == 'stopped' or (c and not c.ok) or Make.GATHER_FINAL[r.why] or try == Make.ROW_TRIES then break end
                    -- a row that failed on the way (a kit that did not open, a lost trade): made once more from where
                    -- it stands - what it already made is in the bags and the plan uses it (2.43.1; the Mithril Champion
                    -- Arrows log: an hour of subcombines, then a kit that did not open, and the row was given up)
                    log.warn('Path: %s failed (%s) - trying the row once more, from what is in the bags', row.recipe.label, R.describe(r))
                end
                if r.why == 'stopped' then return R.fail('stopped', string.format('at row %d of %d', i, #rows)) end
                parts[#parts + 1] = string.format('%s: %s', row.recipe.label, r.ok and (r.value and r.value.summary or 'done') or R.describe(r))
                if r.ok then log.info('Path %d of %d: %s', i, #rows, parts[#parts]) end
                if not r.ok then
                    failed = failed + 1
                    log.warn('Path: %s did not finish (%s)%s', row.recipe.label, R.describe(r), i < #rows and ' - on to the next row' or '')
                end
                if c and not c.ok then return R.fail(c.why, string.format('%s | at row %d of %d', c.detail or '', i, #rows)) end
                -- the row's leftovers go before the next row (2.42.16): its product (sold, or destroyed when the row
                -- says destroy) and its cheap ingredients; what a row not at its trivial still needs is kept
                -- the inventory is cleared only for a row at its trivial (or the skill cap): a row that failed, or ended
                -- short of it, keeps everything it bought and made for the next try (2.43.1, the user's rule; the
                -- Mithril Champion Arrows log: a failed row's 2034 Fletchings, Arrow Heads and Bundled Shafts were sold).
                -- Stop never gets here.
                local atTrivial = Make.past_trivial(env, row.recipe)
                if Make.CLEAN_AFTER_ROW and not (r.ok and atTrivial) then
                    log.info('Clean-up after %s: skipped - %s; what it bought and made stays for the next try', row.recipe.label,
                        r.ok and 'not at its trivial yet' or 'the row did not finish')
                elseif Make.CLEAN_AFTER_ROW then
                    -- what a row not at its trivial still needs, all the way down its subcombines, is kept
                    local keep = {}
                    for j, other in ipairs(rows) do
                        if j ~= i and not Make.past_trivial(env, other.recipe) then
                            for k in pairs(require('engine.cleanup').needs(env.cfg, other.recipe)) do
                                keep[k] = keep[k] or string.format('row %d (%s) still needs it', j, other.recipe.label)
                            end
                        end
                    end
                    local world = env.world and env.world(true) or {}
                    local cu = require('engine.cleanup').after_row(env, ctx, row.recipe, keep, {
                        maxPrice = world.requestOver or Make.CLEAN_MAX_PRICE, destroyProduct = row.disposal == 'destroy', subs = true })
                    if cu.why == 'stopped' then return R.fail('stopped', string.format('at row %d of %d (clean-up)', i, #rows)) end
                    if not cu.ok then log.warn('Clean-up after %s: %s - on to the next row', row.recipe.label, R.describe(cu))
                    elseif cu.value and cu.value.summary ~= 'nothing to clean up' then
                        log.info('Clean-up after %s: %s', row.recipe.label, cu.value.summary)
                    end
                end
            end
            -- each row's own line is in the log already; the summary stays short (a long one can take the client down)
            local s = string.format('%d row%s, %d finished%s - each row is in the log above', #rows, #rows == 1 and '' or 's',
                #rows - failed, failed > 0 and string.format(', %d did not', failed) or '')
            return R.ok({ summary = s })
        end,
        cleanup = function(ctx)
            if current then current.cleanup(ctx); current = nil end
            if env.handoff and env.handoff.end_summons then env.handoff:end_summons('crafter done') end
            return R.ok()
        end,
    }
end

-- A list made one item after another under one Go: the Research tab, `/lc have` and the queue.
--   items: { recipe, qty, kind, disposal } - kind 'research' (the default): qty in hand - what is already held
--          (bags and bank) counts, so a held one is skipped, and the rest is made round after round (a failure
--          eats the materials, so each round plans, buys and makes what is still owed) until held, or a round
--          makes none, never more than ROUNDS rounds. kind 'craft': qty combines, as Make (disposal applies).
--   hooks.done(item, ok, summary)  after each item (the queue takes finished ones off)
-- An item that cannot finish is said and the next one goes on. The preflight asks the network once for
-- everything any item is short of (or that is dear), then plans each item with the answers.
Make.ROUNDS = 20
function Make.batch(env, items, name, hooks)
    hooks = hooks or {}
    local log, B = env.log, env.blocks
    local current
    local keep = {}   -- the open container, carried from one entry to the next (Make.job hooks.keepOpen)
    local function held(world, r)
        return (world.bags(r.name) or 0) + (world.bank(r.name) or 0)
    end
    local function craft(it) return it.kind == 'craft' end
    return {
        name = name, confirm = true, usesToon = true,
        preflight = function(ctx)
            local lines = {}
            local world = env.world()
            local function plan_of(it)
                local n = craft(it) and it.qty or math.max(1, math.ceil((it.qty - held(world, it.recipe)) / (it.recipe.yield or 1)))
                local ok, p = pcall(function() return env.planner:plan(it.recipe.id, n, world) end)
                return ok and p or nil
            end
            if env.supply and ctx then
                local want, seen = {}, {}
                for _, it in ipairs(items) do
                    local p = plan_of(it)
                    for _, list in ipairs({ p and p.short or {}, p and p.pricey or {} }) do
                        for _, f in ipairs(list) do
                            if not seen[lower(f.item)] then seen[lower(f.item)] = true; want[#want + 1] = f.item end
                        end
                    end
                end
                if #want > 0 then
                    local sv = env.supply:survey(ctx, want)
                    if not sv.ok then return sv end
                    env.supply:keep_for_go(want)
                    world = env.world()
                end
            end
            local todo = 0
            for i, it in ipairs(items) do
                local h = held(world, it.recipe)
                local need = it.qty - h
                if craft(it) then
                    todo = todo + 1
                    lines[#lines + 1] = { level = it.disposal == 'destroy' and 'warn' or 'ok', text = string.format('%d. %s [%s]: %d combine%s, %s', i,
                        it.recipe.label, it.recipe.id, it.qty, it.qty == 1 and '' or 's', it.disposal == 'destroy' and 'DESTROYED' or (it.disposal or 'keep')) }
                elseif need <= 0 then
                    lines[#lines + 1] = { level = 'ok', text = string.format('%d. %s: %d held - skipped', i, it.recipe.label, h) }
                else
                    todo = todo + 1
                    lines[#lines + 1] = { level = 'ok', text = string.format('%d. %s [%s]: make %d%s (a failure is made again)', i,
                        it.recipe.label, it.recipe.id, need, h > 0 and string.format(', %d held', h) or '') }
                end
                if craft(it) or need > 0 then
                    local p = plan_of(it)
                    if p and #p.problems > 0 then
                        lines[#lines + 1] = { level = 'warn', text = string.format('   %d will be passed unless that changes: %s', i, p.problems[1]) }
                    end
                    for _, o in ipairs(p and p.orders or {}) do
                        if o.supply then lines[#lines + 1] = { level = 'ok', text = string.format('   %s brings %d %s', o.worker, o.n, o.item) } end
                    end
                end
            end
            if todo == 0 then lines[#lines + 1] = { level = 'block', text = 'Everything is already held - nothing to make' } end
            return lines
        end,
        execute = function(ctx)
            local done, short = 0, {}
            -- every entry's summoned items ordered from their casters now (1:1 with the counts)
            local ahead, w0 = {}, env.world()
            for _, it in ipairs(items) do
                local n = craft(it) and it.qty or math.ceil(math.max(0, it.qty - held(w0, it.recipe)) / (it.recipe.yield or 1))
                ahead[#ahead + 1] = { recipe = it.recipe, n = n }
            end
            Make.order_ahead(env, ahead, ctx)
            local function run(job)
                current = job
                local res = job.execute(ctx)
                local c = job.cleanup(ctx)
                current = nil
                return res, c
            end
            -- One shopping trip for as many entries as fit in the bags (2.41.5; the 2.41.4 log: a research queue of 10
            -- spells went bank -> Scholar Klaz -> combine, and asked the network, once per spell): every raw item
            -- those entries need is taken from the bank and bought in one route, then they are made one by one and
            -- find it all in the bags. What an entry still lacks (a failure ate it) it gets itself, as before.
            -- the container stays open from one entry to the next (Make.job hooks.keepOpen); closed here
            local function close_kept()
                local o = keep.open
                keep.open = nil
                if o and o.kind == 'kit' then B.kit:close_bags(ctx); B.kit:close(ctx, o.pack)
                elseif o and o.kind == 'station' then B.station:close_bags(ctx); B.station:close(ctx, o.target) end
                if B.kitslot then B.kitslot:restore(ctx) end
            end
            local function combines_of(it, world)
                return craft(it) and it.qty or math.ceil(math.max(0, it.qty - held(world, it.recipe)) / (it.recipe.yield or 1))
            end
            local function slots(list)
                local n = 0
                for _, x in ipairs(list) do
                    local size = env.stacks and env.stacks:size(x.name) or nil
                    local have = B.inventory:count(x.name)
                    if not size or size <= 1 then n = n + x.n
                    else n = n + math.ceil((have + x.n) / size) - math.ceil(have / size) end
                end
                return n
            end
            local function gather_from(ctx, list, i)
                local world = env.world()
                local room = B.inventory:free_slots() - Make.ROOM
                -- each entry's needs worked out once and added up (2.41.6 log: working the whole list out again for
                -- every entry added took 27s for 14 spells)
                local needs, j = {}, i - 1
                for k = i, #list do
                    local nd = env.planner:raw_needs({ { recipe = list[k].recipe, n = combines_of(list[k], world) } }, world)
                    local trial = {}
                    for _, x in ipairs(needs) do trial[#trial + 1] = { name = x.name, n = x.n } end
                    local at = {}
                    for idx, x in ipairs(trial) do at[x.name:lower()] = idx end
                    for _, x in ipairs(nd) do
                        local idx = at[x.name:lower()]
                        if idx then trial[idx].n = trial[idx].n + x.n else trial[#trial + 1] = { name = x.name, n = x.n } end
                    end
                    if slots(trial) > room then break end
                    needs, j = trial, k
                end
                if j < i then
                    log.info('Gathering: %s alone needs more bag room than there is - it shops for itself', list[i].recipe.label)
                    return i
                end
                if #needs == 0 then return j end
                log.info('Gathering for %d entr%s in one trip: %d item%s', j - i + 1, j == i and 'y' or 'ies', #needs, #needs == 1 and '' or 's')
                close_kept()
                local res, c = run(Make.gather_job(env, needs, string.format('Gather for %d entries', j - i + 1)))
                if res.why == 'stopped' then return nil, res end
                -- a trip that failed on the way (2.42.8 log: the nav to Klonopin wedged - "did not arrive"), not for
                -- want of anything, is made again before every entry is left to shop for itself (2.42.10)
                for try = 2, Make.GATHER_TRIES do
                    if res.ok or (c and not c.ok) or Make.GATHER_FINAL[res.why] then break end
                    log.warn('Gathering: %s - trying the trip again (%d of %d)', R.describe(res), try, Make.GATHER_TRIES)
                    res, c = run(Make.gather_job(env, needs, string.format('Gather for %d entries', j - i + 1)))
                    if res.why == 'stopped' then return nil, res end
                end
                if not res.ok then log.warn('Gathering: %s - each entry gets what it needs itself', R.describe(res))
                else log.info('Gathering: %s', res.value and res.value.summary or 'done') end
                if c and not c.ok then return nil, c end
                return j
            end
            -- Passes over the list. A research entry whose combine failed (the failure ate the materials) is made
            -- again in the next pass, with the others that failed - gathered in one trip again - not on its own
            -- (2.41.6 log: a failed spell ended "a round made none" and was dropped). An entry whose job could not
            -- run (nothing to buy, ...) ends with the reason. Craft entries are made once.
            local made, owed, pending = {}, {}, {}
            for i = 1, #items do pending[#pending + 1] = i; made[i] = 0 end
            for pass = 1, Make.ROUNDS do
                local todo = {}
                -- what a research entry owes is counted when it is reached (an earlier entry may make some of it)
                for _, i in ipairs(pending) do
                    if craft(items[i]) or not owed[i] or owed[i] - made[i] > 0 then todo[#todo + 1] = i end
                end
                if #todo == 0 then pending = {}; break end
                if pass > 1 then log.info('Pass %d: %d entr%s failed - made again', pass, #todo, #todo == 1 and 'y' or 'ies') end
                local list = {}
                for _, i in ipairs(todo) do list[#list + 1] = items[i] end
                local gatheredTo, still = 0, {}
                for k, i in ipairs(todo) do
                    if not ctx:checkpoint() then return R.fail('stopped') end
                    if k > gatheredTo then
                        local j, e = gather_from(ctx, list, k)
                        if e then return R.fail(e.why, e.detail) end
                        gatheredTo = j
                    end
                    local it = items[i]
                    local r = it.recipe
                    if craft(it) then
                        ctx:status(string.format('%d of %d: %s, %d combines', i, #items, r.label, it.qty))
                        log.info('%d of %d: %s - %d combine%s, %s', i, #items, r.label, it.qty, it.qty == 1 and '' or 's', it.disposal or 'keep')
                        local res, c = run(Make.job(env, r, it.qty, { disposal = it.disposal or 'keep', noAhead = true, keepOpen = keep }))
                        if res.why == 'stopped' then return R.fail('stopped', 'at ' .. r.label) end
                        if c and not c.ok then return R.fail(c.why, string.format('%s | at %s', c.detail or '', r.label)) end
                        local s = res.ok and (res.value and res.value.summary or 'done') or R.describe(res)
                        if res.ok then done = done + 1; log.info('%d of %d: %s', i, #items, s)
                        else short[#short + 1] = r.label; log.warn('%d of %d: %s did not finish (%s)', i, #items, r.label, s) end
                        if hooks.done then hooks.done(it, res.ok, s) end
                    elseif not owed[i] and it.qty - held(env.world(), r) <= 0 then
                        owed[i] = 0
                        log.info('%d of %d: %s already held - skipped', i, #items, r.label)
                        done = done + 1
                        if hooks.done then hooks.done(it, true, 'already held') end
                    else
                        owed[i] = owed[i] or (it.qty - held(env.world(), r))
                        local need = owed[i]
                        local combines = math.ceil((need - made[i]) / (r.yield or 1))
                        ctx:status(string.format('%d of %d: %s, %d of %d', i, #items, r.label, made[i], need))
                        log.info('%d of %d: %s - %d combine%s for the %d still owed%s', i, #items, r.label, combines,
                            combines == 1 and '' or 's', need - made[i], pass > 1 and string.format(' (pass %d)', pass) or '')
                        local before = B.inventory:count(r.name)
                        local res, c = run(Make.job(env, r, combines, { disposal = 'keep', noAhead = true, keepOpen = keep }))
                        local got = math.max(0, B.inventory:count(r.name) - before)
                        made[i] = made[i] + got
                        if res.why == 'stopped' then return R.fail('stopped', string.format('at %s (%d of %d made)', r.label, made[i], need)) end
                        if c and not c.ok then return R.fail(c.why, string.format('%s | at %s', c.detail or '', r.label)) end
                        if made[i] >= need then
                            done = done + 1
                            log.info('%d of %d: %s - %d made', i, #items, r.label, made[i])
                            if hooks.done then hooks.done(it, true, made[i] .. ' made') end
                        elseif res.ok then
                            still[#still + 1] = i
                            log.info('%d of %d: %s - %d of %d made (a combine failed) - made again after the others', i, #items, r.label, made[i], need)
                        else
                            short[#short + 1] = string.format('%s %d/%d', r.label, made[i], need)
                            log.warn('%d of %d: %s - %d of %d made (%s)', i, #items, r.label, made[i], need, R.describe(res))
                            if hooks.done then hooks.done(it, false, R.describe(res)) end
                        end
                    end
                end
                pending = still
            end
            for _, i in ipairs(pending) do
                local it = items[i]
                short[#short + 1] = string.format('%s %d/%d', it.recipe.label, made[i], owed[i] or it.qty)
                log.warn('%s: still short after %d passes', it.recipe.label, Make.ROUNDS)
                if hooks.done then hooks.done(it, false, string.format('still short after %d passes', Make.ROUNDS)) end
            end
            close_kept()
            return R.ok({ summary = string.format('%d item%s, %d done%s', #items, #items == 1 and '' or 's', done,
                #short > 0 and ('; not finished: ' .. table.concat(short, ', ')) or '') })
        end,
        cleanup = function(ctx)
            if current then current.cleanup(ctx); current = nil end
            if keep.open then
                local o = keep.open
                keep.open = nil
                if o.kind == 'kit' then B.kit:close_bags(ctx); B.kit:close(ctx, o.pack)
                elseif o.kind == 'station' then B.station:close_bags(ctx); B.station:close(ctx, o.target) end
            end
            if B.kitslot then B.kitslot:restore(ctx) end
            if env.handoff and env.handoff.end_summons then env.handoff:end_summons('crafter done') end
            return R.ok()
        end,
    }
end

-- One round of a worker's summon order (engine/handoff): as many more of `item` as fit in the bags, up to
-- `upto`, on top of the `base` held now - reagents bought with this character's own coin (checked first), then
-- cast. hooks.yield() true stops it between casts; R.ok({ have, yielded }) either way.
function Make.summon_round(env, item, base, upto, hooks)
    hooks = hooks or {}
    hooks.item, hooks.n, hooks.fit = item, base + upto, { base = base }
    return Make.job(env, { label = string.format('%d more %s', upto, item) }, upto, hooks)
end

-- One trip for a whole list (2.41.5): every raw item the list needs, from the bank and the merchants in one route,
-- before any make of it runs (they then find it all in the bags). items = { { name, n } }
function Make.gather_job(env, items, name)
    return Make.job(env, { label = name or 'the list' }, 1, { item = '(gather)', items = items, name = name })
end

function Make.get_job(env, item, n, hooks)
    hooks = hooks or {}
    hooks.item, hooks.n = item, n
    return Make.job(env, { label = string.format('%d %s', n, item) }, 1, hooks)
end

return Make
