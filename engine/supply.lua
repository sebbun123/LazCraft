-- Supply: who on the network holds an item no merchant sells and no recipe makes (a farmed item - ore, a
-- drop), so a make can order it from them instead of stopping.
--   Supply.new{ peers, log, now, safe = { zone short name = true }, zone_of(name) -> zone from its card or the roster,
--               running(name) -> already working for us (a card) }
--   supply:survey(ctx, items)  asks every character on the network (DanNet /dquery) its zone and how many of
--                              each item it has in its bags (FindItemCount) and bank (FindItemBankCount);
--                              waits up to SURVEY_MS for the answers, logs who has what
--   supply:holders(item)       the last survey for it: { { name, zone, safe, bags, bank, have }, ... } (have > 0),
--                              {} = asked and nobody has any, nil = never asked
--
-- Rules it keeps:
--   * Only DanNet can ask another character a question; without it nobody is asked (said once) and the plan
--     blocks as before.
--   * One question at a time per character, the next only once this one is answered: DanNet gives back the
--     character's last answer whatever the question (2.34.0 log). An answer counts only when it is new - the
--     time it arrived (QReceived) changed after we asked; where DanNet does not give that time, a value
--     already there before we asked is taken after STALE_MS.
--   * A character that does not answer is logged, never guessed - and not "has none" either: for an item whose
--     counts did not come, its counts from the last survey that had them are kept (said in the log), else it is
--     named as not answered for that item (2.40.2 log: Shela's Fruit went unanswered and the row was passed as
--     "nobody on the network has Fruit" while she held 964). The order itself is the check: she answers yes/no.
--   * A count that comes back NULL goes to the end of that character's questions and the next one is asked:
--     asked again at once, 25 of 40 re-asks in the 2.39-2.40 logs never got an answer in the survey's time and
--     every question behind them was lost. NULL_TRIES NULLs for one question and it counts as not answered.
--   * keep_for_go(items) after a preflight's survey; the first pass after Go takes those answers
--     (take_for_go) instead of asking again (2.40.2 log: 7s asked twice, 3s apart). Later passes ask afresh.
--   * Who brings it is the planner's choice (safe zone only, one who has it all first); the order, the worker
--     start and the delivery are the make's (engine/make, engine/handoff).
local R = require('core.result')

local Supply = {}
Supply.__index = Supply

Supply.SURVEY_MS = 6000   -- the longest a survey waits for answers (questions go one at a time per character)
Supply.STALE_MS = 1000    -- no QReceived: an answer that was already there counts after this
Supply.NULL_TRIES = 2     -- a count that comes back NULL is asked again this many times

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local function lower(s) return (s or ''):lower() end

function Supply.new(deps)
    local s = setmetatable({}, Supply)
    for k, v in pairs(deps) do s[k] = v end
    s.log = s.log or NOLOG
    s.safe = s.safe or {}
    s.found = {}   -- lower item -> holders (last survey)
    s.wontStart = {}   -- lower name -> true: did not start as our worker this session
    s.unknown = {}     -- lower item -> names that answered other questions but nothing for it (last survey)
    s.noneAt = {}      -- lower item -> when a survey last found nobody with it (every character answered)
    s.noAnswer = {}    -- lower item -> every name with no answer for it in the last survey (2.44.0: for the plan's words)
    return s
end

-- An item nobody had, asked within this long, is not asked again (2.42.10; 2.42.8 log: a 32-entry research queue
-- asked 13 characters for Fine Runic Parchment Solution before every entry - 6-8s each, nobody had any).
Supply.NONE_MS = 300000

-- The last survey's holders, each marked running (already our worker); a character that would not start as
-- our worker this session is left out until it runs (sends a card).
function Supply:holders(item)
    local list = self.found[lower(item)]
    if not list then return nil end
    local out = {}
    for _, h in ipairs(list) do
        local running = self.running and self.running(h.name) or false
        if running or not self.wontStart[lower(h.name)] then
            local c = {}
            for k, v in pairs(h) do c[k] = v end
            c.running = running
            out[#out + 1] = c
        end
    end
    return out
end

-- The preflight's answers, for the first pass after Go (see the rules above).
function Supply:keep_for_go(items)
    self.forGo = {}
    for _, i in ipairs(items) do self.forGo[lower(i)] = true end
end

function Supply:take_for_go(items)
    local kept = self.forGo
    self.forGo = nil
    if not kept or #items == 0 then return false end
    for _, i in ipairs(items) do if not kept[lower(i)] then return false end end
    self.log.info('Supply: using the preflight\'s answers for %s (asked before Go)', table.concat(items, ', '))
    return true
end

-- Everyone with no answer for an item in the last survey, silent ones too (names), or nil - what the plan says
-- instead of "nobody has any" (2.44.0).
function Supply:no_answer(item)
    local u = self.noAnswer[lower(item)]
    return (u and #u > 0) and u or nil
end

-- Who answered nothing for an item in the last survey (names), or nil.
function Supply:unanswered(item)
    local u = self.unknown[lower(item)]
    return (u and #u > 0) and u or nil
end

function Supply:wont_start(name)
    self.wontStart[lower(name)] = true
    self.log.info('Supply: %s did not come up as our worker - asking the others instead from now on', name)
end

function Supply.count_query(item) return 'FindItemCount[=' .. item .. ']' end
function Supply.bank_query(item) return 'FindItemBankCount[=' .. item .. ']' end

-- only: { lower name = true } - ask just these characters (a second ask for what they did not answer); what the
-- others answered before is kept.
function Supply:survey(ctx, items, only)
    if #items == 0 then return R.ok() end
    if not only then
        local left, skipped = {}, {}
        for _, it in ipairs(items) do
            local at = self.noneAt[lower(it)]
            if at and self.now() - at < Supply.NONE_MS and self.found[lower(it)] and #self.found[lower(it)] == 0 then
                skipped[#skipped + 1] = string.format('%s (%ds ago)', it, math.floor((self.now() - at) / 1000))
            else left[#left + 1] = it end
        end
        if #skipped > 0 then self.log.debug('Supply: nobody had %s when asked - not asked again yet', table.concat(skipped, ', ')) end
        items = left
        if #items == 0 then return R.ok() end
    end
    local p = self.peers
    if p:detect() ~= 'dannet' then
        if not self.saidNoDanNet then
            self.saidNoDanNet = true
            self.log.warn('Supply: asking who on the network has %s needs DanNet - not asked', table.concat(items, ', '))
        end
        return R.ok()
    end
    local names = p:roster()
    if only then
        local some = {}
        for _, n in ipairs(names) do if only[lower(n)] then some[#some + 1] = n end end
        names = some
    end
    if #names == 0 then
        self.log.info('Supply: nobody else on the network to ask for %s', table.concat(items, ', '))
        for _, item in ipairs(items) do self.found[lower(item)] = {} end
        return R.ok()
    end
    local t0 = self.now()
    -- One question at a time per character: DanNet hands back that character's LAST answer whatever the
    -- question (2.34.0 log: a zone read as '0', bags and bank swapped), so the next question goes only once
    -- the answer to this one is in. Characters are asked side by side.
    local chars = {}
    for _, n in ipairs(names) do
        -- the counts first; the zone last (a worker's card also says it)
        local c = { name = n, list = {}, i = 1, vals = {}, got = {}, nulls = {} }
        for _, item in ipairs(items) do
            c.list[#c.list + 1] = Supply.count_query(item)
            c.list[#c.list + 1] = Supply.bank_query(item)
        end
        c.list[#c.list + 1] = 'Zone.ShortName'
        chars[#chars + 1] = c
    end
    local function send(c)
        local q = c.list[c.i]
        c.v0, c.at0 = p:answer(c.name, q)
        c.sentAt = self.now()
        p:query(c.name, q)
    end
    -- true once every question of this character is answered
    local function step(c)
        if c.i > #c.list then return true end
        local v, at = p:answer(c.name, c.list[c.i])
        local new = (at ~= nil and at ~= c.at0)
            or (at == nil and v ~= nil and (c.v0 == nil or self.now() - c.sentAt >= Supply.STALE_MS))
        if not new then return false end
        -- a count is a number and a zone is not: anything else is a late answer to another question - wait on
        local isZone = c.list[c.i] == 'Zone.ShortName'
        c.heard = true
        -- a count that came back NULL is asked again (2.39.2 log: Shela, holding 181 Black Sapphire, answered
        -- NULL once and a row was passed for want of them) - after the rest of its questions (rules above)
        local q = c.list[c.i]
        if v == nil and not isZone then
            c.nulls[q] = (c.nulls[q] or 0) + 1
            if c.nulls[q] <= Supply.NULL_TRIES then
                -- to the end of the list (before the zone); the next question goes now
                table.remove(c.list, c.i)
                table.insert(c.list, #c.list, q)
                self.log.debug('  Supply: %s %s = NULL - asking it again after %s (%d)', c.name, q,
                    c.list[c.i] == q and 'nothing else (the last one)' or c.list[c.i], c.nulls[q])
                send(c)
                return false
            end
        end
        if v ~= nil and (tonumber(v) ~= nil) == isZone then
            self.log.debug('  Supply: %s answered %s to %s - not its answer, waiting on', c.name, tostring(v), c.list[c.i])
            c.v0, c.at0 = v, at
            return false
        end
        c.vals[q] = v
        if v ~= nil then c.got[q] = true end
        c.done = (c.done or 0) + 1
        self.log.debug('  Supply: %s %s = %s (%dms%s)', c.name, c.list[c.i], tostring(v), self.now() - c.sentAt,
            at ~= nil and '' or ', no QReceived - taken after the wait')
        c.i = c.i + 1
        if c.i > #c.list then return true end
        send(c)
        return false
    end
    self.log.info('Supply: asking %d character%s who has %s', #names, #names == 1 and '' or 's', table.concat(items, ', '))
    -- while it asks, nothing else asks DanNet questions (engine/books waits: the answers would cross)
    self.surveying = true
    for _, c in ipairs(chars) do send(c) end
    local w = ctx:wait(Supply.SURVEY_MS, function()
        local all = true
        for _, c in ipairs(chars) do if not step(c) then all = false end end
        return all
    end)
    self.surveying = false
    if not w.ok and w.why ~= 'timeout' then return w end
    local silent, partial = {}, {}
    local lists, unknown = {}, {}
    local retry = {}   -- item -> characters that answered something, but nothing for it (worth asking again;
                       -- one that never answers at all is not - it would only cost another wait)
    for _, item in ipairs(items) do lists[item] = {}; unknown[item] = {}; retry[item] = {} end
    for _, c in ipairs(chars) do
        if not c.heard then silent[#silent + 1] = c.name
        elseif c.i <= #c.list then partial[#partial + 1] = string.format('%s (%d of %d)', c.name, c.done or 0, #c.list) end
        local zone = c.vals['Zone.ShortName']
        zone = zone and lower(zone) or nil
        -- not answered: the zone its worker card (or the roster) last said
        if not zone and self.zone_of then zone = self.zone_of(c.name) end
        for _, item in ipairs(items) do
            local bq, kq = Supply.count_query(item), Supply.bank_query(item)
            local bags, bank = tonumber(c.vals[bq]), tonumber(c.vals[kq])
            local missing = not c.got[bq] or not c.got[kq]
            if missing then
                -- not answered for this item: what the last survey had from this character, else not known
                local prev
                for _, h in ipairs(self.found[lower(item)] or {}) do if lower(h.name) == lower(c.name) then prev = h end end
                if prev then
                    bags = bags or prev.bags
                    bank = bank or prev.bank
                    self.log.info('Supply: %s did not answer for %s this time - keeping its last count (bags %d, bank %d)', c.name, item, bags, bank)
                else   -- either count missing (2.41.7 log: Shylain's bags answered 0, her bank - 2162 - never came)
                    local u = unknown[item]; u[#u + 1] = c.name
                    if c.heard then local rt = retry[item]; rt[#rt + 1] = c.name end
                end
            end
            bags, bank = bags or 0, bank or 0
            if bags + bank > 0 then
                local list = lists[item]
                list[#list + 1] = { name = c.name, zone = zone, safe = zone ~= nil and self.safe[zone] == true,
                                    bags = bags, bank = bank, have = bags + bank,
                                    partial = (c.i <= #c.list or missing) or nil }
            end
        end
    end
    for _, item in ipairs(items) do
        local list = lists[item]
        table.sort(list, function(a, b) return lower(a.name) < lower(b.name) end)
        if only then   -- the others' answers from before stay
            for _, h in ipairs(self.found[lower(item)] or {}) do if not only[lower(h.name)] then list[#list + 1] = h end end
        end
        self.found[lower(item)] = list
        self.unknown[lower(item)] = retry[item]
        self.noAnswer[lower(item)] = unknown[item]
        -- "nobody had it" is held only when everyone answered for it (2.44.0, 2.43.10 log: Shela and Shylain never
        -- answered for Fruit and it was not asked again for 5 minutes)
        self.noneAt[lower(item)] = (#list == 0 and #unknown[item] == 0) and self.now() or nil
        if #list == 0 and #unknown[item] > 0 then
            self.log.info('Supply: nobody who answered has %s - no answer for it from %s', item, table.concat(unknown[item], ', '))
        elseif #list == 0 then
            self.log.info('Supply: nobody on the network has %s', item)
        else
            local parts = {}
            for _, h in ipairs(list) do
                parts[#parts + 1] = string.format('%s %d (bags %d, bank %d) in %s%s%s', h.name, h.have, h.bags, h.bank,
                    h.zone or 'an unknown zone', h.safe and '' or ' - not a safe zone', h.partial and ' - not every answer came' or '')
            end
            self.log.info('Supply: %s - %s', item, table.concat(parts, '; '))
        end
    end
    if #silent > 0 then
        self.log.info('Supply: no answer in %.1fs from %s', Supply.SURVEY_MS / 1000, table.concat(silent, ', '))
    end
    if #partial > 0 then
        self.log.info('Supply: only some answers in %.1fs from %s', Supply.SURVEY_MS / 1000, table.concat(partial, ', '))
    end
    self.log.debug('Supply: survey took %dms', self.now() - t0)
    return R.ok()
end

return Supply
