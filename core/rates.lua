-- Rates: how many combines it takes to raise a tradeskill, so the Leveling tab can say what a row and a whole
-- path will take (and a later repeat pass how big to be) before anything is made.
--
-- The model (2.42.2; reworked 2.42.8 with a full Fletching 202 -> 300 run logged point by point), from the EQEmu
-- skill-up code and checked against every leveling pass in the logs (8075 combines, 6 skills, 0 -> 300): a combine
-- raises the skill with chance
--     p2(skill) x (1 on a success, FAIL_UP on a failure)
--   p2: below 15 always; 15-174 (200 - skill) / 2 %; 175 and up 12.5 - 0.08 x (skill - 175) %  - the current raw
--       skill alone, not the trivial (EQEmu: "the only thing that matters is your current unmodified skill")
--   success(skill, trivial): EQEmu's - trivial 68 and up: skill - 0.75 x trivial + 51.5 %, else skill - trivial +
--       66 %; 5% to 95% (the Mithril Champion Arrows run: 6% at 205, 55% at 255, 94% at 295 - as it says)
--   FAIL_UP: 1 for Fletching, Blacksmithing and Make Poison (their third stat, no -15 in EQEmu: a failure raises the
--       skill as often as a success), 0.7 for the INT/WIS skills (fitted)
-- so the combines from a skill to another are   sum over each point of 1 / (p2 x (success + (1 - success) x FAIL_UP))
-- times a factor: K for everyone (all logged passes against the model; each skill's later rows came within 16% of
-- K x the model, where learning a factor from a skill's early rows did worse), pulled toward what this character's
-- runs of the skill took as they add up: (combines + K x PRIOR) / (model + PRIOR) - one row barely moves it.
--
--   Rates.new{ shipped, learned, log, sleep }
--   Rates.model(from, to, trivial, skill)     the model's combines from -> to, factor 1
--   estimate(who, skill, from, to, trivial) -> combines, 'yours'|'guess', factor
--   add(id, combines, points, from, to, x)    a pass: combines made (success or not), skill from -> to; with x =
--                                             { who, skill, trivial } it teaches the factor. Saved at once (the
--                                             learned file is shared by every character: what another one learned
--                                             since we read it is kept)
-- File (data/rates.ini shipped, settings/rates.ini learned; both count):
--   [Rates]   <recipe id>=<combines>,<points>,<lowest skill>,<highest skill>     (a record of the runs)
--   [Factors] <who>|<skill>=<combines>,<model combines>   learned, per character
local Ini = require('core.ini')

local Rates = {}
Rates.__index = Rates

Rates.FAIL_UP = 0.7      -- a failed combine raises an INT/WIS skill this much less often than a success (fitted)
Rates.FAIL_UP_SKILL = { fletching = 1, blacksmithing = 1, ['make poison'] = 1 }
Rates.K = 1.04           -- every logged run against the model (each skill within 9% of it)
Rates.PRIOR = 1000       -- model combines' worth of K a character's own runs are blended with

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local function lower(s) return (s or ''):lower() end

function Rates.p2(s)
    if s < 15 then return 1 end
    if s < 175 then return (200 - s) / 200 end
    return math.max(0.005, (12.5 - 0.08 * (s - 175)) / 100)
end

function Rates.success(s, trivial)
    if not trivial then return 0.95 end
    local c = trivial >= 68 and (s - 0.75 * trivial + 51.5) or (s - trivial + 66)
    return math.min(0.95, math.max(0.05, c / 100))
end

function Rates.model(from, to, trivial, skill)
    local fu = Rates.FAIL_UP_SKILL[lower(skill)] or Rates.FAIL_UP
    local n = 0
    for s = from, to - 1 do
        local su = Rates.success(s, trivial)
        n = n + 1 / (Rates.p2(s) * (su + (1 - su) * fu))
    end
    return n
end

local function read(path, sleep)
    local out = { rates = {}, factors = {} }
    if not path then return out end
    local doc = Ini.load(path, sleep)
    for _, kv in ipairs(doc and doc.sections.Rates and doc.sections.Rates.keys or {}) do
        local c, p, lo, hi = kv[2]:match('^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)')
        if c then out.rates[kv[1]] = { c = tonumber(c), p = tonumber(p), lo = tonumber(lo), hi = tonumber(hi) } end
    end
    for _, kv in ipairs(doc and doc.sections.Factors and doc.sections.Factors.keys or {}) do
        local c, m = kv[2]:match('^%s*(%d+)%s*,%s*(%d+)')
        if c then out.factors[lower(kv[1])] = { key = kv[1], c = tonumber(c), m = tonumber(m) } end
    end
    return out
end

function Rates.new(deps)
    local r = setmetatable({ log = deps.log or NOLOG, learnedPath = deps.learned, sleep = deps.sleep,
                             unsaved = { rates = {}, factors = {} } }, Rates)
    r.shipped = read(deps.shipped, deps.sleep)
    r.learned = read(deps.learned, deps.sleep)
    return r
end

-- The factor for a character's skill: K, pulled toward its own runs as they add up.
function Rates:factor(who, skill)
    local own = self.learned.factors[lower(who) .. '|' .. lower(skill)]
    if not own or own.m <= 0 then return Rates.K, 'guess' end
    return (own.c + Rates.K * Rates.PRIOR) / (own.m + Rates.PRIOR), 'yours'
end

function Rates:estimate(who, skill, from, to, trivial)
    if not from or not to or to <= from then return 0, 'none', 1 end
    local f, src = self:factor(who or '', skill or '')
    return math.ceil(Rates.model(from, to, trivial, skill) * f), src, f
end

function Rates:save()
    if not self.learnedPath then return end
    -- other characters share the file: their runs since we read it are added in, ours stay ours
    local cur = read(self.learnedPath, self.sleep)
    for id, v in pairs(self.unsaved.rates) do
        local e = cur.rates[id]
        if e then e.c, e.p, e.lo, e.hi = e.c + v.c, e.p + v.p, math.min(e.lo, v.lo), math.max(e.hi, v.hi)
        else cur.rates[id] = { c = v.c, p = v.p, lo = v.lo, hi = v.hi } end
    end
    for k, v in pairs(self.unsaved.factors) do
        local e = cur.factors[k]
        if e then e.c, e.m = e.c + v.c, e.m + v.m else cur.factors[k] = { key = v.key, c = v.c, m = v.m } end
    end
    self.unsaved = { rates = {}, factors = {} }
    self.learned = cur
    local ids = {}
    for id in pairs(cur.rates) do ids[#ids + 1] = id end
    table.sort(ids)
    local rates = {}
    for _, id in ipairs(ids) do
        local e = cur.rates[id]
        rates[#rates + 1] = { id, string.format('%d,%d,%d,%d', e.c, e.p, e.lo, e.hi) }
    end
    local fk = {}
    for _, e in pairs(cur.factors) do fk[#fk + 1] = e end
    table.sort(fk, function(a, b) return lower(a.key) < lower(b.key) end)
    local factors = {}
    for _, e in ipairs(fk) do factors[#factors + 1] = { e.key, string.format('%d,%d', e.c, math.floor(e.m + 0.5)) } end
    local ok, err = Ini.write(self.learnedPath, { { name = 'Rates', keys = rates }, { name = 'Factors', keys = factors } },
        '; Learned in game. [Rates] <id>=<combines>,<points>,<lowest>,<highest>; [Factors] <who>|<skill>=<combines>,<model combines>.')
    if not ok then self.log.warn('Could not save %s (%s)', self.learnedPath, tostring(err)) end
end

function Rates:add(id, combines, points, from, to, x)
    if not id or not combines or combines < 1 or not points or points < 0 or not from or not to then return end
    local u = self.unsaved.rates[id]
    if u then u.c, u.p, u.lo, u.hi = u.c + combines, u.p + points, math.min(u.lo, from), math.max(u.hi, to)
    else self.unsaved.rates[id] = { c = combines, p = points, lo = from, hi = to } end
    local m = 0
    if x and x.who and x.skill then
        -- a pass that gained nothing still counts: its combines went toward the point the next pass gets
        m = Rates.model(from, to, x.trivial, x.skill)
        local key = x.who .. '|' .. x.skill
        local f = self.unsaved.factors[lower(key)]
        if f then f.c, f.m = f.c + combines, f.m + m else self.unsaved.factors[lower(key)] = { key = key, c = combines, m = m } end
    end
    self.log.debug('  rate: %s %d combines, %d point%s (%d -> %d)%s', id, combines, points, points == 1 and '' or 's', from, to,
        x and x.skill and string.format(', model %.0f', m) or '')
    self:save()
    if x and x.who and x.skill then
        local f, src = self:factor(x.who, x.skill)
        self.log.info('Rates: %s %s now %.2f x the model (%s)', x.who, x.skill, f,
            src == 'yours' and string.format('%d combines of yours against %.0f modelled', self.learned.factors[lower(x.who .. '|' .. x.skill)].c,
                self.learned.factors[lower(x.who .. '|' .. x.skill)].m) or 'no runs yet')
    end
end

return Rates
