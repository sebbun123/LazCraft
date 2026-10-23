-- Routes: the ways around geometry that wedges a straight /nav (data/nav.ini, all carried over from the
-- old LazCraft where they were proven in game). Pure: no game calls, so it is tested on its own.
--
--   Routes.plan(z, me, dest, spawn)  -> { legs = { {y, x, z, why}, ... }, spot = {y, x, z, crouch, name} or nil }
--     z     the zone's nav.ini entry (cfg.nav[zone]), or nil (nothing to do)
--     me    { y, x, z } where we stand
--     dest  { y, x, z, name } where we are going (name = the NPC's, for a spawn)
--     spawn true when dest is a spawn (only a spawn is opened from a Spot)
--
-- The order the old LazCraft used, kept:
--   1. SideDocks: start and destination on opposite X sides -> our side's dock, then the far dock (the old
--      LazCraft's rule: every crossing; straight across, Marr's walks went round the four pillars and through
--      the water - 2.39.3 to 2.40.1). SideDocks' third field, when given, limits it to standing within that
--      of our side's dock. The walk off Marr's zone-in is Nav's arrival walk to Tomas, straight, never docked
--      (2.39.2 log: docked, it went round the whole zone).
--   2. Pocket: going to a PocketNpcs NPC from outside the pocket -> pocket hub, then dock; that trip is the
--      pocket's own and no Hub is added. Standing in the pocket going anywhere else -> dock, then hub.
--   3. Hubs: standing inside a hub's radius -> leave through it; a destination inside a hub's radius ->
--      approach through it. (The old bank walk did both; other walks did one. Both is the bank's rule:
--      a hub is clear ground either way.)
--   4. Spot: a spawn within a Spot's radius is walked to the spot instead (opened from there).
--   5. Avoid (2.42.13, Marr's fountain): a box (Avoid<n>= its corners, y x each, and a margin) no walk goes
--      through. Every stretch of the walk - here to the first leg, leg to leg, the last leg to where we go - is
--      checked on the map (y, x): standing in the box, the first leg steps out to its nearest edge (plus the
--      margin); a stretch that would cross it goes round by the box's corners (each pushed out by the margin),
--      whichever way round is shorter. /nav still picks its own path between legs - it cannot be seen - so a
--      leg ends and starts clear of the box, and the stretches between are short.
--   Routes.avoid(z, me, dest) -> the legs of rule 5 alone (the walk off the zone-in to its [Arrive] spot).
-- A leg already within LEG_NEAR of where the walk would be at that point is left out; the same spot twice
-- in a row is walked once.
local Routes = {}

Routes.LEG_NEAR = 15

local function d3(a, b)
    return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
end

local function hub_of(z, p)
    for _, h in ipairs(z.hubs or {}) do
        if d3(h, p) <= h.r then return h end
    end
end

-- ---- the avoid boxes (2D, y x) ----
local function cross(o, a, b) return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1]) end

local function inside(poly, p)
    local c, n = false, #poly
    for i = 1, n do
        local a, b = poly[i], poly[i % n + 1]
        if ((a[1] > p[1]) ~= (b[1] > p[1])) and (p[2] < (b[2] - a[2]) * (p[1] - a[1]) / (b[1] - a[1]) + a[2]) then c = not c end
    end
    return c
end

local function segs_cross(a, b, c, d)
    local d1, d2, d3, d4 = cross(c, d, a), cross(c, d, b), cross(a, b, c), cross(a, b, d)
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0))
end

-- the stretch a-b runs through the box
local function through(poly, a, b)
    if inside(poly, a) or inside(poly, b) or inside(poly, { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2 }) then return true end
    for i = 1, #poly do if segs_cross(a, b, poly[i], poly[i % #poly + 1]) then return true end end
    return false
end

-- the box's corners pushed out from its middle by the margin
local function grown(box)
    local cy, cx = 0, 0
    for _, p in ipairs(box.pts) do cy, cx = cy + p[1], cx + p[2] end
    cy, cx = cy / #box.pts, cx / #box.pts
    local out = {}
    for _, p in ipairs(box.pts) do
        local dy, dx = p[1] - cy, p[2] - cx
        local l = math.sqrt(dy * dy + dx * dx)
        if l == 0 then l = 1 end
        out[#out + 1] = { p[1] + dy / l * box.margin, p[2] + dx / l * box.margin }
    end
    return out
end

local function dist2(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end

-- nearest point to p on the grown box's outline
local function nearest_out(g, p)
    local best, bd
    for i = 1, #g do
        local a, b = g[i], g[i % #g + 1]
        local vy, vx = b[1] - a[1], b[2] - a[2]
        local l2 = vy * vy + vx * vx
        local t = l2 > 0 and math.max(0, math.min(1, ((p[1] - a[1]) * vy + (p[2] - a[2]) * vx) / l2)) or 0
        local q = { a[1] + vy * t, a[2] + vx * t }
        local d = dist2(p, q)
        if not bd or d < bd then best, bd = q, d end
    end
    return best
end

-- the corners to go round by from a to b (shortest way round), or {} when a-b does not touch the box
local function round_by(box, a, b)
    if not through(box.pts, a, b) then return {} end
    local g = grown(box)
    local n = #g
    local best, bestLen
    for s = 1, n do
        if not through(box.pts, a, g[s]) then
            for _, dir in ipairs({ 1, -1 }) do
                local chain, len, i = { g[s] }, dist2(a, g[s]), s
                for _ = 1, n do
                    if not through(box.pts, g[i], b) then
                        len = len + dist2(g[i], b)
                        if not bestLen or len < bestLen then best, bestLen = chain, len end
                        break
                    end
                    local j = (i - 1 + dir) % n + 1
                    len = len + dist2(g[i], g[j])
                    local copy = {}
                    for k, v in ipairs(chain) do copy[k] = v end
                    copy[#copy + 1] = g[j]
                    chain = copy
                    i = j
                end
            end
        end
    end
    return best or {}
end

-- where along a-b (0..1) it first meets the box
local function first_t(poly, a, b)
    if inside(poly, a) then return 0 end
    local best = 1
    for i = 1, #poly do
        local c, d = poly[i], poly[i % #poly + 1]
        local ry, rx, sy, sx = b[1] - a[1], b[2] - a[2], d[1] - c[1], d[2] - c[2]
        local den = ry * sx - rx * sy
        if den ~= 0 then
            local t = ((c[1] - a[1]) * sx - (c[2] - a[2]) * sy) / den
            local u = ((c[1] - a[1]) * rx - (c[2] - a[2]) * ry) / den
            if t >= 0 and t <= 1 and u >= 0 and u <= 1 and t < best then best = t end
        end
    end
    return best
end

-- rule 5 over a walk: points = { me, leg, leg, ..., dest } -> the legs (between me and dest) with the avoid legs
-- put in, or nil when nothing changed. Stretch by stretch, the box a stretch meets first is gone round, and the
-- new stretches are checked again (they may meet another box).
local function avoided(z, points)
    if not z or not z.avoid or #z.avoid == 0 then return nil end
    local pts = {}
    for i, p in ipairs(points) do pts[i] = p end
    local changed = false
    for _, box in ipairs(z.avoid) do
        if inside(box.pts, pts[1]) then
            local q = nearest_out(grown(box), pts[1])
            table.insert(pts, 2, { q[1], q[2], box.z or pts[1][3], why = 'out of ' .. box.name, avoid = true })
            changed = true
            break
        end
    end
    local i, guard = 1, 0
    while i < #pts and guard < 64 do
        guard = guard + 1
        local a, b = pts[i], pts[i + 1]
        local hit, hitT
        for _, box in ipairs(z.avoid) do
            if through(box.pts, a, b) then
                local t = first_t(box.pts, a, b)
                if not hitT or t < hitT then hit, hitT = box, t end
            end
        end
        local chain = hit and round_by(hit, a, b) or {}
        if #chain > 0 then
            local len = math.max(1, dist2(a, b))
            for k = #chain, 1, -1 do
                local c = chain[k]
                local t = math.min(1, dist2(a, c) / len)
                local za, zb = a[3] or b[3] or 0, b[3] or a[3] or 0
                -- the box's own floor height when nav.ini gives it, else a guess between the stretch's ends
                table.insert(pts, i + 1, { c[1], c[2], hit.z or (za + (zb - za) * t), why = 'round ' .. hit.name, avoid = true })
            end
            changed = true
        else
            i = i + 1
        end
    end
    if not changed then return nil end
    local out = {}
    for k = 2, #pts - 1 do out[#out + 1] = pts[k] end
    return out
end

function Routes.avoid(z, me, dest)
    local legs = avoided(z, { me, dest })
    return legs or {}
end

function Routes.plan(z, me, dest, spawn)
    local out = { legs = {} }
    if not z then return out end
    local at = { me[1], me[2], me[3] }
    local function leg(p, why)
        local last = out.legs[#out.legs]
        if last and d3(last, p) < 0.5 then return end
        if d3(at, p) <= Routes.LEG_NEAR then return end
        out.legs[#out.legs + 1] = { p[1], p[2], p[3], why = why }
        at = { p[1], p[2], p[3] }
    end

    -- 1. side docks (X sign)
    if z.docks and (me[2] < 0) ~= (dest[2] < 0) then
        local mine = me[2] < 0 and z.docks.a or z.docks.b
        local far = dest[2] < 0 and z.docks.a or z.docks.b
        if not z.docks.near or d3(at, mine) <= z.docks.near then
            leg(mine, 'this side\'s dock')
            leg(far, 'the far side\'s dock')
        end
    end

    -- 2. the pocket
    local pocketTrip = false
    local pk = z.pocket
    if pk then
        local inPocket = me[2] < pk.split and me[3] > pk.upper
        local forPocket = spawn and dest.name and pk.npcs[dest.name:lower()]
        if forPocket then
            pocketTrip = true
            if not inPocket then
                leg(pk.hub, 'the pocket hub')
                leg(pk.dock, 'the pocket dock')
            end
        elseif inPocket then
            leg(pk.dock, 'the pocket dock (leaving)')
            leg(pk.hub, 'the pocket hub (leaving)')
        end
    end

    -- 3. hubs
    if not pocketTrip then
        local mine = hub_of(z, at)
        local theirs = hub_of(z, dest)
        if mine then leg(mine, 'leave via ' .. mine.name) end
        if theirs then leg(theirs, 'approach via ' .. theirs.name) end
    end

    -- 4. a spot to open the merchant from
    if spawn then
        for _, s in ipairs(z.spots or {}) do
            if d3(s, dest) <= s.r then
                out.spot = { s[1], s[2], s[3], crouch = s.crouch, name = s.name }
                break
            end
        end
    end
    -- 5. the avoid boxes, over the whole walk
    local pts = { { me[1], me[2], me[3] } }
    for _, l in ipairs(out.legs) do pts[#pts + 1] = l end
    pts[#pts + 1] = out.spot or { dest[1], dest[2], dest[3] }
    local av = avoided(z, pts)
    if av then
        out.legs = {}
        local at2 = { me[1], me[2], me[3] }
        for _, l in ipairs(av) do
            local last = out.legs[#out.legs]
            if not (last and d3(last, l) < 0.5) and (l.avoid or d3(at2, l) > Routes.LEG_NEAR) then
                out.legs[#out.legs + 1] = l
                at2 = l
            end
        end
    end
    return out
end

return Routes
