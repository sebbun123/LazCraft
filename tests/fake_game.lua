-- A small simulated character for the block tests: bags, cursor and a few windows.
-- Commands take effect after `latency` ms (like a real server round trip), so a block that does not
-- wait for the game to confirm will fail these tests.
--
-- Usage: local G = FakeGame.new(F)  -- F from fake_mq; replaces F.mq.TLO and hooks F.mq.cmd
--        G:bag(1, 'Backpack', 10); G:put(1, 1, 'Water Flask', 20)
local Game = {}
Game.__index = Game

-- Like the real client, an item's ID is its TYPE: two Jade on the cursor have the same ID.
local idByName, nextId = {}, 1000
local function new_item(name, stack)
    local key = name:lower()
    if not idByName[key] then nextId = nextId + 1; idByName[key] = nextId end
    return { id = idByName[key], name = name, stack = stack or 1 }
end

function Game.new(F)
    local g = setmetatable({
        F = F, latency = 0,       -- the client shows clicks, bags and the cursor at once (as the logs show)
        packs = {}, cursor = {},  -- cursor is a queue; cursor[1] is what the client shows
        windows = { quantitywnd = { open = false, text = '' } },
        bagOrder = {},            -- bags in the order they were opened; Esc closes the newest first
        stuck = {},               -- windows that ignore close attempts
        log = {},
        qtyIgnoresText = false,   -- simulate a client that hands over the whole stack anyway
        bagReadyMs = 0,           -- a click into a bag opened less than this long ago is lost (as seen in game)
        lostClicks = 0,           -- this many slot clicks are lost outright before one takes
        setTextIgnored = false,   -- the amount field never takes the value
        lockAfterMoves = nil,     -- after this many item moves in a row, slot clicks are ignored ...
        lockMs = 0,               -- ... for this long (as seen in game after a fast burst)
        moves = 0, ignoreUntil = -1,
        deafOpens = 0,            -- the next this-many bag openings ignore every slot click until reopened (as seen in game)
        -- the zone
        me = { x = 0, y = 0, z = 0 }, speed = 0.05,   -- units per ms while navigating
        spawns = {}, nextSpawn = 100, targetId = 0,
        nav = { active = false },
        navIgnores = 0,           -- this many /nav commands do nothing
        navStopsShortBy = 0,      -- the next nav ends this far beyond the asked distance
        stuckAt = nil,            -- nav keeps saying active but we stop moving at this distance from the goal
        noPath = {},              -- spawn ids with no nav path
        merchant = { id = 0, received = false },
        merchantMs = 150, listMs = 200,   -- server answers
        merchantIgnores = 0,      -- this many open requests get no answer
        wrongMerchant = nil,      -- an open request opens this spawn id instead
        usableOnly = true,        -- "Show only items I can use" starts ticked; it hides tradeskill items
        sel = nil,                -- { kind = 'merchant' | 'bag', name, pack, slot }
        tradeMs = 150,            -- server answer to a buy or sell
        buyIgnores = 0,           -- this many buys get no answer
        -- kits and combines
        recipes = {},             -- product -> { ingredient, ... } (one each)
        combineMs = 120,
        combineFails = 0,         -- this many combines fail on skill (ingredients used up)
        productLateMs = nil,      -- returned items come back first; the product lands on the cursor this much later
        returnLateMs = nil,       -- returned tools land this much later
        failKeepsTools = false,   -- a failure uses up the tools too
        salvage = {},             -- product -> { ingredient, ... } handed back by a failure (chance)
        failBack = {},            -- product -> { ingredient, ... } always given back by a failure (FailBack=)
        alsoMade = {},            -- product -> { item, ... } made as well by a success (Also=)
        salvageLateMs = nil,
        desyncOnLate = false,     -- a late salvage also brings the game's "Inventory Desyncronization detected" lines
        desyncShutsKit = false,   -- ... and those lines shut an open kit's own window (Pack10), its combine window left up
        kitOpensTradeskill = false, -- right-click raises the tradeskill window; Experiment raises the combine window
        kitIgnoresClose = false,  -- a right-click does not close the open kit (so /cleanup has to)
        -- world stations
        grounds = {}, itemTarget = nil, enviro = {},
        stationMs = 150,          -- server answer to a click on a station
        stationOpensTradeskill = false, -- the station raises the tradeskill window; Experiment raises the combine window
        stationInUse = false,     -- someone else is using it
        stationIgnores = 0,       -- this many clicks on a station get no answer
        stationIgnoresClose = false,
        blankSlotsWithTradeskill = false, -- slot reads go blank while the tradeskill window is open (the old, unproven claim)
        -- bank
        bank = {}, bankMs = 150,
        -- zones and travel
        zone = nil,               -- nil = freeporttemple
        zoneDefs = {},            -- zone -> function(G) that fills a zone's spawns, grounds, doors the first time
        arriveAt = {},            -- zone -> { x, y, z } where zoning in puts us
        saved = {},               -- zones left behind: their spawns, grounds, doors
        doors = {}, doorTarget = nil,
        gameState = 'INGAME', zoneMs = 2000, meshMs = 300, meshLoaded = true,
        portMs = 300,             -- a porter's or a door's answer before zoning begins
        aa = {},                  -- lower name -> { to, castMs, ready, cooldownMs }
        casting = nil, interruptNext = 0, aaIgnores = 0, sayIgnores = 0, doorIgnores = 0,
        landIn = nil,             -- zoning lands here instead of where it should (a wrong-zone test)
        targetSettleMs = nil,     -- a /say this soon after /target is ignored (as seen in game)
        -- spells
        book = {},                -- lower spell -> true (scribed)
        gems = {},                -- gem -> spell name
        memMs = 3000, castMs = 4000, recastMs = 2000, readyAt = {},
        mana = 100, manaCost = 10, medPerSec = 5, sitting = false,
        produce = {},             -- lower spell -> { product, yield, reagents = { {name, n} } }
        fizzleNext = 0,
        -- trades with another character (the partner is played by the test)
        trade = nil,              -- { mine = {items}, theirs = {items}, myOk, theirOk }
        tradesDone = 0,
        dropIgnores = 0,          -- this many Target_HP drops do nothing (the /click left target fallback takes it)
        tradeRange = 20,
    }, Game)
    g:install()
    return g
end

-- ---- setting up -------------------------------------------------------------------------------
-- A container is an item too: it can sit in a top-level slot, inside another bag, or on the cursor.
-- size: 1-4 (small..giant); cap: the biggest size it holds.
local function container(name, slots, kit, opts)
    local c = new_item(name, 1)
    c.bag, c.kit, c.slots, c.open, c.items = true, kit or nil, slots, false, {}
    c.size, c.sizeCap = (opts and opts.size) or 3, (opts and opts.cap) or 4
    c.tsOnly, c.ts = opts and opts.tsOnly or nil, kit or (opts and opts.ts) or nil   -- kits count as tradeskill items
    return c
end
function Game:bag(pack, name, slots, opts) self.packs[pack] = container(name, slots, false, opts) end
function Game:bag_in(pack, slot, name, slots, opts) self.packs[pack].items[slot] = container(name, slots, false, opts) end
function Game:kit_in(pack, slot, name, slots, opts) self.packs[pack].items[slot] = container(name, slots, true, opts) end
function Game:bankbag(b, name, slots) self.bank[b] = { bag = true, name = name, slots = slots, items = {} } end
function Game:bankkit(b, slot, name, slots) self.bank[b].items[slot] = container(name, slots, true) end
function Game:bankput(b, slot, name, stack)
    local item = new_item(name, stack)
    if slot then self.bank[b].items[slot] = item else self.bank[b] = item end
end
function Game:bankcount(name)
    local n = 0
    for _, b in pairs(self.bank) do
        if b.bag then for _, it in pairs(b.items) do if it.name:lower() == name:lower() then n = n + it.stack end end
        elseif b.name:lower() == name:lower() then n = n + b.stack end
    end
    return n
end

function Game:kit(pack, name, slots, opts) self.packs[pack] = container(name, slots, true, opts) end
function Game:put(pack, slot, name, stack)
    local item = new_item(name, stack)
    if slot then self.packs[pack].items[slot] = item else self.packs[pack] = item end
    return item
end
function Game:spawn(name, x, y, z, opts)
    opts = opts or {}
    self.nextSpawn = self.nextSpawn + 1
    local sp = { id = self.nextSpawn, name = name, x = x, y = y, z = z or 0,
                 class = opts.class or 'Merchant', items = opts.items or 20, sells = opts.sells or {}, ports = opts.ports,
                 portTo = opts.portTo,    -- portTo: walking into it zones us there (the AFK mirror's Exit Portal)
                 standing = opts.standing,    -- standing: its con word for us (/consider; nil = indifferently)
                 notNpc = opts.notNpc }       -- notNpc: not found by an `npc "..."` search (only ${Spawn[name]})
    self.spawns[sp.id] = sp
    return sp.id
end
function Game:ground(name, y, x, z, opts)
    local gr = { name = name, y = y, x = x, z = z or 0 }
    for k, v in pairs(opts or {}) do gr[k] = v end
    self.grounds[#self.grounds + 1] = gr
    return gr
end
function Game:door(name, y, x, z, to) self.doors[#self.doors + 1] = { name = name, y = y, x = x, z = z or 0, to = to } end
-- A zone line: running within r of it (x, y) zones us to `to`. Per zone: G.zoneLines[zone] = { {x, y, r, to} }
function Game:zone_line(zone, x, y, r, to)
    self.zoneLines = self.zoneLines or {}
    self.zoneLines[zone] = self.zoneLines[zone] or {}
    table.insert(self.zoneLines[zone], { x = x, y = y, r = r, to = to })
end

-- Zoning: the client leaves the game for zoneMs, then stands in the new zone (its spawns built the first
-- time, kept after), and the navmesh loads meshMs later.
function Game:start_zone(to)
    local g, F = self, self.F
    g.gameState = 'ZONING'
    g.nav.active = false
    g.casting = nil
    F.at(F.now + g.zoneMs, function()
        -- an AFK mirror is '<zone>#afk': the same short name, its own spawns and stations
        local from = g.zoneKey or g.zone or 'freeporttemple'
        g.saved[from] = { spawns = g.spawns, grounds = g.grounds, doors = g.doors }
        to = g.landIn or to
        g.zoneKey = to
        g.zone = to:gsub('#.*$', '')
        local back = g.saved[to]
        if back then g.spawns, g.grounds, g.doors = back.spawns, back.grounds, back.doors
        else
            g.spawns, g.grounds, g.doors = {}, {}, {}
            if g.zoneDefs[to] then g.zoneDefs[to](g) end
        end
        local a = g.arriveAt[to] or g.arriveAt[g.zone] or { 0, 0, 0 }
        g.me = { x = a[1], y = a[2], z = a[3] }
        g.targetId, g.doorTarget = 0, nil
        g.gameState = 'INGAME'
        F.say('You have entered ' .. g.zone .. '.')
        g.spawnsReadyAt = F.now + (g.spawnsLateMs or 0)   -- the zone's spawns arrive a moment after zoning in
        g.meshLoaded = false
        F.at(F.now + g.meshMs, function() g.meshLoaded = true end)
    end)
end
function Game:station_open() return (self.windows.containercombine_items or {}).open == true and self.atStation end

function Game:dist(sp)
    local m = self.me
    return math.sqrt((sp.x - m.x) ^ 2 + (sp.y - m.y) ^ 2 + (sp.z - m.z) ^ 2)
end
-- Take n of an item out of the bags (a spell using its reagents).
function Game:use(name, n)
    for pk = 1, 10 do
        local p = self.packs[pk]
        if p and p.bag then for i = 1, p.slots do
            local it = p.items[i]
            if n > 0 and it and it.name == name then
                local k = math.min(n, it.stack); it.stack, n = it.stack - k, n - k
                if it.stack <= 0 then p.items[i] = nil end
            end
        end end
    end
    return n == 0
end

function Game:tick(dt)
    if self.sitting then self.mana = math.min(100, self.mana + self.medPerSec * dt / 1000) end
    if self.casting and self.nav.active then          -- moving interrupts a cast
        self.casting = nil
        self.F.say('Your spell is interrupted.')
    end
    if self.running then                               -- /keypress forward hold: straight on along the heading
        local step = self.speed * dt
        local h = math.rad(self.heading or 0)
        if not (self.bridgeSnagUntilDuck and not self.ducking) then
            self.me.y, self.me.x = self.me.y + math.cos(h) * step, self.me.x + math.sin(h) * step
        end
        for _, l in ipairs((self.zoneLines or {})[self.zone or 'freeporttemple'] or {}) do
            if self.gameState == 'INGAME' and math.sqrt((self.me.x - l.x) ^ 2 + (self.me.y - l.y) ^ 2) <= l.r then self:start_zone(l.to) end
        end
    end
    local n = self.nav
    if not n.active then return end
    local sp = n.loc or self.spawns[n.id]
    if not sp then n.active = false; return end
    local d = self:dist(sp)
    if self.stuckAt and d <= self.stuckAt and not (self.duckFrees and self.ducking) then return end   -- wedged: active, not moving
    local goal = n.dist + n.short
    if d <= goal then n.active = false; return end
    local step = math.min(self.speed * dt, d - goal)
    local m = self.me
    m.x, m.y, m.z = m.x + (sp.x - m.x) / d * step, m.y + (sp.y - m.y) / d * step, m.z + (sp.z - m.z) / d * step
    if self:dist(sp) <= goal + 1e-6 then n.active = false end
    if sp.portTo and self.gameState == 'INGAME' and self:dist(sp) <= 3 then self:start_zone(sp.portTo) end
end

-- Like the client placing bought items: top up a stack of the same item, else the first empty bag slot.
function Game:give(name, n)
    local slots = (self.kitItems or {})[name:lower()]
    if slots then                                       -- a kit: a container of its own, in the first free slot
        for pk = 1, 10 do
            local p = self.packs[pk]
            if p and p.bag and not p.kit then for i = 1, p.slots do
                if not p.items[i] then p.items[i] = container(name, slots, true); return true end
            end end
        end
        return false
    end
    for _, p in pairs(self.packs) do
        if p.bag then for _, it in pairs(p.items) do
            if it.name == name then it.stack = it.stack + n; return true end
        end end
    end
    for pk = 1, 10 do
        local p = self.packs[pk]
        if p and p.bag and not p.tsOnly then for i = 1, p.slots do
            if not p.items[i] then p.items[i] = new_item(name, n); return true end
        end end
    end
    return false
end
function Game:merchant_sells(name)
    local sp = self.spawns[self.merchant.id]
    if not (sp and (self.windows.merchantwnd or {}).open) then return false end
    for _, it in ipairs(sp.sells) do if it:lower() == name:lower() then return true end end
    return false
end

function Game:hold(name, stack) self.cursor[#self.cursor + 1] = new_item(name, stack) end
-- Window names are case-insensitive, like MQ's.
function Game:window(name, open)
    local key = name:lower()
    self.windows[key] = self.windows[key] or {}
    self.windows[key].open = open
end
function Game:win(name) return self.windows[name:lower()] end

function Game:count(name)
    local n = 0
    for _, p in pairs(self.packs) do
        if p.bag then for _, it in pairs(p.items) do if it.name == name then n = n + it.stack end end
        elseif p.name == name then n = n + p.stack end
    end
    return n
end

function Game:free()
    local n = 0
    for _, p in pairs(self.packs) do
        if p.bag then for i = 1, p.slots do if not p.items[i] then n = n + 1 end end end
    end
    return n
end

-- The partner side of a trade, for tests: they put items in, or they click Trade.
function Game:incoming(list)
    self.trade = self.trade or { mine = {}, theirs = {} }
    for _, x in ipairs(list) do self.trade.theirs[#self.trade.theirs + 1] = new_item(x[1], x[2]) end
    self.trade.myOk, self.trade.theirOk = false, false
    self:window('TradeWnd', true)
end
function Game:partner_accepts()
    if not self.trade then return end
    self.trade.theirOk = true
    self:trade_check()
end
function Game:trade_check()
    local t = self.trade
    if not (t and t.myOk and t.theirOk) or self.tradeNeverCompletes then return end
    for _, it in ipairs(t.theirs) do self:give(it.name, it.stack) end
    self.ppGiven = (self.ppGiven or 0) + (t.myPP or 0)
    self.trade = nil
    self.tradesDone = self.tradesDone + 1
    self:window('TradeWnd', false)
end

-- ---- TLO --------------------------------------------------------------------------------------
local function fn(v) return function() return v end end
local EMPTY = setmetatable({}, { __index = function() return fn(nil) end })

local function item_tlo(it, bag)
    if not it then return setmetatable({ ID = fn(0), Container = fn(0), Item = function() return EMPTY end }, { __index = function() return fn(nil) end }) end
    local t = { ID = fn(it.id or 1), Name = fn(it.name), Stack = fn(it.stack or 1), Size = fn(it.size or 1),
                Tradeskills = fn(it.ts == true) }
    if bag then
        t.SizeCapacity = fn(bag.sizeCap or 4)
        t.Container = fn(bag.slots)
        t.Open = fn(nil)   -- on Lazarus the item's Open member does not report the bag window
        t.Items = function() local n = 0; for _ in pairs(bag.items) do n = n + 1 end; return n end
        t.Item = function(i) local x = bag.items[i]; return item_tlo(x, x and x.bag and x or nil) end
    else
        t.SizeCapacity = fn(0)
        t.Container = fn(0)
        t.Item = function() return EMPTY end
        t.Open = fn(false)
    end
    return t
end

function Game:install()
    local g = self
    local TLO = {}
    TLO.Me = {
        CleanName = fn('Glanen'),
        Class = { Name = function() return g.class end },
        FreeInventory = function() return g:free() end,
        Inventory = function(slot)
            if slot == 'ammo' then return item_tlo(g.worn and g.worn.ammo) end
            local pk = tonumber(tostring(slot):match('^pack(%d+)$'))
            local p = pk and g.packs[pk]
            if not p then return item_tlo(nil) end
            if p.bag then
                if g.blankSlotsWithTradeskill and (g.windows.tradeskillwnd or {}).open then return item_tlo({ id = 1, name = p.name }, { slots = p.slots, items = {} }) end
                return item_tlo(p, p)
            end
            return item_tlo(p)
        end,
    }
    -- buffs (2.46.0, the Radix Draught): g.buffs[name] = true
    TLO.Me.Buff = function(name) return { ID = function() return (g.buffs or {})[name] and 1 or 0 end } end
    TLO.Me.Song = function(name) return { ID = function() return 0 end } end
    TLO.Me.X = function() return g.me.x end
    TLO.Me.Y = function() return g.me.y end
    TLO.Me.Z = function() return g.me.z end
    local function spawn_tlo(sp)
        if not sp then return setmetatable({ Class = { Name = fn(nil) } }, { __index = function(_, k) return k == 'ID' and fn(0) or fn(nil) end }) end
        return { ID = fn(sp.id), CleanName = fn(sp.name), X = fn(sp.x), Y = fn(sp.y), Z = fn(sp.z),
                 Type = fn(sp.class == 'PC' and 'PC' or 'NPC'),
                 Distance3D = function() return g:dist(sp) end, Class = { Name = fn(sp.class) } }
    end
    -- Spawn searches: 'npc "part of name"' (partial match, like MQ) and 'id N'.
    local function search(q)
        if g.spawnsReadyAt and g.F.now < g.spawnsReadyAt then return {} end
        local id = tonumber(q:match('^id (%d+)$'))
        if id then return { g.spawns[id] } end
        if q == 'npc banker' then
            local out = {}
            for _, sp in pairs(g.spawns) do if sp.class == 'Banker' then out[#out + 1] = sp end end
            table.sort(out, function(a, b) return g:dist(a) < g:dist(b) end)
            return out
        end
        local pc = q:match('^pc =(.+)$')
        if pc then
            local out = {}
            for _, sp in pairs(g.spawns) do if sp.class == 'PC' and sp.name:lower() == pc:lower() then out[#out + 1] = sp end end
            return out
        end
        -- 'npc "<part>"': NPCs only (a spawn made with notNpc - the AFK mirror's Exit Portal - is not one);
        -- a bare name: any spawn whose name holds it
        local npcPart = q:match('^npc "(.*)"$')
        local part = (npcPart or q):lower()
        local out = {}
        for _, sp in pairs(g.spawns) do
            if sp.name:lower():find(part, 1, true) and not (npcPart and sp.notNpc) then out[#out + 1] = sp end
        end
        table.sort(out, function(a, b) return g:dist(a) < g:dist(b) end)
        return out
    end
    TLO.Spawn = function(q) return spawn_tlo(search(q)[1]) end
    TLO.SpawnCount = function(q) return function() return #search(q) end end
    TLO.NearestSpawn = function(arg)
        local i, q = arg:match('^(%d+),%s*(.*)$')
        return spawn_tlo(search(q)[tonumber(i)])
    end
    TLO.Target = setmetatable({}, { __index = function(_, k)
        return function()
            local sp = g.spawns[g.targetId]
            if k == 'ID' then return sp and sp.id or 0 elseif k == 'CleanName' then return sp and sp.name end
        end
    end })
    TLO.Navigation = {
        Active = function() return g.nav.active end,
        MeshLoaded = function() return g.meshLoaded end,
        PathExists = function(q)
            -- g.bridgeY: the mesh is broken there - a path only to the same side of it
            local function side(y) return y >= (g.bridgeY or 0) end
            local ly = tonumber(q:match('^loc (%S+)'))
            if ly then return function() return not g.bridgeY or side(ly) == side(g.me.y) end end
            local id = tonumber(q:match('^id (%d+)$'))
            return function()
                local sp = id and g.spawns[id]
                return sp ~= nil and not g.noPath[id] and (not g.bridgeY or side(sp.y) == side(g.me.y))
            end
        end,
    }
    TLO.Merchant = {
        ID = function() return (g.windows.merchantwnd or {}).open and g.merchant.id or 0 end,
        Items = function()
            local sp = g.spawns[g.merchant.id]
            return ((g.windows.merchantwnd or {}).open and g.merchant.received and sp) and sp.items or 0
        end,
        ItemsReceived = function() return (g.windows.merchantwnd or {}).open == true and g.merchant.received end,
        Item = function(q)
            local name = q:gsub('^=', '')
            local nostack = (g.noStack or {})[name:lower()]
            -- partialListMs: the list says complete before all of it is there (2.43.6 log: Audri, 7 of 153)
            local partial = g.merchant.tailAt and g.F.now < g.merchant.tailAt
            return { ID = function() return (not partial and g:merchant_sells(name)) and 5000 or 0 end,
                     Stackable = function() return not nostack end,
                     StackSize = function() return nostack and 1 or (g.stackSize or 1000) end }
        end,
        SelectedItem = {
            Name = function() return g.sel and g.sel.name end,
            -- where the selected item lives: ours = 22 + pack / slot - 1; the merchant's = its list index / -1
            ItemSlot = function()
                if not g.sel then return nil end
                if g.sel.kind == 'merchant' then return 25 end   -- deliberately inside 23..32
                return 22 + g.sel.pack
            end,
            ItemSlot2 = function()
                if not g.sel then return nil end
                if g.sel.kind == 'merchant' then return -1 end
                return g.sel.slot - 1
            end,
            Stack = function()
                if not g.sel then return nil end
                if g.sel.kind == 'merchant' then return 1 end
                local it = g.packs[g.sel.pack] and g.packs[g.sel.pack].items[g.sel.slot]
                return it and it.stack or 0
            end,
        },
    }
    TLO.Me.Bank = function(b)
        local p = g.bank[b]
        if not p then return item_tlo(nil) end
        if p.bag then return item_tlo({ id = 1, name = p.name }, p) end
        return item_tlo(p)
    end
    TLO.FindItemBankCount = function(q) return function() return g:bankcount((q:gsub('^=', ''))) end end
    TLO.Zone = { ShortName = function() return g.zone or 'freeporttemple' end }
    TLO.EverQuest = { GameState = function() return g.gameState end }
    TLO.Me.Casting = { ID = function() return g.casting and 1 or 0 end }
    TLO.Me.Book = function(spell) return function() return g.book[spell:lower()] and 1 or nil end end
    TLO.Me.Gem = function(x)
        if type(x) == 'number' then return { Name = function() return g.gems[x] end } end
        return function() for i = 1, 12 do if g.gems[i] and g.gems[i]:lower() == x:lower() then return i end end; return nil end
    end
    TLO.Me.SpellReady = function(spell) return function()
        local gm; for i = 1, 12 do if g.gems[i] and g.gems[i]:lower() == spell:lower() then gm = i end end
        return gm ~= nil and not g.casting and g.F.now >= (g.readyAt[spell:lower()] or 0)
    end end
    TLO.Me.PctMana = function() return math.floor(g.mana) end
    TLO.Me.Skill = function(name) return function() return (g.skills or {})[name] end end
    TLO.Me.SkillCap = function(name) return function() return (g.skillCaps or {})[name] end end
    TLO.Me.Sitting = function() return g.sitting end
    g.coin = g.coin or { pp = 10000, gp = 0, sp = 0, cp = 0 }   -- plenty, unless a test says otherwise
    TLO.Me.Platinum = function() return g.coin.pp end
    TLO.Me.Gold = function() return g.coin.gp end
    TLO.Me.Silver = function() return g.coin.sp end
    TLO.Me.Copper = function() return g.coin.cp end
    TLO.Me.CursorPlatinum = function() return g.cursorPP or 0 end
    TLO.Me.Moving = function() return g.nav.active end
    TLO.Me.Ducking = function() return g.ducking == true end
    TLO.Me.AltAbility = function(n) return { ID = function() return g.aa[n:lower()] and 1 or 0 end } end
    TLO.Me.AltAbilityReady = function(n) return function() local a = g.aa[n:lower()]; return a ~= nil and a.ready == true end end
    TLO.DoorTarget = {
        ID = function() return g.doorTarget and 1 or 0 end,
        Name = function() return g.doorTarget and g.doorTarget.name end,
        Distance = function() return g.doorTarget and g:dist(g.doorTarget) end,
        Y = function() return g.doorTarget and g.doorTarget.y end,
        X = function() return g.doorTarget and g.doorTarget.x end,
        Z = function() return g.doorTarget and g.doorTarget.z end,
    }
    TLO.Cursor = setmetatable({}, { __index = function(_, k)
        return function()
            local c = g.cursor[1]
            if not c then return k == 'ID' and 0 or nil end
            if k == 'ID' then return c.id elseif k == 'Name' then return c.name elseif k == 'Stack' then return c.stack end
        end
    end })
    TLO.FindItem = function(q)
        local name = q:gsub('^=', '')
        local where
        for pk = 1, 10 do
            local p = g.packs[pk]
            if p and p.bag then for i = 1, p.slots do
                local it = p.items[i]
                if not where and it and it.name:lower() == name:lower() then where = { pk, i, it } end
            end elseif p and not where and p.name and p.name:lower() == name:lower() then where = { pk, nil, p } end
        end
        return {
            ID = function() return where and 1 or 0 end,
            ItemSlot = function() return where and (22 + where[1]) or nil end,
            ItemSlot2 = function() return where and (where[2] and where[2] - 1 or -1) or nil end,
            Stack = function() return where and where[3].stack or nil end,
            Stackable = function() return where and not (g.noStack or {})[name:lower()] or nil end,
            StackSize = function() if not where then return nil end; return (g.noStack or {})[name:lower()] and 1 or (g.stackSize or 1000) end,
            Size = function() return where and (where[3].size or 1) or nil end,
            -- a clicky's cooldown in seconds and its spell (g.itemTimers[name] = when it is ready, g.itemSpells[name])
            TimerReady = function()
                local t = (g.itemTimers or {})[name:lower()]
                return (t and t > g.F.now) and math.ceil((t - g.F.now) / 1000) or 0
            end,
            Spell = { Name = function() return (g.itemSpells or {})[name] end },
        }
    end
    TLO.ItemTarget = setmetatable({}, { __index = function(_, k)
        return function()
            local t = g.itemTarget
            if not t then return nil end
            if k == 'Name' then return 'IT10804_ACTORDEF' elseif k == 'ID' then return 0
            elseif k == 'Distance' then return g:dist(t) elseif k == 'X' then return t.x elseif k == 'Y' then return t.y
            elseif k == 'Z' then return t.z end
        end
    end })
    TLO.InvSlot = function(slot)
        local i = tonumber(tostring(slot):match('^enviro(%d+)$'))
        return { Item = {
            ID = function() return (i and g.enviro[i]) and g.enviro[i].id or 0 end,
            Name = function() return (i and g.enviro[i]) and g.enviro[i].name or nil end,
            Stack = function() return (i and g.enviro[i]) and g.enviro[i].stack or nil end,
        } }
    end
    TLO.FindItemCount = function(q)
        local name = q:gsub('^=', '')
        return function()
            local n = g:count(name)
            for _, c in ipairs(g.cursor) do if c.name == name then n = n + c.stack end end
            for _, a in pairs(g.worn or {}) do   -- the client counts worn slots too
                if a.name == name then n = n + (a.stack or 1) end
            end
            return n
        end
    end
    -- DoClose works on everything except the kit combine window, which only Esc closes (as in game).
    TLO.Window = function(name)
        local base, child = name:match('^([^/]+)/?(.*)$')
        base = base:lower()
        local bagPack = tonumber(base:match('^pack(%d+)$'))
        return {
            Open = function()
                if child ~= '' then return nil end
                if bagPack then local p = g.packs[bagPack]; return p ~= nil and p.bag == true and p.open == true end
                local w = g.windows[base]
                return w ~= nil and w.open == true
            end,
            Text = function() local w = g.windows[base]; return w and w.text end,
            Checked = function() if base == 'merchantwnd' and child == 'MW_UsableButton' then return g.usableOnly end end,
            Enabled = function()
                if base ~= 'merchantwnd' or not (g.windows.merchantwnd or {}).open or not g.sel then return false end
                -- Lazarus keeps both lit whatever is selected (seen in game), so they say nothing
                if child == 'MW_Buy_Button' or child == 'MW_Sell_Button' then return true end
                return false
            end,
            DoOpen = function() g:later(function()
                if g.windows[base] then g.windows[base].open = true else g.windows[base] = { open = true } end
            end) end,
            DoClose = function() g:later(function()
                if base ~= 'containercombine_items' and not g.stuck[base] and g.windows[base] then g.windows[base].open = false end
            end) end,
        }
    end
    self.F.mq.TLO = TLO
    self.F.ticks[#self.F.ticks + 1] = function(dt) g:tick(dt) end
    local realCmd = self.F.mq.cmd
    self.F.mq.cmd = function(s) realCmd(s); g:command(s) end
    self.F.mq.cmdf = function(fmt, ...) self.F.mq.cmd(string.format(fmt, ...)) end
end

-- latency 0 = the client updates at once, as the bag window does in game ("open: yes after 0ms").
function Game:later(f)
    if self.latency == 0 then return f() end
    self.F.at(self.F.now + self.latency, f)
end

-- ---- commands ---------------------------------------------------------------------------------
function Game:take_from(pack, slot, n, fromBank)
    local where = fromBank and self.bank or self.packs
    local p = where[pack]
    local it = slot and p.items[slot] or p
    if it.bag then                                        -- a container moves as itself, with its contents
        if slot then p.items[slot] = nil else where[pack] = nil end
        it.open = false
        self.cursor[#self.cursor + 1] = it
        self:moved()
        return
    end
    local taken = new_item(it.name, n)
    taken.ts = it.ts
    it.stack = it.stack - n
    if it.stack <= 0 then
        if slot then p.items[slot] = nil else where[pack] = nil end
    end
    self.cursor[#self.cursor + 1] = taken
    self:moved()
end

function Game:moved()
    self.moves = self.moves + 1
    if self.lockAfterMoves and self.moves >= self.lockAfterMoves then
        self.moves = 0
        self.ignoreUntil = self.F.now + self.lockMs
    end
end

function Game:close_kit(pk)
    self.packs[pk].open = false
    for i = #self.bagOrder, 1, -1 do if self.bagOrder[i] == pk then table.remove(self.bagOrder, i) end end
    if self.windows.containercombine_items then self.windows.containercombine_items.open = false end
    if self.windows.tradeskillwnd then self.windows.tradeskillwnd.open = false end
end

-- What a combine hands back, onto the cursor queue. A success: the product (yield) and the returned tools.
-- A failure: the tools (unless failKeepsTools) and any salvage. productLateMs / returnLateMs make them arrive later.
function Game:hand_back(product, failed)
    local g = self
    local function give(name, n, late)
        if late then g.F.at(g.F.now + late, function() g.cursor[#g.cursor + 1] = new_item(name, n) end)
        else g.cursor[#g.cursor + 1] = new_item(name, n) end
    end
    if not failed then give(product, (self.yields or {})[product] or 1, self.productLateMs) end
    if not (failed and self.failKeepsTools) then
        for _, t in ipairs((self.returns or {})[product] or {}) do give(t, 1, self.returnLateMs) end
    end
    if failed then
        for _, t in ipairs((self.salvage or {})[product] or {}) do
            -- salvageHeld: the server still has it in the container until it lands - a combine before then is
            -- refused (2.43.1 log: both refusal spirals)
            if self.salvageHeld and self.salvageLateMs then
                g.serverHolds = (g.serverHolds or 0) + 1
                g.F.at(g.F.now + self.salvageLateMs, function() g.serverHolds = g.serverHolds - 1 end)
            end
            give(t, 1, self.salvageLateMs)
            -- 2.46.3 Vadar log: the late landing set the server resending slot data (said 3x, ~a frame apart)
            if self.salvageLateMs and self.desyncOnLate then
                for k = 1, 3 do
                    g.F.at(g.F.now + self.salvageLateMs + 20 * k, function()
                        g.F.say('Inventory Desyncronization detected: Resending slot data...')
                        -- 2.46.7 log: a resync of the kit's slots shut its own window; the combine window stayed up
                        if g.desyncShutsKit then
                            for _, kp in pairs(g.packs) do if kp.kit and kp.open then kp.open = false end end
                        end
                    end)
                end
            end
        end
        for _, t in ipairs((self.failBack or {})[product] or {}) do give(t, 1, self.returnLateMs) end
    else
        for _, t in ipairs((self.alsoMade or {})[product] or {}) do give(t, 1, self.returnLateMs) end
    end
end

function Game:autoinventory()
    if self.autoinvBlocked then return end   -- only when a test asks; not assumed of any window
    local c = self.cursor[1]
    if not c then return end
    local a = self.worn and self.worn.ammo                -- a stack of it worn in Ammo is topped up first (throwing items)
    if a and a.name == c.name then a.stack = a.stack + c.stack; table.remove(self.cursor, 1); self:moved(); return end
    -- wearable: the client puts it on an empty slot of its kind first (2.43.7 log: a Veil, a Necklace, a Tiara)
    local slot = (self.wearable or {})[c.name:lower()]
    if slot then
        self.worn = self.worn or {}
        if not self.worn[slot] then self.worn[slot] = table.remove(self.cursor, 1); self:moved(); return end
    end
    local stacks = not (self.noStack or {})[c.name:lower()]
    for _, p in pairs(self.packs) do                     -- top up an existing stack first (one that stacks)
        if stacks and p.bag and not p.kit then for _, it in pairs(p.items) do
            if it.name == c.name then it.stack = it.stack + c.stack; table.remove(self.cursor, 1); self:moved(); return end
        end end
    end
    for pk = 1, 10 do
        local p = self.packs[pk]
        if p and p.bag and not p.kit and not (p.tsOnly and not c.ts) then for i = 1, p.slots do
            if not p.items[i] then p.items[i] = c; table.remove(self.cursor, 1); self:moved(); return end
        end end
    end
end

function Game:command(s)
    self.log[#self.log + 1] = s
    local g = self
    if s == '/autoinventory' then
        if (g.autoinvIgnores or 0) > 0 then g.autoinvIgnores = g.autoinvIgnores - 1; return end   -- lost (as seen in game)
        return self:later(function() g:autoinventory() end)
    end
    if s == '/destroy' then return self:later(function() if g.cursor[1] then table.remove(g.cursor, 1); g.destroyed = (g.destroyed or 0) + 1 end end) end
    local navId, navDist = s:match('^/nav id (%d+) distance=(%d+)$')
    if navId then
        if not g.meshLoaded or g.gameState ~= 'INGAME' then return end   -- no navmesh yet: nav does nothing
        if g.navIgnores > 0 then g.navIgnores = g.navIgnores - 1; return end
        navId = tonumber(navId)
        if not g.spawns[navId] or g.noPath[navId] then return end
        g.nav = { active = true, id = navId, dist = tonumber(navDist), short = g.navStopsShortBy }
        g.navStopsShortBy = 0
        return
    end
    local ly, lx, lz, ld = s:match('^/nav loc (%S+) (%S+) (%S+) distance=(%d+)$')
    if ly then
        if not g.meshLoaded or g.gameState ~= 'INGAME' then return end
        g.nav = { active = true, loc = { y = tonumber(ly), x = tonumber(lx), z = tonumber(lz) }, dist = tonumber(ld), short = 0 }
        return
    end
    if s == '/nav stop' then g.nav.active = false; return end
    -- /useitem "X" (2.46.0): a clicky with a spell (g.itemSpells) - used up, its buff on, its cooldown started
    local useName = s:match('^/useitem "(.-)"$')
    if useName then
        g.used = g.used or {}
        g.used[#g.used + 1] = useName
        local sp = (g.itemSpells or {})[useName]
        local t = (g.itemTimers or {})[useName:lower()]
        if sp and g:count(useName) > 0 and not (t and t > g.F.now) then
            g:use(useName, 1)
            g.buffs = g.buffs or {}
            g.buffs[sp] = true
            g.itemTimers = g.itemTimers or {}
            g.itemTimers[useName:lower()] = g.F.now + (g.itemCooldownMs or 60000)
        end
        return
    end
    local itName = s:match('^/itemtarget "(.-)"$')
    if itName then
        local best
        for _, gr in ipairs(g.grounds) do
            if gr.name:lower() == itName:lower() and (not best or g:dist(gr) < g:dist(best)) then best = gr end
        end
        g.itemTarget = best
        return
    end
    if s == '/click left item' then
        local t = g.itemTarget
        if not t or g:dist(t) > 30 then return end
        if g.stationIgnores > 0 then g.stationIgnores = g.stationIgnores - 1; return end
        local wasOpen = (g.windows.containercombine_items or {}).open or (g.windows.tradeskillwnd or {}).open
        g.F.at(g.F.now + g.stationMs, function()
            if wasOpen then return end   -- clicking an open station does not close it (seen in game)
            if g.stationInUse or t.inUse then return g.F.say('Someone else is using that. Please wait.') end
            if t.inUseOnce then t.inUseOnce = nil; return g.F.say('Someone else is using that. Please wait.') end   -- a stale one
            g.atStation = true
            if g.stationOpensTradeskill then g.windows.tradeskillwnd = { open = true }
            else g.windows.containercombine_items = { open = true } end
        end)
        return
    end
    local ev = tonumber(s:match('^/nomodkey /itemnotify enviro(%d+) leftmouseup$') or '')
    if ev then
        if not (g.windows.containercombine_items or {}).open then return end
        if g.lostClicks > 0 then g.lostClicks = g.lostClicks - 1; return end
        if g.cursor[1] and not g.enviro[ev] and (g.enviroCursorLag or 0) > 0 then
            -- 2.35.1 log: the slot shows the item while the cursor still shows it too, for a moment
            local lag = g.enviroCursorLag; g.enviroCursorLag = 0
            g.enviro[ev] = g.cursor[1]
            g.F.at(g.F.now + lag, function() table.remove(g.cursor, 1) end)
        elseif g.cursor[1] and not g.enviro[ev] then g.enviro[ev] = table.remove(g.cursor, 1)
        elseif not g.cursor[1] and g.enviro[ev] then g.cursor[1] = g.enviro[ev]; g.enviro[ev] = nil end
        return
    end
    if (s == '/combine enviro' or s:match('^/combine pack%d+$')) and (g.combineIgnores or 0) > 0 then
        g.combineIgnores = g.combineIgnores - 1; return                  -- lost (as seen in game)
    end
    if s == '/combine enviro' then
        if not (g.windows.containercombine_items or {}).open then
            return g.F.say('You cannot combine these items in this container type!')
        end
        g.F.at(g.F.now + g.combineMs, function()
            if (g.serverHolds or 0) > 0 then return g.F.say('You cannot combine these items in this container type!') end
            if g.serverLosesSlot then
                -- 2.35.4 log: the client showed the slot full; the server did not have it - refused, slot empty after
                local slot = g.serverLosesSlot; g.serverLosesSlot = nil
                local it = g.enviro[slot]; g.enviro[slot] = nil
                if it then g.cursor[#g.cursor + 1] = it; g:autoinventory() end
                return g.F.say('You cannot combine these items in this container type!')
            end
            local have = {}
            for i = 1, 10 do local it = g.enviro[i]; if it then have[#have + 1] = it.name:lower() end end
            table.sort(have)
            for product, ings in pairs(g.recipes) do
                local want = {}
                for _, x in ipairs(ings) do want[#want + 1] = x:lower() end
                table.sort(want)
                if table.concat(want, '|') == table.concat(have, '|') then
                    g.enviro = {}
                    if g.consumeBuff and (g.buffs or {})[g.consumeBuff] then
                        g.protected = (g.protected or 0) + 1
                        g.buffs[g.consumeBuff] = nil
                    end
                    if g.combineFails > 0 then
                        g.combineFails = g.combineFails - 1
                        g:hand_back(product, true)
                        return g.F.say('You lacked the skills to fashion the items together.')
                    end
                    g:hand_back(product)
                    local sk = (g.skillUps or {})[product]
                    g.successes = (g.successes or 0) + 1
                    if sk and g.successes % (g.skillUpEvery or 1) == 0 then g.skills[sk] = (g.skills[sk] or 0) + 1 end
                    local line = 'You have fashioned the items together to create something new: ' .. product .. '.'
                    if (g.lostMessages or 0) > 0 then   -- 2.46.3 logs: the product handed back, the message never came
                        g.lostMessages = g.lostMessages - 1
                        return
                    end
                    if g.lateMessageMs then   -- 2.42.15 log: container empty, product on the cursor, the message late
                        local d = g.lateMessageMs; g.lateMessageMs = nil
                        return g.F.at(g.F.now + d, function() g.F.say(line) end)
                    end
                    return g.F.say(line)
                end
            end
            g.F.say('You cannot combine these items in this container type!')
        end)
        return
    end
    local aaName = s:match('^/aa act (.+)$')
    if aaName then
        local a = g.aa[aaName:lower()]
        if not a or not a.ready or g.casting or g.nav.active or g.gameState ~= 'INGAME' then return end
        if g.aaIgnores > 0 then g.aaIgnores = g.aaIgnores - 1; return end
        local c = { name = aaName }
        g.casting = c
        g.F.at(g.F.now + (a.castMs or 5000), function()
            if g.casting ~= c then return end                -- interrupted
            g.casting = nil
            if g.interruptNext > 0 then
                g.interruptNext = g.interruptNext - 1
                return g.F.say('Your spell is interrupted.')
            end
            a.ready = false
            if a.cooldownMs then g.F.at(g.F.now + a.cooldownMs, function() a.ready = true end) end
            g:start_zone(a.to)
        end)
        return
    end
    local mg, ms = s:match('^/memspell (%d+) "(.+)"$')
    if mg then
        if not g.book[ms:lower()] then return end
        g.F.at(g.F.now + g.memMs, function() g.gems[tonumber(mg)] = ms end)
        return
    end
    if s == '/stopcast' then if g.casting and not g.castWontStop then g.casting = nil end; return end
    if s == '/sit' then g.sitting = true; return end
    if s == '/stand' then g.sitting = false; return end
    local cg = tonumber(s:match('^/cast (%d+)$') or '')
    if cg then
        local spell = g.gems[cg]
        if not spell or g.casting or g.nav.active or g.sitting or g.mana < g.manaCost then return end
        if g.F.now < (g.readyAt[spell:lower()] or 0) then return end
        local pr = g.produce[spell:lower()]
        if pr then
            for _, r in ipairs(pr.reagents) do
                if g:count(r[1]) < r[2] then return g.F.say('You are missing some required components.') end
            end
        end
        local c = { spell = spell }
        g.casting = c
        g.F.at(g.F.now + g.castMs, function()
            if g.casting ~= c then return end                -- interrupted
            g.casting = nil
            g.readyAt[spell:lower()] = g.F.now + g.recastMs
            g.mana = g.mana - g.manaCost
            if g.fizzleNext > 0 then g.fizzleNext = g.fizzleNext - 1; return g.F.say('Your spell fizzles!') end
            if pr then
                for _, r in ipairs(pr.reagents) do g:use(r[1], r[2]) end
                if (g.noStack or {})[pr.product:lower()] then   -- a product that does not stack lands one by one
                    for _ = 1, pr.yield do g.cursor[#g.cursor + 1] = new_item(pr.product, 1) end
                else
                    g.cursor[#g.cursor + 1] = new_item(pr.product, pr.yield)
                end
            end
        end)
        return
    end
    local kw = s:match('^/say (.+)$')
    if kw then
        local sp = g.spawns[g.targetId]
        local to = sp and sp.ports and sp.ports[kw:lower()]
        if not to or g:dist(sp) > 20 or g.gameState ~= 'INGAME' then return end
        if g.sayIgnores > 0 then g.sayIgnores = g.sayIgnores - 1; return end
        if g.targetSettleMs and g.F.now - (g.targetAt or -1e9) < g.targetSettleMs then return end   -- the server has not got the target yet
        g.F.at(g.F.now + g.portMs, function() g:start_zone(to) end)
        return
    end
    if s == '/consider' then
        local sp = g.spawns[g.targetId]
        if not sp or g.gameState ~= 'INGAME' then return end
        if (g.conIgnores or 0) > 0 then g.conIgnores = g.conIgnores - 1; return end
        local LINE = { ally = 'regards you as an ally', warmly = 'looks upon you warmly', kindly = 'kindly considers you',
            amiably = 'judges you amiably', indifferently = 'regards you indifferently', apprehensively = 'looks your way apprehensively',
            dubiously = 'glowers at you dubiously', threateningly = 'glares at you threateningly', ['ready to attack'] = 'scowls at you, ready to attack' }
        g.conned = (g.conned or 0) + 1
        return g:later(function() g.F.say(sp.name .. ' ' .. LINE[sp.standing or 'indifferently'] .. ' -- what would you like your tombstone to say?') end)
    end
    local dname = s:match('^/doortarget (.+)$')
    if dname then
        for _, d in ipairs(g.doors) do if d.name:lower() == dname:lower() then g.doorTarget = d end end
        return
    end
    if s == '/click left door' then
        local d = g.doorTarget
        if not d or g:dist(d) > 20 or g.gameState ~= 'INGAME' then return end
        if g.doorIgnores > 0 then g.doorIgnores = g.doorIgnores - 1; return end
        g.F.at(g.F.now + g.portMs, function() g:start_zone(d.to) end)
        return
    end
    if s == '/notify TargetWindow Target_HP leftmouseup' or s == '/click left target' then
        if s:find('Target_HP', 1, true) and g.dropIgnores > 0 then g.dropIgnores = g.dropIgnores - 1; return end
        if (g.cursorPP or 0) > 0 then   -- coins onto the target
            local sp = g.spawns[g.targetId]
            if not (sp and sp.class == 'PC' and g:dist(sp) <= g.tradeRange) then return end
            g.trade = g.trade or { mine = {}, theirs = {} }
            g.trade.myPP = (g.trade.myPP or 0) + g.cursorPP; g.cursorPP = 0
            g.trade.myOk, g.trade.theirOk = false, false
            g:window('TradeWnd', true)
            return
        end
        local c, sp = g.cursor[1], g.spawns[g.targetId]
        if not (c and sp and sp.class == 'PC' and g:dist(sp) <= g.tradeRange) then return end
        g.trade = g.trade or { mine = {}, theirs = {} }
        if #g.trade.mine >= 8 then return end
        g.trade.mine[#g.trade.mine + 1] = table.remove(g.cursor, 1)
        g.trade.myOk, g.trade.theirOk = false, false   -- a change takes back both accepts
        g:window('TradeWnd', true)
        return
    end
    if s == '/notify TradeWnd TRDW_Trade_Button leftmouseup' then
        if g.trade and (g.windows.tradewnd or {}).open then
            g.trade.myOk = true; g:trade_check()
            if g.partnerAcceptsMs and g.trade then g.F.at(g.F.now + g.partnerAcceptsMs, function() g:partner_accepts() end) end
        end
        return
    end
    if s == '/notify TradeWnd TRDW_Cancel_Button leftmouseup' then
        if g.trade then
            for _, it in ipairs(g.trade.mine) do g:give(it.name, it.stack) end
            g.coin.pp = g.coin.pp + (g.trade.myPP or 0)
        end
        g.trade = nil
        g:window('TradeWnd', false)
        return
    end
    local tid = s:match('^/target id (%d+)$')
    if tid then
        tid = tonumber(tid)
        if g.spawns[tid] then g.targetId = tid; g.targetAt = g.F.now end
        return
    end
    if s == '/nomodkey /notify MerchantWnd MW_UsableButton leftmouseup' then
        if (g.windows.merchantwnd or {}).open then g.usableOnly = not g.usableOnly end
        return
    end
    local selName = s:match('^/invoke %${Merchant%.SelectItem%[=(.-)%]}$')
    if selName then
        -- with the filter on, tradeskill items are hidden from the list and cannot be selected
        if g:merchant_sells(selName) and not g.usableOnly then g.sel = { kind = 'merchant', name = selName } end
        return
    end
    local bagName = s:match('^/selectitem "=(.-)"$')
    if bagName then
        if not (g.windows.merchantwnd or {}).open then return end
        for pk = 1, 10 do
            local p = g.packs[pk]
            if p and p.bag then for i = 1, p.slots do
                local it = p.items[i]
                if it and it.name:lower() == bagName:lower() then g.sel = { kind = 'bag', name = it.name, pack = pk, slot = i }; return end
            end end
        end
        return
    end
    local buyN = tonumber(s:match('^/invoke %${Merchant%.Buy%[(%d+)%]}$') or '')
    if buyN then
        if g.buyIgnores > 0 then g.buyIgnores = g.buyIgnores - 1; return end
        local sel = g.sel
        if not (sel and sel.kind == 'merchant') then return end
        if (g.noStack or {})[sel.name:lower()] then buyN = 1 end             -- a non-stacking item comes one per buy
        if buyN > (g.stackSize or 1000) then buyN = g.stackSize end
        g.F.at(g.F.now + g.tradeMs, function()
            if (g.noStack or {})[sel.name:lower()] then
                for pk = 1, 10 do local p = g.packs[pk]
                    if p and p.bag and not p.kit then for i = 1, p.slots do
                        if not p.items[i] then p.items[i] = new_item(sel.name, 1); return end
                    end end
                end
                return
            end
            g:give(sel.name, buyN)
        end)
        return
    end
    local sellN = tonumber(s:match('^/invoke %${Merchant%.Sell%[(%d+)%]}$') or '')
    if sellN then
        local sel = g.sel
        if not (sel and sel.kind == 'bag') then return end
        g.F.at(g.F.now + g.tradeMs, function()
            local p = g.packs[sel.pack]; local it = p and p.items[sel.slot]
            if not it then return end
            if (g.noValue or {})[it.name] then return end   -- the merchant will not buy it
            it.stack = it.stack - math.min(sellN, it.stack)
            if it.stack <= 0 then p.items[sel.slot] = nil; g.sel = nil end
        end)
        return
    end
    if s == '/click right target' then
        local sp = g.spawns[g.targetId]
        if not sp or sp.class ~= 'Banker' or g:dist(sp) > 20 then return end
        g.F.at(g.F.now + g.bankMs, function() g.windows.bigbankwnd = { open = true } end)
        return
    end
    if s == '/notify BigBankWnd DoneButton leftmouseup' then
        if g.windows.bigbankwnd then g.windows.bigbankwnd.open = false end
        for _, b in pairs(g.bank) do if b.bag then b.open = false end end
        return
    end
    local bb, bs = s:match('^/nomodkey /itemnotify in bank(%d+) (%d+) leftmouseup$')
    if bb then
        bb, bs = tonumber(bb), tonumber(bs)
        if not (g.windows.bigbankwnd or {}).open then return end
        local p = g.bank[bb]
        if not (p and p.bag) then return end
        local it = p.items[bs]
        if g.cursor[1] then
            local c = g.cursor[1]
            local size = (g.noStack or {})[c.name:lower()] and 1 or (g.stackSize or 1000)
            if it and it.name == c.name and size > 1 then   -- the same item tops up the stack; what does not fit stays
                local add = math.min(size - it.stack, c.stack)
                it.stack, c.stack = it.stack + add, c.stack - add
                if c.stack <= 0 then table.remove(g.cursor, 1) end
                return
            end
            if (c.size or 1) > (p.sizeCap or 4) then return end   -- too big for this bank bag: stays on the cursor
            table.remove(g.cursor, 1)
            if it then g.cursor[1] = it end           -- dropping onto a different item swaps
            p.items[bs] = c
            return
        end
        if not it then return end
        if p.open and g.bankDeafClicks and g.bankDeafClicks > 0 then g.bankDeafClicks = g.bankDeafClicks - 1; return end
        if it.stack > 1 and p.open and not g.bankNeverSplits then
            g.windows.quantitywnd = { open = true, text = tostring(it.stack), pack = bb, slot = bs, bank = true }
            return
        end
        g:take_from(bb, bs, it.stack, true)   -- from a closed bank bag the whole stack comes up (seen in game)
        return
    end
    if s == '/notify BigBankWnd BIGB_AutoButton leftmouseup' then
        -- Auto Bank: like /autoinventory for the bank - top up stacks of the item, then the first empty slot
        if not (g.windows.bigbankwnd or {}).open or not g.cursor[1] or g.autoBankIgnores then return end
        local c = g.cursor[1]
        if c.bag then return g.F.say('You have no room left in the bank.') end   -- a bag will not go inside a bank bag
        local size = (g.noStack or {})[c.name:lower()] and 1 or (g.stackSize or 1000)
        for b = 1, 24 do local p = g.bank[b]
            if p and p.bag then for _, it in pairs(p.items) do
                if c.stack > 0 and it.name == c.name and size > 1 and it.stack < size then
                    local add = math.min(size - it.stack, c.stack); it.stack, c.stack = it.stack + add, c.stack - add
                end
            end end
        end
        if c.stack > 0 then
            for b = 1, 24 do local p = g.bank[b]
                if p and p.bag then for i = 1, p.slots do
                    if c.stack > 0 and not p.items[i] then p.items[i] = c; table.remove(g.cursor, 1); return end
                end end
            end
            return                                    -- the bank is full: it stays on the cursor
        end
        table.remove(g.cursor, 1)
        return
    end
    -- a click on a top-level bank slot with something on the cursor: into it when it is empty (2.46.2)
    local blc = tonumber(s:match('^/nomodkey /itemnotify bank(%d+) leftmouseup$') or '')
    if blc then
        if (g.windows.bigbankwnd or {}).open and g.cursor[1] and not g.bank[blc] then g.bank[blc] = table.remove(g.cursor, 1) end
        return
    end
    local brc = tonumber(s:match('^/nomodkey /itemnotify bank(%d+) rightmouseup$') or '')
    if brc then
        local p = g.bank[brc]
        if (g.windows.bigbankwnd or {}).open and p and p.bag then p.open = not p.open end
        return
    end
    if s == '/invoke ${Merchant.OpenWindow}' then
        if g.merchantIgnores > 0 then g.merchantIgnores = g.merchantIgnores - 1; return end
        local sp = g.spawns[g.targetId]
        if not sp or sp.class ~= 'Merchant' or g:dist(sp) > 20 then return end
        local openId = g.wrongMerchant or sp.id
        g.F.at(g.F.now + g.merchantMs, function()
            g.windows.merchantwnd = { open = true }
            g.merchant = { id = openId, received = false }
            g.sel = nil
            if g.partialListMs then g.merchant.tailAt = g.F.now + g.listMs + g.partialListMs; g.partialListMs = g.partialListMs2 end
            g.F.at(g.F.now + g.listMs, function() if g.merchant.id == openId then g.merchant.received = true end end)
        end)
        return
    end
    local ctrl = s:find('/ctrlkey', 1, true) ~= nil
    local pk, sl = s:match('/itemnotify in pack(%d+) (%d+) leftmouseup')
    if pk then
        pk, sl = tonumber(pk), tonumber(sl)
        return self:later(function()
            local p = g.packs[pk]; local it = p and p.items[sl]
            if p and p.bag and not p.open then              -- a click into a closed bag just opens it
                p.open = true; g.bagOrder[#g.bagOrder + 1] = pk
                return
            end
            if #g.cursor > 0 and p.bag then
                local cur = g.cursor[1]
                if g.F.now < g.ignoreUntil or p.deaf then return end
                -- a bag with items never goes inside a bag; nothing goes into a bag too small for it
                if cur.bag and next(cur.items) ~= nil then return end
                if (cur.size or 1) > (p.sizeCap or 4) then return end
                if p.tsOnly and not cur.ts then return end   -- a tradeskill-only bag takes tradeskill items only
                table.remove(g.cursor, 1)
                if it then                                          -- a swap: what was there comes to the cursor
                    table.insert(g.cursor, 1, it)
                    if it.bag then it.open = false end
                end
                p.items[sl] = cur
                return
            end
            if not it then return end
            if (g.windows.merchantwnd or {}).open and not ctrl and not g.merchantClickPicksUp then   -- a click selects for sale
                if g.F.now < g.ignoreUntil or p.deaf then return end
                if g.lostClicks > 0 then g.lostClicks = g.lostClicks - 1; return end
                g.sel = { kind = 'bag', name = it.name, pack = pk, slot = sl }
                return
            end
            if g.F.now < g.ignoreUntil then return end   -- locked out after a burst of moves
            if p.deaf then return end                     -- this opening of the bag ignores clicks
            if p.bag and g.F.now - (p.openedAt or -1e9) < g.bagReadyMs then return end   -- click lost
            if g.lostClicks > 0 then g.lostClicks = g.lostClicks - 1; return end
            if ctrl and it.stack > 1 then return g:take_from(pk, sl, 1) end
            if it.stack > 1 and p.open and not g.bankNeverSplits then
                g.windows.quantitywnd = { open = true, text = tostring(it.stack), pack = pk, slot = sl }
                return
            end
            g:take_from(pk, sl, it.stack)
        end)
    end
    if s == '/nomodkey /itemnotify ammo leftmouseup' then
        return self:later(function()
            g.worn = g.worn or {}
            local cur, was = g.cursor[1], g.worn.ammo
            if cur then table.remove(g.cursor, 1); g.worn.ammo = cur else g.worn.ammo = nil end
            if was then table.insert(g.cursor, 1, was) end
            g:moved()
        end)
    end
    local tp = s:match('^/nomodkey /itemnotify pack(%d+) leftmouseup$')
    if tp then
        tp = tonumber(tp)
        return self:later(function()
            local p, cur = g.packs[tp], g.cursor[1]
            local function shut(x)
                if not (x and x.bag) then return end
                x.open = false
                for i = #g.bagOrder, 1, -1 do if g.bagOrder[i] == tp then table.remove(g.bagOrder, i) end end
            end
            if not cur then
                if not p then return end
                shut(p); g.packs[tp] = nil; table.insert(g.cursor, 1, p)
            else
                table.remove(g.cursor, 1)
                g.packs[tp] = cur
                if p then shut(p); table.insert(g.cursor, 1, p) end
            end
            g:moved()
        end)
    end
    local bp = s:match('/itemnotify pack(%d+) rightmouseup')
    if bp then
        bp = tonumber(bp)
        return self:later(function()
            local p = g.packs[bp]
            if not (p and p.bag) then return end
            if g.casting then return end                  -- bags do not open while casting (seen in game)
            if (g.bagClickIgnores or 0) > 0 then g.bagClickIgnores = g.bagClickIgnores - 1; return end   -- lost (2.35.0 log)
            if p.kit then
                if p.open then
                    if not g.kitIgnoresClose then g:close_kit(bp) end
                    return
                end
                p.open = true; g.bagOrder[#g.bagOrder + 1] = bp
                if g.kitOpensTradeskill then g.windows.tradeskillwnd = { open = true }
                else g.windows.containercombine_items = { open = true, pack = bp } end
                return
            end
            p.open = not p.open
            p.openedAt = g.F.now
            if p.open then
                p.deaf = g.deafOpens > 0
                if p.deaf then g.deafOpens = g.deafOpens - 1 end
            end
            for i = #g.bagOrder, 1, -1 do if g.bagOrder[i] == bp then table.remove(g.bagOrder, i) end end
            if p.open then g.bagOrder[#g.bagOrder + 1] = bp end
        end)
    end
    local n = s:match('SetText%[(%d+)%]')
    if n then return self:later(function()
        if g.windows.quantitywnd.open and not g.setTextIgnored then g.windows.quantitywnd.text = n end
    end) end
    if s == '/notify InventoryWindow IW_Money0 leftmouseup' then
        return self:later(function()
            if not (g.windows.inventorywindow or {}).open then return end
            if (g.cursorPP or 0) > 0 then g.coin.pp = g.coin.pp + g.cursorPP; g.cursorPP = 0; return end
            if g.coin.pp > 0 then g.windows.quantitywnd = { open = true, text = tostring(g.coin.pp), money = true } end
        end)
    end
    if s:find('QTYW_Accept_Button', 1, true) then
        return self:later(function()
            local q = g.windows.quantitywnd
            if not q.open then return end
            if q.money then
                local want = math.min(tonumber(q.text) or g.coin.pp, g.coin.pp)
                q.open = false
                g.coin.pp = g.coin.pp - want; g.cursorPP = (g.cursorPP or 0) + want
                return
            end
            local where = q.bank and g.bank or g.packs
            local stack = where[q.pack].items[q.slot].stack
            local want = tonumber(q.text) or stack
            if g.qtyIgnoresText or want >= stack then want = stack end
            q.open = false
            g:take_from(q.pack, q.slot, want, q.bank)
        end)
    end
    if s == '/cleanup' then   -- closes every window and bag; the cursor is untouched
        for _, w in pairs(g.windows) do w.open = false end
        for _, p in pairs(g.packs) do if p.bag then p.open = false end end
        g.bagOrder = {}
        return
    end
    if s == '/nomodkey /notify TradeskillWnd COMBW_ExperimentButton leftmouseup' then
        if (g.windows.tradeskillwnd or {}).open then
            local kp; for pk, p in pairs(g.packs) do if p.kit and p.open then kp = pk end end
            g.windows.containercombine_items = { open = true, pack = kp }
            if not kp then g.atStation = true end   -- a station's Experiment: the tradeskill window stays up
        end
        return
    end
    local cpk = tonumber(s:match('^/combine pack(%d+)$') or '')
    if cpk then
        local p = g.packs[cpk]
        -- MQ's answer when the kit's own window is shut (2.46.7 log: a desync closed Pack10, the combine window stayed)
        if p and p.kit and not p.open then return g.F.say("Window 'pack" .. cpk .. "' not open") end
        if not (p and p.kit and (g.windows.containercombine_items or {}).open) then
            return g.F.say('You cannot combine these items in this container type!')
        end
        g.F.at(g.F.now + g.combineMs, function()
            local have = {}
            for i = 1, p.slots do local it = p.items[i]; if it then have[#have + 1] = it.name:lower() end end
            table.sort(have)
            for product, ings in pairs(g.recipes) do
                local want = {}
                for _, x in ipairs(ings) do want[#want + 1] = x:lower() end
                table.sort(want)
                if table.concat(want, '|') == table.concat(have, '|') then
                    p.items = {}
                    if g.combineFails > 0 then
                        g.combineFails = g.combineFails - 1
                        g:hand_back(product, true)
                        return g.F.say('You lacked the skills to fashion the items together.')
                    end
                    g:hand_back(product)
                    local sk = (g.skillUps or {})[product]
                    g.successes = (g.successes or 0) + 1
                    if sk and g.successes % (g.skillUpEvery or 1) == 0 then g.skills[sk] = (g.skills[sk] or 0) + 1 end
                    return g.F.say('You have fashioned the items together to create something new: ' .. product .. '.')
                end
            end
            g.F.say('You cannot combine these items in this container type!')
        end)
        return
    end
    if s == '/keypress duck' then return self:later(function() g.ducking = not g.ducking end) end
    local hd = s:match('^/face fast heading (%S+)$')
    if hd then g.heading = tonumber(hd); return end
    if s == '/keypress forward hold' then g.running = true; return end
    if s == '/keypress forward' then g.running = false; return end
    -- Esc closes whatever is on top: the split window, then the newest open bag, then the combine window.
    if s == '/keypress esc' then
        return self:later(function()
            local q = g.windows.quantitywnd
            if q.open and not g.stuck.quantitywnd then q.open = false; return end
            if #g.bagOrder > 0 then
                local bp = table.remove(g.bagOrder)
                if g.packs[bp].kit then g:close_kit(bp) else g.packs[bp].open = false end
                return
            end
            local c = g.windows.containercombine_items
            if c and c.open and not g.stuck.containercombine_items and not g.stationIgnoresClose then
                c.open = false; g.atStation = false
            end
        end)
    end
end

return Game
