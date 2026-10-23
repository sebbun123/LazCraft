-- Spawns: finding NPCs and targeting them.
--   find(name)          nearest NPC with exactly this name: { id, name, distance, class, y, x, z }, or nil
--   find_any(name)      any spawn (not only an NPC) by exact name, or nil
--   find_pc(name)       a player character in this zone by exact name, or nil
--   get(id)             the same for a spawn id, or nil once it is gone
--   target(ctx, id)     target by spawn id, confirmed
--   await(ctx, what, finder, ms)   finder() until it returns a spawn, up to ms (APPEAR_MS): spawn, or nil
--                       (and a stop/pause result as the second value)
--
-- Rules it keeps:
--   * Names are matched exactly (ignoring case). A spawn search alone matches parts of names.
--   * Everything after finding works by spawn id: several vendors can stand on the same spot, and only
--     the id says which body we mean.
--   * Just after zoning in, the zone's spawns are still arriving (2.22.0 log: a merchant looked for 0ms
--     after landing in PoK was "not in this zone", and he was). So anything looked for after travel is
--     waited for, up to APPEAR_MS, and how long it took is logged.
--   * Targeting happens in the client, so it shows at once. A target that did not take by the next
--     frame was lost and is sent again, up to 3 times.
local R = require('core.result')

local Spawns = {}
Spawns.__index = Spawns

Spawns.TRIES = 3

local NOLOG = { debug = function() end }

function Spawns.new(mq, log)
    return setmetatable({ mq = mq, log = log or NOLOG }, Spawns)
end

local function lower(s) return (s or ''):lower() end

local function info(s)
    if not s or (s.ID() or 0) == 0 then return nil end
    return { id = s.ID(), name = s.CleanName(), distance = s.Distance3D() or 0, class = s.Class.Name(),
             y = s.Y(), x = s.X(), z = s.Z(), pc = s.Type() == 'PC' }
end

function Spawns:find(name)
    local TLO = self.mq.TLO
    local q = string.format('npc "%s"', name)
    local n = TLO.SpawnCount(q)() or 0
    for i = 1, n do
        local s = TLO.NearestSpawn(string.format('%d, %s', i, q))
        if lower(s.CleanName()) == lower(name) then return info(s) end
    end
    return nil
end

Spawns.APPEAR_MS = 8000

function Spawns:await(ctx, what, finder, ms)
    local s = finder()
    if s then return s end
    local w = ctx:wait(ms or Spawns.APPEAR_MS, function() s = finder(); return s ~= nil end)
    if not w.ok and w.why ~= 'timeout' then return nil, w end
    if s then self.log.debug('  %s showed up after %dms', what, w.ms or 0) end
    return s
end

-- Any spawn by its exact name, whatever its type: ${Spawn[<name>]} (2.42.8 - the AFK mirror's Exit Portal: the user's
-- /echo ${Spawn[Exit Portal].ID} finds it; no log ever showed the `npc "..."` search finding it, and the 2.42.6 log had
-- Mortician in Marr's and Shela in its mirror with neither noticing).
function Spawns:find_any(name)
    local i = info(self.mq.TLO.Spawn(name))
    if i and lower(i.name) == lower(name) then return i end
    return nil
end

function Spawns:find_pc(name)
    local s = self.mq.TLO.Spawn('pc =' .. name)
    local i = info(s)
    if i and lower(i.name) == lower(name) then return i end
    return nil
end

function Spawns:get(id)
    return info(self.mq.TLO.Spawn('id ' .. id))
end

function Spawns:target(ctx, id)
    local TLO = self.mq.TLO
    local function on() return (TLO.Target.ID() or 0) == id end
    if on() then return R.ok() end
    for try = 1, Spawns.TRIES do
        local cmd = '/target id ' .. id
        self.log.debug('  send: %s', cmd)
        self.mq.cmd(cmd)
        local w = ctx:wait(1, on)
        if w.ok or on() then
            self.log.debug('  targeted %s (id %d) after %dms%s', tostring(TLO.Target.CleanName()), id, w.ms or 0,
                try > 1 and string.format(', try %d', try) or '')
            return R.ok()
        end
        if w.why ~= 'timeout' then return w end
    end
    if not self:get(id) then return R.fail('gone', 'spawn ' .. id .. ' is no longer in the zone') end
    return R.fail('target failed', string.format('could not target spawn %d after %d tries', id, Spawns.TRIES))
end

return Spawns
