-- Books: what each character on the network can summon, read from its spellbook over DanNet without running
-- LazCraft there (2.42.12), so a plan knows ahead of time who can cast what - and who is missing a spell.
--   Books.new{ peers, log, now, casters (core/casters), producers (cfg.producers), roster() -> names,
--              running(name) -> working for us now (its card says what it casts), quiet() -> a supply survey is
--              asking (no questions of ours then) }
--   tick()                 every main-loop pass: asks the next question of each character being checked; once in
--                          a while starts on characters never checked (not running, DanNet only)
--   check(name, why)       check one character's book again (the Workers tab's Check spellbooks, a re-check)
--   recheck_for(items)     every character whose class can cast one of these, not running: checked again -> count
--   busy()                 a check is under way
--
-- What is asked, one question at a time per character (DanNet hands back the LAST answer whatever was asked -
-- 2.34.0 log; an answer counts when its QReceived time moved after we asked, else when the value changed):
--   Me.Class.Name (if not known), Me.Level, then Me.Book[<spell>] for every spell of every summoned item its class
--   can cast (producers.ini Classes=). Under MIN_LEVEL nothing more is asked. A book answer is the spell's slot, or
--   NULL when it is not scribed; a NULL is asked once more before it counts (a NULL also comes back now and then
--   for no reason - the supply surveys' logs), a question with no answer at all is asked TRIES times in all.
-- The result goes to core/casters: Casts= the items with a spell scribed, Lacks= the ones its class could cast but
-- has none of the spells for; Level=, Checked=. A running worker's card stays the authority (not asked).
local Casters = require('core.casters')

local Books = {}
Books.__index = Books

Books.MIN_LEVEL = 66
Books.QUESTION_MS = 4000   -- an unanswered question is asked again after this
Books.TRIES = 2            -- ... this often in all, then the character counts as not answering
Books.NULL_TRIES = 1       -- a NULL book answer is asked this many more times before it counts as not scribed
Books.SCAN_MS = 15000      -- how often characters never checked are looked for

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local function lower(s) return (s or ''):lower() end

function Books.new(deps)
    local b = setmetatable({}, Books)
    for k, v in pairs(deps) do b[k] = v end
    b.log = b.log or NOLOG
    b.pending = {}   -- lower name -> the check under way
    b.scanAt = nil
    return b
end

-- The summoned items a class can cast and their spells: { { item, spells = { names } } }
function Books:class_items(class)
    local out = {}
    for item, p in pairs(self.producers or {}) do
        local ok = false
        for _, c in ipairs(p.classes or {}) do if lower(c) == lower(class) then ok = true end end
        if ok then
            local spells = {}
            for _, t in ipairs(p.spells or { p }) do if t.spell then spells[#spells + 1] = t.spell end end
            out[#out + 1] = { item = item, spells = spells }
        end
    end
    table.sort(out, function(a, b) return lower(a.item) < lower(b.item) end)
    return out
end

function Books:busy() return next(self.pending) ~= nil end

function Books:check(name, why)
    local k = lower(name)
    if self.pending[k] then return false end
    if self.peers:detect() ~= 'dannet' then return false end
    local c = { name = name, list = {}, i = 1, tries = 0, nulls = {}, vals = {}, why = why }
    if not self.casters:class_of(name) then c.list[#c.list + 1] = 'Me.Class.Name' end
    c.list[#c.list + 1] = 'Me.Level'
    self.pending[k] = c
    self.log.debug('Spellbook: checking %s%s', name, why and (' (' .. why .. ')') or '')
    self:send(c)
    return true
end

function Books:recheck_for(items)
    local want = {}
    for _, it in ipairs(items) do
        local p = self.producers and (self.producers[it] or self.producers[lower(it)])
        for _, c in ipairs(p and p.classes or {}) do want[lower(c)] = true end
    end
    local n = 0
    for _, name in ipairs(self.roster and self.roster() or {}) do
        local cls = self.casters:class_of(name)
        local lvl = self.casters:level_of(name)
        if cls and want[lower(cls)] and not (self.running and self.running(name)) and not (lvl and lvl < Books.MIN_LEVEL) then
            if self:check(name, 'a plan needs ' .. table.concat(items, ', ')) then n = n + 1 end
        end
    end
    return n
end

function Books:send(c)
    local q = c.list[c.i]
    c.v0, c.at0 = self.peers:answer(c.name, q)
    c.sentAt = self.now()
    self.peers:query(c.name, q)
end

-- the next questions once class and level are known
function Books:plan_book(c)
    local cls = self.casters:class_of(c.name)
    local lvl = tonumber(c.vals['Me.Level'])
    if not cls then return end
    c.class, c.level = cls, lvl
    if lvl and lvl < Books.MIN_LEVEL then return end
    c.items = self:class_items(cls)
    for _, ci in ipairs(c.items) do
        for _, sp in ipairs(ci.spells) do c.list[#c.list + 1] = 'Me.Book[' .. sp .. ']' end
    end
end

function Books:finish(c, why)
    self.pending[lower(c.name)] = nil
    if why then
        -- 2.46.9 (2.46.8 Shela log: Menanu - on DanNet, never answering, likely a client on another machine - was asked
        -- again every SCAN_MS for the whole session): one that does not answer is left out of the scan until it does
        -- something to earn another look (a recheck asked for by name, or Check spellbooks)
        self.silent = self.silent or {}
        self.silent[lower(c.name)] = true
        self.log.info('Spellbook: %s did not answer (%s) - not checked; left out of the scan this session (Check spellbooks asks again)', c.name, why)
        return
    end
    if not c.class then
        self.log.info('Spellbook: %s - its class is not known, not checked', c.name)
        return
    end
    if c.level and c.level < Books.MIN_LEVEL then
        self.casters:set_book(c.name, c.level, nil, nil)
        self.log.info('Spellbook: %s is a level %d %s - not checked (under %d)', c.name, c.level, c.class, Books.MIN_LEVEL)
        return
    end
    local casts, missing, missingSay = {}, {}, {}
    for _, ci in ipairs(c.items or {}) do
        local has = false
        for _, sp in ipairs(ci.spells) do
            local v = c.vals['Me.Book[' .. sp .. ']']
            if v ~= nil and v ~= 'NULL' then has = true end
        end
        if has then casts[#casts + 1] = ci.item
        else
            missing[#missing + 1] = ci.item
            missingSay[#missingSay + 1] = string.format('%s (%s)', ci.item, table.concat(ci.spells, ' or '))
        end
    end
    self.casters:set_book(c.name, c.level, casts, missing)
    self.log.info('Spellbook: %s (%s%s): casts %s%s', c.name, c.class, c.level and (' ' .. c.level) or '',
        #casts > 0 and table.concat(casts, ', ') or 'nothing', #missing > 0 and ('; missing ' .. table.concat(missingSay, ', ')) or '')
end

-- one character: true once done
function Books:step(c)
    local q = c.list[c.i]
    local v, at = self.peers:answer(c.name, q)
    local new = (at ~= nil and at ~= c.at0) or (at == nil and v ~= c.v0 and v ~= nil)
    local timedOut = self.now() - c.sentAt >= Books.QUESTION_MS
    if not new then
        if not timedOut then return false end
        -- no QReceived and nothing changed: a book question's NULL looks like this - taken as the answer
        if at == nil and q:find('^Me%.Book%[') and v == nil then new = true
        else
            c.tries = c.tries + 1
            if c.tries >= Books.TRIES then self:finish(c, string.format('%s, asked %d times', q, c.tries)); return true end
            self:send(c)
            return false
        end
    end
    c.tries = 0
    if q == 'Me.Class.Name' then
        if not v or not Casters.CLASSES[lower(v)] then   -- a late answer to another question: wait on
            c.v0, c.at0 = v, at
            return false
        end
        self.casters:set_class(c.name, v)
    elseif q == 'Me.Level' then
        if not tonumber(v) then c.v0, c.at0 = v, at; return false end
        c.vals[q] = v
        self:plan_book(c)
    else
        if v == nil then
            c.nulls[q] = (c.nulls[q] or 0) + 1
            if c.nulls[q] <= Books.NULL_TRIES then self:send(c); return false end
        elseif not tonumber(v) then   -- not a slot: another question's answer
            c.v0, c.at0 = v, at
            return false
        end
        c.vals[q] = v
    end
    c.i = c.i + 1
    if c.i > #c.list then self:finish(c); return true end
    self:send(c)
    return false
end

function Books:tick()
    -- a supply survey asks its own DanNet questions: wait (the answers would cross); a question sent before it
    -- began is asked again afterwards
    if self.quiet and self.quiet() then
        for _, c in pairs(self.pending) do c.held = true end
        return
    end
    for _, c in pairs(self.pending) do
        if c.held then c.held = nil; self:send(c) else self:step(c) end
    end
    local t = self.now()
    if self.scanAt and t - self.scanAt < Books.SCAN_MS then return end
    self.scanAt = t
    if self.peers:detect() ~= 'dannet' then return end
    -- characters never checked: once each (a running worker's card says what it casts)
    for _, name in ipairs(self.roster and self.roster() or {}) do
        if not self.casters:checked(name) and not (self.running and self.running(name))
            and not (self.silent and self.silent[lower(name)]) then self:check(name, 'never checked') end
    end
end

return Books
