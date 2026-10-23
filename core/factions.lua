-- Factions: where each character stands with each faction-zone merchant (travel.ini [Faction] Zones=), remembered
-- across sessions, so a plan knows who can buy there (2.42.0). Pure, no game calls: the con itself is blocks/faction.
--   Factions.STANDINGS        the game's con words, best first; Factions.BUY_MAX: worst that can still buy (apprehensively)
--   Factions.rank(word)       1 (ally) .. 9 (ready to attack), nil for anything else
--   Factions.can_buy(word)    rank <= BUY_MAX
--   Factions.new{ path, log, sleep }   the crafter's file: settings/LazCraft_<Me>_factions.ini
--   get(char, npc, zone)      the word last seen, or nil (never conned)
--   set(char, npc, zone, word)
--   barred(char, npc, zone)   the word when it was too low to buy, else nil (good, or never conned)
-- File: [<Character>] <Merchant>##<zone>=<word>
local Ini = require('core.ini')

local Factions = {}
Factions.__index = Factions

Factions.STANDINGS = { 'ally', 'warmly', 'kindly', 'amiably', 'indifferently', 'apprehensively', 'dubiously',
                       'threateningly', 'ready to attack' }
Factions.BUY_MAX = 6   -- apprehensively or better can buy (Project Lazarus)

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local function lower(s) return (s or ''):lower() end
local RANK = {}
for i, w in ipairs(Factions.STANDINGS) do RANK[w] = i end

function Factions.rank(word) return RANK[lower(word)] end
function Factions.can_buy(word)
    local r = RANK[lower(word)]
    return r ~= nil and r <= Factions.BUY_MAX
end

local function key(npc, zone) return lower(npc) .. '##' .. lower(zone) end

function Factions.new(deps)
    local f = setmetatable({ path = deps.path, log = deps.log or NOLOG, people = {} }, Factions)
    local doc = deps.path and Ini.load(deps.path, deps.sleep)
    for _, name in ipairs(doc and doc.order or {}) do
        local e = { name = name, seen = {} }
        for _, kv in ipairs(doc.sections[name].keys) do
            local npc, zone = kv[1]:match('^(.-)##(.+)$')
            if npc and RANK[lower(kv[2])] then e.seen[key(npc, zone)] = { npc = npc, zone = lower(zone), word = lower(kv[2]) } end
        end
        f.people[lower(name)] = e
    end
    return f
end

function Factions:save()
    if not self.path then return end
    local list = {}
    for _, e in pairs(self.people) do list[#list + 1] = e end
    table.sort(list, function(a, b) return lower(a.name) < lower(b.name) end)
    local secs = {}
    for _, e in ipairs(list) do
        local keys = {}
        for _, s in pairs(e.seen) do keys[#keys + 1] = { s.npc .. '##' .. s.zone, s.word } end
        table.sort(keys, function(a, b) return lower(a[1]) < lower(b[1]) end)
        secs[#secs + 1] = { name = e.name, keys = keys }
    end
    local ok, err = Ini.write(self.path, secs,
        '; Faction with faction-zone merchants, as each character last conned them (LazCraft). Apprehensively or better can buy.')
    if not ok then self.log.warn('Could not save %s (%s)', self.path, tostring(err)) end
end

function Factions:get(char, npc, zone)
    local e = self.people[lower(char)]
    local s = e and e.seen[key(npc, zone)]
    return s and s.word or nil
end

function Factions:set(char, npc, zone, word)
    word = lower(word)
    if not RANK[word] then return end
    local e = self.people[lower(char)]
    if not e then e = { name = char, seen = {} }; self.people[lower(char)] = e end
    local k = key(npc, zone)
    local s = e.seen[k]
    if s and s.word == word then return end
    e.seen[k] = { npc = npc, zone = lower(zone), word = word }
    self:save()
end

function Factions:barred(char, npc, zone)
    local w = self:get(char, npc, zone)
    if w and not Factions.can_buy(w) then return w end
    return nil
end

return Factions
