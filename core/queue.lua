-- Queue: a list of things to make, run one after another under one Go (engine/make Make.queue). Shared by
-- the Craft and Research tabs, saved per character (settings/LazCraft_<Me>_queue.ini - updates never
-- replace it) on every change, so a restart or a crash keeps it.
--   Queue.new{ path, log, sleep }
--   list()                         entries in order: { id, kind = 'craft'|'research', recipe = id, n, disposal }
--   add(kind, recipeId, n, disposal)  a craft entry is n combines (as Make); a research entry n in hand
--                                  (failures made again). The same recipe and kind twice adds to its n.
--   remove(id), move(id, -1|1), set_n(id, n), clear()
-- File: [Queue] Entry=<kind>|<recipe id>|<n>|<disposal>
local Ini = require('core.ini')

local Queue = {}
Queue.__index = Queue

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local KINDS = { craft = true, research = true }
local DISPOSALS = { keep = true, sell = true, destroy = true }

function Queue.new(deps)
    local q = setmetatable({ file = deps.path, log = deps.log or NOLOG, items = {}, seq = 0 }, Queue)
    local doc = deps.path and Ini.load(deps.path, deps.sleep)
    local sec = doc and doc.sections.Queue
    for _, kv in ipairs(sec and sec.keys or {}) do
        local kind, id, n, d = kv[2]:match('^(%a+)|([^|]+)|(%d+)|?(%a*)$')
        if kind and KINDS[kind] and tonumber(n) and tonumber(n) > 0 then
            q.seq = q.seq + 1
            q.items[#q.items + 1] = { id = q.seq, kind = kind, recipe = id, n = tonumber(n), disposal = DISPOSALS[d] and d or 'keep' }
        end
    end
    return q
end

function Queue:list() return self.items end

function Queue:save()
    if not self.file then return end
    local keys = {}
    for _, e in ipairs(self.items) do keys[#keys + 1] = { 'Entry', string.format('%s|%s|%d|%s', e.kind, e.recipe, e.n, e.disposal) } end
    local ok, err = Ini.write(self.file, { { name = 'Queue', keys = keys } },
        '; The make queue (the Craft and Research tabs write this). Entry=<craft|research>|<recipe id>|<n>|<keep|sell|destroy>')
    if not ok then self.log.warn('Could not save %s (%s)', self.file, tostring(err)) end
end

local function find(self, id)
    for i, e in ipairs(self.items) do if e.id == id then return i, e end end
end

function Queue:add(kind, recipeId, n, disposal)
    if not KINDS[kind] or not recipeId or not n or n < 1 then return nil end
    for _, e in ipairs(self.items) do
        if e.kind == kind and e.recipe == recipeId then
            e.n = e.n + n
            if disposal and DISPOSALS[disposal] then e.disposal = disposal end
            self:save()
            return e
        end
    end
    self.seq = self.seq + 1
    local e = { id = self.seq, kind = kind, recipe = recipeId, n = n, disposal = DISPOSALS[disposal] and disposal or 'keep' }
    self.items[#self.items + 1] = e
    self:save()
    return e
end

function Queue:remove(id)
    local i = find(self, id)
    if i then table.remove(self.items, i); self:save() end
end

function Queue:move(id, d)
    local i = find(self, id)
    local j = i and i + d
    if not i or j < 1 or j > #self.items then return end
    self.items[i], self.items[j] = self.items[j], self.items[i]
    self:save()
end

function Queue:set_n(id, n)
    local _, e = find(self, id)
    if e and n and n >= 1 and e.n ~= n then e.n = n; self:save() end
end

function Queue:clear()
    self.items = {}
    self:save()
end

return Queue
