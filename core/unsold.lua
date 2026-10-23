-- Unsold: items the data says a merchant sells that its list in game did not have (2.42.3; 2.42.2 log: the Alla
-- pages list Borik Darkanvil in Plane of Marr as selling Jar of Lacquer - his 36 items there do not include it,
-- and the Stein row failed). Learned the moment a merchant's complete list is read without the item, shared by
-- every character, and taken out of cfg.merchants so no plan picks that merchant for it again.
--   Unsold.new{ path, merchants = cfg.merchants, log, sleep }   reads the file and takes its entries out
--   add(npc, zone, item) -> true when it was not known yet (saved at once, merged with other characters' saves)
--   remove(npc, zone, item) -> true when it was there: a list that does have it (2.43.7) - saved, and the merchant
--     is put back in the list for it
--   items_for(npc, zone) -> { item, ... } saved as not sold there
-- File: settings/unsold.ini   [Meta] Version=2   [Unsold] <npc>##<zone>=<item>|<item>...
-- A file without Version=2 was learned before 2.43.7, when a list read as complete too early could save an item
-- a merchant does sell (Audri Deepfacet, Platinum Bar): it is moved to unsold_old.ini once and we start empty.
local Ini = require('core.ini')

local Unsold = {}
Unsold.__index = Unsold

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
Unsold.VERSION = '2'
local HEADER = '; Items the data says a merchant sells that its list in game did not have (LazCraft learns these).'
local function lower(s) return (s or ''):lower() end

local function read(path, sleep)
    local out = {}   -- '<npc>##<zone>' lower -> { npc, zone, items = { lower item -> item } }
    local doc = path and Ini.load(path, sleep)
    for _, kv in ipairs(doc and doc.sections.Unsold and doc.sections.Unsold.keys or {}) do
        local npc, zone = kv[1]:match('^(.-)##(.+)$')
        if npc then
            local e = { npc = npc, zone = lower(zone), items = {} }
            for it in (kv[2] or ''):gmatch('[^|]+') do
                it = it:gsub('^%s+', ''):gsub('%s+$', '')
                if it ~= '' then e.items[lower(it)] = it end
            end
            out[lower(npc) .. '##' .. lower(zone)] = e
        end
    end
    return out
end

-- take npc/zone out of the merchants list for an item; what came out is kept in `taken` (to put back)
local taken = setmetatable({}, { __mode = 'k' })
local function drop(merchants, npc, zone, item)
    local list = merchants and merchants[lower(item)]
    if not list then return end
    taken[merchants] = taken[merchants] or {}
    local k = lower(npc) .. '##' .. lower(zone) .. '##' .. lower(item)
    for i = #list, 1, -1 do
        if lower(list[i].npc) == lower(npc) and lower(list[i].zone) == lower(zone) then
            local t = taken[merchants][k] or {}
            t[#t + 1] = table.remove(list, i)
            taken[merchants][k] = t
        end
    end
    if #list == 0 then merchants[lower(item)] = nil end
end
local function undrop(merchants, npc, zone, item)
    local k = lower(npc) .. '##' .. lower(zone) .. '##' .. lower(item)
    local t = merchants and taken[merchants] and taken[merchants][k]
    if not t then return end
    merchants[lower(item)] = merchants[lower(item)] or {}
    for _, v in ipairs(t) do table.insert(merchants[lower(item)], v) end
    taken[merchants][k] = nil
end

function Unsold.new(deps)
    local u = setmetatable({ path = deps.path, merchants = deps.merchants, log = deps.log or NOLOG, sleep = deps.sleep }, Unsold)
    -- once: a file from before 2.43.7 is moved aside and we start empty
    local doc = deps.path and Ini.load(deps.path, deps.sleep)
    local meta = doc and doc.sections.Meta and doc.sections.Meta.map or {}
    if doc and meta.Version ~= Unsold.VERSION then
        local text = Ini.read_file(deps.path, deps.sleep)
        local old = deps.path:gsub('%.ini$', '') .. '_old.ini'
        local fh = text and io.open(old, 'wb')
        if fh then fh:write(text); fh:close() end
        local ok, err = Ini.write(deps.path, { { name = 'Meta', keys = { { 'Version', Unsold.VERSION } } }, { name = 'Unsold', keys = {} } }, HEADER)
        u.log.info('Merchants: settings/unsold.ini was learned before 2.43.7 (a list read too early could save an item a merchant '
            .. 'does sell) - moved to %s and started empty%s', old:match('[^/\\]+$'), ok and '' or (' (could not write: ' .. tostring(err) .. ')'))
    end
    u.known = read(deps.path, deps.sleep)
    local n = 0
    for _, e in pairs(u.known) do
        for _, it in pairs(e.items) do drop(u.merchants, e.npc, e.zone, it); n = n + 1 end
    end
    if n > 0 then u.log.debug('Merchants: %d item%s not sold where the data says (settings/unsold.ini)', n, n == 1 and '' or 's') end
    return u
end

function Unsold:add(npc, zone, item)
    local k = lower(npc) .. '##' .. lower(zone)
    local e = self.known[k]
    if e and e.items[lower(item)] then drop(self.merchants, npc, zone, item); return false end
    if not e then e = { npc = npc, zone = lower(zone), items = {} }; self.known[k] = e end
    e.items[lower(item)] = item
    drop(self.merchants, npc, zone, item)
    -- other characters share the file: theirs since we read it are kept
    local cur = read(self.path, self.sleep)
    for kk, v in pairs(self.known) do
        local c = cur[kk]
        if not c then cur[kk] = v else for ik, it in pairs(v.items) do c.items[ik] = it end end
    end
    for _, v in pairs(cur) do for _, it in pairs(v.items) do drop(self.merchants, v.npc, v.zone, it) end end
    self.known = cur
    self:save()
    return true
end

function Unsold:save()
    local cur = self.known
    if self.path then
        local list = {}
        for _, v in pairs(cur) do if next(v.items) then list[#list + 1] = v end end
        table.sort(list, function(a, b) return lower(a.npc .. a.zone) < lower(b.npc .. b.zone) end)
        local keys = {}
        for _, v in ipairs(list) do
            local items = {}
            for _, it in pairs(v.items) do items[#items + 1] = it end
            table.sort(items)
            keys[#keys + 1] = { v.npc .. '##' .. v.zone, table.concat(items, '|') }
        end
        local ok, err = Ini.write(self.path, { { name = 'Meta', keys = { { 'Version', Unsold.VERSION } } }, { name = 'Unsold', keys = keys } }, HEADER)
        if not ok then self.log.warn('Could not save %s (%s)', self.path, tostring(err)) end
    end
end

function Unsold:items_for(npc, zone)
    local e = self.known[lower(npc) .. '##' .. lower(zone)]
    local out = {}
    for _, it in pairs(e and e.items or {}) do out[#out + 1] = it end
    table.sort(out)
    return out
end

function Unsold:remove(npc, zone, item)
    local k = lower(npc) .. '##' .. lower(zone)
    local e = self.known[k]
    if not (e and e.items[lower(item)]) then return false end
    -- other characters' saves since we read it are kept; this one comes out of theirs too
    local cur = read(self.path, self.sleep)
    for kk, v in pairs(self.known) do
        local c = cur[kk]
        if not c then cur[kk] = v else for ik, it in pairs(v.items) do c.items[ik] = it end end
    end
    if cur[k] then cur[k].items[lower(item)] = nil end
    self.known = cur
    undrop(self.merchants, npc, zone, item)
    self:save()
    return true
end

return Unsold
