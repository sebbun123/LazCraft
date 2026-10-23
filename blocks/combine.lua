-- Combine: fire a combine, read the game's answer, collect what comes back. Shared by kits and stations.
--   run(ctx, cmd, want, opts)      send `cmd` ('/combine pack10', '/combine enviro'), wait for the game's
--                                  message, stow everything that comes back.
--                                  want: the product's name, or { product, yield, tools, ins, also, failBack, destroy }
--                                  (lists of {name, n}: also = made as well, failBack = given back by a failure)
--                                  opts.skipPack: a pack left out when counting (the kit itself)
--                                  opts.describe: function() -> text of what is in the container, for the log
--                                  opts.destroy: the product is destroyed off the cursor as it arrives (never
--                                  anything else - tools, salvage and also-made are stowed as usual)
--                                  R.ok({ result, line, ms, made, destroyed, returned, missing })
--   in_use()                        the station said someone else is using it (since the last reset)
--   reset_in_use()
--
-- Rules it keeps:
--   * The game's message decides the outcome: "You have fashioned the items together" is a success,
--     "You lacked the skills" a failure (ingredients used up), "You cannot combine these items" a refusal.
--   * Whatever the combine hands back lands on the cursor and is stowed, one item at a time, confirmed.
--     The items come one after another with gaps (2.06.2 log: Skewers first, the Rat Kabobs 165-343ms later,
--     landing on the cursor during the next pickup), so an empty cursor is not the end. The recipe says what
--     to expect: a success brings the product (yield), anything Also made and every tool; a failure brings
--     the tools and the FailBack ingredients (given back on a failure, used up on a success). The combine
--     is over once those are in the bags, waited for as a condition and capped at ARRIVE_MS. Anything that
--     never arrives is logged and reported as missing; nothing waits past the cap.
--   * After a failure the cursor must stay empty SALVAGE_MS (each arrival starts it again, FAIL_CAP_MS in all):
--     salvage and bounced returns come seconds late on Lazarus, and one landing mid-placement desyncs.
--   * What came back is named in the log: product, tool, salvage (an ingredient returned by a failure) or
--     other. Salvage cannot be expected (it is chance), so it is not waited for; one that arrives after the
--     combine is over is stowed by the next pickup.
--   * Messages are listened for only from the moment the combine is sent; anything older is dropped.
--   * Destroy (opts.destroy) only ever takes the product of a success, by name, off the cursor - so nothing
--     already in the bags and nothing else that came back can be destroyed.
local R = require('core.result')

local Combine = {}
Combine.__index = Combine

Combine.MS = 5000         -- the server answers a combine within this
Combine.RESEND_MS = 1500  -- no answer by now and nothing moved: the combine was lost; send it again
Combine.SENDS = 3
Combine.ARRIVE_MS = 3000  -- what a combine hands back arrives within this
-- after a failure the cursor must stay empty this long before the combine is over; each arrival starts it again,
-- up to FAIL_CAP_MS in all (1.10.1, was 300: the 2.46.8 and 1.10.0 Vadar logs - a failed Cobalt Plate Gorget
-- Template's Toluene Coal came 0.55s after the message and its Plate Gorget Template Mold at 1.1, 1.7 and 2.0s, the
-- server bouncing it back - each landing while the next combine was placed, then a desync. A success waits nothing)
Combine.SALVAGE_MS = 800
Combine.FAIL_CAP_MS = 4000

local RESULTS = {
    { key = 'success', pattern = 'You have fashioned the items together#*#' },
    { key = 'failed',  pattern = 'You lacked the skills to fashion#*#' },
    { key = 'refused', pattern = 'You cannot combine these items#*#' },
    { key = 'refused', pattern = 'You do not have all the components#*#' },
    { key = 'refused', pattern = 'You must place items#*#' },
    -- MQ's own answer when /combine packN finds that bag's window shut (2.46.7 log: a desync on the kit's slots closed
    -- Pack10 while the combine window stayed up - three sends, "Window 'pack10' not open" each, then "no answer").
    -- Nothing was combined, nothing comes back; the caller resets the container (/cleanup, open again).
    { key = 'closed',  pattern = "Window '#*#' not open#*#" },
}
local IN_USE = { 'Someone else is using that#*#', 'someone else is using that#*#', 'This is already in use#*#' }

local NOLOG = { debug = function() end, info = function() end, warn = function() end }
local nextEvent = 0

function Combine.new(deps)
    local c = setmetatable({ mq = deps.mq, inv = deps.inventory, cursor = deps.cursor, log = deps.log or NOLOG,
                             heard = nil, inUse = false }, Combine)
    local function on(pattern, fn)
        nextEvent = nextEvent + 1
        deps.mq.event('lc_combine_' .. nextEvent, pattern, fn)
    end
    for _, m in ipairs(RESULTS) do
        on(m.pattern, function(line) if not c.heard then c.heard = { result = m.key, line = line } end end)
    end
    for _, p in ipairs(IN_USE) do on(p, function() c.inUse = true end) end
    return c
end

function Combine:in_use() return self.inUse end
function Combine:reset_in_use() self.mq.doevents(); self.inUse = false end

-- Destroy what is on the cursor (the product, checked by the caller), confirmed by the cursor moving on.
function Combine:destroy(ctx, held)
    self.log.debug('  send: /destroy (%s x%d)', held.name, held.stack)
    self.mq.cmd('/destroy')
    local w = ctx:wait(2000, function()
        local c = self.cursor:item()
        return c == nil or c.id ~= held.id or c.stack ~= held.stack
    end)
    if w.ok then return R.ok() end
    if w.why ~= 'timeout' then return w end
    return R.fail('destroy failed', held.name .. ' is still on the cursor after /destroy')
end

function Combine:run(ctx, cmd, want, opts)
    opts = opts or {}
    if type(want) == 'string' then want = { product = want } end
    local product, yield = want.product, want.yield or 1
    local cl = self.cursor:clear(ctx, 'the combine')
    if not cl.ok then return cl end
    local describe = opts.describe or function() return '?' end
    local function count(name) return self.inv:count(name, opts.skipPack) end
    -- the client's own count (bags and worn slots): /autoinventory can put a product in a worn slot - a throwing
    -- item into Ammo - where the bag count never sees it (2.35.2 log: Shaded Kunai x5 stowed, then "did not
    -- come back" and 3s lost, every success)
    local function total(name) return self.inv:client_total(name) end
    local before = count(product)
    local beforeAll = total(product)
    local toolsBefore = {}   -- bag counts before the combine of everything that can come back
    for _, list in ipairs({ want.tools or {}, want.also or {}, want.failBack or {} }) do
        for _, t in ipairs(list) do toolsBefore[t.name] = count(t.name) end
    end
    self.mq.doevents()        -- drop any stale chat before listening
    self.heard = nil
    -- A combine the game never took (2.32.0 log, 23:43:55: no message in 5s, the container still full) is sent
    -- again after RESEND_MS - only while the container still holds exactly what it held when it was sent, so a
    -- combine that did happen is never sent twice.
    local placed = describe()
    local t0 = self.mq.gettime()
    local w
    for try = 1, Combine.SENDS do
        if try > 1 then self.log.debug('  no answer to %s and the container is as it was - sent again (try %d)', cmd, try) end
        -- the last item went in a moment ago: never in the same frame as it (the floor, core/pace - 2.46.7)
        if try == 1 and self.cursor.gap then
            local gp = self.cursor:gap(ctx)
            if not gp.ok then return gp end
            t0 = self.mq.gettime()   -- the answer is timed from the send, not from before the gap
        end
        self.log.debug('  send: %s', cmd)
        self.mq.cmd(cmd)
        local left = Combine.MS - (self.mq.gettime() - t0)
        w = ctx:wait(try < Combine.SENDS and math.min(Combine.RESEND_MS, left) or math.max(1, left), function() return self.heard ~= nil end)
        if w.ok or w.why ~= 'timeout' then break end
        if self.mq.gettime() - t0 >= Combine.MS then break end
        if describe() ~= placed then
            -- the game took it (the container changed) but its message is late: never sent again, and its message
            -- is waited for up to MS (2.42.15 Lopan log: the gorget's container was empty and the product on the
            -- cursor 1.7s after the send - the message came after the 1.5s resend check, and the row was failed)
            self.log.debug('  the container changed with no message yet after %dms - waiting for it (not sent again)',
                self.mq.gettime() - t0)
            w = ctx:wait(math.max(1, Combine.MS - (self.mq.gettime() - t0)), function() return self.heard ~= nil end)
            break
        end
    end
    w.ms = self.mq.gettime() - t0
    if not w.ok and w.why ~= 'timeout' then return w end
    local heard = self.heard
    if not heard then
        local c = self.cursor:item()
        local now = describe()
        if now ~= placed and c and c.name:lower() == product:lower() then
            -- the game took it and handed the product back, but its message never came (2.46.3 logs, all three
            -- crafters: a client stall dropped the chat line - the snapshot's chat has the combine before and not
            -- this one - with the container empty and the product on the cursor; every such row was failed)
            heard = { result = 'success', line = '(no message: the container emptied and ' .. c.name .. ' came onto the cursor)' }
            self.log.warn('Combine: no message after %dms, but the container emptied and %s x%d is on the cursor - counted a success',
                w.ms or 0, c.name, c.stack)
        else
            return R.fail('no answer', string.format('no combine message after %dms (container: %s, cursor: %s)', w.ms or 0,
                now, c and c.name or 'empty'))
        end
    end
    self.log.debug('  combine: %s after %dms: "%s"', heard.result, w.ms or 0, heard.line)

    -- What should come back: the product on a success, the tools either way. Nothing on a refusal.
    local expect = {}
    local function add(list) for _, t in ipairs(list or {}) do expect[#expect + 1] = { name = t.name, n = t.n, before = toolsBefore[t.name] } end end
    if heard.result == 'success' then
        expect[#expect + 1] = { name = product, n = yield, before = before }
        add(want.also)
    end
    if heard.result ~= 'refused' and heard.result ~= 'closed' then add(want.tools) end
    if heard.result == 'failed' then add(want.failBack) end
    local destroyedSoFar = function() return 0 end
    local function short()
        local out = {}
        for _, e in ipairs(expect) do
            local got = count(e.name) - e.before
            if e.name == product then got = math.max(got, total(product) - beforeAll) + destroyedSoFar() end
            if got < e.n then out[#out + 1] = string.format('%s x%d', e.name, e.n - math.max(got, 0)) end
        end
        return out
    end
    local kind = {}
    for _, t in ipairs(want.tools or {}) do kind[t.name:lower()] = 'tool' end
    for _, f in ipairs(want.failBack or {}) do kind[f.name:lower()] = kind[f.name:lower()] or 'given back' end
    for _, i in ipairs(want.ins or {}) do kind[i.name:lower()] = kind[i.name:lower()] or 'salvage' end
    for _, a in ipairs(want.also or {}) do kind[a.name:lower()] = 'also made' end
    kind[product:lower()] = 'product'

    local returned = {}
    local destroyed = 0
    local salvageWatched = false
    destroyedSoFar = function() return destroyed end
    local t0 = self.mq.gettime()
    for _ = 1, 20 do
        local c = self.cursor:item()
        if c then
            local k = kind[c.name:lower()] or 'other'
            returned[#returned + 1] = string.format('%s x%d (%s)', c.name, c.stack, k)
            if k == 'other' then   -- salvage is always one of the ingredients, so this should not happen
                self.log.warn('Combine: %s x%d came back from %s and is not the product, a tool or an ingredient',
                    c.name, c.stack, product)
            end
            if k == 'product' and (opts.destroy or want.destroy) and heard.result == 'success' then
                local d = self:destroy(ctx, c)
                if not d.ok then return d end
                destroyed = destroyed + c.stack
            else
                local st = self.cursor:stow(ctx)
                if not st.ok then return st end
            end
        elseif #short() == 0 then
            -- the Salvage AA hands back an ingredient after the rest of a failure, with no message of its own:
            -- 48-115ms later in every log so far (2.35.4: a
            -- late Metal Tempering Chemicals landed while the next combine was being placed, and the game then
            -- refused that combine with a slot empty). So after a failure the cursor is watched SALVAGE_MS more.
            if heard.result ~= 'failed' or salvageWatched then break end
            salvageWatched = true
            local capLeft = Combine.FAIL_CAP_MS - (self.mq.gettime() - t0)
            if capLeft <= 0 then break end
            local s = ctx:wait(math.min(Combine.SALVAGE_MS, capLeft), function() return self.cursor:item() ~= nil end)
            if not s.ok and s.why ~= 'timeout' then return s end
            if not s.ok then break end
            self.log.debug('  more salvage on the cursor %dms after the rest', s.ms or 0)
            salvageWatched = false
        else
            local left = Combine.ARRIVE_MS - (self.mq.gettime() - t0)
            local a = left > 0 and ctx:wait(left, function() return self.cursor:item() ~= nil or #short() == 0 end)
                or { ok = false, why = 'timeout' }
            if not a.ok and a.why ~= 'timeout' then return a end
            if not a.ok then break end
            if self.cursor:item() then self.log.debug('  more on the cursor after %dms', self.mq.gettime() - t0) end
        end
    end
    local missing = short()
    if #missing > 0 then
        self.log.warn('Combine: %s, but %s did not come back within %dms', heard.result, table.concat(missing, ', '), Combine.ARRIVE_MS)
    end
    local made = math.max(count(product) - before, total(product) - beforeAll) + destroyed
    if count(product) - before < made - destroyed and not self.saidWorn then
        self.saidWorn = true
        local where = {}
        for _, slot in ipairs({ 'ammo', 'range', 'primary', 'secondary' }) do
            local ok, n = pcall(function() return self.mq.TLO.Me.Inventory(slot).Name() end)
            if ok and n and n:lower() == product:lower() then where[#where + 1] = slot end
        end
        self.log.info('%s went outside the bags when stowed (%s) - counted from the client\'s total', product,
            #where > 0 and ('worn in ' .. table.concat(where, ', ')) or 'not in a bag')
    end
    self.log.debug('  back from the combine (%s): %s%s; container now: %s', heard.result,
        #returned > 0 and table.concat(returned, ', ') or 'nothing', destroyed > 0 and string.format(' (%d destroyed)', destroyed) or '',
        describe())
    return R.ok({ result = heard.result, line = heard.line, ms = w.ms or 0, made = made, destroyed = destroyed,
                  returned = returned, missing = missing })
end

return Combine
