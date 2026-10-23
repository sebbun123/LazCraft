-- Planner: works out everything a "make" needs before anything happens in game. Pure: no game calls; it
-- reads a `world` table the caller fills in (what is in the bags and bank, which kits are carried, the zone).
--
--   Planner.new(cfg)                          cfg from Config.load (recipes, recipesByName, merchants, containers, travel)
--   planner:find(query)                       recipes matching an id, a label or a product name: { recipe, ... }
--   planner:plan(recipeId, combines, world)   the whole plan (below)
--   planner:plan_item(item, n, world)         a plan to end up holding n of an item (a worker's order): the
--                                             item is found like an ingredient - bags, bank, buy, make, cast.
--                                             Its last step is a "gather" step that does nothing in game.
--   Planner.describe(plan)                    preflight check lines for the window and log
--
-- world = { zone = 'freeporttemple', bags = function(item) -> n, bank = function(item) -> n,
--           kit = function(containerName) -> true if a bag that works as this kit is carried,
--           canCast = function(spell) -> this character has it scribed,
--           worker = function(item) -> name of a worker that can cast it, or nil,
--           requestOver = copper: an item a merchant sells for more than this a unit is asked for on the network
--                         first (nil = never),
--           supply = function(item) -> who on the network holds it (engine/supply's last survey):
--                    { { name, zone, safe, have }, ... }, {} = asked and nobody has any, nil = not asked,
--           barred = function(npc, zone) -> the con word when this character was last too low to buy from that
--                    merchant (core/factions), else nil - such a merchant is never planned,
--           buyer = function(item, vendors) -> name, zone of a worker to buy it when every vendor is barred for us }
--
-- How each ingredient is resolved (the rules we agreed):
--   1. What we have is used first: bags, then the bank. (LazCraft uses our own storage first.)
--   2. Still short and a vendor sells it: buy it. (Never craft what can be bought.)
--   3. Still short and a recipe makes it: a subcombine. With several recipes for it, the one that can be
--      fully supplied with the fewest purchases is picked (then fewest combines, then lowest id).
--   4. Otherwise it is a held item (dropped, foraged...). Still short: someone on the network who holds it
--      in a safe zone (world.supply) is ordered to bring it - one who has it all, in our zone first, else
--      the fewest characters, most first. Not covered that way: the plan BLOCKS, before any bank trip or
--      shopping, naming who has it outside a safe zone.
--   Tools (returned after the combine) are needed once, not per combine, and never consumed from the ledger.
--   "make N" is N combines of the chosen recipe; a subcombine makes ceil(needed / yield) combines.
--   Subcombines run deepest first, grouped by container; all of one before the next.
--   Shopping: everything this zone sells is bought here; what is left is spread over as few other zones as
--   possible, visited in the order with the fewest hops, ending where the crafting can happen.
local Config = require('core.config')

local Planner = {}
Planner.__index = Planner

Planner.MAX_DEPTH = 4

local function lower(s) return (s or ''):lower() end

function Planner.new(cfg)
    local p = setmetatable({ cfg = cfg }, Planner)
    p.stations = {}   -- container name -> set of zones that have one
    for name, c in pairs(cfg.containers or {}) do
        if c.type == 'station' then
            p.stations[name] = {}
            for _, st in ipairs(c.stations) do p.stations[name][st.zone:lower()] = true end
        end
    end
    p.producers = {}  -- lower item -> producers.ini entry
    for item, pr in pairs(cfg.producers or {}) do p.producers[item:lower()] = pr end
    return p
end

function Planner:is_station(container)
    local c = self.cfg.containers[container]
    return c and c.type == 'station'
end

-- Recipes matching an id, an exact label, or an exact product name (case-insensitive).
function Planner:find(query)
    local q = lower(query)
    for id, r in pairs(self.cfg.recipes) do if lower(id) == q then return { r } end end
    local out = {}
    for _, r in pairs(self.cfg.recipes) do if lower(r.label) == q and r.label ~= r.name then out[#out + 1] = r end end
    if #out > 0 then return out end
    for _, id in ipairs(self.cfg.recipesByName[q] or {}) do out[#out + 1] = self.cfg.recipes[id] end
    return out
end

function Planner:vendors(item) return self.cfg.merchants[lower(item)] or {} end

-- The ledger: how much of each item is still unclaimed in the bags and the bank, so two branches of the tree
-- never count the same stack twice.
local function new_ledger(world)
    local L = { bags = {}, bank = {}, tools = {}, held = {}, world = world }
    function L.take(item, n)
        local k = lower(item)
        if L.bags[k] == nil then L.bags[k] = world.bags(item) or 0 end
        if L.bank[k] == nil then L.bank[k] = world.bank(item) or 0 end
        local a = math.min(n, L.bags[k]); L.bags[k] = L.bags[k] - a
        local b = math.min(n - a, L.bank[k]); L.bank[k] = L.bank[k] - b
        return a, b
    end
    function L.copy()
        local c = new_ledger(world)
        for k, v in pairs(L.bags) do c.bags[k] = v end
        for k, v in pairs(L.bank) do c.bank[k] = v end
        for k, v in pairs(L.tools) do c.tools[k] = v end
        for k, v in pairs(L.held) do c.held[k] = {}; for n, u in pairs(v) do c.held[k][n] = u end end
        return c
    end
    return L
end

-- Resolve `need` of `item`. Returns a node:
--   { item, need, bags, bank, buy = n, vendors = {...}, make = { recipe, combines, children }, short = n, note }
function Planner:resolve(item, need, ledger, depth, path)
    local node = { item = item, need = need }
    node.bags, node.bank = ledger.take(item, need)
    local left = need - node.bags - node.bank
    if left <= 0 then return node end
    local vendors = self:vendors(item)
    -- a faction-zone merchant this character was last too low with (world.barred, core/factions) is left out
    if #vendors > 0 and ledger.world.barred then
        local ok = {}
        for _, v in ipairs(vendors) do
            local w = ledger.world.barred(v.npc, v.zone)
            if w then
                node.barred = node.barred or {}
                node.barred[#node.barred + 1] = string.format('%s (%s) %s', v.npc, v.zone, w)
            else ok[#ok + 1] = v end
        end
        vendors = ok
        -- every merchant for it is one we are too low with: a worker with the faction (or not conned there yet)
        -- buys it and brings it (world.buyer, 2.42.4) - a supply order like a holder's
        local buyer, bz = nil, nil
        if #vendors == 0 and node.barred and ledger.world.buyer and depth < Planner.MAX_DEPTH then
            buyer, bz = ledger.world.buyer(item, self:vendors(item))
        end
        if buyer then
            node.supply = { { worker = buyer, n = left, zone = bz, depth = depth + 1, supply = true, buy = true } }
            node.buyFor = true
            return node
        end
        node.noBuyer = #vendors == 0 and node.barred and ledger.world.buyer ~= nil
    end
    if #vendors > 0 then
        -- dear (over world.requestOver a unit): someone on the network who has it in a safe zone brings what
        -- they can first; the rest is bought
        local price = self:unit_price(item, vendors)
        if ledger.world.supply and ledger.world.requestOver and price and price > ledger.world.requestOver then
            node.pricey = price
            local got = self:supply_from(item, left, ledger, depth, true)
            node.surveyed = got.surveyed
            if #got.orders > 0 then node.supply = got.orders; left = left - got.n end
            if left <= 0 then return node end
        end
        node.buy, node.vendors = left, vendors
        return node
    end
    local ids = self.cfg.recipesByName[lower(item)] or {}
    local best, bestScore, bestLedger
    if #ids > 0 and depth < Planner.MAX_DEPTH and not path[lower(item)] then
        for _, id in ipairs(ids) do
            local trial = ledger.copy()
            local sub = self:make_node(self.cfg.recipes[id], math.ceil(left / self.cfg.recipes[id].yield), trial, depth + 1, path)
            local s = Planner.score(sub)
            if not best or s.short < bestScore.short or (s.short == bestScore.short and (s.buy < bestScore.buy
                or (s.buy == bestScore.buy and s.combines < bestScore.combines))) then
                best, bestScore, bestLedger = sub, s, trial
            end
        end
    end
    -- a cast (producers.ini) when this character has one of its spells: after a subcombine that is fully supplied
    local pr = self.producers[lower(item)]
    local mine = {}   -- the spells for it this character has scribed, biggest first
    if pr and ledger.world.canCast then
        for _, t in ipairs(pr.spells or { pr }) do if ledger.world.canCast(t.spell) then mine[#mine + 1] = t end end
    end
    local castable = #mine > 0 and depth < Planner.MAX_DEPTH and not path[lower(item)]
    -- nobody here has the spell: a worker that does casts it and brings exactly what is needed
    local worker = pr and not castable and depth < Planner.MAX_DEPTH and not path[lower(item)]
        and ledger.world.worker and ledger.world.worker(pr.item)
    if worker and not (best and bestScore.short == 0) then
        node.order = { worker = worker, n = left, producer = pr, depth = depth + 1 }
        return node
    end
    if castable and not (best and bestScore.short == 0) then
        local trial = ledger.copy()
        local c = self:cast_node(item, pr, mine, left, trial, depth, path)
        local s = Planner.score({ children = c.children, tools = {}, combines = 0 })
        if not best or s.short <= bestScore.short then
            for k, v in pairs(trial.bags) do ledger.bags[k] = v end
            for k, v in pairs(trial.bank) do ledger.bank[k] = v end
            for k, v in pairs(trial.tools) do ledger.tools[k] = v end
            for k, v in pairs(trial.held) do ledger.held[k] = v end
            node.cast = c
            return node
        end
    end
    if best then
        for k, v in pairs(bestLedger.bags) do ledger.bags[k] = v end
        for k, v in pairs(bestLedger.bank) do ledger.bank[k] = v end
        for k, v in pairs(bestLedger.tools) do ledger.tools[k] = v end
        for k, v in pairs(bestLedger.held) do ledger.held[k] = v end
        node.make = best
        node.variants = #ids
        return node
    end
    -- someone on the network holds it: ordered from them (a supply survey found them)
    if ledger.world.supply and not (best and bestScore.short == 0) then
        local got = self:supply_from(item, left, ledger, depth)
        node.surveyed = got.surveyed
        node.outside = got.outside
        node.noAnswer = ledger.world.noAnswer and ledger.world.noAnswer(item) or nil
        if #got.orders > 0 and got.n >= left then
            node.supply = got.orders
            return node
        end
        node.inSafe = got.n
    end
    node.short = left
    if #ids > 0 and path[lower(item)] then node.note = 'made from itself (a loop in the recipes)'
    elseif #ids > 0 then node.note = 'subcombines nest deeper than ' .. Planner.MAX_DEPTH
    elseif pr then
        -- 2.41.9: who could - start one with the spell scribed (Workers tab); world.worker already tried every
        -- running caster and every remembered one in a safe zone
        local cls = #(pr.classes or {}) > 0 and table.concat(pr.classes, ', ') or 'a caster'
        node.note = string.format('made by casting %s%s - nobody running has it scribed: start a %s with it (Workers tab)', pr.spell,
            #(pr.spells or {}) > 1 and ' (or a smaller version)' or '', cls)
    end
    return node
end

-- What the network survey found for a short item, for its problem line ('' when nobody was asked).
function Planner.network_words(node)
    if not node.surveyed then return '' end
    local parts = {}
    if (node.inSafe or 0) > 0 then parts[#parts + 1] = string.format('only %d on characters in a safe zone', node.inSafe) end
    for _, h in ipairs(node.outside or {}) do
        parts[#parts + 1] = string.format('%s has %d but is in %s, not a safe zone', h.name, h.have, h.zone or 'an unknown zone')
    end
    if node.noAnswer then
        parts[#parts + 1] = 'no answer about it from ' .. table.concat(node.noAnswer, ', ')
    end
    if #parts == 0 then return '; nobody on the network has any' end
    return '; network: ' .. table.concat(parts, ', ')
end

-- Who brings `need` of a held item: from world.supply's survey, less what this plan already ordered from
-- them. One character who has it all (already our worker first, then in our zone, then the most held, then by
-- name); else the most first until covered. Only characters in a safe zone count; the rest are named in the problem.
-- -> { orders = { { worker, n, zone, depth } }, n = covered, outside = { holders not in a safe zone }, surveyed }
-- Alla's price for one (the cheapest merchant that sells it, else the item's value); nil = not known.
function Planner:unit_price(item, vendors)
    local best
    for _, v in ipairs(vendors or self:vendors(item)) do
        if v.price and (not best or v.price < best) then best = v.price end
    end
    if best then return best end
    local it = self.cfg.items and self.cfg.items[lower(item)]
    return it and it.value or nil
end

function Planner:supply_from(item, need, ledger, depth, partial)
    local out = { orders = {}, n = 0, outside = {} }
    local list = ledger.world.supply(item)
    if not list then return out end
    out.surveyed = true
    local k = lower(item)
    ledger.held[k] = ledger.held[k] or {}
    local used = ledger.held[k]
    local avail = {}
    for _, h in ipairs(list) do
        local left = (h.have or 0) - (used[lower(h.name)] or 0)
        if left > 0 then
            if h.safe then avail[#avail + 1] = { h = h, n = left } else out.outside[#out.outside + 1] = h end
        end
    end
    local here = lower(ledger.world.zone)
    -- already working for us first (nothing to start: 2.39.0 log, a holder that never came up cost two rows),
    -- then in our zone, then the most held
    table.sort(avail, function(a, b)
        if (a.h.running == true) ~= (b.h.running == true) then return a.h.running == true end
        local ah, bh = lower(a.h.zone) == here, lower(b.h.zone) == here
        if ah ~= bh then return ah end
        if a.n ~= b.n then return a.n > b.n end
        return lower(a.h.name) < lower(b.h.name)
    end)
    local pick
    for _, a in ipairs(avail) do if a.n >= need then pick = a; break end end
    local chosen = pick and { pick } or {}
    if not pick then
        table.sort(avail, function(a, b)
            if (a.h.running == true) ~= (b.h.running == true) then return a.h.running == true end
            if a.n ~= b.n then return a.n > b.n end
            return lower(a.h.name) < lower(b.h.name)
        end)
        chosen = avail
    end
    local left = need
    for _, a in ipairs(chosen) do
        if left <= 0 then break end
        local n = math.min(a.n, left)
        out.orders[#out.orders + 1] = { worker = a.h.name, n = n, zone = a.h.zone, depth = depth + 1, supply = true }
        left, out.n = left - n, out.n + n
    end
    if out.n >= need or partial then
        for _, o in ipairs(out.orders) do used[lower(o.worker)] = (used[lower(o.worker)] or 0) + o.n end
    end
    return out
end

-- `left` of an item made by casting with the spells this character has (biggest first): as many of the
-- biggest as fit without making more than needed, then the next, the smallest covering the rest - so
-- 30 with 20/5/1 is 1 x 20 + 2 x 5, and only a lone 100 makes extra. Reagents are used in full per cast.
function Planner:cast_node(item, pr, spells, left, ledger, depth, path)
    local c = { producer = pr, parts = {}, casts = 0, made = 0, children = {}, depth = depth + 1 }
    local rem = left
    for i, t in ipairs(spells) do
        local n = (i < #spells) and math.floor(rem / t.yield) or math.ceil(rem / t.yield)
        if n > 0 then
            c.parts[#c.parts + 1] = { item = pr.item, spell = t.spell, yield = t.yield, reagents = t.reagents, casts = n }
            rem, c.casts, c.made = rem - n * t.yield, c.casts + n, c.made + n * t.yield
        end
    end
    local here = {}
    for k, v in pairs(path) do here[k] = v end
    here[lower(item)] = true
    local need, order = {}, {}
    for _, part in ipairs(c.parts) do
        for _, r in ipairs(part.reagents) do
            if not need[r.name] then need[r.name] = 0; order[#order + 1] = r.name end
            need[r.name] = need[r.name] + r.count * part.casts
        end
    end
    for _, name in ipairs(order) do
        c.children[#c.children + 1] = self:resolve(name, need[name], ledger, depth + 1, here)
    end
    return c
end

-- A recipe made `combines` times: its ingredients (x combines) and tools (once each).
function Planner:make_node(recipe, combines, ledger, depth, path)
    local m = { recipe = recipe, combines = combines, children = {}, tools = {}, depth = depth }
    local here = {}
    for k, v in pairs(path) do here[k] = v end
    if not recipe.gather then here[lower(recipe.name)] = true end   -- gathering an item is not making it from itself
    for _, ing in ipairs(recipe.ins) do
        m.children[#m.children + 1] = self:resolve(ing.name, ing.n * combines, ledger, depth, here)
    end
    for _, t in ipairs(recipe.tools) do
        -- A tool comes back after every combine, so a plan needs it once, however many steps use it. It is
        -- found like an ingredient (bags, then a bank pull, then buy, then make) - a tool in the bank has to
        -- be pulled like anything else (2.06.3: a File in the bank was counted as on hand, and Studs ran out).
        local k = lower(t.name)
        local secured = ledger.tools[k] or 0
        if secured >= t.n then
            m.tools[#m.tools + 1] = { item = t.name, need = t.n, have = secured, shared = true }
        else
            local node = self:resolve(t.name, t.n - secured, ledger, depth, here)
            ledger.tools[k] = t.n
            if (node.bags or 0) >= node.need then
                m.tools[#m.tools + 1] = { item = t.name, need = t.n, have = node.bags + secured }
            else
                node.tool = true
                m.tools[#m.tools + 1] = node
            end
        end
    end
    return m
end

-- Totals under a make node: short units, bought units, combines.
function Planner.score(make)
    local s = { short = 0, buy = 0, combines = make.combines }
    local function walk(node)
        s.short = s.short + (node.short or 0)
        s.buy = s.buy + (node.buy or 0)
        if node.make then
            local sub = Planner.score(node.make)
            s.short, s.buy, s.combines = s.short + sub.short, s.buy + sub.buy, s.combines + sub.combines
        end
        if node.cast then for _, c in ipairs(node.cast.children) do walk(c) end end
    end
    for _, c in ipairs(make.children) do walk(c) end
    for _, t in ipairs(make.tools) do if t.item and t.need and not t.have then walk(t) end end
    return s
end

-- Shortest hop count between zones over travel.ini (a * hop works from anywhere).
function Planner:hops(from, to)
    self.hopMemo = self.hopMemo or {}
    local k = from .. '>' .. to
    local h = self.hopMemo[k]
    if h == nil then
        local path = Config.travel_path(self.cfg.travel, from, to)
        h = path and #path or false
        self.hopMemo[k] = h
    end
    return h or nil
end

local function permutations(list)
    if #list <= 1 then return { list } end
    local out = {}
    for i = 1, #list do
        local rest = {}
        for j = 1, #list do if j ~= i then rest[#rest + 1] = list[j] end end
        for _, p in ipairs(permutations(rest)) do
            local full = { list[i] }
            for _, x in ipairs(p) do full[#full + 1] = x end
            out[#out + 1] = full
        end
    end
    return out
end

function Planner:plan(recipeId, combines, world)
    return self:plan_recipe(self.cfg.recipes[recipeId], combines, world, recipeId)
end

function Planner:plan_item(item, n, world)
    local gather = { id = 'get:' .. lower(item), name = item, label = string.format('%d %s', n, item), container = '(gather)',
                     yield = n, ins = { { name = item, n = n } }, tools = {}, gather = true }
    return self:plan_recipe(gather, 1, world, gather.id)
end

-- Getting several items at once (a queue's shopping, engine/make gather_job): one gather "recipe" with all of them.
-- list = { { name, n } }
function Planner:plan_items(list, world)
    local ins, parts = {}, {}
    for _, it in ipairs(list) do
        if (it.n or 0) > 0 then ins[#ins + 1] = { name = it.name, n = it.n }; parts[#parts + 1] = it.n .. ' ' .. it.name end
    end
    local gather = { id = 'get:list', name = 'the list', label = string.format('%d item%s', #ins, #ins == 1 and '' or 's'),
                     container = '(gather)', yield = 1, ins = ins, tools = {}, gather = true }
    return self:plan_recipe(gather, 1, world, gather.id)
end

-- What a list of makes takes from scratch: the raw items at the bottom of each plan (bought, banked or held - not
-- what subcombines make, not what workers bring), added up over the list. Nothing held is counted: the plan of
-- the gathered list (plan_items, with the real bags and bank) decides what comes from where.
-- list = { { recipe, n } } -> { { name, n } } in first-needed order
function Planner:raw_needs(list, world)
    local empty = {}
    for k, v in pairs(world) do empty[k] = v end
    empty.bags = function() return 0 end
    empty.bank = function() return 0 end
    empty.supply, empty.requestOver = nil, nil
    local sum, order = {}, {}
    local function add(item, n)
        local k = lower(item)
        if not sum[k] then sum[k] = { name = item, n = 0 }; order[#order + 1] = k end
        sum[k].n = sum[k].n + n
    end
    local function walk(node)
        if node.order or node.supply then return end            -- a worker brings it
        if node.buy then add(node.item, node.buy) end
        if node.short then add(node.item, node.short) end
        if node.make then for _, c in ipairs(node.make.children) do walk(c) end end
        if node.cast then for _, c in ipairs(node.cast.children) do walk(c) end end
    end
    for _, it in ipairs(list) do
        if (it.n or 0) > 0 then
            local ok, p = pcall(function() return self:plan(it.recipe.id, it.n, empty) end)
            if ok and p and p.tree then for _, c in ipairs(p.tree.children or {}) do walk(c) end end
        end
    end
    local out = {}
    for _, k in ipairs(order) do out[#out + 1] = sum[k] end
    return out
end

function Planner:plan_recipe(recipe, combines, world, recipeId)
    local plan = { problems = {}, warnings = {}, bankPulls = {}, buys = {}, steps = {}, route = {}, orders = {} }
    if not recipe then plan.problems[#plan.problems + 1] = 'no recipe ' .. tostring(recipeId); return plan end
    plan.recipe, plan.combines = recipe, combines
    local ledger = new_ledger(world)
    plan.tree = self:make_node(recipe, combines, ledger, 0, {})

    -- Walk the tree: bank pulls, purchases, held shortfalls, subcombine steps.
    local buyItems, steps = {}, {}
    local function walk(node, isTool)
        if (node.bank or 0) > 0 then plan.bankPulls[#plan.bankPulls + 1] = { item = node.item, n = node.bank } end
        if node.buy then buyItems[#buyItems + 1] = { item = node.item, n = node.buy, vendors = node.vendors } end
        if node.short then
            -- anything short can be asked for on the network (engine/supply)
            plan.short = plan.short or {}
            plan.short[#plan.short + 1] = { item = node.item, n = node.short }
            if node.barred then
                plan.problems[#plan.problems + 1] = string.format('%s: short %d - sold only by merchants your faction is too low with: %s (apprehensively or better buys)%s; bags %d, bank %d%s',
                    node.item, node.short, table.concat(node.barred, ', '),
                    node.noBuyer and '; no worker to send - none running or in a safe zone that is not known to be too low there too' or '',
                    node.bags or 0, node.bank or 0, Planner.network_words(node))
            elseif node.note then
                plan.problems[#plan.problems + 1] = string.format('%s: short %d - not sold anywhere we know, not made by a recipe (%s); bags %d, bank %d%s',
                    node.item, node.short, node.note, node.bags or 0, node.bank or 0, Planner.network_words(node))
            else
                -- nobody sells it and nothing makes it: it is farmed (a drop, forage, fishing or a quest)
                local it = self.cfg.items and self.cfg.items[lower(node.item)]
                plan.farm = plan.farm or {}
                plan.farm[#plan.farm + 1] = { item = node.item, n = node.short, id = it and it.id }
                plan.problems[#plan.problems + 1] = string.format('%s: short %d - no merchant sells it and no recipe makes it: farm it (a drop, forage, fishing or a quest%s); bags %d, bank %d%s',
                    node.item, node.short, it and (', Alla item ' .. it.id) or '', node.bags or 0, node.bank or 0, Planner.network_words(node))
            end
        end
        if node.make then
            steps[#steps + 1] = node.make
            for _, c in ipairs(node.make.children) do walk(c) end
            for _, t in ipairs(node.make.tools) do if not t.have then walk(t, true) end end
        end
        if node.pricey then
            plan.pricey = plan.pricey or {}
            plan.pricey[#plan.pricey + 1] = { item = node.item, price = node.pricey }
        end
        if node.supply then
            for _, o in ipairs(node.supply) do
                plan.orders[#plan.orders + 1] = { worker = o.worker, item = node.item, n = o.n, supply = true }
                steps[#steps + 1] = { order = o, combines = o.n, depth = o.depth,
                    recipe = { id = 'order:' .. lower(node.item) .. ':' .. lower(o.worker), name = node.item,
                               label = node.item .. ' from ' .. o.worker, container = '(order)', yield = 1, ins = {}, tools = {} } }
            end
        end
        if node.order then
            local o = node.order
            plan.orders[#plan.orders + 1] = { worker = o.worker, item = node.item, n = o.n }
            steps[#steps + 1] = { order = o, combines = o.n, depth = o.depth,
                recipe = { id = 'order:' .. lower(node.item), name = node.item, label = node.item .. ' from ' .. o.worker,
                           container = '(order)', yield = 1, ins = {}, tools = {} } }
        end
        if node.cast then
            for _, part in ipairs(node.cast.parts) do
                steps[#steps + 1] = { cast = part, combines = part.casts, depth = node.cast.depth,
                    recipe = { id = 'cast:' .. lower(node.item) .. ':' .. lower(part.spell), name = part.item,
                               label = part.item .. ' (cast ' .. part.spell .. ')', container = '(cast)', yield = part.yield,
                               ins = {}, tools = {} } }
            end
            for _, c in ipairs(node.cast.children) do walk(c) end
        end
    end
    for _, c in ipairs(plan.tree.children) do walk(c) end
    for _, t in ipairs(plan.tree.tools) do if not t.have then walk(t, true) end end

    -- One line per item: bank pulls added up, problems said once.
    do
        local sum, order = {}, {}
        for _, b in ipairs(plan.bankPulls) do
            local k = lower(b.item)
            if not sum[k] then sum[k] = { item = b.item, n = 0 }; order[#order + 1] = k end
            sum[k].n = sum[k].n + b.n
        end
        plan.bankPulls = {}
        for _, k in ipairs(order) do plan.bankPulls[#plan.bankPulls + 1] = sum[k] end
    end
    -- The same intermediate needed in two branches is one step: combines added, deepest depth kept.
    local merged, byId = {}, {}
    for _, st in ipairs(steps) do
        local m = byId[st.recipe.id]
        if m then m.combines, m.depth = m.combines + st.combines, math.max(m.depth, st.depth)
        else
            m = { recipe = st.recipe, combines = st.combines, depth = st.depth, cast = st.cast, order = st.order }
            byId[st.recipe.id] = m
            merged[#merged + 1] = m
        end
    end
    steps = merged
    -- Steps: deepest subcombines first, grouped by container, then the recipe itself.
    table.sort(steps, function(a, b)
        if a.depth ~= b.depth then return a.depth > b.depth end
        if a.recipe.container ~= b.recipe.container then return a.recipe.container < b.recipe.container end
        if a.cast and b.cast and a.recipe.name == b.recipe.name then return a.cast.yield > b.cast.yield end   -- biggest spell first
        return a.recipe.id < b.recipe.id
    end)
    steps[#steps + 1] = plan.tree
    plan.steps = steps

    -- Containers: stations decide where crafting can happen. A kit not carried is taken from the bank, else
    -- bought (the first variant in containers.ini's BuyOrder that is sold somewhere travel reaches); it is
    -- kept after the run.
    local craftZones
    local kitDone = {}
    plan.kits = {}
    local function get_kit(c)
        kitDone[c] = true
        local def = self.cfg.containers[c] or {}
        local order, seen = {}, {}
        for _, v in ipairs(def.buyOrder or {}) do order[#order + 1] = v; seen[lower(v)] = true end
        for _, v in ipairs(def.accepts or { c }) do if not seen[lower(v)] then order[#order + 1] = v end end
        for _, v in ipairs(order) do
            if (world.bank(v) or 0) > 0 then
                plan.bankPulls[#plan.bankPulls + 1] = { item = v, n = 1 }
                plan.kits[#plan.kits + 1] = string.format('%s: not carried - taking a %s from the bank', c, v)
                return
            end
        end
        local here0 = lower(world.zone)
        for _, v in ipairs(def.buyOrder or {}) do
            local reach = {}
            for _, vend in ipairs(self:vendors(v)) do
                if self:hops(here0, vend.zone) and not (world.barred and world.barred(vend.npc, vend.zone)) then reach[#reach + 1] = vend end
            end
            if #reach > 0 then
                buyItems[#buyItems + 1] = { item = v, n = 1, vendors = reach }
                plan.kits[#plan.kits + 1] = string.format('%s: not carried - buying a %s', c, v)
                return
            end
        end
        plan.problems[#plan.problems + 1] = string.format('%s: not carried, not in the bank, and no vendor we can reach sells one%s', c,
            #(def.buyOrder or {}) > 0 and (' (' .. table.concat(def.buyOrder, ', ') .. ')') or ' (none to buy)')
    end
    for _, st in ipairs(steps) do
        local c = st.recipe.container
        if st.cast or st.order or st.recipe.gather then
            -- made by casting, brought by a worker, or just gathering: no container
        elseif self:is_station(c) then
            local zones = self.stations[c] or {}
            if not next(zones) then plan.problems[#plan.problems + 1] = c .. ': no station location known (containers.ini)' end
            -- zones that have every station the plan uses
            if craftZones == nil then craftZones = {}; for z in pairs(zones) do craftZones[z] = true end
            else for z in pairs(craftZones) do if not zones[z] then craftZones[z] = nil end end end
        elseif not kitDone[c] and not (world.kit and world.kit(c)) then
            get_kit(c)
        end
    end
    if craftZones and not next(craftZones) then
        plan.problems[#plan.problems + 1] = 'no single zone has every station this plan needs'
        craftZones = nil
    end

    -- Shopping and route, chosen together: the fewest zone changes first (here -> the shopping zones -> a
    -- zone with the stations), then the fewest merchant stops. Staying put costs no hops, so a zone that sells
    -- everything (and has the stations) keeps us there.
    local here = lower(world.zone)
    -- A worker in another zone is collected from in its zone before the route (engine/make: we go there, in
    -- step order), so the route starts where the last of them stands (2.42.14 Lopan log: planned from PoK, went to
    -- Marr's for Lunafeet's Tungsten Ore, then walked back to PoK for Water Flask and a forge Marr's has too).
    for _, st in ipairs(steps) do
        if st.order then
            -- world.worker_zone says where to collect (nil: nowhere fixed - a worker busy elsewhere, 2.43.3); a
            -- world without it (the tests) goes by the order's own zone
            local wz
            if world.worker_zone then wz = world.worker_zone(st.order.worker) else wz = st.order.zone end
            wz = wz and lower(wz) or ''
            if wz ~= '' and wz ~= here and self:hops(here, wz) then
                plan.pickupZone = wz
                here = wz
            end
        end
    end
    local function route_for(zs)
        local others = {}
        for _, z in ipairs(zs) do if z ~= here then others[#others + 1] = z end end
        table.sort(others)
        local best, bestCost
        for _, order in ipairs(permutations(others)) do
            local cost, at, ok = 0, here, true
            for _, z in ipairs(order) do
                local h = self:hops(at, z)
                if not h then ok = false; break end
                cost, at = cost + h, z
            end
            local craftAt = at
            if ok and craftZones then
                if craftZones[at] then craftAt = at
                else
                    local bz, bh
                    for z in pairs(craftZones) do
                        local h = self:hops(at, z)
                        if h and (not bh or h < bh or (h == bh and z < bz)) then bz, bh = z, h end
                    end
                    if bz then cost, craftAt = cost + bh, bz else ok = false end
                end
            end
            if ok and (not bestCost or cost < bestCost) then
                bestCost = cost
                best = { here }
                for _, z in ipairs(order) do best[#best + 1] = z end
                if craftAt ~= best[#best] then best[#best + 1] = craftAt end
            end
        end
        return best, bestCost
    end

    -- what each reachable zone sells of the shopping list
    local sells = {}      -- zone -> { [item index] = true }
    local need = {}       -- item indexes some reachable zone sells
    for i, b in ipairs(buyItems) do
        local any = false
        for _, v in ipairs(b.vendors) do
            if v.zone == here or self:hops(here, v.zone) then
                sells[v.zone] = sells[v.zone] or {}
                sells[v.zone][i] = true
                any = true
            end
        end
        if any then need[#need + 1] = i
        else
            local zs = {}
            for _, v in ipairs(b.vendors) do zs[#zs + 1] = v.npc .. ' (' .. v.zone .. ')' end
            plan.problems[#plan.problems + 1] = string.format('%s: sold only where travel.ini cannot reach: %s', b.item, table.concat(zs, ', '))
        end
    end
    local zones = {}
    for z in pairs(sells) do zones[#zones + 1] = z end
    table.sort(zones, function(x, y) if (x == here) ~= (y == here) then return x == here end; return x < y end)

    -- The fewest merchants in these zones that sell every item: one, then two, else greedy (most items
    -- first; ties: here, then by name). -> { { npc, zone, items = { index, ... } } } in pick order
    local function merchants_for(zs)
        local inSet = {}
        for _, z in ipairs(zs) do inSet[z] = true end
        local cand, byKey = {}, {}
        for _, i in ipairs(need) do
            for _, v in ipairs(buyItems[i].vendors) do
                if inSet[v.zone] then
                    local k = v.npc .. '|' .. v.zone
                    if not byKey[k] then byKey[k] = { npc = v.npc, zone = v.zone, has = {} }; cand[#cand + 1] = byKey[k] end
                    byKey[k].has[i] = true
                end
            end
        end
        table.sort(cand, function(x, y)
            if (x.zone == here) ~= (y.zone == here) then return x.zone == here end
            if x.zone ~= y.zone then return x.zone < y.zone end
            return x.npc < y.npc
        end)
        local function all(list)
            for _, i in ipairs(need) do
                local ok = false
                for _, m in ipairs(list) do if m.has[i] then ok = true; break end end
                if not ok then return false end
            end
            return true
        end
        local pick
        for _, m in ipairs(cand) do if all({ m }) then pick = { m }; break end end
        if not pick then
            for x = 1, #cand do
                for y = x + 1, #cand do
                    if all({ cand[x], cand[y] }) then pick = { cand[x], cand[y] }; break end
                end
                if pick then break end
            end
        end
        if not pick then
            pick = {}
            local left = {}
            for _, i in ipairs(need) do left[i] = true end
            while next(left) do
                local best, bestN = nil, 0
                for _, m in ipairs(cand) do
                    local n = 0
                    for i in pairs(left) do if m.has[i] then n = n + 1 end end
                    if n > bestN then best, bestN = m, n end
                end
                if not best then break end
                pick[#pick + 1] = best
                for i in pairs(best.has) do left[i] = nil end
            end
        end
        local out, taken = {}, {}
        for _, m in ipairs(pick) do
            local items = {}
            for _, i in ipairs(need) do if m.has[i] and not taken[i] then items[#items + 1] = i; taken[i] = true end end
            if #items > 0 then out[#out + 1] = { npc = m.npc, zone = m.zone, items = items } end
        end
        return out
    end

    -- every set of up to 3 zones that sells it all: fewest hops, then fewest merchants, then the most here
    local bestRoute, bestCost, bestStops, bestN
    local function try(zs)
        for _, i in ipairs(need) do
            local ok = false
            for _, z in ipairs(zs) do if sells[z][i] then ok = true; break end end
            if not ok then return end
        end
        local route, cost = route_for(zs)
        if not route then return end
        if bestCost and cost > bestCost then return end
        local stops = merchants_for(zs)
        if not bestCost or cost < bestCost or #stops < bestN then
            bestRoute, bestCost, bestStops, bestN = route, cost, stops, #stops
        end
    end
    if #need == 0 then
        bestRoute, bestCost = route_for({})
        bestStops = {}
    else
        for x = 1, #zones do
            try({ zones[x] })
            for y = x + 1, #zones do
                try({ zones[x], zones[y] })
                for w = y + 1, #zones do try({ zones[x], zones[y], zones[w] }) end
            end
        end
        if not bestRoute and #zones > 3 then
            plan.problems[#plan.problems + 1] = 'the shopping needs more than 3 zones'
        end
    end
    -- One stop per merchant, in the order picked (the walk order is settled on arrival, from where they stand).
    for _, m in ipairs(bestStops or {}) do
        plan.buys[m.zone] = plan.buys[m.zone] or {}
        local stop, at = { npc = m.npc, items = {} }, {}
        for _, i in ipairs(m.items) do
            local b, k = buyItems[i], lower(buyItems[i].item)
            -- what it costs (Alla's price at this merchant, else the item's value): a guide, not a quote
            local price
            for _, v in ipairs(b.vendors) do if v.npc == m.npc and v.zone == m.zone then price = v.price end end
            if not price then local it = self.cfg.items and self.cfg.items[k]; price = it and it.value end
            if price then plan.cost = (plan.cost or 0) + price * b.n else plan.costUnknown = true end
            if at[k] then at[k].n = at[k].n + b.n
            else at[k] = { item = b.item, n = b.n }; stop.items[#stop.items + 1] = at[k] end
        end
        table.insert(plan.buys[m.zone], stop)
    end
    if not bestRoute then
        if craftZones then plan.problems[#plan.problems + 1] = 'no route reaches a zone with the stations needed' end
        bestRoute = { here }
    end
    plan.route, plan.hops = bestRoute, bestCost or 0
    plan.craftZone = bestRoute[#bestRoute]

    -- What to wear for each skill the steps raise (skills.ini Trophy= then Clicky=, best first): the best one worn, in the bags,
    -- or in the bank (taken on the bank trip). None is fine. An item the plan itself uses (a Smithy Hammer
    -- as a tool) is never worn - the combine needs it in the bags.
    plan.modifiers = {}
    if world.worn and self.cfg.modifiers then
        local used = {}
        for _, st in ipairs(plan.steps) do
            for _, i in ipairs(st.recipe.ins or {}) do used[lower(i.name)] = true end
            for _, t in ipairs(st.recipe.tools or {}) do used[lower(t.name)] = true end
        end
        local worn = lower(world.worn() or '')
        for _, st in ipairs(plan.steps) do
            local r = st.recipe
            local sk = r.skill
            local list = sk and self.cfg.modifiers[sk]
            if list and not r.gather and not st.cast and not st.order and not plan.modifiers[sk] then
                local pick
                for _, m in ipairs(list) do
                    local k = lower(m)
                    if not used[k] then
                        if worn == k then pick = { item = m, where = 'worn' }
                        elseif (world.bags(m) or 0) > 0 then pick = { item = m, where = 'bags' }
                        elseif (world.bank(m) or 0) > 0 then
                            pick = { item = m, where = 'bank' }
                            plan.bankPulls[#plan.bankPulls + 1] = { item = m, n = 1 }
                        end
                        if pick then break end
                    end
                end
                plan.modifiers[sk] = pick or { none = list }
            end
        end
    end

    -- The bank trip happens first: here if there is a banker, else at the first zone on the route with one.
    if #plan.bankPulls > 0 then
        for _, z in ipairs(plan.route) do if self.cfg.travel.bankers[z] then plan.bankZone = z; break end end
        if not plan.bankZone then
            plan.bankZone = here
            plan.warnings[#plan.warnings + 1] = 'bank trip: no zone on the route is listed with a banker in travel.ini; will look for one here'
        end
    end
    local seen, uniq = {}, {}
    for _, p in ipairs(plan.problems) do if not seen[p] then seen[p] = true; uniq[#uniq + 1] = p end end
    plan.problems = uniq
    return plan
end

-- Every item name the data knows (recipe products, ingredients and tools, cast items and reagents, kits),
-- lower name -> name as written. Built once.
function Planner:item_names()
    if self.names then return self.names end
    local n = {}
    local function add(x) if x and x ~= '' and not n[lower(x)] then n[lower(x)] = x end end
    for _, r in pairs(self.cfg.recipes) do
        add(r.name)
        for _, i in ipairs(r.ins) do add(i.name) end
        for _, t in ipairs(r.tools) do add(t.name) end
    end
    for item, pr in pairs(self.cfg.producers or {}) do
        add(item)
        for _, rg in ipairs(pr.reagents) do add(rg.name) end
    end
    self.names = n
    return n
end

-- The item a typed name means: an exact name (any case) -> that name; else the names containing every
-- word typed. Returns name, nil  or  nil, { candidates } (shortest first, up to 10).
function Planner:match_item(query)
    local names = self:item_names()
    local exact = names[lower(query)]
    if exact then return exact, nil end
    local words = {}
    for w in lower(query):gmatch('%S+') do words[#words + 1] = w end
    local out = {}
    for k, v in pairs(names) do
        local all = true
        for _, w in ipairs(words) do if not k:find(w, 1, true) then all = false; break end end
        if all then out[#out + 1] = v end
    end
    table.sort(out, function(a, b) return #a < #b or (#a == #b and a < b) end)
    if #out == 1 then return out[1], nil end
    while #out > 10 do table.remove(out) end
    return nil, out
end

-- Recipes for the Craft tab: an exact id, else every recipe whose label or product holds every word typed,
-- only of `skill` when one is given (then an empty query lists the whole skill). With a skill: by trivial,
-- lowest first; without: exact names first, then shorter labels. Then by label and id. Up to `max`.
-- Returns the list and how many matched in all.
-- range (2.44.0, the Craft tab's trivial filter): { min, max, unknown } - only trivials from min up and/or up to max;
-- a recipe with no known trivial is left out (counted as the third return) unless `unknown`.
function Planner:search(query, max, skill, range)
    local q = lower(query or ''):match('^%s*(.-)%s*$')
    if q == '' and not skill then return {}, 0, 0 end
    local lo, hi = range and tonumber(range.min), range and tonumber(range.max)
    local filtering = lo ~= nil or hi ~= nil
    local hidden = 0
    local function in_range(r)
        if not filtering then return true end
        if not r.trivial then
            if range.unknown then return true end
            hidden = hidden + 1
            return false
        end
        return (not lo or r.trivial >= lo) and (not hi or r.trivial <= hi)
    end
    if q ~= '' then
        for id, r in pairs(self.cfg.recipes) do
            if lower(id) == q and (not skill or r.skill == skill) then return { r }, 1, 0 end
        end
    end
    local words = {}
    for w in q:gmatch('%S+') do words[#words + 1] = w end
    local out = {}
    for _, r in pairs(self.cfg.recipes) do
        if not skill or r.skill == skill then
            local hay = lower(r.label) .. ' ' .. lower(r.name)
            local all = true
            for _, w in ipairs(words) do if not hay:find(w, 1, true) then all = false; break end end
            if all and in_range(r) then out[#out + 1] = r end
        end
    end
    table.sort(out, function(a, b)
        if skill then
            -- a recipe whose trivial is not known goes last (2.43.0: 3946 Blacksmithing recipes, the first 300
            -- shown were all of unknown trivial and hid the real path)
            local ta, tb = a.trivial or math.huge, b.trivial or math.huge
            if ta ~= tb then return ta < tb end
        else
            local ea, eb = lower(a.name) == q, lower(b.name) == q
            if ea ~= eb then return ea end
            if #a.label ~= #b.label then return #a.label < #b.label end
        end
        if a.label ~= b.label then return a.label < b.label end
        return a.id < b.id
    end)
    local total = #out
    while #out > (max or 30) do table.remove(out) end
    return out, total, hidden
end

-- Product names that contain every word of the query, for "did you mean". Up to `max`.
function Planner:suggest(query, max)
    local words = {}
    for w in lower(query):gmatch('%S+') do words[#words + 1] = w:gsub('s$', '') end
    local seen, out = {}, {}
    for _, r in pairs(self.cfg.recipes) do
        local name = lower(r.name)
        if not seen[name] then
            local all = true
            for _, w in ipairs(words) do if not name:find(w, 1, true) then all = false; break end end
            if all then seen[name] = true; out[#out + 1] = r.name end
        end
    end
    table.sort(out, function(a, b) return #a < #b or (#a == #b and a < b) end)
    while #out > (max or 10) do table.remove(out) end
    return out
end

-- Preflight lines: { level = 'ok'|'warn'|'block', text = ... }, the tree indented.
-- copper -> "12pp 5gp" (the largest coins, nothing for zeros)
function Planner.money(c)
    c = math.floor(c + 0.5)
    local parts = {}
    for _, u in ipairs({ { 1000, 'pp' }, { 100, 'gp' }, { 10, 'sp' }, { 1, 'cp' } }) do
        local n = math.floor(c / u[1]); c = c - n * u[1]
        if n > 0 then parts[#parts + 1] = n .. u[2] end
    end
    return #parts > 0 and table.concat(parts, ' ') or '0cp'
end

function Planner.describe(plan)
    local lines = {}
    local function add(level, text) lines[#lines + 1] = { level = level, text = text } end
    for _, p in ipairs(plan.problems) do add('block', p) end
    if not plan.recipe then return lines end
    local r = plan.recipe
    if r.gather then add('ok', 'Get ' .. r.label)
    else
        add('ok', string.format('%s [%s] x%d combines in %s -> makes %d%s', r.label, r.id, plan.combines, r.container,
            plan.combines * (r.yield or 1), (r.yield or 1) > 1 and string.format(' (%d each)', r.yield) or ''))
    end
    local function node_line(node, indent)
        local parts = {}
        if (node.bags or 0) > 0 then parts[#parts + 1] = node.bags .. ' bags' end
        if (node.bank or 0) > 0 then parts[#parts + 1] = node.bank .. ' bank' end
        if node.buy then parts[#parts + 1] = 'buy ' .. node.buy end
        if node.pricey then parts[#parts + 1] = string.format('%s each - the network is asked first', Planner.money(node.pricey)) end
        if node.make then
            parts[#parts + 1] = string.format('make %d x [%s] in %s%s', node.make.combines, node.make.recipe.id, node.make.recipe.container,
                (node.variants or 1) > 1 and string.format(' (best of %d recipes)', node.variants) or '')
        end
        if node.cast then
            local cs = {}
            for _, part in ipairs(node.cast.parts) do cs[#cs + 1] = string.format('%d x %s (%d each)', part.casts, part.spell, part.yield) end
            parts[#parts + 1] = 'cast ' .. table.concat(cs, ' + ')
        end
        if node.order then parts[#parts + 1] = string.format('%s makes %d and brings them', node.order.worker, node.order.n) end
        for _, o in ipairs(node.supply or {}) do
            parts[#parts + 1] = o.buy and string.format('%s buys %d and brings them (our faction there is too low)', o.worker, o.n)
                or string.format('%s brings %d (has them in %s)', o.worker, o.n, o.zone or '?')
        end
        if node.short then parts[#parts + 1] = 'SHORT ' .. node.short .. (node.note and (' (' .. node.note .. ')') or '') end
        add(node.short and 'block' or 'ok', string.format('%s%s %d%s: %s', indent, node.item, node.need, node.tool and ' (tool)' or '',
            table.concat(parts, ', ')))
        if node.cast then for _, c in ipairs(node.cast.children) do node_line(c, indent .. '  ') end end
        if node.make then
            for _, c in ipairs(node.make.children) do node_line(c, indent .. '  ') end
            for _, t in ipairs(node.make.tools) do
                if t.have then add('ok', string.format('%s  %s (tool): have %d', indent, t.item, t.have)) else node_line(t, indent .. '  ') end
            end
        end
    end
    for _, c in ipairs(plan.tree.children) do node_line(c, '  ') end
    for _, t in ipairs(plan.tree.tools) do
        if t.have then add('ok', string.format('  %s (tool): have %d', t.item, t.have)) else node_line(t, '  ') end
    end
    if #plan.bankPulls > 0 then
        local parts = {}
        for _, b in ipairs(plan.bankPulls) do parts[#parts + 1] = b.n .. ' ' .. b.item end
        add('ok', string.format('Bank (%s): %s', plan.bankZone or '?', table.concat(parts, ', ')))
    end
    for _, z in ipairs(plan.route) do
        for _, stop in ipairs(plan.buys[z] or {}) do
            local parts = {}
            for _, it in ipairs(stop.items) do parts[#parts + 1] = it.n .. ' ' .. it.item end
            add('ok', string.format('Buy in %s from %s: %s', z, stop.npc, table.concat(parts, ', ')))
        end
    end
    local mods = {}
    for sk in pairs(plan.modifiers or {}) do mods[#mods + 1] = sk end
    table.sort(mods)
    for _, sk in ipairs(mods) do
        local m = plan.modifiers[sk]
        if m.item then
            add('ok', string.format('Wear for %s: %s (%s)', sk, m.item, ({ worn = 'already worn', bags = 'in the bags',
                bank = 'in the bank - taken on the bank trip' })[m.where]))
        else
            add('ok', string.format('Wear for %s: none of yours (%s) - carrying on without', sk, table.concat(m.none, ', ')))
        end
    end
    if plan.cost and plan.cost > 0 then
        add('ok', string.format('Cost: about %s%s (Alla prices)', Planner.money(plan.cost), plan.costUnknown and ' plus items with no price' or ''))
    end
    if #plan.steps > 1 then
        local parts = {}
        for _, st in ipairs(plan.steps) do
            if st.recipe.gather then break end
            parts[#parts + 1] = st.cast and string.format('%d cast%s of %s', st.combines, st.combines == 1 and '' or 's', st.cast.spell)
                or st.order and string.format('%d %s', st.combines, st.recipe.label)
                or string.format('%dx %s', st.combines, st.recipe.label)
        end
        add('ok', 'Order: ' .. table.concat(parts, ' -> '))
    end
    add('ok', string.format('Route: %s (%d hop%s), %s in %s', table.concat(plan.route, ' -> '), plan.hops,
        plan.hops == 1 and '' or 's', r.gather and 'done' or 'craft', plan.craftZone or '?'))
    if plan.pickupZone then add('ok', 'Route starts in ' .. plan.pickupZone .. ': a worker there is collected from first') end
    for _, w in ipairs(plan.warnings) do add('warn', w) end
    for _, k in ipairs(plan.kits or {}) do add('ok', k) end
    return lines
end

return Planner
