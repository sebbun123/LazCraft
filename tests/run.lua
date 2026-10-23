-- LazCraft tests. Run from anywhere:  luajit lazcraft/tests/run.lua
local TESTS_DIR = (debug.getinfo(1, 'S').source:match('^@?(.*[\\/])')) or './'
local ROOT = TESTS_DIR .. '../'
package.path = ROOT .. '?.lua;' .. TESTS_DIR .. '?.lua;' .. package.path
local realPrint = print

local passed, failed = 0, 0
local ONLY = os.getenv('LC_ONLY')
local function test(name, fn)
    if ONLY and not name:find(ONLY, 1, true) then return end
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; realPrint('  ok    ' .. name)
    else failed = failed + 1; realPrint('  FAIL  ' .. name .. '\n' .. tostring(err)) end
end
local function eq(a, b, what)
    if a ~= b then error(string.format('%s: expected %s, got %s', what or 'value', tostring(b), tostring(a)), 2) end
end
local function truthy(v, what) if not v then error((what or 'condition') .. ' was false', 2) end end

local R = require('core.result')
local Ini = require('core.ini')
local Config = require('core.config')
local Jobs = require('core.jobs')
local E3 = require('core.e3')

-- A quiet logger that remembers what was said.
local function fake_log()
    local L = { lines = {} }
    for _, lvl in ipairs({ 'debug', 'info', 'warn', 'error' }) do
        L[lvl] = function(fmt, ...)
            L.lines[#L.lines + 1] = lvl .. ': ' .. (select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt))
        end
    end
    function L.has(p) for _, l in ipairs(L.lines) do if l:find(p) then return true end end return false end
    return L
end

-- A clock for runner tests: delay() advances it in frame steps and fires scheduled actions.
local function clock(frameMs)
    local C = { t = 0, frame = frameMs or 16, todo = {} }
    function C.now() return C.t end
    function C.delay(ms)
        local target = C.t + ms
        repeat
            C.t = C.t + C.frame
            if C.t > 600000 then error('runaway: virtual clock passed 10 minutes') end
            for i = #C.todo, 1, -1 do
                if C.todo[i].at <= C.t then local f = table.remove(C.todo, i).fn; f() end
            end
        until C.t >= target
    end
    function C.at(ms, fn) C.todo[#C.todo + 1] = { at = ms, fn = fn } end
    -- A command typed at `ms`: like MQ, it only runs when the runner calls doevents().
    C.pending = {}
    function C.cmd_at(ms, fn) C.at(ms, function() C.pending[#C.pending + 1] = fn end) end
    function C.doevents()
        local due = C.pending
        C.pending = {}
        for _, f in ipairs(due) do f() end
    end
    return C
end
local function new_runner(c, log, e3)
    return Jobs.new({ delay = c.delay, now = c.now, doevents = c.doevents, log = log, e3 = e3 })
end
local function e3_recorder(log)
    local sent = {}
    return E3.new(function(s) sent[#sent + 1] = s end, log), sent
end

realPrint('ini')
test('parse keeps order, case and repeated keys', function()
    local d = Ini.parse('; c\r\n[B]\r\nk=1\r\n[A]\r\nKey = two words \r\nKey=3\r\n# also comment\r\n')
    eq(d.order[1], 'B'); eq(d.order[2], 'A')
    eq(d.sections.A.map.Key, '3'); eq(#d.sections.A.keys, 2); eq(d.sections.A.keys[1][2], 'two words')
end)
test('list splits and trims', function()
    local l = Ini.list(' a, b ,,c ')
    eq(#l, 3); eq(l[2], 'b')
end)

test('a missing file is reported at once, without waiting on retries', function()
    local sleeps = 0
    local text, err = Ini.read_file('/no/such/dir/x.ini', function() sleeps = sleeps + 1 end)
    eq(text, nil); truthy(err, 'error given'); eq(sleeps, 0, 'retry sleeps')
end)

test('a console line is capped (a long one can take the client down); the file gets all of it, first', function()
    package.loaded['core.log'] = nil
    local L = require('core.log')
    local printed = {}
    L.setup({ printer = function(s) printed[#printed + 1] = s end, level = 'info' })
    L.info(string.rep('x', 3000))
    truthy(#printed[1] < 700, 'console line ' .. #printed[1])
    truthy(printed[1]:find('the rest is in the log file', 1, true), 'says so')
    package.loaded['core.log'] = nil
end)

test('log file keeps the previous session and stamps seconds since start', function()
    package.loaded['core.log'] = nil
    local L = require('core.log')
    local t = 1000
    L.setup({ printer = function() end, clock = function() return t end, level = 'info', fileLevel = 'debug' })
    local path = os.tmpname()
    truthy(L.open_file(path)); L.debug('first session'); L.close_file()
    t = 3500
    truthy(L.open_file(path)); L.debug('second %s', 'session'); L.info('shown'); L.close_file()
    local cur = io.open(path):read('*a'); local prev = io.open(path:gsub('%.log$', '') .. '.prev.log'):read('*a')
    truthy(cur:find('second session', 1, true) and not cur:find('first session', 1, true), 'current file')
    truthy(prev:find('first session', 1, true), 'previous file kept')
    truthy(cur:find('2.500 DEBUG', 1, true), 'seconds since start: ' .. cur)
    eq(#L.recent(), 1, 'debug lines stay out of the window')
    os.remove(path); os.remove(path:gsub('%.log$', '') .. '.prev.log')
    package.loaded['core.log'] = nil
end)

realPrint('config')
test('shipped data loads with no problems', function()
    local cfg, problems = Config.load(ROOT .. 'data/')
    eq(#problems, 0, 'problems (' .. table.concat(problems, '; ') .. ')')
    local stations, kits, skips = 0, 0, 0
    for _, c in pairs(cfg.containers) do
        if c.type == 'station' then stations = stations + 1 elseif c.type == 'kit' then kits = kits + 1 else skips = skips + 1 end
    end
    eq(stations, 6, 'stations'); eq(kits, 15, 'kits'); eq(skips, 1, 'skipped (research books)')
    eq(#cfg.containers.Forge.stations, 3, 'forge locations')
    eq(cfg.containers['Brew Barrel'].stations[1].target, 'Brewing Barrel', 'brewing barrel target')
    eq(cfg.containers['Brew Barrel'].stations[2].target, 'Brew Barrel', 'default target')
    eq(cfg.containerByBag['planar fletching kit'], 'Fletching Kit', 'variant maps to kit')
    local nskills = 0; for _ in pairs(cfg.skills) do nskills = nskills + 1 end
    eq(nskills, 11, 'skills')
    eq(cfg.skills.Jewelcrafting.eqSkill, 'Jewelry Making')
    eq(#cfg.skills.Blacksmithing.rungs, 12, 'blacksmithing rungs')
    eq(cfg.skills.Blacksmithing.rungs[1].disposal, 'destroy')
    eq(cfg.skills.Tinkering.race, 'Gnome')
    eq(#cfg.collections.Radix, 9, 'radix')
    eq(cfg.collectionOpts.Radix.Draught, 'Draught of the Craftsman', 'radix draught')
    eq(cfg.collectionOpts.Radix.DraughtBuff, 'Draught of the Craftsman I', 'radix draught buff')
    eq(cfg.collectionOpts.Radix.OneAtATime, 'Essence Fusion Chamber', 'radix one at a time')
    eq(cfg.collectionOpts.Radix.Precombines, 'Flask of Fruit Juice, Fizzlepop, Barbecue Ribs, Baked Potato', 'radix precombines')
    eq(cfg.recipes.O2086.trivial, 500, 'chamber trivial (recipes_local)'); eq(cfg.recipes.O1920.skill, 'Brewing', 'temper skill')
    local nprod = 0; for _ in pairs(cfg.producers) do nprod = nprod + 1 end
    eq(nprod, 27, 'producers')
    eq(cfg.producers['Vial of Clear Mana'].reagents[2].name, 'Poison Vial')
    eq(cfg.producers['Vial of Clear Mana'].reagents[2].count, 5)
    truthy(cfg.lists.neverSell['platinum bar'], 'never sell platinum bar')
    truthy(cfg.lists.fishDestroy['tiny fetid bass'], 'fish destroy list')
end)
test('items.ini: the harvest\'s merchants join merchants.ini\'s, with prices; money reads in coins', function()
    local cfg = Config.load(ROOT .. 'data/')
    truthy((cfg.harvestMerchants or 0) > 1000, 'merchants added: ' .. tostring(cfg.harvestMerchants))
    eq(cfg.items['malt'].value, 15)
    local berina
    for _, v in ipairs(cfg.merchants['malt']) do if v.npc == 'Brewmaster Berina' and v.zone == 'freeporttemple' then berina = v end end
    truthy(berina and berina.price == 15, 'Berina sells Malt in Marr for 15cp')
    local seen = {}
    for _, v in ipairs(cfg.merchants['water flask']) do
        local k = v.npc .. '|' .. v.zone
        truthy(not seen[k], 'listed once: ' .. k); seen[k] = true
    end
    local Pl = require('engine.planner')
    eq(Pl.money(1405), '1pp 4gp 5cp'); eq(Pl.money(0), '0cp')
end)

test('skills.ini: what to wear, best first - Research has the Ethereal Quill (the old LazCraft\'s research modifier) first', function()
    local cfg = Config.load(ROOT .. 'data/')
    eq(table.concat(cfg.modifiers.Research or {}, ', '), 'Ethereal Quill, Geerlok Automated Quill')
    eq(cfg.modifiers.Blacksmithing[1], "Solusek Mining Co. Pioneer's Pick")
end)

test('bad lines become readable problems', function()
    local problems = {}
    Config.parse_containers(Ini.parse('[Forge]\nType=station\nAt1=pok 1 2\n[Bag]\nType=kit\nAccepts=A\nBuyOrder=B\n[X]\nType=box'), problems)
    Config.parse_skills(Ini.parse('[S]\nRung1=Thing, sometimes\n[LevelAll]\nOrder=Nope'), problems)
    Config.parse_producers(Ini.parse('[P]\nSpell=Zap | 0 | Gem x1\n[R]\nSpell=Zap | 5 | Gem five\n[Q]\nSpell=Just a name'), problems)
    local all = table.concat(problems, '\n')
    for _, p in ipairs({ 'At1 is not', 'no At lines', 'BuyOrder "B"', 'Type must be', 'no numeric ID',
                         'Rung1 is not', 'unknown skill "Nope"', 'no Spell', 'amount must be 1', 'reagent "Gem five"', 'no Classes',
                         'is not "<spell> | <amount> | <reagents>"' }) do
        truthy(all:find(p, 1, true), 'problem mentioning ' .. p)
    end
end)
test('settings round-trip and keep unknown keys', function()
    local path = os.tmpname()
    local s = Config.load_settings(path)
    eq(s.LogToFile, '1', 'file logging on by default'); eq(s.LogFileLevel, 'debug')
    s.LogToFile, s.FutureKey = '0', 'x'
    truthy(Config.save_settings(path, s))
    local back = Config.load_settings(path)
    eq(back.LogToFile, '0'); eq(back.FutureKey, 'x')
    os.remove(path)
end)


realPrint('planner')
local Planner = require('engine.planner')

-- A small world built from INI text, so parsing is tested too.
local function mini_cfg(recipesText, merchantsText)
    local problems = {}
    local cfg = Config.load(ROOT .. 'data/')   -- containers and travel from the shipped files
    cfg.recipes = Config.parse_recipes(Ini.parse(recipesText), problems)
    cfg.recipesByName = Config.index_recipes(cfg.recipes)
    cfg.merchants = Config.parse_merchants(Ini.parse(merchantsText))
    eq(#problems, 0, table.concat(problems, '; '))
    return cfg
end
local MEAD = [[
[T1]
Name=Fluid Mead
Container=Brew Barrel
In=Butter x1, White Wine x1, Blue Diamond Dust x1
[T2]
Name=Blue Diamond Dust
Container=Jeweler's Kit
In=Blue Diamond x1, Acid x1
]]
local SHOPS = [[
[Charlette##freeporttemple]
_Zone=freeporttemple
Butter=1
White Wine=1
[Bob##poknowledge]
_Zone=poknowledge
Acid=1
]]
local function world(bags, bank, zone)
    return { zone = zone or 'freeporttemple',
             bags = function(i) return (bags or {})[i] or 0 end, bank = function(i) return (bank or {})[i] or 0 end,
             kit = function(c) return c == "Jeweler's Kit" end }
end
local function lines(plan) local t = {}; for _, l in ipairs(Planner.describe(plan)) do t[#t + 1] = l.level .. ' ' .. l.text end; return table.concat(t, '\n') end

test("planner: the Fluid Mead example - buy here, buy in PoK, held from bank, subcombine first", function()
    local P = Planner.new(mini_cfg(MEAD, SHOPS))
    local plan = P:plan('T1', 10, world({ ['Blue Diamond'] = 3 }, { ['Blue Diamond'] = 7 }))
    local text = lines(plan)
    eq(#plan.problems, 0, text)
    eq(plan.bankPulls[1].item, 'Blue Diamond'); eq(plan.bankPulls[1].n, 7)
    eq(plan.buys.freeporttemple[1].npc, 'Charlette'); eq(#plan.buys.freeporttemple[1].items, 2, 'one stop for both')
    eq(plan.buys.poknowledge[1].items[1].item, 'Acid'); eq(plan.buys.poknowledge[1].items[1].n, 10)
    eq(plan.steps[1].recipe.id, 'T2'); eq(plan.steps[1].combines, 10); eq(plan.steps[2].recipe.id, 'T1')
    eq(table.concat(plan.route, '>'), 'freeporttemple>poknowledge'); eq(plan.craftZone, 'poknowledge')
    eq(plan.bankZone, 'freeporttemple')
    truthy(text:find('Blue Diamond 10: 3 bags, 7 bank', 1, true), text)
end)

test('planner: a held item that is not there blocks; bank before buying; on-hand intermediates count', function()
    local P = Planner.new(mini_cfg(MEAD, SHOPS))
    local short = P:plan('T1', 10, world({ ['Blue Diamond'] = 2 }, { ['Blue Diamond'] = 3 }))
    truthy(lines(short):find('Blue Diamond: short 5', 1, true), lines(short))
    local p = P:plan('T1', 10, world({ ['Blue Diamond'] = 10, ['Blue Diamond Dust'] = 4 }, { Butter = 4 }))
    eq(#p.problems, 0, lines(p))
    eq(p.steps[1].combines, 6, 'only the missing dust is made')
    local butter; for _, s in ipairs(p.buys.freeporttemple[1].items) do if s.item == 'Butter' then butter = s.n end end
    eq(butter, 6, 'banked butter used first'); eq(p.bankPulls[1].item, 'Butter')
end)

test('planner: buys what is sold even if a recipe makes it; yield; tools once; best sub-recipe; loops', function()
    local P = Planner.new(mini_cfg([[
[A]
Name=Ring
Container=Jeweler's Kit
In=Dust x10, Bar x1
Tools=Needle x1
[B1]
Name=Dust
Container=Jeweler's Kit
Yield=4
In=Gem x1
[B2]
Name=Dust
Container=Jeweler's Kit
In=Unobtainium x1
[C]
Name=Bar
Container=Forge
In=Ore x1
[L1]
Name=Loop A
Container=Jeweler's Kit
In=Loop B x1
[L2]
Name=Loop B
Container=Jeweler's Kit
In=Loop A x1
]], [[
[Smith##freeporttemple]
_Zone=freeporttemple
Bar=1
Gem=1
Needle=1
]]))
    local p = P:plan('A', 2, world())
    eq(#p.problems, 0, lines(p))
    local dust = p.tree.children[1]
    eq(dust.make.recipe.id, 'B1', 'the sub-recipe that can be supplied'); eq(dust.make.combines, 5, '20 dust at 4 per combine')
    eq(p.tree.children[2].buy, 2, 'bar bought, not made at a forge')
    eq(p.tree.tools[1].buy, 1, 'one needle, not one per combine')
    local p2 = P:plan('A', 2, world({ Needle = 1 }))
    eq(p2.tree.tools[1].have, 1, 'a needle already carried is enough')
    -- a tool that has to be made: its ingredients come from storage first, like any other
    local P3 = Planner.new(mini_cfg([[
[R]
Name=Spoon Thing
Container=Jeweler's Kit
In=Milk x1
Tools=Spoon x1
[S]
Name=Spoon
Container=Jeweler's Kit
In=Ore x1, Water x1
]], [[
[Smith##freeporttemple]
_Zone=freeporttemple
Ore=1
Water=1
Milk=1
]]))
    local p3 = P3:plan('R', 1, world({}, { Water = 5 }))
    eq(#p3.problems, 0, lines(p3))
    local spoon = p3.tree.tools[1]
    eq(spoon.make.recipe.id, 'S')
    eq(spoon.make.children[2].bank, 1, 'the water for the spoon comes from the bank, not a vendor')
    local loop = P:plan('L1', 1, world())
    truthy(lines(loop):find('loop in the recipes', 1, true), lines(loop))
end)

test('item lists allow commas inside item names', function()
    local l = Config.item_list('Nightbane, Sword of the Valiant x1, One Handed Paladin Grip x2')
    eq(#l, 2); eq(l[1].name, 'Nightbane, Sword of the Valiant'); eq(l[2].n, 2)
end)

test('planner: variants of one product are separate recipes; find lists them', function()
    local cfg = Config.load(ROOT .. 'data/')
    local P = Planner.new(cfg)
    local found = P:find('Silver Amber Ring')
    eq(#found, 2, 'both ring recipes')
    local labels = {}
    for _, r in ipairs(found) do labels[#labels + 1] = r.label end
    table.sort(labels)
    eq(labels[1], 'Silver Amber Ring'); eq(labels[2], 'Silver Amber Ring (Silver Bar)')
    eq(#P:find('Silver Amber Ring (Silver Bar)'), 1, 'a label picks one')
    eq(#P:find('L1'), 1, 'an id picks one')
end)

test('planner: shopping - fewest zone changes first, then the fewest merchants', function()
    local R4 = [[
[K1]
Name=Four Part Thing
Container=Jeweler's Kit
In=Ay x1, Bee x1, Cee x1, Dee x1
]]
    local SHOPS4 = [[
[Pa##poknowledge]
_Zone=poknowledge
Ay=1
Bee=1
[Pb##poknowledge]
_Zone=poknowledge
Cee=1
Dee=1
[Pall##poknowledge]
_Zone=poknowledge
Ay=1
Bee=1
Cee=1
Dee=1
[Mall##freeporttemple]
_Zone=freeporttemple
Ay=1
Bee=1
Cee=1
Dee=1
]]
    local P = Planner.new(mini_cfg(R4, SHOPS4))
    local function stops(p)
        local t = {}
        for z, list in pairs(p.buys) do for _, st in ipairs(list) do t[#t + 1] = st.npc .. '@' .. z .. ':' .. #st.items end end
        table.sort(t); return table.concat(t, ' ')
    end
    -- in PoK: one merchant there sells all four - stay, one stop
    local p = P:plan('K1', 1, world({}, {}, 'poknowledge'))
    eq(stops(p), 'Pall@poknowledge:4'); eq(p.hops, 0)
    -- in Marr: Marr sells it all - stay in Marr
    p = P:plan('K1', 1, world({}, {}, 'freeporttemple'))
    eq(stops(p), 'Mall@freeporttemple:4'); eq(p.hops, 0)
    -- PoK without the one-stop merchant: still stays in PoK (two stops) rather than one stop in Marr
    local SHOPS2 = SHOPS4:gsub('%[Pall##poknowledge%][^%[]*', '')
    P = Planner.new(mini_cfg(R4, SHOPS2))
    p = P:plan('K1', 1, world({}, {}, 'poknowledge'))
    eq(stops(p), 'Pa@poknowledge:2 Pb@poknowledge:2'); eq(p.hops, 0)
    -- Dee only in Marr: one hop either way, so the fewest merchants - all four from Mall in Marr
    local SHOPS3 = SHOPS2:gsub('Cee=1\nDee=1\n%[Mall', 'Cee=1\n[Mall')
    P = Planner.new(mini_cfg(R4, SHOPS3))
    p = P:plan('K1', 1, world({}, {}, 'poknowledge'))
    eq(stops(p), 'Mall@freeporttemple:4'); eq(p.hops, 1)
end)

test('planner: one line per problem, bank pull and merchant item; suggestions for a near miss', function()
    local P = Planner.new(mini_cfg([[
[A]
Name=Big Thing
Container=Sewing Kit
In=Part x1, Other Part x1
[B]
Name=Part
Container=Sewing Kit
In=Flour x1, Water x1
[C]
Name=Other Part
Container=Sewing Kit
In=Flour x2, Water x1
]], [[
[Cook##freeporttemple]
_Zone=freeporttemple
Flour=1
]]))
    local p = P:plan('A', 1, world({}, { Water = 5 }))
    local kits = 0
    for _, pr in ipairs(p.problems) do if pr:find('Sewing Kit', 1, true) then kits = kits + 1 end end
    eq(kits, 1, 'said once')
    eq(#p.bankPulls, 1); eq(p.bankPulls[1].n, 2)
    eq(#p.buys.freeporttemple[1].items, 1); eq(p.buys.freeporttemple[1].items[1].n, 3)
    local P2 = Planner.new(Config.load(ROOT .. 'data/'))
    local near = P2:suggest('Misty Thicket Picnic Baskets')
    local has = false; for _, n in ipairs(near) do if n == 'Misty Thicket Picnic' then has = true end end
    truthy(not has, 'all words must match')
    near = P2:suggest('Misty Thicket Picnic')
    eq(near[1], 'Misty Thicket Picnic')
end)

test('planner: a missing kit, an unreachable vendor and a station nobody has all block', function()
    local P = Planner.new(mini_cfg([[
[K]
Name=Thing
Container=Sewing Kit
In=Far Item x1
]], [[
[Hermit##faraway]
_Zone=faraway
Far Item=1
]]))
    local text = lines(P:plan('K', 1, world()))
    truthy(text:find('Sewing Kit: not carried, not in the bank, and no vendor we can reach sells one', 1, true), text)
    truthy(text:find('sold only where travel.ini cannot reach', 1, true), text)
end)

test('planner: a kit not carried - from the bank first (BuyOrder variants first), else bought in BuyOrder order', function()
    local cfg = Config.load(ROOT .. 'data/')
    local P = Planner.new(cfg)
    local id = P:find('Silk Thread')[1].id
    local w = world(nil, { ['Large Sewing Kit'] = 1, ['Small Sewing Kit'] = 1 })
    w.kit = function() return false end
    local plan = P:plan(id, 1, w)
    local text = lines(plan)
    eq(#plan.problems, 0, text)
    truthy(text:find('Sewing Kit: not carried - taking a Large Sewing Kit from the bank', 1, true), text)
    eq(plan.bankPulls[#plan.bankPulls].item, 'Large Sewing Kit')
    w = world(); w.kit = function() return false end
    plan = P:plan(id, 1, w); text = lines(plan)
    truthy(text:find('Sewing Kit: not carried - buying a Planar Sewing Kit', 1, true), text)
    truthy(text:find('Buy in freeporttemple from Sherin Matrick: 1 Planar Sewing Kit', 1, true) or text:find('1 Planar Sewing Kit', 1, true), text)
end)

test('planner: an item no one sells is cast when this character has the spell; its reagents are found like ingredients', function()
    local cfg = Config.load(ROOT .. 'data/')
    local P = Planner.new(cfg)
    local w = world()
    w.canCast = function(spell) return spell == 'Superior Mass Enchant Silver' end
    local plan = P:plan('O6358', 1, w)
    local text = lines(plan)
    eq(#plan.problems, 0, text)
    truthy(text:find('Enchanted Silver Bar 1: cast 1 x Superior Mass Enchant Silver (100 each)', 1, true), text)
    truthy(text:find('Silver Bar 100: buy 100', 1, true), text)
    truthy(text:find('Order: 1 cast of Superior Mass Enchant Silver -> 1x Silver Amber Ring', 1, true), text)
    truthy(text:find('Silver Amber Ring [O6358] x1 combines in Jeweler\'s Kit -> makes 1', 1, true), text)
    w.canCast = function() return false end
    text = lines(P:plan('O6358', 1, w))
    truthy(text:find('made by casting Superior Mass Enchant Silver (or a smaller version) - nobody running has it scribed: start a ', 1, true), text)
end)

test('planner: plan_item gathers an item like an ingredient - bags, bank, buy, subcombine, cast - with no container', function()
    local P = Planner.new(mini_cfg(MEAD, SHOPS))
    local have = P:plan_item('Blue Diamond Dust', 5, world({ ['Blue Diamond Dust'] = 5 }))
    eq(#have.problems, 0, lines(have)); eq(#have.steps, 1, 'only the gather step'); eq(#have.bankPulls, 0)
    truthy(lines(have):find('Get 5 Blue Diamond Dust', 1, true), lines(have))
    local made = P:plan_item('Blue Diamond Dust', 5, world({ ['Blue Diamond'] = 2 }, { ['Blue Diamond'] = 3 }))
    eq(#made.problems, 0, lines(made)); eq(made.steps[1].recipe.id, 'T2'); eq(made.steps[1].combines, 5)
    eq(made.bankPulls[1].n, 3); eq(made.buys.poknowledge[1].items[1].n, 5)
    local short = P:plan_item('Blue Diamond', 5, world())
    truthy(#short.problems == 1 and short.problems[1]:find('Blue Diamond: short 5', 1, true), lines(short))
    local P2 = Planner.new(Config.load(ROOT .. 'data/'))
    local w = world(); w.canCast = function(spell) return spell == 'Superior Mass Enchant Silver' end
    local cast = P2:plan_item('Enchanted Silver Bar', 150, w)
    local text = lines(cast)
    eq(#cast.problems, 0, text)
    truthy(text:find('Enchanted Silver Bar 150: cast 2 x Superior Mass Enchant Silver', 1, true), text)
    truthy(text:find('Silver Bar 200: buy 200', 1, true), text)
end)

test('planner: search by trivial - from min, up to max, between; no known trivial left out and counted unless asked (2.44.0)', function()
    local P = Planner.new(Config.load(ROOT .. 'data/'))
    local all, totalAll = P:search('', 5000, 'Blacksmithing')
    local up, tUp, hid = P:search('', 5000, 'Blacksmithing', { min = 200 })
    truthy(tUp > 0 and tUp < totalAll, 'fewer'); truthy(hid > 0, 'no-trivial ones counted')
    for _, r in ipairs(up) do truthy(r.trivial and r.trivial >= 200, r.label) end
    local down = P:search('', 5000, 'Blacksmithing', { max = 50 })
    for _, r in ipairs(down) do truthy(r.trivial and r.trivial <= 50, r.label) end
    local mid = P:search('', 5000, 'Blacksmithing', { min = 100, max = 150 })
    for _, r in ipairs(mid) do truthy(r.trivial >= 100 and r.trivial <= 150, r.label) end
    local withU, tU, hid2 = P:search('', 5000, 'Blacksmithing', { min = 200, unknown = true })
    eq(hid2, 0); eq(tU, tUp + hid, 'the no-trivial ones shown when asked')
    local _, tNone = P:search('', 5000, 'Blacksmithing', {})
    eq(tNone, totalAll, 'no limits: everything')
end)

test('planner: a typed item name - exact in any case, one match by words, or a list to pick from', function()
    local P = Planner.new(Config.load(ROOT .. 'data/'))
    eq(P:match_item('enchanted silver bar'), 'Enchanted Silver Bar')
    local one, l0 = P:match_item('magic clay large')
    eq(one, 'Large Block of Magic Clay', table.concat(l0 or {}, ', '))
    local none, list = P:match_item('enchanted gold')
    eq(none, nil); truthy(#list > 1, 'several'); eq(list[1], 'Enchanted Gold Bar', table.concat(list, ', '))
    local _, nothing = P:match_item('zzz qqq'); eq(#nothing, 0)
end)

test('planner: an item nobody here can cast goes to a worker that can (exactly what is needed); our own spell comes first', function()
    local P = Planner.new(Config.load(ROOT .. 'data/'))
    local w = world()
    w.canCast = function() return false end
    w.worker = function(item) return item == 'Enchanted Silver Bar' and 'Shela' or nil end
    local plan = P:plan('O6358', 3, w)
    local text = lines(plan)
    eq(#plan.problems, 0, text)
    truthy(text:find('Enchanted Silver Bar 3: Shela makes 3 and brings them', 1, true), text)
    truthy(not text:find('Silver Bar 100', 1, true), 'no reagents for us to buy')
    eq(plan.steps[1].order.worker, 'Shela'); eq(plan.steps[1].combines, 3); eq(plan.orders[1].n, 3)
    truthy(text:find('Order: 3 Enchanted Silver Bar from Shela -> 3x Silver Amber Ring', 1, true), text)
    w.canCast = function(s) return s == 'Superior Mass Enchant Silver' end
    truthy(lines(P:plan('O6358', 3, w)):find('cast 1 x Superior Mass Enchant Silver', 1, true), 'own spell first')
    w.canCast = function() return false end; w.worker = function() return nil end
    truthy(lines(P:plan('O6358', 3, w)):find('nobody running has it scribed', 1, true), 'nobody: blocks with why')
end)

test('planner: a worker in another zone is collected from there first - the route starts in its zone', function()
    -- 2.42.14 Lopan log: planned from PoK, went to Marr's for Lunafeet's Tungsten Ore, walked back to PoK for a forge
    local P = Planner.new(Config.load(ROOT .. 'data/'))
    local w = world(nil, nil, 'poknowledge')
    w.canCast = function() return false end
    w.worker = function(item) return item == 'Enchanted Silver Bar' and 'Shela' or nil end
    eq(P:plan('O6358', 3, w).route[1], 'poknowledge', 'no zone known: from here')
    w.worker_zone = function() return 'poknowledge' end
    eq(P:plan('O6358', 3, w).pickupZone, nil, 'here already')
    w.worker_zone = function(n) return n == 'Shela' and 'freeporttemple' or nil end
    local plan = P:plan('O6358', 3, w)
    eq(#plan.problems, 0, lines(plan))
    eq(plan.route[1], 'freeporttemple'); eq(plan.pickupZone, 'freeporttemple')
    truthy(lines(plan):find('Route starts in freeporttemple', 1, true), lines(plan))
    -- a worker busy elsewhere (not sitting still in a safe zone) gives no zone: the route starts where we stand (2.43.3)
    w.worker_zone = function() return nil end
    local p2 = P:plan('O6358', 3, w)
    eq(p2.route[1], 'poknowledge'); eq(p2.pickupZone, nil)
end)

test('planner: a merchant item dearer than the limit is asked for on the network first; what nobody has is bought', function()
    local P = Planner.new(Config.load(ROOT .. 'data/'))
    local w = world()
    w.requestOver = 20000   -- 20pp
    local holders = { { name = 'Ann', zone = 'poknowledge', safe = true, have = 3 }, { name = 'Tom', zone = 'soldungb', safe = false, have = 50 } }
    w.supply = function(i) return i == 'Fine Runic Parchment Solution' and holders or (i == 'Ink of Pain' and holders) or nil end
    local p = P:plan_item('Fine Runic Parchment Solution', 5, w)
    local text = lines(p)
    eq(#p.problems, 0, text)
    truthy(text:find('Fine Runic Parchment Solution 5: buy 2, 211pp 3gp 2sp 1cp each - the network is asked first, Ann brings 3', 1, true), text)
    eq(p.orders[1].worker, 'Ann'); eq(p.orders[1].n, 3); eq(p.pricey[1].item, 'Fine Runic Parchment Solution')
    local cheap = P:plan_item('Ink of Pain', 5, w)
    eq(#cheap.orders, 0, 'under the limit: bought'); eq(cheap.pricey, nil)
    w.requestOver = nil
    eq(#P:plan_item('Fine Runic Parchment Solution', 5, w).orders, 0, 'limit off: bought')
end)

test('planner: a held item we are short of is brought by someone on the network in a safe zone - one who has it all, our zone first', function()
    local P = Planner.new(Config.load(ROOT .. 'data/'))
    local w = world({ ['Water Flask'] = 100 })
    local holders = {
        { name = 'Ann', zone = 'poknowledge', safe = true, have = 50 },
        { name = 'Bob', zone = 'freeporttemple', safe = true, have = 30 },
        { name = 'Tom', zone = 'soldungb', safe = false, have = 100 },
    }
    w.supply = function(i) return i == 'Tungsten Ore' and holders or nil end
    local p = P:plan('O122', 10, w)   -- Tungsten Bits: 2 Tungsten Ore a combine
    local text = lines(p)
    eq(#p.problems, 0, text)
    truthy(text:find('Tungsten Ore 20: Bob brings 20 (has them in freeporttemple)', 1, true), 'our zone first: ' .. text)
    eq(p.orders[1].worker, 'Bob'); truthy(p.orders[1].supply)
    eq(p.steps[1].recipe.id, 'order:tungsten ore:bob'); eq(p.steps[1].combines, 20)
    truthy(lines(P:plan('O122', 20, w)):find('Ann brings 40', 1, true), 'one who has it all')
    local split = P:plan('O122', 35, w)
    eq(#split.problems, 0, lines(split))
    eq(#split.orders, 2); eq(split.orders[1].worker, 'Ann'); eq(split.orders[1].n, 50); eq(split.orders[2].worker, 'Bob'); eq(split.orders[2].n, 20)
    local short = P:plan('O122', 50, w)
    eq(#short.orders, 0, 'nothing ordered when it is not covered')
    truthy(short.problems[1]:find('only 80 on characters in a safe zone, Tom has 100 but is in soldungb, not a safe zone', 1, true), short.problems[1])
    w.supply = function() return {} end
    truthy(P:plan('O122', 10, w).problems[1]:find('; nobody on the network has any', 1, true), 'asked, nobody has it')
    w.noAnswer = function() return { 'Shela', 'Shylain' } end
    local pr = P:plan('O122', 10, w).problems[1]
    truthy(pr:find('; network: no answer about it from Shela, Shylain', 1, true) and not pr:find('nobody', 1, true), pr)
    w.noAnswer = nil
    w.supply = function() return nil end
    truthy(not P:plan('O122', 10, w).problems[1]:find('network', 1, true), 'not asked: nothing said')
end)


test('planner: casting uses the spells this character has, biggest first, without making more than needed', function()
    local P = Planner.new(Config.load(ROOT .. 'data/'))
    local w = world()
    local function has(list) local set = {}; for _, x in ipairs(list) do set[x] = true end; return function(s) return set[s] == true end end
    w.canCast = has({ 'Superior Mass Enchant Silver', 'Greater Mass Enchant Silver', 'Mass Enchant Silver', 'Enchant Silver' })
    local p = P:plan_item('Enchanted Silver Bar', 132, w)
    local text = lines(p)
    truthy(text:find('cast 1 x Superior Mass Enchant Silver (100 each) + 1 x Greater Mass Enchant Silver (20 each) + 2 x Mass Enchant Silver (5 each) + 2 x Enchant Silver (1 each)', 1, true), text)
    truthy(text:find('Silver Bar 132: buy 132', 1, true), text)
    truthy(text:find('Order: 1 cast of Superior Mass Enchant Silver -> 1 cast of Greater Mass Enchant Silver -> 2 casts of Mass Enchant Silver -> 2 casts of Enchant Silver', 1, true), text)
    w.canCast = has({ 'Mass Enchant Silver' })
    text = lines(P:plan_item('Enchanted Silver Bar', 7, w))
    truthy(text:find('cast 2 x Mass Enchant Silver (5 each)', 1, true) and text:find('Silver Bar 10: buy 10', 1, true), text)
    w.canCast = has({ 'Superior Mass Enchant Silver', 'Enchant Silver' })
    text = lines(P:plan_item('Enchanted Silver Bar', 3, w))
    truthy(text:find('cast 3 x Enchant Silver (1 each)', 1, true), 'small need, small spell: ' .. text)
end)

test('crew: a worker can cast an item with any of its spells', function()
    local Crew = require('engine.crew')
    local c = Crew.new({ producers = Config.load(ROOT .. 'data/').producers, book = function(s) return s == 'Enchant Velium' end })
    local items = c:can_cast()
    eq(#items, 1); eq(items[1], 'Enchanted Velium Bar')
end)

test('planner: every converted recipe plans without an error', function()
    local cfg = Config.load(ROOT .. 'data/')
    local P = Planner.new(cfg)
    local n, blocked, clean = 0, 0, 0
    local w = world()
    w.kit = function() return true end
    for id in pairs(cfg.recipes) do
        local ok, plan = pcall(P.plan, P, id, 1, w)
        truthy(ok, id .. ': ' .. tostring(plan))
        local okd, d = pcall(Planner.describe, plan)
        truthy(okd, id .. ' describe: ' .. tostring(d))
        n = n + 1
        if #plan.problems > 0 then blocked = blocked + 1 else clean = clean + 1 end
    end
    truthy(n > 11000, 'recipes: ' .. n)
    realPrint(string.format('        (%d recipes: %d fully supplied by vendors/subcombines with empty bags, %d need held items or more)', n, clean, blocked))
end)

realPrint('jobs')
test('plan, preflight and execute run in order', function()
    local c, log = clock(), fake_log()
    local r, order = new_runner(c, log), {}
    r:add({ name = 'J',
        plan = function() order[#order + 1] = 'plan'; return R.ok({ n = 2 }) end,
        preflight = function(_, p) order[#order + 1] = 'pre' .. p.n; return { { level = 'ok', text = 'fine' } } end,
        execute = function(_, p) order[#order + 1] = 'exec' .. p.n; return R.ok({ summary = 'two' }) end })
    r:step()
    eq(table.concat(order, ','), 'plan,pre2,exec2')
    truthy(r.last.ok); truthy(log.has('Done: J %- two'))
end)
test('a blocking preflight check stops before execute', function()
    local c, log = clock(), fake_log()
    local r, ran = new_runner(c, log), false
    r:add({ name = 'J', preflight = function() return { { level = 'block', text = 'need 4 free slots' } } end,
            execute = function() ran = true end })
    r:step()
    eq(ran, false, 'executed'); eq(r.last.why, 'preflight'); eq(r.last.detail, 'need 4 free slots')
end)
test('confirm waits for Go; Cancel ends it', function()
    local c, log = clock(), fake_log()
    local r, ran = new_runner(c, log), 0
    local job = function() return { name = 'J', confirm = true, execute = function() ran = ran + 1 end } end
    r:add(job()); r:step()
    eq(r:view().active.phase, 'awaiting'); r:step(); eq(ran, 0, 'ran without Go')
    r:approve(); r:step(); eq(ran, 1, 'ran after Go')
    r:add(job()); r:step(); r:cancel(); r:step()
    eq(ran, 1, 'ran after Cancel'); eq(r.last.why, 'cancelled')
end)
test('Stop lands at the next wait and clears the queue', function()
    local c, log = clock(), fake_log()
    local r, after = new_runner(c, log), false
    r:add({ name = 'Long', execute = function(ctx)
        local w = ctx:wait(10000)
        if not w.ok then return w end
        after = true
    end })
    r:add({ name = 'Queued', execute = function() end })
    c.cmd_at(500, function() r:stop() end)
    r:step()
    eq(after, false, 'kept going after Stop'); eq(r.last.why, 'stopped'); eq(#r.queue, 0, 'queue')
    truthy(c.t < 700, 'stopped promptly (t=' .. c.t .. ')')
    r:add({ name = 'Next', execute = function() end }); r:step()
    truthy(r.last.ok, 'a new job after Stop runs normally')
end)
test('Pause holds the clock and Resume continues', function()
    local c, log = clock(), fake_log()
    local r = new_runner(c, log)
    local waited
    r:add({ name = 'J', execute = function(ctx)
        local t0 = c.now(); ctx:wait(1000); waited = c.now() - t0
    end })
    c.cmd_at(300, function() r:pause() end)
    c.cmd_at(2300, function() r:resume() end)
    r:step()
    -- 1000 of waiting + about 2000 paused (pause and resume are noticed at the next frame)
    truthy(waited >= 2900 and waited < 3100, 'wall time ' .. waited)
end)
test('a pace ends on the frame nearest its target, not always the frame after', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    F.frameMs = 33                                   -- about 30 frames a second, as in game
    local runner = Jobs.new({ delay = F.mq.delay, now = F.mq.gettime, doevents = F.mq.doevents, log = fake_log() })
    local gaps = {}
    runner:add({ name = 'p', execute = function(ctx)
        -- no other wait has slept first (as in game when every click takes at once): the pace measures the frame itself
        for _, ms in ipairs({ 100, 67, 115, 10, 35, 50 }) do
            local t0 = F.now
            ctx:pace(ms)
            gaps[#gaps + 1] = { ms, F.now - t0 }
        end
        return R.ok()
    end })
    runner:step()
    for _, g in ipairs(gaps) do
        truthy(math.abs(g[2] - g[1]) <= 33 / 2, string.format('pace(%d) took %d', g[1], g[2]))
    end
    eq(gaps[1][2], 99, '100 lands on the 99ms frame, not 132')
end)
test('pacing takes the time asked for', function()
    for _, frame in ipairs({ 1, 16, 33 }) do
        local c, log = clock(frame), fake_log()
        local r, took = new_runner(c, log), nil
        r:add({ name = 'P', execute = function(ctx) local t0 = c.now(); ctx:pace(75); took = c.now() - t0 end })
        r:step()
        -- the frame nearest 75: never more than half a frame off either way
        truthy(math.abs(took - 75) <= frame / 2, string.format('pace(75) at %dms frames took %d', frame, took))
    end
end)
test('wait returns as soon as the condition is met, or times out', function()
    local c, log = clock(10), fake_log()
    local r, res1, res2, t1 = new_runner(c, log)
    local flag = false
    c.at(200, function() flag = true end)
    r:add({ name = 'W', execute = function(ctx)
        local t0 = c.now(); res1 = ctx:wait(5000, function() return flag end); t1 = c.now() - t0
        res2 = ctx:wait(100, function() return false end)
    end })
    r:step()
    truthy(res1.ok); truthy(t1 <= 210, 'met at ' .. t1); eq(res2.why, 'timeout')
end)
test('a Lua error fails the job, logs it, and still releases E3', function()
    local c, log = clock(), fake_log()
    local sent = {}
    local e3 = E3.new(function(s) sent[#sent + 1] = s end, log)
    local r = new_runner(c, log, e3)
    r:add({ name = 'Boom', usesToon = true, execute = function() error('kaboom') end })
    r:step()
    eq(r.last.why, 'error'); truthy(log.has('kaboom'), 'logged')
    eq(table.concat(sent, ','), '/e3p on,/e3p off'); eq(e3:held(), false)
end)
test('E3 is only paused for jobs that use the toon', function()
    local c, log = clock(), fake_log()
    local sent = {}
    local r = new_runner(c, log, E3.new(function(s) sent[#sent + 1] = s end, log))
    r:add({ name = 'NoToon', execute = function() end }); r:step()
    eq(#sent, 0)
end)

test('Stop while paused ends the job', function()
    local c, log = clock(), fake_log()
    local r = new_runner(c, log)
    r:add({ name = 'J', execute = function(ctx) return ctx:wait(5000) end })
    c.cmd_at(200, function() r:pause() end)
    c.cmd_at(1000, function() r:stop() end)
    r:step()
    eq(r.last.why, 'stopped'); truthy(c.t < 1200, 'stopped at ' .. c.t)
end)
test('Stop while waiting for Go is reported as stopped', function()
    local c, log = clock(), fake_log()
    local r, ran = new_runner(c, log), false
    r:add({ name = 'J', confirm = true, execute = function() ran = true end })
    r:step(); r:stop(); r:step()
    eq(ran, false); eq(r.last.why, 'stopped')
end)
test('Pause pressed before Go holds the job until Resume', function()
    local c, log = clock(), fake_log()
    local r, startedAt = new_runner(c, log), nil
    r:add({ name = 'J', confirm = true, execute = function() startedAt = c.now() end })
    r:step(); r:pause(); r:approve()
    c.cmd_at(1500, function() r:resume() end)
    r:step()
    truthy(startedAt and startedAt >= 1500, 'started at ' .. tostring(startedAt))
end)
test('returning false is a failure, not success', function()
    local c, log = clock(), fake_log()
    local r = new_runner(c, log)
    r:add({ name = 'J', execute = function() return false end }); r:step()
    eq(r.last.ok, false); eq(r.last.why, 'failed')
end)
test('odd return values and checks do not crash the runner', function()
    local c, log = clock(), fake_log()
    local r = new_runner(c, log)
    r:add({ name = 'A', execute = function() return R.ok({ summary = {} }) end }); r:step()
    truthy(r.last.ok, 'table summary')
    r:add({ name = 'B', preflight = function() return { 5, { level = 'warn', text = 'w' } } end, execute = function() end })
    r:step()
    truthy(r.last.ok, 'non-table check skipped')
end)
test('E3 is paused for a toon job and resumed when it succeeds', function()
    local c, log = clock(), fake_log()
    local e3, sent = e3_recorder(log)
    local r, during = new_runner(c, log, e3), nil
    r:add({ name = 'J', usesToon = true, execute = function() during = e3:held() end }); r:step()
    eq(during, true, 'held during execute'); eq(table.concat(sent, ','), '/e3p on,/e3p off')
end)
test('a runner error is contained: job cleared, E3 handed back', function()
    local c, log = clock(), fake_log()
    local e3, sent = e3_recorder(log)
    local r = new_runner(c, log, e3)
    local realFinish = r.finish
    local broke = false
    r.finish = function(self, res)
        if not broke then broke = true; error('finish exploded') end
        return realFinish(self, res)
    end
    r:add({ name = 'J', usesToon = true, execute = function() end })
    local ok, err = xpcall(function() r:step() end, debug.traceback)
    eq(ok, false, 'step raised')
    r:abort(err)
    eq(r.active, nil, 'job cleared'); eq(e3:held(), false, 'E3 released'); eq(sent[#sent], '/e3p off')
    r:add({ name = 'K', execute = function() end }); r:step(); truthy(r.last.ok, 'runner still works')
end)

realPrint('window')
test('a drawing error is reported once and leaves ImGui balanced', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    local log = fake_log()
    package.loaded['ui.window'] = nil
    local Window = require('ui.window')
    local w = Window.new({ ImGui = F.ImGui, version = 'x', log = { recent = function() return {} end, error = log.error },
        runner = { view = function() error('view broke') end } })
    F.render = function() w:draw() end
    F.draw(); F.draw()
    eq(F.depth, 0, 'depth'); truthy(log.has('view broke'), 'reported')
    local n = 0; for _, l in ipairs(log.lines) do if l:find('view broke') then n = n + 1 end end
    eq(n, 1, 'reported once')
end)

realPrint('blocks (simulated character)')
local function block_env()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    for _, m in ipairs({ 'blocks.inventory', 'blocks.windows', 'blocks.cursor', 'blocks.spawns', 'blocks.nav', 'blocks.merchant',
                         'blocks.combine', 'blocks.kit', 'blocks.station', 'blocks.bank' }) do package.loaded[m] = nil end
    local inv = require('blocks.inventory').new(F.mq)
    local win = require('blocks.windows').new(F.mq, nil)
    local paces = { item = 0 }
    local cur = require('blocks.cursor').new({ mq = F.mq, inventory = inv, windows = win, itemPace = function() return paces.item end })
    local log = fake_log()
    local spawns = require('blocks.spawns').new(F.mq)
    local nav = require('blocks.nav').new({ mq = F.mq, spawns = spawns })
    local merchant = require('blocks.merchant').new({ mq = F.mq, spawns = spawns, windows = win, inventory = inv, cursor = cur })
    local runner = Jobs.new({ delay = F.mq.delay, now = F.mq.gettime, doevents = F.mq.doevents, log = log })
    local combine = require('blocks.combine').new({ mq = F.mq, inventory = inv, cursor = cur })
    local kit = require('blocks.kit').new({ mq = F.mq, inventory = inv, cursor = cur, windows = win, combine = combine })
    local station = require('blocks.station').new({ mq = F.mq, inventory = inv, cursor = cur, windows = win, combine = combine })
    local bank = require('blocks.bank').new({ mq = F.mq, spawns = spawns, inventory = inv, cursor = cur, windows = win })
    local env = { F = F, G = G, inv = inv, win = win, cur = cur, log = log, paces = paces,
                  spawns = spawns, nav = nav, merchant = merchant, runner = runner, kit = kit, station = station, bank = bank }
    -- Run fn(ctx) as a job and return what it returned.
    function env.run(fn)
        local out
        runner:add({ name = 't', execute = function(ctx) out = fn(ctx); return out end })
        runner:step()
        return out
    end
    return env
end

test('inventory counts bags and loose slots, finds every stack, ignores case', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Water Flask', 20); e.G:put(1, 4, 'Water Flask', 5)
    e.G:put(2, nil, 'water flask', 1)
    eq(e.inv:count('Water Flask'), 26)
    local f = e.inv:find('WATER FLASK'); eq(#f, 3); eq(f[2].slot, 4); eq(f[3].slot, nil)
    eq(e.inv:free_slots(), 8)
    eq(e.inv:bag(1).used, 2); eq(e.inv:bag(2), nil, 'loose item is not a bag')
end)
test('inventory reads slot by slot whatever window is open; client_total is the client count minus the cursor', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 4, 'Water Flask', 20); e.G:hold('Water Flask', 3)
    e.G:window('TradeskillWnd', true)
    local places = e.inv:find('Water Flask')
    eq(#places, 1); eq(places[1].slot, 4); eq(e.inv:count('Water Flask'), 20)
    eq(e.inv:client_total('Water Flask'), 20)
end)
test('stow puts queued cursor items away one at a time, each confirmed', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:hold('Gold Bar', 5); e.G:hold('Silver Bar', 2); e.G:hold('Jade', 1)
    local r = e.run(function(ctx) return e.cur:stow(ctx) end)
    truthy(r.ok, R.describe(r)); eq(r.value, 3); eq(#e.G.cursor, 0)
    eq(e.G:count('Gold Bar'), 5); eq(e.G:count('Jade'), 1)
end)
test('item pace: the next item starts no sooner than ItemPaceMs after the last, counting time already spent', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:hold('Gold Bar', 1); e.G:hold('Jade', 1); e.G:hold('Ruby', 1)
    e.G.latency = 100
    e.paces.item = 300
    local t0 = e.F.now
    local r = e.run(function(ctx) return e.cur:stow(ctx) end)
    truthy(r.ok)
    local took = e.F.now - t0
    -- three items: the 2nd and 3rd start 300ms after the one before (each 100ms round trip counts toward
    -- it), the 3rd still takes its own 100ms; nothing waits after the last. Waits can end a frame late.
    truthy(took >= 700 and took <= 700 + 4 * e.F.frameMs, 'took ' .. took)
    e.paces.item = 0
    e.G:hold('Topaz', 1); e.G:hold('Opal', 1)
    t0 = e.F.now
    e.run(function(ctx) return e.cur:stow(ctx) end)
    -- just the two 100ms round trips, each able to end up to two frames late
    truthy(e.F.now - t0 <= 200 + 4 * e.F.frameMs, '0 = no wait at all (took ' .. (e.F.now - t0) .. ')')
end)
test('a lost /autoinventory is sent again after STOW_RESEND_MS, not waited out', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10)
    e.G.cursor = { { id = 5001, name = 'Platinum Jasper Ring', stack = 1 } }
    e.G.autoinvIgnores = 1
    local t0 = e.F.now
    local r = e.run(function(ctx) return e.cur:stow(ctx) end)
    truthy(r.ok, R.describe(r))
    eq(e.G:count('Platinum Jasper Ring'), 1)
    local sends = 0; for _, c in ipairs(e.G.log) do if c == '/autoinventory' then sends = sends + 1 end end
    eq(sends, 2, 'sent twice')
    truthy(e.F.now - t0 < 700, 'took ' .. (e.F.now - t0) .. 'ms, not the whole wait')
end)

test('stow reports full bags, and a stow that does not land (cursor stuck) without guessing why', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 1); e.G:put(1, 1, 'Ruby', 1); e.G:hold('Jade', 1)
    local r = e.run(function(ctx) return e.cur:stow(ctx) end)
    eq(r.why, 'bags full')
    e.G.packs[1].items[1] = nil; e.G.autoinvBlocked = true
    r = e.run(function(ctx) return e.cur:stow(ctx) end)
    eq(r.why, 'cursor stuck')
end)
test('stow: what /autoinventory will not take is put by hand into a bag that takes it; every bag is logged (2.43.10)', function()
    local e = block_env()
    e.log = fake_log(); e.cur.log = e.log
    package.loaded['blocks.kitslot'] = nil
    local ks = require('blocks.kitslot').new({ mq = e.F.mq, cursor = e.cur, windows = e.win, log = e.log,
        tsOnly = function(n) return (n or ''):lower() == "artisan's adept attache" end, isKit = function() return false end })
    e.cur.by_hand = function(ctx) return ks:stow_by_hand(ctx) end
    e.G:bag(1, "Artisan's Adept Attache", 4); e.G:bag(2, 'Backpack', 2); e.G:put(2, 1, 'Ruby', 1)
    e.G:hold('Brut Champagne', 1); e.G.autoinvBlocked = true
    local r = e.run(function(ctx) return e.cur:stow(ctx) end)
    truthy(r.ok, R.describe(r)); eq(e.G.packs[2].items[2] and e.G.packs[2].items[2].name, 'Brut Champagne', 'in the Backpack, not the Attache')
    truthy(e.log.has("pack1 Artisan's Adept Attache 4/4 free, tradeskill only"), 'bags logged')
    truthy(e.log.has('Put Brut Champagne by hand into Backpack'), 'said where')
    -- nowhere it fits: said, and the cursor is still stuck
    e.G:hold('Patty Melt', 1)
    local r2 = e.run(function(ctx) return e.cur:stow(ctx) end)
    eq(r2.why, 'cursor stuck'); truthy(e.log.has('no bag with a free slot takes Patty Melt'), 'why')
end)
test('pick up one from a stack uses ctrl-click', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 3, 'Water Flask', 20)
    local r = e.run(function(ctx) return e.cur:pick_up(ctx, 'Water Flask', 1) end)
    truthy(r.ok, R.describe(r)); eq(r.value.stack, 1); eq(e.G:count('Water Flask'), 19)
    truthy(e.G.log[#e.G.log]:find('/ctrlkey', 1, true), 'ctrl-click used')
end)
test('pick up part of a stack opens the bag, sets the amount, and leaves the bag open for the caller', function()
    local e = block_env()
    e.G:bag(2, 'Backpack', 10); e.G:put(2, 7, 'Water Flask', 20)
    local r = e.run(function(ctx) return e.cur:pick_up(ctx, 'Water Flask', 5) end)
    truthy(r.ok, R.describe(r)); eq(r.value.stack, 5); eq(r.value.openedPack, 2)
    eq(e.G:count('Water Flask'), 15); eq(e.G.packs[2].open, true)
    local c = e.run(function(ctx) local s = e.cur:stow(ctx); if not s.ok then return s end; return e.win:close_bag(ctx, 2) end)
    truthy(c.ok, R.describe(c)); eq(e.G.packs[2].open, false); eq(e.G:count('Water Flask'), 20)
end)
test('pick up a whole stack takes it in one click', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Water Flask', 20); e.G:put(1, 2, 'Water Flask', 7)
    local before = #e.G.log
    local r = e.run(function(ctx) return e.cur:pick_up(ctx, 'Water Flask', 7) end)
    truthy(r.ok, R.describe(r)); eq(r.value.stack, 7); eq(r.value.openedPack, 1); eq(e.G:count('Water Flask'), 20)
    local slotClicks = 0
    for i = before + 1, #e.G.log do if e.G.log[i]:find('/itemnotify in pack', 1, true) then slotClicks = slotClicks + 1 end end
    eq(slotClicks, 1, 'slot clicks')
end)
test('a click is never sent into a closed bag', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Water Flask', 20)
    for _, n in ipairs({ 1, 5, 20 }) do
        e.G.packs[1].open = false; e.G.bagOrder = {}
        local r = e.run(function(ctx)
            local got = e.cur:pick_up(ctx, 'Water Flask', n)
            if not got.ok then return got end
            local s = e.cur:stow(ctx); if not s.ok then return s end
            return R.ok(got.value)
        end)
        truthy(r.ok, n .. ': ' .. R.describe(r)); eq(r.value.stack, n)
    end
    eq(e.G:count('Water Flask'), 20)
end)
test('pick up refuses a missing item and an amount no stack holds; puts away what is already on the cursor', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Jade', 3)
    eq(e.run(function(ctx) return e.cur:pick_up(ctx, 'Ruby', 1) end).why, 'not found')
    eq(e.run(function(ctx) return e.cur:pick_up(ctx, 'Jade', 4) end).why, 'not enough in one stack')
    -- something already on the cursor (a mouse program, a click by hand) is put away first, and the pickup goes on
    e.G:hold('Gold Bar', 1)
    local r = e.run(function(ctx) return e.cur:pick_up(ctx, 'Jade', 1) end)
    truthy(r.ok, R.describe(r)); eq(e.G:count('Gold Bar'), 1, 'put away'); eq(e.G.cursor[1].name, 'Jade')
end)
test('something else landing on the cursor during a pickup click (a mouse program) is put away and the pickup tried again', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Short Beer', 10)
    local orig, once = e.G.command, true
    e.G.command = function(self, s)
        if once and s:find('/ctrlkey /itemnotify in pack1 1', 1, true) then
            once = false; self.log[#self.log + 1] = s
            self:hold('Brazier of the Ruined Lands', 1)   -- the click is lost; the Brazier lands instead
            return
        end
        return orig(self, s)
    end
    local r = e.run(function(ctx) return e.cur:pick_up(ctx, 'Short Beer', 1) end)
    truthy(r.ok, R.describe(r)); eq(e.G.cursor[1].name, 'Short Beer')
    eq(e.G:count('Brazier of the Ruined Lands'), 1, 'put away in the bags')
end)
test('a pickup that hands over the wrong amount is put back and reported', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Water Flask', 20)
    e.G.qtyIgnoresText = true
    local r = e.run(function(ctx) return e.cur:pick_up(ctx, 'Water Flask', 5) end)
    eq(r.why, 'wrong pickup'); truthy(r.detail:find('x20', 1, true), r.detail)
    eq(#e.G.cursor, 0, 'cursor cleared'); eq(e.G:count('Water Flask'), 20, 'all back in bags')
end)
test('windows close each their own way, and a stuck window is reported', function()
    local e = block_env()
    e.G:window('TradeskillWnd', true); e.G:window('ContainerCombine_Items', true)
    truthy(e.run(function(ctx) return e.win:close(ctx, 'TradeskillWnd') end).ok)
    truthy(e.run(function(ctx) return e.win:close(ctx, 'ContainerCombine_Items') end).ok)
    eq(e.G:win('TradeskillWnd').open, false); eq(e.G:win('ContainerCombine_Items').open, false)
    local esc = 0; for _, c in ipairs(e.G.log) do if c == '/keypress esc' then esc = esc + 1 end end
    eq(esc, 1, 'only the combine window used Esc')
    e.G:window('TradeskillWnd', true); e.G.stuck.tradeskillwnd = true
    local r = e.run(function(ctx) return e.win:close(ctx, 'TradeskillWnd') end)
    eq(r.why, 'timeout'); truthy(r.detail:find('did not close', 1, true))
end)
test('a bag right-click that changes nothing is sent again (the first one after Esc is lost in game)', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10)
    e.G.bagClickIgnores = 1
    local r = e.run(function(ctx) return e.win:open_bag(ctx, 1) end)
    truthy(r.ok, tostring(r.detail)); eq(e.G.packs[1].open, true)
    local n = 0; for _, c in ipairs(e.G.log) do if c == '/nomodkey /itemnotify pack1 rightmouseup' then n = n + 1 end end
    eq(n, 2, 'clicked twice')
    e.G.bagClickIgnores = 10
    local r2 = e.run(function(ctx) return e.win:close_bag(ctx, 1) end)
    eq(r2.why, 'timeout'); truthy(r2.detail:find('4 right-clicks', 1, true), r2.detail)
end)
test('opening a bag that is already open does not click it', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G.packs[1].open = true
    local before = #e.G.log
    truthy(e.run(function(ctx) return e.win:open_bag(ctx, 1) end).ok)
    eq(#e.G.log, before, 'no click sent')
end)
test('Stop during a pickup wait ends it cleanly', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G.packs[1].open = true; e.G:put(1, 1, 'Water Flask', 20)
    e.G.setTextIgnored = true   -- the pickup sits waiting for the amount field
    local runner = Jobs.new({ delay = e.F.mq.delay, now = e.F.mq.gettime, doevents = e.F.mq.doevents, log = e.log })
    local out
    runner:add({ name = 'p', execute = function(ctx) out = e.cur:pick_up(ctx, 'Water Flask', 5); return out end })
    e.F.at(e.F.now + 300, function() e.F.pending[#e.F.pending + 1] = { fn = function() runner:stop() end, args = {} } end)
    runner:step()
    eq(out.why, 'stopped')
end)

test('stow handles two identical items queued on the cursor', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:hold('Jade', 1); e.G:hold('Jade', 1)
    local r = e.run(function(ctx) return e.cur:stow(ctx) end)
    truthy(r.ok, R.describe(r)); eq(r.value, 2); eq(e.G:count('Jade'), 2)
end)
test('with no free slots, stow still tops up an existing stack', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 1); e.G:put(1, 1, 'Water Flask', 19); e.G:hold('Water Flask', 1)
    local r = e.run(function(ctx) return e.cur:stow(ctx) end)
    truthy(r.ok, R.describe(r)); eq(e.G:count('Water Flask'), 20)
end)
test('a split skips a loose pack-slot stack and uses a bag slot', function()
    local e = block_env()
    e.G:put(3, nil, 'Water Flask', 10); e.G:bag(1, 'Backpack', 10); e.G:put(1, 5, 'Water Flask', 20)
    local r = e.run(function(ctx) return e.cur:pick_up(ctx, 'Water Flask', 5) end)
    truthy(r.ok, R.describe(r)); eq(e.G.packs[1].items[5].stack, 15, 'taken from the bag slot')
end)
test('a failed split closes the bag it opened', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Water Flask', 20); e.G.qtyIgnoresText = true
    local r = e.run(function(ctx) return e.cur:pick_up(ctx, 'Water Flask', 5) end)
    eq(r.why, 'wrong pickup'); eq(e.G.packs[1].open, false, 'bag closed'); eq(r.openedPack, nil)
end)
test('close works with any capitalisation of the window name', function()
    local e = block_env()
    e.G:window('ContainerCombine_Items', true)
    local r = e.run(function(ctx) return e.win:close(ctx, 'containercombine_items') end)
    truthy(r.ok, R.describe(r)); eq(e.G:win('ContainerCombine_Items').open, false)
end)
test('Esc keeps going until it reaches the window it was meant for', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:window('ContainerCombine_Items', true)
    truthy(e.run(function(ctx) return e.win:open_bag(ctx, 1) end).ok)
    local t0 = e.F.now
    local r = e.run(function(ctx) return e.win:close(ctx, 'ContainerCombine_Items') end)
    truthy(r.ok, R.describe(r)); eq(e.G:win('ContainerCombine_Items').open, false)
    truthy(e.F.now - t0 < 150, 'pressed again on the next frame, no 1s waits (took ' .. (e.F.now - t0) .. 'ms)')
end)
test('DoClose is never used on the combine window', function()
    local e = block_env()
    e.G:window('ContainerCombine_Items', true)
    e.run(function(ctx) return e.win:close(ctx, 'ContainerCombine_Items') end)
    for _, c in ipairs(e.G.log) do truthy(not c:find('DoClose', 1, true), 'no DoClose sent') end
end)
test('Stop mid-split: cleanup closes the split window, empties the cursor and closes the bag', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Water Flask', 20)
    local runner = Jobs.new({ delay = e.F.mq.delay, now = e.F.mq.gettime, doevents = e.F.mq.doevents, log = e.log })
    local plan = {}
    runner:add({ name = 'p',
        execute = function(ctx)
            local got = e.cur:pick_up(ctx, 'Water Flask', 5)
            plan.openedPack = got.ok and got.value.openedPack or got.openedPack or 1
            return got
        end,
        cleanup = function(ctx)
            e.win:close(ctx, 'QuantityWnd')
            e.cur:stow(ctx)
            if e.cur:is_empty() then return e.win:close_bag(ctx, plan.openedPack) end
        end })
    -- The amount never takes, so the job sits with the split window open until Stop
    e.G.setTextIgnored = true
    e.F.at(e.F.now + 260, function() e.F.pending[#e.F.pending + 1] = { fn = function() runner:stop() end, args = {} } end)
    runner:step()
    eq(runner.last.why, 'stopped')
    eq(e.G:win('QuantityWnd').open, false, 'split window closed')
    eq(#e.G.cursor, 0, 'cursor empty'); eq(e.G.packs[1].open, false, 'bag closed')
    eq(e.G:count('Water Flask'), 20, 'nothing lost')
end)

test('a click lost straight after a bag opens is re-sent on the next frame, with no fixed wait', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Water Flask', 20)
    e.G.bagReadyMs = 10   -- as in game: the first click into a just-opened bag is lost
    local t0 = e.F.now
    local r = e.run(function(ctx) return e.cur:pick_up(ctx, 'Water Flask', 5) end)
    truthy(r.ok, R.describe(r)); eq(r.value.stack, 5); eq(r.value.clicks, 2, 'clicks')
    truthy(e.F.now - t0 <= 3 * e.F.frameMs, 'took ' .. (e.F.now - t0) .. 'ms')
end)
test('a bag that ignores every click is reopened three times, then reported', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G.packs[1].open = true; e.G:put(1, 1, 'Water Flask', 20)
    e.G.lostClicks = 99
    local r = e.run(function(ctx) return e.cur:pick_up(ctx, 'Water Flask', 1) end)
    eq(r.why, 'pickup failed'); truthy(r.detail:find('12 click(s) and 3 reopen(s)', 1, true), r.detail)
    local clicks = 0; for _, c in ipairs(e.G.log) do if c:find('itemnotify in pack', 1, true) then clicks = clicks + 1 end end
    eq(clicks, 12)
    eq(e.G.packs[1].open, true, 'a bag the caller had open is left open')
end)

test('a bag that ignores clicks is closed and reopened, and the pickup goes through with no fixed wait', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Water Flask', 20)
    e.G.deafOpens = 2
    local t0 = e.F.now
    local r = e.run(function(ctx) return e.cur:pick_up(ctx, 'Water Flask', 5) end)
    truthy(r.ok, R.describe(r))
    eq(r.value.reopens, 2); eq(r.value.clicks, 7); eq(r.value.stack, 5)
    truthy(e.F.now - t0 < 400, 'took ' .. (e.F.now - t0) .. 'ms')
end)

test('when every click is ignored, the pickup fails at once instead of waiting out the timeout', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G.packs[1].open = true; e.G:put(1, 1, 'Water Flask', 20)
    e.G.lostClicks = 99
    local t0 = e.F.now
    local r = e.run(function(ctx) return e.cur:pick_up(ctx, 'Water Flask', 5) end)
    eq(r.why, 'pickup failed')
    truthy(e.F.now - t0 < 200, 'failed in ' .. (e.F.now - t0) .. 'ms')
end)

test('probe clicks until the lockout ends, reports how long, and moves nothing', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Water Flask', 20)
    e.G.ignoreUntil = e.F.now + 1500
    local r = e.run(function(ctx) return e.cur:probe(ctx, 'Water Flask', 100, 5000) end)
    truthy(r.ok, R.describe(r))
    truthy(r.value.ms >= 1500 and r.value.ms < 1700, 'took after ' .. r.value.ms .. 'ms')
    eq(e.G:count('Water Flask'), 20); eq(#e.G.cursor, 0); eq(e.G:win('QuantityWnd').open, false)
    e.G.ignoreUntil = e.F.now + 99999
    local r2 = e.run(function(ctx) return e.cur:probe(ctx, 'Water Flask', 100, 1000) end)
    eq(r2.why, 'still ignored')
end)

test('spawns: exact name only, nearest first, by id afterwards', function()
    local e = block_env()
    e.G:spawn('Audri Deepfacet the Elder', 10, 0, 0)
    local far = e.G:spawn('Audri Deepfacet', 300, 0, 0)
    local near = e.G:spawn('Audri Deepfacet', 100, 0, 0)
    local s = e.spawns:find('audri deepfacet')
    eq(s.id, near); eq(s.name, 'Audri Deepfacet'); eq(math.floor(s.distance), 100)
    eq(e.spawns:find('Nobody'), nil)
    truthy(e.spawns:get(far)); eq(e.spawns:get(9999), nil)
    local r = e.run(function(ctx) return e.spawns:target(ctx, far) end)
    truthy(r.ok, R.describe(r)); eq(e.G.targetId, far)
end)

test('nav: travels, measures the distance on arrival, reports time', function()
    local e = block_env()
    local id = e.G:spawn('Brewmaster Berina', 0, 500, 0)
    local r = e.run(function(ctx) return e.nav:go_spawn(ctx, id, 10) end)
    truthy(r.ok, R.describe(r))
    eq(r.value.tries, 1)
    truthy(r.value.distance <= 10.01, 'distance ' .. r.value.distance)
    truthy(r.value.ms >= 9700 and r.value.ms <= 10000, 'took ' .. r.value.ms .. 'ms for 490 units at 50/s')
    local r2 = e.run(function(ctx) return e.nav:go_spawn(ctx, id, 10) end)
    eq(r2.value.tries, 0, 'already there: nothing sent')
end)

test('nav: one that does not start, or ends short, is sent again', function()
    local e = block_env()
    local id = e.G:spawn('Brewmaster Berina', 0, 200, 0)
    e.G.navIgnores = 1
    local r = e.run(function(ctx) return e.nav:go_spawn(ctx, id, 10) end)
    truthy(r.ok, R.describe(r)); eq(r.value.tries, 2)
    local id2 = e.G:spawn('Audri Deepfacet', 0, -200, 0)
    e.G.navStopsShortBy = 40
    local r2 = e.run(function(ctx) return e.nav:go_spawn(ctx, id2, 10) end)
    truthy(r2.ok, R.describe(r2)); eq(r2.value.tries, 2); truthy(r2.value.distance <= 10.01)
end)

test('nav: stuck is caught by lack of movement, retried, then reported; no path fails at once', function()
    local e = block_env()
    local id = e.G:spawn('Brewmaster Berina', 0, 300, 0)
    e.G.stuckAt = 150
    local t0 = e.F.now
    local r = e.run(function(ctx) return e.nav:go_spawn(ctx, id, 10) end)
    eq(r.why, 'did not arrive'); truthy(r.detail:find('3 tries', 1, true), r.detail)
    eq(e.G.nav.active, false, 'nav stopped')
    local spent = e.F.now - t0
    truthy(spent < 3000 + 3 * 3200, 'gave up in ' .. spent .. 'ms')
    local id2 = e.G:spawn('Audri Deepfacet', 0, -300, 0)
    e.G.noPath[id2] = true
    local r2 = e.run(function(ctx) return e.nav:go_spawn(ctx, id2, 10) end)
    eq(r2.why, 'no path')
end)

test('nav: Pause stops the toon where it is, Resume carries on, Stop stops it', function()
    local e = block_env()
    local id = e.G:spawn('Brewmaster Berina', 0, 500, 0)
    local out, atPause, atResume
    e.runner:add({ name = 'n', execute = function(ctx) out = e.nav:go_spawn(ctx, id, 10); return out end })
    e.F.at(2000, function() e.F.pending[#e.F.pending + 1] = { fn = function() e.runner:pause() end, args = {} } end)
    e.F.at(2500, function() atPause = e.G.me.y end)
    e.F.at(5000, function() atResume = e.G.me.y; e.F.pending[#e.F.pending + 1] = { fn = function() e.runner:resume() end, args = {} } end)
    e.runner:step()
    truthy(out.ok, R.describe(out))
    eq(atPause, atResume, 'did not move while paused')
    truthy(out.value.distance <= 10.01)
    local id2 = e.G:spawn('Audri Deepfacet', 0, -500, 0)
    e.runner:add({ name = 'n2', execute = function(ctx) out = e.nav:go_spawn(ctx, id2, 10); return out end })
    e.F.at(e.F.now + 1000, function() e.F.pending[#e.F.pending + 1] = { fn = function() e.runner:stop() end, args = {} } end)
    e.runner:step()
    eq(out.why, 'stopped'); eq(e.G.nav.active, false, 'toon stopped')
end)

test('routes: an avoid box (Marr\'s fountain) - stepped out of, gone round the shorter way, never crossed', function()
    local cfg = Config.load(ROOT .. 'data/')
    local Routes = require('blocks.routes')
    local box = cfg.nav.freeporttemple.avoid and cfg.nav.freeporttemple.avoid[1]
    truthy(box and #box.pts == 4 and box.margin == 10, 'nav.ini Avoid1 loads')
    local z = { avoid = { box } }
    -- the box's own corners: is a point inside it (2D)
    local function inside(p)
        local c, n = false, #box.pts
        for i = 1, n do
            local a, b = box.pts[i], box.pts[i % n + 1]
            if ((a[1] > p[1]) ~= (b[1] > p[1])) and (p[2] < (b[2] - a[2]) * (p[1] - a[1]) / (b[1] - a[1]) + a[2]) then c = not c end
        end
        return c
    end
    local function crosses(a, b)   -- sample the stretch
        for t = 0, 1, 0.02 do if inside({ a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t }) then return true end end
        return false
    end
    local function walk(me, dest)
        local plan = Routes.plan(z, me, dest, false)
        local pts = { me }
        for _, l in ipairs(plan.legs) do pts[#pts + 1] = l end
        pts[#pts + 1] = dest
        return plan.legs, pts
    end
    -- straight through it (north to south): round it, no stretch inside
    local legs, pts = walk({ 300, 0, 0 }, { 0, 0, 0 })
    truthy(#legs >= 2, 'went round: ' .. #legs .. ' legs')
    for i = 1, #pts - 1 do truthy(not crosses(pts[i], pts[i + 1]), 'stretch ' .. i .. ' clear') end
    truthy(legs[1].why:find('round Avoid1', 1, true), legs[1].why)
    -- standing in it: out first
    legs, pts = walk({ 150, 0, 0 }, { 400, 0, 0 })
    truthy(legs[1] and legs[1].why == 'out of Avoid1' and not inside(legs[1]), 'stepped out first')
    for i = 2, #pts - 1 do truthy(not crosses(pts[i], pts[i + 1]), 'then clear ' .. i) end
    -- not near it: nothing added
    legs = walk({ 300, 200, 0 }, { 300, -200, 0 })
    eq(#legs, 0, 'a walk clear of it is left alone')
    -- the walk off the zone-in to Tomas uses the same rule
    local a = Routes.avoid(z, { 150, 0, 0 }, { 400, 0, 0 })
    eq(a[1] and a[1].why, 'out of Avoid1')
    -- a box with its floor height (Avoid2, the pillars by the docks): its corner legs go at that height, not a
    -- guess between the walk's ends (2.42.16 log: round Avoid2 at -31.42 had no nav path; the floor is -48.6)
    local b2 = cfg.nav.freeporttemple.avoid[2]
    truthy(b2 and b2.z and math.abs(b2.z + 48.575) < 0.01, 'Avoid2 has its floor height: ' .. tostring(b2 and b2.z))
    eq(box.z, nil, 'Avoid1 gives none')
    local l2 = Routes.plan({ avoid = { b2 } }, { 450, 0, -5 }, { 900, 0, -48 }, false).legs
    truthy(#l2 >= 1 and l2[1].why:find('round Avoid2', 1, true), #l2 > 0 and l2[1].why or 'no legs')
    for _, l in ipairs(l2) do truthy(math.abs(l[3] + 48.575) < 0.01, 'at the floor height: ' .. l[3]) end
end)

test('routes: nav.ini loads; hubs, the pocket, side docks and spots in the old order', function()
    local cfg = Config.load(ROOT .. 'data/')
    local Routes = require('blocks.routes')
    local pok = cfg.nav.poknowledge
    eq(#pok.hubs, 4, 'pok hubs'); truthy(pok.pocket.npcs['scholar klaz'], 'pocket npcs')
    local function legs(p) local t = {}; for _, l in ipairs(p.legs) do t[#t + 1] = l.why end; return table.concat(t, ', ') end
    -- standing on Hub3 (within 15: not walked), going to the oven by Hub1: approach via Hub1
    local p = Routes.plan(pok, { 3, 230, -122 }, { -339, 776, -96 }, false)
    eq(legs(p), 'approach via Hub1')
    -- into the pocket for its merchant: pocket hub, dock, and no hubs on top
    p = Routes.plan(pok, { 3, 230, -122 }, { -360, 700, -90, name = 'Scholar Klaz' }, true)
    eq(legs(p), 'the pocket hub, the pocket dock')
    -- merchant to merchant inside the pocket: straight
    eq(#Routes.plan(pok, { -360, 700, -90 }, { -370, 690, -90, name = 'Eric Rasumus' }, true).legs, 0)
    -- out of the pocket to the banker: dock, pocket hub (Hub1 is under it - not walked twice), then Hub4
    p = Routes.plan(pok, { -360, 700, -90 }, { 445, 480, -122, name = 'Banker Ceridan' }, true)
    eq(legs(p), 'the pocket dock (leaving), the pocket hub (leaving), approach via Hub4')
    -- the lower tier under the pocket is not in it
    eq(legs(Routes.plan(pok, { -360, 700, -122 }, { 445, 480, -122 }, false)), 'approach via Hub4')
    -- leaving a hub for open ground: out through it
    eq(legs(Routes.plan(pok, { -430, 470, -122 }, { 900, 900, -122 }, false)), 'leave via Hub2')
    -- side docks (still read, no longer in Marr's - its avoid boxes replaced them, 2.42.13): every walk across the X
    -- sign takes both docks; with near= only close to the dock
    local marr = { docks = { a = { 801.88, -43.21, -50.12 }, b = { 803.01, 44.31, -50.12 } } }
    eq(legs(Routes.plan(marr, { 760, -60, -50 }, { 0, 100, 0 }, false)), 'this side\'s dock, the far side\'s dock')
    eq(legs(Routes.plan(marr, { 760, 60, -50 }, { 0, -100, 0 }, false)), 'this side\'s dock, the far side\'s dock')
    local limited = { docks = { a = marr.docks.a, b = marr.docks.b, near = 100 } }
    eq(Routes.plan(limited, { 260, -100, -11 }, { 0, 100, 0 }, false).legs[1], nil, 'near= given, far from the dock: straight')
    eq(Routes.plan(marr, { 0, 100, 0 }, { 0, 100, 0 }, false).legs[1], nil)
    eq(cfg.nav.freeporttemple.docks, nil, 'Marr\'s has no docks now')
    eq(#cfg.nav.freeporttemple.avoid, 2, 'the fountain and the dock band')
    -- a merchant by a spot is opened from it; a station there is not (spawns only)
    local th = cfg.nav.thurgadina
    p = Routes.plan(th, { 0, 0, 0 }, { -330, -60, 3, name = 'Some Merchant' }, true)
    truthy(p.spot and p.spot.crouch, 'thurgadin spot, crouch')
    eq(Routes.plan(th, { 0, 0, 0 }, { -330, -60, 3 }, false).spot, nil)
    eq(Routes.plan(th, { 0, 0, 0 }, { 300, 300, 3, name = 'Far Away' }, true).spot, nil)
    eq(#Routes.plan(nil, { 0, 0, 0 }, { 1, 1, 1 }, true).legs, 0, 'zone not in nav.ini')
end)

test('nav: walks the zone\'s route first (each leg logged), then the destination', function()
    local e = block_env()
    local cfg = Config.load(ROOT .. 'data/')
    local log = fake_log()
    local nav = require('blocks.nav').new({ mq = e.F.mq, spawns = e.spawns, log = log, nav = cfg.nav })
    e.G.zone = 'poknowledge'
    e.G.me = { x = 230, y = 3, z = -122 }
    local id = e.G:spawn('Baker Somebody', 776, -339, -96)
    local r = e.run(function(ctx) return nav:go_spawn(ctx, id, 10) end)
    truthy(r.ok, R.describe(r))
    local hub, final
    for i, c in ipairs(e.G.log) do
        if c == '/nav loc -358.28 821.90 -92.55 distance=15' then hub = hub or i end
        if c == '/nav id ' .. id .. ' distance=10' then final = final or i end
    end
    truthy(hub and final and hub < final, 'Hub1 walked before the merchant')
    truthy(log.has('Nav: approach via Hub1 first %(1 of 1'), 'leg logged')
    -- the same walk in a zone with no nav.ini entry goes straight
    e.G.zone = 'freeportwest'; e.G.me = { x = 0, y = 0, z = 0 }; e.G.log = {}
    local id2 = e.G:spawn('Plain Merchant', 200, 0, 0)
    truthy(e.run(function(ctx) return nav:go_spawn(ctx, id2, 10) end).ok)
    eq(e.G.log[1], '/nav id ' .. id2 .. ' distance=10', 'no legs')
end)

test('nav: a spot merchant is walked to its spot; crouch when stuck there, stand after; stuck spots are written', function()
    local e = block_env()
    local cfg = Config.load(ROOT .. 'data/')
    local log, stuck = fake_log(), {}
    local nav = require('blocks.nav').new({ mq = e.F.mq, spawns = e.spawns, log = log, nav = cfg.nav,
        stuck = function(line) stuck[#stuck + 1] = line end })
    e.G.zone = 'thurgadina'
    e.G.me = { x = -64, y = -100, z = 3 }
    local id = e.G:spawn('Counter Merchant', -60, -345, 8)
    e.G.stuckAt = 40; e.G.duckFrees = true
    local r = e.run(function(ctx) return nav:go_spawn(ctx, id, 10) end)
    truthy(r.ok, R.describe(r))
    truthy(log.has('Nav: opening from Spot1'), 'spot said')
    local sent = table.concat(e.G.log, '\n')
    truthy(sent:find('/nav loc -337.18 -64.11 3.12 distance=15', 1, true), 'walked to the spot')
    truthy(not sent:find('/nav id ' .. id, 1, true), 'not onto the counter')
    local ducks = 0; for _, c in ipairs(e.G.log) do if c == '/keypress duck' then ducks = ducks + 1 end end
    eq(ducks, 2, 'crouched once, stood once')
    eq(e.G.ducking, false, 'standing at the end')
    eq(#stuck, 1, 'stuck spot written'); truthy(stuck[1]:find('thurgadina | stuck=', 1, true), stuck[1])
    -- a player by the spot (a worker coming to its crafter) is walked to, not the spot
    e.G.stuckAt = nil; e.G.me = { x = -64, y = -100, z = 3 }; e.G.log = {}
    local pc = e.G:spawn('Antilerd', -60, -345, 8, { class = 'PC' })
    truthy(e.run(function(ctx) return nav:go_spawn(ctx, pc, 10) end).ok)
    eq(e.G.log[1], '/nav id ' .. pc .. ' distance=10', 'straight to the player')
end)

test('merchant: opens by id, waits for the full list, closes', function()
    local e = block_env()
    local id = e.G:spawn('Brewmaster Berina', 0, 5, 0, { items = 37 })
    local r = e.run(function(ctx) return e.merchant:open(ctx, id) end)
    truthy(r.ok, R.describe(r))
    eq(r.value.items, 37); eq(r.value.listReady, true); eq(r.value.tries, 1)
    truthy(r.value.openMs >= 150 and r.value.openMs < 200, 'opened in ' .. r.value.openMs)
    local c = e.run(function(ctx) return e.merchant:close(ctx) end)
    truthy(c.ok, R.describe(c)); eq(e.merchant:is_open(), false)
end)

test('merchant: an unanswered open is asked again; a different merchant is reported, not used', function()
    local e = block_env()
    local id = e.G:spawn('Brewmaster Berina', 0, 5, 0)
    e.G.merchantIgnores = 1
    local r = e.run(function(ctx) return e.merchant:open(ctx, id) end)
    truthy(r.ok, R.describe(r)); eq(r.value.tries, 2)
    local cl = 0; for _, c in ipairs(e.G.log) do if c == '/cleanup' then cl = cl + 1 end end
    eq(cl, 1, 'one /cleanup before asking again (2.43.4)')
    e.run(function(ctx) return e.merchant:close(ctx) end)
    local other = e.G:spawn('Audri Deepfacet', 0, 6, 0)
    e.G.wrongMerchant = other
    local r2 = e.run(function(ctx) return e.merchant:open(ctx, id) end)
    eq(r2.why, 'wrong merchant'); eq(e.merchant:is_open(), false, 'the wrong one was closed')
end)

test('merchant: opening switches off "only items I can use"; buy and sell are confirmed by the bag count', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Water Flask', 3)
    local id = e.G:spawn('Audri Deepfacet', 0, 5, 0, { sells = { 'Water Flask', 'Jeweler\'s Glass' } })
    local o = e.run(function(ctx) return e.merchant:open(ctx, id) end)
    truthy(o.ok, R.describe(o)); eq(e.G.usableOnly, false, 'filter switched off')
    local b = e.run(function(ctx) return e.merchant:buy(ctx, 'Water Flask', 5) end)
    truthy(b.ok, R.describe(b)); eq(b.value.got, 5); eq(e.G:count('Water Flask'), 8)
    local b2 = e.run(function(ctx) return e.merchant:buy(ctx, "Jeweler's Glass", 2) end)
    truthy(b2.ok, R.describe(b2)); eq(e.G:count("Jeweler's Glass"), 2)
    local sl = e.run(function(ctx) return e.merchant:sell(ctx, 'Water Flask', 5) end)
    truthy(sl.ok, R.describe(sl)); eq(sl.value.sold, 5); eq(e.G:count('Water Flask'), 3)
    local nb = e.run(function(ctx) return e.merchant:buy(ctx, 'Diamond', 1) end)
    eq(nb.why, 'not sold here')
end)

test('merchant: selling spans stacks; a buy that gets no answer is reported, never re-sent', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Water Flask', 2); e.G:put(1, 2, 'Water Flask', 4)
    local id = e.G:spawn('Audri Deepfacet', 0, 5, 0, { sells = { 'Water Flask' } })
    e.run(function(ctx) return e.merchant:open(ctx, id) end)
    local sl = e.run(function(ctx) return e.merchant:sell(ctx, 'Water Flask', 5) end)
    truthy(sl.ok, R.describe(sl)); eq(e.G:count('Water Flask'), 1)
    e.G.buyIgnores = 1
    local b = e.run(function(ctx) return e.merchant:buy(ctx, 'Water Flask', 3) end)
    eq(b.why, 'not bought')
    local buys = 0; for _, c in ipairs(e.G.log) do if c:find('Merchant.Buy', 1, true) then buys = buys + 1 end end
    eq(buys, 1, 'buy sent once'); eq(e.G:count('Water Flask'), 1)
end)

test('merchant: selling clicks the bag slot (re-sent if lost), leaves the bag as it found it', function()
    local e = block_env()
    e.G:bag(2, 'Backpack', 10); e.G:put(2, 4, 'Aquamarine', 10)
    local id = e.G:spawn('Audri Deepfacet', 0, 5, 0, { sells = { 'Aquamarine' } })
    e.run(function(ctx) return e.merchant:open(ctx, id) end)
    e.G.lostClicks = 1
    local sl = e.run(function(ctx) return e.merchant:sell(ctx, 'Aquamarine', 5) end)
    truthy(sl.ok, R.describe(sl)); eq(e.G:count('Aquamarine'), 5)
    eq(e.G.packs[2].open, false, 'bag closed again')
    e.G.packs[2].open = true
    local sl2 = e.run(function(ctx) return e.merchant:sell(ctx, 'Aquamarine', 2) end)
    truthy(sl2.ok, R.describe(sl2)); eq(e.G.packs[2].open, true, 'a bag that was open stays open')
end)

test('merchant: a sell click that picks the item up puts it back and reports it', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Aquamarine', 1)
    local id = e.G:spawn('Audri Deepfacet', 0, 5, 0, { sells = { 'Aquamarine' } })
    e.run(function(ctx) return e.merchant:open(ctx, id) end)
    e.G.merchantClickPicksUp = true
    local sl = e.run(function(ctx) return e.merchant:sell(ctx, 'Aquamarine', 1) end)
    eq(sl.why, 'picked up'); eq(#e.G.cursor, 0, 'cursor empty'); eq(e.G:count('Aquamarine'), 1, 'nothing lost')
end)

local function jewel_env()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Amber', 5); e.G:put(1, 2, 'Enchanted Silver Bar', 5)
    e.G:kit(10, "Jeweler's Kit", 10)
    e.G.recipes['Silver Amber Ring'] = { 'Amber', 'Enchanted Silver Bar' }
    return e
end

test('kit: found only in a top-level slot, with a reason otherwise', function()
    local e = jewel_env()
    local k = e.kit:find("jeweler's kit"); eq(k.pack, 10); eq(k.slots, 10)
    local e2 = block_env()
    e2.G:bag(1, 'Backpack', 10); e2.G:put(1, 3, "Jeweler's Kit", 1)
    local k2, why = e2.kit:find("Jeweler's Kit")
    eq(k2, nil); truthy(why:find('inside another bag', 1, true), why)
    local _, why3 = e2.kit:find('Fletching Kit'); truthy(why3:find('not in the inventory', 1, true), why3)
end)

test('kit: open, place one of each in order, combine, the product is stowed and the kit is empty', function()
    local e = jewel_env()
    local o = e.run(function(ctx) return e.kit:open(ctx, 10) end)
    truthy(o.ok, R.describe(o)); eq(o.value.how, 'right-click')
    local p1 = e.run(function(ctx) return e.kit:place(ctx, 10, 1, 'Amber') end)
    local p2 = e.run(function(ctx) return e.kit:place(ctx, 10, 2, 'Enchanted Silver Bar') end)
    truthy(p1.ok and p2.ok, R.describe(p1) .. ' / ' .. R.describe(p2))
    eq(e.kit:contents(10)[1].name, 'Amber'); eq(e.kit:contents(10)[2].name, 'Enchanted Silver Bar')
    local c = e.run(function(ctx) return e.kit:combine(ctx, 10, 'Silver Amber Ring') end)
    truthy(c.ok, R.describe(c)); eq(c.value.result, 'success'); eq(c.value.made, 1)
    eq(c.value.returned[1], 'Silver Amber Ring x1 (product)')
    eq(e.kit:describe(10), 'empty'); eq(#e.G.cursor, 0)
    eq(e.G:count('Amber'), 4); eq(e.G:count('Enchanted Silver Bar'), 4); eq(e.G:count('Silver Amber Ring'), 1)
end)

test('kit: when the tradeskill window comes up instead, Experiment raises the combine window', function()
    local e = jewel_env()
    e.G.kitOpensTradeskill = true
    local o = e.run(function(ctx) return e.kit:open(ctx, 10) end)
    truthy(o.ok, R.describe(o)); eq(o.value.how, 'right-click + Experiment')
    local c = e.run(function(ctx) return e.kit:close(ctx, 10) end)
    truthy(c.ok, R.describe(c)); eq(e.G.windows.tradeskillwnd.open, false); eq(e.G.packs[10].open, false)
end)

test('kit: a skill failure and a refusal are told apart; clear empties the kit', function()
    local e = jewel_env()
    e.run(function(ctx) return e.kit:open(ctx, 10) end)
    e.G.combineFails = 1
    e.run(function(ctx) e.kit:place(ctx, 10, 1, 'Amber'); return e.kit:place(ctx, 10, 2, 'Enchanted Silver Bar') end)
    local c = e.run(function(ctx) return e.kit:combine(ctx, 10, 'Silver Amber Ring') end)
    eq(c.value.result, 'failed'); eq(c.value.made, 0); eq(e.kit:describe(10), 'empty')
    e.run(function(ctx) e.kit:place(ctx, 10, 1, 'Amber'); return e.kit:place(ctx, 10, 2, 'Amber') end)
    local c2 = e.run(function(ctx) return e.kit:combine(ctx, 10, 'Silver Amber Ring') end)
    eq(c2.value.result, 'refused')
    local cl = e.run(function(ctx) return e.kit:clear(ctx, 10) end)
    truthy(cl.ok, R.describe(cl)); eq(e.kit:describe(10), 'empty')
    eq(e.G:count('Amber'), 4, 'one used by the failed combine, the refused two back in the bags')
end)

test('kit: ingredients never come out of the kit itself; a lost click into the kit is re-sent', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Amber', 1)
    e.G:kit(10, "Jeweler's Kit", 10); e.G.packs[10].items[5] = { id = 1, name = 'Amber', stack = 1 }
    e.run(function(ctx) return e.kit:open(ctx, 10) end)
    e.G.lostClicks = 1
    local p = e.run(function(ctx) return e.kit:place(ctx, 10, 1, 'Amber') end)
    truthy(p.ok, R.describe(p))
    eq(e.G.packs[1].items[1], nil, 'taken from the backpack'); eq(e.G.packs[10].items[5].name, 'Amber', 'kit slot 5 untouched')
end)

test('kit: closed with a right-click on its slot (no Esc); /cleanup only when that does not work', function()
    local e = jewel_env()
    e.run(function(ctx) return e.kit:open(ctx, 10) end)
    local c = e.run(function(ctx) return e.kit:close(ctx, 10) end)
    truthy(c.ok, R.describe(c)); eq(e.G.windows.containercombine_items.open, false)
    for _, cmd in ipairs(e.G.log) do truthy(cmd ~= '/keypress esc' and cmd ~= '/cleanup', 'sent ' .. cmd) end
    e.run(function(ctx) return e.kit:open(ctx, 10) end)
    e.G.kitIgnoresClose = true
    local c2 = e.run(function(ctx) return e.kit:close(ctx, 10) end)
    truthy(c2.ok, R.describe(c2)); eq(e.G.windows.containercombine_items.open, false)
    local cl = 0
    for _, cmd in ipairs(e.G.log) do
        if cmd == '/cleanup' then cl = cl + 1 end
    end
    eq(cl, 1, '/cleanup used once as the fallback')
end)

test('item pace covers kit placement: the second ingredient starts ItemPaceMs after the first', function()
    local e = jewel_env()
    e.run(function(ctx) return e.kit:open(ctx, 10) end)
    e.paces.item = 250
    local t0 = e.F.now
    e.run(function(ctx) e.kit:place(ctx, 10, 1, 'Amber'); return e.kit:place(ctx, 10, 2, 'Enchanted Silver Bar') end)
    local took = e.F.now - t0
    truthy(took >= 250 and took < 250 + 6 * e.F.frameMs, 'two placements took ' .. took .. 'ms')
    eq(e.kit:describe(10), '1=Amber x1, 2=Enchanted Silver Bar x1')
end)

local function forge_env(opts)
    local e = block_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, 'Small Piece of Ore', 9); e.G:put(1, 2, 'Water Flask', 9)
    e.G:ground('Forge', 20, 0, 0); e.G:ground('Forge', 400, 0, 0)
    e.G.recipes['Small Brick of Ore'] = { 'Small Piece of Ore', 'Water Flask' }
    for k, v in pairs(opts or {}) do e.G[k] = v end
    return e
end

test('station: finds the nearest by name, only clicks it within reach', function()
    local e = forge_env()
    local f = e.run(function(ctx) return e.station:find(ctx, 'Forge') end)
    truthy(f.ok, R.describe(f)); eq(math.floor(f.value.distance), 20); eq(f.value.y, 20)
    local nf = e.run(function(ctx) return e.station:find(ctx, 'Kiln') end)
    eq(nf.why, 'not found')
    e.G.grounds[1].y = 90
    local o = e.run(function(ctx) return e.station:open(ctx, 'Forge') end)
    eq(o.why, 'out of reach')
end)

test('station: opens (direct, or via Experiment), places, combines, empties, closes its bags then Esc', function()
    for _, ts in ipairs({ false, true }) do
        local e = forge_env({ stationOpensTradeskill = ts })
        local o = e.run(function(ctx) return e.station:open(ctx, 'Forge') end)
        truthy(o.ok, R.describe(o)); eq(o.value.how, ts and 'click + Experiment' or 'click')
        local p = e.run(function(ctx)
            local a = e.station:place(ctx, 1, 'Small Piece of Ore'); if not a.ok then return a end
            return e.station:place(ctx, 2, 'Water Flask')
        end)
        truthy(p.ok, (ts and 'tradeskill window: ' or '') .. R.describe(p))
        local c = e.run(function(ctx) return e.station:combine(ctx, 'Small Brick of Ore') end)
        truthy(c.ok, R.describe(c)); eq(c.value.result, 'success'); eq(c.value.made, 1)
        eq(e.station:describe(), 'empty'); eq(e.G:count('Small Piece of Ore'), 8)
        e.run(function(ctx) return e.station:close_bags(ctx) end)
        eq(e.G.packs[1].open, false, 'the bag opened for ingredients is closed')
        local esc0 = 0; for _, cmd in ipairs(e.G.log) do if cmd == '/keypress esc' then esc0 = esc0 + 1 end end
        local cl = e.run(function(ctx) return e.station:close(ctx, 'Forge') end)
        truthy(cl.ok, R.describe(cl)); eq(e.G.windows.containercombine_items.open, false)
        local esc = 0
        for _, cmd in ipairs(e.G.log) do
            truthy(cmd ~= '/cleanup', 'no /cleanup needed')
            if cmd == '/keypress esc' then esc = esc + 1 end
        end
        eq(esc - esc0, 1, 'one Esc, since nothing of ours is on top')
    end
end)

test('station: a click caught half done (in the slot and still on the cursor) is waited out, not taken back', function()
    local e = forge_env({})
    truthy(e.run(function(ctx) return e.station:open(ctx, 'Forge') end).ok)
    e.G.enviroCursorLag = 120
    local p = e.run(function(ctx) return e.station:place(ctx, 1, 'Small Piece of Ore') end)
    truthy(p.ok, R.describe(p))
    eq(e.station:contents()[1].name, 'Small Piece of Ore'); eq(#e.G.cursor, 0)
    local n = 0; for _, c in ipairs(e.G.log) do if c == '/nomodkey /itemnotify enviro1 leftmouseup' then n = n + 1 end end
    eq(n, 1, 'clicked once')
end)

test('combine: a product stowed into a worn slot (throwing items into Ammo) counts as made, with no wait', function()
    local e = forge_env({})
    e.G.worn = { ammo = { name = 'Small Brick of Ore', stack = 3, id = 77 } }
    local r = e.run(function(ctx)
        local o = e.station:open(ctx, 'Forge'); if not o.ok then return o end
        local a = e.station:place(ctx, 1, 'Small Piece of Ore'); if not a.ok then return a end
        local b = e.station:place(ctx, 2, 'Water Flask'); if not b.ok then return b end
        return e.station:combine(ctx, 'Small Brick of Ore')
    end)
    truthy(r.ok, R.describe(r)); eq(r.value.result, 'success'); eq(r.value.made, 1); eq(#r.value.missing, 0)
    eq(e.G.worn.ammo.stack, 4, 'it went to Ammo'); truthy(r.value.ms < 1000, 'no wait for it')
end)

test('combine: after a failure, salvage that comes after the rest is waited for and put away (not left for the next combine)', function()
    local e = forge_env({ combineFails = 1, salvage = { ['Small Brick of Ore'] = { 'Water Flask' } }, salvageLateMs = 100 })
    local water = e.G:count('Water Flask')
    local c = e.run(function(ctx)
        local o = e.station:open(ctx, 'Forge'); if not o.ok then return o end
        local a = e.station:place(ctx, 1, 'Small Piece of Ore'); if not a.ok then return a end
        local b = e.station:place(ctx, 2, 'Water Flask'); if not b.ok then return b end
        return e.station:combine(ctx, { product = 'Small Brick of Ore', ins = { { name = 'Small Piece of Ore', n = 1 }, { name = 'Water Flask', n = 1 } } })
    end)
    truthy(c.ok, R.describe(c)); eq(c.value.result, 'failed')
    eq(#e.G.cursor, 0, 'nothing left on the cursor'); eq(e.G:count('Water Flask'), water, 'the late salvage is in the bags')
    eq(c.value.returned[1], 'Water Flask x1 (salvage)')
end)

test('combine: a failure waits for its FailBack ingredient; a success waits for what it makes Also', function()
    local e = forge_env({ combineFails = 1, returnLateMs = 150, failBack = { ['Small Brick of Ore'] = { 'Water Flask' } },
                          alsoMade = { ['Small Brick of Ore'] = { 'Metal Shavings' } } })
    local want = { product = 'Small Brick of Ore', ins = { { name = 'Small Piece of Ore', n = 1 }, { name = 'Water Flask', n = 1 } },
                   failBack = { { name = 'Water Flask', n = 1 } }, also = { { name = 'Metal Shavings', n = 1 } } }
    local function one()
        return e.run(function(ctx)
            local o = e.station:open(ctx, 'Forge'); if not o.ok then return o end
            local a = e.station:place(ctx, 1, 'Small Piece of Ore'); if not a.ok then return a end
            local b = e.station:place(ctx, 2, 'Water Flask'); if not b.ok then return b end
            return e.station:combine(ctx, want)
        end)
    end
    local water = e.G:count('Water Flask')
    local c = one()
    truthy(c.ok, R.describe(c)); eq(c.value.result, 'failed')
    eq(c.value.returned[1], 'Water Flask x1 (given back)'); eq(#c.value.missing, 0); eq(#e.G.cursor, 0)
    eq(e.G:count('Water Flask'), water, 'the water came back')
    c = one()
    truthy(c.ok, R.describe(c)); eq(c.value.result, 'success'); eq(c.value.made, 1)
    eq(c.value.returned[2], 'Metal Shavings x1 (also made)'); eq(#c.value.missing, 0); eq(e.G:count('Metal Shavings'), 1)
end)

test('station: "in use" ends the open at once; an unanswered click is sent again only after the wait', function()
    local e = forge_env({ stationInUse = true })
    local t0 = e.F.now
    local o = e.run(function(ctx) return e.station:open(ctx, 'Forge') end)
    eq(o.why, 'in use'); truthy(e.F.now - t0 < 500, 'gave up at once (' .. (e.F.now - t0) .. 'ms)')
    local e2 = forge_env({ stationIgnores = 1 })
    local o2 = e2.run(function(ctx) return e2.station:open(ctx, 'Forge') end)
    truthy(o2.ok, R.describe(o2))
    local clicks = 0
    for _, cmd in ipairs(e2.G.log) do if cmd == '/click left item' then clicks = clicks + 1 end end
    eq(clicks, 2, 'one lost click, sent again once')
end)

test('station: clear returns leftovers; a station that will not close falls back to /cleanup', function()
    local e = forge_env()
    e.run(function(ctx) return e.station:open(ctx, 'Forge') end)
    e.run(function(ctx) return e.station:place(ctx, 1, 'Water Flask') end)
    local cl = e.run(function(ctx) return e.station:clear(ctx) end)
    truthy(cl.ok, R.describe(cl)); eq(e.station:describe(), 'empty'); eq(e.G:count('Water Flask'), 9)
    e.G.stationIgnoresClose = true
    local c = e.run(function(ctx) return e.station:close(ctx, 'Forge') end)
    truthy(c.ok, R.describe(c)); eq(e.G.windows.containercombine_items.open, false)
    local used = false; for _, cmd in ipairs(e.G.log) do if cmd == '/cleanup' then used = true end end
    truthy(used, '/cleanup as the fallback')
end)

local function bank_env()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10)
    e.G:bankbag(1, 'Bank Bag', 8); e.G:bankput(1, 1, 'Water Flask', 20); e.G:bankput(1, 2, 'Water Flask', 10)
    e.G:spawn('Banker Ceridan', 0, 5, 0, { class = 'Banker' }); e.G:spawn('Banker Far', 0, 300, 0, { class = 'Banker' })
    e.G:spawn('Audri Deepfacet', 0, 2, 0)
    return e
end

test('snapshots: bags and bank read once into counts', function()
    local e = bank_env()
    e.G:put(1, 1, 'Water Flask', 4); e.G:put(1, 2, 'Water Flask', 3); e.G:put(1, 3, 'Amber', 1)
    local b = e.inv:snapshot(); eq(b['water flask'], 7); eq(b.amber, 1)
    local k, readable = e.bank:snapshot(); eq(k['water flask'], 30); truthy(readable)
end)

test('nav: a walk with no path across a broken bridge (nav.ini Bridge=) walks to its near edge, runs across, then on', function()
    local e = block_env()
    local Nav = require('blocks.nav')
    e.G.zone = 'thurgadina'; e.G.me = { x = 5, y = -1100, z = 12 }; e.G.bridgeY = -850
    e.G.bridgeSnagUntilDuck = nil
    local nav = Nav.new({ mq = e.F.mq, spawns = e.spawns, log = e.log,
        nav = { thurgadina = { hubs = {}, spots = {}, bridge = { near = { -977, 5.70, 12.38 }, far = { -702.71, 5.21 }, heading = 0.80 } } } })
    local r = e.run(function(ctx) return nav:go_loc(ctx, -400, 0, 3, 10) end)
    truthy(r.ok, R.describe(r))
    truthy(e.G.me.y > -420, 'arrived past the bridge: ' .. e.G.me.y)
    local held = false; for _, c in ipairs(e.G.log) do if c == '/keypress forward hold' then held = true end end
    truthy(held, 'ran across'); eq(e.G.running, false, 'let go of forward')
    -- this side already: no crossing
    local before = #e.G.log
    truthy(e.run(function(ctx) return nav:go_loc(ctx, -300, 0, 3, 10) end).ok)
    for i = before + 1, #e.G.log do truthy(e.G.log[i] ~= '/keypress forward hold', 'no second crossing') end
end)

test('nav: the first walk in a zone with an arrival spot goes there first, straight (no docks), once per visit; then crossings dock', function()
    local e = block_env()
    local Nav = require('blocks.nav')
    local Config = require('core.config')
    -- the zone-in (X above 0) and Tomas (X below 0) as in the 2.39.3 log: across the X sign, still straight
    e.G.zone = 'freeporttemple'; e.G.me = { x = 100, y = 450, z = -11 }
    local tomas = e.G:spawn('Soulbinder Tomas', -107, 235, -8)
    local nav = Nav.new({ mq = e.F.mq, spawns = e.spawns, log = e.log, arrive = { freeporttemple = { npc = 'Soulbinder Tomas' } },
        nav = { freeporttemple = { hubs = {}, spots = {}, docks = { a = { 801.88, -43.21, -50.12 }, b = { 803.01, 44.31, -50.12 } } } } })
    truthy(e.run(function(ctx) return nav:go_loc(ctx, 450, 110, -11, 10) end).ok)
    truthy(not e.log.has('Nav: first to Soulbinder Tomas'), 'not for the zone LazCraft started in')
    nav:zoned()   -- zoned in
    local r = e.run(function(ctx) return nav:go_loc(ctx, 200, -150, -11, 10) end)
    truthy(r.ok, R.describe(r))
    truthy(e.log.has('Nav: first to Soulbinder Tomas'), 'Tomas first')
    truthy(not e.log.has('dock first'), 'no docks to Tomas, nor on Tomas\'s side')
    -- from Tomas's side to the other (Klonopin's): both docks
    r = e.run(function(ctx) return nav:go_loc(ctx, 300, 60, -11, 10) end)
    truthy(r.ok, R.describe(r))
    truthy(e.log.has('this side\'s dock first') and e.log.has('the far side\'s dock first'), 'across: the docks')
    local tomasNav = 0; for _, c in ipairs(e.G.log) do if c:find('^/nav id ' .. tomas) then tomasNav = tomasNav + 1 end end
    eq(tomasNav, 1)
    e.run(function(ctx) return nav:go_loc(ctx, 0, 100, -11, 10) end)
    tomasNav = 0; for _, c in ipairs(e.G.log) do if c:find('^/nav id ' .. tomas) then tomasNav = tomasNav + 1 end end
    eq(tomasNav, 1, 'once per visit')
    nav:zoned()
    e.run(function(ctx) return nav:go_loc(ctx, 200, 150, -11, 10) end)
    tomasNav = 0; for _, c in ipairs(e.G.log) do if c:find('^/nav id ' .. tomas) then tomasNav = tomasNav + 1 end end
    eq(tomasNav, 2, 'again after zoning')
end)

test('bank: a banker the nav cannot reach is opened from where it stopped when close enough; far away it fails', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10)
    local near = e.G:spawn('Banker Granger', 19, 0, 0, { class = 'Banker' })
    e.G.noPath[near] = true   -- 2.37.0 log: "no nav path to Banker Granger (19 away)", a counter in the way
    local r = e.run(function(ctx) return e.bank:go_open(ctx, e.nav, e.bank:banker()) end)
    truthy(r.ok, R.describe(r)); truthy(e.bank:is_open())
    e.run(function(ctx) return e.bank:close(ctx) end)
    e.G.spawns[near].x = 60
    local r2 = e.run(function(ctx) return e.bank:go_open(ctx, e.nav, e.bank:banker()) end)
    eq(r2.why, 'no path'); truthy(not e.bank:is_open())
end)

test('bank: nearest banker, opens on a right-click, counts from its slots, closes with Done', function()
    local e = bank_env()
    local b = e.bank:banker(); eq(b.name, 'Banker Ceridan')
    local n, how = e.bank:count('Water Flask'); eq(n, 30); eq(how, 'slots')
    local o = e.run(function(ctx) return e.bank:open(ctx, b.id) end)
    truthy(o.ok, R.describe(o)); eq(e.G.windows.bigbankwnd.open, true)
    local c = e.run(function(ctx) return e.bank:close(ctx) end)
    truthy(c.ok, R.describe(c)); eq(e.G.windows.bigbankwnd.open, false)
    local e2 = block_env()
    local n2, how2 = e2.bank:count('Water Flask'); eq(n2, 0); eq(how2, 'client')
end)

test('bank: withdraw an exact amount (splitting, across stacks) and deposit it back into empty slots', function()
    local e = bank_env()
    e.run(function(ctx) return e.bank:open(ctx, e.bank:banker().id) end)
    local w = e.run(function(ctx) return e.bank:withdraw(ctx, 'Water Flask', 5) end)
    truthy(w.ok, R.describe(w)); eq(e.G:count('Water Flask'), 5); eq(e.G:bankcount('Water Flask'), 25)
    local w2 = e.run(function(ctx) return e.bank:withdraw(ctx, 'Water Flask', 22) end)
    truthy(w2.ok, R.describe(w2)); eq(e.G:count('Water Flask'), 27); eq(e.G:bankcount('Water Flask'), 3)
    local d = e.run(function(ctx) return e.bank:deposit(ctx, 'Water Flask', 27) end)
    truthy(d.ok, R.describe(d)); eq(e.G:count('Water Flask'), 0); eq(e.G:bankcount('Water Flask'), 30)
    eq(#e.G.cursor, 0)
    local nope = e.run(function(ctx) return e.bank:withdraw(ctx, 'Diamond', 1) end)
    eq(nope.why, 'not in the bank')
end)

test('bank: a deposit is the exact amount picked up, then Auto Bank (the client tops up stacks, then a slot)', function()
    local e = bank_env()
    e.G.stackSize = 25
    e.G:put(1, 1, 'Water Flask', 9)
    e.run(function(ctx) return e.bank:open(ctx, e.bank:banker().id) end)
    local d = e.run(function(ctx) return e.bank:deposit(ctx, 'Water Flask', 7) end)
    truthy(d.ok, R.describe(d)); eq(d.value.put, 7)
    eq(e.G:bankcount('Water Flask'), 37); eq(e.G:count('Water Flask'), 2, 'exactly 7 went in'); eq(#e.G.cursor, 0)
    local presses = 0; for _, c in ipairs(e.G.log) do if c == '/notify BigBankWnd BIGB_AutoButton leftmouseup' then presses = presses + 1 end end
    eq(presses, 1)
end)

test('bank: when Auto Bank cannot take it (bank full), it goes back to the bags and the deposit says why', function()
    local e = bank_env()
    e.G:put(1, 1, 'Amber', 3)
    e.G.autoBankIgnores = true
    e.run(function(ctx) return e.bank:open(ctx, e.bank:banker().id) end)
    local d = e.run(function(ctx) return e.bank:deposit(ctx, 'Amber', 3) end)
    eq(d.why, 'bank full'); eq(e.G:count('Amber'), 3); eq(#e.G.cursor, 0)
end)

test('bank: part of a stack from a closed bank bag goes back, the bag is opened, then it splits; never stows extra', function()
    local e = bank_env()
    e.run(function(ctx) return e.bank:open(ctx, e.bank:banker().id) end)
    local w = e.run(function(ctx) return e.bank:withdraw(ctx, 'Water Flask', 3) end)
    truthy(w.ok, R.describe(w)); eq(e.G:count('Water Flask'), 3); eq(e.G:bankcount('Water Flask'), 27)
    local opens = 0; for _, c in ipairs(e.G.log) do if c == '/nomodkey /itemnotify bank1 rightmouseup' then opens = opens + 1 end end
    eq(opens, 1, 'bank bag opened once')
    e.G.bankNeverSplits = true
    local w2 = e.run(function(ctx) return e.bank:withdraw(ctx, 'Water Flask', 2) end)
    eq(w2.why, 'could not split'); eq(e.G:count('Water Flask'), 3, 'nothing extra stowed'); eq(e.G:bankcount('Water Flask'), 27)
    eq(#e.G.cursor, 0)
end)

test('merchant: a non-stacking item is bought one at a time; a stackable one at most a stack per buy', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 20)
    local id = e.G:spawn('Klen Ironstove', 0, 5, 0, { sells = { 'Skewer Mold', 'Water Flask' } })
    e.G.noStack = { ['skewer mold'] = true }; e.G.stackSize = 20
    e.run(function(ctx) return e.merchant:open(ctx, id) end)
    local b = e.run(function(ctx) return e.merchant:buy(ctx, 'Skewer Mold', 3) end)
    truthy(b.ok, R.describe(b)); eq(e.G:count('Skewer Mold'), 3)
    local buys = 0; for _, c in ipairs(e.G.log) do if c == '/invoke ${Merchant.Buy[1]}' then buys = buys + 1 end end
    eq(buys, 3, 'three single buys')
    local b2 = e.run(function(ctx) return e.merchant:buy(ctx, 'Water Flask', 45) end)
    truthy(b2.ok, R.describe(b2)); eq(e.G:count('Water Flask'), 45)
end)

test('bank: a bank bag that ignores clicks right after opening is closed and reopened, then the split goes through', function()
    local e = bank_env()
    e.run(function(ctx) return e.bank:open(ctx, e.bank:banker().id) end)
    e.G.bankDeafClicks = 3
    local w = e.run(function(ctx) return e.bank:withdraw(ctx, 'Water Flask', 2) end)
    truthy(w.ok, R.describe(w)); eq(e.G:count('Water Flask'), 2)
end)

realPrint('whole script (fake game)')
-- The whole-script tests run the real init.lua, which writes into lazcraft/settings and lazcraft/logs.
-- Clear those before and after each one so no test sees another's files and nothing is left behind.
local function clean_own_files()
    for _, f in ipairs({ 'settings/LazCraft_Glanen.ini', 'settings/stacks.ini', 'logs/LazCraft_Glanen.log', 'logs/LazCraft_Glanen.prev.log',
                         'settings/LazCraft_Glanen_queue.ini', 'settings/LazCraft_Glanen_paths.ini', 'settings/rates.ini',
                         'settings/LazCraft_Glanen_casters.ini', 'settings/LazCraft_Glanen_factions.ini', 'settings/unsold.ini',
                         'logs/LazCraft_Glanen_status.txt', 'settings/unsold_old.ini' }) do
        os.remove(ROOT .. f)
    end
end
test('start, test run with Go, Stop mid-run, quit', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    -- Fresh module copies so the script gets the fake mq
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result' }) do package.loaded[m] = nil end
    local frames = {}
    F.at(50, function() F.mq.cmd('/lc log on') end)
    F.at(100, function() F.mq.cmd('/lc test') end)
    F.at(300, function() frames.awaiting = F.draw() end)
    F.at(400, function() F.click('Go') end)
    F.at(1500, function() F.mq.cmd('/lc pause') end)
    F.at(2000, function() frames.paused = F.draw() end)
    F.at(4000, function() F.mq.cmd('/lc resume') end)
    F.at(4600, function() frames.running = F.draw() end)
    F.at(11000, function() frames.done = F.draw() end)
    F.at(11100, function() F.mq.cmd('/lc test') end)
    F.at(11300, function() F.click('Go') end)
    F.at(12500, function() F.mq.cmd('/lc stop') end)
    F.at(13000, function() frames.stopped = F.draw() end)
    F.at(13200, function() F.mq.cmd('/lc test') end)
    F.at(13400, function() F.click('Go') end)
    F.at(13900, function() F.mq.cmd('/lc log off') end)
    F.at(14000, function() F.mq.cmd('/lc quit') end)
    local chunk = assert(loadfile(ROOT .. 'init.lua'))
    chunk()
    _G.print = realPrint
    local function has(frame, p)
        for _, l in ipairs(frame or {}) do if l:find(p) then return true end end
        return false
    end
    truthy(has(frames.awaiting, 'colored:Waiting for Go'), 'status shows waiting for Go (a pill)')
    truthy(has(frames.awaiting, 'Test only'), 'preflight list drawn')
    truthy(has(frames.awaiting, 'button:Go'), 'Go button drawn')
    truthy(has(frames.paused, 'colored:Paused'), 'paused shown (a pill)')
    truthy(has(frames.paused, 'button:Resume'), 'Resume button while paused')
    truthy(has(frames.running, 'Step %d of 5'), 'running status')
    truthy(has(frames.running, 'progress:%d / 5'), 'progress bar')
    truthy(has(frames.done, 'Last: Test run %- done'), 'finished')
    truthy(has(frames.stopped, 'failed: stopped'), 'stopped run reported')
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('started on Glanen as crafter'), 'start line')
    truthy(printed:find('LazCraft stopped'), 'clean exit')
    truthy(F.now < 15000, 'quit stopped the running job promptly (t=' .. F.now .. ')')
    eq(F.depth, 0, 'ImGui balanced')
    local logPath = ROOT .. 'logs/LazCraft_Glanen.log'
    local fh = io.open(logPath, 'r')
    truthy(fh, 'log file written in the logs folder')
    local logText = fh:read('*a'); fh:close(); os.remove(logPath)
    truthy(logText:find('Starting: Test run', 1, true), 'job lines in the log file')
    local sf = io.open(ROOT .. 'settings/LazCraft_Glanen.ini', 'r')
    truthy(sf and sf:read('*a'):find('LogToFile=0', 1, true), 'log off saved in settings')
    if sf then sf:close() end
    os.remove(ROOT .. 'settings/LazCraft_Glanen.ini')
    eq(F.binds['/lc'], nil, 'command unbound on exit')
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: /lc pickup and /lc inv on a simulated character', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    G:bag(1, 'Backpack', 10); G:put(1, 2, 'Water Flask', 20)
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor' }) do package.loaded[m] = nil end
    local frame
    F.at(100, function() F.mq.cmd('/lc pickup 3 Water Flask') end)
    F.at(300, function() frame = F.draw() end)
    F.at(400, function() F.click('Go') end)
    F.at(4000, function() F.mq.cmd('/lc inv Water Flask') end)
    F.at(4500, function() F.mq.cmd('/lc quit') end)
    local chunk = assert(loadfile(ROOT .. 'init.lua'))
    chunk()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local has = false; for _, l in ipairs(frame) do if l:find('3 Water Flask', 1, true) or l:find('20 Water Flask in bags', 1, true) then has = true end end
    truthy(has, 'preflight shown')
    truthy(printed:find('Cursor holds Water Flask x3', 1, true), 'picked up 3')
    truthy(printed:find('picked up 3 and put it back', 1, true), 'job finished')
    truthy(printed:find('Water Flask: 20 in bags', 1, true), 'inv check after')
    eq(G.packs[1].open, false, 'bag closed again')
    local sent = table.concat(G.log, '\n')
    truthy(sent:find('/e3p on', 1, true) and sent:find('/e3p off', 1, true), 'E3 paused and resumed')
    local logPath = ROOT .. 'logs/LazCraft_Glanen.log'
    local fh = io.open(logPath, 'r')
    truthy(fh, 'log file written by default')
    local text = fh:read('*a'); fh:close()
    os.remove(logPath); os.remove(ROOT .. 'logs/LazCraft_Glanen.prev.log')
    truthy(text:find('send: /nomodkey /itemnotify pack1 rightmouseup', 1, true), 'bag open step logged')
    truthy(text:find('pack1 open: yes after', 1, true), 'bag open confirmation logged with timing')
    truthy(text:find('click 1: took', 1, true), 'click result logged')
    truthy(text:find('DEBUG', 1, true) and not printed:find('send:', 1, true), 'steps go to the file, not the console')
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: /lc bagtest runs ten rounds from a closed bag and reports lost clicks', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    G:bag(5, 'Backpack', 20); G:put(5, 16, 'Water Flask', 1000)
    G.bagReadyMs = 10
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor' }) do package.loaded[m] = nil end
    F.at(100, function() F.mq.cmd('/lc bagtest 10 Water Flask') end)
    F.at(300, function() F.click('Go') end)
    F.at(6000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('10/10 ok, 10 lost click(s) re-sent, 0 round(s) needed a reopen', 1, true), 'summary: ' .. (printed:match('Bag test[^\n]*Done[^\n]*') or printed:match('[^\n]*10/10[^\n]*') or '?'))
    eq(G:count('Water Flask'), 1000, 'nothing lost'); eq(G.packs[5].open, false, 'bag closed at the end')
    os.remove(ROOT .. 'logs/LazCraft_Glanen.log'); os.remove(ROOT .. 'logs/LazCraft_Glanen.prev.log')
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: /lc bagtest measures a lockout after a burst of moves, with and without a gap', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    G:bag(5, 'Backpack', 20); G:put(5, 16, 'Water Flask', 1000)
    G.lockAfterMoves, G.lockMs = 12, 3000
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor' }) do package.loaded[m] = nil end
    F.at(100, function() F.mq.cmd('/lc bagtest 10 Water Flask') end)
    F.at(300, function() F.click('Go') end)
    F.at(9000, function() G.deafOpens = 1; F.mq.cmd('/lc bagtest 3 gap 400 Water Flask') end)
    F.at(9200, function() F.click('Go') end)
    F.at(12000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Round 7: clicks ignored for about 3', 1, true), printed:match('Round 7[^\n]*') or '?')
    truthy(printed:find('after 12 moves', 1, true), 'moves counted')
    truthy(printed:find('9/10 ok', 1, true), printed:match('[^\n]*/10 ok[^\n]*') or '?')
    truthy(printed:find('400ms apart', 1, true) and printed:find('3/3 ok', 1, true), 'gap run')
    truthy(printed:find('1 round(s) needed a reopen (1 reopens)', 1, true), printed:match('[^\n]*3/3 ok[^\n]*') or '?')
    truthy(printed:find('Round 1: ok in %d+ms, 4 click%(s%), 1 reopen%(s%)'), 'round line shows the reopen')
    eq(G:count('Water Flask'), 1000, 'nothing lost'); eq(G.packs[5].open, false, 'bag closed at the end')
    clean_own_files()
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: /lc navtest goes back and forth, opens and closes each merchant', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    -- clear of Marr's avoid boxes (nav.ini): a straight trip each way
    G.me = { x = 300, y = 0, z = 0 }
    G:spawn('Brewmaster Berina', 300, 150, 0, { items = 30 })
    G:spawn('Audri Deepfacet', 300, -150, 0, { items = 12 })
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor', 'blocks.spawns', 'blocks.nav', 'blocks.merchant' }) do package.loaded[m] = nil end
    local frame
    F.at(100, function() F.mq.cmd('/lc navtest 4 Brewmaster Berina, Audri Deepfacet') end)
    F.at(300, function() frame = F.draw() end)
    F.at(400, function() F.click('Go') end)
    F.at(40000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local shown = false; for _, l in ipairs(frame) do if l:find('Brewmaster Berina: id', 1, true) then shown = true end end
    truthy(shown, 'preflight lists the NPCs')
    truthy(printed:find('Trip 1: Brewmaster Berina: arrived', 1, true), printed:match('Trip 1[^\n]*') or '?')
    truthy(printed:find('Trip 2: Audri Deepfacet: arrived [%d.]+ away in %d+ms %(1 nav%), opened in %d+ms %(1 try%), 12 items'), printed:match('Trip 2[^\n]*') or '?')
    truthy(printed:find('4/4 navs ok', 1, true) and printed:find('4/4 opens ok', 1, true), printed:match('[^\n]*navs ok[^\n]*') or '?')
    eq(G.nav.active, false); eq((G.windows.merchantwnd or {}).open, false, 'merchant closed at the end')
    clean_own_files()
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: /lc buytest buys and sells back, ending with what it started with', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    G:bag(1, 'Backpack', 10); G:put(1, 3, 'Water Flask', 7)
    G:spawn('Audri Deepfacet', 0, 100, 0, { sells = { 'Water Flask' } })
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor', 'blocks.spawns', 'blocks.nav', 'blocks.merchant' }) do package.loaded[m] = nil end
    F.at(100, function() F.mq.cmd('/lc buytest 3 5 Audri Deepfacet, Water Flask') end)
    F.at(300, function() F.click('Go') end)
    F.at(20000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Round 3: bought 5 in %d+ms, sold 5 in %d+ms, 7 in bags'), printed:match('Round 3[^\n]*') or printed)
    truthy(printed:find('3/3 rounds ok', 1, true) and printed:find('7 Water Flask in bags (started with 7)', 1, true), printed:match('[^\n]*rounds ok[^\n]*') or '?')
    eq(G:count('Water Flask'), 7); eq((G.windows.merchantwnd or {}).open, false, 'merchant closed at the end')
    clean_own_files()
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: /lc combinetest makes the ring three times and tidies up', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    G:bag(1, 'Backpack', 10); G:put(1, 1, 'Amber', 5); G:put(1, 2, 'Enchanted Silver Bar', 5)
    G:kit(10, "Jeweler's Kit", 10)
    G.recipes['Silver Amber Ring'] = { 'Amber', 'Enchanted Silver Bar' }
    G.combineFails = 1
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor', 'blocks.spawns', 'blocks.nav', 'blocks.merchant', 'blocks.combine', 'blocks.kit', 'blocks.station', 'blocks.bank' }) do package.loaded[m] = nil end
    local frame
    F.at(100, function() F.mq.cmd("/lc combinetest 3 Jeweler's Kit, Silver Amber Ring, Amber, Enchanted Silver Bar") end)
    F.at(300, function() frame = F.draw() end)
    F.at(400, function() F.click('Go') end)
    F.at(10000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local shown = false; for _, l in ipairs(frame) do if l:find('Amber: have 5, need 3', 1, true) then shown = true end end
    truthy(shown, 'preflight counts ingredients')
    truthy(printed:find('Combine 1: failed', 1, true), printed:match('Combine 1[^\n]*') or printed)
    truthy(printed:find('Combine 2: success %- placed 2 in %d+ms, answer in %d+ms, made 1 Silver Amber Ring, back: Silver Amber Ring x1'), printed:match('Combine 2[^\n]*') or '?')
    truthy(printed:find('2/3 succeeded, 1 failed', 1, true), printed:match('[^\n]*succeeded[^\n]*') or '?')
    eq(G:count('Silver Amber Ring'), 2); eq(G:count('Amber'), 2)
    eq((G.windows.containercombine_items or {}).open, false, 'kit closed'); eq(G.packs[1].open, false, 'backpack closed again')
    clean_own_files()
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: the Settings tab changes a pace at once, saves it, and the kit is left as it was found', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    G:bag(1, 'Backpack', 10); G:put(1, 1, 'Amber', 5); G:put(1, 2, 'Enchanted Silver Bar', 5)
    G:kit(10, "Jeweler's Kit", 10)
    G.recipes['Silver Amber Ring'] = { 'Amber', 'Enchanted Silver Bar' }
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor', 'blocks.spawns', 'blocks.nav', 'blocks.merchant', 'blocks.combine', 'blocks.kit', 'blocks.station', 'blocks.bank' }) do package.loaded[m] = nil end
    local frame
    F.at(100, function() F.tab = 'Settings'; F.inputs['Item pace (ms)##ItemPaceMs'] = 40; F.draw() end)
    F.at(150, function() F.openCombo = 'Window and console show##LogLevel'; F.clicks['debug##LogLevel_debug'] = true; frame = F.draw() end)
    F.at(170, function() F.openCombo = 'Theme##Theme'; F.clicks['Ember##lc_theme_Ember'] = true; F.draw(); F.openCombo = nil; F.tab = 'Status' end)
    -- open the kit by hand first: the job must use it and leave it open
    F.at(200, function() F.mq.cmd('/nomodkey /itemnotify pack10 rightmouseup') end)
    F.at(300, function() F.mq.cmd("/lc combinetest 1 Jeweler's Kit, Silver Amber Ring, Amber, Enchanted Silver Bar") end)
    F.at(500, function() F.click('Go') end)
    F.at(5000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local has = false; for _, l in ipairs(frame) do if l:find('input:Item pace (ms)##ItemPaceMs=40', 1, true) then has = true end end
    truthy(has, 'tab shows the new value')
    local sf = io.open(ROOT .. 'settings/LazCraft_Glanen.ini', 'r'); local text = sf:read('*a'); sf:close()
    truthy(text:find('ItemPaceMs=40', 1, true) and text:find('LogLevel=debug', 1, true), 'saved at once')
    truthy(text:find('Theme=Ember', 1, true), 'the theme too (2.43.0)')
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('paced %d+ms: %d+ms between item starts %(ItemPaceMs 40%)'), 'pace used by the next item')
    truthy(printed:find('Combine 1: success', 1, true), 'combined')
    eq(G.windows.containercombine_items.open, true, 'kit left open, as it was found')
    eq(F.depth, 0, 'ImGui balanced')
    clean_own_files()
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: /lc stationtest goes to the nearest Forge, combines three times and closes it', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    G:bag(1, 'Backpack', 10); G:put(1, 1, 'Small Piece of Ore', 9); G:put(1, 2, 'Water Flask', 9)
    G:ground('Forge', 150, 0, 0)
    G.recipes['Small Brick of Ore'] = { 'Small Piece of Ore', 'Water Flask' }
    G.stationOpensTradeskill = true
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor', 'blocks.spawns', 'blocks.nav', 'blocks.merchant',
                         'blocks.combine', 'blocks.kit', 'blocks.station', 'blocks.bank' }) do package.loaded[m] = nil end
    F.at(100, function() F.mq.cmd('/lc stationtest 3 Forge, Small Brick of Ore, Small Piece of Ore, Water Flask') end)
    F.at(300, function() F.click('Go') end)
    F.at(20000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('At the Forge', 1, true), printed:match('[^\n]*Forge[^\n]*') or printed)
    truthy(printed:find('Forge open (click + Experiment)', 1, true), 'opened')
    truthy(printed:find('With Forge open, Water Flask reads 9 slot by slot and 9 by the client: they agree', 1, true), 'the old claim is checked')
    truthy(printed:find('3/3 succeeded', 1, true), printed:match('[^\n]*succeeded[^\n]*') or printed)
    eq(G:count('Small Brick of Ore'), 3); eq(G:count('Small Piece of Ore'), 6)
    eq(G.windows.containercombine_items.open, false, 'station closed'); eq(G.windows.tradeskillwnd.open, false)
    eq(G.packs[1].open, false, 'the bag opened for ingredients was closed')
    truthy(not printed:find('/cleanup', 1, true), 'closed without /cleanup')
    clean_own_files()
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: if slots did read blank with a station open, stationtest says so plainly', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    G:bag(1, 'Backpack', 10); G:put(1, 1, 'Small Piece of Ore', 9); G:put(1, 2, 'Water Flask', 9)
    G:ground('Forge', 10, 0, 0)
    G.recipes['Small Brick of Ore'] = { 'Small Piece of Ore', 'Water Flask' }
    G.stationOpensTradeskill, G.blankSlotsWithTradeskill = true, true
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor', 'blocks.spawns', 'blocks.nav', 'blocks.merchant',
                         'blocks.combine', 'blocks.kit', 'blocks.station', 'blocks.bank' }) do package.loaded[m] = nil end
    F.at(100, function() F.mq.cmd('/lc stationtest 1 Forge, Small Brick of Ore, Small Piece of Ore, Water Flask') end)
    F.at(300, function() F.click('Go') end)
    F.at(8000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Water Flask reads 0 slot by slot but 9 by the client', 1, true), printed:match('[^\n]*slot by slot[^\n]*') or printed)
    clean_own_files()
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: /lc banktest takes out and puts back, ending as it started', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    G:bag(1, 'Backpack', 10); G:put(1, 1, 'Water Flask', 4)
    G:bankbag(1, 'Bank Bag', 8); G:bankput(1, 1, 'Water Flask', 20)
    G:spawn('Banker Ceridan', 0, 120, 0, { class = 'Banker' })
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor', 'blocks.spawns', 'blocks.nav', 'blocks.merchant',
                         'blocks.combine', 'blocks.kit', 'blocks.station', 'blocks.bank' }) do package.loaded[m] = nil end
    F.at(100, function() F.mq.cmd('/lc banktest 3 5 Water Flask') end)
    F.at(300, function() F.click('Go') end)
    F.at(20000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('bank open in %d+ms; Water Flask: 4 in the bags, 20 in the bank %(slots%)'), printed:match('[^\n]*bank open[^\n]*') or printed)
    truthy(printed:find('Round 3: took 5 out in %d+ms, put 5 back in %d+ms; bags 4, bank 20'), printed:match('[^\n]*Round 3[^\n]*') or '?')
    truthy(printed:find('3/3 rounds ok', 1, true), printed:match('[^\n]*rounds ok[^\n]*') or '?')
    eq(G:count('Water Flask'), 4); eq(G:bankcount('Water Flask'), 20)
    eq(G.windows.bigbankwnd.open, false, 'bank closed'); eq(G.packs[1].open, false, 'bag closed again')
    clean_own_files()
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: /lc deposit all and /lc withdraw move items and close the bank', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    G:bag(1, 'Backpack', 10); G:put(1, 1, 'Water Flask', 997)
    G:bankbag(6, 'Bank Bag', 12)
    G:spawn('Donlo Goobler', 0, 2, 0, { class = 'Banker' })
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor', 'blocks.spawns', 'blocks.nav', 'blocks.merchant',
                         'blocks.combine', 'blocks.kit', 'blocks.station', 'blocks.bank' }) do package.loaded[m] = nil end
    F.at(100, function() F.mq.cmd('/lc deposit all Water Flask') end)
    F.at(3000, function() F.mq.cmd('/lc withdraw 5 Water Flask') end)
    F.at(8000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('997 Water Flask put in; bags 0, bank 997', 1, true), printed:match('[^\n]*put in[^\n]*') or printed)
    truthy(printed:find('5 Water Flask taken out; bags 5, bank 992', 1, true), printed:match('[^\n]*taken out[^\n]*') or printed)
    eq(G.windows.bigbankwnd.open, false, 'bank closed')
    clean_own_files()
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: /lc plan lists variants, then plans one with the bags, bank and zone as they are', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    G:bag(1, 'Backpack', 10); G:put(1, 1, 'Amber', 4); G:put(1, 2, 'Silver Bar', 1)
    G:kit(10, "Jeweler's Kit", 4)
    G:bankbag(1, 'Bank Bag', 8); G:bankput(1, 1, 'Silver Bar', 3)
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor', 'blocks.spawns', 'blocks.nav', 'blocks.merchant',
                         'blocks.combine', 'blocks.kit', 'blocks.station', 'blocks.bank', 'engine.planner' }) do package.loaded[m] = nil end
    local frame
    F.at(100, function() F.mq.cmd('/lc plan 4 Silver Amber Ring') end)
    F.at(200, function() F.mq.cmd('/lc plan 4 L1') end)
    F.at(400, function() frame = F.draw() end)
    F.at(500, function() F.click('Cancel') end)
    F.at(800, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('recipes loaded', 1, true), 'recipes loaded at start')
    truthy(printed:find('"Silver Amber Ring" has 2 recipes', 1, true), printed)
    truthy(printed:find('[L1] Silver Amber Ring (Silver Bar): 1 Amber, 1 Silver Bar', 1, true), printed)
    local text = table.concat(frame, '\n')
    truthy(text:find('Silver Bar 4: 1 bags, 3 bank', 1, true), text)
    truthy(text:find('Amber 4: 4 bags', 1, true), text)
    clean_own_files()
    os.execute('rm -rf "' .. tmp .. '"')
end)

-- A simulated Temple of Marr: the real recipe and merchant data, the stations at their containers.ini spots,
-- the merchants and a banker nearby.
local function marr(setup)
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    G.speed = 0.5
    G.me = { x = 0, y = 700, z = -47 }
    G:bag(1, 'Big Bag', 40); G:bag(2, 'Big Bag', 40)
    G:ground('Pottery Wheel', 643.9, -62.49, -47.35); G:ground('Kiln', 579.98, -62.7, -47.32)
    G:ground('Forge', 805.06, 58.32, -47.34); G:ground('Oven', 584.97, 63.21, -47.36)
    G:spawn('Sculptor Radee', 650, -40, -47, { sells = { 'Firing Sheet', 'Large Block of Clay', 'Large Bowl Sketch' } })
    G:spawn('Klen Ironstove', 600, 40, -47, { sells = { 'Water Flask', 'Rat Meat', 'Spices', 'Jug of Sauces', 'Skewer Mold' } })
    G:spawn('Borik Darkanvil', 790, 40, -47, { sells = { 'Small Piece of Ore', 'File Mold', 'Water Flask' } })
    G:spawn('Banker Lia', 700, 0, -47, { class = 'Banker' })
    G.recipes = {
        ['Unfired Mixing Bowl'] = { 'Large Block of Clay', 'Large Block of Clay', 'Water Flask', 'Large Bowl Sketch' },
        ['Mixing Bowl'] = { 'Firing Sheet', 'Unfired Mixing Bowl' },
        ['Metal Bits'] = { 'Small Piece of Ore', 'Small Piece of Ore', 'Water Flask' },
        ['Skewers'] = { 'Skewer Mold', 'Water Flask', 'Metal Bits' },
        ['Rat Kabobs'] = { 'Rat Meat', 'Spices', 'Jug of Sauces', 'Skewers' },
        ['Studs'] = { 'Metal Bits', 'Metal Bits', 'Metal Bits', 'Water Flask', 'File' },
    }
    G.returns = { ['Studs'] = { 'File' }, ['Rat Kabobs'] = { 'Skewers' } }
    G.yields = { ['Metal Bits'] = 2 }
    -- the click gap off unless a test turns it on (2.46.6): the in-game tests' timings were written without one
    do local sf = io.open(ROOT .. 'settings/LazCraft_Glanen.ini', 'w'); sf:write('[Settings]\nClickPace=fixed\nClickFloorMs=0\nQuietMs=0\n'); sf:close() end
    if setup then setup(G) end
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor', 'blocks.spawns', 'blocks.nav', 'blocks.merchant',
                         'blocks.combine', 'blocks.kit', 'blocks.station', 'blocks.bank', 'engine.planner', 'engine.make' }) do package.loaded[m] = nil end
    return F, G, function() clean_own_files(); os.execute('rm -rf "' .. tmp .. '"') end
end

test('in game: /lc make 2 Mixing Bowl shops, makes the unfired bowls at the wheel, fires them at the kiln', function()
    local F, G, done = marr()
    F.at(100, function() F.mq.cmd('/lc make 2 Mixing Bowl') end)
    F.at(400, function() F.click('Go') end)
    F.at(120000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Bought 4 Large Block of Clay from Sculptor Radee', 1, true), printed)
    truthy(printed:find('Unfired Mixing Bowl: 2/2 ok, made 2; Mixing Bowl: 2/2 ok, made 2', 1, true), printed:match('[^\n]*Done[^\n]*') or printed)
    eq(G:count('Mixing Bowl'), 2); eq(G:count('Unfired Mixing Bowl'), 0); eq(G:count('Large Block of Clay'), 0)
    eq(G.windows.containercombine_items.open, false, 'last station closed')
    done()
end)

-- RADIX (2.46.0): a Draught of the Craftsman clicked before each combine; its one-minute cooldown waited out
local function radix_forge(G, draughts)
    G:put(1, 1, 'Element Imbued Metal Sheet', 4); G:put(1, 2, 'Elemental Forging Temper', 2); G:put(1, 3, 'Smithy Hammer', 1)
    if draughts > 0 then G:put(1, 4, 'Draught of the Craftsman', draughts) end
    G.recipes['Fusion Chamber Base'] = { 'Element Imbued Metal Sheet', 'Element Imbued Metal Sheet', 'Elemental Forging Temper', 'Smithy Hammer' }
    G.returns['Fusion Chamber Base'] = { 'Smithy Hammer' }
    G.itemSpells = { ['Draught of the Craftsman'] = 'Draught of the Craftsman I' }
    G.consumeBuff = 'Draught of the Craftsman I'
    G.itemCooldownMs = 60000
end

test('in game: /lc radix - a Draught before each combine, the cooldown waited out between them', function()
    local F, G, done = marr(function(G) radix_forge(G, 2) end)
    F.at(100, function() F.mq.cmd('/lc radix 2 draught Fusion Chamber Base') end)
    F.at(400, function() F.click('Go') end)
    F.at(240000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    eq(G.protected, 2, 'both combines made under the Draught')
    eq(G:count('Draught of the Craftsman'), 0, 'both used'); eq(G:count('Fusion Chamber Base'), 2)
    truthy(printed:find('to come off cooldown', 1, true), 'the cooldown was waited for')
    truthy(printed:find('Fusion Chamber Base: 2/2 ok, made 2', 1, true), printed:match('[^\n]*Done[^\n]*') or printed)
    done()
end)

test('in game: /lc radix - out of Draughts mid-run: it stops before the next combine, never makes it unprotected', function()
    local F, G, done = marr(function(G) radix_forge(G, 1) end)
    F.at(100, function() F.mq.cmd('/lc radix 2 draught Fusion Chamber Base') end)
    F.at(400, function() F.click('Go') end)
    F.at(240000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    eq(G.protected, 1); eq(G:count('Fusion Chamber Base'), 1, 'one made, the second never tried')
    eq(G:count('Element Imbued Metal Sheet'), 2, 'the second combine kept its sheets')
    truthy(printed:find('no Draught of the Craftsman left', 1, true), printed)
    done()
end)

test('in game: /lc radix - ticked with no Draught at all: nothing happens', function()
    local F, G, done = marr(function(G) radix_forge(G, 0) end)
    F.at(100, function() F.mq.cmd('/lc radix 1 draught Fusion Chamber Base') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    eq(G:count('Fusion Chamber Base'), 0); eq(G:count('Element Imbued Metal Sheet'), 4, 'nothing used')
    truthy(printed:find('there is no Draught of the Craftsman in the bags', 1, true), printed)
    done()
end)

test('in game: /lc radix - unticked, it combines without a Draught and clicks nothing', function()
    local F, G, done = marr(function(G) radix_forge(G, 1) end)
    F.at(100, function() F.mq.cmd('/lc radix 1 nodraught Fusion Chamber Base') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    eq(G:count('Fusion Chamber Base'), 1); eq(G:count('Draught of the Craftsman'), 1, 'not used'); eq(G.used, nil, 'nothing clicked')
    done()
end)

test('in game: /lc make 2 Studs takes water from the bank, uses the File in the bags as the tool', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'File', 1)
        G:bankbag(1, 'Bank Bag', 10); G:bankput(1, 1, 'Water Flask', 50)
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 Studs') end)
    F.at(400, function() F.click('Go') end)
    F.at(150000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Bank: took 5 Water Flask', 1, true), printed:match('[^\n]*Bank:[^\n]*') or printed)
    truthy(printed:find('Bought 6 Small Piece of Ore from Borik Darkanvil', 1, true), printed)
    truthy(printed:find('Metal Bits: 3/3 ok, made 6; Studs: 2/2 ok, made 2', 1, true), printed:match('[^\n]*Done[^\n]*') or printed)
    eq(G:count('File'), 1, 'the tool came back'); eq(G:count('Studs'), 2); eq(G:bankcount('Water Flask'), 45)
    done()
end)

test('in game: /lc make 2 Studs with the File (a tool) in the bank pulls it with the water', function()
    local F, G, done = marr(function(G)
        G:bankbag(1, 'Bank Bag', 10); G:bankput(1, 1, 'Water Flask', 50); G:bankput(1, 2, 'File', 1)
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 Studs') end)
    F.at(400, function() F.click('Go') end)
    F.at(150000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Bank: took 1 File', 1, true), printed:match('[^\n]*Bank:[^\n]*') or printed)
    truthy(printed:find('Metal Bits: 3/3 ok, made 6; Studs: 2/2 ok, made 2', 1, true), printed:match('[^\n]*Done[^\n]*') or printed)
    eq(G:count('File'), 1, 'the tool came back'); eq(G:bankcount('File'), 0); eq(G:count('Studs'), 2)
    done()
end)

test('in game: a failed subcombine leaves the next steps short; they make what they can and say why', function()
    local F, G, done = marr(function(G) G.combineFails = 1; G.noStack = { ['skewer mold'] = true } end)
    F.at(100, function() F.mq.cmd('/lc make 2 Rat Kabobs') end)
    F.at(400, function() F.click('Go') end)
    F.at(150000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(line:find('Metal Bits: 0/1 ok, 1 failed, made 0', 1, true), line)
    truthy(line:find('Skewers: 0/1 ok, made 0 (out of Metal Bits after 0 combines)', 1, true), line)
    truthy(line:find('Rat Kabobs: 0/2 ok, made 0 (out of Skewers after 0 combines)', 1, true), line)
    eq(G:count('Rat Kabobs'), 0)
    done()
end)

test('in game: Rat Kabobs - the Skewers come back first, the kabob lands later; both are stowed before moving on', function()
    local F, G, done = marr(function(G) G.productLateMs = 80; G.noStack = { ['skewer mold'] = true } end)
    F.at(100, function() F.mq.cmd('/lc make 2 Rat Kabobs') end)
    F.at(400, function() F.click('Go') end)
    F.at(150000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(line:find('Metal Bits: 1/1 ok, made 2; Skewers: 1/1 ok, made 1; Rat Kabobs: 2/2 ok, made 2', 1, true), line)
    eq(G:count('Rat Kabobs'), 2); eq(G:count('Skewers'), 1, 'the tool came back'); eq(#G.cursor, 0)
    done()
end)

local function kabob_bags(G)
    G:put(1, 1, 'Rat Meat', 2); G:put(1, 2, 'Spices', 2); G:put(1, 3, 'Jug of Sauces', 2); G:put(1, 4, 'Skewers', 1)
end

test('in game: a failed combine waits for the tool it hands back, even when it comes late, then goes on', function()
    local F, G, done = marr(function(G) kabob_bags(G); G.combineFails = 1; G.returnLateMs = 150 end)
    F.at(100, function() F.mq.cmd('/lc make 2 Rat Kabobs') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Rat Kabobs 1/2: failed', 1, true) and printed:find('back: Skewers x1 (tool)', 1, true), printed)
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(line:find('Rat Kabobs: 1/2 ok, 1 failed, made 1', 1, true), line)
    truthy(not printed:find('arrived on the cursor after', 1, true), 'nothing was late')
    eq(G:count('Skewers'), 1); eq(G:count('Rat Kabobs'), 1); eq(#G.cursor, 0)
    done()
end)

test('in game: a failure that keeps the tool is reported, and the step stops short instead of hanging', function()
    local F, G, done = marr(function(G) kabob_bags(G); G.combineFails = 1; G.failKeepsTools = true end)
    F.at(100, function() F.mq.cmd('/lc make 2 Rat Kabobs') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('failed, but Skewers x1 did not come back', 1, true), printed)
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(line:find('Rat Kabobs: 0/1 ok, 1 failed, made 0 (out of Skewers after 1 combine)', 1, true)
        or line:find('Rat Kabobs: 0/2 ok, 1 failed, made 0 (out of Skewers after 1 combine)', 1, true), line)
    eq(G:count('Skewers'), 0); eq(G:count('Rat Meat'), 1)
    done()
end)

test('in game: salvage that lands after the combine is over, at any moment, is stowed and the run goes on', function()
    local lateSeen = false
    -- with an item pace, the pickups take time, so a late landing can fall between combines or inside a pickup
    -- up to Combine.SALVAGE_MS the combine itself waits for it; later ones land between combines or inside a pickup
    for _, ms in ipairs({ 20, 70, 120, 170, 220, 270, 400, 470, 540 }) do
        local F, G, done = marr(function(G)
            local sf = io.open(ROOT .. 'settings/LazCraft_Glanen.ini', 'w'); sf:write('[Settings]\nClickPace=fixed\nClickFloorMs=0\nQuietMs=0\nItemPaceMs=100\n'); sf:close()
            G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2)
            G.combineFails = 1; G.salvage = { ['Metal Bits'] = { 'Small Piece of Ore' } }; G.salvageLateMs = ms
        end)
        F.at(100, function() F.mq.cmd('/lc make 2 Metal Bits') end)
        F.at(400, function() F.click('Go') end)
        F.at(60000, function() F.mq.cmd('/lc quit') end)
        assert(loadfile(ROOT .. 'init.lua'))()
        _G.print = realPrint
        local printed = table.concat(F.printed, '\n')
        local line = printed:match('[^\n]*Done[^\n]*') or printed
        truthy(line:find('Metal Bits: 1/2 ok, 1 failed, made 2', 1, true), ms .. 'ms: ' .. line)
        eq(G:count('Small Piece of Ore'), 1, ms .. 'ms: the salvaged ore is back in the bags')
        eq(G:count('Metal Bits'), 2); eq(#G.cursor, 0, ms .. 'ms: cursor empty')
        local late = printed:find('Small Piece of Ore x1 arrived on the cursor after the last combine was over', 1, true)
        if late then lateSeen = true end
        if ms <= 270 then truthy(not late, ms .. 'ms: waited for inside the combine') end
        truthy(not printed:find('Pickup failed', 1, true), ms .. 'ms: ' .. printed)
        done()
    end
    truthy(lateSeen, 'at least one landing was caught between combines')
end)

test('in game: salvage landing while the next combine is placed empties the container and places it again - no refusal (2.43.5)', function()
    local F, G, done = marr(function(G)
        local sf = io.open(ROOT .. 'settings/LazCraft_Glanen.ini', 'w'); sf:write('[Settings]\nClickPace=fixed\nClickFloorMs=0\nQuietMs=0\nItemPaceMs=100\n'); sf:close()
        G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2)
        G.combineFails = 1; G.salvage = { ['Metal Bits'] = { 'Small Piece of Ore' } }; G.salvageLateMs = 450; G.salvageHeld = true
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(printed:find('something came back late from the last combine while placing - emptying', 1, true), printed)
    truthy(not printed:find('the game refused it', 1, true), 'placed again before the combine, so never refused')
    truthy(line:find('Metal Bits: 1/2 ok, 1 failed, made 2', 1, true), line)
    eq(G:count('Small Piece of Ore'), 1); eq(#G.cursor, 0)
    done()
end)

test('in game: with no item pace, salvage put away mid-pickup as "not ours" still places the round again (2.46.3 Vadar log)', function()
    for _, ms in ipairs({ 330, 360, 390, 420, 450, 480, 510 }) do
        local F, G, done = marr(function(G)
            local sf = io.open(ROOT .. 'settings/LazCraft_Glanen.ini', 'w'); sf:write('[Settings]\nClickPace=fixed\nClickFloorMs=0\nQuietMs=0\nItemPaceMs=0\n'); sf:close()
            G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2)
            G.combineFails = 1; G.salvage = { ['Metal Bits'] = { 'Small Piece of Ore' } }; G.salvageLateMs = ms; G.salvageHeld = true
        end)
        F.at(100, function() F.mq.cmd('/lc make 2 Metal Bits') end)
        F.at(400, function() F.click('Go') end)
        F.at(60000, function() F.mq.cmd('/lc quit') end)
        assert(loadfile(ROOT .. 'init.lua'))()
        _G.print = realPrint
        local printed = table.concat(F.printed, '\n')
        local line = printed:match('[^\n]*Done[^\n]*') or printed
        if printed:find('(not ours)', 1, true) then
            truthy(printed:find('placing it all again', 1, true), ms .. 'ms: a stray marks the round: ' .. printed)
        end
        truthy(line:find('Metal Bits: 1/2 ok, 1 failed, made 2', 1, true), ms .. 'ms: ' .. line)
        eq(G:count('Small Piece of Ore'), 1, ms .. 'ms'); eq(#G.cursor, 0, ms .. 'ms: cursor empty')
        done()
    end
end)

test('in game: the game\'s desync lines are waited out, the container emptied and placed again (2.46.3 Vadar log)', function()
    local F, G, done = marr(function(G)
        local sf = io.open(ROOT .. 'settings/LazCraft_Glanen.ini', 'w'); sf:write('[Settings]\nClickPace=fixed\nClickFloorMs=0\nQuietMs=0\nItemPaceMs=100\n'); sf:close()
        G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2)
        G.combineFails = 1; G.salvage = { ['Metal Bits'] = { 'Small Piece of Ore' } }; G.salvageLateMs = 450; G.salvageHeld = true
        G.desyncOnLate = true
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(printed:find('the game resent its inventory (desync)', 1, true), printed)
    truthy(not printed:find('the game refused it', 1, true), 'waited out and placed again, so never refused')
    truthy(line:find('Metal Bits: 1/2 ok, 1 failed, made 2', 1, true), line)
    eq(G:count('Small Piece of Ore'), 1); eq(#G.cursor, 0)
    done()
end)

test('datacache: round trip keeps values, shared tables, a self-reference, big tables and holes; a changed file parses again', function()
    local DataCache = require('core.datacache')
    local function deq(a, b, path, seen)
        seen = seen or {}
        if type(a) ~= 'table' or type(b) ~= 'table' then
            if a ~= b then error(path .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end
            return
        end
        if seen[a] then return end
        seen[a] = true
        for k, v in pairs(a) do deq(v, b[k], path .. '.' .. tostring(k), seen) end
        for k in pairs(b) do if a[k] == nil then error(path .. '.' .. tostring(k) .. ' extra') end end
    end
    local shared = { name = 'Water Flask', n = 2 }
    local big = {}
    for i = 1, 450 do big['k' .. i] = { i, i * 1.5, 'v"' .. i .. '\n' } end
    local data = { cfg = { a = shared, b = { shared, shared }, big = big, ['end'] = true, ['with space'] = -0.25,
                           holes = { 1, nil, 3 }, list = { 'x', 'y' }, [7] = 'seven' }, problems = { 'p1' } }
    data.cfg.me = data.cfg   -- a table that contains itself
    local old = DataCache.BATCH_CONSTS
    DataCache.BATCH_CONSTS = 50   -- many small functions: the splitting is exercised
    local text = assert(DataCache.serialize(data, 'K', { 'x.ini' }))
    DataCache.BATCH_CONSTS = old
    local head = assert(loadstring(text))()
    eq(head.key, 'K'); eq(head.files[1], 'x.ini')
    local back = head.build()
    deq(data, back, 'data')
    truthy(back.cfg.a == back.cfg.b[1] and back.cfg.b[1] == back.cfg.b[2], 'shared stays shared')
    truthy(back.cfg.me == back.cfg, 'the self-reference too')
    truthy(not DataCache.serialize({ f = print }, 'K', {}), 'a function is refused')

    -- load(): parse once, then the cache; a data file that changes parses again
    local dir = TESTS_DIR .. 'tmp_dc/'
    os.execute('mkdir -p "' .. dir .. '"')
    local function put(text2) local fh = io.open(dir .. 'a.ini', 'w'); fh:write(text2); fh:close() end
    put('[S]\nk=1\n')
    local parses = 0
    local o = { dataDir = dir, path = dir .. 'cache.lua', who = 'Glanen', code = { ROOT .. 'core/datacache.lua' },
                parse = function(onRead)
                    parses = parses + 1
                    onRead('a.ini')
                    local d = require('core.ini').load(dir .. 'a.ini')
                    return { k = d.sections.S.map.k, many = big }, { 'a problem' }
                end }
    local c1, p1, how1 = DataCache.load(o)
    eq(how1, 'parsed'); eq(c1.k, '1'); eq(p1[1], 'a problem')
    local c2, p2, how2 = DataCache.load(o)
    eq(how2, 'cache'); eq(parses, 1, 'the second start did not parse'); eq(c2.k, '1'); eq(p2[1], 'a problem')
    deq(c1.many, c2.many, 'many')
    put('[S]\nk=22\n')
    local c3, _, how3 = DataCache.load(o)
    eq(how3, 'parsed', 'a changed file'); eq(c3.k, '22'); eq(parses, 2)
    os.remove(dir .. 'a.ini'); os.remove(dir .. 'cache.lua'); os.execute('rm -rf "' .. dir .. '"')

    -- the real data/: what the cache gives back is what the parse gave
    local Config = require('core.config')
    local cfg, problems = Config.load(ROOT .. 'data/')
    local t2 = assert(DataCache.serialize({ cfg = cfg, problems = problems }, 'K', {}))
    local real = assert(loadstring(t2))().build()
    deq(cfg, real.cfg, 'cfg')
end)

test('pace: the quiet window widens x1.5 on trouble (up to MAX), narrows a step after EASE_AFTER clean combines (down to MIN); fixed never moves; the floor is fixed', function()
    local Pace = require('core.pace')
    local st = { ClickPace = 'auto', QuietMs = '300' }
    local said = {}
    local p = Pace.new({ get = function(k) return st[k] end, set = function(k, v) st[k] = v end,
                         log = { info = function(f, ...) said[#said + 1] = string.format(f, ...) end, debug = function() end } })
    eq(p:quiet_ms(), 300); eq(p:floor_ms(), Pace.FLOOR_MS, 'a frame unless set')
    p:hit('desync'); eq(p:quiet_ms(), 450); eq(st.QuietMs, '450', 'saved'); truthy(said[1]:find('300 -> 450ms', 1, true), said[1])
    for _ = 1, 10 do p:hit('desync') end
    eq(p:quiet_ms(), Pace.MAX_MS, 'capped')
    for _ = 1, Pace.EASE_AFTER - 1 do p:clean() end
    eq(p:quiet_ms(), Pace.MAX_MS, 'not yet')
    p:clean(); eq(p:quiet_ms(), Pace.MAX_MS - Pace.STEP_MS, 'one step down')
    for _ = 1, Pace.EASE_AFTER - 1 do p:clean() end
    p:hit('refused'); eq(p:quiet_ms(), Pace.MAX_MS, 'trouble resets the streak and widens again (capped)')
    st.QuietMs = tostring(Pace.MIN_MS)
    for _ = 1, Pace.EASE_AFTER * 3 do p:clean() end
    eq(p:quiet_ms(), Pace.MIN_MS, 'never below MIN')
    st.ClickPace, st.QuietMs = 'fixed', '0'
    p:hit('desync'); for _ = 1, Pace.EASE_AFTER do p:clean() end
    eq(p:quiet_ms(), 0, 'fixed is used as set, 0 included'); eq(st.QuietMs, '0')
    st.QuietMs = nil; st.ClickPace = 'auto'
    eq(p:quiet_ms(), Pace.START_MS, 'nothing saved yet: the start')
    st.ClickFloorMs = '0'; eq(p:floor_ms(), 0, 'the floor as set')
end)

test('in game: burst, then listen - a desync in the quiet window places the round again and widens the window, kept (2.46.5 Vadar log)', function()
    local F, G, done = marr(function(G)
        local sf = io.open(ROOT .. 'settings/LazCraft_Glanen.ini', 'w'); sf:write('[Settings]\nClickPace=auto\nQuietMs=300\n'); sf:close()
        G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2)
        G.combineFails = 1; G.salvage = { ['Metal Bits'] = { 'Small Piece of Ore' } }; G.salvageLateMs = 450; G.salvageHeld = true
        G.desyncOnLate = true
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    -- the stray and its desync lines land together: either can be what widens it
    truthy(printed:find('Pace: quiet window 300 -> 450ms before each combine (', 1, true), printed)
    truthy(not printed:find('the game refused it', 1, true), 'caught before the combine, so never refused')
    truthy(line:find('Metal Bits: 1/2 ok, 1 failed, made 2', 1, true), line)
    local sf = io.open(ROOT .. 'settings/LazCraft_Glanen.ini', 'r'); local text = sf:read('*a'); sf:close()
    truthy(text:find('QuietMs=450', 1, true), 'remembered: ' .. text)
    done()
end)

test('in game: salvage that comes with the failure is named in the report line', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2)
        G.combineFails = 1; G.salvage = { ['Metal Bits'] = { 'Small Piece of Ore' } }
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Metal Bits 1/2: failed', 1, true) and printed:find('back: Small Piece of Ore x1 (salvage)', 1, true), printed)
    done()
end)

test('in game: a combine is not fired when the container does not hold what was placed', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 2); G:put(1, 2, 'Water Flask', 1)
        local g = G
        local orig = G.command
        G.command = function(self, s)   -- something lands in slot 4 of the forge just as slot 3 is filled
            orig(self, s)
            if s == '/nomodkey /itemnotify enviro3 leftmouseup' then g.enviro[4] = { name = 'Rusty Dagger', stack = 1, id = 9999 } end
        end
    end)
    F.at(100, function() F.mq.cmd('/lc make 1 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('does not hold what was placed', 1, true), printed)
    truthy(not table.concat(G.log, '\n'):find('/combine enviro', 1, true), 'no combine fired')
    eq(G:count('Metal Bits'), 0)
    done()
end)

test('in game: a success that makes a different count than the data says is reported', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 2); G:put(1, 2, 'Water Flask', 1); G.yields = { ['Metal Bits'] = 3 }
    end)
    F.at(100, function() F.mq.cmd('/lc make 1 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('the data says Yield=2, the game made 3', 1, true), printed)
    done()
end)

test('in game: make ... destroy - each product goes off the cursor with /destroy; nothing else is destroyed', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2); G:put(1, 3, 'Metal Bits', 5)
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 destroy Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(line:find('Metal Bits: 2/2 ok, made 4, destroyed 4', 1, true), line)
    eq(G:count('Metal Bits'), 5, 'the 5 we had are untouched'); eq(G.destroyed, 2); eq(#G.cursor, 0)
    done()
end)

test('in game: make ... sell - what this run made is sold at a merchant here at the end', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2); G:put(1, 3, 'Metal Bits', 5)
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 sell Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(90000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(printed:find('Sold 4 Metal Bits to', 1, true), printed)
    truthy(line:find('made 4, sold 4', 1, true), line)
    eq(G:count('Metal Bits'), 5, 'only what this run made was sold')
    done()
end)

test('in game: make ... sell - a product that stacked into the Ammo slot comes off into the bags and is sold', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2)
        G.worn = { ammo = { name = 'Metal Bits', stack = 3, id = 4454 } }
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 sell Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(90000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(printed:find('Took the Metal Bits stack out of the Ammo slot to sell it', 1, true), printed)
    truthy(printed:find('Sold 4 Metal Bits to', 1, true), printed)
    truthy(line:find('made 4, sold 4', 1, true), line)
    eq(G.worn.ammo, nil, 'Ammo emptied'); eq(G:count('Metal Bits'), 3, 'the 3 that were there before stay, in the bags')
    done()
end)

test('in game: /lc snap writes the game as it stands - cursor, windows, every bag and what is in it, the last chat (2.43.11)', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 4); G:hold('Brut Champagne', 1)
    end)
    F.at(100, function() F.say('Brewmaster Berina says, Welcome!') end)
    F.at(200, function() F.mq.cmd('/lc snap') end)
    F.at(2500, function() F.mq.cmd('/lc quit') end)   -- past a status rewrite (once a second)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Snapshot (asked: /lc snap)', 1, true), printed)
    truthy(printed:find('cursor: Brut Champagne x1', 1, true), 'cursor')
    truthy(printed:find('Small Piece of Ore x4', 1, true), 'bag contents')
    truthy(printed:find('Brewmaster Berina says, Welcome!', 1, true), 'chat')
    -- the live status file (2.44.0): who, the job, the cursor, the chat
    local fh = io.open(ROOT .. 'logs/LazCraft_Glanen_status.txt', 'r')
    truthy(fh, 'status file written')
    local st = fh and fh:read('*a') or ''; if fh then fh:close() end
    truthy(st:find('LazCraft ', 1, true) and st:find('on Glanen (crafter)', 1, true), st)
    truthy(st:find('cursor: Brut Champagne x1', 1, true) and st:find('Welcome!', 1, true), st)
    done()
end)

test('in game: a combine the game refuses although all showed placed is cleared and placed again once', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2)
        G.serverLosesSlot = 2
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(90000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(printed:find('the game refused it (You cannot combine these items in this container type!); the container now shows 1=Small Piece of Ore x1', 1, true), printed)
    truthy(line:find('Metal Bits: 2/2 ok, made 4', 1, true), line)
    truthy(printed:find('clearing it, /cleanup, opening it again', 1, true), 'the 2.43.4 recovery: /cleanup and open again')
    truthy(printed:find('Snapshot (Metal Bits 1/2 refused', 1, true), 'a snapshot when it was refused (2.43.11)')
    local cl = 0; for _, c in ipairs(G.log) do if c == '/cleanup' then cl = cl + 1 end end
    truthy(cl >= 1, '/cleanup sent')
    done()
end)

test('in game: Leveling Clean up finished rows - every row at its trivial under one preview and one Go (2.43.5)', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Metal Bits', 5); G:put(1, 2, 'Small Piece of Ore', 3); G:put(1, 3, 'Water Flask', 2)
        G.skills = { Blacksmithing = 230 }
    end)
    local frames = {}
    local label
    F.at(100, function()
        F.tab = 'Leveling'; F.openCombo = 'Skill##lc_lvl'; F.click('Blacksmithing (Blacksmithing 230)##lc_lvl_Blacksmithing'); F.draw(); F.openCombo = nil
        for _, l in ipairs(F.draw()) do label = label or l:match('(Clean up finished rows %(%d+%)##lc_lv_cldone)') end
    end)
    F.at(200, function() if label then F.click(label) end; F.draw() end)
    F.at(500, function() frames.preview = F.draw(); F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(label and not label:find('(0)', 1, true), 'the button counts the finished rows: ' .. tostring(label))
    local pv = table.concat(frames.preview or {}, '\n')
    truthy(pv:find('rows at their trivial', 1, true), pv)
    truthy(pv:find('Sell 5 Metal Bits', 1, true), pv)
    local jobs = 0; for _ in printed:gmatch('Clean up Blacksmithing: %d+ finished rows? %- press Go') do jobs = jobs + 1 end
    eq(jobs, 1, 'one job')
    truthy(printed:find('Sold 5 Metal Bits to', 1, true), printed)
    eq(G:count('Metal Bits'), 0)
    done()
end)

test('in game: Leveling Clean up - sells a row\'s product and buyable leftovers, keeps what another row still needs', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Metal Bits', 5); G:put(1, 2, 'Small Piece of Ore', 3); G:put(1, 3, 'Water Flask', 2)
        G.skills = { Blacksmithing = 230 }   -- past both Barbs rows, which make Metal Bits (2.43.1)
    end)
    local frames = {}
    F.at(100, function() F.tab = 'Leveling'; F.openCombo = 'Skill##lc_lvl'; F.click('Blacksmithing (Blacksmithing 230)##lc_lvl_Blacksmithing'); F.draw(); F.openCombo = nil; F.draw() end)
    F.at(200, function() F.click('Clean up##lc_lv_cl_Blacksmithing_1'); F.draw() end)
    F.at(500, function() frames.preview = F.draw(); F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local pv = table.concat(frames.preview or {}, '\n')
    truthy(pv:find('Sell 5 Metal Bits', 1, true) and pv:find('Sell 3 Small Piece of Ore', 1, true), printed)
    truthy(pv:find('Sell 2 Water Flask', 1, true), 'no row left to do needs it')
    truthy(printed:find('Sold 5 Metal Bits to', 1, true) and printed:find('Sold 3 Small Piece of Ore to', 1, true), printed)
    eq(G:count('Metal Bits'), 0); eq(G:count('Small Piece of Ore'), 0); eq(G:count('Water Flask'), 0)
    done()
end)

test('in game: Leveling Clean up - a product the merchant refuses and the data gives no value is destroyed; farmed ore and tools stay', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Rhenium Barbs', 4); G:put(1, 2, 'Rhenium Ore', 2); G:put(1, 3, 'File', 1)
        G.skills = { Blacksmithing = 200 }; G.noValue = { ['Rhenium Barbs'] = true }
    end)
    local frames = {}
    F.at(100, function() F.tab = 'Leveling'; F.openCombo = 'Skill##lc_lvl'; F.click('Blacksmithing (Blacksmithing 200)##lc_lvl_Blacksmithing'); F.draw(); F.openCombo = nil; F.draw() end)
    F.at(200, function() F.click('Clean up##lc_lv_cl_Blacksmithing_6'); F.draw() end)
    F.at(500, function() frames.preview = F.draw(); F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local pv = table.concat(frames.preview or {}, '\n')
    truthy(pv:find('Sell 4 Rhenium Barbs - DESTROYED if the merchant will not take it', 1, true), pv)
    truthy(pv:find('Keep 2 Rhenium Ore', 1, true), pv)
    truthy(not pv:find('File', 1, true), 'the tool is not even listed')
    truthy(printed:find('Destroyed 4 Rhenium Barbs', 1, true), printed)
    eq(G:count('Rhenium Barbs'), 0); eq(G:count('Rhenium Ore'), 2); eq(G:count('File'), 1)
    done()
end)

test('path: a row that failed on the way is made once more; only a row at its trivial is cleaned up (2.43.1)', function()
    local Make = require('engine.make')
    local realJob, realClean, realPast = Make.job, package.loaded['engine.cleanup'], Make.past_trivial
    Make.past_trivial = function(_, r) return r.label ~= 'D' end   -- D ends ok but short of its trivial
    local runs, cleaned, logs = {}, {}, {}
    local results = { A = { R.fail('kit did not open', 'nothing opened'), R.ok({ summary = 'done' }) },
                      B = { R.fail('kit did not open', 'x'), R.fail('kit did not open', 'y') },
                      C = { R.fail('plan changed', 'farm it') }, D = { R.ok({ summary = 'made some' }) } }
    Make.job = function(_, recipe)
        return { execute = function() runs[#runs + 1] = recipe.label; return table.remove(results[recipe.label], 1) end,
                 cleanup = function() return R.ok() end }
    end
    package.loaded['engine.cleanup'] = { needs = function() return {} end, after_row = function(_, _, recipe) cleaned[#cleaned + 1] = recipe.label; return R.ok({ summary = 'nothing to clean up' }) end }
    local log = { info = function(f, ...) logs[#logs + 1] = string.format(f, ...) end, warn = function(f, ...) logs[#logs + 1] = string.format(f, ...) end,
                  debug = function() end }
    local env = { log = log, world = function() return {} end, mq = { TLO = {} } }
    local rows = { { recipe = { label = 'A', ins = {}, tools = {} }, n = 1 }, { recipe = { label = 'B', ins = {}, tools = {} }, n = 1 },
                   { recipe = { label = 'C', ins = {}, tools = {} }, n = 1 }, { recipe = { label = 'D', ins = {}, tools = {} }, n = 1 } }
    local ok, err = pcall(function()
        local job = Make.chain(env, rows, 'Level X')
        return job.execute({ checkpoint = function() return true end, status = function() end })
    end)
    Make.job, package.loaded['engine.cleanup'], Make.past_trivial = realJob, realClean, realPast
    truthy(ok, tostring(err))
    eq(table.concat(runs, ','), 'A,A,B,B,C,D', 'A and B tried twice, C (a final failure) once')
    eq(table.concat(cleaned, ','), 'A', 'only the row at its trivial is cleaned up')
    local text = table.concat(logs, '\n')
    truthy(text:find('Clean-up after B: skipped - the row did not finish', 1, true), text)
    truthy(text:find('Clean-up after D: skipped - not at its trivial yet', 1, true), text)
    truthy(text:find('Path: A failed (failed: kit did not open', 1, true) and text:find('trying the row once more', 1, true), text)
end)

test('clean-up after a row: product sold (or destroyed when the row says destroy); ingredients under 20pp sold, dearer kept; farmed and needed kept', function()
    -- 2.42.16: the Blacksmithing path's leftovers filled the bags row after row
    local cfg = Config.load(ROOT .. 'data/')
    local P = Planner.new(cfg)
    local Cleanup = require('engine.cleanup')
    local bags = { ['cobalt plate gorget template'] = 10, ['toluene coal'] = 50, ['plate gorget template mold'] = 20,
                   ['metal tempering chemicals'] = 30, ['cobalt ore'] = 40, ['smithy hammer'] = 1 }
    local env = { cfg = cfg, planner = P, blocks = { inventory = { count = function(_, n) return bags[n:lower()] or 0 end } } }
    local r = cfg.recipes['O1418']
    local function find(list, name) for _, x in ipairs(list) do if x.name == name then return x end end end
    local p = Cleanup.plan(env, r, { ['metal tempering chemicals'] = 'row 11 (X) still needs it' }, { maxPrice = 20000, subs = true })
    truthy(find(p.sell, 'Cobalt Plate Gorget Template'), 'product sold')
    truthy(find(p.sell, 'Plate Gorget Template Mold'), 'a 1gp mold sold')
    local coal = find(p.kept, 'Toluene Coal'); truthy(coal and coal.why:find('62pp a unit', 1, true), coal and coal.why)
    truthy(find(p.kept, 'Metal Tempering Chemicals'), 'another row needs it')
    truthy(find(p.kept, 'Cobalt Ore'), 'farmed')
    truthy(not find(p.sell, 'Smithy Hammer') and not find(p.kept, 'Smithy Hammer'), 'the tool is not touched')
    local d = Cleanup.plan(env, r, {}, { maxPrice = 20000, destroyProduct = true })
    truthy(find(d.destroy, 'Cobalt Plate Gorget Template') and not find(d.sell, 'Cobalt Plate Gorget Template'), 'destroyed, not sold')
    local lines = {}; for _, l in ipairs(Cleanup.lines(d)) do lines[#lines + 1] = l.text end
    truthy(table.concat(lines, '\n'):find('Destroy 10 Cobalt Plate Gorget Template', 1, true), table.concat(lines, '\n'))
    bags = {}
    local empty = Cleanup.plan(env, r, {}, { maxPrice = 20000 })
    eq(#empty.sell, 0, 'nothing held: nothing to do')
    -- nothing to do ends the job as done, not as a failed preflight (2.46.4; the 2.46.3 logs logged it as an ERROR)
    local el = Cleanup.lines(empty); eq(el[#el].text, 'Nothing to clean up'); eq(el[#el].level, 'done')
    -- a row not at its trivial keeps all it needs, down its subcombines (2.43.1); an item a merchant sells is bought,
    -- so its parts are not counted
    local n = Cleanup.needs(cfg, cfg.recipes['O265'])
    truthy(n['sheet metal'] and n['water flask'] and n['mail sectional mold'] and not n['small brick of ore'], 'Banded Mail: Sheet Metal is bought')
    local m = Cleanup.needs(cfg, cfg.recipes['O4507'])
    truthy(m['mithril fletchings'] and m['mithril arrow heads'] and m['small brick of mithril'] and m['small groove nocks'],
        'Mithril Champion Arrows, all the way down its subcombines')
    truthy(Cleanup.needs(cfg, cfg.recipes['O5790'])['metal bits'], 'Rhenium Barbs makes Metal Bits: the Metal Bits row keeps them while Barbs is not trivial')
end)

test('config: research.ini - classes, levels, each spell on its recipe (the harvest one when it is the same)', function()
    local cfg = Config.load(ROOT .. 'data/')
    eq(#cfg.research.classes, 16)
    local found
    for _, e in ipairs(cfg.research.index.necromancer[66]) do if e.name == 'Spell: Acikin' then found = e end end
    truthy(found, 'Acikin listed at 66'); eq(cfg.recipes[found.id].container, 'Spell Research Kit'); eq(cfg.recipes[found.id].skill, 'Research')
    truthy(not found.id:match('^R'), 'the harvest recipe is used: ' .. found.id)
    eq(#cfg.recipesByName['vial of pure water'] > 0, true, 'the shared subcombines are there')
    local n = 0; for _, lv in ipairs(cfg.research.levels.cleric) do n = n + #cfg.research.index.cleric[lv] end
    truthy(n > 20, 'cleric has its spells: ' .. n)
end)

test('in game: /lc have - counts what is held, makes the rest, and makes a failure again', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 8); G:put(1, 2, 'Water Flask', 4)
        G.combineFails = 1
    end)
    F.at(100, function() F.mq.cmd('/lc have 4 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(120000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Metal Bits - 1 combine for the 2 still owed (pass 2)', 1, true), printed)
    truthy(printed:find('1 item, 1 done', 1, true), printed)
    eq(G:count('Metal Bits'), 4)
    done()
end)

test('in game: /lc have - what is already held is skipped (nothing to make blocks at the preflight)', function()
    local F, G, done = marr(function(G) G:put(1, 1, 'Metal Bits', 5) end)
    local frame
    F.at(100, function() F.mq.cmd('/lc have 4 Metal Bits') end)
    F.at(400, function() frame = F.draw() end)
    F.at(1000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Everything is already held - nothing to make', 1, true), printed)
    eq(G:count('Metal Bits'), 5)
    done()
end)

test('queue: add (the same one twice adds up), move, set the count, remove; saved and read back', function()
    local Queue = require('core.queue')
    local file = os.tmpname()
    local q = Queue.new({ path = file })
    q:add('craft', 'O4454', 10, 'sell'); q:add('research', 'H11742', 1); q:add('craft', 'O4454', 5)
    eq(#q:list(), 2); eq(q:list()[1].n, 15); eq(q:list()[1].disposal, 'sell')
    q:move(q:list()[2].id, -1); eq(q:list()[1].recipe, 'H11742')
    q:set_n(q:list()[2].id, 7)
    local r = Queue.new({ path = file })
    eq(#r:list(), 2); eq(r:list()[1].kind, 'research'); eq(r:list()[2].n, 7); eq(r:list()[2].disposal, 'sell')
    r:remove(r:list()[1].id); eq(#Queue.new({ path = file }):list(), 1)
    r:clear(); eq(#Queue.new({ path = file }):list(), 0)
    os.remove(file)
end)

test('in game: the queue - run under one Go, entries one after another; finished ones come off', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 6); G:put(1, 2, 'Water Flask', 3)
        local qf = io.open(ROOT .. 'settings/LazCraft_Glanen_queue.ini', 'w')
        qf:write('[Queue]\nEntry=craft|O4454|2|keep\nEntry=research|O4454|6|keep\n'); qf:close()
    end)
    local frames = {}
    F.at(100, function() F.tab = 'Craft'; frames.before = F.draw() end)
    F.at(200, function() F.click('Run queue##lc_q_run'); F.draw() end)
    F.at(600, function() frames.plan = F.draw(); F.click('Go') end)
    F.at(120000, function() frames.after = F.draw(); F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local function has(frame, p) for _, l in ipairs(frame or {}) do if l:find(p, 1, true) then return true end end return false end
    truthy(has(frames.before, 'heading:Queue (2)') and has(frames.before, 'text:Metal Bits') and has(frames.before, 'disabled:combines')
        and has(frames.before, 'disabled:in hand'), table.concat(frames.before or {}, '\n'))
    truthy(has(frames.before, 'button:Up##lc_q_u_1 (off)') and has(frames.before, 'button:Dn##lc_q_d_2 (off)'), 'first up and last down are off')
    truthy(has(frames.plan, '1. Metal Bits [O4454]: 2 combines, keep') and has(frames.plan, '2. Metal Bits [O4454]: make 6 (a failure is made again)'), table.concat(frames.plan or {}, '\n'))
    truthy(printed:find('2 entries, 2 done', 1, true) or printed:find('2 items, 2 done', 1, true), printed)
    eq(G:count('Metal Bits'), 6)
    truthy(has(frames.after, 'heading:Queue (0)'), 'finished entries came off')
    os.remove(ROOT .. 'settings/LazCraft_Glanen_queue.ini')
    done()
end)

test('in game: the queue buys everything for its entries in one trip, then makes them (no shopping per entry)', function()
    local F, G, done = marr(function(G)
        local qf = io.open(ROOT .. 'settings/LazCraft_Glanen_queue.ini', 'w')
        qf:write('[Queue]\nEntry=craft|O4454|3|keep\nEntry=craft|O4454|2|keep\n'); qf:close()
    end)
    F.at(100, function() F.tab = 'Craft'; F.draw() end)
    F.at(200, function() F.click('Run queue##lc_q_run'); F.draw() end)
    F.at(600, function() F.click('Go') end)
    F.at(120000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Gathering for 2 entries in one trip', 1, true), printed)
    local opens = 0; for _, c in ipairs(G.log) do if c:find('Merchant.OpenWindow', 1, true) then opens = opens + 1 end end
    eq(opens, 1, 'one merchant visit for both entries')
    local _, forge = printed:gsub('Forge open %(', '')
    eq(forge, 1, 'the forge stays open from one entry to the next')
    truthy(printed:find('2 items, 2 done', 1, true) or printed:find('2 entries, 2 done', 1, true), printed)
    eq(G:count('Metal Bits'), 10)
    os.remove(ROOT .. 'settings/LazCraft_Glanen_queue.ini')
    done()
end)

test('in game: a gathering trip that fails on the way is made again, not left to each entry', function()
    -- 2.42.8 log: the nav to Klonopin wedged, "did not arrive", and 32 research entries each shopped for themselves
    local F, G, done = marr(function(G)
        local qf = io.open(ROOT .. 'settings/LazCraft_Glanen_queue.ini', 'w')
        qf:write('[Queue]\nEntry=craft|O4454|3|keep\nEntry=craft|O4454|2|keep\n'); qf:close()
        G.navIgnores = 99
    end)
    F.at(100, function() F.tab = 'Craft'; F.draw() end)
    F.at(200, function() F.click('Run queue##lc_q_run'); F.draw() end)
    F.at(600, function() F.click('Go') end)
    -- the way clears once the first trip has failed
    F.ticks[#F.ticks + 1] = function()
        if G.navIgnores > 0 and table.concat(F.printed, '\n'):find('trying the trip again', 1, true) then G.navIgnores = 0 end
    end
    F.at(200000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('trying the trip again (2 of 3)', 1, true), printed)
    truthy(not printed:find('each entry gets what it needs itself', 1, true), 'not left to each entry')
    local opens = 0; for _, c in ipairs(G.log) do if c:find('Merchant.OpenWindow', 1, true) then opens = opens + 1 end end
    eq(opens, 1, 'one merchant visit for both entries')
    eq(G:count('Metal Bits'), 10)
    os.remove(ROOT .. 'settings/LazCraft_Glanen_queue.ini')
    done()
end)

test('in game: a research entry whose combine failed is made again after the others (pass 2), not dropped', function()
    -- 2.41.6 log: Word Of Chaos failed ("You lacked the skills") and ended "a round made none"
    local F, G, done = marr(function(G)
        G.combineFails = 1
        local qf = io.open(ROOT .. 'settings/LazCraft_Glanen_queue.ini', 'w')
        qf:write('[Queue]\nEntry=research|O4454|2|keep\nEntry=craft|O4454|1|keep\n'); qf:close()
    end)
    F.at(100, function() F.tab = 'Craft'; F.draw() end)
    F.at(200, function() F.click('Run queue##lc_q_run'); F.draw() end)
    F.at(600, function() F.click('Go') end)
    F.at(200000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('a combine failed) - made again after the others', 1, true), printed)
    truthy(printed:find('Pass 2: 1 entry failed - made again', 1, true), printed)
    truthy(printed:find('2 items, 2 done', 1, true), printed)
    eq(G:count('Metal Bits'), 4)
    os.remove(ROOT .. 'settings/LazCraft_Glanen_queue.ini')
    done()
end)

test('in game: short of a held item (nobody sells it) - makes the combines what is on hand covers, and says so', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Tungsten Ore', 5); G:put(1, 2, 'Water Flask', 4)
        G.recipes['Tungsten Bits'] = { 'Tungsten Ore', 'Tungsten Ore', 'Water Flask' }
    end)
    F.at(100, function() F.mq.cmd('/lc make 4 O122') end)
    F.at(400, function() F.click('Go') end)
    F.at(90000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Only enough Tungsten Ore for 2 of 4 combines - making 2', 1, true), printed)
    eq(G:count('Tungsten Bits'), 2); eq(G:count('Tungsten Ore'), 1)
    done()
end)

test('rates: the skill-up model x K, pulled toward your own runs of the skill as they add up; runs saved, shared ones kept', function()
    local Rates = require('core.rates')
    eq(Rates.p2(10), 1); eq(Rates.p2(100), 0.5); eq(Rates.p2(175), 0.125); truthy(math.abs(Rates.p2(300) - 0.025) < 1e-9)
    eq(Rates.success(100, 300), 0.05); eq(Rates.success(290, 300), 0.95)
    -- 2.41.9 log: Unfired Idol (Emerald) 255 -> 281 took 564 combines (536 ok, 28 failed)
    local m = Rates.model(255, 281, 282); truthy(m * Rates.K > 0.9 * 564 and m * Rates.K < 1.1 * 564, 'model ' .. m)
    local learned = os.tmpname(); os.remove(learned)
    local r = Rates.new({ learned = learned })
    local n, src, fac = r:estimate('Bob', 'Pottery', 255, 281, 282); eq(src, 'guess'); eq(fac, Rates.K); eq(n, math.ceil(m * Rates.K))
    eq(select(1, r:estimate('Bob', 'Baking', 110, 110, 150)), 0, 'nothing to go')
    r:add('O7', 1000, 26, 255, 281, { who = 'Bob', skill = 'Pottery', trivial = 282 })
    n, src, fac = r:estimate('Bob', 'Pottery', 255, 281, 282); eq(src, 'yours')
    truthy(math.abs(fac - (1000 + Rates.K * Rates.PRIOR) / (m + Rates.PRIOR)) < 1e-6, fac)
    truthy(fac > Rates.K and fac < 1000 / m, 'pulled toward Bob\'s runs, not all the way')
    eq(select(2, r:estimate('Ann', 'Pottery', 255, 281, 282)), 'guess', 'Bob\'s runs are not Ann\'s')
    local other = Rates.new({ learned = learned })
    other:add('O5', 10, 5, 0, 5, { who = 'Ann', skill = 'Baking', trivial = 20 })   -- another character saves after us
    r:add('O7', 0, 0, 281, 281)    -- ignored (no combines)
    r:add('O7', 30, 0, 281, 281, { who = 'Bob', skill = 'Pottery', trivial = 282 })   -- no point: still counts
    local again = Rates.new({ learned = learned })
    eq(again.learned.rates.O7.c, 1030); eq(again.learned.rates.O5.c, 10)
    eq(again.learned.factors['bob|pottery'].c, 1030); eq(again.learned.factors['ann|baking'].c, 10)
    os.remove(learned)
end)

test('in game: Leveling - what each row and the whole path still take; a run teaches the rate', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 6); G:put(1, 2, 'Water Flask', 3)
        G.skills = { Blacksmithing = 16 }; G.skillUps = { ['Metal Bits'] = 'Blacksmithing' }
    end)
    local frames = {}
    F.at(100, function() F.tab = 'Leveling'; F.openCombo = 'Skill##lc_lvl'; F.click('Blacksmithing (Blacksmithing 16)##lc_lvl_Blacksmithing'); F.draw(); F.openCombo = nil; frames.lv = F.draw() end)
    F.at(200, function() F.mq.cmd('/lc make 3 trivial Metal Bits') end)
    F.at(500, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local function has(frame, p) for _, l in ipairs(frame or {}) do if l:find(p, 1, true) then return true end end return false end
    truthy(has(frames.lv, 'rows, to the end ~'), table.concat(frames.lv or {}, '\n'))
    truthy(has(frames.lv, 'colored:next') and has(frames.lv, 'disabled:~'), 'the next row is marked, the others say what they take')
    -- Metal Bits 16 -> 18: the model 2.2 x K 1.07 -> 3, plus a tenth = 4
    local n = (table.concat(frames.lv or {}, '\n')):match('input:##lc_lv_n_Blacksmithing_%d+=(%d+)')
    eq(tonumber(n), 4, 'the row count follows the estimate plus a tenth, not 10')
    local rf = io.open(ROOT .. 'settings/rates.ini'); local text = rf and rf:read('*a') or ''; if rf then rf:close() end
    truthy(text:find('O4454=2,2,16,18', 1, true) and text:find('Glanen|Blacksmithing=2,2', 1, true), 'the run was learned: ' .. text)
    done()
end)

test('in game: make ... trivial - stops when the skill reaches the trivial, and logs the skill', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 6); G:put(1, 2, 'Water Flask', 3)
        G.skills = { Blacksmithing = 16 }; G.skillUps = { ['Metal Bits'] = 'Blacksmithing' }
    end)
    local frame
    F.at(100, function() F.mq.cmd('/lc make 3 trivial Metal Bits') end)
    F.at(300, function() frame = F.draw() end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(table.concat(frame, '\n'):find('Stops at trivial 18', 1, true), 'preflight says so')
    truthy(printed:find('Metal Bits: Blacksmithing 16 (trivial 18)', 1, true), printed)
    truthy(line:find('2/3 ok, made 4, skill 16 -> 18 (trivial reached (Blacksmithing 18, trivial 18))', 1, true), line)
    eq(G:count('Small Piece of Ore'), 2)
    done()
end)

test('in game: make ... repeat - buys and makes the combines again, pass after pass, until the trivial', function()
    local F, G, done = marr(function(G)
        G.skills = { Blacksmithing = 10 }; G.skillUps = { ['Metal Bits'] = 'Blacksmithing' }
    end)
    local frame
    F.at(100, function() F.mq.cmd('/lc make 3 repeat Metal Bits') end)
    F.at(300, function() frame = F.draw() end)
    F.at(400, function() F.click('Go') end)
    F.at(400000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(table.concat(frame, '\n'):find('Repeats until the trivial: later passes sized to the points left', 1, true), 'preflight says so')
    truthy(printed:find('Metal Bits: 5 points left, ~%d+ combines %([%d.]+ x the model, [^)]+%) %- 3 combines this pass'), printed)
    truthy(printed:find('Metal Bits: Blacksmithing 11 after combine 1 (1 combine for that point)', 1, true), 'each point said')
    local _, buys = printed:gsub('Bought 6 Small Piece of Ore', '')
    eq(buys, 3, 'bought for each pass')
    truthy(printed:find('Metal Bits: pass 2 done - 3 combines, Blacksmithing 13 -> 16', 1, true), printed)
    truthy(line:find('3 passes, made 16 Metal Bits, skill 10 -> 18 (trivial reached (Blacksmithing 18, trivial 18))', 1, true), line)
    eq(G:count('Metal Bits'), 16)
    done()
end)

test('in game: make ... repeat - a later pass is sized to the points left, not the row again', function()
    -- 2.41.9 log: 564 combines took 255 -> 281, then pass 2 asked 564 more for the last point
    local F, G, done = marr(function(G)
        G.skills = { Blacksmithing = 10 }; G.skillUps = { ['Metal Bits'] = 'Blacksmithing' }; G.skillUpEvery = 3
    end)
    F.at(100, function() F.mq.cmd('/lc make 18 repeat Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(580000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(printed:find('Metal Bits: pass 1 done - 18 combines, Blacksmithing 10 -> 16', 1, true), printed)
    truthy(printed:find('Metal Bits: 2 points left, ~%d+ combines %([%d.]+ x the model, with your runs%) %- 10 combines this pass'), printed)
    truthy(printed:find('Metal Bits: Blacksmithing 13 after combine 9 (3 combines for that point)', 1, true), 'each point said')
    truthy(line:find('2 passes', 1, true) and line:find('skill 10 -> 18', 1, true), line)
    done()
end)

test('in game: make ... repeat - a skill capped below the trivial stops at the cap (Me.SkillCap)', function()
    local F, G, done = marr(function(G)
        G.skills = { Blacksmithing = 10 }; G.skillCaps = { Blacksmithing = 14 }; G.skillUps = { ['Metal Bits'] = 'Blacksmithing' }
    end)
    local frame
    F.at(100, function() F.mq.cmd('/lc make 3 repeat Metal Bits') end)
    F.at(300, function() frame = F.draw() end)
    F.at(400, function() F.click('Go') end)
    F.at(400000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(table.concat(frame, '\n'):find('Stops at your cap 14 (trivial 18)', 1, true), 'preflight says the cap')
    truthy(line:find('2 passes, made 8 Metal Bits, skill 10 -> 14 (skill cap reached (Blacksmithing 14, cap 14, trivial 18))', 1, true), line)
    done()
end)

-- bags with `free` empty slots (two 40-slot bags, the rest filled with odds and ends)
local function fill_bags(G, free)
    local filled = 80 - free
    for i = 1, math.min(filled, 40) do G:put(1, i, 'Rock ' .. i, 1) end
    for i = 1, filled - 40 do G:put(2, i, 'Pebble ' .. i, 1) end
end

test('stacks: learned beats shipped, one look is saved at once, other characters\' saves are kept', function()
    local Stacks = require('core.stacks')
    local dir = os.tmpname(); os.remove(dir); os.execute('mkdir -p "' .. dir .. '"')
    local shipped, learned = dir .. '/s.ini', dir .. '/l.ini'
    local fh = io.open(shipped, 'w'); fh:write('[Stacks]\nBoot Mold=1\nOdd Thing=1\n'); fh:close()
    local a = Stacks.new({ shipped = shipped, learned = learned })
    eq(a:size('boot mold'), 1); eq(a:size('Water Flask'), nil, 'unknown stays unknown')
    a:learn('Water Flask', 20, 'merchant')
    local b = Stacks.new({ shipped = shipped, learned = learned })
    eq(b:size('water flask'), 20, 'saved at once')
    b:learn('Odd Thing', 100, 'merchant')            -- the game says otherwise: it wins
    a:learn('Malt', 1000, 'merchant')                 -- a saves again without losing b's
    local c = Stacks.new({ shipped = shipped, learned = learned })
    eq(c:size('odd thing'), 100); eq(c:size('malt'), 1000); eq(c:size('water flask'), 20)
    os.execute('rm -rf "' .. dir .. '"')
end)

test('in game: bags - a known non-stacking ingredient: the plan makes what fits and buys only for that', function()
    local F, G, done = marr(function(G)
        fill_bags(G, 12)                              -- 12 free, 3 kept spare: 9 for this run
        G.noStack = { ['small piece of ore'] = true }
    end)
    local fh = io.open(ROOT .. 'settings/stacks.ini', 'w'); fh:write('[Stacks]\nSmall Piece of Ore=1\n'); fh:close()
    local frame
    F.at(100, function() F.mq.cmd('/lc make 10 Metal Bits') end)
    F.at(300, function() frame = F.draw() end)
    F.at(400, function() F.click('Go') end)
    F.at(120000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    -- 2 ore a combine, one slot each, plus a slot of Water Flask: 4 combines = 9 slots
    truthy(table.concat(frame, '\n'):find('Bags: 4 of 10 combines fit', 1, true), 'preflight says what fits')
    truthy(table.concat(frame, '\n'):find('Small Piece of Ore does not stack', 1, true), 'and why')
    truthy(printed:find('Bought 8 Small Piece of Ore', 1, true) and printed:find('Bought 4 Water Flask', 1, true), printed)
    truthy(line:find('bags held 4 of 10 combines; Metal Bits: 4/4 ok, made 8', 1, true), line)
    eq(#G.cursor, 0, 'nothing on the cursor')
    done()
end)

test('in game: bags - a non-stacking item nobody knew: read at the merchant, learned, bought last and cut to fit', function()
    local F, G, done = marr(function(G)
        fill_bags(G, 12)
        G.noStack = { ['small piece of ore'] = true }
    end)
    F.at(100, function() F.mq.cmd('/lc make 10 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(120000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    -- at Borik (sells both): Water Flask first (1 slot), then ore, which does not stack: 12 free - 1 - 3 spare = 8
    truthy(printed:find('Bags: buying 8 of 20 Small Piece of Ore (does not stack', 1, true), printed)
    truthy(printed:find('Bought 10 Water Flask', 1, true), 'the flask still fit')
    truthy(printed:find('out of Small Piece of Ore after 4 combines', 1, true), printed)
    eq(#G.cursor, 0, 'nothing on the cursor')
    local learned = io.open(ROOT .. 'settings/stacks.ini'):read('*a')
    truthy(learned:find('Small Piece of Ore=1', 1, true), 'learned: ' .. learned)
    done()
end)

test('in game: bags - repeat to trivial makes what fits each pass until the trivial', function()
    local F, G, done = marr(function(G)
        fill_bags(G, 12)
        G.noStack = { ['small piece of ore'] = true }
        G.skills = { Blacksmithing = 10 }; G.skillUps = { ['Metal Bits'] = 'Blacksmithing' }
    end)
    local fh = io.open(ROOT .. 'settings/stacks.ini', 'w'); fh:write('[Stacks]\nSmall Piece of Ore=1\n'); fh:close()
    F.at(100, function() F.mq.cmd('/lc make 10 repeat Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(400000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    -- pass 1: 4 fit; its Metal Bits then take a slot, so pass 2 fits 3; pass 3 needs 1 more skill-up
    truthy(printed:find('Bags: 4 of 10 combines fit', 1, true) and printed:find('Bags: 3 of 10 combines fit', 1, true), printed)
    truthy(line:find('3 passes, made 16 Metal Bits, skill 10 -> 18 (trivial reached', 1, true), line)
    done()
end)

test('in game: bags - not even one combine fits: stops before buying anything', function()
    local F, G, done = marr(function(G)
        fill_bags(G, 4)
        G.noStack = { ['small piece of ore'] = true }
    end)
    local fh = io.open(ROOT .. 'settings/stacks.ini', 'w'); fh:write('[Stacks]\nSmall Piece of Ore=1\n'); fh:close()
    F.at(100, function() F.mq.cmd('/lc make 10 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(30000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Bags: not even 1 combine fits', 1, true), printed)
    truthy(not table.concat(G.log, '\n'):find('Merchant.Buy', 1, true), 'nothing bought')
    done()
end)

test('in game: shopping - a merchant who does not sell an item after all hands it to one here who does', function()
    local F, G, done = marr(function(G)
        for _, sp in pairs(G.spawns) do if sp.name == 'Borik Darkanvil' then sp.sells = { 'Small Piece of Ore', 'File Mold' } end end
    end)
    F.at(100, function() F.mq.cmd('/lc make 1 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Water Flask: Borik Darkanvil does not have it on its list - buying it from Klen Ironstove instead', 1, true), printed)
    truthy(printed:find('Water Flask: Borik Darkanvil here does not sell it after all (its list in game) - saved', 1, true), 'learned')
    truthy(printed:find('Bought 1 Water Flask from Klen Ironstove', 1, true), printed)
    eq(G:count('Metal Bits'), 2)
    done()
end)

test('in game: shopping - a planned merchant who is not up is swapped for one here who sells the same', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 2)
        G:spawn('Vori', -2000, 700, -47, { sells = { 'Water Flask' } })   -- far away; Anara (first by name) is not up
    end)
    F.at(100, function() F.mq.cmd('/lc make 1 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local who = printed:match('Bought 1 Water Flask from ([^\n%c]+)')
    truthy(who and who:find('Klen Ironstove', 1, true), 'nearest that is up: ' .. tostring(who))
    eq(G:count('Metal Bits'), 2)
    done()
end)

test('in game: trophies - the best one in the bags is worn for the skill, and the Ammo slot goes back after', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 2); G:put(1, 2, 'Water Flask', 1)
        G:put(1, 3, 'Smithy Hammer', 1); G:put(1, 4, 'Hammer of the Ironfrost', 1)
        G.worn = { ammo = { id = 7001, name = 'Arrow', stack = 1 } }
    end)
    local frame, wornMid
    F.at(100, function() F.mq.cmd('/lc make 1 Metal Bits') end)
    F.at(300, function() frame = F.draw() end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(table.concat(frame, '\n'):find('Wear for Blacksmithing: Hammer of the Ironfrost (in the bags)', 1, true), 'plan says what is worn')
    truthy(printed:find('Wearing Hammer of the Ironfrost for Blacksmithing', 1, true), printed)
    truthy(printed:find('Ammo slot back as it was (Arrow)', 1, true), printed)
    eq(G.worn.ammo.name, 'Arrow'); eq(G:count('Hammer of the Ironfrost'), 1, 'back in the bags')
    eq(G:count('Metal Bits'), 2)
    done()
end)

test('in game: trophies - none owned is said and the run carries on; one in the bank comes on the bank trip', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 2); G:put(1, 2, 'Water Flask', 1)
    end)
    local frame
    F.at(100, function() F.mq.cmd('/lc make 1 Metal Bits') end)
    F.at(300, function() frame = F.draw() end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    truthy(table.concat(frame, '\n'):find('Wear for Blacksmithing: none of yours', 1, true), 'none said')
    eq(G:count('Metal Bits'), 2, 'made anyway')
    done()

    F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 2); G:put(1, 2, 'Water Flask', 1)
        G:bankbag(1, 'Bank Bag', 8); G:bankput(1, 1, "Blacksmith's Adamantine Hammer", 1)
    end)
    F.at(100, function() F.mq.cmd('/lc make 1 Metal Bits') end)
    F.at(300, function() frame = F.draw() end)
    F.at(400, function() F.click('Go') end)
    F.at(90000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(table.concat(frame, '\n'):find("Wear for Blacksmithing: Blacksmith's Adamantine Hammer (in the bank - taken on the bank trip)", 1, true), 'bank said')
    truthy(printed:find("Bank: took 1 Blacksmith's Adamantine Hammer", 1, true), printed)
    truthy(printed:find("Wearing Blacksmith's Adamantine Hammer for Blacksmithing", 1, true), printed)
    eq(G.worn.ammo, nil, 'the slot was empty before, and is again')
    eq(G:count("Blacksmith's Adamantine Hammer"), 1)
    done()
end)

test('in game: /lc banktrophies - every trophy and aid in the bags into the bank, nothing else', function()
    local F, G, done = marr(function(G)
        G:bankbag(1, 'Bank Bag', 8)
        G:put(1, 1, "Brewmaster's Mug", 1); G:put(1, 2, 'Geerlok Gem Setter', 1); G:put(1, 3, 'Water Flask', 5)
    end)
    F.at(100, function() F.mq.cmd('/lc banktrophies') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find("Banked 1 Brewmaster's Mug", 1, true) and printed:find('Banked 1 Geerlok Gem Setter', 1, true), printed)
    eq(G:count("Brewmaster's Mug"), 0); eq(G:bankcount("Brewmaster's Mug"), 1); eq(G:count('Water Flask'), 5)
    done()
end)

test('in game: /lc bankgear - trophies, return tools and empty kits inside bags; a pack-slot kit and a full one stay', function()
    local F, G, done = marr(function(G)
        G:bankbag(1, 'Bank Bag', 20)
        G:put(1, 1, "Brewmaster's Mug", 1); G:put(1, 2, 'File', 1); G:put(1, 3, 'Smithy Hammer', 1); G:put(1, 4, 'Empty Vial', 3)
        G:put(1, 5, 'Water Flask', 5)
        G:kit_in(1, 6, 'Mixing Bowl', 10)
        G:kit_in(2, 1, 'Jeweler\'s Kit', 10); G.packs[2].items[1].items[1] = { name = 'Silver Bar', stack = 1, id = 1 }
        G:kit(3, 'Toolbox', 10)
    end)
    F.at(100, function() F.mq.cmd('/lc bankgear') end)
    F.at(400, function() F.click('Go') end)
    F.at(90000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    eq(G:bankcount("Brewmaster's Mug"), 1, 'trophy'); eq(G:bankcount('File'), 1, 'file'); eq(G:bankcount('Smithy Hammer'), 1, 'hammer')
    local inBag = false
    for _, it in pairs(G.bank[1].items) do if it.name == 'Mixing Bowl' then inBag = true end end
    truthy(inBag, 'the empty kit went into a slot inside the bank bag')
    eq(G:count('Empty Vial'), 3, 'an ingredient more than a tool stays'); eq(G:count('Water Flask'), 5)
    eq(G:bankcount("Jeweler's Kit"), 0, 'a kit with something in it stays')
    truthy(G.packs[3] and G.packs[3].name == 'Toolbox', 'the kit in a pack slot stays')
    truthy(printed:find("Left in the bags: Jeweler's Kit (1 with something in it)", 1, true), printed)
    done()
end)

test('in game: /lc bankgear - bank bags too small for the kit: it goes into an empty top-level bank slot', function()
    local F, G, done = marr(function(G)
        G:bankbag(1, 'Bank Bag', 4); G.bank[1].sizeCap = 1
        G:kit_in(1, 6, 'Mixing Bowl', 10)
    end)
    F.at(100, function() F.mq.cmd('/lc bankgear') end)
    F.at(400, function() F.click('Go') end)
    F.at(90000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    eq(G.bank[2] and G.bank[2].name, 'Mixing Bowl', 'top-level slot 2'); eq(next(G.bank[1].items), nil, 'nothing in the small bag')
    eq(#G.cursor, 0)
    done()
end)

test('in game: /lc bankgear - no empty bank slot: the kit stays in the bags, nothing is swapped out of the bank', function()
    local F, G, done = marr(function(G)
        for b = 1, 24 do G:bankbag(b, 'Bank Bag', 4); G.bank[b].sizeCap = 1 end   -- bags too small for a kit, no slot free
        G:put(1, 2, 'File', 1); G:kit_in(1, 6, 'Mixing Bowl', 10)
    end)
    F.at(100, function() F.mq.cmd('/lc bankgear') end)
    F.at(400, function() F.click('Go') end)
    F.at(90000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    eq(G:bankcount('File'), 1, 'the tool still banked')
    eq(G.packs[1].items[6] and G.packs[1].items[6].name, 'Mixing Bowl', 'the kit never left its bag slot')
    for b = 1, 24 do eq(G.bank[b].name, 'Bank Bag', 'bank slot ' .. b .. ' untouched') end
    truthy(printed:find('No empty bank slot - left in the bags: Mixing Bowl', 1, true), printed)
    eq(#G.cursor, 0)
    done()
end)

test('in game: /lc bankgear with a queue still to run does nothing', function()
    local F, G, done = marr(function(G)
        G:bankbag(1, 'Bank Bag', 20); G:put(1, 2, 'File', 1)
        local qf = io.open(ROOT .. 'settings/LazCraft_Glanen_queue.ini', 'w')
        qf:write('[Queue]\nEntry=craft|O4454|2|keep\n'); qf:close()
    end)
    F.at(300, function() F.mq.cmd('/lc bankgear') end)
    F.at(600, function() F.click('Go') end)
    F.at(20000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    eq(G:bankcount('File'), 0, 'nothing banked')
    truthy(table.concat(F.printed, '\n'):find('The queue still has 1 entry', 1, true), 'said why')
    os.remove(ROOT .. 'settings/LazCraft_Glanen_queue.ini')
    done()
end)

test('in game: money - the plan says what it costs against the coin carried, and blocks when it is short', function()
    local F, G, done = marr(function(G) G.coin = { pp = 0, gp = 1, sp = 0, cp = 0 } end)
    F.at(100, function() F.mq.cmd('/lc make 10 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(20000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Money: about 5gp 6sp to spend, you carry 1gp - not enough', 1, true), printed)
    truthy(not table.concat(G.log, '\n'):find('Merchant.Buy', 1, true), 'nothing bought')
    done()
end)

test('in game: /lc level - the path row after row under one Go; a row that cannot finish is said and passed', function()
    local F, G, done = marr(function(G)
        G.skills = { Blacksmithing = 16 }; G.skillUps = { ['Metal Bits'] = 'Blacksmithing' }
        G:put(1, 10, 'Banded Boots', 3)   -- left from an earlier run: row 3 does not reach its trivial, so they stay (2.43.1)
    end)
    local frame
    F.at(100, function() F.mq.cmd('/lc level blacksmithing') end)
    F.at(300, function() frame = F.draw() end)
    F.at(400, function() F.click('Go') end)
    F.at(400000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done: Level Blacksmithing[^\n]*') or printed
    truthy(table.concat(frame, '\n'):find('1. Metal Bits [O4454]: 10 combines a pass, destroy, until the trivial 18', 1, true), 'preflight lists the rows')
    truthy(printed:find('Path 1 of 12: Metal Bits', 1, true), printed)
    truthy(printed:find('Path 2 of 12: Sheet Metal', 1, true), 'went on to row 2')
    truthy(printed:find('Path 1 of 12: Metal Bits: 1 pass, made 4 Metal Bits, skill 16 -> 18 (trivial reached', 1, true), printed)
    truthy(line:find('12 rows, 1 finished, 11 did not - each row is in the log above', 1, true), line)
    truthy(printed:find('row 5: not enough for', 1, true) and printed:find('Tungsten Ore', 1, true), 'preflight says which rows cannot be made')
    truthy(printed:find('Clean-up after Banded Boots: skipped - the row did not finish', 1, true), printed)
    eq(G:count('Banded Boots'), 3, 'a row short of its trivial keeps its items')
    done()
end)

test('in game: a /combine the game never took is sent again (the container unchanged), never twice when it did', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2)
        G.combineIgnores = 1
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local combines = 0; for _, c in ipairs(G.log) do if c == '/combine enviro' then combines = combines + 1 end end
    eq(combines, 3, 'the lost one, its resend, then the second combine')
    eq(G:count('Metal Bits'), 4, 'two combines made, not three')
    done()
end)

test('in game: a combine whose message comes late (the container already empty) is waited for, never sent again', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2)
        G.lateMessageMs = 2000   -- 2.42.15 Lopan log: product on the cursor at 1.7s, the message after
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local combines = 0; for _, c in ipairs(G.log) do if c == '/combine enviro' then combines = combines + 1 end end
    eq(combines, 2, 'one each, the late one not sent again')
    eq(G:count('Metal Bits'), 4, 'both made')
    local printed = table.concat(F.printed, '\n')
    truthy(not printed:find('no combine message', 1, true), printed)
    done()
end)

test('in game: a combine whose message never comes, the container empty and the product on the cursor, is a success', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2)
        G.lostMessages = 1   -- 2.46.3 logs: a client stall lost the line; every such row was failed "no answer"
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local combines = 0; for _, c in ipairs(G.log) do if c == '/combine enviro' then combines = combines + 1 end end
    eq(combines, 2, 'one each, the silent one not sent again')
    eq(G:count('Metal Bits'), 4, 'both made')
    local printed = table.concat(F.printed, '\n')
    truthy(not printed:find('no combine message', 1, true), printed)
    truthy(printed:find('counted a success', 1, true), printed)
    done()
end)

test('a stow the client ignores for over 2s right after a combine keeps trying, and lands', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10)
    e.G.cursor = { { id = 5002, name = 'Bottle', stack = 2 } }
    e.G.autoinvIgnores = 5   -- 5 sends 500ms apart: 2.5s ignored, the 6th takes
    local t0 = e.F.now
    local r = e.run(function(ctx) return e.cur:stow(ctx) end)
    truthy(r.ok, R.describe(r))
    eq(e.G:count('Bottle'), 2)
    truthy(e.F.now - t0 < 3500, 'took ' .. (e.F.now - t0) .. 'ms')
end)

test('in game: make ... trivial when the skill is already past it - blocked at the preflight, nothing bought or walked', function()
    local F, G, done = marr(function(G)
        G:put(1, 2, 'Water Flask', 1)
        G.skills = { Blacksmithing = 300 }
    end)
    local frame
    F.at(100, function() F.mq.cmd('/lc make 3 trivial Metal Bits') end)
    F.at(300, function() frame = F.draw() end)
    F.at(400, function() F.click('Go') end)
    F.at(20000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('failed: preflight (Your Blacksmithing is 300 - already at Metal Bits\'s trivial 18, nothing to make)', 1, true), printed)
    local log = table.concat(G.log, '\n')
    truthy(not log:find('Merchant.Buy', 1, true) and not log:find('/nav', 1, true), 'nothing bought, nowhere walked')
    done()
end)

test('in game: a run that fills the bags stops with the reason (keep)', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2)
        for i = 3, 40 do G:put(1, i, 'Rock ' .. i, 1) end
        for i = 1, 37 do G:put(2, i, 'Pebble ' .. i, 1) end   -- 3 free, then the first combine's Metal Bits takes one
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('bags full (2 free slots) after 1 combine', 1, true), printed)
    eq(G:count('Metal Bits'), 2)
    done()
end)

test('in game: make ... sell - when the bags fill mid-run it sells what it made so far, then carries on', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2)
        for i = 3, 40 do G:put(1, i, 'Rock ' .. i, 1) end
        for i = 1, 37 do G:put(2, i, 'Pebble ' .. i, 1) end
    end)
    F.at(100, function() F.mq.cmd('/lc make 2 sell Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(120000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(printed:find('Bags down to 2 free - selling the 2 Metal Bits made so far', 1, true), printed)
    truthy(line:find('Metal Bits: 2/2 ok, made 4, sold 4', 1, true), line)
    eq(G:count('Metal Bits'), 0)
    done()
end)

test('in game: make ... sell - a product the client put on an empty worn slot stays there; the bags are sold, the row goes on (2.43.8)', function()
    local F, G, done = marr(function(G)
        G:put(1, 1, 'Small Piece of Ore', 6); G:put(1, 2, 'Water Flask', 3)
        for i = 3, 40 do G:put(1, i, 'Rock ' .. i, 1) end
        for i = 1, 37 do G:put(2, i, 'Pebble ' .. i, 1) end
        G.wearable = { ['metal bits'] = 'face' }
    end)
    F.at(100, function() F.mq.cmd('/lc make 3 sell Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(120000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(printed:find('went into a worn slot when stowed and stays there; selling the 2 in the bags', 1, true), printed)
    truthy(not printed:find('none left', 1, true), 'never short at the merchant')
    truthy(line:find('Metal Bits: 3/3 ok, made 6, sold 4', 1, true), line)
    eq(G:count('Metal Bits'), 0); eq(G.worn.face and G.worn.face.stack, 2, 'the worn ones stay worn')
    done()
end)

-- ---- travel ----------------------------------------------------------------------------------------
-- The hubs as travel.ini describes them: Klonopin in Marr, Valium and a stone in PoK, Marr's Calling.
local function hubs(G)
    G:spawn('Klonopin', 680, 20, -47, { ports = { poknowledge = 'poknowledge', abysmal = 'abysmal' } })
    G:spawn('Soulbinder Tomas', 100, 100, -47)
    G.arriveAt.freeporttemple = { 0, 0, -47 }
    G.aa["marr's calling"] = { to = 'freeporttemple', castMs = 3000, ready = true }
    G.zoneDefs.poknowledge = function(g)
        g:spawn('Valium', 10, 10, -150, { ports = { abysmal = 'abysmal' } })
        g:door('POKTNPORT500', 449.98, -74.21, -152.87, 'nexus')
    end
    G.arriveAt.poknowledge = { 0, 0, -150 }
    G.zoneDefs.abysmal = function(g) g:spawn('Jorlan Hegeway', 30, 30, 0, { sells = { 'Bat Fur' } }) end
end
-- Start the test somewhere other than Marr (Marr's spawns are kept for when we zone back).
local function start_in(G, zone)
    G.saved.freeporttemple = { spawns = G.spawns, grounds = G.grounds, doors = G.doors }
    G.spawns, G.grounds, G.doors = {}, {}, {}
    G.zone = zone
    if G.zoneDefs[zone] then G.zoneDefs[zone](G) end
    G.me = { x = 0, y = 0, z = 0 }
end
-- PoK's two forges (containers.ini At1, At2), standing by the first; Metal Bits makings in the bags
local function pok_forges(G, one, two)
    G.zone = 'poknowledge'
    G.me = { x = 750, y = -340, z = -91 }
    G:ground('Forge', -342.89, 755.66, -91.33, one)
    G:ground('Forge', -397.91, 434.47, -124.87, two)
    G:put(1, 1, 'Small Piece of Ore', 2); G:put(1, 2, 'Water Flask', 1)
end

test('in game: stations - the nearest one in use: the next one on the list', function()
    local F, G, done = marr(function(G) pok_forges(G, { inUse = true }, nil) end)
    F.at(100, function() F.mq.cmd('/lc make 1 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(90000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('clicking once more', 1, true), 'clicked the busy one twice')
    truthy(printed:find('Forge at -343, 756 is in use - trying the next one', 1, true), printed)
    eq(G:count('Metal Bits'), 2, 'made at the other forge')
    done()
end)

test('in game: stations - "in use" with nobody there clears on one more click', function()
    local F, G, done = marr(function(G) pok_forges(G, { inUseOnce = true }, nil) end)
    F.at(100, function() F.mq.cmd('/lc make 1 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('clicking once more', 1, true), printed)
    truthy(not printed:find('trying the next one', 1, true), 'stayed at the first forge')
    eq(G:count('Metal Bits'), 2)
    done()
end)

test('in game: stations - every one here busy: this zone\'s AFK mirror next, and the combine is made there', function()
    local F, G, done = marr(function(G)
        pok_forges(G, { inUse = true }, { inUse = true })
        G:spawn('Lazy Lady Linda', -300, 700, -91, { ports = { enter = 'poknowledge#afk' } })
        G.zoneDefs['poknowledge#afk'] = function(g)
            g:ground('Forge', -342.89, 755.66, -91.33); g:ground('Forge', -397.91, 434.47, -124.87)
        end
        G.arriveAt['poknowledge#afk'] = { 700, -300, -91 }
    end)
    F.at(100, function() F.mq.cmd('/lc make 1 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(150000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(not printed:find('trying them again', 1, true), 'no waiting on a busy station')
    truthy(printed:find('Every Forge in poknowledge is busy - trying poknowledge (AFK mirror)', 1, true), printed)
    truthy(printed:find('Travel: in the AFK mirror of poknowledge', 1, true), printed)
    eq(G.zoneKey, 'poknowledge#afk')
    eq(G:count('Metal Bits'), 2, 'made in the mirror')
    done()
end)

test('in game: stations - busy here and in the mirror: the next zone with the station', function()
    local F, G, done = marr(function(G)
        hubs(G)
        local marrForge
        for _, gr in ipairs(G.grounds) do if gr.name == 'Forge' then marrForge = gr end end
        G.saved.freeporttemple = { spawns = G.spawns, grounds = G.grounds, doors = G.doors }
        G.spawns, G.grounds, G.doors = {}, {}, {}
        pok_forges(G, { inUse = true }, { inUse = true })   -- PoK, no Lazy Lady Linda here: no mirror to get into
    end)
    F.at(100, function() F.mq.cmd('/lc make 1 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(200000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Could not get to poknowledge (AFK mirror)', 1, true), printed)
    truthy(printed:find('trying freeporttemple', 1, true), printed)
    eq(G.zone, 'freeporttemple')
    eq(G:count('Metal Bits'), 2, 'made at the Marr forge')
    done()
end)

local function travel_run(setup, cmd, quitAt)
    local F, G, done = marr(function(G) hubs(G); if setup then setup(G) end end)
    F.at(100, function() F.mq.cmd(cmd) end)
    F.at(400, function() F.click('Go') end)
    F.at(quitAt or 120000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    return printed, printed:match('[^\n]*Done[^\n]*') or printed, G, done
end

test('travel: a porter - nav, target, say; said again when the first say does nothing', function()
    local printed, line, G, done = travel_run(function(G) G.sayIgnores = 1 end, '/lc travel poknowledge')
    truthy(printed:find('Klonopin did not port us after "Poknowledge" (try 1', 1, true), printed)
    truthy(line:find('in poknowledge, 1 hop', 1, true), line)
    eq(G.zone, 'poknowledge'); eq(G.gameState, 'INGAME')
    done()
end)

test('travel: the porter is targeted before the nav, so the first say is heard (a say right after /target is ignored)', function()
    local printed, line, G, done = travel_run(function(G) G.targetSettleMs = 500 end, '/lc travel poknowledge')
    truthy(not printed:find('did not port us', 1, true), printed)
    truthy(line:find('in poknowledge, 1 hop', 1, true), line)
    local says = 0; for _, c in ipairs(G.log) do if c == '/say Poknowledge' then says = says + 1 end end
    eq(says, 1, 'one say')
    done()
end)

test('travel: an AA fired standing still, fired again only after an interruption; then the arrival spot', function()
    local printed, line, G, done = travel_run(function(G) start_in(G, 'poknowledge'); G.interruptNext = 1 end, '/lc travel freeporttemple')
    truthy(printed:find("Marr's Calling was interrupted (try 1)", 1, true), printed)
    truthy(line:find('in freeporttemple, 1 hop', 1, true), line)
    eq(G.zone, 'freeporttemple')
    local tomas; for _, sp in pairs(G.spawns) do if sp.name == 'Soulbinder Tomas' then tomas = sp end end
    truthy(G:dist(tomas) <= 18, 'went to Soulbinder Tomas first: ' .. G:dist(tomas))
    local fires = 0; for _, c in ipairs(G.log) do if c == "/aa act Marr's Calling" then fires = fires + 1 end end
    eq(fires, 2, 'fired once, and once more after the interruption')
    done()
end)

test('travel: an AA on cooldown is waited for, then fired once', function()
    local printed, line, G, done = travel_run(function(G)
        start_in(G, 'poknowledge'); G.aa["marr's calling"].ready = false
        G.F.at(8000, function() G.aa["marr's calling"].ready = true end)
    end, '/lc travel freeporttemple')
    truthy(printed:find("waiting for Marr's Calling to be ready", 1, true), printed)
    truthy(line:find('in freeporttemple', 1, true), line)
    done()
end)

test('travel: a door - nav near it, /doortarget, click', function()
    local printed, line, G, done = travel_run(function(G) start_in(G, 'poknowledge'); G.doorIgnores = 1 end, '/lc travel nexus')
    truthy(printed:find('clicking POKTNPORT500 did nothing (try 1', 1, true), printed)
    truthy(line:find('in nexus, 1 hop', 1, true), line)
    eq(G.zone, 'nexus')
    done()
end)

test('travel: two hops (AA to Marr, then the porter); the navmesh is loaded before moving on', function()
    local printed, line, G, done = travel_run(function(G) start_in(G, 'abysmal') end, '/lc travel poknowledge')
    truthy(printed:find('Travel: abysmal -> freeporttemple -> poknowledge', 1, true), printed)
    truthy(line:find('in poknowledge, 2 hops', 1, true), line)
    eq(G.zone, 'poknowledge')
    done()
end)

test('travel: no porter, the wrong zone, or no route each stop with the reason', function()
    local printed, _, G, done = travel_run(function(G)
        for id, sp in pairs(G.spawns) do if sp.name == 'Klonopin' then G.spawns[id] = nil end end
    end, '/lc travel abysmal')
    truthy(printed:find('Klonopin is not in freeporttemple', 1, true), printed)
    eq(G.zone or 'freeporttemple', 'freeporttemple')
    done()
    printed, _, G, done = travel_run(function(G) G.landIn = 'nexus' end, '/lc travel poknowledge')
    truthy(printed:find('landed in nexus, not poknowledge', 1, true), printed)
    done()
    printed, _, G, done = travel_run(nil, '/lc travel nowhere')
    truthy(printed:find('no way from freeporttemple to nowhere', 1, true), printed)
    done()
end)

test('in game: a make whose route leaves the zone - buy here, travel, buy there, craft in the kits there', function()
    local printed, line, G, done = travel_run(function(G)
        G:kit(9, 'Sewing Kit', 10); G:kit(10, 'Tackle Box', 10)
        G:spawn('A Shady Merchant', 640, 10, -47, { sells = { 'Spiderling Silk' } })
        G:spawn('Engineer Beri', 660, 10, -47, { sells = { 'Dry Hook' } })
        G.recipes['Silk Thread'] = { 'Spiderling Silk', 'Spiderling Silk' }
        G.recipes['Night Swooper Dry Fly'] = { 'Bat Fur', 'Silk Thread', 'Dry Hook' }
    end, '/lc make 1 Night Swooper Dry Fly', 200000)
    truthy(printed:find('Bought 2 Spiderling Silk from A Shady Merchant', 1, true), printed)
    truthy(printed:find('Bought 1 Bat Fur from Jorlan Hegeway', 1, true), printed)
    truthy(line:find('Silk Thread: 1/1 ok, made 1; Night Swooper Dry Fly: 1/1 ok, made 1', 1, true), line)
    eq(G.zone, 'abysmal'); eq(G:count('Night Swooper Dry Fly'), 1); eq(#G.cursor, 0)
    done()
end)

test('in game: just after zoning in, the merchant is waited for (the zone\'s spawns arrive a moment later)', function()
    local printed, line, G, done = travel_run(function(G)
        G:kit(9, 'Sewing Kit', 10); G:kit(10, 'Tackle Box', 10)
        G:spawn('A Shady Merchant', 640, 10, -47, { sells = { 'Spiderling Silk' } })
        G:spawn('Engineer Beri', 660, 10, -47, { sells = { 'Dry Hook' } })
        G.recipes['Silk Thread'] = { 'Spiderling Silk', 'Spiderling Silk' }
        G.recipes['Night Swooper Dry Fly'] = { 'Bat Fur', 'Silk Thread', 'Dry Hook' }
        G.spawnsLateMs = 1500
    end, '/lc make 1 Night Swooper Dry Fly', 200000)
    truthy(not printed:find('is not in this zone', 1, true), printed)
    truthy(printed:find('Bought 1 Bat Fur from Jorlan Hegeway', 1, true), printed)
    eq(G:count('Night Swooper Dry Fly'), 1)
    done()
end)

test('travel: Northern Felwithe - the Kelethin stone (a door with no Near: its own spot), then the Greater Faydark zone line', function()
    local printed, line, G, done = travel_run(function(G)
        local pok = G.zoneDefs.poknowledge
        G.zoneDefs.poknowledge = function(g) pok(g); g:door('POKKELPORT500', 100, 200, -150, 'gfaydark') end
        G:zone_line('gfaydark', -2590.65 - 25, -1935.80, 15, 'felwithea')
    end, '/lc travel felwithea', 200000)
    truthy(printed:find('freeporttemple -> poknowledge -> gfaydark -> felwithea', 1, true), printed)
    truthy(printed:find('Travel: in felwithea after 3 hops', 1, true), printed)
    eq(G.zone, 'felwithea'); eq(G.running, false, 'forward let go')
    done()
end)

test('travel: a run that never meets its zone line fails with why, and forward is let go', function()
    local printed, line, G, done = travel_run(function(G)
        local pok = G.zoneDefs.poknowledge
        G.zoneDefs.poknowledge = function(g) pok(g); g:door('POKKELPORT500', 100, 200, -150, 'gfaydark') end
    end, '/lc travel felwithea', 200000)
    truthy(printed:find('never left gfaydark', 1, true), printed)
    eq(G.zone, 'gfaydark'); eq(G.running, false)
    done()
end)

-- Faction (2.42.0): Velium Bar is sold only by Talem Tucter in Thurgadin (merchants.ini)
local function faction_env(standing, opts)
    opts = opts or {}
    local e = block_env()
    e.G:bag(1, 'Backpack', 10)
    e.G.coin = { pp = 1000, gp = 0, sp = 0, cp = 0 }
    e.G.zoneDefs.thurgadina = function(g) g:spawn('Talem Tucter', 10, 10, 0, { sells = { 'Velium Bar' }, standing = standing }) end
    local zones = {}
    local travel = {
        zone = function() return e.G.zone or 'freeporttemple' end,
        go = function(_, ctx, to)
            zones[#zones + 1] = to
            e.G:start_zone(to)
            local w = ctx:wait(60000, function() return e.G.gameState == 'INGAME' and e.G.zone == to and e.G.meshLoaded end)
            if not w.ok and w.why ~= 'timeout' then return w end
            return w.ok and R.ok({ hops = 1 }) or R.fail('zone', 'did not zone')
        end,
    }
    package.loaded['blocks.faction'] = nil; package.loaded['core.factions'] = nil
    local Factions = require('core.factions')
    local factions = Factions.new({})
    if opts.saved then factions:set('Antilerd', 'Talem Tucter', 'thurgadina', opts.saved) end
    local cfg = Config.load(ROOT .. 'data/')
    local blocks = { inventory = e.inv, windows = e.win, cursor = e.cur, spawns = e.spawns, nav = e.nav, merchant = e.merchant,
        bank = e.bank, kit = e.kit, station = e.station, travel = travel,
        faction = require('blocks.faction').new({ mq = e.F.mq, spawns = e.spawns, log = e.log }),
        kitslot = { restore = function() return R.ok() end } }
    local env = { blocks = blocks, planner = Planner.new(cfg), cfg = cfg, log = e.log, mq = e.F.mq, describe = Planner.describe,
        factions = factions, me = 'Antilerd',
        world = function()
            return { zone = e.G.zone or 'freeporttemple', bags = function(i) return e.inv:count(i) end, bank = function() return 0 end,
                     canCast = function() return false end, kit = function() return false end,
                     barred = function(npc, zone) return factions:barred('Antilerd', npc, zone) end }
        end }
    return e, env, factions, zones
end

test('faction: a merchant too low to buy from - conned, saved, Marr\'s Calling out, the run fails naming it', function()
    local e, env, factions, zones = faction_env('dubiously')
    e.runner:add(require('engine.make').get_job(env, 'Velium Bar', 2)); e.runner:step()
    local r = e.runner.last
    eq(r.ok, false); eq(r.why, 'cannot get it', 'planned again: no merchant left, no worker to send')
    truthy(tostring(r.detail):find('sold only by merchants your faction is too low with: Talem Tucter (thurgadina) dubiously', 1, true), tostring(r.detail))
    truthy(e.log.has('regards us dubiously %- too low to buy'), 'the con said')
    eq(factions:barred('Antilerd', 'Talem Tucter', 'thurgadina'), 'dubiously', 'saved')
    eq(table.concat(zones, ','), 'thurgadina,freeporttemple', 'Marr\'s straight out')
    eq(e.G:count('Velium Bar'), 0); eq(e.G.conned, 1)
    truthy(e.log.has('Could not buy in thurgadina %- Marr\'s Calling out'), 'said')
end)

test('faction: apprehensively buys - conned, bought, saved, then Marr\'s Calling out of the zone', function()
    local e, env, factions, zones = faction_env('apprehensively')
    e.runner:add(require('engine.make').get_job(env, 'Velium Bar', 2)); e.runner:step()
    truthy(e.runner.last.ok, R.describe(e.runner.last))
    eq(e.G:count('Velium Bar'), 2)
    eq(factions:get('Antilerd', 'Talem Tucter', 'thurgadina'), 'apprehensively')
    eq(table.concat(zones, ','), 'thurgadina,freeporttemple')
    truthy(e.log.has('Faction: Talem Tucter regards us apprehensively$'), 'logged')
    truthy(e.log.has('Bought in thurgadina %- Marr\'s Calling out'), 'said')
end)

test('faction: a con that brings no line is sent again; a merchant saved as too low is never planned', function()
    local e, env = faction_env('kindly')
    e.G.conIgnores = 1
    e.runner:add(require('engine.make').get_job(env, 'Velium Bar', 1)); e.runner:step()
    truthy(e.runner.last.ok, R.describe(e.runner.last)); eq(e.G.conned, 1, 'the second /consider answered')
    local e2, env2, _, zones2 = faction_env('kindly', { saved = 'threateningly' })
    local plan = env2.planner:plan_item('Velium Bar', 1, env2.world())
    local text = table.concat(plan.problems, '\n')
    truthy(text:find('Velium Bar: short 1 - sold only by merchants your faction is too low with: Talem Tucter (thurgadina) threateningly', 1, true), text)
    e2.runner:add(require('engine.make').get_job(env2, 'Velium Bar', 1)); e2.runner:step()
    eq(e2.runner.last.ok, false); eq(#zones2, 0, 'nowhere went')
end)

test('unsold: a merchant whose list lacks what the data says is learned, and the pass is planned again elsewhere', function()
    -- 2.42.2 log: Borik Darkanvil in Marr (36 items) has no Jar of Lacquer; the data says he does
    local e = block_env()
    e.G:bag(1, 'Backpack', 10)
    e.G.coin = { pp = 1000, gp = 0, sp = 0, cp = 0 }
    e.G:spawn('Borik Darkanvil', 10, 10, 0, { sells = { 'Water Flask' } })
    e.G.zoneDefs.poknowledge = function(g)
        for _, n in ipairs({ 'Kanio Paerk', 'Blacksmith Gerta', 'Yeril Imsin', 'Boiron Ston', 'Borik Darkanvil' }) do
            g:spawn(n, 10, 10, 0, { sells = { 'Jar of Lacquer' } })
        end
    end
    e.G.zoneDefs.abysmal = function(g)
        for _, n in ipairs({ 'Jorlan Hegeway', 'Lita Hegeway', 'Viliani I`Xvoyt', 'Uiyaniv Tu`Vrozix' }) do
            g:spawn(n, 10, 10, 0, { sells = { 'Jar of Lacquer' } })
        end
    end
    local zones = {}
    local travel = {
        zone = function() return e.G.zone or 'freeporttemple' end,
        go = function(_, ctx, to)
            zones[#zones + 1] = to
            e.G:start_zone(to)
            local w = ctx:wait(60000, function() return e.G.gameState == 'INGAME' and e.G.zone == to and e.G.meshLoaded end)
            if not w.ok and w.why ~= 'timeout' then return w end
            return w.ok and R.ok({ hops = 1 }) or R.fail('zone', 'did not zone')
        end,
    }
    local cfg = Config.load(ROOT .. 'data/')
    package.loaded['core.unsold'] = nil
    local path = TESTS_DIR .. 'tmp_unsold.ini'; os.remove(path)
    local unsold = require('core.unsold').new({ path = path, merchants = cfg.merchants })
    local blocks = { inventory = e.inv, windows = e.win, cursor = e.cur, spawns = e.spawns, nav = e.nav, merchant = e.merchant,
        bank = e.bank, kit = e.kit, station = e.station, travel = travel, kitslot = { restore = function() return R.ok() end } }
    local env = { blocks = blocks, planner = Planner.new(cfg), cfg = cfg, log = e.log, mq = e.F.mq, describe = Planner.describe,
        unsold = unsold, me = 'Antilerd',
        world = function()
            return { zone = e.G.zone or 'freeporttemple', bags = function(i) return e.inv:count(i) end, bank = function() return 0 end,
                     canCast = function() return false end, kit = function() return false end }
        end }
    e.runner:add(require('engine.make').get_job(env, 'Jar of Lacquer', 2)); e.runner:step()
    truthy(e.runner.last.ok, R.describe(e.runner.last))
    eq(e.G:count('Jar of Lacquer'), 2); eq(#zones, 1); truthy(zones[1] ~= 'freeporttemple', 'bought in another zone')
    truthy(e.log.has('Jar of Lacquer: Borik Darkanvil here does not sell it after all'), 'said')
    truthy(e.log.has('planning again without that merchant'), 'replanned')
    for _, v in ipairs(cfg.merchants['jar of lacquer'] or {}) do
        truthy(not (v.npc == 'Borik Darkanvil' and v.zone == 'freeporttemple'), 'taken out of the list')
    end
    local again = require('core.unsold').new({ path = path, merchants = Config.load(ROOT .. 'data/').merchants })
    truthy(again.known['borik darkanvil##freeporttemple'].items['jar of lacquer'], 'saved')
    os.remove(path)
end)

test('unsold: a list that is not all there when it says complete is opened again - bought here, nothing saved (2.43.7)', function()
    -- 2.42.2 log: Borik Darkanvil in Marr (36 items) has no Jar of Lacquer; the data says he does
    local e = block_env()
    e.G:bag(1, 'Backpack', 10)
    e.G.coin = { pp = 1000, gp = 0, sp = 0, cp = 0 }
    e.G:spawn('Borik Darkanvil', 10, 10, 0, { sells = { 'Water Flask', 'Jar of Lacquer' } })
    e.G.partialListMs = 6000   -- past the 5s wait on the first open; the second open is whole
    e.G.zoneDefs.poknowledge = function(g)
        for _, n in ipairs({ 'Kanio Paerk', 'Blacksmith Gerta', 'Yeril Imsin', 'Boiron Ston', 'Borik Darkanvil' }) do
            g:spawn(n, 10, 10, 0, { sells = { 'Jar of Lacquer' } })
        end
    end
    e.G.zoneDefs.abysmal = function(g)
        for _, n in ipairs({ 'Jorlan Hegeway', 'Lita Hegeway', 'Viliani I`Xvoyt', 'Uiyaniv Tu`Vrozix' }) do
            g:spawn(n, 10, 10, 0, { sells = { 'Jar of Lacquer' } })
        end
    end
    local zones = {}
    local travel = {
        zone = function() return e.G.zone or 'freeporttemple' end,
        go = function(_, ctx, to)
            zones[#zones + 1] = to
            e.G:start_zone(to)
            local w = ctx:wait(60000, function() return e.G.gameState == 'INGAME' and e.G.zone == to and e.G.meshLoaded end)
            if not w.ok and w.why ~= 'timeout' then return w end
            return w.ok and R.ok({ hops = 1 }) or R.fail('zone', 'did not zone')
        end,
    }
    local cfg = Config.load(ROOT .. 'data/')
    package.loaded['core.unsold'] = nil
    local path = TESTS_DIR .. 'tmp_unsold3.ini'; os.remove(path)
    local unsold = require('core.unsold').new({ path = path, merchants = cfg.merchants })
    local blocks = { inventory = e.inv, windows = e.win, cursor = e.cur, spawns = e.spawns, nav = e.nav, merchant = e.merchant,
        bank = e.bank, kit = e.kit, station = e.station, travel = travel, kitslot = { restore = function() return R.ok() end } }
    local env = { blocks = blocks, planner = Planner.new(cfg), cfg = cfg, log = e.log, mq = e.F.mq, describe = Planner.describe,
        unsold = unsold, me = 'Antilerd',
        world = function()
            return { zone = e.G.zone or 'freeporttemple', bags = function(i) return e.inv:count(i) end, bank = function() return 0 end,
                     canCast = function() return false end, kit = function() return false end }
        end }
    e.runner:add(require('engine.make').get_job(env, 'Jar of Lacquer', 2)); e.runner:step()
    truthy(e.runner.last.ok, R.describe(e.runner.last))
    eq(e.G:count('Jar of Lacquer'), 2); eq(#zones, 0, 'bought here')
    truthy(e.log.has('Jar of Lacquer not on the list yet'), 'reopened, said')
    truthy(not e.log.has('does not sell it after all'), 'nothing learned')
    eq(#unsold:items_for('Borik Darkanvil', 'freeporttemple'), 0)
    os.remove(path)
end)

test('merchant: a list that says complete before what we came for is on it is waited for; past the wait, opened again (2.43.7)', function()
    local e = block_env()
    e.G:bag(1, 'Backpack', 10)
    e.merchant.log = e.log
    local id = e.G:spawn('Brewmaster Berina', 0, 5, 0, { sells = { 'Water Flask' } })
    e.G.partialListMs = 800
    local r = e.run(function(ctx) return e.merchant:open(ctx, id, { 'Water Flask' }) end)
    truthy(r.ok, R.describe(r)); eq(#r.value.missing, 0, 'waited for, found')
    truthy(e.log.has('what we came for on the list: yes'), 'logged')
    e.run(function(ctx) return e.merchant:close(ctx) end)
    e.G.partialListMs = 7000
    local r2 = e.run(function(ctx) return e.merchant:open(ctx, id, { 'Water Flask' }) end)
    eq(r2.value.missing[1], 'Water Flask', 'not there within the wait: said missing')
    truthy(e.log.has('not on it: Water Flask'), 'logged')
end)

test('unsold: a list in game that does have it takes it off and puts the merchant back; a pre-2.43.7 file is moved aside once', function()
    local path = TESTS_DIR .. 'tmp_unsold2.ini'; local old = TESTS_DIR .. 'tmp_unsold2_old.ini'
    os.remove(path); os.remove(old)
    local fh = io.open(path, 'wb'); fh:write('[Unsold]\r\nAudri Deepfacet##freeporttemple=Platinum Bar\r\n'); fh:close()
    package.loaded['core.unsold'] = nil
    local Unsold = require('core.unsold')
    local function audri(m) for _, v in ipairs(m['platinum bar'] or {}) do if v.npc == 'Audri Deepfacet' and v.zone == 'freeporttemple' then return true end end end
    local m1 = Config.load(ROOT .. 'data/').merchants
    local L = fake_log()
    local u = Unsold.new({ path = path, merchants = m1, log = L })
    truthy(L.has('moved to tmp_unsold2_old.ini and started empty'), 'said')
    truthy(io.open(old, 'rb'), 'the old file kept'); truthy(audri(m1), 'Audri sells Platinum Bar again')
    eq(#u:items_for('Audri Deepfacet', 'freeporttemple'), 0)
    -- learned, then a full list shows it: taken off, put back
    truthy(u:add('Audri Deepfacet', 'freeporttemple', 'Platinum Bar')); truthy(not audri(m1), 'taken out')
    local L2 = fake_log()
    local m2 = Config.load(ROOT .. 'data/').merchants
    local u2 = Unsold.new({ path = path, merchants = m2, log = L2 })
    truthy(not L2.has('started empty'), 'a 2.43.7 file is kept'); truthy(not audri(m2), 'read back')
    truthy(u2:remove('Audri Deepfacet', 'freeporttemple', 'Platinum Bar')); truthy(audri(m2), 'put back')
    local u3 = Unsold.new({ path = path, merchants = Config.load(ROOT .. 'data/').merchants })
    eq(#u3:items_for('Audri Deepfacet', 'freeporttemple'), 0, 'saved')
    os.remove(path); os.remove(old)
end)

test('factions: con words rank best first; apprehensively is the worst that buys; saved and read back', function()
    local Factions = require('core.factions')
    truthy(Factions.can_buy('apprehensively')); truthy(not Factions.can_buy('dubiously')); truthy(Factions.can_buy('Ally'))
    eq(Factions.rank('ready to attack'), 9); eq(Factions.rank('nonsense'), nil)
    local path = TESTS_DIR .. 'tmp_factions.ini'
    local f = Factions.new({ path = path })
    f:set('Shela', 'Talem Tucter', 'Thurgadina', 'glowers'); eq(f:get('Shela', 'Talem Tucter', 'thurgadina'), nil, 'not a con word')
    f:set('Shela', 'Talem Tucter', 'Thurgadina', 'dubiously'); f:set('Ejtou', 'Talem Tucter', 'thurgadina', 'kindly')
    local g = Factions.new({ path = path })
    eq(g:barred('shela', 'talem tucter', 'thurgadina'), 'dubiously'); eq(g:barred('Ejtou', 'Talem Tucter', 'thurgadina'), nil)
    eq(g:get('Ejtou', 'Talem Tucter', 'thurgadina'), 'kindly')
    os.remove(path)
end)

-- ---- kits moved into pack10 ------------------------------------------------------------------------
local function silk_run(setup, cmd)
    local F, G, done = marr(function(G)
        G:spawn('A Shady Merchant', 640, 10, -47, { sells = { 'Spiderling Silk' } })
        G:spawn('Engineer Beri', 660, 10, -47, { sells = { 'Dry Hook' } })
        G.recipes['Silk Thread'] = { 'Spiderling Silk', 'Spiderling Silk' }
        G.recipes['Night Swooper Dry Fly'] = { 'Bat Fur', 'Silk Thread', 'Dry Hook' }
        G:kit_in(1, 30, 'Sewing Kit', 10)
        if setup then setup(G) end
    end)
    F.at(100, function() F.mq.cmd(cmd or '/lc make 1 Silk Thread') end)
    F.at(400, function() F.click('Go') end)
    F.at(150000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    return printed, printed:match('[^\n]*Done[^\n]*') or printed, G, done
end
local function at(G, pk, sl) local x = sl and G.packs[pk].items[sl] or G.packs[pk]; return x and x.name end

test('kits: pack10 empty - the kit goes in for the step and back to its bag after', function()
    local printed, line, G, done = silk_run()
    truthy(line:find('Silk Thread: 1/1 ok, made 1', 1, true), line)
    truthy(printed:find('Sewing Kit into pack10 (into an empty pack10)', 1, true), printed)
    eq(at(G, 10), nil, 'pack10 empty again'); eq(at(G, 1, 30), 'Sewing Kit', 'the kit is back where it was')
    eq(#G.cursor, 0)
    done()
end)

test('kits: pack10 holds an empty kit - swapped in, swapped back', function()
    local printed, line, G, done = silk_run(function(G) G:kit(10, 'Tackle Box', 10) end)
    truthy(line:find('Silk Thread: 1/1 ok, made 1', 1, true), line)
    truthy(printed:find('swapped with Tackle Box', 1, true), printed)
    eq(at(G, 10), 'Tackle Box'); eq(at(G, 1, 30), 'Sewing Kit')
    done()
end)

test('kits: pack10 holds a bag with items - emptied into the other bags, the bag goes back, its items stay put', function()
    local printed, line, G, done = silk_run(function(G)
        G:bag(10, 'Backpack', 8); G:put(10, 1, 'Bone Chips', 5); G:put(10, 2, 'Rat Whiskers', 2); G:put(10, 4, 'Cloth Cap', 1)
    end)
    truthy(line:find('Silk Thread: 1/1 ok, made 1', 1, true), line)
    truthy(printed:find('moved 3 items out of the bag in pack10', 1, true), printed)
    eq(at(G, 10), 'Backpack'); eq(next(G.packs[10].items), nil, 'the Backpack is back, empty')
    eq(at(G, 1, 30), 'Sewing Kit')
    eq(G:count('Bone Chips'), 5); eq(G:count('Rat Whiskers'), 2); eq(G:count('Cloth Cap'), 1)
    done()
end)

test('kits: pack10 holds a single item - it is stowed, the kit goes in; the item is not put back', function()
    local printed, line, G, done = silk_run(function(G) G:put(10, nil, 'Rusty Dagger', 1) end)
    truthy(line:find('Silk Thread: 1/1 ok, made 1', 1, true), line)
    truthy(printed:find('Rusty Dagger from pack10 stowed', 1, true), printed)
    eq(at(G, 10), nil); eq(G:count('Rusty Dagger'), 1); eq(at(G, 1, 30), 'Sewing Kit')
    done()
end)

test('kits: two kits in one run (subcombine) - each takes pack10 in turn, everything ends where it started', function()
    local printed, line, G, done = silk_run(function(G)
        G:bag(10, 'Backpack', 8); G:put(10, 1, 'Bone Chips', 5)
        G:kit_in(1, 31, 'Tackle Box', 10)
        G:put(1, 5, 'Bat Fur', 1)
    end, '/lc make 1 Night Swooper Dry Fly')
    truthy(line:find('Silk Thread: 1/1 ok, made 1; Night Swooper Dry Fly: 1/1 ok, made 1', 1, true), line)
    eq(at(G, 10), 'Backpack'); eq(at(G, 1, 30), 'Sewing Kit'); eq(at(G, 1, 31), 'Tackle Box')
    eq(G:count('Night Swooper Dry Fly'), 1); eq(#G.cursor, 0)
    done()
end)

test('kits: the kit that started in pack10 is needed by a later step - everything still ends where it started', function()
    local printed, line, G, done = silk_run(function(G)
        G:kit(10, 'Tackle Box', 10)                      -- 2.09.0 in game: Tackle Box in pack10, Sewing Kit in a bag
        G:put(1, 5, 'Bat Fur', 1)
    end, '/lc make 1 Night Swooper Dry Fly')
    truthy(line:find('Silk Thread: 1/1 ok, made 1; Night Swooper Dry Fly: 1/1 ok, made 1', 1, true), line)
    eq(at(G, 10), 'Tackle Box', 'the Tackle Box is back in pack10'); eq(at(G, 1, 30), 'Sewing Kit', 'the Sewing Kit is back in its bag')
    done()
end)

test('kits: a kit not carried is taken from the bank on the bank trip, used, and kept', function()
    local printed, line, G, done = silk_run(function(G)
        G.packs[1].items[30] = nil
        G:bankbag(1, 'Bank Bag', 10); G:bankkit(1, 1, 'Large Sewing Kit', 10)
        G:spawn('Sherin Matrick', 620, 10, -47, { sells = { 'Planar Sewing Kit', 'Large Sewing Kit' } })
        G.kitItems = { ['planar sewing kit'] = 10, ['large sewing kit'] = 10 }
    end)
    truthy(printed:find('Bank: took 1 Large Sewing Kit', 1, true), printed)
    truthy(not printed:find('Bought 1 Planar Sewing Kit', 1, true), 'the bank comes before buying')
    truthy(line:find('Silk Thread: 1/1 ok, made 1', 1, true), line)
    eq(G:count('Large Sewing Kit'), 1, 'kept in the bags'); eq(G:bankcount('Large Sewing Kit'), 0); eq(at(G, 10), nil)
    done()
end)

test('kits: a kit not carried and not banked is bought - the first variant in BuyOrder - used, and kept', function()
    local printed, line, G, done = silk_run(function(G)
        G.packs[1].items[30] = nil
        G:spawn('Sherin Matrick', 620, 10, -47, { sells = { 'Planar Sewing Kit', 'Large Sewing Kit' } })
        G.kitItems = { ['planar sewing kit'] = 10, ['large sewing kit'] = 10 }
    end)
    truthy(printed:find('Bought 1 Planar Sewing Kit from Sherin Matrick', 1, true), printed)
    truthy(line:find('Silk Thread: 1/1 ok, made 1', 1, true), line)
    eq(G:count('Planar Sewing Kit'), 1, 'kept in the bags'); eq(G:count('Large Sewing Kit'), 0)
    done()
end)

test('kits: a bag too small for what comes out of pack10 - it goes to another slot that fits, and back after', function()
    local printed, line, G, done = silk_run(function(G)
        G.packs[1].items[30] = nil
        G:bag(3, 'Small Pouch', 4, { cap = 2 }); G:kit_in(3, 1, 'Sewing Kit', 10, { size = 2 })
        G:bag(10, 'Backpack', 8, { size = 3 })
    end)
    truthy(line:find('Silk Thread: 1/1 ok, made 1', 1, true), line)
    truthy(printed:find('swapped with Backpack', 1, true), printed)
    eq(at(G, 10), 'Backpack'); eq(at(G, 3, 1), 'Sewing Kit')
    local reopen = 0; for _, c in ipairs(G.log) do if c == '/nomodkey /itemnotify pack3 rightmouseup' then reopen = reopen + 1 end end
    truthy(reopen <= 4, 'the pouch is not reopened over and over for a Backpack it cannot hold: ' .. reopen)
    done()
end)

test("kits: a tradeskill-only bag (Artisan's Adept Attache) gets only tradeskill items - never a bag or other items", function()
    local printed, line, G, done = silk_run(function(G)
        G.packs[1].items[30] = nil
        G:bag(1, "Artisan's Adept Attache", 10, { tsOnly = true }); G:kit_in(1, 1, 'Sewing Kit', 10)
        G:bag(10, 'Backpack', 8); G:put(10, 1, 'Cloth Cap', 1)
        G:put(10, 2, 'Bone Chips', 4).ts = true
    end)
    truthy(line:find('Silk Thread: 1/1 ok, made 1', 1, true), line)
    eq(at(G, 10), 'Backpack'); eq(at(G, 1, 1), 'Sewing Kit')
    for i = 1, 10 do
        local it = G.packs[1].items[i]
        truthy(not it or it.ts or it.kit, 'only tradeskill items in the Attache, found ' .. tostring(it and it.name))
    end
    eq(G:count('Cloth Cap'), 1); eq(G:count('Bone Chips'), 4)
    -- clicks into the Attache: the Bone Chips going in, the kit coming out, the kit going back - nothing refused
    local clicks = 0; for _, c in ipairs(G.log) do if c:find('/itemnotify in pack1 ', 1, true) then clicks = clicks + 1 end end
    eq(clicks, 3, 'no clicks into the Attache with something it would refuse')
    done()
end)

test('jobs: a cast E3 began before the pause is let finish before anything else; past the cap it is /stopcast', function()
    local printed, line, G, done = silk_run(function(G)
        G.casting = { spell = 'Some Buff' }
        G.F.at(3000, function() G.casting = nil end)          -- E3's buff lands 3s in
    end)
    truthy(line:find('Silk Thread: 1/1 ok, made 1', 1, true), line)
    truthy(not table.concat(G.log, '\n'):find('/stopcast', 1, true), 'a cast that ends is not stopped')
    done()
    printed, line, G, done = silk_run(function(G) G.casting = { spell = 'A Long Song' } end)
    truthy(printed:find('still casting after 15s - /stopcast', 1, true), printed)
    truthy(line:find('Silk Thread: 1/1 ok, made 1', 1, true), line)
    done()
end)

test('kits: a kit already in place with leftovers in it is emptied first, then used (2.46.3 Vadar log: "slot taken")', function()
    local printed, line, G, done = silk_run(function(G)
        G:kit(10, 'Sewing Kit', 10); G:put(10, 1, 'Bone Chips', 1)
    end)
    truthy(line:find('Silk Thread: 1/1 ok, made 1', 1, true), line)
    truthy(printed:find('holds 1=Bone Chips x1 from before - emptying it first', 1, true), printed)
    truthy(not printed:find('slot taken', 1, true), printed)
    eq(G:count('Bone Chips'), 1, 'kept, in the bags')
    done()
end)

test('kits: an ingredient inside another kit in a top-level slot is taken out first (2.46.3 Cadbane log: pack9 did not open)', function()
    local printed, line, G, done = silk_run(function(G)
        G.kitOpensTradeskill = true   -- Lazarus: a kit in a pack slot opens the tradeskill window, not a PackN window
        G:kit(9, 'Tackle Box', 10); G:put(9, 1, 'Spiderling Silk', 2)
    end)
    truthy(line:find('Silk Thread: 1/1 ok, made 1', 1, true), line)
    truthy(printed:find('took Spiderling Silk out of the Tackle Box in pack9', 1, true), printed)
    truthy(not printed:find('did not open', 1, true), printed)
    eq(at(G, 9), 'Tackle Box'); eq(next(G.packs[9].items), nil, 'the Tackle Box is left empty')
    done()
end)

test('kits: the preflight does not count pack10\'s free slots when a kit will take pack10 (2.46.3 Cadbane log: no room)', function()
    local F, G, done = marr(function(G)
        G:spawn('A Shady Merchant', 640, 10, -47, { sells = { 'Spiderling Silk' } })
        G.recipes['Silk Thread'] = { 'Spiderling Silk', 'Spiderling Silk' }
        G:kit_in(1, 30, 'Sewing Kit', 10)
        G:bag(10, 'Backpack', 8); G:put(10, 1, 'Bone Chips', 5)
    end)
    local frame
    F.at(100, function() F.mq.cmd('/lc make 1 Silk Thread') end)
    F.at(300, function() frame = F.draw() end)
    F.at(400, function() F.mq.cmd('/lc cancel') end)
    F.at(1000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local text = table.concat(frame or {}, '\n')
    truthy(text:find('not counting the 7 free in pack10: the kit goes there', 1, true), text)
    eq(at(G, 10), 'Backpack', 'cancelled: nothing moved')
    done()
end)

test('kits: a desync that shuts the kit\'s own window gets /cleanup and the kit opened again before the next combine (2.46.7 Vadar log)', function()
    local printed, line, G, done = silk_run(function(G)
        local sf = io.open(ROOT .. 'settings/LazCraft_Glanen.ini', 'w'); sf:write('[Settings]\nClickPace=fixed\nClickFloorMs=0\nQuietMs=300\n'); sf:close()
        G.combineFails = 1; G.salvage = { ['Silk Thread'] = { 'Spiderling Silk' } }; G.salvageLateMs = 450
        G.desyncOnLate = true; G.desyncShutsKit = true
    end, '/lc make 2 Silk Thread')
    truthy(line:find('Silk Thread: 1/2 ok, 1 failed', 1, true), line)
    truthy(printed:find('Sewing Kit: clearing, /cleanup and opening it again before the next combine', 1, true), printed)
    truthy(not printed:find('no answer', 1, true), 'never sent into a shut window')
    eq(#G.cursor, 0)
    done()
end)

test('kits: a run that fails still puts the inventory back', function()
    local printed, _, G, done = silk_run(function(G)
        G:kit(10, 'Tackle Box', 10)
        G.recipes['Silk Thread'] = nil     -- the game refuses the combine
    end)
    truthy(printed:find('combine refused', 1, true), printed)
    truthy(printed:find('Kits: inventory put back as it was', 1, true), printed)
    eq(at(G, 10), 'Tackle Box'); eq(at(G, 1, 30), 'Sewing Kit'); eq(G:count('Spiderling Silk'), 2)
    done()
end)

test('in game: a cast step - memorize, meditate, cast (again after a fizzle), stow the product, then the combine', function()
    local F, G, done = marr(function(G)
        G:kit(9, "Jeweler's Kit", 4)
        G:put(1, 1, 'Amber', 1); G:put(1, 2, 'Silver Bar', 100)
        G.book['superior mass enchant silver'] = true
        G.produce['superior mass enchant silver'] = { product = 'Enchanted Silver Bar', yield = 100, reagents = { { 'Silver Bar', 100 } } }
        G.recipes['Silver Amber Ring'] = { 'Amber', 'Enchanted Silver Bar' }
        G.mana = 20; G.fizzleNext = 1; G.manaCost = 5
    end)
    F.at(100, function() F.mq.cmd('/lc make 1 O6358') end)
    F.at(400, function() F.click('Go') end)
    F.at(200000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local line = printed:match('[^\n]*Done[^\n]*') or printed
    truthy(printed:find('sitting to meditate', 1, true), printed)
    truthy(printed:find('made nothing (fizzled)', 1, true), printed)
    truthy(line:find('Enchanted Silver Bar (cast Superior Mass Enchant Silver): 1/1 ok, 1 failed, made 100; Silver Amber Ring: 1/1 ok, made 1', 1, true), line)
    eq(G.gems[8], 'Superior Mass Enchant Silver'); eq(G:count('Silver Bar'), 0)
    eq(G:count('Enchanted Silver Bar'), 99); eq(G:count('Silver Amber Ring'), 1); eq(#G.cursor, 0); eq(G.sitting, false)
    done()
end)

test('in game: an open kit is not mistaken for the station - it is closed, then the station is used', function()
    local F, G, done = marr(function(G)
        G:kit(10, "Jeweler's Kit", 4)
        G:put(1, 1, 'Small Piece of Ore', 4); G:put(1, 2, 'Water Flask', 2)
    end)
    F.at(50, function() F.mq.cmd('/nomodkey /itemnotify pack10 rightmouseup') end)   -- the kit open by hand
    F.at(100, function() F.mq.cmd('/lc make 2 Metal Bits') end)
    F.at(400, function() F.click('Go') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Metal Bits: 2/2 ok, made 4', 1, true), printed:match('[^\n]*Done[^\n]*') or printed)
    eq(G:count('Metal Bits'), 4)
    done()
end)

test('kit: a combine window that is not this kit (a station) is closed, then the kit opens', function()
    local e = jewel_env()
    e.G:window('ContainerCombine_Items', true)   -- someone else's combine window
    local o = e.run(function(ctx) return e.kit:open(ctx, 10) end)
    truthy(o.ok, R.describe(o)); eq(o.value.how, 'right-click'); eq(e.G.packs[10].open, true)
end)

test('settings live in lazcraft/settings, list every value, and an old file is moved in', function()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local old = io.open(tmp .. '/LazCraft_Glanen.ini', 'w'); old:write('[Settings]\r\nItemPaceMs=7\r\nPaceStowMs=50\r\n'); old:close()
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor' }) do package.loaded[m] = nil end
    F.at(100, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local path = ROOT .. 'settings/LazCraft_Glanen.ini'
    local fh = io.open(path, 'r'); truthy(fh, 'settings file written'); local text = fh:read('*a'); fh:close()
    truthy(text:find('ItemPaceMs=7', 1, true), 'old value carried over')
    truthy(text:find('LogToFile=1', 1, true) and text:find('LogFileLevel=debug', 1, true), 'every setting listed')
    truthy(not text:find('PaceStowMs', 1, true), 'retired settings dropped')
    eq(io.open(tmp .. '/LazCraft_Glanen.ini', 'r'), nil, 'old file removed')
    os.remove(path); os.remove(ROOT .. 'logs/LazCraft_Glanen.log'); os.remove(ROOT .. 'logs/LazCraft_Glanen.prev.log')
    os.execute('rm -rf "' .. tmp .. '"')
end)

realPrint('peers and crew')
local Peers = require('blocks.peers')
local Crew = require('engine.crew')

-- Characters on one network: each has its own mq stub; '/dex', '/e3bct', '/bct', '/dgge' reach the others.
local function net()
    local N = { now = 0, chars = {}, queue = {} }
    function N.char(name, plugins)
        local m = { name = name, cmds = {}, binds = {}, plugins = plugins or { MQ2DanNet = 'MQ2DanNet' } }
        m.TLO = {
            Plugin = function(n) return function() return m.plugins[n] end end,
            EQBC = { Connected = function() return m.plugins.connected == true end },
            MQ2Mono = { Query = function() return function() return m.plugins.e3 end end },
        }
        m.gettime = function() return N.now end
        m.bind = function(n, fn) m.binds[n] = fn end
        m.unbind = function(n) m.binds[n] = nil end
        m.cmd = function(s)
            m.cmds[#m.cmds + 1] = s
            local to, c = s:match('^/dex (%S+) (.*)$')
            if not to then to, c = s:match('^/e3bct (%S+) (.*)$') end
            if not to then to, c = s:match('^/bct (%S+) /(.*)$') end
            if to then N.queue[#N.queue + 1] = { to = to:lower(), cmd = c }; return end
            local g = s:match('^/dgge (.*)$')
            if g then for k in pairs(N.chars) do if k ~= name:lower() then N.queue[#N.queue + 1] = { to = k, cmd = g } end end; return end
            if s:match('^/lc_') then N.queue[#N.queue + 1] = { to = name:lower(), cmd = s } end
        end
        N.chars[name:lower()] = m
        return m
    end
    -- deliver everything sent so far (and what that sends), like doevents on each client
    function N.flush()
        local guard = 0
        while #N.queue > 0 do
            guard = guard + 1; if guard > 100 then error('message loop') end
            local q = table.remove(N.queue, 1)
            local m = N.chars[q.to]
            if m then
                local words = {}
                for w in q.cmd:gmatch('%S+') do words[#words + 1] = w end
                local fn = m.binds[table.remove(words, 1)]
                if fn then fn(unpack(words)) end
            end
        end
    end
    return N
end

test('peers: names survive the trip - spaces, apostrophes, commas, empty', function()
    for _, s in ipairs({ "Artisan's Adept Attache", 'Spell: Mass, Enchant', '', 'Shela' }) do
        eq(Peers.decode(Peers.encode(s)), s)
        truthy(not Peers.encode(s):find('[ \',]'), 'no separators left in ' .. s)
    end
    eq(Peers.encode(''), '-')
    local l = Peers.decode_list(Peers.encode_list({ 'Enchanted Silver Bar', "Bob's, Thing" }))
    eq(#l, 2); eq(l[2], "Bob's, Thing")
    eq(#Peers.decode_list('-'), 0)
end)

test('peers: auto picks DanNet, then E3, then EQBC; a chosen one that is missing is said once and retried later', function()
    local N = net()
    local log = fake_log()
    local choice = 'auto'
    local m = N.char('Shela', { MQ2DanNet = 'x', MQ2Mono = 'x', MQ2EQBC = 'x' })
    local p = Peers.new({ mq = m, log = log, me = 'Shela', choice = function() return choice end })
    eq(p:detect(), 'dannet')
    truthy(m.cmds[1]:find('/dnet localecho off', 1, true), 'DanNet echo off')
    m.plugins = { MQ2Mono = 'x', MQ2EQBC = 'x', e3 = 'FALSE' }; p:reset()
    eq(p:detect(), 'e3')
    m.plugins = { MQ2Mono = 'x', MQ2EQBC = 'x', connected = true }; p:reset()
    eq(p:detect(), 'eqbc', 'E3 not answering and EQBC connected')
    choice = 'dannet'; p:reset()
    eq(p:detect(), nil)
    eq(p:send('Bob', 'hello'), false)
    eq(p:send('Bob', 'hello'), false)
    local said = 0
    for _, l in ipairs(log.lines) do if l:find('DanNet chosen', 1, true) then said = said + 1 end end
    eq(said, 1, 'said once')
    m.plugins.MQ2DanNet = 'x'
    eq(p:detect(), nil, 'not retried before RETRY_MS')
    N.now = Peers.RETRY_MS + 1
    eq(p:detect(), 'dannet')
end)

test('peers: each network gets its own command; to yourself runs here; every message is logged', function()
    local N = net()
    local log = fake_log()
    local m = N.char('Shela', { MQ2DanNet = 'x' })
    local p = Peers.new({ mq = m, log = log, me = 'Shela', choice = function() return 'auto' end })
    p:send('Bob', 'card', Peers.encode('pok'), 'idle', '-')
    eq(m.cmds[#m.cmds], '/dex Bob /lc_card Shela pok idle -')
    p:send('shela', 'hello')
    eq(m.cmds[#m.cmds], '/lc_hello Shela', 'self runs locally')
    p:group('hello'); eq(m.cmds[#m.cmds], '/dgge /lc_hello Shela')
    m.plugins = { MQ2Mono = 'x', e3 = 'false' }; p:reset()
    p:send('Bob', 'hello'); eq(m.cmds[#m.cmds], '/e3bct Bob /lc_hello Shela')
    m.plugins = { MQ2EQBC = 'x', connected = true }; p:reset()
    p:send('Bob', 'hello'); eq(m.cmds[#m.cmds], '/bct Bob //lc_hello Shela')
    p:raw('Bob', '/lua run lazcraft worker Shela'); eq(m.cmds[#m.cmds], '/bct Bob //lua run lazcraft worker Shela')
    truthy(log.has('peer %-> Bob: /lc_hello Shela'), 'sends logged')
    local got
    p:on('card', function(from, zone) got = from .. ' ' .. zone end)
    m.binds['/lc_card']("Bob", 'pok')
    eq(got, 'Bob pok'); truthy(log.has('peer <%- Bob: card pok'), 'arrivals logged')
end)

local function crew_pair()
    local N = net()
    local w = { zone = 'poknowledge', busy = false, book = { ['Superior Mass Enchant Silver'] = true } }
    local remembered = {}
    local producers = {
        ['Enchanted Silver Bar'] = { spell = 'Superior Mass Enchant Silver' },
        ['Large Block of Magic Clay'] = { spell = 'Superior Mass Enchant Clay' },
    }
    local clog, wlog = fake_log(), fake_log()
    local cm, wm = N.char('Shela'), N.char('Bob')
    local cp = Peers.new({ mq = cm, log = clog, me = 'Shela', choice = function() return 'auto' end })
    local wp = Peers.new({ mq = wm, log = wlog, me = 'Bob', choice = function() return 'auto' end })
    local crafter = Crew.new({ peers = cp, log = clog, now = function() return N.now end, role = 'crafter', me = 'Shela',
        producers = producers, book = function() return false end, zone = function() return 'freeporttemple' end,
        busy = function() return false end, known = function() return remembered end,
        remember = function(n) remembered[#remembered + 1] = n end })
    local worker = Crew.new({ peers = wp, log = wlog, now = function() return N.now end, role = 'worker', me = 'Bob', crafter = 'Shela',
        producers = producers, book = function(s) return w.book[s] == true end, zone = function() return w.zone end,
        busy = function() return w.busy end })
    return N, crafter, worker, w, remembered, clog, wlog
end

test('crew: the roster - everyone DanNet sees, their zones, safe or not; a running worker says its own zone', function()
    local N, crafter, worker, w = crew_pair()
    local cm = N.chars['shela']
    local zones = { sue = 'poknowledge', tom = 'soldunga' }
    cm.TLO.DanNet = setmetatable({ Peers = function() return 'lazarus_shela|lazarus_bob|lazarus_sue|lazarus_tom|lazarus_ann' end },
        { __call = function(_, name) return { Q = function(q) return function() return q == 'Zone.ShortName' and zones[name:lower()] or 'NULL' end end } end })
    crafter:start(); worker:start(); N.flush()
    crafter:tick()
    local asked = {}
    for _, c in ipairs(cm.cmds) do local n = c:match('^/squelch /dquery (%S+) %-q') ; if n then asked[#asked + 1] = n end end
    eq(table.concat(asked, ','), 'Ann,Sue,Tom', 'zones asked of the ones without a card (not me, not Bob)')
    local safe = { poknowledge = true, freeporttemple = true }
    local by = {}
    for _, r in ipairs(crafter:roster_view(safe)) do by[r.name:lower()] = r end
    eq(by.shela, nil, 'not me')
    truthy(by.bob.running and by.bob.zone == 'poknowledge' and by.bob.safe, 'Bob works for us, in PoK')
    truthy(not by.sue.running and by.sue.safe == true, 'Sue in PoK: can be started')
    eq(by.tom.safe, false, 'Tom out in Sol A: greyed')
    eq(by.ann.safe, nil, 'Ann: zone not known')
end)

test('crew: a worker sends its card on start; the crafter lists it, remembers it, and the card says what it can cast', function()
    local N, crafter, worker, w, remembered, clog = crew_pair()
    crafter:start(); worker:start(); N.flush()
    local rows = crafter:view()
    eq(#rows, 1); eq(rows[1].name, 'Bob'); eq(rows[1].zone, 'poknowledge'); eq(rows[1].state, 'idle'); eq(rows[1].status, 'ok')
    eq(#rows[1].items, 1); eq(rows[1].items[1], 'Enchanted Silver Bar', 'the spellbook, not the class')
    eq(remembered[1], 'Bob')
    truthy(clog.has('Worker Bob: poknowledge, idle, casts Enchanted Silver Bar'), 'logged')
    eq(#crafter:casters('enchanted silver bar'), 1); eq(#crafter:casters('Large Block of Magic Clay'), 0)
end)

test('casters: remembered casts first, then the class producers.ini names; lacks left out; a card clears lacks', function()
    local Casters = require('core.casters')
    local c = Casters.new({})
    c:set_class('Ejtou', 'Cleric'); c:set_class('Zed', 'Druid'); c:set_class('Tom', 'Warrior'); c:set_class('Odd', 'soldunga')
    eq(c:class_of('Odd'), nil, 'only a real class is taken')
    c:set_casts('Shela', { 'Vial of Clear Mana' })
    local pr = { classes = { 'Cleric', 'Druid' } }
    local function names(list) local o = {}; for _, x in ipairs(list) do o[#o + 1] = x.name .. ':' .. x.why end; return table.concat(o, ',') end
    eq(names(c:candidates('vial of clear mana', pr)), 'Shela:cast it before,Ejtou:Cleric,Zed:Druid', 'cast before first, then classes')
    eq(names(c:candidates('Vial of Clear Mana', pr, function(n) return n ~= 'Zed' end)), 'Shela:cast it before,Ejtou:Cleric', 'ok() filters')
    c:set_lacks('Ejtou', 'Vial of Clear Mana')
    eq(names(c:candidates('Vial of Clear Mana', pr)), 'Shela:cast it before,Zed:Druid', 'one known to lack it is left out')
    eq(table.concat(c:lacking('Vial of Clear Mana'), ','), 'Ejtou')
    c:set_casts('Ejtou', { 'Vial of Clear Mana' })
    eq(#c:lacking('Vial of Clear Mana'), 0, 'scribed since: its card clears it')
    -- saved and read back
    local path = TESTS_DIR .. 'tmp_casters.ini'
    local d = Casters.new({ path = path })
    d:set_class('Ejtou', 'cleric'); d:set_casts('Ejtou', { 'Amber', 'Vial of Clear Mana' }); d:set_lacks('Zed', 'Amber')
    local e = Casters.new({ path = path })
    eq(e:class_of('ejtou'), 'Cleric'); eq(table.concat(e:casts('Ejtou'), ','), 'Amber,Vial of Clear Mana'); truthy(e:lacks('Zed', 'amber'))
    os.remove(path)
end)

test('crew: the card carries the class; the crafter remembers casts and class, and asks DanNet the class of one never started', function()
    local N = net()
    local Casters = require('core.casters')
    local memo = Casters.new({})
    local producers = { ['Enchanted Silver Bar'] = { spell = 'Superior Mass Enchant Silver' } }
    local cm, wm = N.char('Shela'), N.char('Bob')
    local cp = Peers.new({ mq = cm, log = fake_log(), me = 'Shela', choice = function() return 'auto' end })
    local wp = Peers.new({ mq = wm, log = fake_log(), me = 'Bob', choice = function() return 'auto' end })
    local crafter = Crew.new({ peers = cp, now = function() return N.now end, role = 'crafter', me = 'Shela', memo = memo,
        producers = producers, book = function() return false end, zone = function() return 'freeporttemple' end,
        busy = function() return false end, known = function() return {} end, remember = function() end })
    local worker = Crew.new({ peers = wp, now = function() return N.now end, role = 'worker', me = 'Bob', crafter = 'Shela',
        producers = producers, book = function() return true end, zone = function() return 'poknowledge' end,
        busy = function() return false end, class = function() return 'Enchanter' end })
    -- Sue answers each question; Ann's DanNet hands back the last answer (a class) whatever is asked
    local answers = { sue = { ['Zone.ShortName'] = 'poknowledge', ['Me.Class.Name'] = 'Cleric' } }
    cm.TLO.DanNet = setmetatable({ Peers = function() return 'lazarus_shela|lazarus_bob|lazarus_sue|lazarus_ann' end },
        { __call = function(_, name) return { Q = function(q) return function()
            if name:lower() == 'ann' then return 'Wizard' end
            return (answers[name:lower()] or {})[q] or 'NULL' end end } end })
    crafter:start(); worker:start(); N.flush()
    eq(memo:class_of('Bob'), 'Enchanter', 'from the card'); eq(table.concat(memo:casts('Bob'), ','), 'Enchanted Silver Bar')
    crafter:tick()
    eq(crafter.zones.sue, 'poknowledge'); eq(crafter.zones.ann, nil, 'a class is never taken as a zone')
    N.now = N.now + Crew.ROSTER_MS
    crafter:tick()
    local q = {}
    for _, c in ipairs(cm.cmds) do if c:find('Me.Class.Name', 1, true) then q[#q + 1] = c:match('/dquery (%S+)') end end
    eq(table.concat(q, ','), 'Sue', 'the class is asked once the zone is known')
    eq(memo:class_of('Sue'), 'Cleric')
    local by = {}
    for _, r in ipairs(crafter:roster_view({ poknowledge = true })) do by[r.name:lower()] = r end
    eq(by.sue.class, 'Cleric', 'the Workers tab shows it')
end)

test('make: a caster started for an item whose card does not list it - fails naming the spell, remembered as lacking it', function()
    local Make = require('engine.make')
    local Casters = require('core.casters')
    local memo = Casters.new({}); memo:set_class('Ejtou', 'Cleric')
    local log = fake_log()
    local started = {}
    local env = { mq = { gettime = function() return 0 end }, log = log, casters = memo,
        planner = { producers = { ['vial of clear mana'] = { spells = { { spell = 'Clear Mana' } } } } },
        crew = { start_worker = function(_, n) started[#started + 1] = n end, card_since = function() return true end,
                 can_make = function() return false end } }
    local ctx = { status = function() end, wait = function(_, _, cond) return cond() and R.ok() or { ok = false, why = 'timeout' } end }
    local r = Make.start_for(env, ctx, 'Ejtou', 'Vial of Clear Mana', true)
    eq(r.ok, false); eq(r.why, 'missing spell'); eq(r.worker, 'Ejtou'); eq(started[1], 'Ejtou')
    truthy(r.detail:find('Ejtou (Cleric) cannot make Vial of Clear Mana - Clear Mana is not in its spellbook: buy and scribe it there', 1, true), r.detail)
    truthy(memo:lacks('Ejtou', 'Vial of Clear Mana'), 'remembered')
    truthy(log.has('cannot make Vial of Clear Mana'), 'said in the log')
    env.crew.can_make = function() return true end
    truthy(Make.start_for(env, ctx, 'Ejtou', 'Vial of Clear Mana', true).ok, 'with the spell: ok')
    env.crew.can_make = function() return false end
    truthy(Make.start_for(env, ctx, 'Bob', 'Vial of Clear Mana', false).ok, 'a holder (not a caster) is not checked')
end)

test('crew: the card goes again only when zone or idle/busy changes', function()
    local N, crafter, worker, w = crew_pair()
    crafter:start(); worker:start(); N.flush()
    local function cards() local n = 0; for _, c in ipairs(N.chars.bob.cmds) do if c:find('lc_card', 1, true) then n = n + 1 end end; return n end
    local before = cards()
    worker:tick(); worker:tick(); eq(cards(), before, 'nothing changed, nothing sent')
    w.zone = 'freeporttemple'; worker:tick(); N.flush()
    eq(cards(), before + 1); eq(crafter:view()[1].zone, 'freeporttemple')
    w.busy = true; worker:tick(); N.flush()
    eq(crafter:view()[1].state, 'busy')
end)

test('crew: hello gets a fresh card (spellbook re-read); a second crafter\'s hello is served too (2.44.0)', function()
    local N, crafter, worker, w, _, _, wlog = crew_pair()
    crafter:start(); worker:start(); N.flush()
    w.book['Superior Mass Enchant Clay'] = true
    crafter:hello(); N.flush()
    eq(#crafter:view()[1].items, 2, 'newly scribed spell shows after hello')
    local other = Peers.new({ mq = N.char('Zed'), me = 'Zed', choice = function() return 'auto' end })
    other:send('Bob', 'hello'); N.flush()
    local toZed = 0; for _, c in ipairs(N.chars.bob.cmds) do if c:find('^/dex Zed /lc_card') then toZed = toZed + 1 end end
    eq(toZed, 1, 'a card for Zed')
    truthy(wlog.has('Also working for Zed'), 'logged')
    truthy(worker:serves('zed') and worker:serves('Shela'), 'serves both'); eq(worker.crafter, 'Shela', 'Shela stays its own')
    -- a change goes to both
    w.zone = 'freeporttemple'; worker:tick(); N.flush()
    local zedCards, shelaCards = 0, 0
    for _, c in ipairs(N.chars.bob.cmds) do
        if c:find('^/dex Zed /lc_card Bob freeporttemple') then zedCards = zedCards + 1 end
        if c:find('^/dex Shela /lc_card Bob freeporttemple') then shelaCards = shelaCards + 1 end
    end
    eq(zedCards, 1); eq(shelaCards, 1)
    worker:stop(); N.flush()
    local byes = 0; for _, c in ipairs(N.chars.bob.cmds) do if c:find('/lc_bye') then byes = byes + 1 end end
    eq(byes, 2, 'bye to both')
end)

test('crew: two drivers - each answers the other\'s hello as a driver, and never starts the other as a worker (2.44.0)', function()
    local N, crafter, worker, w, _, clog = crew_pair()
    local zlog = fake_log()
    local zp = Peers.new({ mq = N.char('Zed'), log = zlog, me = 'Zed', choice = function() return 'auto' end })
    local zed = Crew.new({ peers = zp, log = zlog, now = function() return N.now end, role = 'crafter', me = 'Zed',
        producers = {}, book = function() return false end, zone = function() return 'freeporttemple' end,
        busy = function() return false end, known = function() return {} end, remember = function() end, version = 'X' })
    crafter:start(); zed:start(); N.flush()
    crafter:start_worker('Zed'); N.flush()
    truthy(crafter:is_driver('Zed'), 'Zed is a driver'); truthy(clog.has('Zed is a driver too'), 'said')
    N.now = Crew.HELLO_MS + 1; crafter:tick()
    local runs = 0; for _, c in ipairs(N.chars.shela.cmds) do if c:find('/lua run', 1, true) then runs = runs + 1 end end
    eq(runs, 0, 'never /lua run on a driver')
    eq(crafter:start_worker('Zed'), false, 'refused from now on')
    truthy(clog.has('Not starting Zed as a worker'), 'said why')
end)

test('crew: a remembered worker that does not answer a hello shows as not answering; bye shows stopped', function()
    local N, crafter, worker, w, remembered = crew_pair()
    remembered[1] = 'Sue'
    crafter:start(); worker:start(); N.flush()
    local function row(name) for _, r in ipairs(crafter:view()) do if r.name == name then return r end end end
    eq(row('Sue').status, 'waiting')
    N.now = Crew.HELLO_MS + 1
    eq(row('Sue').status, 'not answering')
    eq(row('Bob').status, 'ok', 'Bob answered the hello')
    crafter:hello(); N.now = N.now + Crew.HELLO_MS + 1
    eq(row('Bob').status, 'not answering', 'card older than the last hello')
    crafter:hello(); N.flush()
    eq(row('Bob').status, 'ok')
    worker:stop(); N.flush()
    eq(row('Bob').status, 'stopped')
    eq(#crafter:casters('Enchanted Silver Bar'), 0)
end)

test('crew: start_worker asks first; runs LazCraft only when nobody answers, even with an old card', function()
    local N, crafter, worker = crew_pair()
    crafter:start(); N.flush()
    local function runs() local n = 0; for _, c in ipairs(N.chars.shela.cmds) do if c:find('/lua run', 1, true) then n = n + 1 end end; return n end
    crafter:start_worker('Bob'); N.flush()
    eq(N.chars.shela.cmds[#N.chars.shela.cmds], '/dex Bob /lc_hello Shela', 'asked first')
    crafter:tick(); eq(runs(), 0, 'not before HELLO_MS')
    N.now = Crew.HELLO_MS; crafter:tick()
    eq(N.chars.shela.cmds[#N.chars.shela.cmds], '/dex Bob /lua run lazcraft worker Shela')
    worker:start(); N.flush()
    N.now = N.now + 100
    crafter:start_worker('bob'); N.flush(); crafter:tick()
    eq(runs(), 1, 'it answered: not started twice')
    -- /lua stop on the worker: no bye, its old card is still on the board
    N.chars.bob.binds = {}
    N.now = N.now + 100
    crafter:start_worker('Bob'); N.flush(); crafter:tick()
    eq(runs(), 1)
    N.now = N.now + Crew.HELLO_MS; crafter:tick()
    eq(runs(), 2, 'silence after the hello: started again')
end)

local function script_env()
    local F = dofile(TESTS_DIR .. 'fake_mq.lua')
    clean_own_files()
    local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
    F.install(tmp)
    local G = dofile(TESTS_DIR .. 'fake_game.lua').new(F)
    F.mq.TLO.Plugin = function(n) return function() return n == 'MQ2DanNet' and n or nil end end
    for _, m in ipairs({ 'core.log', 'core.config', 'core.jobs', 'core.e3', 'ui.window', 'core.ini', 'core.result',
                         'blocks.inventory', 'blocks.windows', 'blocks.cursor', 'blocks.peers', 'engine.crew',
                         'blocks.trade', 'engine.handoff', 'blocks.spawns' }) do package.loaded[m] = nil end
    return F, G, tmp
end
local function sent_matching(G, p)
    local out = {}
    for _, c in ipairs(G.log) do if c:find(p) then out[#out + 1] = c end end
    return out
end

test('in game: a worker sends its card to its crafter on start, busy while a job runs, idle after, bye on quit', function()
    local F, G, tmp = script_env()
    G.book = { ['superior mass enchant silver'] = true }; G.class = 'Enchanter'
    F.at(100, function() F.mq.cmd('/lc test') end)
    F.at(300, function() F.mq.cmd('/lc go') end)
    F.at(9000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))('worker', 'Shela')
    _G.print = realPrint
    local cards = sent_matching(G, '^/dex Shela /lc_card ')
    local VER = (io.open(ROOT .. 'init.lua'):read('*a'):match("local VERSION = '([^']+)'")):gsub(' ', '_')
    eq(cards[1], '/dex Shela /lc_card Glanen freeporttemple idle Enchanted_Silver_Bar ' .. VER .. ' Enchanter')
    eq(cards[2], '/dex Shela /lc_card Glanen freeporttemple busy Enchanted_Silver_Bar ' .. VER .. ' Enchanter', 'busy as soon as the job queues')
    eq(cards[3], '/dex Shela /lc_card Glanen freeporttemple idle Enchanted_Silver_Bar ' .. VER .. ' Enchanter', 'idle when it ends')
    eq(#cards, 3, 'nothing extra')
    eq(#sent_matching(G, '^/dex Shela /lc_bye Glanen$'), 1, 'bye on quit')
    truthy(F.render ~= nil, 'a worker draws its own window (2.42.7)')
    os.remove(ROOT .. 'logs/LazCraft_Glanen.log'); os.remove(ROOT .. 'logs/LazCraft_Glanen.prev.log')
    os.remove(ROOT .. 'settings/LazCraft_Glanen.ini')
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: a worker\'s Pause holds its job and starts nothing new; its crafter is told (card paused); Resume carries on', function()
    local F, G, tmp = script_env()
    local frames = {}
    F.at(100, function() F.mq.cmd('/lc test') end)
    F.at(300, function() F.mq.cmd('/lc go') end)
    F.at(400, function() frames.before = F.draw(); F.click('Pause##lc_wpause') end)
    F.at(3000, function() frames.paused = F.draw() end)
    F.at(20000, function() F.click('Resume##lc_wres') end)
    F.at(40000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))('worker', 'Shela')
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local before, paused = table.concat(frames.before or {}, '\n'), table.concat(frames.paused or {}, '\n')
    truthy(before:find('Working for Shela', 1, true) and before:find('button:Pause##lc_wpause', 1, true), before)
    truthy(paused:find('Paused - Shela waits', 1, true) and paused:find('button:Resume##lc_wres', 1, true), paused)
    truthy(printed:find('Paused by hand - Shela waits until Resume', 1, true), printed)
    truthy(#sent_matching(G, '^/dex Shela /lc_card Glanen freeporttemple paused ') >= 1, 'the card says paused')
    truthy(printed:find('Resumed by hand', 1, true) and printed:find('Done: ', 1, true), 'carried on after Resume')
    os.remove(ROOT .. 'logs/LazCraft_Glanen.log'); os.remove(ROOT .. 'logs/LazCraft_Glanen.prev.log')
    os.remove(ROOT .. 'settings/LazCraft_Glanen.ini')
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: a worker takes its crafter\'s theme and saves it; another crafter\'s or an unknown one is not taken (2.43.0)', function()
    local F, G, tmp = script_env()
    F.at(300, function() F.mq.cmd('/lc_theme Shela Ember') end)
    F.at(600, function() F.mq.cmd('/lc_theme Bob Glass') end)
    F.at(900, function() F.mq.cmd('/lc_theme Shela Neon') end)
    F.at(1200, function() F.draw(); F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))('worker', 'Shela')
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Theme: Ember from Shela', 1, true), printed)
    truthy(printed:find('Neon is not a theme here', 1, true), 'an unknown one is said and left')
    truthy(not printed:find('Theme: Glass', 1, true), 'another crafter\'s is ignored')
    local sf = io.open(ROOT .. 'settings/LazCraft_Glanen.ini', 'r'); local text = sf:read('*a'); sf:close()
    truthy(text:find('Theme=Ember', 1, true), 'saved')
    eq(F.depth, 0, 'ImGui balanced')
    os.remove(ROOT .. 'logs/LazCraft_Glanen.log'); os.remove(ROOT .. 'logs/LazCraft_Glanen.prev.log')
    os.remove(ROOT .. 'settings/LazCraft_Glanen.ini')
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('theme: every theme pushes what the build has and pops exactly that; an unknown name is Midnight', function()
    package.loaded['ui.theme'] = nil
    local Theme = require('ui.theme')
    local cols, vars = 0, 0
    local fake = { PushStyleColor = function(slot, r, g, b, a)
                       assert(type(slot) == 'number' and r >= 0 and r <= 1 and a >= 0 and a <= 1, 'floats 0-1'); cols = cols + 1 end,
                   PopStyleColor = function(n) cols = cols - n end,
                   PushStyleVar = function(slot, v) assert(type(slot) == 'number' and type(v) == 'number'); vars = vars + 1 end,
                   PopStyleVar = function(n) vars = vars - n end }
    local Col, Var = {}, {}
    for i, k in ipairs({ 'WindowBg', 'TitleBg', 'TitleBgActive', 'Border', 'Button', 'Separator', 'PlotHistogram', 'Header' }) do Col[k] = i end
    for i, k in ipairs({ 'WindowRounding', 'FrameRounding', 'WindowTitleAlign' }) do Var[k] = i end
    _G.ImGuiCol, _G.ImGuiStyleVar = Col, Var
    for _, name in ipairs(Theme.NAMES) do
        local c, v = Theme.push(fake, name)
        eq(c, 8, name .. ': the slots this build has'); eq(v, 3, name .. ': vars')
        Theme.pop(fake, c, v)
        eq(cols, 0); eq(vars, 0)
    end
    _G.ImGuiCol, _G.ImGuiStyleVar = nil, nil
    eq(select(1, Theme.push(fake, 'Midnight')), 0, 'no ImGuiCol (the tests): nothing pushed')
    truthy(Theme.get('Neon') == Theme.get('Midnight') and not Theme.valid('Neon') and Theme.valid('Glass'))
    local p = Theme.palette('Ember')
    truthy(p.label[1] > p.label[3], 'Ember labels are warm')
end)

test('in game: a worker with no crafter name waits, and works for the first crafter that says hello', function()
    local F, G, tmp = script_env()
    local frames = {}
    F.at(500, function() frames.waiting = F.draw() end)
    F.at(1000, function() F.mq.cmd('/lc_hello Mortician') end)
    F.at(1500, function() frames.working = F.draw() end)
    F.at(2000, function() F.mq.cmd('/lc_hello Bob') end)
    F.at(3000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))('worker')
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('No crafter named - waiting', 1, true), printed)
    truthy(table.concat(frames.waiting or {}, '\n'):find('Waiting for a crafter', 1, true), 'the window says so')
    truthy(printed:find('Working for Mortician from now on', 1, true), printed)
    truthy(table.concat(frames.working or {}, '\n'):find('Working for Mortician', 1, true), 'the window too')
    eq(#sent_matching(G, '^/dex Mortician /lc_card Glanen '), 1, 'its card goes to Mortician')
    eq(#sent_matching(G, '^/dex Bob /lc_card '), 1, 'a later crafter is served too (2.44.0)')
    truthy(printed:find('Also working for Bob', 1, true), printed)
    eq(#sent_matching(G, '^/dex Mortician /lc_bye Glanen$'), 1, 'bye on quit')
    eq(#sent_matching(G, '^/dex Bob /lc_bye Glanen$'), 1, 'to both')
    os.remove(ROOT .. 'logs/LazCraft_Glanen.log'); os.remove(ROOT .. 'logs/LazCraft_Glanen.prev.log')
    os.remove(ROOT .. 'settings/LazCraft_Glanen.ini')
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: the crafter says hello on start, lists cards on the Workers tab, remembers workers, starts one', function()
    local F, G, tmp = script_env()
    local frame
    F.at(100, function() F.mq.cmd("/lc_card Bob poknowledge idle Enchanted_Silver_Bar,Large_Block_of_Magic_Clay") end)
    F.at(300, function() F.tab = 'Workers'; frame = F.draw(); F.tab = 'Status' end)
    F.at(400, function() F.mq.cmd('/lc worker Bob') end)
    F.at(450, function() F.mq.cmd("/lc_card Bob poknowledge idle Enchanted_Silver_Bar,Large_Block_of_Magic_Clay") end)
    F.at(500, function() F.mq.cmd('/lc worker Sue') end)
    F.at(600, function() F.mq.cmd('/lc fetch Bob 5 Enchanted Silver Bar') end)
    F.at(4000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    eq(#sent_matching(G, '^/dgge /lc_hello Glanen$'), 1, 'hello to the group on start')
    local function has(p) for _, l in ipairs(frame) do if l:find(p, 1, true) then return true end end return false end
    truthy(has('heading:Running  (1)') and has('text:Bob') and has('disabled:poknowledge') and has('colored:idle'), 'Workers tab shows Bob')
    truthy(#sent_matching(G, '^/dex Bob /lc_theme Glanen Midnight$') >= 1, 'a worker that comes up gets the theme (2.43.0)')
    local printed = table.concat(F.printed, '\n')
    truthy(printed:find('Worker Bob: poknowledge, idle, casts Enchanted Silver Bar, Large Block of Magic Clay', 1, true), 'card logged')
    truthy(printed:find('Bob is already working for you', 1, true), 'Bob not started twice')
    eq(#sent_matching(G, '^/dex Sue /lua run lazcraft worker Glanen$'), 1, 'Sue started after no answer')
    eq(#sent_matching(G, '^/dex Bob /lua run'), 0, 'Bob answered, not started')
    eq(#sent_matching(G, '^/dex Bob /lc_come Glanen %S+ 5 Enchanted_Silver_Bar freeporttemple %S+ %S+ %S+ main$'), 1, 'fetch asks Bob to come (we are not in the AFK mirror)')
    local sf = io.open(ROOT .. 'settings/LazCraft_Glanen.ini', 'r')
    local text = sf and sf:read('*a') or ''; if sf then sf:close() end
    truthy(text:find('Workers=Bob', 1, true), 'Bob remembered')
    truthy(text:find('Network=auto', 1, true), 'network setting saved')
    os.remove(ROOT .. 'logs/LazCraft_Glanen.log'); os.remove(ROOT .. 'logs/LazCraft_Glanen.prev.log')
    os.remove(ROOT .. 'settings/LazCraft_Glanen.ini')
    os.execute('rm -rf "' .. tmp .. '"')
end)

realPrint('trade and handoff')
local Trade = require('blocks.trade')
local Handoff = require('engine.handoff')

local function trade_env()
    local e = block_env()
    e.log = fake_log()
    e.trade = Trade.new({ mq = e.F.mq, inventory = e.inv, cursor = e.cur, windows = e.win, spawns = e.spawns, log = e.log })
    return e
end
local ESB = 'Enchanted Silver Bar'

-- a taker that clicks Trade as soon as a trade is loaded and confirms when it lands
local function taker(e)
    local L = { loads = {} }
    L.loaded = function(k, units) L.loads[k] = units; e.G:partner_accepts() end
    L.accepted = function(k) return L.loads[k] ~= nil end
    L.got = function(k) return e.G.tradesDone >= k end
    L.cancelled = function() return L.why end
    return L
end

test('trade give: exact amounts across stacks in one trade, loaded said once, done only when the taker got it', function()
    local e = trade_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, ESB, 20); e.G:put(1, 2, ESB, 30); e.G:put(1, 3, ESB, 15)
    local id = e.G:spawn('Antilerd', 5, 0, 0, { class = 'PC' })
    local L = taker(e)
    local r = e.run(function(ctx) return e.trade:give(ctx, id, ESB, 60, L) end)
    truthy(r.ok, R.describe(r)); eq(r.value.given, 60); eq(r.value.trades, 1)
    eq(L.loads[1], 60); eq(e.G:count(ESB), 5); eq(e.G.tradesDone, 1)
    eq(#e.G.cursor, 0); eq(e.G.packs[1].open, false, 'bag closed again')
    truthy(e.log.has('into the trade %(target window%)'), 'drop logged')
end)

test('trade give: more than 8 stacks goes in two trades; a lost Target_HP drop falls back to clicking the target', function()
    local e = trade_env()
    e.G:bag(1, 'Backpack', 10)
    for i = 1, 10 do e.G:put(1, i, ESB, 5) end
    e.G:put(1, 1, 'Water Flask', 1)   -- not a bar: 9 stacks of bars
    e.G:bag(2, 'Backpack', 10); e.G:put(2, 1, ESB, 5)
    local id = e.G:spawn('Antilerd', 5, 0, 0, { class = 'PC' })
    e.G.dropIgnores = 1
    local L = taker(e)
    local r = e.run(function(ctx) return e.trade:give(ctx, id, ESB, 50, L) end)
    truthy(r.ok, R.describe(r)); eq(r.value.trades, 2); eq(L.loads[1], 40); eq(L.loads[2], 10)
    eq(e.G:count(ESB), 0)
    truthy(e.log.has('click on target'), 'fallback used and logged')
end)

test('give pp: inventory window opened, amount set and read back, dropped, Trade clicked, purse down by exactly n', function()
    local e = trade_env()
    e.G.coin.pp = 500
    local id = e.G:spawn('Lunafeet', 5, 0, 0, { class = 'PC' })
    e.G.partnerAcceptsMs = 2000
    local r = e.run(function(ctx) return e.trade:give_pp(ctx, id, 120) end)
    truthy(r.ok, R.describe(r)); eq(r.value.before, 500); eq(r.value.after, 380)
    eq(e.G.coin.pp, 380); eq(e.G.ppGiven, 120); eq(e.G.cursorPP, 0)
    truthy(e.log.has('DoOpen: InventoryWindow'), 'inventory opened')
    truthy(e.log.has('On the cursor: 120 pp'), 'cursor amount logged')
    truthy(e.log.has('120 pp into the trade %(target window%)'), 'drop logged')
    truthy(e.log.has('waiting up to 60s for Lunafeet'), 'hand wait logged')
end)

test('give pp: nobody clicks Trade - cancelled after the wait, coins back in the purse; short and too far refused', function()
    local e = trade_env()
    e.G.coin.pp = 500
    local id = e.G:spawn('Lunafeet', 5, 0, 0, { class = 'PC' })
    local r = e.run(function(ctx) return e.trade:give_pp(ctx, id, 100) end)
    eq(r.why, 'not accepted'); eq(e.G.coin.pp, 500, 'cancel gave it back'); eq(e.G.windows.tradewnd.open, false)
    eq(e.run(function(ctx) return e.trade:give_pp(ctx, id, 900) end).why, 'short')
    e.G.spawns[id].x = 40
    eq(e.run(function(ctx) return e.trade:give_pp(ctx, id, 10) end).why, 'too far')
end)

test('trade give: too far, taker never clicks, taker gives up - each reported, items back in the bags', function()
    local e = trade_env()
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, ESB, 20)
    local far = e.G:spawn('Antilerd', 40, 0, 0, { class = 'PC' })
    eq(e.run(function(ctx) return e.trade:give(ctx, far, ESB, 5, taker(e)) end).why, 'too far')
    e.G.spawns[far].x = 5
    local L = taker(e); L.loaded = function(k, u) L.loads[k] = u end; L.accepted = function() return false end
    local r = e.run(function(ctx) return e.trade:give(ctx, far, ESB, 5, L) end)
    eq(r.why, 'not accepted')
    e.run(function(ctx) return e.trade:cancel(ctx) end)
    eq(e.G:count(ESB), 20, 'cancel gives it back')
    local L2 = taker(e); L2.loaded = function() L2.why = 'crafter stopped' end
    local r2 = e.run(function(ctx) return e.trade:give(ctx, far, ESB, 5, L2) end)
    eq(r2.why, 'cancelled')
end)

test('trade take: waits for loaded, clicks Trade, says accepted, confirms by the count, says got', function()
    local e = trade_env()
    e.G:bag(1, 'Backpack', 10)
    local L = { acc = {}, gots = {} }
    local loadedAt
    e.F.at(500, function() e.G:incoming({ { ESB, 20 }, { ESB, 5 } }) end)
    e.F.at(700, function() loadedAt = 25 end)
    L.loaded = function(k) return k == 1 and loadedAt or nil end
    L.accept = function(k) L.acc[k] = true; e.G:partner_accepts() end
    L.got = function(k, u) L.gots[k] = u end
    L.cancelled = function() return nil end
    local r = e.run(function(ctx) return e.trade:take(ctx, ESB, 25, L) end)
    truthy(r.ok, R.describe(r)); eq(r.value.taken, 25); eq(L.gots[1], 25); truthy(L.acc[1])
    eq(e.G:count(ESB), 25)
end)

test('trade take: loaded with no window, or a trade that never lands, is reported', function()
    local e = trade_env()
    e.G:bag(1, 'Backpack', 10)
    local L = { loaded = function() return 5 end, accept = function() end, got = function() end, cancelled = function() return nil end }
    eq(e.run(function(ctx) return e.trade:take(ctx, ESB, 5, L) end).why, 'no trade window')
    e.G:incoming({ { ESB, 5 } })
    local r = e.run(function(ctx) return e.trade:take(ctx, ESB, 5, L) end)   -- the giver never clicks
    eq(r.why, 'not received'); truthy(r.detail:find('still open', 1, true), r.detail)
end)

-- Handoff on one side, the other side played by a script watching what we send.
local function handoff_env(role)
    local e = trade_env()
    package.loaded['blocks.peers'] = nil
    local Peers = require('blocks.peers')
    e.F.mq.TLO.Plugin = function(n) return function() return n == 'MQ2DanNet' and n or nil end end
    local me = role == 'crafter' and 'Antilerd' or 'Shela'
    e.peers = Peers.new({ mq = e.F.mq, log = e.log, me = me, choice = function() return 'auto' end })
    e.paths = { freeporttemple = true, poknowledge = true }
    e.travel = {
        path = function(_, to) return e.paths[to] and {} or nil end,
        go = function(_, ctx, to)
            e.G:start_zone(to)
            local w = ctx:wait(60000, function() return e.G.gameState == 'INGAME' and e.G.zone == to end)
            if not w.ok and w.why ~= 'timeout' then return w end
            return w.ok and R.ok({ hops = 1 }) or R.fail('zone', 'did not zone')
        end,
    }
    e.h = Handoff.new({ peers = e.peers, log = e.log, now = e.F.mq.gettime, role = role, me = me,
        crafter = role == 'worker' and 'Antilerd' or '', runner = e.runner, trade = e.trade, nav = e.nav,
        spawns = e.spawns, cursor = e.cur, travel = e.travel, zone = function() return e.G.zone or 'freeporttemple' end })
    e.h:start()
    -- each frame: the handoff's own tick, then new outgoing messages to `on(cmd)`
    e.F.ticks[#e.F.ticks + 1] = function() e.h:tick() end
    function e.script(on)
        local seen = 0
        e.F.ticks[#e.F.ticks + 1] = function()
            while seen < #e.G.log do seen = seen + 1; on(e.G.log[seen]) end
        end
    end
    return e
end
local function sent(e, p) local n = 0; for _, c in ipairs(e.G.log) do if c:find(p) then n = n + 1 end end; return n end

-- a worker played by the script: answers come with coming, walks for `walkMs`, arrives, loads, completes
local function scripted_worker(e, walkMs, opts)
    opts = opts or {}
    local asks = 0
    e.script(function(c)
        local id, n, zone = c:match('^/dex Shela /lc_come Antilerd (%S+) (%d+) Enchanted_Silver_Bar (%S+) %S+ %S+ %S+$')
        if id then
            asks = asks + 1
            if opts.failFirst and asks == 1 then
                return e.F.at(e.F.now + 200, function() e.F.mq.cmd('/lc_failed Shela ' .. id .. ' drop_failed') end)
            end
            if opts.silent then return end
            e.F.mq.cmd('/lc_coming Shela ' .. id .. ' poknowledge queued')
            for t = 10000, walkMs - 1, 10000 do
                e.F.at(e.F.now + t, function() e.F.mq.cmd('/lc_coming Shela ' .. id .. ' ' .. zone .. ' walking') end)
            end
            e.F.at(e.F.now + walkMs, function() e.F.mq.cmd('/lc_arrived Shela ' .. id) end)
            e.F.at(e.F.now + walkMs + 300, function() e.G:incoming({ { ESB, tonumber(n) } }) end)
            e.F.at(e.F.now + walkMs + 400, function() e.F.mq.cmd('/lc_loaded Shela ' .. id .. ' 1 ' .. n) end)
        end
        if c:match('^/dex Shela /lc_accepted Antilerd %S+ 1$') then e.F.at(e.F.now + 100, function() e.G:partner_accepts() end) end
    end)
    return function() return asks end
end

test('handoff: the crafter stays put, asks the worker to come, waits on its word, takes the trade', function()
    local e = handoff_env('crafter')
    e.G:bag(1, 'Backpack', 10)
    scripted_worker(e, 45000)   -- a long walk: kept alive by its updates
    e.runner:add(e.h:fetch_job('Shela', ESB, 25)); e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.why) .. ' ' .. tostring(e.runner.last.detail))
    eq(e.G:count(ESB), 25)
    eq(sent(e, '^/nav'), 0, 'the crafter did not move')
    eq(sent(e, '^/dex Shela /lc_come Antilerd %S+ 25 Enchanted_Silver_Bar freeporttemple %S+ %S+ %S+$'), 1, 'told where to come')
    eq(sent(e, '^/dex Shela /lc_got Antilerd %S+ 1 25$'), 1, 'told her it arrived')
    truthy(e.log.has('Shela is coming: freeporttemple %(walking%)'), 'progress logged')
    truthy(e.log.has('Shela is here after 45'), 'arrival logged')
end)

test('handoff: a worker that fails is asked once more; one that goes quiet is not', function()
    local e = handoff_env('crafter')
    e.G:bag(1, 'Backpack', 10)
    local asks = scripted_worker(e, 2000, { failFirst = true })
    e.runner:add(e.h:fetch_job('Shela', ESB, 5)); e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.detail)); eq(asks(), 2); eq(e.G:count(ESB), 5)
    truthy(e.log.has('trying once more'), 'retry logged')
    local e2 = handoff_env('crafter')
    e2.G:bag(1, 'Backpack', 10)
    local asks2 = scripted_worker(e2, 2000, { silent = true })
    e2.runner:add(e2.h:fetch_job('Shela', ESB, 5)); e2.runner:step()
    eq(e2.runner.last.why, 'quiet'); eq(asks2(), 1)
    truthy(tostring(e2.runner.last.detail):find('never answered', 1, true), tostring(e2.runner.last.detail))
end)

-- a crafter played by the script: accepts each loaded trade and confirms it
local function scripted_crafter(e)
    e.script(function(c)
        local id, k, u = c:match('^/dex Antilerd /lc_loaded Shela (%S+) (%d+) (%d+)$')
        if id then
            e.F.mq.cmd(string.format('/lc_accepted Antilerd %s %s', id, k))
            e.G:partner_accepts()
            e.F.at(e.F.now + 50, function() e.F.mq.cmd(string.format('/lc_got Antilerd %s %s %s', id, k, u)) end)
        end
    end)
end

test('handoff: the worker walks to its crafter, says arrived, gives; ignores anyone else', function()
    local e = handoff_env('worker')
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, ESB, 100)
    local cid = e.G:spawn('Antilerd', 60, 0, 0, { class = 'PC' })
    scripted_crafter(e)
    e.F.mq.cmd('/lc_come Zed z-1 5 Enchanted_Silver_Bar freeporttemple')
    e.F.mq.cmd('/lc_come Antilerd a-1 25 Enchanted_Silver_Bar freeporttemple')
    e.F.mq.doevents()
    truthy(e.log.has('works for Antilerd %- ignored'), 'Zed ignored')
    eq(sent(e, '^/dex Antilerd /lc_coming Shela a%-1 freeporttemple queued$'), 1, 'answered at once')
    e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.detail)); eq(e.G:count(ESB), 75)
    truthy(e.G:dist(e.G.spawns[cid]) <= Handoff.NAV_DIST + 3, 'walked to the crafter')
    eq(sent(e, '^/dex Antilerd /lc_coming Shela a%-1 freeporttemple walking$'), 1)
    eq(sent(e, '^/dex Antilerd /lc_arrived Shela a%-1$'), 1)
end)

test('handoff: a far crafter (no nav path to its spawn) is reached by the spot it said it stands on', function()
    local e = handoff_env('worker')
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, ESB, 100)
    local cid = e.G:spawn('Antilerd', 400, 200, 0, { class = 'PC' })
    e.G.noPath[cid] = true   -- as seen in game: /nav id to a character 427 away has no path
    scripted_crafter(e)
    e.F.mq.cmd('/lc_come Antilerd a-1 25 Enchanted_Silver_Bar freeporttemple 200.00 400.00 0.00'); e.F.mq.doevents()
    e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.detail)); eq(e.G:count(ESB), 75)
    eq(sent(e, '^/nav loc 200%.00 400%.00 0%.00 distance=10$'), 1, 'walked to the spot')
end)

test('handoff: the worker travels to the crafter\'s zone, keeps saying where it is, and gives there', function()
    local e = handoff_env('worker')
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, ESB, 100)
    e.G.zoneMs = 25000
    e.G.zoneDefs.poknowledge = function(g) g:spawn('Antilerd', 5, 0, 0, { class = 'PC' }) end
    scripted_crafter(e)
    e.F.mq.cmd('/lc_come Antilerd a-1 10 Enchanted_Silver_Bar poknowledge'); e.F.mq.doevents()
    e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.detail)); eq(e.G.zone, 'poknowledge'); eq(e.G:count(ESB), 90)
    truthy(sent(e, '^/dex Antilerd /lc_coming Shela a%-1 %S+ travelling$') >= 3, 'updates while travelling')
end)

test('handoff: the crafter in the AFK mirror (same short name) - the worker goes in first; the other way round it comes out first', function()
    -- 2.41.1 log: Antilerd walked to Mortician's spot in Marr while Mortician stood in Marr's mirror, "not in freeporttemple"
    local e = handoff_env('worker')
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, ESB, 100)
    local inMirror, entered = false, 0
    e.travel.in_mirror = function() return inMirror end
    e.travel.enter_mirror = function() entered = entered + 1; inMirror = true; return R.ok() end
    e.G:spawn('Antilerd', 5, 0, 0, { class = 'PC' })
    scripted_crafter(e)
    e.F.mq.cmd('/lc_come Antilerd a-1 10 Enchanted_Silver_Bar freeporttemple 0.00 5.00 0.00 mirror'); e.F.mq.doevents()
    e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.detail)); eq(entered, 1); eq(e.G:count(ESB), 90)
    truthy(e.log.has('Antilerd is in the AFK mirror of freeporttemple %- going in'), 'said')
    -- in the mirror ourselves, the crafter in the zone itself: out through the Exit Portal first
    local left = 0
    e.travel.leave_mirror = function() left = left + 1; inMirror = false; return R.ok() end
    e.F.mq.cmd('/lc_come Antilerd a-2 10 Enchanted_Silver_Bar freeporttemple 0.00 5.00 0.00 main'); e.F.mq.doevents()
    e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.detail)); eq(left, 1); eq(e.G:count(ESB), 80)
    truthy(e.log.has('Antilerd is in freeporttemple itself, not its AFK mirror %- going out'), 'said')
    -- an older crafter (no place): as before
    e.F.mq.cmd('/lc_come Antilerd a-3 10 Enchanted_Silver_Bar freeporttemple 0.00 5.00 0.00'); e.F.mq.doevents()
    e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.detail)); eq(e.G:count(ESB), 70); eq(left, 1); eq(entered, 1)
end)

test('travel: the AFK mirror is known by its Exit Portal NPC (same short name), or by having gone in', function()
    local e = block_env()
    local T = require('blocks.travel').new({ mq = e.F.mq, nav = e.nav, spawns = e.spawns, travel = { mirror = {}, arrive = {} }, log = e.log })
    truthy(not T:in_mirror())
    e.G:spawn('Exit Portal', 10, 10, 0, { notNpc = true })
    truthy(T:in_mirror()); truthy(T:where():find('AFK mirror', 1, true))
end)

test('travel: out of the AFK mirror by walking into its Exit Portal - confirmed by the zoning, then not in the mirror', function()
    local e = block_env()
    e.G.zoneKey = 'freeporttemple#afk'
    e.G:spawn('Exit Portal', 20, 0, 0, { portTo = 'freeporttemple', notNpc = true })
    local T = require('blocks.travel').new({ mq = e.F.mq, nav = e.nav, spawns = e.spawns, travel = { mirror = {}, arrive = {} }, log = e.log })
    truthy(T:in_mirror())
    local r = e.run(function(ctx) return T:leave_mirror(ctx) end)
    truthy(r.ok, R.describe(r))
    eq(e.G.zoneKey, 'freeporttemple'); truthy(not T:in_mirror())
    truthy(e.log.has('Travel: out of the AFK mirror, in freeporttemple'), 'said')
    -- not in the mirror: nothing to do
    r = e.run(function(ctx) return T:leave_mirror(ctx) end)
    truthy(r.ok)
end)

test('handoff: a worker with no way there, or out of the item, says why', function()
    local e = handoff_env('worker')
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, ESB, 10)
    e.G:spawn('Antilerd', 5, 0, 0, { class = 'PC' })
    scripted_crafter(e)
    e.F.mq.cmd('/lc_come Antilerd a-1 5 Enchanted_Silver_Bar abysmal'); e.F.mq.doevents(); e.runner:step()
    eq(e.runner.last.why, 'no way there')
    eq(sent(e, '^/dex Antilerd /lc_failed Shela a%-1 '), 1, 'crafter told')
    e.F.mq.cmd('/lc_come Antilerd a-2 500 Enchanted_Silver_Bar freeporttemple'); e.F.mq.doevents(); e.runner:step()
    eq(e.runner.last.why, 'ran out')
    eq(sent(e, '^/dex Antilerd /lc_failed Shela a%-2 '), 1, 'crafter told')
end)

test('handoff order: the crafter asks, logs the answer and the work, then fetches what was made', function()
    local e = handoff_env('crafter')
    e.G:bag(1, 'Backpack', 10)
    local fetchAsks = scripted_worker(e, 1000)
    e.script(function(c)
        local id, n = c:match('^/dex Shela /lc_ask Antilerd (%S+) (%d+) Enchanted_Silver_Bar$')
        if id then
            e.F.mq.cmd('/lc_answer Shela ' .. id .. ' yes buy_100,_1_cast_of_Superior_Mass_Enchant_Silver')
            for t = 5000, 55000, 5000 do
                e.F.at(e.F.now + t, function() e.F.mq.cmd('/lc_working Shela ' .. id .. ' Casting_' .. math.floor(t / 20000)) end)
            end
            e.F.at(e.F.now + 60000, function() e.F.mq.cmd('/lc_made Shela ' .. id .. ' 100') end)
        end
    end)
    e.runner:add(e.h:order_job('Shela', ESB, 25)); e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.why) .. ' ' .. tostring(e.runner.last.detail))
    eq(e.G:count(ESB), 25); eq(fetchAsks(), 1)
    truthy(e.log.has('Shela will get it: buy 100, 1 cast of Superior Mass Enchant Silver'), 'answer logged')
    truthy(e.log.has('Shela: Casting 2'), 'work logged')
    truthy(e.log.has('Shela has 100 Enchanted Silver Bar %(60'), 'made logged')
end)

test('handoff: a worker serving two crafters counts only what is not held for the other (2.44.0)', function()
    local e = handoff_env('worker')
    e.h.serves_fn = function(n) return n == 'Antilerd' or n == 'Zed' end
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, ESB, 100)
    e.h.makeEnv = { blocks = { inventory = e.inv } }
    e.h:hold('Antilerd', ESB, 100)   -- summoned for Antilerd, not given yet
    eq(e.h:reserved(ESB, 'Zed'), 100); eq(e.h:reserved(ESB, 'Antilerd'), 0)
    e.F.mq.cmd('/lc_summon Zed z-1 60 Enchanted_Silver_Bar'); e.F.mq.doevents()
    truthy(e.log.has('100 Enchanted Silver Bar held for other crafters %- not counted for Zed'), 'said')
    truthy(e.log.has('0 held already, 60 to cast'), 'none of Antilerd\'s counted for Zed')
    e.F.mq.cmd('/lc_summon Antilerd a-1 60 Enchanted_Silver_Bar'); e.F.mq.doevents()
    truthy(e.log.has('100 held already, 0 to cast'), 'Antilerd\'s own count')
    eq(e.h.holding['antilerd|' .. ESB:lower()], 100, 'not counted twice')
    -- a third crafter is not served
    e.F.mq.cmd('/lc_summon Tom t-1 5 Enchanted_Silver_Bar'); e.F.mq.doevents()
    truthy(e.log.has('Tom asked for Enchanted Silver Bar, but this worker works for'), 'not one of ours')
end)

test('handoff: a worker out of a safe zone takes no order, no summon and no come - it says why (2.43.9)', function()
    local e = handoff_env('worker')
    e.h.makeEnv = { cfg = { travel = { safe = { freeporttemple = true, poknowledge = true } } } }
    e.G.zone = 'sebilis'
    e.F.mq.cmd('/lc_ask Antilerd o-1 1 Frying_Pan_Mold'); e.F.mq.doevents()
    e.F.mq.cmd('/lc_summon Antilerd o-2 100 Enchanted_Silver_Bar'); e.F.mq.doevents()
    e.F.mq.cmd('/lc_come Antilerd o-3 5 Enchanted_Silver_Bar freeporttemple'); e.F.mq.doevents()
    eq(#e.runner.queue, 0, 'nothing queued'); eq(e.runner.active, nil)
    eq(sent(e, '^/dex Antilerd /lc_answer Shela o%-1 no in_sebilisXCOMX_not_a_safe_zone$'), 1, 'order refused, said')
    eq(sent(e, '^/dex Antilerd /lc_answer Shela o%-2 no '), 1, 'summon refused')
    eq(sent(e, '^/dex Antilerd /lc_failed Shela o%-3 '), 1, 'come refused')
    truthy(e.log.has('not a safe zone'), 'logged')
end)

test('handoff order: a no ends it with the reason; silence ends it as quiet', function()
    local e = handoff_env('crafter')
    e.script(function(c)
        local id = c:match('^/dex Shela /lc_ask Antilerd (%S+) ')
        if id then e.F.mq.cmd('/lc_answer Shela ' .. id .. ' no Silver_Bar:_sold_only_where_travel.ini_cannot_reach') end
    end)
    e.runner:add(e.h:order_job('Shela', ESB, 25)); e.runner:step()
    eq(e.runner.last.why, 'declined'); truthy(e.runner.last.detail:find('cannot reach', 1, true), e.runner.last.detail)
    local e2 = handoff_env('crafter')
    e2.runner:add(e2.h:order_job('Shela', ESB, 25)); e2.runner:step()
    eq(e2.runner.last.why, 'quiet')
end)

test('handoff order: the worker plans, says yes with how, says what it is doing, makes it, says made', function()
    local e = handoff_env('worker')
    e.G:bag(1, 'Backpack', 20)
    e.G:spawn('Mirao Frostpouch', 5, 0, 0, { sells = { 'Silver Bar' } })
    e.G.book['superior mass enchant silver'] = true
    e.G.produce['superior mass enchant silver'] = { product = ESB, yield = 100, reagents = { { 'Silver Bar', 100 } } }
    e.G.stackSize = 1000
    local cfg = Config.load(ROOT .. 'data/')
    cfg.merchants = Config.parse_merchants(Ini.parse('[Mirao Frostpouch##freeporttemple]\n_Zone=freeporttemple\nSilver Bar=1\n'))
    package.loaded['blocks.cast'] = nil; package.loaded['blocks.kitslot'] = nil; package.loaded['blocks.travel'] = nil
    local blocks = { inventory = e.inv, windows = e.win, cursor = e.cur, spawns = e.spawns, nav = e.nav, merchant = e.merchant,
        bank = e.bank, kit = e.kit, station = e.station, travel = { zone = function() return e.G.zone or 'freeporttemple' end } }
    blocks.cast = require('blocks.cast').new({ mq = e.F.mq, nav = e.nav, inventory = e.inv, cursor = e.cur, log = e.log })
    blocks.kitslot = require('blocks.kitslot').new({ mq = e.F.mq, cursor = e.cur, windows = e.win, log = e.log,
        isKit = function() return false end, tsOnly = function() return false end })
    local planner = Planner.new(cfg)
    e.h.make = require('engine.make')
    e.h.makeEnv = { blocks = blocks, planner = planner, cfg = cfg, log = e.log, mq = e.F.mq, describe = Planner.describe,
        world = function()
            return { zone = 'freeporttemple', bags = function(i) return e.inv:count(i) end, bank = function() return 0 end,
                     canCast = function(s) return blocks.cast:has(s) end, kit = function() return false end }
        end }
    e.F.mq.cmd('/lc_ask Antilerd o-1 25 Enchanted_Silver_Bar'); e.F.mq.doevents()
    e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.why) .. ' ' .. tostring(e.runner.last.detail))
    eq(e.G:count(ESB), 100)
    local said = {}; for _, c in ipairs(e.G.log) do if c:find('lc_', 1, true) then said[#said + 1] = c end end
    eq(sent(e, '^/dex Antilerd /lc_answer Shela o%-1 yes buy_100XCOMX_1_cast_of_Superior_Mass_Enchant_Silver$'), 1, 'yes with how: ' .. table.concat(said, ' | '))
    truthy(sent(e, '^/dex Antilerd /lc_working Shela o%-1 Casting_Superior_Mass_Enchant_Silver') >= 1, 'said it was casting')
    eq(sent(e, '^/dex Antilerd /lc_made Shela o%-1 100$'), 1, 'made')
    e.F.mq.cmd('/lc_ask Antilerd o-2 5 Blue_Diamond'); e.F.mq.doevents(); e.runner:step()
    eq(e.runner.last.why, 'cannot get it')
    eq(sent(e, '^/dex Antilerd /lc_answer Shela o%-2 no '), 1, 'no with why')
    eq(sent(e, '^/dex Antilerd /lc_failed Shela o%-2 '), 0, 'a no is the whole answer')
end)

test('handoff order: orders queued together are bought in one trip (the first plans the others too)', function()
    -- 2.42.4 log: Antilerd went to Felwithe for 1228 Large Brick of Mithril, came back, went again for 2457 Small Brick
    local e = handoff_env('worker')
    e.G:bag(1, 'Backpack', 20)
    e.G.coin = { pp = 100000, gp = 0, sp = 0, cp = 0 }
    e.G.zoneDefs.abysmal = function(g) g:spawn('Opal Leganyn', 10, 10, 0, { sells = { 'Large Brick of Mithril', 'Small Brick of Mithril' } }) end
    local cfg = Config.load(ROOT .. 'data/')
    cfg.merchants = Config.parse_merchants(Ini.parse('[Opal Leganyn##abysmal]\n_Zone=abysmal\nLarge Brick of Mithril=1\nSmall Brick of Mithril=1\n'))
    local zones = {}
    local travel = {
        zone = function() return e.G.zone or 'freeporttemple' end,
        go = function(_, ctx, to)
            zones[#zones + 1] = to
            e.G:start_zone(to)
            local w = ctx:wait(60000, function() return e.G.gameState == 'INGAME' and e.G.zone == to and e.G.meshLoaded end)
            if not w.ok and w.why ~= 'timeout' then return w end
            return w.ok and R.ok({ hops = 1 }) or R.fail('zone', 'did not zone')
        end,
    }
    local blocks = { inventory = e.inv, windows = e.win, cursor = e.cur, spawns = e.spawns, nav = e.nav, merchant = e.merchant,
        bank = e.bank, kit = e.kit, station = e.station, travel = travel, kitslot = { restore = function() return R.ok() end } }
    e.h.make = require('engine.make')
    e.h.makeEnv = { blocks = blocks, planner = Planner.new(cfg), cfg = cfg, log = e.log, mq = e.F.mq, describe = Planner.describe,
        describe_money = Planner.money,
        world = function()
            return { zone = e.G.zone or 'freeporttemple', bags = function(i) return e.inv:count(i) end, bank = function() return 0 end,
                     canCast = function() return false end, kit = function() return false end }
        end }
    e.F.mq.cmd('/lc_ask Antilerd o-1 30 Large_Brick_of_Mithril'); e.F.mq.cmd('/lc_ask Antilerd o-2 50 Small_Brick_of_Mithril')
    e.F.mq.doevents()
    e.runner:step(); truthy(e.runner.last.ok, R.describe(e.runner.last))
    e.runner:step(); truthy(e.runner.last.ok, R.describe(e.runner.last))
    eq(table.concat(zones, ','), 'abysmal', 'one trip')
    eq(e.G:count('Large Brick of Mithril'), 30); eq(e.G:count('Small Brick of Mithril'), 50)
    eq(sent(e, '^/dex Antilerd /lc_made Shela o%-1 30$'), 1); eq(sent(e, '^/dex Antilerd /lc_made Shela o%-2 50$'), 1)
    truthy(e.log.has('One trip: planning 30 Large Brick of Mithril with the order queued behind it %(50 Small Brick of Mithril%)'), 'said')
end)

-- A worker who can cast Mass Enchant Silver (5 a cast) and buy Silver Bar here, for summon orders.
local function summon_worker_env(opts)
    opts = opts or {}
    local e = handoff_env('worker')
    e.G:bag(1, 'Backpack', opts.slots or 20)
    e.G:spawn('Mirao Frostpouch', 5, 0, 0, { sells = { 'Silver Bar' } })
    e.G.book['mass enchant silver'] = true
    e.G.produce['mass enchant silver'] = { product = ESB, yield = 5, reagents = { { 'Silver Bar', 5 } } }
    e.G.noStack = opts.noStack
    local cfg = Config.load(ROOT .. 'data/')
    cfg.merchants = Config.parse_merchants(Ini.parse('[Mirao Frostpouch##freeporttemple]\n_Zone=freeporttemple\nSilver Bar=1\n'))
    package.loaded['blocks.cast'] = nil; package.loaded['blocks.kitslot'] = nil
    local blocks = { inventory = e.inv, windows = e.win, cursor = e.cur, spawns = e.spawns, nav = e.nav, merchant = e.merchant,
        bank = e.bank, kit = e.kit, station = e.station, travel = { zone = function() return e.G.zone or 'freeporttemple' end } }
    blocks.cast = require('blocks.cast').new({ mq = e.F.mq, nav = e.nav, inventory = e.inv, cursor = e.cur, log = e.log })
    blocks.kitslot = require('blocks.kitslot').new({ mq = e.F.mq, cursor = e.cur, windows = e.win, log = e.log,
        isKit = function() return false end, tsOnly = function() return false end })
    e.h.make = require('engine.make')
    e.h.makeEnv = { blocks = blocks, planner = Planner.new(cfg), cfg = cfg, log = e.log, mq = e.F.mq, describe = Planner.describe,
        describe_money = Planner.money,
        stacks = { size = function(_, i) return (opts.noStack or {})[i:lower()] and 1 or 1000 end },
        world = function()
            return { zone = 'freeporttemple', bags = function(i) return e.inv:count(i) end, bank = function() return 0 end,
                     canCast = function(sp) return blocks.cast:has(sp) end, kit = function() return false end }
        end }
    return e
end

test('summon order (worker): cast round by round; something queued mid-way goes first, then it carries on; made at the end', function()
    local e = summon_worker_env()
    local order = {}
    local added
    e.F.ticks[#e.F.ticks + 1] = function()
        if not added and e.log.has('Cast: Mass Enchant Silver 1/') then
            added = true
            e.runner:add({ name = 'A delivery', execute = function() order[#order + 1] = 'delivery at ' .. e.G:count(ESB); return R.ok() end })
        end
    end
    e.F.mq.cmd('/lc_summon Antilerd s-1 15 Enchanted_Silver_Bar'); e.F.mq.doevents()
    for _ = 1, 6 do if e.runner.active or #e.runner.queue > 0 then e.runner:step() end end
    eq(e.G:count(ESB), 15)
    eq(order[1], 'delivery at 5', 'the delivery went right after the cast in progress')
    truthy(e.log.has('something else is queued, it goes first'), 'said')
    eq(sent(e, '^/dex Antilerd /lc_answer Shela s%-1 yes '), 1, 'yes once')
    truthy(sent(e, '^/dex Antilerd /lc_working Shela s%-1 %S+ %d+$') >= 1, 'progress with its count')
    eq(sent(e, '^/dex Antilerd /lc_made Shela s%-1 15$'), 1, 'made at the end')
    eq(sent(e, '/lc_failed'), 0)
end)

test('summon order (worker): what it already holds counts - only the rest is cast', function()
    local e = summon_worker_env()
    e.G:put(1, 1, ESB, 10)
    e.F.mq.cmd('/lc_summon Antilerd s-1 15 Enchanted_Silver_Bar'); e.F.mq.doevents()
    for _ = 1, 3 do if e.runner.active or #e.runner.queue > 0 then e.runner:step() end end
    eq(e.G:count(ESB), 15, '10 held + 1 cast of 5')
    truthy(e.log.has('10 held already, 5 to cast'), 'said')
    eq(sent(e, '^/dex Antilerd /lc_made Shela s%-1 15$'), 1)
    -- holding it all: nothing cast
    local e2 = summon_worker_env()
    e2.G:put(1, 1, ESB, 20)
    e2.F.mq.cmd('/lc_summon Antilerd s-2 15 Enchanted_Silver_Bar'); e2.F.mq.doevents()
    for _ = 1, 3 do if e2.runner.active or #e2.runner.queue > 0 then e2.runner:step() end end
    eq(e2.G:count(ESB), 20); eq(sent(e2, '/cast'), 0)
    eq(sent(e2, '^/dex Antilerd /lc_made Shela s%-2 20$'), 1, 'made at once')
end)

test('summon order (worker): two summon orders do not step aside for each other - both are cast', function()
    -- 2.41.7 log: Ejtou's Rose Quartz and Amber orders stepped aside for each other 300+ times, nothing cast
    local e = summon_worker_env()
    e.F.mq.cmd('/lc_summon Antilerd s-1 5 Enchanted_Silver_Bar'); e.F.mq.doevents()
    e.F.mq.cmd('/lc_summon Antilerd s-2 10 Enchanted_Silver_Bar'); e.F.mq.doevents()
    for _ = 1, 6 do if e.runner.active or #e.runner.queue > 0 then e.runner:step() end end
    truthy(not e.log.has('something else is queued'), 'no stepping aside for a summon')
    eq(sent(e, '^/dex Antilerd /lc_made Shela s%-1 '), 1); eq(sent(e, '^/dex Antilerd /lc_made Shela s%-2 '), 1)
end)

test('summon order (worker): bags full - it waits, and carries on after a give frees room', function()
    local e = summon_worker_env({ slots = 10, noStack = { [ESB:lower()] = true } })
    for pk = 2, 10 do e.G:put(pk, nil, 'Rusty Dagger', 1) end   -- the other inventory slots taken: one bag of room
    e.F.mq.cmd('/lc_summon Antilerd s-1 15 Enchanted_Silver_Bar'); e.F.mq.doevents()
    e.runner:step()
    eq(e.G:count(ESB), 5)
    truthy(e.log.has('bags full, waiting until some are given'), 'parked')
    eq(#e.runner.queue, 0); eq(sent(e, '/lc_made'), 0); eq(sent(e, '/lc_failed'), 0)
    -- the crafter took them (a give): room again
    for _, pk in pairs(e.G.packs) do if pk.bag then for k, it in pairs(pk.items) do if it.name == ESB then pk.items[k] = nil end end end end
    e.h:unpark()
    for _ = 1, 4 do if e.runner.active or #e.runner.queue > 0 then e.runner:step() end end
    truthy(e.log.has('room in the bags again'), 'carried on')
    truthy(sent(e, '^/dex Antilerd /lc_made Shela s%-1 ') == 1 or e.log.has('bags full'), 'made, or waiting again for room')
end)

test('summon order (worker): called off while waiting in the queue - dropped, nothing more made', function()
    local e = summon_worker_env()
    e.runner:add({ name = 'Busy', execute = function(ctx) ctx:wait(3000, function() return false end); return R.ok() end })
    e.F.mq.cmd('/lc_summon Antilerd s-1 15 Enchanted_Silver_Bar'); e.F.mq.doevents()
    e.F.mq.cmd('/lc_failed Antilerd s-1 crafter_done'); e.F.mq.doevents()
    for _ = 1, 3 do if e.runner.active or #e.runner.queue > 0 then e.runner:step() end end
    eq(e.G:count(ESB), 0)
    eq(sent(e, '/lc_made'), 0)
end)

test('summon order (crafter): a pass waits only until the worker holds what it needs, then takes it; the rest is called off at the end', function()
    local e = handoff_env('crafter')
    e.G:bag(1, 'Backpack', 10)
    local fetches = scripted_worker(e, 1000)
    e.script(function(c)
        local id = c:match('^/dex Shela /lc_summon Antilerd (%S+) 10 Enchanted_Silver_Bar$')
        if id then
            e.F.mq.cmd('/lc_answer Shela ' .. id .. ' yes buy_10')
            for i, t in ipairs({ 3000, 8000, 13000 }) do
                e.F.at(e.F.now + t, function() e.F.mq.cmd('/lc_working Shela ' .. id .. ' Casting ' .. (i * 3)) end)
            end
        end
    end)
    local st, took, at = {}, nil, nil
    local t0 = e.F.now
    e.runner:add({ name = 'pass', execute = function(ctx)
        e.h:place_summon('Shela', ESB, 10)
        local s = e.h:summon_for('Shela', ESB)
        local f = e.h:take_summoned(ctx, s, 'Shela', ESB, 5, st)
        took, at = f.ok and f.value.taken, e.F.now
        return f
    end, cleanup = function() e.h:end_summons('crafter done'); return R.ok() end })
    e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.why) .. ' ' .. tostring(e.runner.last.detail))
    eq(took, 5); eq(fetches(), 1); eq(e.G:count(ESB), 5)
    truthy(at - t0 >= 8000, 'waited for 6 made (it needed 5)')
    truthy(e.log.has('Waiting on Shela: 0 Enchanted Silver Bar made so far, this pass needs 5'), 'said')
    eq(sent(e, '^/dex Shela /lc_failed Antilerd %S+ crafter_done$'), 1, 'the rest called off')
end)

test('summon order (crafter): the worker gives up with fewer than the pass needs - "summon short" (the pass orders them instead)', function()
    local e = handoff_env('crafter')
    e.script(function(c)
        local id = c:match('^/dex Shela /lc_summon Antilerd (%S+) ')
        if id then
            e.F.at(e.F.now + 2000, function() e.F.mq.cmd('/lc_working Shela ' .. id .. ' Casting 2') end)
            e.F.at(e.F.now + 4000, function() e.F.mq.cmd('/lc_failed Shela ' .. id .. ' not_enough_money') end)
        end
    end)
    local res
    e.runner:add({ name = 'pass', execute = function(ctx)
        e.h:place_summon('Shela', ESB, 10)
        res = e.h:take_summoned(ctx, e.h.summons['shela|' .. ESB:lower()], 'Shela', ESB, 5, {})
        return R.ok()
    end })
    e.runner:step()
    eq(res.why, 'summon short'); truthy(res.detail:find('holds 2', 1, true) and res.detail:find('not enough money', 1, true), res.detail)
    eq(e.h:summon_for('Shela', ESB), nil, 'no longer used')
end)

test('summon order (crafter): items taken from the worker by an order of their own come off its held count; made sets it', function()
    -- 2.42.13 Lopan log: pass 1 ordered 128 Rose Quartz on its own (summon short) and took them from Ejtou's 130;
    -- the summon order still said 125 held, pass 2 asked for 19 and Ejtou had 2
    local e = handoff_env('crafter')
    e.G:bag(1, 'Backpack', 10)
    scripted_worker(e, 1000)
    local s
    e.runner:add({ name = 'pass', execute = function(ctx)
        e.h:place_summon('Shela', ESB, 30)
        s = e.h:summon_for('Shela', ESB)
        s.r.have = 25
        return e.h:fetch(ctx, 'Shela', ESB, 20, {})
    end })
    e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.detail))
    eq(s.r.have, 5, '25 held - 20 taken by the other order')
    e.F.mq.cmd('/lc_made Shela ' .. s.id .. ' 2'); e.F.mq.doevents()
    eq(s.r.have, 2, 'the worker said what it holds at the end')
end)

test('order ahead: summoned items of every row ordered at Go, per worker and item, in row order; held ones and supply orders not', function()
    local placed = {}
    local h = { summons = {}, place_summon = function(_, w, item, n) placed[#placed + 1] = w .. ':' .. item .. ':' .. n end,
                summon_for = function(_, w, item) return (w == 'Kai' and item == 'Imbued Amber') and {} or nil end }
    local plans = {
        A = { orders = { { worker = 'Shela', item = 'Vial of Clear Mana', n = 10 }, { worker = 'Kai', item = 'Imbued Amber', n = 10 },
                         { worker = 'Tom', item = 'Fruit', n = 3, supply = true } } },
        B = { orders = { { worker = 'Shela', item = 'Large Block of Magic Clay', n = 7 }, { worker = 'Shela', item = 'Vial of Clear Mana', n = 7 } } },
    }
    local env = { handoff = h, log = { info = function() end }, world = function() return {} end,
                  planner = { plan = function(_, id) return plans[id] end } }
    require('engine.make').order_ahead(env, { { recipe = { id = 'A' }, n = 10 }, { recipe = { id = 'B' }, n = 7 }, { recipe = { id = 'B' }, n = 0 } })
    eq(table.concat(placed, ' | '), 'Shela:Vial of Clear Mana:17 | Shela:Large Block of Magic Clay:7')
end)

test('make with a worker: the order goes out at Go, we carry on, then collect before the step that needs it', function()
    local e = handoff_env('crafter')
    e.G:bag(1, 'Backpack', 10)
    local fetches = scripted_worker(e, 1000)
    local askedAt
    e.script(function(c)
        local id = c:match('^/dex Shela /lc_ask Antilerd (%S+) 3 Enchanted_Silver_Bar$')
        if id then
            askedAt = e.F.now
            e.F.mq.cmd('/lc_answer Shela ' .. id .. ' yes buy_100XCOMX_1_cast')
            for t = 8000, 32000, 8000 do e.F.at(e.F.now + t, function() e.F.mq.cmd('/lc_working Shela ' .. id .. ' Casting') end) end
            e.F.at(e.F.now + 35000, function() e.F.mq.cmd('/lc_made Shela ' .. id .. ' 100') end)
        end
    end)
    local cfg = Config.load(ROOT .. 'data/')
    local blocks = { inventory = e.inv, windows = e.win, cursor = e.cur, spawns = e.spawns, nav = e.nav, merchant = e.merchant,
        bank = e.bank, kit = e.kit, station = e.station, travel = { zone = function() return 'freeporttemple' end },
        kitslot = { restore = function() return R.ok() end } }
    local job = require('engine.make').get_job({ blocks = blocks, planner = Planner.new(cfg), cfg = cfg, log = e.log, mq = e.F.mq,
        describe = Planner.describe, handoff = e.h,
        world = function()
            return { zone = 'freeporttemple', bags = function(i) return e.inv:count(i) end, bank = function() return 0 end,
                     canCast = function() return false end, kit = function() return false end,
                     worker = function(i) return i == ESB and 'Shela' or nil end }
        end }, ESB, 3)
    e.runner:add(job); e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.why) .. ' ' .. tostring(e.runner.last.detail))
    eq(e.G:count(ESB), 3); eq(fetches(), 1); truthy(askedAt ~= nil, 'asked')
    truthy(e.log.has('Shela has 100 Enchanted Silver Bar %(35'), 'collected after made')
end)

test('make with a worker: everything it brings this pass comes in one visit (taken together at the first step)', function()
    -- 2.40.2 log: Shela walked over twice in one pass, 30s apart, to two stations
    local e = handoff_env('crafter')
    e.G:bag(1, 'Backpack', 10)
    local comes = {}
    e.script(function(c)
        local id, n, item = c:match('^/dex Shela /lc_ask Antilerd (%S+) (%d+) (%S+)$')
        if id then
            e.F.mq.cmd('/lc_answer Shela ' .. id .. ' yes x')
            e.F.at(e.F.now + 2000, function() e.F.mq.cmd('/lc_made Shela ' .. id .. ' ' .. n) end)
        end
        local cid, cn, citem = c:match('^/dex Shela /lc_come Antilerd (%S+) (%d+) (%S+) ')
        if cid then
            comes[#comes + 1] = citem
            e.F.at(e.F.now + 500, function() e.F.mq.cmd('/lc_arrived Shela ' .. cid) end)
            e.F.at(e.F.now + 800, function() e.G:incoming({ { citem:gsub('_', ' '), tonumber(cn) } }) end)
            e.F.at(e.F.now + 900, function() e.F.mq.cmd('/lc_loaded Shela ' .. cid .. ' 1 ' .. cn) end)
        end
        if c:match('^/dex Shela /lc_accepted Antilerd %S+ 1$') then e.F.at(e.F.now + 100, function() e.G:partner_accepts() end) end
    end)
    local cfg = Config.load(ROOT .. 'data/')
    local rec = { id = 'T1', name = 'Test Bowl', label = 'Test Bowl', container = "Jeweler's Kit", yield = 1, tools = {},
                  ins = { { name = ESB, n = 2 }, { name = 'Large Block of Magic Clay', n = 3 } } }
    cfg.recipes.T1 = rec
    local blocks = { inventory = e.inv, windows = e.win, cursor = e.cur, spawns = e.spawns, nav = e.nav, merchant = e.merchant,
        bank = e.bank, kit = e.kit, station = e.station, travel = { zone = function() return 'freeporttemple' end },
        kitslot = { restore = function() return R.ok() end } }
    local job = require('engine.make').job({ blocks = blocks, planner = Planner.new(cfg), cfg = cfg, log = e.log, mq = e.F.mq,
        describe = Planner.describe, handoff = e.h, describe_money = Planner.money,
        world = function()
            return { zone = 'freeporttemple', bags = function(i) return e.inv:count(i) end, bank = function() return 0 end,
                     canCast = function() return false end, kit = function() return true end,
                     worker = function(i) return (i == ESB or i == 'Large Block of Magic Clay') and 'Shela' or nil end }
        end }, rec, 1, { noAhead = true })
    job.confirm = false
    e.runner:add(job); e.runner:step()
    eq(#comes, 2, 'both fetched')
    eq(e.G:count(ESB), 2); eq(e.G:count('Large Block of Magic Clay'), 3)
    truthy(e.log.has('Shela is here %- taking the 3 Large Block of Magic Clay for a later step now too')
        or e.log.has('Shela is here %- taking the 2 Enchanted Silver Bar for a later step now too'), 'the second in the same visit')
end)

test('faction: our faction too low - a worker buys it; one too low there too is saved, and the next is sent', function()
    local e = handoff_env('crafter')
    e.G:bag(1, 'Backpack', 10)
    package.loaded['core.factions'] = nil
    local factions = require('core.factions').new({})
    factions:set('Antilerd', 'Talem Tucter', 'thurgadina', 'dubiously')
    local asked, comes = {}, 0
    e.script(function(c)
        local who, id, n = c:match('^/dex (%S+) /lc_ask Antilerd (%S+) (%d+) Velium_Bar$')
        if who then
            asked[#asked + 1] = who
            e.F.mq.cmd('/lc_answer ' .. who .. ' ' .. id .. ' yes buy_' .. n)
            if who == 'Shela' then
                -- what a worker's own run says when its plan, made again, finds its faction too low as well
                e.F.at(e.F.now + 1000, function() e.F.mq.cmd('/lc_failed Shela ' .. id .. ' ' .. require('blocks.peers').encode(
                    'failed: cannot get it (Velium Bar: short 2 - sold only by merchants your faction is too low with: Talem Tucter (thurgadina) dubiously (apprehensively or better buys); bags 0, bank 0)')) end)
            else
                e.F.at(e.F.now + 2000, function() e.F.mq.cmd('/lc_made ' .. who .. ' ' .. id .. ' ' .. n) end)
            end
        end
        local cwho, cid, cn = c:match('^/dex (%S+) /lc_come Antilerd (%S+) (%d+) Velium_Bar ')
        if cwho then
            comes = comes + 1
            e.F.at(e.F.now + 500, function() e.F.mq.cmd('/lc_arrived ' .. cwho .. ' ' .. cid) end)
            e.F.at(e.F.now + 800, function() e.G:incoming({ { 'Velium Bar', tonumber(cn) } }) end)
            e.F.at(e.F.now + 900, function() e.F.mq.cmd('/lc_loaded ' .. cwho .. ' ' .. cid .. ' 1 ' .. cn) end)
        end
        if c:match('^/dex %S+ /lc_accepted Antilerd %S+ 1$') then e.F.at(e.F.now + 100, function() e.G:partner_accepts() end) end
    end)
    local cfg = Config.load(ROOT .. 'data/')
    local blocks = { inventory = e.inv, windows = e.win, cursor = e.cur, spawns = e.spawns, nav = e.nav, merchant = e.merchant,
        bank = e.bank, kit = e.kit, station = e.station, travel = { zone = function() return 'freeporttemple' end },
        kitslot = { restore = function() return R.ok() end } }
    local crew = { board = {}, start_worker = function() end, card_since = function() return true end,
                   running = function() return true end, can_make = function() return true end }
    local env = { blocks = blocks, planner = Planner.new(cfg), cfg = cfg, log = e.log, mq = e.F.mq, describe = Planner.describe,
        handoff = e.h, describe_money = Planner.money, crew = crew, factions = factions, me = 'Antilerd',
        world = function()
            return { zone = 'freeporttemple', bags = function(i) return e.inv:count(i) end, bank = function() return 0 end,
                     canCast = function() return false end, kit = function() return true end,
                     barred = function(npc, zone) return factions:barred('Antilerd', npc, zone) end,
                     buyer = function(item, vendors)
                         for _, n in ipairs({ 'Shela', 'Ejtou' }) do
                             for _, v in ipairs(vendors) do if not factions:barred(n, v.npc, v.zone) then return n, 'freeporttemple' end end
                         end
                     end }
        end }
    local plan = env.planner:plan_item('Velium Bar', 2, env.world())
    local lines = {}; for _, l in ipairs(Planner.describe(plan)) do lines[#lines + 1] = l.text end
    truthy(table.concat(lines, '\n'):find('Shela buys 2 and brings them (our faction there is too low)', 1, true), table.concat(lines, '\n'))
    e.runner:add(require('engine.make').get_job(env, 'Velium Bar', 2)); e.runner:step()
    truthy(e.runner.last.ok, R.describe(e.runner.last))
    eq(table.concat(asked, ','), 'Shela,Ejtou'); eq(comes, 1); eq(e.G:count('Velium Bar'), 2)
    eq(factions:barred('Shela', 'Talem Tucter', 'thurgadina'), 'dubiously', 'Shela saved as too low')
    truthy(e.log.has('Shela cannot buy it either'), 'said')
end)

test('make with a worker: stopping calls the order off', function()
    local e = handoff_env('crafter')
    local cfg = Config.load(ROOT .. 'data/')
    local blocks = { inventory = e.inv, windows = e.win, cursor = e.cur, spawns = e.spawns, nav = e.nav, merchant = e.merchant,
        bank = e.bank, kit = e.kit, station = e.station, travel = { zone = function() return 'freeporttemple' end },
        kitslot = { restore = function() return R.ok() end } }
    e.script(function(c)
        local id = c:match('^/dex Shela /lc_ask Antilerd (%S+) ')
        if id then
            e.F.mq.cmd('/lc_answer Shela ' .. id .. ' yes x')
            for t = 5000, 60000, 5000 do e.F.at(e.F.now + t, function() e.F.mq.cmd('/lc_working Shela ' .. id .. ' Casting') end) end
        end
    end)
    e.F.at(12000, function() e.runner:stop() end)
    local job = require('engine.make').get_job({ blocks = blocks, planner = Planner.new(cfg), cfg = cfg, log = e.log, mq = e.F.mq,
        describe = Planner.describe, handoff = e.h,
        world = function()
            return { zone = 'freeporttemple', bags = function() return 0 end, bank = function() return 0 end,
                     canCast = function() return false end, kit = function() return false end, worker = function() return 'Shela' end }
        end }, ESB, 3)
    e.runner:add(job); e.runner:step()
    eq(e.runner.last.why, 'stopped')
    eq(sent(e, '^/dex Shela /lc_failed Antilerd %S+ crafter_stopped$'), 1, 'order called off')
end)

-- A DanNet that answers /dquery the way the 2.34.0 log showed it does: Q[anything] is that character's LAST answer,
-- whatever the question; QReceived moves on with each answer. answers[name][query] = value, given `ms` after asking.
local function fake_dannet(e, peers, answers, ms)
    local val, rec, n = {}, {}, 0
    for name, v in pairs(answers.stale or {}) do val[name] = v; rec[name] = 1 end
    e.F.mq.TLO.DanNet = setmetatable({ Peers = function() return peers end }, { __call = function(_, name)
        name = name:lower()
        return { Q = function() return function() return val[name] end end,
                 QReceived = function() return function() return rec[name] end end }
    end })
    e.script(function(c)
        local name, q = c:match('^/squelch /dquery (%S+) %-q "(.*)"$')
        if not name then return end
        name = name:lower()
        local v = (answers[name] or {})[q]
        if type(v) == 'table' then v = table.remove(v, 1) end   -- a list: one answer per ask, in turn
        if v == nil then return end   -- this one does not answer
        e.F.at(e.F.now + (ms or 200), function()
            n = n + 1
            val[name], rec[name] = v, 100 + n
        end)
    end)
end

test('books: a spellbook read over DanNet - casts and missing saved; under level 66 not read; a NULL asked once more', function()
    local e = handoff_env('crafter')
    local cfg = Config.load(ROOT .. 'data/')
    package.loaded['engine.books'] = nil; package.loaded['core.casters'] = nil
    local Books = require('engine.books')
    local memo = require('core.casters').new({})
    memo:set_class('Ejtou', 'Cleric')
    local probe = Books.new({ producers = cfg.producers, casters = memo })
    local items = probe:class_items('Cleric')
    truthy(#items >= 2, 'clerics summon things')
    local answers = { ejtou = { ['Me.Level'] = '70' }, low = { ['Me.Class.Name'] = 'Wizard', ['Me.Level'] = '50' } }
    for i, ci in ipairs(items) do
        for _, sp in ipairs(ci.spells) do answers.ejtou['Me.Book[' .. sp .. ']'] = (i == 1) and '23' or 'NULL' end
    end
    fake_dannet(e, 'lazarus_ejtou|lazarus_low', answers)
    local books = Books.new({ peers = e.peers, log = e.log, now = e.F.mq.gettime, casters = memo, producers = cfg.producers,
        roster = function() return { 'Ejtou', 'Low' } end, running = function() return false end })
    e.F.ticks[#e.F.ticks + 1] = function() books:tick() end
    local res = e.run(function(ctx)
        books:tick()
        return ctx:wait(120000, function() return books.scanAt ~= nil and not books:busy() end)
    end)
    truthy(res.ok, R.describe(res))
    eq(table.concat(memo:casts('Ejtou'), ','), items[1].item, 'casts what is scribed')
    eq(#memo:lacks_list('Ejtou'), #items - 1, 'the rest of its class\'s items: missing')
    eq(memo:level_of('Ejtou'), 70); truthy(memo:checked('Ejtou'))
    eq(memo:class_of('Low'), 'Wizard'); eq(memo:level_of('Low'), 50); eq(#memo:casts('Low'), 0, 'under 66: no book read')
    truthy(e.log.has('Spellbook: Ejtou %(Cleric 70%): casts ' .. items[1].item:gsub('%p', '%%%0')), 'said')
    truthy(e.log.has('Spellbook: Low is a level 50 Wizard %- not checked'), 'said')
    local nullAsks = 0
    for _, c in ipairs(e.G.log) do if c:find('/dquery Ejtou', 1, true) and c:find(items[2].spells[1], 1, true) then nullAsks = nullAsks + 1 end end
    eq(nullAsks, 2, 'a NULL is asked once more before it counts')
end)

-- The crafter getting an item only Shela holds: survey, Shela started as our worker, ordered, brought.
local function supply_env(shelaZone, opts)
    opts = opts or {}
    local e = handoff_env('crafter')
    e.G:bag(1, 'Backpack', 10)
    local Supply = require('engine.supply')
    fake_dannet(e, 'lazarus_shela|lazarus_tom', {
        shela = { ['Zone.ShortName'] = shelaZone ~= '' and shelaZone or nil, ['FindItemCount[=' .. ESB .. ']'] = opts.shelaCount or '40', ['FindItemBankCount[=' .. ESB .. ']'] = opts.shelaBank or '10' },
        tom = opts.tom or (opts.tomSilent and {} or { ['Zone.ShortName'] = 'soldungb', ['FindItemCount[=' .. ESB .. ']'] = '0', ['FindItemBankCount[=' .. ESB .. ']'] = '0' }),
        stale = { shela = '999' },
    })
    e.supply = Supply.new({ peers = e.peers, log = e.log, now = e.F.mq.gettime, safe = { freeporttemple = true, poknowledge = true },
        zone_of = opts.zoneOf })
    e.started = {}
    local up = {}
    e.crew = {
        start_worker = function(_, name)
            e.started[#e.started + 1] = name
            -- not running yet: LazCraft starts there and its card comes 6s later
            e.F.at(e.F.now + 6000, function() up[name:lower()] = e.F.now end)
        end,
        card_since = function(_, name, t) return (up[name:lower()] or -1) >= t end,
    }
    local cfg = Config.load(ROOT .. 'data/')
    local blocks = { inventory = e.inv, windows = e.win, cursor = e.cur, spawns = e.spawns, nav = e.nav, merchant = e.merchant,
        bank = e.bank, kit = e.kit, station = e.station, kitslot = { restore = function() return R.ok() end } }
    -- travel goes where it is told (2.42.15: the route starts in the zone of a worker collected from first)
    local at = 'freeporttemple'
    e.went = {}
    blocks.travel = { zone = function() return at end, path = function() return true end,
        go = function(_, _, z) e.went[#e.went + 1] = z; at = z; return R.ok() end }
    e.env = { blocks = blocks, planner = Planner.new(cfg), cfg = cfg, log = e.log, mq = e.F.mq,
        describe = Planner.describe, handoff = e.h, supply = e.supply, crew = e.crew,
        world = function()
            return { zone = blocks.travel.zone(), bags = function(i) return e.inv:count(i) end, bank = function() return 0 end,
                     canCast = function() return false end, kit = function() return false end,
                     supply = function(i) return e.supply:holders(i) end }
        end }
    return e
end

test('supply: a held item nobody here has - the network is asked, Shela (safe zone) is started as our worker, ordered, and brings it', function()
    local e = supply_env('poknowledge')
    local fetches = scripted_worker(e, 1000)
    local askedAt
    e.script(function(c)
        local id = c:match('^/dex Shela /lc_ask Antilerd (%S+) 5 Enchanted_Silver_Bar$')
        if id then
            askedAt = e.F.now
            e.F.mq.cmd('/lc_answer Shela ' .. id .. ' yes 5_in_bags')
            e.F.at(e.F.now + 2000, function() e.F.mq.cmd('/lc_made Shela ' .. id .. ' 40') end)
        end
    end)
    e.runner:add(require('engine.make').get_job(e.env, ESB, 5)); e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.why) .. ' ' .. tostring(e.runner.last.detail))
    eq(e.G:count(ESB), 5); eq(fetches(), 1)
    eq(e.started[1], 'Shela', 'started as our worker first'); truthy(askedAt ~= nil, 'then ordered')
    truthy(e.log.has('Supply: asking 2 characters who has Enchanted Silver Bar'), 'asked the network')
    truthy(e.log.has('Supply: Enchanted Silver Bar %- Shela 50 %(bags 40, bank 10%) in poknowledge$'), 'the new answer, not the old 999')
    truthy(e.log.has('Shela is working for us'), 'start logged')
    eq(table.concat(e.went, '>'), 'poknowledge', 'to her zone once - the route starts there, no trip back')
end)

test('supply: some on hand but short for the whole count - the network is asked for the rest, not the count cut', function()
    -- 2.42.6 log: Cobalt and Tungsten Ore on hand for 1 of 20 Alloy Reinforced Bank Vaults - 1 made, twice, while
    -- Antilerd and Shela held hundreds in their banks
    local e = supply_env('freeporttemple')
    e.G:put(1, 1, ESB, 2)
    local rec = { id = 'T9', name = 'Test Ring', label = 'Test Ring', container = "Jeweler's Kit", yield = 1, tools = {},
                  ins = { { name = ESB, n = 1 } } }
    e.env.cfg.recipes.T9 = rec
    e.env.world = function()
        return { zone = 'freeporttemple', bags = function(i) return e.inv:count(i) end, bank = function() return 0 end,
                 canCast = function() return false end, kit = function() return true end,
                 supply = function(i) return e.supply:holders(i) end }
    end
    e.runner:add(require('engine.make').job(e.env, rec, 5)); e.runner:step()
    local v = e.runner:view()
    eq(v.active and v.active.phase, 'awaiting', 'the preflight is up')
    local lines = {}; for _, c in ipairs(v.active.checks) do lines[#lines + 1] = c.text end
    local text = table.concat(lines, '\n')
    truthy(e.log.has('Supply: asking 2 characters who has Enchanted Silver Bar'), 'asked the network for the rest')
    truthy(text:find('Supply: Shela brings 3 Enchanted Silver Bar', 1, true), text)
    truthy(not text:find('Only enough', 1, true), 'the count is not cut: ' .. text)
    e.runner:cancel(); e.runner:step()
end)

test('supply: a zone question nobody answers is taken from the worker card; the counts still count', function()
    local e = supply_env('', { zoneOf = function(n) return n == 'Shela' and 'poknowledge' or nil end })
    scripted_worker(e, 1000)
    e.script(function(c)
        local id = c:match('^/dex Shela /lc_ask Antilerd (%S+) 5 Enchanted_Silver_Bar$')
        if id then
            e.F.mq.cmd('/lc_answer Shela ' .. id .. ' yes 5_in_bags')
            e.F.at(e.F.now + 500, function() e.F.mq.cmd('/lc_made Shela ' .. id .. ' 40') end)
        end
    end)
    e.runner:add(require('engine.make').get_job(e.env, ESB, 5)); e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.why) .. ' ' .. tostring(e.runner.last.detail))
    truthy(e.log.has('Shela 50 %(bags 40, bank 10%) in poknowledge %- not every answer came'), 'zone from the card')
end)

test('supply: a holder that does not come up as our worker is left out, and the next one is ordered instead', function()
    local e = supply_env('poknowledge', { tom = { ['Zone.ShortName'] = 'poknowledge', ['FindItemCount[=' .. ESB .. ']'] = '60', ['FindItemBankCount[=' .. ESB .. ']'] = '0' } })
    local start = e.crew.start_worker
    e.crew.start_worker = function(c, name) if name == 'Tom' then e.started[#e.started + 1] = name; return end; return start(c, name) end
    scripted_worker(e, 1000)
    e.script(function(c)
        local id = c:match('^/dex Shela /lc_ask Antilerd (%S+) 5 Enchanted_Silver_Bar$')
        if id then
            e.F.mq.cmd('/lc_answer Shela ' .. id .. ' yes 5_in_bags')
            e.F.at(e.F.now + 500, function() e.F.mq.cmd('/lc_made Shela ' .. id .. ' 40') end)
        end
    end)
    e.runner:add(require('engine.make').get_job(e.env, ESB, 5)); e.runner:step()
    truthy(e.runner.last.ok, tostring(e.runner.last.why) .. ' ' .. tostring(e.runner.last.detail))
    eq(e.started[1], 'Tom', 'the one with the most first'); eq(e.started[2], 'Shela', 'then the next')
    truthy(e.log.has('Supply: Tom did not come up as our worker'), 'said'); eq(e.G:count(ESB), 5)
end)

test('supply: workers never travel after us - one in another zone is collected there first, one here before we leave', function()
    for _, case in ipairs({ { shela = 'poknowledge', want = 'travel poknowledge | come poknowledge | travel freeporttemple | travel poknowledge' },
                            { shela = 'freeporttemple', want = 'come freeporttemple | travel poknowledge' } }) do
        local e = supply_env(case.shela)
        e.supply.safe.freeporttemple = true
        local events, cur = {}, 'freeporttemple'
        e.env.blocks.travel.zone = function() return cur end
        e.env.blocks.travel.path = function() return {} end
        e.env.blocks.travel.go = function(_, ctx, z) events[#events + 1] = 'travel ' .. z; cur = z; return R.ok({ hops = 1 }) end
        e.h.zone = function() return cur end
        local P = e.env.planner
        local orig = P.plan_item
        P.plan_item = function(self, ...) local p = orig(self, ...); p.route = { 'freeporttemple', 'poknowledge' }; return p end
        scripted_worker(e, 1000)
        e.script(function(c)
            local id = c:match('^/dex Shela /lc_ask Antilerd (%S+) 5 Enchanted_Silver_Bar$')
            if id then
                e.F.mq.cmd('/lc_answer Shela ' .. id .. ' yes 5_in_bags')
                e.F.at(e.F.now + 500, function() e.F.mq.cmd('/lc_made Shela ' .. id .. ' 40') end)
            end
            local z = c:match('^/dex Shela /lc_come Antilerd %S+ %d+ %S+ (%S+)')
            if z then events[#events + 1] = 'come ' .. z end
        end)
        e.runner:add(require('engine.make').get_job(e.env, ESB, 5)); e.runner:step()
        truthy(e.runner.last.ok, tostring(e.runner.last.why) .. ' ' .. tostring(e.runner.last.detail))
        eq(table.concat(events, ' | '), case.want)
        eq(e.G:count(ESB), 5)
    end
end)

test('supply: a count that comes back NULL is asked again, not taken as none', function()
    local e = supply_env('poknowledge', { shelaCount = { 'NULL', '40' } })
    local P = require('engine.planner')
    local s = e.F.mq
    local res
    e.runner:add({ name = 'survey', execute = function(ctx) res = e.supply:survey(ctx, { ESB }); return res end }); e.runner:step()
    truthy(res and res.ok)
    local h = e.supply:holders(ESB)
    eq(#h, 1); eq(h[1].bags, 40); eq(h[1].have, 50)
end)

test('supply: an item nobody had is not asked again for a while (a research queue asked it before every entry)', function()
    local e = supply_env('poknowledge', { shelaCount = '0', shelaBank = '0' })
    local function asks() local n = 0; for _, c in ipairs(e.G.log) do if c:find('/dquery', 1, true) then n = n + 1 end end; return n end
    local function survey() e.runner:add({ name = 'survey', execute = function(ctx) return e.supply:survey(ctx, { ESB }) end }); e.runner:step() end
    survey()
    local first = asks()
    truthy(first > 0, 'asked the first time'); eq(#e.supply:holders(ESB), 0, 'nobody has any')
    survey()
    eq(asks(), first, 'not asked again within NONE_MS')
    e.supply.noneAt[ESB:lower()] = e.F.now - require('engine.supply').NONE_MS - 1
    survey()
    truthy(asks() > first, 'asked again once that is old')
end)

test('supply: a NULL goes to the end of that character\'s questions - one that never comes back does not cost the rest', function()
    -- 2.40.2 log: Shela's re-asked count never came back and her Fruit was never asked
    local e = handoff_env('crafter')
    fake_dannet(e, 'lazarus_shela', { shela = { ['Zone.ShortName'] = 'poknowledge',
        ['FindItemCount[=' .. ESB .. ']'] = { 'NULL' }, ['FindItemBankCount[=' .. ESB .. ']'] = '10',
        ['FindItemCount[=Fruit]'] = '964', ['FindItemBankCount[=Fruit]'] = '0' } })
    local s = require('engine.supply').new({ peers = e.peers, log = e.log, now = e.F.mq.gettime, safe = { poknowledge = true } })
    local res
    e.runner:add({ name = 'survey', execute = function(ctx) res = s:survey(ctx, { ESB, 'Fruit' }); return res end }); e.runner:step()
    truthy(res and res.ok)
    truthy(e.log.has('NULL %- asking it again after FindItemBankCount'), 'the next question went first')
    local f = s:holders('Fruit'); eq(#f, 1); eq(f[1].have, 964)
    local b = s:holders(ESB); eq(#b, 1); eq(b[1].bank, 10); truthy(b[1].partial, 'its bag count never came')
end)

test('supply: an item a character did not answer for keeps its last count, never "nobody has it"', function()
    local e = handoff_env('crafter')
    fake_dannet(e, 'lazarus_shela', { shela = { ['Zone.ShortName'] = 'poknowledge',
        ['FindItemCount[=Fruit]'] = { '964' }, ['FindItemBankCount[=Fruit]'] = { '0' } } })
    local s = require('engine.supply').new({ peers = e.peers, log = e.log, now = e.F.mq.gettime, safe = { poknowledge = true } })
    e.runner:add({ name = 'survey 1', execute = function(ctx) return s:survey(ctx, { 'Fruit' }) end }); e.runner:step()
    eq(s:holders('Fruit')[1].have, 964)
    -- the second time her counts do not come
    e.runner:add({ name = 'survey 2', execute = function(ctx) return s:survey(ctx, { 'Fruit' }) end }); e.runner:step()
    local f = s:holders('Fruit'); eq(#f, 1); eq(f[1].have, 964)
    truthy(e.log.has('Shela did not answer for Fruit this time %- keeping its last count'), 'said')
    truthy(not e.log.has('nobody on the network has Fruit'))
    -- never answered and nothing before: named, not "nobody"
    e.runner:add({ name = 'survey 3', execute = function(ctx) return s:survey(ctx, { 'Brownie Parts' }) end }); e.runner:step()
    truthy(e.log.has('nobody who answered has Brownie Parts %- no answer for it from Shela'), 'named')
    -- 2.44.0: the plan names her, and "nobody had it" is not held - the next survey asks again
    eq(table.concat(s:no_answer('Brownie Parts') or {}, ','), 'Shela')
    eq(s.noneAt['brownie parts'], nil, 'not held as nobody')
end)

test('supply: a character that answered only half for an item is named, and asked again just that one', function()
    -- 2.41.7 log: Shylain's bags answered 0, her bank (2162 Vial of Clear Mana) never came, two rows were passed
    local e = handoff_env('crafter')
    fake_dannet(e, 'lazarus_shela|lazarus_tom', {
        shela = { ['Zone.ShortName'] = 'poknowledge', ['FindItemCount[=Fruit]'] = '0', ['FindItemBankCount[=Fruit]'] = { 'NULL', 'NULL', 'NULL', '2162' } },
        tom = { ['Zone.ShortName'] = 'poknowledge', ['FindItemCount[=Fruit]'] = '0', ['FindItemBankCount[=Fruit]'] = '0' } })
    local s = require('engine.supply').new({ peers = e.peers, log = e.log, now = e.F.mq.gettime, safe = { poknowledge = true } })
    e.runner:add({ name = 'survey 1', execute = function(ctx) return s:survey(ctx, { 'Fruit' }) end }); e.runner:step()
    eq(#s:holders('Fruit'), 0); eq(table.concat(s:unanswered('Fruit') or {}, ','), 'Shela')
    local before = sent(e, '/dquery [Tt]')
    e.runner:add({ name = 'survey 2', execute = function(ctx) return s:survey(ctx, { 'Fruit' }, { shela = true }) end }); e.runner:step()
    local h = s:holders('Fruit'); eq(#h, 1); eq(h[1].bank, 2162)
    eq(sent(e, '/dquery [Tt]'), before, 'only Shela asked again')
end)

test('summon order (crafter): a pass takes from the order placed ahead, even when its plan picked another caster', function()
    local e = handoff_env('crafter')
    e.h:place_summon('Ejtou', 'Imbued Emerald', 578)
    e.h.summons['ejtou|imbued emerald'].r.have = 875
    eq(e.h:summon_for('Shylain', 'Imbued Emerald'), nil)
    local s = e.h:summon_for(nil, 'Imbued Emerald')
    truthy(s and s.r.peer == 'Ejtou', 'Ejtou\'s order')
end)

test('supply: the preflight\'s answers serve the first pass after Go; later passes ask afresh', function()
    local s = require('engine.supply').new({ peers = {}, now = function() return 0 end })
    s:keep_for_go({ 'Fruit', 'Brownie Parts' })
    truthy(s:take_for_go({ 'fruit' }), 'first pass: kept')
    truthy(not s:take_for_go({ 'Fruit' }), 'then asked again')
    s:keep_for_go({ 'Fruit' })
    truthy(not s:take_for_go({ 'Fruit', 'Diamond' }), 'not all of them asked: asked')
    truthy(not s:take_for_go({ 'Fruit' }), 'and dropped')
end)

test('supply: nobody in a safe zone has it - blocked, naming who has it and where; a silent character is said', function()
    local e = supply_env('soldungb', { tomSilent = true })
    e.runner:add(require('engine.make').get_job(e.env, ESB, 5)); e.runner:step()
    eq(e.runner.last.why, 'cannot get it')
    truthy(e.runner.last.detail:find('Shela has 50 but is in soldungb, not a safe zone', 1, true), e.runner.last.detail)
    eq(#e.started, 0, 'nobody started')
    eq(sent(e, '/lc_ask '), 0, 'nothing ordered')
    truthy(e.log.has('Supply: no answer in 6.0s from Tom'), 'the silent one is said')
end)

test('supply: a holder that never comes up as our worker ends the run with why, before anything is ordered', function()
    local e = supply_env('poknowledge')
    e.crew.start_worker = function(_, name) e.started[#e.started + 1] = name end
    e.runner:add(require('engine.make').get_job(e.env, ESB, 5)); e.runner:step()
    eq(e.runner.last.why, 'worker did not start')
    truthy(e.runner.last.detail:find('Shela did not answer as our worker within 30s', 1, true), e.runner.last.detail)
    eq(sent(e, '/lc_ask '), 0, 'nothing ordered')
end)


test('handoff: a crafter calling a request off stops that job on the worker; the queue behind it carries on', function()
    local e = handoff_env('worker')
    e.G:bag(1, 'Backpack', 10); e.G:put(1, 1, ESB, 100)
    e.G.zoneMs = 25000
    e.G.zoneDefs.poknowledge = function(g) g:spawn('Antilerd', 5, 0, 0, { class = 'PC' }) end
    e.F.mq.cmd('/lc_come Antilerd a-1 10 Enchanted_Silver_Bar poknowledge')
    e.F.mq.cmd('/lc_come Antilerd a-2 1 Enchanted_Silver_Bar poknowledge')
    e.F.mq.doevents()
    e.F.at(e.F.now + 5000, function() e.F.mq.cmd('/lc_failed Antilerd a-1 crafter_stopped') end)
    e.F.at(e.F.now + 5000, function() e.F.mq.cmd('/lc_failed Antilerd a-2 crafter_stopped') end)
    e.runner:step()
    eq(e.runner.last.why, 'stopped')
    eq(#e.runner.queue, 0, 'the queued one was dropped too (it was called off)')
    eq(sent(e, '^/dex Antilerd /lc_failed '), 0, 'no echo back')
    truthy(e.runner.log.has('called off'), 'logged')
end)

test('handoff order: called off mid-cast, the worker stops the cast - nothing lands on the cursor, reagents kept', function()
    local e = handoff_env('worker')
    e.G:bag(1, 'Backpack', 20)
    e.G:spawn('Mirao Frostpouch', 5, 0, 0, { sells = { 'Silver Bar' } })
    e.G.book['superior mass enchant silver'] = true
    e.G.produce['superior mass enchant silver'] = { product = ESB, yield = 100, reagents = { { 'Silver Bar', 100 } } }
    e.G.castMs = 10000
    local cfg = Config.load(ROOT .. 'data/')
    cfg.merchants = Config.parse_merchants(Ini.parse('[Mirao Frostpouch##freeporttemple]\n_Zone=freeporttemple\nSilver Bar=1\n'))
    package.loaded['blocks.cast'] = nil
    local blocks = { inventory = e.inv, windows = e.win, cursor = e.cur, spawns = e.spawns, nav = e.nav, merchant = e.merchant,
        bank = e.bank, kit = e.kit, station = e.station, travel = { zone = function() return 'freeporttemple' end },
        kitslot = { restore = function() return R.ok() end } }
    blocks.cast = require('blocks.cast').new({ mq = e.F.mq, nav = e.nav, inventory = e.inv, cursor = e.cur, log = e.log })
    e.h.make = require('engine.make')
    e.h.makeEnv = { blocks = blocks, planner = Planner.new(cfg), cfg = cfg, log = e.log, mq = e.F.mq, describe = Planner.describe,
        world = function()
            return { zone = 'freeporttemple', bags = function(i) return e.inv:count(i) end, bank = function() return 0 end,
                     canCast = function(s) return blocks.cast:has(s) end, kit = function() return false end }
        end }
    local calledOff = false
    e.F.ticks[#e.F.ticks + 1] = function()
        if e.G.casting and not calledOff then
            calledOff = true
            e.F.at(e.F.now + 2000, function() e.F.mq.cmd('/lc_failed Antilerd o-1 crafter_stopped') end)
        end
    end
    e.F.mq.cmd('/lc_ask Antilerd o-1 3 Enchanted_Silver_Bar'); e.F.mq.doevents()
    e.runner:step()
    eq(e.runner.last.why, 'stopped')
    e.F.mq.delay(15000)
    eq(e.G.casting, nil, 'cast stopped'); eq(#e.G.cursor, 0, 'nothing on the cursor afterwards')
    eq(e.G:count('Silver Bar'), 100, 'reagents kept'); eq(e.G:count(ESB), 0)
    eq(sent(e, '^/dex Antilerd /lc_made '), 0)
end)

test('in game: the crafter\'s Close all quits LazCraft on every worker, then here', function()
    local F, G = script_env()
    F.at(100, function() F.mq.cmd('/lc_card Bob poknowledge idle -') end)
    F.at(300, function() F.draw(); F.click('Close all##lc_closeall') end)
    F.at(60000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    eq(#sent_matching(G, '^/dex Bob /lc quit$'), 1, 'Bob told to quit')
    truthy(printed:find('Close all: LazCraft quits on Bob and here', 1, true), printed)
    truthy(F.now < 60000, 'quit here at once')
    clean_own_files()
end)

test('in game: tradeskills this character cannot train (skill cap 0) are left out of the Craft and Leveling lists', function()
    local F, G = script_env()
    G.skillCaps = { Alchemy = 0, ['Make Poison'] = 0, Tinkering = 0, Pottery = 300 }
    local frames = {}
    F.at(100, function() F.tab = 'Craft'; F.openCombo = 'Tradeskill##lc_skill'; frames.craft = F.draw(); F.openCombo = nil end)
    F.at(150, function() F.tab = 'Leveling'; F.openCombo = 'Skill##lc_lvl'; frames.level = F.draw(); F.openCombo = nil end)
    F.at(200, function() F.mq.cmd('/lc level Alchemy') end)
    F.at(1000, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local printed = table.concat(F.printed, '\n')
    local craft, level = table.concat(frames.craft or {}, '\n'), table.concat(frames.level or {}, '\n')
    truthy(craft:find('Pottery##lc_sk_Pottery', 1, true), craft)
    for _, sk in ipairs({ 'Alchemy', 'Make Poison', 'Tinkering' }) do
        truthy(not craft:find(sk .. '##lc_sk_', 1, true), sk .. ' left out of Craft')
        truthy(not level:find('##lc_lvl_' .. sk, 1, true), sk .. ' left out of Leveling')
    end
    truthy(printed:find('Tradeskills Glanen cannot train (skill cap 0), left out of the lists: Alchemy, Make Poison, Tinkering', 1, true), printed)
    truthy(printed:find('Glanen cannot train Alchemy (skill cap 0)', 1, true), 'the command says why')
    clean_own_files()
end)

test('in game: the window - search, pick, Plan shows the preflight in the strip; Summon orders; Travel and Start queue', function()
    local F, G, tmp = script_env()
    local zones = { ann = 'poknowledge', tom = 'soldunga' }
    F.mq.TLO.DanNet = setmetatable({ Peers = function() return 'lazarus_ann|lazarus_tom' end },
        { __call = function(_, name) return { Q = function() return function() return zones[name:lower()] end end } end })
    G.book = { ['enchant silver'] = true }
    G:bag(1, 'Big Bag', 40)
    local frames = {}
    local function label_with(frame, kind, p)
        for _, l in ipairs(frame) do
            local v = l:match('^' .. kind .. ':(.*)$')
            if v and v:find(p, 1, true) then return (v:gsub('%*$', '')) end
        end
    end
    F.at(100, function() F.mq.cmd('/lc_card Bob poknowledge idle Enchanted_Silver_Bar') end)
    F.at(150, function() F.tab = 'Craft'; F.openCombo = 'Tradeskill##lc_skill'; frames.skill = F.draw() end)
    F.at(170, function() F.click('Fishing##lc_sk_Fishing'); F.openCombo = nil; F.draw(); frames.fishing = F.draw() end)
    F.at(190, function() F.openCombo = 'Tradeskill##lc_skill'; F.click('All (type to search)##lc_sk_all'); F.openCombo = nil end)
    F.at(200, function() F.tab = 'Craft'; F.inputs['Search##lc_q'] = 'amber ring silver'; F.draw(); frames.search = F.draw() end)
    F.at(300, function() F.click(label_with(frames.search, 'selectable', '##lc_rO6358')); frames.picked = F.draw() end)
    F.at(400, function() F.click('Plan##lc_plan') end)
    F.at(900, function() frames.plan = F.draw() end)
    F.at(1000, function() F.click('Cancel') end)
    F.at(1100, function() F.tab = 'Leveling'; frames.level = F.draw() end)
    F.at(1150, function() F.openCombo = 'Skill##lc_lvl'; F.draw(); F.click('Blacksmithing##lc_lvl_Blacksmithing'); F.openCombo = nil; frames.lvlbs = F.draw() end)
    F.at(1200, function() F.click('Make##lc_lv_m_Blacksmithing_1') end)
    F.at(1350, function() frames.lvlmake = F.draw(); F.click('Cancel') end)
    F.at(1500, function() F.tab = 'Summon'; frames.summon = F.draw() end)
    F.at(1600, function() F.click('Bob##lc_o_Enchanted Silver Bar_Bob') end)
    F.at(1700, function() F.mq.cmd('/lc stop') end)
    F.at(2500, function() F.tab = 'Travel'; frames.travel = F.draw() end)
    F.at(2500, function() F.tab = 'Workers'; frames.workers = F.draw() end)
    F.at(2600, function() F.tab = 'Workers'; F.inputs['Name##lc_wname'] = 'Sue'; F.draw(); F.click('Start##lc_wstart') end)
    F.at(3000, function() F.tab = 'Log'; frames.log = F.draw() end)
    F.at(3100, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local function has(frame, p) for _, l in ipairs(frame or {}) do if l:find(p, 1, true) then return true end end return false end
    truthy(has(frames.search, "selectable:Silver Amber Ring##lc_rO6358") and has(frames.search, "disabled:Jeweler's Kit"), 'search lists it')
    truthy(has(frames.picked, 'button:Plan##lc_plan') and has(frames.picked, 'Combines##lc_n'), 'picked shows count and buttons')
    truthy(has(frames.picked, 'text:Amber') and has(frames.picked, 'text:Enchanted Silver Bar'), 'picked shows what it uses (the ingredient table)')
    truthy(has(frames.picked, '= 1 Silver Amber Ring'), 'picked shows what the combines make')
    truthy(has(frames.picked, 'Cost: about'), 'picked shows what it costs')
    truthy(has(frames.picked, 'button:+ Queue##lc_q_add'), 'a recipe can go in the queue')
    truthy(has(frames.picked, 'combo:Then##lc_disp=Keep'), 'product choice, Keep picked')
    truthy(not has(frames.picked, 'Stop at trivial'), 'no trivial on the Craft tab')
    truthy(has(frames.lvlmake, 'Stops at trivial 18'), 'a leveling Make stops at the trivial')
    truthy(has(frames.lvlmake, 'Metal Bits made by this run: DESTROYED'), 'with the rung\'s disposal')
    truthy(has(frames.level, 'combo:Skill##lc_lvl=Alchemy'), 'leveling opens on the first skill')
    truthy(has(frames.level, 'button:Run path##lc_lv_path') and has(frames.level, 'button:Run all skills##lc_lv_all'), 'path buttons')
    truthy(has(frames.lvlbs, 'disabled:1.') and has(frames.lvlbs, 'text:Metal Bits') and has(frames.lvlbs, 'text:18'), 'a path row: recipe, trivial')
    truthy(has(frames.lvlbs, 'combo:##lc_lv_d_Blacksmithing_1=Destroy'), 'the rung\'s own disposal is picked')
    truthy(has(frames.lvlbs, 'input:##lc_lv_n_Blacksmithing_1='), 'combines box (its count follows the estimate)')
    truthy(has(frames.lvlbs, 'checkbox:Rep##lc_lv_r_Blacksmithing_1=false'), 'repeat to trivial, off')
    truthy(has(frames.skill, 'Fishing##lc_sk_Fishing'), 'the dropdown lists the tradeskills')
    truthy(has(frames.fishing, 'Fish Bones') and has(frames.fishing, 'heading:Recipes'), 'a tradeskill lists its recipes')
    truthy(not has(frames.fishing, 'Silver Amber Ring'), 'and only its recipes')
    truthy(has(frames.plan, 'colored:Plan: 1 x Silver Amber Ring') and has(frames.plan, 'colored:Waiting for Go'), 'plan waits for Go in the job panel')
    truthy(has(frames.plan, 'Silver Amber Ring [O6358] x1 combines'), 'preflight shown in the strip')
    truthy(has(frames.summon, 'Enchanted Silver Bar - me, Bob'), 'summon row: me and Bob')
    truthy(has(frames.summon, 'Vial of Clear Mana - nobody running has the spell'), 'nobody row greyed')
    eq(#sent_matching(G, '^/dex Bob /lc_ask Glanen %S+ 1 Enchanted_Silver_Bar$'), 1, 'order sent to Bob')
    truthy(has(frames.travel, 'text:poknowledge') and has(frames.travel, 'button:Go##lc_t_poknowledge'), 'travel buttons')
    eq(#sent_matching(G, '^/dex Sue /lc_hello Glanen$'), 1, 'Start checks on Sue first')
    truthy(has(frames.log, 'Queued: Plan: 1 x Silver Amber Ring'), 'log tab shows the log')
    truthy(has(frames.workers, 'button:Start##lc_ws_Ann'), 'Ann in PoK can be started')
    truthy(has(frames.workers, 'disabled:Tom') and has(frames.workers, 'disabled:soldunga (not safe)') and not has(frames.workers, 'Start##lc_ws_Tom'), 'Tom greyed, no Start')
    truthy(has(frames.workers, 'button:Start all (1)##lc_wall'), 'Start all counts the startable')
    os.remove(ROOT .. 'logs/LazCraft_Glanen.log'); os.remove(ROOT .. 'logs/LazCraft_Glanen.prev.log')
    os.remove(ROOT .. 'settings/LazCraft_Glanen.ini')
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: with tables, theme slots and a texture as MQ has them, every tab draws balanced; the logo shows (2.43.0)', function()
    local F, G, tmp = script_env()
    package.loaded['ui.theme'] = nil
    _G.ImGuiTableFlags = { RowBg = 64, SizingStretchProp = 16384, PadOuterX = 2097152 }
    _G.ImGuiTableColumnFlags = { WidthFixed = 16, WidthStretch = 8 }
    _G.ImGuiSelectableFlags = { SpanAllColumns = 2 }
    _G.ImGuiCol = { WindowBg = 2, Text = 0, Button = 21, Separator = 27, PlotHistogram = 40, TableRowBg = 46 }
    _G.ImGuiStyleVar = { WindowRounding = 3, FrameRounding = 12, WindowTitleAlign = 23 }
    _G.ImVec2 = function(x, y) return { x = x, y = y } end
    F.mq.CreateTexture = function(path) return { path = path, GetTextureID = function() return 'tex:' .. path:match('[^/]*$') end } end
    G:bag(1, 'Big Bag', 40); G:put(1, 1, 'Small Piece of Ore', 4)
    local frames = {}
    F.at(100, function() F.mq.cmd('/lc_card Bob poknowledge idle Enchanted_Silver_Bar') end)
    for i, tab in ipairs({ 'Craft', 'Leveling', 'Research', 'Summon', 'Workers', 'Log', 'Travel', 'Settings' }) do
        F.at(200 + i * 20, function() F.tab = tab; frames[tab] = F.draw() end)
    end
    F.at(400, function() F.tab = 'Craft'; F.openCombo = 'Tradeskill##lc_skill'; F.click('Blacksmithing##lc_sk_Blacksmithing'); F.openCombo = nil; frames.bs = F.draw() end)
    F.at(450, function() F.click('Metal Bits##lc_rO4454'); frames.picked = F.draw() end)
    F.at(470, function() F.inputs['to##lc_tmin'] = '250'; F.draw(); frames.trivmin = F.draw() end)
    F.at(500, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    for _, k in ipairs({ 'ImGuiTableFlags', 'ImGuiTableColumnFlags', 'ImGuiSelectableFlags', 'ImGuiCol', 'ImGuiStyleVar', 'ImVec2' }) do _G[k] = nil end
    local function has(frame, p) for _, l in ipairs(frame or {}) do if l:find(p, 1, true) then return true end end return false end
    for _, tab in ipairs({ 'Craft', 'Leveling', 'Research', 'Summon', 'Workers', 'Log', 'Travel', 'Settings' }) do
        truthy(frames[tab] and #frames[tab] > 0, tab .. ' drew')
    end
    truthy(has(frames.Craft, 'image:tex:emblem.png 93x64'), 'the emblem is drawn 64 tall, as wide as its shape (2.43.4)')
    truthy(has(frames.Workers, 'table:##lc_w_run') and has(frames.Workers, 'column:Casts'), 'workers in a table')
    truthy(has(frames.Travel, 'table:##lc_travel'), 'travel in a table')
    truthy(has(frames.bs, 'heading:Trivial 0 - 49') and has(frames.bs, 'table:##lc_rg1'), 'recipes in trivial bands, each a table')
    truthy(has(frames.picked, 'table:##lc_ings') and has(frames.picked, 'text:Small Piece of Ore'), 'the ingredient table')
    truthy(has(frames.trivmin, 'inputtext:to##lc_tmin=250'), 'the Min box')
    truthy(not has(frames.trivmin, 'heading:Trivial 0 - 49') and has(frames.trivmin, 'heading:Trivial 250 - 299'), 'only from 250 up')
    truthy(has(frames.trivmin, 'with no known trivial'), 'the no-trivial count')
    truthy(has(frames.picked, 'disabled:bags'), 'what is held says bags')
    local printed = table.concat(F.printed, '\n')
    truthy(not printed:find('Window error', 1, true), printed)
    eq(F.depth, 0, 'ImGui balanced')
    os.remove(ROOT .. 'logs/LazCraft_Glanen.log'); os.remove(ROOT .. 'logs/LazCraft_Glanen.prev.log')
    os.remove(ROOT .. 'settings/LazCraft_Glanen.ini')
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: Leveling shows the skill big with a bar, greys out rows already past and points at the next', function()
    local F, G, tmp = script_env()
    G.skills = { Blacksmithing = 20 }
    local frames = {}
    F.at(100, function() F.tab = 'Leveling'; F.openCombo = 'Skill##lc_lvl'; F.click('Blacksmithing (Blacksmithing 20)##lc_lvl_Blacksmithing'); F.draw(); F.openCombo = nil; frames.bs = F.draw() end)
    F.at(200, function() F.click('Make##lc_lv_m_Blacksmithing_1'); frames.click = F.draw() end)
    F.at(250, function() F.click('Run path##lc_lv_path'); F.draw(); frames.run = F.draw() end)
    F.at(400, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local function has(frame, p) for _, l in ipairs(frame or {}) do if l:find(p, 1, true) then return true end end return false end
    truthy(has(frames.bs, 'heading:Blacksmithing  20 / 300'), 'the skill in its heading')
    truthy(has(frames.bs, 'progress:next: row 2, Sheet Metal'), 'the bar names the next row')
    truthy(has(frames.bs, 'disabled:Metal Bits') and has(frames.bs, 'colored:done'), 'row 1 greyed, marked done')
    truthy(has(frames.bs, 'button:Make##lc_lv_m_Blacksmithing_1 (off)'), 'row 1 controls off')
    truthy(has(frames.bs, 'button:Make##lc_lv_m_Blacksmithing_2') and not has(frames.bs, 'button:Make##lc_lv_m_Blacksmithing_2 (off)'), 'row 2 live')
    truthy(has(frames.bs, 'text:Sheet Metal') and has(frames.bs, 'colored:next'), 'row 2 marked next')
    truthy(not has(frames.click, 'Waiting for Go'), 'a greyed row does not start')
    truthy(has(frames.bs, 'checkbox:Rep##lc_lv_r_Blacksmithing_2=false'), 'off before')
    truthy(has(frames.run, 'checkbox:Rep##lc_lv_r_Blacksmithing_2=true'), 'Run path ticks Repeat on every row')
    os.remove(ROOT .. 'logs/LazCraft_Glanen.log'); os.remove(ROOT .. 'logs/LazCraft_Glanen.prev.log')
    os.remove(ROOT .. 'settings/LazCraft_Glanen.ini')
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('paths: added recipes, rungs taken off and product choices are saved and read back; restore clears them', function()
    local Paths = require('core.paths')
    local file = os.tmpname()
    local p = Paths.new({ path = file })
    truthy(p:add('Blacksmithing', 'O1947', 'sell')); eq(p:add('Blacksmithing', 'o1947', 'keep'), false, 'once only')
    p:add('Blacksmithing', 'O454', 'destroy'); p:remove('Blacksmithing', 'Tungsten Metal Bits'); p:disposal('Blacksmithing', 'O1947', 'keep')
    local q = Paths.new({ path = file })
    local c = q:changes('Blacksmithing')
    eq(#c.adds, 2); eq(c.adds[1].id, 'O1947'); eq(c.adds[1].disposal, 'keep'); eq(c.adds[2].disposal, 'destroy')
    eq(c.removed['tungsten metal bits'], 'Tungsten Metal Bits'); eq(q:count('Blacksmithing'), 3); eq(q:count('Tailoring'), 0)
    q:forget('Blacksmithing', 'O454'); eq(Paths.new({ path = file }):count('Blacksmithing'), 2)
    q:restore('Blacksmithing'); eq(Paths.new({ path = file }):count('Blacksmithing'), 0)
    os.remove(file)
end)

test('in game: Leveling - add a recipe by typing (it sits by its trivial), take rows off with X, Restore path', function()
    local F, G, tmp = script_env()
    local file = ROOT .. 'settings/LazCraft_Glanen_paths.ini'
    os.remove(file)
    local frames = {}
    local function pick() F.tab = 'Leveling'; F.openCombo = 'Skill##lc_lvl'; F.click('Blacksmithing##lc_lvl_Blacksmithing'); F.draw(); F.openCombo = nil end
    F.at(100, function() pick(); F.inputs['Add a recipe##lc_lv_q'] = 'embroidering'; F.draw(); frames.search = F.draw() end)
    F.at(200, function() F.click('Embroidering Needle - trivial 122, Forge [O1947]##lc_lv_add_O1947'); F.draw(); frames.added = F.draw() end)
    F.at(300, function() F.click('X##lc_lv_x_Blacksmithing_6'); F.draw(); frames.dropped = F.draw() end)
    F.at(400, function() F.click('Restore path (2 changes)##lc_lv_restore'); F.draw(); frames.restored = F.draw() end)
    F.at(500, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local function has(frame, p) for _, l in ipairs(frame or {}) do if l:find(p, 1, true) then return true end end return false end
    truthy(has(frames.search, 'selectable:Embroidering Needle - trivial 122, Forge [O1947]##lc_lv_add_O1947'), 'the search lists it')
    local function idx(frame, p) for i, l in ipairs(frame or {}) do if l == p then return i end end return nil end
    local a, b, c = idx(frames.added, 'text:Banded Mail'), idx(frames.added, 'text:Embroidering Needle (added)'), idx(frames.added, 'text:Tungsten Bits')
    truthy(a and b and c and a < b and b < c, 'added between Banded Mail and Tungsten by its trivial')
    truthy(has(frames.added, 'combo:##lc_lv_d_Blacksmithing_5=Sell'), 'an added recipe is sold by default')
    truthy(not has(frames.dropped, 'text:Tungsten Bits') and has(frames.dropped, 'text:Rhenium Barbs'), 'Tungsten taken off')
    truthy(has(frames.dropped, 'button:Restore path (2 changes)##lc_lv_restore'), 'restore offered')
    truthy(has(frames.restored, 'text:Tungsten Bits') and not has(frames.restored, 'Embroidering Needle (added)'), 'restored')
    os.remove(file)
    os.remove(ROOT .. 'logs/LazCraft_Glanen.log'); os.remove(ROOT .. 'logs/LazCraft_Glanen.prev.log')
    os.remove(ROOT .. 'settings/LazCraft_Glanen.ini')
    os.execute('rm -rf "' .. tmp .. '"')
end)

test('in game: the Research tab - class, level, type; rows say held and scribed; Make shows the plan', function()
    local F, G, tmp = script_env()
    G.book['acikin'] = true
    local frames = {}
    F.at(100, function() F.tab = 'Research'; F.draw(); frames.first = F.draw() end)
    F.at(200, function() F.openCombo = 'Class##lc_rs_class'; F.click('necromancer##lc_rs_c_necromancer'); F.draw(); F.openCombo = nil
        F.openCombo = 'Level##lc_rs_lv'; F.click('66##lc_rs_lv_66'); F.draw(); F.openCombo = nil; frames.necro = F.draw() end)
    F.at(250, function() F.click('-##lc_rs_fold_necromancer_66'); frames.folded = F.draw(); F.click('+##lc_rs_fold_necromancer_66') end)
    F.at(270, function() local q = nil
        for _, l in ipairs(F.draw()) do q = q or l:match('^smallbutton:(Queue %d+##lc_rs_qlv_necromancer_66)$') end
        frames.qlabel = q; if q then F.click(q) end; frames.queued = F.draw() end)
    F.at(300, function() for _, l in ipairs(F.draw()) do local m = l:match('^button:(Make all shown %(%d+ not held%)##lc_rs_all)$'); if m then F.click(m) end end; F.draw() end)
    F.at(1200, function() frames.plan = F.draw() end)
    F.at(1300, function() F.mq.cmd('/lc quit') end)
    assert(loadfile(ROOT .. 'init.lua'))()
    _G.print = realPrint
    local function has(frame, p) for _, l in ipairs(frame or {}) do if l:find(p, 1, true) then return true end end return false end
    truthy(has(frames.first, 'combo:Class##lc_rs_class=bard'), 'first class when ours has none')
    truthy(has(frames.necro, 'text:Acikin') and not has(frames.necro, 'Spell: Acikin') and not has(frames.necro, 'scribed')
        and has(frames.necro, 'text:360'), 'scribed is not held: not greyed, no pill, no "Spell: "')
    truthy(not has(frames.necro, 'Make##lc_rs_m_') and has(frames.necro, '+ Queue##lc_rs_q_necromancer_H11742'), 'rows queue, no Make')
    local helps = 0; for _, l in ipairs(frames.necro or {}) do if l == 'disabled:(?)' then helps = helps + 1 end end
    truthy(not has(frames.necro, 'column:Spell or tome') and helps == 1, 'no header row; the only (?) is the Qty note, none on the divider')
    truthy(has(frames.necro, 'Make all shown ('), 'make all')
    truthy(has(frames.necro, 'heading:Level 66') and not has(frames.necro, 'heading:Level 67'), 'only level 66, under its divider')
    truthy(has(frames.necro, 'disabled:x1') and not has(frames.necro, 'input:##lc_rs_n_'), 'Qty box only on the row under the mouse')
    truthy(has(frames.folded or {}, 'button:+##lc_rs_fold_necromancer_66') and not has(frames.folded, 'text:Acikin'), 'folded away')
    truthy(frames.qlabel and has(frames.queued or {}, 'heading:Queue (') and not has(frames.queued, 'heading:Queue (0)'),
        'Queue on the divider queues that level: ' .. tostring(frames.qlabel))
    truthy(has(frames.plan, 'Spell: Acikin [H11742]: make 1 (a failure is made again)'), table.concat(frames.plan or {}, '\n'))
    os.remove(ROOT .. 'logs/LazCraft_Glanen.log'); os.remove(ROOT .. 'logs/LazCraft_Glanen.prev.log')
    os.remove(ROOT .. 'settings/LazCraft_Glanen.ini')
    os.execute('rm -rf "' .. tmp .. '"')
end)

clean_own_files()
realPrint(string.format('\n%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
