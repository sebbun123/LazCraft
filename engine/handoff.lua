-- Handoff: getting items from a worker. The worker comes to the crafter and gives; the crafter stays put.
--   Crafter: order_job(worker, item, n) - asks the worker to get n (it plans like the crafter does: bags,
--            bank, buy, make, cast), waits on its word while it works, then fetches them.
--   Crafter: fetch_job(worker, item, n) - asks the worker to come with n, waits where it stands (the worker
--            says where it is every HEARTBEAT_MS on the way; SILENT_MS without a word = it is not coming),
--            then takes the trades.
--   Worker:  a 'come' from its crafter queues a give job: travel to the crafter's zone (travel.ini), walk to
--            the spot the crafter said it stands on (/nav loc - a far character's spawn is not kept up to
--            date, and /nav id to it has no path: 2.32.0 logs, 534 and 427 away), then to it, say arrived,
--            trade n of the item over.
--   Worker:  an 'ask' queues a get job (Make.get_job): plan, answer yes/no, do it, say made and hold them.
--   Summon orders (2.41.0) - an item made by casting, ordered at Go for a whole job (engine/make order_ahead):
--   Crafter: place_summon(worker, item, n); a pass takes what it needs with take_summoned (waits only while the
--            worker has fewer made than the pass needs); end_summons(why) calls the rest off.
--   Worker:  a 'summon' is worked in rounds (Make.summon_round: as many as fit in the bags, reagents bought
--            with its own coin, then cast). Anything else queued goes first: between casts, and while
--            meditating, the round stops and the order goes back in the queue behind it. Bags full: it waits
--            until a give frees room. Its count of the item goes with every 'working' word.
--
-- Messages (each carries the request id, so an old message can never count for a new request):
--   ask <id> <n> <item>           crafter -> worker   get me n of this
--   answer <id> yes|no <why>      worker -> crafter   whether it can, and how (or why not)
--   summon <id> <n> <item>        crafter -> worker   make n more of this by casting, between everything else
--   working <id> <status> [have]  worker -> crafter   what it is doing (on change, and every HEARTBEAT_MS);
--                                                     a summon order also says how many it holds
--   made <id> <have>              worker -> crafter   done, holding them
--   come <id> <n> <item> <zone>   crafter -> worker   bring me n, I am in <zone>
--   coming <id> <zone> <state>    worker -> crafter   on the way (sent at once, then every HEARTBEAT_MS)
--   arrived <id>                  worker -> crafter   next to you, loading the trade
--   loaded <id> <k> <units>       worker -> crafter   trade k is in the window
--   accepted <id> <k>             crafter -> worker   I clicked Trade on trade k
--   got <id> <k> <units>          crafter -> worker   my count went up by trade k
--   failed <id> <reason>          either way          giving up on this request
--
-- A failed request is tried once more for what is still missing, unless it cannot work (no way there,
-- stopped, out of the item, went quiet).
local Peers = require('blocks.peers')
local R = require('core.result')

local Handoff = {}
Handoff.__index = Handoff

Handoff.NAV_DIST = 10
Handoff.TRIES = 2
Handoff.HEARTBEAT_MS = 10000
Handoff.SILENT_MS = 30000
local NO_RETRY = { ['not here'] = true, stopped = true, ['ran out'] = true, ['confirmation box'] = true,
                   ['no way there'] = true, quiet = true }
local NO_RETRY_TEXT = { 'not in my zone', 'no way', 'ran out', 'stopped' }

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local function lower(s) return (s or ''):lower() end

-- deps: peers, log, now, role, me, crafter (worker), runner, trade, nav, spawns, cursor, travel, zone() -> short name,
--       make (the Make module) and makeEnv (its env), for orders
function Handoff.new(deps)
    local h = setmetatable({}, Handoff)
    for k, v in pairs(deps) do h[k] = v end
    h.log = h.log or NOLOG
    h.reqs = {}
    h.seq = 0
    h.summons = {}   -- crafter: lower(worker)|lower(item) -> { id, r } open summon orders
    return h
end

function Handoff:req(from, id)
    local r = self.reqs[id]
    if not r then
        self.log.debug('  %s: no request %s here - ignored', from, id)
        return nil
    end
    if lower(r.peer) ~= lower(from) then
        self.log.debug('  request %s belongs to %s, not %s - ignored', id, r.peer, from)
        return nil
    end
    return r
end

function Handoff:start()
    local p = self.peers
    p:on('failed', function(from, id, why)
        local r = self:req(from, id)
        if r then r.heard = self.now() end
        if r and not r.cancelled then
            r.cancelled = Peers.decode(why)
            self.log.info('%s gave up on request %s: %s', from, id, r.cancelled)
            -- worker: stop the job doing it (queued or running); the rest of the queue carries on
            if self.role == 'worker' and r.jobId and not r.done then self.runner:drop(r.jobId) end
            -- a summon order waiting for bag room has no job: it is simply forgotten
            if self.role == 'worker' and r.kind == 'summon' and r.parked then self.reqs[id] = nil end
        end
    end)
    if self.role == 'worker' then
        p:on('come', function(from, id, n, item, zone, y, x, z, place)
            local loc = tonumber(y) and tonumber(x) and tonumber(z) and { tonumber(y), tonumber(x), tonumber(z) } or nil
            self:on_come(from, id, tonumber(n), Peers.decode(item), lower(Peers.decode(zone)), loc, place)
        end)
        p:on('ask', function(from, id, n, item) self:on_ask(from, id, tonumber(n), Peers.decode(item)) end)
        p:on('summon', function(from, id, n, item) self:on_summon(from, id, tonumber(n), Peers.decode(item)) end)
        p:on('accepted', function(from, id, k) local r = self:req(from, id); if r then r.accepted[tonumber(k)] = true end end)
        p:on('got', function(from, id, k) local r = self:req(from, id); if r then r.got[tonumber(k)] = true end end)
    else
        p:on('loaded', function(from, id, k, units)
            local r = self:req(from, id); if r then r.heard = self.now(); r.loaded[tonumber(k)] = tonumber(units) end
        end)
        p:on('coming', function(from, id, zone, state)
            local r = self:req(from, id)
            if not r then return end
            r.heard = self.now()
            local where = Peers.decode(zone) .. ' (' .. Peers.decode(state) .. ')'
            if where ~= r.where then r.where = where; self.log.info('%s is coming: %s', from, where) end
        end)
        p:on('answer', function(from, id, verdict, why)
            local r = self:req(from, id)
            if not r then return end
            r.heard, r.answer, r.why = self.now(), verdict, Peers.decode(why)
            if verdict == 'yes' then self.log.info('%s will get it: %s', from, r.why)
            else self.log.info('%s cannot: %s', from, r.why) end
        end)
        p:on('working', function(from, id, status, have)
            local r = self:req(from, id)
            if not r then return end
            r.heard = self.now()
            if tonumber(have) then r.have = tonumber(have) end
            local st = Peers.decode(status)
            if st ~= r.status then r.status = st; self.log.info('%s: %s', from, st) end
        end)
        p:on('made', function(from, id, have)
            local r = self:req(from, id)
            if r then
                r.heard, r.made = self.now(), tonumber(have) or 0
                -- a summon order's count: what it holds at the end (2.42.13 Lopan log: the last 'working' count
                -- stayed - 125 - after the worker's bags had gone down to 2)
                if r.kind == 'summon' and tonumber(have) then r.have = tonumber(have) end
            end
        end)
        p:on('arrived', function(from, id)
            local r = self:req(from, id)
            if r then r.heard, r.arrived = self.now(), true end
        end)
    end
end

-- ---------------------------------------------------------------- worker

-- Worker: is this a crafter we work for (2.44.0: every crafter that said hello - crew:serves; the tests' one crafter)
function Handoff:serves(from)
    if self.serves_fn then return self.serves_fn(from) end
    return lower(from) == lower(self.crafter or '')
end

-- Worker: what it holds for each crafter (2.44.0, several drivers): made or bought for an order, summoned for a summon
-- order, until given. Another crafter's order counts only what is not held for someone else.
function Handoff:hold(peer, item, delta)
    self.holding = self.holding or {}
    local k = lower(peer) .. '|' .. lower(item)
    self.holding[k] = math.max(0, (self.holding[k] or 0) + (delta or 0))
    if self.holding[k] == 0 then self.holding[k] = nil end
end

-- held for crafters other than `except`
function Handoff:reserved(item, except)
    local n, suffix = 0, '|' .. lower(item)
    for k, v in pairs(self.holding or {}) do
        if k:sub(-#suffix) == suffix and k:sub(1, #k - #suffix) ~= lower(except or '') then n = n + v end
    end
    return n
end

-- Worker: the zone we stand in when it is not a safe one (travel.ini [Safe]) - no order is taken there: the
-- character is out playing (2.43.9 Lunafeet log: in sebilis, it took an order and ported out to Jaggedpine)
function Handoff:unsafe()
    local safe = self.makeEnv and self.makeEnv.cfg and self.makeEnv.cfg.travel and self.makeEnv.cfg.travel.safe
    local z = lower(self.zone and self.zone() or '')
    if safe and z ~= '' and not safe[z] then return z end
    return nil
end

function Handoff:on_come(from, id, n, item, zone, loc, place)
    if not self:serves(from) then
        self.log.info('%s asked for %s, but this worker works for %s - ignored', from, item, self.crafter)
        return
    end
    local uz = self:unsafe()
    if uz then
        self.log.warn('%s wants %d %s brought to %s - not going: we are in %s, not a safe zone', from, n or 0, item, zone, uz)
        return self.peers:send(from, 'failed', id, Peers.encode('in ' .. uz .. ', not a safe zone'))
    end
    if not n or n < 1 or item == '' or zone == '' then
        self.log.warn('Bad request from %s: %s %s %s', from, tostring(n), item, zone)
        return self.peers:send(from, 'failed', id, Peers.encode('bad request'))
    end
    -- place: 'mirror' when the crafter stands in the zone's AFK mirror, 'main' when not, nil from an older crafter
    local r = { peer = from, accepted = {}, got = {}, zone = zone, loc = loc, state = 'queued', beat = self.now(),
                mirror = place == 'mirror' or (place ~= 'main' and nil) }
    self.reqs[id] = r
    self.log.info('%s wants %d %s in %s%s', from, n, item, zone, r.mirror and ' (AFK mirror)' or '')
    self.peers:send(from, 'coming', id, Peers.encode(lower(self.zone())), r.state)
    r.jobId = self.runner:add(self:give_job(id, from, item, n))
end

-- How a plan gets the item, in a few words (for the yes answer).
local function plan_words(plan)
    local parts = {}
    local bags = 0
    for _, c in ipairs(plan.tree.children) do bags = bags + (c.bags or 0) end
    if bags > 0 then parts[#parts + 1] = bags .. ' in bags' end
    local bank = 0
    for _, b in ipairs(plan.bankPulls) do bank = bank + b.n end
    if bank > 0 then parts[#parts + 1] = 'bank ' .. bank end
    local buys = 0
    for _, stops in pairs(plan.buys) do for _, st in ipairs(stops) do for _, it in ipairs(st.items) do buys = buys + it.n end end end
    if buys > 0 then parts[#parts + 1] = 'buy ' .. buys end
    for _, st in ipairs(plan.steps) do
        if st.cast then parts[#parts + 1] = string.format('%d cast%s of %s', st.combines, st.combines == 1 and '' or 's', st.cast.spell)
        elseif not st.recipe.gather then parts[#parts + 1] = string.format('%dx %s', st.combines, st.recipe.label) end
    end
    if #plan.route > 1 then parts[#parts + 1] = 'route ' .. table.concat(plan.route, '>') end
    return #parts > 0 and table.concat(parts, ', ') or 'nothing to do'
end

function Handoff:on_ask(from, id, n, item)
    if not self:serves(from) then
        self.log.info('%s asked for %s, but this worker works for %s - ignored', from, item, self.crafter)
        return
    end
    if not n or n < 1 or item == '' then
        self.log.warn('Bad order from %s: %s %s', from, tostring(n), item)
        return self.peers:send(from, 'answer', id, 'no', Peers.encode('bad order'))
    end
    local uz = self:unsafe()
    if uz then
        self.log.warn('%s orders %d %s - refused: we are in %s, not a safe zone', from, n, item, uz)
        return self.peers:send(from, 'answer', id, 'no', Peers.encode('in ' .. uz .. ', not a safe zone'))
    end
    local h = self
    local r = { peer = from, kind = 'order', beat = self.now(), item = item, n = n, queued = true }
    self.reqs[id] = r
    self.log.info('%s orders %d %s', from, n, item)
    local hooks
    hooks = {
        name = string.format('Get %d %s for %s', n, item, from),
        planned = function(plan)
            if #plan.problems > 0 then
                r.done = true
                h.peers:send(from, 'answer', id, 'no', Peers.encode(plan.problems[1]))
                return R.fail('cannot get it', table.concat(plan.problems, '; '))
            end
            h.peers:send(from, 'answer', id, 'yes', Peers.encode(plan_words(plan)))
            return R.ok()
        end,
    }
    -- what we hold for other crafters stays theirs: the job gets this order's n on top of it (2.44.0)
    local others = self:reserved(item, from)
    if others > 0 then self.log.info('%d %s held for other crafters - getting %d on top for %s', others, item, n, from) end
    local job = self.make.get_job(self.makeEnv, item, n + others, hooks)
    r.job = job.name
    local exec = job.execute
    job.execute = function(ctx)
        r.queued = false
        hooks.items = h:with_queued(id, item, n + others)
        local res = exec(ctx)
        if not r.done then
            r.done = true
            if res.ok then h:hold(from, item, n); h.peers:send(from, 'made', id, res.value.have)
            elseif not r.cancelled then h.peers:send(from, 'failed', id, Peers.encode(R.describe(res))) end
        end
        h.reqs[id] = nil
        return res
    end
    local clean = job.cleanup
    job.cleanup = function(ctx)
        if not r.done then
            r.done = true
            if not r.cancelled then h.peers:send(from, 'failed', id, Peers.encode('worker stopped')) end
        end
        h.reqs[id] = nil
        return clean(ctx)
    end
    r.jobId = self.runner:add(job)
end

-- One trip for every order waiting (2.42.5; 2.42.4 log: Antilerd went to Felwithe for 1228 Large Brick of Mithril,
-- came back, and went again for 2457 Small Brick ordered at the same moment). The order starting is planned with
-- every other order still queued from the same crafter - each one whose own plan is clean, of another item - so
-- the route buys all of it at once; their own jobs then find it in the bags. -> the items list, or nil (just this)
function Handoff:with_queued(id, item, n)
    local me = self.reqs[id]
    local env = self.makeEnv
    if not (me and env and env.planner and env.world) then return nil end
    local list, extra = { { name = item, n = n } }, {}
    local world
    for oid, o in pairs(self.reqs) do
        if oid ~= id and o.kind == 'order' and o.queued and not o.done and lower(o.peer) == lower(me.peer)
           and o.item and lower(o.item) ~= lower(item) then
            world = world or env.world(true)
            local ok, p = pcall(function() return env.planner:plan_item(o.item, o.n, world) end)
            if ok and p and #p.problems == 0 then
                list[#list + 1] = { name = o.item, n = o.n }
                extra[#extra + 1] = string.format('%d %s', o.n, o.item)
            end
        end
    end
    if #extra == 0 then return nil end
    table.sort(extra)
    self.log.info('One trip: planning %d %s with the order%s queued behind it (%s)', n, item, #extra == 1 and '' or 's',
        table.concat(extra, ', '))
    return list
end

-- A trade under way (worker): a pause by hand waits for it to finish.
function Handoff:giving()
    for _, r in pairs(self.reqs) do if r.state == 'giving' and not r.done then return true end end
    return false
end

-- Every pass of the main loop (and every wait in a job): say where we are to a crafter we are coming to,
-- or what we are doing for an order. Paused by hand (2.42.7): every message says so, and the crafter waits.
function Handoff:tick()
    if self.role ~= 'worker' then return end
    local t = self.now()
    local held = self.held and self.held() and self.runner and (self.runner.paused or not self.runner.active)
    local pausedWord = 'paused on ' .. tostring(self.me) .. ' (by hand)'
    for id, r in pairs(self.reqs) do
        if r.kind == 'summon' then
            if not r.done then
                local v = self.runner:view()
                local st = r.parked or ((v.active and v.active.name == r.job) and (v.active.status ~= '' and v.active.status or 'summoning')
                    or ('queued' .. (v.active and (' behind ' .. v.active.name) or '')))
                if held then st = pausedWord end
                st = string.format('%s (%d of %d made)', st, r.made, r.n)
                if st ~= r.status or t - r.beat >= Handoff.HEARTBEAT_MS then
                    r.status, r.beat = st, t
                    self.peers:send(r.peer, 'working', id, Peers.encode(st), self:count(r.item))
                end
            end
        elseif r.kind == 'order' then
            if not r.done then
                local v = self.runner:view()
                local st = (v.active and v.active.name == r.job) and (v.active.status ~= '' and v.active.status or 'working')
                    or ('queued' .. (v.active and (' behind ' .. v.active.name) or ''))
                if held then st = pausedWord end
                if st ~= r.status or t - r.beat >= Handoff.HEARTBEAT_MS then
                    r.status, r.beat = st, t
                    self.peers:send(r.peer, 'working', id, Peers.encode(st))
                end
            end
        elseif r.state ~= 'giving' and not r.done and (t - r.beat >= Handoff.HEARTBEAT_MS or (held and not r.saidHeld)) then
            r.beat, r.saidHeld = t, held
            self.peers:send(r.peer, 'coming', id, Peers.encode(lower(self.zone())), held and Peers.encode(pausedWord) or r.state)
        end
    end
end

function Handoff:set_state(id, r, state)
    r.state, r.beat = state, self.now()
    self.peers:send(r.peer, 'coming', id, Peers.encode(lower(self.zone())), state)
end

function Handoff:give_job(id, to, item, n)
    local h = self
    local r = self.reqs[id]
    local function fail(res, say)
        r.done = true
        if not r.cancelled then h.peers:send(to, 'failed', id, Peers.encode(say or R.describe(res))) end
        return res
    end
    return {
        name = string.format('Give %d %s to %s', n, item, to),
        usesToon = true,
        execute = function(ctx)
            if r.cancelled then return R.fail('cancelled', to .. ' gave up: ' .. r.cancelled) end
            if lower(h.zone()) ~= r.zone then
                h:set_state(id, r, 'travelling')
                if not h.travel:path(r.zone) then
                    return fail(R.fail('no way there', string.format('travel.ini has no way from %s to %s', lower(h.zone()), r.zone)))
                end
                local t = h.travel:go(ctx, r.zone)
                if not t.ok then return fail(t) end
            end
            -- the same short name, but the crafter in the AFK mirror and we not (or the other way): the Exit
            -- Portal tells them apart (2.41.1 log: Antilerd walked to Mortician's spot in Marr while Mortician
            -- stood in Marr's mirror - "not in freeporttemple", twice)
            if r.mirror ~= nil and h.travel.in_mirror and h.travel:in_mirror() ~= r.mirror then
                if r.mirror then
                    h:set_state(id, r, 'travelling')
                    h.log.info('%s is in the AFK mirror of %s - going in', to, r.zone)
                    local m = h.travel:enter_mirror(ctx)
                    if not m.ok then return fail(m) end
                else
                    h:set_state(id, r, 'travelling')
                    h.log.info('%s is in %s itself, not its AFK mirror - going out', to, r.zone)
                    local m = h.travel:leave_mirror(ctx)
                    if not m.ok then return fail(m) end
                end
            end
            -- first to where the crafter said it stands; its spawn is only kept up to date once we are near
            if r.loc and h.nav.pos then
                local mx, my, mz = h.nav:pos()
                local away = math.sqrt((mx - r.loc[2]) ^ 2 + (my - r.loc[1]) ^ 2 + (mz - r.loc[3]) ^ 2)
                if away > Handoff.NAV_DIST + 5 then
                    h:set_state(id, r, 'walking')
                    local g = h.nav:go_loc(ctx, r.loc[1], r.loc[2], r.loc[3], Handoff.NAV_DIST)
                    if not g.ok then return fail(g) end
                end
            end
            local s, e = h.spawns:await(ctx, to, function() return h.spawns:find_pc(to) end)
            if e then return e end
            if not s then return fail(R.fail('not here', to .. ' is not in ' .. r.zone)) end
            if s.distance > Handoff.NAV_DIST then
                h:set_state(id, r, 'walking')
                local g = h.nav:go_spawn(ctx, s.id, Handoff.NAV_DIST)
                if not g.ok then return fail(g) end
            end
            r.state = 'giving'
            h.peers:send(to, 'arrived', id)
            local res = h.trade:give(ctx, s.id, item, n, {
                loaded = function(k, units) h.peers:send(to, 'loaded', id, k, units) end,
                accepted = function(k) return r.accepted[k] == true end,
                got = function(k) return r.got[k] == true end,
                cancelled = function() return r.cancelled end,
            })
            if not res.ok then return fail(res) end
            r.done = true
            h:hold(to, item, -res.value.given)
            return R.ok({ summary = string.format('gave %d %s to %s in %d trade(s)', res.value.given, item, to, res.value.trades) })
        end,
        cleanup = function(ctx)
            local c = h.trade:cancel(ctx)
            h.nav:stop(ctx)
            local s = h.cursor:stow(ctx)
            if not r.done and not r.cancelled then h.peers:send(to, 'failed', id, Peers.encode('worker stopped')) end
            h.reqs[id] = nil
            h:unpark()   -- a summon order waiting for bag room carries on
            if not c.ok then return c end
            return s
        end,
    }
end

-- How many of an item this character holds (bags).
function Handoff:count(item)
    local inv = self.makeEnv and self.makeEnv.blocks and self.makeEnv.blocks.inventory
    return inv and inv:count(item) or 0
end

function Handoff:on_summon(from, id, n, item)
    if not self:serves(from) then
        self.log.info('%s asked for %s, but this worker works for %s - ignored', from, item, self.crafter)
        return
    end
    if not n or n < 1 or item == '' then
        self.log.warn('Bad summon order from %s: %s %s', from, tostring(n), item)
        return self.peers:send(from, 'answer', id, 'no', Peers.encode('bad order'))
    end
    local uz = self:unsafe()
    if uz then
        self.log.warn('%s orders %d %s ahead - refused: we are in %s, not a safe zone', from, n, item, uz)
        return self.peers:send(from, 'answer', id, 'no', Peers.encode('in ' .. uz .. ', not a safe zone'))
    end
    -- what it already holds counts: only the rest is cast (it gives those first) - less what it holds for another
    -- crafter (2.44.0)
    local others = self:reserved(item, from)
    local held = math.max(0, self:count(item) - others)
    if others > 0 then self.log.info('%d %s held for other crafters - not counted for %s', others, item, from) end
    local r = { peer = from, kind = 'summon', beat = self.now(), n = n, made = math.min(n, held), item = item }
    -- held for this crafter: at least what this order counts as made already (never counted twice)
    local mine = (self.holding or {})[lower(from) .. '|' .. lower(item)] or 0
    if r.made > mine then self:hold(from, item, r.made - mine) end
    self.reqs[id] = r
    self.log.info('%s orders %d %s ahead (summoned between everything else) - %d held already, %d to cast', from, n, item,
        held, n - r.made)
    self:queue_summon(id, r)
end

-- Back in the queue: a summon order waiting for bag room, after a give.
function Handoff:unpark()
    for id, r in pairs(self.reqs) do
        if r.kind == 'summon' and r.parked and not r.done and not r.cancelled then
            self.log.info('Summon: room in the bags again - %s carries on (%d of %d made)', r.item, r.made, r.n)
            self:queue_summon(id, r)
        end
    end
end

function Handoff:end_summon(id, r, res)
    r.done = true
    self.reqs[id] = nil
    if res.ok then self.peers:send(r.peer, 'made', id, self:count(r.item))
    elseif not r.cancelled then self.peers:send(r.peer, 'failed', id, Peers.encode(R.describe(res))) end
    return res
end

function Handoff:queue_summon(id, r)
    local h = self
    r.parked = nil
    local job = { name = string.format('Summon %d %s for %s', r.n, r.item, r.peer), usesToon = true, summon = true }
    r.job = job.name
    -- something to step aside for: a delivery or an order - never another summon order (2.41.7 log: Ejtou's two
    -- summon orders stepped aside for each other 300+ times a second, and nothing was cast)
    local function waiting()
        for _, j in ipairs(h.runner.queue) do if not j.summon then return true end end
        return false
    end
    job.execute = function(ctx)
        r.stepped = false
        while r.made < r.n do
            if r.cancelled then return R.fail('cancelled', r.peer .. ' called it off: ' .. r.cancelled) end
            if waiting() then
                -- deliveries and orders first: behind them in the queue again
                h.log.info('Summon: %s - %d of %d made; something else is queued, it goes first', r.item, r.made, r.n)
                r.stepped = true
                h:queue_summon(id, r)
                return R.ok({ summary = string.format('%d of %d %s made, stepped aside', r.made, r.n, r.item) })
            end
            local base = h:count(r.item)
            local round = h.make.summon_round(h.makeEnv, r.item, base, r.n - r.made, {
                name = job.name, yield = waiting,
                planned = function(plan)
                    if #plan.problems > 0 then return R.fail('cannot get it', table.concat(plan.problems, '; ')) end
                    if not r.answered then
                        r.answered = true
                        h.peers:send(r.peer, 'answer', id, 'yes', Peers.encode(plan_words(plan)))
                    end
                    return R.ok()
                end,
            })
            local res = round.execute(ctx)
            local c = round.cleanup(ctx)
            local got = math.max(0, h:count(r.item) - base)
            r.made = r.made + got
            h:hold(r.peer, r.item, got)
            h.log.info('Summon: %s - made %d this round, %d of %d', r.item, got, r.made, r.n)
            if not res.ok then
                if res.why == 'stopped' then return res end
                if res.why == 'bags full' then
                    r.parked = 'waiting for bag room'
                    h.log.info('Summon: %s - bags full, waiting until some are given (%s)', r.item, R.describe(res))
                    return R.ok({ summary = string.format('%d of %d %s made, bags full', r.made, r.n, r.item) })
                end
                if not r.answered then
                    r.answered = true
                    h.peers:send(r.peer, 'answer', id, 'no', Peers.encode(R.describe(res)))
                end
                return h:end_summon(id, r, res)
            end
            if not c.ok then return h:end_summon(id, r, c) end
            if got == 0 and not res.value.yielded then
                return h:end_summon(id, r, R.fail('made nothing', string.format('a round of %s made none', r.item)))
            end
        end
        return h:end_summon(id, r, R.ok({ summary = string.format('made %d %s, holding %d', r.made, r.item, h:count(r.item)) }))
    end
    job.cleanup = function()
        -- stopped here (not stepped aside, waiting for room or done): the crafter is told
        if not r.done and not r.stepped and not r.parked and not r.cancelled and r.jobId == job.id then
            r.done = true
            h.peers:send(r.peer, 'failed', id, Peers.encode('worker stopped'))
            h.reqs[id] = nil
        end
        return R.ok()
    end
    r.jobId = self.runner:add(job)
end

-- ---------------------------------------------------------------- crafter

-- Summon orders: placed at Go for a whole job (engine/make order_ahead); passes take from them.
function Handoff:place_summon(worker, item, n)
    self.seq = self.seq + 1
    local id = string.format('%s-%d-%d', Peers.encode(self.me), self.now(), self.seq)
    local r = { peer = worker, kind = 'summon', heard = self.now(), at = self.now(), n = n, item = item, taken = 0 }
    self.reqs[id] = r
    self.summons[lower(worker) .. '|' .. lower(item)] = { id = id, r = r }
    self.log.info('Ordering ahead: %d %s from %s (summoned between its other work; request %s)', n, item, worker, id)
    self.peers:send(worker, 'summon', id, n, Peers.encode(item))
    return id, r
end

-- The open summon order for this worker and item, if any. Without a worker: any worker's for the item (the one
-- that already holds the most) - a plan may pick another caster than the one ordered ahead (2.41.7 log: Emerald
-- ordered ahead from Ejtou, who held 875, then ordered again from Shylain, who had to cast 56 times).
function Handoff:summon_for(worker, item)
    if worker then
        local s = self.summons[lower(worker) .. '|' .. lower(item)]
        if not s then return nil end
        if s.r.answer == 'no' or s.r.cancelled then return nil end
        return s
    end
    local best
    for _, s in pairs(self.summons) do
        if lower(s.r.item) == lower(item) and s.r.answer ~= 'no' and not s.r.cancelled then
            if not best or (s.r.have or 0) > (best.r.have or 0) then best = s end
        end
    end
    return best
end

-- Every open summon order: worker, item, n, have, status (the Workers tab).
function Handoff:summon_view()
    local out = {}
    for _, s in pairs(self.summons) do
        local r = s.r
        out[#out + 1] = { worker = r.peer, item = r.item, n = r.n, have = r.have, taken = r.taken, status = r.status,
                          done = r.made ~= nil, failed = r.cancelled or (r.answer == 'no' and r.why) or nil }
    end
    table.sort(out, function(a, b) return a.worker .. a.item < b.worker .. b.item end)
    return out
end

function Handoff:end_summons(why)
    for k, s in pairs(self.summons) do
        local r = s.r
        if r.made == nil and r.answer ~= 'no' and not r.cancelled then
            self.peers:send(r.peer, 'failed', s.id, Peers.encode(why or 'crafter done'))
            self.log.info('Called off: the rest of %s from %s (%d taken of %d ordered)', r.item, r.peer, r.taken, r.n)
        end
        self.reqs[s.id] = nil
        self.summons[k] = nil
    end
end

-- A pass takes `need` from a summon order: at once when the worker holds that many, else it waits on its word
-- (its count comes with each 'working'). Ended with fewer: R.fail('summon short') - the pass orders them instead.
function Handoff:take_summoned(ctx, s, worker, item, need, st)
    local r = s.r
    local function ended() return r.made ~= nil or r.answer == 'no' or r.cancelled ~= nil end
    if (r.have or 0) < need and not ended() then
        r.heard = math.max(r.heard, self.now() - Handoff.HEARTBEAT_MS)
        self.log.info('Waiting on %s: %d %s made so far, this pass needs %d (%d ordered ahead)', worker, r.have or 0, item, need, r.n)
        local res = self:await(ctx, r, worker, function()
            ctx:status(string.format('Waiting on %s: %d of %d %s', worker, r.have or 0, need, item))
            return (r.have or 0) >= need or ended()
        end)
        if not res.ok and res.why ~= 'cancelled' then return res end
    end
    local have = r.have or 0
    if have < need then
        return R.fail('summon short', string.format('%s holds %d %s, this pass needs %d%s', worker, have, item, need,
            r.cancelled and (' (' .. r.cancelled .. ')') or (r.answer == 'no' and (' (' .. (r.why or 'cannot') .. ')') or '')))
    end
    self.log.info('%s holds %d %s made ahead - asking it to bring %d', worker, have, item, need)
    ctx:status(string.format('Fetching %d %s from %s', need, item, worker))
    local f = self:fetch(ctx, worker, item, need, st)
    r.taken = r.taken + (f.ok and f.value.taken or f.taken or 0)
    return f
end

-- What we took from a worker, by any request (a summon order's, an order of its own): its summon order for the
-- item holds that many fewer (2.42.13 Lopan log: pass 1 ordered 128 Imbued Rose Quartz on its own and took them
-- out of Ejtou's 130; the summon order still said 125 held, so pass 2 asked for 19 and Ejtou had 2).
function Handoff:took_from(worker, item, n)
    if not n or n <= 0 then return end
    local s = self.summons[lower(worker) .. '|' .. lower(item)]
    if not s or s.r.have == nil then return end
    local was = s.r.have
    s.r.have = math.max(0, was - n)
    self.log.debug('  summon order %s: %s holds %d %s (was %d, %d taken)', s.id, worker, s.r.have, item, was, n)
end

-- Wait where we stand until done() is true. The worker says something at least every HEARTBEAT_MS; silence
-- for SILENT_MS means it has stopped (or never started).
function Handoff:await(ctx, r, worker, done)
    while not done() do
        if r.cancelled then return R.fail('cancelled', worker .. ' gave up: ' .. r.cancelled) end
        local w = ctx:wait(1000, function() return done() or r.cancelled ~= nil end)
        if not w.ok and w.why ~= 'timeout' then return w end
        if not done() and not r.cancelled and self.now() - r.heard >= Handoff.SILENT_MS then
            local last = r.where or r.status
            return R.fail('quiet', string.format('no word from %s for %ds%s', worker, Handoff.SILENT_MS / 1000,
                last and (' (last: ' .. last .. ')') or ' (never answered)'))
        end
    end
    if r.cancelled then return R.fail('cancelled', worker .. ' gave up: ' .. r.cancelled) end
    return R.ok()
end

-- Ask the worker to come with n and take the trades; tried once more for what is missing. `st.active` is the
-- open request (for cleanup).
function Handoff:fetch(ctx, worker, item, n, st)
    local taken = 0
    local s = self.nav:stop(ctx)
    if not s.ok then return s end
    for try = 1, Handoff.TRIES do
        self.seq = self.seq + 1
        local id = string.format('%s-%d-%d', Peers.encode(self.me), self.now(), self.seq)
        local r = { peer = worker, loaded = {}, gotTotal = 0, heard = self.now() }
        self.reqs[id], st.active = r, id
        local want = n - taken
        local zone = lower(self.zone())
        self.log.info('Asking %s to bring %d %s to %s (request %s)', worker, want, item, zone, id)
        -- where we stand: a far worker walks there first (its view of our spawn is not kept up to date)
        if self.nav.pos then
            local mx, my, mz = self.nav:pos()
            -- and whether we stand in the zone's AFK mirror (same short name)
            local place = (self.travel and self.travel.in_mirror) and (self.travel:in_mirror() and 'mirror' or 'main') or nil
            local y, x, z = string.format('%.2f', my), string.format('%.2f', mx), string.format('%.2f', mz)
            if place then self.peers:send(worker, 'come', id, want, Peers.encode(item), Peers.encode(zone), y, x, z, place)
            else self.peers:send(worker, 'come', id, want, Peers.encode(item), Peers.encode(zone), y, x, z) end
        else
            self.peers:send(worker, 'come', id, want, Peers.encode(item), Peers.encode(zone))
        end
        local t0 = self.now()
        local res = self:await(ctx, r, worker, function() return r.arrived end)
        if res.ok then
            self.log.info('%s is here after %.1fs', worker, (self.now() - t0) / 1000)
            res = self.trade:take(ctx, item, want, {
                loaded = function(k) return r.loaded[k] end,
                accept = function(k) self.peers:send(worker, 'accepted', id, k) end,
                got = function(k, units) r.gotTotal = r.gotTotal + units; self.peers:send(worker, 'got', id, k, units) end,
                cancelled = function() return r.cancelled end,
            })
        end
        taken = taken + r.gotTotal
        self:took_from(worker, item, r.gotTotal)
        st.active = nil
        self.reqs[id] = nil
        if res.ok then return R.ok({ taken = taken }) end
        if not r.cancelled then self.peers:send(worker, 'failed', id, Peers.encode(R.describe(res))) end
        local c = self.trade:cancel(ctx)
        if not c.ok then return c end
        local hopeless = NO_RETRY[res.why] or try == Handoff.TRIES
        for _, txt in ipairs(NO_RETRY_TEXT) do
            if r.cancelled and r.cancelled:find(txt, 1, true) then hopeless = true end
        end
        if hopeless then
            res.detail = string.format('%s (got %d of %d)', res.detail or res.why, taken, n)
            res.taken = taken
            return res
        end
        self.log.warn('Fetch: %s - trying once more for the %d still missing', R.describe(res), n - taken)
    end
end

-- After a stop or failure mid-fetch: tell the worker, close any trade window, stow the cursor.
function Handoff:release(ctx, st)
    if st.active then
        local r = self.reqs[st.active]
        if r then self.peers:send(r.peer, 'failed', st.active, Peers.encode('crafter stopped')) end
        self.reqs[st.active] = nil
        st.active = nil
    end
    local c = self.trade:cancel(ctx)
    local s = self.cursor:stow(ctx)
    if not c.ok then return c end
    return s
end

local function crafter_cleanup(h, worker, st)
    return function(ctx)
        if st.active then
            h.peers:send(worker, 'failed', st.active, Peers.encode('crafter stopped'))
            h.reqs[st.active] = nil
            st.active = nil
        end
        local c = h.trade:cancel(ctx)
        local s = h.cursor:stow(ctx)
        if not c.ok then return c end
        return s
    end
end

function Handoff:fetch_job(worker, item, n)
    local h, st = self, {}
    return {
        name = string.format('Fetch %d %s from %s', n, item, worker),
        usesToon = true,
        execute = function(ctx)
            local res = h:fetch(ctx, worker, item, n, st)
            if not res.ok then return res end
            return R.ok({ summary = string.format('got %d %s from %s', res.value.taken, item, worker) })
        end,
        cleanup = crafter_cleanup(h, worker, st),
    }
end

-- Orders in three parts, so a make can ask early and collect late:
--   place_order(worker, item, n) -> id, r     sends ask; the answer and updates land in r as they come
--   collect(ctx, id, r, worker, item, n, st)  waits for made (or no), then fetches them (st.active for cleanup)
--   drop_order(id, why)                       tell the worker we no longer want it
function Handoff:place_order(worker, item, n)
    self.seq = self.seq + 1
    local id = string.format('%s-%d-%d', Peers.encode(self.me), self.now(), self.seq)
    local r = { peer = worker, heard = self.now(), at = self.now() }
    self.reqs[id] = r
    self.log.info('Ordering %d %s from %s (request %s)', n, item, worker, id)
    self.peers:send(worker, 'ask', id, n, Peers.encode(item))
    return id, r
end

function Handoff:drop_order(id, why)
    local r = self.reqs[id]
    if not r then return end
    self.reqs[id] = nil
    if r.made == nil and r.answer ~= 'no' and not r.cancelled then
        self.peers:send(r.peer, 'failed', id, Peers.encode(why or 'crafter stopped'))
    end
end

function Handoff:collect(ctx, id, r, worker, item, n, st)
    if r.made == nil and r.answer ~= 'no' then
        -- it may have been working a long while unheard by an await: the clock starts now
        r.heard = math.max(r.heard, self.now() - Handoff.HEARTBEAT_MS)
        ctx:status(string.format('Waiting on %s for %d %s', worker, n, item))
        local res = self:await(ctx, r, worker, function() return r.made ~= nil or r.answer == 'no' end)
        if not res.ok then self:drop_order(id, res.why == 'stopped' and 'crafter stopped' or R.describe(res)); return res end
    end
    self.reqs[id] = nil
    if r.answer == 'no' then return R.fail('declined', worker .. ' cannot: ' .. (r.why or '?')) end
    if r.cancelled then return R.fail('cancelled', worker .. ' gave up: ' .. r.cancelled) end
    self.log.info('%s has %d %s (%.1fs after the order) - asking it to bring %d', worker, r.made, item, (self.now() - r.at) / 1000, n)
    ctx:status(string.format('Fetching %d %s from %s', n, item, worker))
    return self:fetch(ctx, worker, item, n, st)
end

-- Ask the worker to get n, wait on its word while it works, then fetch them.
function Handoff:order_job(worker, item, n)
    local h, st = self, {}
    local oid
    return {
        name = string.format('Order %d %s from %s', n, item, worker),
        usesToon = true,
        execute = function(ctx)
            local id, r = h:place_order(worker, item, n)
            oid = id
            local f = h:collect(ctx, id, r, worker, item, n, st)
            oid = nil
            if not f.ok then return f end
            return R.ok({ summary = string.format('%s got and brought %d %s', worker, f.value.taken, item) })
        end,
        cleanup = function(ctx)
            if oid then h:drop_order(oid, 'crafter stopped'); oid = nil end
            return crafter_cleanup(h, worker, st)(ctx)
        end,
    }
end

return Handoff
