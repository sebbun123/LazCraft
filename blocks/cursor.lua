-- Cursor: the only block that puts things on, or takes things off, the cursor.
--   item()                    { id, name, stack } or nil
--   stow(ctx)                 put everything on the cursor into the bags, one item at a time, each confirmed
--   pick_up(ctx, name, n, skipPack)  put exactly n of an item on the cursor from one bag slot, confirmed
--                             (never from pack `skipPack`, e.g. the kit being filled).
--                             Returns R.ok({ id, name, stack, openedPack }). If it had to open the bag, it
--                             leaves that bag open (openedPack) for the caller to close once its whole
--                             batch is done: clicking a bag while holding an item is asking for trouble, and
--                             opening and closing per pickup was a race the old code kept losing.
--
-- Rules it keeps:
--   * Not a rule: an older note said /autoinventory does nothing while a merchant or bank window is open. The
--     old bank code autoinventoried with the bank open and it worked, so nothing here refuses; a stow that
--     does not land is reported with which windows were open.
--   * Item pace (ItemPaceMs, one setting): the next item cannot start sooner than that after the previous
--     one started; time already spent counts, so it only ever waits the difference. Every item move starts
--     here (a pickup, a stow, taking something out of a kit), so this is the one place it is kept.
--   * Ctrl-click takes one from a stack; a plain click takes the whole stack.
--   * Clicking a slot in a CLOSED bag just opens the bag, so the bag is opened (and confirmed open) first.
--   * Taking part of a stack goes through the quantity window: set the amount, wait until the field
--     shows it, then accept.
--   * The quantity window can pop up on any stack pickup, so it is always handled.
--   * Lost clicks are fixed by trying again, never by waiting a fixed time: re-send on the next frame, and if
--     the bag keeps ignoring clicks, close and reopen it. A fast connection never waits for a slow one.
--   * Cancel the quantity window with Esc; its Cancel button takes the whole stack.
local R = require('core.result')

local Cursor = {}
Cursor.__index = Cursor

Cursor.TIMEOUT_MS = 2000
Cursor.STOW_TRIES = 10  -- /autoinventory sends: re-sent STOW_RESEND_MS apart, then the last waits out STOW_MS
Cursor.STOW_RESEND_MS = 500
Cursor.STOW_MS = 6000   -- right after a combine the client can ignore it for over 2s (2.32.0 log, 23:35:17: 2.3s,
                        -- then the next one took at once), so a stow keeps trying this long before it gives up
Cursor.MAX_STOW = 20   -- a cursor queue longer than this means something keeps feeding it
Cursor.CLICK_TRIES = 3  -- a click that changed nothing by the next frame was lost and is sent again
Cursor.REOPEN_TRIES = 3 -- if no click takes, close and reopen the bag and click again (seen to clear it in game)
Cursor.SETTLE_MS = 1000 -- a click caught half done (the item in the slot and still on the cursor) gets this long to finish


-- Desync (2.46.5; 2.46.3 Vadar log): a salvage landing while the next combine was placed was put away as "not ours",
-- the game said "Inventory Desyncronization detected: Resending slot data..." and every click after that worked on a
-- stale view of the bags (a stack of 984 went into the kit as "1"). Both are counted here for the step that is placing:
--   strays    things on the cursor this block put away that nobody picked up (clear's "not ours", a wrong pickup)
--   desyncs   the game's desync lines; settle(ctx) waits until they stop (DESYNC_QUIET_MS without one)
Cursor.DESYNC_QUIET_MS = 1000
Cursor.DESYNC_MAX_MS = 6000

-- deps: mq, inventory, windows, itemPace = function() -> ms (ItemPaceMs, read fresh each time)
local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local nextEvent = 0

function Cursor.new(deps)
    local c = setmetatable({
        mq = deps.mq, inv = deps.inventory, win = deps.windows, log = deps.log or NOLOG,
        itemPace = deps.itemPace or function() return 0 end, lastItemStart = nil,
        strays = 0, desyncs = 0, lastDesync = nil,
    }, Cursor)
    if deps.mq.event then
        nextEvent = nextEvent + 1
        deps.mq.event('lc_desync_' .. nextEvent, 'Inventory Desyncronization detected#*#', function()
            c.desyncs = c.desyncs + 1
            c.lastDesync = deps.mq.gettime()
        end)
    end
    return c
end

-- The floor between two inventory clicks (core/pace ClickFloorMs, a frame by default; set by init as .pace): call
-- right before sending one. Waits only what is left of it since the last click; time already spent counts.
function Cursor:gap(ctx)
    local ms = self.pace and self.pace:floor_ms() or 0
    if ms > 0 and self.lastClick then
        local left = ms - (self.mq.gettime() - self.lastClick)
        if left > 0 then
            local p = ctx:pace(left)
            if not p.ok then return p end
        end
    end
    self.lastClick = self.mq.gettime()
    return R.ok()
end

-- Listen before a /combine (2.46.7, core/pace QuietMs): the game says it is out of step ~200ms after the move that did
-- it, so after the last item went in it gets that long to say so. Ends early on the first desync line.
-- R.ok({ ms, desynced })
function Cursor:quiet(ctx)
    local ms = self.pace and self.pace:quiet_ms() or 0
    if ms <= 0 then return R.ok({ ms = 0, desynced = false }) end
    local d0 = self.desyncs
    local w = ctx:wait(ms, function() return self.desyncs ~= d0 end)
    if not w.ok and w.why ~= 'timeout' then return w end
    local desynced = self.desyncs ~= d0
    self.log.debug('  listened %dms before the combine: %s', w.ms or ms, desynced and 'a desync line came' or 'quiet')
    return R.ok({ ms = w.ms or ms, desynced = desynced })
end

-- Wait for the game to finish resending slot data: no desync line for DESYNC_QUIET_MS (capped at DESYNC_MAX_MS).
function Cursor:settle(ctx)
    if self.mq.doevents then self.mq.doevents() end
    if not self.lastDesync then return R.ok({ ms = 0 }) end
    local t0 = self.mq.gettime()
    local w = ctx:wait(Cursor.DESYNC_MAX_MS, function()
        return self.mq.gettime() - (self.lastDesync or 0) >= Cursor.DESYNC_QUIET_MS
    end)
    if not w.ok and w.why ~= 'timeout' then return w end
    local ms = self.mq.gettime() - t0
    self.log.debug('  desync: %s after %dms (%d desync line%s so far)', w.ok and 'quiet' or 'still going', ms,
        self.desyncs, self.desyncs == 1 and '' or 's')
    return R.ok({ ms = ms })
end

function Cursor:send(cmd)
    self.log.debug('  send: %s', cmd)
    self.mq.cmd(cmd)
end

-- One line describing everything a pickup depends on, written to the log when something goes wrong.
function Cursor:snapshot(place)
    local parts = {}
    local c = self:item()
    parts[#parts + 1] = 'cursor=' .. (c and string.format('%s x%d', c.name, c.stack) or 'empty')
    local q = self.win:is_open('QuantityWnd')
    parts[#parts + 1] = 'QuantityWnd=' .. (q and ('open "' .. tostring(self.mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text()) .. '"') or 'closed')
    if place then
        parts[#parts + 1] = string.format('Pack%d=%s', place.pack, self.win:is_open('Pack' .. place.pack) and 'open' or 'closed')
        if place.slot then
            local it = self.mq.TLO.Me.Inventory('pack' .. place.pack).Item(place.slot)
            parts[#parts + 1] = string.format('slot%d=%s x%s', place.slot, tostring(it.Name()), tostring(it.Stack()))
        end
    end
    return table.concat(parts, ', ')
end

-- Call as an item move starts. Waits only what is left of ItemPaceMs since the previous item started.
function Cursor:item_start(ctx)
    local pace, now = self.itemPace(), self.mq.gettime()
    if pace > 0 and self.lastItemStart then
        local since = now - self.lastItemStart
        local left = pace - since
        if left > 0 then
            local p = ctx:pace(left)
            self.log.debug('  paced %dms: %dms between item starts (ItemPaceMs %d)', p.ms or left, since + (p.ms or left), pace)
            if not p.ok then return p end
        end
    end
    self.lastItemStart = self.mq.gettime()
    return R.ok()
end

function Cursor:item()
    local C = self.mq.TLO.Cursor
    local id = C.ID() or 0
    if id == 0 then return nil end
    local stack = C.Stack() or 1
    return { id = id, name = C.Name() or '?', stack = stack < 1 and 1 or stack }
end

function Cursor:is_empty() return self:item() == nil end

function Cursor:stow(ctx)
    local stowed = 0
    for _ = 1, Cursor.MAX_STOW do
        local cur = self:item()
        if not cur then return R.ok(stowed) end
        -- Cursor.ID is the item TYPE, so two identical items in a row look the same. The bag count going
        -- up is what proves the one we stowed landed.
        local before = self.inv:count(cur.name)
        local ps = self:item_start(ctx)
        if not ps.ok then return ps end
        local function landed()
            local now = self:item()
            if now == nil or now.id ~= cur.id or now.stack ~= cur.stack then return true end
            return self.inv:count(cur.name) >= before + cur.stack
        end
        -- The client stows at once (every stow in the 2.27.0 logs: 0ms), but one sent just as the item lands from a
        -- combine can be lost (21:05:22 and 21:07:00: nothing in 2s; the same command in cleanup took at once).
        -- A lost one is sent again after STOW_RESEND_MS - well past the 0ms it takes, so a slow one is never sent
        -- twice (a second send would stow the next item on the cursor unpaced) - and the last waits out the rest.
        local gp = self:gap(ctx)
        if not gp.ok then return gp end
        local w, t0 = nil, self.mq.gettime()
        for try = 1, Cursor.STOW_TRIES do
            if try > 1 then self.log.debug('  /autoinventory did not take - sent again (try %d)', try) end
            self:send('/autoinventory')
            local left = Cursor.STOW_MS - (self.mq.gettime() - t0)
            w = ctx:wait(try < Cursor.STOW_TRIES and math.min(Cursor.STOW_RESEND_MS, math.max(1, left)) or math.max(1, left), landed)
            if w.ok or w.why ~= 'timeout' then break end
            if self.mq.gettime() - t0 >= Cursor.STOW_MS then break end
        end
        w.ms = self.mq.gettime() - t0
        self.log.debug('  stowed %s x%d: %s after %dms', cur.name, cur.stack, w.ok and 'yes' or w.why, w.ms or 0)
        if not w.ok then
            self.log.warn('Stow failed: %s; MerchantWnd=%s, BigBankWnd=%s', self:snapshot(),
                self.win:is_open('MerchantWnd') and 'open' or 'closed', self.win:is_open('BigBankWnd') and 'open' or 'closed')
            if w.why ~= 'timeout' then return w end
            -- 2.43.10: by hand into a slot that takes it (blocks/kitslot, wired by init as by_hand)
            if self.by_hand then
                local h = self.by_hand(ctx)
                if not h.ok and h.why == 'stopped' then return h end
                if not h.ok then self.log.warn('Could not put %s away by hand either: %s', cur.name, R.describe(h)) end
                if landed() then stowed = stowed + 1; goto continue end
            end
            if self.inv:free_slots() == 0 then
                return R.fail('bags full', string.format('%s x%d is still on the cursor', cur.name, cur.stack))
            end
            return R.fail('cursor stuck', cur.name .. ' would not go into the bags')
        end
        stowed = stowed + 1
        ::continue::
    end
    return R.fail('cursor stuck', 'items kept arriving on the cursor')
end

-- Pick the slot to take from: an exact stack if there is one, else the smallest stack that can give n.
-- Splitting needs a bag slot, so for a split a loose pack-slot stack does not count.
local function choose(places, n)
    local best
    for _, p in ipairs(places) do
        if p.stack == n then return p end
        local canGive = p.stack > n and (n == 1 or p.slot ~= nil)
        if canGive and (not best or p.stack < best.stack) then best = p end
    end
    return best
end

local function click_cmd(place, ctrl)
    local mod = ctrl and '/nomodkey /ctrlkey' or '/nomodkey'
    if place.slot then return string.format('%s /itemnotify in pack%d %d leftmouseup', mod, place.pack, place.slot) end
    return string.format('%s /itemnotify pack%d leftmouseup', mod, place.pack)
end

function Cursor:qty_set(ctx, n)
    local field = 'QuantityWnd/QTYW_SliderInput'
    self:send(string.format('/invoke ${Window[%s].SetText[%d]}', field, n))
    local w = ctx:wait(Cursor.TIMEOUT_MS, function() return self.mq.TLO.Window(field).Text() == tostring(n) end)
    self.log.debug('  amount reads %s: %s after %dms', tostring(self.mq.TLO.Window(field).Text()), w.ok and 'yes' or w.why, w.ms or 0)
    if w.ok then return R.ok() end
    if w.why == 'timeout' then return R.fail('quantity not set', 'the amount field never showed ' .. n) end
    return w
end

function Cursor:qty_accept(ctx)
    local gp = self:gap(ctx)
    if not gp.ok then return gp end
    self:send('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
    local w = ctx:wait(Cursor.TIMEOUT_MS, function() return not self.win:is_open('QuantityWnd') and not self:is_empty() end)
    self.log.debug('  accepted: %s after %dms', w.ok and 'yes' or w.why, w.ms or 0)
    return w
end

-- Diagnostic: click a bag slot of `name` every `everyMs` until a click takes (cursor fills or the split
-- window opens), then undo it with Esc / stow. Nothing moves. Returns R.ok({ ms, clicks, at }): time
-- until clicks were accepted again and the clock time (mq.gettime) when one took, or R.fail('still ignored') after `maxMs`.
function Cursor:probe(ctx, name, everyMs, maxMs)
    local places = self.inv:find(name) or {}
    local place
    for _, p in ipairs(places) do if p.slot then place = p; break end end
    if not place then return R.fail('not found', name .. ' is not in a bag slot') end
    local bag = self.inv:bag(place.pack)
    if bag and not bag.open then
        local o = self.win:open_bag(ctx, place.pack)
        if not o.ok then return o end
    end
    local function arrived() return self.win:is_open('QuantityWnd') or not self:is_empty() end
    local t0, clicks = self.mq.gettime(), 0
    while true do
        clicks = clicks + 1
        self:send(click_cmd(place, false))
        local w = ctx:wait(1, arrived)
        if not w.ok and w.why ~= 'timeout' then return w end
        if arrived() then
            local at = self.mq.gettime()
            local ms = at - t0
            self.log.debug('  probe: click %d took after %dms', clicks, ms)
            if self.win:is_open('QuantityWnd') then
                local c = self.win:close(ctx, 'QuantityWnd')
                if not c.ok then return c end
            end
            local s = self:stow(ctx)
            if not s.ok then return s end
            return R.ok({ ms = ms, clicks = clicks, at = at })
        end
        if self.mq.gettime() - t0 >= maxMs then
            return R.fail('still ignored', string.format('%d clicks over %dms', clicks, self.mq.gettime() - t0))
        end
        local p = ctx:pace(everyMs)
        if not p.ok then return p end
    end
end

Cursor.click_cmd = click_cmd

-- The click ladder for anything clicked in a bag slot. Click, and re-send on the next frame up to
-- CLICK_TRIES; if the bag ignores every click, close and reopen it, up to REOPEN_TRIES. `took()` says the
-- click worked; `untouched()` says nothing is in flight (so sending again is safe). `reopen(ctx)` closes and
-- opens the container again (default: the bag's own window).
-- Returns the last wait result (why = 'ignored' when no click took), clicks, reopens.
function Cursor:click_slot(ctx, place, cmd, took, untouched, reopen)
    local clicks, reopens, w = 0, 0, nil
    while true do
        local tries = 0
        repeat
            clicks, tries = clicks + 1, tries + 1
            local gp = self:gap(ctx)   -- the floor (core/pace): never two clicks in one frame (2.46.7)
            if not gp.ok then return gp, clicks, reopens end
            self:send(cmd)
            w = ctx:wait(1, took)   -- 1ms rounds up to the next frame
            if w.ok and not took() then w = { ok = false, why = 'timeout', ms = w.ms } end
            if not w.ok and w.why ~= 'timeout' then return w, clicks, reopens end
            self.log.debug('  click %d: %s after %dms', clicks, w.ok and 'took' or 'no effect', w.ms or 0)
        until w.ok or tries >= Cursor.CLICK_TRIES or not untouched()
        if not w.ok and not untouched() then
            -- neither done nor untouched: the click is in flight (2.35.1 log: the ore showed in the station slot
            -- AND still on the cursor 49ms after the click; taking that for a miss stowed it and broke the run).
            -- Wait for it to settle one way or the other.
            local s = ctx:wait(Cursor.SETTLE_MS, function() return took() or untouched() end)
            if not s.ok and s.why ~= 'timeout' then return s, clicks, reopens end
            self.log.debug('  click %d: in flight, %s after %dms', clicks, took() and 'took' or (untouched() and 'went back' or 'still unsettled'), s.ms or 0)
            if took() then return R.ok({ ms = (w.ms or 0) + (s.ms or 0) }), clicks, reopens end
        end
        if w.ok or not untouched() then return w, clicks, reopens end
        if not place.slot or reopens >= Cursor.REOPEN_TRIES then return R.fail('ignored'), clicks, reopens end
        reopens = reopens + 1
        self.log.debug('  no click took; reopening %s (reopen %d)', place.pack and ('pack' .. place.pack) or place.bank and ('bank' .. place.bank) or 'it', reopens)
        if reopen then
            local r = reopen(ctx)
            if not r.ok then return r, clicks, reopens end
        else
            local c = self.win:close_bag(ctx, place.pack)
            if not c.ok then return c, clicks, reopens end
            local o = self.win:open_bag(ctx, place.pack)
            if not o.ok then return o, clicks, reopens end
        end
    end
end

-- Something on the cursor that this step did not put there (a mouse program, a click by hand): put away,
-- said, and the step carries on (2.32.0 log: a Brazier picked up by a mouse program stopped two runs).
function Cursor:clear(ctx, before)
    local held = self:item()
    if not held then return R.ok() end
    self.strays = self.strays + 1
    self.log.info('%s x%d is on the cursor (not ours) - putting it away%s', held.name, held.stack, before and (' before ' .. before) or '')
    return self:stow(ctx)
end

Cursor.PICKUP_TRIES = 3   -- a pickup that got something else (it landed on the cursor during the click) is tried again

function Cursor:pick_up(ctx, name, n, skipPack)
    local r
    for try = 1, Cursor.PICKUP_TRIES do
        local c = self:clear(ctx, 'picking up ' .. name)
        if not c.ok then return c end
        r = self:pick_up_once(ctx, name, n, skipPack)
        -- only something else on the cursor (it landed during the click) is worth another go; a wrong amount is not
        if r.ok or not r.foreign then return r end
        if try < Cursor.PICKUP_TRIES then self.log.info('Pickup of %s: %s - trying again', name, r.detail or r.why) end
    end
    return r
end

function Cursor:pick_up_once(ctx, name, n, skipPack)
    n = n or 1
    local held = self:item()
    if held then return R.fail('cursor busy', held.name .. ' is already on the cursor') end
    local places = self.inv:find(name, skipPack)
    if #places == 0 then return R.fail('not found', name .. ' is not in the bags') end
    local place = choose(places, n)
    if not place then return R.fail('not enough in one stack', string.format('no single stack of %s has %d', name, n)) end
    self.log.debug('  pick up %s x%d from pack%d%s (stack %d)', name, n, place.pack,
        place.slot and (' slot ' .. place.slot) or '', place.stack)

    local partial = n < place.stack and n > 1
    if partial and not place.slot then return R.fail('cannot split', name .. ' is loose in a pack slot') end
    local openedBag = false
    if place.slot then
        local bag = self.inv:bag(place.pack)
        if bag and not bag.open then
            local o = self.win:open_bag(ctx, place.pack)
            if not o.ok then return o end
            openedBag = true
        end
    end

    -- On success the bag stays open for the caller (openedPack). On failure we close it ourselves if the
    -- cursor is empty; otherwise we hand it back as openedPack so the caller's cleanup can.
    local function finish(res)
        if not res.ok and res.why ~= 'stopped' and res.why ~= 'cursor busy' then self.log.warn('Pickup failed: %s', self:snapshot(place)) end
        if not res.ok and res.why == 'cursor busy' then self.log.debug('  %s - not clicking', res.detail or res.why) end
        if not openedBag then return res end
        if res.ok then res.value.openedPack = place.pack; return res end
        if self:is_empty() and self.win:close_bag(ctx, place.pack).ok then return res end
        res.openedPack = place.pack
        return res
    end

    -- A click that works shows at once (the cursor fills or the split window opens). One that changed
    -- nothing by the next frame was lost - nothing is in flight - so it is safe to send again.
    local function arrived() return self.win:is_open('QuantityWnd') or not self:is_empty() end
    local function untouched()
        if arrived() then return false end
        local it = place.slot and self.mq.TLO.Me.Inventory('pack' .. place.pack).Item(place.slot)
            or self.mq.TLO.Me.Inventory('pack' .. place.pack)
        return (it.Stack() or 1) == place.stack
    end
    local ps = self:item_start(ctx)
    if not ps.ok then return finish(ps) end
    -- The pace can take frames: something may have landed on the cursor meanwhile. Never click with it there.
    local late = self:item()
    if late then return finish(R.fail('cursor busy', late.name .. ' landed on the cursor before the pickup click')) end
    local w, clicks, reopens = self:click_slot(ctx, place, click_cmd(place, n == 1 and place.stack > 1), arrived, untouched)
    if not w.ok and w.why == 'ignored' then
        self.log.debug('  no click took (%s)', self:snapshot(place))
        return finish(R.fail('pickup failed', string.format('nothing came onto the cursor after %d click(s) and %d reopen(s)', clicks, reopens)))
    end
    if not w.ok and w.why ~= 'timeout' then return finish(w) end
    if not w.ok then
        w = ctx:wait(Cursor.TIMEOUT_MS, arrived)   -- something changed but has not finished arriving
        self.log.debug('  after click: %s after %dms (%s)', w.ok and 'something arrived' or w.why, w.ms or 0, self:snapshot(place))
        if not w.ok then
            if w.why == 'timeout' then return finish(R.fail('pickup failed', string.format('nothing came onto the cursor after %d click(s)', clicks))) end
            return finish(w)
        end
    end

    if self.win:is_open('QuantityWnd') then
        if partial then
            local s = self:qty_set(ctx, n)
            if not s.ok then
                self.win:close(ctx, 'QuantityWnd')
                return finish(s)
            end
        end
        local a = self:qty_accept(ctx)
        if not a.ok then
            self.win:close(ctx, 'QuantityWnd')
            if a.why == 'timeout' then return finish(R.fail('pickup failed', 'the quantity window did not hand over the item')) end
            return finish(a)
        end
    end

    local got = self:item()
    if not got or got.name:lower() ~= name:lower() or got.stack ~= n then
        local desc = got and string.format('%s x%d', got.name, got.stack) or 'nothing'
        local detail = string.format('wanted %s x%d, got %s', name, n, desc)
        if got then
            local back = self:stow(ctx)
            if not back.ok then detail = detail .. '; it is still on the cursor: ' .. R.describe(back) end
        end
        local f = R.fail('wrong pickup', detail)
        f.foreign = got ~= nil and got.name:lower() ~= name:lower()
        if f.foreign then self.strays = self.strays + 1 end
        return finish(f)
    end
    got.clicks, got.reopens = clicks, reopens
    return finish(R.ok(got))
end

return Cursor
