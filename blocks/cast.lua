-- Cast: making items with a spell (producers.ini), on this character.
--   has(spell)                      the spell is scribed in this character's book
--   produce(ctx, producer, casts, yield)  cast it `casts` times, each confirmed by the product arriving.
--                                   R.ok({ casts, made, attempts, yielded })
--                                   yield() true (a worker's summon order: something else is queued) ends it
--                                   between casts - and a meditation - with what is made so far, yielded = true
--   halt(ctx)                       stop a cast in progress (for cleanup after a stop)
--
-- Rules it keeps (from the old LazCraft, proven in game):
--   * Whether a character can make it is its spellbook, not its class (a class match does not mean scribed).
--   * A spell already memorized is cast from its gem; otherwise it is memorized into gem 8 (/memspell) and the
--     gem is read until it shows the spell - memorizing takes seconds.
--   * The cast is only fired standing, still, not casting, with the gem ready (Me.SpellReady): a /cast into a
--     refreshing gem starts nothing.
--   * Mana: below 30% sit and meditate until above 90% (capped), then stand.
--   * The product lands on the cursor and /autoinventory does nothing mid-cast: the cast is waited out, then
--     the cursor is stowed. A cast counts when the product count goes up.
--   * A fizzle or an interruption (the game's message) is cast again, within a budget of casts + 10.
--   * Every wait is on a condition with a cap; nothing waits on a timer.
local R = require('core.result')

local Cast = {}
Cast.__index = Cast

Cast.GEM = 8
Cast.MEM_MS = 15000
Cast.READY_MS = 30000
Cast.STILL_MS = 3000
Cast.START_MS = 6000
Cast.CAST_MS = 30000
Cast.ARRIVE_MS = 3000
Cast.MED_LOW, Cast.MED_HIGH, Cast.MED_MS = 30, 90, 300000
Cast.SPARE = 10

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local MESSAGES = {
    { key = 'fizzled', pattern = 'Your spell fizzles#*#' },
    { key = 'interrupted', pattern = 'Your spell is interrupted#*#' },
    { key = 'interrupted', pattern = 'Your casting has been interrupted#*#' },
    { key = 'components', pattern = 'You are missing some required components#*#' },
    { key = 'mana', pattern = 'Insufficient Mana to cast this spell#*#' },
}
local nextEvent = 0

function Cast.new(deps)
    local c = setmetatable({ mq = deps.mq, nav = deps.nav, inv = deps.inventory, cursor = deps.cursor,
                             log = deps.log or NOLOG, heard = nil }, Cast)
    for _, m in ipairs(MESSAGES) do
        nextEvent = nextEvent + 1
        deps.mq.event('lc_cast_' .. nextEvent, m.pattern, function() if not c.heard then c.heard = m.key end end)
    end
    return c
end

local function lower(s) return (s or ''):lower() end

function Cast:send(cmd)
    self.log.debug('  send: %s', cmd)
    self.mq.cmd(cmd)
end

function Cast:has(spell) return (self.mq.TLO.Me.Book(spell)() or 0) ~= 0 end
function Cast:casting() return (self.mq.TLO.Me.Casting.ID() or 0) > 0 end

-- How many of `name` we hold, the cursor included (the product sits there until the cast is over).
function Cast:count(name)
    local n = self.inv:count(name)
    local c = self.cursor:item()
    if c and lower(c.name) == lower(name) then n = n + c.stack end
    return n
end

function Cast:gem_for(ctx, spell)
    local Me = self.mq.TLO.Me
    local g = Me.Gem(spell)()
    if type(g) == 'number' and g > 0 then return R.ok(g) end
    self:send(string.format('/memspell %d "%s"', Cast.GEM, spell))
    local w = ctx:wait(Cast.MEM_MS, function() return lower(Me.Gem(Cast.GEM).Name()) == lower(spell) end)
    if not w.ok and w.why ~= 'timeout' then return w end
    if lower(Me.Gem(Cast.GEM).Name()) ~= lower(spell) then
        return R.fail('not memorized', string.format('%s did not show in gem %d after %ds', spell, Cast.GEM, Cast.MEM_MS / 1000))
    end
    self.log.debug('  %s memorized in gem %d after %dms', spell, Cast.GEM, w.ms or 0)
    return R.ok(Cast.GEM)
end

function Cast:med(ctx, yield)
    local Me = self.mq.TLO.Me
    if (Me.PctMana() or 100) >= Cast.MED_LOW then return R.ok() end
    self.log.info('Cast: mana %d%% - sitting to meditate', Me.PctMana() or 0)
    if not Me.Sitting() then self:send('/sit') end
    local w = ctx:wait(Cast.MED_MS, function() return (Me.PctMana() or 0) >= Cast.MED_HIGH or (yield ~= nil and yield()) end)
    if not w.ok and w.why ~= 'timeout' then return w end
    if (Me.PctMana() or 0) < Cast.MED_HIGH and yield and yield() then
        self.log.info('Cast: mana %d%% after %ds - something else is waiting, stopping here', Me.PctMana() or 0, math.floor((w.ms or 0) / 1000))
        return R.ok({ yielded = true })
    end
    self.log.info('Cast: mana %d%% after %ds - standing', Me.PctMana() or 0, math.floor((w.ms or 0) / 1000))
    return R.ok()
end

function Cast:stand(ctx)
    local Me = self.mq.TLO.Me
    if Me.Sitting() then
        self:send('/stand')
        local w = ctx:wait(Cast.STILL_MS, function() return not Me.Sitting() end)
        if not w.ok and w.why ~= 'timeout' then return w end
    end
    local s = self.nav:stop(ctx)
    if not s.ok then return s end
    local w = ctx:wait(Cast.STILL_MS, function() return not Me.Moving() and not self:casting() and not Me.Sitting() end)
    if not w.ok and w.why ~= 'timeout' then return w end
    if Me.Moving() or self:casting() or Me.Sitting() then return R.fail('not ready to cast', 'still moving, casting or sitting') end
    return R.ok()
end

-- Stop a cast in progress (a job stopped mid-cast): /stopcast, confirmed. An interrupted cast uses no
-- reagents, and nothing lands on the cursor after we have gone.
function Cast:halt(ctx)
    if not self:casting() then return R.ok() end
    self:send('/stopcast')
    local w = ctx:wait(Cast.STILL_MS, function() return not self:casting() end)
    self.log.debug('  cast stopped: %s after %dms', w.ok and 'yes' or w.why, w.ms or 0)
    if w.ok then return R.ok() end
    if w.why == 'timeout' then return R.fail('still casting', 'the cast would not stop') end
    return w
end

function Cast:stow(ctx)
    if self.cursor:item() then return self.cursor:stow(ctx) end
    return R.ok()
end

function Cast:produce(ctx, p, casts, yield)
    local Me = self.mq.TLO.Me
    if not self:has(p.spell) then return R.fail('spell not scribed', p.spell .. ' is not in the spellbook') end
    local g = self:gem_for(ctx, p.spell)
    if not g.ok then return g end
    local gem = g.value
    local start = self:count(p.item)
    local done, attempts = 0, 0
    self.yieldSaid = false
    local budget = casts + Cast.SPARE
    local function yielded()
        self.log.info('Cast: %s - %d of %d casts, stopping for what is waiting', p.spell, done, casts)
        return R.ok({ casts = done, made = self:count(p.item) - start, attempts = attempts, yielded = true })
    end
    while done < casts and attempts < budget do
        if not ctx:checkpoint() then return R.fail('stopped') end
        if yield and yield() then return yielded() end
        for _, r in ipairs(p.reagents) do
            if self.inv:count(r.name) < r.count then
                return R.fail('out of reagents', string.format('%s: %d of %d casts, out of %s (each takes %d)', p.spell, done, casts, r.name, r.count))
            end
        end
        local s = self:stow(ctx)
        if not s.ok then return s end
        local m = self:med(ctx, yield)
        if not m.ok then return m end
        if m.value and m.value.yielded then
            local s2 = self:stand(ctx)
            if not s2.ok then return s2 end
            return yielded()
        end
        local st = self:stand(ctx)
        if not st.ok then return st end
        local rd = ctx:wait(Cast.READY_MS, function() return Me.SpellReady(p.spell)() == true end)
        if not rd.ok and rd.why ~= 'timeout' then return rd end
        if Me.SpellReady(p.spell)() ~= true then return R.fail('gem not ready', string.format('%s not ready after %ds', p.spell, Cast.READY_MS / 1000)) end
        if yield and yield() then return yielded() end   -- came in while we stood up and the gem refreshed
        attempts = attempts + 1
        local before = self:count(p.item)
        self.mq.doevents()
        self.heard = nil
        ctx:status(string.format('Casting %s (%d of %d)', p.spell, done + 1, casts))
        self:send('/cast ' .. gem)
        local b = ctx:wait(Cast.START_MS, function() return self:casting() or self:count(p.item) > before or self.heard ~= nil end)
        if not b.ok and b.why ~= 'timeout' then return b end
        if self:casting() then
            local e = ctx:wait(Cast.CAST_MS, function() return not self:casting() end)
            if not e.ok and e.why ~= 'timeout' then return e end
            if self:casting() then return R.fail('cast too long', string.format('%s still casting after %ds', p.spell, Cast.CAST_MS / 1000)) end
        end
        -- the product, or the game's word on why not
        local a = ctx:wait(Cast.ARRIVE_MS, function() return self:count(p.item) > before or self.heard ~= nil end)
        if not a.ok and a.why ~= 'timeout' then return a end
        s = self:stow(ctx)
        if not s.ok then return s end
        local got = self:count(p.item) - before
        if got > 0 then
            done = done + 1
            self.log.info('Cast: %s %d/%d - %d %s', p.spell, done, casts, got, p.item)
            if p.yield and got ~= p.yield and not self.yieldSaid then
                self.yieldSaid = true
                self.log.warn('Cast: %s made %d, producers.ini says %d - fix it there', p.spell, got, p.yield)
            end
        elseif self.heard == 'components' then
            return R.fail('out of reagents', string.format('%s: the game says reagents are missing', p.spell))
        else
            self.log.warn('Cast: %s attempt %d made nothing (%s)', p.spell, attempts, self.heard or (b.ok and 'no product' or 'never started'))
        end
    end
    local made = self:count(p.item) - start
    if done < casts then
        return R.fail('casts failed', string.format('%s: %d of %d casts after %d attempts (made %d)', p.spell, done, casts, attempts, made))
    end
    return R.ok({ casts = done, made = made, attempts = attempts })
end

return Cast
