-- KitSlot: getting a kit into a top-level inventory slot for a combine, and putting everything back after.
--   ensure(ctx, names)   a kit (any of these bag names) in a top-level slot: R.ok({ pack, how })
--   restore(ctx)         the original pack10 bag back in pack10, every moved kit back where it was found
--   moved()              has anything been moved since the last restore
--   in_kits(names)       stacks of these items inside a kit in a top-level slot
--   unkit(ctx, places)   move those stacks out into free slots of plain bags
--
-- A kit in a top-level slot opens the kit's way (blocks/kit, set by init as .kit), never as a bag: on Lazarus its
-- right-click raises the tradeskill window and no PackN window (2.46.4).
-- Rules it keeps (agreed with Jacob):
--   * A kit already in any top-level slot is used where it is (someone may have put it there).
--   * Otherwise it goes into pack10: the last bag to fill, so the one we can borrow.
--       pack10 empty            -> the kit goes in
--       pack10 an empty bag/kit -> swap: the kit goes in, the other takes the kit's old spot
--       pack10 a bag with items -> its items go to free slots in the other bags (each placed explicitly:
--                                  /autoinventory would drop them back into the same bag), then swap
--       pack10 a single item    -> the kit goes in, the item comes to the cursor and is stowed
--   * Before anything goes into a bag, the bag is checked: too small for it (Size vs SizeCapacity), or a
--     tradeskill-only bag (lists.ini TradeskillOnlyBags, e.g. Artisan's Adept Attache) and not a tradeskill
--     item -> straight to another free slot that takes it. A refusal looks like a lost click, so it is never
--     tried. A bag with items never goes inside another bag.
--   * At the end (cleanup too): the original pack10 bag goes back in pack10 and every kit we moved goes
--     back where it was found. The items emptied out of the pack10 bag stay where they landed, and so does
--     a single item that was in pack10 (otherwise the bag is filled and emptied on every run).
--   * Every pickup starts with an empty cursor and every move is confirmed by reading the slots, with the
--     cursor's click ladder. After putting things back, every slot is read again: "put back" is only said
--     when it is true.
local R = require('core.result')

local KitSlot = {}
KitSlot.__index = KitSlot

KitSlot.PACK = 10

local NOLOG = { debug = function() end, info = function() end, warn = function() end }

function KitSlot.new(deps)
    return setmetatable({ mq = deps.mq, cursor = deps.cursor, win = deps.windows, isKit = deps.isKit or function() return false end,
                          tsOnly = deps.tsOnly or function() return false end,
                          log = deps.log or NOLOG, tracked = {}, home = nil, opened = {} }, KitSlot)
end

local function lower(s) return (s or ''):lower() end
local function key(p) return p.slot and (p.pack .. ':' .. p.slot) or tostring(p.pack) end
local function label(p) return p.slot and string.format('pack%d slot %d', p.pack, p.slot) or ('pack' .. p.pack) end

-- What sits at a place: { name, bag (slots, 0 for an item), items, size, cap } or nil.
function KitSlot:read(p)
    local top = self.mq.TLO.Me.Inventory('pack' .. p.pack)
    local it = p.slot and top.Item(p.slot) or top
    if (it.ID() or 0) == 0 then return nil end
    return { name = it.Name(), bag = it.Container() or 0, items = it.Items and it.Items() or 0,
             size = it.Size and it.Size() or 0, cap = it.SizeCapacity and it.SizeCapacity() or 0,
             ts = it.Tradeskills and it.Tradeskills() == true or false }
end

function KitSlot:cursor_name() local c = self.cursor:item(); return c and lower(c.name) end

-- A kit in a top-level slot (2.46.4): a right-click on it opens the tradeskill window, never a PackN window (2.46.3
-- Cadbane log: "pack9 did not open (4 right-clicks)" on a Planar Fletching Kit, every time), so it is opened the kit's
-- way (blocks/kit: right-click, then Experiment) and its slots are clicked in its combine window.
function KitSlot:kit_at(pack)
    return self.kit ~= nil and self.isKit(self.mq.TLO.Me.Inventory('pack' .. pack).Name())
end

function KitSlot:open_for(ctx, p)
    if not p.slot then return R.ok() end
    if self:kit_at(p.pack) then
        if self.openedKit == p.pack then return R.ok() end
        if self.openedKit then self:close_opened(ctx) end
        local o = self.kit:open(ctx, p.pack)
        if o.ok then self.openedKit = p.pack end
        return o
    end
    if self.win:is_open('Pack' .. p.pack) then return R.ok() end
    local o = self.win:open_bag(ctx, p.pack)
    if o.ok then self.opened[p.pack] = true end
    return o
end

function KitSlot:reopen_for(p)
    if not self:kit_at(p.pack) then return nil end
    return function(ctx) return self.kit:reopen(ctx, p.pack) end
end

function KitSlot:close_opened(ctx)
    for pk in pairs(self.opened) do self.win:close_bag(ctx, pk) end
    self.opened = {}
    if self.openedKit then
        local c = self.kit:close(ctx, self.openedKit)
        if not c.ok then self.log.warn('Kits: could not close the kit in pack%d (%s)', self.openedKit, R.describe(c)) end
        self.openedKit = nil
    end
end

-- Pick up what is at `p` (the cursor must be empty).
function KitSlot:pickup(ctx, p)
    local what = self:read(p)
    if not what then return R.fail('nothing there', label(p) .. ' is empty') end
    local cl = self.cursor:clear(ctx, 'moving ' .. what.name)
    if not cl.ok then return cl end
    local o = self:open_for(ctx, p)
    if not o.ok then return o end
    local name = lower(what.name)
    local function have() return self:cursor_name() == name and self:read(p) == nil end
    -- a stack in an open bag asks how many (proven at the bank): the whole stack is the default
    local function took() return have() or self.win:is_open('QuantityWnd') end
    local function untouched() return self.cursor:item() == nil and not self.win:is_open('QuantityWnd') and lower((self:read(p) or {}).name) == name end
    local w = self.cursor:click_slot(ctx, p, self.cursor.click_cmd(p, false), took, untouched, self:reopen_for(p))
    if self.win:is_open('QuantityWnd') then
        local a = self.cursor:qty_accept(ctx)
        if not a.ok then return a end
    end
    if not have() then return R.fail('not picked up', string.format('%s at %s (%s)', what.name, label(p), tostring(w.why))) end
    self.log.debug('  picked up %s from %s', what.name, label(p))
    return R.ok(what)
end

-- Drop the cursor's item at `p`. R.ok(what came back onto the cursor, or nil). R.fail('refused') when the
-- game would not take it there (too big for that bag, or a bag with items).
function KitSlot:drop(ctx, p)
    local c = self.cursor:item()
    if not c then return R.fail('cursor empty', 'nothing to drop at ' .. label(p)) end
    local o = self:open_for(ctx, p)
    if not o.ok then return o end
    local before = self:read(p)
    local name, was = lower(c.name), before and lower(before.name)
    local function took()
        local now = self:read(p)
        if not now or lower(now.name) ~= name then return false end
        if was then return self:cursor_name() == was end
        return self.cursor:item() == nil
    end
    local function untouched()
        local now = self:read(p)
        return self:cursor_name() == name and lower(now and now.name) == lower(was)
    end
    local w = self.cursor:click_slot(ctx, p, self.cursor.click_cmd(p, false), took, untouched, self:reopen_for(p))
    if not took() then
        if untouched() then return R.fail('refused', string.format('%s would not go into %s', c.name, label(p))) end
        return R.fail('not dropped', string.format('%s at %s (%s)', c.name, label(p), tostring(w.why)))
    end
    self.log.debug('  %s -> %s%s', c.name, label(p), before and (' (' .. before.name .. ' came back)') or '')
    return R.ok(before)
end

-- Would this bag (a top-level one) take `what`? Not when it is too small for it, and a tradeskill-only bag
-- (lists.ini, e.g. Artisan's Adept Attache) takes only tradeskill items. `what` unknown: only plain bags.
function KitSlot:takes(bag, what)
    if self.tsOnly(bag.Name()) and not (what and what.ts) then return false end
    local cap = bag.SizeCapacity and bag.SizeCapacity() or 0
    if what and (what.size or 0) > 0 and cap > 0 and what.size > cap then return false end
    return true
end

-- A free slot in a bag other than pack10 (and not a kit) that takes `what`.
function KitSlot:free_slot(what, avoid)
    local Me = self.mq.TLO.Me
    for pk = 1, 10 do
        if pk ~= KitSlot.PACK then
            local bag = Me.Inventory('pack' .. pk)
            local slots = bag.Container() or 0
            if slots > 0 and not self.isKit(bag.Name()) and self:takes(bag, what) then
                for i = 1, slots do
                    local p = { pack = pk, slot = i }
                    if (bag.Item(i).ID() or 0) == 0 and not (avoid and key(avoid) == key(p)) then return p end
                end
            end
        end
    end
    return nil
end

-- Every bag as it stands, for the log: free slots, tradeskill-only, the biggest item it holds, and whether it
-- would take `what` (2.43.10: proof for an item /autoinventory would not stow).
function KitSlot:bag_report(what)
    local Me, parts = self.mq.TLO.Me, {}
    for pk = 1, 10 do
        local bag = Me.Inventory('pack' .. pk)
        local slots = bag.Container() or 0
        if (bag.ID() or 0) > 0 and slots > 0 then
            local free = 0
            for i = 1, slots do if (bag.Item(i).ID() or 0) == 0 then free = free + 1 end end
            parts[#parts + 1] = string.format('pack%d %s %d/%d free%s, size up to %s%s', pk, tostring(bag.Name()), free, slots,
                self.tsOnly(bag.Name()) and ', tradeskill only' or '', tostring(bag.SizeCapacity and bag.SizeCapacity() or '?'),
                self.isKit(bag.Name()) and ', a kit' or ((what and not self:takes(bag, what)) and ', will not take it' or ''))
        end
    end
    return table.concat(parts, '; ')
end

-- What /autoinventory would not stow (2.43.10, 2.43.7 log: Brut Champagne and Patty Melt stayed on the cursor
-- through 30 /autoinventory sends, and E3 could not stow them either, ~98 slots free): every bag is logged, then
-- it is clicked by hand into a free slot of a bag that takes it (big enough, not tradeskill-only unless it is a
-- tradeskill item). R.ok(place) or R.fail('no room').
function KitSlot:stow_by_hand(ctx)
    local c = self.cursor:item()
    if not c then return R.ok() end
    local C = self.mq.TLO.Cursor
    local what = { name = c.name, size = (C.Size and C.Size()) or 0, ts = C.Tradeskills and C.Tradeskills() == true or false }
    self.log.info('%s x%d would not stow: size %s, %s; %d in the bags; bags: %s', c.name, c.stack, tostring(what.size),
        what.ts and 'a tradeskill item' or 'not a tradeskill item', self.cursor.inv:count(c.name), self:bag_report(what))
    local p = self:free_slot(what)
    if not p then return R.fail('no room', string.format('no bag with a free slot takes %s (size %s%s)', c.name, tostring(what.size),
        what.ts and '' or ', not a tradeskill item')) end
    local d = self:drop(ctx, p)
    self:close_opened(ctx)
    if not d.ok then return d end
    local bag = self.mq.TLO.Me.Inventory('pack' .. p.pack)
    self.log.info('Put %s by hand into %s (%s)', c.name, tostring(bag.Name()), label(p))
    return R.ok(p)
end

function KitSlot:tracked_at(p)
    for _, obj in ipairs(self.tracked) do if obj.at and key(obj.at) == key(p) then return obj end end
    if self.home and self.home.at and key(self.home.at) == key(p) then return self.home end
    return nil
end

-- A container on the cursor goes to `p`, or, if refused there, to another free slot that fits.
function KitSlot:put_container(ctx, p, what)
    -- too big for that bag: straight to a slot that fits. A refusal looks like a lost click, so trying would run
    -- the whole click ladder (2.12.0 in game: 12 clicks and 3 reopens of pack2 for a Rucksack it cannot hold).
    if p.slot and what then
        local bag = self.mq.TLO.Me.Inventory('pack' .. p.pack)
        if not self:takes(bag, what) then
            local alt = self:free_slot(what, p)
            if not alt then return R.fail('no room', string.format('%s will not go into %s (%s) and no other free slot takes it', what.name, bag.Name(), label(p))) end
            self.log.debug('  %s will not go into %s (too small, or tradeskill items only) - %s instead', what.name, bag.Name(), label(alt))
            local d = self:drop(ctx, alt)
            if not d.ok then return d end
            return R.ok(alt), d.value
        end
    end
    local d = self:drop(ctx, p)
    if d.ok then return R.ok(p), d.value end
    if d.why ~= 'refused' then return d end
    local alt = self:free_slot(what, p)
    if not alt then return R.fail('no room', string.format('%s fits nowhere (refused at %s, no other free slot takes it)', self.cursor:item().name, label(p))) end
    self.log.debug('  %s refused at %s - trying %s', self.cursor:item().name, label(p), label(alt))
    local d2 = self:drop(ctx, alt)
    if not d2.ok then return d2 end
    return R.ok(alt), d2.value
end

-- Empty the bag in pack10 into free slots in the other bags.
function KitSlot:empty_pack(ctx)
    local top = self.mq.TLO.Me.Inventory('pack' .. KitSlot.PACK)
    local n = 0
    for i = 1, top.Container() or 0 do
        local p = { pack = KitSlot.PACK, slot = i }
        local what = self:read(p)
        if what then
            local dest = self:free_slot(what)
            if not dest then return R.fail('no room', string.format('no free slot in the other bags for %s from pack%d', what.name, KitSlot.PACK)) end
            local u = self:pickup(ctx, p)
            if not u.ok then return u end
            local d = self:drop(ctx, dest)
            if not d.ok then return d end
            n = n + 1
        end
    end
    if self.win:is_open('Pack' .. KitSlot.PACK) then self.win:close_bag(ctx, KitSlot.PACK) end
    self.opened[KitSlot.PACK] = nil
    self.log.info('Kits: moved %d item%s out of the bag in pack%d', n, n == 1 and '' or 's', KitSlot.PACK)
    return R.ok(n)
end

-- Stacks of these items inside a kit in a top-level slot: { {pack, slot, name}, ... }. A pickup opens a bag as a
-- PackN window, which such a kit never shows (kit_at), and its combine window is the one the step's own station or
-- kit needs; so they are moved out first (unkit) - 2.46.3 Cadbane log: bought Ceramic Lining Sketches landed in the
-- Planar Fletching Kit in pack9 and three Casserole Dish runs failed on them.
function KitSlot:in_kits(names)
    local out = {}
    if not self.kit then return out end
    local want = {}
    for _, n in ipairs(names) do want[lower(n)] = true end
    local Me = self.mq.TLO.Me
    for pk = 1, 10 do
        local top = Me.Inventory('pack' .. pk)
        if (top.Container() or 0) > 0 and self.isKit(top.Name()) then
            for i = 1, top.Container() do
                local it = top.Item(i)
                if (it.ID() or 0) > 0 and want[lower(it.Name())] then out[#out + 1] = { pack = pk, slot = i, name = it.Name() } end
            end
        end
    end
    return out
end

-- Move those stacks (in_kits) into free slots of plain bags, whole. Nothing else may have a combine window open.
function KitSlot:unkit(ctx, places)
    local moved = 0
    for _, p in ipairs(places) do
        local what = self:read(p)
        if what and lower(what.name) == lower(p.name) then
            local dest = self:free_slot(what)
            if not dest and not self:kit_at(KitSlot.PACK) then   -- pack10 is borrowed for kits, so it is the last resort here
                local bag = self.mq.TLO.Me.Inventory('pack' .. KitSlot.PACK)
                for i = 1, bag.Container() or 0 do
                    if (bag.Item(i).ID() or 0) == 0 and self:takes(bag, what) then dest = { pack = KitSlot.PACK, slot = i }; break end
                end
            end
            if not dest then
                self:close_opened(ctx)
                return R.fail('no room', string.format('%s is inside the %s in pack%d, and no plain bag has a free slot to take it out to',
                    what.name, tostring(self.mq.TLO.Me.Inventory('pack' .. p.pack).Name()), p.pack))
            end
            local u = self:pickup(ctx, p)
            if not u.ok then self:close_opened(ctx); return u end
            local d = self:drop(ctx, dest)
            if not d.ok then self:close_opened(ctx); return d end
            moved = moved + 1
            self.log.info('Kits: took %s out of the %s in pack%d (to %s) - a kit there cannot be opened as a bag', what.name,
                tostring(self.mq.TLO.Me.Inventory('pack' .. p.pack).Name()), p.pack, label(dest))
        end
    end
    self:close_opened(ctx)
    return R.ok(moved)
end

function KitSlot:find_inside(names)
    local want = {}
    for _, n in ipairs(names) do want[lower(n)] = true end
    local Me = self.mq.TLO.Me
    for pk = 1, 10 do
        local bag = Me.Inventory('pack' .. pk)
        for i = 1, bag.Container() or 0 do
            local it = bag.Item(i)
            if (it.ID() or 0) > 0 and want[lower(it.Name())] and (it.Container() or 0) > 0 then return { pack = pk, slot = i }, it.Name() end
        end
    end
    return nil
end

function KitSlot:ensure(ctx, names)
    local want = {}
    for _, n in ipairs(names) do want[lower(n)] = true end
    local Me = self.mq.TLO.Me
    for pk = 1, 10 do
        local top = Me.Inventory('pack' .. pk)
        if want[lower(top.Name())] and (top.Container() or 0) > 0 then return R.ok({ pack = pk, how = 'in place' }) end
    end
    if self.cursor:item() then
        local s = self.cursor:stow(ctx)
        if not s.ok then return s end
    end
    local slotP = { pack = KitSlot.PACK }
    local occ = self:read(slotP)
    if self.home == nil then
        -- what pack10 held before we touched it: a bag goes back at the end; an item or nothing does not
        self.home = (occ and occ.bag > 0) and { name = occ.name, target = slotP, at = slotP } or false
    end
    if occ and occ.bag > 0 and occ.items > 0 then
        local e = self:empty_pack(ctx)
        if not e.ok then self:close_opened(ctx); return e end
    end
    local from, name = self:find_inside(names)
    if not from then self:close_opened(ctx); return R.fail('kit not carried', table.concat(names, ' / ') .. ' is not in the inventory') end
    -- the thing at `from` may be one we already moved: an earlier kit, or the original pack10 bag (which can
    -- itself be a kit a later step needs - 2.09.0 log: Tackle Box from pack10, used in the second step)
    local kit = self:tracked_at(from)
    if not kit then
        kit = { name = name, target = from, at = from }
        self.tracked[#self.tracked + 1] = kit
    end
    local displaced = self:tracked_at(slotP)
    local u = self:pickup(ctx, from)
    if not u.ok then self:close_opened(ctx); return u end
    local d = self:drop(ctx, slotP)
    if not d.ok then self:close_opened(ctx); return d end
    kit.at = slotP
    local came = d.value
    local how = 'into an empty pack' .. KitSlot.PACK
    if came and came.bag > 0 then
        local where, _ = self:put_container(ctx, from, came)
        if not where.ok then self:close_opened(ctx); return where end
        if displaced then displaced.at = where.value end
        how = string.format('swapped with %s (now at %s)', came.name, label(where.value))
    elseif came then
        local s = self.cursor:stow(ctx)
        if not s.ok then self:close_opened(ctx); return s end
        how = string.format('%s from pack%d stowed', came.name, KitSlot.PACK)
    end
    self:close_opened(ctx)
    self.log.info('Kits: %s into pack%d (%s)', name, KitSlot.PACK, how)
    return R.ok({ pack = KitSlot.PACK, how = how })
end

function KitSlot:moved() return #self.tracked > 0 or (self.home and self.home.at and key(self.home.at) ~= key(self.home.target)) or false end

-- Move `obj` to its target; whatever it displaces is moved on to its own target (a chain of swaps).
function KitSlot:send_home(ctx, obj)
    local u = self:pickup(ctx, obj.at)
    if not u.ok then return u end
    obj.at = nil
    local guard = 0
    while obj do
        guard = guard + 1
        if guard > 20 then return R.fail('restore loop', 'more than 20 swaps') end
        local target = obj.target
        local next = self:tracked_at(target)
        if next == obj then next = nil end
        local where, came = self:put_container(ctx, target, nil)
        if not where.ok then return where end
        obj.at = where.value
        if not came then return R.ok() end
        if next and lower(next.name) == lower(came.name) then
            obj = next
            obj.at = nil
        else
            -- something we did not move landed in that spot meanwhile: stow it
            self.log.debug('  %s was in %s - stowing it', came.name, label(target))
            return self.cursor:stow(ctx)
        end
    end
    return R.ok()
end

function KitSlot:restore(ctx)
    if not self:moved() then self.tracked, self.home = {}, nil; return R.ok() end
    if self.cursor:item() then
        local s = self.cursor:stow(ctx)
        if not s.ok then return s end
    end
    local problems = {}
    local order = {}
    if self.home then order[#order + 1] = self.home end
    for _, obj in ipairs(self.tracked) do order[#order + 1] = obj end
    for _, obj in ipairs(order) do
        if obj.at and key(obj.at) ~= key(obj.target) then
            local r = self:send_home(ctx, obj)
            if not r.ok then problems[#problems + 1] = string.format('%s: %s', obj.name, R.describe(r)) end
        end
    end
    -- read the slots back: everything we moved is where it started
    for _, obj in ipairs(order) do
        local now = self:read(obj.target)
        if lower(now and now.name) ~= lower(obj.name) then
            problems[#problems + 1] = string.format('%s should be at %s but %s is there', obj.name, label(obj.target), now and now.name or 'nothing')
        end
    end
    self:close_opened(ctx)
    self.tracked, self.home = {}, nil
    if #problems > 0 then
        self.log.warn('Kits: could not put everything back: %s', table.concat(problems, '; '))
        return R.fail('not restored', table.concat(problems, '; '))
    end
    self.log.info('Kits: inventory put back as it was')
    return R.ok()
end

return KitSlot
