-- Crew: the crafter and its workers, kept up to date by cards rather than queries.
--
-- A card is what a worker says about itself:  card <zone> <idle|busy> <items it can cast>
--   Worker: sends its card to its crafter on start, whenever its zone or idle/busy changes, and when the
--           crafter says hello. What it can cast is its spellbook (any producers.ini spell for it scribed),
--           read at start and on each hello - a class match does not mean scribed. On exit it says bye.
--   Crafter: keeps the latest card from each worker. hello() asks every worker it has heard from before
--           (remembered in settings) plus the group; a worker that has not answered HELLO_MS after a
--           hello shows as not answering. start_worker(name) says hello first and runs LazCraft on that
--           character only if no card comes back within HELLO_MS; a card is the proof it is up.
-- Several drivers (2.44.0): a crafter answers another crafter's hello with 'driver', and is never started as a
--   worker, ordered from or sent anywhere by it (is_driver). A worker works for every crafter that says hello: the
--   first is its own (theme, window), the others are served too (serves) - its card goes to all of them, and its
--   jobs queue in the order they come.
local Peers = require('blocks.peers')

local Crew = {}
Crew.__index = Crew

Crew.HELLO_MS = 3000
Crew.ROSTER_MS = 10000   -- crafter: how often the network's character list and their zones are read again

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local function lower(s) return (s or ''):lower() end

-- deps: peers, log, now, role ('crafter'|'worker'), me, crafter (worker: whose worker it is),
--       producers (cfg.producers), book(spell) -> scribed, zone() -> short name, busy() -> true while a job runs,
--       known() -> list of remembered worker names, remember(name) (crafter),
--       memo (crafter: core/casters - who casts what), class() -> this character's class (worker's card)
function Crew.new(deps)
    local c = setmetatable({}, Crew)
    for k, v in pairs(deps) do c[k] = v end
    c.log = c.log or NOLOG
    c.board = {}     -- crafter: lower name -> { name, zone, state, items, at, gone }
    c.asked = {}     -- crafter: lower name -> when hello was sent
    c.items = nil    -- worker: what it can cast
    c.sent = nil     -- worker: the last card sent, to send again only on change
    c.starting = {}  -- crafter: lower name -> { name, at } while checking before a start
    c.silent = {}    -- crafter: lower name -> the hello it did not answer (logged once)
    c.roster = {}    -- crafter: every character the network sees (names)
    c.zones = {}     -- crafter: lower name -> zone short name, from DanNet (characters without a card)
    c.rosterAt = nil
    c.asking = {}    -- crafter: lower name -> the question last asked by the roster ('zone' or 'class')
    c.drivers = {}   -- crafter: lower name -> { name, at, version } other crafters (they said 'driver')
    c.crafters = {}  -- worker: lower name -> name, every crafter it works for (the first is self.crafter)
    if c.role == 'worker' and (c.crafter or '') ~= '' then c.crafters[lower(c.crafter)] = c.crafter end
    return c
end

-- ---------------------------------------------------------------- worker

function Crew:can_cast()
    local out = {}
    for item, p in pairs(self.producers or {}) do
        for _, t in ipairs(p.spells or { p }) do
            if t.spell and self.book(t.spell) then out[#out + 1] = item; break end
        end
    end
    table.sort(out)
    return out
end

function Crew:card_now()
    -- paused by hand (its window, 2.42.7) shows as such on the crafter's Workers tab
    local state = (self.paused and self.paused()) and 'paused' or (self.busy() and 'busy' or 'idle')
    return { zone = lower(self.zone()), state = state, items = self.items or {} }
end

-- worker: does it work for this crafter (2.44.0: any that said hello)
function Crew:serves(name) return self.crafters[lower(name or '')] ~= nil end

function Crew:crafter_names()
    local out = {}
    for _, n in pairs(self.crafters) do out[#out + 1] = n end
    table.sort(out)
    return out
end

-- to: one crafter (its hello), else every crafter we work for
function Crew:push(why, to)
    local c = self:card_now()
    self.sent = c.zone .. '|' .. c.state .. '|' .. table.concat(c.items, ',')
    local targets = to and { to } or self:crafter_names()
    self.log.debug('Card to %s (%s): %s, %s, casts %s', table.concat(targets, ', '), why, c.zone, c.state,
        #c.items > 0 and table.concat(c.items, ', ') or 'nothing')
    -- the version goes last (2.41.4): a crafter can tell a worker that still runs older code (2.41.x logs: Shela on
    -- 2.40.2 an hour after the update - a running Lua keeps the code it started with)
    -- and its class (2.41.9): the crafter remembers who could cast what (core/casters)
    local cls = self.class and self.class() or nil
    for _, t in ipairs(targets) do
        self.peers:send(t, 'card', Peers.encode(c.zone), c.state, Peers.encode_list(c.items), Peers.encode(self.version or '?'),
            Peers.encode(cls and cls ~= '' and cls or '?'))
    end
end

-- crafter: another crafter (it answered our hello with 'driver')
function Crew:is_driver(name) return self.drivers[lower(name or '')] ~= nil end

function Crew:on_driver(from, ver)
    local k = lower(from)
    if not self.drivers[k] then
        self.log.info('%s is a driver too (LazCraft %s) - never started as a worker, ordered from or sent anywhere', from,
            ver and Peers.decode(ver) or '?')
    end
    self.drivers[k] = { name = from, at = self.now(), version = ver and Peers.decode(ver) or nil }
    if self.starting[k] then
        self.starting[k] = nil
        self.log.info('Not starting %s as a worker: it runs LazCraft as a driver', from)
    end
end

-- ---------------------------------------------------------------- crafter

function Crew:on_card(from, zone, state, list, ver, cls)
    local key = lower(from)
    local e = self.board[key]
    local items = Peers.decode_list(list)
    local new = { name = from, zone = lower(Peers.decode(zone)), state = state or '?', items = items, at = self.now(),
                  version = ver and Peers.decode(ver) or nil }
    -- a worker on other code than ours: said once per version seen (the Workers tab shows it, with Restart)
    if self.version and new.version ~= self.version and (not e or e.version ~= new.version or e.gone) then
        self.log.warn('Worker %s runs LazCraft %s, this is %s - restart it there (Workers tab: Restart)', from,
            new.version or 'older than 2.41.4', self.version)
    end
    local sig = new.zone .. '|' .. new.state .. '|' .. table.concat(items, ',')
    if not e or e.gone or e.sig ~= sig then
        self.log.info('Worker %s: %s, %s, casts %s', from, new.zone, new.state,
            #items > 0 and table.concat(items, ', ') or 'nothing')
    end
    new.sig = sig
    self.board[key] = new
    -- a worker that just came up (or back): told what it should know from us, e.g. the window's theme (2.43.0)
    if (not e or e.gone) and self.on_up then pcall(self.on_up, from) end
    if self.memo then
        self.memo:set_casts(from, items)
        if cls then self.memo:set_class(from, Peers.decode(cls)) end
    end
    if not e and self.remember then self.remember(from) end
end

function Crew:on_bye(from)
    local e = self.board[lower(from)]
    if e and not e.gone then
        e.gone = true
        self.log.info('Worker %s stopped', from)
    end
end

function Crew:hello()
    local names = {}
    for _, n in ipairs(self.known and self.known() or {}) do names[lower(n)] = n end
    for k, e in pairs(self.board) do names[k] = e.name end
    local t = self.now()
    for k, n in pairs(names) do
        self.asked[k] = t
        self.peers:send(n, 'hello')
    end
    self.peers:group('hello')
end

-- Ask first, start only on silence (an old card proves nothing - the script may have been stopped since).
-- A card within HELLO_MS means it is already running; none means /lua run on that character. tick() decides.
function Crew:start_worker(name)
    local key = lower(name)
    if self.drivers[key] then
        self.log.info('Not starting %s as a worker: it runs LazCraft as a driver', name)
        return false
    end
    if self.starting[key] then
        self.log.info('Already checking on %s', name)
        return false
    end
    self.starting[key] = { name = name, at = self.now() }
    self.asked[key] = self.now()
    self.log.info('Checking whether %s is already running', name)
    return self.peers:send(name, 'hello')
end

-- Stop LazCraft on a worker and start it again (new code after an update): /lua stop there, then the usual start
-- (a hello first - the stopped worker does not answer it - then /lua run).
function Crew:restart_worker(name)
    self.log.info('Restarting LazCraft on %s', name)
    self.peers:raw(name, '/lua stop lazcraft')
    local e = self.board[lower(name)]
    if e then e.gone = true end
    return self:start_worker(name)
end

function Crew:check_starts()
    local t = self.now()
    -- say once in the log when a hello went unanswered (the Workers tab shows it too)
    for key, at in pairs(self.asked) do
        local e = self.board[key]
        if t - at >= Crew.HELLO_MS and self.silent[key] ~= at and not self.starting[key]
           and not (e and (e.gone or e.at >= at)) then
            self.silent[key] = at
            self.log.info('%s did not answer (asked %ds ago)', e and e.name or key, math.floor((t - at) / 1000))
        end
    end
    for key, s in pairs(self.starting) do
        local e = self.board[key]
        if self.drivers[key] then
            self.starting[key] = nil
            self.log.info('Not starting %s as a worker: it runs LazCraft as a driver', s.name)
        elseif e and not e.gone and e.at >= s.at then
            self.starting[key] = nil
            self.log.info('%s is already working for you (%s, %s)', e.name, e.zone, e.state)
        elseif t - s.at >= Crew.HELLO_MS then
            self.starting[key] = nil
            self.asked[key] = t
            self.log.info('No answer from %s in %ds - starting LazCraft there as your worker', s.name, Crew.HELLO_MS / 1000)
            self.peers:raw(s.name, '/lua run lazcraft worker ' .. self.me)
        end
    end
end

function Crew:answering(e)
    local asked = self.asked[lower(e.name)]
    return not asked or e.at >= asked or (self.now() - asked) < Crew.HELLO_MS
end

-- Sorted rows for the window: { name, zone, state, items, status = 'ok'|'waiting'|'not answering'|'stopped' }
function Crew:view()
    local rows, seen = {}, {}
    for k, e in pairs(self.board) do
        seen[k] = true
        local status = e.gone and 'stopped' or (self:answering(e) and 'ok' or 'not answering')
        rows[#rows + 1] = { name = e.name, zone = e.zone, state = e.state, items = e.items, status = status }
    end
    for k, t in pairs(self.asked) do
        if not seen[k] then
            local name = k
            for _, n in ipairs(self.known and self.known() or {}) do if lower(n) == k then name = n end end
            rows[#rows + 1] = { name = name, items = {}, status = (self.now() - t) < Crew.HELLO_MS and 'waiting' or 'not answering' }
        end
    end
    table.sort(rows, function(a, b) return lower(a.name) < lower(b.name) end)
    return rows
end

-- The network's characters and where they are, read every ROSTER_MS (a character with a card says its own zone).
function Crew:roster_tick()
    local t = self.now()
    if not self.rosterAt or t - self.rosterAt >= Crew.ROSTER_MS then
        self.rosterAt = t
        self.roster = self.peers:roster()
        for _, n in ipairs(self.roster) do
            local e = self.board[lower(n)]
            if not (e and not e.gone) and not (self.asking_elsewhere and self.asking_elsewhere(n)) then
                -- a character never started: its class once (who could cast what), else its zone. One question at
                -- a time - DanNet hands back the last answer whatever the question
                if self.memo and not self.memo:class_of(n) and self.zones[lower(n)] then
                    self.asking[lower(n)] = 'class'
                    self.peers:query(n, 'Me.Class.Name')
                else
                    self.asking[lower(n)] = 'zone'
                    self.peers:ask_zone(n)
                end
            end
        end
    end
    local Casters = require('core.casters')
    for _, n in ipairs(self.roster) do
        local v = self.peers:answer(n, self.asking[lower(n)] == 'class' and 'Me.Class.Name' or 'Zone.ShortName')
        -- a number is a count, a level or a book slot (another question's answer), never a zone or a class
        if v and not tonumber(v) and not (self.asking_elsewhere and self.asking_elsewhere(n)) then
            local isClass = Casters.CLASSES[lower(v)] ~= nil
            if self.asking[lower(n)] == 'class' then
                if isClass and self.memo then self.memo:set_class(n, v) end
            elseif not isClass then
                self.zones[lower(n)] = lower(v)
            end
        end
    end
end

-- Every character for the Workers tab: the network's and every worker we have heard from.
-- { name, zone, safe (true/false/nil = zone unknown), running, state, items, status } sorted by name.
function Crew:roster_view(safeZones)
    local rows, seen = {}, {}
    local function row(name)
        local k = lower(name)
        if seen[k] then return end
        seen[k] = true
        local e = self.board[k]
        local running = e and not e.gone and self:answering(e)
        local zone = (running and e.zone) or self.zones[k]
        local safe = nil
        if zone then safe = (safeZones or {})[zone] == true end
        rows[#rows + 1] = { name = e and e.name or name, zone = zone, safe = safe, running = running and true or false,
                            state = running and e.state or nil, items = running and e.items or {},
                            status = e and (e.gone and 'stopped' or (running and 'ok' or 'not answering')) or nil,
                            version = running and e.version or nil,
                            old = running and self.version ~= nil and e.version ~= self.version or nil,
                            -- remembered (core/casters): its class, what its last card listed
                            class = self.memo and self.memo:class_of(name) or nil,
                            level = self.memo and self.memo:level_of(name) or nil,
                            lacks = self.memo and self.memo:lacks_list(name) or nil,
                            castBefore = (not running and self.memo) and self.memo:casts(name) or nil }
    end
    for _, n in ipairs(self.roster) do row(n) end
    for _, e in pairs(self.board) do row(e.name) end
    table.sort(rows, function(a, b) return lower(a.name) < lower(b.name) end)
    return rows
end

-- Running and answering, and what it casts now (its card).
function Crew:running(name)
    local e = self.board[lower(name)]
    return e ~= nil and not e.gone and self:answering(e)
end

function Crew:can_make(name, item)
    local e = self.board[lower(name)]
    for _, it in ipairs(e and e.items or {}) do if lower(it) == lower(item) then return true end end
    return false
end

-- A card from `name` at or after time t (and no bye since): it is running and working for us.
function Crew:card_since(name, t)
    local e = self.board[lower(name)]
    return e ~= nil and not e.gone and e.at >= t
end

-- Workers that are up and can cast `item` (for the planner, later).
function Crew:casters(item)
    local out = {}
    for _, e in pairs(self.board) do
        if not e.gone and self:answering(e) then
            for _, it in ipairs(e.items) do
                if lower(it) == lower(item) then out[#out + 1] = e; break end
            end
        end
    end
    table.sort(out, function(a, b) return lower(a.name) < lower(b.name) end)
    return out
end

-- ---------------------------------------------------------------- both

function Crew:start()
    self.started = true
    if self.role == 'worker' then
        self.peers:on('hello', function(from)
            -- started with no crafter named (2.42.10): the first crafter whose hello comes is the one
            if self.crafter == '' then
                self.crafter = from
                self.log.info('Working for %s from now on (its hello came first)', from)
                if self.on_adopt then self.on_adopt(from) end
            end
            -- every crafter that says hello is served (2.44.0); the first stays our own
            if not self.crafters[lower(from)] then
                self.crafters[lower(from)] = from
                if lower(from) ~= lower(self.crafter) then
                    self.log.info('Also working for %s (its orders queue with %s\'s)', from, self.crafter)
                end
            end
            self.items = self:can_cast()
            self:push('asked', from)
        end)
        self.items = self:can_cast()
        if self.crafter ~= '' then self:push('started') end
    else
        self.peers:on('card', function(from, zone, state, list, ver, cls) self:on_card(from, zone, state, list, ver, cls) end)
        self.peers:on('bye', function(from) self:on_bye(from) end)
        -- another crafter's hello: we are a driver, not a worker (2.44.0)
        self.peers:on('hello', function(from) self.peers:send(from, 'driver', Peers.encode(self.version or '?')) end)
        self.peers:on('driver', function(from, ver) self:on_driver(from, ver) end)
        self:hello()
    end
end

-- Main loop, every pass: a worker sends its card again when its zone or idle/busy changed; the crafter
-- finishes any start_worker checks.
function Crew:tick()
    if not self.started then return end
    if self.role ~= 'worker' then self:check_starts(); return self:roster_tick() end
    if self.crafter == '' then return end   -- no crafter yet: nobody to send a card to
    local c = self:card_now()
    local sig = c.zone .. '|' .. c.state .. '|' .. table.concat(c.items, ',')
    if sig ~= self.sent then self:push('changed') end
end

function Crew:stop()
    if not self.started then return end
    self.started = false
    if self.role == 'worker' then
        for _, n in ipairs(self:crafter_names()) do self.peers:send(n, 'bye') end
    end
    self.peers:unbind_all()
end

return Crew
