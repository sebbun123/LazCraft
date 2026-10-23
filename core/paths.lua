-- Paths: this character's own changes to the skills.ini leveling paths, kept in its own file
-- (settings/LazCraft_<Me>_paths.ini - updates never replace it), the old LazCraft's per-character
-- path additions.
--   Paths.new{ path, log, sleep }
--   changes(skill)              -> { adds = { { id, disposal } }, removed = { lower rung name = true } }
--   add(skill, id, disposal)    a recipe added to the path (by id; sits by its trivial)
--   remove(skill, rungName)     a skills.ini rung left out of the path
--   forget(skill, id)           an added recipe taken off again
--   disposal(skill, id, d)      an added recipe's product choice
--   restore(skill)              the path back to skills.ini
-- Every change is saved at once.
--
-- File:  [Blacksmithing]
--        Add=O1947, sell
--        Remove=Tungsten Metal Bits
local Ini = require('core.ini')

local Paths = {}
Paths.__index = Paths

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local function lower(s) return (s or ''):lower() end
local function trim(s) return ((s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end
local DISPOSALS = { keep = true, sell = true, destroy = true }

function Paths.new(deps)
    local p = setmetatable({ file = deps.path, log = deps.log or NOLOG, sleep = deps.sleep, skills = {}, order = {} }, Paths)
    local doc = deps.path and Ini.load(deps.path, deps.sleep)
    for _, name in ipairs(doc and doc.order or {}) do
        local sec = doc.sections[name]
        local c = p:get(name)
        for _, kv in ipairs(sec and sec.keys or {}) do
            local k = lower(kv[1])
            if k == 'add' then
                local id, d = kv[2]:match('^%s*([^,]-)%s*,%s*(%a+)%s*$')
                id = id or trim(kv[2])
                if id ~= '' then c.adds[#c.adds + 1] = { id = id, disposal = DISPOSALS[lower(d)] and lower(d) or 'sell' } end
            elseif k == 'remove' and trim(kv[2]) ~= '' then
                c.removed[lower(trim(kv[2]))] = trim(kv[2])
            end
        end
    end
    return p
end

function Paths:get(skill)
    local c = self.skills[skill]
    if not c then
        c = { adds = {}, removed = {} }
        self.skills[skill] = c
        self.order[#self.order + 1] = skill
    end
    return c
end

function Paths:changes(skill) return self.skills[skill] or { adds = {}, removed = {} } end

function Paths:count(skill)
    local c = self:changes(skill)
    local n = #c.adds
    for _ in pairs(c.removed) do n = n + 1 end
    return n
end

function Paths:save()
    if not self.file then return end
    local sections = {}
    for _, skill in ipairs(self.order) do
        local c = self.skills[skill]
        local keys = {}
        for _, a in ipairs(c.adds) do keys[#keys + 1] = { 'Add', a.id .. ', ' .. a.disposal } end
        local rm = {}
        for _, name in pairs(c.removed) do rm[#rm + 1] = name end
        table.sort(rm)
        for _, name in ipairs(rm) do keys[#keys + 1] = { 'Remove', name } end
        if #keys > 0 then sections[#sections + 1] = { name = skill, keys = keys } end
    end
    local ok, err = Ini.write(self.file, sections,
        '; Your own changes to the skills.ini leveling paths (the Leveling tab writes this). Add=<recipe id>, <keep|sell|destroy>; Remove=<rung>')
    if not ok then self.log.warn('Could not save %s (%s)', self.file, tostring(err)) end
end

function Paths:add(skill, id, disposal)
    local c = self:get(skill)
    for _, a in ipairs(c.adds) do if lower(a.id) == lower(id) then return false end end
    c.adds[#c.adds + 1] = { id = id, disposal = DISPOSALS[disposal] and disposal or 'sell' }
    self:save()
    return true
end

function Paths:forget(skill, id)
    local c = self:get(skill)
    for i = #c.adds, 1, -1 do if lower(c.adds[i].id) == lower(id) then table.remove(c.adds, i) end end
    self:save()
end

function Paths:disposal(skill, id, d)
    if not DISPOSALS[d] then return end
    for _, a in ipairs(self:get(skill).adds) do
        if lower(a.id) == lower(id) and a.disposal ~= d then a.disposal = d; self:save() end
    end
end

function Paths:remove(skill, rungName)
    self:get(skill).removed[lower(rungName)] = rungName
    self:save()
end

function Paths:restore(skill)
    local c = self:get(skill)
    c.adds, c.removed = {}, {}
    self:save()
end

return Paths
