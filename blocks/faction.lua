-- Faction: where this character stands with an NPC, by /consider (2.42.0).
--   Faction.new{ mq, spawns, log }
--   con(ctx, id)   target the spawn, /consider, read the game's line: R.ok({ word, rank, buy })
--                  word = 'ally' .. 'ready to attack' (core/factions STANDINGS), buy = can buy from it (apprehensively
--                  or better). R.fail('no con') when no line came after TRIES.
--
-- Rules it keeps:
--   * The standard EverQuest con lines (confirmed for Lazarus). The con is the check - merchants word their
--     refusals differently, so a refusal is never read.
--   * Old chat is dropped before the /consider; a con that brings no line within CON_MS is sent again.
local R = require('core.result')
local Factions = require('core.factions')

local Faction = {}
Faction.__index = Faction

Faction.TRIES = 3
Faction.CON_MS = 2000

Faction.LINES = {
    { word = 'ally',            pattern = '#*#regards you as an ally#*#' },
    { word = 'warmly',          pattern = '#*#looks upon you warmly#*#' },
    { word = 'kindly',          pattern = '#*#kindly considers you#*#' },
    { word = 'amiably',         pattern = '#*#judges you amiably#*#' },
    { word = 'indifferently',   pattern = '#*#regards you indifferently#*#' },
    { word = 'apprehensively',  pattern = '#*#looks your way apprehensively#*#' },
    { word = 'dubiously',       pattern = '#*#glowers at you dubiously#*#' },
    { word = 'threateningly',   pattern = '#*#glares at you threateningly#*#' },
    { word = 'ready to attack', pattern = '#*#scowls at you, ready to attack#*#' },
}

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local nextEvent = 0

function Faction.new(deps)
    local f = setmetatable({ mq = deps.mq, spawns = deps.spawns, log = deps.log or NOLOG, heard = nil }, Faction)
    for _, l in ipairs(Faction.LINES) do
        nextEvent = nextEvent + 1
        deps.mq.event('lc_faction_' .. nextEvent, l.pattern, function(line)
            if not f.heard then f.heard = { word = l.word, line = line } end
        end)
    end
    return f
end

function Faction:con(ctx, id)
    local t = self.spawns:target(ctx, id)
    if not t.ok then return t end
    for try = 1, Faction.TRIES do
        self.mq.doevents()   -- drop old chat before listening
        self.heard = nil
        self.log.debug('  send: /consider')
        self.mq.cmd('/consider')
        local w = ctx:wait(Faction.CON_MS, function() return self.heard ~= nil end)
        if not w.ok and w.why ~= 'timeout' then return w end
        if self.heard then
            local word = self.heard.word
            self.log.debug('  con after %dms: %s', w.ms or 0, tostring(self.heard.line))
            return R.ok({ word = word, rank = Factions.rank(word), buy = Factions.can_buy(word) })
        end
        self.log.debug('  /consider: no line after %dms (try %d)', Faction.CON_MS, try)
    end
    return R.fail('no con', string.format('/consider brought no faction line after %d tries', Faction.TRIES))
end

return Faction
