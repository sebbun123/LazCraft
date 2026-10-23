-- Station: a tradeskill object in the world (Forge, Oven, Brewing Barrel...) and the combines made at it.
--   find(ctx, name)                 nearest station with this clickable name: { name, distance, y, x, z }
--   open(ctx, name)                 click it and raise its combine window, confirmed. R.ok({ how })
--   is_open()
--   contents()                      { [slot] = { name, stack } } for its slots (enviro1..)
--   place(ctx, slot, name)          take one from the bags and put it in that station slot, confirmed
--   combine(ctx, want)              '/combine enviro' and collect what comes back (want: see Combine:run)
--   clear(ctx)                      move everything in its slots back to the bags
--   close(ctx, name)                close it (Esc on its combine window)
--   close_bags(ctx)                 close the bags opened to take ingredients out
--
-- Rules it keeps:
--   * A station is found with /itemtarget "<name>" (its clickable name: Forge, Loom, Brewing Barrel...).
--     Ground stations report an internal ACTORDEF name and ID 0, so the check is that the target is within
--     click reach (REACH), never its name or ID.
--   * Clicking a station (/click left item) is a TOGGLE and the server answers it, so it is never clicked
--     again while an open might still be on its way; it is only clicked again after OPEN_MS with nothing open.
--   * Some stations open the tradeskill window: Experiment raises the combine window. Others open ready.
--   * "Someone else is using that" ends the open at once with 'in use', so the caller can try another.
--   * Its slots are read with InvSlot[enviroN].Item and filled with /itemnotify enviroN.
--   * Clicks into its slots use the cursor's click ladder (re-click next frame); there is no reopen,
--     since reopening a station is a server round trip.
--   * Closing: Esc on its combine window, checked next frame and pressed again only if something else on top
--     closed instead. (Clicking the station again does NOT close it: tested in game, 2.03.2.) /cleanup is the
--     logged fallback (it closes every window).
--   * Bags opened to take ingredients out are remembered and closed by close_bags().
local R = require('core.result')

local Station = {}
Station.__index = Station

Station.TRIES = 3
Station.REACH = 30       -- a ground object can be clicked from this close
Station.OPEN_MS = 3000   -- the server answers a click within this
Station.SLOTS = 10
local WND = 'ContainerCombine_Items'

local NOLOG = { debug = function() end, warn = function() end, info = function() end }

function Station.new(deps)
    return setmetatable({ mq = deps.mq, inv = deps.inventory, cursor = deps.cursor, win = deps.windows,
                          combiner = deps.combine, log = deps.log or NOLOG, openedPacks = {} }, Station)
end

local function lower(s) return (s or ''):lower() end

function Station:send(cmd)
    self.log.debug('  send: %s', cmd)
    self.mq.cmd(cmd)
end

function Station:is_open() return self.win:is_open(WND) end

-- Every window that matters to a station, plus any open pack windows (a kit's combine window has the
-- same name as a station's, and an open kit shows its pack window).
function Station:windows_state()
    local function st(w) return self.win:is_open(w) and 'open' or 'closed' end
    local packs = {}
    for pk = 1, 10 do if self.win:is_open('Pack' .. pk) then packs[#packs + 1] = 'Pack' .. pk end end
    return string.format('%s=%s, TradeskillWnd=%s, open packs: %s', WND, st(WND), st('TradeskillWnd'),
        #packs > 0 and table.concat(packs, ' ') or 'none')
end

local function target_info(T)
    if (T.Name() or '') == '' then return nil end
    return { name = T.Name(), distance = T.Distance() or 9999, y = T.Y(), x = T.X(), z = T.Z() }
end

-- Item-target the nearest station by name (in the client, so it shows at once).
function Station:find(ctx, name)
    local cmd = string.format('/itemtarget "%s"', name)
    self:send(cmd)
    local w = ctx:wait(1, function() return target_info(self.mq.TLO.ItemTarget) ~= nil end)
    if not w.ok and w.why ~= 'timeout' then return w end
    local t = target_info(self.mq.TLO.ItemTarget)
    if not t then return R.fail('not found', 'no ' .. name .. ' in this zone') end
    self.log.debug('  %s: %s, %.1f away at %.2f %.2f %.2f', name, tostring(t.name), t.distance, t.y or 0, t.x or 0, t.z or 0)
    return R.ok(t)
end

function Station:open(ctx, name)
    if self:is_open() then
        self.log.debug('  %s already open (%s)', name, self:windows_state())
        return R.ok({ how = 'already open' })
    end
    local how
    if not self.win:is_open('TradeskillWnd') then
        local f = self:find(ctx, name)
        if not f.ok then return f end
        if f.value.distance > Station.REACH then
            return R.fail('out of reach', string.format('%s is %.0f away (reach %d)', name, f.value.distance, Station.REACH))
        end
        self.combiner:reset_in_use()
        local function reacted() return self:is_open() or self.win:is_open('TradeskillWnd') or self.combiner:in_use() end
        for try = 1, Station.TRIES do
            self:send('/click left item')
            local w = ctx:wait(Station.OPEN_MS, reacted)
            if not w.ok and w.why ~= 'timeout' then return w end
            if self.combiner:in_use() then return R.fail('in use', name .. ': someone else is using it') end
            if reacted() then
                self.log.debug('  click %d on %s: %s after %dms', try, name, self:windows_state(), w.ms or 0)
                break
            end
            self.log.debug('  click %d on %s: no answer after %dms', try, name, w.ms or 0)
        end
        if not reacted() then return R.fail('station did not open', name .. ': no answer to ' .. Station.TRIES .. ' clicks') end
        how = 'click'
    end
    if not self:is_open() and self.win:is_open('TradeskillWnd') then
        for try = 1, Station.TRIES do
            self:send('/nomodkey /notify TradeskillWnd COMBW_ExperimentButton leftmouseup')
            local w = ctx:wait(1, function() return self:is_open() end)
            if not w.ok and w.why ~= 'timeout' then return w end
            if self:is_open() then break end
            self.log.debug('  Experiment click %d: no combine window yet', try)
        end
        how = (how and how .. ' + ' or '') .. 'Experiment'
    end
    if not self:is_open() then
        return R.fail('no combine window', name .. ' opened but its combine window did not (' .. self:windows_state() .. ')')
    end
    self.log.debug('  %s open via %s (%s)', name, how or '?', self:windows_state())
    return R.ok({ how = how or '?' })
end

function Station:contents()
    local out = {}
    for i = 1, Station.SLOTS do
        local it = self.mq.TLO.InvSlot('enviro' .. i).Item
        if (it.ID() or 0) > 0 or (it.Name() or '') ~= '' then out[i] = { name = it.Name(), stack = it.Stack() or 1 } end
    end
    return out
end

function Station:describe()
    local parts = {}
    local c = self:contents()
    for i = 1, Station.SLOTS do
        if c[i] then parts[#parts + 1] = string.format('%d=%s x%d', i, c[i].name, c[i].stack) end
    end
    return #parts > 0 and table.concat(parts, ', ') or 'empty'
end

function Station:place(ctx, slot, name)
    local t0 = self.mq.gettime()
    if not self:is_open() then return R.fail('not open', 'the station is not open') end
    if self:contents()[slot] then return R.fail('slot taken', string.format('station slot %d already holds %s', slot, self:contents()[slot].name)) end
    local got = self.cursor:pick_up(ctx, name, 1)
    local opened = got.openedPack or (got.value and got.value.openedPack)
    if opened then self.openedPacks[opened] = true end
    if not got.ok then return got end
    local function took()
        local c = self:contents()[slot]
        return self.cursor:is_empty() and c ~= nil and lower(c.name) == lower(name)
    end
    local function untouched()
        local c = self.cursor:item()
        return c ~= nil and lower(c.name) == lower(name) and not self:contents()[slot]
    end
    local w = self.cursor:click_slot(ctx, {}, string.format('/nomodkey /itemnotify enviro%d leftmouseup', slot), took, untouched)
    if not took() then
        local back = self.cursor:stow(ctx)
        return R.fail('not placed', string.format('%s did not go into station slot %d (%s; station: %s; %s)%s', name, slot,
            tostring(w.ok and 'something else changed' or w.why), self:describe(), self:windows_state(),
            back.ok and '' or ('; still on the cursor: ' .. R.describe(back))))
    end
    local ms = self.mq.gettime() - t0
    self.log.debug('  %s -> station slot %d after %dms', name, slot, ms)
    return R.ok({ ms = ms })
end

function Station:combine(ctx, want)
    if not self:is_open() then return R.fail('not open', 'the station is not open') end
    return self.combiner:run(ctx, '/combine enviro', want, { describe = function() return 'station ' .. self:describe() end })
end

function Station:clear(ctx)
    for slot, it in pairs(self:contents()) do
        local function took() return not self.cursor:is_empty() or self.win:is_open('QuantityWnd') end
        local ps = self.cursor:item_start(ctx)
        if not ps.ok then return ps end
        local w = self.cursor:click_slot(ctx, {}, string.format('/nomodkey /itemnotify enviro%d leftmouseup', slot),
            took, function() return not took() end)
        if not took() then return R.fail('not cleared', string.format('could not take %s out of station slot %d (%s)', it.name, slot, tostring(w.why))) end
        if self.win:is_open('QuantityWnd') then
            local a = self.cursor:qty_accept(ctx)
            if not a.ok then return a end
        end
        local st = self.cursor:stow(ctx)
        if not st.ok then return st end
        self.log.debug('  cleared %s from station slot %d', it.name, slot)
    end
    return R.ok()
end

function Station:close(ctx, name)
    if self.win:is_open('TradeskillWnd') then
        local t = self.win:close(ctx, 'TradeskillWnd')   -- this one only closes with DoClose
        if not t.ok then return t end
    end
    if not self:is_open() then return R.ok() end
    local before = self:windows_state()
    local c = self.win:close(ctx, WND)                    -- Esc, next-frame checked, pressed again if needed
    self.log.debug('  closing %s: %s -> %s', name, before, self:windows_state())
    if c.ok then return R.ok() end
    if c.why ~= 'timeout' then return c end
    self.log.warn('Station: Esc did not close %s (%s) - using /cleanup', name, self:windows_state())
    self:send('/cleanup')
    local w = ctx:wait(1, function() return not self:is_open() end)
    if w.ok then return R.ok() end
    if w.why ~= 'timeout' then return w end
    return R.fail('station stuck open', self:windows_state())
end

function Station:close_bags(ctx)
    for pk in pairs(self.openedPacks) do
        if self.cursor:is_empty() then self.win:close_bag(ctx, pk) end
    end
    self.openedPacks = {}
    return R.ok()
end

return Station
