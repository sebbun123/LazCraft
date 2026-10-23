-- Bank: the only block that opens, reads and closes the bank, and moves items in and out of it.
--   banker()                    the nearest banker in the zone: { id, name, distance } or nil
--   open(ctx, id)               target the banker and open the bank, confirmed
--   is_open()
--   count(name)                 how many are in the bank: (n, how). how = 'slots' when the bank's slots could
--                               be read, else 'client' (FindItemBankCount, which also counts the shared bank)
--   find(name)                  { {bank=, slot=, stack=}, ... } (slot nil = loose in a top-level bank slot)
--   withdraw(ctx, name, n)      take exactly n out into the bags, confirmed by the bag count. R.ok({ got, ms })
--   deposit(ctx, name, n)       put exactly n from the bags into the bank with the Auto Bank button, confirmed by
--                               the cursor emptying and the bank count. R.ok({ put, ms })
--   deposit_container(ctx, name)  one bag or kit from the bags into the first EMPTY slot inside a bank bag big enough
--                               for it, else an empty top-level bank slot; never Auto Bank. R.ok({ slot, where })
--   close(ctx)                  the Done button, confirmed
--   close_bags(ctx)             close the bags opened to take items out for a deposit
--
-- Rules it keeps:
--   * A bank is opened by targeting a banker (by id) and right-clicking it. It is a server round trip:
--     waited for, and only clicked again after OPEN_MS with nothing open.
--   * Bank slots are Me.Bank(1..24); items mostly sit in bank bags. /itemnotify in bankB S clicks one.
--   * Taking part of a stack goes through the quantity window (set the amount, confirm it shows, accept),
--     the same as from a bag. From a CLOSED bank bag a click takes the whole stack with no window (seen in
--     game): it goes straight back, the bank bag is opened (right-click bankB), and the click is repeated.
--   * Never more than asked for is stowed; extra goes back where it came from.
--   * A deposit is the exact amount picked up from the bags, then the bank window's Auto Bank button
--     (BIGB_AutoButton): the client chooses the slot, topping up stacks of the item first, like
--     /autoinventory does for bags. Pressed again only if nothing left the cursor.
--   * Every move is an item move: it starts through the cursor's item pace.
local R = require('core.result')

local Bank = {}
Bank.__index = Bank

Bank.TRIES = 3
Bank.OPEN_MS = 3000
Bank.AUTO_MS = 3000   -- Auto Bank empties the cursor within this
Bank.SLOTS = 24
local WND = 'BigBankWnd'

local NOLOG = { debug = function() end, info = function() end, warn = function() end }

function Bank.new(deps)
    return setmetatable({ mq = deps.mq, spawns = deps.spawns, inv = deps.inventory, cursor = deps.cursor,
                          win = deps.windows, log = deps.log or NOLOG, openedPacks = {}, openedBags = {} }, Bank)
end

local function lower(s) return (s or ''):lower() end

function Bank:send(cmd)
    self.log.debug('  send: %s', cmd)
    self.mq.cmd(cmd)
end

function Bank:is_open() return self.win:is_open(WND) end

function Bank:banker()
    local s = self.mq.TLO.Spawn('npc banker')
    if (s.ID() or 0) == 0 then return nil end
    return { id = s.ID(), name = s.CleanName(), distance = s.Distance3D() or 0 }
end

function Bank:open(ctx, id)
    if self:is_open() then return R.ok({ ms = 0, tries = 0 }) end
    for try = 1, Bank.TRIES do
        local t = self.spawns:target(ctx, id)
        if not t.ok then return t end
        self:send('/click right target')
        local w = ctx:wait(Bank.OPEN_MS, function() return self:is_open() end)
        self.log.debug('  %s open: %s after %dms', WND, w.ok and 'yes' or w.why, w.ms or 0)
        if w.ok then return R.ok({ ms = w.ms or 0, tries = try }) end
        if w.why ~= 'timeout' then return w end
    end
    return R.fail('bank did not open', string.format('no answer to %d clicks on the banker', Bank.TRIES))
end

-- Walk to the banker and open it. A banker the nav cannot reach to the last step (2.37.0 log: PoK's Banker
-- Granger, "no nav path ... (19 away)" from the hub spot - a counter in the way) is clicked from where we stopped
-- when it is within REACH: the click either opens it or does not, and only then is it a failure.
Bank.REACH = 30
local NAV_SHORT = { ['no path'] = true, ['did not arrive'] = true, ['nav too long'] = true }
function Bank:go_open(ctx, nav, b)
    local g = nav:go_spawn(ctx, b.id, 10)
    if not g.ok then
        if not NAV_SHORT[g.why] then return g end
        local now = self.spawns:get(b.id)
        local d = now and now.distance
        if not d or d > Bank.REACH then return g end
        self.log.info('Nav could not get closer to %s (%s) - %.0f away, trying to open it from here', b.name, g.why, d)
        local o = self:open(ctx, b.id)
        if not o.ok then
            if o.why == 'stopped' then return o end
            return R.fail(g.why, string.format('%s; and the banker did not open from %.0f away', g.detail or g.why, d))
        end
        return o
    end
    return self:open(ctx, b.id)
end

function Bank:close(ctx)
    self.openedBags = {}   -- bank bags close with the bank
    if not self:is_open() then return R.ok() end
    self:send('/notify BigBankWnd DoneButton leftmouseup')
    local w = ctx:wait(1, function() return not self:is_open() end)
    if not w.ok and w.why ~= 'timeout' then return w end
    if not self:is_open() then return R.ok() end
    self.log.debug('  Done button did not close the bank; DoClose')
    return self.win:close(ctx, WND)
end

-- Walk the bank's slots. Returns places and whether any slot could be read at all.
function Bank:find(name)
    local want, out, readable = lower(name), {}, false
    local Me = self.mq.TLO.Me
    for b = 1, Bank.SLOTS do
        local slot = Me.Bank(b)
        if (slot.ID() or 0) > 0 then
            readable = true
            local cap = slot.Container() or 0
            if cap > 0 then
                for i = 1, cap do
                    local it = slot.Item(i)
                    if (it.ID() or 0) > 0 and lower(it.Name()) == want then
                        out[#out + 1] = { bank = b, slot = i, stack = math.max(1, it.Stack() or 1) }
                    end
                end
            elseif lower(slot.Name()) == want then
                out[#out + 1] = { bank = b, slot = nil, stack = math.max(1, slot.Stack() or 1) }
            end
        end
    end
    return out, readable
end

-- Every item in the bank at once: counts[lower name] = total, and whether the slots could be read.
function Bank:snapshot()
    local counts, readable = {}, false
    local Me = self.mq.TLO.Me
    for b = 1, Bank.SLOTS do
        local slot = Me.Bank(b)
        if (slot.ID() or 0) > 0 then
            readable = true
            local cap = slot.Container() or 0
            local function add(it)
                local k = lower(it.Name())
                if k ~= '' then counts[k] = (counts[k] or 0) + math.max(1, it.Stack() or 1) end
            end
            if cap > 0 then
                for i = 1, cap do
                    local it = slot.Item(i)
                    if (it.ID() or 0) > 0 then add(it) end
                end
            else
                add(slot)
            end
        end
    end
    return counts, readable
end

-- A CONTAINER INTO AN EMPTY BANK SLOT (2.46.2), the old LazCraft's way (deposit_to_bank). Auto Bank will not take a
-- kit: Mortician's log, 03:40, three presses with a Jeweler's Kit - "You have no room left in the bank" twice, then the
-- kit went in and a bank bag (Alloy Reinforced Bank Vault) came out onto the cursor. Bags nest on Lazarus, so a kit
-- goes into the first EMPTY slot inside a bank bag big enough for it (SizeCapacity), clicked directly; with none, the
-- first empty top-level bank slot. Each slot is read empty again just before the drop - a click on a full slot swaps.
-- No room anywhere: it is not picked up at all.
function Bank:empty_places(size)
    local Me, out = self.mq.TLO.Me, {}
    for b = 1, Bank.SLOTS do
        local bag = Me.Bank(b)
        local cap = (tonumber(bag.ID()) or 0) > 0 and (tonumber(bag.Container()) or 0) or 0
        if cap > 0 and (tonumber(bag.SizeCapacity()) or 4) >= (size or 1) then
            for i = 1, cap do
                if (tonumber(bag.Item(i).ID()) or 0) == 0 then out[#out + 1] = { bank = b, slot = i } end
            end
        end
    end
    for b = 1, Bank.SLOTS do
        if (tonumber(Me.Bank(b).ID()) or 0) == 0 then out[#out + 1] = { bank = b } end
    end
    return out
end
function Bank:deposit_container(ctx, name)
    if not self:is_open() then return R.fail('not open', 'the bank is not open') end
    local size = 1
    pcall(function() size = tonumber(self.mq.TLO.FindItem('=' .. name).Size()) or 1 end)
    local places = self:empty_places(size)
    if #places == 0 then return R.fail('no bank slot', string.format('%s: no empty bank slot for it - left in the bags', name)) end
    local got = self.cursor:pick_up(ctx, name, 1)
    local opened = got.openedPack or (got.value and got.value.openedPack)
    if opened then self.openedPacks[opened] = true end
    if not got.ok then return got end
    local Me = self.mq.TLO.Me
    local refused = {}   -- a bank bag that would not take it once is not tried slot by slot
    for _, p in ipairs(places) do
        local function at() return p.slot and Me.Bank(p.bank).Item(p.slot) or Me.Bank(p.bank) end
        if not (p.slot and refused[p.bank]) and (tonumber(at().ID()) or 0) == 0 then   -- still empty, now
            if p.slot then self:send(string.format('/nomodkey /itemnotify in bank%d %d leftmouseup', p.bank, p.slot))
            else self:send(string.format('/nomodkey /itemnotify bank%d leftmouseup', p.bank)) end
            local w = ctx:wait(Bank.AUTO_MS, function() return self.cursor:is_empty() end)
            if not w.ok and w.why ~= 'timeout' then return w end
            if self.cursor:is_empty() then
                local where = p.slot and string.format('bank%d slot %d', p.bank, p.slot) or string.format('bank slot %d', p.bank)
                self.log.debug('  %s -> %s after %dms', name, where, w.ms or 0)
                return R.ok({ slot = p.bank, where = where })
            end
            local c = self.cursor:item()
            if c and lower(c.name) ~= lower(name) then
                -- something came out of the bank: never walk off with it - straight back where it was
                if p.slot then self:send(string.format('/nomodkey /itemnotify in bank%d %d leftmouseup', p.bank, p.slot))
                else self:send(string.format('/nomodkey /itemnotify bank%d leftmouseup', p.bank)) end
                ctx:wait(Bank.AUTO_MS, function() local x = self.cursor:item(); return x and lower(x.name) == lower(name) end)
                self.log.warn('  %s: %s came out of the bank - put back', name, c.name)
                break
            end
            if p.slot then refused[p.bank] = true end
            self.log.debug('  %s would not go into %s - trying the next place', name,
                p.slot and string.format('bank%d slot %d', p.bank, p.slot) or string.format('bank slot %d', p.bank))
        end
    end
    self.cursor:stow(ctx)
    return R.fail('no bank slot', string.format('%s: no bank slot took it - put back in the bags', name))
end

function Bank:count(name)
    local places, readable = self:find(name)
    if readable then
        local n = 0
        for _, p in ipairs(places) do n = n + p.stack end
        return n, 'slots'
    end
    return self.mq.TLO.FindItemBankCount('=' .. name)() or 0, 'client'
end

local function click_cmd(place)
    if place.slot then return string.format('/nomodkey /itemnotify in bank%d %d leftmouseup', place.bank, place.slot) end
    return string.format('/nomodkey /itemnotify bank%d leftmouseup', place.bank)
end

local function bank_item(mq, place)
    local slot = mq.TLO.Me.Bank(place.bank)
    return place.slot and slot.Item(place.slot) or slot
end

function Bank:withdraw(ctx, name, n)
    if not self:is_open() then return R.fail('not open', 'the bank is not open') end
    local cl = self.cursor:clear(ctx, 'taking ' .. name .. ' out of the bank')
    if not cl.ok then return cl end
    local t0, got = self.mq.gettime(), 0
    while got < n do
        local places = self:find(name)
        if #places == 0 then return R.fail('not in the bank', string.format('%s: took %d of %d, none left in the bank', name, got, n)) end
        local want = n - got
        -- an exact stack, else the smallest that covers it, else the biggest there is
        local place
        for _, p in ipairs(places) do if p.stack == want then place = p; break end end
        if not place then
            for _, p in ipairs(places) do if p.stack > want and (not place or p.stack < place.stack) then place = p end end
        end
        if not place then
            for _, p in ipairs(places) do if not place or p.stack > place.stack then place = p end end
        end
        local take = math.min(want, place.stack)
        self.log.debug('  take %s x%d from bank%d%s (stack %d)', name, take, place.bank, place.slot and (' slot ' .. place.slot) or '', place.stack)
        local before = self.inv:count(name)
        local ps = self.cursor:item_start(ctx)
        if not ps.ok then return ps end
        local function took() return not self.cursor:is_empty() or self.win:is_open('QuantityWnd') end
        -- A bank bag we opened can ignore clicks just after opening (as inventory bags do): the ladder then
        -- closes and reopens it (two right-clicks, a frame apart) and clicks again.
        local function reopen(c)
            for _ = 1, 2 do
                self:send(string.format('/nomodkey /itemnotify bank%d rightmouseup', place.bank))
                local w = c:wait(1, function() return false end)
                if w.why ~= 'timeout' then return w end
            end
            return R.ok()
        end
        local function grab()
            local where = self.openedBags[place.bank] and { slot = place.slot, bank = place.bank } or {}
            local w = self.cursor:click_slot(ctx, where, click_cmd(place), took, function() return not took() end,
                self.openedBags[place.bank] and reopen or nil)
            if not took() then
                return R.fail('not taken', string.format('%s: the click on bank%d%s did nothing (%s)', name, place.bank,
                    place.slot and (' slot ' .. place.slot) or '', tostring(w.why)))
            end
            return R.ok()
        end
        local g = grab()
        if not g.ok then return g end
        -- Part of a stack from a CLOSED bank bag comes up whole, with no split window (seen in game). Put it
        -- straight back, open that bank bag, and click again: from an open bag the split window comes up.
        local c0 = self.cursor:item()
        if take < place.stack and place.slot and c0 and c0.stack > take and not self.win:is_open('QuantityWnd') then
            self.log.debug('  the whole stack (%d) came up from closed bank bag %d; putting it back and opening the bag', c0.stack, place.bank)
            local back = self:put_back(ctx, place, name)
            if not back.ok then return back end
            self:send(string.format('/nomodkey /itemnotify bank%d rightmouseup', place.bank))
            self.openedBags[place.bank] = true
            g = grab()
            if not g.ok then return g end
        end
        if self.win:is_open('QuantityWnd') then
            if take < place.stack then
                local q = self.cursor:qty_set(ctx, take)
                if not q.ok then self.win:close(ctx, 'QuantityWnd'); return q end
            end
            local a = self.cursor:qty_accept(ctx)
            if not a.ok then self.win:close(ctx, 'QuantityWnd'); return R.fail('not taken', 'the quantity window did not hand it over') end
        end
        -- Never stow more than was asked for: anything extra goes back where it came from.
        local c1 = self.cursor:item()
        if c1 and lower(c1.name) == lower(name) and c1.stack > take then
            local back = self:put_back(ctx, place, name)
            if not back.ok then return back end
            return R.fail('could not split', string.format('%s: wanted %d from a stack of %d, the whole stack came up even from the open bag; put it back',
                name, take, place.stack))
        end
        local c = self.cursor:item()
        if not c or lower(c.name) ~= lower(name) then
            return R.fail('wrong item', string.format('wanted %s, the cursor holds %s', name, c and c.name or 'nothing'))
        end
        local st = self.cursor:stow(ctx)
        if not st.ok then return st end
        local moved = self.inv:count(name) - before
        self.log.debug('  %d %s now in the bags', moved, name)
        if moved <= 0 then return R.fail('not taken', name .. ': nothing reached the bags') end
        got = got + moved
    end
    if got ~= n then return R.fail('wrong amount', string.format('%s: wanted %d, took %d', name, n, got)) end
    return R.ok({ got = got, ms = self.mq.gettime() - t0 })
end

-- Drop what is on the cursor back into the bank slot it came from, confirmed.
function Bank:put_back(ctx, place, name)
    local function back() return self.cursor:is_empty() end
    self.cursor:click_slot(ctx, {}, click_cmd(place), back, function() return not back() end)
    if back() then return R.ok() end
    return R.fail('stuck on cursor', string.format('%s could not be put back into bank%d slot %s', name, place.bank, tostring(place.slot)))
end

-- First empty slot inside a bank bag.
-- Deposit with the bank window's Auto Bank button: the client puts what is on the cursor into the bank the
-- way /autoinventory does for bags (topping up stacks of it first, then an empty slot).
function Bank:deposit(ctx, name, n)
    if not self:is_open() then return R.fail('not open', 'the bank is not open') end
    local t0, put = self.mq.gettime(), 0
    while put < n do
        local have = self.inv:count(name)
        if have == 0 then return R.fail('none left', string.format('%s: put %d of %d, none left in the bags', name, put, n)) end
        -- the biggest single stack that does not exceed what is left to put (one pickup, no split if possible)
        local want = n - put
        local take
        for _, p in ipairs(self.inv:find(name)) do
            if p.stack <= want and (not take or p.stack > take) then take = p.stack end
        end
        take = take or want
        local got = self.cursor:pick_up(ctx, name, take)
        local opened = got.openedPack or (got.value and got.value.openedPack)
        if opened then self.openedPacks[opened] = true end
        if not got.ok then return got end
        local before = self:count(name)
        local function held() local c = self.cursor:item(); return c ~= nil and lower(c.name) == lower(name) and c.stack == take end
        local w
        for try = 1, Bank.TRIES do
            self:send('/notify BigBankWnd BIGB_AutoButton leftmouseup')
            w = ctx:wait(Bank.AUTO_MS, function() return not held() end)
            if not w.ok and w.why ~= 'timeout' then return w end
            if not held() then break end
            self.log.debug('  Auto Bank %d: %s still on the cursor after %dms', try, name, w.ms or 0)
        end
        if held() then
            self.cursor:stow(ctx)
            return R.fail('bank full', string.format('Auto Bank left %s on the cursor (bank full?) - put back in the bags', name))
        end
        if not self.cursor:is_empty() then
            local c = self.cursor:item()
            self.cursor:stow(ctx)
            return R.fail('not deposited', string.format('Auto Bank left %s x%d on the cursor - put back in the bags', c.name, c.stack))
        end
        local after = self:count(name)
        if after ~= before + take then
            self.log.warn('Bank: Auto Bank took %s x%d but the bank count went %d -> %d', name, take, before, after)
        end
        self.log.debug('  %s x%d -> bank by Auto Bank after %dms (bank %d -> %d)', name, take, w.ms or 0, before, after)
        put = put + take
    end
    return R.ok({ put = put, ms = self.mq.gettime() - t0 })
end

-- Close the bags opened to take items out for a deposit.
function Bank:close_bags(ctx)
    for pk in pairs(self.openedPacks) do
        if self.cursor:is_empty() then self.win:close_bag(ctx, pk) end
    end
    self.openedPacks = {}
    return R.ok()
end

return Bank
