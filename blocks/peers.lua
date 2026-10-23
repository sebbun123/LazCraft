-- Peers: messages between LazCraft characters, the AdventureTime way - each side says what it knows,
-- nobody polls. Every message is a bound command '/lc_<verb> <from> <args...>'.
--   send(to, verb, ...)    one character (to yourself: runs here, no network)
--   group(verb, ...)       the in-game group, everyone but you
--   raw(to, cmd)           a plain command on another character (/lua run ...)
--   on(verb, fn)           handle a message: fn(from, args...), decoded
--   detect()               which network to use; nil when none
--   roster()               every character the network can see but me: DanNet's peer list ("server_name" -
--                          the name after the last _, the old LazCraft's reading), else EQBC's names; E3 has
--                          no list (only cards say who is up)
--   ask_zone(name)         DanNet only: /dquery its Zone.ShortName; zone_answer(name) reads the answer (or nil)
--
-- Rules it keeps:
--   * Network order on Auto: DanNet, then E3, then EQBC (AdventureTime's proven detection). A chosen one
--     that is missing is said once, then tried again after RETRY_MS - not on every message.
--   * No plugin is loaded for you (the old fixed 750ms load wait is gone).
--   * Names travel encoded: spaces, apostrophes and commas break MQ's argument split. '-' is an empty value,
--     because an empty trailing argument does not arrive. A list is encoded items joined by ','.
--   * Replies go over the network, never tells (tells are rate limited).
--   * DanNet's echo is turned off so messages do not fill the chat.
--   * A group message may come back to the sender on E3 (/e3bcga); handlers that care check `from`.
local Peers = {}
Peers.__index = Peers

Peers.PREFIX = '/lc_'
Peers.RETRY_MS = 15000
Peers.CHOICES = { 'auto', 'dannet', 'e3', 'eqbc' }

local NOLOG = { debug = function() end, info = function() end, warn = function() end }

function Peers.encode(s)
    s = tostring(s or '')
    if s == '' then return '-' end
    return (s:gsub("'", 'XAPOSX'):gsub(',', 'XCOMX'):gsub(' ', '_'))
end

function Peers.decode(s)
    s = tostring(s or '')
    if s == '-' then return '' end
    return (s:gsub('_', ' '):gsub('XCOMX', ','):gsub('XAPOSX', "'"))
end

function Peers.encode_list(list)
    if not list or #list == 0 then return '-' end
    local out = {}
    for i, v in ipairs(list) do out[i] = Peers.encode(v) end
    return table.concat(out, ',')
end

function Peers.decode_list(s)
    local out = {}
    if not s or s == '-' or s == '' then return out end
    for part in s:gmatch('[^,]+') do out[#out + 1] = Peers.decode(part) end
    return out
end

-- deps: mq, log, me (this character's name), choice() -> 'auto'|'dannet'|'e3'|'eqbc'
function Peers.new(deps)
    return setmetatable({ mq = deps.mq, log = deps.log or NOLOG, me = deps.me, choice = deps.choice,
                          chan = nil, retryAt = 0, said = false, bound = {} }, Peers)
end

local function lower(s) return (s or ''):lower() end

function Peers:plugin(name)
    local ok, v = pcall(function() return self.mq.TLO.Plugin(name)() end)
    return ok and v ~= nil
end

function Peers:eqbc_connected()
    local ok, v = pcall(function() return self.mq.TLO.EQBC.Connected() end)
    return ok and v == true
end

-- E3 answers through MQ2Mono only while it runs; an unresolved query comes back as text.
function Peers:e3_answers()
    local ok, v = pcall(function() return self.mq.TLO.MQ2Mono.Query('e3', 'E3N.State.Basics.IsPaused')() end)
    local s = ok and v ~= nil and tostring(v):lower() or ''
    return s == 'true' or s == 'false'
end

function Peers:fail(msg)
    if not self.said then self.said = true; self.log.warn('Network: %s', msg) end
    self.retryAt = self.mq.gettime() + Peers.RETRY_MS
    return nil
end

function Peers:reset()
    self.chan, self.retryAt, self.said = nil, 0, false
end

function Peers:detect()
    if self.chan then return self.chan end
    if self.retryAt > 0 and self.mq.gettime() < self.retryAt then return nil end
    local want = lower(self.choice and self.choice() or 'auto')
    local dnet, mono, eqbc = self:plugin('MQ2DanNet'), self:plugin('MQ2Mono'), self:plugin('MQ2EQBC')
    local chan
    if want == 'dannet' then
        if not dnet then return self:fail('DanNet chosen, but MQ2DanNet is not loaded - messages will not send') end
        chan = 'dannet'
    elseif want == 'e3' then
        if not mono then return self:fail('E3 chosen, but MQ2Mono/E3 is not loaded - messages will not send') end
        chan = 'e3'
    elseif want == 'eqbc' then
        if not eqbc then return self:fail('EQBC chosen, but MQ2EQBC is not loaded - messages will not send') end
        chan = 'eqbc'
    elseif dnet then
        chan = 'dannet'
    elseif mono and (self:e3_answers() or not (eqbc and self:eqbc_connected())) then
        chan = 'e3'
    elseif eqbc then
        chan = 'eqbc'
    else
        return self:fail('no DanNet, E3 or EQBC found - messages will not send')
    end
    if chan == 'eqbc' and not self:eqbc_connected() then
        self.log.warn('Network: MQ2EQBC is loaded but not connected - messages drop until it connects')
    end
    if chan == 'dannet' then
        self.mq.cmd('/squelch /dnet localecho off')
        self.mq.cmd('/squelch /dnet commandecho off')
    end
    self.chan, self.said, self.retryAt = chan, false, 0
    self.log.info('Network: %s%s', chan, want ~= 'auto' and ' (chosen)' or ' (auto)')
    return chan
end

function Peers:wire(verb, args)
    local parts = { Peers.PREFIX .. verb, Peers.encode(self.me) }
    for i = 1, args.n do parts[#parts + 1] = tostring(args[i]) end
    return table.concat(parts, ' ')
end

-- Arguments go out as given: callers encode names (encode / encode_list); numbers pass as they are.
function Peers:send(to, verb, ...)
    local cmd = self:wire(verb, { n = select('#', ...), ... })
    if lower(to) == lower(self.me) then
        self.log.debug('  peer -> self: %s', cmd)
        self.mq.cmd(cmd)
        return true
    end
    local chan = self:detect()
    if not chan then
        self.log.debug('  peer -> %s: %s (not sent: no network)', to, cmd)
        return false
    end
    self.log.debug('  peer -> %s: %s', to, cmd)
    if chan == 'dannet' then self.mq.cmd(string.format('/dex %s %s', to, cmd))
    elseif chan == 'e3' then self.mq.cmd(string.format('/e3bct %s %s', to, cmd))
    else self.mq.cmd(string.format('/bct %s /%s', to, cmd)) end   -- EQBC runs a tell only when it starts with //
    return true
end

function Peers:group(verb, ...)
    local cmd = self:wire(verb, { n = select('#', ...), ... })
    local chan = self:detect()
    if not chan then
        self.log.debug('  peer -> group: %s (not sent: no network)', cmd)
        return false
    end
    self.log.debug('  peer -> group: %s', cmd)
    if chan == 'dannet' then self.mq.cmd('/dgge ' .. cmd)
    elseif chan == 'e3' then self.mq.cmd('/e3bcga ' .. cmd)
    else self.mq.cmd('/bcg /' .. cmd) end
    return true
end

function Peers:raw(to, cmd)
    local chan = self:detect()
    if not chan then
        self.log.debug('  peer -> %s: %s (not sent: no network)', to, cmd)
        return false
    end
    self.log.debug('  peer -> %s: %s', to, cmd)
    if chan == 'dannet' then self.mq.cmd(string.format('/dex %s %s', to, cmd))
    elseif chan == 'e3' then self.mq.cmd(string.format('/e3bct %s %s', to, cmd))
    else self.mq.cmd(string.format('/bct %s /%s', to, cmd)) end
    return true
end

function Peers:roster()
    local me, out, seen = lower(self.me), {}, {}
    local function add(n)
        n = tostring(n or ''):gsub('^%s+', ''):gsub('%s+$', '')
        n = n:sub(1, 1):upper() .. n:sub(2):lower()   -- DanNet lists names in lower case; EQ names start capitalised
        if n ~= '' and lower(n) ~= me and not seen[lower(n)] then seen[lower(n)] = true; out[#out + 1] = n end
    end
    local okD, list = pcall(function() return self.mq.TLO.DanNet.Peers() end)
    if okD and list and list ~= '' then
        for entry in tostring(list):gmatch('[^|]+') do add(entry:match('_([^_]+)$') or entry) end
    end
    if #out == 0 then
        local okE, names = pcall(function() return self.mq.TLO.EQBC.Names() end)
        if okE and names and names ~= '' then for n in tostring(names):gmatch('[^%s,]+') do add(n) end end
    end
    table.sort(out, function(a, b) return lower(a) < lower(b) end)
    return out
end

-- DanNet queries: query(name, q) asks a character for a TLO value (q like 'Zone.ShortName'); answer(name, q)
-- is the last value DanNet holds for it (nil = none) and when it arrived (QReceived; nil if DanNet does not say).
function Peers:query(name, q)
    if self:detect() ~= 'dannet' then return false end
    self.mq.cmd(string.format('/squelch /dquery %s -q "%s"', name, q))
    return true
end

function Peers:answer(name, q)
    local ok, v = pcall(function() return self.mq.TLO.DanNet(name).Q(q)() end)
    local okR, at = pcall(function() return self.mq.TLO.DanNet(name).QReceived(q)() end)
    at = okR and tonumber(at) or nil
    if not ok or v == nil then return nil, at end
    v = tostring(v):gsub('^%s+', ''):gsub('%s+$', '')
    if v == '' or v == 'NULL' then return nil, at end
    return v, at
end

function Peers:ask_zone(name) return self:query(name, 'Zone.ShortName') end

function Peers:zone_answer(name)
    local v = self:answer(name, 'Zone.ShortName')
    return v and lower(v) or nil
end

-- fn(from, ...) gets the sender decoded and the rest as sent (decode names yourself).
function Peers:on(verb, fn)
    local name = Peers.PREFIX .. verb
    self.bound[#self.bound + 1] = name
    self.mq.bind(name, function(from, ...)
        local who = Peers.decode(from)
        local args = { ... }
        self.log.debug('  peer <- %s: %s %s', who ~= '' and who or '?', verb, table.concat(args, ' '))
        if who == '' then return end
        fn(who, ...)
    end)
end

function Peers:unbind_all()
    for _, name in ipairs(self.bound) do pcall(self.mq.unbind, name) end
    self.bound = {}
end

return Peers
