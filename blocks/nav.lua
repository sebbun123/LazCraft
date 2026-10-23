-- Nav: the only block that moves the toon.
--   go_spawn(ctx, id, dist)   travel to within `dist` of a spawn, confirmed by measuring the distance.
--                             R.ok({ ms, distance, tries })
--   go_loc(ctx, y, x, z, dist)  the same for a spot (a station's location)
--   active()                  is MQ2Nav moving us right now
--   stop(ctx)                 stop moving, confirmed
--
-- Rules it keeps:
--   * Arrival is measured (3D distance to the spawn), never assumed from nav ending.
--   * Nav starts in the client, so it shows at once. A nav that did not start, ended short, or stopped
--     making progress is sent again, up to 3 times. No fixed waits stand in for this.
--   * "Stuck" means our own position has not moved for STUCK_MS while nav says it is active. Every stuck
--     spot is also written to logs/navstuck.log (kept across runs) - where to add a hub next.
--   * Pause stops the toon; Resume sends the nav again. Stop and cleanup stop it.
--   * In a zone listed in data/nav.ini every walk goes through its route (blocks/routes.lua): docks, the
--     pocket, hubs, then a merchant's spot. Each leg is a walk of its own and logged. A leg that cannot be
--     reached is said and the walk goes on to the next one (the destination's own walk decides).
local R = require('core.result')
local Routes = require('blocks.routes')

local Nav = {}
Nav.__index = Nav

Nav.TRIES = 3
Nav.STUCK_MS = 3000     -- not moving this long while nav is active = stuck
Nav.SLACK = 3           -- arriving within dist + this counts as there
Nav.MAX_MS = 180000     -- safety net for one trip; stuck detection normally ends a bad trip long before
Nav.SPOT_DIST = 15      -- a merchant's spot counts as reached this close (the old LazCraft's)

local NOLOG = { debug = function() end, info = function() end, warn = function() end }

-- deps: mq, spawns, log, nav (cfg.nav from data/nav.ini), stuck(line) (appends a line to logs/navstuck.log),
--       arrive (cfg.travel.arrive: where to go first in a zone whose zone-in snags)
function Nav.new(deps)
    local n = setmetatable({ mq = deps.mq, spawns = deps.spawns, log = deps.log or NOLOG, navCfg = deps.nav,
                             stuckLog = deps.stuck, arrive = deps.arrive or {} }, Nav)
    -- the zone we start in counts as visited: the arrival spot is for after zoning in, not for wherever the
    -- character stood when LazCraft started (2.41.3 log: Shela, started by the merchants, walked 408 to Tomas
    -- before buying - as the old LazCraft, which went to Tomas only after Marr's Calling)
    local ok, z = pcall(function() return deps.mq.TLO.Zone.ShortName() end)
    if ok and z and z ~= '' then n.zoneSeen = z:lower(); n.arrivedIn = z:lower() end
    return n
end


function Nav:send(cmd)
    self.log.debug('  send: %s', cmd)
    self.mq.cmd(cmd)
end

function Nav:active() return self.mq.TLO.Navigation.Active() == true end

function Nav:pos()
    local Me = self.mq.TLO.Me
    return Me.X() or 0, Me.Y() or 0, Me.Z() or 0
end

function Nav:stop(ctx)
    if not self:active() then return R.ok() end
    self:send('/nav stop')
    local w = ctx:wait(1000, function() return not self:active() end)
    self.log.debug('  nav stopped: %s after %dms', w.ok and 'yes' or w.why, w.ms or 0)
    if w.ok then return R.ok() end
    if w.why == 'timeout' then return R.fail('nav stuck on', 'nav would not stop') end
    return w
end

local function loc_goal(self, y, x, z, dist, what)
    local where = string.format('%.2f %.2f %.2f', y, x, z)
    return {
        what = what or ('loc ' .. where),
        path = 'loc ' .. where,
        cmd = string.format('/nav loc %s distance=%d', where, dist),
        away = function()
            local mx, my, mz = self:pos()
            return math.sqrt((mx - x) ^ 2 + (my - y) ^ 2 + (mz - z) ^ 2)
        end,
    }
end

-- First walk in a zone with an arrival spot (travel.ini [Arrive], e.g. Marr's Soulbinder Tomas off the fountain):
-- go there first, straight (no route rules), unless already within ARRIVE_SKIP. Once per visit to the zone:
-- zoned() (travel, after every zone change and the AFK mirror) starts a new visit; so does a zone change seen
-- on the next walk. The zone LazCraft starts in is not a new visit (2.41.4). Crafter and worker alike.
Nav.ARRIVE_SKIP = 30
Nav.ARRIVE_DIST = 15
Nav.ARRIVE_SPAWN_MS = 5000
function Nav:zoned() self.arrivedIn, self.zoneSeen = nil, nil end

function Nav:arrive_first(ctx)
    local zn = (self.mq.TLO.Zone.ShortName() or ''):lower()
    if zn ~= self.zoneSeen then self.zoneSeen, self.arrivedIn = zn, nil end
    if self.arrivedIn == zn then return R.ok() end
    self.arrivedIn = zn
    local spot = self.arrive[zn]
    if not spot then return R.ok() end
    local goal, target
    if spot.npc then
        local s
        local w = ctx:wait(Nav.ARRIVE_SPAWN_MS, function() s = self.spawns:find(spot.npc); return s ~= nil end)
        if not w.ok and w.why ~= 'timeout' then return w end
        if not s then self.log.warn('Nav: %s is not in %s - going on without it', spot.npc, zn); return R.ok() end
        if s.distance <= Nav.ARRIVE_SKIP then return R.ok() end
        self.log.info('Nav: first to %s (%s\'s zone-in snags), %.0f away', spot.npc, zn, s.distance)
        goal = { what = s.name, path = 'id ' .. s.id, cmd = string.format('/nav id %d distance=%d', s.id, Nav.ARRIVE_DIST),
                 away = function() local sp = self.spawns:get(s.id); return sp and sp.distance end }
        target = s.y and { s.y, s.x, s.z }
    else
        goal = loc_goal(self, spot.loc[1], spot.loc[2], spot.loc[3], Nav.ARRIVE_DIST)
        local d = goal.away()
        if d <= Nav.ARRIVE_SKIP then return R.ok() end
        self.log.info('Nav: first to %.1f %.1f %.1f (%s\'s zone-in snags), %.0f away', spot.loc[1], spot.loc[2], spot.loc[3], zn, d)
        target = spot.loc
    end
    -- the zone's avoid boxes (nav.ini Avoid<n>, Marr's fountain) hold for this walk too (2.42.13)
    local z = self.navCfg and self.navCfg[zn]
    if z and target then
        local mx, my, mz = self:pos()
        local legs = Routes.avoid(z, { my, mx, mz }, target)
        for i, l in ipairs(legs) do
            self.log.info('Nav: %s first (%d of %d, %.2f %.2f %.2f)', l.why, i, #legs, l[1], l[2], l[3])
            local lr = self:go(ctx, loc_goal(self, l[1], l[2], l[3], Routes.LEG_NEAR, l.why), Routes.LEG_NEAR)
            if not lr.ok and lr.why == 'stopped' then return lr end
            if not lr.ok then self.log.warn('Nav: %s: %s - going on', l.why, R.describe(lr)) end
        end
    end
    local r = self:go(ctx, goal, Nav.ARRIVE_DIST)
    if not r.ok and r.why == 'stopped' then return r end
    if not r.ok then self.log.warn('Nav: did not reach the arrival spot (%s) - going on', R.describe(r)) end
    return R.ok()
end

-- Travel to within `dist` of a spawn (by id).
function Nav:go_spawn(ctx, id, dist)
    local s = self.spawns:get(id)
    local goal = {
        what = s and s.name or ('spawn ' .. id),
        path = 'id ' .. id,
        cmd = string.format('/nav id %d distance=%d', id, dist),
        away = function() local sp = self.spawns:get(id); return sp and sp.distance end,
    }
    -- a player (a worker walking to its crafter) is walked to, never to a merchant's spot
    return self:routed(ctx, goal, dist, s and s.y and { s.y, s.x, s.z, name = s.name }, s and not s.pc)
end

-- Travel to within `dist` of a spot (y, x, z, the order /nav loc and the configs use).
function Nav:go_loc(ctx, y, x, z, dist)
    return self:routed(ctx, loc_goal(self, y, x, z, dist), dist, { y, x, z }, false)
end

-- These end a walk; anything else from a leg (did not arrive, no path, too long) is said and passed.
local LEG_MOVES_ON = { ['did not arrive'] = true, ['no path'] = true, ['nav too long'] = true }

-- The zone's route (data/nav.ini) first, then the walk itself.
function Nav:routed(ctx, goal, dist, dest, spawn)
    local zn = (self.mq.TLO.Zone.ShortName() or ''):lower()
    local z = self.navCfg and self.navCfg[zn]
    local d = goal.away()
    if d and d > dist + Nav.SLACK then
        local a = self:arrive_first(ctx)
        if not a.ok then return a end
        d = goal.away()
    end
    if not z or not dest or not d or d <= dist + Nav.SLACK then return self:go(ctx, goal, dist) end
    -- a broken mesh across a bridge (nav.ini Bridge=): no path from this side - cross it first
    if z.bridge and self.mq.TLO.Navigation.PathExists(string.format('loc %.2f %.2f %.2f', dest[1], dest[2], dest[3]))() ~= true then
        local c = self:cross_bridge(ctx, z.bridge)
        if not c.ok then return c end
    end
    local mx, my, mz = self:pos()
    local plan = Routes.plan(z, { my, mx, mz }, dest, spawn)
    for i, l in ipairs(plan.legs) do
        self.log.info('Nav: %s first (%d of %d, %.2f %.2f %.2f)', l.why, i, #plan.legs, l[1], l[2], l[3])
        local r = self:go(ctx, loc_goal(self, l[1], l[2], l[3], Routes.LEG_NEAR, l.why), Routes.LEG_NEAR)
        if not r.ok then
            if not LEG_MOVES_ON[r.why] then return r end
            self.log.warn('Nav: did not reach %s (%s) - going on', l.why, r.detail or r.why)
        end
    end
    if plan.spot then
        local sp = plan.spot
        self.log.info('Nav: opening from %s (%.2f %.2f %.2f)%s, not walking onto the counter', sp.name,
            sp[1], sp[2], sp[3], sp.crouch and ', crouching if stuck' or '')
        local g = loc_goal(self, sp[1], sp[2], sp[3], Nav.SPOT_DIST, sp.name)
        g.crouch = sp.crouch
        return self:go(ctx, g, Nav.SPOT_DIST)
    end
    return self:go(ctx, goal, dist)
end

-- Across a bridge the mesh does not cover (the old LazCraft's Thurgadin crossing, proven in game): walk to its near
-- edge, face the heading and hold forward until within BRIDGE_DONE of the far edge. Stuck BRIDGE_TOGGLE_MS:
-- crouch (slips a height snag), then stand again, in turn; no ground gained for BRIDGE_STUCK_MS ends it.
Nav.BRIDGE_DONE = 10
Nav.BRIDGE_TOGGLE_MS = 2000
Nav.BRIDGE_STUCK_MS = 8000
Nav.BRIDGE_MS = 45000
function Nav:cross_bridge(ctx, b)
    self.log.info('Nav: no path from this side of the bridge - walking to its near edge, then running across')
    local g = self:go(ctx, loc_goal(self, b.near[1], b.near[2], b.near[3], 15, 'the bridge near edge'), 15)
    if not g.ok then return g end
    local function far()
        local x, y = self:pos()
        return math.sqrt((y - b.far[1]) ^ 2 + (x - b.far[2]) ^ 2)
    end
    if far() <= Nav.BRIDGE_DONE then return R.ok() end
    local face = string.format('/face fast heading %.2f', b.heading)
    self:send(face)
    self:send('/keypress forward hold')
    ctx:while_paused(function() self:send('/keypress forward') end, function() self:send(face); self:send('/keypress forward hold') end)
    local now = self.mq.gettime
    local last, lastGain, lastToggle, ducked = far(), now(), now(), false
    local w = ctx:wait(Nav.BRIDGE_MS, function()
        local d = far()
        if d <= Nav.BRIDGE_DONE then return true end
        local t = now()
        if d < last - 0.5 then
            last, lastGain = d, t
            if ducked then self:send('/keypress duck'); ducked = false end
        elseif t - lastToggle >= Nav.BRIDGE_TOGGLE_MS then
            self:send('/keypress duck')
            ducked = not ducked
            lastToggle = t
            self.log.info('Nav: stuck on the bridge - %s', ducked and 'crouching' or 'standing back up')
            self:send(face)
        end
        return t - lastGain >= Nav.BRIDGE_STUCK_MS
    end)
    self:send('/keypress forward')
    ctx:while_paused()
    if ducked then self:duck(ctx, false) end
    if not w.ok and w.why ~= 'timeout' then return w end
    local d = far()
    if d > 15 then
        self:note_stuck('the bridge far edge')
        return R.fail('bridge', string.format('did not get across the bridge (%.0f from its far edge)', d))
    end
    self.log.info('Nav: across the bridge (%.1f from its far edge)', d)
    return R.ok()
end

function Nav:note_stuck(what)
    if not self.stuckLog then return end
    local x, y, z = self:pos()
    local TLO = self.mq.TLO
    self.stuckLog(string.format('%s | %s | %s | stuck=%.2f %.2f %.2f | dest=%s', os.date('%Y-%m-%d %H:%M:%S'),
        tostring(TLO.Me.Name and TLO.Me.Name() or '?'), tostring(TLO.Zone.ShortName() or '?'), y, x, z, what))
end

-- Crouch (the old LazCraft's way past a low spot by a counter): on, and back up, each confirmed.
function Nav:duck(ctx, on)
    local function ducking() return self.mq.TLO.Me.Ducking() == true end
    if ducking() == on then return end
    self:send('/keypress duck')
    local w = ctx:wait(1000, function() return ducking() == on end)
    self.log.debug('  %s: %s after %dms', on and 'crouched' or 'stood up', w.ok and 'yes' or w.why, w.ms or 0)
end

-- The one travel loop: start, watch for arrival or no progress, measure, send again if short.
function Nav:go(ctx, goal, dist)
    local away = goal.away
    local d = away()
    if not d then return R.fail('gone', goal.what .. ' is not in the zone') end
    if d <= dist + Nav.SLACK then
        self.log.debug('  already there (%.1f away)', d)
        return R.ok({ ms = 0, distance = d, tries = 0 })
    end
    if self.mq.TLO.Navigation.PathExists(goal.path)() ~= true then
        return R.fail('no path', string.format('no nav path to %s (%.0f away)', goal.what, d))
    end

    local cmd = goal.cmd
    local t0 = self.mq.gettime()
    local lastX, lastY, lastZ, lastMove = 0, 0, 0, 0
    local function moved_now()
        lastX, lastY, lastZ = self:pos()
        lastMove = self.mq.gettime()
    end
    ctx:while_paused(
        function() self:send('/nav stop') end,
        function() self:send(cmd); moved_now() end)
    local ducked = false
    local function finish(res)
        ctx:while_paused()
        if ducked then self:duck(ctx, false) end
        return res
    end

    local tries = 0
    while true do
        tries = tries + 1
        self:send(cmd)
        local started = ctx:wait(1, function() return self:active() end)
        if not started.ok and started.why ~= 'timeout' then self:stop(ctx); return finish(started) end
        if self:active() then
            self.log.debug('  nav started after %dms', started.ms or 0)
            moved_now()
            local w = ctx:wait(Nav.MAX_MS, function()
                if not self:active() then return true end
                local x, y, z = self:pos()
                if (x - lastX) ^ 2 + (y - lastY) ^ 2 + (z - lastZ) ^ 2 >= 1 then moved_now() end
                return self.mq.gettime() - lastMove >= Nav.STUCK_MS
            end)
            if not w.ok then
                self:stop(ctx)
                if w.why == 'timeout' then return finish(R.fail('nav too long', string.format('still travelling after %ds', Nav.MAX_MS / 1000))) end
                return finish(w)
            end
            if self:active() then
                local x, y, z = self:pos()
                self.log.warn('Nav: no progress for %dms at %.1f, %.1f, %.1f', Nav.STUCK_MS, y, x, z)
                self:note_stuck(goal.what)
                self:stop(ctx)
                if goal.crouch and not ducked then ducked = true; self:duck(ctx, true) end
            end
        else
            self.log.debug('  nav did not start')
        end
        d = away()
        if not d then return finish(R.fail('gone', goal.what .. ' left the zone')) end
        if d <= dist + Nav.SLACK then
            local ms = self.mq.gettime() - t0
            self.log.debug('  arrived %.1f away after %dms (%d tr%s)', d, ms, tries, tries == 1 and 'y' or 'ies')
            return finish(R.ok({ ms = ms, distance = d, tries = tries }))
        end
        if tries >= Nav.TRIES then
            return finish(R.fail('did not arrive', string.format('%.0f away after %d tries', d, tries)))
        end
        self.log.debug('  %.1f away; sending nav again (try %d)', d, tries + 1)
    end
end

return Nav
