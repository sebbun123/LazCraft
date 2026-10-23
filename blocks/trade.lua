-- Trade: handing items to another character, and taking them from one. The two sides talk through `link`
-- (messages, wired by engine/handoff), so the block only does the clicking and the confirming.
--
--   give(ctx, whoId, item, n, link)   giver. Loads up to 8 stacks per trade onto the target, then
--       link.loaded(k, units)        says trade k is loaded (units in it)
--       link.accepted(k) -> bool     the taker has clicked Trade on trade k
--       link.got(k) -> bool          the taker's count went up by trade k's units
--       link.cancelled() -> why|nil  the taker gave up
--     clicks Trade only after the taker has, and counts trade k done only when the taker says it got it.
--     R.ok({ given, trades })
--   take(ctx, item, n, link)          taker.
--       link.loaded(k) -> units|nil  the giver says trade k is loaded
--       link.accept(k)               tell the giver we clicked Trade on trade k
--       link.got(k, units)           tell the giver our count went up
--       link.cancelled() -> why|nil  the giver gave up
--     clicks Trade once the giver says the trade is loaded, confirms by our count going up by its units.
--     R.ok({ taken, trades })
--   give_pp(ctx, whoId, n)            platinum, the receiver accepting by hand (see below)
--   cancel(ctx)                       close an open trade window with its Cancel button (the giver gets
--                                     everything back), confirmed
--
-- Rules it keeps:
--   * The giver says when a trade is loaded; nobody guesses with a delay (old LazCraft: a guessed delay
--     completed one-item trades mid-batch). There is no fallback timer - no "loaded" means no trade.
--   * Each side clicks Trade itself (E3 does not confirm trades for its driver). The taker clicks first and
--     says so; the giver's click completes it, so the window never changes after anyone accepted.
--   * Done is counts, not the window closing: the taker's bag count must go up by the trade's units.
--   * A stack goes onto the target from the cursor; the trade window opens with the first. The drop is
--     /notify TargetWindow Target_HP, then /click left target if the cursor still holds it (which one
--     worked is logged - the old code had both and it was never shown which was needed).
--   * Exact amounts come off the cursor block (amount field read back before accepting, Esc to cancel).
--   * A confirmation box after Trade is not clicked through: it is reported, so we see what it says first.
--   * Every wait is on a condition with a cap. Every step is logged.
local R = require('core.result')

local Trade = {}
Trade.__index = Trade

Trade.STACKS = 8            -- slots in one trade
Trade.DIST = 15             -- the giver must be this close to the taker
Trade.DROP_MS = 2000        -- a dropped stack leaves the cursor
Trade.OPEN_MS = 3000        -- the trade window shows
Trade.LOAD_MS = 30000       -- taker: the giver says a trade is loaded
Trade.ACCEPT_MS = 15000     -- giver: the taker says it clicked Trade
Trade.DONE_MS = 10000       -- the trade completes and the count moves
Trade.CLOSE_MS = 3000

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local WND = 'TradeWnd'

function Trade.new(deps)
    return setmetatable({ mq = deps.mq, inv = deps.inventory, cursor = deps.cursor, win = deps.windows,
                          spawns = deps.spawns, log = deps.log or NOLOG }, Trade)
end

function Trade:send(cmd)
    self.log.debug('  send: %s', cmd)
    self.mq.cmd(cmd)
end

function Trade:is_open() return self.win:is_open(WND) end

-- Who has clicked Trade, as the window shows it (MQ Window.MyTradeReady / HisTradeReady) - for the log: a trade
-- that never completed (2.42.13 Lopan log: Lopan clicked Trade 35ms after Ejtou said loaded, the window stayed
-- open 10s) says which side was not on.
function Trade:ready_text()
    local function flag(m)
        local ok, v = pcall(function() local w = self.mq.TLO.Window(WND); return w[m] and w[m]() end)
        if not ok or v == nil then return '?' end
        return (v == true or v == 'TRUE') and 'on' or 'off'
    end
    return string.format('ours %s, theirs %s', flag('MyTradeReady'), flag('HisTradeReady'))
end

local function wait(ctx, ms, cond)
    local w = ctx:wait(ms, cond)
    if not w.ok and w.why ~= 'timeout' then return w, true end
    return w, false
end

function Trade:confirm_box()
    if self.win:is_open('ConfirmationDialogBox') then
        local text = tostring(self.mq.TLO.Window('ConfirmationDialogBox/CD_TextOutput').Text() or '?')
        return R.fail('confirmation box', 'a confirmation box opened: "' .. text .. '" - not clicked')
    end
    return nil
end

function Trade:cancel(ctx)
    if not self:is_open() then return R.ok() end
    self:send('/notify TradeWnd TRDW_Cancel_Button leftmouseup')
    local w = ctx:wait(Trade.CLOSE_MS, function() return not self:is_open() end)
    self.log.debug('  trade window closed: %s after %dms', w.ok and 'yes' or w.why, w.ms or 0)
    if w.ok then return R.ok() end
    if w.why == 'timeout' then return R.fail('trade stuck open', 'the trade window would not close') end
    return w
end

-- Put what is on the cursor onto the target (opens the trade window with the first stack).
function Trade:drop(ctx)
    local held = self.cursor:item()
    for _, cmd in ipairs({ '/notify TargetWindow Target_HP leftmouseup', '/click left target' }) do
        self:send(cmd)
        local w, bad = wait(ctx, Trade.DROP_MS, function() return self.cursor:is_empty() end)
        if bad then return w end
        if w.ok then
            self.log.debug('  %s x%d into the trade (%s) after %dms', held and held.name or '?', held and held.stack or 0,
                cmd:find('Target_HP', 1, true) and 'target window' or 'click on target', w.ms or 0)
            return R.ok()
        end
    end
    return R.fail('drop failed', string.format('%s stayed on the cursor after both drops', held and held.name or 'the item'))
end

-- The biggest stack of `item` in the bags (what one pickup can take whole).
function Trade:largest(item)
    local best = 0
    for _, p in ipairs(self.inv:find(item) or {}) do if p.stack > best then best = p.stack end end
    return best
end

function Trade:give(ctx, whoId, item, n, link)
    local who = self.spawns:get(whoId)
    if not who then return R.fail('not here', 'the taker is not in this zone') end
    if who.distance > Trade.DIST then
        return R.fail('too far', string.format('%s is %.0f away (trade range %d)', who.name, who.distance, Trade.DIST))
    end
    local t = self.spawns:target(ctx, whoId)
    if not t.ok then return t end
    local opened, given, k = {}, 0, 0
    local function close_bags()
        for pack in pairs(opened) do if self.cursor:is_empty() then self.win:close_bag(ctx, pack) end end
    end
    while given < n do
        if not ctx:checkpoint() then close_bags(); return R.fail('stopped') end
        local why = link.cancelled()
        if why then close_bags(); return R.fail('cancelled', who.name .. ' gave up: ' .. why) end
        k = k + 1
        local units, stacks = 0, 0
        while stacks < Trade.STACKS and given + units < n do
            local amt = math.min(n - given - units, self:largest(item))
            if amt <= 0 then break end
            local p = self.cursor:pick_up(ctx, item, amt)
            if p.openedPack then opened[p.openedPack] = true end
            if not p.ok then close_bags(); return p end
            if p.value.openedPack then opened[p.value.openedPack] = true end
            local d = self:drop(ctx)
            if not d.ok then close_bags(); return d end
            stacks, units = stacks + 1, units + amt
        end
        close_bags(); opened = {}
        if units == 0 then
            return R.fail('ran out', string.format('gave %d of %d %s, no more in the bags', given, n, item))
        end
        local o, bad = wait(ctx, Trade.OPEN_MS, function() return self:is_open() end)
        if bad then return o end
        if not o.ok then return R.fail('no trade window', 'the trade window did not open after the drops') end
        self.log.info('Trade %d: %d %s in %d stack(s) for %s', k, units, item, stacks, who.name)
        link.loaded(k, units)
        local a, bad2 = wait(ctx, Trade.ACCEPT_MS, function() return link.accepted(k) or link.cancelled() ~= nil end)
        if bad2 then return a end
        if link.cancelled() then return R.fail('cancelled', who.name .. ' gave up: ' .. link.cancelled()) end
        if not a.ok then return R.fail('not accepted', string.format('%s did not click Trade within %ds', who.name, Trade.ACCEPT_MS / 1000)) end
        self.log.debug('  %s clicked Trade after %dms', who.name, a.ms or 0)
        self:send('/notify TradeWnd TRDW_Trade_Button leftmouseup')
        local g, bad3 = wait(ctx, Trade.DONE_MS, function()
            return link.got(k) or link.cancelled() ~= nil or self.win:is_open('ConfirmationDialogBox')
        end)
        if bad3 then return g end
        local cb = self:confirm_box()
        if cb then return cb end
        if link.cancelled() then return R.fail('cancelled', who.name .. ' gave up: ' .. link.cancelled()) end
        if not g.ok then
            local open = self:is_open()
            if open then self.log.info('Trade %d not done: the window says Trade is %s', k, self:ready_text()) end
            return R.fail('not received', string.format('%s did not confirm trade %d within %ds (window %s)', who.name, k,
                Trade.DONE_MS / 1000, open and 'still open' or 'closed'))
        end
        given = given + units
        self.log.info('Trade %d done: %s got %d %s (%d of %d) after %dms', k, who.name, units, item, given, n, g.ms or 0)
    end
    return R.ok({ given = given, trades = k })
end

-- ---- platinum (2.43.4) ------------------------------------------------------------------------
-- give_pp(ctx, whoId, n)   n platinum to whoId, the receiver clicking Trade by hand (the /lc givepp test; the
--   worker top-up builds on it once a log shows each step). Steps, each logged: target -> inventory window ->
--   click the platinum slot -> amount set and read back -> accept -> coins on the cursor checked -> drop on the
--   target -> trade window -> our Trade click -> wait for the window to close -> our platinum down by exactly n.
--   R.ok({ given, before, after })
Trade.HAND_MS = 60000       -- the receiver clicks Trade by hand

function Trade:pp() return tonumber(self.mq.TLO.Me.Platinum()) or 0 end

-- coins on the cursor (Me.CursorPlatinum); nil when this build has no such field
function Trade:cursor_pp()
    local ok, v = pcall(function() return self.mq.TLO.Me.CursorPlatinum() end)
    if ok then return tonumber(v) end
    return nil
end

-- what our side of the trade window shows for money, for the log ('?' when the field is not there)
function Trade:money_text()
    local ok, v = pcall(function() return self.mq.TLO.Window('TradeWnd/TRDW_MyMoney0').Text() end)
    return (ok and v ~= nil) and tostring(v) or '?'
end

-- coins on the cursor go back into the purse (a click on the platinum slot while holding them)
function Trade:put_back_pp(ctx)
    if (self:cursor_pp() or 0) <= 0 then return R.ok() end
    self:send('/notify InventoryWindow IW_Money0 leftmouseup')
    local w = ctx:wait(Trade.DROP_MS, function() return (self:cursor_pp() or 0) <= 0 end)
    self.log.debug('  coins back in the purse: %s after %dms (%d pp)', w.ok and 'yes' or w.why, w.ms or 0, self:pp())
    if w.ok then return R.ok() end
    if w.why == 'timeout' then return R.fail('coins stuck', 'the platinum stayed on the cursor') end
    return w
end

function Trade:give_pp(ctx, whoId, n)
    local who = self.spawns:get(whoId)
    if not who then return R.fail('not here', 'the receiver is not in this zone') end
    if who.distance > Trade.DIST then
        return R.fail('too far', string.format('%s is %.0f away (trade range %d)', who.name, who.distance, Trade.DIST))
    end
    local before = self:pp()
    if before < n then return R.fail('short', string.format('%d pp on us, %d asked', before, n)) end
    if not self.cursor:is_empty() then return R.fail('cursor busy', 'the cursor holds an item') end
    if (self:cursor_pp() or 0) > 0 then return R.fail('cursor busy', 'the cursor holds coins') end
    self.log.info('Giving %d pp to %s (%.0f away); %d pp on us, cursor field %s', n, who.name, who.distance, before,
        self:cursor_pp() == nil and 'missing (Me.CursorPlatinum)' or 'there')
    local t = self.spawns:target(ctx, whoId)
    if not t.ok then return t end
    -- 1. the inventory window: the platinum slot lives there
    if not self.win:is_open('InventoryWindow') then
        self.log.debug('  DoOpen: InventoryWindow')
        self.mq.TLO.Window('InventoryWindow').DoOpen()
        local o = self.win:wait_open(ctx, 'InventoryWindow', Trade.OPEN_MS)
        if not o.ok then return o end
    end
    -- 2. click the platinum slot: the amount window (or the coins straight onto the cursor)
    self:send('/notify InventoryWindow IW_Money0 leftmouseup')
    local q, bad = wait(ctx, Trade.OPEN_MS, function() return self.win:is_open('QuantityWnd') or (self:cursor_pp() or 0) > 0 end)
    if bad then return q end
    if not q.ok then return R.fail('nothing picked up', 'clicking the platinum slot opened no amount window and put no coins on the cursor') end
    local qty = self.win:is_open('QuantityWnd')
    self.log.debug('  platinum slot: %s after %dms', qty and 'amount window' or 'coins on the cursor', q.ms or 0)
    if qty then
        local s = self.cursor:qty_set(ctx, n)
        if not s.ok then self.win:close(ctx, 'QuantityWnd'); return s end
        self:send('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
        local a, bad2 = wait(ctx, Trade.DROP_MS, function()
            return not self.win:is_open('QuantityWnd') and ((self:cursor_pp() or 0) > 0 or self:pp() < before)
        end)
        if bad2 then return a end
        self.log.debug('  accepted: %s after %dms', a.ok and 'yes' or a.why, a.ms or 0)
        if not a.ok then self.win:close(ctx, 'QuantityWnd'); return R.fail('not picked up', 'the amount window did not hand over the coins') end
    end
    local onCur, purse = self:cursor_pp(), self:pp()
    self.log.info('On the cursor: %s pp, purse %d pp (was %d)', tostring(onCur), purse, before)
    local right = (onCur == n) or (onCur == nil and before - purse == n)
    if not right then
        local pb = self:put_back_pp(ctx)
        if not pb.ok then return pb end
        return R.fail('wrong amount', string.format('%s pp came up, %d asked - put back', tostring(onCur or (before - purse)), n))
    end
    -- 3. drop on the target: the trade window opens with the coins in it
    local dropped
    for _, cmd in ipairs({ '/notify TargetWindow Target_HP leftmouseup', '/click left target' }) do
        self:send(cmd)
        local w, bad3 = wait(ctx, Trade.DROP_MS, function()
            local c = self:cursor_pp()
            if c == nil then return self:is_open() end
            return c <= 0
        end)
        if bad3 then return w end
        if w.ok then
            dropped = true
            self.log.debug('  %d pp into the trade (%s) after %dms', n, cmd:find('Target_HP', 1, true) and 'target window' or 'click on target', w.ms or 0)
            break
        end
    end
    if not dropped then
        local pb = self:put_back_pp(ctx)
        if not pb.ok then return pb end
        return R.fail('drop failed', 'the platinum stayed on the cursor after both drops - put back')
    end
    local o, bad4 = wait(ctx, Trade.OPEN_MS, function() return self:is_open() end)
    if bad4 then return o end
    if not o.ok then return R.fail('no trade window', 'the trade window did not open after the drop') end
    self.log.info('Trade window open: our money field reads %s; purse %d pp', self:money_text(), self:pp())
    -- 4. our Trade click, then the receiver's by hand
    self:send('/notify TradeWnd TRDW_Trade_Button leftmouseup')
    self.log.info('Clicked Trade (window says %s) - waiting up to %ds for %s to click Trade', self:ready_text(), Trade.HAND_MS / 1000, who.name)
    local d, bad5 = wait(ctx, Trade.HAND_MS, function() return not self:is_open() or self.win:is_open('ConfirmationDialogBox') end)
    if bad5 then return d end
    local cb = self:confirm_box()
    if cb then return cb end
    if not d.ok then
        self.log.info('Trade not done: the window says Trade is %s', self:ready_text())
        local c = self:cancel(ctx)
        if not c.ok then return c end
        return R.fail('not accepted', string.format('%s did not click Trade within %ds - cancelled', who.name, Trade.HAND_MS / 1000))
    end
    self.log.debug('  trade window closed after %dms', d.ms or 0)
    local after = self:pp()
    self.log.info('Trade window closed; purse %d pp (was %d, gave %d)', after, before, before - after)
    if before - after ~= n then
        return R.fail('not given', string.format('purse went %d -> %d pp, expected %d less (the trade was cancelled?)', before, after, n))
    end
    return R.ok({ given = n, before = before, after = after })
end

function Trade:take(ctx, item, n, link)
    local taken, k = 0, 0
    while taken < n do
        if not ctx:checkpoint() then return R.fail('stopped') end
        k = k + 1
        local units
        local l, bad = wait(ctx, Trade.LOAD_MS, function()
            units = link.loaded(k)
            return units ~= nil or link.cancelled() ~= nil
        end)
        if bad then return l end
        if link.cancelled() then return R.fail('cancelled', 'the giver gave up: ' .. link.cancelled()) end
        if not l.ok then return R.fail('nothing loaded', string.format('no trade %d loaded within %ds', k, Trade.LOAD_MS / 1000)) end
        local o, bad2 = wait(ctx, Trade.OPEN_MS, function() return self:is_open() end)
        if bad2 then return o end
        if not o.ok then return R.fail('no trade window', string.format('the giver says trade %d is loaded, but no trade window is open', k)) end
        local before = self.inv:count(item)
        self.log.info('Trade %d: %d %s loaded - accepting', k, units, item)
        self:send('/notify TradeWnd TRDW_Trade_Button leftmouseup')
        link.accept(k)
        local d, bad3 = wait(ctx, Trade.DONE_MS, function()
            return self.inv:count(item) >= before + units or link.cancelled() ~= nil or self.win:is_open('ConfirmationDialogBox')
        end)
        if bad3 then return d end
        local cb = self:confirm_box()
        if cb then return cb end
        local got = self.inv:count(item) - before
        if got < units then
            if self:is_open() then self.log.info('Trade %d not done: the window says Trade is %s', k, self:ready_text()) end
            if link.cancelled() then return R.fail('cancelled', 'the giver gave up: ' .. link.cancelled()) end
            return R.fail('not received', string.format('trade %d: %d of %d %s arrived in %ds (window %s)', k, got, units, item,
                Trade.DONE_MS / 1000, self:is_open() and 'still open' or 'closed'))
        end
        taken = taken + got
        self.log.info('Trade %d done: got %d %s (%d of %d) after %dms', k, got, item, taken, n, d.ms or 0)
        link.got(k, got)
    end
    return R.ok({ taken = taken, trades = k })
end

return Trade
