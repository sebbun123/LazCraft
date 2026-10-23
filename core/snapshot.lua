-- Snapshot: what the game looks like right now, written into the log (2.43.11). The user cannot always say what
-- the screen showed when something went wrong; this says it for them.
--   Snapshot.new{ mq, log, kitslot (bag_report), e3 }   starts keeping the last KEEP lines of game chat
--   dump(reason)   writes: where we are and what we target, E3, the cursor, every open window, every bag with what
--                  is in it, the worn slots, and the last chat lines (oldest first, with their age)
-- Taken by /lc snap, and on its own when a job fails and when the game refuses a combine.
-- Every read is guarded: a field this build does not have reads '?', and a snapshot never stops a job.
local Snapshot = {}
Snapshot.__index = Snapshot

Snapshot.KEEP = 50      -- chat lines kept
Snapshot.SHOW = 30      -- chat lines written
Snapshot.WINDOWS = { 'InventoryWindow', 'MerchantWnd', 'TradeWnd', 'GiveWnd', 'QuantityWnd', 'BigBankWnd',
                     'ContainerCombine_Items', 'TradeskillWnd', 'ConfirmationDialogBox', 'LargeDialogWindow',
                     'SpellBookWnd', 'LootWnd', 'AdvancedLootWnd' }

local NOLOG = { debug = function() end, info = function() end, warn = function() end }

function Snapshot.new(deps)
    local s = setmetatable({ mq = deps.mq, log = deps.log or NOLOG, kitslot = deps.kitslot, e3 = deps.e3, chat = {} }, Snapshot)
    if deps.mq and deps.mq.event then
        deps.mq.event('lc_snap_chat', '#*#', function(line) s:hear(line) end)
    end
    return s
end

function Snapshot:hear(line)
    local c = self.chat
    c[#c + 1] = { at = self.mq.gettime and self.mq.gettime() or 0, line = tostring(line or '') }
    while #c > Snapshot.KEEP do table.remove(c, 1) end
end

local function get(fn)
    local ok, v = pcall(fn)
    if not ok or v == nil then return '?' end
    return v
end

-- where, target, E3, cursor, open windows - cheap enough to read every second (the live status file)
function Snapshot:head(out)
    local TLO = self.mq.TLO
    local function add(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
    local Me = TLO.Me
    add('where: %s at %s, %s, %s; target %s (id %s, %s away)', tostring(get(function() return TLO.Zone.ShortName() end)),
        tostring(get(function() return math.floor(Me.X()) end)), tostring(get(function() return math.floor(Me.Y()) end)),
        tostring(get(function() return math.floor(Me.Z()) end)), tostring(get(function() return TLO.Target.CleanName() end)),
        tostring(get(function() return TLO.Target.ID() end)), tostring(get(function() return math.floor(TLO.Target.Distance()) end)))
    add('E3: %s; free bag slots (the client\'s count): %s', self.e3 and (self.e3:held() and 'paused by us' or 'not paused by us') or '?',
        tostring(get(function() return Me.FreeInventory() end)))
    local cur = get(function() return TLO.Cursor.Name() end)
    add('cursor: %s%s; platinum on it: %s', tostring(cur),
        cur ~= '?' and (' x' .. tostring(get(function() return TLO.Cursor.Stack() end))) or '',
        tostring(get(function() return Me.CursorPlatinum() end)))
    local open = {}
    for _, w in ipairs(Snapshot.WINDOWS) do
        if get(function() return TLO.Window(w).Open() end) == true then open[#open + 1] = w end
    end
    for pk = 1, 10 do
        if get(function() return TLO.Window('Pack' .. pk).Open() end) == true then open[#open + 1] = 'Pack' .. pk end
    end
    add('open windows: %s', #open > 0 and table.concat(open, ', ') or 'none of those watched')
    return out
end

-- the last n chat lines, oldest first, with their age
function Snapshot:chat_lines(out, n)
    local now = self.mq.gettime and self.mq.gettime() or 0
    local from = math.max(1, #self.chat - n + 1)
    out[#out + 1] = string.format('last %d chat lines:', #self.chat - from + 1)
    for i = from, #self.chat do
        local c = self.chat[i]
        out[#out + 1] = string.format('  -%.1fs %s', (now - c.at) / 1000, c.line)
    end
    return out
end

function Snapshot:lines()
    local TLO, out = self.mq.TLO, {}
    local function add(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
    local Me = TLO.Me
    self:head(out)
    if self.kitslot and self.kitslot.bag_report then
        add('bags: %s', tostring(get(function() return self.kitslot:bag_report() end)))
    end
    for pk = 1, 10 do
        local top = Me.Inventory('pack' .. pk)
        if get(function() return top.ID() end) ~= '?' and (top.ID() or 0) > 0 then
            local slots = tonumber(get(function() return top.Container() end)) or 0
            if slots > 0 then
                local items = {}
                for i = 1, slots do
                    local it = top.Item(i)
                    if (get(function() return it.ID() end) or 0) ~= '?' and (it.ID() or 0) > 0 then
                        local st = tonumber(get(function() return it.Stack() end)) or 1
                        items[#items + 1] = string.format('%d:%s%s', i, tostring(it.Name()), st > 1 and (' x' .. st) or '')
                    end
                end
                add('pack%d %s: %s', pk, tostring(top.Name()), #items > 0 and table.concat(items, ', ') or 'empty')
            else
                add('pack%d (no bag): %s', pk, tostring(top.Name()))
            end
        end
    end
    local worn = {}
    for i = 0, 22 do
        local n = get(function() local it = Me.Inventory(i); return (it.ID() or 0) > 0 and it.Name() or nil end)
        if n ~= '?' then worn[#worn + 1] = string.format('%d:%s', i, n) end
    end
    add('worn: %s', #worn > 0 and table.concat(worn, ', ') or 'nothing read')
    return self:chat_lines(out, Snapshot.SHOW)
end

-- The live status file (2.44.0): rewritten about once a second (STATUS_MS) with what the job is doing and the
-- head of a snapshot, so "what is it doing right now?" is one file read. `top` = lines to put first (who, the job).
Snapshot.STATUS_MS = 1000
Snapshot.STATUS_CHAT = 10
function Snapshot:status_tick(path, top)
    local now = self.mq.gettime and self.mq.gettime() or 0
    if self.statusAt and now - self.statusAt < Snapshot.STATUS_MS then return end
    self.statusAt = now
    local ok, out = pcall(function()
        local o = {}
        for _, l in ipairs(top() or {}) do o[#o + 1] = l end
        self:head(o)
        return self:chat_lines(o, Snapshot.STATUS_CHAT)
    end)
    if not ok then out = { 'could not read the status: ' .. tostring(out) } end
    local fh = io.open(path, 'w')
    if not fh then
        if not self.saidStatus then self.saidStatus = true; self.log.warn('Could not write the status file %s', tostring(path)) end
        return
    end
    fh:write(table.concat(out, '\n'), '\n')
    fh:close()
end

function Snapshot:dump(reason)
    local ok, lines = pcall(function() return self:lines() end)
    self.log.info('Snapshot (%s):', tostring(reason or 'asked'))
    if not ok then self.log.warn('  could not read it all: %s', tostring(lines)); return end
    for _, l in ipairs(lines) do self.log.info('  %s', l) end
end

return Snapshot
