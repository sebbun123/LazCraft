-- Merchant: the only block that opens, reads and closes the merchant window.
--   open(ctx, id, want)  open the merchant with this spawn id and wait for its full item list; `want` (item
--                     names, optional): also wait, up to LIST_MS, until each is on the list (2.43.7).
--                     R.ok({ openMs, listMs, items, listReady, tries, missing = { names not on it } })
--   has(name)         the open merchant's list has it
--   close(ctx)        close the window, confirmed
--   is_open()
--   buy(ctx, name, n)    buy exactly n, confirmed by the bag count. R.ok({ ms, got })
--   sell(ctx, name, n)   sell n from the bags, confirmed by the bag count. R.ok({ ms, sold })
--   stack_size(name)     how many fit in one bag slot (1 = does not stack), read off the open merchant's item;
--                        nil when it does not sell it. Every read is learned (core/stacks).
--
-- Rules it keeps:
--   * Open by target id with Merchant.OpenWindow, never a screen click: vendors can stand stacked on one
--     spot and a click opens whichever body is in front.
--   * The window is ours only when Merchant.ID is the spawn we asked for. A different one is closed and
--     reported (not retried): we have not seen it happen yet, and want to know if it does.
--   * The item list arrives in pieces after the window opens. Merchant.ItemsReceived says it is complete;
--     nothing reads the list before that. It is not always right (2.43.6 log: Audri Deepfacet, 153 items in 17
--     opens, said complete at 7 and at 10): what we came for (the data says she sells it) is waited for too.
--   * Opening is a server round trip, so it is waited for (ending the moment it opens). If it never
--     answers, the request is sent again, up to 3 times.
--   * "Show only items I can use" hides tradeskill items, so it is switched off whenever a window opens.
--   * The merchant's item is selected with Merchant.SelectItem. Ours is selected the way a player does it:
--     a click on the bag slot while the window is open (/selectitem did not select bag items on Lazarus).
--     The bag click uses the cursor's click ladder (re-click, then reopen the bag).
--   * A selection is confirmed by the name AND where the selected item lives: one of ours reports
--     ItemSlot = 22 + pack and ItemSlot2 = slot - 1; the merchant's does not. (Buy and Sell both stay lit
--     on Lazarus whatever is selected, so the buttons say nothing.) Every buy and every sell selects again
--     first. If a click picks the item up instead, it is put back and reported.
--   * Buy and Sell are never re-sent: they spend money and items. If the count does not move, it is reported.
--   * How many per buy comes from the item: not Stackable = one at a time (a mold), else up to its StackSize.
local R = require('core.result')

local Merchant = {}
Merchant.__index = Merchant

Merchant.TRIES = 3
Merchant.OPEN_MS = 3000   -- no answer by now: the request was lost; ask again
Merchant.LIST_MS = 5000
Merchant.TRADE_MS = 3000  -- the server answers a buy or sell within this

local NOLOG = { debug = function() end, warn = function() end }

function Merchant.new(deps)
    return setmetatable({ mq = deps.mq, spawns = deps.spawns, win = deps.windows, inv = deps.inventory,
                          cursor = deps.cursor, stacks = deps.stacks, log = deps.log or NOLOG }, Merchant)
end

function Merchant:is_open() return self.win:is_open('MerchantWnd') end
function Merchant:open_id() return self.mq.TLO.Merchant.ID() or 0 end

function Merchant:close(ctx) return self.win:close(ctx, 'MerchantWnd') end

function Merchant:open(ctx, id, want)
    local M = self.mq.TLO.Merchant
    if self:is_open() then
        if self:open_id() == id then
            local m = self:wait_for(ctx, want)
            if not m.ok then return m end
            return R.ok({ openMs = 0, listMs = 0, items = M.Items() or 0, listReady = M.ItemsReceived() == true, tries = 0, missing = m.value })
        end
        local c = self:close(ctx)
        if not c.ok then return c end
    end
    for try = 1, Merchant.TRIES do
        if try > 1 then
            -- the window did not come (2.43.1 log: Jaren Cloudchaser, 3 x 3s, a few yards away; clicks from the user's
            -- other computer were bleeding over): /cleanup closes every window before the next ask (2.43.4)
            self.log.debug('  send: /cleanup (MerchantWnd did not open - every window closed before asking again)')
            self.mq.cmd('/cleanup')
            local c = ctx:wait(1000, function() return not self.win:is_open('InventoryWindow') end)
            if not c.ok and c.why ~= 'timeout' then return c end
        end
        local t = self.spawns:target(ctx, id)
        if not t.ok then return t end
        local cmd = '/invoke ${Merchant.OpenWindow}'
        self.log.debug('  send: %s', cmd)
        self.mq.cmd(cmd)
        local w = ctx:wait(Merchant.OPEN_MS, function() return self:is_open() end)
        self.log.debug('  MerchantWnd open: %s after %dms', w.ok and 'yes' or w.why, w.ms or 0)
        if not w.ok and w.why ~= 'timeout' then return w end
        if w.ok then
            if self:open_id() == id then
                local l = ctx:wait(Merchant.LIST_MS, function() return M.ItemsReceived() == true end)
                if not l.ok and l.why ~= 'timeout' then return l end
                local items = M.Items() or 0
                self.log.debug('  item list: %s, %d items after %dms', l.ok and 'complete' or 'incomplete', items, l.ms or 0)
                local a = self:show_all(ctx)
                if not a.ok then return a end
                local m = self:wait_for(ctx, want)
                if not m.ok then return m end
                return R.ok({ openMs = w.ms or 0, listMs = l.ms or 0, items = M.Items() or 0, listReady = l.ok, tries = try, missing = m.value })
            end
            local got = self:open_id()
            local c = self:close(ctx)
            if not c.ok then return c end
            return R.fail('wrong merchant', string.format('opened spawn %d, wanted %d', got, id))
        end
    end
    return R.fail('merchant did not open', string.format('spawn %d after %d tries', id, Merchant.TRIES))
end

local function lower(s) return (s or ''):lower() end

function Merchant:has(name)
    return self:is_open() and (self.mq.TLO.Merchant.Item('=' .. name).ID() or 0) ~= 0
end

-- Each of `want` on the open list, waited for up to LIST_MS. -> R.ok({ names still not on it })
function Merchant:wait_for(ctx, want)
    if not want or #want == 0 then return R.ok({}) end
    local function missing()
        local out = {}
        for _, n in ipairs(want) do if not self:has(n) then out[#out + 1] = n end end
        return out
    end
    if #missing() == 0 then return R.ok({}) end
    local before = self.mq.TLO.Merchant.Items() or 0
    local w = ctx:wait(Merchant.LIST_MS, function() return #missing() == 0 end)
    if not w.ok and w.why ~= 'timeout' then return w end
    local left = missing()
    self.log.debug('  what we came for on the list: %s after %dms (%d items, %d when it said complete)%s', w.ok and 'yes' or 'no',
        w.ms or 0, self.mq.TLO.Merchant.Items() or 0, before, #left > 0 and ('; not on it: ' .. table.concat(left, ', ')) or '')
    return R.ok(left)
end

-- Client-side clicks: confirmed by the next frame, re-sent up to 3 times.
function Merchant:click(ctx, cmd, done, what, force)
    if not force and done() then return R.ok() end
    for try = 1, Merchant.TRIES do
        self.log.debug('  send: %s', cmd)
        self.mq.cmd(cmd)
        local w = ctx:wait(1, done)
        if w.ok or done() then
            self.log.debug('  %s after %dms%s', what, w.ms or 0, try > 1 and (', try ' .. try) or '')
            return R.ok()
        end
        if w.why ~= 'timeout' then return w end
    end
    return R.fail('no response', string.format('%s: nothing changed after %d tries (%s)', what, Merchant.TRIES, self:state()))
end

-- One line with everything selection depends on, for the log when it does not take.
function Merchant:state()
    local TLO = self.mq.TLO
    local function on(b) return TLO.Window('MerchantWnd/' .. b).Enabled() == true and 'on' or 'off' end
    local S = TLO.Merchant.SelectedItem
    return string.format('selected="%s" stack=%s slot=%s/%s, Buy=%s, Sell=%s, label="%s"',
        tostring(S.Name()), tostring(S.Stack()), tostring(S.ItemSlot()), tostring(S.ItemSlot2()),
        on('MW_Buy_Button'), on('MW_Sell_Button'), tostring(TLO.Window('MerchantWnd/MW_SelectedItemLabel').Text()))
end

function Merchant:show_all(ctx)
    local btn = self.mq.TLO.Window('MerchantWnd/MW_UsableButton')
    if btn.Checked() ~= true then return R.ok() end
    return self:click(ctx, '/nomodkey /notify MerchantWnd MW_UsableButton leftmouseup',
        function() return btn.Checked() ~= true end, '"Show only items I can use" off')
end

-- Is the selected item this one of ours, at `place` in the bags?
function Merchant:selected_ours(name, place)
    local S = self.mq.TLO.Merchant.SelectedItem
    if lower(S.Name()) ~= lower(name) then return false end
    if place.slot then return S.ItemSlot() == 22 + place.pack and S.ItemSlot2() == place.slot - 1 end
    return S.ItemSlot() == 22 + place.pack
end

-- Is the merchant's own item of this name selected (not one of ours)?
function Merchant:selected_theirs(name)
    local S = self.mq.TLO.Merchant.SelectedItem
    if lower(S.Name()) ~= lower(name) then return false end
    local slot, slot2 = S.ItemSlot() or -1, S.ItemSlot2() or -1
    return not (slot >= 23 and slot <= 32 and self:is_ours_at(slot, slot2, name))
end

-- Does our bag really hold this item at that ItemSlot/ItemSlot2?
function Merchant:is_ours_at(slot, slot2, name)
    local bag = self.mq.TLO.Me.Inventory('pack' .. (slot - 22))
    local it = slot2 >= 0 and bag.Item(slot2 + 1) or bag
    return lower(it.Name()) == lower(name)
end

-- How many we hold: bags plus the cursor (a buy can land on the cursor when the bags are tight).
function Merchant:have(name)
    local n = self.inv:count(name)
    local c = self.cursor:item()
    if c and lower(c.name) == lower(name) then n = n + c.stack end
    return n
end

function Merchant:stack_size(name)
    if not self:is_open() then return nil end
    local it = self.mq.TLO.Merchant.Item('=' .. name)
    if (it.ID() or 0) == 0 then return nil end
    if self.stacks then return self.stacks:from_item(name, it, 'merchant') end
    if it.Stackable() ~= true then return 1 end
    return tonumber(it.StackSize()) or nil
end

function Merchant:buy(ctx, name, n)
    if not self:is_open() then return R.fail('not open', 'no merchant window') end
    local it = self.mq.TLO.Merchant.Item('=' .. name)
    if (it.ID() or 0) == 0 then
        return R.fail('not sold here', name .. ' is not on this merchant')
    end
    -- The item says how it stacks: a non-stackable one is bought one at a time, a stackable one at most a
    -- full stack per buy. Each buy is confirmed by the count before the next.
    local stackable = it.Stackable() == true
    local per = stackable and math.max(1, it.StackSize() or n) or 1
    if self.stacks then self.stacks:from_item(name, it, 'merchant') end
    local t0, got = self.mq.gettime(), 0
    while got < n do
        if not ctx:checkpoint() then return R.fail('stopped') end
        local s = self:click(ctx, string.format('/invoke ${Merchant.SelectItem[=%s]}', name),
            function() return self:selected_theirs(name) end, 'selected ' .. name .. ' to buy', true)
        if not s.ok then return s end
        local k = math.min(per, n - got)
        local before = self:have(name)
        self.log.debug('  send: /invoke ${Merchant.Buy[%d]} (%s)', k, stackable and ('stacks to ' .. per) or 'does not stack')
        self.mq.cmd(string.format('/invoke ${Merchant.Buy[%d]}', k))
        local w = ctx:wait(Merchant.TRADE_MS, function() return self:have(name) >= before + k end)
        local this = self:have(name) - before
        self.log.debug('  bought %d of %d after %dms', this, k, w.ms or 0)
        if not w.ok and w.why ~= 'timeout' then return w end
        if not self.cursor:is_empty() then
            local st = self.cursor:stow(ctx)
            if not st.ok then return st end
        end
        if this <= 0 then
            return R.fail('not bought', string.format('%s: nothing arrived after %d of %d (money, bags full, or no answer)', name, got, n))
        end
        got = got + this
    end
    if got ~= n then return R.fail('wrong amount', string.format('%s: wanted %d, got %d', name, n, got)) end
    return R.ok({ ms = self.mq.gettime() - t0, got = got })
end

function Merchant:sell(ctx, name, n)
    if not self:is_open() then return R.fail('not open', 'no merchant window') end
    local sold, t0 = 0, self.mq.gettime()
    local opened = {}
    local function finish(res)
        for pack in pairs(opened) do
            if self.cursor:is_empty() then self.win:close_bag(ctx, pack) end
        end
        return res
    end
    local function picked() return not self.cursor:is_empty() or self.win:is_open('QuantityWnd') end
    while sold < n do
        local places = self.inv:find(name) or {}
        local place = places[1]
        for _, p in ipairs(places) do if p.slot then place = p; break end end
        if not place then return finish(R.fail('none left', string.format('%s: sold %d of %d, none left', name, sold, n))) end
        local before = self.inv:count(name)
        if place.slot then
            local bag = self.inv:bag(place.pack)
            if bag and not bag.open then
                local o = self.win:open_bag(ctx, place.pack)
                if not o.ok then return finish(o) end
                opened[place.pack] = true
            end
        end
        local function took() return self:selected_ours(name, place) or picked() end
        local w = self.cursor:click_slot(ctx, place, self.cursor.click_cmd(place, false), took, function() return not took() end)
        if picked() then
            -- Put it back exactly where it came from.
            self.win:close(ctx, 'QuantityWnd')
            local back = ''
            if not self.cursor:is_empty() then
                local b = self:click(ctx, self.cursor.click_cmd(place, false), function() return self.cursor:is_empty() end, 'put it back')
                if not b.ok then back = '; it is still on the cursor' end
            end
            return finish(R.fail('picked up', name .. ': the click picked it up instead of selecting it for sale' .. back))
        end
        if not w.ok then
            if w.why ~= 'ignored' and w.why ~= 'timeout' then return finish(w) end
            return finish(R.fail('not selected', string.format('%s: the click did not select it (%s)', name, self:state())))
        end
        self.log.debug('  selected our %s (pack%d%s): %s', name, place.pack, place.slot and (' slot ' .. place.slot) or '', self:state())
        local k = math.min(n - sold, self.mq.TLO.Merchant.SelectedItem.Stack() or 1)
        self.log.debug('  send: /invoke ${Merchant.Sell[%d]}', k)
        self.mq.cmd(string.format('/invoke ${Merchant.Sell[%d]}', k))
        local sw = ctx:wait(Merchant.TRADE_MS, function() return self.inv:count(name) <= before - k end)
        local gone = before - self.inv:count(name)
        self.log.debug('  sold %d of %d after %dms', gone, k, sw.ms or 0)
        if not sw.ok and sw.why ~= 'timeout' then return finish(sw) end
        if gone <= 0 then return finish(R.fail('not sold', string.format('%s: the merchant did not take it', name))) end
        sold = sold + gone
    end
    return finish(R.ok({ ms = self.mq.gettime() - t0, sold = sold }))
end

return Merchant
