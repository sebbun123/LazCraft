-- Stacks: how many of an item fit in one bag slot (1 = does not stack).
--   Stacks.new{ shipped = path, learned = path, log, sleep }
--   size(name)            known size, or nil
--   learn(name, size, where)   the game showed it (a merchant window, a stack in the bags); saved at once when new
--   from_item(name, it)   learn from an item TLO (Stackable/StackSize); returns the size or nil
--
-- Rules it keeps:
--   * Stacking belongs to the item, so one look settles it for good. What the game showed is written to the
--     learned file (settings/stacks.ini - updates never replace it) and wins over the shipped list
--     (data/stacks.ini, the old LazCraft's buylast flags).
--   * Nothing is guessed: an item never seen is unknown (nil), and the merchant checks it before buying.
local Ini = require('core.ini')

local Stacks = {}
Stacks.__index = Stacks

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local function lower(s) return (s or ''):lower() end

local function read(path, sleep)
    local out, names = {}, {}
    if not path then return out, names end
    local doc = Ini.load(path, sleep)
    local sec = doc and doc.sections.Stacks
    for _, kv in ipairs(sec and sec.keys or {}) do
        local n = tonumber(kv[2])
        if n and n >= 1 then out[lower(kv[1])] = math.floor(n); names[lower(kv[1])] = kv[1] end
    end
    return out, names
end

function Stacks.new(deps)
    local s = setmetatable({ log = deps.log or NOLOG, learnedPath = deps.learned, sleep = deps.sleep }, Stacks)
    s.shipped = read(deps.shipped, deps.sleep)
    s.learned, s.names = read(deps.learned, deps.sleep)
    return s
end

function Stacks:size(name)
    local k = lower(name)
    return self.learned[k] or self.shipped[k]
end

function Stacks:save()
    if not self.learnedPath then return end
    -- other characters share the file: take in what they learned since we read it
    local cur, names = read(self.learnedPath, self.sleep)
    for k, v in pairs(cur) do
        if not self.learned[k] then self.learned[k], self.names[k] = v, names[k] end
    end
    local keys = {}
    for k in pairs(self.learned) do keys[#keys + 1] = k end
    table.sort(keys)
    local list = {}
    for _, k in ipairs(keys) do list[#list + 1] = { self.names[k] or k, tostring(self.learned[k]) } end
    local ok, err = Ini.write(self.learnedPath, { { name = 'Stacks', keys = list } },
        '; Learned in game: how many of an item fit in one bag slot (1 = does not stack). Wins over data/stacks.ini.')
    if not ok then self.log.warn('Could not save %s (%s)', self.learnedPath, tostring(err)) end
end

function Stacks:learn(name, size, where)
    size = tonumber(size)
    if not name or not size or size < 1 then return end
    local k = lower(name)
    if self.learned[k] == size then return end
    local was = self:size(name)
    self.learned[k], self.names[k] = size, name
    self.log.debug('  %s %s (%s)%s', name, size == 1 and 'does not stack' or ('stacks to ' .. size), where or 'seen',
        was and was ~= size and string.format(' - the list said %d', was) or '')
    self:save()
end

-- An item TLO (a merchant's item, one in the bags): Stackable false = 1, else its StackSize.
function Stacks:from_item(name, it, where)
    if not it or (it.ID() or 0) == 0 then return nil end
    local size
    if it.Stackable() == true then size = tonumber(it.StackSize()) else size = 1 end
    if not size or size < 1 then return nil end
    self:learn(name, size, where)
    return size
end

return Stacks
