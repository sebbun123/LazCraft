-- Travel: getting from this zone to another over the hops in travel.ini.
--   zone()                 this zone's short name (lower case)
--   path(to)               the hops from here to `to` (empty when already there), or nil when travel.ini has no way
--   go(ctx, to)            take every hop to `to`, each confirmed. R.ok({ hops, ms })
--   mirror                 true while in a zone's AFK mirror (same short name; set by enter_mirror, cleared by a hop)
--   in_mirror()            in an AFK mirror: its "Exit Portal" NPC is here (only the mirror has it - seen in Marr's,
--                          2.41.1), or we went in ourselves (mirror)
--   where()                this zone, "(AFK mirror)" when in one
--   enter_mirror(ctx)      into this zone's AFK mirror (travel.ini [Mirror]): R.ok() once in it, in game
--   leave_mirror(ctx)      out of it: walking into its Exit Portal ports us out (seen in game) - R.ok() once out, in game
--
-- Hops (data, travel.ini [<from>><to>]):
--   aa    AA=<name>             stand still, fire the AA once, leave the cast alone, the zone changes
--   say   Npc=<porter> Say=<kw>  target the porter, nav to it (arrival measured), /say the keyword
--   door  Door=<name> [Near=<y x z>]  nav near it (no Near: /doortarget first, then to the door's own spot),
--                                      /doortarget, /click left door
--   run   Near=<y x z> Heading=<h>  nav to Near, face the heading and run forward until the zone changes (a zone
--                                   line; the old LazCraft's Greater Faydark -> Northern Felwithe, proven there)
-- [Arrive] <zone>=<npc or y x z>: where to go first after zoning in (Marr's zone-in point snags).
--
-- Rules it keeps:
--   * A hop is done when the zone has changed and the client is in game again - never after a fixed wait.
--     Every wait has a cap, so a hop that does nothing fails with a reason instead of hanging.
--   * After zoning in: the navmesh is loaded before anything moves (a check, not a settle delay), then
--     the zone's arrival spot if travel.ini lists one.
--   * An AA is fired only when standing still and not casting: moving interrupts the cast (old LazCraft,
--     in game). It is fired once; a cast in progress is never fired again (that re-activated the AA and
--     interrupted it). It is fired again only if the cast never started or was interrupted.
--   * A porter is targeted before the nav to it (a /say right after /target is ignored - in game), and
--     spoken to once we have arrived. Saying the keyword again is safe, so it is said again if nothing happens.
--   * The AFK mirror has the same short name, so entering it is confirmed by the zoning itself: the client
--     leaving the game and coming back, or the "You have entered" message - whichever shows (logged).
--   * A door click is a toggle: it is only clicked again while we are still standing in the old zone with
--     nothing under way.
local R = require('core.result')
local Config = require('core.config')

local Travel = {}
Travel.__index = Travel

Travel.TRIES = 3
Travel.STILL_MS = 3000        -- stopping and finishing a cast before an AA
Travel.AA_READY_MS = 180000   -- an AA on cooldown: wait for it this long at most (logged)
Travel.CAST_START_MS = 1000   -- a fired AA shows as casting within this (seen in game: 82-322ms)
Travel.CAST_MS = 30000        -- a started cast has ended (or zoning begun) within this
Travel.TRIGGER_MS = 10000     -- after a /say or a door click, zoning has begun within this
Travel.ZONE_MS = 60000        -- zoning, start to in game in the new zone
Travel.MESH_MS = 15000        -- the new zone's navmesh is loaded within this
Travel.SPAWN_MS = 5000        -- an arrival-spot NPC appears within this after zoning in
Travel.TALK_DIST = 10         -- how close to a porter
Travel.DOOR_DIST = 10         -- how close to a door's Near spot
Travel.ARRIVE_SKIP = 30       -- already this close to the arrival spot: no need to go there
Travel.ARRIVE_DIST = 15

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local INTERRUPTED = { 'Your spell is interrupted#*#', 'Your casting has been interrupted#*#' }
local nextEvent = 0

function Travel.new(deps)
    local t = setmetatable({ mq = deps.mq, nav = deps.nav, spawns = deps.spawns, travel = deps.travel,
                             log = deps.log or NOLOG, interrupted = false }, Travel)
    for _, p in ipairs(INTERRUPTED) do
        nextEvent = nextEvent + 1
        deps.mq.event('lc_travel_' .. nextEvent, p, function() t.interrupted = true end)
    end
    nextEvent = nextEvent + 1
    deps.mq.event('lc_travel_' .. nextEvent, 'You have entered #*#', function() t.entered = true end)
    t.mirror = false
    return t
end

local function lower(s) return (s or ''):lower() end

function Travel:send(cmd)
    self.log.debug('  send: %s', cmd)
    self.mq.cmd(cmd)
end

function Travel:zone() return lower(self.mq.TLO.Zone.ShortName()) end
Travel.MIRROR_SIGN = 'Exit Portal'
function Travel:portal()
    if not self.spawns then return nil end
    return (self.spawns.find_any and self.spawns:find_any(Travel.MIRROR_SIGN)) or self.spawns:find(Travel.MIRROR_SIGN)
end
function Travel:in_mirror()
    local p = self:portal()
    -- said when it changes, so a log shows what the check saw
    local seen = p and string.format('%s id %d, %.0f away', Travel.MIRROR_SIGN, p.id, p.distance or -1) or 'none'
    if seen ~= self.lastPortal then
        self.lastPortal = seen
        self.log.debug('  AFK mirror check in %s: %s%s', self:zone(), seen, self.mirror and ' (we went in ourselves)' or '')
    end
    if p then return true end
    return self.mirror == true
end
function Travel:where() return self:zone() .. (self:in_mirror() and ' (AFK mirror)' or '') end
function Travel:in_game() return self.mq.TLO.EverQuest.GameState() == 'INGAME' end
function Travel:path(to) return Config.travel_path(self.travel, self:zone(), to) end
function Travel:casting() return (self.mq.TLO.Me.Casting.ID() or 0) > 0 end
function Travel:moving() return self.mq.TLO.Me.Moving() == true end

-- Zoning has begun (or is already over) since we stood in `from`.
function Travel:left(from) return not self:in_game() or self:zone() ~= from end

function Travel:go(ctx, to)
    to = lower(to)
    local t0 = self.mq.gettime()
    local path = self:path(to)
    if not path then return R.fail('no route', string.format('travel.ini has no way from %s to %s', self:zone(), to)) end
    if #path == 0 then return R.ok({ hops = 0, ms = 0 }) end
    local names = {}
    for _, h in ipairs(path) do names[#names + 1] = h.to end
    self.log.info('Travel: %s -> %s', self:zone(), table.concat(names, ' -> '))
    for i, h in ipairs(path) do
        if not ctx:checkpoint() then return R.fail('stopped') end
        ctx:status(string.format('Travel %d of %d: to %s', i, #path, h.to))
        local from = self:zone()
        local r = self:hop(ctx, h, from)
        if not r.ok then return R.fail(r.why, string.format('%s -> %s (%s): %s', from, h.to, h.how, r.detail or r.why)) end
        self.mirror = false
        local a = self:arrive(ctx, from, h.to)
        if not a.ok then return R.fail(a.why, string.format('%s -> %s: %s', from, h.to, a.detail or a.why)) end
    end
    local ms = self.mq.gettime() - t0
    self.log.info('Travel: in %s after %d hop%s, %.1fs', to, #path, #path == 1 and '' or 's', ms / 1000)
    return R.ok({ hops = #path, ms = ms })
end

function Travel:hop(ctx, h, from)
    if h.how == 'aa' then return self:hop_aa(ctx, h, from) end
    if h.how == 'say' then return self:hop_say(ctx, h, from) end
    if h.how == 'door' then return self:hop_door(ctx, h, from) end
    if h.how == 'run' then return self:hop_run(ctx, h, from) end
    return R.fail('bad hop', 'unknown How=' .. tostring(h.how))
end

-- Wait until zoning has begun, up to `ms`. R.ok(true) when it has, R.ok(false) when not.
function Travel:wait_left(ctx, from, ms)
    local w = ctx:wait(ms, function() return self:left(from) end)
    if not w.ok and w.why ~= 'timeout' then return w end
    return R.ok(self:left(from), w.ms)
end

function Travel:hop_aa(ctx, h, from)
    local Me = self.mq.TLO.Me
    if (Me.AltAbility(h.aa).ID() or 0) == 0 then return R.fail('no such AA', 'this character does not have ' .. h.aa) end
    for try = 1, Travel.TRIES do
        -- standing still and not casting, or the cast is interrupted
        local s = self.nav:stop(ctx)
        if not s.ok then return s end
        local w = ctx:wait(Travel.STILL_MS, function() return not self:moving() and not self:casting() end)
        if not w.ok and w.why ~= 'timeout' then return w end
        if self:moving() or self:casting() then
            return R.fail('not still', string.format('still %s after %dms', self:moving() and 'moving' or 'casting', Travel.STILL_MS))
        end
        if not Me.AltAbilityReady(h.aa)() then
            self.log.info('Travel: waiting for %s to be ready', h.aa)
            local r = ctx:wait(Travel.AA_READY_MS, function() return Me.AltAbilityReady(h.aa)() == true end)
            if not r.ok and r.why ~= 'timeout' then return r end
            if not Me.AltAbilityReady(h.aa)() then return R.fail('AA not ready', string.format('%s still not ready after %ds', h.aa, Travel.AA_READY_MS / 1000)) end
            self.log.debug('  %s ready after %dms', h.aa, r.ms or 0)
        end
        self.mq.doevents()
        self.interrupted = false
        self:send('/aa act ' .. h.aa)
        local c = ctx:wait(Travel.CAST_START_MS, function() return self:casting() or self:left(from) end)
        if not c.ok and c.why ~= 'timeout' then return c end
        if self:left(from) then return R.ok() end
        if not self:casting() then
            self.log.debug('  %s: no cast after %dms (try %d)', h.aa, c.ms or 0, try)
        else
            self.log.debug('  casting %s after %dms', h.aa, c.ms or 0)
            -- leave the cast alone until it ends or the zone changes
            local e = ctx:wait(Travel.CAST_MS, function() return not self:casting() or self:left(from) end)
            if not e.ok and e.why ~= 'timeout' then return e end
            if self:casting() and not self:left(from) then return R.fail('cast too long', string.format('still casting %s after %ds', h.aa, Travel.CAST_MS / 1000)) end
            if self:left(from) then return R.ok() end
            -- the cast ended: zoning follows, or the game says it was interrupted (a chat line, so it can
            -- arrive a moment after the cast ends)
            local z = ctx:wait(Travel.TRIGGER_MS, function() return self:left(from) or self.interrupted end)
            if not z.ok and z.why ~= 'timeout' then return z end
            if self:left(from) then return R.ok() end
            if not self.interrupted then
                return R.fail('no zone', string.format('%s finished but nothing happened in %ds', h.aa, Travel.TRIGGER_MS / 1000))
            end
            self.log.warn('Travel: %s was interrupted (try %d)', h.aa, try)
        end
    end
    return R.fail('AA did not land', string.format('%s: %d tries', h.aa, Travel.TRIES))
end

function Travel:hop_say(ctx, h, from)
    local s, e = self.spawns:await(ctx, h.npc, function() return self.spawns:find(h.npc) end)
    if e then return e end
    if not s then return R.fail('no porter', h.npc .. ' is not in ' .. from) end
    -- Target first, then go: a /say sent the moment the target is set is ignored (2.08.0 log: every first say
    -- right after /target did nothing, the second, 10s later, ported). Targeted before the nav, the server
    -- has the target long before we arrive.
    local t = self.spawns:target(ctx, s.id)
    if not t.ok then return t end
    local g = self.nav:go_spawn(ctx, s.id, Travel.TALK_DIST)
    if not g.ok then return g end
    if (self.mq.TLO.Target.ID() or 0) ~= s.id then
        local t2 = self.spawns:target(ctx, s.id)
        if not t2.ok then return t2 end
    end
    for try = 1, Travel.TRIES do
        self:send('/say ' .. h.say)
        local z = self:wait_left(ctx, from, Travel.TRIGGER_MS)
        if not z.ok then return z end
        if z.value then return R.ok() end
        self.log.warn('Travel: %s did not port us after "%s" (try %d, %ds)', h.npc, h.say, try, Travel.TRIGGER_MS / 1000)
        local again = self.spawns:get(s.id)
        if not again then return R.fail('no porter', h.npc .. ' is gone') end
        if again.distance > Travel.TALK_DIST + 5 then
            local g2 = self.nav:go_spawn(ctx, s.id, Travel.TALK_DIST)
            if not g2.ok then return g2 end
        end
        if (self.mq.TLO.Target.ID() or 0) ~= s.id then
            local t2 = self.spawns:target(ctx, s.id)
            if not t2.ok then return t2 end
        end
    end
    return R.fail('porter did not port', string.format('%s, "%s", %d tries', h.npc, h.say, Travel.TRIES))
end

function Travel:door_targeted(name)
    local D = self.mq.TLO.DoorTarget
    return (D.ID() or 0) > 0 and lower(D.Name()) == lower(name)
end

function Travel:target_door(ctx, name)
    for _ = 1, Travel.TRIES do
        self:send('/doortarget ' .. name)
        local w = ctx:wait(1, function() return self:door_targeted(name) end)
        if not w.ok and w.why ~= 'timeout' then return w end
        if self:door_targeted(name) then return R.ok() end
    end
    return R.fail('no door', string.format('/doortarget %s found nothing', name))
end

function Travel:hop_door(ctx, h, from)
    local near = h.near
    if not near then
        -- no Near: the door's own spot (the old LazCraft's Kelethin stone)
        local t = self:target_door(ctx, h.door)
        if not t.ok then return t end
        local D = self.mq.TLO.DoorTarget
        near = { D.Y(), D.X(), D.Z() }
        self.log.debug('  door %s at %.1f %.1f %.1f, %.1f away', h.door, near[1] or 0, near[2] or 0, near[3] or 0, D.Distance() or -1)
    end
    local g = self.nav:go_loc(ctx, near[1], near[2], near[3], Travel.DOOR_DIST)
    if not g.ok then return g end
    for try = 1, Travel.TRIES do
        if not self:door_targeted(h.door) then
            local t = self:target_door(ctx, h.door)
            if not t.ok then return t end
            self.log.debug('  door %s targeted, %.1f away', h.door, self.mq.TLO.DoorTarget.Distance() or -1)
        end
        self:send('/click left door')
        local z = self:wait_left(ctx, from, Travel.TRIGGER_MS)
        if not z.ok then return z end
        if z.value then return R.ok() end
        self.log.warn('Travel: clicking %s did nothing (try %d, %ds)', h.door, try, Travel.TRIGGER_MS / 1000)
    end
    return R.fail('door did not port', string.format('%s, %d clicks', h.door, Travel.TRIES))
end

-- A zone line: to the staging spot, face the heading, run forward until the zone changes (RUN_MS at most,
-- the heading put back every RUN_FACE_MS so we do not drift). Forward is always let go, whatever happens.
Travel.RUN_DIST = 15
Travel.RUN_MS = 20000
Travel.RUN_FACE_MS = 200
function Travel:hop_run(ctx, h, from)
    local g = self.nav:go_loc(ctx, h.near[1], h.near[2], h.near[3], Travel.RUN_DIST)
    if not g.ok then return R.fail(g.why, 'could not reach the spot to run from: ' .. (g.detail or g.why)) end
    local face = string.format('/face fast heading %.2f', h.heading)
    self:send(face)
    self:send('/keypress forward hold')
    ctx:while_paused(function() self.mq.cmd('/keypress forward') end,
                     function() self.mq.cmd(face); self.mq.cmd('/keypress forward hold') end)
    local t0, left = self.mq.gettime(), false
    local res = R.ok()
    while self.mq.gettime() - t0 < Travel.RUN_MS do
        local w = ctx:wait(Travel.RUN_FACE_MS, function() return self:left(from) end)
        if self:left(from) then left = true; break end
        if not w.ok and w.why ~= 'timeout' then res = w; break end
        self.mq.cmd(face)   -- not logged: every RUN_FACE_MS
    end
    ctx:while_paused()
    self:send('/keypress forward')
    if not res.ok then return res end
    if not left then
        return R.fail('no zone line', string.format('ran %ds at heading %.2f and never left %s', Travel.RUN_MS / 1000, h.heading, from))
    end
    self.log.debug('  zone line crossed after %dms', self.mq.gettime() - t0)
    return R.ok()
end

-- Zoning under way: wait to be in game in `to`, the navmesh loaded, then the zone's arrival spot.
function Travel:arrive(ctx, from, to)
    local t0 = self.mq.gettime()
    local w = ctx:wait(Travel.ZONE_MS, function() return self:in_game() and self:zone() ~= from end)
    if not w.ok and w.why ~= 'timeout' then return w end
    if not (self:in_game() and self:zone() ~= from) then
        return R.fail('zoning too long', string.format('not in game in a new zone after %ds', Travel.ZONE_MS / 1000))
    end
    if self:zone() ~= to then return R.fail('wrong zone', string.format('landed in %s, not %s', self:zone(), to)) end
    self.log.debug('  in %s after %dms', to, w.ms or 0)
    local NavT = self.mq.TLO.Navigation
    if NavT.MeshLoaded then
        local m = ctx:wait(Travel.MESH_MS, function() return NavT.MeshLoaded() == true end)
        if not m.ok and m.why ~= 'timeout' then return m end
        if NavT.MeshLoaded() ~= true then return R.fail('no navmesh', string.format('%s has no navmesh loaded after %ds', to, Travel.MESH_MS / 1000)) end
        self.log.debug('  navmesh loaded after %dms', m.ms or 0)
    end
    if self.nav.zoned then self.nav:zoned() end
    local spot = self.travel.arrive[to]
    if spot then
        local r = self:go_arrival(ctx, to, spot)
        if not r.ok then return r end
    end
    self.log.info('Travel: arrived in %s (%.1fs)', to, (self.mq.gettime() - t0) / 1000)
    return R.ok()
end

function Travel:enter_mirror(ctx)
    local zone = self:zone()
    local m = (self.travel.mirror or {})[zone]
    if not m then return R.fail('no mirror', zone .. ' has no AFK mirror in travel.ini') end
    if self:in_mirror() then return R.fail('in the mirror', 'already in the AFK mirror of ' .. zone) end
    self.log.info('Travel: into the AFK mirror of %s (%s)', zone, m.npc)
    if m.near then
        local g = self.nav:go_loc(ctx, m.near[1], m.near[2], m.near[3], Travel.ARRIVE_DIST)
        if not g.ok then return g end
    end
    local s, e = self.spawns:await(ctx, m.npc, function() return self.spawns:find(m.npc) end)
    if e then return e end
    if not s then return R.fail('no npc', m.npc .. ' is not in ' .. zone) end
    local t = self.spawns:target(ctx, s.id)
    if not t.ok then return t end
    local g = self.nav:go_spawn(ctx, s.id, Travel.TALK_DIST)
    if not g.ok then return g end
    local t0 = self.mq.gettime()
    local wentOut = false
    local function zoning() if not self:in_game() then wentOut = true end; return wentOut or self.entered end
    local started = false
    for try = 1, Travel.TRIES do
        if (self.mq.TLO.Target.ID() or 0) ~= s.id then
            local t2 = self.spawns:target(ctx, s.id)
            if not t2.ok then return t2 end
        end
        self.entered = false
        self:send('/say ' .. m.say)
        local w = ctx:wait(Travel.TRIGGER_MS, zoning)
        if not w.ok and w.why ~= 'timeout' then return w end
        if w.ok then started = true; break end
        self.log.warn('Travel: %s did not take us in after "%s" (try %d, %ds)', m.npc, m.say, try, Travel.TRIGGER_MS / 1000)
    end
    if not started then return R.fail('no mirror', string.format('%s, "%s", %d tries', m.npc, m.say, Travel.TRIES)) end
    local w = ctx:wait(Travel.ZONE_MS, function() zoning(); return self:in_game() and (wentOut or self.entered) end)
    if not w.ok and w.why ~= 'timeout' then return w end
    if not self:in_game() then return R.fail('zoning too long', string.format('not in game after %ds', Travel.ZONE_MS / 1000)) end
    self.mirror = true
    if self.nav.zoned then self.nav:zoned() end
    self.log.debug('  in the mirror after %dms (seen by: %s)', self.mq.gettime() - t0,
        (wentOut and self.entered) and 'zoning and the message' or (wentOut and 'zoning' or 'the message'))
    local NavT = self.mq.TLO.Navigation
    if NavT.MeshLoaded then
        local mw = ctx:wait(Travel.MESH_MS, function() return NavT.MeshLoaded() == true end)
        if not mw.ok and mw.why ~= 'timeout' then return mw end
    end
    local spot = self.travel.arrive[zone]
    if spot then
        local r = self:go_arrival(ctx, zone, spot)
        if not r.ok then return r end
    end
    self.log.info('Travel: in the AFK mirror of %s (%.1fs)', zone, (self.mq.gettime() - t0) / 1000)
    return R.ok()
end

-- Out of the AFK mirror: walk into its Exit Portal NPC, which ports us out (seen in game, 2.41.2). Confirmed by the
-- zoning itself, as going in; then the navmesh and the zone's arrival spot, like any zone-in.
Travel.PORTAL_DIST = 1
function Travel:leave_mirror(ctx)
    local zone = self:zone()
    if not self:in_mirror() then return R.ok() end
    local t0 = self.mq.gettime()
    local wentOut = false
    local function zoning() if not self:in_game() then wentOut = true end; return wentOut or self.entered end
    local started = false
    for try = 1, Travel.TRIES do
        local s = self:portal()
        if not s then return R.fail('no exit', string.format('no %s here to leave the AFK mirror of %s by', Travel.MIRROR_SIGN, zone)) end
        self.log.info('Travel: out of the AFK mirror of %s - walking into the %s (%.0f away)', zone, Travel.MIRROR_SIGN, s.distance)
        self.entered = false
        local g = self.nav:go_spawn(ctx, s.id, Travel.PORTAL_DIST)   -- ends as we zone (the portal is gone): the zoning says
        if not g.ok and g.why == 'stopped' then return g end
        local w = ctx:wait(Travel.TRIGGER_MS, zoning)
        if not w.ok and w.why ~= 'timeout' then return w end
        if w.ok then started = true; break end
        self.log.warn('Travel: the %s did not port us out (try %d; walk: %s)', Travel.MIRROR_SIGN, try, g.ok and 'reached it' or R.describe(g))
    end
    if not started then return R.fail('no exit', string.format('the %s did not port us out after %d tries', Travel.MIRROR_SIGN, Travel.TRIES)) end
    local w = ctx:wait(Travel.ZONE_MS, function() zoning(); return self:in_game() and (wentOut or self.entered) end)
    if not w.ok and w.why ~= 'timeout' then return w end
    if not self:in_game() then return R.fail('zoning too long', string.format('not in game after %ds', Travel.ZONE_MS / 1000)) end
    self.mirror = false
    if self.nav.zoned then self.nav:zoned() end
    local NavT = self.mq.TLO.Navigation
    if NavT.MeshLoaded then
        local mw = ctx:wait(Travel.MESH_MS, function() return NavT.MeshLoaded() == true end)
        if not mw.ok and mw.why ~= 'timeout' then return mw end
    end
    local spot = self.travel.arrive[zone]
    if spot then
        local r = self:go_arrival(ctx, zone, spot)
        if not r.ok then return r end
    end
    self.log.info('Travel: out of the AFK mirror, in %s (%.1fs)', zone, (self.mq.gettime() - t0) / 1000)
    return R.ok()
end

function Travel:go_arrival(ctx, to, spot)
    -- the nav block knows the arrival spots and goes there straight (no route rules): one place for both
    if self.nav.arrive_first then return self.nav:arrive_first(ctx) end
    if spot.npc then
        local s
        local w = ctx:wait(Travel.SPAWN_MS, function() s = self.spawns:find(spot.npc); return s ~= nil end)
        if not w.ok and w.why ~= 'timeout' then return w end
        if not s then
            self.log.warn('Travel: arrival spot %s is not in %s - going on without it', spot.npc, to)
            return R.ok()
        end
        if s.distance <= Travel.ARRIVE_SKIP then return R.ok() end
        self.log.debug('  %s: first to %s (%.0f away)', to, spot.npc, s.distance)
        return self.nav:go_spawn(ctx, s.id, Travel.ARRIVE_DIST)
    end
    local y, x, z = spot.loc[1], spot.loc[2], spot.loc[3]
    local Me = self.mq.TLO.Me
    local d = math.sqrt(((Me.X() or 0) - x) ^ 2 + ((Me.Y() or 0) - y) ^ 2 + ((Me.Z() or 0) - z) ^ 2)
    if d <= Travel.ARRIVE_SKIP then return R.ok() end
    self.log.debug('  %s: first to %.1f %.1f %.1f (%.0f away)', to, y, x, z, d)
    return self.nav:go_loc(ctx, y, x, z, Travel.ARRIVE_DIST)
end

return Travel
