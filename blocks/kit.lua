-- Kit: a tradeskill container carried in the bags (Jeweler's Kit and the like) and the combines made in it.
--   find(name)                    { pack, slots } when the kit sits in a top-level slot (pack1..pack10), or
--                                 nil plus why (not carried, or inside another bag)
--   open(ctx, pack)               raise its combine window, confirmed. R.ok({ how })
--   contents(pack)                { [slot] = { name, stack } }
--   place(ctx, pack, slot, name)  take one from the bags and put it in that kit slot, confirmed
--   combine(ctx, pack, want)      combine what is in the kit and collect what comes back (want: see Combine:run).
--                                 R.ok({ result, line, ms, made, returned })
--   clear(ctx, pack)              move everything in the kit back to the bags
--   close(ctx, pack)              close the kit, the way it was opened: a right-click on its slot
--
-- Rules it keeps:
--   * The kit must sit in a top-level slot; a kit inside another bag cannot be combined in.
--   * '/combine packN' combines the kit's contents. It only works while the kit's combine window
--     (ContainerCombine_Items) is open. If the kit opens the tradeskill window instead, Experiment raises it.
--   * The combine itself (the game's message, collecting what comes back) is the combine block's job.
--   * Ingredients are taken one at a time and never from the kit itself.
--   * Clicks into the kit use the cursor's click ladder (re-click, then close and reopen the kit).
--   * A right-click on the kit's slot closes it again. It is a toggle, so it is only sent again if nothing
--     changed. DoClose leaves the combine window half-broken and is never used on it. If the right-click
--     does not close it, /cleanup does (it closes every window, so it is the logged fallback, not the way).
--   * Item pace is kept by the cursor block (every pickup, stow and kit clear starts an item there).
local R = require('core.result')

local Kit = {}
Kit.__index = Kit

Kit.TRIES = 3
-- a kit right-click that opened nothing by then was lost: sent again (2.43.1; the Mithril Champion Arrows log: three
-- right-clicks 33ms apart, straight after the Forge was closed with Esc, all lost and an hour's row failed - a bag
-- right-clicked just after waited 524ms, then its second click opened it). As blocks/windows does for bags.
Kit.RESEND_MS = 500
Kit.OPEN_TRIES = 4
local WND = 'ContainerCombine_Items'

local NOLOG = { debug = function() end, warn = function() end, info = function() end }
function Kit.new(deps)
    return setmetatable({ mq = deps.mq, inv = deps.inventory, cursor = deps.cursor, win = deps.windows,
                          combiner = deps.combine, log = deps.log or NOLOG, openedPacks = {} }, Kit)
end

local function lower(s) return (s or ''):lower() end

function Kit:send(cmd)
    self.log.debug('  send: %s', cmd)
    self.mq.cmd(cmd)
end

function Kit:find(name)
    local Me = self.mq.TLO.Me
    for pk = 1, 10 do
        local it = Me.Inventory('pack' .. pk)
        if lower(it.Name()) == lower(name) and (it.Container() or 0) > 0 then
            return { pack = pk, slots = it.Container() }
        end
    end
    if (self.mq.TLO.FindItem('=' .. name).ID() or 0) > 0 then
        return nil, name .. ' is inside another bag - it must sit in a top-level inventory slot'
    end
    return nil, name .. ' is not in the inventory'
end

function Kit:is_open() return self.win:is_open(WND) end

-- Every window a kit can raise, for the log.
function Kit:windows_state(pack)
    local function st(w) return self.win:is_open(w) and 'open' or 'closed' end
    return string.format('%s=%s, TradeskillWnd=%s, Pack%d=%s', WND, st(WND), st('TradeskillWnd'), pack, st('Pack' .. pack))
end

function Kit:open(ctx, pack)
    -- A combine window is ours only if this kit's own pack window is open too: a station's (or another
    -- kit's) uses the same window name. Anything else is closed first.
    if self:is_open() then
        if self.win:is_open('Pack' .. pack) then return R.ok({ how = 'already open' }) end
        self.log.debug('  a combine window is open but not this kit\'s (%s) - closing it', self:windows_state(pack))
        local c = self.win:close(ctx, WND)
        if not c.ok then return c end
    end
    local function reacted()
        return self:is_open() or self.win:is_open('TradeskillWnd') or self.win:is_open('Pack' .. pack)
    end
    local how
    if not reacted() then
        for try = 1, Kit.OPEN_TRIES do
            self:send(string.format('/nomodkey /itemnotify pack%d rightmouseup', pack))
            local w = ctx:wait(Kit.RESEND_MS, reacted)
            if not w.ok and w.why ~= 'timeout' then return w end
            if reacted() then
                self.log.debug('  kit right-click %d: %s after %dms', try, self:windows_state(pack), w.ms or 0)
                break
            end
            self.log.debug('  kit right-click %d: nothing opened in %dms', try, w.ms or Kit.RESEND_MS)
        end
        if not reacted() then return R.fail('kit did not open', 'nothing opened after ' .. Kit.OPEN_TRIES .. ' right-clicks') end
        how = 'right-click'
    end
    if not self:is_open() and self.win:is_open('TradeskillWnd') then
        for try = 1, Kit.TRIES do
            self:send('/nomodkey /notify TradeskillWnd COMBW_ExperimentButton leftmouseup')
            local w = ctx:wait(1, function() return self:is_open() end)
            if not w.ok and w.why ~= 'timeout' then return w end
            if self:is_open() then break end
            self.log.debug('  Experiment click %d: no combine window yet', try)
        end
        how = (how and how .. ' + ' or '') .. 'Experiment'
    end
    if not self:is_open() then
        return R.fail('no combine window', 'the kit opened but its combine window did not (' .. self:windows_state(pack) .. ')')
    end
    self.log.debug('  kit open via %s (%s)', how or '?', self:windows_state(pack))
    return R.ok({ how = how or '?' })
end

function Kit:reopen(ctx, pack)
    local c = self:close(ctx, pack)
    if not c.ok then return c end
    return self:open(ctx, pack)
end

function Kit:contents(pack)
    local out = {}
    local kit = self.mq.TLO.Me.Inventory('pack' .. pack)
    for i = 1, kit.Container() or 0 do
        local it = kit.Item(i)
        if (it.ID() or 0) > 0 then out[i] = { name = it.Name(), stack = it.Stack() or 1 } end
    end
    return out
end

function Kit:describe(pack)
    local parts = {}
    local c = self:contents(pack)
    for i = 1, self.mq.TLO.Me.Inventory('pack' .. pack).Container() or 0 do
        if c[i] then parts[#parts + 1] = string.format('%d=%s x%d', i, c[i].name, c[i].stack) end
    end
    return #parts > 0 and table.concat(parts, ', ') or 'empty'
end

function Kit:place(ctx, pack, slot, name)
    local t0 = self.mq.gettime()
    if self:contents(pack)[slot] then return R.fail('slot taken', string.format('kit slot %d already holds %s', slot, self:contents(pack)[slot].name)) end
    local got = self.cursor:pick_up(ctx, name, 1, pack)
    if got.openedPack or (got.value and got.value.openedPack) then self.openedPacks[got.openedPack or got.value.openedPack] = true end
    if not got.ok then return got end
    local target = { pack = pack, slot = slot }
    local function took()
        local c = self:contents(pack)[slot]
        return self.cursor:is_empty() and c ~= nil and lower(c.name) == lower(name)
    end
    local function untouched()
        local c = self.cursor:item()
        return c ~= nil and lower(c.name) == lower(name) and not self:contents(pack)[slot]
    end
    local w = self.cursor:click_slot(ctx, target, string.format('/nomodkey /itemnotify in pack%d %d leftmouseup', pack, slot),
        took, untouched, function(c) return self:reopen(c, pack) end)
    if not took() then
        local back = self.cursor:stow(ctx)
        local why = w.ok and 'something else changed' or w.why
        return R.fail('not placed', string.format('%s did not go into kit slot %d (%s; kit: %s)%s', name, slot, tostring(why),
            self:describe(pack), back.ok and '' or ('; still on the cursor: ' .. R.describe(back))))
    end
    local ms = self.mq.gettime() - t0
    self.log.debug('  %s -> kit slot %d after %dms', name, slot, ms)
    return R.ok({ ms = ms })
end

function Kit:combine(ctx, pack, want)
    if not self:is_open() then return R.fail('not open', 'the kit combine window is not open') end
    return self.combiner:run(ctx, string.format('/combine pack%d', pack), want,
        { skipPack = pack, describe = function() return 'kit ' .. self:describe(pack) end })
end

function Kit:clear(ctx, pack)
    for slot, it in pairs(self:contents(pack)) do
        local target = { pack = pack, slot = slot }
        local function took() return not self.cursor:is_empty() or self.win:is_open('QuantityWnd') end
        local ps = self.cursor:item_start(ctx)
        if not ps.ok then return ps end
        local w = self.cursor:click_slot(ctx, target, string.format('/nomodkey /itemnotify in pack%d %d leftmouseup', pack, slot),
            took, function() return not took() end, function(c) return self:reopen(c, pack) end)
        if not took() then return R.fail('not cleared', string.format('could not take %s out of kit slot %d (%s)', it.name, slot, tostring(w.why))) end
        if self.win:is_open('QuantityWnd') then
            local a = self.cursor:qty_accept(ctx)
            if not a.ok then return a end
        end
        local st = self.cursor:stow(ctx)
        if not st.ok then return st end
        self.log.debug('  cleared %s from kit slot %d', it.name, slot)
    end
    return R.ok()
end

function Kit:close(ctx, pack)
    if self.win:is_open('TradeskillWnd') then
        local t = self.win:close(ctx, 'TradeskillWnd')   -- this one only closes with DoClose
        if not t.ok then return t end
    end
    local function shut() return not self:is_open() and not self.win:is_open('Pack' .. pack) end
    if shut() then return R.ok() end
    for try = 1, Kit.TRIES do
        local before = self:windows_state(pack)
        self:send(string.format('/nomodkey /itemnotify pack%d rightmouseup', pack))
        local w = ctx:wait(1, shut)
        if not w.ok and w.why ~= 'timeout' then return w end
        local after = self:windows_state(pack)
        self.log.debug('  kit right-click %d to close: %s', try, after)
        if shut() then return R.ok() end
        if self.win:is_open('TradeskillWnd') then          -- the toggle reopened the tradeskill window
            local t = self.win:close(ctx, 'TradeskillWnd')
            if not t.ok then return t end
            if shut() then return R.ok() end
        end
        if after ~= before then break end                   -- it reacted but did not close: stop toggling
    end
    self.log.warn('Kit: a right-click did not close it (%s) - using /cleanup', self:windows_state(pack))
    self:send('/cleanup')
    local w = ctx:wait(1, shut)
    if w.ok then return R.ok() end
    if w.why ~= 'timeout' then return w end
    return R.fail('kit stuck open', self:windows_state(pack))
end

-- Close the bags opened to take ingredients out.
function Kit:close_bags(ctx)
    for pk in pairs(self.openedPacks) do
        if self.cursor:is_empty() then self.win:close_bag(ctx, pk) end
    end
    self.openedPacks = {}
    return R.ok()
end

return Kit
