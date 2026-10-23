-- Casters: who on the network can make a summoned item (producers.ini), remembered across sessions, so a plan
-- can name - and start - a caster that is not running yet (2.41.9; 2.41.7 log: Pottery said "no worker has" Vial
-- of Clear Mana while Shela, who casts it, simply was not started).
--   Casters.new{ path, log, sleep }     the crafter's file: settings/LazCraft_<Me>_casters.ini
--   set_casts(name, items)               a worker's card: what it casts now (from its spellbook)
--   set_class(name, class)               its class (the card, or DanNet for one never started)
--   class_of(name), casts(name)
--   set_lacks(name, item)                started for it, but its card did not list it: the spell is not scribed
--   candidates(item, producer, ok(name)) -> { { name, why } } who could make it, best first:
--       cast it before (its last card listed it), then of a class producers.ini names (Classes=) - leaving out
--       anyone known to lack the spell; ok(name) filters (in a safe zone, not running already, ...)
-- File: [<Name>] Class=<class>  Level=<n>  Casts=<item>|<item>...  Lacks=<item>|...  Checked=1 (its book was read)
local Ini = require('core.ini')

local Casters = {}
Casters.__index = Casters

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local function lower(s) return (s or ''):lower() end

-- The EverQuest classes (a DanNet answer is taken as a class only when it is one of these).
Casters.CLASSES = {}
for _, c in ipairs({ 'Bard', 'Beastlord', 'Berserker', 'Cleric', 'Druid', 'Enchanter', 'Magician', 'Monk', 'Necromancer',
                     'Paladin', 'Ranger', 'Rogue', 'Shadow Knight', 'Shaman', 'Warrior', 'Wizard' }) do
    Casters.CLASSES[lower(c)] = c
end

local function split(v)
    local out = {}
    for part in (v or ''):gmatch('[^|]+') do
        local t = part:gsub('^%s+', ''):gsub('%s+$', '')
        if t ~= '' then out[#out + 1] = t end
    end
    return out
end

function Casters.new(deps)
    local c = setmetatable({ path = deps.path, log = deps.log or NOLOG, people = {} }, Casters)
    local doc = deps.path and Ini.load(deps.path, deps.sleep)
    for _, name in ipairs(doc and doc.order or {}) do
        local m = doc.sections[name].map
        local e = { name = name, class = m.Class ~= '' and m.Class or nil, casts = {}, lacks = {},
                    level = tonumber(m.Level), checked = m.Checked == '1' }
        for _, it in ipairs(split(m.Casts)) do e.casts[lower(it)] = it end
        for _, it in ipairs(split(m.Lacks)) do e.lacks[lower(it)] = it end
        c.people[lower(name)] = e
    end
    return c
end

function Casters:entry(name)
    local k = lower(name)
    local e = self.people[k]
    if not e then e = { name = name, casts = {}, lacks = {} }; self.people[k] = e end
    return e
end

function Casters:save()
    if not self.path then return end
    local names = {}
    for _, e in pairs(self.people) do names[#names + 1] = e end
    table.sort(names, function(a, b) return lower(a.name) < lower(b.name) end)
    local secs = {}
    for _, e in ipairs(names) do
        local casts, lacks = {}, {}
        for _, v in pairs(e.casts) do casts[#casts + 1] = v end
        for _, v in pairs(e.lacks) do lacks[#lacks + 1] = v end
        table.sort(casts); table.sort(lacks)
        secs[#secs + 1] = { name = e.name, keys = { { 'Class', e.class or '' }, { 'Level', e.level and tostring(e.level) or '' },
                                                    { 'Casts', table.concat(casts, '|') }, { 'Lacks', table.concat(lacks, '|') },
                                                    { 'Checked', e.checked and '1' or '' } } }
    end
    local ok, err = Ini.write(self.path, secs,
        '; Who casts what (LazCraft remembers each worker\'s card). Lacks = started for it, but the spell was not scribed.')
    if not ok then self.log.warn('Could not save %s (%s)', self.path, tostring(err)) end
end

function Casters:class_of(name) local e = self.people[lower(name)]; return e and e.class end
function Casters:level_of(name) local e = self.people[lower(name)]; return e and e.level end
function Casters:checked(name) local e = self.people[lower(name)]; return e ~= nil and e.checked == true end

-- Its spellbook, read over DanNet (engine/books, 2.42.12): what it casts and what its class could but it has not
-- scribed (both replace what was known); casts = nil: under the level that is checked, only the level kept.
function Casters:set_book(name, level, casts, missing)
    local e = self:entry(name)
    e.level, e.checked = level or e.level, true
    if casts then
        e.casts, e.lacks = {}, {}
        for _, it in ipairs(casts) do e.casts[lower(it)] = it end
        for _, it in ipairs(missing or {}) do e.lacks[lower(it)] = it end
    end
    self:save()
end

-- What it lacks (sorted): its class could cast these, its book or card says it cannot.
function Casters:lacks_list(name)
    local e = self.people[lower(name)]
    local out = {}
    for _, v in pairs(e and e.lacks or {}) do out[#out + 1] = v end
    table.sort(out)
    return out
end
function Casters:casts(name)
    local e = self.people[lower(name)]
    local out = {}
    for _, v in pairs(e and e.casts or {}) do out[#out + 1] = v end
    table.sort(out)
    return out
end

function Casters:set_class(name, class)
    local c = Casters.CLASSES[lower(class)]
    if not c then return end
    local e = self:entry(name)
    if e.class ~= c then e.class = c; self:save() end
end

-- A card: what it casts now. Anything it now casts is no longer "lacks".
function Casters:set_casts(name, items)
    local e = self:entry(name)
    local now, changed = {}, false
    for _, it in ipairs(items or {}) do now[lower(it)] = it end
    for k in pairs(e.casts) do if not now[k] then changed = true end end
    for k, v in pairs(now) do
        if not e.casts[k] then changed = true end
        if e.lacks[k] then e.lacks[k] = nil; changed = true end
    end
    e.casts = now
    if changed then self:save() end
end

function Casters:set_lacks(name, item)
    local e = self:entry(name)
    if not e.lacks[lower(item)] then e.lacks[lower(item)] = item; self:save() end
end

function Casters:lacks(name, item)
    local e = self.people[lower(name)]
    return e ~= nil and e.lacks[lower(item)] ~= nil
end

-- Who was started for it and did not have the spell (names, sorted).
function Casters:lacking(item)
    local out = {}
    for _, e in pairs(self.people) do if e.lacks[lower(item)] then out[#out + 1] = e.name end end
    table.sort(out, function(a, b) return lower(a) < lower(b) end)
    return out
end

function Casters:candidates(item, producer, ok)
    local out, seen = {}, {}
    local k = lower(item)
    local classes = {}
    for _, c in ipairs(producer and producer.classes or {}) do classes[lower(c)] = true end
    local list = {}
    for _, e in pairs(self.people) do list[#list + 1] = e end
    table.sort(list, function(a, b) return lower(a.name) < lower(b.name) end)
    for _, e in ipairs(list) do
        if e.casts[k] and not e.lacks[k] and (not ok or ok(e.name)) then
            seen[lower(e.name)] = true
            out[#out + 1] = { name = e.name, why = 'cast it before' }
        end
    end
    for _, e in ipairs(list) do
        if not seen[lower(e.name)] and e.class and classes[lower(e.class)] and not e.lacks[k] and (not ok or ok(e.name)) then
            out[#out + 1] = { name = e.name, why = e.class }
        end
    end
    return out
end

return Casters
