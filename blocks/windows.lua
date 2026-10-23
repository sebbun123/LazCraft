-- Windows: the one place that opens, closes and asks about game windows.
--   is_open(name)
--   wait_open(ctx, name, ms) / wait_closed(ctx, name, ms)
--   close(ctx, name)              each window by the method it actually responds to, then confirmed
--   open_bag(ctx, pack) / close_bag(ctx, pack)
--
-- Rules it keeps:
--   * The station window (TradeskillWnd) only closes with DoClose; Esc never reaches it.
--   * The quantity window closes with Esc. Esc closes whatever is on top, so it is pressed again (next
--     frame) until ours closes. (A kit's combine window is closed by the kit block, by right-clicking the kit.)
--   * Right-clicking a bag TOGGLES it, so a bag is only clicked when its open state is not what we want,
--     and the click is confirmed by reading the state back; one that changed nothing in BAG_RESEND_MS was
--     lost and is sent again (up to BAG_SENDS).
--   * A bag's open state is read from its window (Pack1..Pack10); the item's own Open member does not
--     report it on Lazarus.
--   * The bag window reports open the moment it is asked to open. A click into it can still be lost right
--     after; the cursor's click ladder (re-click next frame, then reopen) deals with that, not a wait here.
local R = require('core.result')

local Windows = {}
Windows.__index = Windows

Windows.TIMEOUT_MS = 2000
Windows.BAG_RESEND_MS = 500   -- a bag right-click that changed nothing by then was lost: sent again
Windows.BAG_SENDS = 4

-- How each window is closed (keys lowercased). Anything not listed closes with DoClose.
local CLOSE_BY = {
    containercombine_items = 'esc',
    quantitywnd = 'esc',
}
Windows.ESC_TRIES = 5   -- Esc closes whatever is on top, so it may take more than one to reach ours

local NOLOG = { debug = function() end }

function Windows.new(mq, log)
    return setmetatable({ mq = mq, log = log or NOLOG }, Windows)
end

function Windows:send(cmd)
    self.log.debug('  send: %s', cmd)
    self.mq.cmd(cmd)
end

function Windows:is_open(name)
    return self.mq.TLO.Window(name).Open() == true
end

function Windows:wait_open(ctx, name, ms)
    local w = ctx:wait(ms or Windows.TIMEOUT_MS, function() return self:is_open(name) end)
    self.log.debug('  %s open: %s after %dms', name, w.ok and 'yes' or w.why, w.ms or 0)
    if w.ok then return R.ok() end
    if w.why == 'timeout' then return R.fail('timeout', name .. ' did not open') end
    return w
end

function Windows:wait_closed(ctx, name, ms)
    local w = ctx:wait(ms or Windows.TIMEOUT_MS, function() return not self:is_open(name) end)
    self.log.debug('  %s closed: %s after %dms', name, w.ok and 'yes' or w.why, w.ms or 0)
    if w.ok then return R.ok() end
    if w.why == 'timeout' then return R.fail('timeout', name .. ' did not close') end
    return w
end

function Windows:close(ctx, name)
    if not self:is_open(name) then return R.ok() end
    if CLOSE_BY[name:lower()] ~= 'esc' then
        self.log.debug('  DoClose: %s', name)
        self.mq.TLO.Window(name).DoClose()
        return self:wait_closed(ctx, name)
    end
    -- Esc acts in the client at once: if ours is still open on the next frame, Esc closed something
    -- else on top of it, so press again straight away.
    local last
    for _ = 1, Windows.ESC_TRIES do
        self:send('/keypress esc')
        last = self:wait_closed(ctx, name, 1)
        if last.ok or last.why ~= 'timeout' then return last end
    end
    return last
end

local function bag_open(mq, pack)
    return mq.TLO.Window('Pack' .. pack).Open() == true
end
Windows.bag_open = bag_open

local function set_bag(self, ctx, pack, want)
    local item = self.mq.TLO.Me.Inventory('pack' .. pack)
    if (item.Container() or 0) == 0 then return R.fail('not a bag', 'pack' .. pack) end
    if bag_open(self.mq, pack) == want then
        self.log.debug('  pack%d already %s', pack, want and 'open' or 'closed')
        return R.ok()
    end
    -- The bag window answers at once; still unchanged after BAG_RESEND_MS, the click was lost (2.35.0 log: the
    -- first right-click after Esc closed a station's window, three times, 2s each; the next one opened it at
    -- once), so it is sent again - never while the state already shows what we want (it toggles).
    local w
    for send = 1, Windows.BAG_SENDS do
        self:send(string.format('/nomodkey /itemnotify pack%d rightmouseup', pack))
        w = ctx:wait(Windows.BAG_RESEND_MS, function() return bag_open(self.mq, pack) == want end)
        self.log.debug('  pack%d %s: %s after %dms%s', pack, want and 'open' or 'closed', w.ok and 'yes' or w.why, w.ms or 0,
            send > 1 and string.format(' (click %d)', send) or '')
        if w.ok then return R.ok() end
        if w.why ~= 'timeout' then return w end
    end
    return R.fail('timeout', string.format('pack%d did not %s (%d right-clicks)', pack, want and 'open' or 'close', Windows.BAG_SENDS))
end

function Windows:open_bag(ctx, pack) return set_bag(self, ctx, pack, true) end
function Windows:close_bag(ctx, pack) return set_bag(self, ctx, pack, false) end

return Windows
