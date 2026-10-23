-- Loads the shipped data files and the per-character settings into plain tables.
-- Anything wrong in a file is collected as a readable problem instead of stopping the load, so one bad
-- line never takes the whole script down; the caller logs the problems.
local Ini = require('core.ini')

local Config = {}

local DISPOSALS = { sell = true, destroy = true, keep = true }

local function lower_set(sec)
    local set = {}
    if sec then for _, kv in ipairs(sec.keys) do set[kv[1]:lower()] = true end end
    return set
end

-- containers.ini -> { [name] = { type, stations = { {zone,y,x,z,target} }, accepts = {}, buyOrder = {} } },
--                   plus byBag[lowercased bag name] = container name (every Accepts entry and the name itself)
function Config.parse_containers(doc, problems)
    local out, byBag = {}, {}
    for _, name in ipairs(doc.order) do
        local sec = doc.sections[name]
        local c = { name = name, type = (sec.map.Type or ''):lower(), stations = {}, accepts = {}, buyOrder = {},
                    skill = sec.map.Skill }
        if c.type == 'station' then
            local n = 1
            while sec.map['At' .. n] do
                local zone, y, x, z = sec.map['At' .. n]:match('^(%S+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)$')
                if zone then
                    c.stations[#c.stations + 1] = { zone = zone, y = tonumber(y), x = tonumber(x), z = tonumber(z),
                                                    target = sec.map['Target' .. n] or name, index = n }
                else
                    problems[#problems + 1] = string.format('containers.ini [%s] At%d is not "<zone> <y> <x> <z>"', name, n)
                end
                n = n + 1
            end
            if #c.stations == 0 then
                problems[#problems + 1] = string.format('containers.ini [%s] is a station with no At lines', name)
            end
        elseif c.type == 'kit' then
            c.accepts = Ini.list(sec.map.Accepts)
            c.buyOrder = Ini.list(sec.map.BuyOrder)
            if #c.accepts == 0 then c.accepts = { name } end
            for _, b in ipairs(c.buyOrder) do
                local ok = false
                for _, a in ipairs(c.accepts) do if a == b then ok = true end end
                if not ok then
                    problems[#problems + 1] = string.format('containers.ini [%s] BuyOrder "%s" is not in Accepts', name, b)
                end
            end
        elseif c.type == 'skip' then
            -- only read by tools/parse_harvest.py (recipes made only in these are left out)
        else
            problems[#problems + 1] = string.format('containers.ini [%s] Type must be station, kit or skip', name)
        end
        out[name] = c
        byBag[name:lower()] = name
        for _, a in ipairs(c.accepts) do byBag[a:lower()] = name end
    end
    return out, byBag
end

-- skills.ini -> skills[name], collections[name] = { recipes }, levelAll = { names }; collectionOpts[name] = the
-- section's other keys (Radix: Draught=, DraughtOn=)
function Config.parse_skills(doc, problems)
    local skills, collections, levelAll, collectionOpts = {}, {}, {}, {}
    local order = {}
    for _, name in ipairs(doc.order) do
        local sec = doc.sections[name]
        local coll = name:match('^Collection:(.+)$')
        if coll then
            collections[coll] = Ini.list(sec.map.Recipes)
            collectionOpts[coll] = sec.map
        elseif name == 'LevelAll' then
            levelAll = Ini.list(sec.map.Order)
        else
            local s = {
                name = name, id = tonumber(sec.map.ID), eqSkill = sec.map.EQSkill or name,
                class = sec.map.Class, race = sec.map.Race, disposal = (sec.map.Disposal or 'sell'):lower(),
                trophy = Ini.list(sec.map.Trophy), clicky = Ini.list(sec.map.Clicky), rungs = {},
            }
            if not s.id then problems[#problems + 1] = string.format('skills.ini [%s] has no numeric ID', name) end
            if not DISPOSALS[s.disposal] then
                problems[#problems + 1] = string.format('skills.ini [%s] Disposal "%s" is not sell/destroy/keep', name, s.disposal)
                s.disposal = 'sell'
            end
            local n = 1
            while sec.map['Rung' .. n] do
                local recipe, disp = sec.map['Rung' .. n]:match('^(.-)%s*,%s*(%a+)$')
                disp = disp and disp:lower()
                if recipe and DISPOSALS[disp] then
                    s.rungs[#s.rungs + 1] = { recipe = recipe, disposal = disp }
                else
                    problems[#problems + 1] = string.format('skills.ini [%s] Rung%d is not "<recipe>, <sell|destroy|keep>"', name, n)
                end
                n = n + 1
            end
            skills[name] = s
            order[#order + 1] = name
        end
    end
    for _, n in ipairs(levelAll) do
        if not skills[n] then problems[#problems + 1] = string.format('skills.ini LevelAll names unknown skill "%s"', n) end
    end
    return skills, collections, levelAll, order, collectionOpts
end

-- producers.ini -> producers[item] = { item, spells = { {spell, yield, reagents = { {name, count} }} ... } biggest
-- yield first, classes = {}, group }. spell/yield/reagents are the biggest spell's, for code that needs one.
-- Spell=<spell> | <yield> | <reagents>, one line per spell. (The older Spell=/Yield=/Reagents= keys still read.)
local function parse_reagents(text, item, problems)
    local out = {}
    for _, part in ipairs(Ini.list(text)) do
        local nm, cnt = part:match('^(.-)%s+x(%d+)$')
        if nm then out[#out + 1] = { name = nm, count = tonumber(cnt) }
        else problems[#problems + 1] = string.format('producers.ini [%s] reagent "%s" is not "<item> x<count>"', item, part) end
    end
    return out
end

function Config.parse_producers(doc, problems)
    local out = {}
    for _, item in ipairs(doc.order) do
        local sec = doc.sections[item]
        local p = { item = item, spells = {}, classes = Ini.list(sec.map.Classes), group = sec.map.Group or 'Other' }
        for _, kv in ipairs(sec.keys) do
            if kv[1] == 'Spell' then
                local spell, yield, reagents = kv[2]:match('^(.-)%s*|%s*(.-)%s*|%s*(.-)%s*$')
                if spell then
                    local y = tonumber(yield)
                    if spell == '' then problems[#problems + 1] = string.format('producers.ini [%s] has a Spell line with no spell', item)
                    elseif not y or y < 1 then problems[#problems + 1] = string.format('producers.ini [%s] %s: the amount must be 1 or more', item, spell)
                    else p.spells[#p.spells + 1] = { spell = spell, yield = y, reagents = parse_reagents(reagents, item, problems) } end
                elseif sec.map.Yield then   -- the older three-key form
                    p.spells[#p.spells + 1] = { spell = kv[2], yield = tonumber(sec.map.Yield) or 0,
                                                reagents = parse_reagents(sec.map.Reagents, item, problems) }
                    if p.spells[#p.spells].yield < 1 then problems[#problems + 1] = string.format('producers.ini [%s] Yield must be 1 or more', item) end
                else
                    problems[#problems + 1] = string.format('producers.ini [%s] Spell is not "<spell> | <amount> | <reagents>"', item)
                end
            end
        end
        table.sort(p.spells, function(a, b) return a.yield > b.yield end)
        if #p.spells == 0 then problems[#problems + 1] = string.format('producers.ini [%s] has no Spell', item)
        else p.spell, p.yield, p.reagents = p.spells[1].spell, p.spells[1].yield, p.spells[1].reagents end
        if #p.classes == 0 then problems[#problems + 1] = string.format('producers.ini [%s] has no Classes', item) end
        out[item] = p
    end
    return out
end

-- lists.ini -> lowercased sets, plus vendorOverride[item] = vendor
function Config.parse_lists(doc)
    local s = doc.sections
    local override = {}
    if s.VendorOverride then for _, kv in ipairs(s.VendorOverride.keys) do override[kv[1]] = kv[2] end end
    return {
        noSellTo = lower_set(s.NoSellTo), neverSell = lower_set(s.NeverSell), dontAskGroup = lower_set(s.DontAskGroup),
        fishKeep = lower_set(s.FishKeep), fishDestroy = lower_set(s.FishDestroy), vendorOverride = override,
        tradeskillOnly = lower_set(s.TradeskillOnlyBags),
    }
end

-- Load everything from dataDir. Returns cfg, problems (array of strings).
-- "Amber x1, Silver Bar x2" -> { {name='Amber', n=1}, {name='Silver Bar', n=2} }
function Config.item_list(text, problems, where)
    -- Item names can contain commas ("Poison, Nightbane"), so an entry ends only at " x<n>" followed by a
    -- comma or the end of the text.
    local out = {}
    local rest = Ini.trim(text or '')
    while rest ~= '' do
        local name, n, after = rest:match('^(.-)%s+x(%d+)%s*,%s*(.*)$')
        if not name then name, n = rest:match('^(.-)%s+x(%d+)%s*$'); after = '' end
        if not name then
            if problems then problems[#problems + 1] = string.format('%s: "%s" is not "<item> x<n>"', where, rest) end
            break
        end
        out[#out + 1] = { name = Ini.trim(name), n = tonumber(n) }
        rest = after
    end
    return out
end

-- recipes.ini (and recipes_local.ini on top): one section per recipe, keyed by id.
-- Returns recipes[id] = { id, name, label, container, skill, trivial, yield, ins = {..}, tools = {..} } and
-- byName[lower product name] = { id, ... } (several recipes can make one product).
function Config.parse_recipes(doc, problems, recipes)
    recipes = recipes or {}
    for _, id in ipairs(doc.order) do
        local m = doc.sections[id].map
        if not m.Name or not m.Container or not m.In then
            problems[#problems + 1] = string.format('recipes [%s] needs Name, Container and In', id)
        else
            recipes[id] = {
                id = id, name = m.Name, label = m.Label or m.Name, container = m.Container, skill = m.Skill,
                trivial = tonumber(m.Trivial), yield = math.max(1, tonumber(m.Yield) or 1),
                ins = Config.item_list(m.In, problems, 'recipes [' .. id .. '] In'),
                tools = Config.item_list(m.Tools, problems, 'recipes [' .. id .. '] Tools'),
                also = Config.item_list(m.Also, problems, 'recipes [' .. id .. '] Also'),
                failBack = Config.item_list(m.FailBack, problems, 'recipes [' .. id .. '] FailBack'),
            }
        end
    end
    return recipes
end

-- research.ini (the old LazCraft's research data): [Recipe:<name>##<class>] one class's spell or tome (Name= is
-- the product), [Recipe:<name>] a shared subcombine (vellums, parchments, cleanser, vials), [Research:<class>_<level>]
-- SpellN= what that class researches at that level. Ingredients are Ingredient<n>=<item>|<count>[|subcombine|dropped].
-- A recipe the harvest (recipes.ini) already has - same product, same ingredients - is used as it is; a shared
-- subcombine is only added when no recipe makes it (the harvest wins). Anything else joins as R<n>.
-- Returns { classes = { sorted }, index = { [class] = { [level] = { { name, id }, ... } } }, levels = { [class] = { sorted } } }
function Config.parse_research(doc, recipes, problems)
    local byName = {}
    for id, r in pairs(recipes) do
        local k = r.name:lower()
        byName[k] = byName[k] or {}
        byName[k][#byName[k] + 1] = id
    end
    local function key_of(list)
        local t = {}
        for _, x in ipairs(list) do t[#t + 1] = x.name:lower() .. '*' .. x.n end
        table.sort(t)
        return table.concat(t, ',')
    end
    local keyFor = {}   -- '<name>##<class>' lower -> recipe id
    local n = 0
    for _, sec in ipairs(doc.order) do
        local rest = sec:match('^Recipe:(.+)$')
        if rest then
            local m = doc.sections[sec].map
            local surface, cls = rest:match('^(.-)##(.+)$')
            surface = surface or rest
            local name = m.Name or surface
            local ins = {}
            for _, kv in ipairs(doc.sections[sec].keys) do
                if kv[1]:match('^Ingredient%d+$') then
                    local item, cnt = kv[2]:match('^([^|]+)|(%d+)')
                    if item then ins[#ins + 1] = { name = Ini.trim(item), n = tonumber(cnt) }
                    elseif problems then problems[#problems + 1] = string.format('research [%s]: "%s" is not <item>|<n>', sec, kv[2]) end
                end
            end
            local same
            for _, id in ipairs(byName[name:lower()] or {}) do
                if key_of(recipes[id].ins) == key_of(ins) then same = id; break end
            end
            local id = same
            if not id and (cls or not byName[name:lower()]) then
                n = n + 1
                id = 'R' .. n
                recipes[id] = { id = id, name = name, label = name, container = m.Container, skill = 'Research',
                    trivial = tonumber(m.Trivial), yield = math.max(1, tonumber(m.Yield) or 1), ins = ins, tools = {},
                    also = {}, failBack = {}, research = cls }
                byName[name:lower()] = byName[name:lower()] or {}
                table.insert(byName[name:lower()], id)
            end
            if cls and id then keyFor[(name .. '##' .. cls):lower()] = id end
        end
    end
    local out = { classes = {}, index = {}, levels = {} }
    for _, sec in ipairs(doc.order) do
        local cls, lv = sec:match('^Research:(.+)_(%d+)$')
        if cls then
            lv = tonumber(lv)
            if not out.index[cls] then out.index[cls] = {}; out.levels[cls] = {}; out.classes[#out.classes + 1] = cls end
            local list = out.index[cls][lv]
            if not list then list = {}; out.index[cls][lv] = list; table.insert(out.levels[cls], lv) end
            for _, kv in ipairs(doc.sections[sec].keys) do
                if kv[1]:match('^Spell%d+$') then
                    local id = keyFor[(kv[2] .. '##' .. cls):lower()]
                    if id then list[#list + 1] = { name = kv[2], id = id }
                    elseif problems then problems[#problems + 1] = string.format('research [%s]: no recipe for %s', sec, kv[2]) end
                end
            end
        end
    end
    table.sort(out.classes)
    for _, l in pairs(out.levels) do table.sort(l) end
    return out
end

function Config.index_recipes(recipes)
    local byName = {}
    for id, r in pairs(recipes) do
        local k = r.name:lower()
        byName[k] = byName[k] or {}
        table.insert(byName[k], id)
    end
    for _, ids in pairs(byName) do table.sort(ids) end
    return byName
end

-- merchants.ini (MerchantScanner's format): [Npc##zone] _Zone=<zone>, then <item>=1 per item sold.
-- Returns byItem[lower item] = { {npc=, zone=}, ... }
function Config.parse_merchants(doc)
    local byItem, byZone = {}, {}
    for _, sec in ipairs(doc.order) do
        local s = doc.sections[sec]
        local zone = s.map._Zone
        local npc = sec:gsub('##.*$', '')
        if zone then
            byZone[zone:lower()] = byZone[zone:lower()] or {}
            table.insert(byZone[zone:lower()], npc)
            for _, kv in ipairs(s.keys) do
                if kv[1] ~= '_Zone' then
                    local k = kv[1]:lower()
                    byItem[k] = byItem[k] or {}
                    table.insert(byItem[k], { npc = npc, zone = zone:lower() })
                end
            end
        end
    end
    return byItem, byZone
end

-- travel.ini: [<from>><to>] hops (from may be *), plus [Bankers] Zones=, [Safe], [Faction], [Mirror], [Arrive].
function Config.parse_travel(doc, problems)
    local hops, bankers, arrive, mirror, safe, faction = {}, {}, {}, {}, {}, {}
    for _, sec in ipairs(doc.order) do
        local m = doc.sections[sec].map
        if sec == 'Faction' then
            -- zones whose merchants sell only to characters with the faction (conned before buying, 2.42.0)
            for _, z in ipairs(Ini.list(m.Zones)) do faction[z:lower()] = true end
        elseif sec == 'Mirror' then
            -- <zone>=<npc>|<keyword>[|<y x z>]: the zone's AFK mirror
            for _, kv in ipairs(doc.sections[sec].keys) do
                local npc, say, near = kv[2]:match('^(.-)|(.-)|(.+)$')
                if not npc then npc, say = kv[2]:match('^(.-)|(.+)$') end
                local loc
                if near then
                    local y, x, z = near:match('^%s*(%-?[%d.]+)%s+(%-?[%d.]+)%s+(%-?[%d.]+)%s*$')
                    loc = y and { tonumber(y), tonumber(x), tonumber(z) }
                end
                if npc and say and (not near or loc) then
                    mirror[kv[1]:lower()] = { npc = npc, say = say, near = loc }
                else
                    problems[#problems + 1] = string.format('travel.ini [Mirror] %s= is not "<npc>|<keyword>[|<y x z>]"', kv[1])
                end
            end
        elseif sec == 'Safe' then
            for _, z in ipairs(Ini.list(m.Zones)) do safe[z:lower()] = true end
        elseif sec == 'Bankers' then
            for _, z in ipairs(Ini.list(m.Zones)) do bankers[z:lower()] = true end
        elseif sec == 'Arrive' then
            -- <zone>=<npc name> or <zone>=<y x z>: where to go first after zoning in
            for _, kv in ipairs(doc.sections[sec].keys) do
                local y, x, z = kv[2]:match('^(%-?[%d.]+)%s+(%-?[%d.]+)%s+(%-?[%d.]+)$')
                arrive[kv[1]:lower()] = y and { loc = { tonumber(y), tonumber(x), tonumber(z) } } or { npc = kv[2] }
            end
        else
            local from, to = sec:match('^(.-)>(.+)$')
            local how = m.How and m.How:lower()
            -- door: Near= optional (2.42.0: without it, the door's own spot); run: walk to Near, face Heading and
            -- run on until the zone changes (a zone line - the old LazCraft's Greater Faydark -> Felwithe)
            local need = ({ aa = { 'AA' }, say = { 'Npc', 'Say' }, door = { 'Door' }, run = { 'Near', 'Heading' } })[how or '']
            local missing
            for _, k in ipairs(need or {}) do if not m[k] then missing = k end end
            if not from or not need or missing then
                problems[#problems + 1] = string.format('travel.ini [%s] needs [<from>><to>], How=aa|say|door|run and its keys%s',
                    sec, missing and (' (no ' .. missing .. '=)') or '')
            else
                local near
                if m.Near then
                    local y, x, z = m.Near:match('^(%-?[%d.]+)%s+(%-?[%d.]+)%s+(%-?[%d.]+)$')
                    near = y and { tonumber(y), tonumber(x), tonumber(z) }
                    if not near then problems[#problems + 1] = string.format('travel.ini [%s] Near= is not "y x z"', sec) end
                end
                local heading = m.Heading and tonumber(m.Heading)
                if m.Heading and not heading then problems[#problems + 1] = string.format('travel.ini [%s] Heading= is not a number', sec) end
                hops[#hops + 1] = { from = from:lower(), to = to:lower(), how = how, aa = m.AA, npc = m.Npc,
                                    say = m.Say, door = m.Door, near = near, heading = heading, name = sec }
            end
        end
    end
    return { hops = hops, bankers = bankers, arrive = arrive, mirror = mirror, safe = safe, faction = faction }
end

-- The fewest hops from one zone to another over travel.ini: a list of hops (empty when already there), or nil.
function Config.travel_path(travel, from, to)
    from, to = from:lower(), to:lower()
    if from == to then return {} end
    local came, frontier = { [from] = false }, { from }
    while #frontier > 0 do
        local nextf = {}
        for _, z in ipairs(frontier) do
            for _, h in ipairs(travel.hops) do
                if (h.from == z or h.from == '*') and h.to ~= z and came[h.to] == nil then
                    came[h.to] = { hop = h, prev = z }
                    if h.to == to then
                        local path, at = {}, to
                        while came[at] do table.insert(path, 1, came[at].hop); at = came[at].prev end
                        return path
                    end
                    nextf[#nextf + 1] = h.to
                end
            end
        end
        frontier = nextf
    end
    return nil
end

-- nav.ini: per zone, the ways around geometry (see the file's header). Returns zone (lower) ->
-- { hubs = { {y,x,z,r} }, docks = { a = {y,x,z} (X<0), b = {y,x,z} (X>0) },
--   pocket = { hub, dock, split, upper, npcs = set }, spots = { {y,x,z,r,crouch} } }
local function yxz(s)
    local y, x, z = (s or ''):match('^%s*(%-?[%d.]+)%s+(%-?[%d.]+)%s+(%-?[%d.]+)%s*$')
    return y and { tonumber(y), tonumber(x), tonumber(z) }
end
function Config.parse_nav(doc, problems)
    local out = {}
    for _, sec in ipairs(doc.order) do
        local z = { hubs = {}, spots = {} }
        local function bad(k, want) problems[#problems + 1] = string.format('nav.ini [%s] %s= is not "%s"', sec, k, want) end
        for _, kv in ipairs(doc.sections[sec].keys) do
            local k, v = kv[1], kv[2]
            if k:match('^Hub') then
                local y, x, zz, r = v:match('^(%-?[%d.]+)%s+(%-?[%d.]+)%s+(%-?[%d.]+)%s+([%d.]+)$')
                if y then z.hubs[#z.hubs + 1] = { tonumber(y), tonumber(x), tonumber(zz), r = tonumber(r), name = k }
                else bad(k, 'y x z radius') end
            elseif k:match('^Spot') then
                local y, x, zz, r, rest = v:match('^(%-?[%d.]+)%s+(%-?[%d.]+)%s+(%-?[%d.]+)%s+([%d.]+)%s*(.*)$')
                if y then z.spots[#z.spots + 1] = { tonumber(y), tonumber(x), tonumber(zz), r = tonumber(r),
                                                    crouch = rest:lower() == 'crouch', name = k }
                else bad(k, 'y x z radius [crouch]') end
            elseif k == 'SideDocks' then
                local a, b, near = v:match('^(.-)|([^|]*)|?%s*([%d.]*)%s*$')
                a, b = yxz(a), yxz(b)
                if a and b then
                    if a[2] > b[2] then a, b = b, a end
                    z.docks = { a = a, b = b, near = tonumber(near) }
                else bad(k, 'y x z | y x z [| near]') end
            elseif k == 'Pocket' then
                local p = {}
                for part in (v .. '|'):gmatch('(.-)|') do p[#p + 1] = part end
                local hub, dock, split, upper = yxz(p[1]), yxz(p[2]), tonumber(p[3]), tonumber(p[4])
                if hub and dock and split and upper then
                    z.pocket = z.pocket or { npcs = {} }
                    z.pocket.hub, z.pocket.dock, z.pocket.split, z.pocket.upper = hub, dock, split, upper
                else bad(k, 'y x z | y x z | split X | upper Z') end
            elseif k == 'Bridge' then
                local a, f, h = v:match('^(.-)|(.-)|%s*(%-?[%d.]+)%s*$')
                local near = a and yxz(a)
                local fy, fx = (f or ''):match('^%s*(%-?[%d.]+)%s+(%-?[%d.]+)%s*$')
                if near and fy then z.bridge = { near = near, far = { tonumber(fy), tonumber(fx) }, heading = tonumber(h) }
                else bad(k, 'y x z | y x | heading') end
            elseif k:match('^Avoid') then
                -- Avoid<n>=y x [z], y x [z], ... | margin: a box no walk goes through (blocks/routes rule 5)
                local list, margin = v:match('^(.-)|%s*([%d.]+)%s*$')
                list = list or v
                local pts, zs, zn = {}, 0, 0
                for part in list:gmatch('[^,]+') do
                    local y, x, h = part:match('^%s*(%-?[%d.]+)%s+(%-?[%d.]+)%s*(%-?[%d.]*)')
                    if y then
                        pts[#pts + 1] = { tonumber(y), tonumber(x) }
                        if tonumber(h) then zs, zn = zs + tonumber(h), zn + 1 end
                    end
                end
                if #pts >= 3 then
                    z.avoid = z.avoid or {}
                    -- the floor height round the box, when the corners give it (2.42.17: a corner leg walked at a
                    -- height guessed between the walk's two ends had no nav path - the pillars' floor is -48.6)
                    z.avoid[#z.avoid + 1] = { pts = pts, margin = tonumber(margin) or 10, name = k, z = zn > 0 and zs / zn or nil }
                else bad(k, 'y x, y x, y x[, ...] [| margin]') end
            elseif k == 'PocketNpcs' then
                z.pocket = z.pocket or { npcs = {} }
                for _, n in ipairs(Ini.list(v)) do z.pocket.npcs[n:lower()] = true end
            else
                problems[#problems + 1] = string.format('nav.ini [%s] %s= is not a known key', sec, k)
            end
        end
        if z.pocket and not z.pocket.hub then
            problems[#problems + 1] = string.format('nav.ini [%s] PocketNpcs= without Pocket=', sec)
            z.pocket = nil
        end
        out[sec:lower()] = z
    end
    return out
end

-- items.ini (tools/parse_items.py, from the Alla item pages): Name=<id>|<value>|<zone>><npc>><price>;...
-- -> lower name -> { name, id, value (copper), sellers = { { zone, npc, price } } }
function Config.parse_items(doc)
    local out = {}
    local sec = doc.sections.Items
    for _, kv in ipairs(sec and sec.keys or {}) do
        local id, value, rest = kv[2]:match('^(%d+)|(%d+)|(.*)$')
        if id then
            local it = { name = kv[1], id = tonumber(id), value = tonumber(value), sellers = {} }
            for part in rest:gmatch('[^;]+') do
                local z, npc, price = part:match('^(.-)>(.-)>(%d+)$')
                if z then it.sellers[#it.sellers + 1] = { zone = z:lower(), npc = npc, price = tonumber(price) } end
            end
            out[kv[1]:lower()] = it
        end
    end
    return out
end

-- The harvest's merchants join merchants.ini's (a scan in game): every one not listed yet is added, with its
-- price. Returns how many were added.
function Config.merge_item_merchants(cfg)
    local added = 0
    for k, it in pairs(cfg.items or {}) do
        local list = cfg.merchants[k] or {}
        cfg.merchants[k] = list
        local have = {}
        for _, v in ipairs(list) do have[v.npc:lower() .. '|' .. v.zone] = v end
        for _, s in ipairs(it.sellers) do
            local key = s.npc:lower() .. '|' .. s.zone
            if have[key] then
                have[key].price = have[key].price or s.price
            else
                local v = { npc = s.npc, zone = s.zone, price = s.price }
                list[#list + 1] = v; have[key] = v; added = added + 1
                cfg.merchantsByZone[s.zone] = cfg.merchantsByZone[s.zone] or {}
                local byZ, there = cfg.merchantsByZone[s.zone], false
                for _, n in ipairs(byZ) do if n:lower() == s.npc:lower() then there = true; break end end
                if not there then byZ[#byZ + 1] = s.npc end
            end
        end
        if #list == 0 then cfg.merchants[k] = nil end
    end
    return added
end

-- onRead(file): told of every data file read (core/datacache keys its cache on them)
function Config.load(dataDir, sleep, onRead)
    local problems = {}
    local function doc(file)
        if onRead then onRead(file) end
        local d, err = Ini.load(dataDir .. file, sleep)
        if not d then
            problems[#problems + 1] = string.format('%s could not be read (%s)', file, tostring(err))
            return { order = {}, sections = {} }
        end
        return d
    end
    local cfg = {}
    cfg.containers, cfg.containerByBag = Config.parse_containers(doc('containers.ini'), problems)
    cfg.skills, cfg.collections, cfg.levelAll, cfg.skillOrder, cfg.collectionOpts = Config.parse_skills(doc('skills.ini'), problems)
    local pdoc = doc('producers.ini')
    cfg.producers = Config.parse_producers(pdoc, problems)
    cfg.producerOrder = pdoc.order   -- items in the file's order (the Summon tab lists them so)
    cfg.lists = Config.parse_lists(doc('lists.ini'))
    cfg.recipes = Config.parse_recipes(doc('recipes.ini'), problems)
    if onRead then onRead('recipes_local.ini'); onRead('research.ini') end
    local localDoc = Ini.load(dataDir .. 'recipes_local.ini', sleep)
    if localDoc then Config.parse_recipes(localDoc, problems, cfg.recipes) end
    local rdoc = Ini.load(dataDir .. 'research.ini', sleep)
    cfg.research = rdoc and Config.parse_research(rdoc, cfg.recipes, problems) or { classes = {}, index = {}, levels = {} }
    cfg.recipesByName = Config.index_recipes(cfg.recipes)
    -- a recipe whose data has no Skill (the old converted ones) gets its container's (containers.ini Skill=);
    -- cfg.skillNames is every tradeskill a recipe has, sorted (the Craft tab's list)
    local seen = {}
    cfg.skillNames = {}
    for _, r in pairs(cfg.recipes) do
        if not r.skill or r.skill == '' then
            local c = cfg.containers[r.container]
            r.skill = c and c.skill or nil
        end
        if r.skill and not seen[r.skill] then seen[r.skill] = true; cfg.skillNames[#cfg.skillNames + 1] = r.skill end
    end
    table.sort(cfg.skillNames)
    cfg.merchants, cfg.merchantsByZone = Config.parse_merchants(doc('merchants.ini'))
    cfg.items = Config.parse_items(doc('items.ini'))
    cfg.harvestMerchants = Config.merge_item_merchants(cfg)
    cfg.travel = Config.parse_travel(doc('travel.ini'), problems)
    cfg.nav = Config.parse_nav(doc('nav.ini'), problems)
    -- what to wear per skill, best first: skills.ini Trophy= then Clicky= (the leveling aids)
    cfg.modifiers = {}
    for name, sk in pairs(cfg.skills) do
        local list = {}
        for _, t in ipairs(sk.trophy or {}) do list[#list + 1] = t end
        for _, c in ipairs(sk.clicky or {}) do list[#list + 1] = c end
        if #list > 0 then cfg.modifiers[name] = list end
    end
    return cfg, problems
end

-- Per-character settings. Unknown keys in the file are kept so a newer build's settings survive an older one.
Config.SETTING_DEFAULTS = {
    LogToFile = '1',        -- on by default: every step goes to lua/lazcraft/logs (what a report is read from)
    StatusFile = '1',       -- logs/LazCraft_<name>_status.txt rewritten each second: what it is doing now (2.44.0)
    LogLevel = 'info',      -- console and window
    LogFileLevel = 'debug', -- the file
    ItemPaceMs = '0',      -- the shortest time from one item starting to the next; 0 = no wait
    ClickPace = 'auto',    -- auto: QuietMs is learned (core/pace) - widens when the game desyncs; fixed: used as set
    ClickFloorMs = '34',   -- the least time between two inventory clicks: a frame, so a pickup and its drop never share one
    QuietMs = '300',       -- listen this long for desync lines before each /combine (2.46.7); in auto, the start and what it learned
    Network = 'auto',      -- messages to other characters: auto (DanNet, then E3, then EQBC), dannet, e3, eqbc
    Workers = '',          -- crafter: workers it has heard from, asked again on start
    RequestOverPP = '20',  -- an item a merchant sells for more than this (pp, a unit) is asked for on the network first; 0 = never
    Theme = 'Midnight',    -- the window's look (ui/theme): Midnight, Slate, Ember, Glass; a worker takes its crafter's
    ShowLogo = '1',        -- 0 = the LC mark instead of the logo image (2.43.1)
}

-- Settings that no longer exist; dropped from the file on the next start so nothing stale lingers.
Config.RETIRED_SETTINGS = { 'PaceStowMs', 'PaceBagOpenMs', 'PacePickupMs', 'PacePlaceMs', 'ClickGapMs' }

-- What the Settings tab shows, in order, under its section headings (2.43.0).
Config.SETTINGS_META = {
    { key = 'Theme',         kind = 'theme', section = 'Look', label = 'Theme',
      help = 'the window\'s colours and corners; workers working for you take the same one' },
    { key = 'ClickPace',     kind = 'choice', section = 'Pacing', choices = { 'auto', 'fixed' }, label = 'Click pace',
      help = 'auto = the quiet window below is learned: it widens when the game says its inventory is out of step, and narrows after clean combines; fixed = used exactly as set' },
    { key = 'QuietMs',       kind = 'ms', section = 'Pacing', label = 'Quiet window before combine',
      help = 'items go in fast; before each combine the game gets this long to say it is out of step (a desync), and if it does the round is placed again. In auto this is where it starts and what it has learned' },
    { key = 'ClickFloorMs',  kind = 'ms', section = 'Pacing', label = 'Least time between clicks',
      help = 'never two inventory clicks closer than this (34 = a frame, so a pickup and its drop never share one)' },
    { key = 'ItemPaceMs',    kind = 'ms', section = 'Pacing', label = 'Item pace',
      help = 'shortest time from one item starting to the next (pickup, placing, stowing); time already spent counts. 0 = no wait' },
    { key = 'RequestOverPP', kind = 'pp', section = 'Money', label = 'Ask the network first over',
      help = 'an ingredient a merchant sells for more than this a unit (Alla price) is asked for on the network before buying; 0 = always buy. The clean-up after a leveling row sells ingredients under it' },
    { key = 'Network',       kind = 'choice', section = 'Workers and log', choices = { 'auto', 'dannet', 'e3', 'eqbc' }, label = 'Network',
      help = 'how characters talk: auto = DanNet, then E3, then EQBC' },
    { key = 'LogLevel',      kind = 'choice', section = 'Workers and log', choices = { 'info', 'debug' }, label = 'Window and console show',
      help = 'info = normal messages, debug = every step' },
    { key = 'LogToFile',     kind = 'bool', section = 'Workers and log', label = 'Write a log file', help = 'every step, to lua/lazcraft/logs' },
    { key = 'StatusFile',    kind = 'bool', section = 'Workers and log', label = 'Write a live status file', help = 'what it is doing right now, rewritten each second: lua/lazcraft/logs/LazCraft_<name>_status.txt' },
    { key = 'LogFileLevel',  kind = 'choice', section = 'Workers and log', choices = { 'debug', 'info' }, label = 'Log file gets',
      help = 'debug = every step (best for reports)' },
}

function Config.load_settings(path, sleep)
    local settings = {}
    for k, v in pairs(Config.SETTING_DEFAULTS) do settings[k] = v end
    local d = Ini.load(path, sleep)
    if d and d.sections.Settings then
        for _, kv in ipairs(d.sections.Settings.keys) do settings[kv[1]] = kv[2] end
    end
    for _, k in ipairs(Config.RETIRED_SETTINGS) do settings[k] = nil end
    return settings
end

function Config.save_settings(path, settings)
    local keys = {}
    for k in pairs(settings) do keys[#keys + 1] = k end
    table.sort(keys)
    local list = {}
    for _, k in ipairs(keys) do list[#list + 1] = { k, settings[k] } end
    return Ini.write(path, { { name = 'Settings', keys = list } })
end

return Config
