-- Gear: the only block that changes what is worn - the Ammo slot, where tradeskill trophies and aids go.
--   worn(slot)               the item in the slot (default 'ammo'), or nil
--   equip(ctx, name, slot)   wear an item from the bags, confirmed; what was worn there goes into the bags.
--                            R.ok({ was = name or nil, already = true when it was worn already })
--   unequip(ctx, slot)       take what is worn there off into the bags, confirmed
--
-- Rules it keeps:
--   * The item goes through the cursor block (pick up, confirmed), then one click on the slot. The click
--     happens in the client, so the slot shows it at once; a click that changed nothing is sent again after
--     CLICK_MS, up to TRIES. What came off the slot is stowed, confirmed.
--   * A bag it had to open for the pickup is closed again.
local R = require('core.result')

local Gear = {}
Gear.__index = Gear

Gear.TRIES = 3
Gear.CLICK_MS = 250

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local function lower(s) return (s or ''):lower() end

function Gear.new(deps)
    return setmetatable({ mq = deps.mq, cursor = deps.cursor, win = deps.windows, log = deps.log or NOLOG }, Gear)
end

function Gear:worn(slot)
    local it = self.mq.TLO.Me.Inventory(slot or 'ammo')
    local n = it and it.Name and it.Name()
    if not n or n == '' then return nil end
    return n
end

function Gear:equip(ctx, name, slot)
    slot = slot or 'ammo'
    local was = self:worn(slot)
    if was and lower(was) == lower(name) then return R.ok({ was = was, already = true }) end
    local p = self.cursor:pick_up(ctx, name, 1)
    if not p.ok then return p end
    local function on() return lower(self:worn(slot)) == lower(name) end
    local cmd = '/nomodkey /itemnotify ' .. slot .. ' leftmouseup'
    local w
    for try = 1, Gear.TRIES do
        self.log.debug('  send: %s%s', cmd, try > 1 and string.format(' (try %d)', try) or '')
        self.mq.cmd(cmd)
        w = ctx:wait(Gear.CLICK_MS, on)
        if w.ok or w.why ~= 'timeout' then break end
    end
    if not w.ok then
        if w.why ~= 'timeout' then return w end
        local s = self.cursor:stow(ctx)
        return R.fail('not worn', string.format('%s would not go into %s%s', name, slot, s.ok and '' or (' (and the cursor: ' .. R.describe(s) .. ')')))
    end
    self.log.debug('  %s worn in %s after %dms%s', name, slot, w.ms or 0, was and (' (' .. was .. ' came off)') or '')
    local s = self.cursor:stow(ctx)
    if not s.ok then return s end
    if p.value.openedPack then self.win:close_bag(ctx, p.value.openedPack) end
    return R.ok({ was = was })
end

function Gear:unequip(ctx, slot)
    slot = slot or 'ammo'
    local was = self:worn(slot)
    if not was then return R.ok() end
    local cl = self.cursor:clear(ctx, 'taking ' .. was .. ' off')
    if not cl.ok then return cl end
    local cmd = '/nomodkey /itemnotify ' .. slot .. ' leftmouseup'
    local w
    for try = 1, Gear.TRIES do
        self.log.debug('  send: %s%s', cmd, try > 1 and string.format(' (try %d)', try) or '')
        self.mq.cmd(cmd)
        w = ctx:wait(Gear.CLICK_MS, function() return self:worn(slot) == nil end)
        if w.ok or w.why ~= 'timeout' then break end
    end
    if not w.ok then
        if w.why ~= 'timeout' then return w end
        return R.fail('still worn', was .. ' would not come off ' .. slot)
    end
    return self.cursor:stow(ctx)
end

return Gear
