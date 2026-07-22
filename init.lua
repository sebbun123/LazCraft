-- TradeskillSuite.lua - ImGui front-end + pure-Lua engine for tradeskill automation
-- Run: /lua run Lazcraft
-- Bind: /tsui show|hide|toggle|stop

local mq = require('mq')
local ImGui = require('ImGui')

local INI_NAME = 'tradeskills.ini'
local scriptName = 'Lazcraft'

local KIT_PACK_DEFAULT = 10
local INVENTORY_THRESHOLD = 3   -- free slots in combine loop that triggers selling product
local BUY_THRESHOLD = 6         -- free slots required before starting a buy pass
local MAX_QUANTITY = 10000
local COMBINE_PACE_MS = 375     -- pause after every combine
local PLACE_PACE_MS = 75        -- default Fast; the pickup->drop
                                -- idle. Slashed to test the hypothesis that desyncs come from the
                                -- combine/inventory step, not placement. If desyncs stay low, placement
                                -- speed is exonerated and we keep it fast. Combine/settle pacing unchanged.
local COMBINE_SETTLE_MS = 550   -- pause after staging, before /combine (400->550 test: give the server a
                                -- bit more time to seat all slots before it reads them for the combine)
local FAIL_SETTLE_MS = 2000     -- after a WORLD combine FAILS: wait this long doing NOTHING (no slot reads,
                                -- no pickups - the salvage just sits on the cursor) before we route it back
                                -- into the barrel. The desyncs are isolated to this window: the container's
                                -- client view is briefly stale after a fail, and the first ACTION into a stale
                                -- slot trips the desync (which then cascades). A dead-wait can't make it worse,
                                -- only let the window pass. 2s pre-emptive vs the 3s we wait once a desync is
                                -- actually confirmed. Separate from COMBINE_SETTLE_MS so only the fail path slows.
local AUTOINV_PACE_MS = 750     -- deliberate pause BETWEEN consecutive /autoinventory pulls. Theory under test:
                                -- blitzing autoinventory through a multi-item salvage queue outruns the server
                                -- and trips the inventory desync (the original drain_cursor comment flagged this
                                -- exact thing at 150ms). Only applies when MORE items remain on the cursor, so a
                                -- single-item bag (the success case) pays nothing. Tune down if desyncs stay low.
local USE_CLEAR_KIT = true      -- clear the kit before combines, but only when it actually has items (see clear_kit)

local DISPOSAL = { DESTROY = 'destroy', SELL = 'sell', KEEP = 'keep' }

-- Recommended leveling paths per tradeskill UI name.
-- Each entry: { item=recipe name, disposal=DISPOSAL mode }
-- Listed in trivial order — the engine auto-stops at each trivial before advancing.
local RECOMMENDED_PATHS = {
    Jewelcrafting = {
        -- All ingredients vendor purchased from Audri Deepfacet / jeweler vendors in PoK
        { item = 'Golden Jaded Bracelet',         disposal = DISPOSAL.SELL },  -- t=178
        { item = 'Platinum Jasper Ring',          disposal = DISPOSAL.SELL },  -- t=236
        { item = 'Platinum Opal Engagement Ring', disposal = DISPOSAL.SELL },  -- t=263
        { item = 'Platinum Star Ruby Veil',       disposal = DISPOSAL.SELL },  -- t=271
        { item = 'Platinum Ruby Veil',            disposal = DISPOSAL.SELL },  -- t=279
        -- Gem endgame (Black Sapphire / Diamond / Blue Diamond, all |dropped). Each
        -- uses a plain vendor bar; the enchanted twin is preserved inline via |ench:
        -- for a future toggle. Two rungs per gem so leveling has a fallback if one
        -- gem runs short. Capped at 300.
        { item = 'Black Sapphire Platinum Necklace', disposal = DISPOSAL.SELL },  -- t=284 (Black Sapphire)
        { item = 'Black Sapphire Velium Necklace',   disposal = DISPOSAL.SELL },  -- t=287 (Black Sapphire)
        { item = 'Platinum Diamond Wedding Ring',    disposal = DISPOSAL.SELL },  -- t=287 (Diamond)
        { item = 'Velium Diamond Wedding Ring',      disposal = DISPOSAL.SELL },  -- t=290 (Diamond)
        { item = 'Platinum Blue Diamond Tiara',      disposal = DISPOSAL.SELL },  -- t=295 (Blue Diamond)
        { item = 'Velium Blue Diamond Bracelet',     disposal = DISPOSAL.SELL },  -- t=302 (Blue Diamond)
    },
    Baking = {
        -- All ingredients vendor purchased in PoK
        { item = 'Fish Rolls',    disposal = DISPOSAL.SELL },  -- t=135
        { item = 'Patty Melt',    disposal = DISPOSAL.SELL },  -- t=191
        { item = 'Barbecue Ribs', disposal = DISPOSAL.SELL },  -- t=250
        -- Endgame rung: Misty Thicket Picnic (t335). A deep, multi-container capstone (oven +
        -- mixing-bowl + sewing-kit subcombines) whose tree bottoms out in farmed mats -- most
        -- notably Fruit and Brownie Parts (both |dropped, several subcombines down). Pre-stock
        -- those from the mules first (the Level/Craft pre-stock buttons surface them off the
        -- tree). Like Brut Champagne for Brewing, it carries the grind 250->300.
        { item = 'Misty Thicket Picnic', disposal = DISPOSAL.SELL },  -- t=335 (Fruit/Brownie Parts farmed, deep tree)
    },
    Blacksmithing = {
        { item = 'Metal Bits',             disposal = DISPOSAL.DESTROY },                    -- t=18
        { item = 'Sheet Metal',            disposal = DISPOSAL.DESTROY },                    -- t=31
        { item = 'Banded Boots',           disposal = DISPOSAL.SELL, maxBatch = 20 },        -- t=95  non-stackable ingredients
        { item = 'Banded Mail',            disposal = DISPOSAL.SELL, maxBatch = 20 },        -- t=115 non-stackable ingredients
        -- Ore-tier ladder (Tungsten/Rhenium/Cobalt). Each rung's only farmed mat is
        -- a single |dropped ore pulled from the mules; everything else is vendor or a
        -- returned tool. Crafted until the ore runs out, then advance. Reaches the 300 cap.
        { item = 'Tungsten Metal Bits',           disposal = DISPOSAL.SELL },  -- t=150 (Tungsten Ore|dropped)
        { item = 'Rhenium Barbs',                 disposal = DISPOSAL.SELL },  -- t=184 (Rhenium Ore|dropped)
        { item = 'Shaded Kunai',                  disposal = DISPOSAL.SELL },  -- t=215 (Rhenium Ore|dropped)
        { item = 'Cobalt Barbs',                  disposal = DISPOSAL.SELL },  -- t=222 (Cobalt Ore|dropped)
        { item = 'Cobalt Sheet Metal',            disposal = DISPOSAL.SELL },  -- t=265 (Cobalt Ore|dropped)
        { item = 'Rhenium Plate Bracer Template', disposal = DISPOSAL.SELL },  -- t=272 (Rhenium Ore|dropped)
        { item = 'Rhenium Breastplate Template',  disposal = DISPOSAL.SELL },  -- t=290 (Rhenium Ore|dropped)
        { item = 'Cobalt Plate Gorget Template',  disposal = DISPOSAL.SELL },  -- t=348 (Cobalt Ore|dropped) - carries 290->300 cap
    },
    Tailoring = {
        { item = 'Woven Mandrake',                    disposal = DISPOSAL.SELL },  -- t=66  (Mandrake Root, vendor)
        -- Picnic Basket (t=76) was here and is a real Sewing Kit recipe, but one of its two
        -- ingredients - Steel Boning - is a BLACKSMITHING world-container combine (forge + a File).
        -- Leveling Tailoring shouldn't drag you to a forge for hundreds of subcombines, so it's out.
        -- Gorget ladder. All tiers use a FARMED pelt/silk (|dropped) pulled from
        -- the mules, plus vendor mats + the returned needle. Ordered Leather before
        -- Silk per priority; each tier is crafted until its mat runs out, then we
        -- move on. Capped at skill 300 via PATH_MAX_SKILL (no point past cap).
        { item = 'Fine Leather Gorget Template',      disposal = DISPOSAL.SELL },  -- t=272 (Fine Animal Pelt|dropped)
        { item = 'Fine Silk Gorget Template',         disposal = DISPOSAL.SELL },  -- t=272 (Fine Silk|dropped)
        { item = 'Excellent Leather Gorget Template', disposal = DISPOSAL.SELL },  -- t=310 (Excellent Animal Pelt|dropped)
        { item = 'Excellent Silk Gorget Template',    disposal = DISPOSAL.SELL },  -- t=310 (Excellent Silk|dropped)
        { item = 'Superb Leather Gorget Template',    disposal = DISPOSAL.SELL },  -- t=348 (Superb Animal Pelt|dropped)
        { item = 'Superb Silk Gorget Template',       disposal = DISPOSAL.SELL },  -- t=348 (Superb Silk|dropped)
    },
    Fletching = {
        -- Low rungs: vendor-purchased from fletching vendors in PoK.
        { item = 'Class 1 Wood Hooked Arrow',    disposal = DISPOSAL.SELL },  -- t=102
        { item = 'Class 1 Steel Point Arrow',    disposal = DISPOSAL.SELL },  -- t=202
        -- Endgame rung: Mithril Champion Arrows (subcombine tree). Mats are vendor-bought
        -- in Northern Felwithe; the Arrow Heads / Bundled Shafts / Working Knife sub-parts
        -- are FORGE combines, so they need a forge reachable in Felwithe (see stations.ini).
        -- Carries 202 -> 300 cap.
        { item = 'Mithril Champion Arrows',      disposal = DISPOSAL.SELL },  -- t=335 (Mithril mats, Felwithe)
    },
    Brewing = {
        -- All ingredients vendor purchased in PoK
        { item = 'Fetid Essence',          disposal = DISPOSAL.SELL },  -- t=122  (Water Flask + Fishing Grubs)
        { item = "Minotaur Hero's Brew",  disposal = DISPOSAL.SELL },  -- t=248  (~1pp/combine, cheap grind)
        -- Endgame rung: Brut Champagne (subcombine tree). Soda Water + Champagne Magnum
        -- sub-parts; the Magnum needs a caster-made Enchanted Gold Bar (|dropped, pre-load
        -- via Make/Bring). Mixes brew-barrel (world) + jeweler's-kit (inventory) combines.
        -- Carries 248 -> 300 cap.
        { item = 'Brut Champagne',         disposal = DISPOSAL.SELL },  -- t=335 (Enchanted Gold Bar|dropped via Champagne Magnum)
    },
    Pottery = {
        -- Wheel (unfired) recipes carry the real scaling trivials; firing in the
        -- kiln is a low fixed step. All ingredients vendor-bought in PoK.
        { item = 'Unfired Large Bowl',         disposal = DISPOSAL.DESTROY },  -- t=148
        { item = 'Unfired Sealed Poison Vial', disposal = DISPOSAL.DESTROY },  -- t=188
        { item = 'Unfired Casserole Dish',     disposal = DISPOSAL.DESTROY },  -- t=199 (Ceramic Lining subcombine; all vendor mats)
        -- Deity idols: each needs a caster-SUMMONED Imbued gem + Vial of Clear Mana +
        -- Large Block of Magic Clay (all |dropped), so production is supply-limited -- keep
        -- the cleric/enchanter feeding them or the run caps to what's on hand. All destroy
        -- (no vendor value, don't stack). Keyed by gem; all produce the item "Unfired Idol".
        { item = 'Unfired Idol (Amber)',       disposal = DISPOSAL.DESTROY },  -- t=248 (Imbued Amber)
        { item = 'Unfired Idol (Rose Quartz)', disposal = DISPOSAL.DESTROY },  -- t=255 (Imbued Rose Quartz <- vendor-bought Star Rose Quartz)
        { item = 'Unfired Idol (Emerald)',     disposal = DISPOSAL.DESTROY },  -- t=282 (Imbued Emerald)
        { item = 'Unfired Star Ruby Encrusted Stein', disposal = DISPOSAL.DESTROY }, -- t=335 (Celestial Essence + Lacquered Star Ruby subcombines; carries ->300 cap)
    },
    Research = {
        -- Spell Research Kit recipes. Binding Powders are |dropped (world drops, mule-fed);
        -- the Spellcaster's Empowering Essences are |dropped too -- caster-SUMMONED by an
        -- Enchanter (Focus Mass ... spells), supply-limited like the cleric imbues. Binding
        -- Solution + Piece of Parchment are vendor. Default disposal Sell (user can change).
        { item = 'Vial of Pure Water',                  disposal = DISPOSAL.SELL },  -- t=54  (all vendor)
        { item = 'Crude Enchanted Spell Parchment',     disposal = DISPOSAL.SELL },  -- t=58  (Crude essence + Crude Binding Powder)
        { item = 'Refined Enchanted Spell Parchment',   disposal = DISPOSAL.SELL },  -- t=272 (Refined essence + Refined Binding Powder)
        { item = 'Intricate Enchanted Spell Parchment', disposal = DISPOSAL.SELL },  -- t=312 (Intricate essence + Intricate Binding Powder; carries ->300 cap)
    },
    Alchemy = {
        -- Medicine Bag; all ingredients vendor-bought. The first three are throwaway
        -- leveling fodder (Destroy); the Distillate is a useful heal-over-time potion we
        -- Keep. Disposal is per-recipe here (Alchemy is in fixedDisposalSkills).
        { item = "Kilva's Skin of Flame",             disposal = DISPOSAL.DESTROY },  -- t=136
        { item = 'Elixir of Concentration',           disposal = DISPOSAL.DESTROY },  -- t=212
        { item = 'Potion of Mystical Aptitude',       disposal = DISPOSAL.DESTROY },  -- t=255
        { item = 'Distillate of Celestial Healing X', disposal = DISPOSAL.KEEP },     -- t=348 (heal-over-time; keep, carries ->300 cap)
    },
    ['Make Poison'] = {
        -- Mortar and Pestle (Rogue-only). First three are vendor-only leveling fodder (Destroy);
        -- the XI poisons are Kept. Nigriventer/Gormar venoms are |dropped (farmed -- Request them).
        -- Quellious' Trauma needs the Refined Grade A Muscimol Extract |subcombine (recipe pending).
        { item = 'Atrophic Sap',         disposal = DISPOSAL.DESTROY },  -- t=98
        { item = 'Calcium Rot',          disposal = DISPOSAL.DESTROY },  -- t=172  (King's Thorn vendor TBD)
        { item = 'Spirit Of Sloth',      disposal = DISPOSAL.DESTROY },  -- t=275
        { item = "Spider's Bite XI",     disposal = DISPOSAL.KEEP },     -- t=324  (Nigriventer Venom|dropped)
        { item = "Quellious' Trauma XI", disposal = DISPOSAL.KEEP },     -- t=332  (Muscimol Extract|subcombine - pending)
        { item = "Scorpion's Agony XI",  disposal = DISPOSAL.KEEP },     -- t=335  (Gormar Venom|dropped; carries ->300 cap)
    },
    -- Tinkering (Gnome-only). Toolbox inventory kit. All products are junk (Destroy).
    -- Vendor mats are PoK-sold (Grease/Gears/Sprockets/Gnomish Bolts/Metal Rod/Smithy
    -- Hammer/Firewater); the |dropped mats (Small Piece of Acrylia, Knuckle Joint,
    -- Clockwork Carapace) are farmed/Requested. Note the skill gap 215->236 between the
    -- Geerlok's trivial and the Crab Cracker's usable range - add a filler rung if it stalls.
    Tinkering = {
        { item = 'Geerlok Automated Hammer', disposal = DISPOSAL.DESTROY },  -- t=215 (from ~102; Small Piece of Acrylia|dropped; eats a Smithy Hammer each combine)
        { item = 'Crab Cracker',             disposal = DISPOSAL.DESTROY },  -- t=288 (from ~236; Knuckle Joint|dropped)
        { item = 'Wok',                      disposal = DISPOSAL.DESTROY },  -- t=302 (from ~288; Clockwork Carapace|dropped)
    },
}

-- Hard skill caps per recommended path. Leveling stops once the EQ skill reaches
-- this value, even if higher-trivial recipes remain -- combines past the cap can't
-- raise skill and would just burn limited (farmed) materials.
local PATH_MAX_SKILL = {
    Tailoring = 300,
    Blacksmithing = 300,
    Jewelcrafting = 300,
    Fletching = 300,
}

-- Absolute skill ceiling. EQ tradeskills cap at 300, so leveling never crafts above this
-- for ANY tradeskill -- even if a recipe's trivial is higher (e.g. Champion Arrows 335) or
-- the tradeskill isn't listed in PATH_MAX_SKILL above. PATH_MAX_SKILL can only LOWER a
-- skill's effective cap below 300, never raise it.
local HARD_SKILL_CAP = 300

local UI = {
    round = 0,   -- 0 = crisp square corners (EQ look); was 8 (rounded)
    btn_w = 100,
    btn_h = 26,
    green = { 0.28, 0.62, 0.42, 1.0 },
    blue  = { 0.22, 0.42, 0.68, 1.0 },
    red   = { 0.62, 0.28, 0.28, 1.0 },
    amber = { 0.72, 0.52, 0.20, 1.0 },   -- armed "Confirm Start" state
    steel = { 0.18, 0.22, 0.30, 1.0 },
}

local state = {
    VERSION = '1.01',                              -- release version, shown in the title bar
    BUILD_TAG = 'dannet-first-2026-07-22',            -- release marker (log header + Settings = stale-copy check)
    running = true,
    windowOpen = true,
    wasOpen = true,
    sizeSet = false,

    iniPath = nil,
    iniSections = nil,
    skills = {},          -- ordered list of skill names, e.g. { 'Jewelcrafting' }
    skillIndex = 1,

    itemIndex = 1,
    quantityBuf = '1',
    disposalMode = DISPOSAL.KEEP,
    stopOnTrivial = true,

    statusMsg = '',
    busy = false,
    stopRequested = false,
    pauseRequested = false,   -- Pause button: suspend at the next checkpoint (resume continues in place)
    paused = false,           -- true while actually suspended in check_pause's spin
    log = {},

    doneCount = 0,
    totalCount = 0,

    -- Queue: list of { skillName, itemName, qty, disposal, stopOnTrivial }
    queue = {},
    queueRunning = false,
    currentQueueIndex = 0,

    -- Session stats
    sessionStarted = false,
    sessionSkillName = nil,       -- EQ skill name being tracked
    sessionSkillStart = nil,      -- skill level at session start
    sessionMade = 0,
    sessionFailed = 0,
    sessionFizzles = 0,           -- skill-fail fizzles across the session (salvage recovers mats)
    sessionDesyncs = 0,           -- desyncs across the session - the canary when running fast placement
    sessionStartTime = nil,
    sessionLastSkill = nil,

    -- Leveling plan
    levelPlan = {},           -- { skillName, itemName, trivial, disposal }
    levelPathName = '',       -- the RECOMMENDED_PATHS name backing the current plan (for keep-ingredients)
    keepIngredients = {},     -- per-path: true = don't sell leftover reagents when advancing rungs
    levelTargetBuf = '300',   -- target skill level
    levelBatchBuf = '100',    -- combines per attempt in leveling mode
    levelSkillFilter = '',    -- which EQ skill we're leveling
    levelRunning = false,
    levelSupplyFromGroup = false,  -- when a dropped mat runs out mid-level, refill from the group (Marr's)
    levelSupplyMode = 'needed',    -- 'needed' = pull one batch's worth per refill; 'all' = sweep everything the group has
    craftSupplyFromGroup = false,  -- Craft tab: pull this recipe's dropped-mat shortfall from the group on Start
    craftSupplyMode = 'needed',    -- 'needed' = exact shortfall; 'all' = sweep everything the group has
    crossZoneSupply = true,        -- when same-zone supply comes up short, ask the network who has the mats and
                                   -- travel to the OTHER hub (Marr/PoK, live or AFK mirror) if a holder is there.
                                   -- Ask-first: we only travel after confirming a reachable holder actually has it.
    summonCharCount = 1,           -- Welcome page: how many characters you're leveling (multiplies summon recommendations)
    welcomeDontDefault = false,    -- if true, skip the Welcome page on load and auto-select the first main skill < 300
    levelCurrentIndex = 0,
    recPathSelected = 'Welcome',   -- Leveling tab lands on the Welcome/guide page by default; the startup
                                   -- landing block only overrides this if the user ticked "don't open here".
    activeTab = 'Craft',      -- track active tab to restore after reloads
    pendingTabSelect = true,  -- force tab selection on first render
    levelStatusMsg = '',
    levelDisposal = DISPOSAL.SELL,
    -- Skills whose leveling products can't be vendored (forced to Destroy; Sell/Keep hidden).
    unsellableSkills = { Pottery = true },
    -- Skills that default to KEEP (not Sell) but still allow the user to pick Sell/Destroy/Keep. Tinkering
    -- products CAN be sold, but Keep is the sensible default (many are wanted, not vendored).
    keepDefaultSkills = { Tinkering = true },
    -- Skills that use the disposal set per-rung in RECOMMENDED_PATHS (radio hidden; some rungs
    -- kept, some destroyed -- e.g. Alchemy keeps the Distillate, destroys the leveling junk).
    fixedDisposalSkills = { Alchemy = true, ['Make Poison'] = true },
    -- Class-restricted leveling paths: hidden from the Skill Path dropdown unless the crafter
    -- is the matching class. Paths not listed are available to everyone.
    pathClassReq = { Alchemy = 'Shaman', ['Make Poison'] = 'Rogue' },
    -- Recipes red at confirm time, kept red during the run so skips stay visible (not recomputed).
    levelSkipSet = nil,
    levelRecipeSearch = '',   -- search filter for level tab recipe picker
    levelRecipeSelected = '', -- currently selected recipe in level tab

    pendingJob = nil,
    vendorMap  = {},
    vendorZone = {},
    stationLocs = {},

    -- Request tab: upfront supply list of { item, mode='stack'|'all' }
    requestQueue       = {},
    reqSkillSelected   = '',   -- skill chosen in the dropped-items dropdown
    reqSearchBuf       = '',   -- search filter over all dropped mats
    reqManualBuf       = '',   -- manual dropped-item entry
    reqParchManualBuf  = '',   -- manual parchment entry
}

-- The real leveling ceiling for a skill: the character's illusion-proof SkillCap (a class may
-- cap a skill below 300, e.g. Brewing 200), floored by any PATH_MAX_SKILL, never above the hard
-- cap. Both the start gate (level_plan_start) and the advance loop call this so they agree with
-- run_engine's in-combine stop. Assigned onto state (not a top-level local) to respect the
-- 200-local ceiling on the main chunk. eqSkill is the EQ TLO skill name; skillName is the plan's.
state.level_skill_ceiling = function(eqSkill, skillName)
    local realCap = eqSkill and (mq.TLO.Me.SkillCap(eqSkill)() or 0) or 0
    if realCap <= 0 then realCap = HARD_SKILL_CAP end   -- TLO unavailable: fall back to the hard cap
    return math.min((skillName and PATH_MAX_SKILL[skillName]) or HARD_SKILL_CAP, HARD_SKILL_CAP, realCap)
end

-- Dev-tab speed tuning. The CURRENT defaults are already the fastest stable speed (going
-- faster just desyncs), so 'fast' = current and the other four levels progressively ADD
-- pacing for machines/zones that need to back off. state.set_speed reassigns the captured
-- top-level knob (an upvalue), so the change takes effect live for every function that reads
-- it. The UI reads the active value back out of speedLevels so it never has to capture the
-- knobs itself (keeps the render function's upvalue count down).
state.speedLevels = {
    combinePace   = { fast = 375,  medium = 550,  slow = 750,  slower = 1000, slowest = 1500 },   -- pause after every combine
    placePace     = { blazing = 50, fast = 75, medium = 150, slow = 300 },   -- pause between slot placements; the ONE speed players tune. Data-backed sweep on Misty Thicket Picnic (the 8-placement product-on-cursor stress case): 100ms held ~400 combines and 50ms held 108, both with 0 real desyncs, so this ladder sits well inside proven-safe. Blazing (50) is send-it; Fast (75) is the expected default; Medium (150) comfortable; Slow (300) the old proven floor kept as a safety net for worse connections.
    combineSettle = { fast = 550,  medium = 800,  slow = 1100, slower = 1500, slowest = 2000 },   -- pause after staging, before /combine
    autoinvPace   = { fast = 750,  medium = 1000, slow = 1500, slower = 2000, slowest = 3000 },   -- pause between /autoinventory pulls
    failSettle    = { fast = 2000, medium = 2500, slow = 3000, slower = 4000, slowest = 5000 },   -- dead-wait after a world combine fails
}
state.speedSel = { combinePace = 'fast', placePace = 'fast', combineSettle = 'fast', autoinvPace = 'fast', failSettle = 'fast' }  -- placePace defaults to Fast (75ms), the data-backed expected pick; Blazing/Medium/Slow also available. Saved per-character settings override this on load.
state.set_speed = function(knob, lvl)
    local row = state.speedLevels[knob]
    local v = row and row[lvl]
    if not v then return end
    state.speedSel[knob] = lvl
    if knob == 'combinePace' then COMBINE_PACE_MS = v
    elseif knob == 'placePace' then PLACE_PACE_MS = v
    elseif knob == 'combineSettle' then COMBINE_SETTLE_MS = v
    elseif knob == 'autoinvPace' then AUTOINV_PACE_MS = v
    elseif knob == 'failSettle' then FAIL_SETTLE_MS = v end
    if state.save_settings then state.save_settings() end   -- auto-save (no-op while loading)
end
-- ---------------------------------------------------------------------------

local function trim(s)
    -- Linear-time trim. The old `^%s*(.-)%s*$` pattern backtracks O(L^2) on line
    -- length, which made load_config crawl when the ini contained a very long line.
    s = tostring(s or '')
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Encode/decode item names for transit over /dex .../ts_* commands. Spaces break MQ2's
-- arg tokenization and an apostrophe is treated as a quote delimiter (which mangled
-- "Intricate Spellcaster's Empowering Essence" - qty parsed as 0, made nothing). Map
-- both to letter-only sentinels that survive command parsing and never appear in EQ item
-- names. decode() reverses it for names that come BACK from a mule (e.g. /ts_madedone),
-- so the sentinel never leaks into display text. (One table, not two locals - the main
-- chunk sits at Lua's 200-local ceiling.)
local namecodec = {}
function namecodec.encode(name)
    return (tostring(name or ''):gsub("'", 'XAPOSX'):gsub(' ', '_'))
end
function namecodec.decode(name)
    return (tostring(name or ''):gsub('XAPOSX', "'"):gsub('_', ' '))
end

local function split_commas(s)
    local out = {}
    for piece in (s or ''):gmatch('[^,]+') do
        out[#out + 1] = trim(piece)
    end
    return out
end

local function file_exists(path)
    local fh = io.open(path, 'r')
    if fh then fh:close(); return true end
    return false
end

-- ---------------------------------------------------------------------------
-- File logging: mirror every printf_log line to TradeskillSuite_log.txt in the
-- same folder as this script. Keeps the last N runs (rolling) rather than wiping each
-- /lua run, timestamped, flushed per line so the log survives a crash.
-- ---------------------------------------------------------------------------
local LOG_FILE_PATH
do
    -- Resolve this script's own directory. debug.getinfo gives the .lua path;
    -- fall back to MQ's lua resource folder if that isn't usable.
    local dir
    local ok, src = pcall(function() return debug.getinfo(1, 'S').source end)
    if ok and src then
        src = tostring(src):gsub('^@', '')
        dir = src:match('^(.*[/\\])')
    end
    if not dir or dir == '' then
        local luaPath
        pcall(function() luaPath = mq.TLO.MacroQuest.Path('lua')() end)
        if luaPath and luaPath ~= '' then dir = luaPath .. '\\' end
    end
    local charName = ''
    pcall(function() charName = mq.TLO.Me.Name() or '' end)
    charName = charName:gsub('[^%w]', '')   -- EQ names are alphanumeric; strip anything odd for a safe filename
    local logName = (charName ~= '') and ('Lazcraft_' .. charName .. '_log.txt') or 'Lazcraft_log.txt'
    -- Logs live in <lazcraft>\Logs\ so the package folder isn't buried under one file per character.
    -- mkdir is fire-and-forget (harmless if it already exists); if the folder can't be used we fall
    -- back to the old location beside init.lua rather than silently losing logging.
    local logDir = (dir or '') .. 'Logs\\'
    pcall(function() os.execute('mkdir "' .. logDir:gsub('\\+$', '') .. '" 2>nul') end)
    LOG_FILE_PATH = logDir .. logName
    do
        local probe = io.open(LOG_FILE_PATH, 'a')
        if probe then probe:close() else LOG_FILE_PATH = (dir or '') .. logName end
    end
    local KEEP_SESSIONS = 10   -- keep this many recent runs; older ones roll off the top
    -- Instead of truncating, keep the last (KEEP_SESSIONS-1) sessions so this run becomes the
    -- newest of KEEP_SESSIONS. Each session begins with the '=== ... started' marker line.
    local prior = ''
    local rf = io.open(LOG_FILE_PATH, 'r')
    if rf then
        local content = rf:read('*a') or ''
        rf:close()
        local marker = '=== Lazcraft log - started'
        local sessions, idx = {}, 1
        while true do
            local s = content:find(marker, idx, true)
            if not s then break end
            local nxt = content:find(marker, s + #marker, true)
            sessions[#sessions + 1] = content:sub(s, (nxt and nxt - 1) or #content)
            if not nxt then break end
            idx = nxt
        end
        local first = math.max(1, #sessions - (KEEP_SESSIONS - 1) + 1)
        local keep = {}
        for i = first, #sessions do keep[#keep + 1] = sessions[i] end
        prior = table.concat(keep)
    end
    local fh = io.open(LOG_FILE_PATH, 'w')   -- rewrite: kept prior sessions + this fresh one
    if fh then
        if prior ~= '' then fh:write(prior) end
        fh:write(string.format('=== Lazcraft log - started %s [build %s] ===\n',
            os.date('%Y-%m-%d %H:%M:%S'), state.BUILD_TAG or '?'))
        fh:close()
        printf('\ag[Tradeskill]\ax logging to %s (keeping last %d runs) [build %s]', LOG_FILE_PATH, KEEP_SESSIONS, state.BUILD_TAG or '?')
    else
        LOG_FILE_PATH = nil   -- couldn't open the file; disable file logging quietly
    end
end

-- ---------------------------------------------------------------------------
-- Package directory + config resolution
-- ---------------------------------------------------------------------------
-- The Lazcraft install folder is wherever this script (init.lua) lives. We detect
-- it from the script's own path so the folder can be renamed/moved freely; all
-- configs (tradeskills/merchants/stations/research/fishing/drops) live alongside it.
do
    local dir
    local ok, src = pcall(function() return debug.getinfo(1, 'S').source end)
    if ok and src then
        src = tostring(src):gsub('^@', '')
        dir = src:match('^(.*[/\\])')
    end
    if not dir or dir == '' then
        local luaPath
        pcall(function() luaPath = mq.TLO.MacroQuest.Path('lua')() end)
        if luaPath and luaPath ~= '' then dir = (luaPath:gsub('[/\\]$', '')) .. '\\' end
    end
    state.pkgDir = dir or ''
end

-- Read a config: return the first existing path, searching the package folder first
-- then the legacy <MQ>\config, \Config, and \lua locations (so pre-migration installs
-- keep working). Returns nil if the file is nowhere to be found.
state.config_read = function(filename)
    local cands = {}
    if state.pkgDir ~= '' then cands[#cands + 1] = state.pkgDir .. filename end
    local mqPath = trim(mq.TLO.MacroQuest.Path() or '')
    if mqPath ~= '' then
        cands[#cands + 1] = mqPath .. '\\config\\' .. filename
        cands[#cands + 1] = mqPath .. '\\Config\\' .. filename
        cands[#cands + 1] = mqPath .. '\\lua\\' .. filename
    end
    for _, p in ipairs(cands) do
        if file_exists(p) then return p end
    end
    return nil
end

-- Where to WRITE a config: always the package folder (the canonical home). Falls back
-- to <MQ>\config only if the package dir somehow couldn't be detected.
state.config_write = function(filename)
    if state.pkgDir ~= '' then return state.pkgDir .. filename end
    local mqPath = trim(mq.TLO.MacroQuest.Path() or '')
    if mqPath ~= '' then return mqPath .. '\\config\\' .. filename end
    return filename
end

-- ─── Per-character settings ────────────────────────────────────────────────
-- Each character gets Settings\<Name>.ini in the package folder, holding their speed knob
-- selections and any recipes they've hand-added to a leveling path (which otherwise reset on
-- reload). Auto-saved on change; loaded once at startup.
state.customPathAdditions = {}   -- [pathName] = { recipeName, ... }  (persisted per character)
state.illusionName = ''       -- faction-zone illusion (Felwithe/Jaggedpine): Name + Type (Spell/Item/AA)
state.illusionType = 'Spell'  -- 'Spell' | 'Item' | 'AA'
state.shrinkName   = ''       -- optional shrink before a buy/craft approach; blank Name = never pause to shrink
state.shrinkType   = 'Item'   -- 'Spell' | 'Item' | 'AA'
state.settings_path = function()
    local char = ''
    pcall(function() char = mq.TLO.Me.Name() or '' end)
    char = char:gsub('[^%w]', '')
    if char == '' then char = 'default' end
    local base = (state.pkgDir ~= '' and state.pkgDir) or ''
    local dir  = base .. 'Settings\\'
    if not state._settingsDirMade then
        -- os.execute('mkdir ...') spawns a cmd.exe shell, which blocks for SECONDS inside the game -
        -- that was the whole load freeze. Only pay it if the dir truly doesn't exist: probe for the
        -- settings file first, then try a direct file write, and fall back to mkdir only if needed.
        local probe = io.open(dir .. char .. '.ini', 'r')
        if probe then
            probe:close()
        else
            local test = io.open(dir .. '.dirtest', 'w')
            if test then
                test:close(); os.remove(dir .. '.dirtest')
            else
                pcall(function() os.execute('mkdir "' .. dir:gsub('\\+$', '') .. '" >nul 2>nul') end)
            end
        end
        state._settingsDirMade = true
    end
    return dir .. char .. '.ini'
end
state.load_settings = function()
    state.customPathAdditions = {}
    state.keepIngredients = {}   -- fresh each load; repopulated from [KeepIngredients]
    state.cantBuy = {}   -- fresh each load; repopulated from [CantBuy]
    state._loadingSettings = true   -- suppress the auto-save that set_speed would otherwise trigger
    local fh = io.open(state.settings_path(), 'r')
    if not fh then state._loadingSettings = false; return end
    -- Read the whole file once, then split lines in memory. Per-line fh:lines() I/O crawls inside the
    -- game on Windows (the same trap the recipe parser avoids) - this was the multi-second load freeze.
    local content = fh:read('*a') or ''
    fh:close()
    -- Guard against a corrupt/bloated settings file taking down the whole load. It should be a few KB;
    -- anything huge is a bug (duplicate path-additions piling up), so cap what we process and warn.
    if #content > 512 * 1024 then
        printf_log('\arWARNING: settings file is %d KB (should be tiny) - it has bloated. Processing the first part only; consider deleting it to reset.\ax', math.floor(#content / 1024))
        content = content:sub(1, 512 * 1024)
    end
    local section = nil
    for rawline in content:gmatch('[^\r\n]+') do
        local line = (rawline:gsub('\r', '')):gsub('^%s+', ''):gsub('%s+$', '')
        if line == '' or line:sub(1, 1) == ';' then
            -- skip blanks/comments
        elseif line:sub(1, 1) == '[' then
            section = line:sub(2, -2)
        elseif section == 'Speed' then
            local k, v = line:match('^(.-)=(.*)$')
            if k and v and state.speedLevels and state.speedLevels[k] and state.set_speed then
                state.set_speed(k, v)
            end
        elseif section == 'Illusion' then
            local k, v = line:match('^(.-)=(.*)$')
            if k == 'Name' then state.illusionName = v or ''
            elseif k == 'Type' then state.illusionType = v or 'Spell'
            -- migrate old 3-key format (Spell=/Item=/AA=) -> Name + Type
            elseif k == 'Spell' and (v or '') ~= '' then state.illusionName = v; state.illusionType = 'Spell'
            elseif k == 'Item'  and (v or '') ~= '' then state.illusionName = v; state.illusionType = 'Item'
            elseif k == 'AA'    and (v or '') ~= '' then state.illusionName = v; state.illusionType = 'AA' end
        elseif section == 'Shrink' then
            local k, v = line:match('^(.-)=(.*)$')
            if k == 'Name' then state.shrinkName = v or ''
            elseif k == 'Type' then state.shrinkType = v or 'Item'
            elseif k == 'Item' and (v or '') ~= '' then state.shrinkName = v; state.shrinkType = 'Item' end
        elseif section == 'Welcome' then
            local k, v = line:match('^(.-)=(.*)$')
            if k == 'DontDefault' then state.welcomeDontDefault = (v == '1')
            elseif k == 'CharCount' then state.summonCharCount = math.max(1, math.min(6, tonumber(v) or 1)) end
        elseif section == 'Toggles' then
            local k, v = line:match('^(.-)=(.*)$')
            local function validDisp(x)
                if x == DISPOSAL.SELL or x == DISPOSAL.DESTROY or x == DISPOSAL.KEEP then return x end
                return nil
            end
            if k == 'CraftSupplyFromGroup' then state.craftSupplyFromGroup = (v == '1')
            elseif k == 'CrossZoneSupply' then state.crossZoneSupply = (v == '1')
            elseif k == 'LevelSupplyFromGroup' then state.levelSupplyFromGroup = (v == '1')
            elseif k == 'CraftDisposal' then state.disposalMode = validDisp(v) or state.disposalMode
            elseif k == 'LevelDisposal' then state.levelDisposal = validDisp(v) or state.levelDisposal end
        elseif section == 'CantBuy' then
            -- Items this character can't shop for (faction-gated vendors). Sourced from the group instead.
            local k, v = line:match('^(.-)=(.*)$')
            if k == 'Combines' then
                state.groupBuyCombines = tostring(tonumber(v) or 100)
            elseif k == 'JaggedQty' then
                state.jaggedBuyQty = tostring(math.max(1, math.min(6, tonumber(v) or 1)))
            else
                local item = line:match('^(.-)=1$') or line:match('^(.-)=true$')
                if item and item ~= '' then state.cantBuy[trim(item)] = true end
            end
        elseif section == 'KeepIngredients' then
            -- Per-path "don't sell tradeskill ingredients" toggles.
            local k = line:match('^(.-)=1$') or line:match('^(.-)=true$')
            if k and k ~= '' then state.keepIngredients[trim(k)] = true end
        elseif section and section:sub(1, 5) == 'Path:' then
            local skill = section:sub(6)
            local _, recipe = line:match('^(.-)=(.*)$')
            if recipe and recipe ~= '' then
                state.customPathAdditions[skill] = state.customPathAdditions[skill] or {}
                -- Dedup on load: a previously-bloated file self-heals (the next save writes the clean set).
                local dup = false
                for _, r in ipairs(state.customPathAdditions[skill]) do if r == recipe then dup = true; break end end
                if not dup then table.insert(state.customPathAdditions[skill], recipe) end
            end
        end
    end
    state._loadingSettings = false
    -- Seed the change-trackers so the first UI frame doesn't see a "change" vs nil and re-save.
    state._savedDisposalMode = state.disposalMode
    state._savedLevelDisposal = state.levelDisposal
end
state.save_settings = function()
    if state._loadingSettings then return end
    -- Preserve the listener's imbue gem slot. The TSL UI is the ONLY thing that SETS it, but it lives
    -- in this same per-character file - so read its current value off disk and re-emit it below,
    -- otherwise this wholesale rewrite would drop it. (Casters run both the suite and the listener.)
    local tslGemSlot
    do
        local rf = io.open(state.settings_path(), 'r')
        if rf then
            for line in rf:lines() do
                local gv = line:match('^GemSlot%s*=%s*(%d+)')
                if gv then tslGemSlot = gv end
            end
            rf:close()
        end
    end
    local fh = io.open(state.settings_path(), 'w')
    if not fh then return end
    fh:write('; Lazcraft per-character settings - auto-saved, safe to edit.\n\n')
    if tslGemSlot then fh:write('[TSL]\nGemSlot=' .. tslGemSlot .. '\n\n') end
    fh:write('[Speed]\n')
    for _, k in ipairs({ 'combinePace', 'placePace', 'combineSettle', 'autoinvPace', 'failSettle' }) do
        if state.speedSel and state.speedSel[k] then fh:write(k .. '=' .. state.speedSel[k] .. '\n') end
    end
    fh:write('\n[Illusion]\n')
    fh:write('Name=' .. (state.illusionName or '') .. '\n')
    fh:write('Type=' .. (state.illusionType or 'Spell') .. '\n')
    fh:write('\n[Shrink]\n')
    fh:write('Name=' .. (state.shrinkName or '') .. '\n')
    fh:write('Type=' .. (state.shrinkType or 'Item') .. '\n')
    fh:write('\n[Welcome]\n')
    fh:write('DontDefault=' .. (state.welcomeDontDefault and '1' or '0') .. '\n')
    fh:write('CharCount=' .. tostring(state.summonCharCount or 1) .. '\n')
    -- Per-character UI toggles that used to reset every session. Supply-from-group is a saved
    -- preference (worst case it no-ops when nobody's in zone - harmless), and the Sell/Destroy/Keep
    -- disposal choice on each tab is remembered so you don't reselect it every run.
    fh:write('\n[Toggles]\n')
    fh:write('CraftSupplyFromGroup=' .. (state.craftSupplyFromGroup and '1' or '0') .. '\n')
    fh:write('CrossZoneSupply=' .. (state.crossZoneSupply and '1' or '0') .. '\n')
    fh:write('LevelSupplyFromGroup=' .. (state.levelSupplyFromGroup and '1' or '0') .. '\n')
    fh:write('CraftDisposal=' .. tostring(state.disposalMode or DISPOSAL.SELL) .. '\n')
    fh:write('LevelDisposal=' .. tostring(state.levelDisposal or DISPOSAL.SELL) .. '\n')
    if next(state.cantBuy or {}) or (state.groupBuyCombines and state.groupBuyCombines ~= '1000') or (state.jaggedBuyQty and state.jaggedBuyQty ~= '1') then
        fh:write('\n[CantBuy]\n')
        fh:write('Combines=' .. tostring(state.groupBuyCombines or '100') .. '\n')
        fh:write('JaggedQty=' .. tostring(math.max(1, math.min(6, tonumber(state.jaggedBuyQty) or 1))) .. '\n')
        for item in pairs(state.cantBuy or {}) do fh:write(item .. '=1\n') end
    end
    if next(state.keepIngredients or {}) then
        fh:write('\n[KeepIngredients]\n')
        for path, on in pairs(state.keepIngredients) do
            if on then fh:write(path .. '=1\n') end
        end
    end
    for skill, recipes in pairs(state.customPathAdditions or {}) do
        if #recipes > 0 then
            fh:write('\n[Path:' .. skill .. ']\n')
            for i, r in ipairs(recipes) do fh:write('Recipe' .. i .. '=' .. r .. '\n') end
        end
    end
    fh:close()
end
-- Record/forget a hand-added recipe for a path, then persist.
state.remember_path_add = function(pathName, recipe)
    if not pathName or pathName == '' or not recipe or recipe == '' then return end
    state.customPathAdditions[pathName] = state.customPathAdditions[pathName] or {}
    for _, r in ipairs(state.customPathAdditions[pathName]) do if r == recipe then return end end
    table.insert(state.customPathAdditions[pathName], recipe)
    state.save_settings()
end
state.forget_path_add = function(pathName, recipe)
    local list = pathName and state.customPathAdditions[pathName]
    if not list then return end
    for i = #list, 1, -1 do if list[i] == recipe then table.remove(list, i) end end
    state.save_settings()
end

local function log_to_file(line)
    if not LOG_FILE_PATH then return end
    local fh = io.open(LOG_FILE_PATH, 'a')
    if not fh then return end
    fh:write(string.format('[%s] %s\n', os.date('%H:%M:%S'), line))
    fh:close()
end

-- File-only desync instrumentation. Writes straight to the log (no game-chat spam),
-- greppable with the 'DSDBG' prefix. Flip state.dsyncDbg off when done diagnosing.
state.dsyncDbg = false   -- diagnosis complete; probes dormant. Flip true to re-enable the DSDBG firehose.
function state.dlog(msg, ...)
    if not state.dsyncDbg then return end
    if select('#', ...) > 0 then msg = string.format(msg, ...) end
    log_to_file('DSDBG ' .. msg)
end

local function printf_log(msg, ...)
    if select('#', ...) > 0 then msg = string.format(msg, ...) end
    printf('\ag[Tradeskill]\ax %s', msg)        -- chat: any \a color codes embedded in msg render here
    local plain = (msg:gsub('\a%-?.', ''))      -- strip color codes for the file log + UI (no bell-char litter)
    log_to_file(plain)
    local l = state.log
    l[#l + 1] = plain
    while #l > 8 do table.remove(l, 1) end
    state.statusMsg = plain
end

-- Same-zone network peers. Returns names of characters on the comms network (E3/DanNet/EQBC) who are
-- in OUR zone right now, excluding self. This is who can supply mats: any networked character present in
-- the zone, whether grouped or not - so you can park a mule with mats here without grouping it. The
-- physical-presence filter (a pc spawn with ID>0) is what makes it correct: someone in another zone
-- can't hand over items, so they're excluded even if they're on the network. Peer-list source depends on
-- the network (DanNet underlies E3 on Lazarus, so DanNet.Peers covers both); every candidate is then
-- gated by the same-zone spawn check, so an over-broad peer list can't cause a bad pull.
state.same_zone_peers = function()
    local myName = mq.TLO.Me.Name() or ''
    local myZone = trim(mq.TLO.Zone.ShortName() or '')
    -- Collect candidate peer names (from DanNet, else EQBC, else group), then batch-query their zones in
    -- one parallel /dquery pass and keep those in OUR zone. Gate is actual zone, not spawn range - a mule
    -- can be in our zone but across the map (PoK is huge); we ask them and navigate over.
    local cands, seen = {}, {}
    local function addCand(nm)
        nm = tostring(nm or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if nm == '' or nm:lower() == myName:lower() or seen[nm:lower()] then return end
        seen[nm:lower()] = true
        cands[#cands + 1] = nm
    end
    local okD, peers = pcall(function() return mq.TLO.DanNet.Peers() end)
    if okD and peers and peers ~= '' then
        for entry in tostring(peers):gmatch('([^|]+)') do
            addCand(entry:match('_([^_]+)$') or entry:match('([^|]+)$') or entry)
        end
    end
    if #cands == 0 then
        local okE, ebnames = pcall(function() return mq.TLO.EQBC.Names() end)
        if okE and ebnames and ebnames ~= '' then
            for nm in tostring(ebnames):gmatch('([^%s,]+)') do addCand(nm) end
        end
    end
    if #cands == 0 then
        local gs = mq.TLO.Group.Members() or 0
        for i = 1, gs do
            local mem = mq.TLO.Group.Member(i)
            if mem and (mem.ID() or 0) > 0 then addCand(mem.Name() or '') end
        end
    end
    if #cands == 0 then return {} end
    local zones = state.query_peer_zones(cands)   -- parallel /dquery, one window
    local names = {}
    for _, nm in ipairs(cands) do
        if trim(zones[nm] or '') == myZone then names[#names + 1] = nm end
    end
    return names
end


-- Generic DanNet peer read, straight from Lua (no listener round-trip). Fires ONE /dquery, then polls
-- the peer's own DanNet[peer].Q[query] result off the TLO until it lands - a LIVE query, never a stale
-- observation (Observe lagged badly on zone changes, so we always query). Returns the value as a
-- trimmed string, or '' on timeout. This is the reusable version of the old hand-rolled zone read:
-- any peer MQ-TLO expression works - 'Zone.ShortName', 'Me.PctHPs', 'Me.CombatState', 'CountBuffs', etc.
-- CAVEAT: the query is a raw TLO expression sent through /dquery, so expressions with SPACES or quotes
-- (e.g. FindItemCount[=Powder of Ro]) are fragile to escape over the wire - that's exactly why item
-- supply goes through the TradeskillListener (clean command, peer parses the name locally) rather than
-- a direct dquery. Use this for simple, space-free reads.
state.dannet_query = function(peer, query, timeout)
    if not peer or peer == '' or not query or query == '' then return '' end
    timeout = timeout or 2000
    pcall(function() mq.cmdf('/dquery %s -q "%s"', peer, query) end)   -- QUOTE the query: names with spaces (FindItemCount[=Powder of Ro]) get chopped at the first space unquoted
    local dl = mq.gettime() + timeout   -- allow for the network round-trip
    while mq.gettime() < dl do
        mq.delay(40)
        local ok, v = pcall(function() return mq.TLO.DanNet(peer).Q(query)() end)
        if ok and v ~= nil and tostring(v) ~= '' and tostring(v) ~= 'NULL' then
            return (tostring(v)):gsub('^%s+', ''):gsub('%s+$', '')
        end
    end
    return ''
end

-- Numeric convenience: read a peer TLO number (0 on failure). e.g. state.dannet_number(peer, 'Me.PctHPs').
state.dannet_number = function(peer, query, timeout)
    return tonumber(state.dannet_query(peer, query, timeout)) or 0
end

-- Read a peer's on-hand count of an EXACT item directly via DanNet (no /ts_check listener round-trip).
-- FindItemCount[=name] returns 0 for none (a valid answer), so we distinguish that from a FAILED query:
-- returns the count (>=0) on success, or -1 if the query never came back (caller falls back to the
-- listener). Item names carry spaces / apostrophes - this test proves whether Laz's DanNet passes them
-- cleanly over /dquery; if it can't, we keep the listener for supply.
state.peer_item_count = function(peer, itemName)
    if not peer or peer == '' or not itemName or itemName == '' then return -1 end
    -- Count BOTH the peer's inventory AND its bank - a mule can deliver from either (its listener
    -- withdraws from the bank). FindItemCount = bags/equipped; FindItemBankCount = bank.
    local inv  = state.dannet_query(peer, string.format('FindItemCount[=%s]', itemName), 2000)
    local bank = state.dannet_query(peer, string.format('FindItemBankCount[=%s]', itemName), 2000)
    if inv == '' and bank == '' then return -1 end   -- both timed out / no reply
    return (tonumber(inv) or 0) + (tonumber(bank) or 0)
end

-- Query a SET of peers for their on-hand count of each item, listener-free, all in parallel (round-trips
-- overlap - mirrors query_peer_zones). Populates state.availReplies[item]=total and
-- state.availHolders[item]={peer=qty} EXACTLY as the old /ts_avail path did, so every downstream
-- delivery consumer is unchanged. Returns { itemName = total } for items at least one peer stocks.
state.peer_item_counts = function(peers, items)
    state.availReplies = {}
    state.availHolders = {}
    if not peers or #peers == 0 or not items or #items == 0 then return {} end
    -- Fire ONE query per peer per pass, never FindItemCount and FindItemBankCount to the same peer at
    -- once: on Laz's DanNet two concurrent queries to one peer collide (the second .Q read returns the
    -- FIRST query's result), so a BANK-only item read back its bags count (0) and got skipped -> bought.
    -- So for each item we sweep bags across all peers, read them, THEN sweep bank across all peers. This
    -- is the same one-query-per-peer shape as query_peer_zones, which never misbehaved.
    local function sweep(query)
        for _, pr in ipairs(peers) do
            pcall(function() mq.cmdf('/dquery %s -q "%s"', pr, query) end)
        end
        local res = {}
        local deadline = mq.gettime() + 2000
        while mq.gettime() < deadline do
            mq.delay(40)
            local pending = false
            for _, pr in ipairs(peers) do
                if res[pr] == nil then
                    local got
                    pcall(function()
                        local v = mq.TLO.DanNet(pr).Q(query)()
                        if v ~= nil and tostring(v) ~= '' and tostring(v) ~= 'NULL' then got = tonumber(tostring(v)) or 0 end
                    end)
                    if got ~= nil then res[pr] = got else pending = true end
                end
            end
            if not pending then break end
        end
        return res
    end
    for _, item in ipairs(items) do
        local inv  = sweep(('FindItemCount[=%s]'):format(item))
        local bank = sweep(('FindItemBankCount[=%s]'):format(item))
        for _, pr in ipairs(peers) do
            local total = (inv[pr] or 0) + (bank[pr] or 0)
            if total > 0 then
                state.availReplies[item] = (state.availReplies[item] or 0) + total
                state.availHolders[item] = state.availHolders[item] or {}
                state.availHolders[item][pr] = (state.availHolders[item][pr] or 0) + total
            end
        end
    end
    local avail = {}
    for _, item in ipairs(items) do
        if (state.availReplies[item] or 0) > 0 then avail[item] = state.availReplies[item] end
    end
    return avail
end

-- Read a networked peer's CURRENT zone remotely (works cross-zone, unlike the spawn check). Fail-safe:
-- an unreadable peer returns '' (not counted as "in a reachable hub", so we never travel on a guess).
-- NOTE: the AFK mirror shares its zone shortname with the regular zone, so this says "in a Marr/PoK
-- instance" but NOT live-vs-AFK - that's resolved later by the spawn check after we travel there.
state.peer_zone = function(name)
    if not name or name == '' then return '' end
    local z = state.dannet_query(name, 'Zone.ShortName', 2000)
    -- Fallback: if the query didn't land but the peer is in OUR zone, our own zone shortname applies.
    if z == '' then
        pcall(function()
            local sp = mq.TLO.Spawn(string.format('pc "%s"', name))
            if sp and (sp.ID() or 0) > 0 then z = tostring(mq.TLO.Zone.ShortName() or '') end
        end)
    end
    return (z or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

-- All networked peers (by name), regardless of zone - the full roster to check zones against. Same
-- enumeration as same_zone_peers but WITHOUT the same-zone spawn gate.
state.all_network_peers = function()
    local myName = mq.TLO.Me.Name() or ''
    local names, seen = {}, {}
    local function add(nm)
        nm = tostring(nm or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if nm ~= '' and nm:lower() ~= myName:lower() and not seen[nm:lower()] then
            seen[nm:lower()] = true; names[#names + 1] = nm
        end
    end
    local okD, peers = pcall(function() return mq.TLO.DanNet.Peers() end)
    if okD and peers and peers ~= '' then
        -- Lazarus: pipe-delimited "server_char" entries; take the name after the last underscore.
        for entry in tostring(peers):gmatch('([^|]+)') do
            add(entry:match('_([^_]+)$') or entry)
        end
    end
    if #names == 0 then
        local okE, ebnames = pcall(function() return mq.TLO.EQBC.Names() end)
        if okE and ebnames and ebnames ~= '' then
            for nm in tostring(ebnames):gmatch('([^%s,]+)') do add(nm) end
        end
    end
    return names
end

-- Peers whose current zone is in `zoneSet` (a set like { freeporttemple=true, poknowledge=true }).
-- Returns { name = zoneShortname }. Used to filter the roster to bots in a reachable hub before any
-- travel: a bot outside those zones is out of scope and ignored (no travel wasted on it).
state.peers_in_zones = function(zoneSet)
    local out = {}
    for _, nm in ipairs(state.all_network_peers()) do
        local z = state.peer_zone(nm)
        if z ~= '' and zoneSet[z] then out[nm] = z end
    end
    return out
end

-- Peer-execute abstraction. We send commands to other characters (start their listener,
-- ask for items). Most Lazarus players run E3 (mq2mono loaded), so prefer E3's /e3bct;
-- fall back to EQBC's /bct, then DanNet's /dex. Detected ONCE (plugins don't change mid-
-- session) and announced so it's clear which path is live. Defined AFTER printf_log so its
-- announce binds to the local. Kept on `state` (main chunk is at Lua's 200-local ceiling).
state.peerKind = nil
state.peer_cmdf = function(char, fmt, ...)
    local cmd = fmt:format(...)
    if not state.peerKind then
        -- Prefer DanNet: its echo can be silenced (/dnet localecho/commandecho off) and E3N rides on it anyway.
        -- Ensure it's actually loaded first; only fall back to E3/EQBC if DanNet can't be brought up.
        local dnet = mq.TLO.Plugin('MQ2DanNet')() ~= nil
        if not dnet then pcall(function() mq.cmd('/plugin mq2dannet load') end); mq.delay(750); dnet = mq.TLO.Plugin('MQ2DanNet')() ~= nil end
        if dnet then
            state.peerKind = 'dannet'
            pcall(function() mq.cmd('/squelch /dnet localecho off') end)
            pcall(function() mq.cmd('/squelch /dnet commandecho off') end)
            printf_log('Peer network: DanNet (/dex).')
        elseif mq.TLO.Plugin('mq2mono')() then
            state.peerKind = 'e3'
            printf_log('Peer network: E3 (/e3bct) [DanNet unavailable].')
        elseif mq.TLO.Plugin('MQ2EQBC')() then
            state.peerKind = 'eqbc'
            printf_log('Peer network: EQBC (/bct) [DanNet unavailable].')
        else
            state.peerKind = 'dannet'
            printf_log('Peer network: DanNet (/dex) [unverified].')
        end
    end
    if state.peerKind == 'e3' then
        mq.cmdf('/e3bct %s %s', char, cmd)
    elseif state.peerKind == 'eqbc' then
        mq.cmdf('/bct %s %s', char, cmd)
    else
        mq.cmdf('/dex %s %s', char, cmd)
    end
end

-- Verbose per-placement / per-combine tracing. Invaluable while diagnosing the world
-- desync, but it's ~9 lines per combine, which buries real events once things work.
-- Off by default; flip WDBG to true to turn the firehose back on for a debug run.
local WDBG = false  -- verbose per-placement/combine tracing. Off by default; flip true for a debug run.
local function wdbg(msg, ...)
    if not WDBG then return end
    if select('#', ...) > 0 then msg = string.format(msg, ...) end
    printf_log('  [wdbg] %s', msg)
end

-- ---------------------------------------------------------------------------
-- Config loading (tradeskills.ini)
-- ---------------------------------------------------------------------------

-- Open a file for reading, retrying briefly if it fails. Windows Defender / OneDrive can hold a
-- just-written file (like merchants.ini after a scan) under an exclusive lock for a moment - io.open
-- then returns nil and the caller wrongly concludes "file not found" (the intermittent load FAILURE,
-- distinct from the slow-but-succeeds stall). A few retries with a short wait rides out that lock.
-- Fast path pays nothing: if the first open succeeds (the normal case) it returns immediately.
-- (On state.X, not a file-level local, to stay under the main chunk's 200-local ceiling.)
state.open_read_retry = function(path, tries)
    if not path then return nil end
    tries = tries or 5
    for attempt = 1, tries do
        local fh = io.open(path, 'r')
        if fh then
            if attempt > 1 then printf_log('  (opened %s on attempt %d - was briefly locked)', path:match('[^\\/]+$') or path, attempt) end
            return fh
        end
        if attempt < tries then mq.delay(400) end   -- wait for AV/sync to release, then retry
    end
    return nil
end

local function parse_ini_file(iniPath)
    local sections = {}
    local order = {}
    local fh = state.open_read_retry(iniPath)   -- retry-open (survives a transient AV/OneDrive lock)
    if not fh then return sections, order end
    -- Read the whole file in one shot, then split lines in memory. Per-line file
    -- I/O (fh:lines()) is fast in a test harness but can crawl inside the game on
    -- Windows, so we avoid 80k+ small reads here.
    local content = fh:read('*a') or ''
    fh:close()
    local current = nil
    for line in content:gmatch('[^\r\n]+') do
        local stripped = trim(line)
        local c = stripped:byte(1)
        if c and c ~= 59 then                          -- not blank, not ';' comment
            if c == 91 then                            -- '[' -> only then pay for the section match
                local sec = stripped:match('^%[(.-)%]$')
                if sec then
                    current = trim(sec)
                    if not sections[current] then
                        sections[current] = {}
                        order[#order + 1] = current
                    end
                end
            elseif current then                        -- Key=Val: plain find beats the capture pattern
                local eq = stripped:find('=', 1, true)
                if eq then
                    sections[current][trim(stripped:sub(1, eq - 1))] = trim(stripped:sub(eq + 1))
                end
            end
        end
    end
    return sections, order
end

-- Parse ONE section's body text (Key=Val lines) into a table. Used by the lazy loader below.
state.parse_section_body = function(body)
    local t = {}
    for line in (body or ''):gmatch('[^\r\n]+') do
        local stripped = trim(line)
        local c = stripped:byte(1)
        if c and c ~= 59 then
            local eq = stripped:find('=', 1, true)
            if eq then t[trim(stripped:sub(1, eq - 1))] = trim(stripped:sub(eq + 1)) end
        end
    end
    return t
end

-- Lazy loader for the big recipe ini: a fast header-only scan that stores each section's RAW
-- body text and defers Key=Val parsing until the section is actually accessed. A session only
-- ever touches a handful of recipes, so this cuts load time ~3x on the 2.8MB file. Returns
-- rawStore (name -> body text) and order (section names in file order). Verified to produce
-- byte-identical parsed sections to the full parser.
state.parse_ini_lazy = function(path)
    local rawStore, order = {}, {}
    if not path then return rawStore, order end
    local fh = state.open_read_retry(path)
    if not fh then return rawStore, order end
    local content = '\n' .. (fh:read('*a') or '')   -- leading \n anchors the first header
    fh:close()
    local hdrs = {}
    for spos, name, epos in content:gmatch('()\n%[([^%]\r\n]+)%]()') do
        hdrs[#hdrs + 1] = { spos = spos, name = trim(name), epos = epos }
    end
    for i, h in ipairs(hdrs) do
        local bodyEnd = (hdrs[i + 1] and hdrs[i + 1].spos) or (#content + 1)
        local body = content:sub(h.epos, bodyEnd - 1)
        if rawStore[h.name] then
            rawStore[h.name] = rawStore[h.name] .. '\n' .. body   -- merge a duplicate section
        else
            rawStore[h.name] = body
            order[#order + 1] = h.name
        end
    end
    return rawStore, order
end

local function resolve_ini_path()
    -- Package folder first (via config_read), then the legacy config\/lua\ spots.
    -- config_write gives the package-folder default if it's a first run / not found.
    return state.config_read(INI_NAME) or state.config_write(INI_NAME)
end

local function load_config()
    local t0 = os.clock()
    printf_log('load_config: start')
    -- Timing note: the recipe PARSE is consistently ~0.15s. When a load is slow it's the merchants.ini /
    -- research.ini READ stalling for seconds - Windows Defender/OneDrive scanning those files right after
    -- the scanner rewrote them (the install lives under C:\Users\...\Desktop). The real fix is an AV/sync
    -- exclusion on the lazcraft folder (or moving the install off the Desktop). Nothing in Lua can make
    -- the OS release a scan-locked file faster, but we avoid redundant file opens below to cut exposure.
    local ok, err = pcall(function()
    local path = resolve_ini_path()
    state.iniPath = path
    printf_log('load_config: reading recipes from %s', path or '(no path)')
    local rawStore, order = state.parse_ini_lazy(path)
    printf_log('load_config: recipe parse took %.2fs', os.clock() - t0)
    state.iniRaw = rawStore
    state.iniOrder = order
    -- iniSections is a lazy view: a recipe's Key=Val body is parsed only when first accessed
    -- (get_recipe, subcombine checks, etc.) and cached, so load stays fast. pairs() over it only
    -- sees materialized sections - the two loops that need ALL sections iterate iniOrder instead.
    -- Case-insensitive section index: the recipe data mixes casing between section names ("Block Of
    -- High Quality Ore") and how ingredients reference them ("Block of..."), so exact lookups miss and
    -- the engine can't find the recipe (e.g. the Small Piece <- Small Brick "reduce" recipe). This maps
    -- lowercased name -> actual name; the iniSections __index falls back through it. Combined with the
    -- subcombine cycle guard, this safely unlocks the ore reduce chains (incl. dropped velium/acrylia).
    state.sectionCI = {}
    for _, secName in ipairs(order) do
        state.sectionCI[secName:lower()] = secName
    end
    state.iniSections = setmetatable({}, {
        __index = function(t, name)
            local body = rawStore[name]
            if not body then
                local actual = state.sectionCI[(name or ''):lower()]
                if actual and actual ~= name then body = rawStore[actual] end
            end
            if not body then return nil end
            local parsed = state.parse_section_body(body)
            rawset(t, name, parsed)
            return parsed
        end,
    })
    state.cyclicMatCache = {}   -- recipe graph changed; drop cached cyclic-material results
    printf_log('load_config: parsed %d sections', #order)

    state.skills = {}
    for _, secName in ipairs(order) do
        local skillName = secName:match('^Skill:(.+)$')
        if skillName then state.skills[#state.skills + 1] = skillName end
    end

    if #state.skills == 0 then
        printf_log('WARNING: no [Skill:...] sections found in %s.', path or '(no path)')
    end
    state.skillIndex = 1
    state.itemIndex = 1

    -- Load merchants.ini - builds a full item -> { vendors } map by inverting
    -- the entire merchants.ini. Every item any vendor sells is automatically
    -- mapped. [Vendors] in tradeskills.ini acts as an override on top of this,
    -- letting you force a specific vendor for an item if needed.
    local mqPath = trim(mq.TLO.MacroQuest.Path() or '')
    local merchantPath = state.config_read('merchants.ini')
    state.vendorMap  = {}   -- item -> { vendorName, ... } (list, closest picked at buy time)
    state.itemInfo   = {}   -- item -> { price = copper, stack = bool } from merchants.ini price,stack
    state.vendorZone = {}   -- vendorName -> zoneName (last seen; use vendor_zone_for for correctness)
    state.vendorZones = {}  -- vendorName -> { every zone this vendor appears in }
    state.vendorItemCount = {}   -- vendorName -> item count (from scan); gates the pre-open settle
    -- Open with retry: a just-rewritten merchants.ini can be briefly locked by Defender/OneDrive, making
    -- io.open return nil - without the retry that shows as "not found" and all prices vanish for the run.
    local merchFh = state.open_read_retry(merchantPath)
    if merchFh then
        -- Single-pass load: parse merchants.ini and build the vendor map DIRECTLY, without first
        -- materializing a full sections table and re-iterating it (that doubled the table-building
        -- and GC, which got slow once the filter-fix re-scans grew the file). Section keys are
        -- "VendorName##zone" (legacy: plain "VendorName"); the real name strips the ##zone, and the
        -- zone comes from the _Zone= line - so the SAME vendor can exist in multiple zones as
        -- distinct instances (e.g. Audri Deepfacet in PoK and Marr).
        local itemCount = 0
        local fh = merchFh
            local content = fh:read('*a') or ''
            fh:close()
            local curVendor, curZone, curCnt = nil, nil, 0
            local function flush()   -- record the section's item count (max across duplicate sections)
                if curVendor then
                    state.vendorItemCount[curVendor] = math.max(state.vendorItemCount[curVendor] or 0, curCnt)
                end
            end
            for line in content:gmatch('[^\r\n]+') do
                local stripped = trim(line)
                local c = stripped:byte(1)
                if c and c ~= 59 then                       -- not blank, not ';' comment
                    if c == 91 then                         -- '[' new vendor section
                        flush()
                        local sec = stripped:match('^%[(.-)%]$')
                        curVendor = sec and trim(sec:match('^(.-)##') or sec) or nil
                        curZone, curCnt = nil, 0
                    elseif curVendor then
                        local eq = stripped:find('=', 1, true)
                        if eq then
                            local key = trim(stripped:sub(1, eq - 1))
                            if key == '_Zone' then
                                curZone = trim(stripped:sub(eq + 1))
                                state.vendorZone[curVendor] = curZone
                                -- A vendor NAME can exist in several zones (Jaren Cloudchaser sells
                                -- arrow mats in Marr AND kits in PoK). vendorZone keeps only the last
                                -- one parsed, which makes the code think the other copy doesn't exist
                                -- and zone-hop needlessly. Record every zone; vendor_zone_for() picks.
                                local zl = state.vendorZones[curVendor]
                                if not zl then zl = {}; state.vendorZones[curVendor] = zl end
                                local dup = false
                                for _, z in ipairs(zl) do if z == curZone then dup = true; break end end
                                if not dup then zl[#zl + 1] = curZone end
                            elseif key:byte(1) ~= 95 then   -- skip other _-prefixed meta keys
                                curCnt = curCnt + 1
                                local list = state.vendorMap[key]
                                if not list then list = {}; state.vendorMap[key] = list end
                                list[#list + 1] = { name = curVendor, zone = curZone }
                                itemCount = itemCount + 1
                                -- Value is "price,stack" from the scanner (e.g. 94800,1); old scans
                                -- wrote a bare "1". Capture price + stackability into itemInfo for the
                                -- cost estimate and the buylast-from-stackable derivation. A bare "1"
                                -- leaves both nil (unknown), so the manual buylast flag still applies.
                                local val = trim(stripped:sub(eq + 1))
                                local p, s = val:match('^(%-?%d+)%s*,%s*([01])$')
                                if p then
                                    state.itemInfo = state.itemInfo or {}
                                    -- Keep the first non-zero price seen; stackability is item-wide.
                                    local info = state.itemInfo[key] or {}
                                    if not info.price or info.price == 0 then info.price = tonumber(p) end
                                    info.stack = (s == '1')
                                    state.itemInfo[key] = info
                                end
                            end
                        end
                    end
                end
            end
            flush()
            -- Zone-fill safety: if any section listed items BEFORE its _Zone line, those entries got
            -- a nil zone - backfill from the vendor's now-known zone so buy-time zone logic is correct.
            for _, list in pairs(state.vendorMap) do
                for _, inst in ipairs(list) do
                    if inst.zone == nil then inst.zone = state.vendorZone[inst.name] end
                end
            end
        printf_log('Loaded merchants.ini (%d item->vendor mappings) [%.2fs total].', itemCount, os.clock() - t0)
        state._lvCost = nil   -- prices may have changed - invalidate the leveling cost cache
        state._costCacheSig = nil   -- and the Craft-tab estimate cache
    else
        printf_log('merchants.ini not found - vendor lookups will fail. Run MerchantScanner to build it.')
    end

    -- Apply [Vendors] overrides from tradeskills.ini on top of merchants.ini.
    -- An entry here forces that specific vendor for the item, replacing the
    -- auto-discovered list. Useful for preferring one vendor over others.
    local vendorSec = state.iniSections['Vendors'] or {}
    for item, vendor in pairs(vendorSec) do
        if trim(vendor) ~= '' then
            local vn = trim(vendor)
            state.vendorMap[item] = { { name = vn, zone = state.vendorZone[vn] } }
        end
    end

    -- Load stations.ini - maps station names to { zone, loc } entries.
    -- Built by MerchantScanner's Stations tab. Multiple entries per station
    -- name are supported (one per zone). Keyed as stationName -> { zoneName -> loc }
    local stationPath = state.config_read('stations.ini')
    state.stationLocs = {}  -- stationName -> { {zone=z, loc=l}, ... }
    if stationPath and file_exists(stationPath) then
        local sSections, _ = parse_ini_file(stationPath)
        local stationCount = 0
        for rawName, data in pairs(sSections) do
            local stationName = rawName:match('^(.-)%|') or rawName
            local zone = data['Zone'] or 'unknown'
            local loc  = data['Loc']
            local target = data['Target']   -- optional: the world actor's targetable name if it
                                            -- differs from the station's config name (e.g. a PoK
                                            -- "Brewing Barrel" vs the usual "Brew Barrel")
            if loc then
                if not state.stationLocs[stationName] then
                    state.stationLocs[stationName] = {}
                end
                local entries = state.stationLocs[stationName]
                entries[#entries + 1] = { zone = zone, loc = loc, target = target }
                stationCount = stationCount + 1
            end
        end
        printf_log('Loaded stations.ini (%d station entries).', stationCount)
    end
    -- Load research.ini - standalone, class/level-tagged spell & tome recipes for
    -- the Research tab. [Recipe:<name>##<class>] sections merge into iniSections so
    -- the engine crafts them by their class-keyed name; [Research:<class>_<level>]
    -- sections build the class -> level -> names index the tab filters on.
    state.researchIndex   = {}   -- [class] = { [level] = { name, ... } }
    state.researchClasses = {}   -- sorted unique class names
    local researchPath = state.config_read('research.ini') or state.config_read('research_ini.ini')
    if researchPath then
        local rSections, rOrder = parse_ini_file(researchPath)
        local recipeCount = 0
        for _, secName in ipairs(rOrder) do
            if secName:sub(1, 7) == 'Recipe:' then
                state.iniSections[secName] = rSections[secName]
                state.iniOrder[#state.iniOrder + 1] = secName   -- so full-section scans see it
                recipeCount = recipeCount + 1
            else
                local cls, lvl = secName:match('^Research:(.+)_(%d+)$')
                if cls then
                    lvl = tonumber(lvl)
                    local idx = state.researchIndex[cls]
                    if not idx then idx = {}; state.researchIndex[cls] = idx end
                    local sec, names = rSections[secName], {}
                    local n = tonumber(sec.SpellCount) or 0
                    for i = 1, n do
                        local nm = sec['Spell' .. i]
                        if nm then names[#names + 1] = trim(nm) end
                    end
                    idx[lvl] = names
                end
            end
        end
        for cls in pairs(state.researchIndex) do
            state.researchClasses[#state.researchClasses + 1] = cls
        end
        table.sort(state.researchClasses)
        printf_log('Loaded %s (%d recipes, %d classes).', researchPath:match('[^\\]+$') or 'research.ini', recipeCount, #state.researchClasses)
    else
        printf_log('research.ini not found - Research tab will be empty.')
    end

    -- Mules are determined dynamically from group members at runtime
    -- No mules.ini needed
    state.mules = {}
    end)   -- end pcall body
    if not ok then printf_log('load_config: ERROR during load: %s', tostring(err)) end
    printf_log('load_config: DONE in %.2fs total.', os.clock() - t0)
end

-- The set of item names the suite could ever BUY: every recipe ingredient plus every container
-- (inventory kits like Mixing Bowl / Tackle Box). Scanned straight off the raw recipe bodies so it
-- doesn't force the lazy recipe parse. Everything else a vendor sells is dead weight in merchants.ini.
state.needed_items = function()
    local needed = {}
    for _, body in pairs(state.iniRaw or {}) do
        for name in body:gmatch('Ingredient%d+%s*=%s*([^|\r\n]+)') do needed[trim(name)] = true end
        for cont in body:gmatch('Container%s*=%s*([^\r\n]+)') do
            for c in cont:gmatch('[^,]+') do needed[trim(c)] = true end   -- Container can be a comma list
        end
    end
    return needed
end

-- Sorted list of every recipe name in the database (built once, cached) - powers the Add-typed
-- autocomplete on the Level tab. Keys look like "Recipe:<name>"; strip the prefix.
state.build_recipe_names = function()
    local names = {}
    for _, key in ipairs(state.iniOrder or {}) do
        local rn = key:match('^Recipe:(.+)$')
        if rn then names[#names + 1] = rn end
    end
    table.sort(names)
    return names
end

-- Forward-declared: current_skill_section's Radix branch calls current_item_name, which is
-- defined further down. Without this the call resolves to a nil global and the Craft tab render
-- crashes the instant Radix is selected. (Same local, just declared earlier - no new local.)
local current_item_name
local function current_skill_name()
    if state.craftActivityRadix then return 'Radix' end
    if state.craftActivityFishing then return 'Fishing' end
    return state.skills[state.skillIndex]
end

local function current_skill_section()
    -- Radix recipes span skills, so resolve the section from the selected recipe's
    -- container rather than from a 'Skill:' entry (there is no 'Skill:Radix').
    if state.craftActivityRadix then
        return state.skill_section_for_recipe(current_item_name())
    end
    local name = current_skill_name()
    if not name then return nil end
    return (state.iniSections or {})['Skill:' .. name]
end

local function current_skill_items()
    if state.craftActivityRadix then
        return state.radixRecipes or {}
    end
    local sec = current_skill_section()
    if not sec then return {} end
    local items = split_commas(sec.Items)
    -- Parity with the Level tab: fold in every leveling-path (RECOMMENDED_PATHS) recipe for
    -- this skill, so anything you can level is also pickable here. Deduped; any leveling rung
    -- the ini Items list doesn't already name is appended in path order. Programmatic, so the
    -- two lists can't drift.
    local path = RECOMMENDED_PATHS[current_skill_name()]
    if path then
        local seen = {}
        for _, it in ipairs(items) do seen[it] = true end
        for _, rung in ipairs(path) do
            if rung.item and not seen[rung.item] then
                seen[rung.item] = true
                items[#items + 1] = rung.item
            end
        end
    end
    table.sort(items)   -- Craft tab shows these alphabetically (ini/path order is arbitrary)
    return items
end

function current_item_name()
    -- A recipe picked via the Craft-tab search box overrides the combo, as long as it belongs to the
    -- skill currently selected (so switching skills auto-drops a stale pick). Radix bypasses the check.
    if state.craftPick and state.craftPick ~= '' then
        if state.craftActivityRadix or state.skill_name_for_recipe(state.craftPick) == current_skill_name() then
            return state.craftPick
        end
    end
    local items = current_skill_items()
    return items[state.itemIndex]
end

-- Sorted list of all recipe names for the level tab picker
state.all_recipe_names = function()
    local names = {}
    for _, k in ipairs(state.iniOrder or {}) do
        if k:sub(1,7) == 'Recipe:' and not k:find('##', 1, true) then
            names[#names+1] = k:sub(8)
        end
    end
    table.sort(names)
    return names
end

-- Raw, reduce-UNAWARE recipe lookup: always the default (build) recipe for a name, straight from the
-- ini. The planner and cyclic analysis use THIS so their structural view never depends on inventory.
-- On `state` (not a top-level local) - the main chunk is at Lua's 200-local ceiling.
state._rawRecipe = function(itemName)
    if not itemName then return nil end
    local sec = (state.iniSections or {})['Recipe:' .. itemName]
    if not sec then return nil end
    local rec = {
        name = (sec.Name and trim(sec.Name)) or itemName,
        key  = itemName,   -- section key for re-lookup; differs from name when Name= overrides
        yield = tonumber(sec.Yield) or 1,
        trivial = tonumber(sec.Trivial),
        sellable = sec.Sellable == nil or trim(sec.Sellable):lower() ~= 'false',
        disabled = sec.Disabled ~= nil and trim(sec.Disabled):lower() == 'true',
        containerOverride = sec.Container and trim(sec.Container) or nil,
        containerTypeOverride = sec.ContainerType and trim(sec.ContainerType):lower() or nil,
        navLocOverride = sec.NavLoc and trim(sec.NavLoc) or nil,
        ingredients = {},
    }
    local i = 1
    while true do
        local raw = sec['Ingredient' .. i]
        if not raw then break end
        -- Strip inline comments
        raw = raw:match('^(.-)%s*;.*$') or raw
        -- Format: Name|Qty or Name|Qty|flag[|flag...]
        -- flags can be: subcombine, returned, dropped, buylast (and may combine,
        -- e.g. Name|1|returned|buylast)
        local ingName, qtyStr, flag = raw:match('^(.-)%|(%d+)%|(.+)$')
        if not ingName then
            ingName, qtyStr = raw:match('^(.-)%|(%d+)$')
        end
        if ingName then
            local flagSet = {}
            if flag then
                for f in flag:gmatch('[^|]+') do flagSet[trim(f):lower()] = true end
            end
            rec.ingredients[#rec.ingredients + 1] = {
                name       = trim(ingName),
                qty        = tonumber(qtyStr) or 1,
                subcombine = flagSet['subcombine'] or false,
                returned   = flagSet['returned'] or false,
                dropped    = flagSet['dropped'] or false,
                buylast    = flagSet['buylast'] or false,
            }
        end
        i = i + 1
    end
    return rec
end

state.reduceChains = {
    ['Small Piece of Velium'] = { section = 'Small Piece Of Velium',       from = 'Small Brick of Velium' },
    ['Small Brick of Velium'] = { section = 'Reduce Small Brick Of Velium', from = 'Large Brick of Velium' },
    ['Large Brick of Velium'] = { section = 'Reduce Large Brick Of Velium', from = 'Block of Velium' },
}
-- Should we REDUCE to get this form - is a bigger form on hand, or is a bigger form itself reducible
-- from something on hand? If so, chisel down instead of building up. On `state` (200-local ceiling).
state.should_reduce = function(form, seen)
    local rc = state.reduceChains[form]
    if not rc then return false end
    seen = seen or {}
    if seen[form] then return false end
    seen[form] = true
    local function ic(nm)
        local ok, n = pcall(function() return mq.TLO.FindItemCount('=' .. nm)() end)
        return (ok and type(n) == 'number') and n or 0
    end
    if ic(rc.from) > 0 then return true end
    if state.reduceChains[rc.from] then return state.should_reduce(rc.from, seen) end
    return false
end

-- Reduce-AWARE recipe lookup. For a reduce-chain form, when a bigger form is on hand (or reducible),
-- return the REDUCE recipe (same output item) so the engine chisels down instead of building up.
-- Everything else falls straight through to the raw build recipe, unchanged and inventory-independent.
local function get_recipe(itemName)
    if not itemName then return nil end
    local rc = state.reduceChains[itemName]
    if rc and state.should_reduce(itemName) then
        return state._rawRecipe(rc.section)
    end
    return state._rawRecipe(itemName)
end

-- True if any ingredient is a farmed/dropped material (mule-supplied). Such
-- recipes are mat-limited, so leveling crafts them until the material runs out
-- and then moves on rather than re-selecting and stalling on empty mules.
local function recipe_has_dropped(rec)
    if not rec then return false end
    for _, ing in ipairs(rec.ingredients) do
        if ing.dropped then return true end
    end
    return false
end

-- The five spell-research parchments (all mob drops, none vendor-bought). These
-- aren't tradeskill recipe ingredients, so they live here rather than in the ini.
local REQUEST_PARCHMENTS = {
    'Grimy Fine Runic Parchment',   -- research lvl 66
    'Dirty Vellum',                 -- research lvl 67
    'Grubby Fine Vellum',           -- research lvl 68
    'Shabby Runic Vellum',          -- research lvl 69
    'Sooty Fine Runic Vellum',      -- research lvl 70
}

-- Lazily-built indexes of dropped/farmed mats for the Request tab pickers.
-- _droppedBySkill[skill] = sorted unique dropped mats used in that skill's
-- leveling path; _droppedAll = sorted unique dropped mats anywhere in the ini.
local _droppedBySkill, _droppedAll
state.build_dropped_indexes = function()
    _droppedBySkill = {}
    local allSet = {}

    -- Curated supplement for the Request "Dropped Materials" picker, layered on top of
    -- the leveling-path derivation below. Function-scoped (the main chunk is at Lua's
    -- local ceiling, so this can't be a top-level local).
    --   add  = always show for this skill, even if no leveling recipe contributes it
    --   hide = never show, even if a recipe flags it 'dropped' (the Imbued gems are
    --          flagged dropped in pottery recipes but are really caster-summoned, so
    --          they belong under Made-by-Casters, not here)
    local EXTRA = {
        Tailoring = { add = { 'Superb Silk', 'Superb Animal Pelt', 'Pristine Silk', 'Pristine Animal Pelt' } },
        Baking    = { add = { 'Brownie Parts', 'Fruit' } },
        Pottery   = { hide = { 'Imbued Amber', 'Imbued Rose Quartz', 'Imbued Emerald' } },
        -- Hand me item lists and I'll fill these in:
        -- Alchemy      = { add = { ... } },
        -- Blacksmithing= { add = { ... } },
        -- Brewing      = { add = { ... } },
        -- ['Make Poison'] = { add = { ... } },
    }
    local globalHide = {}
    for _, ex in pairs(EXTRA) do
        for _, h in ipairs(ex.hide or {}) do globalHide[h] = true end
    end

    -- (a) per leveling skill, from its recommended-path recipes. Each path entry
    -- is a { item = name, disposal = ... } table, so pull the name off it.
    local buckets = {}
    for skillName, recipeList in pairs(RECOMMENDED_PATHS) do
        local seen, list = {}, {}
        for _, entry in ipairs(recipeList) do
            local rec = get_recipe(entry.item)
            if rec then
                for _, ing in ipairs(rec.ingredients) do
                    if ing.dropped and not seen[ing.name] then
                        seen[ing.name] = true
                        list[#list + 1] = ing.name
                    end
                end
            end
        end
        buckets[skillName] = { seen = seen, list = list }
    end

    -- (a2) merge the always-show supplement (create a bucket if the skill has no path).
    for skillName, ex in pairs(EXTRA) do
        local b = buckets[skillName]
        if not b then b = { seen = {}, list = {} }; buckets[skillName] = b end
        for _, nm in ipairs(ex.add or {}) do
            if not b.seen[nm] then b.seen[nm] = true; b.list[#b.list + 1] = nm end
        end
    end

    -- (a2b) merge the user's own persisted additions (Request tab "Add item" box).
    if not state.userDrops then state.loadUserDrops() end
    for skillName, set in pairs(state.userDrops or {}) do
        local b = buckets[skillName]
        if not b then b = { seen = {}, list = {} }; buckets[skillName] = b end
        for nm in pairs(set) do
            if not b.seen[nm] then b.seen[nm] = true; b.list[#b.list + 1] = nm end
        end
    end

    -- (a3) finalize: drop hidden items, sort, feed the global "search all" set.
    for skillName, b in pairs(buckets) do
        local final = {}
        for _, nm in ipairs(b.list) do
            if not globalHide[nm] then
                final[#final + 1] = nm
                allSet[nm] = true
            end
        end
        table.sort(final)
        _droppedBySkill[skillName] = final
    end

    -- (b) every dropped ingredient anywhere in the ini (light raw scan -- no full
    -- recipe build, since this sweeps thousands of sections). Hidden items stay out.
    for _, secName in ipairs(state.iniOrder or {}) do
        if secName:match('^Recipe:') then
            local sec = state.iniSections[secName]   -- lazily parses & caches this section
            if type(sec) == 'table' then
                local j = 1
                while true do
                    local raw = sec['Ingredient' .. j]
                    if not raw then break end
                    raw = raw:match('^(.-)%s*;.*$') or raw
                    local name, rest = raw:match('^(.-)%|%d+%|(.+)$')
                    if name and rest then
                        for f in rest:gmatch('[^|]+') do
                            if trim(f):lower() == 'dropped' and not globalHide[trim(name)] then
                                allSet[trim(name)] = true
                            end
                        end
                    end
                    j = j + 1
                end
            end
        end
    end

    _droppedAll = {}
    for name in pairs(allSet) do _droppedAll[#_droppedAll + 1] = name end
    table.sort(_droppedAll)
end
-- Build once, but never let a data hiccup here propagate into the render loop
-- (an uncaught error mid-frame leaves ImGui's stack unbalanced and pauses the
-- overlay). On failure we fall back to empty lists -- search/manual still work.
local function ensure_dropped_indexes()
    if _droppedBySkill and _droppedAll then return end
    pcall(state.build_dropped_indexes)
    _droppedBySkill = _droppedBySkill or {}
    _droppedAll     = _droppedAll or {}
end
local function dropped_by_skill()
    ensure_dropped_indexes()
    return _droppedBySkill
end
local function dropped_all()
    ensure_dropped_indexes()
    return _droppedAll
end

-- Invalidate the cached pickers so the next dropped_by_skill()/dropped_all() rebuilds
-- (called after the user adds/removes a custom item). Lives here so it can see the
-- _droppedBySkill / _droppedAll upvalues; kept on state to dodge the local ceiling.
state.invalidate_dropped = function() _droppedBySkill = nil; _droppedAll = nil end

-- User-curated "always-show" additions to the Request "Dropped Materials" picker, kept
-- in <MQ>\config\TradeskillRequestDrops.ini so they survive a /lua restart. Format is a
-- plain [Skill] section per skill with one "Item Name=1" per line - editable in-game via
-- the Request tab's "Add item" box, or by hand. Merged into the picker in
-- build_dropped_indexes alongside the hard-coded EXTRA table.
state.userDrops = nil   -- skill -> { [item] = true }; nil until first load
state.userDropsPath = function()
    return state.config_write('TradeskillRequestDrops.ini')
end
state.loadUserDrops = function()
    state.userDrops = {}
    local path = state.config_read('TradeskillRequestDrops.ini')
    if not path then return end
    local ok, sections = pcall(parse_ini_file, path)
    if not ok or not sections then return end
    for skill, items in pairs(sections) do
        local set = {}
        for item in pairs(items) do set[item] = true end
        state.userDrops[trim(skill)] = set
    end
end
state.saveUserDrops = function()
    local path = state.userDropsPath()
    if not path then return false end
    local fh = io.open(path, 'w')
    if not fh then return false end
    fh:write('; Tradeskill Suite - user-added Request "Dropped Materials" items.\n')
    fh:write('; One [Skill] section per skill, then "Item Name=1" per line.\n')
    fh:write('; Add/remove these in-game on the Request tab, or edit here directly.\n\n')
    local skills = {}
    for s in pairs(state.userDrops or {}) do skills[#skills + 1] = s end
    table.sort(skills)
    for _, s in ipairs(skills) do
        local items = {}
        for it in pairs(state.userDrops[s]) do items[#items + 1] = it end
        if #items > 0 then
            table.sort(items)
            fh:write(('[%s]\n'):format(s))
            for _, it in ipairs(items) do fh:write(('%s=1\n'):format(it)) end
            fh:write('\n')
        end
    end
    fh:close()
    return true
end
state.addUserDrop = function(skill, item)
    item, skill = trim(item or ''), trim(skill or '')
    if item == '' or skill == '' then return false end
    if not state.userDrops then state.loadUserDrops() end
    state.userDrops[skill] = state.userDrops[skill] or {}
    state.userDrops[skill][item] = true
    state.saveUserDrops()
    state.invalidate_dropped()
    return true
end
state.removeUserDrop = function(skill, item)
    if not state.userDrops or not state.userDrops[skill] then return end
    state.userDrops[skill][item] = nil
    state.saveUserDrops()
    state.invalidate_dropped()
end
state.isUserDrop = function(skill, item)
    return state.userDrops and state.userDrops[skill] and state.userDrops[skill][item] or false
end

-- Fishing catch lists. Two buckets - Destroy and Keep - of item names, built in-game by
-- holding a catch on the cursor and clicking Keep/Destroy on the Fishing (leveling) activity.
-- Persisted to config\fishing.ini ([Destroy]/[Keep], "Item Name=1" per line). The fishing
-- loop /destroys cursor items on the Destroy list and bags Keep-listed (and unlisted) ones.
state.fishListPath = function()
    return state.config_write('fishing.ini')
end
state.loadFishLists = function()
    state.fishLists = { destroy = {}, keep = {} }
    local path = state.config_read('fishing.ini')
    if not path then return end
    local ok, sections = pcall(parse_ini_file, path)
    if not ok or not sections then return end
    for name in pairs(sections['Destroy'] or {}) do state.fishLists.destroy[trim(name)] = true end
    for name in pairs(sections['Keep']    or {}) do state.fishLists.keep[trim(name)]    = true end
end
state.saveFishLists = function()
    local path = state.fishListPath()
    if not path or not state.fishLists then return false end
    local fh = io.open(path, 'w')
    if not fh then return false end
    fh:write('; Tradeskill Suite - fishing catch handling.\n')
    fh:write('; [Destroy] items are /destroyed when caught; [Keep] items are bagged.\n')
    fh:write('; Build these in-game: hold a catch on the cursor and click Keep/Destroy on\n')
    fh:write('; the Fishing (leveling) activity, or edit here directly ("Item Name=1").\n\n')
    for _, bucket in ipairs({ 'Destroy', 'Keep' }) do
        local set = state.fishLists[bucket:lower()] or {}
        local items = {}
        for it in pairs(set) do items[#items + 1] = it end
        table.sort(items)
        fh:write(('[%s]\n'):format(bucket))
        for _, it in ipairs(items) do fh:write(('%s=1\n'):format(it)) end
        fh:write('\n')
    end
    fh:close()
    return true
end
-- Add `item` to a bucket ('destroy' or 'keep'). An item lives in exactly one bucket, so
-- adding to one clears it from the other (lets you re-classify a mistake in one click).
state.addFishItem = function(bucket, item)
    item = trim(item or '')
    if item == '' or (bucket ~= 'destroy' and bucket ~= 'keep') then return false end
    if not state.fishLists then state.loadFishLists() end
    local other = (bucket == 'destroy') and 'keep' or 'destroy'
    state.fishLists[other][item] = nil
    state.fishLists[bucket][item] = true
    state.saveFishLists()
    return true
end
state.removeFishItem = function(bucket, item)
    if not state.fishLists or not state.fishLists[bucket] then return end
    state.fishLists[bucket][item] = nil
    state.saveFishLists()
end

-- Items a caster mule MAKES on request. `classes` lists EVERY class that can produce it (same spell
-- name across classes), so summons can be load-balanced across whoever's in the group. `class` is
-- kept as the primary/first for older single-producer code paths.
local MAKEABLE = {
    -- group drives the Request-tab collapsible sections: 'mana'/'vials'/'metal' live under "Casters",
    -- 'gems' under "Priests". (class/classes are unchanged - purely for who actually produces.)
    { item = 'Large Block of Magic Clay', group = 'metal', class = 'Enchanter', classes = { 'Enchanter' } },
    { item = 'Vial of Clear Mana',        group = 'vials', class = 'Enchanter', classes = { 'Enchanter' } },
    { item = 'Vial of Purified Mana',     group = 'vials', class = 'Enchanter', classes = { 'Enchanter' } },
    { item = 'Vial of Distilled Mana',    group = 'vials', class = 'Enchanter', classes = { 'Enchanter' } },
    { item = "Crude Spellcaster's Empowering Essence",     group = 'mana', class = 'Enchanter', classes = { 'Enchanter', 'Magician', 'Wizard', 'Necromancer' } },
    { item = "Refined Spellcaster's Empowering Essence",   group = 'mana', class = 'Enchanter', classes = { 'Enchanter', 'Magician', 'Wizard', 'Necromancer' } },
    { item = "Intricate Spellcaster's Empowering Essence", group = 'mana', class = 'Enchanter', classes = { 'Enchanter', 'Magician', 'Wizard', 'Necromancer' } },
    { item = 'Enchanted Electrum Bar',    group = 'metal', class = 'Enchanter', classes = { 'Enchanter' } },
    { item = 'Enchanted Silver Bar',      group = 'metal', class = 'Enchanter', classes = { 'Enchanter' } },
    { item = 'Enchanted Gold Bar',        group = 'metal', class = 'Enchanter', classes = { 'Enchanter' } },
    { item = 'Enchanted Platinum Bar',    group = 'metal', class = 'Enchanter', classes = { 'Enchanter' } },
    { item = 'Enchanted Velium Bar',      group = 'metal', class = 'Enchanter', classes = { 'Enchanter' } },
    { item = 'Enchanted Lrg. Brick of Adamantite', group = 'metal', class = 'Enchanter', classes = { 'Enchanter' } },
    { item = 'Enchanted Lrg. Brick of Brellium',   group = 'metal', class = 'Enchanter', classes = { 'Enchanter' } },
    { item = 'Enchanted Lrg. Brick of Mithril',    group = 'metal', class = 'Enchanter', classes = { 'Enchanter' } },
    -- Deity-idol gem imbues (one idol per character's deity). classes = every class that can make it.
    -- Buyable gems (bought + imbued):
    { item = 'Imbued Amber',        group = 'gems', class = 'Cleric', classes = { 'Cleric', 'Druid', 'Shaman' } },
    { item = 'Imbued Jade',         group = 'gems', class = 'Druid',  classes = { 'Druid', 'Shaman' } },           -- no Cleric
    { item = 'Imbued Peridot',      group = 'gems', class = 'Cleric', classes = { 'Cleric', 'Druid' } },
    { item = 'Imbued Topaz',        group = 'gems', class = 'Cleric', classes = { 'Cleric', 'Druid' } },
    { item = 'Imbued Opal',         group = 'gems', class = 'Cleric', classes = { 'Cleric', 'Druid' } },
    { item = 'Imbued Sapphire',     group = 'gems', class = 'Cleric', classes = { 'Cleric', 'Druid', 'Shaman' } },
    { item = 'Imbued Ruby',         group = 'gems', class = 'Cleric', classes = { 'Cleric', 'Druid' } },
    { item = 'Imbued Emerald',      group = 'gems', class = 'Cleric', classes = { 'Cleric', 'Druid' } },
    { item = 'Imbued Rose Quartz',  group = 'gems', class = 'Cleric', classes = { 'Cleric', 'Druid' } },           -- made from vendor-bought Star Rose Quartz
    -- Farmed gems (base gem not vendor-sold; caster imbues supplied/on-hand gems):
    { item = 'Imbued Black Pearl',    group = 'gems', class = 'Cleric', classes = { 'Cleric', 'Druid' },           needs = 'Black Pearl' },
    { item = 'Imbued Plains Pebble',  group = 'gems', class = 'Cleric', classes = { 'Cleric', 'Druid' },           needs = 'Plains Pebble' },
    { item = 'Imbued Ivory',          group = 'gems', class = 'Druid',  classes = { 'Druid', 'Shaman' },           needs = 'Ivory' },          -- no Cleric
    { item = 'Imbued Fire Opal',      group = 'gems', class = 'Druid',  classes = { 'Druid', 'Wizard' },           needs = 'Fire Opal' },      -- no Cleric
    { item = 'Imbued Black Sapphire', group = 'gems', class = 'Cleric', classes = { 'Cleric', 'Druid' },           needs = 'Black Sapphire' },
    { item = 'Imbued Diamond',        group = 'gems', class = 'Cleric', classes = { 'Cleric', 'Druid', 'Shaman' }, needs = 'Diamond' },
}

-- Request-queue helpers (Request tab). Entries are { item, mode='stack'|'all'|'make', qty }.
-- qty is only used by 'make' (how many to produce); stack/all ignore it.
local function request_queue_add(item, mode, qty)
    item = trim(item or '')
    if item == '' then return end
    for _, e in ipairs(state.requestQueue) do
        if e.item:lower() == item:lower() then
            if mode == 'make' then e.mode = 'make'; if qty then e.qty = qty end end   -- flip to Make in place
            return
        end
    end
    if mode == 'make' then
        state.requestQueue[#state.requestQueue + 1] = { item = item, mode = 'make', qty = qty }
    else
        -- Pull item: starts as "All" (empty qty box). Type a number per item to make it exact.
        state.requestQueue[#state.requestQueue + 1] = { item = item, mode = 'pull', qtyBuf = '' }
    end
end
local function request_queue_remove(i)
    table.remove(state.requestQueue, i)
end
local function request_queue_clear()
    state.requestQueue = {}
end
local function request_queue_run()
    if state.busy or #state.requestQueue == 0 then return end
    local reqs = {}
    for _, e in ipairs(state.requestQueue) do
        reqs[#reqs + 1] = { item = e.item, mode = e.mode, qty = e.qty, from = e.from or '' }
    end
    -- Each entry now carries its own source (e.from); '' = group/own-bank-first.
    state.pendingJob = { action = 'request', requests = reqs }
end

-- All DROPPED (farmed) mats in a recipe's tree, in first-seen order, excluding NO-DROP items (which
-- can't be traded). Drives the per-recipe Radix "farmed mats" request buttons.
state.droppedMatsInTree = function(rec)
    if not rec then return {} end
    local out, seen = {}, {}
    local function walk(r, depth)
        if not r or depth > 8 then return end
        for _, ing in ipairs(r.ingredients or {}) do
            if ing.dropped and not seen[ing.name] and not state.NODROP_ITEMS[ing.name] then
                seen[ing.name] = true
                out[#out + 1] = ing.name
            end
            if (state.iniSections or {})['Recipe:' .. ing.name] then
                walk(get_recipe(ing.name), depth + 1)
            end
        end
    end
    walk(rec, 0)
    return out
end

-- ---------------------------------------------------------------------------
-- Inventory / item helpers
-- ---------------------------------------------------------------------------

-- Count only what's in BAGS, NOT worn/equipped slots. MacroQuest's FindItemCount includes equipped
-- items AND the augments slotted into them, so an aug that shares a name with a tradeskill ingredient
-- (e.g. "Bat Wings" the aug vs "Bat Wings" the TS item) would falsely inflate the count - the suite
-- would think it already had the ingredient, skip the buy, then fail to place it (it's in your gear,
-- not a bag). Tradeskill mats always live in bags, so bags-only is the correct scope. (Bank is
-- counted separately via bank_count / the DanNet bank query.)
local function item_count(name)
    local target = (name or ''):lower()
    local total = 0
    local ok = pcall(function()
        for pk = 1, 12 do
            local slot = mq.TLO.Me.Inventory('pack' .. pk)
            if (slot.ID() or 0) > 0 then
                local cap = slot.Container() or 0
                if cap > 0 then                              -- a bag: count its contents
                    for i = 1, cap do
                        local it = slot.Item(i)
                        if (it.ID() or 0) > 0 and (it.Name() or ''):lower() == target then
                            local n = it.Stack() or 1
                            total = total + (n < 1 and 1 or n)
                        end
                    end
                elseif (slot.Name() or ''):lower() == target then   -- a plain item directly in an inventory slot
                    local n = slot.Stack() or 1
                    total = total + (n < 1 and 1 or n)
                end
            end
        end
    end)
    if not ok then return 0 end
    return total
end

-- How many full combines the on-hand dropped mats can support for this recipe.
-- Returns math.huge when the recipe has no dropped mats (i.e. it isn't
-- mat-limited - vendor/subcombine mats are always obtainable). This is the
-- gate for "do we have the items for this recipe?": >= 1 means yes.
-- (Defined here, after item_count, so that call resolves to the local.)
-- How many TOP-LEVEL combines the on-hand dropped/summoned mats support, walking the WHOLE
-- tree (not just direct ingredients) and crediting on-hand subcombine product. Without the
-- tree walk a recipe like Brut Champagne - whose only dropped mat (Enchanted Gold Bar) is
-- nested inside the Champagne Magnum subcombine - looked unlimited, so the leveling advancer
-- kept re-picking it after plan_requirements aborted on the missing mat (an infinite loop).
local function dropped_combines_available(rec, _depth)
    if not rec then return 0 end
    _depth = _depth or 0
    local limit = math.huge
    if _depth > 8 then return limit end
    for _, ing in ipairs(rec.ingredients) do
        if ing.returned then
            -- made/bought once and reused; not a per-combine constraint
        elseif ing.dropped then
            local n = math.floor(item_count(ing.name) / math.max(1, ing.qty or 1))
            if n < limit then limit = n end
        elseif (state.iniSections or {})['Recipe:' .. ing.name] and not (state.vendorMap or {})[ing.name] then
            -- Subcombine (and not vendor-bought): top combines it can feed = on-hand product
            -- plus what its OWN dropped mats can still make. A sub with no dropped mats is
            -- unlimited and never constrains.
            local subRec = get_recipe(ing.name)
            local subAvail = dropped_combines_available(subRec, _depth + 1)
            if subAvail ~= math.huge then
                local subYield = math.max(1, (subRec and subRec.yield) or 1)
                local perTop = ing.qty or 1
                local total = math.floor((item_count(ing.name) + subAvail * subYield) / perTop)
                if total < limit then limit = total end
            end
        end
    end
    return limit
end

-- Batch size for a leveling combine: the requested batch, but never more than
-- the dropped mats on hand can support (so the buy-pass doesn't over-buy vendor
-- mats for combines we can't actually do). Non-dropped recipes use the full batch.
local function level_batch_qty(rec)
    local batch = math.max(1, math.min(MAX_QUANTITY, tonumber(state.levelBatchBuf) or 100))
    local avail = dropped_combines_available(rec)
    if avail ~= math.huge and avail < batch then
        batch = math.max(1, avail)
    end
    return batch
end

local function item_id(name)
    return mq.TLO.FindItem('=' .. name).ID() or 0
end

-- Resolves container information from a skill section, returning a table:
--   { type='inventory'|'world', name=string, navLoc=string|nil }
-- For 'inventory' type: name is the actual item name found in pack<kitPack>.
-- For 'world' type: checks InventoryContainer in pack<kitPack> first (takes
--   priority if found), then falls back to the world container; name is
--   the found inventory item name or the Container= name for the world obj.
-- Kit config: maps container keyword -> { variants (best first), vendors, buy preference }
local KIT_CONFIG = {
    { keyword = 'sewing kit',    variants = { 'Planar Sewing Kit', 'Large Sewing Kit', 'Deluxe Sewing Kit', 'Sewing Kit', 'Small Sewing Kit' }, vendors = { 'Sherin Matrick', 'Tailor Kujen', 'Higwyn Matrick', 'Tratlan Matrick' }, buyOrder = { 'Planar Sewing Kit', 'Large Sewing Kit' } },
    { keyword = "jeweler's kit", variants = { "Planar Jeweler's Kit", "Jeweler's Kit" },                                    vendors = { 'Noirin Khalen', 'Audri Deepfacet' },                                       buyOrder = { "Planar Jeweler's Kit", "Jeweler's Kit" } },
    { keyword = 'fletching kit', variants = { 'Planar Fletching Kit', 'Fletching Kit' },                                   vendors = { 'Jaren Cloudchaser', 'Fletcher Lenvale', 'Ellis Cloudchaser' },           buyOrder = { 'Planar Fletching Kit', 'Fletching Kit' } },
    { keyword = 'mixing bowl',   variants = { 'Mixing Bowl' },                                                             vendors = { 'Klen Ironstove', 'Brewmaster Berina', 'Culkin Ironstove', 'Perago Crotal' }, buyOrder = { 'Mixing Bowl' } },
    -- Added with the new tradeskills. Vendors confirmed from merchants.ini. Each
    -- base name is listed as a variant so the existing exact-name resolution still
    -- works; Reinforced Medicine Bag (Tailoring-made, bigger) is accepted if held.
    { keyword = 'spell research kit', variants = { 'Spell Research Kit' },                          vendors = { 'Eric Rasumus', 'Scholar Klaz' },        buyOrder = { 'Spell Research Kit' } },   -- Research
    { keyword = 'tome binding kit',   variants = { 'Tome Binding Kit' },                            vendors = { 'Scholar Klaz', 'Nursa Rasumus' },       buyOrder = { 'Tome Binding Kit' } },     -- Research (melee tomes) - both PoK
    { keyword = 'medicine bag',       variants = { 'Reinforced Medicine Bag', 'Medicine Bag' },     vendors = { 'Alchemist Redsa' },                     buyOrder = { 'Medicine Bag' } },         -- Alchemy
    { keyword = 'mortar and pestle',  variants = { 'Mortar and Pestle' },                           vendors = { 'Toxicologist Huey' },                   buyOrder = { 'Mortar and Pestle' } },    -- Make Poison
    { keyword = 'toolbox',            variants = { 'Deluxe Toolbox', 'Collapsible Toolbox', 'Toolbox' }, vendors = { 'Engineer Beri' },                       buyOrder = { 'Toolbox' } },              -- Tinkering (Deluxe/Collapsible are tinker-made; best held one is used, else a plain Toolbox is bought)
    { keyword = 'tackle box',         variants = { 'Tackle Box' },                                  vendors = { 'Angler Winifred', 'Ramos Jerwan', 'Daeld Atand' }, buyOrder = { 'Tackle Box' } }, -- Fishing (also the Fishing Trophy container; Winifred sells it + Mounting Board)
    { keyword = 'glaze mortar',       variants = { 'Glaze Mortar' },                                vendors = { 'Sculptor Radee', 'Elisha Dirtyshoes' }, buyOrder = { 'Glaze Mortar' } },         -- Pottery (Infused Formative Glaze) - inventory KIT; both vendors PoK, also sell Glaze Lacquer
    { keyword = 'concordance of research', variants = { 'Concordance of Research' },                 vendors = {},                                        buyOrder = {}, quest = true },           -- Runic Tablets (quest kit - staged from bags, never bought)
}

local function resolve_container_info(skillSec, kitPack)
    local containerType = trim(skillSec.ContainerType or 'inventory'):lower()
    local navLoc = trim(skillSec.NavLoc or '')

    -- Check for optional inventory container (Collapsible Distillery etc.)
    -- for world-type tradeskills - takes priority if present in ANY pack slot
    if containerType == 'world' and skillSec.InventoryContainer then
        local invCandidates = split_commas(skillSec.InventoryContainer)
        for _, name in ipairs(invCandidates) do
            local kit = mq.TLO.FindItem('=' .. name)
            local slot = (kit.ID() or 0) > 0 and (kit.ItemSlot() or 0) or 0
            if slot >= 23 and slot <= 34 then
                local p = slot - 22
                printf_log('Found %s in pack%d - using it instead of world container.', name, p)
                return { type = 'inventory', name = name, navLoc = nil, pack = p }
            end
        end
    end

    if containerType == 'inventory' then
        -- Inventory bag, found in ANY pack slot. A recipe tree can span MULTIPLE kits
        -- (e.g. the Misty Thicket Picnic uses both a Mixing Bowl and a Sewing Kit), so we
        -- cannot assume the one fixed kitPack slot -- we search every pack and report which
        -- one actually holds the kit via cinfo.pack, which the caller then uses.
        local candidates = split_commas(skillSec.Container)

        -- Check if this is a known kit type that has variants
        local containerName = candidates[1] or ''
        local kitCfg = nil
        for _, c in ipairs(KIT_CONFIG) do
            if containerName:lower():find(c.keyword, 1, true) then kitCfg = c; break end
        end

        if kitCfg then
            -- Accept any variant of this kit type in any pack
            for p = 1, 12 do
                local bagName = (mq.TLO.Me.Inventory('pack' .. p).Name() or ''):lower()
                if bagName ~= '' then
                    for _, variant in ipairs(kitCfg.variants) do
                        if bagName == variant:lower() then
                            return { type = 'inventory', name = mq.TLO.Me.Inventory('pack' .. p).Name(), navLoc = nil, pack = p }
                        end
                    end
                end
            end
            return nil
        end

        for _, name in ipairs(candidates) do
            local kit = mq.TLO.FindItem('=' .. name)
            local slot = (kit.ID() or 0) > 0 and (kit.ItemSlot() or 0) or 0
            if slot >= 23 and slot <= 34 then
                return { type = 'inventory', name = name, navLoc = nil, pack = slot - 22 }
            end
        end
        return nil  -- inventory container not found in any pack
    else
        -- World container: pick the closest known station location across all
        -- zones. Stations in the current zone get their actual 3D distance;
        -- stations in other zones get a large penalty so they only win if
        -- there's no entry for the current zone at all.
        local displayName = trim(split_commas(skillSec.Container)[1] or 'crafting station')
        local doorId = tonumber(skillSec.DoorID)

        local curZone = trim(mq.TLO.Zone.ShortName() or '')
        local stationLocs = state.stationLocs or {}
        local px = mq.TLO.Me.Y() or 0
        local py = mq.TLO.Me.X() or 0
        local pz = mq.TLO.Me.Z() or 0

        -- Build list of all stations sorted by distance (current zone first)
        local allStations = {}
        if stationLocs[displayName] then
            for _, entry in ipairs(stationLocs[displayName]) do
                local ly, lx, lz = entry.loc:match('([%-%.%d]+)%s+([%-%.%d]+)%s+([%-%.%d]+)')
                if ly then
                    local d
                    if entry.zone == curZone then
                        d = math.sqrt((px-tonumber(ly))^2 + (py-tonumber(lx))^2 + (pz-tonumber(lz))^2)
                    else
                        d = math.huge
                    end
                    allStations[#allStations+1] = { loc = entry.loc, zone = entry.zone, dist = d, target = entry.target }
                end
            end
            table.sort(allStations, function(a, b) return a.dist < b.dist end)
        end

        -- Fallback: use navLoc from skill section if no stations found
        if #allStations == 0 and navLoc ~= '' then
            allStations[1] = { loc = navLoc, zone = curZone, dist = 0 }
        end

        local bestStation = allStations[1]
        return {
            type = 'world',
            name = displayName,
            doorName = displayName,
            doorId = doorId,
            navLoc = bestStation and bestStation.loc or nil,
            navZone = bestStation and bestStation.zone or nil,
            navTarget = bestStation and bestStation.target or nil,
            allStations = allStations,  -- all locations to try if one is in use
        }
    end
end

-- ---------------------------------------------------------------------------
-- Tree validator (read-only dry run). Walks the FULL subcombine tree for a
-- recipe and prints a bill of materials -- every subcombine with its container
-- (resolvable / in bags?) and every base mat with source + have/need -- then a
-- GO / NO-GO verdict. No combines, no buying, no travel. This is the pre-flight
-- so you know what's missing BEFORE hitting Go, instead of finding out 15 levels
-- deep mid-combine. Reuses the SAME resolve_container_info the engine uses, so a
-- container that shows resolvable here will actually open at run time.
-- ---------------------------------------------------------------------------
local function plan_tree(name, qty, kitPack)
    kitPack = kitPack or KIT_PACK_DEFAULT
    qty = qty or 1
    -- Grouped blockers so the verdict reads as root causes, not one line per affected
    -- combine. Container blockers collapse by container (with a count of combines they
    -- block); mat blockers dedupe by item name. The TREE output still flags every line.
    local contBlocks, contOrder = {}, {}   -- cdesc -> count
    local matBlocks, matOrder = {}, {}     -- item name -> message
    local function add_cont_block(cdesc)
        if not contBlocks[cdesc] then contBlocks[cdesc] = 0; contOrder[#contOrder + 1] = cdesc end
        contBlocks[cdesc] = contBlocks[cdesc] + 1
    end
    local function add_mat_block(key, msg)
        if not matBlocks[key] then matBlocks[key] = msg; matOrder[#matOrder + 1] = key end
    end

    local function container_status(recSec)
        local cinfo = resolve_container_info(recSec, kitPack)
        local ctype = trim(recSec.ContainerType or 'inventory'):lower()
        local cname = split_commas(recSec.Container or '?')[1] or '?'
        if not cinfo then
            -- A configured kit (Mixing Bowl, Sewing Kit, ...) that isn't in bags yet is NOT a
            -- blocker: the run buys and stages it (ensure_kit_in_pack) before combining. Only
            -- flag containers we genuinely can't resolve or buy.
            if ctype == 'inventory' then
                local lc = (cname or ''):lower()
                for _, c in ipairs(KIT_CONFIG) do
                    if lc:find(c.keyword, 1, true) then
                        return true, cname .. ' (will buy)'
                    end
                end
            end
            return false, cname .. (ctype == 'inventory' and ' -- NOT IN BAGS' or ' -- unresolved')
        elseif cinfo.type == 'world' then
            if cinfo.allStations and #cinfo.allStations > 0 then
                return true, cname .. ' (world)'
            end
            return false, cname .. ' -- NO STATION LOC'
        end
        return true, cname .. ' (pack' .. (cinfo.pack or '?') .. ')'
    end

    local function walk(iname, needItems, depth, isReturned)
        local pad = string.rep('  ', depth)
        local rec = get_recipe(iname)
        local recSec = (state.iniSections or {})['Recipe:' .. iname]
        if not rec or not recSec then return end
        local yield = rec.yield or 1
        local combines = math.max(1, math.ceil(needItems / yield))
        local cok, cdesc = container_status(recSec)
        printf_log('%s* %s x%d%s  [%s]%s', pad, iname, needItems,
            isReturned and ' (returned tool)' or '', cdesc, cok and '' or '   <-- BLOCKER')
        if not cok then
            add_cont_block(cdesc)
        end
        if depth >= 12 then
            printf_log('%s  ...(max depth - possible recipe loop)', pad)
            return
        end
        for _, ing in ipairs(rec.ingredients) do
            local sub = (state.iniSections or {})['Recipe:' .. ing.name]
            if ing.returned then
                local have = item_count(ing.name)
                if sub and have < 1 then
                    walk(ing.name, 1, depth + 1, true)
                else
                    printf_log('%s  - %s (returned tool) have %d', pad, ing.name, have)
                end
            elseif ing.dropped then
                local need = ing.qty * combines
                local have = item_count(ing.name)
                printf_log('%s  - %s x%d  [farmed/|dropped: have %d]%s',
                    pad, ing.name, need, have, have >= need and '' or '   <-- SHORT')
                if have < need then
                    add_mat_block(ing.name, string.format('%s: farmed, have %d need %d', ing.name, have, need))
                end
            elseif sub then
                walk(ing.name, ing.qty * combines, depth + 1, false)
            elseif (state.vendorMap or {})[ing.name] then
                printf_log('%s  - %s x%d  [vendor]', pad, ing.name, ing.qty * combines)
            else
                local need = ing.qty * combines
                local have = item_count(ing.name)
                printf_log('%s  - %s x%d  [NO VENDOR/RECIPE: have %d]%s',
                    pad, ing.name, need, have, have >= need and '' or '   <-- BLOCKER')
                if have < need then
                    add_mat_block(ing.name, string.format('%s: no vendor or recipe, have %d need %d', ing.name, have, need))
                end
            end
        end
    end

    if not get_recipe(name) then
        printf_log('PLAN: no recipe found for "%s".', name)
        return false
    end
    printf_log('========== PLAN: %s x%d (dry run) ==========', name, qty)
    walk(name, qty, 0, false)
    printf_log('--------------------------------------------')
    local total = #contOrder + #matOrder
    if total == 0 then
        printf_log('GO: tree is fully makeable from current bags/vendors.')
        return true
    end
    printf_log('NO-GO: %d root issue(s):', total)
    for _, cdesc in ipairs(contOrder) do
        local n = contBlocks[cdesc]
        printf_log('   x %s (blocks %d combine%s)', cdesc, n, n == 1 and '' or 's')
    end
    for _, key in ipairs(matOrder) do
        printf_log('   x %s', matBlocks[key])
    end
    return false
end

-- "Usable" free slots = total free inventory MINUS the slots inside the combine kit
-- (pack<kitPack>) and the dedicated tradeskill bag. Those are staging space -- cleared
-- and refilled every combine -- so they don't count as room for finished goods.
local TS_BAG_NAME = "Artisan's Adept Attache"

-- Count empty slots inside one pack. Used only for the staging-bag subtractions.
local function bag_free_slots(pack)
    -- Aggregate reads: capacity minus item count. The per-slot Item[s].ID walk returns
    -- empty for every slot when a tradeskill/forge window is open, so a FULL bag would
    -- read as all-free; Container and Items survive the open window and give the truth.
    local bag = mq.TLO.Me.Inventory('pack' .. pack)
    local cap = bag.Container() or 0
    if cap <= 0 then return 0 end
    return cap - (bag.Items() or 0)
end

local function free_slots(kitPack)
    -- Use the client's own free-slot count. The old per-bag walk read 0 usable slots
    -- whenever a tradeskill/forge window (TradeskillWnd) was open -- Container()/Item()
    -- reads are blocked in that state -- which produced a false "0 free slots" and an
    -- endless sell loop. Me.FreeInventory stays correct with the window open.
    local free = mq.TLO.Me.FreeInventory() or 0
    -- Exclude staging space -- finished goods can't land there, so its free slots
    -- aren't room and counting them risks overfilling. Two sources:
    --   * the combine kit (inventory crafts only; world crafts pass kitPack = nil)
    --   * the dedicated tradeskill bag
    -- bag_free_slots uses aggregate reads, so these stay correct mid-combine.
    if kitPack then free = free - bag_free_slots(kitPack) end
    for i = 1, 10 do
        if (mq.TLO.Me.Inventory('pack' .. i).Name() or '') == TS_BAG_NAME then
            free = free - bag_free_slots(i)
            break
        end
    end
    if free < 0 then free = 0 end
    return free
end

local function skill_value(skillName)
    if not skillName or skillName == '' then return nil end
    return mq.TLO.Me.Skill(skillName)() or 0
end

-- Dropped/supplied mats anywhere in rec's tree we can't make even one combine from (have <
-- per-combine need). Mirrors dropped_combines_available's tree walk. Returns ready-to-print
-- strings with on-hand counts and (if a caster makes it) the producing class. Shared by the
-- leveling preflight and the "nothing to do" report.
state.missingMats = function(rec)
    local out, seen = {}, {}
    local function walk(r, depth)
        if not r or depth > 8 then return end
        for _, ing in ipairs(r.ingredients) do
            if ing.returned then
                -- reused tool, not a per-combine constraint
            elseif ing.dropped then
                local need, have = math.max(1, ing.qty or 1), item_count(ing.name)
                if have < need and not seen[ing.name] then
                    seen[ing.name] = true
                    local maker
                    for _, mk in ipairs(MAKEABLE) do if mk.item == ing.name then maker = mk.class; break end end
                    out[#out + 1] = string.format('%s (have %d%s)', ing.name, have, maker and (', ' .. maker .. '-made') or '')
                end
            elseif (state.iniSections or {})['Recipe:' .. ing.name] and not (state.vendorMap or {})[ing.name] then
                if item_count(ing.name) < (ing.qty or 1) then walk(get_recipe(ing.name), depth + 1) end
            end
        end
    end
    walk(rec, 0)
    return out
end

-- Top-level non-vendor reagents a rung consumes, each with on-hand status. Used by the
-- leveling preview (UI ingredient list + recipe green/red). Caster-made (MAKEABLE) and
-- |dropped reagents are judged strictly on-hand; a pure subcombine passes if it's on hand
-- OR makeable from current mats. Vendor-bought mats and reused tools are excluded.
state.limitingMats = function(rec)
    local out = {}
    if not rec then return out end
    for _, ing in ipairs(rec.ingredients) do
        if not ing.returned then
            local vendor = (state.vendorMap or {})[ing.name] ~= nil
            local maker
            for _, mk in ipairs(MAKEABLE) do if mk.item == ing.name then maker = mk.class; break end end
            local sub = (not vendor) and ((state.iniSections or {})['Recipe:' .. ing.name] ~= nil)
            if ing.dropped or maker or sub then
                local need = math.max(1, ing.qty or 1)
                local have = item_count(ing.name)
                local ok
                if ing.dropped or maker then
                    ok = have >= need
                else
                    ok = have >= need or dropped_combines_available(get_recipe(ing.name)) >= 1
                end
                out[#out + 1] = { name = ing.name, have = have, need = need, ok = ok, maker = maker }
            end
        end
    end
    return out
end

-- Caster-made (MAKEABLE) reagents the rung is short on, as ready-to-print strings. These
-- carry no |dropped flag so missingMats misses them; the leveling reasons list adds these.
state.makeableShort = function(rec)
    local out = {}
    for _, ing in ipairs(rec and rec.ingredients or {}) do
        if not ing.returned then
            for _, mk in ipairs(MAKEABLE) do
                if mk.item == ing.name then
                    local need, have = math.max(1, ing.qty or 1), item_count(ing.name)
                    if have < need then out[#out + 1] = string.format('%s (have %d, %s-made)', ing.name, have, mk.class) end
                    break
                end
            end
        end
    end
    return out
end

-- A rung is craftable right now iff its dropped tree supports >=1 combine AND every
-- top-level non-vendor reagent is on hand. Stricter than dropped_combines_available alone,
-- which ignores caster-made reagents (e.g. Imbued Amber) that carry no |dropped flag -- so
-- the green/red the user sees matches what run_engine will actually start vs abort.
state.canCraftNow = function(rec)
    if dropped_combines_available(rec) < 1 then return false end
    for _, m in ipairs(state.limitingMats(rec)) do if not m.ok then return false end end
    return true
end

-- Mats the engine can't auto-source: no flag, no vendor, not caster-made, not a sub-recipe,
-- and short on hand. These don't BLOCK the recipe (the engine still calls it and you supply
-- them), but the preflight surfaces them so you know what to bring instead of failing at
-- staging mid-run. (Evergreen Leaf with its vendor unscanned is the textbook case.)
state.supplyNeeded = function(rec)
    local out = {}
    if not rec then return out end
    local vmap = state.vendorMap or {}
    local secs = state.iniSections or {}
    for _, ing in ipairs(rec.ingredients) do
        if not ing.returned and not ing.dropped then
            local maker = false
            for _, mk in ipairs(MAKEABLE) do if mk.item == ing.name then maker = true; break end end
            local sub = secs['Recipe:' .. ing.name] ~= nil
            if not maker and not sub and vmap[ing.name] == nil then
                local need = math.max(1, ing.qty or 1)
                local have = item_count(ing.name)
                if have < need then
                    out[#out + 1] = string.format('%s (have %d, need %d each - no vendor)', ing.name, have, need)
                end
            end
        end
    end
    return out
end

-- How many of a rung we can make now: the requested batch, capped by dropped-mat
-- availability and by on-hand caster-made reagents. Vendor-only rungs are capped only by
-- the batch. (An estimate; run_engine re-caps precisely against the full supply tree.)
state.craftableCount = function(rec)
    local batch = math.max(1, math.min(MAX_QUANTITY, tonumber(state.levelBatchBuf) or 100))
    local n = math.min(batch, dropped_combines_available(rec))   -- huge avail -> batch
    for _, ing in ipairs(rec and rec.ingredients or {}) do
        if not ing.returned then
            for _, mk in ipairs(MAKEABLE) do
                if mk.item == ing.name then
                    n = math.min(n, math.floor(item_count(ing.name) / math.max(1, ing.qty or 1)))
                    break
                end
            end
        end
    end
    return math.max(0, n)
end

-- Two-press leveling Start: the FIRST press runs this preflight (no crafting) so the user sees,
-- in the MQ window, exactly what will craft vs what will be SKIPPED for missing mats -- the guard
-- against silently skipping a batch of recipes. Returns ready, skip counts; the caller only arms
-- the confirm when ready > 0.
state.levelPreflight = function()
    if #state.levelPlan == 0 then
        printf_log('Leveling: plan is empty - load a path or add recipes first.')
        return 0, 0
    end
    local firstSec = (state.iniSections or {})['Skill:' .. (state.levelPlan[1].skillName or '')]
    local eqSkill = firstSec and firstSec.Skill
    local curSkill = eqSkill and skill_value(eqSkill) or 0
    printf_log('\agLeveling preflight\ax - skill %d:', curSkill)
    local ready, skip = {}, {}
    for _, e in ipairs(state.levelPlan) do
        if e.trivial > curSkill then   -- below trivial = still gains skill = would be attempted
            if state.canCraftNow(get_recipe(e.itemName)) then
                ready[#ready + 1] = e
            else
                skip[#skip + 1] = e
            end
        end
    end
    if #skip > 0 then
        printf_log('\arWill SKIP - missing mats (%d):\ax', #skip)
        for _, e in ipairs(skip) do
            printf_log('\ar%s (%d)\ax', e.itemName, e.trivial)
            local rec = get_recipe(e.itemName)
            for _, m in ipairs(state.missingMats(rec)) do printf_log('\ay   * %s\ax', m) end
            for _, m in ipairs(state.makeableShort(rec)) do printf_log('\ay   * %s\ax', m) end
        end
    end
    if #ready > 0 then
        printf_log('\agWill craft (%d):\ax', #ready)
        for _, e in ipairs(ready) do
            local rec = get_recipe(e.itemName)
            local n = state.craftableCount(rec)
            local tag = (dropped_combines_available(rec) == math.huge) and ' (vendor mats)' or ''
            printf_log('\ag   %s (%d) - can make %d%s\ax', e.itemName, e.trivial, n, tag)
            for _, s in ipairs(state.supplyNeeded(rec)) do
                printf_log('\ay      supply yourself: %s\ax', s)
            end
        end
    end
    if #ready > 0 then
        local levelSkill = state.levelPlan[1] and state.levelPlan[1].skillName or ''
        if state.fixedDisposalSkills[levelSkill] then
            printf_log('Finished combines: disposal is set per recipe (some kept, some destroyed).')
        else
            local dispWord = (state.levelDisposal == DISPOSAL.SELL and 'Sold')
                          or (state.levelDisposal == DISPOSAL.DESTROY and 'Destroyed')
                          or 'Kept'
            printf_log('Finished combines will be %s.', dispWord)
        end
        printf_log('\ayThis is leveling mode - it continues through recipes until each goes trivial or runs out of materials.\ax')
    end
    if #ready == 0 and #skip == 0 then
        printf_log('Nothing below trivial at skill %d - already done or at the cap.', curSkill)
    elseif #ready == 0 then
        if state.levelSupplyFromGroup then
            printf_log('\ayNo recipes ready on hand\ax - the %d above will be requested from same-zone characters on the network. Press Start to begin.', #skip)
        else
            printf_log('\arNo recipes ready\ax - supply the missing mats above, then press Start.')
        end
    elseif #skip == 0 then
        printf_log('\agAll %d recipe(s) ready.\ax Press Start again to begin.', #ready)
    else
        printf_log('Press Start again to craft %d recipe(s) and SKIP \ar%d\ax (missing mats).', #ready, #skip)
    end
    return #ready, #skip
end

local function cursor_id() return mq.TLO.Cursor.ID() or 0 end

local desyncDetected = false   -- set by ts_desync event, checked/reset in clear_cursor/drain_cursor/world_clear
local desyncLatch = false      -- also set by ts_desync; only world_stage clears it, so it survives a whole stage attempt
local stationInUse = false     -- set when another player is using a world container

local function clear_cursor()
    for _ = 1, 8 do
        if cursor_id() == 0 then break end
        local wasStacked = (mq.TLO.Cursor.Stack() or 1) > 1   -- stowing a whole stack hits the server hard
        mq.cmd('/autoinventory')
        mq.delay(600, function() return cursor_id() == 0 end)
        -- A stacked drop desyncs the server, and that desync takes ~1s to SURFACE. Wait it
        -- out here BEFORE the check below, so the desync handler actually catches it instead
        -- of us sailing past while the flag is still pending.
        if wasStacked then mq.delay(2000) end
        if desyncDetected then
            printf_log('Inventory desync detected - settling cursor...')
            desyncDetected = false
            state.settle_desync()
        elseif cursor_id() > 0 then
            mq.delay(PLACE_PACE_MS)  -- pace between queued cursor items to avoid a desync burst
        end
    end
    return cursor_id() == 0
end

-- After a desync, a ghost copy of a recently-handled item surfaces on the cursor on a
-- delay (~0.5-2s) - AFTER a normal empty-check would have already passed, which is how
-- staging ends up grabbing/placing the ghost. A blind wait races it. Instead: actively
-- bag whatever surfaces, and require the cursor to read empty several checks in a row
-- (stable) before we let staging resume. Faster than a flat 3s when the cursor is already
-- clean (~450ms), and only spends real time when a ghost actually shows up.
function state.settle_desync()
    local stable = 0
    local drains = 0
    for _ = 1, 24 do
        if cursor_id() ~= 0 then
            mq.cmd('/autoinventory')               -- bag the ghost the instant it appears
            mq.delay(500, function() return cursor_id() == 0 end)
            drains = drains + 1
            stable = 0
            if drains >= 5 then break end          -- ghost keeps reappearing; stop, let caller cope
        else
            stable = stable + 1
            if stable >= 3 then break end          -- empty across 3 checks running = settled
            mq.delay(150)
        end
    end
    state.dlog('settle_desync done: drains=%d cursor=%s', drains, (mq.TLO.Cursor.Name() or '(empty)'))
    return cursor_id() == 0
end

local function accept_qty_window(n)
    if not mq.TLO.Window('QuantityWnd').Open() then return end
    if n and n > 0 then
        mq.TLO.Window('QuantityWnd/QTYW_SliderInput').SetText(tostring(n))()
        mq.delay(500, function() return mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text() == tostring(n) end)
    end
    mq.TLO.Window('QuantityWnd/QTYW_Accept_Button').LeftMouseUp()
    mq.delay(1000, function() return not mq.TLO.Window('QuantityWnd').Open() end)
end

local function check_stop()
    if state.stopRequested then error('__TS_STOP__', 0) end
end

-- PAUSE: unlike Stop (which throws and terminates), Pause SUSPENDS in place. Called at the same
-- per-combine / per-step checkpoints as check_stop. When paused it hands control back to the player
-- (drains the cursor to a safe state, closes any combine/trade windows, lets E3 run) and SPINS until
-- the user resumes or stops. Because we never unwind the loop, the loop's own counters (n, madeTotal)
-- stay live - resuming continues at the CURRENT combine, not from 1. On resume we re-validate via the
-- optional revalidate() callback the caller passes (reopen the kit, re-check ingredients, etc.).
-- revalidate() should return true if it's safe to continue, false to abort the run.
state.check_pause = function(revalidate)
    if not state.pauseRequested then return end
    -- Reach a safe state before yielding: nothing half-held on the cursor, and NONE of the automation's
    -- windows left open (world container/Oven, bags, experiment window) - the player is about to drive.
    if (mq.TLO.Cursor.ID() or 0) > 0 then
        mq.cmd('/autoinventory'); mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
    end
    -- Close everything with /cleanup (bags + world container + experiment window in one shot), then let
    -- close_kit_bags esc-finish any straggler (a world container sometimes only closes via esc). This is
    -- why the Oven no longer stays open on pause.
    mq.cmd('/cleanup')
    mq.delay(400)
    mq.doevents()
    if mq.TLO.Window('TradeskillWnd').Open() or mq.TLO.Window('ContainerCombine_Items').Open() then
        state.close_kit_bags()
    end
    mq.cmd('/e3p off')   -- give the toon back to the player while paused
    state.paused = true
    printf_log('\ayPaused. Do what you need - press Resume to continue where you left off, or Stop to end.\ax')
    -- Spin until resume or stop. Keep pumping events so the UI stays responsive and Stop/Resume land.
    while state.pauseRequested and not state.stopRequested do
        mq.delay(100)
        mq.doevents()
    end
    state.paused = false
    if state.stopRequested then error('__TS_STOP__', 0) end   -- stopped while paused
    -- Resuming: take the toon back and re-validate before handing control to the loop again.
    mq.cmd('/e3p on')
    mq.delay(200)
    printf_log('Resuming - re-checking state before continuing...')
    if revalidate then
        local okv, cont = pcall(revalidate)
        if not okv or cont == false then
            printf_log('\arCan\'t safely resume (state changed and couldn\'t be restored) - stopping.\ax')
            state.stopRequested = true
            error('__TS_STOP__', 0)
        end
    end
end

-- Request handlers wired to the UI buttons.
state.request_pause = function()
    if not state.busy then return end
    state.pauseRequested = true
end
state.request_resume = function()
    state.pauseRequested = false   -- the check_pause spin exits and re-validates
end

local function delay(ms, cond)
    if cond then
        mq.delay(ms, function()
            mq.doevents()
            -- mq.delay's callback MUST return a bool. A caller's cond() can return nil
            -- (e.g. a TLO read that came back nil), which would crash with "expected bool,
            -- got nil". Coerce to a real boolean so any cond is safe.
            return (state.stopRequested or cond()) and true or false
        end)
    else
        local deadline = mq.gettime() + ms
        while mq.gettime() < deadline and not state.stopRequested do
            mq.delay(math.min(100, math.max(1, deadline - mq.gettime())))
            mq.doevents()
        end
    end
    check_stop()
end

-- ---------------------------------------------------------------------------
-- Combine result events
-- ---------------------------------------------------------------------------

local combineFlags = { success = false, fail = false, wrongContainer = false, lacked = false, desync = false }
mq.event('ts_success', 'You have fashioned the items together#*#', function() combineFlags.success = true end)
mq.event('ts_lacked',  'You lacked the skills to fashion#*#',      function() combineFlags.fail = true; combineFlags.lacked = true end)
mq.event('ts_cannot',  'You cannot combine these items#*#',        function() combineFlags.fail = true end)
-- More specific than ts_cannot: this means the staged CONTENTS are wrong for the
-- recipe (not a fizzle), so retrying the same set loops. Flag it so the combine
-- loop can clear, re-stage fresh once, and abort if it still complains.
mq.event('ts_wrongcont', 'You cannot combine these items in this container#*#', function() combineFlags.fail = true; combineFlags.wrongContainer = true end)
mq.event('ts_missing', 'You do not have all the components#*#',    function() combineFlags.fail = true end)
mq.event('ts_place',   'You must place items#*#',                  function() combineFlags.fail = true end)
mq.event('ts_inuse',   'Someone else is using that#*#',            function() stationInUse = true end)
mq.event('ts_inuse2',  'someone else is using that#*#',            function() stationInUse = true end)
mq.event('ts_inuse3',  'This is already in use#*#',                function() stationInUse = true end)
mq.event('ts_zonein',  'You have entered #*#',                     function() state.sawZoneIn = true end)

-- Fishing failure messages. Without these, casting on dry land is SILENT: /doability just does
-- nothing, the loop keeps casting, and any item left on the cursor (e.g. a pole a failed equip
-- didn't put away) gets misread as a catch. Now the engine can say exactly why it isn't fishing.
mq.event('ts_fish_land',    '#*#catch land sharks#*#',                  function() state.fishFail = 'not near water (cast on dry land)' end)
mq.event('ts_fish_nopole',  "#*#fish without a fishing pole#*#",        function() state.fishFail = 'no fishing pole equipped' end)
mq.event('ts_fish_nobait',  '#*#fish without fishing bait#*#',          function() state.fishFail = 'out of fishing bait' end)
mq.event('ts_fish_primary', '#*#pole in your primary hand#*#',          function() state.fishFail = 'pole is not in the primary hand' end)

-- Supply mule responses. Delivered SILENTLY over the /dex peer network (the mule
-- does `/dex <crafter> /ts_done <encoded> <qty>`), not game tells -- game tells
-- rate-limit fast across a leveling run. Args arrive clean as command params, so
-- there's no trailing apostrophe to strip like the old tell-event captures had.
local supplyResponse = { type = nil, item = nil, qty = 0 }
local function ts_set_response(kind)
    return function(encoded, qty)
        supplyResponse = {
            type = kind,
            item = namecodec.decode(encoded),
            qty  = tonumber(qty) or 0,
        }
    end
end
mq.bind('/ts_have', ts_set_response('have'))
mq.bind('/ts_none', ts_set_response('none'))
mq.bind('/ts_done', ts_set_response('done'))
mq.bind('/ts_fail', ts_set_response('fail'))
-- Batch completion: the mule sends /ts_qdone <total> when a whole /ts_qrun batch is delivered.
-- First arg is a count, not an encoded item name, so it needs its own handler.
mq.bind('/ts_qdone', function(total)
    supplyResponse = { type = 'qdone', item = nil, qty = tonumber(total) or 0 }
end)

-- DIAGNOSTIC: /ts_zones - list every networked bot and the zone we read for it (via /dquery), flagging
-- the ones in the Marr/PoK hubs (reachable for cross-zone supply). Read-only; safe to run anytime.
mq.bind('/ts_zones', function()
    local hubs = { ['freeporttemple'] = true, ['poknowledge'] = true }   -- Marr, PoK (the reachable hubs)
    local peers = state.all_network_peers()
    printf_log('/ts_zones: %d networked peer(s). My zone: %s', #peers, (mq.TLO.Zone.ShortName() or '?'))
    if #peers == 0 then printf_log('  (no peers seen - is DanNet/E3 up?)'); return end
    for _, nm in ipairs(peers) do
        local z = state.peer_zone(nm)
        local tag = (z == '' and '\ar(zone unreadable)\ax')
                 or (hubs[z] and ('\ag' .. z .. ' [reachable hub]\ax'))
                 or z
        printf_log('  %s -> %s', nm, tag)
    end
end)

-- Fast group check: members reply to /ts_check with /ts_avail <encoded> <count> <holder>. We record
-- both the running total AND which members hold it, so the delivery can ask ONLY the holders instead
-- of spinning through empty-handed members. availReplies[item] = total; availHolders[item] = { name=qty }.
state.availReplies = {}
state.availHolders = {}
mq.bind('/ts_avail', function(encoded, qty, holder)
    if not encoded then return end
    local item = namecodec.decode(encoded)
    local n = tonumber(qty) or 0
    state.availReplies[item] = (state.availReplies[item] or 0) + n
    if holder and holder ~= '' and n > 0 then
        state.availHolders[item] = state.availHolders[item] or {}
        state.availHolders[item][holder] = (state.availHolders[item][holder] or 0) + n
    end
end)

-- DIAG PROBE: /tsprobe <bot> <Encoded_Item>   e.g.  /tsprobe belree Blue_Diamond
-- The bot must be CROSS-ZONE from us (a different reachable hub). For each send channel (E3, then
-- DanNet) it starts the bot's listener, fires /ts_check, and reports whether a /ts_avail came back.
-- The bot ALWAYS replies over its own peer_cmdf (E3), so: reply here => that direction works. Also
-- eyeball the BOT's own log for  "/ts_check from <us> for <item> -> have N"  to see if the COMMAND
-- arrived (separates a dead command path from a dead reply path).
mq.bind('/tsprobe', function(bot, encoded)
    if not bot or not encoded then printf_log('usage: /tsprobe <bot> <Encoded_Item>  (spaces as _)'); return end
    local me = mq.TLO.Me.Name() or ''
    local item = namecodec.decode(encoded)
    local function trial(label, send)
        state.availReplies = {}; state.availHolders = {}
        send(('/lua run TradeskillListener'))
        mq.delay(3000)
        send(('/ts_check %s %s'):format(me, encoded))
        local deadline = mq.gettime() + 3500
        while mq.gettime() < deadline and state.availReplies[item] == nil do mq.doevents(); mq.delay(50) end
        local got = state.availReplies[item]
        if got ~= nil then
            local hs = {}; for h in pairs(state.availHolders[item] or {}) do hs[#hs + 1] = h end
            printf_log('[tsprobe %s] REPLY received: %s = %d (holder: %s)', label, item, got,
                (#hs > 0 and table.concat(hs, ', ') or '-'))
        else
            printf_log('[tsprobe %s] NO reply in 3.5s - now check %s\'s log for "/ts_check from %s".', label, bot, me)
        end
    end
    printf_log('=== tsprobe: %s for %s (must be cross-zone) ===', bot, item)
    trial('E3',     function(c) mq.cmdf('/e3bct %s %s', bot, c) end)
    trial('DanNet', function(c) mq.cmdf('/dex %s %s', bot, c) end)
    printf_log('=== tsprobe done ===')
end)

-- Ask a set of peers for their CURRENT zone, listener-free. Fire /dquery at all of them at once (the
-- round-trips overlap), then read each peer's own result back via DanNet[name].Q[Zone.ShortName]. This
-- is LIVE (never stale, unlike the cached Observe) and needs NO listener running - so the caller can
-- filter to reachable zones and only THEN start listeners on the few that matter. Returns { name = zone }.
state.query_peer_zones = function(peers)
    local out = {}
    -- fire all queries first so the round-trips run in parallel
    for _, p in ipairs(peers) do
        pcall(function() mq.cmdf('/dquery %s -q Zone.ShortName', p) end)
    end
    -- then poll each peer's result slot until it lands (or we time out)
    local deadline = mq.gettime() + 2000
    while mq.gettime() < deadline do
        mq.delay(40)
        local pending = false
        for _, p in ipairs(peers) do
            if out[p] == nil then
                local z = ''
                pcall(function()
                    local v = mq.TLO.DanNet(p).Q('Zone.ShortName')()
                    if v and tostring(v) ~= '' and tostring(v) ~= 'NULL' then z = tostring(v) end
                end)
                if z ~= '' then out[p] = (z:gsub('^%s+',''):gsub('%s+$',''))
                else pending = true end
            end
        end
        if not pending then break end   -- every peer answered
    end
    return out
end

-- fire-and-forget: the crafter doesn't wait for the (possibly long) cast batch.
-- /ts_makestart acks that the producer began; /ts_madedone arrives later, async,
-- when the batch is done and sitting in the producer's bags (Bring to fetch it).
local makeResponse = { type = nil }
mq.bind('/ts_makestart', function(encoded) makeResponse = { type = 'start' } end)
-- Kick off the all-tradeskills chain (Jewelcrafting -> Pottery) without the UI.
mq.bind('/ts_levelall', function() state.level_all_start() end)
-- TEST: /ts_handoff <peer> <qty> <item name...>  - exercise the crafter->peer hand-off in isolation
-- before it's wired into the gem pipeline. E.g. /ts_handoff Sunetoo 5 Star Rose Quartz
mq.bind('/ts_handoff', function(peer, qtyStr, ...)
    local item = table.concat({ ... }, ' ')
    if not peer or item == '' then printf_log('usage: /ts_handoff <peer> <qty> <item name>'); return end
    local qty = math.max(1, math.floor(tonumber(qtyStr) or 1))
    mq.cmd('/e3p on')   -- pause E3 for the trade (it grabs the cursor mid-pickup otherwise)
    state.deliver_to_peer(peer, item, qty)
end)
mq.bind('/ts_makefail',  function(caster, encoded)
    makeResponse = { type = 'fail' }
    if caster and encoded then
        state.summonFails = state.summonFails or {}
        state.summonFails[#state.summonFails + 1] = { caster = caster, item = namecodec.decode(encoded) }
    end
end)
mq.bind('/ts_madedone', function(encoded, qty)
    local item = namecodec.decode(encoded)
    makeResponse = { type = 'done' }
    printf_log('Finished making %d %s - go to the Request tab and Bring it.', tonumber(qty) or 0, item)
end)

-- Request dropped ingredient from mules in order.
-- Starts listener on each mule via /dex, waits for response, triggers trade.
-- Returns qty received (may be less than needed), or 0 if all mules exhausted.
local ZONE_MARR       = 'freeporttemple'
local ZONE_POK        = 'poknowledge'
local ZONE_JAGGEDPINE = 'jaggedpine'
local ZONE_THURGADIN  = 'thurgadina'
local ZONE_FELWITHE   = 'felwithea'   -- Northern Felwithe (fletching vendor)

local function current_zone()
    return trim(mq.TLO.Zone.ShortName() or '')
end

-- The zone to use for a vendor. A vendor NAME can exist in more than one zone (Jaren Cloudchaser is
-- in both Marr and PoK); if one of them is the zone we're standing in, use that - no travel. Falls
-- back to the last-parsed zone (vendorZone) when the vendor is only known in one place, and nil when
-- unknown (callers treat nil as "no travel needed").
state.vendor_zone_for = function(vname)
    if not vname then return nil end
    local cz = current_zone()
    for _, z in ipairs((state.vendorZones or {})[vname] or {}) do
        if z == cz then return cz end
    end
    return (state.vendorZone or {})[vname]
end


-- Some crafting stations (and the PoK bank cluster) sit in geometry where a direct /nav
-- straight to them wedges the toon on world-object collision and never settles. The fix is
-- to route THROUGH a known clean hub loc first: nav works fine as long as the last approach
-- doesn't come at the station head-on. Any destination in the same zone within `radius` of a
-- waypoint is approached via that waypoint (and returned to after). Locs are "Y X Z" (/loc order),
-- same format as stations.ini. Add a waypoint only for the spots that actually wedge.
state.approachWaypoints = {
    { zone = ZONE_POK, loc = '-358.28 821.90 -92.55', radius = 100 },
    { zone = ZONE_POK, loc = '-381.12 469.72 -122.08', radius = 100 },
    { zone = ZONE_POK, loc = '3.66 223.33 -122.07', radius = 100 },
    { zone = ZONE_POK, loc = '439.07 476.58 -122.08', radius = 100 },   -- Banker Ceridan/Granger staging spot (open either from here)
}

-- Plane of Marr "ferry": the two sides (X<0 = Side A, X>0 = Side B) are split by a pillar band near
-- the north end. A straight A<->B crossing wedges on a pillar EITHER direction. Instead of a radius
-- hub, we cross explicitly through two docks at the clear north end (Y~802, past the pillars): when a
-- crossing is detected (start and destination on opposite X sides), nav to OUR side's dock, then the
-- OTHER side's dock, THEN let normal nav finish. Like a ferry: always the same clean two-stop route.
-- (Docks on state.X, not file-level locals, to stay under the main chunk's 200-local ceiling.)
state.MARR_FERRY_A = '801.88 -43.21 -50.12'   -- Side A dock (X<0)
state.MARR_FERRY_B = '803.01 44.31 -50.12'    -- Side B dock (X>0)
-- Route through the ferry if this is a cross-side trip in Marr. Returns true if it ferried. destLoc is
-- "Y X Z". A crossing = my current X and the destination X have opposite signs (one side to the other).
state.route_marr_ferry = function(destLoc, destZone)
    if (destZone or current_zone()) ~= ZONE_MARR then return false end
    if not destLoc then return false end
    local _, dx = tostring(destLoc):match('([%-%.%d]+)%s+([%-%.%d]+)')
    dx = tonumber(dx)
    if not dx then return false end
    local mx = mq.TLO.Me.X() or 0
    -- Same side (or on the center line) = no crossing, nav normally.
    if (mx < 0) == (dx < 0) then return false end
    -- Cross-side trip: dock on my side first, then the far dock, then normal nav finishes the approach.
    local myDock  = (mx < 0) and state.MARR_FERRY_A or state.MARR_FERRY_B
    local farDock = (dx < 0) and state.MARR_FERRY_A or state.MARR_FERRY_B
    printf_log('Marr crossing - taking the ferry (dock to dock across the north end)...')
    state.nav_loc_wait(myDock)
    state.nav_loc_wait(farDock)
    return true
end

-- Plane of Knowledge "ferry" for the research-merchant pocket. The Safe Hub (bank + stations + the
-- research merchants all hang off it) and the merchant pocket are split by a cluster of crafting
-- stations that nav clips when it shortcuts straight across (the two recorded "nav blocker" boxes).
-- So, exactly like the Marr docks, we cross on an explicit two-stop lane that hugs SOUTH of the
-- stations: Safe Hub <-> Ferry. Deterministic - going IN, we already know the vendor by NAME before
-- we move; coming OUT, position (west of the split) tells us we're in the pocket.
state.POK_FERRY_HUB     = '-357.55 826.30 -90.05'   -- Safe Hub (bank + stations side)
state.POK_FERRY_DOCK    = '-363.72 722.83 -90.05'   -- Ferry (research-merchant pocket entrance)
state.POK_FERRY_SPLIT_X = 748                        -- west of this X (Me.X) = in the pocket; the stations sit ~758+
state.POK_FERRY_UPPER_Z = -100                       -- pocket is UPPER tier (z~-90); the lower crafting tier is z~-122/-124
state.POK_RESEARCH_MERCHANTS = {
    ['blacksmith gerta'] = true, ['caden zharik']    = true, ['merchant tarrin']   = true,
    ['scholar klaz']     = true, ['eric rasumus']    = true, ['maree rasumus']     = true,
    ['sansus rasumus']   = true, ['nursa rasumus']   = true, ['toxicologist huey'] = true,
}
-- Cross via the ferry lane if this PoK trip enters or leaves the research-merchant pocket. destName is
-- the NPC we're navving to (nil for bank/station trips - those can only be LEAVING the pocket). Returns
-- 'in'  (ferried IN to the pocket for a research merchant - the ferry owns the trip, so the caller
--        skips the radius-hub router to avoid roaming),
-- 'out' (ferried OUT of the pocket for a non-merchant dest - the caller STILL stages the
--        destination's own hub afterward so the descent doesn't wedge), or false.
state.route_pok_ferry = function(destName, destZone)
    if (destZone or current_zone()) ~= ZONE_POK then return false end
    local isMerch  = (destName and state.POK_RESEARCH_MERCHANTS[tostring(destName):lower()]) or false
    -- The pocket is UPPER tier. The lower crafting tier (forges/ovens/bankers) is ALSO X < SPLIT
    -- but sits ~30 units lower, so an X-only test wrongly flagged lower-tier trips as "in the
    -- pocket" and ferried them up to the research hub (skipping the forge/lower waypoint routing,
    -- then wedging on the descent). Require upper tier so the lower tier is exempt.
    local inPocket = (mq.TLO.Me.X() or 0) < state.POK_FERRY_SPLIT_X
                     and (mq.TLO.Me.Z() or 0) > state.POK_FERRY_UPPER_Z
    if isMerch then
        -- Going to a research merchant: the ferry OWNS this trip - always claim it so the radius-hub
        -- router never touches it. (That fall-through was the roaming: once we're in the pocket,
        -- merchant->merchant returned false here and the radius router did its safe-waypoint dance.)
        -- Only cross the lane if we're not already in the pocket; otherwise nav straight to the vendor.
        if not inPocket then
            printf_log('PoK: taking the ferry in to the research merchants (safe hub -> ferry)...')
            state.nav_loc_wait(state.POK_FERRY_HUB)
            state.nav_loc_wait(state.POK_FERRY_DOCK)
        end
        return 'in'
    elseif inPocket then
        -- Leaving the pocket for anywhere else (bank, a station, another zone): Ferry back out, then hub.
        printf_log('PoK: taking the ferry out of the research merchants (ferry -> safe hub)...')
        state.nav_loc_wait(state.POK_FERRY_DOCK)
        state.nav_loc_wait(state.POK_FERRY_HUB)
        return 'out'
    end
    return false
end

-- Return the waypoint loc to route through for a destination at (destLoc, destZone), or nil if
-- none applies (no waypoint in that zone, or the destination is outside every waypoint's radius).
state.approach_waypoint_for = function(destLoc, destZone)
    if not destLoc then return nil end
    local dy, dx, dz = tostring(destLoc):match('([%-%.%d]+)%s+([%-%.%d]+)%s+([%-%.%d]+)')
    if not dy then return nil end
    dy, dx, dz = tonumber(dy), tonumber(dx), tonumber(dz)
    for _, wp in ipairs(state.approachWaypoints or {}) do
        if wp.zone == destZone then
            local wy, wx, wz = wp.loc:match('([%-%.%d]+)%s+([%-%.%d]+)%s+([%-%.%d]+)')
            if wy then
                local ex, ey, ez = dx - tonumber(wx), dy - tonumber(wy), dz - tonumber(wz)
                if (ex*ex + ey*ey + ez*ez) <= (wp.radius * wp.radius) then
                    return wp.loc
                end
            end
        end
    end
    return nil
end

-- Nav to a plain loc and wait until we arrive (or nav genuinely stops). Mirrors the engage/arrive
-- polling used at the station and banker: wait for nav to engage, re-issue once if it doesn't, then
-- wait for it to finish. No-op (returns true) if we're already within arriveDist. Used to route
-- through an approach waypoint - a spot nav reaches cleanly - before a wedge-prone destination.
state.nav_loc_wait = function(loc, arriveDist)
    if not loc then return false end
    local ly, lx, lz = tostring(loc):match('([%-%.%d]+)%s+([%-%.%d]+)%s+([%-%.%d]+)')
    if not ly then return false end
    ly, lx, lz = tonumber(ly), tonumber(lx), tonumber(lz)
    local reach = arriveDist or 15
    local function here()
        local ex = (mq.TLO.Me.X() or 0) - lx
        local ey = (mq.TLO.Me.Y() or 0) - ly
        local ez = (mq.TLO.Me.Z() or 0) - lz
        return (ex*ex + ey*ey + ez*ez) <= (reach * reach)
    end
    if here() then return true end
    state.pre_nav()
    mq.cmdf('/nav loc %s', loc)
    local engaged = false
    local startD = mq.gettime() + 3000
    while mq.gettime() < startD do
        if mq.TLO.Navigation.Active() then engaged = true; break end
        if here() then break end
        mq.delay(100)
    end
    if not engaged and not here() then
        mq.cmdf('/nav loc %s', loc)   -- re-issue a dropped nav
        local r = mq.gettime() + 3000
        while mq.gettime() < r do
            if mq.TLO.Navigation.Active() then engaged = true; break end
            if here() then break end
            mq.delay(100)
        end
    end
    state.nav_stuck_reset()
    local deadline = mq.gettime() + 30000
    while mq.gettime() < deadline do
        if not mq.TLO.Navigation.Active() then break end
        if here() then break end
        state.nav_stuck_check('loc ' .. tostring(loc), loc)   -- log if wedged >5s; dest coords known
        mq.delay(100)
    end
    mq.delay(200)   -- settle
    return here()
end

-- Nav-stuck detector. Call once per poll iteration of a nav-wait loop with a label for the destination.
-- Nav can report Active() while the toon is physically wedged (mesh gap, pillar, geometry). We detect
-- that by watching whether position actually CHANGES: if we haven't moved more than STUCK_MOVE units in
-- STUCK_SECS seconds, we're stuck. On the first detection of an episode we append the stuck loc to
-- config/navstuck.ini (label | zone | Y X Z | heading | timestamp - same format as LocMarker) so problem
-- spots accumulate for later review and a ferry/waypoint fix. Returns true once per episode when it first
-- trips (so the caller can react - e.g. re-issue nav), then stays quiet until movement resumes/reset.
state.STUCK_SECS = 5
state.STUCK_MOVE = 3          -- units; below this over the window counts as "not moving"
state.nav_stuck_reset = function()
    state._stuckAnchorX = nil
    state._stuckAnchorY = nil
    state._stuckSince = nil
    state._stuckLogged = false
end
state.nav_stuck_check = function(destLabel, destLoc)
    local x, y = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0
    local now = mq.gettime()
    if not state._stuckAnchorX then
        state._stuckAnchorX, state._stuckAnchorY, state._stuckSince = x, y, now
        state._stuckLogged = false
        return false
    end
    local dx, dy = x - state._stuckAnchorX, y - state._stuckAnchorY
    if (dx*dx + dy*dy) > (state.STUCK_MOVE * state.STUCK_MOVE) then
        state._stuckAnchorX, state._stuckAnchorY, state._stuckSince = x, y, now
        state._stuckLogged = false
        return false
    end
    if (now - (state._stuckSince or now)) >= (state.STUCK_SECS * 1000) then
        if not state._stuckLogged then
            state._stuckLogged = true
            local who  = mq.TLO.Me.Name() or '?'
            local zone = mq.TLO.Zone.ShortName() or mq.TLO.Zone.Name() or 'unknown'
            local loc  = string.format('%.2f %.2f %.2f', y, x, mq.TLO.Me.Z() or 0)
            local head = string.format('%.1f', mq.TLO.Me.Heading.Degrees() or 0)
            local dest = tostring(destLabel or '?')
            local destL = destLoc and (' @ ' .. tostring(destLoc)) or ''
            -- One CSV-ish line per stuck episode. Fields: datetime, char, zone, stuck Y X Z, heading,
            -- intended destination (label and coords when known). Pipe-delimited for easy parsing.
            local line = string.format('%s | %s | %s | stuck=%s | hdg=%s | dest=%s%s\n',
                os.date('%Y-%m-%d %H:%M:%S'), who, zone, loc, head, dest, destL)
            local path = state.config_write('navstuck_persistent.ini')
            pcall(function()
                -- Write a self-documenting header once, when the file is new/empty.
                local existing = io.open(path, 'r')
                local isNew = true
                if existing then local first = existing:read('*l'); existing:close(); isNew = (first == nil) end
                local fh = io.open(path, 'a')
                if fh then
                    if isNew then
                        fh:write('; Lazcraft nav-stuck log - PERSISTENT (never rotated). Each line is one spot where nav\n')
                        fh:write('; wedged >' .. state.STUCK_SECS .. 's. Datamine these to find and fix problem locations.\n')
                        fh:write('; Format: datetime | char | zone | stuck=Y X Z | hdg=deg | dest=label [@ Y X Z]\n\n')
                    end
                    fh:write(line); fh:close()
                end
            end)
            printf_log('\ayNav appears stuck near %s (%s) heading %s -> %s - logged to navstuck_persistent.ini.\ax', loc, zone, dest, head)
        end
        return true
    end
    return false
end

-- If a destination is near an approach waypoint, nav to that waypoint first so the final approach
-- comes from clean ground instead of pathing into the destination's collision. If the destination
-- has NO hub but we're currently standing in one (e.g. leaving a vendor by the crafting cluster),
-- EXIT through that hub so the departure doesn't path out through the local collision. Same-zone
-- only for the exit case (a zone change walks nowhere). Returns the hub loc used, or nil.
state.route_via_waypoint = function(destLoc, destZone)
    local wp = state.approach_waypoint_for(destLoc, destZone)
    local leaving = false
    if not wp and (not destZone or destZone == current_zone()) then
        local myloc = string.format('%.2f %.2f %.2f', mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0, mq.TLO.Me.Z() or 0)
        wp = state.approach_waypoint_for(myloc, current_zone())
        leaving = (wp ~= nil)
    end
    if not wp then return nil end
    printf_log(leaving and 'Leaving via the safe waypoint first...' or 'Approaching via the safe waypoint first...')
    state.nav_loc_wait(wp)
    return wp
end

-- Route to a banker THROUGH the safe hub. Rule: if we're currently standing inside a safe-hub radius
-- (e.g. the crafting cluster we just combined at), step OUT to that hub first, THEN nav - so we leave
-- cleanly instead of pathing through the cluster's collision toward the banker. After that, if the
-- banker itself sits by a hub, come in via that one too. Target must already be the banker.
state.route_bank_via_hub = function()
    -- If we're in the PoK research-merchant pocket, ferry out (ferry -> safe hub) before anything else -
    -- the banker is on the hub side, past the station cluster.
    state.route_pok_ferry(nil, current_zone())
    local myloc = string.format('%.2f %.2f %.2f', mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0, mq.TLO.Me.Z() or 0)
    local myhub = state.approach_waypoint_for(myloc, current_zone())
    if myhub then
        printf_log('Leaving via the safe hub before heading to the bank...')
        state.nav_loc_wait(myhub)
    end
    if (mq.TLO.Target.ID() or 0) > 0 then
        local bloc = string.format('%.2f %.2f %.2f', mq.TLO.Target.Y() or 0, mq.TLO.Target.X() or 0, mq.TLO.Target.Z() or 0)
        local bwp = state.approach_waypoint_for(bloc, current_zone())
        if bwp then state.nav_loc_wait(bwp) end
    end
end

local supplyExhausted = {}  -- tracks items we've already tried and failed to get from mules

-- Accept an incoming trade on THIS toon. E3 won't auto-confirm trades on the active main driver, so
-- when a mule fills our trade window we click the Trade button ourselves (and handle the yes/no
-- confirmation if one pops). Called from the receive-wait loops while a mule is delivering.
state.accept_open_trade = function()
    if not mq.TLO.Window('TradeWnd').Open() then return false end
    mq.delay(600)                                  -- let the mule finish placing every slot
    if not mq.TLO.Window('TradeWnd').Open() then return false end
    mq.cmd('/notify TradeWnd TRDW_Trade_Button leftmouseup')
    mq.delay(400)
    if mq.TLO.Window('ConfirmationDialogBox').Open() then   -- some trades pop a confirm
        mq.cmd('/notify ConfirmationDialogBox Yes_Button leftmouseup')
        mq.delay(300)
    end
    return true
end

-- FAST GROUP CHECK: before any (slow) delivery, ask every in-zone group member how many of each item
-- they hold (bags + bank) via /ts_check, which replies over the peer net WITHOUT opening a bank or
-- moving. Fired for all members and all items at once, then we wait a short window for replies. Returns
-- a set { itemName = totalAvailable } for items at least one member has. This is what makes "check the
-- group for everything on craft start" cheap: nobody-has-it is a sub-second answer instead of a 10s
-- per-item mule spin-up. Members must be in the crafter's current zone (they deliver in-zone).
local function group_check(itemNames)
    local mules = state.same_zone_peers()
    if #mules == 0 then
        -- DIAGNOSTIC: no same-zone mules. Show what DanNet actually sees so we can tell a not-connected-yet
        -- network (empty Peers) from a zone/instance mismatch - the recurring "0 mules right after a restart".
        local okD, peers = pcall(function() return mq.TLO.DanNet.Peers() end)
        printf_log('group_check: 0 same-zone mules. my zone=[%s]  DanNet.Peers=[%s]',
            tostring(mq.TLO.Zone.ShortName() or '?'), okD and tostring(peers) or 'ERR')
        state.availReplies = {}; state.availHolders = {}; return {}
    end
    -- Item counts now come STRAIGHT FROM DanNet: FindItemCount[=name] over a quoted /dquery (proven
    -- ~66ms, spaces AND apostrophes both pass on Laz). No listener startup, no /ts_check, no reply-gather
    -- window - the TradeskillListener is only needed for the actual delivery + casting now. peer_item_counts
    -- fills availReplies[item]=total and availHolders[item]={mule=qty}, so every delivery consumer is unchanged.
    local avail = state.peer_item_counts(mules, itemNames)
    local got = 0
    for _ in pairs(avail) do got = got + 1 end
    printf_log('group_check: asked %d item(s) of %d mule(s) via DanNet, %d in stock.', #itemNames, #mules, got)
    return avail
end

local function request_supply(itemName, needed, recipient)
    needed = needed or math.huge   -- how many we want before we can stop early
    -- Build mule list from current group members
    if supplyExhausted[itemName] then
        printf_log('Supply of %s already exhausted this session - skipping.', itemName)
        return 0
    end
    local mules = {}
    local myName = mq.TLO.Me.Name() or ''
    recipient = recipient or myName                 -- who receives the item (default: us)
    local toOther = (recipient ~= myName)           -- delivering to a third party (e.g. the cleric)?
    for _, nm in ipairs(state.same_zone_peers()) do
        if nm ~= recipient then                     -- the recipient isn't a mule to ask; it's who we deliver TO
            mules[#mules + 1] = nm
        end
    end

    if #mules == 0 then
        printf_log('No same-zone networked characters found - cannot request %s.', itemName)
        return 0
    end

    printf_log('Found %d same-zone character(s) to try for %s.', #mules, itemName)
    local totalReceived = 0
    local startCount = toOther and 0 or item_count(itemName)   -- lag-free: progress = start + delivered

    for _, muleName in ipairs(mules) do
        -- Mule must be in OUR zone (it navigates to the crafter to deliver). Gate on actual zone, not spawn
        -- range: a same-zone mule can be across the map (PoK is huge) and still nav over. Spawn-visibility
        -- was too strict and skipped a valid same-zone mule.
        local mz = state.peer_zone(muleName)
        local myZone = trim(mq.TLO.Zone.ShortName() or '')
        if mz == '' or mz ~= myZone then
            printf_log('Mule %s not in our zone (%s) - skipping.', muleName, mz ~= '' and mz or '?')
            goto nextMule
        end

        printf_log('Requesting %s from %s...', itemName, muleName)

        -- Encode item name (replace spaces with underscores) to avoid MQ2 event parsing issues
        local encodedName = namecodec.encode(itemName)

        -- Start listener on mule
        state.peer_cmdf(muleName, '/lua run TradeskillListener')
        mq.delay(2000)  -- give it time to start

        -- Ask the mule to deliver one stack. It withdraws, navs, and trades on its
        -- own. Sent over /dex (silent peer network) with our name so the mule can
        -- /dex its responses straight back -- no game tells, no rate limiting.
        supplyResponse = { type = nil }
        -- Tell the mule EXACTLY how many we still need, so it delivers precisely that and the next
        -- mule tops up the remainder (order 333, this bot has 100 -> it brings 100; next brings 233).
        -- Open-ended requests (no finite target) fall back to a full-stack delivery.
        local haveNow = startCount + totalReceived   -- lag-free progress
        local remaining = (needed ~= math.huge) and math.max(1, needed - haveNow) or nil
        -- 4th arg = who the mule delivers TO; responses still come back to us (myName). 5th arg (when
        -- present) = the exact count still needed.
        if remaining then
            state.peer_cmdf(muleName, '/ts_need %s %s %s %d', myName, encodedName, recipient, remaining)
        else
            state.peer_cmdf(muleName, '/ts_need %s %s %s', myName, encodedName, recipient)
        end

        -- Wait for the mule. It first pings /ts_have (en route), then /ts_done
        -- or /ts_fail when the trade resolves (or /ts_none if nothing).
        local deadline = mq.gettime() + 30000
        while mq.gettime() < deadline
              and supplyResponse.type ~= 'done'
              and supplyResponse.type ~= 'fail'
              and supplyResponse.type ~= 'none' do
            mq.doevents()
            state.accept_open_trade()   -- click Trade ourselves (E3 won't on the main driver)
            if supplyResponse.type == 'have' then
                deadline = mq.gettime() + 45000   -- mule is delivering; give it time
                supplyResponse.type = nil
            end
            mq.delay(100)
        end

        if supplyResponse.type == 'done' then
            local received = supplyResponse.qty
            printf_log('Received %d %s from %s.', received, itemName, muleName)
            totalReceived = totalReceived + received
            -- When delivering to a third party we can't see their bags, so stop on the amount
            -- actually delivered; otherwise use our own on-hand count.
            local have = startCount + totalReceived   -- lag-free progress
            if have >= needed then
                break  -- enough delivered/on-hand, stop asking the rest
            end
            -- otherwise keep asking the remaining bots
        elseif supplyResponse.type == 'fail' then
            printf_log('Trade failed with %s.', muleName)
            state.peer_cmdf(muleName, '/ts_cancel %s', myName)
        else
            -- 'none' or timeout
            printf_log('%s does not have %s.', muleName, itemName)
            state.peer_cmdf(muleName, '/ts_cancel %s', myName)
        end

        ::nextMule::
    end

    if totalReceived == 0 then
        -- Same-zone came up empty. Before giving up, try the ask-first cross-zone flow: ask the whole
        -- network who has it, and if a holder is in the other reachable hub, travel there and re-request.
        -- Guard against recursion: the re-request inside try_cross_zone_supply runs in the new zone and
        -- must NOT re-enter cross-zone (it would loop hub-to-hub). _inCrossZone gates that.
        if state.crossZoneSupply and not state._inCrossZone then
            state._inCrossZone = true
            local xz = 0
            local ok = pcall(function() xz = state.try_cross_zone_supply(itemName, needed, recipient) or 0 end)
            state._inCrossZone = false
            if ok and xz > 0 then
                return xz
            end
        end
        printf_log('No %s available from any same-zone character - will not retry.', itemName)
        supplyExhausted[itemName] = true
    end
    return totalReceived
end

-- Ask the configured producer CLASS in our group to MAKE qty of itemName (Request
-- tab 'make' mode). Finds the in-group, in-zone member whose Class matches the
-- MAKEABLE config and sends /ts_make; errors out if that class isn't present.
-- Uses the same /dex response path (supplyResponse) as request_supply.
local function request_make(itemName, qty)
    qty = tonumber(qty) or 0
    if qty <= 0 then printf_log('Make %s: invalid quantity.', itemName); return 0 end

    local wantClass
    for _, m in ipairs(MAKEABLE) do
        if m.item:lower() == itemName:lower() then wantClass = m.class; break end
    end
    if not wantClass then
        printf_log('No producer configured for %s.', itemName); return 0
    end

    local myName = mq.TLO.Me.Name() or ''
    local producer
    for _, nm in ipairs(state.same_zone_peers()) do
        local sp = mq.TLO.Spawn(string.format('pc "%s"', nm))
        local cls = sp and sp.Class.Name() or ''
        if cls == wantClass then producer = nm; break end
    end
    if not producer then
        printf_log('No %s on the network in this zone - cannot make %s. Bring a %s into the zone.', wantClass, itemName, wantClass)
        return 0
    end
    if (mq.TLO.Spawn(string.format('pc "%s"', producer)).ID() or 0) == 0 then
        printf_log('%s (%s) not in zone - cannot make %s.', producer, wantClass, itemName)
        return 0
    end

    printf_log('Asking %s (%s) to make %d %s...', producer, wantClass, qty, itemName)
    local encodedName = namecodec.encode(itemName)
    -- Start the producer's listener only ONCE per request-run. Restarting it for a second summon
    -- would kill the first one mid-cast; instead the running listener queues each /ts_make in turn.
    state.makeListenersStarted = state.makeListenersStarted or {}
    if not state.makeListenersStarted[producer] then
        state.peer_cmdf(producer, '/lua run TradeskillListener')
        mq.delay(2000)
        state.makeListenersStarted[producer] = true
    end
    makeResponse = { type = nil }
    state.peer_cmdf(producer, '/ts_make %s %s %d', myName, encodedName, qty)

    -- Fire-and-forget: a cast batch can take a long time, so we don't block on it.
    -- Just confirm the producer started, then return. It keeps the items in its
    -- own bags and tells us (/ts_madedone) when done; you then Bring it from the
    -- Request tab, which delivers via the normal /ts_need trade (no re-casting).
    local deadline = mq.gettime() + 12000
    while mq.gettime() < deadline and makeResponse.type == nil do
        mq.doevents(); mq.delay(100)
    end
    if makeResponse.type == 'fail' then
        printf_log('%s could not start making %s.', producer, itemName)
    elseif makeResponse.type == 'start' then
        printf_log('%s is making %d %s in the background. You will get a notice when it is done; then Bring it from the Request tab.', producer, qty, itemName)
    else
        printf_log('No start confirmation from %s yet - it may still be working. Watch for the finished notice, then Bring it.', producer)
    end
    return 0
end

-- Smart-divide summons: given a basket of { {item=, qty=}, ... }, split the total casting work
-- across every capable, in-group, in-zone caster - EXCLUDING ourselves (the crafter stays free to
-- craft). Balances on QUANTITY (all imbues cast 5 per ~7s, so qty ~= time). One capable caster gets
-- the whole line solo; two+ split it. Constrained lines (fewest capable classes) are placed first.
state.dispatch_makes = function(basket)
    local myName = mq.TLO.Me.Name() or ''
    -- Roster: class -> { same-zone networked char names of that class, excluding self }.
    local byClass = {}
    for _, nm in ipairs(state.same_zone_peers()) do
        local sp = mq.TLO.Spawn(string.format('pc "%s"', nm))
        local cls = sp and sp.Class.Name() or ''
        if cls ~= '' then
            byClass[cls] = byClass[cls] or {}
            byClass[cls][#byClass[cls] + 1] = nm
        end
    end

    -- Resolve each line to its eligible casters (any capable class in the zone on the network).
    local lines = {}
    for _, b in ipairs(basket) do
        local cfg
        for _, m in ipairs(MAKEABLE) do if m.item:lower() == b.item:lower() then cfg = m; break end end
        if not cfg then
            printf_log('No producer configured for %s - skipping.', b.item)
        else
            local classes = cfg.classes or { cfg.class }
            local eligible = {}
            for _, cls in ipairs(classes) do
                for _, nm in ipairs(byClass[cls] or {}) do eligible[#eligible + 1] = nm end
            end
            if #eligible == 0 then
                printf_log('No capable caster in this zone for %s (needs %s) - skipping. Bring one into the zone.', b.item, table.concat(classes, '/'))
            else
                lines[#lines + 1] = { item = b.item, qty = b.qty, eligible = eligible }
            end
        end
    end
    if #lines == 0 then printf_log('Summon: no capable casters for anything requested.'); return end

    -- Assign most-constrained lines first, balancing total assigned qty across casters.
    table.sort(lines, function(a, b) return #a.eligible < #b.eligible end)
    local load = {}       -- caster -> total qty assigned so far
    local plan = {}       -- caster -> { item -> qty }
    local CHUNK = 5       -- casts yield 5 at a time; assign in 5s so splits land on cast boundaries
    for _, ln in ipairs(lines) do
        local remaining = ln.qty
        while remaining > 0 do
            local best, bestLoad = nil, math.huge
            for _, c in ipairs(ln.eligible) do
                if (load[c] or 0) < bestLoad then best = c; bestLoad = load[c] or 0 end
            end
            local give = math.min(CHUNK, remaining)
            plan[best] = plan[best] or {}
            plan[best][ln.item] = (plan[best][ln.item] or 0) + give
            load[best] = (load[best] or 0) + give
            remaining = remaining - give
        end
    end

    -- Fire /ts_make to each caster for its assigned lines (start each listener once).
    -- Diagnostic: show exactly who we detected and what each was assigned, so a mis-read class or a
    -- bad split is visible in the log instead of a silent "could not memorize" downstream.
    do
        local roster = {}
        for cls, names in pairs(byClass) do
            for _, nm in ipairs(names) do roster[#roster + 1] = nm .. '=' .. cls end
        end
        printf_log('Summon roster (excl. self): %s', #roster > 0 and table.concat(roster, ', ') or '(none)')
        for caster, items in pairs(plan) do
            local parts = {}
            for item, qty in pairs(items) do parts[#parts + 1] = string.format('%d %s', qty, item) end
            printf_log('  -> %s: %s', caster, table.concat(parts, ', '))
        end
    end
    state.makeListenersStarted = state.makeListenersStarted or {}
    state.summonFails = {}
    local triedFor = {}   -- item -> { caster = true } that already has this share / failed it

    -- Send one make share to a caster (starting its listener once).
    local function fire(caster, item, qty)
        if not state.makeListenersStarted[caster] then
            state.peer_cmdf(caster, '/lua run TradeskillListener')
            mq.delay(2000)
            state.makeListenersStarted[caster] = true
        end
        printf_log('Asking %s to make %d %s...', caster, qty, item)
        state.peer_cmdf(caster, '/ts_make %s %s %d', myName, namecodec.encode(item), qty)
        mq.delay(300)
    end

    -- Source the base gems onto each caster (on-hand -> crafter stock -> group -> buy) BEFORE firing,
    -- so each caster imbues supplied gems and buys nothing.
    local _gsOk, _gsErr = pcall(function() state.source_gems_for_plan(plan) end)
    if not _gsOk then printf_log('[gem sourcing] ERROR (casters fell back to buying their own): %s', tostring(_gsErr)) end

    -- Fire the initial plan.
    for caster, items in pairs(plan) do
        for item, qty in pairs(items) do
            fire(caster, item, qty)
        end
    end

    -- A class match doesn't guarantee the SPELL is scribed on that toon. Watch for "can't make this"
    -- reports and reassign each failed share to another capable caster; if none is left, say clearly
    -- which gem to scribe. Casters reject fast (spellbook check), so a few short rounds cover it.
    for _ = 1, 5 do
        local waited = 0
        while waited < 5000 do mq.doevents(); mq.delay(200); waited = waited + 200 end
        if not state.summonFails or #state.summonFails == 0 then break end
        local fails = state.summonFails
        state.summonFails = {}
        local anyReassigned = false
        for _, f in ipairs(fails) do
            triedFor[f.item] = triedFor[f.item] or {}
            triedFor[f.item][f.caster] = true
            local qty = plan[f.caster] and plan[f.caster][f.item]
            if qty and qty > 0 then
                plan[f.caster][f.item] = nil
                local cfg
                for _, m in ipairs(MAKEABLE) do if m.item:lower() == f.item:lower() then cfg = m; break end end
                -- Pick the least-loaded capable caster that hasn't itself REJECTED this item (a caster
                -- already assigned it is fine - it can absorb more; only an actual rejection excludes).
                local alt, altLoad = nil, math.huge
                if cfg then
                    for _, cls in ipairs(cfg.classes or { cfg.class }) do
                        for _, nm in ipairs(byClass[cls] or {}) do
                            if not (triedFor[f.item] and triedFor[f.item][nm]) then
                                local ld = 0
                                for _, q in pairs(plan[nm] or {}) do ld = ld + q end
                                if ld < altLoad then alt = nm; altLoad = ld end
                            end
                        end
                    end
                end
                if alt then
                    printf_log('\ay%s can\'t make %s (spell not scribed) - reassigning %d to %s.\ax', f.caster, f.item, qty, alt)
                    plan[alt] = plan[alt] or {}
                    plan[alt][f.item] = (plan[alt][f.item] or 0) + qty
                    triedFor[f.item][alt] = true
                    fire(alt, f.item, qty)
                    anyReassigned = true
                else
                    printf_log('\ar%s can\'t make %s, and no other capable caster in the zone has that imbue scribed - scribe it or skip that gem.\ax', f.caster, f.item)
                end
            end
        end
        if not anyReassigned then break end
    end
    printf_log('\agSummon dispatched across same-zone casters on the network - balanced by quantity.\ax')
end

-- "All" supply: ask every group member to bank-sweep EVERY stack of an item and
-- trade it over. Like request_supply, but uses the listener's /ts_need_all mode
-- and never stops early on a count -- we want everything everyone has. Crafter
-- stays put; each in-zone mule navs to us. Returns total received.
local function request_all(itemName)
    local myName = mq.TLO.Me.Name() or ''
    local mules = state.same_zone_peers()
    if #mules == 0 then
        printf_log('No same-zone networked characters found - cannot request %s.', itemName)
        return 0
    end

    local encodedName = namecodec.encode(itemName)
    local totalReceived = 0
    for _, muleName in ipairs(mules) do
        check_stop()
        local mz = state.peer_zone(muleName)
        local myZone = trim(mq.TLO.Zone.ShortName() or '')
        local function spawnHere() return (mq.TLO.Spawn(string.format('pc "%s"', muleName)).ID() or 0) > 0 end
        local reachable = false
        if mz == '' or mz ~= myZone then
            printf_log('Mule %s not in our zone (%s) - skipping.', muleName, mz ~= '' and mz or '?')
        elseif spawnHere() then
            reachable = true
        else
            -- Same zone NAME but not a spawn in OUR instance - we can't tell live vs AFK. Resolve it
            -- deterministically: anchor out and back (=> live), check, then the AFK mirror. Exhaustive.
            printf_log('%s reports %s but isn\'t in our instance - resolving live vs AFK...', muleName, mz)
            if state.reach_same_zone_holder(myZone, spawnHere) then
                reachable = true
            else
                printf_log('%s not reachable in %s (live or AFK mirror) - skipping.', muleName, myZone)
            end
        end
        if reachable then
            printf_log('Requesting ALL %s from %s (bank sweep)...', itemName, muleName)
            state.peer_cmdf(muleName, '/lua run TradeskillListener')
            mq.delay(2000)
            supplyResponse = { type = nil }
            state.peer_cmdf(muleName, '/ts_need_all %s %s', myName, encodedName)

            -- A big haul can take several trade trips; the mule pings /ts_have
            -- before each (extends our wait) and /ts_done with its total at the end.
            local deadline = mq.gettime() + 60000
            while mq.gettime() < deadline
                  and supplyResponse.type ~= 'done'
                  and supplyResponse.type ~= 'fail'
                  and supplyResponse.type ~= 'none' do
                mq.doevents()
                state.accept_open_trade()   -- click Trade ourselves (E3 won't on the main driver)
                if supplyResponse.type == 'have' then
                    deadline = mq.gettime() + 60000   -- still delivering
                    supplyResponse.type = nil
                end
                mq.delay(100)
            end

            if supplyResponse.type == 'done' then
                totalReceived = totalReceived + (supplyResponse.qty or 0)
                printf_log('%s delivered %d %s.', muleName, supplyResponse.qty or 0, itemName)
            elseif supplyResponse.type == 'fail' then
                printf_log('Trade failed with %s.', muleName)
                state.peer_cmdf(muleName, '/ts_cancel %s', myName)
            else
                printf_log('%s has no %s.', muleName, itemName)
            end
        end
    end
    printf_log('Total %s received: %d', itemName, totalReceived)
    return totalReceived
end

-- Ask ONE already-listening character for ONE item and wait for the trade to resolve.
-- Returns qty received (0 on none/fail/timeout). The CALLER starts the char's listener
-- (so a whole batch of items can be asked of one character without restarting it).
-- mode='all' uses the bank-sweep command + a longer wait; anything else pulls one stack.
-- Kept on `state` (main chunk is at Lua's local ceiling).
state.ask_listening_char = function(charName, itemName, recipient, mode)
    local myName = mq.TLO.Me.Name() or ''
    recipient = recipient or myName
    local encodedName = namecodec.encode(itemName)
    local isAll = (mode == 'all')
    supplyResponse = { type = nil }
    if isAll then
        state.peer_cmdf(charName, '/ts_need_all %s %s 1', myName, encodedName)        -- trailing 1 = keep alive
    else
        state.peer_cmdf(charName, '/ts_need %s %s %s 0 1', myName, encodedName, recipient)  -- 4th=0 (stack), 5th 1 = keep alive
    end
    local window = isAll and 60000 or 30000
    local deadline = mq.gettime() + window
    while mq.gettime() < deadline
          and supplyResponse.type ~= 'done'
          and supplyResponse.type ~= 'fail'
          and supplyResponse.type ~= 'none' do
        mq.doevents()
        state.accept_open_trade()   -- click Trade ourselves (E3 won't on the main driver)
        if supplyResponse.type == 'have' then
            deadline = mq.gettime() + (isAll and 60000 or 45000)   -- en route; extend
            supplyResponse.type = nil
        end
        mq.delay(100)
    end
    if supplyResponse.type == 'done' then
        return supplyResponse.qty or 0
    else
        if supplyResponse.type == 'fail' then printf_log('  Trade failed with %s.', charName) end
        -- NOTE: do NOT /ts_cancel here. With keep-alive batching that would stop the
        -- listener mid-batch (a 'none' on item 1 would kill it before item 2). The grouped
        -- caller sends a single /ts_cancel after the whole batch.
        return 0
    end
end

-- Grouped supply pass: contact each character ONCE and ask it for every still-needed item
-- before moving on (instead of looping all characters per item). This is the per-character
-- batching - far fewer round-trips and listener starts.
--   items     : { { name=, needed=, mode= }, ... }  ('all' => drain; needed=math.huge)
--   targetChar : if set, ask ONLY this character (no group fan-out, no bank-first); used by
--                the Request tab's "from" dropdown. Caller handles crafter-bank-first.
-- Logs a shortfall line per item that didn't reach `needed` (so a targeted ask clearly
-- "fails" when that character doesn't have it).
state.request_supply_grouped = function(items, targetChar)
    local myName = mq.TLO.Me.Name() or ''
    local chars = {}
    if targetChar and targetChar ~= '' then
        chars = { targetChar }
    else
        for _, nm in ipairs(state.same_zone_peers()) do chars[#chars + 1] = nm end
    end
    if #chars == 0 then
        printf_log(targetChar and ('%s is not available.'):format(targetChar)
            or 'No same-zone networked characters online to ask - start their listeners (mules in an AFK/mirror instance are a different zone and will not be seen).')
        return
    end

    local function short(it) return item_count(it.name) < it.needed end

    for _, charName in ipairs(chars) do
        check_stop()
        local anyShort = false
        for _, it in ipairs(items) do if short(it) then anyShort = true break end end
        if not anyShort then break end   -- everything satisfied; stop early

        local function spawnHere() return (mq.TLO.Spawn(('pc "%s"'):format(charName)).ID() or 0) > 0 end
        local reachable = spawnHere()
        if not reachable then
            -- Not a spawn in THIS instance. If they report our zone name, we're likely in different
            -- instances (live vs AFK mirror) - hop to the AFK mirror and re-check before giving up.
            local cz = state.peer_zone(charName)
            local myZone = trim(mq.TLO.Zone.ShortName() or '')
            if cz ~= '' and cz == myZone then
                printf_log('%s reports %s but isn\'t in our instance - resolving live vs AFK...', charName, cz)
                if state.reach_same_zone_holder(myZone, spawnHere) then
                    reachable = true
                end
            end
        end
        if not reachable then
            printf_log('%s not reachable in zone (live or AFK mirror) - skipping.', charName)
        else
            local shortItems = {}
            for _, it in ipairs(items) do if short(it) then shortItems[#shortItems + 1] = it end end
            printf_log('Asking %s for %d still-needed item(s) in one batch...', charName, #shortItems)
            state.peer_cmdf(charName, '/lua run TradeskillListener')
            mq.delay(2000)

            -- Build the batch on the mule (one /ts_qadd per item), snapshotting our counts
            -- so we can measure what actually arrives.
            local before = {}
            for _, it in ipairs(shortItems) do
                check_stop()
                before[it.name] = item_count(it.name)
                -- Pass the exact still-needed count (finite needed) so the mule delivers precisely
                -- that; 'all' (needed == huge) sends 0 and the mule sweeps by mode instead.
                local qadd = (it.needed ~= math.huge) and math.max(0, math.floor(it.needed - item_count(it.name))) or 0
                state.peer_cmdf(charName, '/ts_qadd %s %s %d', namecodec.encode(it.name), it.mode or 'stack', qadd)
                mq.delay(150)   -- small gap so the queued items land in order
            end

            -- Execute: the mule makes ONE bank trip and trades everything (8 per window).
            -- Wait for /ts_qdone; each /ts_have ping (start of every trade trip) extends the wait.
            supplyResponse = { type = nil }
            state.peer_cmdf(charName, '/ts_qrun %s', myName)
            local deadline = mq.gettime() + 120000
            while mq.gettime() < deadline and supplyResponse.type ~= 'qdone' do
                mq.doevents()
                state.accept_open_trade()   -- click Trade ourselves (E3 won't on the main driver)
                if supplyResponse.type == 'have' then
                    deadline = mq.gettime() + 120000   -- progress; keep waiting
                    supplyResponse.type = nil
                end
                check_stop()
                mq.delay(100)
            end
            mq.delay(500)   -- let the final trade fully settle into bags before we re-read counts

            -- Report per-item deltas (deliveries land directly in our bags).
            for _, it in ipairs(shortItems) do
                local got = item_count(it.name) - (before[it.name] or 0)
                if got > 0 then
                    printf_log('  %s: +%d (now %d%s).', it.name, got, item_count(it.name),
                        it.needed ~= math.huge and ('/' .. it.needed) or '')
                end
            end

            -- Done with this character: the keep-alive listener won't stop on its own, so
            -- shut it down cleanly before moving to the next.
            state.peer_cmdf(charName, '/ts_cancel %s', myName)
        end
    end

    -- Shortfall report (a targeted ask that comes up short is the "fail if they don't have it").
    for _, it in ipairs(items) do
        if it.needed ~= math.huge and item_count(it.name) < it.needed then
            if targetChar then
                printf_log('\ar%s did not have enough %s (%d/%d).\ax', targetChar, it.name, item_count(it.name), it.needed)
            else
                printf_log('\ayShort on %s after asking the group: %d/%d.\ax', it.name, item_count(it.name), it.needed)
            end
        end
    end
end
mq.event('ts_desync',  'Inventory Desyncronization detected#*#',  function()
    desyncDetected = true
    desyncLatch = true
    combineFlags.desync = true   -- per-combine: distinguishes a desync miss from a plain skill fizzle
    state.desyncCount = (state.desyncCount or 0) + 1   -- true per-run tally: catches placement AND combine desyncs
    state.dlog('>>> DESYNC FIRED. cursor=%s stack=%d',
        (mq.TLO.Cursor.Name() or '(empty)'), (mq.TLO.Cursor.Stack() or 0))
end)

-- "Cannot top an item into the cursor slot!" means the client cursor read empty (so our
-- drain-before-pickup guard passed) but the SERVER still held a cursor item - a client/server
-- split, common on big runs. Treat it exactly like a desync so world_stage aborts and does the
-- clean close/reopen resync instead of plowing on and stacking onto stranded items.
mq.event('ts_cannottop', '#*#Cannot top an item into the cursor slot#*#', function()
    desyncDetected = true
    desyncLatch = true
    combineFlags.desync = true
    state.desyncCount = (state.desyncCount or 0) + 1
    state.dlog('>>> CANNOT-TOP FIRED (treating as desync). cursor=%s stack=%d',
        (mq.TLO.Cursor.Name() or '(empty)'), (mq.TLO.Cursor.Stack() or 0))
end)

-- ---------------------------------------------------------------------------
-- Navigation / merchant
-- ---------------------------------------------------------------------------

-- Drop levitation right before any navigation - a levitating toon floats off the mesh and
-- paths poorly. Fired at every nav kickoff. Safe to spam (a no-op when not levitating), and
-- since E3 is paused during runs it won't get re-cast mid-nav.
-- Shrink (via a click item) so tight, dwarf-built geometry doesn't snag the toon while we maneuver
-- to a vendor or station. Only when forWork (an actual buy/craft approach - pure travel/zoning skips
-- it, since we're just passing through), only once per zone, and only if we aren't already small.
state.lastShrinkZone = nil
state.maybe_shrink = function(forWork)
    if not forWork then return end                    -- just traveling: don't bother shrinking
    local name = trim(state.shrinkName or '')
    if name == '' then return end                     -- no shrink configured: never pause to shrink (default)
    local z = current_zone()
    if state.lastShrinkZone == z then return end      -- already handled this zone
    if (mq.TLO.Me.Height() or 99) <= 2.5 then state.lastShrinkZone = z; return end  -- already small enough
    local ty = state.shrinkType or 'Item'
    if ty == 'Item' and item_count(name) < 1 then return end   -- item not on hand: act as if nothing was set
    state.lastShrinkZone = z
    mq.delay(500)   -- settle: an effect fired the instant a prior nav stops gets interrupted, so let movement stop first
    printf_log('Shrinking (%s) with %s before working in %s...', ty, name, z)
    if ty == 'Spell' then
        mq.cmdf('/memspell 8 "%s"', name)
        mq.delay(10000, function() return (mq.TLO.Me.Gem(8).Name() or '') == name end)
        mq.cmd('/cast 8')
        mq.delay(1500, function() return (mq.TLO.Me.Casting.ID() or 0) > 0 end)
        mq.delay(12000, function() return (mq.TLO.Me.Casting.ID() or 0) == 0 end)
    elseif ty == 'AA' then
        mq.cmdf('/aa act %s', name)   -- no quotes: /aa act takes the whole name as-is
        mq.delay(5000)
    else   -- Item
        mq.cmdf('/useitem "%s"', name)
        mq.delay(5000)   -- let the shrink cast finish before we start moving
    end
end

-- Zones where levitate floats the toon off the mesh and snags on geometry - drop it ONLY here.
-- Covers Thurgadin + the Great Divide leg on the way to it, and Felwithe + the Greater Faydark leg
-- on the way to it. Everywhere else keeps levitate (it helps some routes). Shortnames; verify the
-- two transit zones (greatdivide / gfaydark) if a leg still gets stuck.
state.DROPLEV_ZONES = { [ZONE_THURGADIN] = true, [ZONE_FELWITHE] = true, greatdivide = true, gfaydark = true }
state.pre_nav = function(forWork)
    state.maybe_illusion()   -- faction-zone illusion (Felwithe/Jaggedpine) BEFORE the shrink
    state.maybe_shrink(forWork)   -- shrink only for a buy/craft approach, and only if not already small
    if state.DROPLEV_ZONES[current_zone()] then   -- drop levitate only in the stuck-prone zones
        mq.cmd('/droplev')
        mq.delay(100)
    end
end

-- Faction-zone illusion: Felwithe and Jaggedpine vendors are faction-reliant, so apply the
-- character's configured illusion once on zone-in, BEFORE the shrink. Spell mems into gem 8 and
-- casts (waits out the cast so it lands before we move); Item is /useitem; AA is /aa act. Only one
-- fires per the configured Type (Spell/Item/AA). Fire-and-forget - we do NOT verify it worked.
-- No-op outside those two zones or if nothing is configured. Fires once per zone (lastIllusionZone).
state.lastIllusionZone = nil
state.maybe_illusion = function()
    local z = current_zone()
    if z ~= ZONE_FELWITHE and z ~= ZONE_JAGGEDPINE then return end
    if state.lastIllusionZone == z then return end
    state.lastIllusionZone = z
    local name = trim(state.illusionName or '')
    if name == '' then return end
    local ty = state.illusionType or 'Spell'
    if ty == 'Spell' then
        printf_log('Illusion (faction zone): memming "%s" in gem 8 and casting...', name)
        mq.cmdf('/memspell 8 "%s"', name)
        mq.delay(10000, function() return (mq.TLO.Me.Gem(8).Name() or '') == name end)
        mq.cmd('/cast 8')
        mq.delay(1500, function() return (mq.TLO.Me.Casting.ID() or 0) > 0 end)   -- wait for the cast to start
        mq.delay(12000, function() return (mq.TLO.Me.Casting.ID() or 0) == 0 end) -- then to finish
        mq.delay(500)
    elseif ty == 'AA' then
        printf_log('Illusion (faction zone): /aa act %s...', name)
        mq.cmdf('/aa act %s', name)   -- no quotes: /aa act takes the whole name as-is
        mq.delay(3000)   -- give any cast a moment (not verified)
    else   -- Item
        printf_log('Illusion (faction zone): /useitem %s...', name)
        mq.cmdf('/useitem "%s"', name)
        mq.delay(3000)   -- give any cast a moment (not verified)
    end
end

-- ── Height-aware distance to a spawn ──────────────────────────────────────────────────────────
-- MacroQuest's Spawn.Distance() is HORIZONTAL only (X/Y) - a target directly above or below reads
-- as "close" even when it's a full floor away and can't be interacted with. These helpers add the Z
-- axis so reach checks don't false-positive on "same map dot, wrong height".
--   spawn_dist3d(sp) -> true 3D distance (sqrt(dx^2+dy^2+dz^2)), or a big number if unreadable.
--   spawn_zgap(sp)   -> absolute vertical gap only (|myZ - targetZ|); the "am I on the right floor" check.
-- Pass a spawn TLO (e.g. mq.TLO.Target, mq.TLO.Spawn('npc "Name"')). Returns 99999 if the spawn/coords
-- aren't readable, so callers treat "unknown" as "far" and keep navigating rather than falsely arriving.
state.spawn_dist3d = function(sp)
    if not sp or (sp.ID() or 0) == 0 then return 99999 end
    local mx, my, mz = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
    local sx, sy, sz = sp.X(), sp.Y(), sp.Z()
    if not (mx and my and mz and sx and sy and sz) then
        -- Fall back to the 2D distance if Z is unreadable - better than nothing.
        return sp.Distance() or 99999
    end
    local dx, dy, dz = mx - sx, my - sy, mz - sz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

state.spawn_zgap = function(sp)
    if not sp or (sp.ID() or 0) == 0 then return 99999 end
    local mz, sz = mq.TLO.Me.Z(), sp.Z()
    if not (mz and sz) then return 99999 end
    return math.abs(mz - sz)
end

-- Convenience: "is this spawn genuinely reachable" - close in 3D AND not separated by a big vertical
-- gap. maxDist is the 3D reach (default 25); maxZ is the height tolerance (default 15 - enough for a
-- ramp/step, small enough to reject a floor above/below). Use this instead of a bare Distance() <= N
-- when a target could be stacked vertically (multi-level rooms, platforms, ledges).
state.spawn_reachable = function(sp, maxDist, maxZ)
    maxDist = maxDist or 25
    maxZ = maxZ or 15
    if not sp or (sp.ID() or 0) == 0 then return false end
    return state.spawn_dist3d(sp) <= maxDist and state.spawn_zgap(sp) <= maxZ
end

-- Target a banker. PoK's bankers cluster and most path badly - Dogle Pitt is the nav-reliable one,
-- so target him by name there (falling back to any banker if he's somehow not found). Other zones
-- just grab the nearest banker.
state.target_banker = function()
    if current_zone() == ZONE_POK then
        -- Nearest of the three known-good bankers (3D so the lower-tier gap counts). Dogle Pitt navs
        -- clean; Banker Ceridan / Banker Granger are reached via the staging waypoint in
        -- state.approachWaypoints (route_bank_via_hub routes through it). Picking nearest = less travel.
        local who, whod
        for _, n in ipairs({ 'Dogle Pitt', 'Banker Ceridan', 'Banker Granger' }) do
            local d = mq.TLO.Spawn(n).Distance3D()
            if d and d > 0 and (not whod or d < whod) then who, whod = n, d end
        end
        if who then
            mq.cmdf('/target %s', who)
            mq.delay(500, function() return (mq.TLO.Target.ID() or 0) > 0 end)
            if (mq.TLO.Target.ID() or 0) > 0 then return end
        end
    end
    mq.cmd('/target npc banker')
    mq.delay(500, function() return (mq.TLO.Target.ID() or 0) > 0 end)
    if (mq.TLO.Target.ID() or 0) == 0 then
        mq.cmd('/target npc banker radius 200')
        mq.delay(500, function() return (mq.TLO.Target.ID() or 0) > 0 end)
    end
end

-- Draught of the Craftsman: a clicky that buffs "scavenge" so a FAILED combine returns the mats
-- instead of eating them. Auto-used (once per run, before the world container opens) for the hard
-- Radix recipes listed here, when the per-recipe checkbox is on (auto-checked). No-op without the
-- item. ASSUMES the item name is exactly 'Draught of the Craftsman' - verify in-game.
state.draughtRecipes = { ['Essence Fusion Chamber'] = true }
state.useDraught = {}   -- per-recipe checkbox state; nil/true = on (auto-filled), false = off
state.maybe_use_draught = function(recipeName)
    if state.draughtUsedThisRun then return end
    if not state.draughtRecipes[recipeName] then return end
    if state.useDraught[recipeName] == false then return end   -- checkbox unticked
    local DRAUGHT = 'Draught of the Craftsman'
    if item_count(DRAUGHT) < 1 then
        printf_log('%s: %s not in bags - combining without the scavenge buff.', recipeName, DRAUGHT)
        return
    end
    state.draughtUsedThisRun = true
    printf_log('Clicking %s before the %s combine (scavenges the mats if it fails)...', DRAUGHT, recipeName)
    mq.cmdf('/useitem "%s"', DRAUGHT)
    mq.delay(5000)   -- let the buff land (stationary) before we nav to / open the container
end

-- Shared pathing core: walks to an already-resolved spawn ID. `label` is
-- just for log messages.
-- Temple of Marr's nav mesh snags in spots and we get hung on geometry. Right after
-- zoning in, route through a known-good NPC (Soulbinder Tomas) once to put us at a
-- clean starting point before heading anywhere. No-op outside Marr, when Tomas isn't
-- found, or when we're already next to him. Uses a raw /nav id (not nav_to_spawn).
local function marr_unstick()
    if current_zone() ~= ZONE_MARR then return end
    -- spawns can lag for a moment right after a zone-in; give Tomas time to appear
    mq.delay(2500, function() return (mq.TLO.Spawn('Soulbinder Tomas').ID() or 0) > 0 end)
    local tomas = mq.TLO.Spawn('Soulbinder Tomas')
    local id = tomas.ID() or 0
    if id <= 0 then return end
    if (tomas.Distance() or 9999) <= 30 then return end
    printf_log('Marr: routing via Soulbinder Tomas to avoid geometry...')
    state.pre_nav()
    mq.cmdf('/nav id %d distance=15', id)
    mq.delay(500, function() return mq.TLO.Navigation.Active() end)
    state.nav_stuck_reset()
    local deadline = mq.gettime() + 20000
    while mq.gettime() < deadline do
        if (mq.TLO.Spawn('Soulbinder Tomas').Distance() or 9999) <= 20 then break end
        if not mq.TLO.Navigation.Active() then break end
        state.nav_stuck_check('Soulbinder Tomas')
        mq.delay(100)
    end
end

-- Some vendors sit in tight/elevated geometry where navving straight onto the NPC lands us on the
-- counter or wedges on height. For those zones we nav to a fixed staging loc NEXT TO the vendor
-- (close enough to open the merchant) and STOP there - no final approach onto the spawn. Locs are
-- "Y X Z" (/nav loc order). crouch=true runs the stuck->crouch mitigation while pathing there.
state.CROUCH_CMD = '/keypress duck'   -- CONFIRM: the crouch/duck keybind for your client; swap if different
state.vendorApproachLoc = {
    [ZONE_THURGADIN] = { loc = '-337.18 -64.11 3.12', crouch = true },   -- off the counter; crouch to slip height
    [ZONE_FELWITHE]  = { loc = '-88.09 -414.17 5.91' },
}
state.VENDOR_APPROACH_R = 50   -- only use the staging loc when the target vendor is within this of it

-- Nav to a plain loc and wait until we arrive (or nav genuinely stops). If crouchOnStuck, and we make
-- no real progress for >2s while still navigating, tap crouch once to slip geometry (stand back up on
-- arrival). Returns true if we ended up within ~arriveDist of the loc.
state.nav_loc_arrive = function(loc, arriveDist, crouchOnStuck)
    arriveDist = arriveDist or 15
    local ly, lx, lz = tostring(loc):match('([%-%.%d]+)%s+([%-%.%d]+)%s+([%-%.%d]+)')
    if not ly then return false end
    ly, lx, lz = tonumber(ly), tonumber(lx), tonumber(lz)
    local function d3()
        local dx = (mq.TLO.Me.X() or 0) - lx
        local dy = (mq.TLO.Me.Y() or 0) - ly
        local dz = (mq.TLO.Me.Z() or 0) - lz
        return math.sqrt(dx*dx + dy*dy + dz*dz)
    end
    mq.cmdf('/nav loc %s', loc)
    delay(1500, function() return mq.TLO.Navigation.Active() or d3() <= arriveDist end)
    local deadline  = mq.gettime() + 60000
    local lastX, lastY = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0
    local stuckSince = mq.gettime()
    local crouched   = false
    while mq.gettime() < deadline do
        check_stop()
        if d3() <= arriveDist then break end
        if not mq.TLO.Navigation.Active() then break end
        local nx, ny = mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0
        if math.sqrt((nx-lastX)^2 + (ny-lastY)^2) > 3 then
            lastX, lastY, stuckSince = nx, ny, mq.gettime()   -- real progress: reset the stuck timer
        elseif crouchOnStuck and not crouched and (mq.gettime() - stuckSince) > 2000 then
            printf_log('Stuck for >2s pathing to the staging spot - crouching to slip the geometry...')
            mq.cmd(state.CROUCH_CMD)
            crouched, stuckSince = true, mq.gettime()
        end
        delay(200)
    end
    if crouched then mq.cmd(state.CROUCH_CMD) end   -- stand back up so we don't walk the rest crouched
    return d3() <= (arriveDist + 5)
end

local function nav_to_spawn(id, label)
    check_stop()
    if not id or id == 0 then
        printf_log('Could not find %s.', label)
        return false
    end
    mq.cmdf('/target id %d', id)
    delay(1000, function() return (mq.TLO.Target.ID() or 0) == id end)
    local function dist() return mq.TLO.Target.Distance() or 999 end
    -- Height-aware "already here": Target.Distance() is HORIZONTAL only, so a vendor/banker directly
    -- above or below (a different floor of a multi-level room - common in PoK) reads as ~0 away and we'd
    -- wrongly bail as "arrived", then the interaction fails because we can't actually reach them. Only
    -- short-circuit when we're close in 2D AND on roughly the same level (small Z gap); otherwise fall
    -- through and actually navigate (which climbs the ramp/stairs to close the vertical gap).
    local zgap = state.spawn_zgap(mq.TLO.Target)
    if dist() <= 10 and zgap <= 12 then mq.cmd('/face fast') return true end
    if dist() <= 10 and zgap > 12 then
        printf_log('%s is close on the map but %.0f up/down (different level) - navigating to the right floor...', label, zgap)
    end

    -- Route through a safe hub when approaching a wedge-prone spot - and when LEAVING one (the router
    -- exits via the current hub if the destination has none). Past the <=10 early return, so we only
    -- route when we actually travel; nav_loc_wait no-ops if we're already on the hub.
    do
        local sloc = string.format('%.2f %.2f %.2f', mq.TLO.Target.Y() or 0, mq.TLO.Target.X() or 0, mq.TLO.Target.Z() or 0)
        -- Marr ferry first: if this is a cross-side trip, dock-to-dock across the clear north end before
        -- the normal approach. If it ferried, we're now on the destination's side; normal nav finishes.
        state.route_marr_ferry(sloc, current_zone())
        -- PoK research-merchant pocket uses the explicit ferry lane (deterministic by vendor name).
        -- Skip the radius-hub router only when the ferry took us INTO the pocket for a merchant
        -- (it owns that trip). On a ferry-OUT (or no ferry), still stage the destination's own hub.
        if state.route_pok_ferry(label, current_zone()) ~= 'in' then
            state.route_via_waypoint(sloc, current_zone())
        end
    end

    -- Staging-loc vendors (Thurg/Felwithe): nav to the fixed spot beside the vendor and open
    -- from there instead of pathing onto the NPC. Only when THIS target is the vendor the loc
    -- serves (near it), so porters/other in-zone NPCs still nav normally.
    local va = state.vendorApproachLoc[current_zone()]
    if va then
        local ay, ax, az = va.loc:match('([%-%.%d]+)%s+([%-%.%d]+)%s+([%-%.%d]+)')
        local near = ay and (((mq.TLO.Target.Y() or 0)-tonumber(ay))^2
                           + ((mq.TLO.Target.X() or 0)-tonumber(ax))^2
                           + ((mq.TLO.Target.Z() or 0)-tonumber(az))^2) <= (state.VENDOR_APPROACH_R*state.VENDOR_APPROACH_R)
        if near then
            printf_log('Approaching %s via its staging spot (no counter-climb)...', label)
            state.pre_nav(true)
            local ok = state.nav_loc_arrive(va.loc, 15, va.crouch)
            mq.cmd('/nav stop'); mq.cmd('/face fast')
            if not ok then printf_log('Could not reach the staging spot for %s.', label) end
            return ok
        end
    end

    printf_log('Navigating to %s...', label)
    state.pre_nav(true)   -- buying/selling here: shrink if needed
    mq.cmdf('/nav id %d distance=10', id)
    -- 3D distance for arrival: prevents "false arrival" when the path passes directly over/under the
    -- target (2D dist momentarily small, but we're a floor away). /nav walks the mesh, so real arrival
    -- closes the Z gap too.
    local function dist3() return state.spawn_dist3d(mq.TLO.Target) end
    state.nav_stuck_reset()
    local deadline = mq.gettime() + 60000
    while mq.gettime() < deadline do
        check_stop()
        if dist3() <= 12 then break end
        if not mq.TLO.Navigation.Active() then
            mq.cmdf('/moveto id %d', id)
            delay(8000, function() return dist3() <= 12 end)
            break
        end
        local _dloc = string.format('%.2f %.2f %.2f', mq.TLO.Target.Y() or 0, mq.TLO.Target.X() or 0, mq.TLO.Target.Z() or 0)
        state.nav_stuck_check(label, _dloc)   -- log if wedged >5s en route to this target (dest coords known)
        delay(200)
    end
    mq.cmd('/nav stop')
    mq.cmd('/face fast')
    if dist3() > 15 then
        printf_log('Could not reach %s (%.0f away, 3D).', label, dist3())
        return false
    end
    return true
end

-- Navigate to a specific NPC by exact name (used for buying, where the
-- recipe data tells us exactly who sells the ingredients).
local function nav_to(name)
    local id = mq.TLO.Spawn(string.format('npc "%s"', name)).ID() or 0
    return nav_to_spawn(id, name)
end

-- Crafter -> peer hand-off. Deliver `qty` of `itemName` from OUR bags to a networked peer (e.g. base
-- gems to a caster we're supplying). Every other trade in the suite flows peer->crafter; this is the
-- one outbound path. It mirrors the listener's proven trade_item sequence: nav to the peer, target it,
-- pick the stack (QuantityWnd sets the exact count), drop it on the target to open/fill the trade, then
-- click Trade - the peer's own listener clicks ITS side (that's how it auto-accepts), so the window
-- closing = both accepted. Returns how many we handed over. The peer must be running TradeskillListener;
-- we start it first. Assumes E3 is already paused by the job (a live E3 grabs the cursor mid-pickup).
state.deliver_to_peer = function(peerName, itemName, qty)
    qty = qty or item_count(itemName)
    if qty <= 0 or item_count(itemName) <= 0 then
        printf_log('Nothing to hand %s: no %s on hand.', peerName, itemName); return 0
    end
    state.peer_cmdf(peerName, '/lua run TradeskillListener')   -- so it can click its side of the trade
    mq.delay(1500)

    local pid = mq.TLO.Spawn(string.format('pc "%s"', peerName)).ID() or 0
    if pid == 0 then printf_log('Cannot find %s to deliver %s.', peerName, itemName); return 0 end
    if not nav_to_spawn(pid, peerName) then
        printf_log('Could not reach %s to deliver %s.', peerName, itemName); return 0
    end
    mq.cmdf('/target pc %s', peerName)
    mq.delay(500, function() return (mq.TLO.Target.Name() or ''):lower() == peerName:lower() end)
    if (mq.TLO.Target.Name() or ''):lower() ~= peerName:lower() then
        printf_log('Could not target %s.', peerName); return 0
    end

    local placed, slots = 0, 0
    while placed < qty and slots < 8 and item_count(itemName) > 0 do
        clear_cursor()
        -- Locate the item's bag/slot so we can grab EXACTLY `want` via the split dialog. (find_item_slot
        -- is defined later in the file, so the search is inlined here.)
        local bagNum, slotNum
        do
            local up = itemName:upper()
            for b = 1, 10 do
                local cont = mq.TLO.Me.Inventory('pack' .. b).Container() or 0
                if cont > 0 then
                    for sl = 1, cont do
                        local nm = mq.TLO.Me.Inventory('pack' .. b).Item(sl).Name()
                        if nm and nm:upper() == up then bagNum, slotNum = b, sl; break end
                    end
                end
                if bagNum then break end
            end
        end
        if not bagNum then printf_log('Could not locate %s in bags for %s.', itemName, peerName); break end
        local slotStack = mq.TLO.Me.Inventory('pack' .. bagNum).Item(slotNum).Stack() or 1
        local want = math.min(qty - placed, slotStack)

        -- Grab exactly `want` using the SAME gesture the bank withdraw does ~reliably: right-click the
        -- bag to OPEN it (a closed bag grabs the whole stack), left-click the slot to pop the split, then
        -- set the amount via the SetText TLO and WAIT until the field actually reads it before accepting
        -- (accepting early takes the full-stack default - the over-grab bug). SINGLE grab, no retry/
        -- put-back loop (that regressed it in the bank). On failure: /keypress esc (the REAL cancel; the
        -- Cancel button PULLS THE STACK) and stop short - never over-deliver.
        mq.cmdf('/itemnotify pack%d rightmouseup', bagNum)   -- open the bag so the split pops
        mq.delay(350)
        mq.cmdf('/itemnotify in pack%d %d leftmouseup', bagNum, slotNum)
        mq.delay(800, function() return mq.TLO.Window('QuantityWnd').Open() or (mq.TLO.Cursor.ID() or 0) > 0 end)
        if mq.TLO.Window('QuantityWnd').Open() then
            local wantS, set = tostring(want), false
            mq.cmdf('/invoke ${Window[QuantityWnd/QTYW_SliderInput].SetText[%d]}', want)
            local deadline, ticks = mq.gettime() + 1200, 0
            repeat
                if (mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text() or '') == wantS then set = true; break end
                mq.delay(40); ticks = ticks + 1
                if ticks % 8 == 0 then mq.cmdf('/invoke ${Window[QuantityWnd/QTYW_SliderInput].SetText[%d]}', want) end
            until mq.gettime() > deadline
            if not set then
                printf_log('Hand-off: could not set qty to %d for %s (reads %s) - cancelling (handed %d, no over-deliver).',
                    want, itemName, tostring(mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text()), placed)
                mq.cmd('/keypress esc'); mq.delay(300, function() return not mq.TLO.Window('QuantityWnd').Open() end)
                break
            end
            mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
            mq.delay(600, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
        end
        if (mq.TLO.Cursor.ID() or 0) == 0 then
            printf_log('Failed to pick up %s for %s.', itemName, peerName); break
        end
        local stackSize = mq.TLO.Cursor.Stack() or 1
        if stackSize > want then
            -- No split popped and we grabbed the whole slot - put it back rather than over-deliver.
            printf_log('Hand-off: grabbed %d of %s but wanted %d - putting back (handed %d, no over-deliver).',
                stackSize, itemName, want, placed)
            mq.cmd('/autoinventory'); mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
            break
        end
        mq.cmd('/notify TargetWindow Target_HP leftmouseup')   -- drop on target = open/fill trade
        mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
        if (mq.TLO.Cursor.ID() or 0) > 0 then
            mq.cmd('/click left target')
            mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
        end
        if (mq.TLO.Cursor.ID() or 0) > 0 then
            printf_log('Could not place %s on %s.', itemName, peerName)
            mq.cmd('/autoinventory'); break
        end
        placed = placed + stackSize
        slots = slots + 1
    end

    if placed == 0 then
        if mq.TLO.Window('TradeWnd').Open() then mq.cmd('/notify TradeWnd TRDW_Cancel_Button leftmouseup') end
        return 0
    end
    printf_log('Handing %d %s to %s - confirming trade...', placed, itemName, peerName)
    mq.delay(300)
    mq.cmd('/notify TradeWnd TRDW_Trade_Button leftmouseup')
    mq.delay(8000, function() return not mq.TLO.Window('TradeWnd').Open() end)
    if mq.TLO.Window('TradeWnd').Open() then
        mq.cmd('/notify TradeWnd TRDW_Trade_Button leftmouseup')   -- retry if our click beat the receiver
        mq.delay(4000, function() return not mq.TLO.Window('TradeWnd').Open() end)
    end
    if mq.TLO.Window('TradeWnd').Open() then
        printf_log('Trade with %s still open after confirm - cancelling.', peerName)
        mq.cmd('/notify TradeWnd TRDW_Cancel_Button leftmouseup'); return 0
    end
    printf_log('\\agHanded %d %s to %s.\\ax', placed, itemName, peerName)
    return placed
end

-- Navigate to whichever merchant NPC is physically closest in the zone,
-- regardless of name. Used for selling - any vendor will buy back goods,
-- so there's no reason to walk past a closer one to reach a specific name.
-- Vendors that don't buy items back - skip these when looking for a sell target
local VENDOR_IGNORE = {
    ['Perago Crotal'] = true,   -- PoK: don't sell here
    Kaeda = true,
    Quaser = true,
    Klorg = true,
    Zenma = true,
    Maxea = true,
    Vasha = true,
    Dusouc = true,
    Kriza = true,
    Ifer = true,
    Azibo = true,
    Elry = true,
    ['Adira Frozenhammer'] = true,
    ['Verix Klex'] = true,
    ['Wendell Lightforge'] = true,
    ['Weapons Master Zaknafein'] = true,
}

-- Forge/oven/station OPEN signal for world_open detection. On Lazarus the station
-- registers as TradeskillWnd (confirmed in-game: TSW=true when the forge is open).
-- Kept deliberately narrow -- folding in ContainerWindow/EnviroContainer/CCI caused
-- false positives (one reads Open() in an idle state), which made detection "succeed"
-- without the forge actually being open and broke the combine flow.
local function world_station_open()
    return mq.TLO.Window('TradeskillWnd').Open()
end

-- Windows that block the merchant window from opening: the station window and the
-- experimental combine window. Used ONLY to esc them before vending, so a false
-- positive here is harmless (just an extra esc) -- this is why it can check a wider
-- set than world_station_open() does.
local function combine_blocking_window_open()
    return mq.TLO.Window('TradeskillWnd').Open()
        or mq.TLO.Window('ContainerCombine_Items').Open()
end

-- Close the tradeskill combine windows, each via the method it ACTUALLY responds to:
--   * TradeskillWnd (the automated forge) only closes with DoClose() -- /keypress esc never
--     reaches it (confirmed in-game).
--   * ContainerCombine_Items (the experimental combine window) only closes with esc --
--     DoClose() leaves it in a blank/broken state (confirmed in-game).
-- Close the kit/combine window (ContainerCombine_Items) the SAME way open_kit opens it:
-- the OPEN_INV_BAGS toggle. Symmetric open/close, instead of esc-ing it shut. Because it's
-- a TOGGLE we press it exactly ONCE and verify -- looping it would just re-open the window.
-- esc stays as the fallback (still the proven clean close) for the rare case the toggle
-- doesn't take. Returns true once the window is shut.
state.close_kit_bags = function()
    if not mq.TLO.Window('ContainerCombine_Items').Open() then return true end
    mq.cmd('/keypress OPEN_INV_BAGS')
    mq.delay(500, function() return not mq.TLO.Window('ContainerCombine_Items').Open() end)
    mq.doevents()
    if not mq.TLO.Window('ContainerCombine_Items').Open() then return true end
    local tries = 0
    while mq.TLO.Window('ContainerCombine_Items').Open() and tries < 12 do
        mq.cmd('/keypress esc')
        mq.delay(300, function() return not mq.TLO.Window('ContainerCombine_Items').Open() end)
        mq.doevents()
        tries = tries + 1
    end
    return not mq.TLO.Window('ContainerCombine_Items').Open()
end

-- Bounded loop. Returns true if both are closed.
local function force_close_combine_windows()
    -- /cleanup closes ALL windows in one shot - bags, ContainerCombine_Items, AND the world
    -- TradeskillWnd (forge/oven/barrel) - and leaves the cursor untouched (confirmed in-game).
    -- It's the reliable way to shut a stuck world container; the old per-window closes below
    -- stay as a fallback in case anything lingers.
    mq.cmd('/cleanup')
    mq.delay(400)
    mq.doevents()
    if not combine_blocking_window_open() then return true end
    -- Fallback: ContainerCombine_Items closes the symmetric way we open it (OPEN_INV_BAGS
    -- toggle, esc inside close_kit_bags); TradeskillWnd only closes via DoClose.
    state.close_kit_bags()
    for _ = 1, 12 do
        if not mq.TLO.Window('TradeskillWnd').Open() then break end
        mq.TLO.Window('TradeskillWnd').DoClose()
        mq.delay(300)
        mq.doevents()
    end
    return not combine_blocking_window_open()
end

-- Close any open station/combine windows before vending. Returns true if everything closed,
-- false (with a warning) if something is still stuck open.
local function close_station_windows()
    if force_close_combine_windows() then return true end
    printf_log('WARNING: a station/combine window is stuck open before vending.')
    return false
end

local function nav_to_nearest_merchant()
    -- Always close any open world container before navigating to a vendor
    close_station_windows()
    -- Find nearest merchant that isn't on the ignore list
    local radius = 500
    local found_id, found_name
    for i = 1, 50 do
        local spawn = mq.TLO.NearestSpawn(string.format('%d, npc class merchant', i))
        local id = spawn.ID() or 0
        if id == 0 then break end
        local name = spawn.Name() or ''
        -- Strip server suffix (e.g. "Kaeda000" -> "Kaeda")
        -- Strip the server suffix (e.g. "Adira Frozenhammer000" -> "Adira Frozenhammer") but keep the
        -- FULL name, so multi-word vendors match the ignore list exactly (no first-word overreach).
        local baseName = trim((name:gsub('%d+$', '')))
        if not VENDOR_IGNORE[baseName] then
            found_id = id
            found_name = name
            break
        end
    end
    if not found_id then
        local spawn = mq.TLO.NearestSpawn('npc class merchant')
        found_id = spawn.ID() or 0
        found_name = spawn.Name() or 'merchant'
    end
    return nav_to_spawn(found_id, found_name), found_name
end

local function merchant_open() return mq.TLO.Window('MerchantWnd').Open() end

local function close_merchant()
    if merchant_open() then
        mq.TLO.Window('MerchantWnd').DoClose()
        delay(1500, function() return not merchant_open() end)
    end
end

local function close_world_container()
    force_close_combine_windows()
    -- Wait for the world station window to ACTUALLY report closed before returning. /cleanup closes it
    -- asynchronously; if we return while it's still mid-close, a following world_open sees TradeskillWnd
    -- still Open(), takes its "already open, reuse it" path, skips the re-click - and then the window
    -- finishes closing, leaving us thinking the container is open when it's shut ("Oven did not open").
    for _ = 1, 10 do
        if not mq.TLO.Window('TradeskillWnd').Open() then break end
        mq.delay(100)
        mq.doevents()
    end
    -- A world (forge/oven/barrel) combine just ran. Its experiment window is a
    -- ContainerCombine_Items that only closes via a focus-dependent esc, so force_close
    -- doesn't always land it. Flag the next kit-open to hard-reset before trusting
    -- kit_open() -- otherwise a surviving forge window gets mistaken for the kit and every
    -- following kit combine stages into the wrong window (the "stuck on forges" bug).
    state.combineWindowDirty = true
end

local function open_merchant(vendorName)
    -- Resolve the intended vendor's spawn id up front. The PoK Rasumus vendors (Maree/Eric/Nursa) - and
    -- other clustered merchants - stand stacked on the same spot, so opening by screen-click
    -- (/click right target) pops whichever BODY is in front, not the one we navigated to. Eric's list
    -- doesn't carry Maree's items, so the buy dead-ends forever ("not in the readable list" -> select "").
    -- Opening AND verifying by target id is stack-safe where the click is not. vid==0 (spawn momentarily
    -- out of range) => best-effort, skip verification rather than hard-fail.
    local vid = mq.TLO.Spawn(string.format('npc "%s"', vendorName)).ID() or 0

    -- The open merchant is OURS only when Merchant.ID matches the vendor we want (confirmed readable on Laz).
    local function open_is_vendor()
        if not merchant_open() then return false end
        if vid == 0 then return true end                       -- can't verify: trust whatever opened
        return (mq.TLO.Merchant.ID() or 0) == vid
    end

    -- Reuse an already-open window ONLY if it's this vendor; a leftover window from a stacked neighbour
    -- (or the previous trip) otherwise gets mistaken for ours and we buy off the wrong list.
    if open_is_vendor() then return true end
    if merchant_open() then close_merchant() end

    -- A leftover forge/oven/combine window blocks the merchant from opening -- this was the cause of the
    -- vendor hangs. Clear any station windows before trying.
    close_station_windows()

    for _ = 1, 4 do
        check_stop()
        -- (Re)assert the target by ID and CLOSE IN before opening. Being right on top of the vendor (vs
        -- ~10 out in a crowd) is what keeps the open from grabbing a stacked neighbour, and clears the
        -- plain "could not open merchant" misses on other vendors too.
        if vid > 0 then
            mq.cmdf('/target id %d', vid)
            delay(600, function() return (mq.TLO.Target.ID() or 0) == vid end)
            -- Get RIGHT on top of the vendor - the ~1.5 you land on with a manual /nav target. Stopping
            -- ~5-10 out in a stacked crowd is the real heart of the wrong-merchant bug: the open grabs
            -- whichever body is in front. Only a melee-range approach reliably lands the intended NPC.
            if (mq.TLO.Target.Distance() or 999) > 2 then
                mq.cmdf('/nav id %d distance=1', vid)
                delay(6000, function() return (mq.TLO.Target.Distance() or 999) <= 2 or not mq.TLO.Navigation.Active() end)
                mq.cmd('/nav stop')
                mq.cmd('/face fast')
            end
        end
        -- Open by target id (stack-safe). NO /click right target fallback - that screen-click is exactly
        -- what opened the wrong stacked NPC.
        mq.cmd('/invoke ${Merchant.OpenWindow}')
        delay(2500, function() return merchant_open() end)

        if open_is_vendor() then
            -- Open, THEN wait (briefly) for the list to populate before returning. Capped so a vendor whose
            -- count never populates doesn't stall us.
            delay(2500, function() return (mq.TLO.Merchant.Items() or 0) > 0 end)
            -- Turn OFF "Show only items I can use". Checked, it hides non-equippable tradeskill mats. It's a
            -- button (no writable state), so we read .Checked and click to uncheck ONLY when it's on.
            if mq.TLO.Window('MerchantWnd/MW_UsableButton').Checked() then
                printf_log('Merchant: unchecking "Show only items I can use" to reveal all items...')
                mq.cmd('/nomodkey /notify MerchantWnd MW_UsableButton leftmouseup')
                delay(2000, function() return not mq.TLO.Window('MerchantWnd/MW_UsableButton').Checked() end)
                delay(800)   -- let the list repopulate with the now-visible items
            end
            return true
        elseif merchant_open() then
            -- Opened the WRONG (neighbouring) merchant - close it and retry; the re-target by id above
            -- should land the right body next pass.
            printf_log('Opened the wrong merchant (id %s, wanted %s) - closing and retrying...',
                tostring(mq.TLO.Merchant.ID() or 0), vendorName)
            close_merchant()
        end
    end
    printf_log('WARNING: could not open merchant window for %s.', vendorName)
    return false
end

local function buy_item(name, qty)
    if qty <= 0 then return true end
    clear_cursor()   -- clear any straggler first: a held item (e.g. from a prior botched combine) blocks the buy pickup
    local target = item_count(name) + qty
    local list = mq.TLO.Window('MerchantWnd/MW_ItemList')
    -- Wait for the FULL merchant packet before deciding anything - the window widget lazy-renders
    -- and can cap well below the real item count (an 80-item vendor renders ~64 rows), so items far
    -- down the list read as '' and get falsely called "not sold". Merchant.ItemsReceived flips true
    -- only when every item has arrived.
    delay(6000, function() return mq.TLO.Merchant.ItemsReceived() end)

    local function row_count()
        return math.max(list.Items() or 0, mq.TLO.Merchant.Items() or 0)
    end
    -- Find by the Merchant TLO (full packet data), NOT the window widget. The widget under-renders;
    -- Merchant.Item[i] has every item the vendor sells. The index also drives list.Select for the buy,
    -- and selecting scrolls the row into view even if it wasn't rendered yet.
    local function find_row(itemName)
        local up = itemName:upper()
        -- Walk the WIDGET rows by DIRECT INDEX to a high fixed bound - do NOT trust list.Items() or
        -- Merchant.Items() as the bound. Both under-report on this server (an item proven to sit at
        -- row 52 was missed when the count read 80-and-change; Klaz rows read fine past 250). Rows past
        -- the real end return '' and don't match; a hit early-returns, so the fixed bound only ever
        -- adds coverage. This is the actual fix for the "80" ceiling.
        for i = 1, 1000 do
            if (list.List(i, 2)() or ''):upper() == up then return i end
        end
        -- Merchant TLO as a last-ditch secondary.
        local m = mq.TLO.Merchant.Items() or 0
        for i = 1, m do
            if (mq.TLO.Merchant.Item(i).Name() or ''):upper() == up then return i end
        end
        return 0
    end
    local row = find_row(name)
    if row == 0 then
        -- The WIDGET streams its rows in - its count (list.Items) climbs until the list is fully
        -- loaded, and on a big vendor it can sit at a partial count (e.g. 80) for a moment before the
        -- rest arrive. Do NOT trust Merchant.ItemsReceived here: it flips true while the widget is
        -- still filling, which made us walk a half-loaded list and miss the item. Instead re-walk until
        -- we find it OR the widget's row count holds STEADY (fully arrived).
        local hardDeadline = mq.gettime() + 15000
        local lastCount, countStable = -1, mq.gettime()
        while row == 0 and mq.gettime() < hardDeadline do
            delay(300)
            row = find_row(name)
            if row > 0 then break end
            local c = list.Items() or 0
            if c ~= lastCount then lastCount = c; countStable = mq.gettime() end
            -- Fully loaded = the widget's row count stopped growing for 2s. Only then is "not sold" real.
            if c > 0 and (mq.gettime() - countStable) > 2000 then break end
        end
    end
    if row == 0 then
        -- The list reader can under-report (some vendors expose only ~80 rows to the code even when
        -- they sell far more). We already KNOW this vendor sells the item - the merchant map routed us
        -- here on purpose - so a scan miss is a false negative, not proof it's unsold. Fall through and
        -- try the direct name lookup + buy instead of aborting.
        printf_log('%s not in the readable vendor list (%d rows) - trusting the map and trying by name...', name, row_count())
    end
    printf_log('Buying %dx %s...', qty, name)

    -- Select the item. Primary path: the row the walk found (reliable for the readable list). Fallback:
    -- the by-name SelectItem method for items too deep for the walk to see. Verify against BOTH the
    -- SelectedItem TLO and the window label (whichever the UI populates).
    local function selected_ok()
        return (mq.TLO.Merchant.SelectedItem.Name() or ''):upper() == name:upper()
            or (mq.TLO.Window('MerchantWnd/MW_SelectedItemLabel').Text() or ''):upper() == name:upper()
    end
    if row > 0 then
        list.Select(row)()
        delay(1500, selected_ok)
    end
    if not selected_ok() then
        mq.TLO.Merchant.SelectItem('=' .. name)()   -- docs: SelectItem method, '=' for exact match
        delay(1800, selected_ok)
    end
    if not selected_ok() then
        printf_log('WARNING: could not select %s to buy (selected "%s") - aborting this buy.',
            name, mq.TLO.Merchant.SelectedItem.Name() or mq.TLO.Window('MerchantWnd/MW_SelectedItemLabel').Text() or '')
        return false
    end

    -- Try to buy all at once via quantity window
    local remaining = target - item_count(name)
    while remaining > 0 do
        check_stop()
        -- Slot limit applies on every vendor run: once we hit the buy threshold,
        -- stop buying and return what we managed to get (success, not failure) so
        -- the caller goes to combine. Non-stacking items (e.g. molds) can't
        -- overflow the bags this way -- the combines burn them down and the next
        -- pass tops up. If we can't even make one combine, the caller's sanity
        -- check fails the craft out.
        if free_slots() <= BUY_THRESHOLD then
            printf_log('Hit %d free slots buying %s (%d on hand) - stopping to go combine.',
                BUY_THRESHOLD, name, item_count(name))
            return true
        end
        mq.cmd('/notify MerchantWnd MW_Buy_Button leftmouseup')
        delay(800, function() return mq.TLO.Window('QuantityWnd').Open() or item_count(name) >= target end)
        if mq.TLO.Window('QuantityWnd').Open() then
            -- Buy all remaining in one shot
            accept_qty_window(remaining)
            delay(2000, function() return item_count(name) >= target end)
            clear_cursor()
        else
            -- No quantity window - item bought one at a time (stackable with qty=1)
            delay(500, function() return item_count(name) > (target - remaining) end)
            clear_cursor()
        end
        local newRemaining = target - item_count(name)
        if newRemaining >= remaining then
            -- No progress
            printf_log('WARNING: still short %s (%d/%d).', name, item_count(name), target)
            return false
        end
        remaining = newRemaining
    end
    return true
end

-- Scans top-level bag packs (1-10) for the first slot containing an item
-- matching `name` (case-insensitive - EQ's displayed item/slot names can
-- differ in case from how the name is stored/typed elsewhere, e.g. ALL
-- CAPS in some UI labels). Returns bagNum, slotNum or nil, nil if not found.
local function find_item_slot(name)
    local upperName = name:upper()
    for bagNum = 1, 10 do
        local container = mq.TLO.Me.Inventory('pack' .. bagNum).Container() or 0
        if container > 0 then
            for slotNum = 1, container do
                local slotName = mq.TLO.Me.Inventory('pack' .. bagNum).Item(slotNum).Name()
                if slotName and slotName:upper() == upperName then
                    return bagNum, slotNum
                end
            end
        end
    end
    return nil, nil
end

-- Sells the entire stack of `name` in one shot, mirroring TurboLoot's
-- proven SellItem sequence: pick up the slot's contents to cursor
-- (accepting the QuantityWnd prompt that appears for stackable items -
-- this was the missed step before, since stacked items DO show that
-- prompt on pickup, unlike single items), confirm the merchant actually
-- registered the item as selected, shift-click Sell to sell the whole
-- stack, then verify by re-checking that SAME slot rather than
-- re-scanning by name (re-scanning can find a different slot mid-sale
-- and misread progress).
-- Items to NEVER sell, no matter which sell pass reaches them (between-recipes tree sell, terminal
-- sell, make-room sell). Bars are expensive intermediate stock you'd rather keep than vendor for
-- coppers. Matched case-insensitively on exact item name. Guard lives in sell_item_by_id so every
-- caller is covered from one place.
local SELL_NEVER = {
    ['platinum bar'] = true,
    ['velium bar']   = true,
}

-- Items never worth requesting from the group: cheap, stackable, sold by nearly every vendor, so a
-- trade round-trip costs more (time + a mule's bank trip) than just buying it. Matched case-insensitively.
local SUPPLY_IGNORE = {
    ['water flask'] = true,
}

local function sell_item_by_id(name)
    if not merchant_open() then return false end
    if name and SELL_NEVER[tostring(name):lower()] then
        printf_log('Keeping %dx %s (on the never-sell list).', item_count(name), name)
        return true
    end
    local have = item_count(name)
    if have <= 0 then return true end
    printf_log('Selling %dx %s...', have, name)

    local guard = 0
    local maxGuard = have + 5  -- enough iterations for all items plus buffer
    while item_count(name) > 0 and guard < maxGuard do
        guard = guard + 1
        check_stop()

        local bagNum, slotNum = find_item_slot(name)
        if not bagNum then
            printf_log('WARNING: could not locate %s in bags (have %d by count) - stopping.', name, item_count(name))
            break
        end

        if cursor_id() > 0 then
            mq.cmd('/autoinventory')
            delay(500, function() return cursor_id() == 0 end)
        end

        mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', bagNum, slotNum)

        if mq.TLO.Window('QuantityWnd').Open() then
            mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
            delay(500, function() return not mq.TLO.Window('QuantityWnd').Open() end)
        end

        delay(800, function()
            return (mq.TLO.Window('MerchantWnd/MW_SelectedItemLabel').Text() or ''):upper() == name:upper()
        end)
        local selectedText = mq.TLO.Window('MerchantWnd/MW_SelectedItemLabel').Text() or ''
        if selectedText:upper() ~= name:upper() then
            printf_log('WARNING: merchant did not register %s as selected (showed "%s") - skipping.', name, selectedText)
            clear_cursor()
            break
        end

        if not mq.TLO.Window('MerchantWnd/MW_Sell_Button').Enabled() then
            printf_log('WARNING: Sell button not enabled for %s - skipping.', name)
            clear_cursor()
            break
        end

        mq.cmd('/nomodkey /shift /notify MerchantWnd MW_Sell_Button leftmouseup')

        local upperName = name:upper()
        delay(800, function()
            local n = mq.TLO.Me.Inventory('pack' .. bagNum).Item(slotNum).Name()
            return not n or n:upper() ~= upperName
        end)

        local stillThere = mq.TLO.Me.Inventory('pack' .. bagNum).Item(slotNum).Name()
        if stillThere and stillThere:upper() == upperName then
            printf_log('WARNING: sell did not register for %s - stopping.', name)
            clear_cursor()
            break
        end
    end
    clear_cursor()
    return item_count(name) <= 0
end

-- ---------------------------------------------------------------------------
-- Tradeskill container helpers
-- Inventory containers: pack<kitPack> bag, ContainerCombine_Items window
-- World containers: barrel at NavLoc, TradeskillWnd + ContainerCombine_Items
-- ---------------------------------------------------------------------------

local function kit_open(cinfo)
    -- "Kit open" = slot 10's combine window (ContainerCombine_Items) is actually up. The
    -- combine itself is '/combine packN', which only works once this window is open (a closed
    -- window makes '/combine' report "cannot combine in this container type"). open_kit raises
    -- the window; '/combine' fills and fires it. The window's greyed Combine button is fine -
    -- we never click it.
    return mq.TLO.Window('ContainerCombine_Items').Open()
end

-- ===========================================================================
-- WORLD CONTAINER (Brewing Barrel etc.)
-- Clean, self-contained path. Never shares logic with inventory containers.
-- ===========================================================================

local function drain_cursor()
    -- A FAILED world combine hands the ENTIRE ingredient set back as a queue on the
    -- cursor (8 items for a Misty Thicket Picnic). The old loop blitzed /autoinventory
    -- through that queue at 150ms with no pacing, outrunning the server and tripping the
    -- inventory desync -- which then left stale bag counts so the next stage grabbed whole
    -- stacks ("Grabbed a stack of 997..."). Pace between queued items the way clear_cursor
    -- does. A single item (the normal success case) still exits immediately when the
    -- cursor clears, so only the multi-item failed-combine queue pays the pacing cost.
    local attempts = 0
    while cursor_id() > 0 and attempts < 12 do
        attempts = attempts + 1
        mq.cmd('/autoinventory')
        mq.delay(600, function() return cursor_id() == 0 end)
        if desyncDetected then
            -- A desync surfaced. Do NOT wait 3s or retry here (that's the cascade) and do NOT
            -- clear the flag - leave it set and bail, so the world combine path can run the
            -- proper close -> autoinventory -> reopen recovery. (The kit path effectively
            -- never desyncs, so this just bails there too.)
            return false
        elseif cursor_id() > 0 then
            mq.delay(AUTOINV_PACE_MS)   -- more items still on the cursor: pace before the next /autoinventory
                                        -- so we don't blitz the queue and outrun the server (desync trigger)
        end
    end
    return cursor_id() == 0   -- caller can verify the cursor is truly empty before a pickup
end

local ZONE_MARR      = 'freeporttemple'
local ZONE_POK       = 'poknowledge'
local ZONE_JAGGEDPINE = 'jaggedpine'
local ZONE_THURGADIN = 'thurgadina'
local ZONE_FELWITHE = 'felwithea'   -- Northern Felwithe (fletching vendor)

-- Navigate to barrel, click it, enter experimental mode, open bags.
-- Tries all known station locations in order if one is in use by another player.
-- Returns true on success, false if all stations failed.
-- Map a station's config label to the in-game name of the clickable item that
-- /itemtarget grabs. Most match their label (Oven, Kiln, Brew Barrel, Pottery
-- Wheel); the blacksmithing station's clickable is named "Forge", and the
-- tailoring/loam station's is "Loom".
local WORLD_ITEM_OVERRIDE = {
    ['blacksmithing'] = 'Forge',
    ['loam']          = 'Loom',
    ['tailoring']     = 'Loom',
}
local function world_item_name(label)
    label = label or ''
    return WORLD_ITEM_OVERRIDE[label:lower()] or label
end

-- After name-targeting a station, confirm /itemtarget actually grabbed a matching
-- item before we click. Ground stations (forge, oven, kiln...) report an internal
-- ACTORDEF name (e.g. "IT10804_ACTORDEF") and ID 0, so we can match on NEITHER the
-- name nor the ID. /itemtarget already matched our station by its display name, so
-- any item target that's actually in click range is the one we want. The distance
-- gate also rejects a stale target left over from a previous location we tried.
local WORLD_CLICK_RANGE = 30
local function world_target_ok(expectedItem)
    if (mq.TLO.ItemTarget.Name() or '') == '' then return false end
    local dist = mq.TLO.ItemTarget.Distance()
    return dist ~= nil and dist <= WORLD_CLICK_RANGE
end

-- Forward declarations: world_open (below) calls these travel helpers, but they
-- are defined further down. Declaring them here makes world_open capture them as
-- upvalues; the definitions below assign into these (note: no 'local' there).
local travel_to_marr, travel_to_pok, travel_to_jaggedpine, travel_to_thurgadin, travel_to_felwithe

local function world_open(cinfo)
    drain_cursor()
    local baseExpectedItem = world_item_name(cinfo.name)   -- default target name; a location may override
    -- Close a lingering experiment window (ContainerCombine_Items with no TradeskillWnd) before opening
    -- this world station, or it gets mistaken for the container. Lead with /cleanup - it nukes the window
    -- (and a desynced state) in ONE shot; close_kit_bags (OPEN_INV_BAGS toggle, then esc) finishes any
    -- straggler. This mirrors the close path (force_close_combine_windows) so open/close are consistent,
    -- and avoids waddling through a dozen escs when /cleanup clears it immediately. /cleanup also closes
    -- bags, but staging reopens those anyway, so the cost is trivial vs. a flaky esc-only close. If a world
    -- station (TradeskillWnd) is already open, leave it alone - the reuse path below keeps using it.
    if not mq.TLO.Window('TradeskillWnd').Open() then
        if mq.TLO.Window('ContainerCombine_Items').Open() then
            mq.cmd('/cleanup')
            mq.delay(400, function() return not mq.TLO.Window('ContainerCombine_Items').Open() end)
            mq.doevents()
        end
        state.close_kit_bags()   -- finisher: esc-closes anything /cleanup left (desync-proof backstop)
    end
    mq.cmd('/target clear')
    mq.delay(200)

    -- Build the list of locations to try. Put the last-known-good location (navLoc) FIRST, then
    -- the rest - so a reopen after a desync retries the station that just WORKED instead of walking
    -- the whole list from the top again (which wastes time on far/stale locations and can loop).
    local toTry = {}
    local allStations = cinfo.allStations or {}
    if #allStations > 0 then
        if cinfo.navLoc then
            toTry[#toTry+1] = { loc = cinfo.navLoc, zone = cinfo.navZone, target = cinfo.navTarget }
            for _, st in ipairs(allStations) do
                if st.loc ~= cinfo.navLoc or st.zone ~= cinfo.navZone then
                    toTry[#toTry+1] = st
                end
            end
        else
            toTry = allStations
        end
    elseif cinfo.navLoc then
        toTry = {{ loc = cinfo.navLoc, zone = cinfo.navZone, target = cinfo.navTarget }}
    end

    -- Always prefer a station in the zone we're CURRENTLY in. The station list was
    -- ordered when the job first resolved (possibly from a different zone), so without
    -- this we'd trek back to that zone after every sell trip even when the zone we're
    -- standing in has its own station. Re-sort here so the current zone wins.
    if #toTry > 1 then
        local cz = current_zone()
        local here, elsewhere = {}, {}
        for _, st in ipairs(toTry) do
            if st.zone == cz then here[#here+1] = st else elsewhere[#elsewhere+1] = st end
        end
        if #here > 0 then
            local reordered = {}
            for _, st in ipairs(here)      do reordered[#reordered+1] = st end
            for _, st in ipairs(elsewhere) do reordered[#reordered+1] = st end
            toTry = reordered
        end
    end

    if #toTry == 0 then
        printf_log('ERROR: no station locations known for %s.', cinfo.name)
        return false
    end

    printf_log('%s: %d location(s) available.', cinfo.name, #toTry)

    for idx, station in ipairs(toTry) do
        -- This location may name a different world actor than the station's config name.
        local expectedItem = (station.target and station.target ~= '' and station.target) or baseExpectedItem
        -- Zone if needed
        if station.zone and current_zone() ~= station.zone then
            local z = station.zone
            if z == ZONE_MARR then
                if not travel_to_marr() then return false end
            elseif z == ZONE_POK then
                if not travel_to_pok() then return false end
            elseif z == ZONE_JAGGEDPINE then
                if not travel_to_jaggedpine() then return false end
            end
        end

        -- Navigate to this station
        if station.loc then
            if #toTry > 1 then
                printf_log('Trying %s (%d/%d)...', cinfo.name, idx, #toTry)
            else
                printf_log('Navigating to %s...', cinfo.name)
            end
            -- Come at the station from a nearby safe waypoint (if one applies) so the final
            -- approach doesn't path into the station's collision and wedge. Skip when we're
            -- already essentially at the station (a same-spot reopen) - no point walking off and
            -- back. No-op when no waypoint is near or we're already standing on it.
            do
                local qy, qx, qz = tostring(station.loc):match('([%-%.%d]+)%s+([%-%.%d]+)%s+([%-%.%d]+)')
                local atStation = qy and (((mq.TLO.Me.X() or 0) - tonumber(qx))^2
                                        + ((mq.TLO.Me.Y() or 0) - tonumber(qy))^2
                                        + ((mq.TLO.Me.Z() or 0) - tonumber(qz))^2)
                                       <= (WORLD_CLICK_RANGE * WORLD_CLICK_RANGE)
                if not atStation then
                    state.route_marr_ferry(station.loc, station.zone)
                    -- A station is never a merchant, so route_pok_ferry can only ferry us OUT of
                    -- the pocket. Always stage the station's own hub afterward (e.g. descend to the
                    -- forge hub) - this is the sell-return-to-forge wedge fix.
                    state.route_pok_ferry(nil, station.zone)
                    state.route_via_waypoint(station.loc, station.zone)
                end
            end
            state.pre_nav(true)   -- crafting here: shrink if needed
            mq.cmdf('/nav loc %s', station.loc)
            -- Make sure we actually ARRIVE before targeting. A /nav issued while the client
            -- is still settling (post-zone, post-window-close, after the dry-run) can be
            -- silently dropped; if Navigation never engages, the old code fell straight
            -- through and /itemtarget'd from wherever we stood -- "clicking before we get
            -- there", which burns the location. So: if we're not already in range, wait for
            -- nav to engage, re-issue once if it doesn't, then wait for arrival and settle.
            local sy, sx, sz = tostring(station.loc):match('([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)')
            local function at_loc()
                if not (sx and sy and sz) then return false end
                local dx = (mq.TLO.Me.X() or 0) - tonumber(sx)
                local dy = (mq.TLO.Me.Y() or 0) - tonumber(sy)
                local dz = (mq.TLO.Me.Z() or 0) - tonumber(sz)
                return (dx*dx + dy*dy + dz*dz) <= (WORLD_CLICK_RANGE * WORLD_CLICK_RANGE)
            end
            if not at_loc() then
                local engaged = false
                local startDeadline = mq.gettime() + 3000
                while mq.gettime() < startDeadline do
                    if mq.TLO.Navigation.Active() then engaged = true; break end
                    if at_loc() then break end
                    mq.delay(100)
                end
                if not engaged and not at_loc() then
                    mq.cmdf('/nav loc %s', station.loc)   -- re-issue a dropped nav
                    local retry = mq.gettime() + 3000
                    while mq.gettime() < retry do
                        if mq.TLO.Navigation.Active() then engaged = true; break end
                        if at_loc() then break end
                        mq.delay(100)
                    end
                end
                state.nav_stuck_reset()
                local deadline = mq.gettime() + 30000
                while mq.gettime() < deadline do
                    if not mq.TLO.Navigation.Active() then break end
                    state.nav_stuck_check('station')
                    mq.delay(100)
                end
                mq.delay(300)   -- settle at the station before targeting
            end
        end

        -- Try to OPEN this station, retrying the SAME station on a desync/unresponsive open
        -- instead of skipping to the next one. We only move on for a genuine "in use by
        -- another player" (stationInUse), or after exhausting these attempts - a transient
        -- desync shouldn't cost us a perfectly good station.
        local MAX_OPEN_ATTEMPTS = 3
        for attempt = 1, MAX_OPEN_ATTEMPTS do
            stationInUse = false
            mq.doevents()

            -- If the station window is already open (we just combined at this same forge, or
            -- a prior attempt opened it), DON'T click it again: a click TOGGLES the forge, so
            -- clicking an already-open one closes it and reads as "couldn't open". Reuse it.
            if world_station_open() then
                printf_log('%s already open - reusing it.', cinfo.name)
            else
                if attempt > 1 then
                    printf_log('%s did not open - retrying THIS station (%d/%d), not skipping...', cinfo.name, attempt, MAX_OPEN_ATTEMPTS)
                    drain_cursor()   -- clear any cursor mess a desync left behind
                    mq.delay(400)
                else
                    printf_log('Clicking %s...', cinfo.name)
                end
                mq.cmdf('/itemtarget "%s"', expectedItem)
                mq.delay(250)
                if world_target_ok(expectedItem) then
                    mq.cmd('/click left item')
                else
                    printf_log('No %s in reach here (nearest target: %s, dist %s).',
                        expectedItem, mq.TLO.ItemTarget.Name() or 'none', tostring(mq.TLO.ItemTarget.Distance() or 'n/a'))
                end
            end

            -- Poll for the station window (or an in-use message). Generous on the first try
            -- (a legit forge/oven can be slow, and re-clicking a mid-open one toggles it shut),
            -- then quick on retries - after a desync-cleared re-click a good open registers fast.
            -- Worst case across all attempts is ~5s, not the ~18s a flat wide poll would cost.
            local pollMs = (attempt == 1) and 3000 or 1000
            local deadline = mq.gettime() + pollMs
            while mq.gettime() < deadline do
                mq.doevents()
                if world_station_open() or stationInUse then break end
                mq.delay(50)
            end

            if world_station_open() then
                break   -- opened; the success block below takes over
            elseif stationInUse then
                stationInUse = false
                if world_station_open() then force_close_combine_windows() end
                if attempt < 2 then
                    -- "Someone else is using that" ALSO fires for a stale/desynced barrel with nobody
                    -- on it, so try the SAME station ONCE more (a phantom clears on a re-click). If it's
                    -- still in use, it's a real occupant - stop retrying and advance to the next station.
                    printf_log('%s: "in use" (attempt %d/%d) - one quick retry before moving on...', cinfo.name, attempt, MAX_OPEN_ATTEMPTS)
                    drain_cursor()
                    mq.delay(800)
                else
                    -- Still "in use" after every attempt: genuinely occupied - move to the next station.
                    printf_log('%s is in use by another player - trying next station...', cinfo.name)
                    if toTry[idx+1] then
                        cinfo.navLoc  = toTry[idx+1].loc
                        cinfo.navZone = toTry[idx+1].zone
                    end
                    if idx < #toTry then mq.delay(500) end
                    break   -- stop retrying this station; let the outer loop advance
                end
            elseif attempt == MAX_OPEN_ATTEMPTS then
                printf_log('WARNING: could not open %s at location %d after %d attempts - trying next...', cinfo.name, idx, MAX_OPEN_ATTEMPTS)
            end
            -- otherwise: didn't open and not in-use (desync/unresponsive) -> retry this same station
        end

        if world_station_open() then
            -- Update cinfo so subsequent calls know which station we're at
            cinfo.navLoc  = station.loc
            cinfo.navZone = station.zone
            -- Enter experimental mode. The Experiment button lives on TradeskillWnd,
            -- so only drive it when that's the station window (forge/oven). Stations
            -- that open ContainerWindow/EnviroContainer are already combine-ready.
            if mq.TLO.Window('TradeskillWnd').Open() then
                mq.cmd('/notify TradeskillWnd COMBW_ExperimentButton leftmouseup')
                mq.delay(300, function() return mq.TLO.Window('ContainerCombine_Items').Open() end)
            end
            mq.cmd('/keypress OPEN_INV_BAGS')
            mq.delay(200)
            printf_log('%s ready.', cinfo.name)
            desyncDetected = false; desyncLatch = false   -- container open => synced
            return true
        end
    end

    -- All regular stations in use. Before waiting, try escalating into an AFK mirror instance (Marr
    -- AFK, then PoK AFK) - a fresh copy with the same stations, usually free. On success, re-run the
    -- whole open from scratch: cinfo.allStations is untouched, and we're now standing in the mirror.
    if #toTry > 0 and state.try_next_afk_instance and state.try_next_afk_instance() then
        return world_open(cinfo)
    end

    -- All stations tried and failed — if it was due to in-use, wait and retry the whole loop once
    if #toTry > 0 then
        printf_log('All %s stations in use or unreachable - waiting 12s before one retry...', cinfo.name)
        mq.delay(12000)
        for idx, station in ipairs(toTry) do
            stationInUse = false
            mq.doevents()
            local expectedItem = (station.target and station.target ~= '' and station.target) or baseExpectedItem
            mq.cmdf('/itemtarget "%s"', expectedItem)
            mq.delay(250)
            if world_target_ok(expectedItem) then mq.cmd('/click left item') end
            local retryDeadline = mq.gettime() + 6000
            while mq.gettime() < retryDeadline do
                mq.doevents()
                if world_station_open() or stationInUse then break end
                mq.delay(50)
            end
            if not stationInUse and world_station_open() then
                cinfo.navLoc  = station.loc
                cinfo.navZone = station.zone
                if mq.TLO.Window('TradeskillWnd').Open() then
                    mq.cmd('/notify TradeskillWnd COMBW_ExperimentButton leftmouseup')
                    mq.delay(300, function() return mq.TLO.Window('ContainerCombine_Items').Open() end)
                end
                mq.cmd('/keypress OPEN_INV_BAGS')
                mq.delay(200)
                printf_log('%s ready.', cinfo.name)
                desyncDetected = false; desyncLatch = false   -- container open => synced
                return true
            end
            stationInUse = false
        end
    end

    printf_log('ERROR: all %s locations tried and failed.', cinfo.name)
    return false
end

-- Non-destructive read of an enviro slot, the world-container analog of
-- kit_slot_name. Verified in-game on Lazarus: InvSlot[enviroN].Item reads the
-- slot correctly (Me.Inventory[enviroN] returns null here, so don't use it). Lets
-- world_place confirm an item seated and world_clear confirm a slot emptied,
-- instead of inferring from the cursor (which a desync can fake).
local function world_slot_name(i)
    local n = mq.TLO.InvSlot('enviro' .. i).Item.Name()
    if not n or n == '' then return nil end
    return n
end

-- Place one ingredient into an enviro slot.
-- IMPORTANT: ctrl+click picks up ONE item to cursor, then plain /itemnotify
-- drops it into the enviro slot. No /nomodkey on the enviro placement.
-- Place a SINGLE item into a specific enviro slot, verifying every step. Precise per-item flow:
--   1. Make sure the cursor is empty (autoinventory anything on it first).
--   2. Pick up ONE of the item (ctrl-click a stack grabs one; force any qty window to 1).
--   3. Verify the cursor now holds exactly 1 of the RIGHT item - if not, autoinventory and retry.
--   4. Drop it into enviroN.
--   5. Verify the slot holds exactly that item - if not, autoinventory whatever's on the cursor and retry.
-- No drain_cursor() here (it bails/cascades on desync); we autoinventory directly and re-check, so a
-- leftover product from a prior combine can never end up dropped into a slot.
local function world_place(name, slot)
    wdbg('place %s -> enviro%d (bags=%d)', name, slot, item_count(name))
    for attempt = 1, 5 do
        mq.doevents()
        if stationInUse then return false end
        if item_count(name) <= 0 then return false end

        -- 1. Cursor empty before pickup. Autoinventory whatever's on it, verify, up to a few passes.
        if cursor_id() ~= 0 then
            for _ = 1, 6 do
                mq.cmd('/autoinventory')
                mq.delay(400, function() return cursor_id() == 0 end)
                if cursor_id() == 0 then break end
            end
            if cursor_id() ~= 0 then
                wdbg('cursor would not clear (holds %s) - retry attempt %d', mq.TLO.Cursor.Name() or '?', attempt)
                mq.delay(300)
                goto retry
            end
        end

        -- 2. Pick up ONE. Ctrl grabs a single from a stack; plain for a single item. Address by bag slot.
        do
            local fi = mq.TLO.FindItem('=' .. name)
            local iSlot  = fi.ItemSlot() or 0
            local iSlot2 = fi.ItemSlot2() or -1
            local ctrl = ((fi.Stack() or 1) > 1) and '/nomodkey /ctrlkey' or '/nomodkey'
            if iSlot >= 23 and iSlot2 >= 0 then
                mq.cmdf('%s /itemnotify in pack%d %d leftmouseup', ctrl, iSlot - 22, iSlot2 + 1)
            elseif iSlot >= 23 then
                mq.cmdf('%s /itemnotify pack%d leftmouseup', ctrl, iSlot - 22)
            else
                mq.cmdf('/nomodkey /ctrlkey /itemnotify "%s" leftmouseup', name)
            end
        end
        mq.delay(1000, function() return cursor_id() > 0 or mq.TLO.Window('QuantityWnd').Open() end)
        if mq.TLO.Window('QuantityWnd').Open() then accept_qty_window(1) end

        -- 3. Verify the cursor holds exactly 1 of the RIGHT item. Anything else -> put it back, retry.
        if cursor_id() == 0 then
            wdbg('pickup of %s did not land on cursor - retry %d', name, attempt)
            goto retry
        end
        local curName = mq.TLO.Cursor.Name() or ''
        local curStack = mq.TLO.Cursor.Stack() or 1
        if curName:upper() ~= name:upper() or curStack ~= 1 then
            wdbg('cursor holds %s x%d (wanted %s x1) - putting back, retry %d', curName, curStack, name, attempt)
            mq.cmd('/autoinventory')
            mq.delay(400, function() return cursor_id() == 0 end)
            goto retry
        end

        -- 4. Drop into the slot.
        delay(PLACE_PACE_MS)
        mq.cmdf('/nomodkey /itemnotify enviro%d leftmouseup', slot)
        mq.delay(800, function() return cursor_id() == 0 end)

        -- 5. Verify the slot holds our item and the cursor is empty. If wrong, clean up and retry.
        if cursor_id() == 0 then
            local placed = world_slot_name(slot)
            if placed and placed:upper() == name:upper() then
                wdbg('placed %s -> enviro%d: slot holds %s x%d (bags left=%d)',
                    name, slot, placed, mq.TLO.InvSlot('enviro' .. slot).Item.Stack() or 1, item_count(name))
                delay(PLACE_PACE_MS)
                return true
            end
            wdbg('after drop, enviro%d holds %s (wanted %s) - retry %d', slot, tostring(placed), name, attempt)
        end
        -- drop didn't take (cursor not empty, or wrong/short in slot): autoinventory cursor and retry
        if cursor_id() ~= 0 then
            mq.cmd('/autoinventory')
            mq.delay(400, function() return cursor_id() == 0 end)
        end
        ::retry::
    end
    printf_log('WARNING: could not place a single %s in enviro slot %d.', name, slot)
    return false
end

-- Pull everything out of enviro slots after a FAILED combine.
-- Never call this after a SUCCESS - product is on cursor, not in slots,
-- and picking up from a slot while holding something causes a swap.
local function world_clear(slotCount)
    drain_cursor()
    -- A desync makes a slot pickup silently no-op: the item stays in the slot but
    -- the client cursor reads empty, so an inference-based clear moved on and the
    -- next world_place dropped a same-type single on top, stacking it (1->2->3...).
    -- Mirror the forge's clear_kit: read the slot itself to decide when it's truly
    -- empty, and re-pull until it is, so staging can never drop onto a dirty slot.
    if desyncDetected then
        printf_log('Inventory desync detected - settling cursor...')
        desyncDetected = false
        state.settle_desync()
    end
    for i = 1, slotCount do
        for _ = 1, 6 do
            if not world_slot_name(i) then break end   -- slot verified empty
            wdbg('enviro slot %d held: %s x%d', i,
                world_slot_name(i), mq.TLO.InvSlot('enviro' .. i).Item.Stack() or 1)
            mq.cmdf('/itemnotify enviro%d leftmouseup', i)
            mq.delay(800, function() return cursor_id() > 0 or mq.TLO.Window('QuantityWnd').Open() end)
            accept_qty_window(nil)   -- a stacked slot can prompt for qty; take the whole stack
            drain_cursor()
            if desyncDetected then
                desyncDetected = false
                mq.delay(3000)
            end
            mq.delay(300, function() return not world_slot_name(i) end)   -- wait for the slot to read empty
        end
        if world_slot_name(i) then
            printf_log('WARNING: enviro slot %d still occupied after clearing attempts.', i)
        end
    end
end

-- Fire the combine, wait, then route the cursor results.
-- Returns (success, staged): staged is true only when a FAILED combine left a clean,
-- reusable ingredient set in the enviro slots, so the caller can skip re-placement.
local function world_combine_return(cinfo, rec, expectedName, before, slotCount)
    combineFlags.success = false
    combineFlags.fail = false
    combineFlags.lacked = false
    combineFlags.desync = false

    -- Desync recovery (the working model): the server gets confused by salvage sitting on the
    -- cursor while the container is still OPEN. So CLOSE the container first, THEN autoinventory
    -- the cursor (items land in bags and the stale view clears), THEN reopen. No 3s waits - those
    -- only cascade. Defined up here so the pre-combine gate below can use it too.
    local function resync()
        printf_log('Desync on %s - close, autoinventory cursor, reopen.', cinfo.name or 'container')
        -- /cleanup closes ALL open windows at once (the safe shut state) before we drain the
        -- cursor; it leaves the cursor alone, so the drain below still handles it. close_world_
        -- container() stays as a fallback in case the container window lingers. (Mirrors kit_resync.)
        mq.cmd('/cleanup')
        mq.delay(300)
        close_world_container()
        mq.delay(400)
        local t = 0
        while cursor_id() > 0 and t < 16 do
            t = t + 1
            mq.cmd('/autoinventory')
            mq.delay(500, function() return cursor_id() == 0 end)
            if cursor_id() > 0 then mq.delay(AUTOINV_PACE_MS) end   -- pace between items, don't blitz
        end
        if cursor_id() > 0 then
            printf_log('resync: cursor STILL holds %s x%d after autoinventory - server may still be out of sync.',
                mq.TLO.Cursor.Name() or '?', mq.TLO.Cursor.Stack() or 1)
        end
        desyncDetected = false   -- live flags consumed; combineFlags.desync stays set for the caller's log
        desyncLatch = false
        world_open(cinfo)
    end

    -- HARD GATE: never combine with anything on the cursor. Leftover salvage that didn't fully
    -- bag is exactly what carries into the next combine and desyncs it. Log what's stuck
    -- (diagnostic), bag it (paced), and if it STILL won't clear - server's out of sync - resync
    -- rather than craft on top of it.
    if cursor_id() > 0 then
        printf_log('DIRTY CURSOR before combine: %s x%d - clearing before we craft.',
            mq.TLO.Cursor.Name() or '?', mq.TLO.Cursor.Stack() or 1)
        drain_cursor()
        if cursor_id() > 0 then
            resync()
            return false, false
        end
    end

    -- Settle before firing. Each placement is confirmed client-side, but the LAST
    -- one can still be in flight to the server when we combine - so the server sees
    -- 7 of 8 ingredients, the combine fails, and items strand in the slots. Pause,
    -- then confirm every slot actually reads filled (waiting on any that don't) so we
    -- only ever combine a complete set. This is the "happening too fast" symptom.
    delay(COMBINE_SETTLE_MS)
    for i = 1, slotCount do
        if not world_slot_name(i) then
            delay(1500, function() return world_slot_name(i) ~= nil end)
        end
    end
    -- DIAGNOSTIC: dump every enviro slot's contents right before the combine. If a qty>1 ingredient
    -- (e.g. Slice of Jumjum Cake|2) stacked back into ONE slot instead of filling two, we'll see a gap
    -- here - the combine then fires on an incomplete set and times out ("failed - other"). Remove once
    -- the Misty Thicket Picnic alternating-failure cause is confirmed.
    if WDBG then
        local parts = {}
        for i = 1, slotCount do
            local nm = world_slot_name(i)
            parts[#parts + 1] = string.format('%d=%s', i, nm or 'EMPTY')
        end
        printf_log('enviro pre-combine [%s]: %s', tostring(expectedName), table.concat(parts, ', '))
    end
    mq.cmd('/combine enviro')
    local deadline = mq.gettime() + 8000
    while mq.gettime() < deadline do
        mq.doevents()
        if combineFlags.success or combineFlags.fail then break end
        if cursor_id() > 0 then break end
        if expectedName and item_count(expectedName) > before then break end
        mq.delay(100)
    end
    mq.doevents()
    mq.delay(200)  -- let the full result set land on the cursor

    wdbg('post-combine %s: fail=%s success=%s cursor=%s x%d', expectedName,
        tostring(combineFlags.fail), tostring(combineFlags.success),
        cursor_id() > 0 and (mq.TLO.Cursor.Name() or '?') or 'EMPTY',
        cursor_id() > 0 and (mq.TLO.Cursor.Stack() or 1) or 0)

    -- FAILURE (or desync) = no product appeared. A failed combine - including one the server
    -- flags as a desync - hands the ingredients back as MULTIPLE items queued on the cursor.
    -- THEORY UNDER TEST (per Jacob): the desync IS that dirty cursor, so don't route salvage back
    -- into the barrel (an action onto a still-dirty cursor). Clear the cursor COMPLETELY and
    -- deliberately first: autoinventory, wait 0.75s, check; repeat until empty. Then re-stage fresh.
    if not combineFlags.success and not (expectedName and item_count(expectedName) > before) then
        -- Empty the cursor one item at a time, slowly, checking after each: /autoinventory,
        -- wait 0.75s, look again. Salvage can be several items, so loop until the cursor reads
        -- empty (guarded). Log each pass so we can see exactly what salvage comes back. If it
        -- genuinely won't clear by bagging (server rejecting it), fall back to a close/reopen.
        local pass = 0
        while cursor_id() > 0 and pass < 20 do
            pass = pass + 1
            printf_log('Salvage pass %d: autoinventory %s x%d.', pass,
                mq.TLO.Cursor.Name() or '?', mq.TLO.Cursor.Stack() or 1)
            mq.cmd('/autoinventory')
            mq.delay(750)   -- was 1000; one notch down to a value already proven safe (AUTOINV_PACE_MS). Next step 500 if clean.
        end
        if cursor_id() > 0 then
            printf_log('Cursor STILL not clear after %d passes (%s x%d) - resyncing.', pass,
                mq.TLO.Cursor.Name() or '?', mq.TLO.Cursor.Stack() or 1)
            resync()
        end
        delay(COMBINE_PACE_MS)
        return false, false   -- cursor cleared (or resynced); caller re-stages fresh
    end

    -- Success: the product (and any returned tool) is on the CURSOR. Bag it before returning so the next
    -- stage starts with an empty cursor. (world_place also verifies an empty cursor before each pickup, so
    -- this is the first line of defense, not the only one.) Plain /autoinventory, looped for a multi-item
    -- product stack - not drain_cursor, which bails on a desync and could leave the product on the cursor.
    for _ = 1, 8 do
        if cursor_id() == 0 then break end
        mq.cmd('/autoinventory')
        mq.delay(400, function() return cursor_id() == 0 end)
    end
    local ok = item_count(expectedName) > before or combineFlags.success
    delay(COMBINE_PACE_MS)
    return ok, false
end

-- Stage a clean ingredient set into the (already open) world container, returning true
-- when a full set is seated. Adaptive resync: most stages are clean and pay nothing. But
-- if a desync surfaces DURING the stage -- the symptom that, left alone, makes us drop a
-- second set onto a stranded first and spiral -- we close and reopen the container to
-- force a fresh server view, then stage again. A plain combine failure (items returned,
-- slots truly empty) stages clean on the first try and never triggers a close/reopen.
local function world_stage(cinfo, rec, slotCount)
    for attempt = 1, 3 do
        desyncLatch = false   -- cleared only here, so it reflects THIS attempt (handlers reset desyncDetected, not this)
        stationInUse = false  -- ditto: set only if an occupant message fires while WE stage this attempt
        world_clear(slotCount)
        drain_cursor()
        local placedOk = true
        local slot = 1
        for _, ing in ipairs(rec.ingredients) do
            for _ = 1, ing.qty do
                if not world_place(ing.name, slot) then placedOk = false; break end
                slot = slot + 1
            end
            if not placedOk then break end
        end
        if placedOk and not desyncLatch then
            if WDBG then
                local map = {}
                for i = 1, slotCount do
                    local nm = world_slot_name(i)
                    local st = nm and (mq.TLO.InvSlot('enviro' .. i).Item.Stack() or 1) or 0
                    map[#map + 1] = string.format('%d:%s%s', i, nm or 'empty', (st > 1) and ('x' .. st) or '')
                end
                wdbg('staged slots -> %s', table.concat(map, ' '))
            end
            return true   -- clean set, no desync: combine away
        end

        -- A placement failed or a desync hit mid-stage, so the container view can't be
        -- trusted and re-staging in place risks stacking onto stranded items. Force a
        -- clean resync and try again. Only call it a desync if the real desync message
        -- actually fired - a stuck cursor or short placement is just a place retry.
        if stationInUse then
            -- Occupied WHILE staging: the "in use" message fired as we tried to seat items - another
            -- player is really on this one. Don't fight it by reopening the SAME station; jump to the
            -- next known location. Only reopen the same one (to wait it out) when there's no alternate.
            stationInUse = false
            local all, curIdx = cinfo.allStations or {}, 0
            for i, st in ipairs(all) do if st.loc == cinfo.navLoc then curIdx = i; break end end
            if curIdx > 0 and all[curIdx + 1] then
                cinfo.navLoc, cinfo.navZone = all[curIdx + 1].loc, all[curIdx + 1].zone
                printf_log('%s in use while staging - moving to the next station...', cinfo.name or 'container')
            else
                printf_log('%s in use while staging - no other location, reopening to wait it out...', cinfo.name or 'container')
            end
        elseif desyncLatch then
            printf_log('Desync during stage of %s - closing and reopening to resync (attempt %d)...',
                cinfo.name or 'container', attempt)
        else
            printf_log('Could not seat a clean set in %s - reopening to retry (attempt %d)...',
                cinfo.name or 'container', attempt)
        end
        close_world_container()
        if not world_open(cinfo) then return false end
    end
    printf_log('WARNING: could not get a clean stage of %s after resync attempts.', cinfo.name or 'container')
    return false
end

-- ===========================================================================
-- INVENTORY CONTAINER (Jeweler's Kit, Fletching Kit etc.)
-- ===========================================================================

local function kit_slot_name(kitPack, i)
    local n = mq.TLO.Me.Inventory('pack' .. kitPack).Item(i).Name()
    if not n or n == '' then return nil end
    return n
end

local function ensure_bags_open(kitPack)
    if not mq.TLO.Window('InventoryWindow').Open() then
        -- Open the inventory window via the NAMED binding INVENTORY, never the literal 'i' key.
        -- '/keypress i' only works if that char has 'i' bound to Inventory - a char that uses 'b' for
        -- bags and has 'i' unbound/rebound never opens the window, so the kit chain stalls and the run
        -- SPINS (this was the character-specific bug). INVENTORY is the client's built-in binding name
        -- (confirmed working in-game; note it's INVENTORY, not OPEN_INVENTORY, on this build) and it
        -- ignores the user's keymap. Fall back to 'i' only if the named binding somehow didn't take.
        mq.cmd('/keypress INVENTORY')
        delay(400, function() return mq.TLO.Window('InventoryWindow').Open() end)
        if not mq.TLO.Window('InventoryWindow').Open() then
            mq.cmd('/keypress i')
            delay(400, function() return mq.TLO.Window('InventoryWindow').Open() end)
        end
    end
end

local function open_kit(cinfo, kitPack)
    -- Raise slot 10's combine window so '/combine packN' (in combine_and_wait) has it to
    -- combine into - on a closed window '/combine' just errors "cannot combine in this
    -- container type". We open it only when it isn't already up; once open it stays up across
    -- combines (the '/combine' path doesn't slam it shut the way the old button-click did), so
    -- there's no per-combine reopen and no constant bag flicker.
    -- kit_open() only checks "is ANY ContainerCombine_Items open" -- it can't tell our kit's
    -- window from a leftover forge/oven experiment window (both are ContainerCombine_Items).
    -- So after a world combine we must hard-close any stale window AND force a fresh kit open,
    -- instead of trusting the reuse check below. This is the "stuck on forges" fix.
    local needFreshOpen = false
    if mq.TLO.Window('TradeskillWnd').Open() then
        -- Automated forge left open: DoClose for TradeskillWnd, esc for the experiment window.
        if force_close_combine_windows() then
            printf_log('Closed the forge window before opening %s.', cinfo.name or 'kit')
        else
            printf_log('WARNING: forge window still open - kit open may fail.')
        end
        needFreshOpen = true
        state.combineWindowDirty = false
    elseif state.combineWindowDirty then
        -- A world combine just ran with no forge window still up, but its experiment
        -- ContainerCombine_Items may have survived. Close it (OPEN_INV_BAGS toggle, esc
        -- fallback) so it can't be mistaken for our kit, then open the kit fresh below.
        state.close_kit_bags()
        needFreshOpen = true
        state.combineWindowDirty = false
    end
    if not needFreshOpen and kit_open(cinfo) then return true end
    clear_cursor()
    close_merchant()
    -- Check pack<kitPack> DIRECTLY rather than FindItem (which returns the first match - a
    -- stray duplicate kit in a lower slot would make us reject the one correctly seated in
    -- pack<kitPack>). If our pack holds the kit, we're good regardless of any extra copies.
    local inPack = mq.TLO.Me.Inventory('pack' .. kitPack).Name() or ''
    if inPack:lower() ~= (cinfo.name or ''):lower() then
        if mq.TLO.FindItem('=' .. cinfo.name).ID() then
            printf_log('ERROR: %s must be in pack%d (slot %d) - pack%d currently holds "%s".',
                cinfo.name, kitPack, 22 + kitPack, kitPack, inPack ~= '' and inPack or 'nothing')
        else
            printf_log('ERROR: %s not found in inventory.', cinfo.name)
        end
        return false
    end
    if not mq.TLO.Window('InventoryWindow').Open() then
        -- Named binding INVENTORY, not the literal 'i' key (keybind-independent - see ensure_bags_open;
        -- a char using 'b' for bags with 'i' unbound would otherwise stall/spin here).
        mq.cmd('/keypress INVENTORY')
        delay(500, function() return mq.TLO.Window('InventoryWindow').Open() end)
        if not mq.TLO.Window('InventoryWindow').Open() then
            mq.cmd('/keypress i')
            delay(500, function() return mq.TLO.Window('InventoryWindow').Open() end)
        end
    end
    -- Open slot 10's combine window. Primary opener is OPEN_INV_BAGS: it opens all bags
    -- including the kit's combine window, and is the reliable route (confirmed in-game -
    -- the literal 'b' key only works if that's the bound key, and a slot right-click opens
    -- the kit as a plain single-slot bag on some clients). If a kit instead opens
    -- TradeskillWnd (Combine/Experiment choice), click Experiment. Right-click is last-ditch.
    for _ = 1, 4 do
        if mq.TLO.Window('ContainerCombine_Items').Open() then return true end
        check_stop()
        mq.cmd('/keypress OPEN_INV_BAGS')
        delay(1000, function() return mq.TLO.Window('ContainerCombine_Items').Open()
            or mq.TLO.Window('TradeskillWnd').Open() end)
        if mq.TLO.Window('TradeskillWnd').Open() and not mq.TLO.Window('ContainerCombine_Items').Open() then
            mq.cmd('/nomodkey /notify TradeskillWnd COMBW_ExperimentButton leftmouseup')
            delay(1000, function() return mq.TLO.Window('ContainerCombine_Items').Open() end)
        end
        if mq.TLO.Window('ContainerCombine_Items').Open() then return true end
        mq.cmdf('/nomodkey /itemnotify pack%d rightmouseup', kitPack)
        delay(800, function() return mq.TLO.Window('ContainerCombine_Items').Open() end)
    end
    if mq.TLO.Window('ContainerCombine_Items').Open() then return true end
    printf_log('ERROR: could not open %s (pack%d). [cursor=%s, pack%d="%s" cap=%d, invWnd=%s]',
        cinfo.name, kitPack,
        (mq.TLO.Cursor.Name() or 'empty'), kitPack,
        (mq.TLO.Me.Inventory('pack' .. kitPack).Name() or '?'),
        (mq.TLO.Me.Inventory('pack' .. kitPack).Container() or 0),
        tostring(mq.TLO.Window('InventoryWindow').Open()))
    return false
end

-- Kit analog of the world container's resync(). When the kit goes stale (a desync left the
-- server's view of slot 10 out of sync - a ghost on the cursor, or a phantom stack the server
-- dropped into a slot), draining/re-staging while the combine window is still OPEN just churns;
-- the server stays confused and the desyncs cascade. Mirror the world fix that worked: CLOSE
-- the combine window first, THEN autoinventory the cursor (the ghost/salvage lands in bags and
-- the stale view clears with nothing open to fight), THEN reopen the kit fresh.
local function kit_resync(cinfo, kitPack)
    printf_log('Kit desync - close, autoinventory cursor, reopen.')
    state.dlog('kit_resync: enter. cursor=%s stack=%d', (mq.TLO.Cursor.Name() or '(empty)'), (mq.TLO.Cursor.Stack() or 0))
    -- /cleanup closes ALL open windows in one shot (bags, container, merchant, bank...) - the
    -- safe shut state we want before draining the cursor. It does NOT touch the cursor, so the
    -- drain below still handles that. If the ContainerCombine_Items window ever lingers after
    -- /cleanup, close it the symmetric way (OPEN_INV_BAGS toggle, esc fallback).
    mq.cmd('/cleanup')
    mq.delay(300, function() return not mq.TLO.Window('ContainerCombine_Items').Open() end)
    state.close_kit_bags()
    mq.delay(400)
    local t = 0
    while cursor_id() > 0 and t < 16 do
        t = t + 1
        mq.cmd('/autoinventory')   -- now the container is CLOSED, so this actually clears
        mq.delay(500, function() return cursor_id() == 0 end)
        if cursor_id() > 0 then mq.delay(AUTOINV_PACE_MS) end
    end
    if cursor_id() > 0 then
        printf_log('kit_resync: cursor STILL holds %s x%d after autoinventory - server may still be out of sync.',
            mq.TLO.Cursor.Name() or '?', mq.TLO.Cursor.Stack() or 1)
    end
    desyncDetected = false
    desyncLatch = false
    local ok = open_kit(cinfo, kitPack)
    state.dlog('kit_resync: done. reopened=%s cursor=%s', tostring(ok), (mq.TLO.Cursor.Name() or '(empty)'))
    return ok
end

local function clear_kit(cinfo, kitPack, slotCount)
    if not USE_CLEAR_KIT then return end
    if not kit_open(cinfo) then return end
    -- Smart: only pull if the kit actually has something staged (leftovers from a
    -- mid-craft stop or a failed combine). Skip the burst entirely when it's empty.
    local hasItems = false
    for i = 1, slotCount do
        if kit_slot_name(kitPack, i) then hasItems = true; break end
    end
    if not hasItems then return end
    ensure_bags_open(kitPack)
    for i = 1, slotCount do
        for attempt = 1, 3 do
            if not kit_slot_name(kitPack, i) then break end
            -- Make sure we grab onto an empty cursor (a leftover would top/swap).
            if cursor_id() > 0 then
                mq.cmd('/autoinventory')
                delay(600, function() return cursor_id() == 0 end)
            end
            -- Grab the WHOLE slot in one pickup. A plain (no-ctrl) pickup takes the entire
            -- stack - whether that's the single item we staged or a desync-merged 500 - so one
            -- /autoinventory then drops the whole lot into the first open bag slot in a single
            -- move. No per-item bleed, no stacked-drop settle: a clear that used to take ~20s on
            -- a merged stack now takes ~1s, and it's the same cheap path for a normal 1-item slot.
            mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', kitPack, i)
            delay(800, function() return cursor_id() > 0 or mq.TLO.Window('QuantityWnd').Open() end)
            accept_qty_window(nil)   -- if a qty window pops, accept the full stack
            if cursor_id() > 0 then
                mq.cmd('/autoinventory')
                delay(1000, function() return cursor_id() == 0 end)
            end
            delay(300, function() return not kit_slot_name(kitPack, i) end)
            -- Pace between pulls. The speed optimization above rips slots out back-to-back, but on a
            -- desync-MERGED kit that just cascades more desyncs (the server can't keep up with a burst
            -- of pulls). Mirror the settle resync()/kit_resync use between autoinventory pulls. Occasional
            -- path (only when the kit has leftovers), so the cost is fine; tune via the autoinvPace knob.
            delay(AUTOINV_PACE_MS)
        end
        if kit_slot_name(kitPack, i) then
            printf_log('WARNING: kit slot %d still occupied after clearing attempts.', i)
        end
    end
end

local function place_in_kit(name, kitPack, slot)
    if item_count(name) <= 0 then
        printf_log('WARNING: place_in_kit - no %s in inventory.', name)
        return false
    end
    ensure_bags_open(kitPack)
    local upperName = name:upper()
    printf_log('Placing %s into kit slot %d...', name, slot)
    for _ = 1, 4 do
        check_stop()
        clear_cursor()
        local bagBefore = item_count(name)
        local curBefore = mq.TLO.Cursor.Name() or '(empty)'
        mq.cmdf('/nomodkey /ctrlkey /itemnotify "%s" leftmouseup', name)
        delay(1200, function() return cursor_id() > 0 or mq.TLO.Window('QuantityWnd').Open() end)
        local qtyPopped = mq.TLO.Window('QuantityWnd').Open()
        accept_qty_window(1)
        state.dlog('pickup %s slot=%d: bagBefore=%d curBefore=%s -> cursorNow=%s stack=%d qtyWnd=%s',
            name, slot, bagBefore, curBefore,
            (mq.TLO.Cursor.Name() or '(empty)'), (mq.TLO.Cursor.Stack() or 0), tostring(qtyPopped))
        if cursor_id() > 0 then
            local curName = (mq.TLO.Cursor.Name() or ''):upper()
            local cstack = mq.TLO.Cursor.Stack() or 1
            if curName ~= upperName then
                -- GHOST: a desync left a copy of a recently-handled item on the cursor, and it
                -- surfaced after our empty-check passed. Placing it would seed the wrong item
                -- into this slot (and the re-stage then over-stacks). Drain it and retry from a
                -- clean cursor instead of ever dropping it.
                state.dlog('GHOST on cursor: wanted %s, holding %s stack=%d - draining, retrying.',
                    name, (mq.TLO.Cursor.Name() or '(empty)'), cstack)
                clear_cursor()
            elseif cstack > 1 then
                -- Never drop a whole stack into a kit slot. If the cursor somehow holds more
                -- than one (a stack-sized ghost), put it back and retry rather than over-filling.
                printf_log('Grabbed a stack of %d %s (wanted 1) - returning, retrying.', cstack, name)
                clear_cursor()
            else
                -- The cursor shows a single CLIENT-side, but the server can still be processing
                -- the pickup from the bag stack. Dropping before it catches up is what lets the
                -- server reconcile the whole bag stack into this slot (the 900-item merges). Pace
                -- here too, scaled by the place knob, so "slow placement" actually slows the
                -- pickup->drop gap and not just the gap between slots.
                delay(PLACE_PACE_MS)
                mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', kitPack, slot)
                delay(1200, function() return cursor_id() == 0 end)
                if cursor_id() == 0 then
                    -- If the drop landed on top of an item already in this slot, it's now a
                    -- stack. That over-stack desyncs the server (and the desync surfaces ~1s
                    -- later), so wait it out before staging the next slot - otherwise the
                    -- following placements read stale inventory and the errors cascade.
                    local slotStack = (mq.TLO.Me.Inventory('pack' .. kitPack).Item(slot).Stack()) or 1
                    state.dlog('placed %s -> slot=%d: slotStack=%d landed=%s cursorAfter=%s',
                        name, slot, slotStack, (kit_slot_name(kitPack, slot) or '(empty)'),
                        (mq.TLO.Cursor.Name() or '(empty)'))
                    if slotStack > 1 then
                        mq.delay(2000)
                    end
                    local placed = kit_slot_name(kitPack, slot)
                    if placed and placed:upper() == upperName then
                        delay(PLACE_PACE_MS)
                        return true
                    end
                end
            end
        end
        clear_cursor()
    end
    printf_log('WARNING: could not place %s in kit slot %d.', name, slot)
    return false
end

local function kit_capacity(kitPack)
    return mq.TLO.Me.Inventory('pack' .. kitPack).Container() or 0
end

local function first_free_kit_slot(kitPack)
    for i = 1, kit_capacity(kitPack) do
        if not kit_slot_name(kitPack, i) then return i end
    end
    return nil
end

-- Stage a recipe into the kit by placing ONLY what's missing, matching by COUNT
-- not slot position (EQ combines use every item in the container regardless of
-- which slot it's in). Anything already present is left exactly where it is:
--   * returned tools (the needle) - wherever the game dropped them back
--   * a failed combine - all ingredients still sit there, so nothing is replaced
-- We never get more items back than we put in, so a present item is always a
-- legitimate ingredient, never junk (cross-recipe junk is handled by clear_kit).
local function stage_kit(cinfo, rec, kitPack)
    if not kit_open(cinfo) then
        printf_log('stage_kit: kit did not open for %s - cannot stage.', cinfo and cinfo.name or '?')
        return false
    end
    ensure_bags_open(kitPack)
    -- Tally what's already in the kit, by item name.
    local present = {}
    for i = 1, kit_capacity(kitPack) do
        local nm = kit_slot_name(kitPack, i)
        if nm then
            nm = nm:upper()
            present[nm] = (present[nm] or 0) + 1
        end
    end
    -- Pre-combine check: the kit must hold ONLY what THIS recipe uses. A subcombine can leave a
    -- non-consumed tool behind - e.g. the Mithril Working Knife stays in the kit after a Mithril
    -- Fletchings subcombine (it's a |returned tool). That knife is NOT an ingredient of the parent
    -- (Mithril Champion Arrows), so without this we'd stage the parent's ingredients AROUND the
    -- leftover knife, the combine would report wrong contents, and the reactive clear/re-stage
    -- would burn an attempt. If anything present isn't needed here (a foreign item, or a surplus
    -- beyond the recipe's qty), clear the kit and stage a clean set. A returned tool that IS part
    -- of THIS recipe (Fletchings' own knife) matches need[] and is kept in place for reuse.
    local need = {}
    local hasReturned = false
    for _, ing in ipairs(rec.ingredients) do
        local k = ing.name:upper()
        need[k] = (need[k] or 0) + ing.qty
        if ing.returned then hasReturned = true end
    end
    -- Returned-tool recipes: stage a fresh full set. return_cursor_items now BAGS the tool instead
    -- of re-seating it into whatever kit slot happened to be free, so this loop places it back in
    -- its recipe position every time (Ingredient5 -> slot 5 for the gorget templates). That's the
    -- only arrangement observed to combine reliably: on Fine Leather Gorget Template, combine 1
    -- (fresh, recipe order) succeeded and every combine after it (needle re-seated into slot 1,
    -- consumables 2-5) failed non-fizzle, forever. This clear is the belt to that braces: if a
    -- combine ever leaves something behind, don't fill around it.
    if hasReturned and next(present) ~= nil then
        clear_kit(cinfo, kitPack, kit_capacity(kitPack))
        present = {}
    end
    for nm, cnt in pairs(present) do
        if cnt > (need[nm] or 0) then
            clear_kit(cinfo, kitPack, kit_capacity(kitPack))
            present = {}   -- kit emptied; everything gets placed fresh below
            break
        end
    end
    -- Placement order. Normally recipe order (summoned essence ends up last). The Dev toggle
    -- 'stage summoned first' flips MAKEABLE reagents to the front - an A/B test for whether the
    -- placement desyncs follow the summoned item or just the last slot filled.
    local order = rec.ingredients
    if state.stageSummonedFirst then
        local summoned, rest = {}, {}
        for _, ing in ipairs(rec.ingredients) do
            local mk = false
            for _, m in ipairs(MAKEABLE) do if m.item == ing.name then mk = true; break end end
            if mk then summoned[#summoned + 1] = ing else rest[#rest + 1] = ing end
        end
        order = {}
        for _, ing in ipairs(summoned) do order[#order + 1] = ing end
        for _, ing in ipairs(rest) do order[#order + 1] = ing end
    end
    -- Place only the shortfall for each ingredient.
    for _, ing in ipairs(order) do
        local key = ing.name:upper()
        local have = math.min(present[key] or 0, ing.qty)
        present[key] = (present[key] or 0) - have   -- consume matched count
        for _ = 1, (ing.qty - have) do
            local slot = first_free_kit_slot(kitPack)
            if not slot then
                printf_log('ERROR: no free kit slot for %s.', ing.name)
                return false
            end
            if not place_in_kit(ing.name, kitPack, slot) then
                printf_log('stage_kit: could not place %s (have %d) into slot %d.', ing.name, item_count(ing.name), slot)
                return false
            end
        end
    end
    return true
end

-- After a combine, ALL results land on the cursor (success or fail). Walk the
-- cursor queue: drop raw ingredients straight back into the kit (reused next
-- combine, no bag round-trip) and /autoinventory anything else (the product).
local function return_cursor_items(cinfo, rec, kitPack)
    local need = {}
    local isReturnedTool = {}
    for _, ing in ipairs(rec.ingredients) do
        need[ing.name:upper()] = (need[ing.name:upper()] or 0) + ing.qty
        if ing.returned then isReturnedTool[ing.name:upper()] = true end
    end
    local function kit_qty(nameUpper)
        local c = 0
        for i = 1, kit_capacity(kitPack) do
            local it = mq.TLO.Me.Inventory('pack' .. kitPack).Item(i)
            if (it.Name() or ''):upper() == nameUpper then c = c + (it.Stack() or 1) end
        end
        return c
    end
    local guard = 0
    while cursor_id() > 0 and guard < 40 do
        guard = guard + 1
        local cname = (mq.TLO.Cursor.Name() or ''):upper()
        local cstack = mq.TLO.Cursor.Stack() or 1
        local returned = false
        -- A raw ingredient the kit still needs -> drop it back into a free slot, but ONLY
        -- one at a time. A failed combine spits stackables (empty vials, flasks) back as a
        -- single merged stack on the cursor; dropping that whole stack into one slot
        -- over-stacks it, the game refuses to combine, and the clear/re-stage churn that
        -- follows desyncs inventory. Re-seat singles; send any returned STACK to bags and
        -- let stage_kit pull fresh singles from there.
        -- A RETURNED TOOL (sewing needle, smithy hammer, file) never gets re-seated here. It came
        -- back on the cursor, and first_free_kit_slot would drop it into whatever slot happens to be
        -- free - slot 1 one combine, slot 4 the next. That nondeterminism is the bug: the only
        -- arrangement observed to combine reliably is a fresh set placed in RECIPE order, with the
        -- tool in its own ingredient position (last, for the gorget templates). So bag it and let
        -- stage_kit pull it back out into the right slot.
        -- Salvage from a failed/fizzled combine NEVER goes back into the kit. Re-seating a returned
        -- item into a free kit slot (the old path here) is exactly what was desyncing us: the server's
        -- view of slot 10 goes stale and the next combine trips. So EVERYTHING off the cursor -
        -- returned tools, returned ingredients, stacks, and the product - is autoinventoried to bags,
        -- and stage_kit re-pulls a clean set in recipe order for the next attempt.
        if cstack == 1 and isReturnedTool[cname] then
            mq.cmd('/autoinventory')
            mq.delay(700, function() return cursor_id() == 0 or (mq.TLO.Cursor.Name() or ''):upper() ~= cname end)
            returned = true
        end
        if not returned then
            mq.cmd('/autoinventory')  -- product, returned ingredient, or a returned stack -> bags
            mq.delay(700, function() return cursor_id() == 0 or (mq.TLO.Cursor.Name() or ''):upper() ~= cname end)
        end
        if desyncDetected then
            -- Desync mid-return = the kit view is stale. Draining further with the window OPEN
            -- is what cascades (proven on world containers). Close, bag the cursor, reopen.
            desyncDetected = false
            kit_resync(cinfo, kitPack)
            break   -- cursor is bagged and the kit's reopened fresh; stage_kit re-pulls cleanly
        else
            mq.delay(PLACE_PACE_MS)
        end
    end
    if cursor_id() > 0 then clear_cursor() end  -- bag any stragglers
end

-- Pre-combine integrity: every staged kit slot should hold exactly one item, since
-- place_in_kit only ever drops one per slot. A failed combine can very rarely leave a
-- slot double-stacked (~1/300), which the game refuses to combine ("You may not have
-- any stacks of items in the container..."). The scan is just one Stack() read per
-- slot - a no-op on the clean path. On the rare hit we clear and re-stage: clear_kit
-- sends everything (surplus included) to bags, stage_kit re-places exactly the needed
-- count one-per-slot, so needed items go back and leftovers stay in bags.
local function ensure_no_overstack(cinfo, rec, kitPack)
    local over = false
    for i = 1, kit_capacity(kitPack) do
        local st = (mq.TLO.Me.Inventory('pack' .. kitPack).Item(i).Stack()) or 0
        if st > 1 then
            state.dlog('OVERSTACK at slot=%d: %s stack=%d', i,
                (kit_slot_name(kitPack, i) or '(empty)'), st)
            over = true; break
        end
    end
    if not over then return true end
    local slotCount = 0
    for _, ing in ipairs(rec.ingredients) do slotCount = slotCount + ing.qty end
    printf_log('Over-stacked item in container - clearing and re-staging a clean set.')
    -- An over-stack is usually a phantom the server dropped into a slot while its view was
    -- stale. Close/reopen first (like the world path) so clear_kit + stage_kit operate on a
    -- freshly-synced container view instead of fighting the stale one.
    kit_resync(cinfo, kitPack)
    clear_kit(cinfo, kitPack, slotCount)
    return stage_kit(cinfo, rec, kitPack)
end

local function combine_and_wait(cinfo, rec, kitPack, expectedName, before)
    if not kit_open(cinfo) then
        if (state._cwGateN or 0) < 3 then
            state._cwGateN = (state._cwGateN or 0) + 1
            printf_log('combine gate FAIL %s: kit_open() returned false (window not up).', tostring(expectedName))
        end
        return false
    end
    if not ensure_no_overstack(cinfo, rec, kitPack) then
        if (state._cwGateN or 0) < 3 then
            state._cwGateN = (state._cwGateN or 0) + 1
            printf_log('combine gate FAIL %s: ensure_no_overstack() returned false (overstack re-stage failed).', tostring(expectedName))
        end
        return false
    end
    combineFlags.success = false
    combineFlags.fail = false
    combineFlags.lacked = false
    combineFlags.wrongContainer = false
    -- Slot 10's combine window is already up (open_kit raised it), so a single '/combine packN'
    -- combines its contents. We never click the greyed Combine button - '/combine' is the lever.
    -- The kit_open() gate above guarantees the window is up, so '/combine' won't error out with
    -- "cannot combine in this container type".
    mq.cmdf('/combine pack%d', kitPack)
    local deadline = mq.gettime() + 8000
    while mq.gettime() < deadline do
        mq.doevents()
        if combineFlags.fail or combineFlags.success then break end
        if cursor_id() > 0 then break end
        if expectedName and item_count(expectedName) > before then break end
        mq.delay(100)
    end
    mq.doevents()
    mq.delay(200)  -- let the full result set land on the cursor
    return_cursor_items(cinfo, rec, kitPack)
    check_stop()
    delay(COMBINE_PACE_MS)
    if not expectedName then return combineFlags.success end
    if item_count(expectedName) > before then return true end
    -- Diagnostic: a persistent "combine failed" on a well-above-trivial recipe (Mithril Fletchings at
    -- skill 252, trivial 34) shouldn't happen. Log what we actually observed - but only the first few
    -- per recipe (so it's not 750 lines) - to reveal whether the combine fired at all vs. fired-but-
    -- detection-missed. Reset the counter when the expected item changes.
    if state._cwDiagFor ~= expectedName then state._cwDiagFor = expectedName; state._cwDiagN = 0 end
    state._cwDiagN = (state._cwDiagN or 0) + 1
    if state._cwDiagN <= 3 then
        printf_log('combine diag %s #%d: flags(succ=%s fail=%s lacked=%s wrong=%s) count %d->%d cursor=%s',
            expectedName, state._cwDiagN, tostring(combineFlags.success), tostring(combineFlags.fail),
            tostring(combineFlags.lacked), tostring(combineFlags.wrongContainer),
            before, item_count(expectedName), tostring(mq.TLO.Cursor.Name() or '(none)'))
    end
    return combineFlags.success and not combineFlags.fail
end


-- ---------------------------------------------------------------------------
-- Zone travel helpers
-- ---------------------------------------------------------------------------

function travel_to_pok()
    if current_zone() == ZONE_POK then return true end
    -- Klonopin (the PoK portal NPC) only exists in hub zones like Marr. If he isn't in
    -- our current zone (e.g. we're out in Felwithe after a buy run), Marr's Calling gets
    -- us to Marr first, which always has him. This makes PoK reachable from anywhere and
    -- is what lets the forge sub-parts route home: Felwithe -> Marr -> PoK -> forge.
    if (mq.TLO.Spawn('npc Klonopin').ID() or 0) == 0 then
        printf_log('Klonopin not in zone - routing through Temple of Marr first...')
        if not travel_to_marr() then return false end
    end
    printf_log('Travelling to Plane of Knowledge...')
    state.pre_nav()
    mq.cmd('/nav spawn Klonopin')
    -- Wait for nav to spin up before checking if it's finished
    mq.delay(2000, function() return mq.TLO.Navigation.Active() end)
    local deadline = mq.gettime() + 30000
    while mq.gettime() < deadline do
        check_stop()
        if not mq.TLO.Navigation.Active() then break end
        mq.delay(200)
    end
    mq.cmd('/nav stop')
    mq.delay(300)
    mq.cmd('/target Klonopin')
    mq.delay(500)
    mq.cmd('/say Poknowledge')
    mq.delay(8000, function() return current_zone() == ZONE_POK end)
    if current_zone() ~= ZONE_POK then
        printf_log('ERROR: failed to zone to PoK (still in %s).', current_zone())
        return false
    end
    printf_log('Arrived in Plane of Knowledge.')
    mq.delay(1000)
    return true
end

function travel_to_marr()
    if current_zone() == ZONE_MARR then return true end
    printf_log("Travelling to Temple of Marr via Marr's Calling...")
    -- Marr's Calling can fail to land (interrupted cast - usually because we're still
    -- moving from the previous leg). Stop first, then cast and verify the zone; retry a
    -- few times rather than stranding ourselves (e.g. in Thurgadin with no other way out).
    local maxAttempts = 4
    local aaName = "Marr's Calling"
    local aaExists = (mq.TLO.Me.AltAbility(aaName).ID() or 0) > 0
    for attempt = 1, maxAttempts do
        if current_zone() == ZONE_MARR then break end
        if attempt > 1 then
            printf_log("Marr's Calling didn't land (attempt %d/%d) - recasting...", attempt, maxAttempts)
        end
        -- 1) Fire only when genuinely stationary AND not already casting. Firing while still
        --    drifting from the last nav leg interrupts the cast; firing mid-cast gets the
        --    activation refused. Both fail silently, so wait out movement/casting first.
        mq.cmd('/nav stop')
        mq.delay(3000, function()
            return not mq.TLO.Me.Moving() and (mq.TLO.Me.Casting.ID() or 0) == 0
        end)
        -- Wait for the AA to be off cooldown first (logged, so the log shows if cooldown is
        -- the holdup). Guarded on the AA existing so a name typo can't hang us here.
        if aaExists and not mq.TLO.Me.AltAbilityReady(aaName)() then
            printf_log("Waiting for Marr's Calling to refresh...")
            mq.delay(180000, function() return mq.TLO.Me.AltAbilityReady(aaName)() end)
        end
        -- 2) Fire it ONCE, then leave the cast completely alone until it lands. The script
        --    re-firing /aa act mid-cast was re-activating the AA and interrupting its own cast
        --    every pass - you saw it land the instant the lua stopped and the re-fires stopped.
        --    So: no re-check, no early exit on cast state. Just wait for the zone. This returns
        --    the moment we land, and only falls through to another attempt if a full 25s passes
        --    with no zone - by which point any cast is long over, so the next fire can't cut one
        --    short. The diagnostic line records our state at fire time in case it still misses.
        printf_log("Marr's Calling: firing (moving=%s casting=%d ready=%s)",
            tostring(mq.TLO.Me.Moving()), (mq.TLO.Me.Casting.ID() or 0),
            tostring(mq.TLO.Me.AltAbilityReady(aaName)()))
        mq.cmd("/aa act marr's calling")
        mq.delay(25000, function() return current_zone() == ZONE_MARR end)
    end
    if current_zone() ~= ZONE_MARR then
        printf_log('ERROR: failed to zone to Temple of Marr after %d tries (still in %s).', maxAttempts, current_zone())
        return false
    end
    printf_log('Arrived in Temple of Marr.')
    mq.delay(1000)
    marr_unstick()   -- one-time hop to Soulbinder Tomas to clear the zone-in geometry
    return true
end

-- ─── AFK mirror instances ───────────────────────────────────────────────────
-- Marr and PoK each have an "afk" mirror instance - same zone shortname, same merchants and
-- stations - reached by /say enter to Lazy Lady Linda in the regular zone. When every regular
-- station is in use, we escalate into these mirrors to double our station pool. Because the mirror
-- keeps the SAME zone ID, current_zone() can't tell us we zoned; the "You have entered" message
-- (state.sawZoneIn) is the only real signal, so we key the confirmation off that.
state.afkTier = 0   -- 0 = regular only, 1 = entered Marr AFK, 2 = entered PoK AFK (reset each run)

state.enter_afk = function(zoneShort)
    -- Be in the regular zone first (no-op if we're already standing in that zone, regular or mirror).
    if current_zone() ~= zoneShort then
        if zoneShort == ZONE_MARR then
            if not travel_to_marr() then return false end
        elseif zoneShort == ZONE_POK then
            if not travel_to_pok() then return false end
        elseif zoneShort == state.ZONE_NEXUS then
            if not state.travel_to_nexus() then return false end
        else
            return false   -- no AFK mirror path for this zone (e.g. PoT)
        end
    end
    -- Marr's approach to Lady snags if navved head-on; route through a clean loc first (skips the
    -- soulbinder hop). PoK navs to her cleanly, so no waypoint there.
    if zoneShort == ZONE_MARR then
        state.nav_loc_wait('160.37 -128.98 6.31')
    end
    -- Reach Lazy Lady Linda.
    local lid = mq.TLO.Spawn('npc "Lazy Lady Linda"').ID() or 0
    if lid == 0 then
        printf_log('AFK: could not find Lazy Lady Linda in %s - staying put.', current_zone())
        return false
    end
    mq.cmdf('/target id %d', lid)
    mq.delay(300)
    if (mq.TLO.Target.Distance() or 999) > 15 then
        state.pre_nav()
        mq.cmdf('/nav id %d', lid)
        mq.delay(2000, function() return mq.TLO.Navigation.Active() end)
        local dl = mq.gettime() + 30000
        while mq.gettime() < dl do
            check_stop()
            if not mq.TLO.Navigation.Active() then break end
            if (mq.TLO.Target.Distance() or 999) <= 15 then break end
            mq.delay(150)
        end
        mq.cmd('/nav stop')
    end
    if (mq.TLO.Target.Distance() or 999) > 20 then
        printf_log('AFK: could not reach Lazy Lady Linda - staying put.')
        return false
    end
    -- Enter the mirror: /say enter, then wait for the loading screen / "You have entered" message.
    -- No zone-in message within the window means it didn't take (not at Lady, or already inside) -
    -- fall back gracefully rather than assuming we moved.
    state.sawZoneIn = false
    printf_log('Entering the AFK mirror of %s via Lazy Lady Linda...', zoneShort)
    mq.cmd('/say enter')
    local zdl = mq.gettime() + 30000
    while mq.gettime() < zdl do
        mq.doevents()
        if state.sawZoneIn then break end
        mq.delay(100)
    end
    if not state.sawZoneIn then
        printf_log('AFK: no zone-in after /say enter - could not confirm the mirror.')
        return false
    end
    mq.delay(2000)   -- settle after the loading screen
    -- The AFK mirror is the SAME zone layout as native Marr, so clear the fountain zone-in geometry
    -- the same way native arrival does - hop to Soulbinder Tomas. marr_unstick is gated on the Marr
    -- zone shortname, which the mirror shares, so it works here unchanged. PoK's mirror navs cleanly
    -- and needs no equivalent.
    if zoneShort == ZONE_MARR then
        marr_unstick()
    end
    printf_log('Entered the AFK mirror of %s - retrying stations there.', zoneShort)
    return true
end

-- We're in myZone but the holder isn't a spawn in OUR instance - and we can't tell whether WE are in the
-- live zone or its AFK mirror (they share a shortname). Resolve it deterministically: a PORT always lands
-- in LIVE, so hop OUT to a different hub then straight back to myZone (we're now in LIVE) and check. Still
-- missing => they must be in the AFK mirror, so hop there and check. Live-then-mirror is exhaustive - if
-- neither instance has them, the zone read was stale or they moved. spawnHere() is the caller's live
-- visibility check for the specific holder.
state.reach_same_zone_holder = function(myZone, spawnHere)
    local back = state.CROSS_ZONES[myZone]
    if not (back and back.travel) then return false end   -- can't port back here; nothing we can do
    -- anchor via a DIFFERENT hub (Marr, unless we ARE in Marr - then PoK)
    local anchor     = (myZone == ZONE_MARR) and travel_to_pok or travel_to_marr
    local anchorName = (myZone == ZONE_MARR) and 'PoK' or 'Marr'
    printf_log('  cannot tell live vs AFK - re-anchoring via %s to reach live %s...', anchorName, myZone)
    if not anchor() then printf_log('  could not reach %s to re-anchor.', anchorName); return false end
    if not back.travel() then printf_log('  could not port back into %s.', myZone); return false end
    -- porting back landed us in LIVE
    if spawnHere() then printf_log('  found in the LIVE instance of %s.', myZone); return true end
    -- not in live => the AFK mirror is the only other place they can be
    if back.afk and state.enter_afk(myZone) and spawnHere() then
        printf_log('  found in the AFK mirror of %s.', myZone); return true
    end
    return false
end

-- Escalate to the next AFK mirror when all regular stations are in use. Order: Marr AFK, then PoK
-- AFK. Advances the tier so we never re-enter the same mirror in a run; returns false when both are
-- spent (world_open then falls back to its wait-and-retry). Reset to tier 0 at the start of each run.
-- Leave an AFK mirror and land in the LIVE copy of the zone we're standing in. The mirror shares the
-- zone shortname, so a plain travel no-ops ("already there") - hop to the OTHER hub and come back:
-- leaving the zone entirely means the RETURN zones us into a fresh live instance. Self-guarding:
-- returns false if the hop can't complete, so the caller degrades gracefully.
state.rezone_to_live = function(zoneShort)
    if zoneShort == ZONE_MARR then
        if not travel_to_pok() then return false end   -- leaves the Marr mirror
        return travel_to_marr()                        -- returns into LIVE Marr
    elseif zoneShort == ZONE_POK then
        if not travel_to_marr() then return false end  -- leaves the PoK mirror
        return travel_to_pok()                         -- returns into LIVE PoK
    end
    return false
end

state.try_next_afk_instance = function()
    if state.afkTier < 1 then
        state.afkTier = 1
        printf_log('All regular stations in use - trying the Marr AFK mirror...')
        return state.enter_afk(ZONE_MARR)
    elseif state.afkTier < 2 then
        state.afkTier = 2
        printf_log('Marr AFK also full - trying the PoK AFK mirror...')
        return state.enter_afk(ZONE_POK)
    end
    return false
end

-- ── Ask-first cross-zone supply ──────────────────────────────────────────────
-- When a same-zone request comes up short, don't give up if the mats exist in the OTHER crafting hub.
-- Ask the whole network who has them (instant, no travel), and only if a holder is in a reachable hub
-- (Marr/PoK, live or AFK mirror) do we travel there to collect. Ask-first: travel is a confirmed action,
-- never a gamble. Scoped to the two crafting hubs on purpose - other zones are out of scope, ignored.
-- Returns qty received (0 if nothing reachable). Only called after same-zone already failed/short.
-- Zone shortnames for the PoK-stone destinations (on state to avoid new main-chunk locals; the file is
-- at Lua's 200-local ceiling). Nexus has an AFK mirror; PoT does not.
state.ZONE_NEXUS = 'nexus'
state.ZONE_POT   = 'potranquility'

-- Travel to a PoK-stone zone: get to PoK, target the stone by door name, nav to it, click it, wait for
-- the zone change. Modeled on travel_to_felwithe (the proven PoK-stone pattern). `approach` is the loc
-- near the stone (fallback if the door's own coords aren't handy); `doorName` is the clickable stone.
state.travel_via_pok_stone = function(destZone, doorName, approach, label)
    if current_zone() == destZone then return true end
    if not travel_to_pok() then return false end   -- routes through Marr if Klonopin isn't here
    printf_log('Travelling to %s: heading to the stone (%s)...', label, doorName)
    mq.cmdf('/doortarget %s', doorName)
    mq.delay(600, function() return (mq.TLO.DoorTarget.ID() or 0) > 0 end)
    -- Nav to the door's own coords if we have them, else the provided approach loc.
    local dy, dx, dz = mq.TLO.DoorTarget.Y(), mq.TLO.DoorTarget.X(), mq.TLO.DoorTarget.Z()
    if dy and dx and dz and (mq.TLO.DoorTarget.Distance() or 9999) > 18 then
        state.nav_loc_wait(string.format('%.2f %.2f %.2f', dy, dx, dz), 12)
        mq.cmdf('/doortarget %s', doorName)   -- re-target after moving
        mq.delay(300)
    elseif approach then
        state.nav_loc_wait(approach, 12)
        mq.cmdf('/doortarget %s', doorName)
        mq.delay(300)
    end
    if (mq.TLO.DoorTarget.ID() or 0) == 0 then
        printf_log('ERROR: could not target the %s stone (%s).', label, doorName)
        return false
    end
    printf_log('Clicking the %s stone...', label)
    mq.cmd('/click left door')
    mq.delay(15000, function() return current_zone() == destZone end)
    if current_zone() ~= destZone then
        printf_log('ERROR: %s stone click did not land us in %s (still %s).', label, destZone, current_zone())
        return false
    end
    printf_log('Arrived in %s.', label)
    mq.delay(1500)   -- let the zone + navmesh settle
    return true
end
-- Nexus: PoK stone POKTNPORT500 near 449.98 -74.21 -152.87 (loc is Y X Z).
state.travel_to_nexus = function()
    return state.travel_via_pok_stone(state.ZONE_NEXUS, 'POKTNPORT500', '449.98 -74.21 -152.87', 'Nexus')
end
-- Plane of Tranquility: PoK stone POKTPORT500 near -148.68 -322.23 -152.87.
state.travel_to_pot = function()
    return state.travel_via_pok_stone(state.ZONE_POT, 'POKTPORT500', '-148.68 -322.23 -152.87', 'Plane of Tranquility')
end

-- Reachable zones for cross-zone supply. Each entry: travel = how to get there; afk = has an AFK mirror
-- instance (so we try enter_afk if the holder isn't in the live instance). To ADD a zone: add an entry
-- here with its travel_to_* function and whether it has an AFK mirror. Nothing else needs to change.
-- NOTE on return trips: after collecting, the crafter STAYS in the destination zone. Fine for the hubs;
-- if you add far zones, consider whether it should return to where the craft started (it doesn't now).
state.CROSS_ZONES = {
    [ZONE_MARR]        = { travel = function() return travel_to_marr() end,      afk = true  },
    [ZONE_POK]         = { travel = function() return travel_to_pok()  end,      afk = true  },
    [state.ZONE_NEXUS] = { travel = function() return state.travel_to_nexus() end, afk = true  },
    [state.ZONE_POT]   = { travel = function() return state.travel_to_pot()   end, afk = false },
    -- Add more here as their AFK-mirror status is confirmed, e.g.:
    -- [ZONE_JAGGEDPINE] = { travel = function() return travel_to_jaggedpine() end, afk = false },
    -- [ZONE_THURGADIN]  = { travel = function() return travel_to_thurgadin()  end, afk = false },
    -- [ZONE_FELWITHE]   = { travel = function() return travel_to_felwithe()   end, afk = false },
}
state.try_cross_zone_supply = function(itemName, needed, recipient)
    if not state.crossZoneSupply then return 0 end
    local origin = current_zone()
    -- Only meaningful if we're currently in a reachable zone (we travel between them). We don't drag the
    -- crafter in from a non-listed zone.
    if not state.CROSS_ZONES[origin] then return 0 end

    -- 1) Get every peer's CURRENT zone listener-free (/dquery, live so never stale), filter to peers in a
    --    reachable zone (PoK/Marr/Nexus/PoT) other than ours. Both this and the item check below are
    --    listener-free - no character is touched just to answer a question. Only the bot we finally pull
    --    from gets its listener started (inside request_supply, after we travel).
    local myName = mq.TLO.Me.Name() or ''
    local allPeers = state.all_network_peers()
    if #allPeers == 0 then return 0 end
    local zones = state.query_peer_zones(allPeers)   -- { name = zone }, live + listener-free
    local peers, peerZone = {}, {}
    for _, p in ipairs(allPeers) do
        local z = zones[p]
        if z and state.CROSS_ZONES[z] and z ~= origin then
            peers[#peers + 1] = p
            peerZone[p] = z
        end
    end
    if #peers == 0 then
        printf_log('Cross-zone: no peer is in a reachable zone for %s - not asking anyone.', itemName)
        return 0
    end
    printf_log('Cross-zone: %d reachable peer(s) for %s: %s', #peers, itemName, table.concat(peers, ', '))
    -- 2) Ask those reachable peers how much they hold, via DanNet sweep (bags+bank), listener-free: no startup, no /ts_check broadcast, no gather window, and
    -- none of the cross-zone /ts_avail latency games - each /dquery round-trips and we read the peer's own
    -- result. Populates availHolders[itemName]={peer=qty}, keyed by the lowercase DanNet name (== peerZone).
    state.peer_item_counts(peers, { itemName })
    local holders = state.availHolders[itemName] or {}
    local best, bestZone, bestQty = nil, nil, 0
    for holder, qty in pairs(holders) do
        -- /ts_avail reports the holder as the listener's Me.Name() (proper case, "Belree"), but peerZone
        -- is keyed by DanNet names (lowercased, "belree"). Look up case-insensitively or the holder we
        -- just found gets rejected here and we wrongly print "no holder".
        local hz = peerZone[holder] or peerZone[tostring(holder):lower()]
        if holder ~= myName and holder ~= recipient and (qty or 0) > 0 and hz then
            printf_log('Cross-zone:   %s holds %s x%d, zone=[%s]', holder, itemName, qty, tostring(hz))
            if qty > bestQty then best, bestZone, bestQty = holder, hz, qty end
        end
    end
    if not best then
        printf_log('Cross-zone:   (no reachable peer holds %s)', itemName)
        return 0
    end
    printf_log('Cross-zone: %s has %d %s in %s - travelling there to collect.', best, bestQty, itemName, bestZone)

    -- 3) TRAVEL to that zone (live instance first), then re-request in the normal same-zone way. The
    --    same-zone spawn check inside request_supply validates the holder is actually reachable here.
    local cfg = state.CROSS_ZONES[bestZone]
    if not (cfg and cfg.travel and cfg.travel()) then
        printf_log('Cross-zone: could not travel to %s.', bestZone)
        return 0
    end
    -- clear the exhausted flag so the re-request actually runs (same-zone marked it exhausted)
    supplyExhausted[itemName] = nil
    -- Is the holder actually in THIS instance now? (spawn check = mirror-safety)
    local got = 0
    if (mq.TLO.Spawn(string.format('pc "%s"', best)).ID() or 0) > 0 then
        got = request_supply(itemName, needed, recipient)
    elseif cfg.afk then
        -- 4) Not in the live instance, and this zone HAS an AFK mirror - hop in and try there.
        printf_log('Cross-zone: %s not in the live %s instance - trying the AFK mirror...', best, bestZone)
        if state.enter_afk(bestZone) and (mq.TLO.Spawn(string.format('pc "%s"', best)).ID() or 0) > 0 then
            supplyExhausted[itemName] = nil
            got = request_supply(itemName, needed, recipient)
        else
            printf_log('Cross-zone: %s not reachable in %s (live or AFK) - giving up on the trip.', best, bestZone)
        end
    else
        -- No AFK mirror for this zone; the holder just isn't in the live instance.
        printf_log('Cross-zone: %s not in %s (no AFK mirror to check) - giving up on the trip.', best, bestZone)
    end
    return got
end

-- BATCHED cross-zone supply. Given a LIST of {name, needed}, this does ONE reachable-network sweep
-- for the whole list, resolves each item to its best reachable holder, groups the shopping list by
-- ZONE then by HOLDER, and travels to each zone ONCE - pulling everything a holder has in a single
-- grouped delivery. This replaces the per-item escalation that traveled to a holder once PER ITEM
-- (PoK -> Marr -> PoK -> Marr for four items two bots held between them). Items nobody reachable holds
-- are simply left short here (the caller's buy pass / craft covers them). No decomposition itself -
-- the caller already flattened the tree into the item list; this just sources it without waste.
state.cross_zone_supply_grouped = function(items)
    if not state.crossZoneSupply or not items or #items == 0 then return end
    local origin = current_zone()
    if not state.CROSS_ZONES[origin] then return end   -- we only shuttle between reachable hubs

    -- 1) Reachable peers: in a CROSS_ZONES hub other than ours. Names come lowercased from DanNet.
    local myName = mq.TLO.Me.Name() or ''
    local allPeers = state.all_network_peers()
    if #allPeers == 0 then return end
    local zones = state.query_peer_zones(allPeers)
    local peers, peerZone = {}, {}
    for _, p in ipairs(allPeers) do
        local z = zones[p]
        if z and state.CROSS_ZONES[z] and z ~= origin then peers[#peers + 1] = p; peerZone[p] = z end
    end
    if #peers == 0 then
        printf_log('Cross-zone: no reachable peer in another hub for the %d short item(s).', #items)
        return
    end

    -- 2) ONE DanNet sweep for the WHOLE list, listener-free (bags+bank per peer, all in parallel).
    --    Replaces the listener startup + chunked /ts_check_multi + settle-gather, and sidesteps the
    --    cross-zone /ts_avail latency entirely (each /dquery round-trips; we read each peer's own result).
    local itemNames = {}
    for _, it in ipairs(items) do itemNames[#itemNames + 1] = it.name end
    state.peer_item_counts(peers, itemNames)

    -- 3) Best reachable holder per item -> group by zone -> holder (holder resolved to its LOWERCASE
    --    peer name so peer_zone/AFK-hop/peer_cmdf all match; the listener reports proper-case names).
    local byZone = {}   -- zone -> { canonHolder -> { {name,needed,mode} } }
    local found = false
    for _, it in ipairs(items) do
        local best, bestQty = nil, 0
        for holder, qty in pairs(state.availHolders[it.name] or {}) do
            local canon = tostring(holder):lower()
            if peerZone[canon] and (qty or 0) > bestQty then best, bestQty = canon, qty end
        end
        if best then
            found = true
            local hz = peerZone[best]
            byZone[hz] = byZone[hz] or {}
            byZone[hz][best] = byZone[hz][best] or {}
            table.insert(byZone[hz][best], { name = it.name, needed = it.needed, mode = 'stack' })
            printf_log('Cross-zone plan: %s <- %s  [%s x%d]', it.name, best, hz, bestQty)
        end
    end
    if not found then
        printf_log('Cross-zone: no reachable peer holds any of the %d short item(s).', #items)
        return
    end

    -- 4) One trip per zone; grouped delivery per holder (request_supply_grouped batches all a holder's
    --    items into one bank trip + trade, and does its own spawn-check + AFK-mirror hop).
    for zone, holders in pairs(byZone) do
        check_stop()
        local cfg = state.CROSS_ZONES[zone]
        local nHolders = 0; for _ in pairs(holders) do nHolders = nHolders + 1 end
        printf_log('Cross-zone: travelling to %s to collect from %d holder(s) in one trip.', zone, nHolders)
        if cfg and cfg.travel and cfg.travel() then
            for holder, holderItems in pairs(holders) do
                check_stop()
                for _, it in ipairs(holderItems) do supplyExhausted[it.name] = nil end
                state.request_supply_grouped(holderItems, holder)
            end
        else
            printf_log('Cross-zone: could not travel to %s - %d holder(s) skipped.', zone, nHolders)
        end
    end
end

function travel_to_jaggedpine()
    if current_zone() == ZONE_JAGGEDPINE then return true end

    -- Must be in Marr to use the Jaggedpine portal (Klonopin -> /say jaggedpine)
    if not travel_to_marr() then return false end
    printf_log('Travelling to Jaggedpine Treefolk...')
    state.pre_nav()
    mq.cmd('/nav spawn Klonopin')
    -- Wait for nav to spin up before checking if it's finished
    mq.delay(2000, function() return mq.TLO.Navigation.Active() end)
    local deadline = mq.gettime() + 30000
    while mq.gettime() < deadline do
        check_stop()
        if not mq.TLO.Navigation.Active() then break end
        mq.delay(200)
    end
    mq.cmd('/nav stop')
    mq.delay(300)
    mq.cmd('/target Klonopin')
    mq.delay(500)
    mq.cmd('/say jaggedpine')
    mq.delay(12000, function() return current_zone() == ZONE_JAGGEDPINE end)
    if current_zone() ~= ZONE_JAGGEDPINE then
        printf_log('ERROR: failed to zone to Jaggedpine (still in %s).', current_zone())
        return false
    end
    printf_log('Arrived in Jaggedpine Treefolk.')
    mq.delay(1000)
    return true
end

-- Nav to a loc and WAIT until we actually ARRIVE (within arriveDist of Y/X). Breaks
-- ONLY on arrival or the hard deadline -- never on a transient inactive blip, which
-- was cutting navs short and handing off to the north-run early. If nav genuinely
-- stalls (inactive and not there), it re-issues /nav, throttled to once every 3s.
-- Fire /nav and let it run the FULL mesh path to completion, then proceed. We do NOT
-- gate on arrival distance or re-issue (the staging spots sit just past the mesh edge by
-- design, so distance never closes and that just times out). Two things matter:
--  1. A single Navigation.Active==false read isn't enough -- the flag blinks false on
--     mesh seams/recomputes mid-path; we confirm it STAYS inactive before calling it done.
--  2. The deadline is only a true-hang guard, NOT the normal exit. It must be longer than
--     the longest real path (Great Divide is a big zone) or it cuts a valid nav short
--     mid-run. check_stop() lets the user abort manually, so a generous cap is safe.
-- arriveDist unused, kept for call-site compat.
local NAV_DONE_CONFIRM_MS = 1200
local NAV_HANG_GUARD_MS   = 120000   -- 2 min: only fires on a genuine hang, not normal runs
-- Nav to a loc and WAIT for arrival. Returns true only if we actually got there.
-- This used to `return true` unconditionally: if /nav loc couldn't path (spot off the nav mesh, bad
-- coords, out of bounds) Navigation.Active() never went true, the wait loop broke on its first pass,
-- and it reported success ~3s later without moving. That's how a character "fished" from the vendor:
-- go_to_spot thought it had arrived. Now a failed nav says so, and the caller can abort loudly.
local function nav_to_loc(y, x, z, arriveDist)
    local reach = arriveDist or 15
    local function dist()
        local ex = (mq.TLO.Me.X() or 0) - x
        local ey = (mq.TLO.Me.Y() or 0) - y
        local ez = (mq.TLO.Me.Z() or 0) - z
        return math.sqrt(ex * ex + ey * ey + ez * ez)
    end
    if dist() <= reach then return true end   -- already standing there

    -- After a zone-in the navmesh may not be loaded yet: /nav loc then does nothing, Navigation.Active
    -- never goes true, and we'd report "could not path" while standing 2500 units from the target
    -- (the Greater Faydark -> Felwithe zone-line run failed exactly this way). Wait for the mesh.
    -- MeshLoaded doesn't exist on every MQ build, so probe it defensively and just proceed if absent.
    do
        local haveTLO, loaded = pcall(function() return mq.TLO.Navigation.MeshLoaded() end)
        if haveTLO and loaded ~= nil then
            local mdl = mq.gettime() + 10000
            while mq.gettime() < mdl do
                local ok, v = pcall(function() return mq.TLO.Navigation.MeshLoaded() end)
                if ok and v then break end
                mq.delay(250)
            end
        end
    end

    state.pre_nav()
    mq.cmdf('/nav loc %.2f %.2f %.2f', y, x, z)
    mq.delay(5000, function() return mq.TLO.Navigation.Active() end)   -- let nav spin up (slow right after a zone)
    if not mq.TLO.Navigation.Active() and dist() > reach then
        mq.cmdf('/nav loc %.2f %.2f %.2f', y, x, z)   -- re-issue once; a nav can be dropped mid-run
        mq.delay(5000, function() return mq.TLO.Navigation.Active() end)
    end
    local effReach = reach
    if not mq.TLO.Navigation.Active() and dist() > reach then
        -- The exact point may be OFF the navmesh (a loc in water, inside geometry, out of bounds):
        -- nav then refuses outright rather than walking as close as it can. Ask it to stop short,
        -- which paths to the nearest reachable mesh point instead. Fishing only needs to be NEAR
        -- the water, so landing on the shore is the right answer - accept that wider radius.
        effReach = math.max(reach, 25) + 5
        mq.cmdf('/nav loc %.2f %.2f %.2f distance=%d', y, x, z, math.max(reach, 25))
        mq.delay(2000, function() return mq.TLO.Navigation.Active() end)
    end
    if not mq.TLO.Navigation.Active() and dist() > effReach then
        printf_log('\arNav could not path to %.2f %.2f %.2f (still %.0f away) - the spot may be off the nav mesh.\ax', y, x, z, dist())
        return false
    end

    local deadline = mq.gettime() + NAV_HANG_GUARD_MS
    while mq.gettime() < deadline do
        check_stop()
        if dist() <= effReach then break end
        if not mq.TLO.Navigation.Active() then
            mq.delay(NAV_DONE_CONFIRM_MS)                  -- transient pause? wait it out
            if not mq.TLO.Navigation.Active() then break end   -- still stopped: truly done
        end
        mq.delay(150)
    end
    mq.cmd('/nav stop')
    mq.delay(300)

    local d = dist()
    if d > effReach then
        printf_log('\arNav stopped %.0f from %.2f %.2f %.2f (wanted within %d) - did not arrive.\ax', d, y, x, z, effReach)
        return false
    end
    return true
end

-- Open a named door ONLY if it's closed. Toggling an already-open door would shut it,
-- so we read DoorTarget.Open first (confirmed reliable on PORT1414: FALSE closed /
-- TRUE open). Safe to call anywhere: no-ops unless the named door is targeted AND
-- within click range AND closed. DoorTarget is a separate TLO from the spawn target,
-- so this won't disturb any /target or /face already in progress.
-- Returns true if the door ended up open (or was already open), false otherwise.
local function ensure_door_open(name)
    mq.cmdf('/doortarget %s', name)
    mq.delay(150, function() return (mq.TLO.DoorTarget.ID() or 0) > 0 end)
    if (mq.TLO.DoorTarget.ID() or 0) == 0 then return false end          -- not targeted
    local dn = mq.TLO.DoorTarget.Name() or ''
    if not dn:find(name, 1, true) then return false end                   -- wrong door
    if (mq.TLO.DoorTarget.Distance() or 99999) > 25 then return false end -- too far to click
    if mq.TLO.DoorTarget.Open() then return true end                      -- already open: leave it
    mq.cmd('/click left door')
    mq.delay(500, function() return mq.TLO.DoorTarget.Open() end)
    return mq.TLO.DoorTarget.Open() or false
end

-- Thurgadin (velium vendor Talem Tucter) has no portal; the route is:
--   PoK -> click the Great Divide stone (door POKTGDPORT500) -> run north into
--   Thurgadin -> hand-walk the broken-mesh stretch to Guard Dagur.
-- Use a porter (Valium in PoK / Klonopin in Marr - same NPC, both offer the full port list) to reach
-- Thurgadin directly: nav to whichever porter is in the zone we're in and /say thurgadina. This skips
-- the whole Great Divide stone -> zone-line -> 20s off-mesh forward-run, which is fragile. If no porter
-- path works, fall back to the old stone route so we're never worse than before.
-- Thurgadin's nav mesh is broken across a bridge near the zone-in. Whether we arrived by porter or by
-- the Great Divide zone line, we land on the near side. /nav to the near edge (last spot the mesh
-- reaches), then cross by hand: face a fixed absolute heading and run straight to the far-edge mark,
-- where the mesh works again and the buy pass's nav_to(vendor) takes over. Shared by both arrival paths
-- - the porter used to skip this and strand us on the wrong side of the bridge.
local function thurgadin_cross_bridge()
    printf_log('Thurgadin: nav to bridge near edge, then heading-run across...')
    state.pre_nav(true)   -- shrink before the bridge: the near-edge geometry wedges a tall model
    nav_to_loc(-977, 5.70, 12.38, 15)

    local BRIDGE_HEADING = 0.80
    local farY, farX = -702.71, 5.21
    local function far_dist()
        local py, px = mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0
        return math.sqrt((py - farY)^2 + (px - farX)^2)
    end
    if far_dist() > 10 then
        mq.cmdf('/face fast heading %.2f', BRIDGE_HEADING)
        mq.delay(300)
        mq.cmd('/keypress forward hold')
        local hardCap = mq.gettime() + 45000   -- absolute safety cap; we bail earlier on sustained no-progress
        local lastDist = far_dist()
        local lastImprove = mq.gettime()   -- last time we actually gained ground
        local lastToggle  = mq.gettime()   -- last crouch/stand toggle
        local crouched = false
        while mq.gettime() < hardCap do
            check_stop()
            local d = far_dist()
            if d <= 10 then break end
            mq.cmdf('/face fast heading %.2f', BRIDGE_HEADING)   -- re-assert in case we drift
            if d < lastDist - 0.5 then
                lastDist = d
                lastImprove = mq.gettime()
                if crouched then mq.cmd(state.CROUCH_CMD); crouched = false end   -- unstuck: stand back up
            elseif (mq.gettime() - lastToggle) > 2000 then
                -- stuck 2s: toggle crouch. Crouching slips a height snag; if that didn't free us, standing
                -- back up on the next toggle might - alternate until we move (forward stays held).
                mq.cmd(state.CROUCH_CMD)
                crouched = not crouched
                lastToggle = mq.gettime()
                printf_log('Bridge: stuck - %s to slip the geometry...', crouched and 'crouching' or 'standing back up')
            end
            if (mq.gettime() - lastImprove) > 8000 then break end   -- genuinely wedged 8s despite toggling - give up
            mq.delay(150)
        end
        mq.cmd('/keypress forward')   -- release
        if crouched then mq.cmd(state.CROUCH_CMD) end   -- stand back up so mesh nav runs at full speed
        mq.delay(300)
    end
    if far_dist() > 15 then
        printf_log('WARNING: did not reach bridge far edge (%.1f away) - vendor nav may fail.', far_dist())
    else
        printf_log('Across the bridge (%.1f from mark) - mesh nav available.', far_dist())
    end

    printf_log('Navigating to Talem Tucter (velium vendor)...')
    if not nav_to('Talem Tucter') then
        printf_log('Note: could not auto-nav to Talem Tucter from here (buy pass will retry).')
    end
    return true
end

local function thurgadin_via_porter()
    local zone = current_zone()
    local porter
    if zone == ZONE_POK then porter = 'Valium'
    elseif zone == ZONE_MARR then porter = 'Klonopin' end
    if not porter then return false end   -- not in a porter zone; caller handles travel

    printf_log('Travelling to Thurgadin via %s (/say thurgadina)...', porter)
    state.pre_nav()   -- porter is in open PoK/Marr; the shrink happens on the Thurgadin side (bridge)
    mq.cmdf('/nav spawn %s', porter)
    mq.delay(2000, function() return mq.TLO.Navigation.Active() end)
    local deadline = mq.gettime() + 30000
    while mq.gettime() < deadline do
        check_stop()
        if not mq.TLO.Navigation.Active() then break end
        mq.delay(200)
    end
    mq.cmd('/nav stop'); mq.delay(300)
    mq.cmdf('/target %s', porter)
    mq.delay(500)
    mq.cmd('/say thurgadina')
    mq.delay(12000, function() return current_zone() == ZONE_THURGADIN end)
    return current_zone() == ZONE_THURGADIN
end

function travel_to_thurgadin()
    if current_zone() == ZONE_THURGADIN then return true end

    -- Porter first. Try the porter in whatever zone we're standing in; if we're in neither porter
    -- zone, hop to PoK (always reachable) and use Valium there.
    if current_zone() ~= ZONE_POK and current_zone() ~= ZONE_MARR then
        travel_to_pok()
    end
    if thurgadin_via_porter() then
        printf_log('Arrived in Thurgadin (via porter).')
        mq.delay(1000)
        return thurgadin_cross_bridge()
    end
    printf_log('Porter route did not land us in Thurgadin - falling back to the Great Divide stone.')

    -- Fallback: the Great Divide stone in PoK, then run the zone line.
    if not travel_to_pok() then return false end
    printf_log('Travelling to Thurgadin: heading to the Great Divide stone in PoK...')
    nav_to_loc(453, -231, -152, 15)
    mq.delay(300)

    printf_log('Clicking the Great Divide stone (door POKTGDPORT500)...')
    mq.cmd('/doortarget POKTGDPORT500')
    mq.delay(500)
    mq.cmd('/click left door')
    -- We don't need Great Divide's exact short name: leaving PoK == the click worked.
    mq.delay(15000, function() return current_zone() ~= ZONE_POK end)
    if current_zone() == ZONE_POK then
        printf_log('ERROR: stone click did not zone us out of PoK - check the loc/click method.')
        return false
    end
    printf_log('In %s - running to the Thurgadin zone line...', current_zone())
    mq.delay(1500)

    -- Nav to the spot just shy of the Thurgadin zone line (where the mesh ends).
    nav_to_loc(44.69, -146, 99.84, 15)

    -- Face the zone-line heading and run forward off-mesh until we zone into Thurgadin.
    local ZONEIN_HEADING = 354.98
    mq.cmdf('/face fast heading %.2f', ZONEIN_HEADING)
    mq.delay(400)
    mq.cmd('/keypress forward hold')
    local deadline = mq.gettime() + 20000
    while mq.gettime() < deadline do
        check_stop()
        if current_zone() == ZONE_THURGADIN then break end
        mq.cmdf('/face fast heading %.2f', ZONEIN_HEADING)   -- re-assert so we don't drift off-mesh
        mq.delay(200)
    end
    mq.cmd('/keypress forward')   -- release the held key
    mq.delay(1000, function() return current_zone() == ZONE_THURGADIN end)

    if current_zone() ~= ZONE_THURGADIN then
        printf_log('ERROR: failed to zone into Thurgadin (still in %s).', current_zone())
        return false
    end
    printf_log('Arrived in Thurgadin.')
    mq.delay(1000)
    return thurgadin_cross_bridge()
end

-- Northern Felwithe (fletching vendor) is reached via the Kelethin stone in PoK:
--   (Marr ->) PoK -> click the Kelethin stone (door POKKELPORT500) -> Greater Faydark
--   -> nav to the staging spot -> face 92.58 and run forward into Northern Felwithe.
-- Klonopin (the PoK portal NPC) only exists in hub zones like Marr, so if we're somewhere
-- without him, Marr's Calling gets us to Marr first, which has him.
function travel_to_felwithe()
    if current_zone() == ZONE_FELWITHE then return true end

    -- Get to PoK (travel_to_pok routes through Marr automatically if Klonopin isn't here).
    if not travel_to_pok() then return false end

    -- Target the Kelethin stone, nav to it using its own coords, then click it.
    printf_log('Travelling to Felwithe: heading to the Kelethin stone (POKKELPORT500)...')
    mq.cmd('/doortarget POKKELPORT500')
    mq.delay(600, function() return (mq.TLO.DoorTarget.ID() or 0) > 0 end)
    if (mq.TLO.DoorTarget.ID() or 0) == 0 then
        printf_log('ERROR: could not target the Kelethin stone (POKKELPORT500).')
        return false
    end
    local sy, sx, sz = mq.TLO.DoorTarget.Y(), mq.TLO.DoorTarget.X(), mq.TLO.DoorTarget.Z()
    if sy and sx and sz and (mq.TLO.DoorTarget.Distance() or 9999) > 18 then
        nav_to_loc(sy, sx, sz, 12)
        mq.cmd('/doortarget POKKELPORT500')   -- re-target after moving
        mq.delay(300)
    end
    printf_log('Clicking the Kelethin stone...')
    mq.cmd('/click left door')
    mq.delay(15000, function() return current_zone() ~= ZONE_POK end)
    if current_zone() == ZONE_POK then
        printf_log('ERROR: stone click did not zone us out of PoK - check the loc/click method.')
        return false
    end
    printf_log('In %s - running to the Felwithe zone line...', current_zone())
    mq.delay(3000)   -- let the zone (and its navmesh) settle before asking nav for anything

    -- Nav to the staging spot in Greater Faydark, then face the heading and run forward
    -- off-mesh until we zone into Northern Felwithe. If we never reached the staging spot the
    -- forward run is pointless (it's a 20s sprint, and the spot can be 2500+ units away) - say so
    -- instead of blind-running and then reporting the vaguer "failed to zone into Felwithe".
    if not nav_to_loc(-1935.80, -2590.65, 25.74, 15) then
        printf_log('\arERROR: could not reach the Greater Faydark staging spot - not blind-running to the zone line.\ax')
        return false
    end

    -- Forward runs toward the faced heading; 92.56 pointed exactly backwards down the
    -- line, so face the reciprocal (92.56 + 180) to run toward the Felwithe zone line.
    local FELWITHE_HEADING = 272.56
    mq.cmdf('/face fast heading %.2f', FELWITHE_HEADING)
    mq.delay(400)
    mq.cmd('/keypress forward hold')
    local deadline = mq.gettime() + 20000
    while mq.gettime() < deadline do
        check_stop()
        if current_zone() == ZONE_FELWITHE then break end
        mq.cmdf('/face fast heading %.2f', FELWITHE_HEADING)   -- re-assert so we don't drift
        mq.delay(200)
    end
    mq.cmd('/keypress forward')   -- release
    mq.delay(1000, function() return current_zone() == ZONE_FELWITHE end)

    if current_zone() ~= ZONE_FELWITHE then
        printf_log('ERROR: failed to zone into Northern Felwithe (still in %s).', current_zone())
        return false
    end
    printf_log('Arrived in Northern Felwithe - buy pass will nav to the fletching vendor.')
    mq.delay(1000)
    return true
end

-- West Freeport (one vendor lives here). PoK -> nav to the staging loc -> click the
-- Freeport stone (door POKFPTPORT500) -> West Freeport. Defined on `state` (not a local)
-- to avoid adding to the main-chunk local count. West Freeport's zone shortname is 'freportw'.
state.travel_to_freeport = function()
    if current_zone() == 'freportw' then return true end
    -- Get to PoK first (routes through Marr automatically if needed).
    if not travel_to_pok() then return false end
    printf_log('Travelling to West Freeport via the PoK Freeport stone (POKFPTPORT500)...')
    nav_to_loc(-451.35, -237.90, -149.85, 12)
    mq.cmd('/doortarget POKFPTPORT500')
    mq.delay(600, function() return (mq.TLO.DoorTarget.ID() or 0) > 0 end)
    if (mq.TLO.DoorTarget.ID() or 0) == 0 then
        printf_log('ERROR: could not target the Freeport stone (POKFPTPORT500).')
        return false
    end
    printf_log('Clicking the Freeport stone...')
    mq.cmd('/click left door')
    mq.delay(15000, function() return current_zone() ~= ZONE_POK end)
    if current_zone() == ZONE_POK then
        printf_log('ERROR: stone click did not zone us out of PoK - check the loc/click method.')
        return false
    end
    printf_log('Arrived in %s.', current_zone())
    mq.delay(1000)
    return true
end

-- North Freeport ('freportn') - has the Small Brick of High Quality Ore vendor (Kyrin Steelbone)
-- among others. There's no port here; the route is West Freeport, then walk across the zone line.
-- Reach West Freeport (via the PoK stone), nav to the spot just shy of the freportn zone line,
-- face the zone-in heading, and hold forward until we cross. Same walk-through pattern as Thurgadin.
state.travel_to_freportn = function()
    if current_zone() == 'freportn' then return true end
    -- Get to West Freeport first (reuses the PoK Freeport-stone route).
    if not state.travel_to_freeport() then return false end
    if current_zone() ~= 'freportw' then
        printf_log('ERROR: expected West Freeport, in %s - cannot reach North Freeport.', current_zone())
        return false
    end
    printf_log('In West Freeport - walking to the North Freeport zone line...')
    mq.delay(1000)

    -- Nav to the spot just shy of the freportn zone line (EQ /loc order: Y, X, Z).
    nav_to_loc(225.31, -129.91, -8.04, 12)

    -- Face the zone-in heading and run forward until we cross into North Freeport.
    local ZONEIN_HEADING = 350.97
    mq.cmdf('/face fast heading %.2f', ZONEIN_HEADING)
    mq.delay(400)
    mq.cmd('/keypress forward hold')
    local deadline = mq.gettime() + 20000
    while mq.gettime() < deadline do
        check_stop()
        if current_zone() == 'freportn' then break end
        mq.cmdf('/face fast heading %.2f', ZONEIN_HEADING)   -- re-assert so we don't drift
        mq.delay(200)
    end
    mq.cmd('/keypress forward')   -- release the held key
    mq.delay(1000, function() return current_zone() == 'freportn' end)

    if current_zone() ~= 'freportn' then
        printf_log('ERROR: failed to zone into North Freeport (still in %s).', current_zone())
        return false
    end
    printf_log('Arrived in North Freeport.')
    mq.delay(1000)
    return true
end

-- Abysmal Sea (one vendor: Uiyaniv Tu`Vrozix, sells King's Thorn). Klonopin in Temple of
-- Marr ports here when you say 'Abysmal' - same NPC/pattern as the PoK port, different
-- keyword. Get to Marr first, then nav to Klonopin and say it. On `state` to avoid a
-- main-chunk local. Abysmal Sea's zone shortname is 'abysmal'.
-- Hub porters: Valium in PoK, Klonopin in Marr - and they reach the SAME destinations. Use the
-- porter in whatever hub we're already standing in (saves a hop), and only fall back to the OTHER
-- hub's porter if the local one doesn't take this keyword or the port flakes. On `state`.
state.porter_hop = function(keyword, destZone)
    if current_zone() == destZone then return true end
    local function try_here()
        local cz = current_zone()
        local porter = (cz == ZONE_MARR) and 'Klonopin' or 'Valium'
        printf_log('Porting to %s: %s in %s (say %s)...', destZone, porter, (cz == ZONE_MARR) and 'Marr' or 'PoK', keyword)
        for attempt = 1, 3 do
            if nav_to(porter) then   -- walks all the way to the porter before saying it
                mq.cmd('/target ' .. porter); mq.delay(500)
                mq.cmd('/say ' .. keyword)
                mq.delay(10000, function() return current_zone() == destZone end)
                if current_zone() == destZone then return true end
            end
            if attempt < 3 then printf_log('%s port did not fire (attempt %d/3) - retrying...', destZone, attempt); mq.delay(1000) end
        end
        return false
    end
    -- Start from a hub. If we're in neither PoK nor Marr, PoK (Valium) is the default entry.
    if current_zone() ~= ZONE_POK and current_zone() ~= ZONE_MARR then
        if not travel_to_pok() then return false end
    end
    if try_here() then return true end
    -- Local porter didn't offer it (or flaked) - hop to the OTHER hub and try its porter.
    local other = (current_zone() == ZONE_MARR) and ZONE_POK or ZONE_MARR
    if other == ZONE_POK then
        if not travel_to_pok()  then return false end
    else
        if not travel_to_marr() then return false end
    end
    return try_here()
end

state.travel_to_abysmal = function()
    if current_zone() == 'abysmal' then return true end
    if not state.porter_hop('Abysmal', 'abysmal') then
        printf_log('ERROR: failed to zone to Abysmal Sea (still in %s).', current_zone())
        return false
    end
    printf_log('Arrived in Abysmal Sea.')
    mq.delay(1000)
    return true
end

-- Natimbi (GoD) is a two-hop translocator chain from Abysmal Sea: Magus Pellen -> Nedaria's
-- Landing (say Nedaria), then Magus Wnela -> Natimbi (say Natimbi). nav_to waits until we're
-- actually at each Magus before saying the keyword. Short-circuits if already down the chain.
-- On `state`. ASSUMES zone shortnames 'nedaria' and 'natimbi' - verify in-game.
state.travel_to_natimbi = function()
    if current_zone() == 'natimbi' then return true end
    -- Hop 1: reach Nedaria's Landing (via Abysmal + Magus Pellen), unless we're already there/past.
    if current_zone() ~= 'nedaria' then
        if not state.travel_to_abysmal() then return false end
        printf_log('Natimbi: Magus Pellen in Abysmal (say Nedaria)...')
        for attempt = 1, 3 do
            if nav_to('Magus Pellen') then
                mq.cmd('/target Magus Pellen'); mq.delay(500)
                mq.cmd('/say Nedaria')
                mq.delay(10000, function() return current_zone() == 'nedaria' end)
                if current_zone() == 'nedaria' then break end
            end
            if attempt < 3 then printf_log('Nedaria port did not fire (attempt %d/3) - retrying...', attempt); mq.delay(1000) end
        end
        if current_zone() ~= 'nedaria' then
            printf_log('ERROR: failed to zone to Nedaria (still in %s).', current_zone())
            return false
        end
        mq.delay(1000)
    end
    -- Hop 2: Nedaria's Landing -> Natimbi via Magus Wnela.
    printf_log('Natimbi: Magus Wenla in Nedaria (say Natimbi)...')
    for attempt = 1, 3 do
        if nav_to('Magus Wenla') then
            mq.cmd('/target Magus Wenla'); mq.delay(500)
            mq.cmd('/say Natimbi')
            mq.delay(10000, function() return current_zone() == 'natimbi' end)
            if current_zone() == 'natimbi' then break end
        end
        if attempt < 3 then printf_log('Natimbi port did not fire (attempt %d/3) - retrying...', attempt); mq.delay(1000) end
    end
    if current_zone() ~= 'natimbi' then
        printf_log('ERROR: failed to zone to Natimbi (still in %s).', current_zone())
        return false
    end
    printf_log('Arrived in Natimbi.')
    mq.delay(1000)
    return true
end

-- Hardcore Qeynos Hills instance: porter (say qrg) -> Surefall Glade, RUN through the zone line
-- into Qeynos Hills, nav to the 'rift' spawn, and /say enter 1 to load the instance. Ends inside
-- the instance; the fishing spot's loc then navs to the water. On `state`. ASSUMES zone shortnames
-- 'qrg' (Surefall Glade) and 'qeytoqrg' (Qeynos Hills) - verify in-game.
state.travel_to_hardcore_qeynos = function()
    -- 1) Port to Surefall Glade (unless we're already there or further along the chain).
    if current_zone() ~= 'qrg' and current_zone() ~= 'qeytoqrg' then
        if not state.porter_hop('qrg', 'qrg') then return false end
    end
    -- 2) Surefall Glade -> Qeynos Hills: run forward through the zone line (same pattern as Dagnor's).
    if current_zone() == 'qrg' then
        printf_log('Hardcore Qeynos: running from Surefall Glade to Qeynos Hills...')
        nav_to_loc(-602.44, 107.37, 3.12, 15)
        local H = 210.08
        mq.cmdf('/face fast heading %.2f', H); mq.delay(400)
        mq.cmd('/keypress forward hold')
        local d = mq.gettime() + 20000
        while mq.gettime() < d do
            check_stop()
            if current_zone() ~= 'qrg' then break end
            mq.cmdf('/face fast heading %.2f', H)   -- re-assert so we don't drift off-mesh
            mq.delay(200)
        end
        mq.cmd('/keypress forward')   -- release
        mq.delay(1000, function() return current_zone() ~= 'qrg' end)
        if current_zone() == 'qrg' then
            printf_log('ERROR: did not zone from Surefall Glade to Qeynos Hills.')
            return false
        end
    end
    -- 3) Qeynos Hills -> the Hardcore instance via the rift. The rift is NOT a targetable NPC, so
    -- nav to it and wait for the nav to FINISH (don't poll a spawn distance - that looped), then
    -- /say enter 1. The instance shares Qeynos Hills' shortname and this build exposes no instance id
    -- (Zone.Instance doesn't exist), so we can't detect the zone-in by identity - the /say reliably
    -- loads it, so we wait out the load and proceed to the fishing loc.
    printf_log('Hardcore Qeynos: navving to the rift...')
    mq.cmd('/nav spawn rift')
    mq.delay(2000, function() return mq.TLO.Navigation.Active() end)   -- let nav engage
    local d2 = mq.gettime() + 30000
    while mq.gettime() < d2 do
        check_stop()
        if not mq.TLO.Navigation.Active() then break end   -- nav done = we're at the rift
        mq.delay(200)
    end
    mq.cmd('/nav stop'); mq.delay(500)
    printf_log('Hardcore Qeynos: at the rift - entering (say enter 1)...')
    mq.cmd('/say enter 1')
    mq.delay(8000)   -- let the instance load, then proceed to the fishing loc
    printf_log('Hardcore Qeynos: proceeding into the instance to fish.')
    return true
end

-- Klonopin ports to the Gulf of Gunthak when you say 'gunthak' - same NPC/pattern as the
-- other ports, different keyword. Routed via PoK (where the fishing buy happens and where we
-- target Klonopin). Gulf of Gunthak's zone shortname is 'gunthak'. On `state` to avoid a
-- main-chunk local.
state.travel_to_gunthak = function()
    if current_zone() == 'gunthak' then return true end
    -- Reach PoK first, then say the keyword to Valium (the PoK porter; Klonopin is Marr's).
    if not travel_to_pok() then return false end
    printf_log('Travelling to Gulf of Gunthak: Valium in PoK (say gunthak)...')
    for attempt = 1, 3 do
        -- nav_to waits until we're actually next to Valium (within ~15) before returning, so we
        -- never say the keyword from across the zone - which silently no-ops the port.
        if nav_to('Valium') then
            mq.cmd('/target Valium')
            mq.delay(500)
            mq.cmd('/say gunthak')
            mq.delay(10000, function() return current_zone() == 'gunthak' end)
            if current_zone() == 'gunthak' then break end
        end
        if attempt < 3 then
            printf_log('Gunthak port did not fire (attempt %d/3) - re-navving to Valium and retrying...', attempt)
            mq.delay(1000)
        end
    end
    if current_zone() ~= 'gunthak' then
        printf_log('ERROR: failed to zone to Gulf of Gunthak (still in %s).', current_zone())
        return false
    end
    printf_log('Arrived in Gulf of Gunthak.')
    mq.delay(1000)
    return true
end

-- Dagnor's Cauldron (zone shortname 'cauldron'): reached by porting to Unrest (shortname
-- 'unrest') via Valium in PoK, then RUNNING through the zone line - same run-forward-off-mesh
-- pattern as travel_to_thurgadin. In Unrest we nav to the zone-line loc, face the heading, and
-- hold forward until we zone into Cauldron. On `state` to avoid a main-chunk local.
-- ASSUMES: Valium offers 'unrest', and the shortnames are 'unrest'/'cauldron' - verify in-game.
state.travel_to_dagnor = function()
    if current_zone() == 'cauldron' then return true end
    -- 1) Port to Unrest via Valium in PoK (skip if we're already in Unrest).
    if current_zone() ~= 'unrest' then
        if not travel_to_pok() then return false end
        printf_log("Travelling to Dagnor's Cauldron: Valium in PoK (say unrest)...")
        for attempt = 1, 3 do
            if nav_to('Valium') then   -- waits until we're actually at Valium before saying it
                mq.cmd('/target Valium'); mq.delay(500)
                mq.cmd('/say unrest')
                mq.delay(10000, function() return current_zone() == 'unrest' end)
                if current_zone() == 'unrest' then break end
            end
            if attempt < 3 then
                printf_log('Unrest port did not fire (attempt %d/3) - re-navving to Valium and retrying...', attempt)
                mq.delay(1000)
            end
        end
        if current_zone() ~= 'unrest' then
            printf_log('ERROR: failed to zone to Unrest (still in %s).', current_zone())
            return false
        end
        printf_log("In Unrest - running to the Dagnor's Cauldron zone line...")
        mq.delay(1000)
    end
    -- 2) Nav to the zone-line loc, face the heading, run forward until we zone into Cauldron.
    nav_to_loc(55.10, 328, 5.31, 15)
    local ZONEIN_HEADING = 355.86
    mq.cmdf('/face fast heading %.2f', ZONEIN_HEADING)
    mq.delay(400)
    mq.cmd('/keypress forward hold')
    local deadline = mq.gettime() + 20000
    while mq.gettime() < deadline do
        check_stop()
        if current_zone() == 'cauldron' then break end
        mq.cmdf('/face fast heading %.2f', ZONEIN_HEADING)   -- re-assert so we don't drift off-mesh
        mq.delay(200)
    end
    mq.cmd('/keypress forward')   -- release the held key
    mq.delay(1000, function() return current_zone() == 'cauldron' end)
    if current_zone() ~= 'cauldron' then
        printf_log("ERROR: failed to zone into Dagnor's Cauldron (still in %s).", current_zone())
        return false
    end
    printf_log("Arrived in Dagnor's Cauldron.")
    mq.delay(1000)
    return true
end

-- Firiona Vie: reached by clicking the FV stone in PoK (door POKFVPORT500) - same stone-click
-- pattern as the Great Divide/Thurgadin port, and it ports DIRECTLY to FV (no zone-line run).
-- On `state`. ASSUMES the FV zone shortname is 'firiona' (used only for the already-there guard;
-- the "did we leave PoK" success check doesn't depend on it) - verify and tell me if it differs.
state.travel_to_fv = function()
    if current_zone() == 'firiona' then return true end
    if not travel_to_pok() then return false end
    printf_log('Travelling to Firiona Vie: clicking the FV stone in PoK (POKFVPORT500)...')
    nav_to_loc(-363.81, -321.82, -150.07, 15)
    mq.delay(300)
    for attempt = 1, 3 do
        mq.cmd('/doortarget POKFVPORT500')
        mq.delay(500)
        mq.cmd('/click left door')
        mq.delay(15000, function() return current_zone() ~= ZONE_POK end)
        if current_zone() ~= ZONE_POK then break end
        if attempt < 3 then
            printf_log('FV stone click did not zone us (attempt %d/3) - retrying...', attempt)
            nav_to_loc(-363.81, -321.82, -150.07, 15)
            mq.delay(300)
        end
    end
    if current_zone() == ZONE_POK then
        printf_log('ERROR: FV stone click did not zone us out of PoK - check the loc/door.')
        return false
    end
    printf_log('Arrived in Firiona Vie (%s).', current_zone())
    mq.delay(1000)
    return true
end

-- North Karana (zone shortname 'northkarana'): a direct Valium port (say northkarana), same
-- pattern as Gunthak. Replaces Jaggedpine as the spot for the 8lb Fetid Bass trophy. On `state`.
-- ASSUMES Valium offers 'northkarana' and the shortname is 'northkarana' - verify in-game.
state.travel_to_northkarana = function()
    if current_zone() == 'northkarana' then return true end
    if not travel_to_pok() then return false end
    printf_log('Travelling to North Karana: Valium in PoK (say northkarana)...')
    for attempt = 1, 3 do
        if nav_to('Valium') then   -- waits until we're actually at Valium before saying it
            mq.cmd('/target Valium'); mq.delay(500)
            mq.cmd('/say northkarana')
            mq.delay(10000, function() return current_zone() == 'northkarana' end)
            if current_zone() == 'northkarana' then break end
        end
        if attempt < 3 then
            printf_log('North Karana port did not fire (attempt %d/3) - re-navving to Valium and retrying...', attempt)
            mq.delay(1000)
        end
    end
    if current_zone() ~= 'northkarana' then
        printf_log('ERROR: failed to zone to North Karana (still in %s).', current_zone())
        return false
    end
    printf_log('Arrived in North Karana.')
    mq.delay(1000)
    return true
end

-- Generic zone -> travel dispatcher. Maps a vendor's zone shortname to the proven
-- travel function so any flow (buy pass, kit buy) can "hop to where the vendor is"
-- instead of assuming we're already in the right zone. On `state` to avoid a
-- main-chunk local. Returns true if we're already in, or successfully reached, the zone.
state.travel_to_zone = function(zone)
    if not zone or zone == '' or zone == current_zone() then return true end
    if zone == ZONE_POK then return travel_to_pok()
    elseif zone == ZONE_MARR then return travel_to_marr()
    elseif zone == ZONE_JAGGEDPINE then return travel_to_jaggedpine()
    elseif zone == ZONE_THURGADIN then return travel_to_thurgadin()
    elseif zone == ZONE_FELWITHE then return travel_to_felwithe()
    elseif zone == 'freportw' then return state.travel_to_freeport()
    elseif zone == 'freportn' then return state.travel_to_freportn()
    elseif zone == 'abysmal' then return state.travel_to_abysmal()
    elseif zone == 'gunthak' then return state.travel_to_gunthak()
    elseif zone == 'cauldron' then return state.travel_to_dagnor()
    elseif zone == 'northkarana' then return state.travel_to_northkarana()
    end
    printf_log('No travel method for zone "%s" - cannot hop there.', zone)
    return false
end

-- "Buy manually" shopping list: when an item's only vendor is in a zone the buy pass can't auto-
-- travel to, we record item+vendor+zone here instead of dead-ending, so the user is told exactly
-- where to go. Accumulates across the session; cleared from the Craft tab.
state.manualBuys = state.manualBuys or {}
state.record_manual_buy = function(items, vendor, zone)
    for _, it in ipairs(items or {}) do
        local name = (type(it) == 'table' and it.name) or it
        local dup = false
        for _, e in ipairs(state.manualBuys) do
            if e.item == name and e.zone == zone then dup = true; break end
        end
        if not dup then state.manualBuys[#state.manualBuys + 1] = { item = name, vendor = vendor, zone = zone } end
        printf_log('Buy manually: %s from %s in %s (no auto-travel there).', name, vendor or '?', zone or '?')
    end
end
-- Group the manual-buy list by zone into printable lines (one trip per zone). Returns {} if empty.
state.manual_buys_report = function()
    local byZone = {}
    for _, e in ipairs(state.manualBuys or {}) do
        local z = e.zone or '?'
        byZone[z] = byZone[z] or {}
        byZone[z][#byZone[z] + 1] = string.format('%s (%s)', e.item, e.vendor or '?')
    end
    local lines = {}
    for z, items in pairs(byZone) do
        lines[#lines + 1] = string.format('  %s: %s', z, table.concat(items, ', '))
    end
    return lines
end

-- The mules stage in Temple of Marr, so make sure we're there before asking, then
-- request from the group. Centralizes the "go to where the mules are" step so every
-- supply caller gets it. Returns the number of items received (0 if none/failed).
local function ensure_supply(itemName, needed)
    if current_zone() ~= ZONE_MARR then
        printf_log('%s needed from mules - traveling to Temple of Marr...', itemName)
        if not travel_to_marr() then
            printf_log('ERROR: could not reach Temple of Marr - cannot request %s.', itemName)
            return 0
        end
    end
    return request_supply(itemName, needed)
end

-- ---------------------------------------------------------------------------
-- Shared buy pass: groups all needed ingredients by vendor, makes one
-- trip per distinct vendor. Per-ingredient vendor overrides (ing.vendor)
-- take priority over the skill-level defaultVendor. Ingredients with a
-- nil vendor (e.g. subcombine placeholders) are skipped with a warning.
-- Returns false if any ingredient couldn't be fully purchased.
-- ---------------------------------------------------------------------------
local function buy_pass(rec, quantity, defaultVendor)
    local vendorMap  = state.vendorMap  or {}
    local vendorZone = state.vendorZone or {}

    -- (close_station_windows moved below: only close the kit when we're ACTUALLY going to a vendor.
    -- Closing it here on every buy_pass - including the many no-op "already have everything" ones a
    -- subcombine-heavy craft fires - is what thrashed the bags open/closed on every combine.)

    -- Helper: pick the vendor for an item from its vendor list, following the stay/travel rule:
    -- prefer a vendor in the CURRENT zone (stay put, nearest by distance); else prefer Marr, then
    -- PoK, then any other reachable zone. Unreachable-zone vendors are dropped unless they're the
    -- only option.
    local function pick_vendor(itemName)
        local vendors = vendorMap[itemName]
        if not vendors or #vendors == 0 then
            -- Fall back to defaultVendor if provided (zone from scanned data if known)
            if defaultVendor and trim(defaultVendor) ~= '' then
                local dv = trim(defaultVendor)
                return { name = dv, zone = state.vendor_zone_for(dv) }   -- prefer this vendor's copy in the current zone
            end
            return nil
        end
        local curZone = current_zone()
        -- Only consider instances we can actually reach: the current zone, or a
        -- zone we have a travel method for (PoK / Marr / Jaggedpine). Instances in
        -- zones we can't get to (e.g. Talem Tucter in Thurgadin) are dropped here so
        -- we never pick one and then abort. They're kept only if they are the ONLY
        -- option, in which case the downstream error is the correct outcome.
        local function reachable(inst, allowThurg)
            local z = inst.zone or curZone
            if z == curZone then
                -- Current zone - but only if the vendor is actually SPAWNED right now. A server hiccup or
                -- an AFK/instance gap can leave an expected vendor missing (e.g. Redsa not up in an AFK
                -- Marr's); picking that ghost and then aborting the craft is the bug. A missing current-
                -- zone vendor is treated as unreachable so we fall through to the next vendor (or a zone).
                return (mq.TLO.Spawn(string.format('npc "%s"', inst.name)).ID() or 0) > 0
            end
            if z == ZONE_POK or z == ZONE_MARR or z == ZONE_JAGGEDPINE then
                return true
            end
            -- Thurgadin/Felwithe (off-mesh stone trips) and Freeport (PoK stone -> West Freeport, then
            -- walk the zone line into North Freeport) are longer routes, so only consider them when
            -- nothing in a primary zone sells the item (velium / fletching / Small Brick of HQ Ore).
            return allowThurg and (z == ZONE_THURGADIN or z == ZONE_FELWITHE
                or z == 'freportw' or z == 'freportn')
        end
        local pool = {}
        for _, inst in ipairs(vendors) do
            if reachable(inst, false) then pool[#pool + 1] = inst end
        end
        if #pool == 0 then
            for _, inst in ipairs(vendors) do
                if reachable(inst, true) then pool[#pool + 1] = inst end
            end
        end
        if #pool == 0 then pool = vendors end   -- nothing reachable: fall back, error downstream
        if #pool == 1 then return pool[1] end
        -- Preference (the "when to stay / where to go" rule): stay in the CURRENT zone if it
        -- sells the item; otherwise, when we must travel, prefer Marr, then PoK, then any other
        -- reachable zone. Within the current zone, pick the nearest by spawn distance.
        local function zone_rank(z)
            if z == curZone   then return 0 end   -- already here: stay
            if z == ZONE_MARR then return 1 end   -- must travel: Marr first
            if z == ZONE_POK  then return 2 end   -- then PoK
            return 3                              -- then any other reachable zone
        end
        local best, bestRank, bestDist = nil, math.huge, math.huge
        for _, inst in ipairs(pool) do
            local z = inst.zone or curZone
            local rank = zone_rank(z)
            local d = math.huge
            if z == curZone then
                local sp = mq.TLO.Spawn(string.format('npc "%s"', inst.name))
                d = sp.Distance() or 99999
            end
            if rank < bestRank or (rank == bestRank and d < bestDist) then
                bestRank, bestDist, best = rank, d, inst
            end
        end
        if not best then best = pool[1] end
        return best
    end

    -- At/below the buy threshold: STOP buying and go combine. We deliberately do
    -- NOT sell here -- stopping early is what keeps the bags from ever filling up,
    -- which keeps the 3-slot sell a rare fallback. Same behaviour as the mid-buy
    -- check below. (Returning false here would abort the whole craft.)
    if free_slots() <= BUY_THRESHOLD then
        printf_log('%d free slots - stopping buy pass, going to combine.', free_slots())
        return true
    end

    -- compute shortfalls per ingredient, picking closest vendor for each
    local needed = {}
    for _, ing in ipairs(rec.ingredients) do
        local v = pick_vendor(ing.name)
        if not v then
            printf_log('ERROR: no vendor found for "%s" - aborting. Run MerchantScanner or add to [Vendors] in tradeskills.ini.', ing.name)
            return false
        else
            -- absQty: buy an exact count regardless of `quantity` (e.g. a single
            -- vendor-sold returned tool like a needle). Otherwise scale by quantity.
            local need = ing.absQty or (ing.qty * quantity)
            local short = need - item_count(ing.name)
            if short > 0 then
                needed[ing.name] = { qty = short, vendor = v }
            end
        end
    end

    if not next(needed) then
        return true   -- nothing short: silent no-op (avoids the double 'skipping' noise across pre-buy + preflight)
    end

    -- We ARE going to a vendor now, so close any open tradeskill/combine window before we walk off.
    -- (Doing this here instead of at the top means a no-op buy_pass never touches the kit - no bag thrash.)
    close_station_windows()

    -- group by vendor INSTANCE (name+zone), preserving ini order (first-seen)
    local vendorOrder = {}
    local byVendor = {}    -- instKey -> { {name=item, qty=...}, ... }
    local instByKey = {}   -- instKey -> { name=, zone= }
    local function inst_key(inst) return inst.name .. '##' .. (inst.zone or '') end
    for _, ing in ipairs(rec.ingredients) do
        local entry = needed[ing.name]
        if entry then
            local inst = entry.vendor
            local key = inst_key(inst)
            if not byVendor[key] then
                byVendor[key] = {}
                instByKey[key] = inst
                vendorOrder[#vendorOrder + 1] = key
            end
            -- avoid adding the same ingredient twice if it appears in
            -- the recipe more than once (same name, same vendor)
            local already = false
            for _, existing in ipairs(byVendor[key]) do
                if existing.name == ing.name then already = true; break end
            end
            if not already then
                -- buylast = "non-stackable, buy last so it doesn't fill bags before stackables."
                -- Prefer the SCANNED stackability (a fact) over the manual flag (a hand-maintained
                -- guess): a non-stackable item is buylast, a stackable one isn't. Fall back to the
                -- manual flag only when the item hasn't been scanned yet (stack unknown).
                local info = (state.itemInfo or {})[ing.name]
                local isBuyLast
                if info ~= nil and info.stack ~= nil then
                    isBuyLast = not info.stack
                else
                    isBuyLast = ing.buylast or false
                end
                byVendor[key][#byVendor[key] + 1] = { name = ing.name, qty = entry.qty, buylast = isBuyLast }
            end
        end
    end

    -- BATCH NON-STACKABLES TO BAG SPACE. Each non-stackable unit eats a whole slot, so buying the full
    -- demand is impossible, and with 2+ non-stackables buying the first to "full" starves the others and
    -- deadlocks. Stackables buy at full (≈1 slot regardless of qty); non-stackables are capped to one
    -- bag-load: batch = usable_slots / (non-stackable units per SINGLE combine). The combine loop rebuys
    -- when a batch runs out, so the run completes in cycles. Per-combine qty comes from the REAL recipe
    -- (get_recipe), not ing.qty - callers pass ing.qty as either per-combine OR full demand, so it's not
    -- reliable here. Needs scanned stackability; unknown falls back to the buylast flag.
    do
        local realRec = get_recipe(rec.name)
        local perCombineQty = {}   -- item -> units per single combine, from the recipe
        if realRec then
            for _, ring in ipairs(realRec.ingredients or {}) do
                perCombineQty[ring.name] = math.max(1, ring.qty or 1)
            end
        end
        local nonStackPerCombine = 0
        for _, ing in ipairs(rec.ingredients) do
            if needed[ing.name] then
                local info = (state.itemInfo or {})[ing.name]
                local nonStack
                if info ~= nil and info.stack ~= nil then nonStack = not info.stack else nonStack = ing.buylast or false end
                if nonStack and not ing.returned then
                    nonStackPerCombine = nonStackPerCombine + (perCombineQty[ing.name] or 1)
                end
            end
        end
        if nonStackPerCombine > 0 then
            local usable = math.max(1, free_slots() or 0)   -- already nets the kit/reserve
            local batchCombines = math.max(1, math.floor(usable / nonStackPerCombine))
            for _, items in pairs(byVendor) do
                for _, it in ipairs(items) do
                    if it.buylast then
                        local cap = batchCombines * (perCombineQty[it.name] or 1)
                        if it.qty > cap then it.qty = cap end
                    end
                end
            end
            printf_log('Non-stackable batch: %d combine(s) per bag-load (%d slots / %d non-stack per combine) - rebuys each cycle.',
                batchCombines, usable, nonStackPerCombine)
        end
    end

    local allOk = true -- kept for compatibility, buy_pass now aborts on any failure

    -- Within each vendor, buy normal (stackable) items first and any |buylast
    -- items last, so non-stacking buylast items don't fill the bags before we've
    -- picked up everything else from that vendor. Stable: preserves relative order.
    local vendorOnlyBuyLast = {}   -- vendorName -> true if every needed item is buylast
    for v, items in pairs(byVendor) do
        local normal, last = {}, {}
        for _, it in ipairs(items) do
            if it.buylast then last[#last + 1] = it else normal[#normal + 1] = it end
        end
        local merged = {}
        for _, it in ipairs(normal) do merged[#merged + 1] = it end
        for _, it in ipairs(last)   do merged[#merged + 1] = it end
        byVendor[v] = merged
        vendorOnlyBuyLast[v] = (#normal == 0 and #last > 0)
    end

    -- Sort vendors globally by distance from current position.
    -- Vendors in the current zone will naturally sort nearest; out-of-zone
    -- vendors return 99999 (not visible) and sort to the end.
    local function spawn_dist(name)
        local sp = mq.TLO.Spawn(string.format('npc "%s"', name))
        return sp.Distance() or 99999
    end

    -- Finish the zone we're already in BEFORE traveling away. Otherwise a buylast-only vendor
    -- in our current zone (e.g. Felwithe) sorts behind an out-of-zone non-buylast vendor, so we
    -- Marr's out, shop elsewhere, then come all the way back - the wasteful "Marr's to Felwithe"
    -- round-trip on a restart. Current-zone first, then non-buylast-only, then nearest.
    local curZoneNow = current_zone()
    table.sort(vendorOrder, function(a, b)
        local aHere = (instByKey[a].zone or curZoneNow) == curZoneNow
        local bHere = (instByKey[b].zone or curZoneNow) == curZoneNow
        if aHere ~= bHere then return aHere end       -- current-zone vendors first
        local aLast, bLast = vendorOnlyBuyLast[a] or false, vendorOnlyBuyLast[b] or false
        if aLast ~= bLast then return not aLast end   -- then non-buylast-only vendors first
        return spawn_dist(instByKey[a].name) < spawn_dist(instByKey[b].name)
    end)

    -- Visit vendors in sorted order, zoning when the next vendor is in a
    -- different zone than where we currently are.
    for phase = 1, 2 do   -- GLOBAL two-pass: phase 1 = all non-buylast items; phase 2 = buylast (molds) LAST
    for _, key in ipairs(vendorOrder) do
        check_stop()
        local inst = instByKey[key]
        local vName = inst.name
        -- Global mold-last ordering: buy every non-buylast item (Sheet Metal, Water Flask, ...) at
        -- EVERY vendor before buying ANY buylast mold. Sorting molds last within a single vendor
        -- isn't enough when another vendor sells a needed stackable (e.g. Water Flask) - that vendor
        -- must be visited first, or the mold fills the bags and the combine is short. So we filter
        -- each vendor's list to the current phase and skip the vendor entirely if it has nothing here.
        local phaseItems = {}
        for _, it in ipairs(byVendor[key]) do
            if (phase == 2) == (it.buylast and true or false) then phaseItems[#phaseItems + 1] = it end
        end
        if #phaseItems > 0 then
        -- Stop before each vendor run too: if bags are already low, don't travel
        -- to another vendor -- go combine with what we have.
        if free_slots() <= BUY_THRESHOLD then
            printf_log('%d free slots - stopping buy pass before %s, going to combine.', free_slots(), vName)
            return true
        end
        local vZone = inst.zone or current_zone()
        if vZone ~= current_zone() then
            local travelled = false
            if vZone == ZONE_POK then
                travelled = travel_to_pok()
            elseif vZone == ZONE_MARR then
                travelled = travel_to_marr()
            elseif vZone == ZONE_JAGGEDPINE then
                travelled = travel_to_jaggedpine()
            elseif vZone == ZONE_THURGADIN then
                travelled = travel_to_thurgadin()
            elseif vZone == ZONE_FELWITHE then
                travelled = travel_to_felwithe()
            elseif vZone == 'freportw' then
                travelled = state.travel_to_freeport()
            elseif vZone == 'freportn' then
                travelled = state.travel_to_freportn()
            elseif vZone == 'abysmal' then
                travelled = state.travel_to_abysmal()
            else
                -- No travel method for this zone: record it as a manual buy so the user gets a
                -- clear "go here and buy it" list instead of a cryptic abort.
                state.record_manual_buy(phaseItems, vName, vZone)
                local rep = state.manual_buys_report()
                if #rep > 0 then
                    printf_log('--- Buy these manually (no auto-travel), by zone: ---')
                    for _, ln in ipairs(rep) do printf_log('%s', ln) end
                end
                printf_log('Cannot auto-reach %s in "%s" - aborting this craft.', vName, vZone)
                return false
            end
            if not travelled then
                printf_log('ERROR: could not travel to zone "%s" for vendor %s - aborting.', vZone, vName)
                return false
            end
        end
        if vZone == current_zone() then
            -- Vendor presence check (spawn-ID): some NPCs don't exist in an AFK mirror (e.g. Alchemist
            -- Redsa isn't in Marr's mirror), yet the mirror shares the zone shortname so vZone matches.
            -- If the NPC isn't spawned in THIS instance and we're in a mirror, hop back to the live copy
            -- and re-check before navving - otherwise nav_to spins on a vendor that physically isn't here.
            if (mq.TLO.Spawn('npc =' .. vName).ID() or 0) == 0 and (state.afkTier or 0) >= 1 then
                printf_log('%s not present in this instance (AFK mirror) - returning to the live zone...', vName)
                if state.rezone_to_live(current_zone()) then state.afkTier = 0 end
            end
            printf_log('Buying from %s...', vName)
            if not nav_to(vName) then
                printf_log('ERROR: could not reach vendor %s - aborting.', vName)
                return false
            end
            -- Pre-open settle, but ONLY where it's needed. Big merchant lists (Maree: 80 items)
            -- open partial if we open the instant we arrive - they need a beat to fully register.
            -- Small vendors load instantly, so from the merchants.ini scan we pay the settle only
            -- for large lists. Trying 1s for big vendors (was 2s) to cut the pre-buy dead stop.
            local vbig = ((state.vendorItemCount or {})[vName] or 0) >= 40
            mq.delay(vbig and 1000 or 300)
            if not open_merchant(vName) then
                printf_log('ERROR: could not open merchant %s - aborting.', vName)
                return false
            end
            -- Snapshot the target count per item so we can confirm the buy actually took.
            -- Faction can let the merchant OPEN but silently refuse the sale (Felwithe), which
            -- otherwise sails straight through to the Marr's gate with no mats on hand.
            local want = {}
            for _, item in ipairs(phaseItems) do
                want[item.name] = (want[item.name] or item_count(item.name)) + item.qty
            end
            local hitSlots = false
            for _, item in ipairs(phaseItems) do
                if free_slots() <= BUY_THRESHOLD then
                    printf_log('Hit %d free slots mid-buy - stopping purchase, proceeding to combines.', BUY_THRESHOLD)
                    hitSlots = true
                    break
                end
                if not buy_item(item.name, item.qty) then
                    printf_log('ERROR: failed to buy "%s" from %s - aborting.', item.name, vName)
                    close_merchant()
                    return false
                end
            end
            close_merchant()
            -- Confirm the shopping list actually completed here. Skip only when bags filled
            -- (a legit "go combine, top up next pass" partial). If anything is genuinely short,
            -- FAIL the run right now - do NOT gate to Marr's on bad/missing mats.
            if not hitSlots and free_slots() > BUY_THRESHOLD then
                local short = {}
                for nm, tgt in pairs(want) do
                    if item_count(nm) < tgt then
                        short[#short + 1] = string.format('%s (%d/%d)', nm, item_count(nm), tgt)
                    end
                end
                if #short > 0 then
                    printf_log('ERROR: failed to purchase from %s (faction or availability?): %s',
                        vName, table.concat(short, ', '))
                    printf_log('Aborting the craft here - NOT gating back to Marr.')
                    return false
                end
            end
            if hitSlots then return true end   -- bags full: go combine with what we have
        end
        end   -- if #phaseItems > 0
    end
    end   -- for phase = 1, 2 (non-buylast first, then molds last)

    -- After buying, if we're not in Marr or PoK, try Marr's Calling once.
    -- If that fails, error out — don't attempt combines in the wrong zone.
    local z = current_zone()
    if z ~= ZONE_MARR and z ~= ZONE_POK then
        printf_log("Buying done but still in %s - settling before Marr's Calling...", z)
        mq.delay(5000)   -- let the buy fully finish (items landed, merchant closed) before we gate out
        if not travel_to_marr() then
            printf_log('ERROR: could not return to Marr or PoK from %s - aborting.', z)
            return false
        end
    end

    return allOk
end

-- ---------------------------------------------------------------------------
-- Gem sourcing for the summon pipeline. Given the assignment plan (caster -> {imbued gem -> qty}),
-- make sure each caster holds the BASE gems it needs to imbue, using a strict waterfall so the plat
-- stays on the crafter and nothing is over-sourced:
--   1) what the caster already holds (query /ts_check)   2) the crafter's OWN bags/bank (hand over)
--   3) the group (request_supply delivers straight to the caster)   4) buy the remainder (buyable only)
-- Each step shrinks the shortfall the next covers. Imbued gems then STAY on the caster; the craft grabs
-- them in place. Farmed gems (no vendor) can't be bought - if the group's short we warn and make fewer.
state.source_gems_for_plan = function(plan)
    local myName = mq.TLO.Me.Name() or ''
    do local n = 0; for _ in pairs(plan) do n = n + 1 end; printf_log('[gem sourcing] starting for %d caster(s)...', n) end
    state.makeListenersStarted = state.makeListenersStarted or {}
    for caster in pairs(plan) do
        if not state.makeListenersStarted[caster] then
            state.peer_cmdf(caster, '/lua run TradeskillListener'); mq.delay(1500)
            state.makeListenersStarted[caster] = true
        end
    end

    -- base gem + whether it's vendor-buyable, for an imbued gem line (only 'gems' entries have one).
    local function gem_info(imbued)
        for _, m in ipairs(MAKEABLE) do
            if m.item:lower() == imbued:lower() then
                if m.group ~= 'gems' then return nil end
                if m.needs then return m.needs, false end                      -- farmed: never bought
                if imbued == 'Imbued Rose Quartz' then return 'Star Rose Quartz', true end
                return (imbued:gsub('^Imbued ', '')), true                     -- buyable: strip "Imbued "
            end
        end
        return nil
    end

    -- How many of `item` does one peer hold right now (bags+bank)? Ask just that peer, read its reply.
    local function query_count(caster, item)
        -- DanNet (bags+bank), listener-free - no /ts_check round-trip. peer_item_count returns -1 on a
        -- failed query (peer down / no reply); treat that as 0.
        local n = state.peer_item_count(caster, item)
        return (n >= 0) and n or 0
    end

    -- Buy up to `n` of `baseGem` onto the crafter from its vendor (open_merchant navs + opens).
    local function buy_gem(baseGem, n)
        local vlist = (state.vendorMap or {})[baseGem]
        if not vlist or #vlist == 0 then
            printf_log('\\arGems: no vendor known for %s - cannot buy.\\ax', baseGem); return 0
        end
        local before = item_count(baseGem)
        for _, v in ipairs(vlist) do
            if open_merchant(v.name) then
                buy_item(baseGem, n)
                close_merchant()
            end
            if item_count(baseGem) - before >= n then break end
        end
        return item_count(baseGem) - before
    end

    for caster, items in pairs(plan) do
        for imbued, qty in pairs(items) do
            local baseGem, buyable = gem_info(imbued)
            if baseGem then
                -- The caster TOPS UP to `qty` (produce: make only qty - have). So pre-read how many of the
                -- imbued gem it already holds and source base gems for the OUTSTANDING casts only -
                -- otherwise we over-hand for imbues that already exist (the "handed 20, made 10" waste).
                local haveImbued = query_count(caster, imbued)
                local target = math.max(0, qty - haveImbued)
                local cur = (target > 0) and query_count(caster, baseGem) or 0
                printf_log('[gem sourcing] %s: %s x%d (has %d imbued) -> make %d, base %s on hand %d',
                    caster, imbued, qty, haveImbued, target, baseGem, cur)
                -- 2) crafter's own stock first (pull from bank into bags if needed), so a stockpile is spent
                if cur < target then
                    local need = target - cur
                    if item_count(baseGem) < need and state.bank_count(baseGem) > 0 then
                        state.withdraw_count(baseGem, math.min(need - item_count(baseGem), state.bank_count(baseGem)))
                    end
                    local fromCrafter = math.min(need, item_count(baseGem))
                    if fromCrafter > 0 then
                        printf_log('Gems: handing %s %d %s from my own stock...', caster, fromCrafter, baseGem)
                        state.deliver_to_peer(caster, baseGem, fromCrafter)
                        cur = query_count(caster, baseGem)
                    end
                end
                -- 3) group -> delivered straight to the caster
                if cur < target then
                    printf_log('Gems: asking the group for %d %s for %s...', target - cur, baseGem, caster)
                    request_supply(baseGem, target - cur, caster)
                    cur = query_count(caster, baseGem)
                end
                -- 4) buy the remainder (buyable only), then hand it over
                if cur < target then
                    local short = target - cur
                    if buyable then
                        printf_log('Gems: buying %d %s to hand to %s...', short, baseGem, caster)
                        local got = buy_gem(baseGem, short)
                        if got > 0 then state.deliver_to_peer(caster, baseGem, math.min(short, item_count(baseGem))) end
                    else
                        printf_log('\\arGems: %s is farmed and short %d for %s - it will make fewer. Farm/supply more.\\ax', baseGem, short, caster)
                    end
                end
            end
        end
    end
    printf_log('\\agGem sourcing done - casters supplied; firing the imbues.\\ax')
end

-- Destroys one copy of `name`. Crafted jewelry doesn't stack, so we
-- can't reliably match a single captured Item ID against whichever slot
-- FindItem happens to return (see sell_item_by_id above for the same
-- issue). In Destroy mode each copy is destroyed immediately after it's
-- made, so matching by name alone is safe here.
local function destroy_one(name)
    local invItem = mq.TLO.FindItem('=' .. name)
    if (invItem.ID() or 0) == 0 then return false end
    mq.cmdf('/nomodkey /itemnotify "%s" leftmouseup', name)
    delay(800, function() return cursor_id() > 0 end)
    if cursor_id() > 0 then
        mq.cmd('/destroy')
        delay(1000, function() return cursor_id() == 0 end)
    end
    clear_cursor()
    return true
end

-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Recursive subcombine execution
-- ---------------------------------------------------------------------------

-- Forward declaration so execute_recipe can call itself recursively
local execute_recipe
-- Forward-declared too: defined further down (after the vendor/buy helpers it needs) but
-- called from execute_recipe above that point, to stage a kit into the canonical slot.
local ensure_kit_in_pack

-- Net requirements planning: turn the top recipe into a flat bill of materials in one place,
-- the single source of truth for both the vendor pre-buy and the production cap. Every leaf is
-- classified exactly as the combine loop classifies it (returned -> dropped -> vendor -> recipe
-- -> assume-vendor), so the plan can never disagree with what actually gets made vs bought.
-- On-hand stock is netted: subcombine product already in your bags PRUNES the tree (6 Champagne
-- Magnums on hand -> only 994 get made, so only 994 sets of their mats are pulled), credited
-- once globally so a subcombine shared by two parents isn't double-counted. Leaf demand sums
-- GROSS across every parent that uses it (three recipes each needing a Bottle on a 1000 run ->
-- 3000 Bottles); on-hand leaves are netted once downstream by buy_pass.
--
-- Returns nil if the recipe is unknown, else:
--   buyDemand[name]    = vendor units to acquire (subcombine-pruned, gross leaf). buy_pass nets
--                        your on-hand once when it runs, so pass quantity=1.
--   supplyDemand[name] = non-purchasable units still needed (subcombine-pruned).
--   grossSupply[name]  = non-purchasable units a FULL run needs ignoring on-hand subcombine
--                        product -- the true per-combine ratio, used to size the cap.
--   makeQty[name]      = subcombines to actually make, net of on-hand (for the manifest).
local function plan_requirements(topName, topCombines, reserved, ignoreCantBuy)
    if not get_recipe(topName) then return nil end
    local secs = state.iniSections or {}
    local vmap = state.vendorMap or {}
    local function isRecipe(n) return secs['Recipe:' .. n] ~= nil end
    -- "Can't buy" (per character): a vendor-sold item THIS toon cannot shop for - a faction-gated
    -- vendor, e.g. an SK who can't enter Felwithe for mithril. It's still vendor-sold in the data;
    -- we just source it from the group instead, so it lands in supplyDemand and the ONE upfront
    -- pre-load trip requests it alongside the dropped mats. Buy Ingredients passes ignoreCantBuy so
    -- a BOT that CAN reach the vendor still buys the real leaves.
    local function can_buy(n)
        if not vmap[n] then return false end
        if ignoreCantBuy then return true end
        return not (state.cantBuy or {})[n]
    end

    -- Is `name` a cyclic-only material - one whose recipe tree loops back to itself with NO vendor
    -- exit (e.g. velium Small Brick <-> Small Piece, neither vendor-sold)? Such forms can't be crafted
    -- from scratch; they're FARMED, and the reduce/build recipes only convert between forms you already
    -- have. We treat them as supply leaves so the plan says "supply N" instead of walking the loop and
    -- ballooning the counts. High Quality Ore is NOT cyclic here: its Small Brick is vendor-sold, so the
    -- vendor exit breaks the loop and those forms stay craftable (buy brick -> reduce to pieces).
    state.cyclicMatCache = state.cyclicMatCache or {}
    local function is_cyclic_material(name)
        local cached = state.cyclicMatCache[name]
        if cached ~= nil then return cached end
        local function dfs(n, target, seen, depth)
            if depth > 8 or seen[n] then return false end
            seen[n] = true
            local r = state._rawRecipe(n); if not r then return false end
            for _, ing in ipairs(r.ingredients) do
                if not ing.returned and not vmap[ing.name] and isRecipe(ing.name) then
                    if ing.name == target then return true end
                    if dfs(ing.name, target, seen, depth + 1) then return true end
                end
            end
            return false
        end
        local result = dfs(name, name, {}, 0)
        state.cyclicMatCache[name] = result
        return result
    end

    -- RAW walk: full tree, no netting. Only totals SUPPLY mats (for the cap ratio). A
    -- vendor-sold item is bought even when a recipe exists, so we don't recurse into it.
    local grossSupply = {}
    local function rawWalk(name, combines, depth)
        if depth > 8 then return end
        local rec = get_recipe(name); if not rec then return end
        for _, ing in ipairs(rec.ingredients) do
            local total = (ing.qty or 1) * combines
            if ing.returned then
                if isRecipe(ing.name) and item_count(ing.name) == 0 then rawWalk(ing.name, 1, depth + 1) end
            elseif ing.dropped then
                grossSupply[ing.name] = (grossSupply[ing.name] or 0) + total
            elseif can_buy(ing.name) then
                -- vendor leaf (even if also a recipe): bought, not a supply mat - skip
            elseif vmap[ing.name] then
                -- Vendor-sold but unbuyable by this character: it's supply, so it must count toward
                -- the scarcity cap like any other supply mat (otherwise the batch is sized as if we
                -- had unlimited mithril and stalls mid-run waiting on the group).
                grossSupply[ing.name] = (grossSupply[ing.name] or 0) + total
            elseif isRecipe(ing.name) and is_cyclic_material(ing.name) then
                -- Cyclic-only (farmed) form: supply it, don't walk the conversion loop.
                grossSupply[ing.name] = (grossSupply[ing.name] or 0) + total
            elseif isRecipe(ing.name) then
                local sub = get_recipe(ing.name)
                rawWalk(ing.name, math.ceil(total / math.max(1, (sub and sub.yield) or 1)), depth + 1)
            end
        end
    end
    rawWalk(topName, topCombines, 0)

    -- NETTED walk: prune subcombines by on-hand product (credited once, globally), summing
    -- buy/supply leaf demand gross across all live parents.
    local buyDemand, supplyDemand, makeQty, credit = {}, {}, {}, {}
    local buyLast = {}   -- item name -> true if it's a |buylast (mold): buy it after everything else
    local function netWalk(name, combines, depth)
        if depth > 8 then return end
        local rec = get_recipe(name); if not rec then return end
        for _, ing in ipairs(rec.ingredients) do
            local total = (ing.qty or 1) * combines
            if ing.returned then
                if isRecipe(ing.name) and item_count(ing.name) == 0 then netWalk(ing.name, 1, depth + 1) end
            elseif ing.dropped then
                supplyDemand[ing.name] = (supplyDemand[ing.name] or 0) + total
            elseif can_buy(ing.name) then
                buyDemand[ing.name] = (buyDemand[ing.name] or 0) + total
                if ing.buylast then buyLast[ing.name] = true end
            elseif vmap[ing.name] then
                -- Vendor-sold, but this character can't shop there: source it from the group.
                supplyDemand[ing.name] = (supplyDemand[ing.name] or 0) + total
            elseif isRecipe(ing.name) and is_cyclic_material(ing.name) then
                -- Cyclic-only (farmed) form (velium Small Brick/Piece etc.): treat as supply, don't
                -- recurse into the build<->reduce loop. Netted against on-hand later like any supply mat.
                supplyDemand[ing.name] = (supplyDemand[ing.name] or 0) + total
            elseif isRecipe(ing.name) then
                -- Credit BOTH on-hand AND banked product, so a subcombine we already have banked
                -- prunes its subtree and we don't buy the leaf mats to remake it. In run_engine the
                -- bank pull has already run by the time this is called, so bank_count reads 0 and this
                -- is a no-op; in the research grouped buy it hasn't, so THIS is where banked
                -- intermediates get pruned before the vendor trip.
                -- `reserved` (optional, shared across a batch's per-spell calls) claims each unit of
                -- shared bank/on-hand stock as it's consumed, so two spells needing the SAME banked
                -- intermediate don't both prune it - the second sees it already spoken for.
                if credit[ing.name] == nil then
                    local avail = item_count(ing.name)
                        + ((state.bank_count and state.bank_count(ing.name)) or 0)
                    if reserved then avail = math.max(0, avail - (reserved[ing.name] or 0)) end
                    credit[ing.name] = avail
                end
                local used = math.min(credit[ing.name], total)
                credit[ing.name] = credit[ing.name] - used
                if reserved and used > 0 then reserved[ing.name] = (reserved[ing.name] or 0) + used end
                local needed = total - used
                if needed > 0 then
                    makeQty[ing.name] = (makeQty[ing.name] or 0) + needed
                    local sub = get_recipe(ing.name)
                    netWalk(ing.name, math.ceil(needed / math.max(1, (sub and sub.yield) or 1)), depth + 1)
                end
            else
                buyDemand[ing.name] = (buyDemand[ing.name] or 0) + total
                if ing.buylast then buyLast[ing.name] = true end
            end
        end
    end
    netWalk(topName, topCombines, 0)

    return { buyDemand = buyDemand, supplyDemand = supplyDemand,
             grossSupply = grossSupply, makeQty = makeQty, buyLast = buyLast }
end

-- Total coin on hand, in COPPER (plat+gold+silver+copper). Used to gate buys on affordability.
state.coin_on_hand_cp = function()
    local p = mq.TLO.Me.Platinum() or 0
    local g = mq.TLO.Me.Gold() or 0
    local s = mq.TLO.Me.Silver() or 0
    local c = mq.TLO.Me.Copper() or 0
    return p * 1000 + g * 100 + s * 10 + c
end

-- Estimate what a plan's BUY pass will cost, in copper, from scanned prices. Returns:
--   costCp   - summed price*qty over every buyDemand item we have a price for
--   priced   - how many buy item types were priced
--   total    - how many buy item types there are
-- complete estimate = (priced == total). A partial estimate undercounts (unpriced items count as 0),
-- so callers WARN but don't hard-block on a partial - only a COMPLETE estimate that exceeds coin blocks.
state.plan_cost_cp = function(plan)
    local costCp, priced, total = 0, 0, 0
    for nm, q in pairs((plan and plan.buyDemand) or {}) do
        if q > 0 then
            total = total + 1
            local info = (state.itemInfo or {})[nm]
            if info and info.price and info.price > 0 then
                costCp = costCp + info.price * q
                priced = priced + 1
            end
        end
    end
    return costCp, priced, total
end

-- Affordability gate. Given a recipe + combine count, returns (ok, reason).
--   ok=true  -> proceed (affordable, OR estimate is partial so we don't block - warn instead)
--   ok=false -> a COMPLETE estimate exceeds coin on hand; reason is a ready-to-log message.
-- Always returns a second value 'warn' (string or nil) for the partial-estimate case so the caller
-- can surface it without stopping.
state.can_afford_plan = function(recipeName, combines)
    local okp, plan = pcall(function() return plan_requirements(recipeName, combines) end)
    if not okp or not plan then return true, nil end   -- can't plan -> don't block on cost
    local costCp, priced, total = state.plan_cost_cp(plan)
    local haveCp = state.coin_on_hand_cp()
    local havePp = math.floor(haveCp / 1000)
    local costPp = math.floor(costCp / 1000)
    if total == 0 or priced == 0 then
        return true, nil   -- nothing priced / nothing to buy - no basis to block
    end
    if priced < total then
        -- partial estimate: warn but proceed (the known part may already exceed coin, but we can't be sure)
        local warn = string.format('cost estimate is partial (%d of %d buy items priced; ~%d pp known) vs %d pp on hand',
            priced, total, costPp, havePp)
        return true, warn
    end
    -- complete estimate
    if costCp > haveCp then
        return false, string.format('need ~%d pp but only have %d pp', costPp, havePp)
    end
    return true, nil
end



-- ── Pre-load dropped mats from the group (staged in Marr's) ───────────────────────────────────
-- Compute the DROPPED-item shortfall for a set of recipes (each { name=, combines= }), netting
-- bags + bank. supplyDemand from plan_requirements already gives the per-item dropped need across
-- the whole tree. Returns { item = shortfallQty } for everything we can't cover ourselves.
-- Items flagged 'dropped' in a recipe but actually NO DROP (can't be traded), so they must never be
-- requested from the group - the crafter has to farm/hold them itself. Excluded from request shortfalls.
state.NODROP_ITEMS = { ['Ancient Shield of Corrupted Tranquility'] = true }

state.dropped_shortfall = function(recipeList)
    local demand = {}
    for _, r in ipairs(recipeList or {}) do
        -- Resolve by section KEY when the caller has it. Gem-variant recipes (idols: Amber/Ivory/...)
        -- share Name="Unfired Idol", so a display-name lookup collides to the base (Ivory) section and
        -- the shortfall is computed for the wrong gem. r.key is the exact section; r.name is the fallback.
        local plan = plan_requirements(r.key or r.name, r.combines or 1)
        if plan and plan.supplyDemand then
            for item, need in pairs(plan.supplyDemand) do
                demand[item] = (demand[item] or 0) + need
            end
        end
    end
    local short = {}
    for item, need in pairs(demand) do
        -- Skip NO-DROP items: they can't be traded, so a group request would just fail.
        if not state.NODROP_ITEMS[item] then
            local have = item_count(item) + ((state.bank_count and state.bank_count(item)) or 0)
            if need > have then short[item] = need - have end
        end
    end
    return short
end

-- Travel to Marr's (the group's staging zone), request the EXACT shortfall of each dropped item from
-- the group, then return to PoK ready to craft. One resupply trip, computed upfront - so a run never
-- has to stop mid-iteration to beg for mats. `recipeList` is a list of { name=, combines= }.
state.preload_dropped = function(recipeList)
    local short = state.dropped_shortfall(recipeList)
    if not next(short) then
        printf_log('Pre-load: already have every dropped mat needed - nothing to request.')
        return true
    end
    printf_log('\agPre-load: dropped-mat shortfalls to request from the group:\ax')
    -- A fresh request always re-checks the group - clear any session "exhausted" flags for these
    -- items. The bank/group checks are cheap, and the user explicitly asked again.
    for item in pairs(short) do supplyExhausted[item] = nil end
    local items = {}
    for item, qty in pairs(short) do
        printf_log('  need %d more %s', qty, item)
        -- needed = target BAGS count (current on-hand + the shortfall). request_supply_grouped stops
        -- when bags reach it and asks each mule only for the still-missing remainder. We leave the
        -- crafter's own bank for the craft's pre-pass; the group covers just the true shortfall.
        items[#items + 1] = { name = item, needed = item_count(item) + qty, mode = 'stack' }
    end

    -- No forced Marr trip: mules deliver to wherever the crafter stands (request_supply navs the mule
    -- to us). Members just need to be in our CURRENT zone - request_supply skips any who aren't. So we
    -- receive right here instead of dragging the whole run to Marr first.

    -- ONE grouped batch: a single bank trip + one trade window PER MULE for ALL items together
    -- (e.g. Brownie Parts AND Fruit in the same trip), exact counts, split across mules as needed.
    state.request_supply_grouped(items, nil)

    printf_log('\agPre-load complete - mats in hand. Start your craft; it will route to its station.\ax')
    return true
end

-- Reading A leveling selection: from the current rung forward, pick the first below-trivial rung whose
-- dropped shortfall the GROUP can cover (fast /ts_check, NO delivery here). run_engine does the single
-- actual pull for the chosen rung when it crafts it, so we never double-request and never pull for rungs
-- we won't reach. Returns the chosen index, or nil if none qualifies. Lives in state.X so its locals
-- don't count against the main chunk's 200-local ceiling. checkFn is group_check (passed in from the
-- advance loop where it's in scope).
state.level_group_select = function(curSkill, checkFn)
    local batchQ = math.max(1, math.min(MAX_QUANTITY, tonumber(state.levelBatchBuf) or 100))
    for i = state.levelCurrentIndex, #state.levelPlan do
        local ent = state.levelPlan[i]
        local cand = get_recipe(ent.itemName)
        if cand and ent.trivial > curSkill
           and not (state.levelSkip and state.levelSkip[ent.itemName])
           and not (state.levelSupplyFailed and state.levelSupplyFailed[ent.itemName]) then
            local short = state.dropped_shortfall({ { name = cand.name, key = cand.key, combines = batchQ } })
            if not next(short) then
                return i   -- no dropped shortfall - already selectable
            end
            local names = {}
            for nm in pairs(short) do names[#names + 1] = nm end
            local avail = checkFn(names)   -- fast group availability; no delivery
            local covered = true
            for _, nm in ipairs(names) do
                if not (avail[nm] and avail[nm] > 0) then covered = false; break end
            end
            if covered then
                printf_log('Leveling: group can supply %s - selecting it (run_engine will pull the mats).', cand.name)
                return i
            end
            state.levelSupplyFailed = state.levelSupplyFailed or {}
            state.levelSupplyFailed[cand.name] = true
            printf_log('Leveling: group is out of dropped mats for %s - moving to the next recipe.', cand.name)
        end
    end
    return nil
end

-- Ensure exactly 1 of a returned item is in inventory.
-- If already there: done. If craftable: make one. Otherwise: error.
local function ensure_returned_item(name, kitPack)
    if item_count(name) > 0 then return true end
    local recSec = (state.iniSections or {})['Recipe:' .. name]
    if recSec then
        printf_log('%s not in inventory - crafting one...', name)
        return execute_recipe(name, 1, nil, kitPack)
    end
    -- Vendor-sold returned tool (e.g. Simple Sewing Needle): buy exactly one.
    if (state.vendorMap or {})[name] then
        printf_log('%s not in inventory - buying one...', name)
        local oneRec = { name = name, ingredients = { { name = name, qty = 1 } } }
        if buy_pass(oneRec, 1, nil) and item_count(name) > 0 then
            return true
        end
        printf_log('ERROR: could not buy %s.', name)
        return false
    end
    printf_log('ERROR: %s not in inventory and no recipe found. Obtain one manually.', name)
    return false
end

-- A |returned tool momentarily reads item_count 0 while it's on the CURSOR being handed
-- back after a combine (FindItemCount sees it in bags/kit, but not on the cursor). Before
-- treating it as lost - which would buy/craft a needless second one - settle any cursor
-- item and re-read. This is what lets us keep just ONE returned tool on hand instead of a spare.
state.returned_tool_missing = function(name)
    if item_count(name) > 0 then return false end
    if cursor_id() ~= 0 then          -- likely the tool mid-hand-back; stow it and re-check
        mq.cmd('/autoinventory')
        mq.delay(700, function() return cursor_id() == 0 end)
    end
    mq.delay(150)
    return item_count(name) == 0
end

-- Make at least `needed` of a subcombine, retrying up to 10 times.
-- If noRetry is true, makes exactly one pass (for leveling mode).
-- Returns true if we end up with >= needed, false otherwise.
local function make_subcombine(name, needed, defaultVendor, kitPack, noRetry)
    local subRec = get_recipe(name)
    if not subRec then
        printf_log('ERROR: no recipe for subcombine %s.', name)
        return false
    end
    -- CYCLE GUARD. Some materials convert between forms BOTH ways (e.g. Block of High Quality Ore is
    -- made from Large Brick, and Large Brick is made from Block). Recursing into such a pair loops
    -- forever and hangs the game. Track what's being made up the call stack; if this item is already
    -- in progress, don't recurse - use on-hand/vendor stock instead. An infinite hang becomes a clear
    -- "buy it or a related form, or pre-stock it" message. (Vendor-sold forms never reach here - they're
    -- bought directly - so this only bites genuinely circular, non-vendor conversions.)
    state._makingStack = state._makingStack or {}
    if state._makingStack[name] then
        if item_count(name) >= needed then return true end
        printf_log('\arCircular recipe: %s converts back into itself - it can\'t be crafted from scratch. Buy it (or a related ore form) or pre-stock it. Proceeding with %d on hand.\ax',
            name, item_count(name))
        return noRetry and true or false
    end
    state._makingStack[name] = true

    -- The loop below calls execute_recipe, which can THROW (check_stop, a nav failure, __TS_STOP__).
    -- If it does, we must still clear _makingStack[name] - otherwise it stays flagged "in progress"
    -- forever, and every later attempt at this item false-fires the cycle guard ("converts back into
    -- itself") and refuses to craft it. That's the Barbecue Sauce spin: one interrupted subcombine
    -- poisoned the recipe for the rest of the session. pcall guarantees the cleanup, then re-raise.
    local MAX_ATTEMPTS = noRetry and 1 or 10
    local runOk, runErr = pcall(function()
        local attempt = 0
        while item_count(name) < needed and attempt < MAX_ATTEMPTS do
            attempt = attempt + 1
            local have = item_count(name)
            local toMake = needed - have
            local combines = math.ceil(toMake / subRec.yield)
            printf_log('Subcombine %s: need %d have %d - making %d combines (attempt %d)...',
                name, needed, have, combines, attempt)
            local before = item_count(name)
            execute_recipe(name, combines, defaultVendor, kitPack, noRetry)
            if item_count(name) == before then
                printf_log('WARNING: no progress on %s (still have %d/%d) - stopping retries.',
                    name, item_count(name), needed)
                break
            end
        end
    end)

    state._makingStack[name] = nil   -- ALWAYS clear, even if the loop threw
    if not runOk then error(runErr) end   -- re-raise a genuine stop/error after cleaning up

    if item_count(name) < needed then
        if not noRetry then
            -- Not fatal any more: the callers craft what the partial allows.
            printf_log('Subcombine %s: made %d/%d - callers will craft what this allows.', name, item_count(name), needed)
            return false
        end
        -- In noRetry mode, partial success is OK - we'll just make fewer final combines
        printf_log('Subcombine %s: made %d/%d (partial ok in leveling mode).', name, item_count(name), needed)
    end
    return true
end

-- Full cycle for one recipe: buy ingredients (including subcombines), open
-- container, combine qty times. Used for subcombines and direct calls.
-- Returns true if at least one combine succeeded (or qty == 0).
execute_recipe = function(itemName, qty, defaultVendor, kitPack, noRetry)
    kitPack = kitPack or KIT_PACK_DEFAULT
    local rec = get_recipe(itemName)
    if not rec then
        printf_log('ERROR: no recipe found for %s.', itemName)
        return false
    end
    -- Use rec.key (the resolved section) not itemName, so a reduce recipe (whose section is
    -- "Reduce X" but whose output Name= is X) finds its own Container/ContainerType.
    local recSec = (state.iniSections or {})['Recipe:' .. (rec.key or itemName)]
    if not recSec or not recSec.Container then
        printf_log('ERROR: [Recipe:%s] has no Container= defined.', itemName)
        return false
    end

    printf_log('Preparing %dx %s...', qty, itemName)

    -- Preflight: returned -> handle separately, vendor sold -> buy, has recipe -> subcombine
    local vendorIngs = {}
    for _, ing in ipairs(rec.ingredients) do
        check_stop()
        if ing.returned then
            -- Returned items with recipes: make one now during preflight for correct ordering
            if (state.iniSections or {})['Recipe:' .. ing.name] and not (state.vendorMap or {})[ing.name] then
                if item_count(ing.name) == 0 then
                    if not ensure_returned_item(ing.name, kitPack) then
                        printf_log('ERROR: could not obtain returned item %s - aborting.', ing.name)
                        return false
                    end
                end
            end
            -- Non-craftable / vendor-sold returned items checked per-combine
        elseif ing.dropped then
            -- Farmed/foraged mat: pre-loaded into bags (or mule-supplied), NEVER bought.
            -- run_engine handles this for top recipes; subcombines need it too, or the
            -- buy pass aborts with "no vendor found". If short, we proceed with what's on
            -- hand and the combine loop simply makes fewer.
            local needed = ing.qty * qty
            if item_count(ing.name) < needed then
                printf_log('%s: have %d of %d (farmed/|dropped - pre-load via the Request tab).',
                    ing.name, item_count(ing.name), needed)
            end
        elseif (state.vendorMap or {})[ing.name] then
            -- Vendor sold: always buy, even if a recipe also exists
            vendorIngs[#vendorIngs + 1] = ing
        elseif (state.iniSections or {})['Recipe:' .. ing.name] then
            local needed = ing.qty * qty
            if item_count(ing.name) < needed then
                if not make_subcombine(ing.name, needed, defaultVendor, kitPack, noRetry) then
                    -- Partial is fine: craft what the mats allow rather than abandoning the run. A
                    -- single fizzle eats a dropped mat (e.g. a Black Pearl), so the subcombine comes
                    -- up one short and we'd otherwise abort the whole parent for nothing. The combine
                    -- loop already stops cleanly when an ingredient runs out, making fewer of the parent.
                    printf_log('Only %d of %d %s - continuing with what we have.',
                        item_count(ing.name), needed, ing.name)
                end
            end
        else
            vendorIngs[#vendorIngs + 1] = ing
        end
    end

    -- Buy all vendor ingredients in one pass
    if #vendorIngs > 0 then
        local vendorRec = {
            name = rec.name, yield = rec.yield, trivial = rec.trivial,
            sellable = rec.sellable, ingredients = vendorIngs,
        }
        if not buy_pass(vendorRec, qty, defaultVendor) then
            printf_log('ERROR: buy pass failed for %s - aborting.', itemName)
            return false
        end
    end

    -- For a configured inventory kit, stage it into the canonical slot FIRST: buy one if
    -- we have none, or clear that slot and move the kit in if it's sitting elsewhere. So a
    -- combine never depends on the user pre-placing the kit, and a multi-kit tree (MTP's
    -- Mixing Bowl + Sewing Kit) just swaps the needed kit into the slot as each runs.
    -- ensure_kit_in_pack returns false / no-ops for non-kit containers, so world
    -- containers fall straight through to the resolve below.
    if trim(recSec.ContainerType or 'inventory'):lower() == 'inventory' then
        ensure_kit_in_pack(recSec.Container or '', KIT_PACK_DEFAULT)
    end

    -- Resolve container
    local cinfo = resolve_container_info(recSec, kitPack)
    if not cinfo then
        printf_log('ERROR: no container found for %s.', itemName)
        return false
    end
    -- Use whichever pack the kit ended up in (slot 10 after staging, or wherever a
    -- non-configured kit was found).
    if cinfo.pack then kitPack = cinfo.pack end

    -- Seat the tradeskill trophy for THIS combine's container if the skill is past 300.
    -- No-op under 300 or for containers without a trophy; hard-stops the run (-> PoK) if a
    -- required trophy is missing from bags and bank. Done before zoning so the bank trip (if
    -- any) happens before we travel to the station.
    if not state.ensure_trophy(recSec.Container) then return false end

    -- Zone to container if needed
    if cinfo.type == 'world' and cinfo.navZone and current_zone() ~= cinfo.navZone then
        local z = cinfo.navZone
        if z == ZONE_MARR then
            if not travel_to_marr() then return false end
        elseif z == ZONE_POK then
            if not travel_to_pok() then return false end
        elseif z == ZONE_JAGGEDPINE then
            if not travel_to_jaggedpine() then return false end
        end
    end

    -- Open container
    if cinfo.type == 'world' then
        if not world_open(cinfo) then return false end
    else
        if not open_kit(cinfo, kitPack) then return false end
        clear_kit(cinfo, kitPack, 10)
    end

    -- Slot count
    local slotCount = 0
    for _, ing in ipairs(rec.ingredients) do
        slotCount = slotCount + ing.qty
    end

    -- Combine loop
    local madeTotal = 0
    local worldStaged = false   -- true while a reusable set sits in the enviro slots
    local hardStageFails = 0    -- consecutive staging failures; bail instead of spinning all qty
    for n = 1, qty do
        check_stop()
        -- Pause checkpoint for subcombines too (deep trees spend most time here). Resume re-validates:
        -- reopen the kit / world container and continue at the current subcombine, not from 1.
        state.check_pause(function()
            if cinfo.type == 'world' then
                if not world_open(cinfo) then return false end
                worldStaged = false
            else
                -- The player likely MOVED the kit during the pause (rearranged bags), so re-seat it into
                -- pack<kitPack> before opening - otherwise open_kit fails "must be in packN" and the resume
                -- bails with "can't safely resume." Matches revalidate #2: re-adjust to the right state
                -- (reopen/re-seat the kit) instead of giving up, since a pause means the player DID something.
                if not ensure_kit_in_pack(recSec.Container or '', kitPack) then return false end
                if not open_kit(cinfo, kitPack) then return false end
            end
            return true
        end)

        -- Ensure returned items present before each combine
        for _, ing in ipairs(rec.ingredients) do
            if ing.returned and state.returned_tool_missing(ing.name) then
                printf_log('%s missing before combine %d - obtaining...', ing.name, n)
                if cinfo.type == 'world' then close_world_container() end
                if not ensure_returned_item(ing.name, kitPack) then
                    printf_log('ERROR: could not obtain %s - aborting.', ing.name)
                    return false
                end
                -- Re-open our container after the detour. ensure_returned_item may craft the tool at a
                -- DIFFERENT station (e.g. the Mithril Working Knife is forged in a Blacksmithing world
                -- container), which closes THIS recipe's kit. World path already reopened; the inventory
                -- kit was NOT - so kit_open failed on every later combine and staging spun forever
                -- ("could not stage ingredients", the Mithril Fletchings bug). Reopen both cases.
                if cinfo.type == 'world' then
                    if not world_open(cinfo) then return false end
                    worldStaged = false   -- reopening empties the enviro slots
                else
                    if not open_kit(cinfo, kitPack) then
                        printf_log('ERROR: could not reopen %s after obtaining %s - aborting.', cinfo.name, ing.name)
                        return false
                    end
                end
            end
        end

        -- Confirm we hold every ingredient for ONE combine BEFORE opening the
        -- container and staging anything. Otherwise we place part of the set,
        -- discover the shortfall mid-stage (e.g. out of Fruit at slot 4), and have
        -- to clear it back out - repeatedly. Buys and subcombines already ran by
        -- now, so a shortfall here means it's genuinely unavailable.
        do
            local short
            for _, ing in ipairs(rec.ingredients) do
                if item_count(ing.name) < ing.qty then
                    short = string.format('%s (have %d, need %d)', ing.name, item_count(ing.name), ing.qty)
                    break
                end
            end
            if short then
                printf_log('Stopping %s at %d/%d made - out of %s.', itemName, madeTotal, qty, short)
                break
            end
        end

        if cinfo.type == 'world' then
            -- Stage from a known-empty enviro. Returned items from a failed combine are bagged
            -- (never re-placed into slots), so normally the slots are already empty here -- this
            -- clear is just insurance against a stale set left by a prior session/stop.
            if not worldStaged then
                if world_stage(cinfo, rec, slotCount) then
                    worldStaged = true
                else
                    printf_log('FAILED %s: could not stage ingredients (%d/%d).', itemName, n, qty)
                end
            end
            if worldStaged then
                local before = item_count(itemName)
                local ok, staged = world_combine_return(cinfo, rec, itemName, before, slotCount)
                if ok then
                    madeTotal = madeTotal + 1
                    worldStaged = false   -- ingredients consumed; re-place next pass
                else
                    printf_log('FAILED combine %d/%d: %s.', n, qty, itemName)
                    worldStaged = staged  -- reuse in place if cleanly re-staged
                end
            end
        else
            -- Reopen the kit if it closed. A FAILED combine returns its ingredients via the cursor, and
            -- for a returned-tool recipe (Mithril Fletchings' knife) that cursor-return runs /autoinventory,
            -- which closes the ContainerCombine_Items window. The loop opened the kit once up top and only
            -- CHECKS it in stage_kit, so once combine 1 failed the window stayed shut and every later stage
            -- logged "kit did not open" forever. Raising it here before each stage self-heals that.
            if not kit_open(cinfo) then
                if not open_kit(cinfo, kitPack) then
                    printf_log('FAILED %s: could not reopen kit (%d/%d).', itemName, n, qty)
                    hardStageFails = hardStageFails + 1
                    if hardStageFails >= 5 then
                        printf_log('\ar%s: kit would not reopen %d times in a row - aborting this subcombine.\ax', itemName, hardStageFails)
                        break
                    end
                    goto continue_subcombine
                end
            end
            local placedOk = stage_kit(cinfo, rec, kitPack)
            if not placedOk then
                printf_log('FAILED %s: could not stage ingredients (%d/%d).', itemName, n, qty)
                clear_kit(cinfo, kitPack, slotCount)
                hardStageFails = hardStageFails + 1
                if hardStageFails >= 5 then
                    printf_log('\ar%s: staging failed %d times in a row - aborting this subcombine (check the recipe/ingredients; nothing was made).\ax', itemName, hardStageFails)
                    break
                end
            else
                hardStageFails = 0   -- staged fine, reset the streak
                local before = item_count(itemName)
                -- Decisive probe (first 3 only): is the combine window actually open at the moment we're
                -- about to combine, right after a successful stage? If this says open=false, the kit
                -- window is closing between stage and combine - the real root of the Fletchings failures.
                if (state._cwWinN or 0) < 3 then
                    state._cwWinN = (state._cwWinN or 0) + 1
                    printf_log('pre-combine probe #%d %s: ContainerCombine_Items open=%s',
                        state._cwWinN, itemName, tostring(mq.TLO.Window('ContainerCombine_Items').Open()))
                end
                if combine_and_wait(cinfo, rec, kitPack, itemName, before) then
                    madeTotal = madeTotal + 1
                else
                    printf_log('FAILED combine %d/%d: %s.', n, qty, itemName)
                    -- A failed combine does NOT reliably leave a clean, reusable set in the kit -
                    -- especially for a returned-tool recipe (Mithril Fletchings), where the knife gets
                    -- bagged and the brick's state is uncertain. If we "leave them and reuse", the next
                    -- stage places a FRESH set into the next free slots instead of reusing slots 1-2, and
                    -- they pile up until "no free kit slot" (the slot 1->2->...->8 climb). So clear the kit
                    -- after a failure and let the next pass stage a clean set from bags.
                    clear_kit(cinfo, kitPack, slotCount)
                end
            end
        end
        ::continue_subcombine::
    end

    if cinfo.type == 'world' then close_world_container() end
    printf_log('%s: made %d/%d.', itemName, madeTotal, qty)
    return madeTotal > 0 or qty == 0
end

-- Ensures the right kit is in pack<kitPack>. Checks inventory first, buys if needed.
-- Returns true if kit is now in place, false otherwise.
ensure_kit_in_pack = function(containerName, kitPack)
    -- Find matching kit config
    local cfg = nil
    for _, c in ipairs(KIT_CONFIG) do
        if containerName:lower():find(c.keyword, 1, true) then cfg = c; break end
    end
    if not cfg then return false end

    -- Check if correct kit already in pack<kitPack>
    local function kit_in_pack()
        local bagName = (mq.TLO.Me.Inventory('pack' .. kitPack).Name() or ''):lower()
        for _, v in ipairs(cfg.variants) do
            if bagName == v:lower() then return true end
        end
        return false
    end

    if kit_in_pack() then return true end

    -- A DIFFERENT kit is about to go into pack<kitPack>. Now that a clean run leaves the combine window
    -- open across recipes, any window still up is for the OLD kit - flag a fresh open so open_kit rebuilds
    -- it for the new one instead of reusing the wrong window. (Same-kit runs return above and never hit this.)
    state.combineWindowDirty = true

    -- A swap is needed. If we got here straight off a WORLD subcombine (e.g. this inventory
    -- kit sits under a Kiln/Pottery Wheel parent), that combine's product is often still on the
    -- cursor pre-autoinventory - and a bag pickup/swap with an occupied cursor silently no-ops,
    -- leaving the wrong kit in pack<kitPack> so open_kit then errors and the run only recovers
    -- on a retry. Stow the cursor first so the swap below actually takes on the first pass.
    -- (This is the Concordance-vs-Glaze-Mortar thrash: Glaze Mortar buried under the Kiln tree.)
    clear_cursor()

    -- Find which variant we have in inventory (prefer best first), excluding pack10
    local function find_kit_in_inventory()
        for _, variant in ipairs(cfg.variants) do
            local kit = mq.TLO.FindItem('=' .. variant)
            local id   = kit.ID() or 0
            local slot = kit.ItemSlot() or 0
            if id > 0 and slot ~= (22 + kitPack) then
                return variant, slot, kit.ItemSlot2() or -1
            end
        end
        return nil, nil, nil
    end

    local kitName, kitSlot, kitSlot2 = find_kit_in_inventory()

    -- If not found anywhere, buy one
    if not kitName then
        if cfg.quest then
            printf_log('\ar%s is a quest item and you do not have one - cannot craft this. (The suite does not run the quest.)\ax', containerName)
            return false
        end
        printf_log('No %s found - buying one...', containerName)
        -- Bank first: we likely have one banked from a past run - pull it before hitting a vendor
        -- (faster, and it's ours). Try variants in buy-order preference. FindItemBankCount reads the
        -- real banked count remotely, so only attempt the pull for a variant that's actually banked -
        -- no walk to an empty bank (withdraw_count also self-guards on the same remote read).
        for _, v in ipairs(cfg.buyOrder) do
            local okc, c = pcall(function() return mq.TLO.FindItemBankCount('=' .. v)() end)
            local maybe = okc and type(c) == 'number' and c > 0
            if maybe and state.withdraw_count(v, 1) > 0 then
                kitName = v
                printf_log('Pulled %s from the bank (skipping vendor buy).', kitName)
                break
            end
        end
        -- Prefer a kit vendor who actually SELLS one of our kit variants in THIS zone, before
        -- traveling. The vendors list is preference-ordered, not distance-ordered, so a first-listed
        -- out-of-zone vendor triggers a zone hop even when another copy is standing right here.
        -- Note it must be "sells it here", not merely "exists here": Jaren Cloudchaser is in Marr
        -- (arrow mats only) AND in PoK (kits) - going to the Marr one would just waste a trip.
        local function sells_kit_here(vname)
            local cz = current_zone()
            for _, buyName in ipairs(cfg.buyOrder) do
                for _, inst in ipairs((state.vendorMap or {})[buyName] or {}) do
                    if inst.name == vname and inst.zone == cz then return true end
                end
            end
            return false
        end
        local vendorOrder = {}
        for _, vname in ipairs(cfg.vendors) do
            if sells_kit_here(vname) then vendorOrder[#vendorOrder + 1] = vname end
        end
        for _, vname in ipairs(cfg.vendors) do
            if not sells_kit_here(vname) then vendorOrder[#vendorOrder + 1] = vname end
        end
        for _, vname in ipairs(vendorOrder) do
            if kitName then break end   -- already pulled one from the bank
            -- The kit vendor may live in another zone (e.g. the research kit vendors
            -- are in PoK); hop there first rather than only buying if the vendor
            -- happens to be in the current zone. Skip a vendor we can't reach.
            -- Travel to the zone where THIS vendor sells a kit (prefer here if he sells it here).
            -- Falls back to his known zone if merchants.ini has no kit line for him.
            local vzone
            do
                local cz = current_zone()
                for _, buyName in ipairs(cfg.buyOrder) do
                    for _, inst in ipairs((state.vendorMap or {})[buyName] or {}) do
                        if inst.name == vname and inst.zone then
                            if inst.zone == cz then vzone = cz break end
                            vzone = vzone or inst.zone
                        end
                    end
                    if vzone == cz then break end
                end
                vzone = vzone or state.vendor_zone_for(vname)
            end
            local reachable = (not vzone) or vzone == current_zone() or state.travel_to_zone(vzone)
            if reachable then
                local sp = mq.TLO.Spawn(string.format('npc "%s"', vname))
                if (sp.ID() or 0) > 0 then
                    if nav_to_spawn(sp.ID(), vname) and open_merchant(vname) then
                        for _, buyName in ipairs(cfg.buyOrder) do
                            if buy_item(buyName, 1) then
                                kitName = buyName
                                break
                            end
                        end
                        close_merchant()
                    end
                end
            end
            if kitName then break end
        end
        if not kitName then
            printf_log('ERROR: could not buy %s.', containerName)
            return false
        end
        -- Get its slot after buying
        local kit = mq.TLO.FindItem('=' .. kitName)
        kitSlot = kit.ItemSlot() or 0
    end

    if kitSlot == 0 then
        printf_log('ERROR: cannot find %s in inventory.', kitName)
        return false
    end

    printf_log('Moving %s to pack%d...', kitName, kitPack)

    -- Remember whatever currently lives in the kit pack (normally a storage bag) so we can put it
    -- back when the run goes idle. First swap of the run wins; nil = not yet recorded, '' = nothing
    -- was there. The swap below parks this bag in another top-level slot and leaves the kit here.
    if state.kitPackOriginalBag == nil then
        state.kitPackOriginalBag = mq.TLO.Me.Inventory('pack' .. kitPack).Name() or ''
    end

    -- Park the cursor's bag into the first EMPTY top-level inventory slot (a general pack
    -- position 1-10 that holds nothing). A FULL bag relocates to a top-level slot fine - only
    -- NESTING a full bag fails - so we never have to empty pack<kitPack>'s current bag first,
    -- we just move it whole. Skips the kit pack itself.
    local function park_bag_in_empty_toplevel(exclude)
        for i = 1, 10 do
            if i ~= exclude and (mq.TLO.Me.Inventory('pack' .. i).ID() or 0) == 0 then
                mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', i)
                mq.delay(500, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                if (mq.TLO.Cursor.ID() or 0) == 0 then return true end
            end
        end
        return false
    end

    -- Fallback for a TRULY full inventory (every top-level slot already holds a bag). We can't
    -- relocate pack<kitPack>'s current bag whole, so free pack<kitPack> the slow-but-reliable
    -- way: empty that bag's contents into other bags' free inner slots, then nest the now-EMPTY
    -- bag into the first free bag slot (skipping the TS bag and pack<kitPack> itself). An empty
    -- bag nests where a full one can't. Returns true if pack<kitPack> ends up free.
    local function empty_and_nest_occupant(kp)
        local occ = mq.TLO.Me.Inventory('pack' .. kp)
        if (occ.ID() or 0) == 0 then return true end  -- already empty
        -- 1) empty its contents into OTHER bags' free inner slots. We deliberately do NOT use
        --    /autoinventory here: it drops the item into the FIRST free slot, which is usually
        --    another empty slot in THIS same bag, so the bag never actually empties. Placing
        --    explicitly into a different bag guarantees each item leaves pack<kp>. (This is the
        --    bug that left a "ten bags, none full" inventory unable to seat the combine kit.)
        local function drop_into_other_bag()
            for i = 1, 10 do
                if i ~= kp then
                    local bag = mq.TLO.Me.Inventory('pack' .. i)
                    for ts = 1, (bag.Container() or 0) do
                        if (bag.Item(ts).ID() or 0) == 0 then
                            mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', i, ts)
                            mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                            if (mq.TLO.Cursor.ID() or 0) == 0 then return true end
                        end
                    end
                end
            end
            return false
        end
        for s = 1, (occ.Container() or 0) do
            if (occ.Item(s).ID() or 0) > 0 then
                mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', kp, s)
                mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
                if (mq.TLO.Cursor.ID() or 0) > 0 and not drop_into_other_bag() then
                    -- genuinely nowhere else to put it; stow it and let the empty-check below bail
                    mq.cmd('/autoinventory')
                    mq.delay(AUTOINV_PACE_MS, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                end
            end
        end
        -- bail if it still isn't empty (no free inner slots anywhere to take its contents)
        local occ2 = mq.TLO.Me.Inventory('pack' .. kp)
        for s = 1, (occ2.Container() or 0) do
            if (occ2.Item(s).ID() or 0) > 0 then return false end
        end
        -- 2) pick up the now-empty bag
        mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', kp)
        mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
        if (mq.TLO.Cursor.ID() or 0) == 0 then return false end
        -- 3) nest it into the first free bag slot (not the TS bag, not pack<kitPack>)
        for i = 1, 10 do
            if i ~= kp then
                local bag = mq.TLO.Me.Inventory('pack' .. i)
                if (bag.Name() or '') ~= TS_BAG_NAME then
                    for s = 1, (bag.Container() or 0) do
                        if (bag.Item(s).ID() or 0) == 0 then
                            mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', i, s)
                            mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                            if (mq.TLO.Cursor.ID() or 0) == 0 then return true end
                        end
                    end
                end
            end
        end
        return false  -- nowhere to nest it
    end

    -- If pack<kitPack> holds a bag and there's NO empty top-level slot to relocate it to, free
    -- pack<kitPack> up front (empty + nest its bag) so the swap below has nothing to strand on
    -- the cursor. Done before we pick up the kit because a bag can't be emptied from the cursor.
    do
        local occupied = (mq.TLO.Me.Inventory('pack' .. kitPack).ID() or 0) > 0
        local hasEmptyTop = false
        for i = 1, 10 do
            if i ~= kitPack and (mq.TLO.Me.Inventory('pack' .. i).ID() or 0) == 0 then hasEmptyTop = true; break end
        end
        if occupied and not hasEmptyTop then
            -- PRE-FLIGHT CAPACITY CHECK. Emptying pack<kitPack>'s bag means relocating everything inside
            -- it into free slots of the OTHER bags (not the TS bag, not pack<kitPack> itself). Count what
            -- has to move vs. the free slots available to take it, up front - so if it can't possibly fit
            -- we say "clear some bag space" immediately instead of half-moving items and failing mid-swap.
            local occBag = mq.TLO.Me.Inventory('pack' .. kitPack)
            local toRelocate = 0
            for s = 1, (occBag.Container() or 0) do
                if (occBag.Item(s).ID() or 0) > 0 then toRelocate = toRelocate + 1 end
            end
            local freeElsewhere = 0
            for i = 1, 10 do
                if i ~= kitPack then
                    local bag = mq.TLO.Me.Inventory('pack' .. i)
                    if (bag.ID() or 0) > 0 and (bag.Name() or '') ~= TS_BAG_NAME then
                        for s = 1, (bag.Container() or 0) do
                            if (bag.Item(s).ID() or 0) == 0 then freeElsewhere = freeElsewhere + 1 end
                        end
                    end
                end
            end
            if freeElsewhere < toRelocate then
                printf_log('\arNot enough bag space to make room for the kit: pack%d\'s bag holds %d item(s) but only %d free slot(s) elsewhere to move them to. Clear some bag space and Start again.\ax',
                    kitPack, toRelocate, freeElsewhere)
                return false
            end
            if not empty_and_nest_occupant(kitPack) then
                printf_log('\arCouldn\'t free pack%d for the kit even though space looked sufficient - clear some bag space and Start again.\ax', kitPack)
                return false
            end
        end
    end

    -- Step 1: Find kit's current location
    local kit = mq.TLO.FindItem('=' .. kitName)
    local itemSlot  = kit.ItemSlot() or 0   -- bag slot (22+n)
    local itemSlot2 = kit.ItemSlot2() or -1  -- slot within bag (-1 = is the bag itself)

    if itemSlot == 0 then
        printf_log('ERROR: cannot find %s in inventory.', kitName)
        return false
    end

    local bagNum = itemSlot - 22  -- which pack (1-10)

    -- Step 2: Pick up the kit
    if itemSlot2 >= 0 then
        -- Kit is inside a bag - use "in pack# slot#" notation
        mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', bagNum, itemSlot2 + 1)
    elseif bagNum >= 1 and bagNum <= 10 then
        -- Kit IS a bag in a pack slot
        mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', bagNum)
    else
        mq.cmdf('/nomodkey /itemnotify %d leftmouseup', itemSlot)
    end
    mq.delay(500, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)

    if (mq.TLO.Cursor.ID() or 0) == 0 then
        printf_log('ERROR: failed to pick up %s.', kitName)
        return false
    end

    -- Step 3: Click slot 10 - swaps kit into slot, puts old bag on cursor
    mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', kitPack)
    mq.delay(500, function() return (mq.TLO.Cursor.ID() or 0) > 0 or kit_in_pack() end)

    -- Step 4: If the swap put a displaced bag on the cursor, relocate it WHOLE into an empty
    -- top-level slot - no emptying, no nesting. Picking the kit up in Step 2 freed its old
    -- slot, so a top-level kit's vacated spot is itself a valid landing slot. If there's
    -- genuinely no empty top-level slot, the swap can't finish - warn clearly and leave the
    -- bag on the cursor rather than dropping it onto something.
    if (mq.TLO.Cursor.ID() or 0) > 0 then
        if not park_bag_in_empty_toplevel(kitPack) then
            printf_log('WARNING: pack%d held a bag and there is no empty top-level inventory slot to move it to - free one general slot and retry. (Its bag is on your cursor.)', kitPack)
        end
    end

    if kit_in_pack() then
        printf_log('%s placed in pack%d.', kitName, kitPack)
        return true
    end

    printf_log('ERROR: failed to place %s in pack%d.', kitName, kitPack)
    return false
end

local function run_engine(job)
    -- Clear any leftover Stop from a PREVIOUS run FIRST. The supply-from-group pass below calls
    -- check_stop(), but the main reset is LOWER DOWN (after that pass). Without clearing here, a stale
    -- stopRequested (e.g. from a prior crash or Stop) aborts the supply phase on the very NEXT run,
    -- before the reset can clear it - a crash loop that halts at the same spot every run and pulls
    -- zero items. Clearing here does NOT swallow stops raised DURING this run (bank pre-pass, etc.).
    state.stopRequested = false
    -- Disabled recipes ("Not Enabled" on Lazarus) are archived in the ini but can
    -- never be crafted - refuse before doing any work.
    if job.recipe and job.recipe.disabled then
        printf_log('Recipe "%s" is disabled (Not Enabled on Lazarus) - cannot craft.', job.recipe.name or '?')
        return
    end

    -- BANK PRE-PASS - must run FIRST, before the dropped-mat check below (which otherwise aborts on
    -- "have 0" for mats sitting in the bank). Pulls everything this tree needs that we already own
    -- banked - trophies, returned tools, dropped/vendor mats, and finished subcombines - in one trip,
    -- only the shortfall. Runs for every craft path including research (which calls run_engine).
    -- runIsLeveling MUST be set before this: the pre-pass skips trophies on leveling runs, and it used
    -- to read a stale value (set 60+ lines below), so a leveling run wrongly demanded a capped-skill
    -- subcombine's trophy (e.g. a Tailoring trophy while leveling Baking).
    state.runIsLeveling = (job.leveling == true)
    if job.recipe and not state.ensure_trophies_for_tree(job.recipe, job.quantity or 1) then return end

    -- Craft-tab "Supply from group members": before crafting, ask the group for EVERY ingredient we're
    -- short on (vendor-buyable AND dropped), not just dropped mats. A fast /ts_check sweep finds who has
    -- what in ~1s; we deliver only what someone actually holds and let the buy pass / craft cover the
    -- rest. No Marr trip - members just need to be in our current zone (they deliver in-zone).
    if job.supplyFromGroup and job.recipe then
        local NO_GROUP_TRADE = { ['water flask'] = true }
        local combines = (job.supplyMode == 'all') and 1000000 or (job.quantity or 1)

        -- Ask the group for a set of item names, pull whatever members hold into our inventory.
        -- Returns how many item TYPES we actually received (so the caller can log / decide to re-plan).
        -- wantOf(nm) supplies the target quantity per item for the given plan.
        local function ask_and_pull(names, wantOf, label)
            local list = {}
            for _, nm in ipairs(names) do
                if not NO_GROUP_TRADE[nm:lower()] and not SUPPLY_IGNORE[tostring(nm):lower()] then
                    list[#list + 1] = nm
                end
            end
            if #list == 0 then return 0 end
            printf_log('Checking the group (%s) for %d item type(s)...', label, #list)

            -- Per-item goal, captured BEFORE any delivery: target TOTAL on-hand = current + what the
            -- plan wants. Same-zone and reachable-network sourcing share this one goal, and "short" is
            -- always measured against it, so we can tell what actually arrived.
            local startCount, target = {}, {}
            for _, nm in ipairs(list) do
                startCount[nm] = item_count(nm)
                target[nm] = startCount[nm] + (wantOf(nm) or 0)
            end

            -- 1) SAME-ZONE sweep (fast batched listener check); deliver whatever in-zone holders have.
            local avail = group_check(list)
            local toGet = {}
            for _, nm in ipairs(list) do
                if avail[nm] and avail[nm] > 0 then
                    toGet[#toGet + 1] = { name = nm, needed = target[nm], mode = 'stack' }
                    -- show WHO holds it (from availHolders) so an attribution bug is visible directly in
                    -- the log, before delivery even picks a mule.
                    local hs = {}
                    for h, q in pairs(state.availHolders[nm] or {}) do hs[#hs + 1] = ('%s:%d'):format(h, q) end
                    printf_log('  group has %s (%d available: %s) - requesting.', nm, avail[nm], table.concat(hs, ', '))
                end
            end
            if #toGet > 0 then
                for _, it in ipairs(toGet) do supplyExhausted[it.name] = nil end
                local byHolder = {}
                for _, it in ipairs(toGet) do
                    local holders = state.availHolders[it.name] or {}
                    local best, bestQty = nil, 0
                    for hn, hq in pairs(holders) do
                        if hq > bestQty then best, bestQty = hn, hq end
                    end
                    if best then byHolder[best] = byHolder[best] or {}; byHolder[best][#byHolder[best] + 1] = it end
                end
                if next(byHolder) then
                    for holder, itemsForHolder in pairs(byHolder) do
                        state.request_supply_grouped(itemsForHolder, holder)
                    end
                else
                    state.request_supply_grouped(toGet, nil)
                end
            end

            -- 2) REACHABILITY-FIRST escalation, BATCHED. Gather every item still short of target into
            -- ONE list and hand it to cross_zone_supply_grouped: one network sweep, group holders by
            -- zone, travel to each zone ONCE and pull everything a holder has in a single trade. This
            -- is what stops the PoK->Marr->PoK->Marr bounce of traveling to a bot per single item.
            -- Buyable never gates whether we ask; it only decides the vendor fallback afterward.
            if state.crossZoneSupply and not state._inCrossZone then
                local shortItems = {}
                for _, nm in ipairs(list) do
                    if item_count(nm) < target[nm] then
                        shortItems[#shortItems + 1] = { name = nm, needed = target[nm] }
                    end
                end
                if #shortItems > 0 then
                    state._inCrossZone = true
                    pcall(function() state.cross_zone_supply_grouped(shortItems) end)
                    state._inCrossZone = false
                end
            end

            -- Item types we actually gained stock on (re-plan signal for the caller).
            local got = 0
            for _, nm in ipairs(list) do if item_count(nm) > startCount[nm] then got = got + 1 end end
            return got
        end

        -- PHASE 1: the highest-value asks - the intermediate SUBCOMBINE products we'd otherwise craft
        -- (plan.makeQty) plus dropped mats (supplyDemand). If a mule hands over a finished intermediate
        -- (e.g. leftover Jumjum Cake), we skip crafting its ENTIRE sub-tree. Ask top-down first so we
        -- don't waste requests on sub-ingredients of something already supplied.
        -- Plan on the section KEY, not the display name. Gem-variant idols (Amber/Emerald/Ivory/...) all
        -- share Name="Unfired Idol", so plan_requirements(job.recipe.name) resolves to the FIRST such
        -- section (the base Imbued Ivory one) and the supply pass asks for the WRONG gem. job.recipe.key
        -- is the exact section we're crafting, so supply and craft agree. (Matches the craft-side calls.)
        local okp, plan = pcall(function() return plan_requirements(job.recipe.key or job.recipe.name, combines) end)
        if okp and plan then
            -- FIRST CHECK: do we already hold every GROUP-SUPPLIABLE leaf (the dropped + vendor mats a
            -- mule could actually hand over)? If so the group has nothing to add - skip the whole dance
            -- instead of asking around only to conclude "we've got it." Non-tradeable leaves (water flask
            -- etc.) are ignored here since the buy pass covers those regardless. supplyMode 'all' inflates
            -- demand past any on-hand count, so this never fires there (it keeps sourcing, as intended).
            local function _gtradeable(nm)
                return not NO_GROUP_TRADE[nm:lower()] and not SUPPLY_IGNORE[tostring(nm):lower()]
            end
            local haveAll = true
            for nm, q in pairs(plan.supplyDemand or {}) do
                if q > 0 and _gtradeable(nm) and item_count(nm) < q then haveAll = false; break end
            end
            if haveAll then
                for nm, q in pairs(plan.buyDemand or {}) do
                    if q > 0 and _gtradeable(nm) and item_count(nm) < q then haveAll = false; break end
                end
            end
            if haveAll then
                printf_log('Already have every ingredient on hand - skipping the group-supply step.')
            else
            local phase1 = {}
            for nm, q in pairs(plan.makeQty or {}) do if q > 0 then phase1[#phase1 + 1] = nm end end
            for nm, q in pairs(plan.supplyDemand or {}) do if q > 0 then phase1[#phase1 + 1] = nm end end
            local got1 = ask_and_pull(phase1, function(nm)
                -- Return the ADDITIONAL amount to request (net of on-hand). makeQty is already netted
                -- against on-hand+bank; supplyDemand is the GROSS recipe total, so subtract what we
                -- already have or we'd ask the group for a full batch of a mat we already hold enough of.
                if plan.makeQty and plan.makeQty[nm] then return plan.makeQty[nm] end
                local gross = plan.supplyDemand and plan.supplyDemand[nm]
                if gross then return math.max(0, gross - item_count(nm)) end
                return 0
            end, 'intermediates')

            -- RE-PLAN after phase 1. netWalk already prunes any subtree whose product is now on-hand,
            -- so receiving Jumjum Cake means the re-plan no longer lists Clump of Dough / Frosting / Cake
            -- Round / etc. We only ask phase 2 for what's genuinely still needed.
            local plan2 = plan
            if got1 > 0 then
                local okp2, p2 = pcall(function() return plan_requirements(job.recipe.key or job.recipe.name, combines) end)
                if okp2 and p2 then plan2 = p2 end
            end

            -- PHASE 2: the base ingredients still needed after pruning - vendor items (buyDemand) and any
            -- remaining dropped/intermediate mats the group might still cover.
            local phase2 = {}
            for nm, q in pairs(plan2.buyDemand or {}) do if q > 0 then phase2[#phase2 + 1] = nm end end
            for nm, q in pairs(plan2.supplyDemand or {}) do if q > 0 then phase2[#phase2 + 1] = nm end end
            for nm, q in pairs(plan2.makeQty or {}) do if q > 0 then phase2[#phase2 + 1] = nm end end
            ask_and_pull(phase2, function(nm)
                -- Net GROSS demand (buy/supply recipe totals) against on-hand; makeQty is already netted.
                local gross = (plan2.buyDemand and plan2.buyDemand[nm]) or (plan2.supplyDemand and plan2.supplyDemand[nm])
                if gross then return math.max(0, gross - item_count(nm)) end
                if plan2.makeQty and plan2.makeQty[nm] then return plan2.makeQty[nm] end
                return 0
            end, 'remaining')

            printf_log('Group hand-off complete - crafting with what we received; buy pass covers the rest.')
            end
        end
    end

    -- Cap the run to the dropped/farmed mats actually on hand right now, so the buy
    -- pass never buys vendor mats for combines we can't make. This is the single
    -- chokepoint that enforces "only buy if we have combines, and only as many as we
    -- can combine" for EVERY path (manual Craft included, which isn't otherwise
    -- capped). Vendor-only recipes have no dropped ingredient, so avail == math.huge
    -- and nothing changes. Re-checked here (not just at advance time) so it uses the
    -- freshest count right before buying.
    if job.recipe then
        local avail = dropped_combines_available(job.recipe)
        if avail ~= math.huge then
            if avail < 1 then
                -- Use the shared missingMats helper (same one the preflight uses) so this run-time message
                -- matches what you saw before pressing Start: a clear list of the DROPPED mats that are
                -- short, recursing through subcombines. Vendor items are excluded (they auto-buy).
                local short = state.missingMats(job.recipe)
                if #short > 0 then
                    printf_log('\arCannot craft %s - missing dropped mats:\ax', job.recipe.name or '?')
                    for _, line in ipairs(short) do printf_log('   \ay- %s\ax', line) end
                    -- Mark this recipe supply-failed so leveling SKIPS it next pass instead of re-selecting
                    -- it forever. Without this, level_group_select's narrow dropped-shortfall check can say
                    -- "group can supply" while run_engine's full ingredient-tree check finds nothing on hand
                    -- - the two disagree and the recipe gets picked, fails here, picked again... (the Misty
                    -- Thicket Picnic loop: Brownie Parts/Fruit that no one actually has).
                    if job.leveling and job.recipe and job.recipe.name then
                        state.levelSupplyFailed = state.levelSupplyFailed or {}
                        state.levelSupplyFailed[job.recipe.name] = true
                    end
                else
                    printf_log('No dropped mats on hand for %s - nothing to combine, skipping.', job.recipe.name or '?')
                    if job.leveling and job.recipe and job.recipe.name then
                        state.levelSupplyFailed = state.levelSupplyFailed or {}
                        state.levelSupplyFailed[job.recipe.name] = true
                    end
                end
                return
            end
            if (job.quantity or 0) > avail then
                printf_log('Limiting %s to %d (dropped mats on hand) - only buying what we can combine.', job.recipe.name or '?', avail)
                job.quantity = avail
            end
        end
    end

    -- Preflight: crafting needs a little bag headroom - to park pack10's bag while staging the
    -- kit, and to catch each combine's product/returns. If inventory is nearly full, bail NOW
    -- rather than buying a kit we then can't stage and thrashing (pack10 park fails; combine
    -- salvage strands on the cursor and later combines misplace ingredients).
    if free_slots() < 3 then
        printf_log('\arInventory too full to craft: %d free bag slot(s), need at least 3. Free up space and restart.\ax', free_slots())
        return
    end

    state.busy = true
    state.stopRequested = false
    state.savedSlots = {}     -- fresh slot record for this run (trophy/modifier ammo swaps)
    state.draughtUsedThisRun = false   -- allow one Draught of the Craftsman click this run
    state.runIsLeveling = (job.leveling == true)   -- leveling-tab runs skip trophies entirely
    -- ...but DO wear the optional +5% leveling modifier for this skill, if you own one.
    if state.runIsLeveling then
        state.ensure_leveling_modifier(state.skill_name_for_recipe(job.itemName))
    end
    state.bankSeenThisRun = false                  -- re-verify bank contents once per run
    state._bankCache = nil                          -- drop any cached closed-bank counts from a prior run
    state.afkTier = 0                              -- try regular stations first each run; escalate to AFK mirrors only if all are in use
    -- (E3 is paused by the job dispatcher for the whole action, so no per-run toggle here.)
    state.doneCount = 0
    state.totalCount = job.quantity
    state.log = {}
    supplyExhausted = {}  -- reset per run

    -- Defensively close any open world container from a previous run
    close_world_container()
    close_merchant()

    -- Session tracking
    local eqSkillName = job.skillSection and job.skillSection.Skill
    if not state.sessionStarted then
        state.sessionStarted = true
        state.sessionSkillName = eqSkillName
        state.sessionSkillStart = eqSkillName and skill_value(eqSkillName) or nil
        state.sessionMade = 0
        state.sessionFailed = 0
        state.sessionFizzles = 0
        state.sessionDesyncs = 0
        state.sessionStartTime = mq.gettime()
        state.sessionLastSkill = state.sessionSkillStart
    end

    local ok, err = pcall(function()
        local skillSec = job.skillSection
        local rec = job.recipe
        local vendorName = skillSec.Vendor
        local kitPack = job.kitPack or KIT_PACK_DEFAULT

        -- Resolve container. Research recipes are keyed [Recipe:<name>##<class>] and
        -- Name=-overridden recipes (e.g. the deity idols, all named "Unfired Idol") have a
        -- section key that differs from rec.name, so look up by the section KEY. The job may
        -- also pass the resolved section directly in recipeSection.
        local recSec = job.recipeSection or (state.iniSections or {})['Recipe:' .. (rec.key or rec.name)]
        if not recSec or not recSec.Container then
            printf_log('ERROR: [Recipe:%s] has no Container= defined.', rec.key or rec.name)
            return
        end
        -- For a configured inventory kit, stage it into the canonical slot first (buy if
        -- missing, else clear that slot and move it in) - same as execute_recipe, so a
        -- combine never depends on the user having pre-placed the kit. No-op for world
        -- containers and non-configured kits.
        if trim(recSec.ContainerType or 'inventory'):lower() == 'inventory' then
            ensure_kit_in_pack(recSec.Container or '', KIT_PACK_DEFAULT)
        end
        local cinfo = resolve_container_info(recSec, kitPack)
        if not cinfo then
            local containerName = recSec.Container or ''
            -- Last resort if the staging above didn't apply (e.g. non-configured kit).
            if ensure_kit_in_pack(containerName, kitPack) then
                cinfo = resolve_container_info(recSec, kitPack)
            end
            if not cinfo then
                -- ensure_kit_in_pack already logged the specific reason (usually the bag-space capacity
                -- message). Full bags won't fix themselves on a retry, and leveling would otherwise
                -- re-select this same rung and spin forever (the "musical bags" loop). Hard-stop the run.
                printf_log('\arStopping: couldn\'t place %s in slot %d (see the reason above).\ax', containerName, kitPack)
                state.stopRequested = true
                state.levelRunning = false
                state.queueRunning = false
                return
            end
        end
        if cinfo.pack then kitPack = cinfo.pack end

        -- Open/clear inventory container upfront
        if cinfo.type == 'inventory' then
            if not open_kit(cinfo, kitPack) then return end
            clear_kit(cinfo, kitPack, 10)
            printf_log('%s ready.', cinfo.name)
        else
            printf_log('Will navigate to %s after buying ingredients.', cinfo.name)
        end

        -- invSlots: nil for world containers, kitPack number for inventory containers
        -- invSlots: nil for world containers, kitPack number for inventory containers.
        -- NOTE: must be a real if/else -- the `x and nil or kitPack` idiom is broken
        -- because nil is falsy, so it always fell through to kitPack and world crafts
        -- wrongly subtracted slot-10's bag from the free count (false 0 / sell loop).
        local invSlots
        if cinfo.type == 'world' then invSlots = nil else invSlots = kitPack end

        -- One-pass net-requirements plan: the single bill of materials for the whole tree,
        -- netted against what's already in the bags. Drives both the production cap and the
        -- vendor pre-buy, so the two can never disagree about what gets made vs bought.
        local plan = plan_requirements(rec.key or rec.name, job.quantity)
        if not plan then
            printf_log('ERROR: no recipe for %s - aborting.', rec.name)
            return
        end

        -- Cap the run to what the scarcest non-purchasable (dropped/foraged/summoned/caster-
        -- made) mat allows, crediting on-hand subcombine product. If we can't make even one
        -- combine of something required, stop now with one clear error BEFORE any vendor trip.
        do
            -- A reduce-chain form (velium etc.) can be obtained by chiselling down on-hand BIGGER
            -- forms too, so count that reducible stock as available - otherwise a run off a farmed
            -- Block of Velium would wrongly abort as "missing Small Brick". Each bigger unit reduces
            -- to `yield` of this form, recursively up the chain. Execution then reduces on demand.
            local function reducible_have(form, seen)
                local have = item_count(form)
                local rc = state.reduceChains and state.reduceChains[form]
                if rc then
                    seen = seen or {}
                    if not seen[form] then
                        seen[form] = true
                        local rr = state._rawRecipe(rc.section)
                        local y = (rr and rr.yield) or 2
                        have = have + y * reducible_have(rc.from, seen)
                    end
                end
                return have
            end
            local missing, capMat, capQty = {}, nil, job.quantity
            for nm, pruned in pairs(plan.supplyDemand) do
                local gross = plan.grossSupply[nm] or pruned
                if gross > 0 then
                    -- maxT solves perCombine*T - savedByOnHandSubcombines <= have(nm), where
                    -- perCombine = gross/job.quantity and saved = gross - pruned. So on-hand
                    -- subcombines (which need no more of this mat) raise the achievable count.
                    local haveNm = reducible_have(nm)
                    local maxT = math.floor((haveNm + gross - pruned) * job.quantity / gross)
                    if maxT < 1 then
                        -- Tailor the guidance: a |dropped item that's also in MAKEABLE is
                        -- caster-SUMMONED, so point at the Request tab and the producing class.
                        -- Otherwise it's foraged/dropped and has to be brought from a mule.
                        local cls
                        for _, m in ipairs(MAKEABLE) do
                            if m.item:lower() == nm:lower() then cls = m.class; break end
                        end
                        if cls then
                            missing[#missing + 1] = string.format(
                                'Missing %s, summoned - make it via the Request tab (Make, then Bring); producer class: %s.', nm, cls)
                        else
                            missing[#missing + 1] = string.format(
                                'Missing %s, dropped - forage it, or pull it from a mule via the Request tab (Bring).', nm)
                        end
                    elseif maxT < capQty then
                        capQty, capMat = maxT, nm
                    end
                end
            end
            if #missing > 0 then
                for _, msg in ipairs(missing) do printf_log('%s', msg) end
                -- Before giving up: actually ASK the group for the missing dropped/supply mats (the
                -- Frying Pan Mold on a can't-buy crafter lands here). Without this the leveling advance
                -- just re-planned the same recipe every cycle - nine "Missing Frying Pan Mold" in ten
                -- seconds - instead of pulling it from a mule once. Same grouped request as pre-load.
                local reqItems = {}
                for nm, pruned in pairs(plan.supplyDemand) do
                    local gross = plan.grossSupply[nm] or pruned
                    if gross > 0 and reducible_have(nm) + (gross - pruned) < gross then
                        reqItems[#reqItems + 1] = { name = nm, needed = item_count(nm) + 1, mode = 'stack' }
                    end
                end
                if #reqItems > 0 and state.request_supply_grouped then
                    if current_zone() ~= ZONE_MARR then
                        printf_log('Traveling to Marr to receive the missing mat(s) from the group...')
                        travel_to_marr()
                    end
                    if current_zone() == ZONE_MARR then
                        printf_log('Requesting the missing mat(s) from the group before giving up...')
                        pcall(function() state.request_supply_grouped(reqItems, nil) end)
                    end
                    -- Re-check: if the group came through, fall through and craft; else abort for real.
                    local stillShort = false
                    for _, it in ipairs(reqItems) do
                        if item_count(it.name) < 1 then stillShort = true; break end
                    end
                    if not stillShort then
                        printf_log('Group supplied the missing mat(s) - continuing.')
                        plan = plan_requirements(rec.key or rec.name, job.quantity)
                    else
                        printf_log('Aborting - group could not supply, load the missing item(s) above and try again.')
                        return
                    end
                else
                    printf_log('Aborting - load the missing item(s) above and try again.')
                    return
                end
            end
            if capQty < job.quantity then
                printf_log('Capping run to %d (limited by %s: have %d). Re-planning buys for %d.',
                    capQty, capMat, item_count(capMat), capQty)
                job.quantity = capQty
                plan = plan_requirements(rec.key or rec.name, job.quantity)   -- "subtract once more" at the capped qty
            end
        end

        -- Preflight manifest: the whole run laid out before a single platinum is spent.
        do
            printf_log('--- Plan: %d x %s ---', job.quantity, rec.name)
            local mk = {}
            for nm, q in pairs(plan.makeQty) do
                if q > 0 then mk[#mk + 1] = string.format('%d %s', q, nm) end
            end
            table.sort(mk)
            if #mk > 0 then printf_log('  MAKE:   %s', table.concat(mk, ', ')) end
            local bp = {}
            for nm, q in pairs(plan.buyDemand) do
                local short = q - item_count(nm)
                if short > 0 then bp[#bp + 1] = string.format('%d %s', short, nm) end
            end
            table.sort(bp)
            if #bp > 0 then printf_log('  BUY:    %s', table.concat(bp, ', ')) end
            -- Cost estimate: sum (units to buy over the whole run) x (scanned price). buyDemand is the
            -- full run demand, so this is the total spend, not just the shortfall we're topping up now.
            -- Only counts items whose price we've scanned; flags how many of the buy items are priced so
            -- a partial total never masquerades as complete.
            do
                local totalCp, priced, totalItems = 0, 0, 0
                for nm, q in pairs(plan.buyDemand) do
                    if q > 0 then
                        totalItems = totalItems + 1
                        local info = (state.itemInfo or {})[nm]
                        if info and info.price and info.price > 0 then
                            totalCp = totalCp + info.price * q
                            priced = priced + 1
                        end
                    end
                end
                if totalItems > 0 and priced > 0 then
                    local pp = math.floor(totalCp / 1000)
                    local note = (priced < totalItems) and string.format(' (%d of %d items priced)', priced, totalItems) or ''
                    printf_log('  COST:   ~%s pp%s', tostring(pp), note)
                end
            end
            local sp = {}
            for nm, q in pairs(plan.supplyDemand) do
                if q > 0 then
                    local cls
                    for _, m in ipairs(MAKEABLE) do
                        if m.item:lower() == nm:lower() then cls = m.class; break end
                    end
                    local src = cls and ('summoned, ' .. cls) or 'dropped'
                    sp[#sp + 1] = string.format('%s (%s; have %d, need %d)', nm, src, item_count(nm), q)
                end
            end
            table.sort(sp)
            if #sp > 0 then printf_log('  SUPPLY: %s', table.concat(sp, ', ')) end
        end

        -- AFFORDABILITY GATE. Before spending any travel/buy time, check we can pay for this run's buy
        -- pass with coin on hand (plat+gold+silver+copper). Only a COMPLETE price estimate that exceeds
        -- coin blocks; a partial estimate warns and proceeds (per config). Craft-tab: abort the run.
        -- Leveling: this rung is the first we can't afford - stop the run cleanly (everything up to here
        -- was already crafted), so leveling "does everything it can, then fails at the unaffordable rung."
        do
            local affordable, msg = state.can_afford_plan(rec.key or rec.name, job.quantity or 1)
            if affordable then
                if msg then printf_log('\ayNote: %s - proceeding anyway.\ax', msg) end   -- partial-estimate warning
            else
                if job.leveling then
                    printf_log('\arLeveling stop: can\'t afford %s (%s). Crafted everything affordable up to here.\ax', rec.name, msg or 'insufficient coin')
                    state.levelRunning = false
                else
                    printf_log('\arCan\'t afford this run: %s (%s). Sell some goods or lower the quantity, then try again.\ax', rec.name, msg or 'insufficient coin')
                end
                return
            end
        end

        -- Pick ONE zone for the whole run (stay in the current zone if it stocks everything, else
        -- prefer Marr, then PoK) and go there BEFORE buying, so the pre-buy stays in one zone
        -- instead of bouncing, and the oven follows (the world-station nav re-prefers the current
        -- zone). Only forces a zone if that zone stocks everything we need to buy; otherwise leaves
        -- the normal per-item routing to handle a genuine split.
        do
            local buyList = {}
            for nm, q in pairs(plan.buyDemand) do
                if (q - item_count(nm)) > 0 then buyList[#buyList + 1] = nm end
            end
            if #buyList > 0 then
                local rz = state.run_zone_for_items(buyList)
                if rz and current_zone() ~= rz then
                    printf_log('Staging the whole run in %s (single zone)...',
                        rz == ZONE_MARR and 'Temple of Marr' or 'Plane of Knowledge')
                    if rz == ZONE_MARR then travel_to_marr() else travel_to_pok() end
                end
            end
        end

        -- One-trip vendor pre-buy: buy every vendor mat the WHOLE tree needs in a single pass
        -- up front (grouped by vendor, so a zone's mats are one stop instead of one trip per
        -- sub-part). buy_pass nets on-hand, so pass quantity=1 against the planned demand; the
        -- per-sub-part buys in the preflight below then find everything on hand and skip.
        do
            local preIngs = {}
            for nm, q in pairs(plan.buyDemand) do
                -- Only pre-buy what we're ACTUALLY still short of. The group hand-off just above may have
                -- delivered part of buyDemand, so listing the stale demand printed 'Pre-buying N' then
                -- immediately 'already have all' - contradictory. Re-check against what's on hand now.
                if item_count(nm) < q then
                    preIngs[#preIngs + 1] = { name = nm, qty = q, buylast = plan.buyLast and plan.buyLast[nm] or false }
                end
            end
            if #preIngs > 0 then
                printf_log('Pre-buying %d vendor mat type(s) in one pass to avoid repeat vendor trips...', #preIngs)
                buy_pass({ name = rec.name, yield = rec.yield, trivial = rec.trivial,
                           sellable = rec.sellable, ingredients = preIngs }, 1, vendorName)
            end
        end

        -- (Bank pre-pass already ran at the top of run_engine - trophies, tools, dropped/vendor mats
        -- and finished subcombines were pulled from the bank there before this preflight.)

        -- Preflight: make subcombines and collect vendor ingredients
        printf_log('Starting preflight ingredient checks...')

        local vendorIngs = {}
        for _, ing in ipairs(rec.ingredients) do
            check_stop()
            if ing.returned then
                -- Keep ONE of a vendor-sold returned tool on hand. It's handed back after
                -- every combine, so a single one cycles indefinitely. The old code bought a
                -- spare because a tool momentarily reads count 0 while on the cursor mid-hand-
                -- back, tripping a spurious "lost it, buy another"; that window is now handled
                -- by state.returned_tool_missing (settle + re-read), so one is enough.
                if (state.vendorMap or {})[ing.name] then
                    if item_count(ing.name) < 1 then
                        vendorIngs[#vendorIngs + 1] = { name = ing.name, qty = 1, absQty = 1, returned = true, buylast = ing.buylast }
                    end
                elseif item_count(ing.name) == 0 then
                    -- Craftable / non-vendor returned item: obtain one now.
                    if not ensure_returned_item(ing.name, kitPack) then
                        printf_log('ERROR: could not obtain returned item %s - aborting.', ing.name)
                        return
                    end
                end
            elseif ing.dropped then
                -- Foraged/dropped mats: never bought, never traveled for. Shortfalls are
                -- reported up front by the tree-wide foraged pre-flight check above, so
                -- there's nothing to do here -- just skip and craft what's on hand.
            elseif (state.vendorMap or {})[ing.name] then
                -- Vendor sold: always buy, even if a recipe also exists
                vendorIngs[#vendorIngs + 1] = ing
            elseif (state.iniSections or {})['Recipe:' .. ing.name] then
                local needed = ing.qty * job.quantity
                if item_count(ing.name) < needed then
                    if not make_subcombine(ing.name, needed, vendorName, kitPack, job.leveling) then
                        -- Partial is fine: craft what the mats allow rather than aborting the run.
                        -- A fizzle can eat a dropped mat and leave the subcombine one short; the
                        -- combine loop stops cleanly when an ingredient runs out and makes fewer.
                        printf_log('Only %d of %d %s - continuing with what we have.',
                            item_count(ing.name), needed, ing.name)
                    end
                end
            else
                -- No vendor and no recipe: this can only come from your bags (a
                -- dropped/farmed mat). Pre-load it via the Request tab; we don't
                -- travel for it. If short, the batch crafts what's on hand and ends.
                local needed = ing.qty * job.quantity
                if item_count(ing.name) < needed then
                    printf_log('%s: have %d of %d - no vendor/recipe, pre-load via the Request tab.',
                        ing.name, item_count(ing.name), needed)
                end
            end
        end

        -- Single upfront buy pass
        if #vendorIngs > 0 then
            local vendorRec = {
                name = rec.name, yield = rec.yield, trivial = rec.trivial,
                sellable = rec.sellable, ingredients = vendorIngs,
            }
            if not buy_pass(vendorRec, job.quantity, vendorName) then
                printf_log('ERROR: buy pass failed - aborting.')
                return
            end
        end

        -- Sanity check: make sure we have enough for at least 1 combine
        for _, ing in ipairs(rec.ingredients) do
            if not ing.returned and item_count(ing.name) < ing.qty then
                -- Deadlock guard: the usual reason a vendor mat is missing here is that the bags
                -- filled during the buy pass before this mat's turn (BUY_THRESHOLD stop), so the
                -- combine can't run, the run aborts, the caller re-plans "buy the rest", the buy
                -- pass refuses (still full), and it loops forever. So when bags are full, don't just
                -- abort: do ONE sell trip to make room. If that frees space, return and let the
                -- caller re-plan + buy the missing mat with the new headroom; if the bags are STILL
                -- full (nothing sellable), hard-stop so it can't retry forever.
                if free_slots(invSlots) <= BUY_THRESHOLD then
                    printf_log('Short %s and bags are full (%d free) - selling %s to make room...',
                        ing.name, free_slots(invSlots), rec.name)
                    if cinfo.type == 'world' then close_world_container() end
                    drain_cursor()
                    close_merchant()
                    local reached, nearName = nav_to_nearest_merchant()
                    if reached and open_merchant(nearName) then
                        sell_item_by_id(rec.name)
                        close_merchant()
                    end
                    if free_slots(invSlots) <= BUY_THRESHOLD then
                        printf_log('\arERROR: bags still full after selling (%d free) - nothing sellable to make room. Stopping so it does not retry the same recipe forever.\ax', free_slots(invSlots))
                        state.stopRequested = true   -- unrecoverable: halt instead of re-planning into the buy/abort loop
                        return
                    end
                    printf_log('Freed space (%d free) - re-planning to buy the rest.', free_slots(invSlots))
                    return
                end
                printf_log('ERROR: not enough %s for even 1 combine (have %d need %d) - aborting.',
                    ing.name, item_count(ing.name), ing.qty)
                -- On a leveling run, mark this recipe skipped so the advance loop moves ON instead of
                -- re-selecting it every cycle (the Barbecue Ribs spin: 24 aborts in 90 seconds). This
                -- aborts at PREFLIGHT, before any combine, so the combine seatbelt never sees it - the
                -- skip has to happen here.
                if job.leveling then
                    state.levelSkip = state.levelSkip or {}
                    state.levelSkip[rec.name] = true
                    printf_log('Skipping %s this run - could not obtain %s.', rec.name, ing.name)
                end
                return
            end
        end

        -- Seat the trophy for the TOP recipe's container now - AFTER subcombines (which may
        -- have swapped in a different skill's trophy, e.g. Barbecue Sauce's Brewing Mug during
        -- a Baking item) and BEFORE we travel to/open the top container. execute_recipe only
        -- hooks subcombines, so this is what makes the top combine use the right trophy (e.g.
        -- swap Brewing Mug -> Baking Rolling Pin for Baked Potato). No-op under 300 or for
        -- containers without a trophy; hard-stops (-> PoK) if a required trophy is missing.
        if not state.ensure_trophy(recSec.Container) then return end

        -- Zone and open world container. The buy pass may have staged us in a zone (e.g. Marr)
        -- that already has this station; stay here instead of trekking to the zone the job
        -- resolved to. navZone is a resolve-time pick and was dragging us to PoK even while we
        -- stood at the Marr oven. Only fall back to navZone if the current zone can't host this
        -- station. (world_open re-prefers the current zone per-location too - belt and suspenders.)
        if cinfo.type == 'world' then
            local cz = current_zone()
            local hereHasStation = false
            for _, st in ipairs(cinfo.allStations or {}) do
                if st.zone == cz then hereHasStation = true; break end
            end
            local targetZone = hereHasStation and cz or cinfo.navZone
            if targetZone and current_zone() ~= targetZone then
                printf_log('Travelling to %s for combines...', targetZone)
                if targetZone == ZONE_MARR then
                    if not travel_to_marr() then return end
                elseif targetZone == ZONE_POK then
                    if not travel_to_pok() then return end
                elseif targetZone == ZONE_JAGGEDPINE then
                    if not travel_to_jaggedpine() then return end
                else
                    printf_log('WARNING: no travel method for %s - combining in current zone.', targetZone)
                end
            elseif not targetZone then
                printf_log('WARNING: station zone unknown - combining in current zone.')
            end
            state.maybe_use_draught(rec.name)   -- scavenge buff before the (hard) combine, if enabled
            if not world_open(cinfo) then return end
        else
            -- Inventory top recipe: sub-parts may have left a forge/oven open. Re-open the
            -- kit so the right container is active before the combine loop. open_kit closes
            -- any lingering forge window first, and is a fast no-op if the kit is already up.
            if not open_kit(cinfo, kitPack) then return end
        end

        -- Slot count
        local slotCount = 0
        for _, ing in ipairs(rec.ingredients) do
            slotCount = slotCount + ing.qty
        end

        local madeTotal = 0
        local failedTotal = 0
        local desyncTotal = 0   -- combine-time desyncs only (per-combine classification below)
        state.desyncCount = 0   -- TRUE total for this run (placement + combine), tallied at the event source
        local fizzleTotal = 0   -- normal skill-fail fizzles (expected; salvage recovers the mats)
        -- This run's starting point in the running session totals. We update state live from
        -- base+running so the Stats tab moves during the grind, and finalize on every exit path.
        local sessionMadeBase   = state.sessionMade
        local sessionFailedBase = state.sessionFailed
        local sessionFizzleBase = state.sessionFizzles or 0
        local sessionDesyncBase = state.sessionDesyncs or 0
        local trivialHit = false
        local worldStaged = false   -- true while a reusable set sits in the enviro slots
        local wrongContainerStrikes = 0  -- consecutive "wrong container contents" hits
        local stuckCombines = 0          -- consecutive NON-fizzle failures (stuck/overstacked window); the slot-10 reset zeroes this
        local hardFailStreak = 0         -- consecutive REAL failures with nothing made; NOT zeroed by the slot-10 reset - the give-up seatbelt

        local loopOk, loopErr = pcall(function()
            for n = 1, job.quantity do
                check_stop()
                -- PAUSE checkpoint. Suspends here (loop counters preserved, so we resume at combine n,
                -- not 1). On resume, re-validate: reopen the kit and confirm we still hold a combine's
                -- worth of ingredients (the player may have moved the kit or used mats while paused).
                state.check_pause(function()
                    if cinfo and cinfo.type == 'inventory' then
                        if not ensure_kit_in_pack(rec.Container or job.recipe.Container or '', kitPack) then return false end
                        if not open_kit(cinfo, kitPack) then return false end
                    elseif cinfo and cinfo.type == 'world' then
                        if not world_open(cinfo) then return false end
                        worldStaged = false   -- reopening empties the enviro slots
                    end
                    return true
                end)
                -- Live stats: push this run's progress into the session totals every pass so the
                -- Stats tab updates during the grind instead of only at the end.
                state.sessionMade   = sessionMadeBase   + madeTotal
                state.sessionFailed = sessionFailedBase + failedTotal
                state.sessionFizzles = sessionFizzleBase + fizzleTotal
                state.sessionDesyncs = sessionDesyncBase + (state.desyncCount or 0)
                state.sessionLastSkill = (eqSkillName and skill_value(eqSkillName)) or state.sessionLastSkill

                -- Inventory threshold mid-run. Honors the PRODUCT's disposal:
                --   SELL    -> vendor the product to make room (the normal case).
                --   DESTROY -> destroy the product to make room (no vendor trip).
                --   KEEP    -> the user explicitly chose to keep it, so we do NOT sell or destroy it,
                --              even though that means we can't free space here. If bags are genuinely
                --              full of a KEEP product, stop and say so rather than override the choice.
                if free_slots(invSlots) <= INVENTORY_THRESHOLD then
                    if job.disposal == DISPOSAL.KEEP then
                        printf_log('\arInventory low (%d free) and %s is set to KEEP - stopping (won\'t sell or destroy a KEEP product). Free bag space, then Start again.\ax', free_slots(invSlots), rec.name)
                        state.stopRequested = true
                        break
                    elseif job.disposal == DISPOSAL.DESTROY then
                        printf_log('Inventory low (%d free slots) - destroying %s (disposal=DESTROY) to continue...', free_slots(invSlots), rec.name)
                        while item_count(rec.name) > 0 and free_slots(invSlots) <= INVENTORY_THRESHOLD do
                            destroy_one(rec.name)
                        end
                        if free_slots(invSlots) <= INVENTORY_THRESHOLD then
                            printf_log('\arERROR: only %d free slots and destroying %s freed nothing - free up bag space, then press Start again.\ax', free_slots(invSlots), rec.name)
                            state.stopRequested = true
                            break
                        end
                        printf_log('Slots freed up (%d free) - resuming...', free_slots(invSlots))
                        if cinfo.type == 'world' then
                            if not world_open(cinfo) then
                                printf_log('ERROR: could not reopen %s after destroying - stopping.', cinfo.name)
                                break
                            end
                            worldStaged = false
                        end
                    else
                    printf_log('Inventory low (%d free slots) - attempting to sell %s to continue...', free_slots(invSlots), rec.name)
                    if cinfo.type == 'world' then close_world_container() end
                    close_merchant()
                    local reached, nearName = nav_to_nearest_merchant()
                    if reached and open_merchant(nearName) then
                        sell_item_by_id(rec.name)
                        close_merchant()
                    end
                    if free_slots(invSlots) <= INVENTORY_THRESHOLD then
                        printf_log('\arERROR: only %d free slots and selling freed nothing - free up bag space, then press Start again.\ax', free_slots(invSlots))
                        printf_log('(Nothing sellable was made yet, or this vendor won\'t buy %s. Stopping so it doesn\'t retry the same recipe forever.)', rec.name)
                        state.stopRequested = true   -- unrecoverable HERE: halt the whole run instead of re-planning the same recipe in a loop
                        break
                    end
                    printf_log('Slots freed up (%d free) - resuming...', free_slots(invSlots))
                    if cinfo.type == 'world' then
                        if not world_open(cinfo) then
                            printf_log('ERROR: could not reopen %s after selling - stopping.', cinfo.name)
                            break
                        end
                        worldStaged = false   -- reopening empties the enviro slots
                    end
                    end
                end

                -- Ensure returned/dropped items, and check we have enough of everything
                local shortIngredient = nil
                for _, ing in ipairs(rec.ingredients) do
                    if ing.returned and state.returned_tool_missing(ing.name) then
                        printf_log('%s missing before combine %d - obtaining...', ing.name, n)
                        if cinfo.type == 'world' then close_world_container() end
                        if not ensure_returned_item(ing.name, kitPack) then
                            printf_log('ERROR: could not obtain %s - aborting.', ing.name)
                            error('__TS_STOP__')
                        end
                        if cinfo.type == 'world' then
                            if not world_open(cinfo) then error('__TS_STOP__') end
                            worldStaged = false   -- reopening empties the enviro slots
                        end
                    elseif ing.dropped and item_count(ing.name) < ing.qty then
                        -- Dropped/farmed mats are pre-loaded into bags up front via
                        -- the Request tab. We NEVER travel for them mid-craft. Out
                        -- of one just ends the batch gracefully so leveling advances
                        -- to the next recipe.
                        printf_log('Out of %s (pre-loaded mat) - ending batch, moving on.', ing.name)
                        shortIngredient = ing.name
                        break
                    elseif not ing.returned and not ing.dropped and item_count(ing.name) < ing.qty then
                        shortIngredient = ing.name
                        break
                    end
                end
                if shortIngredient then
                    -- Is this a VENDOR-buyable non-stackable that just ran out its batch? If so, the
                    -- run isn't done - we deliberately bought only a bag-load (batch cap in buy_pass).
                    -- Rebuy a fresh batch and CONTINUE the loop instead of ending the run. Only for
                    -- vendor-sold, non-returned mats; dropped/farmed shortfalls still end the batch.
                    local isVendorBatch = (state.vendorMap or {})[shortIngredient] ~= nil
                        and not state.stopRequested
                        and madeTotal < job.quantity and #vendorIngs > 0
                    if isVendorBatch then
                        printf_log('Batch of %s used up (%d/%d made) - rebuying next batch...', shortIngredient, madeTotal, job.quantity)
                        if cinfo.type == 'world' then close_world_container() end
                        close_merchant()
                        local rebuyRec = { name = rec.name, yield = rec.yield, trivial = rec.trivial,
                                           sellable = rec.sellable, ingredients = vendorIngs }
                        if not buy_pass(rebuyRec, job.quantity - madeTotal, vendorName) then
                            printf_log('Rebuy failed - ending batch.')
                            break
                        end
                        -- Re-open the station and re-stage for the next batch.
                        if cinfo.type == 'world' then
                            if not world_open(cinfo) then printf_log('ERROR: could not reopen %s after rebuy - stopping.', cinfo.name); break end
                            worldStaged = false
                        end
                        -- Did the rebuy actually get us enough for at least one combine? If not, stop.
                        local stillShort = false
                        for _, ig in ipairs(rec.ingredients) do
                            if not ig.returned and not ig.dropped and item_count(ig.name) < ig.qty then stillShort = true; break end
                        end
                        if stillShort then
                            printf_log('Rebuy did not restock %s (bags full or vendor out) - ending batch.', shortIngredient)
                            break
                        end
                        shortIngredient = nil   -- restocked: fall through and keep combining
                    else
                        printf_log('Not enough %s (%d/%d) - ending batch early.',
                            shortIngredient, item_count(shortIngredient), rec.ingredients[1].qty)
                        break
                    end
                end

                if cinfo.type == 'world' then
                    -- Stage from a known-empty enviro (see execute_recipe note). Failed-combine
                    -- items are bagged, not re-placed, so this clear is insurance against a
                    -- stale set from a prior session/stop -- not the normal path.
                    if not worldStaged then
                        if world_stage(cinfo, rec, slotCount) then
                            worldStaged = true
                        else
                            printf_log('FAILED %s: could not stage ingredients (%d/%d).', rec.name, n, job.quantity)
                            failedTotal = failedTotal + 1
                        end
                    end
                    if worldStaged then
                        local before = item_count(rec.name)
                        local ok, staged = world_combine_return(cinfo, rec, rec.name, before, slotCount)
                        if ok then
                            madeTotal = madeTotal + 1
                            hardFailStreak = 0   -- made one: recipe works, clear the give-up streak
                            worldStaged = false   -- consumed; re-place next pass
                            if job.disposal == DISPOSAL.DESTROY then destroy_one(rec.name) end
                        else
                            -- Classify the miss so the log shows the TRUE desync rate, not an
                            -- inflated one: a real desync (ts_desync fired) vs a normal skill
                            -- fizzle (You lacked the skills) vs something else. Fizzles are
                            -- expected at this trivial gap and the salvage returns the mats.
                            if combineFlags.desync then
                                printf_log('Combine %d/%d failed (DESYNC, recovering): %s.', n, job.quantity, rec.name)
                                desyncTotal = desyncTotal + 1
                                hardFailStreak = 0   -- a recovering desync isn't a broken recipe
                            elseif combineFlags.lacked then
                                printf_log('Combine %d/%d fizzled (skill fail, salvage recovered): %s.', n, job.quantity, rec.name)
                                fizzleTotal = fizzleTotal + 1
                                hardFailStreak = 0   -- ordinary skill fizzle
                            else
                                printf_log('Combine %d/%d failed (other - investigate): %s.', n, job.quantity, rec.name)
                                hardFailStreak = hardFailStreak + 1
                            end
                            worldStaged = staged  -- reuse in place if cleanly re-staged
                            failedTotal = failedTotal + 1
                        end
                    end
                else
                    if not open_kit(cinfo, kitPack) then
                        printf_log('ERROR: could not open %s - stopping.', cinfo.name)
                        break
                    end
                    close_merchant()
                    if not stage_kit(cinfo, rec, kitPack) then
                        printf_log('FAILED %s: could not stage ingredients (%d/%d).', rec.name, n, job.quantity)
                        clear_kit(cinfo, kitPack, slotCount)
                        failedTotal = failedTotal + 1
                    else
                        local before = item_count(rec.name)
                        if combine_and_wait(cinfo, rec, kitPack, rec.name, before) then
                            madeTotal = madeTotal + 1
                            wrongContainerStrikes = 0
                            stuckCombines = 0
                            hardFailStreak = 0   -- made one: recipe works, clear the give-up streak
                            if job.disposal == DISPOSAL.DESTROY then destroy_one(rec.name) end
                        elseif combineFlags.wrongContainer then
                            -- Contents are wrong for this recipe (not a fizzle). Clear and
                            -- re-stage a fresh set once (the next pass restages from bags);
                            -- if it complains again the recipe/container is genuinely
                            -- misconfigured, so abort instead of looping forever.
                            wrongContainerStrikes = wrongContainerStrikes + 1
                            clear_kit(cinfo, kitPack, slotCount)
                            if wrongContainerStrikes >= 2 then
                                printf_log('ABORT %s: "cannot combine in this container type" persisted after a fresh re-stage - check the recipe/container.', rec.name)
                                break
                            end
                            printf_log('Wrong container contents for %s - cleared, re-staging fresh and retrying once.', rec.name)
                            failedTotal = failedTotal + 1
                        else
                            -- normal fizzle: ingredients were returned to the kit off the cursor - reuse next pass
                            wrongContainerStrikes = 0
                            failedTotal = failedTotal + 1
                            if combineFlags.lacked then
                                printf_log('Combine %d/%d fizzled (skill fail): %s.', n, job.quantity, rec.name)
                                fizzleTotal = fizzleTotal + 1   -- was only counted on the WORLD path, so
                                                                -- kit runs (Tailoring, Jewelcrafting) always
                                                                -- reported "0 skill-fizzles" no matter what
                                stuckCombines = 0   -- ordinary skill fizzle, not a stuck window
                                hardFailStreak = 0  -- fizzle = mechanism works, just unlucky skill
                            else
                                printf_log('FAILED combine %d/%d: %s.', n, job.quantity, rec.name)
                                -- A non-fizzle failure (e.g. an over-stack left slot 10's combine
                                -- window in a bad state). A few in a row means the window is stuck,
                                -- so reset it: clear the kit, close slot 10 and VERIFY it closed,
                                -- then reopen. Abort the recipe if the close won't take.
                                stuckCombines = stuckCombines + 1
                                hardFailStreak = hardFailStreak + 1   -- survives the slot-10 reset below
                                if stuckCombines >= 3 then
                                    printf_log('%d non-fizzle failures in a row - resetting slot 10 (clear, close, reopen)...', stuckCombines)
                                    clear_kit(cinfo, kitPack, slotCount)
                                    -- Stuck window: lead with /cleanup (reliable nuke) before the esc
                                    -- finisher - the toggle+esc alone can fail on exactly the stuck state
                                    -- that got us here.
                                    if mq.TLO.Window('ContainerCombine_Items').Open() then
                                        mq.cmd('/cleanup')
                                        mq.delay(400, function() return not mq.TLO.Window('ContainerCombine_Items').Open() end)
                                        mq.doevents()
                                    end
                                    state.close_kit_bags()
                                    if mq.TLO.Window('ContainerCombine_Items').Open() then
                                        printf_log('ERROR: slot 10 would not close (still open) - aborting %s.', rec.name)
                                        break
                                    end
                                    if not open_kit(cinfo, kitPack) then
                                        printf_log('ERROR: could not reopen slot 10 after reset - aborting %s.', rec.name)
                                        break
                                    end
                                    printf_log('Slot 10 reset OK - resuming %s.', rec.name)
                                    stuckCombines = 0
                                end
                            end
                        end
                    end
                end

                state.doneCount = n

                -- Seatbelt: a long run of REAL (non-fizzle) failures with nothing made means the
                -- recipe is broken (e.g. a returned tool that never re-seats), not just unlucky - and
                -- the slot-10 reset keeps zeroing its own counter, so it never self-stops (this is the
                -- 8-hour "resetting slot 10" x583 loop). Give up here: stop this recipe, and in a
                -- leveling run mark it skipped so the plan advances to the next recipe instead of
                -- re-planning the same broken one. hardFailStreak only counts real failures and resets
                -- on any success/fizzle, so normal grinding never trips it. 15 = ~5 slot-10 resets' worth.
                if hardFailStreak >= 15 then
                    printf_log('GIVING UP on %s: %d combines in a row failed with nothing made - skipping this recipe.', rec.name, hardFailStreak)
                    if job.leveling then
                        state.levelSkip = state.levelSkip or {}
                        state.levelSkip[rec.name] = true
                    end
                    break
                end
                -- Stop-at-trivial / hard-300-cap is a LEVELING behavior only: once the skill
                -- can't rise, a leveling run is done. A deliberate Craft/Radix run is after the
                -- PRODUCTS, so it makes the full requested quantity even at cap (e.g. Mithril
                -- Champion Arrows, trivial 335, crafted at Fletching 300). Gate on job.leveling.
                if job.stopOnTrivial and job.leveling then
                    local curSkill = skill_value(skillSec.Skill)
                    -- Use the SAME ceiling the advance loop uses (state.level_skill_ceiling) so the two
                    -- can NEVER disagree - the documented "prints 'stopping' but keeps re-queuing / grinds
                    -- past the cap" bug. That helper already folds in the class SkillCap, any PATH_MAX_SKILL,
                    -- and the hard 300 cap, so every tradeskill is gated identically. Stop at whichever comes
                    -- first: this recipe going trivial, or the skill ceiling. (This also gates SUBCOMBINE
                    -- combines routed through execute_recipe, not just the top product.)
                    local ceiling = state.level_skill_ceiling(skillSec.Skill, job.skillName or skillSec.Skill)
                    local stopAt = math.min(rec.trivial or ceiling, ceiling)
                    if curSkill and curSkill >= stopAt then
                        if curSkill >= ceiling then
                            -- Hit the skill ceiling - say WHICH kind: a class/path cap BELOW 300 (can't
                            -- raise it further, not a bug or missing mats) vs the true 300 max. ceiling
                            -- already folds in SkillCap + PATH_MAX + the hard 300, so ceiling < 300 means
                            -- class/path-limited; ceiling == 300 means genuinely maxed.
                            if ceiling < HARD_SKILL_CAP then
                                printf_log("%s is at your class's cap (%d) - this is as high as you can raise it, stopping.",
                                    skillSec.Skill, ceiling)
                            else
                                printf_log('%s reached the skill cap (%d) - stopping.',
                                    skillSec.Skill, HARD_SKILL_CAP)
                            end
                        else
                            printf_log('%s reached trivial (%d/%d) - stopping.',
                                skillSec.Skill, curSkill, rec.trivial)
                        end
                        trivialHit = true
                        break
                    end
                end
            end
        end)

        local stoppedByUser = (not loopOk) and tostring(loopErr):find('__TS_STOP__', 1, true)

        -- Finalize the session counts here -- BEFORE the stop/trivial returns below, which used to
        -- skip the write entirely (that, plus the end-only update, is why Stats sat at 0). Absolute
        -- set from this run's base, so it agrees with the live in-loop updates and never doubles.
        state.sessionMade   = sessionMadeBase   + madeTotal
        state.sessionFailed = sessionFailedBase + failedTotal
        state.sessionFizzles = sessionFizzleBase + fizzleTotal
        state.sessionDesyncs = sessionDesyncBase + (state.desyncCount or 0)

        if cinfo.type == 'world' then
            close_world_container()
            -- Peel back to the safe waypoint (if the station had one) so the next leg - sell trip,
            -- next recipe, or zone out - starts from clean ground instead of on top of the station.
            local wp = state.approach_waypoint_for(cinfo.navLoc, cinfo.navZone)
            if wp then
                printf_log('Leaving the station via the safe waypoint...')
                state.nav_loc_wait(wp)
            end
        end
        if job.disposal == DISPOSAL.SELL and item_count(rec.name) > 0 and not stoppedByUser then
            -- Don't sell a product a LATER rung consumes. Woven Mandrake finishes one Tailoring rung
            -- and is an ingredient of the next (Picnic Basket): selling the 50 we'd just made meant
            -- turning round and crafting 250 from scratch. The between-recipes MAT sell already keeps
            -- what's needed next; this product sell never consulted the plan.
            -- NOTE: skipped entirely when stoppedByUser - a Stop halts cleanly with no vendor trip / sell
            -- (that mid-stop sell was the "finicky Stop" behavior). Whatever's made stays in bags.
            local needLater = false
            if job.leveling then
                local okc, r = pcall(function() return state.product_needed_later(rec.name) end)
                needLater = okc and r or false
            end
            if needLater then
                printf_log('Keeping %d %s - a later recipe in this path needs it.', item_count(rec.name), rec.name)
            else
            drain_cursor()
            printf_log('Selling remaining %d %s...', item_count(rec.name), rec.name)
            close_merchant()
            if cinfo.type == 'world' then close_world_container() end
            local reached, nearName = nav_to_nearest_merchant()
            if reached and open_merchant(nearName) then
                sell_item_by_id(rec.name)
                close_merchant()
            else
                printf_log('WARNING: could not reach vendor for final sell pass.')
            end
            end   -- needLater
        end

        if stoppedByUser then
            printf_log('Stopped by user. %d made, %d failed (%d skill-fizzles, %d desyncs).', madeTotal, failedTotal, fizzleTotal, (state.desyncCount or 0))
            return
        end
        if not loopOk then error(loopErr, 0) end
        if trivialHit then
            printf_log('Stopped at trivial. %d made, %d failed (%d skill-fizzles, %d desyncs).', madeTotal, failedTotal, fizzleTotal, (state.desyncCount or 0))
            return
        end

        printf_log('Run complete: %d made, %d failed (%d skill-fizzles, %d desyncs).', madeTotal, failedTotal, fizzleTotal, (state.desyncCount or 0))
        state.sessionLastSkill = eqSkillName and skill_value(eqSkillName) or state.sessionLastSkill
    end)

    if not ok then
        if tostring(err):find('__TS_STOP__', 1, true) then
            printf_log('Stopped by user.')
        else
            printf_log('ERROR: %s', tostring(err))
        end
    end
    -- Only force the kit/combine window shut here when we actually need a clean reset: a desync this run
    -- leaves the container dirty, and an error/stop should end on clean ground. On a CLEAN inventory-kit
    -- run we LEAVE IT OPEN so the next recipe (e.g. the next research spell) just combines instead of the
    -- close-on-every-recipe / reopen churn. A world craft already closed in the finalize block above, and
    -- the next vendor trip's open_merchant closes any leftover kit window regardless.
    if not ok or (state.desyncCount or 0) > 0 then
        close_world_container()
    end
    close_merchant()
    state.restore_saved_slots()   -- put ammo (trophy/modifier) back to what you had on
    drain_cursor()                -- don't leave anything sitting on the cursor when the run ends
    state.pauseRequested = false   -- clear pause state when the run ends (normal, stop, or error)
    state.paused = false
    state.busy = false
end

-- ─── Research crafting ──────────────────────────────────────────────────────
-- Research is a standalone, class/level-tagged flow (research.ini). It reuses the
-- suite's proven engine: each selected spell/tome runs through run_engine with a
-- synthetic Research skill section and the class-keyed recipe section passed in
-- (recipes are keyed [Recipe:<name>##<class>], so rec.name alone won't find them).
-- No crafting/vendor logic is copied from the old macro - only its recipe data.

local RESEARCH_TOME_CLASSES = {
    war = true, warrior = true, rog = true, rogue = true, mnk = true, monk = true,
    rng = true, ranger = true, bst = true, beastlord = true, shd = true, shadowknight = true,
    pal = true, paladin = true, brd = true, bard = true, ber = true, berserker = true,
}

-- A research product is a tome/discipline unless its name is a caster Spell:/Song:.
local function is_research_tome(name)
    if not name then return false end
    return not (name:sub(1, 6) == 'Spell:' or name:sub(1, 5) == 'Song:')
end

-- Only melee/hybrid characters can make tomes - checked against the live character.
local function char_can_make_tomes()
    local c = (mq.TLO.Me.Class.ShortName() or ''):lower()
    if RESEARCH_TOME_CLASSES[c] then return true end
    local n = (mq.TLO.Me.Class.Name() or ''):lower()
    return RESEARCH_TOME_CLASSES[n] == true
end

-- Move (or acquire) a research kit into the kit pack slot.
local function run_research_kit(job)
    state.busy = true
    state.stopRequested = false
    if ensure_kit_in_pack(job.kit, KIT_PACK_DEFAULT) then
        printf_log('%s is in slot %d.', job.kit, KIT_PACK_DEFAULT)
    else
        printf_log('Could not place %s in slot %d - is it on a vendor or in your bags?', job.kit, KIT_PACK_DEFAULT)
    end
    state.busy = false
end

-- Craft a list of research items. Each item: { name=<display>, key=<name##class>, qty=N }.
-- Every item routes through run_engine (the shared, tested path); stops cleanly
-- between items if the user hits Stop.
local function run_research_engine(job)
    local items = job.items or {}
    if #items == 0 then return end

    state.busy = true
    state.stopRequested = false

    -- Resolve each queued spell to its recipe and a SUCCESS target. We craft to N
    -- successes, not N attempts: a failed combine eats the mats, so each round re-buys and
    -- retries the still-owed count. Vendor buying is grouped into ONE pass per round across
    -- the whole batch (buy everything up front, then combine) instead of a vendor trip per
    -- spell. Successes are counted by the finished item's count delta - spells/tomes are
    -- KEEP (never sold/destroyed), so the delta is exact.
    local specs = {}
    for _, it in ipairs(items) do
        local rec    = get_recipe(it.key)
        local recSec = (state.iniSections or {})['Recipe:' .. it.key]
        if rec and recSec then
            local countName = (tostring(it.name or it.key):gsub('##.*$', ''))   -- strip any ##class
            specs[#specs + 1] = {
                name = it.name or it.key, countName = countName, key = it.key,
                rec = rec, recSec = recSec, ordered = it.qty or 1, made = 0, remaining = it.qty or 1,
            }
        else
            printf_log('Research: no recipe found for %s.', it.name or it.key or '?')
        end
    end

    local ok, err = pcall(function()
        if #specs == 0 then return end

        local SAFETY_PASSES = 20   -- backstop; the real terminator is "no progress this pass"
        for pass = 1, SAFETY_PASSES do
            if state.stopRequested then break end

            -- Who still owes successes?
            local todo, owed = {}, 0
            for _, s in ipairs(specs) do
                if s.remaining > 0 then todo[#todo + 1] = s; owed = owed + s.remaining end
            end
            if #todo == 0 then break end

            printf_log('\ag=== Research %s: %d spell(s), %d combine(s) to make ===\ax',
                pass == 1 and 'batch' or ('retry round ' .. (pass - 1)), #todo, owed)

            -- (1) GROUPED BUY: sum the vendor demand of every still-owed spell (each spell's
            -- whole tree, subcombines included) and buy it ALL in one pass. buy_pass nets
            -- on-hand, so each spell's own pre-buy inside run_engine below finds everything
            -- present and skips its vendor trip - one batch trip instead of one per spell.
            local combined = {}
            local bankReserved = {}   -- shared across spells: claims banked/on-hand intermediates so
                                      -- two spells needing the same one don't both prune it
            for _, s in ipairs(todo) do
                local plan = plan_requirements(s.key, s.remaining, bankReserved)
                if plan and plan.buyDemand then
                    for nm, q in pairs(plan.buyDemand) do combined[nm] = (combined[nm] or 0) + q end
                end
            end
            -- ONE bank visit for the whole round: trophies + every banked ingredient/subcombine across
            -- ALL owed spells (dropped parchments, banked intermediates, banked buy-mats). This replaces
            -- the old per-spell bank trips - each spell's own run_engine bank pass now finds it all
            -- on-hand and makes no trip. buy_pass below still nets on-hand, so it buys only the true
            -- shortfall left after the pull. (Closes the bank and steps off via the safe hub itself.)
            do
                local trees = {}
                for _, s in ipairs(todo) do trees[#trees + 1] = { rec = s.rec, qty = s.remaining } end
                state.runIsLeveling = false   -- research is never a leveling run; pull trophies if any exist
                state.ensure_bank_for_trees(trees)
            end
            local preIngs = {}
            for nm, q in pairs(combined) do preIngs[#preIngs + 1] = { name = nm, qty = q } end
            if #preIngs > 0 then
                clear_cursor()   -- never start a buy with the displaced ammo (or anything) still held
                printf_log('Buying %d vendor mat type(s) for the whole batch in one pass...', #preIngs)
                buy_pass({ name = 'Research batch', yield = 1, trivial = 0, sellable = false,
                           ingredients = preIngs }, 1, nil)
            end
            if state.stopRequested then break end

            -- (2) CRAFT each owed spell from on-hand mats. run_engine's own buy pass no-ops
            -- (everything's bought) and it re-does the subcombines each attempt.
            local progressed = false
            for _, s in ipairs(todo) do
                if state.stopRequested then break end
                local before = item_count(s.countName)
                run_engine({
                    action = 'craft', skillSection = { Skill = 'Research' },
                    recipeSection = s.recSec, recipe = s.rec, quantity = s.remaining,
                    disposal = DISPOSAL.KEEP, kitPack = KIT_PACK_DEFAULT, stopOnTrivial = false,
                })
                local got = item_count(s.countName) - before
                if got < 0 then got = 0 end
                if got > 0 then progressed = true end
                s.made = s.made + got
                s.remaining = math.max(0, s.remaining - got)
                if s.remaining > 0 then
                    printf_log('\ay%s: %d/%d made, %d still owed.\ax', s.name, s.made, s.ordered, s.remaining)
                else
                    printf_log('\ag%s: %d/%d made.\ax', s.name, s.made, s.ordered)
                end
            end

            -- (3) A full round that made nothing means we're stuck - out of pre-loaded
            -- dropped/manual mats for the remaining spells. Stop rather than loop on empty buys.
            if not progressed then
                printf_log('\arNo combines succeeded this round - likely out of pre-loaded mats for the remaining spells. Stopping.\ax')
                break
            end
        end

        -- Final report
        local short = {}
        for _, s in ipairs(specs) do
            if s.made < s.ordered then short[#short + 1] = string.format('%s (%d/%d)', s.name, s.made, s.ordered) end
        end
        if #short == 0 then
            printf_log('\agResearch batch complete - every spell made as ordered.\ax')
        else
            printf_log('\ayBatch finished with shortfalls - pre-load more of the dropped/manual mats, then re-queue these:\ax')
            for _, line in ipairs(short) do printf_log('  \ar%s\ax', line) end
        end
    end)

    if not ok then
        if tostring(err):find('__TS_STOP__', 1, true) then
            printf_log('Stopped by user.')
        else
            printf_log('ERROR: %s', tostring(err))
        end
    end

    close_world_container()
    close_merchant()
    drain_cursor()                -- leave nothing on the cursor when this run ends
    state.busy = false
end

-- Standalone action: sells every leftover raw ingredient for the current
-- recipe (whatever's still in inventory), to the nearest vendor. Does
-- not touch the crafted output item or do any crafting.
-- Collect every SELLABLE mat in a recipe's full tree: its own ingredients plus, recursively, the
-- ingredients of any subcombine it makes, and the subcombine outputs themselves. Returned tools
-- (needles, hammers) and dropped/farmed mats are never included - we keep those. Used by the
-- between-recipes sell pass, which otherwise only cleared the top recipe's direct ingredients and
-- left the whole subcombine tree cluttering the bags. `seen` guards the both-ways ore conversions.
state.collect_tree_mats = function(rec, out, seen)
    if not rec or not rec.ingredients then return out end
    out, seen = out or {}, seen or {}
    for _, ing in ipairs(rec.ingredients) do
        if not ing.returned and not ing.dropped then
            local key = ing.name
            if not seen[key:upper()] then
                seen[key:upper()] = true
                out[#out + 1] = key
                -- If this mat is itself crafted, its own mats (and leftovers) can be sold too.
                local sub = (state.iniSections or {})['Recipe:' .. key] and get_recipe(key)
                if sub then state.collect_tree_mats(sub, out, seen) end
            end
        end
    end
    return out
end

-- Does any LATER rung of the level plan consume this item? Walks each remaining below-trivial
-- recipe's full tree. Used before the trivial-stop product sell: Woven Mandrake is the product of one
-- Tailoring rung and an ingredient of the next (Picnic Basket), so selling the 50 we just made meant
-- immediately re-crafting 250 of them. Keep what we're about to need.
state.product_needed_later = function(itemName)
    if not itemName or not state.levelPlan then return false end
    local up = itemName:upper()
    local from = (state.levelCurrentIndex or 1) + 1
    for i = from, #state.levelPlan do
        local e = state.levelPlan[i]
        local rec = e and get_recipe(e.itemName)
        if rec then
            for _, nm in ipairs(state.collect_tree_mats(rec)) do
                if nm:upper() == up then return true end
            end
        end
    end
    return false
end

local function run_sell_reagents(job)
    state.busy = true
    state.stopRequested = false
    state.log = {}

    local ok, err = pcall(function()
        local rec = job.recipe
        local anyToSell = false
        for _, ing in ipairs(rec.ingredients) do
            if not ing.returned and not ing.dropped and item_count(ing.name) > 0 then anyToSell = true end
        end
        if not anyToSell then
            printf_log('No leftover reagents for %s to sell.', rec.name)
            return
        end

        -- Close any open containers/merchants before navigating
        close_world_container()
        close_merchant()

        local reached, nearName = nav_to_nearest_merchant()
        if not reached then
            printf_log('WARNING: could not reach a vendor to sell reagents.')
            return
        end
        if not open_merchant(nearName) then
            printf_log('WARNING: could not open merchant window at %s.', nearName)
            return
        end
        for _, ing in ipairs(rec.ingredients) do
            if not ing.returned and not ing.dropped and item_count(ing.name) > 0 then
                sell_item_by_id(ing.name)
            end
        end
        close_merchant()
        printf_log('Reagent sell pass complete.')
    end)

    if not ok then
        if tostring(err):find('__TS_STOP__', 1, true) then
            printf_log('Stopped by user.')
        else
            printf_log('ERROR: %s', tostring(err))
        end
    end
    close_world_container()
    close_merchant()
    drain_cursor()                -- leave nothing on the cursor when this run ends
    state.busy = false
end

-- Leveling: moving from one recipe to the next, sell the leftover VENDOR mats of the recipe we're
-- leaving so they don't eat bag space for the rest of the run. Covers the recipe's whole tree
-- (subcombine mats + intermediates), which is where the clutter actually accumulates - the old code
-- only cleared the top recipe's direct ingredients. Returned tools and dropped/farmed mats are never
-- sold, and anything the NEXT recipe's tree needs is kept, so we don't sell a stack and re-buy it a
-- minute later. Lives on state (not the main chunk) to respect the 200-local ceiling.
-- Clutter test for the between-recipes sell: an item is "clutter" only if it is BOTH non-stackable
-- AND vendor-sold. Non-stackable items each eat a whole bag slot, and vendor-sold ones are cheap
-- (molds, patterns, single-use vendor parts) - selling those keeps bags open without touching the
-- valuable stuff. Stackable items (subcombine products; bars) are KEPT - they pack into a slot or
-- two and are expensive to remake. This is what stops the Misty Thicket Picnic disaster, where a
-- skipped nested recipe sold 30 minutes of stackable subcombines.
state.is_clutter_item = function(name)
    if not name or name == '' then return false end
    if (state.vendorMap or {})[name] == nil then return false end   -- crafted/looted only -> keep
    local ok, stackable = pcall(function() return mq.TLO.FindItem('=' .. name).Stackable() end)
    if ok and stackable then return false end                       -- stackable vendor item -> keep
    return true                                                      -- non-stackable AND vendor-sold
end

state.sell_between_recipes = function(prevEntry, nextEntry, nextRec, skillSec)
    -- DISABLED (per user): we no longer sell leftover ingredient clutter between rungs. The suite sells
    -- finished PRODUCTS (via disposal mode), not ingredients - leftover molds/patterns/parts now ride
    -- along in bags instead of being vendored. Trade-off accepted: a very long leveling run can fill
    -- bags with non-stackable clutter; if that becomes a problem, switch these to DESTROY rather than
    -- re-enabling the sell. The function is kept (callers still invoke it) so re-enabling is a one-line
    -- revert, but it does nothing now.
    do return end
end

-- Standalone action: sell every ingredient (job.mode == 'ingredients') or every
-- product (job.mode == 'products') across the whole level plan, in one merchant
-- visit. Used by the Level tab's quick inventory-cleanup buttons. Reusable tools
-- flagged |returned (needles, etc.) are kept, not sold.
local function run_level_sell(job)
    state.busy = true
    state.stopRequested = false
    state.log = {}

    local ok, err = pcall(function()
        local sellProducts = (job.mode == 'products')

        -- Build a de-duplicated, plan-ordered list of names to sell.
        local names, seen = {}, {}
        local function add(n)
            if n and n ~= '' and not seen[n] then seen[n] = true; names[#names+1] = n end
        end
        if job.names then
            -- Explicit list (e.g. a single rung's product from its row button).
            for _, n in ipairs(job.names) do add(n) end
        else
        for _, entry in ipairs(state.levelPlan or {}) do
            if sellProducts then
                add(entry.itemName)
            else
                local rec = get_recipe(entry.itemName)
                if rec then
                    for _, ing in ipairs(rec.ingredients) do
                        if not ing.returned and not ing.dropped then add(ing.name) end
                    end
                end
            end
        end
        end

        -- Keep only what we actually have on hand.
        local toSell = {}
        for _, n in ipairs(names) do
            if item_count(n) > 0 then toSell[#toSell+1] = n end
        end
        if #toSell == 0 then
            printf_log('Nothing to sell (%s on hand).', sellProducts and 'no products' or 'no ingredients')
            return
        end

        close_world_container()
        close_merchant()
        local reached, nearName = nav_to_nearest_merchant()
        if not reached then
            printf_log('WARNING: could not reach a vendor to sell.')
            return
        end
        if not open_merchant(nearName) then
            printf_log('WARNING: could not open merchant window at %s.', nearName)
            return
        end
        printf_log('Selling %d %s type(s)...', #toSell, sellProducts and 'product' or 'ingredient')
        for _, n in ipairs(toSell) do
            check_stop()
            if item_count(n) > 0 then sell_item_by_id(n) end
        end
        close_merchant()
        printf_log('%s sell pass complete.', sellProducts and 'Product' or 'Ingredient')
    end)

    if not ok then
        if tostring(err):find('__TS_STOP__', 1, true) then
            printf_log('Stopped by user.')
        else
            printf_log('ERROR: %s', tostring(err))
        end
    end
    close_world_container()
    close_merchant()
    drain_cursor()                -- leave nothing on the cursor when this run ends
    state.busy = false
end

-- Pull itemName from the CRAFTER's own bank toward `target` on-hand, before any mule
-- request. Navs to the nearest banker (PoK/Marr both have one), withdraws a stack at a
-- time until we hit target or the bank runs dry, then closes. Returns on-hand count.
-- Early-outs (no banker trip) when nothing of itemName is banked, and falls through
-- gracefully (returns current on-hand) if no banker is reachable, so the caller can ask
-- the group for the remainder. Ported from TradeskillListener's proven bank routine.
-- Lazy bank-bag opener (crafter side, mirrors the listener). rightmouseup TOGGLES with no memory, so
-- re-opening the same bag per-grab was thrash. Open each bag we actually pull from ONCE per trip and
-- remember it; reset on a fresh bank open. Non-stackables (e.g. the trophy) skip this - they grab
-- straight from a closed bag (no split window to pop).
state.bank_bag_opened = {}
state.ensure_bank_bag_open = function(b)
    if state.bank_bag_opened[b] then return end
    mq.cmdf('/itemnotify bank%d rightmouseup', b); mq.delay(80)
    state.bank_bag_opened[b] = true
    printf_log('  (opened bank bag %d)', b)
end

state.bankTopUp = function(itemName, target)
    target = target or math.huge
    if item_count(itemName) >= target then return item_count(itemName) end

    local function bank_count() return state.bank_count(itemName) end
    -- Only make the trip if the REGULAR bank has some we can actually pull. state.bank_count counts
    -- only what grab() can reach (it excludes shared-bank copies), so we don't walk to the bank for
    -- an item that's only in shared storage. Skip the trip on 0 rather than walk to an empty bank.
    if bank_count() <= 0 then return item_count(itemName) end

    -- Find and reach a banker (Dogle Pitt in PoK - the nav-reliable one).
    state.target_banker()
    if (mq.TLO.Target.ID() or 0) == 0 then
        printf_log('Bank: no banker in this zone for %s - asking the group instead.', itemName)
        return item_count(itemName)
    end
    if state.spawn_dist3d(mq.TLO.Target) > 10 or state.spawn_zgap(mq.TLO.Target) > 12 then
        local bid = mq.TLO.Target.ID() or 0
        -- Route through the safe hub: leave our current cluster's hub first (if we're in one), then
        -- approach the banker's hub. Inside the >10 guard, so a multi-item visit routes once, not per item.
        state.route_bank_via_hub()
        state.pre_nav()
        mq.cmdf('/nav id %d', bid)
        -- Wait for nav to ENGAGE; re-issue once if it doesn't. A /nav dropped mid-run (the
        -- client still settling after vendor-hopping) is why "could not reach the banker"
        -- fired even with the banker right there - the old code bailed the instant nav read
        -- inactive.
        local engaged = false
        local startD = mq.gettime() + 3000
        while mq.gettime() < startD do
            if mq.TLO.Navigation.Active() then engaged = true; break end
            if (mq.TLO.Target.Distance() or 999) <= 10 then break end
            mq.delay(100)
        end
        if not engaged and (mq.TLO.Target.Distance() or 999) > 10 then
            mq.cmdf('/nav id %d', bid)
            local r = mq.gettime() + 3000
            while mq.gettime() < r do
                if mq.TLO.Navigation.Active() then engaged = true; break end
                if (mq.TLO.Target.Distance() or 999) <= 10 then break end
                mq.delay(100)
            end
        end
        local deadline = mq.gettime() + 15000
        while mq.gettime() < deadline do
            if not mq.TLO.Navigation.Active() then break end
            mq.doevents(); mq.delay(100)
        end
    end
    if state.spawn_dist3d(mq.TLO.Target) > 10 or state.spawn_zgap(mq.TLO.Target) > 12 then
        printf_log('Bank: could not reach the banker for %s - asking the group instead.', itemName)
        return item_count(itemName)
    end

    -- Open the bank.
    if not mq.TLO.Window('BigBankWnd').Open() then
        mq.cmd('/click right target')
        mq.delay(1000, function() return mq.TLO.Window('BigBankWnd').Open() end)
        state.bank_bag_opened = {}   -- fresh open: reset the per-trip opened-bag set
    end
    if not mq.TLO.Window('BigBankWnd').Open() then
        printf_log('Bank: could not open the bank window for %s.', itemName)
        return item_count(itemName)
    end
    state.bankSeenThisRun = true   -- contents are now known; future 0-counts are trustworthy

    -- Withdraw one stack per pass (handles both bagged and top-level bank slots).
    local upper = itemName:upper()
    local function withdraw_one()
        for b = 1, 24 do
            local bankSlot = mq.TLO.Me.Bank(b)
            if (bankSlot.ID() or 0) > 0 then
                local slots = bankSlot.Container() or 0
                if slots > 0 then
                    for s = 1, slots do
                        if (bankSlot.Item(s).Name() or ''):upper() == upper then
                            -- bankTopUp pulls the WHOLE slot stack (no split), so no bag open needed -
                            -- a whole-stack grab works from a closed bag (baseline rule).
                            mq.cmdf('/itemnotify in bank%d %d leftmouseup', b, s)
                            mq.delay(500, function() return (mq.TLO.Cursor.ID() or 0) > 0 or mq.TLO.Window('QuantityWnd').Open() end)
                            if mq.TLO.Window('QuantityWnd').Open() then
                                mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
                                mq.delay(500, function() return not mq.TLO.Window('QuantityWnd').Open() end)
                            end
                            if (mq.TLO.Cursor.ID() or 0) > 0 then
                                local stack = mq.TLO.Cursor.Stack() or 1
                                mq.cmd('/autoinventory')
                                mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                                return stack
                            end
                        end
                    end
                elseif (bankSlot.Name() or ''):upper() == upper then
                    mq.cmdf('/nomodkey /itemnotify bank%d leftmouseup', b)
                    mq.delay(500, function() return (mq.TLO.Cursor.ID() or 0) > 0 or mq.TLO.Window('QuantityWnd').Open() end)
                    if mq.TLO.Window('QuantityWnd').Open() then
                        mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
                        mq.delay(500, function() return not mq.TLO.Window('QuantityWnd').Open() end)
                    end
                    if (mq.TLO.Cursor.ID() or 0) > 0 then
                        local stack = mq.TLO.Cursor.Stack() or 1
                        mq.cmd('/autoinventory')
                        mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                        return stack
                    end
                end
            end
        end
        return 0
    end

    local pulled = 0
    while item_count(itemName) < target and bank_count() > 0 do
        local before = item_count(itemName)
        local got = withdraw_one()
        -- Stop if a pull yielded nothing or didn't land in bags (e.g. bags full) - avoids
        -- looping forever on a stuck cursor.
        if got <= 0 or item_count(itemName) <= before then break end
        pulled = pulled + got
    end

    clear_cursor()
    if mq.TLO.Window('BigBankWnd').Open() then
        mq.cmd('/notify BigBankWnd DoneButton leftmouseup')
        mq.delay(300)
    end
    if pulled > 0 then
        printf_log('Bank: withdrew %d %s (now have %d) before asking the group.', pulled, itemName, item_count(itemName))
    end
    return item_count(itemName)
end

-- Name of the tradeskill modifier to seat in the Ammo slot before research combines.
-- "Place and forget" - it is not consumed, so once equipped it persists. Generic on
-- purpose: change this (or call state.equip_modifier directly with another name) when
-- new modifiers come into play.
state.tsModifier = 'Ethereal Quill'

-- Seat a tradeskill modifier item into the Ammo slot. Verified on Lazarus: the worn-slot
-- click registers WITHOUT the inventory window open, so no invWnd gating is needed.
--   * Idempotent - no-op if `name` is already in Ammo.
--   * If it's only in the bank, pulls one via the proven bankTopUp routine first.
--   * Picking it to cursor and clicking Ammo swaps out any existing ammo item onto the
--     cursor; we /autoinventory that displaced item back into bags.
-- Returns true if the modifier ends up in Ammo, false if it couldn't be found/seated.
-- Worn-slot save/restore. When we swap something into a worn slot for a run (a fishing pole
-- into the primary/mainhand, a trophy/modifier into ammo), we record what was there FIRST, then
-- put it back when the run ends (Stop or natural finish). savedSlots is reset at the start of a
-- run and drained by restore_saved_slots in the run's cleanup. Uses raw mq.delay (never the
-- check_stop `delay`) so it still runs after a Stop has already fired __TS_STOP__.
state.savedSlots = {}
state.remember_slot = function(slot)
    state.savedSlots = state.savedSlots or {}
    if state.savedSlots[slot] == nil then   -- nil = not recorded yet; '' = recorded as empty
        state.savedSlots[slot] = mq.TLO.Me.Inventory(slot).Name() or ''
    end
end
state.restore_saved_slots = function()
    if not state.savedSlots then return end
    for slot, original in pairs(state.savedSlots) do
        original = original or ''
        if (mq.TLO.Me.Inventory(slot).Name() or '') ~= original then
            if cursor_id() ~= 0 then mq.cmd('/autoinventory'); mq.delay(600, function() return cursor_id() == 0 end) end
            if cursor_id() == 0 then
                if original ~= '' and item_count(original) >= 1 then
                    mq.cmdf('/itemnotify "%s" leftmouseup', original)          -- pick the original to cursor
                    mq.delay(700, function() return cursor_id() ~= 0 end)
                    if cursor_id() ~= 0 then
                        mq.cmdf('/itemnotify %s leftmouseup', slot)            -- drop it back into the slot
                        mq.delay(700, function() return (mq.TLO.Me.Inventory(slot).Name() or '') == original end)
                    end
                elseif original == '' then
                    mq.cmdf('/itemnotify %s leftmouseup', slot)                -- slot was empty: unequip what's there
                    mq.delay(700, function() return cursor_id() ~= 0 end)
                end
                if cursor_id() ~= 0 then mq.cmd('/autoinventory'); mq.delay(600, function() return cursor_id() == 0 end) end
                if (mq.TLO.Me.Inventory(slot).Name() or '') == original then
                    printf_log('Restored %s slot%s.', slot, original ~= '' and (' (' .. original .. ')') or ' (emptied)')
                end
            end
        end
    end
    -- Whatever got displaced by the restore (the trophy/quill we pulled OUT of ammo) can be left on the
    -- cursor - stow it so a Stop/finish never ends with it stuck there.
    if cursor_id() ~= 0 then mq.cmd('/autoinventory'); mq.delay(600, function() return cursor_id() == 0 end) end
    state.savedSlots = {}
end

-- Put the bag that lived in the kit pack (slot 10) back where it started. The kit swap parks that
-- bag in another top-level slot and leaves the kit in slot 10; this reverses it so inventory ends
-- how it began. No-op if slot 10 already holds the original, or we never recorded/displaced one.
state.restore_kit_pack = function(kitPack)
    kitPack = kitPack or KIT_PACK_DEFAULT
    local orig = state.kitPackOriginalBag
    state.kitPackOriginalBag = nil          -- consume it; a fresh run records again
    if not orig or orig == '' then return end
    if (mq.TLO.Me.Inventory('pack' .. kitPack).Name() or '') == orig then return end   -- already home
    -- Locate the original bag's current top-level slot (the swap parked it in 1-9).
    local from = nil
    for i = 1, 10 do
        if i ~= kitPack and (mq.TLO.Me.Inventory('pack' .. i).Name() or '') == orig then from = i; break end
    end
    if not from then return end             -- couldn't find it (nested/gone) - leave inventory as-is
    clear_cursor()
    -- Pick up the original bag and drop it onto the kit pack: swaps the kit onto the cursor.
    mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', from)
    mq.delay(500, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
    if (mq.TLO.Cursor.ID() or 0) == 0 then return end
    mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', kitPack)
    mq.delay(600, function() return (mq.TLO.Me.Inventory('pack' .. kitPack).Name() or '') == orig end)
    -- The kit is now on the cursor; drop it into the slot the bag vacated.
    if (mq.TLO.Cursor.ID() or 0) > 0 then
        mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', from)
        mq.delay(500, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
    end
    clear_cursor()
    if (mq.TLO.Me.Inventory('pack' .. kitPack).Name() or '') == orig then
        printf_log('Restored %s to slot %d.', orig, kitPack)
    end
end

state.equip_modifier = function(name)
    if not name or name == '' then return true end

    -- Already seated? Done.
    if (mq.TLO.Me.Inventory('ammo').Name() or '') == name then
        return true
    end

    -- Ensure it's on-hand: if it's only banked, retrieve one stack first.
    if item_count(name) < 1 then
        local banked = 0
        local ok, n = pcall(function() return mq.TLO.FindItemBankCount('=' .. name)() end)
        if ok and type(n) == 'number' then banked = n end
        if banked > 0 then
            printf_log('Modifier %s is in the bank - retrieving...', name)
            state.bankTopUp(name, 1)
        end
    end
    if item_count(name) < 1 then
        printf_log('\arModifier %s not found in bags or bank - skipping equip.\ax', name)
        return false
    end

    state.remember_slot('ammo')   -- record what was in ammo so we can put it back at run's end

    -- Pick to cursor.
    if not clear_cursor() then
        printf_log('\arCursor not empty - cannot equip %s right now.\ax', name)
        return false
    end
    mq.cmdf('/itemnotify "%s" leftmouseup', name)
    mq.delay(600, function() return cursor_id() ~= 0 end)
    if cursor_id() == 0 then
        printf_log('\arCould not pick up %s to equip.\ax', name)
        return false
    end

    -- Drop into Ammo (swaps any existing ammo item onto the cursor), then bag whatever
    -- got displaced.
    mq.cmd('/itemnotify ammo leftmouseup')
    mq.delay(600, function() return (mq.TLO.Me.Inventory('ammo').Name() or '') == name end)
    if cursor_id() ~= 0 then
        mq.cmd('/autoinventory')
        mq.delay(600, function() return cursor_id() == 0 end)
    end

    local seated = (mq.TLO.Me.Inventory('ammo').Name() or '') == name
    if seated then
        printf_log('\agEquipped tradeskill modifier:\ax %s (Ammo slot).', name)
    else
        printf_log('\arFailed to seat %s in Ammo.\ax', name)
    end
    return seated
end

-- Tradeskill trophies. Keyed by the recipe's Container (the canonical skill signal - recipes
-- carry no Skill= field). Each trophy seats in the Ammo slot (same as the research quill) and
-- is REQUIRED once the matching skill is past 300; those high-trivial combines can't be made
-- without it. `skill` is the [Skill:x] section name; the live EQ skill is read via that
-- section's Skill= value. Containers with no trophy (Medicine Bag/Alchemy, Spell Research Kit,
-- Toolbox) are absent and simply skipped.
-- `better` is an OPTIONAL higher tier, best-first: if you own one (bags or bank) it's used instead
-- of `trophy`. The base `trophy` stays the fallback and the thing we hard-stop on, so a character
-- without the new tier behaves exactly as before. Adding a tier is one line here.
state.TROPHY_BY_CONTAINER = {
    ['Blacksmithing']        = { skill = 'Blacksmithing', trophy = "Blacksmith's Adamantine Hammer",
                                 better = { "Solusek Mining Co. Pioneer's Pick" } },   -- +18% vs +15%
    ['Sewing Kit']           = { skill = 'Tailoring',     trophy = 'Mystical Bolt' },
    ['Pottery Wheel']        = { skill = 'Pottery',       trophy = "Clay Flinger's Loop" },
    ['Kiln']                 = { skill = 'Pottery',       trophy = "Clay Flinger's Loop" },
    ['Oven']                 = { skill = 'Baking',        trophy = "Denmother's Rolling Pin" },
    ['Mixing Bowl']          = { skill = 'Baking',        trophy = "Denmother's Rolling Pin" },
    ["Jeweler's Kit"]        = { skill = 'Jewelcrafting', trophy = "Intricate Jewelers Glass" },
    ['Fletching Kit']        = { skill = 'Fletching',     trophy = "Fletcher's Arrow" },
    ['Planar Fletching Kit'] = { skill = 'Fletching',     trophy = "Fletcher's Arrow" },
    ['Brew Barrel']          = { skill = 'Brewing',       trophy = "Brewmaster's Mug" },
    ['Brewing Barrel']       = { skill = 'Brewing',       trophy = "Brewmaster's Mug" },
    ['Mortar and Pestle']    = { skill = 'Make Poison',   trophy = 'Peerless Pestle' },
}

-- The trophy to actually use for a container: the first `better` tier you OWN (bags or bank),
-- otherwise the base `trophy`. Bank counts, because a trophy sitting in the bank gets pulled by the
-- up-front ensure_trophies_for_tree pass just like the base one - so a Pioneer's Pick in the bank is
-- found, withdrawn and equipped, and the Adamantine Hammer is simply left where it is (nothing sells
-- or banks it; it just stops being the one we ask for). Every trophy decision routes through here so
-- the pre-pull, the equip, and the "not in bags or bank" hard stop all agree on the same item.
state.best_trophy_for = function(map)
    if not map then return nil end
    for _, t in ipairs(map.better or {}) do
        if item_count(t) > 0 then return t end
        local ok, n = pcall(function() return mq.TLO.FindItemBankCount('=' .. t)() end)
        if ok and type(n) == 'number' and n > 0 then return t end
        if (mq.TLO.Me.Inventory('ammo').Name() or '') == t then return t end   -- already wearing it
    end
    return map.trophy
end

-- OPTIONAL leveling-phase modifiers (the Geerlok tinkered tools + a couple of better
-- alternatives). Unlike TROPHY_BY_CONTAINER above (the +15% quest trophies, REQUIRED at the
-- 300 cap), these are the +5% aids you use ON THE WAY to 300 and are ALWAYS optional: we
-- equip the best one you own for the skill being leveled and simply skip if you own none -
-- a run is never blocked for lack of one. Keyed by skill name (the SKILL_SECTION_BY_CONTAINER
-- value); listed best-first so a better item is preferred when you have it. They apply DURING
-- leveling (the cap trophies are skipped then); leveling stops at 300, so the two tiers never
-- fight over the Ammo slot.
state.LEVELING_MODIFIER_BY_SKILL = {
    Tinkering       = { 'Geerlok Clockwork Contraption' },
    Alchemy         = { 'Geerlok Alchemy Set' },
    ['Make Poison'] = { 'Geerlok Automated Pestle' },
    Research        = { 'Geerlok Automated Quill' },
    Blacksmithing   = { 'Hammer of the Ironfrost', 'Smithy Hammer' },      -- Ironfrost preferred
    Tailoring       = { 'Akhevan Shadow Shears', 'Geerlok Sewing Contraption' },  -- Shears preferred
    Baking          = { 'Geerlok All Purpose Baking Utensil' },
    Brewing         = { 'Geerlok Fermentation Device' },
    Fletching       = { 'Geerlok Planing Tool' },
    Jewelcrafting   = { 'Geerlok Gem Setter' },
    Pottery         = { 'Geerlok Sculpting Tools' },
}

-- Equip the best owned leveling modifier for a skill. Soft: if you own none it does nothing
-- and never fails the run. Called at the start of a leveling run for the skill being leveled.
state.ensure_leveling_modifier = function(skillName)
    local prefs = skillName and state.LEVELING_MODIFIER_BY_SKILL[skillName]
    if not prefs then return end
    local function owned(m)
        if item_count(m) > 0 then return true end
        local ok, n = pcall(function() return mq.TLO.FindItemBankCount('=' .. m)() end)
        return (ok and type(n) == 'number' and n > 0) or false
    end
    local best
    for _, m in ipairs(prefs) do
        if owned(m) then best = m; break end
    end
    if not best then return end                                             -- own none: level without one
    if (mq.TLO.Me.Inventory('ammo').Name() or '') == best then return end   -- already wearing it
    printf_log('Leveling %s: equipping your %s (+skill aid).', skillName, best)
    state.equip_modifier(best)   -- soft (pulls from bank if needed); if it can't seat, we just proceed
end

-- Before a combine, make sure the right trophy is seated for the container we're about to use.
-- Trophies apply only to DELIBERATE crafting (Craft/Radix); a leveling-tab run skips them
-- entirely (state.runIsLeveling) - leveling products are throwaway and you won't own the
-- trophies anyway. Otherwise: invoke at skill >= 300, skip below. By the time we get here the
-- up-front pull (ensure_trophies_for_tree) has already withdrawn every trophy the tree needs
-- into bags, so this normally just swaps from bags. The bank/hard-stop path below stays as a
-- defensive fallback. No-op for containers with no trophy. Returns true to proceed.
state.TROPHY_THRESHOLD = 300
state.runIsLeveling = false
state.ensure_trophy = function(containerStr)
    if state.runIsLeveling then return true end   -- leveling run: never touch a trophy
    local first = trim(split_commas(containerStr or '')[1] or '')
    if first == '' then return true end
    local map = state.TROPHY_BY_CONTAINER[first]
    if not map then return true end   -- no trophy for this container (Alchemy/Research/Tinkering)

    -- Gate on the live skill, read via the [Skill:x] section's EQ skill name.
    local sec = (state.iniSections or {})['Skill:' .. map.skill]
    local eqName = (sec and sec.Skill) or map.skill
    local lvl = skill_value(eqName) or 0
    if lvl < state.TROPHY_THRESHOLD then return true end   -- below cap, trophy not needed

    -- Pick the tier we'll actually use: a `better` trophy you own (bags or bank) beats the base one.
    local want = state.best_trophy_for(map)

    -- Already seated? Done (no bank trip).
    if (mq.TLO.Me.Inventory('ammo').Name() or '') == want then return true end

    -- Truly absent (not in bags and not in bank) -> hard stop.
    local have = item_count(want)
    if have < 1 then
        local ok, n = pcall(function() return mq.TLO.FindItemBankCount('=' .. want)() end)
        local banked = (ok and type(n) == 'number') and n or 0
        if banked < 1 then
            printf_log("\ar==== STOP ====\ax")
            printf_log("\arNeed '%s' (the %s trophy) for this combine - your %s skill is at the cap (%d) so it's required, but it's not in your bags or bank.\ax",
                want, map.skill, map.skill, lvl)
            printf_log("\arGo grab '%s' from PoK, put it in your bank, then restart.\ax", want)
            return false
        end
    end

    -- Present somewhere -> seat it (equip_modifier handles the bank pull + Ammo swap).
    if state.equip_modifier(want) then return true end
    printf_log("\arCould not seat '%s' into Ammo (clear your cursor and retry). Aborting.\ax", want)
    return false
end

-- Walk a recipe's full combine tree and collect the DISTINCT trophies its combines will need
-- (every container that has a trophy, for a skill currently >= 300). Not cached - the set
-- depends on live skill. Returns a list of { trophy, skill }.
state.trophiesInTree = function(rec)
    if not rec then return {} end
    local list, seen = {}, {}
    local function consider(containerStr)
        local first = trim(split_commas(containerStr or '')[1] or '')
        local map = state.TROPHY_BY_CONTAINER[first]
        if not map then return end
        local want = state.best_trophy_for(map)   -- pull the tier we'll actually equip
        if seen[want] then return end
        local sec = (state.iniSections or {})['Skill:' .. map.skill]
        local eqName = (sec and sec.Skill) or map.skill
        if (skill_value(eqName) or 0) >= state.TROPHY_THRESHOLD then
            seen[want] = true
            list[#list + 1] = { trophy = want, skill = map.skill }
        end
    end
    local function walk(r, depth)
        if not r or depth > 8 then return end
        local rs = (state.iniSections or {})['Recipe:' .. (r.key or r.name)]
        if rs then consider(rs.Container) end
        for _, ing in ipairs(r.ingredients) do
            if (state.iniSections or {})['Recipe:' .. ing.name] then
                walk(get_recipe(ing.name), depth + 1)
            end
        end
    end
    walk(rec, 0)
    return list
end

-- All |returned tool names anywhere in a craft tree (deduped). Used to pull them from the bank
-- during the trophy trip instead of making/buying fresh ones - they accumulate in the bank.
state.returnedToolsInTree = function(rec)
    if not rec then return {} end
    local list, seen = {}, {}
    local function walk(r, depth)
        if not r or depth > 8 then return end
        for _, ing in ipairs(r.ingredients) do
            if ing.returned and not seen[ing.name] then
                seen[ing.name] = true
                list[#list + 1] = ing.name
            end
            if (state.iniSections or {})['Recipe:' .. ing.name] then
                walk(get_recipe(ing.name), depth + 1)
            end
        end
    end
    walk(rec, 0)
    return list
end

-- Choose ONE zone to run the whole job in, so the pre-buy and the oven we combine at stay in
-- one place instead of bouncing (the vendor picker is per-item and will otherwise scatter across
-- Marr and PoK). Prefer the CURRENT zone if it stocks everything (stay put); else prefer Temple
-- of Marr (its tradeskill vendors cluster near the oven), then PoK. Returns a zone only if that
-- single zone stocks EVERY item we need to buy; if none covers everything, returns nil and the
-- normal per-item routing handles the split.
state.run_zone_for_items = function(items)
    local vm = state.vendorMap or {}
    local function covers_all(z)
        for _, itemName in ipairs(items) do
            local insts = vm[itemName]
            -- Only VENDOR-sold items constrain the buy zone. An item with no vendor entry is
            -- dropped/summoned/mule-supplied (e.g. Brownie Parts, Fruit) - acquired off-vendor,
            -- so it must NOT veto a zone, or we'd never consolidate a tree that contains one.
            if insts then
                local found = false
                for _, inst in ipairs(insts) do
                    if (inst.zone or '') == z then found = true; break end
                end
                if not found then return false end      -- a vendor item this zone doesn't stock
            end
        end
        return true
    end
    local cur = current_zone()
    if covers_all(cur) then return cur end        -- already standing where everything's sold: stay
    if covers_all(ZONE_MARR) then return ZONE_MARR end   -- must travel: prefer Marr
    if covers_all(ZONE_POK)  then return ZONE_POK  end   -- then PoK
    return nil
end

-- Up-front trophy pull for a DELIBERATE (non-leveling) run: before any combine, grab every
-- trophy the whole tree will need from the bank in ONE trip, so per-combine equips just swap
-- from bags (no repeated bank runs). If any needed trophy is in neither bags nor bank, the run
-- HARD-STOPS with the full list -> go grab them in PoK. Returns true to proceed, false to abort.

-- Bank count of an exact item, restricted to what we can ACTUALLY withdraw: the regular bank
-- (slots 1-24 and the bags inside them) - exactly where grab() looks. FindItemBankCount also counts
-- the SHARED bank (and anywhere else grab() can't reach), so trusting it sent us to the bank for a
-- "Cake Round" we could never pull. Falls back to FindItemBankCount ONLY when the regular bank isn't
-- readable at all (no slot reports an ID), so a bank we can't see yet is never wrongly read as empty.
-- FREE and accurate anytime on Laz (no bank trip needed to read).
state.bank_count = function(name)
    -- CACHE (closed bank only): with the window shut, contents can't change (no withdraw possible) and
    -- the read is a slow console echo. So cache per-name and each distinct item echoes just ONCE per
    -- planning pass, instead of once per caller (plan_bank_pulls + dropped_shortfall-per-candidate +
    -- trophy checks all hit the same items). The cache is dropped the instant the bank opens, so once
    -- we start withdrawing, Me.Bank reads are live and always fresh.
    local bankOpen = mq.TLO.Window('BigBankWnd').Open()
    if bankOpen then
        state._bankCache = nil
    else
        state._bankCache = state._bankCache or {}
        if state._bankCache[name] ~= nil then return state._bankCache[name] end
    end

    local up = name:upper()
    local total, visible = 0, false
    for b = 1, 24 do
        local bag = mq.TLO.Me.Bank(b)
        if (bag.ID() or 0) > 0 then
            visible = true
            local slots = bag.Container() or 0
            if slots > 0 then
                for s = 1, slots do
                    if (bag.Item(s).Name() or ''):upper() == up then
                        total = total + math.max(1, bag.Item(s).Stack() or 1)
                    end
                end
            elseif (bag.Name() or ''):upper() == up then
                total = total + math.max(1, bag.Stack() or 1)
            end
        end
    end
    local result
    if visible then
        result = total
    else
        -- Bank closed / uncached: Me.Bank read nothing. FindItemBankCount reads a CLOSED bank correctly
        -- now (verified cold via /laztestbankread - the old build's '0 cold' bug is gone), so read it
        -- straight from the TLO. No console-echo hack needed.
        local ok, n = pcall(function() return mq.TLO.FindItemBankCount('=' .. name)() end)
        result = (ok and type(n) == 'number') and n or 0
    end
    if not bankOpen then state._bankCache[name] = result end
    return result
end

-- TEST: /lazbagtest   -- Open bank bag slot 1 and withdraw its FIRST item, logging every gesture so we
-- can see exactly which step lands (or doesn't land) the item in bags. Uses the crafter's proven
-- open-bag-then-grab sequence (rightmouseup to open, then plain grab - NO /nomodkey). Run it standing
-- at a banker with the slot-1 bank bag holding at least one item.
mq.bind('/lazbagtest', function()
    printf_log('=== /lazbagtest: bank slot 1, first item ===')
    if not mq.TLO.Window('BigBankWnd').Open() then
        printf_log('  bank closed - targeting banker + right-click...')
        mq.cmd('/target npc banker'); mq.delay(700, function() return (mq.TLO.Target.ID() or 0) > 0 end)
        mq.cmd('/click right target'); mq.delay(1500, function() return mq.TLO.Window('BigBankWnd').Open() end)
    end
    printf_log('  BigBankWnd.Open = %s', tostring(mq.TLO.Window('BigBankWnd').Open()))
    if not mq.TLO.Window('BigBankWnd').Open() then printf_log('  cannot open bank - aborting.'); return end

    local bag = mq.TLO.Me.Bank(1)
    printf_log('  Bank(1): id=%d name=%q container_slots=%d', bag.ID() or 0, tostring(bag.Name() or ''), bag.Container() or 0)
    if (bag.Container() or 0) < 1 then printf_log('  bank slot 1 is NOT a container/bag - aborting.'); return end
    local iname = bag.Item(1).Name() or ''
    if iname == '' then printf_log('  slot 1 of the bank bag is empty - aborting.'); return end
    local before = item_count(iname)
    printf_log('  first item = %q (stack %d).  bags before = %d, cursor = %d', iname, bag.Item(1).Stack() or 1, before, mq.TLO.Cursor.ID() or 0)

    printf_log('  [1] /itemnotify bank1 rightmouseup   (open the bag)')
    mq.cmd('/itemnotify bank1 rightmouseup'); mq.delay(350)

    printf_log('  [2] /itemnotify in bank1 1 leftmouseup   (grab - no nomodkey)')
    mq.cmd('/itemnotify in bank1 1 leftmouseup')
    mq.delay(800, function() return (mq.TLO.Cursor.ID() or 0) > 0 or mq.TLO.Window('QuantityWnd').Open() end)
    printf_log('      -> cursor=%d (%s)  QuantityWnd.Open=%s', mq.TLO.Cursor.ID() or 0, tostring(mq.TLO.Cursor.Name() or ''), tostring(mq.TLO.Window('QuantityWnd').Open()))

    if mq.TLO.Window('QuantityWnd').Open() then
        printf_log('  [3] split window popped - accepting whole amount')
        mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
        mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
        printf_log('      -> cursor=%d', mq.TLO.Cursor.ID() or 0)
    end

    if (mq.TLO.Cursor.ID() or 0) > 0 then
        printf_log('  [4] /autoinventory   (stash to bags)')
        mq.cmd('/autoinventory'); mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
    end

    local after = item_count(iname)
    printf_log('  RESULT: bags %d -> %d (delta %+d), cursor now=%d', before, after, after - before, mq.TLO.Cursor.ID() or 0)
    printf_log(after > before and '  >>> SUCCESS: the item moved into bags.' or '  >>> FAIL: nothing landed - note the last step above that changed cursor/window state.')
end)

-- DIAG PROBE: /tsbankprobe <Encoded_Item>   e.g.  /tsbankprobe Denmother's_Rolling_Pin  (spaces as _)
-- Read-only. Reports what every bank-read path sees for one item, so we can tell WHY a banked trophy
-- reads as "not in bank". Run it ONCE in the state the craft hits it (bank window CLOSED), then open
-- your bank manually and run it AGAIN - compare. If closed reads 0 and open reads >0, the pre-check is
-- trusting bank data that isn't cached until the window has been opened at least once.
mq.bind('/tsbankprobe', function(encoded)
    if not encoded then printf_log('usage: /tsbankprobe <Encoded_Item>  (spaces as _)'); return end
    local name = namecodec.decode(encoded)
    local up = name:upper()
    local anyID = false
    for b = 1, 24 do if (mq.TLO.Me.Bank(b).ID() or 0) > 0 then anyID = true; break end end
    local function fibc(q)
        local ok, n = pcall(function() return mq.TLO.FindItemBankCount(q)() end)
        return (ok and type(n) == 'number') and n or -1
    end
    printf_log('=== tsbankprobe: %s ===', name)
    printf_log('  BigBankWnd.Open = %s', tostring(mq.TLO.Window('BigBankWnd').Open()))
    printf_log('  bags item_count = %d', item_count(name))
    printf_log('  state.bank_count = %d   (this is what bankTopUp gates on)', state.bank_count(name))
    printf_log('  Me.Bank readable (any slot 1-24 has an ID) = %s', tostring(anyID))
    printf_log('  FindItemBankCount[=%s] = %d', name, fibc('=' .. name))
    printf_log('  FindItemBankCount[%s]  = %d  (partial match)', name, fibc(name))
    local shown = 0
    for b = 1, 24 do
        local bag = mq.TLO.Me.Bank(b)
        if (bag.ID() or 0) > 0 then
            shown = shown + 1
            local slots = bag.Container() or 0
            if slots > 0 then
                local hit = ''
                for s = 1, slots do
                    if (bag.Item(s).Name() or ''):upper() == up then hit = string.format('  <-- FOUND in slot %d', s) end
                end
                printf_log('  bank[%d] = %s (bag, %d slots)%s', b, bag.Name() or '?', slots, hit)
            else
                printf_log('  bank[%d] = %s x%d%s', b, bag.Name() or '?', (bag.Stack() or 1),
                    ((bag.Name() or ''):upper() == up) and '  <-- FOUND' or '')
            end
        end
    end
    if shown == 0 then printf_log('  (no readable bank slots - bank data not cached; open the bank once and re-run)') end
    printf_log('=== tsbankprobe done ===')
end)

-- Plan bank withdrawals for a whole craft tree. Fills `pulls` (name -> qty to withdraw). For each
-- ingredient: use what's on hand first, then pull the shortfall from the bank (up to what's banked).
-- If it's a subcombine the bank can't fully cover, recurse for ONLY the portion we'll actually MAKE
-- - so a finished product sitting in the bank (e.g. Celestial Cleanser) gets pulled and its entire
-- subtree is pruned. `reserved` keeps shared ingredients across branches from being counted twice.
state.plan_bank_pulls = function(rec, qty, pulls, reserved, depth)
    depth = depth or 0
    if not rec or not rec.ingredients or depth > 8 then return end
    for _, ing in ipairs(rec.ingredients) do
        if not ing.returned then
            local need = (ing.qty or 1) * qty
            local handAvail = math.max(0, item_count(ing.name) - (reserved.hand[ing.name] or 0))
            local useHand = math.min(need, handAvail)
            reserved.hand[ing.name] = (reserved.hand[ing.name] or 0) + useHand
            local short = need - useHand
            if short > 0 then
                local banked = math.max(0, state.bank_count(ing.name) - (reserved.bank[ing.name] or 0))
                local pull = math.min(short, banked)
                if pull > 0 then
                    pulls[ing.name] = (pulls[ing.name] or 0) + pull
                    reserved.bank[ing.name] = (reserved.bank[ing.name] or 0) + pull
                end
                local remaining = short - pull
                if remaining > 0 then
                    local subRec = get_recipe(ing.name)
                    if subRec then
                        local yield = subRec.yield or 1
                        if yield < 1 then yield = 1 end
                        state.plan_bank_pulls(subRec, math.ceil(remaining / yield), pulls, reserved, depth + 1)
                    end
                end
            end
        end
    end
end

state.ensure_trophies_for_tree = function(rec, qty)
    qty = qty or 1

    -- Plan every bank withdrawal up front from FREE reads (no trip): returned tools, plus every
    -- ingredient AND subcombine-product shortfall the bank can cover. We only travel if there's
    -- actually something to pull.
    local pulls = {}                              -- item name -> qty to withdraw
    local reserved = { hand = {}, bank = {} }
    pcall(function() state.plan_bank_pulls(rec, qty, pulls, reserved, 0) end)
    for _, tool in ipairs(state.returnedToolsInTree(rec)) do
        if item_count(tool) < 1 and (pulls[tool] or 0) == 0 and state.bank_count(tool) > 0 then
            pulls[tool] = 1
        end
    end

    -- Trophies (skipped on leveling runs) - these HARD-STOP the run if missing.
    local trophyNeeded = state.runIsLeveling and {} or state.trophiesInTree(rec)
    local trophiesToPull, ammo = {}, (mq.TLO.Me.Inventory('ammo').Name() or '')
    for _, t in ipairs(trophyNeeded) do
        if item_count(t.trophy) < 1 and ammo ~= t.trophy then trophiesToPull[#trophiesToPull + 1] = t end
    end

    if not next(pulls) and #trophiesToPull == 0 then return true end   -- nothing banked to get: no trip

    -- ONE trip, ONE open window: trophies first (they can hard-stop), then all planned pulls. Both use
    -- withdraw_count, which opens the bank via reach_and_open_bank (a no-op once it's already open) and
    -- leaves it open - so the whole list is grabbed on a single bank visit. (bankTopUp used to CLOSE the
    -- window every call, which reopened the bank once per trophy - that was the repeated open/close.)
    local missing = {}
    for _, t in ipairs(trophiesToPull) do
        check_stop()
        state.withdraw_count(t.trophy, 1)
        if item_count(t.trophy) < 1 then missing[#missing + 1] = t end
    end
    for name, n in pairs(pulls) do
        check_stop()
        local got = state.withdraw_count(name, n)
        if got > 0 then printf_log('Bank: pulled %d x %s (skipping buy/make).', got, name) end
    end

    -- Done at the bank: CLOSE the window. withdraw_count/reach_and_open_bank leave it open (only
    -- bankTopUp closed it), so we'd walk off - and then ask the group for supplies - with the bank
    -- still up on the crafter. Close before we move or send any tells.
    if mq.TLO.Window('BigBankWnd').Open() then
        mq.cmd('/notify BigBankWnd DoneButton leftmouseup')
        mq.delay(500, function() return not mq.TLO.Window('BigBankWnd').Open() end)
    end

    -- Leave the banker via the safe waypoint once the whole trip is done (this is the single bank
    -- visit), so the next leg - stations especially - starts from clean ground. No-op if none is near.
    do
        local myloc = string.format('%.2f %.2f %.2f', mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0, mq.TLO.Me.Z() or 0)
        local wp = state.approach_waypoint_for(myloc, current_zone())
        if wp then
            printf_log('Leaving the bank via the safe waypoint...')
            state.nav_loc_wait(wp)
        end
    end

    if #missing > 0 then
        printf_log('\ar==== STOP: missing tradeskill trophies ====\ax')
        for _, t in ipairs(missing) do
            printf_log("\ar  need '%s' (%s) - not in bags or bank\ax", t.trophy, t.skill)
        end
        printf_log('\arGrab them in PoK, put them in your bank, then restart this craft.\ax')
        return false
    end
    return true
end

-- Batch bank pre-pass: the "one bank run for the whole list" pass. Given a set of craft trees
-- ({ {rec=, qty=}, ... }), pull EVERYTHING they need from the bank in ONE visit - trophies, returned
-- tools, and every ingredient/subcombine shortfall the bank can cover across ALL trees, with a shared
-- `reserved` so a mat two trees need isn't double-pulled. Same plan-from-free-reads-then-one-trip shape
-- as ensure_trophies_for_tree, just unioned across the batch. After it runs, each tree's own
-- ensure_trophies_for_tree finds it all on-hand and makes no trip of its own. Returns false only when a
-- REQUIRED trophy is missing from both bags and bank (hard stop), true otherwise.
state.ensure_bank_for_trees = function(trees)
    local pulls = {}                              -- item name -> qty to withdraw (unioned)
    local reserved = { hand = {}, bank = {} }
    local trophiesToPull, seenTrophy = {}, {}
    local ammo = mq.TLO.Me.Inventory('ammo').Name() or ''

    for _, t in ipairs(trees or {}) do
        local rec, qty = t.rec, t.qty or 1
        if rec then
            pcall(function() state.plan_bank_pulls(rec, qty, pulls, reserved, 0) end)
            for _, tool in ipairs(state.returnedToolsInTree(rec)) do
                if item_count(tool) < 1 and (pulls[tool] or 0) == 0 and state.bank_count(tool) > 0 then
                    pulls[tool] = 1
                end
            end
            if not state.runIsLeveling then
                for _, tr in ipairs(state.trophiesInTree(rec)) do
                    if not seenTrophy[tr.trophy] and item_count(tr.trophy) < 1 and ammo ~= tr.trophy then
                        seenTrophy[tr.trophy] = true
                        trophiesToPull[#trophiesToPull + 1] = tr
                    end
                end
            end
        end
    end

    if not next(pulls) and #trophiesToPull == 0 then return true end   -- nothing banked to get: no trip

    -- ONE trip, ONE open window: trophies first (they hard-stop), then all planned pulls. withdraw_count
    -- opens the bank via reach_and_open_bank (which routes through the safe hub) and leaves it open, so
    -- the whole list is grabbed on a single visit.
    local missing = {}
    for _, tr in ipairs(trophiesToPull) do
        check_stop()
        state.withdraw_count(tr.trophy, 1)
        if item_count(tr.trophy) < 1 then missing[#missing + 1] = tr end
    end
    for name, n in pairs(pulls) do
        check_stop()
        local got = state.withdraw_count(name, n)
        if got > 0 then printf_log('Bank: pulled %d x %s (batch pre-pass).', got, name) end
    end

    -- Close the bank and step off via the safe hub (withdraw_count leaves the window open).
    if mq.TLO.Window('BigBankWnd').Open() then
        mq.cmd('/notify BigBankWnd DoneButton leftmouseup')
        mq.delay(500, function() return not mq.TLO.Window('BigBankWnd').Open() end)
    end
    do
        local myloc = string.format('%.2f %.2f %.2f', mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0, mq.TLO.Me.Z() or 0)
        local wp = state.approach_waypoint_for(myloc, current_zone())
        if wp then printf_log('Leaving the bank via the safe waypoint...'); state.nav_loc_wait(wp) end
    end

    if #missing > 0 then
        printf_log('\ar==== STOP: missing tradeskill trophies ====\ax')
        for _, tr in ipairs(missing) do
            printf_log("\ar  need '%s' (%s) - not in bags or bank\ax", tr.trophy, tr.skill)
        end
        printf_log('\arGrab them in PoK, put them in your bank, then restart.\ax')
        return false
    end
    return true
end

-- Walk to a banker and open the bank window. Returns true if the bank is open. Uses the same
-- hardened banker nav as bankTopUp (a dropped /nav after moving around was stranding us).
state.reach_and_open_bank = function()
    if mq.TLO.Window('BigBankWnd').Open() then return true end
    state.target_banker()   -- Dogle Pitt in PoK; nearest banker elsewhere
    if (mq.TLO.Target.ID() or 0) == 0 then
        printf_log('Bank: no banker in this zone.')
        return false
    end
    if (mq.TLO.Target.Distance() or 999) > 10 then
        local bid = mq.TLO.Target.ID() or 0
        -- Route through the safe hub: leave our current cluster's hub first (if we're in one), then
        -- approach the banker's hub.
        state.route_bank_via_hub()
        state.pre_nav()
        mq.cmdf('/nav id %d', bid)
        local engaged, startD = false, mq.gettime() + 3000
        while mq.gettime() < startD do
            if mq.TLO.Navigation.Active() then engaged = true; break end
            if (mq.TLO.Target.Distance() or 999) <= 10 then break end
            mq.delay(100)
        end
        if not engaged and (mq.TLO.Target.Distance() or 999) > 10 then
            mq.cmdf('/nav id %d', bid)
            local r = mq.gettime() + 3000
            while mq.gettime() < r do
                if mq.TLO.Navigation.Active() then break end
                if (mq.TLO.Target.Distance() or 999) <= 10 then break end
                mq.delay(100)
            end
        end
        local deadline = mq.gettime() + 15000
        while mq.gettime() < deadline do
            if not mq.TLO.Navigation.Active() then break end
            mq.doevents(); mq.delay(100)
        end
    end
    if (mq.TLO.Target.Distance() or 999) > 10 then
        printf_log('Bank: could not reach the banker.')
        return false
    end
    if not mq.TLO.Window('BigBankWnd').Open() then
        mq.cmd('/click right target')
        mq.delay(1000, function() return mq.TLO.Window('BigBankWnd').Open() end)
        state.bank_bag_opened = {}   -- fresh open: reset the per-trip opened-bag set
    end
    if not mq.TLO.Window('BigBankWnd').Open() then
        printf_log('Bank: could not open the bank window.')
        return false
    end
    state.bankSeenThisRun = true
    return true
end

-- First empty slot INSIDE a bank bag (containers nest on Laz, so items live in bank bags, not the
-- 24 top-level slots). Returns bagIdx, slotIdx or nil. Used to place deposits without swapping onto
-- whatever already occupies a slot.
local function first_empty_bank_slot()
    for b = 1, 24 do
        local bag = mq.TLO.Me.Bank(b)
        local slots = bag.Container() or 0
        if slots > 0 then
            for s = 1, slots do
                if (bag.Item(s).ID() or 0) == 0 then return b, s end
            end
        end
    end
    return nil
end

-- Deposit a held item/container into the first EMPTY bank-bag slot. /itemnotify onto an occupied
-- slot swaps (the old item lands on the cursor and you walk off with it), so we find a real empty
-- slot, then re-check it's still empty at drop time and back out (autoinventory) if not.
state.deposit_to_bank = function(name)
    if not state.reach_and_open_bank() then return false end
    if (mq.TLO.FindItemCount('=' .. name)() or 0) == 0 then
        printf_log('Bank: no %s in bags to deposit.', name); return false
    end
    local b, s = first_empty_bank_slot()
    if not b then printf_log('Bank: full - no empty bag slot for %s.', name); return false end
    clear_cursor()
    mq.cmdf('/itemnotify "%s" leftmouseup', name)
    mq.delay(600, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
    if (mq.TLO.Cursor.ID() or 0) == 0 then printf_log('Bank: could not pick up %s.', name); return false end
    if (mq.TLO.Me.Bank(b).Item(s).ID() or 0) ~= 0 then mq.cmd('/autoinventory'); return false end  -- no longer empty
    mq.cmdf('/nomodkey /itemnotify in bank%d %d leftmouseup', b, s)
    mq.delay(600, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
    if (mq.TLO.Cursor.ID() or 0) ~= 0 then          -- a swap happened - put it back, don't wander off
        mq.cmd('/autoinventory'); printf_log('Bank: slot was not empty for %s - aborted.', name); return false
    end
    printf_log('Deposited %s into bank%d slot %d.', name, b, s)
    return true
end

-- Withdraw an EXACT count of a stackable item from the bank. A plain grab opens the QuantityWnd; we
-- set its slider to n and Accept (confirmed working on Laz). If n >= the whole stack, the window may
-- not open at all (it just grabs everything) - which is fine. n is clamped to what's actually banked.
state.withdraw_count = function(name, n)
    n = math.max(1, math.floor(n or 1))
    -- Check remotely first: only what's grabbable from the REGULAR bank counts (state.bank_count
    -- excludes shared-bank copies we can't actually pull) - don't walk over for nothing.
    local banked = state.bank_count(name)
    if banked <= 0 then printf_log('Bank: no %s banked.', name); return 0 end
    if not state.reach_and_open_bank() then return 0 end
    if n > banked then n = banked end

    local upper = name:upper()
    local before = item_count(name)
    clear_cursor()
    mq.delay(30)

    -- Find the item's bank slot (nested bag or top-level) and grab it. A plain grab pops the split
    -- window; the KEY is setting the amount via the TLO SetText method (NOT /notify settext, which is
    -- an invalid notification) - that was the "pulled the whole stack" bug all along.
    local grabbedStack = 0   -- the grabbed slot's stack size (set by grab), decides split handling
    local grabbedBag, grabbedSlot = 0, 0   -- nested bank bag + slot we grabbed from (for closed-bag recovery)
    local function grab()
        for b = 1, 24 do
            local bag = mq.TLO.Me.Bank(b)
            if (bag.ID() or 0) > 0 then
                local slots = bag.Container() or 0
                if slots > 0 then
                    for sidx = 1, slots do
                        if (bag.Item(sidx).Name() or ''):upper() == upper then
                            -- BASELINE RULE: only a PARTIAL pull of a stack needs the split window
                            -- (bag open). A whole-stack pull, or a non-stackable (Stack()==1), grabs
                            -- straight from a closed bag.
                            grabbedStack = bag.Item(sidx).Stack() or 1
                            grabbedBag, grabbedSlot = b, sidx
                            if n < grabbedStack then state.ensure_bank_bag_open(b) end   -- partial opens; whole leaves the bag as-is
                            mq.cmdf('/itemnotify in bank%d %d leftmouseup', b, sidx); return true
                        end
                    end
                elseif (bag.Name() or ''):upper() == upper then
                    grabbedStack = bag.Stack() or 1
                    grabbedBag, grabbedSlot = 0, 0
                    mq.cmdf('/itemnotify bank%d leftmouseup', b); return true
                end
            end
        end
        return false
    end
    -- Restored to the simple version that pulled exactly 2, reliably (build -p): grab, wait for the
    -- split window, set the amount, accept. No retry/put-back loop (that regressed it).
    if not grab() then printf_log('Bank: could not locate %s to grab.', name); return 0 end
    -- GATE, don't flat-wait: proceed the instant the split window (or cursor) appears. If nothing
    -- landed in a short beat, the bag opened late - re-fire the grab now that it's surely open, then
    -- gate again. Self-correcting, so the ensure-open delay stays short and the fast case is fast.
    mq.delay(800, function() return mq.TLO.Window('QuantityWnd').Open() or (mq.TLO.Cursor.ID() or 0) > 0 end)
    -- Re-grab ONLY on a TOTAL miss (nothing landed at all - bag opened late / was closed), not just
    -- because the split window is slow. The old eager short-gate re-grabbed on every partial and cost
    -- an extra round-trip each time.
    if not mq.TLO.Window('QuantityWnd').Open() and (mq.TLO.Cursor.ID() or 0) == 0 then
        grab()
        mq.delay(800, function() return mq.TLO.Window('QuantityWnd').Open() or (mq.TLO.Cursor.ID() or 0) > 0 end)
    end
    -- CLOSED-BAG RECOVERY: partial wanted but no split popped and we grabbed the WHOLE stack -> the bag was
    -- closed (an ensure_bank_bag_open toggle shut an already-open bag). Put the stack back, force the bag
    -- open, and regrab so the split pops. One toggle doesn't always land, so try up to 3 times. Fires only
    -- on this exact symptom, so a normal partial pays nothing; without it we'd stow the whole stack.
    for attempt = 1, 3 do
        if not (n < grabbedStack and grabbedBag > 0 and not mq.TLO.Window('QuantityWnd').Open()
                and (mq.TLO.Cursor.ID() or 0) > 0) then break end
        printf_log('  partial split did not pop (bag closed) - returning stack, reopening bag, regrab %d...', attempt)
        mq.cmdf('/itemnotify in bank%d %d leftmouseup', grabbedBag, grabbedSlot)   -- deposit the stack back
        mq.delay(500, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
        state.bank_bag_opened[grabbedBag] = nil                                    -- clear cache so we TRULY reopen
        state.ensure_bank_bag_open(grabbedBag)
        grab()
        mq.delay(800, function() return mq.TLO.Window('QuantityWnd').Open() or (mq.TLO.Cursor.ID() or 0) > 0 end)
    end
    -- Fail-safe: if the split STILL never popped and we're holding the whole stack, return it to the bank
    -- and bail (0) rather than stow it - never over-pull.
    if n < grabbedStack and grabbedBag > 0 and not mq.TLO.Window('QuantityWnd').Open()
       and (mq.TLO.Cursor.ID() or 0) > 0 then
        mq.cmdf('/itemnotify in bank%d %d leftmouseup', grabbedBag, grabbedSlot)
        mq.delay(500, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
        printf_log('Bank: could not open bag to split %s after retries - skipping (no over-pull).', name)
        return 0
    end
    if mq.TLO.Window('QuantityWnd').Open() then
      if n >= grabbedStack then
        -- WHOLE stack: accept the split's DEFAULT (the full stack), the way TurboGive's
        -- HandleBankQuantityWindow does. SetText-ing n>=stack just fails the slider max and
        -- cancels (the 'reads 995' bug).
        mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
        mq.delay(500, function() return not mq.TLO.Window('QuantityWnd').Open() end)
      else
        -- Set the amount, then WAIT until the field actually reads n before accepting (accepting early
        -- takes the full-stack default - that was the bug). Issue the /invoke ONCE, then poll the cheap
        -- text read; only re-issue occasionally if it hasn't committed. The extra /invoke calls were
        -- the slow part.
        local want = tostring(n)
        local set  = false
        local fld  = mq.TLO.Window('QuantityWnd/QTYW_SliderInput')
        -- Direct TLO setter (fast, one-shot). Safe now that the closed-bag recovery above guarantees the
        -- split window is really open before we set the amount - the earlier over-pull was a whole-stack
        -- grab with NO split getting stowed, not the setter itself.
        fld.SetText(want)()
        local deadline, ticks = mq.gettime() + 1000, 0
        repeat
            if (fld.Text() or '') == want then set = true; break end
            mq.delay(20)
            ticks = ticks + 1
            if ticks % 8 == 0 then fld.SetText(want)() end   -- re-issue occasionally if it hasn't stuck
        until mq.gettime() > deadline
        if not set then
            printf_log('Bank: could not set qty to %d for %s (reads %s) - cancelling to avoid over-pull.',
                n, name, tostring(mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text()))
            mq.cmd('/keypress esc')   -- the REAL cancel; QTYW_Cancel_Button is invalid and PULLS THE STACK
            mq.delay(300, function() return not mq.TLO.Window('QuantityWnd').Open() end)
            return 0
        end
        mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
        mq.delay(500, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
      end
    end
    -- Stow the grab: /autoinventory, then poll the cursor tightly and re-fire every 100ms if the first
    -- fire didn't take (it often no-ops for a beat right after the split accept). Clears the instant it stows.
    if (mq.TLO.Cursor.ID() or 0) > 0 then
        mq.cmd('/autoinventory')
        local t0, lastFire = mq.gettime(), mq.gettime()
        while (mq.TLO.Cursor.ID() or 0) > 0 and (mq.gettime() - t0) < 1500 do
            mq.delay(10)
            if (mq.TLO.Cursor.ID() or 0) > 0 and (mq.gettime() - lastFire) > 100 then
                mq.cmd('/autoinventory'); lastFire = mq.gettime()
            end
        end
    end
    local got = item_count(name) - before
    printf_log('Withdrew %d x %s (asked %d).', got, name, n)
    return got
end

-- Every item flagged |returned in any recipe (cached) - the returned-tool set, used both to bank
-- them and to recognize what to pull back. Built once from the raw recipe bodies.
state.all_returned_tools = function()
    if state.allReturnedTools then return state.allReturnedTools end
    local set = {}
    for _, body in pairs(state.iniRaw or {}) do
        for line in body:gmatch('Ingredient%d+=([^\r\n]+)') do
            local nm, rest = line:match('^([^|]+)|(.+)$')
            if nm and rest and rest:lower():find('returned', 1, true) then set[trim(nm)] = true end
        end
    end
    state.allReturnedTools = set
    return set
end

-- "Bank all Trophies" (Craft tab): walk to the bank and deposit every tradeskill trophy we're
-- holding - one that's seated in Ammo AND any in bags - into the first free bank slot. Reverse
-- of the equip/prefetch flow: pick up (from Ammo or bags), drop into an empty bank slot.
state.bank_all_trophies = function()
    state.busy = true
    local ok, err = pcall(function()
        -- Distinct trophies currently on us (Ammo slot or bags). Consider EVERY tier - base and any
        -- `better` ones - not just the one we'd equip, or a higher-tier trophy in your bags would
        -- never get banked by this button.
        local seen, onHand = {}, {}
        local ammoNow = mq.TLO.Me.Inventory('ammo').Name() or ''
        for _, map in pairs(state.TROPHY_BY_CONTAINER) do
            local tiers = { map.trophy }
            for _, b in ipairs(map.better or {}) do tiers[#tiers + 1] = b end
            for _, t in ipairs(tiers) do
                if not seen[t] then
                    seen[t] = true
                    if ammoNow == t or item_count(t) > 0 then onHand[#onHand + 1] = t end
                end
            end
        end
        -- The research modifier (e.g. Ethereal Quill) seats in Ammo just like a trophy - bank it too.
        if state.tsModifier and state.tsModifier ~= '' and not seen[state.tsModifier] then
            seen[state.tsModifier] = true
            if ammoNow == state.tsModifier or item_count(state.tsModifier) > 0 then
                onHand[#onHand + 1] = state.tsModifier
            end
        end
        -- Also bank any |returned tools we're holding (needles, hammers, Sculpting/Etching Tools) -
        -- they accumulate from combines; this is what lets us pull them back on the next craft.
        for tool in pairs(state.all_returned_tools()) do
            if not seen[tool] then
                seen[tool] = true
                if item_count(tool) > 0 then onHand[#onHand + 1] = tool end
            end
        end
        -- And any tradeskill KITS/containers we're holding (Sewing/Jeweler's/research kits, etc.) -
        -- variants from KIT_CONFIG. They cycle the same way: bank now, pull before buying next time.
        for _, cfg in ipairs(KIT_CONFIG) do
            for _, v in ipairs(cfg.variants or {}) do
                if not seen[v] then
                    seen[v] = true
                    if item_count(v) > 0 then onHand[#onHand + 1] = v end
                end
            end
        end
        if #onHand == 0 then
            printf_log('No trophies, tools, or kits on hand to bank.')
            return
        end
        printf_log('Banking %d item(s) (trophies / tools / kits)...', #onHand)
        if not state.reach_and_open_bank() then return end

        local banked = 0
        for _, t in ipairs(onHand) do
            check_stop()
            clear_cursor()
            -- Pick it up: from Ammo if seated there, otherwise from bags.
            if (mq.TLO.Me.Inventory('ammo').Name() or '') == t then
                mq.cmd('/itemnotify ammo leftmouseup')
            else
                mq.cmdf('/itemnotify "%s" leftmouseup', t)
            end
            mq.delay(600, function() return cursor_id() ~= 0 end)
            if cursor_id() == 0 then
                printf_log('  could not pick up %s - skipping.', t)
            else
                -- Drop into the first empty top-level bank slot, then into a bank-bag slot.
                local placed = false
                for b = 1, 24 do
                    if (mq.TLO.Me.Bank(b).ID() or 0) == 0 then
                        mq.cmdf('/nomodkey /itemnotify bank%d leftmouseup', b)
                        mq.delay(600, function() return cursor_id() == 0 end)
                        if cursor_id() == 0 then placed = true; break end
                    end
                end
                if not placed then
                    for b = 1, 24 do
                        local bag = mq.TLO.Me.Bank(b)
                        local slots = bag.Container() or 0
                        if slots > 0 then
                            for s = 1, slots do
                                if (bag.Item(s).ID() or 0) == 0 then
                                    mq.cmdf('/nomodkey /itemnotify in bank%d %d leftmouseup', b, s)
                                    mq.delay(600, function() return cursor_id() == 0 end)
                                    if cursor_id() == 0 then placed = true; break end
                                end
                            end
                        end
                        if placed then break end
                    end
                end
                if placed then
                    banked = banked + 1
                    printf_log('  banked %s.', t)
                else
                    printf_log('  no empty bank slot for %s - returning it to bags.', t)
                    clear_cursor()   -- autoinventory it back
                end
            end
        end

        if mq.TLO.Window('BigBankWnd').Open() then
            mq.cmd('/notify BigBankWnd DoneButton leftmouseup')
            mq.delay(300)
        end
        printf_log('Done - banked %d trophy(ies).', banked)
    end)
    if not ok then
        if tostring(err):find('__TS_STOP__', 1, true) then
            printf_log('Stopped by user.')
        else
            printf_log('ERROR: %s', tostring(err))
        end
    end
    state.busy = false
end

-- Map a recipe's Container to its [Skill:x] section name, so a recipe can be crafted locally
-- (action='craft' -> run_engine) without the user first picking the skill on the Craft tab.
-- run_engine needs the section for its default Vendor and skill reads.
state.SKILL_SECTION_BY_CONTAINER = {
    ['Blacksmithing']        = 'Blacksmithing',
    ['Sewing Kit']           = 'Tailoring',
    ['Deluxe Sewing Kit']    = 'Tailoring',
    ['Pottery Wheel']        = 'Pottery',
    ['Kiln']                 = 'Pottery',
    ['Oven']                 = 'Baking',
    ['Mixing Bowl']          = 'Baking',
    ["Jeweler's Kit"]        = 'Jewelcrafting',
    ['Fletching Kit']        = 'Fletching',
    ['Planar Fletching Kit'] = 'Fletching',
    ['Brew Barrel']          = 'Brewing',
    ['Brewing Barrel']       = 'Brewing',
    ['Mortar and Pestle']    = 'Make Poison',
    ['Medicine Bag']         = 'Alchemy',
    ['Tackle Box']           = 'Fishing',
    ['Spell Research Kit']   = 'Research',
    ['Toolbox']              = 'Tinkering',
    ['Deluxe Toolbox']       = 'Tinkering',
    ['Collapsible Toolbox']  = 'Tinkering',
}
state.skill_section_for_recipe = function(recipeName)
    local recSec = (state.iniSections or {})['Recipe:' .. (recipeName or '')]
    if not recSec or not recSec.Container then return nil end
    local first = trim(split_commas(recSec.Container)[1] or '')
    local skillName = state.SKILL_SECTION_BY_CONTAINER[first]
    if not skillName then return nil end
    return (state.iniSections or {})['Skill:' .. skillName]
end

-- Bare skill NAME a recipe maps to (via its container), for queue entries: the queue stores
-- skillName and queue_start rebuilds 'Skill:'..skillName, so a Radix item must record its real
-- skill (e.g. Baking) rather than the 'Radix' activity label.
state.skill_name_for_recipe = function(recipeName)
    local recSec = (state.iniSections or {})['Recipe:' .. (recipeName or '')]
    if not recSec or not recSec.Container then return nil end
    local first = trim(split_commas(recSec.Container)[1] or '')
    return state.SKILL_SECTION_BY_CONTAINER[first]
end

-- Research queue. Persists across class/level/type changes so a single order can span
-- multiple classes; each entry remembers its OWN class so it crafts under the right tag.
-- accumulate=true (the per-spell "+") bumps an existing entry's quantity; accumulate=false
-- (Queue All) skips anything already queued so a repeat bulk-add doesn't pile on.
state.rs_queue_add = function(name, level, qty, cls, accumulate)
    state.rsQueue = state.rsQueue or {}
    for _, e in ipairs(state.rsQueue) do
        if e.name == name and e.class == cls then
            if accumulate then e.qty = e.qty + qty end
            return
        end
    end
    state.rsQueue[#state.rsQueue + 1] = { name = name, level = level, qty = qty, class = cls }
end

-- Parse ONE *_missingspells.ini (written by the standalone missing_spells checker) and
-- queue every still-missing spell that exists in research.ini, aggregating duplicates
-- already in the queue (two clerics missing the same spell -> x2). Returns:
--   added, skipped, skippedNames(list, capped), badClass(list)
state.rsLoadMsg = ''
state.load_missing_file = function(path)
    local added, skipped = 0, 0
    local skippedNames, badClass = {}, {}
    if not path or not file_exists(path) then return 0, 0, {}, {} end

    -- Valid research names per class (canonical researchIndex keys).
    local known = {}
    for cls, byLvl in pairs(state.researchIndex or {}) do
        local set = {}
        for _, names in pairs(byLvl) do for _, n in ipairs(names) do set[n] = true end end
        known[cls] = set
    end
    -- Map a file's Class (lower/despaced by the checker) onto the suite's canonical key,
    -- so a multi-word class (e.g. Shadow Knight) still lines up with research.ini.
    local function canon_class(fileCls)
        local norm = trim(fileCls or ''):lower():gsub('%s+', '')
        for cls in pairs(known) do
            if cls:lower():gsub('%s+', '') == norm then return cls end
        end
        return nil
    end

    local ok, sections = pcall(parse_ini_file, path)
    if ok and sections then
        for _, sec in pairs(sections) do
            local cls = canon_class(sec.Class)
            if not cls then
                if sec.Class then badClass[#badClass + 1] = trim(sec.Class) end
            else
                local i = 1
                while sec['Missing' .. i] do
                    local lvl, name = (sec['Missing' .. i]):match('^(%d+)%|(.+)$')
                    if lvl and name then
                        name = trim(name)
                        if known[cls][name] then
                            state.rs_queue_add(name, tonumber(lvl), 1, cls, true)
                            added = added + 1
                        else
                            skipped = skipped + 1
                            if #skippedNames < 6 then skippedNames[#skippedNames + 1] = name end
                        end
                    end
                    i = i + 1
                end
            end
        end
    end
    return added, skipped, skippedNames, badClass
end

-- List the *_missingspells.ini files in a folder. Tries LuaFileSystem, then a shell dir,
-- both guarded. Returns { {char=, file=, path=}, ... }, method('lfs'|'dir'|'none').
state.list_missing_in_dir = function(dir)
    dir = (dir or ''):gsub('[\\/]+$', '')   -- strip trailing slash
    local found, seen, method = {}, {}, 'none'
    local function add(fname)
        fname = trim(fname or '')
        local ch = fname:match('^(.-)_missingspells%.ini$')
        if ch and not seen[fname:lower()] then
            seen[fname:lower()] = true
            found[#found + 1] = { char = ch, file = fname, path = dir .. '\\' .. fname }
        end
    end
    local ok, lfs = pcall(require, 'lfs')
    if ok and lfs and lfs.dir then
        local before = #found
        pcall(function() for e in lfs.dir(dir) do add(e) end end)
        if #found > before then method = 'lfs' end
    end
    if method == 'none' then
        pcall(function()
            local p = io.popen('dir /b "' .. dir .. '\\*_missingspells.ini" 2>nul')
            if p then
                for line in p:lines() do add(line) end
                p:close()
            end
        end)
        if #found > 0 then method = 'dir' end
    end
    return found, method
end

-- One-click: scan the config folder (so a hand-out works for people NOT grouped with the
-- crafter) plus self + current group as a fallback, and load every file found.
state.rs_load_missing = function()
    local mqPath = trim(mq.TLO.MacroQuest.Path() or '')
    if mqPath == '' then state.rsLoadMsg = 'Could not resolve the MacroQuest path.'; return end
    local configDir = mqPath .. '\\config'

    local files, method = state.list_missing_in_dir(configDir)
    -- Fold in self + group by name, so we still cover grouped toons if listing isn't available.
    local seen = {}
    for _, f in ipairs(files) do seen[f.char:lower()] = true end
    local function addChar(nm)
        nm = trim(nm or '')
        if nm ~= '' and not seen[nm:lower()] then
            seen[nm:lower()] = true
            files[#files + 1] = { char = nm, path = configDir .. '\\' .. nm .. '_missingspells.ini' }
        end
    end
    addChar(mq.TLO.Me.Name())
    local gs = mq.TLO.Group.Members() or 0
    for g = 1, gs do
        local m = mq.TLO.Group.Member(g)
        if m and (m.ID() or 0) > 0 then addChar(m.Name()) end
    end

    local filesFound, charsLoaded, added, skipped = 0, 0, 0, 0
    local skippedNames, badClass = {}, {}
    for _, f in ipairs(files) do
        if file_exists(f.path) then
            filesFound = filesFound + 1
            local a, s, sn, bc = state.load_missing_file(f.path)
            if a > 0 then charsLoaded = charsLoaded + 1 end
            added = added + a; skipped = skipped + s
            for _, x in ipairs(sn) do if #skippedNames < 6 then skippedNames[#skippedNames + 1] = x end end
            for _, x in ipairs(bc) do badClass[#badClass + 1] = x end
        end
    end

    if filesFound == 0 then
        state.rsLoadMsg = 'No *_missingspells.ini found in config. Run the checker, or use Browse below.'
    else
        local scan = (method ~= 'none') and (' [' .. method .. ' scan]') or ' [self+group]'
        local msg = string.format('Queued %d missing spell(s) from %d character(s)%s.', added, charsLoaded, scan)
        if skipped > 0 then
            msg = msg .. string.format(' Skipped %d not in research.ini (%s%s).', skipped,
                table.concat(skippedNames, ', '), skipped > #skippedNames and ', ...' or '')
        end
        if #badClass > 0 then msg = msg .. ' Unknown class in: ' .. table.concat(badClass, ', ') .. '.' end
        state.rsLoadMsg = msg
    end
    printf_log('Load missing spells: %s', state.rsLoadMsg)
end

-- Load a single chosen file (from the Browse picker) and report.
state.rs_load_missing_one = function(path)
    local a, s, sn, bc = state.load_missing_file(path)
    local msg = string.format('Queued %d from %s.', a, (path:match('[^\\/]+$') or path))
    if s > 0 then
        msg = msg .. string.format(' Skipped %d not in research.ini (%s%s).', s,
            table.concat(sn, ', '), s > #sn and ', ...' or '')
    end
    if #bc > 0 then msg = msg .. ' Unknown class: ' .. table.concat(bc, ', ') .. '.' end
    state.rsLoadMsg = msg
    printf_log('Load missing (file): %s', msg)
end

-- Default Downloads guess for the Browse picker (USERPROFILE\Downloads), best-effort.
state.rs_downloads_dir = function()
    local up
    pcall(function() up = os.getenv('USERPROFILE') end)
    if up and up ~= '' then return up .. '\\Downloads' end
    return ''
end

-- Standalone action: fulfil a list of upfront supply requests. Each item in
-- job.requests is { item=..., mode='stack'|'all' }. 'stack' pulls until we have
-- ~1000 (stopping after a bot that hands over a full stack); 'all' bank-sweeps
-- every stack from every member. Crafter never moves -- the mules come to it.
local function run_request_queue(job)
    state.busy = true
    state.stopRequested = false
    state.log = {}

    local ok, err = pcall(function()
        local reqs = job.requests or {}
        if #reqs == 0 then
            printf_log('Request queue is empty.')
            return
        end
        local targetChar = job.targetChar   -- legacy single-target (now unused by the queue UI)
        -- Explicit user request: clear any session "exhausted" flags so we retry.
        for k in pairs(supplyExhausted) do supplyExhausted[k] = nil end
        state.makeListenersStarted = {}   -- fresh run: start each producer's listener once, then queue makes to it
        printf_log('Running %d supply request(s)%s...', #reqs,
            (targetChar and targetChar ~= '') and (' from ' .. targetChar) or '')

        -- Each pull item is either an EXACT quantity (a number in its box) or ALL (empty/0). make/
        -- deliver stay per-item. Pulls come from own bank first, then any same-zone character on the network.
        local allPulls = {}
        local makeBasket = {}   -- 'make' items -> one smart-divide dispatch across capable casters
        for idx, req in ipairs(reqs) do
            check_stop()
            close_world_container()
            close_merchant()
            if req.mode == 'make' then
                -- Collect make/summon items and split them across ALL capable casters at the end
                -- (e.g. essences across every Enchanter/Magician/Wizard/Necromancer in group), instead
                -- of dumping the whole order on one producer.
                makeBasket[#makeBasket + 1] = { item = req.item, qty = req.qty or 0 }
            elseif req.mode == 'deliver' and req.recipient then
                -- Hand a stack to another character (e.g. Black Pearl to the cleric). Start its
                -- listener so it accepts the incoming trade, then have a mule deliver TO it.
                printf_log('[%d/%d] Deliver %s to %s', idx, #reqs, req.item, req.recipient)
                state.peer_cmdf(req.recipient, '/lua run TradeskillListener')
                mq.delay(2000)
                request_supply(req.item, req.qty or 1000, req.recipient)
            else
                local n = tonumber(req.qtyBuf or '')
                if n and n > 0 then
                    -- Exact quantity: own bank first, then split across same-zone networked characters.
                    printf_log('[%d/%d] Request %d x %s (bank first, then same-zone network)', idx, #reqs, math.floor(n), req.item)
                    state.bankTopUp(req.item, math.floor(n))
                    request_supply(req.item, math.floor(n))
                else
                    allPulls[#allPulls + 1] = { name = req.item, needed = math.huge, mode = 'all' }
                end
            end
        end

        -- Make/summon items: one smart-divide dispatch across all capable casters (with reassignment).
        if #makeBasket > 0 then
            state.dispatch_makes(makeBasket)
        end

        -- 'All' items: own bank first, then ONE grouped sweep over everyone.
        if #allPulls > 0 then
            for _, it in ipairs(allPulls) do
                check_stop()
                printf_log('Own bank first: %s (all)', it.name)
                state.bankTopUp(it.name, math.huge)   -- math.huge drains our bank fully
            end
            state.request_supply_grouped(allPulls, nil)
        end

        printf_log('All supply requests complete.')
    end)

    if not ok then
        if tostring(err):find('__TS_STOP__', 1, true) then
            printf_log('Stopped by user.')
        else
            printf_log('ERROR: %s', tostring(err))
        end
    end
    state.busy = false
end

-- Standalone action: buys enough of every ingredient for `job.quantity`
-- combines worth of the current recipe, grouped by vendor. Does not
-- open the kit or craft anything.
local function run_buy_reagents(job)
    state.busy = true
    state.stopRequested = false
    state.log = {}

    local ok, err = pcall(function()
        local rec = job.recipe
        local vendorName = job.skillSection.Vendor
        -- Buy the tree's VENDOR-BUYABLE LEAVES, not the recipe's raw ingredient list. Handing the raw
        -- list to buy_pass aborts on the first crafted intermediate ("no vendor found for Mithril Arrow
        -- Heads"), because subcombines aren't sold anywhere. plan_requirements.buyDemand is exactly the
        -- subcombine-pruned leaf set with the yield math done - the same thing run_engine pre-buys with.
        -- This is what lets a BOT with the right faction stock a recipe the crafter can't shop for
        -- (e.g. mithril, sold only in Felwithe): run Lazcraft on the bot, hit Buy Ingredients, then
        -- move the mats over with the Request tab.
        -- ignoreCantBuy=true: Buy Ingredients is explicitly "go shop for this", so it always resolves
        -- the TRUE vendor leaves. That's what lets a BOT with faction stock a mat the crafter flagged
        -- "can't buy" - the crafter's own craft run treats that same mat as group-supplied instead.
        local plan = plan_requirements(rec.key or rec.name, job.quantity, nil, true)
        if not plan or not plan.buyDemand then
            printf_log('Could not plan %s - falling back to its direct ingredients.', rec.name)
            buy_pass(rec, job.quantity, vendorName)
            printf_log('Reagent buy pass complete.')
            return
        end

        local preIngs = {}
        for nm, q in pairs(plan.buyDemand) do
            preIngs[#preIngs + 1] = { name = nm, qty = q, buylast = plan.buyLast and plan.buyLast[nm] or false }
        end
        if #preIngs == 0 then
            printf_log('Nothing to buy for %dx %s - every mat is crafted or farmed.', job.quantity, rec.name)
            return
        end

        printf_log('Buying %d vendor mat type(s) for %dx %s (whole tree, one pass)...', #preIngs, job.quantity, rec.name)
        -- buy_pass nets what's already on hand, so pass quantity=1 against the planned demand.
        buy_pass({ name = rec.name, yield = rec.yield, trivial = rec.trivial,
                   sellable = rec.sellable, ingredients = preIngs }, 1, vendorName)
        printf_log('Reagent buy pass complete.')
    end)

    if not ok then
        if tostring(err):find('__TS_STOP__', 1, true) then
            printf_log('Stopped by user.')
        else
            printf_log('ERROR: %s', tostring(err))
        end
    end
    close_world_container()
    close_merchant()
    state.busy = false
end

-- Standalone action: destroys every copy of the recipe's output item
-- currently in inventory, one at a time, by picking it up to cursor
-- and using /destroy. Useful for cleaning out unsellable products.
-- Mithril is sold ONLY in Felwithe (Opal Leganyn / Tanalin Silverkale), which is faction-gated. A
-- character that can't shop there lists these in cantBuy, so plan_requirements sources them from the
-- group instead of routing a trip it can't make. A bot that CAN shop there buys them with the
-- Settings button. Only Mithril Champion Arrows needs them, so both are named outright.
state.FELWITHE_RECIPE = 'Mithril Champion Arrows'
state.FELWITHE_MATS = { 'Small Brick of Mithril', 'Large Brick of Mithril' }

-- Jaggedpine: the Frying Pan Mold (needed to make the Non-Stick Frying Pan) is sold ONLY by Tallien
-- Brightflash in Jaggedpine, whose faction can be too low to shop. Same pattern as Felwithe: a
-- character that can't buy it lists it in cantBuy and sources it from a bot. The mold IS consumed
-- (one per pan); it's flagged buylast only because it's non-stackable, not because it's reusable.
-- Quantity = how many pans you'll make = how many molds to buy. Default 1, cap 6.
state.JAGGEDPINE_ITEM = 'Frying Pan Mold'

-- Supplier-bot mode for the LEVEL plan: buy only the mats ticked "Can't buy", for every rung in the
-- plan, at the Per Run batch size. Deliberately uses the raw Per Run number rather than
-- level_batch_qty: that helper caps the batch by dropped mats on hand, and a ticked mat now counts as
-- supply - so on the bot (which has none yet) it would collapse to 1. ignoreCantBuy resolves the true
-- vendor leaves so the bot can actually shop for them.
state.run_buy_felwithe = function(job)
    state.busy = true
    state.stopRequested = false

    local ok, err = pcall(function()
        local combines = math.max(1, math.min(MAX_QUANTITY, tonumber(state.groupBuyCombines) or 1000))
        local rec = get_recipe(state.FELWITHE_RECIPE)
        if not rec then
            printf_log('ERROR: no recipe data for %s.', state.FELWITHE_RECIPE)
            return
        end

        -- ignoreCantBuy=true: resolve the TRUE vendor leaves. This character IS the one that can shop
        -- in Felwithe, so it must see mithril as buyable even if the box is (wrongly) ticked here.
        local plan = plan_requirements(state.FELWITHE_RECIPE, combines, nil, true)
        local want = {}
        for _, nm in ipairs(state.FELWITHE_MATS) do want[nm] = true end
        local demand = {}
        for nm, q in pairs((plan and plan.buyDemand) or {}) do
            if want[nm] then demand[nm] = (demand[nm] or 0) + q end
        end

        -- The Mithril Working Knife is a |returned tool for Mithril Fletchings: not vendor-sold, and
        -- crafted from exactly 1 Small Brick of Mithril. It's the CRAFTER who needs it, not this bot,
        -- so don't make it conditional on anyone's inventory - just always buy the one extra brick.
        demand['Small Brick of Mithril'] = (demand['Small Brick of Mithril'] or 0) + 1

        local ings = {}
        for nm, q in pairs(demand) do ings[#ings + 1] = { name = nm, qty = q } end
        if #ings == 0 then
            printf_log('%s needs no mithril at %d combines - nothing to buy.', state.FELWITHE_RECIPE, combines)
            return
        end

        printf_log('Buying mithril for %d combines of %s:', combines, state.FELWITHE_RECIPE)
        for _, i in ipairs(ings) do printf_log('   %d x %s', i.qty, i.name) end
        -- buy_pass nets on-hand and routes to the vendor that sells each item (Felwithe), travelling there.
        buy_pass({ name = state.FELWITHE_RECIPE, yield = rec.yield, trivial = rec.trivial,
                   sellable = false, ingredients = ings }, 1, nil)
        printf_log('Mithril buy complete - bring it to the crafter.')
    end)

    if not ok then
        if tostring(err):find('__TS_STOP__', 1, true) then
            printf_log('Stopped by user.')
        else
            printf_log('ERROR: %s', tostring(err))
        end
    end
    close_merchant()
    state.busy = false
end

-- Bot buys the faction-gated Frying Pan Mold from Jaggedpine (Tallien Brightflash). One mold per
-- Non-Stick Frying Pan, so it buys `quantity` of them. Mirrors run_buy_felwithe; the mold is a plain
-- vendor item so we skip the plan walk and just buy it directly.
state.run_buy_jaggedpine = function(job)
    state.busy = true
    state.stopRequested = false

    local ok, err = pcall(function()
        local qty = math.max(1, math.min(6, tonumber(state.jaggedBuyQty) or 1))
        printf_log('Buying %d x %s from Jaggedpine...', qty, state.JAGGEDPINE_ITEM)
        -- buy_pass nets on-hand and routes to the vendor that sells it (Tallien Brightflash,
        -- jaggedpine), travelling there. sellable=false so it never gets auto-sold afterward.
        buy_pass({ name = state.JAGGEDPINE_ITEM, yield = 1, trivial = 0, sellable = false,
                   ingredients = { { name = state.JAGGEDPINE_ITEM, qty = qty } } }, 1, nil)
        if item_count(state.JAGGEDPINE_ITEM) < 1 then
            printf_log('\arGot no %s - Tallien Brightflash may be unreachable, or faction too low even here.\ax', state.JAGGEDPINE_ITEM)
        else
            printf_log('%s buy complete - bring it to the crafter.', state.JAGGEDPINE_ITEM)
        end
    end)

    if not ok then
        if tostring(err):find('__TS_STOP__', 1, true) then
            printf_log('Stopped by user.')
        else
            printf_log('ERROR: %s', tostring(err))
        end
    end
    close_merchant()
    state.busy = false
end

local function run_destroy_all_engine(job)
    state.busy = true
    state.stopRequested = false
    state.log = {}

    local ok, err = pcall(function()
        local name = job.recipe.name
        local count = item_count(name)
        if count <= 0 then
            printf_log('No %s in inventory to destroy.', name)
            return
        end
        printf_log('Destroying %dx %s...', count, name)
        local destroyed = 0
        while item_count(name) > 0 do
            check_stop()
            local before = item_count(name)
            local invItem = mq.TLO.FindItem('=' .. name)
            if (invItem.ID() or 0) == 0 then break end
            mq.cmdf('/nomodkey /itemnotify "%s" leftmouseup', name)
            delay(600, function() return cursor_id() > 0 end)
            if cursor_id() > 0 then
                mq.cmd('/destroy')
                delay(600, function() return cursor_id() == 0 end)
                if item_count(name) < before then
                    destroyed = destroyed + 1
                else
                    clear_cursor()
                end
            end
        end
        printf_log('Destroyed %dx %s.', destroyed, name)
    end)

    if not ok then
        if tostring(err):find('__TS_STOP__', 1, true) then
            printf_log('Stopped by user.')
        else
            printf_log('ERROR: %s', tostring(err))
        end
    end
    close_world_container()
    close_merchant()
    state.busy = false
end

-- ---------------------------------------------------------------------------
-- Fishing (leveling)
-- ---------------------------------------------------------------------------
-- Buy a Fishing Pole (worn in the primary/mainhand slot) + a stack of bait from
-- Daeld Atand in PoK, travel to the chosen spot, face the water, and fish. The pole
-- BREAKS with use, so we re-buy + re-equip when the mainhand goes empty; bait is
-- consumed, so we re-buy when it hits zero. Runs off action='fish' with job.spot
-- ('pok' to level, 'gunthak' for the trophy fish). Defined on `state` (not a top-level
-- local) to stay under the main-chunk local cap.
--
-- TUNABLES (change here if Lazarus differs from these defaults):
--   FISH_CAST_CMD   - how fishing is triggered. Default '/doability Fishing'. If
--                     that isn't how fishing fires on Laz, this is the ONE line to change.
--   FISH_SPOTS      - per-spot loc (/loc order Y X Z), heading, travel fn, and skillCap
--                     (nil = trophy mode, no skill stop). Add a spot by adding an entry.
--   FISH_BAIT       - the bait item fishing consumes (Daeld Atand also stocks this).
--   FISH_SLOTS      - worn-slot token(s) for the pole; 'mainhand' on current MQ.
state.run_fish_engine = function(job)
    state.busy = true
    state.stopRequested = false
    state.fishFail = nil     -- fresh run: forget any land/pole/bait failure from last time
    state.log = {}
    state.savedSlots = {}     -- fresh slot record for this run
    -- (E3 is paused by the job dispatcher for the whole action.)
    if not state.fishLists then state.loadFishLists() end

    -- config / tunables
    local FISH_TROPHY     = 'Bounty of the Master Baiter'   -- equipped while fishing; right-click summons gear
    local hasTrophy       = item_count(FISH_TROPHY) >= 1
    -- With the trophy we summon Master gear (no vendor). Without it, fall back to the vendor pole/bait.
    local FISH_POLE       = hasTrophy and "Master Baiter's Rod" or 'Fishing Pole'
    local FISH_BAIT       = hasTrophy and 'Master Bait'        or 'Fishing Bait'
    local FISH_VENDOR     = 'Daeld Atand'         -- pole + bait live in PoK (fallback path only)
    local FISH_BAIT_STACK = 1000
    local BAIT_CAP        = 1000      -- summoned Master Bait over this is DESTROYED, not bagged
    local BAIT_START_MIN  = 500       -- (vendor path) start a hunt with a full stack if bait is below this
    local FISH_CAST_CMD   = '/doability Fishing'
    local FISH_CAST_WAIT  = 10000     -- ms to wait for a cast/catch to resolve
    local FISH_SLOTS      = { 'mainhand', 'primary' }   -- try mainhand, fall back to primary

    -- Fishing spots. Each: how to get there, where to stand, which way to face, and a skill
    -- cap. PoK is for leveling (stop at the cap). Gulf of Gunthak is for the trophy fish -
    -- skillCap = nil means never stop on skill; fish until bags fill or you stop. Locs are
    -- /loc order (Y X Z), the same convention as the PoK spot that already works.
    local FISH_SPOTS = {
        pok = {
            label = 'Plane of Knowledge (leveling)', travel = travel_to_pok,
            -- poleStock 5, not 1: a broken rod at stock 1 means a full vendor round trip. With spares
            -- we just swap in place. The vendor is close, but a trek per break still cost hours.
            loc = { y = -33.51, x = 1461, z = -123 }, heading = 359.16, skillCap = 200, poleStock = 5,
            -- /nav loc refuses to path to the water loc on some installs (it sits off the navmesh;
            -- nav stops ~50 short). Fall back to the fishing vendor - who stands beside the pond -
            -- and just face the water from there. If that still isn't water, the land-shark event
            -- aborts the run rather than casting at dirt.
            -- Heading 88.52 is the reciprocal of 268.52, which faced away from the water.
            fallbackVendor = true, fallbackHeading = 88.52,
        },
        gunthak = {
            label = 'Gulf of Gunthak (trophy fish)', travel = state.travel_to_gunthak,
            loc = { y = 1324.70, x = -14.75, z = -44.55 }, heading = 190.80, skillCap = nil, poleStock = 5,
        },
        dagnor = {
            label = "Dagnor's Cauldron (trophy fish)", travel = state.travel_to_dagnor,
            loc = { y = -1554.33, x = -698.11, z = -0.55 }, heading = 7.68, skillCap = nil, poleStock = 5,
        },
        northkarana = {
            label = 'North Karana (trophy fish)', travel = state.travel_to_northkarana,
            -- 78.39 faced away from the water; face the reciprocal (78.39 + 180).
            loc = { y = 226.14, x = -2894, z = -62.33 }, heading = 258.39, skillCap = nil, poleStock = 5,
        },
        firiona = {
            label = 'Firiona Vie (trophy fish)', travel = state.travel_to_fv,
            -- +25 from the grabbed 128.15 to face the water dead-on.
            loc = { y = -2681.22, x = 3610.88, z = -121.04 }, heading = 153.15, skillCap = nil, poleStock = 5,
        },
        natimbi = {
            label = 'Natimbi (GoD fishing)', travel = state.travel_to_natimbi,
            -- 258.91 faced away from the water; face the reciprocal (258.91 - 180).
            loc = { y = -876.77, x = -1475.40, z = 212.11 }, heading = 78.91, skillCap = nil, poleStock = 5,
        },
        hardcore = {
            label = 'Hardcore Qeynos Hills (Shard)', travel = state.travel_to_hardcore_qeynos,
            loc = { y = 4786, x = 672.42, z = -22.42 }, heading = 183.74, skillCap = nil, poleStock = 5,
        },
        here = {   -- the plain "Fish" button: fish wherever you're standing, no travel, no target
            label = 'the current spot', travel = nil, loc = nil, heading = nil, skillCap = nil, poleStock = 1,
        },
    }
    local spot        = FISH_SPOTS[job.spot] or FISH_SPOTS.pok
    local poleStock   = spot.poleStock or 1          -- how many poles to keep on hand (spares for far spots)
    local targetFish  = job.targetFish               -- trophy mode: fish until we have targetQty of this IN BAGS
    local targetQty   = tonumber(job.targetQty) or 1

    local function pole_in_slot()
        for _, s in ipairs(FISH_SLOTS) do
            if (mq.TLO.Me.Inventory(s).Name() or '') == FISH_POLE then return true end
        end
        return false
    end

    -- Pick the pole to cursor and drop it into the primary slot (same itemnotify pattern
    -- as equip_modifier); auto-inventory whatever the swap displaced.
    local function equip_pole()
        if pole_in_slot() then return true end
        if item_count(FISH_POLE) < 1 then return false end
        state.remember_slot('mainhand')   -- record the original weapon so we can put it back at run's end
        if not clear_cursor() then return false end
        mq.cmdf('/itemnotify "%s" leftmouseup', FISH_POLE)
        delay(700, function() return cursor_id() ~= 0 end)
        if cursor_id() == 0 then return false end
        for _, s in ipairs(FISH_SLOTS) do
            mq.cmdf('/itemnotify %s leftmouseup', s)
            delay(700, pole_in_slot)
            if pole_in_slot() then break end
        end
        if cursor_id() ~= 0 then
            mq.cmd('/autoinventory')
            delay(600, function() return cursor_id() == 0 end)
        end
        return pole_in_slot()
    end

    -- Trek to Daeld Atand in PoK and top poles up to poleStock and bait up to FISH_BAIT_STACK.
    -- Only makes the trip if poles are below poleMin OR bait is below baitMin. The initial supply
    -- passes higher mins so a hunt starts well-stocked (no early treks); a mid-hunt restock passes
    -- min 1 so it only fires when truly out. Well-stocked already -> no trip, just fish.
    local function resupply(poleMin, baitMin)
        poleMin = poleMin or 0
        baitMin = baitMin or 0
        local needTrip = (poleMin > 0 and item_count(FISH_POLE) < poleMin)
                      or (baitMin > 0 and item_count(FISH_BAIT) < baitMin)
        if not needTrip then return true end
        if not travel_to_pok() then return false end
        check_stop()
        nav_to(FISH_VENDOR)
        if not open_merchant(FISH_VENDOR) then return false end
        if poleMin > 0 then
            local shortPole = poleStock - item_count(FISH_POLE)
            if shortPole > 0 then buy_item(FISH_POLE, shortPole) end
        end
        if baitMin > 0 then
            local short = FISH_BAIT_STACK - item_count(FISH_BAIT)
            if short > 0 then buy_item(FISH_BAIT, short) end
        end
        close_merchant()
        return true
    end

    -- Summon Master gear from the equipped trophy (instant clicky, no vendor trip). Summoned items
    -- land on the cursor. Keep exactly ONE rod and bait up to BAIT_CAP; destroy the rest. The rod
    -- keep/destroy decision uses the BAG count taken BEFORE each click (cursor clear) plus a
    -- "kept one this click" flag - never the cursor item itself, since FindItemCount counts the
    -- cursor on this build (that was the "destroy every summoned rod" bug).
    local function summon_supply(needPole, baitMin)
        baitMin = math.min(baitMin or 0, BAIT_CAP - 100)   -- stay under the cap so we don't fight the destroy
        for _ = 1, 20 do
            -- Cursor is clear here, so these are bag/worn counts (reliable).
            if (not needPole or item_count(FISH_POLE) >= 1) and item_count(FISH_BAIT) >= baitMin then break end
            local needRodNow = needPole and item_count(FISH_POLE) < 1   -- do we still need a rod coming in?
            local baitBefore = item_count(FISH_BAIT)                    -- bag bait BEFORE this click
            mq.cmdf('/useitem "%s"', FISH_TROPHY)   -- instant cast
            delay(1000, function() return cursor_id() ~= 0 end)
            local keptRod = false
            local guard = 0
            while cursor_id() ~= 0 and guard < 20 do
                guard = guard + 1
                local c = mq.TLO.Cursor.Name() or ''
                if c == FISH_POLE then
                    -- Keep only if we needed one coming in and haven't kept one yet this click.
                    if needRodNow and not keptRod then mq.cmd('/autoinventory'); keptRod = true
                    else mq.cmd('/destroy') end
                elseif c == FISH_BAIT then
                    -- Once bags already hold 1k+ bait, destroy summoned bait on the cursor instead of
                    -- bagging it - so a long run of rod summons never piles up extra stacks.
                    if baitBefore >= BAIT_CAP then mq.cmd('/destroy') else mq.cmd('/autoinventory') end
                else
                    mq.cmd('/autoinventory')   -- anything else summoned: bag it
                end
                delay(500, function() return cursor_id() == 0 end)
            end
        end
        return item_count(FISH_POLE) >= 1
    end

    -- Unified supply: summon from the trophy if we have it (no vendor trip, no travel), otherwise
    -- fall back to the PoK vendor buy.
    local function supply(needPole, baitTarget)
        if hasTrophy then return summon_supply(needPole, baitTarget) end
        return resupply(needPole and 1 or 0, baitTarget)
    end

    local function go_to_spot()
        if spot.travel and not spot.travel() then error('could not travel to ' .. spot.label) end
        if spot.loc then
            printf_log('Fishing: heading to %s...', spot.label)
            -- Verify we actually arrived. A silently-failed nav used to leave us wherever we stood,
            -- casting at dry land for hours while burning bait and rods.
            if not nav_to_loc(spot.loc.y, spot.loc.x, spot.loc.z) then
                -- Fallback: the water loc can sit off the navmesh, so nav refuses to path to it.
                -- The fishing vendor stands beside the pond - nav to him (a normal spawn nav that
                -- works) and face the water. The land-shark event still guards us if this is wrong.
                if spot.fallbackVendor and nav_to(FISH_VENDOR) then
                    printf_log('Fishing: water loc is off the navmesh - fishing from beside %s instead.', FISH_VENDOR)
                    if spot.fallbackHeading then mq.cmdf('/face fast heading %.2f', spot.fallbackHeading) end
                    delay(500)
                    return
                end
                error('could not reach the fishing spot at ' .. spot.label .. ' - not casting from here')
            end
            if spot.heading then mq.cmdf('/face fast heading %.2f', spot.heading) end
            delay(500)
        else
            printf_log('Fishing: fishing at %s.', spot.label)   -- no travel/nav (the plain Fish button)
        end
    end

    local startSkill = skill_value('Fishing') or 0
    local ok, err = pcall(function()
        if targetFish then
            printf_log('Fishing: starting at %s - hunting %d x %s (have %d in bags).', spot.label, targetQty, targetFish, item_count(targetFish))
            if item_count(targetFish) >= targetQty then
                printf_log('Fishing: already have %d x %s - nothing to catch.', item_count(targetFish), targetFish)
                return
            end
        else
            printf_log('Fishing: starting at %s.', spot.label)
        end

        -- Equip the fishing trophy (ammo) for the whole run if we own it - it boosts fishing and is
        -- what we right-click to summon gear. The slot is restored at run end by restore_saved_slots.
        if hasTrophy then state.equip_modifier(FISH_TROPHY) end

        -- Initial supply: rod + a full stack of bait. With the trophy this summons (instant, no
        -- travel); otherwise it's the PoK vendor buy, topping up only when actually low.
        if not supply(true, hasTrophy and BAIT_CAP or BAIT_START_MIN) then
            error(hasTrophy and ('could not summon a ' .. FISH_POLE .. ' from ' .. FISH_TROPHY) or ('could not buy pole/bait from ' .. FISH_VENDOR))
        end
        check_stop()
        if item_count(FISH_POLE) < 1 then error('no ' .. FISH_POLE .. ' after supply.') end
        if not equip_pole() then error('could not equip the ' .. FISH_POLE .. ' to the primary slot') end

        go_to_spot()
        if spot.skillCap then
            printf_log('Fishing: skill %d (stopping at %d). Casting with "%s".', startSkill, spot.skillCap, FISH_CAST_CMD)
        else
            printf_log('Fishing: skill %d (trophy mode - runs until bags fill or you stop). Casting with "%s".', startSkill, FISH_CAST_CMD)
        end

        while true do
            check_stop()

            if targetFish and item_count(targetFish) >= targetQty then
                printf_log('Fishing: have %d x %s in bags - trophy target reached. Done.', item_count(targetFish), targetFish)
                break
            end

            if spot.skillCap then
                local sk = skill_value('Fishing') or 0
                if sk >= spot.skillCap then
                    printf_log('Fishing: hit skill %d (cap %d) - done.', sk, spot.skillCap)
                    break
                end
            end

            -- Rod broke (primary slot empty)? Re-summon/re-buy one and re-equip. With the trophy
            -- this is an instant summon in place; the vendor path treks only when fully out.
            if not pole_in_slot() then
                if item_count(FISH_POLE) < 1 then
                    printf_log('Fishing: out of rods - %s.', hasTrophy and 'summoning another' or 'trekking back')
                    if not supply(true, 0) then error('rod resupply failed') end
                    if not hasTrophy then go_to_spot() end   -- vendor path left the spot; summon didn't
                end
                if not equip_pole() then error('could not re-equip the rod') end
            end

            -- Out of bait? Summon/buy more, then make sure the rod is still on.
            if item_count(FISH_BAIT) < 1 then
                printf_log('Fishing: out of bait - %s.', hasTrophy and 'summoning more' or 'restocking')
                if not supply(false, hasTrophy and BAIT_CAP or FISH_BAIT_STACK) then error('bait resupply failed') end
                if not hasTrophy then go_to_spot() end
                if not pole_in_slot() then equip_pole() end
            end

            -- Bags full? Stop (v1 keeps catches; empty bags and rerun).
            if free_slots() <= 0 then
                printf_log('Fishing: bags are full - stopping. Empty them and run again.')
                break
            end

            -- Cast, then wait for the cast/reel to resolve. A catch lands on the cursor:
            -- Destroy-listed items get /destroyed, everything else (Keep-listed or not yet
            -- classified) is bagged. Unlisted catches are logged so you can classify them.
            --
            -- Clear the cursor FIRST. A pole left there by a failed equip would otherwise be read as
            -- a catch on the next cast ("caught Fishing Pole" x3 in three seconds) - the cursor is
            -- how we detect a catch, so it has to be empty before we cast.
            if cursor_id() ~= 0 then clear_cursor() end
            state.fishFail = nil
            mq.cmd(FISH_CAST_CMD)
            delay(FISH_CAST_WAIT, function() return cursor_id() ~= 0 or state.fishFail ~= nil end)
            mq.doevents()
            -- The game told us why this cast can't work: stop instead of casting into nothing for
            -- hours. Dry land means the nav never got us to the water.
            if state.fishFail then
                error('cannot fish here - ' .. tostring(state.fishFail))
            end
            if cursor_id() ~= 0 then
                local caught = mq.TLO.Cursor.Name() or ''
                local lists = state.fishLists or { destroy = {}, keep = {} }
                local isTarget = (targetFish ~= nil and caught == targetFish)
                if isTarget then
                    mq.cmd('/autoinventory')                 -- the trophy fish: always keep
                elseif caught == FISH_POLE then
                    -- We fish these up. It's the very consumable that breaks and forces the vendor
                    -- trek, so keep it silently as a spare (equip_pole picks it up from bags on the
                    -- next break) rather than announcing it as unlisted every time.
                    mq.cmd('/autoinventory')
                elseif caught ~= '' and lists.destroy[caught] then
                    mq.cmd('/destroy')
                    delay(700, function() return cursor_id() == 0 end)
                    if cursor_id() ~= 0 then mq.cmd('/autoinventory') end   -- destroy didn't take: don't jam the cursor
                else
                    if caught ~= '' and not lists.keep[caught] then
                        printf_log('Fishing: caught %s (unlisted) - bagging it. Add it to Keep/Destroy on the Fishing panel.', caught)
                    end
                    mq.cmd('/autoinventory')
                end
                delay(700, function() return cursor_id() == 0 end)
                if isTarget then
                    -- Count the TOTAL in bags (includes any you already had) so a restart or a
                    -- mid-run trek keeps counting toward the target instead of recounting from zero.
                    printf_log('Fishing: caught %s (%d/%d in bags).', caught, item_count(targetFish), targetQty)
                end
            end
        end

        printf_log('Fishing: finished. Skill %d -> %d.', startSkill, skill_value('Fishing') or 0)
    end)

    if not ok then
        if tostring(err):find('__TS_STOP__', 1, true) then
            printf_log('Stopped by user.')
        else
            printf_log('ERROR: %s', tostring(err))
        end
    end
    close_merchant()
    close_world_container()
    state.restore_saved_slots()   -- put the fishing pole's slot back to your weapon
    state.busy = false
end

-- ─── Alcohol Tolerance (Get Smashed) ────────────────────────────────────────
-- Raise the Alcohol Tolerance skill to its cap the only way there is: drink. Buy a chunk of Ale
-- (cheap; falls back to other alcohols the merchant list knows), then sip it. Each drink rolls a
-- skill-up but also raises Me.Drunk; once Drunk passes 80 we stop and let it wear off before drinking
-- again (skill-ups come easier when you're less drunk anyway). Done when Alcohol Tolerance hits cap.
state.run_booze_engine = function(job)
    state.busy = true
    state.stopRequested = false

    local SKILL          = 'Alcohol Tolerance'
    local DRUNK_STOP     = 150       -- stop drinking above this, wait until back under it (the meter runs to 200 = passout)
    local DRINK_PACE_MS  = 1200      -- between drinks: let the skill roll + drunk tick register
    local BOOZE_BUY_QTY  = 1000      -- one Lazarus stack; cheap, and cuts vendor trips. Rebuys when empty.
    -- Ale first (mild + cheap = controlled sipping), then other common alcohols if Ale isn't sold.
    local BOOZE_ORDER    = { 'Ale', 'Brandy', 'Whiskey', 'Wine', 'Beer', 'Rum', 'Vodka', 'Grog' }

    local function pick_vendor(sellers)
        local cz = current_zone()
        local marr, pok
        for _, s in ipairs(sellers) do
            if s.zone == cz then return s end          -- already here: no travel
            if s.zone == ZONE_MARR then marr = marr or s end
            if s.zone == ZONE_POK  then pok  = pok  or s end
        end
        return marr or pok or sellers[1]
    end

    -- Ensure we have some booze on hand; returns the name we hold, or nil if nothing could be bought.
    local function buy_booze()
        for _, name in ipairs(BOOZE_ORDER) do
            if item_count(name) >= 1 then return name end
            local sellers = (state.vendorMap or {})[name]
            if sellers and #sellers > 0 then
                local v = pick_vendor(sellers)
                local reachable = true
                if v.zone and current_zone() ~= v.zone then
                    reachable = state.travel_to_zone(v.zone)
                end
                if reachable then
                    check_stop()
                    if nav_to(v.name) and open_merchant(v.name) then
                        buy_item(name, BOOZE_BUY_QTY)
                        close_merchant()
                        if item_count(name) >= 1 then
                            printf_log('Get Smashed: bought %s from %s.', name, v.name)
                            return name
                        end
                    end
                end
            end
        end
        return nil
    end

    local ok, err = pcall(function()
        local cap = mq.TLO.Me.SkillCap(SKILL)() or 0
        if cap <= 0 then cap = 200 end   -- TLO unavailable: fall back to the usual Alcohol Tolerance cap
        local skill = skill_value(SKILL) or 0
        if skill >= cap then
            printf_log('Get Smashed: Alcohol Tolerance already at cap (%d) - nothing to do.', cap)
            return
        end
        printf_log('Get Smashed: Alcohol Tolerance %d/%d - stocking up...', skill, cap)

        local booze = buy_booze()
        if not booze then
            error('no alcohol found in the merchant list - scan a tavern vendor (Ale) first')
        end

        local lastLogged = skill
        while true do
            check_stop()
            skill = skill_value(SKILL) or 0
            if skill ~= lastLogged then
                printf_log('Get Smashed: Alcohol Tolerance %d/%d.', skill, cap)
                lastLogged = skill
            end
            if skill >= cap then
                printf_log('Get Smashed: hit the Alcohol Tolerance cap (%d). Done. *hic*', cap)
                break
            end

            if item_count(booze) < 1 then
                booze = buy_booze()
                if not booze then error('out of alcohol and none could be rebought') end
            end

            local drunk = mq.TLO.Me.Drunk() or 0
            if drunk > DRUNK_STOP then
                printf_log('Get Smashed: Drunk %d (skill %d/%d) - sobering up under %d...', drunk, skill, cap, DRUNK_STOP)
                while (mq.TLO.Me.Drunk() or 0) > DRUNK_STOP do
                    check_stop()
                    delay(3000)
                end
            else
                mq.cmdf('/useitem "%s"', booze)
                delay(DRINK_PACE_MS)
            end
        end
    end)

    if not ok then
        if tostring(err):find('__TS_STOP__', 1, true) then
            printf_log('Get Smashed: stopped by user.')
        else
            printf_log('Get Smashed ERROR: %s', tostring(err))
        end
    end
    close_merchant()
    state.busy = false
end

local function push_ui_style()
    local vars, cols = 0, 0
    local function pv(v, ...)
        if v ~= nil and pcall(ImGui.PushStyleVar, v, ...) then vars = vars + 1 end
    end
    local function pc(c, r, g, b, a)
        if c ~= nil and pcall(ImGui.PushStyleColor, c, r, g, b, a) then cols = cols + 1 end
    end
    pv(ImGuiStyleVar.WindowRounding, UI.round)
    pv(ImGuiStyleVar.FrameRounding, UI.round)
    pv(ImGuiStyleVar.GrabRounding, UI.round)
    pv(ImGuiStyleVar.FramePadding, 8, 5)
    pc(ImGuiCol.WindowBg, 0.07, 0.08, 0.11, 0.96)
    pc(ImGuiCol.FrameBg, 0.12, 0.14, 0.18, 1.0)
    pc(ImGuiCol.Button, UI.steel[1], UI.steel[2], UI.steel[3], 1.0)
    return vars, cols
end

local function pop_ui_style(vars, cols)
    if cols and cols > 0 and ImGui.PopStyleColor then pcall(ImGui.PopStyleColor, cols) end
    if vars and vars > 0 and ImGui.PopStyleVar then pcall(ImGui.PopStyleVar, vars) end
end

local function themed_button(label, color, w, h, disabled)
    if disabled and ImGui.BeginDisabled then ImGui.BeginDisabled(true) end
    local c = color or UI.steel
    local alpha = disabled and 0.45 or 1.0
    ImGui.PushStyleColor(ImGuiCol.Button, c[1] * 0.90, c[2] * 0.90, c[3] * 0.90, alpha)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, math.min(c[1] * 1.15, 1), math.min(c[2] * 1.15, 1), math.min(c[3] * 1.15, 1), alpha)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, c[1] * 0.72, c[2] * 0.72, c[3] * 0.72, alpha)
    local clicked = ImGui.Button(label, w or UI.btn_w, h or UI.btn_h)
    ImGui.PopStyleColor(3)
    if disabled and ImGui.EndDisabled then ImGui.EndDisabled() end
    return clicked and not disabled
end

-- (Historical note: an intermittent "text field won't hold focus" report was chased at length and turned
-- out to be environmental - Synergy's emulated mouse injecting phantom clicks into the ImGui overlay,
-- re-clicking the field every few frames so it never settled. Not a suite bug; nothing to fix in code.)

-- Hover-tooltip helper: renders a dim "(?)" that shows longer help text on hover, so wordy explainers
-- don't have to live inline and clutter every tab. Use on the SAME line as a short label:
--   ImGui.Text('Placement pace'); ImGui.SameLine(); state.help_marker('Long explanation here...')
state.help_marker = function(text)
    ImGui.TextDisabled('(?)')
    if ImGui.IsItemHovered() then
        if ImGui.BeginTooltip then
            ImGui.BeginTooltip()
            ImGui.PushTextWrapPos(360)
            ImGui.TextWrapped(text)
            ImGui.PopTextWrapPos()
            ImGui.EndTooltip()
        elseif ImGui.SetTooltip then
            ImGui.SetTooltip(text)
        end
    end
end

local function draw_recipe_preview(rec, qty)
    if not rec then
        ImGui.TextDisabled('No recipe data for this item.')
        return
    end
    ImGui.Text(string.format('Yield per combine: %d', rec.yield))
    if ImGui.BeginTable('##ts_ing', 3, (ImGuiTableFlags.Borders or 0) + (ImGuiTableFlags.RowBg or 0), 0, 0) then
        ImGui.TableSetupColumn('Ingredient', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Per Combine', ImGuiTableColumnFlags.WidthFixed, 90)
        ImGui.TableSetupColumn('Total Needed', ImGuiTableColumnFlags.WidthFixed, 100)
        ImGui.TableHeadersRow()
        for _, ing in ipairs(rec.ingredients) do
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.Text(ing.name)
            ImGui.TableNextColumn()
            ImGui.Text(tostring(ing.qty))
            ImGui.TableNextColumn()
            ImGui.Text(tostring(ing.qty * qty))
        end
        ImGui.EndTable()
    end

    -- Estimated cost: full tree-wide buy total x scanned prices - the SAME basis as the plan's COST
    -- line, so the UI number matches the log. plan_requirements walks the whole tree, too heavy to run
    -- every render frame, so cache it and only recompute when the recipe or quantity changes.
    do
        local sig = (rec.key or rec.name or '') .. '@' .. tostring(qty)
        if state._costCacheSig ~= sig then
            state._costCacheSig = sig
            state._costCache = nil
            local okc, plan = pcall(function() return plan_requirements(rec.key or rec.name, qty) end)
            if okc and plan and plan.buyDemand then
                local totalCp, priced, items = 0, 0, 0
                for nm, q in pairs(plan.buyDemand) do
                    if q > 0 then
                        items = items + 1
                        local info = (state.itemInfo or {})[nm]
                        if info and info.price and info.price > 0 then
                            totalCp = totalCp + info.price * q
                            priced = priced + 1
                        end
                    end
                end
                state._costCache = { cp = totalCp, priced = priced, items = items }
            end
        end
        local c = state._costCache
        if c and c.items > 0 then
            if ImGui.BeginTable('##ts_ing_cost', 2, (ImGuiTableFlags.Borders or 0) + (ImGuiTableFlags.RowBg or 0), 0, 0) then
                ImGui.TableSetupColumn('', ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn('', ImGuiTableColumnFlags.WidthFixed, 110)
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                ImGui.Text('Estimated Price')
                ImGui.TableNextColumn()
                if c.priced > 0 then
                    ImGui.Text(string.format('~%d pp', math.floor(c.cp / 1000)))
                    if c.priced < c.items then
                        ImGui.TableNextRow()
                        ImGui.TableNextColumn()
                        ImGui.TextDisabled(string.format('(%d of %d items priced - scan the rest for a full estimate)', c.priced, c.items))
                        ImGui.TableNextColumn()
                    end
                else
                    ImGui.TextDisabled('not scanned')
                end
                ImGui.EndTable()
            end
        end
    end
end

-- Resolves the currently selected skill/item/recipe/quantity from the UI.
-- Returns nil plus logs an error if anything required is missing.
local function resolve_current_selection()
    local skillName = current_skill_name()
    local skillSec = current_skill_section()
    local itemName = current_item_name()
    local rec = get_recipe(itemName)
    local qty = math.max(1, math.min(MAX_QUANTITY, tonumber(state.quantityBuf) or 1))

    if not skillName or not skillSec then
        printf_log('ERROR: no tradeskill selected.')
        return nil
    end
    if not rec then
        printf_log('ERROR: no recipe data found for %s.', tostring(itemName))
        return nil
    end
    return skillSec, rec, qty
end

local function run_start()
    if state.busy then return end
    local skillSec, rec, qty = resolve_current_selection()
    if not skillSec then return end

    local job = {
        action = 'craft',
        skillSection = skillSec,
        recipe = rec,
        quantity = qty,
        disposal = state.disposalMode,
        kitPack = KIT_PACK_DEFAULT,
        stopOnTrivial = false,   -- Craft always makes the full quantity; leveling owns stopping
        supplyFromGroup = state.craftSupplyFromGroup,   -- pull dropped-mat shortfall from group first
        supplyMode = state.craftSupplyMode,             -- 'needed' (exact) or 'all' (sweep)
    }

    state.pendingJob = job
end

local function queue_add()
    local skillSec, rec, qty = resolve_current_selection()
    if not skillSec or not rec then return end
    -- Store the recipe's REAL skill name. For normal activities that's the selected skill;
    -- for Radix it's resolved from the recipe's container (queue_start rebuilds from this).
    local realSkill = current_skill_name()
    if state.craftActivityRadix then
        realSkill = state.skill_name_for_recipe(rec.name)
        if not realSkill then
            printf_log('ERROR: could not map %s to a tradeskill.', tostring(rec.name))
            return
        end
    end
    state.queue[#state.queue + 1] = {
        skillName  = realSkill,
        itemName   = rec.name,
        qty        = qty,
        disposal   = state.disposalMode,
        stopOnTrivial = false,   -- Craft always makes the full quantity; leveling owns stopping
    }
end

local function queue_remove(i)
    table.remove(state.queue, i)
end

local function queue_move_up(i)
    if i <= 1 then return end
    state.queue[i], state.queue[i-1] = state.queue[i-1], state.queue[i]
end

local function queue_move_down(i)
    if i >= #state.queue then return end
    state.queue[i], state.queue[i+1] = state.queue[i+1], state.queue[i]
end

local function queue_start()
    if state.busy or #state.queue == 0 then return end
    -- Reset session stats for new queue run
    state.sessionStarted = false
    state.currentQueueIndex = 1
    state.queueRunning = true
    -- Kick off first job
    local entry = state.queue[1]
    local skillSec = (state.iniSections or {})['Skill:' .. (entry.skillName or '')]
    local rec = get_recipe(entry.itemName)
    if not skillSec or not rec then
        printf_log('ERROR: could not find skill/recipe for queue entry: %s', entry.itemName or '?')
        state.queueRunning = false
        return
    end
    state.pendingJob = {
        action = 'craft',
        skillSection = skillSec,
        recipe = rec,
        quantity = entry.qty,
        disposal = entry.disposal,
        kitPack = KIT_PACK_DEFAULT,
        stopOnTrivial = entry.stopOnTrivial,
        supplyFromGroup = state.craftSupplyFromGroup,   -- same toggle drives the queue too
        supplyMode = state.craftSupplyMode,
    }
end

local function queue_clear()
    state.queue = {}
    state.queueRunning = false
    state.currentQueueIndex = 0
end

-- Leveling plan functions
local function level_plan_add()
    local _, rec, _ = resolve_current_selection()
    if not rec then return end
    -- Don't add duplicates
    for _, e in ipairs(state.levelPlan) do
        if e.itemName == rec.name then return end
    end
    state.levelPlan[#state.levelPlan + 1] = {
        skillName = current_skill_name(),
        itemName  = rec.name,
        trivial   = rec.trivial or 0,
        disposal  = state.disposalMode,
    }
    -- Auto-sort by trivial
    table.sort(state.levelPlan, function(a, b) return a.trivial < b.trivial end)
end

local function level_plan_remove(i)
    table.remove(state.levelPlan, i)
end

local function level_load_recommended(skillUIName)
    local path = RECOMMENDED_PATHS[skillUIName]
    if not path then
        state.levelStatusMsg = 'No recommended path for ' .. skillUIName .. ' yet.'
        return
    end
    state.levelPlan = {}
    state.levelPathName = skillUIName   -- remember which path this plan came from (keep-ingredients lookup)
    local missing = {}
    for _, entry in ipairs(path) do
        local rec = get_recipe(entry.item)
        if rec and not rec.disabled then
            state.levelPlan[#state.levelPlan + 1] = {
                skillName = skillUIName,
                itemName  = entry.item,
                trivial   = rec.trivial or 0,
                disposal  = entry.disposal,
                order     = #state.levelPlan + 1,   -- preserve path order
            }
        else
            missing[#missing + 1] = entry.item
        end
    end
    -- Re-add any recipes this character hand-added to this path (persisted per character across
    -- reloads), so a path you've customized comes back exactly as you built it.
    for _, recipe in ipairs((state.customPathAdditions and state.customPathAdditions[skillUIName]) or {}) do
        local already = false
        for _, e in ipairs(state.levelPlan) do if e.itemName == recipe then already = true; break end end
        if not already then
            local crec = get_recipe(recipe)
            if crec and not crec.disabled then
                state.levelPlan[#state.levelPlan + 1] = {
                    skillName = skillUIName, itemName = recipe, trivial = crec.trivial or 0,
                    disposal = state.levelDisposal, order = #state.levelPlan + 1,
                }
            end
        end
    end
    -- Sort by trivial, but keep path order for ties (e.g. Leather before Silk
    -- at the same trivial, per the buy/craft priority).
    table.sort(state.levelPlan, function(a, b)
        if a.trivial ~= b.trivial then return a.trivial < b.trivial end
        return (a.order or 0) < (b.order or 0)
    end)
    if #missing > 0 then
        state.levelStatusMsg = string.format('Loaded %d recipes. Missing: %s', #state.levelPlan, table.concat(missing, ', '))
    else
        state.levelStatusMsg = string.format('Loaded %d recipes for %s.', #state.levelPlan, skillUIName)
    end
end

local function level_plan_start()
    if state.busy or #state.levelPlan == 0 then return end
    state.sessionStarted = false
    state.levelRunning = true
    state.levelCurrentIndex = 1
    state.levelSupplyFailed = {}   -- fresh run: forget which recipes the group was out of last time
    state.levelSkip = {}           -- fresh run: forget which recipes the seatbelt gave up on last time

    -- Find first recipe where skill < trivial
    local eqSkill = nil
    -- get skill from first entry
    local firstSec = (state.iniSections or {})['Skill:' .. (state.levelPlan[1].skillName or '')]
    if firstSec then eqSkill = firstSec.Skill end
    local curSkill = eqSkill and skill_value(eqSkill) or 0
    printf_log("Level start: skill=%s value=%d", tostring(eqSkill), curSkill)

    -- Already at cap? Refuse to start. Without this, pressing Start at cap (e.g. Brewing 200)
    -- launches a full batch that can only fizzle - the skill can't rise. Same illusion-proof
    -- ceiling the advance loop stops on mid-run, so start and mid-run agree.
    local startCap = state.level_skill_ceiling(eqSkill, state.levelPlan[1] and state.levelPlan[1].skillName)
    if curSkill >= startCap then
        printf_log("%s is already at its cap (%d) - nothing to level.", tostring(eqSkill), startCap)
        state.levelRunning = false
        return
    end

    -- Find appropriate starting index - first recipe that is both below trivial
    -- AND has the dropped mats on hand (vendor-only recipes always qualify). When "Supply from
    -- group" is on we DON'T require mats on hand: we start on the first below-trivial recipe anyway,
    -- and the advance block's refill hook pulls its dropped mats from the group on the first pass
    -- (otherwise this pre-check would bail before we ever get to request anything).
    local foundIndex = nil
    for i, entry in ipairs(state.levelPlan) do
        if entry.trivial > curSkill
           and (state.levelSupplyFromGroup or state.canCraftNow(get_recipe(entry.itemName))) then
            foundIndex = i
            break
        end
    end

    if not foundIndex then
        -- Don't just say "nothing to do" - spell out which supplied mat each below-trivial recipe
        -- is short, using the same collectors the preflight uses.
        printf_log('Leveling plan: nothing to do at skill %d - each below-trivial recipe is short a dropped/supplied mat:', curSkill)
        local anyListed = false
        for _, e in ipairs(state.levelPlan) do
            if e.trivial > curSkill then
                local rec = get_recipe(e.itemName)
                local missing = state.missingMats(rec)
                for _, m in ipairs(state.makeableShort(rec)) do missing[#missing + 1] = m end
                if #missing > 0 then
                    anyListed = true
                    printf_log('\ar%s (%d)\ax', e.itemName, e.trivial)   -- recipe name in red, own line
                    for _, m in ipairs(missing) do
                        printf_log('\ay   * %s\ax', m)                     -- each missing mat in yellow, bulleted
                    end
                end
            end
        end
        if not anyListed then
            printf_log('  (no below-trivial recipes remain - skill may be at/above the path cap)')
        end
        state.levelRunning = false
        return
    end

    state.levelCurrentIndex = foundIndex

    local entry = state.levelPlan[state.levelCurrentIndex]
    if not entry then
        printf_log('Leveling plan: already past all trivials at skill %d!', curSkill)
        state.levelRunning = false
        return
    end

    local skillSec = (state.iniSections or {})['Skill:' .. (entry.skillName or '')]
    local rec = get_recipe(entry.itemName)
    if not skillSec or not rec then
        printf_log('ERROR: level plan entry invalid: %s', entry.itemName or '?')
        state.levelRunning = false
        return
    end

    local target = tonumber(state.levelTargetBuf) or 300
    printf_log('Leveling: starting at %s (trivial %d, skill %d, target %d)',
        entry.itemName, entry.trivial, curSkill, target)

    state.pendingJob = {
        action = 'craft',
        skillSection = skillSec,
        recipe = rec,
        quantity = level_batch_qty(rec),
        disposal = entry.disposal,
        kitPack = KIT_PACK_DEFAULT,
        stopOnTrivial = true,  -- always stop at trivial in leveling mode
        leveling = true,       -- leveling-tab run: no trophies
        -- Ask the group for this rung's mats if the toggle is on. This was previously set ONLY on the
        -- rung-ADVANCE job build, so the FIRST rung (the one you press Start on) never carried the flag -
        -- run_engine's group-supply block was skipped and it went straight to "cannot craft, missing
        -- mats" without ever asking (the Misty Thicket Picnic "not even asking" bug: Khulian had 39
        -- Brownie Parts + 987 Fruit, but the first job never requested them).
        supplyFromGroup = state.levelSupplyFromGroup,
        supplyMode = state.levelSupplyMode,
    }
end

-- ======================= ALL-TRADESKILLS AUTO-CHAIN =======================
-- Level every GENERAL tradeskill in dependency order, hands-free: load a skill's path, switch the UI to
-- it, run it until it self-stops (trivial/300 or out of mats), then advance to the next. Stops after
-- Pottery. The specialized skills (Fishing, Research, Make Poison, Alchemy, Tinkering, Alcohol) simply
-- aren't in this list, so they're skipped. Pure orchestration - it reuses the exact per-skill machinery
-- the Start button uses (level_load_recommended + level_plan_start).
state.LEVEL_ALL_ORDER = { 'Jewelcrafting', 'Brewing', 'Tailoring', 'Blacksmithing', 'Fletching', 'Baking', 'Pottery' }

-- Advance to the next skill (or finish). Called at kickoff and each time a skill's run ends. Loops past
-- any skill with no path; if level_plan_start refuses (already at cap / nothing to do) it leaves
-- levelRunning false and we roll straight on to the next skill in the same pass.
state.level_all_next = function()
    while state.levelAllRunning do
        state.levelAllIndex = (state.levelAllIndex or 0) + 1
        local skill = state.LEVEL_ALL_ORDER[state.levelAllIndex]
        if not skill then
            printf_log('\\agAll tradeskills: chain complete\\ax (finished at Pottery).')
            state.levelAllRunning = false
            return
        end
        if RECOMMENDED_PATHS[skill] then
            printf_log('\\agAll tradeskills: %s (%d/%d)\\ax', skill, state.levelAllIndex, #state.LEVEL_ALL_ORDER)
            state.recPathSelected = skill    -- UI: path selector follows to this skill
            state.forceLevelTab   = true     -- UI: jump to the Leveling tab
            level_load_recommended(skill)
            level_plan_start()
            if state.levelRunning then return end   -- it started; wait for it to finish, then we're called again
            -- else it refused (cap / nothing to do) - continue the loop to the next skill
        end
    end
end

-- Kick off the whole chain from the top (Jewelcrafting).
state.level_all_start = function()
    if state.busy or state.levelAllRunning then return end
    state.levelAllRunning = true
    state.levelAllIndex   = 0
    printf_log('\\agStarting ALL tradeskills\\ax - Jewelcrafting through Pottery, hands-free.')
    state.level_all_next()
end

local function run_sell_all_reagents()
    if state.busy then return end
    local skillSec, rec, _ = resolve_current_selection()
    if not skillSec then return end
    state.pendingJob = {
        action = 'sell_reagents',
        skillSection = skillSec,
        recipe = rec,
    }
end

local function run_buy_all_reagents()
    if state.busy then return end
    local skillSec, rec, qty = resolve_current_selection()
    if not skillSec then return end

    state.pendingJob = {
        action = 'buy_reagents',
        skillSection = skillSec,
        recipe = rec,
        quantity = qty,
    }
end

local function run_destroy_all_product()
    if state.busy then return end
    local skillSec, rec, _ = resolve_current_selection()
    if not skillSec then return end

    state.pendingJob = {
        action = 'destroy_all',
        skillSection = skillSec,
        recipe = rec,
    }
end

local function run_level_sell_ingredients()
    if state.busy or #state.levelPlan == 0 then return end
    state.pendingJob = { action = 'level_sell', mode = 'ingredients' }
end

local function run_level_sell_products()
    if state.busy or #state.levelPlan == 0 then return end
    state.pendingJob = { action = 'level_sell', mode = 'products' }
end

-- Every stop is attributed. "Stopped by user" used to appear with no hint of WHO asked: the Stop
-- button and the /tsui stop bind look identical from inside the run. Another lua, macro, or keybind
-- firing '/tsui stop' would silently kill a fishing run and look like a mystery abort. Callers pass
-- a source; anything that doesn't gets a traceback so we can find it.
local function run_stop(src)
    state.stopRequested = true
    state.levelAllRunning = false   -- a Stop halts the whole all-tradeskills chain, not just the current skill
    if src then
        printf_log('Stop requested by: %s', src)
    else
        local tb = ''
        pcall(function() tb = debug.traceback('', 2) or '' end)
        printf_log('Stop requested by an UNNAMED caller (external command or another script?):%s', tb)
    end
end
-- Shared request queue - both the Supply and Summon tabs feed ONE queue and ONE Run All, so a single
-- mule trip fetches farmed drops AND delivers summons together. Rendered on whichever tab is active.
state.render_request_queue = function()
    if themed_button('Run All##ts_req_run', UI.green, 220, UI.btn_h, state.busy or #state.requestQueue == 0) then
        request_queue_run()
    end
    ImGui.SameLine()
    if themed_button('Clear##ts_req_clear', UI.red, 100, UI.btn_h, state.busy or #state.requestQueue == 0) then
        request_queue_clear()
    end
    ImGui.Spacing()
    if #state.requestQueue == 0 then
        ImGui.TextDisabled('Queue empty. + items in Supply or Summon, then Run All.')
    else
        for i, e in ipairs(state.requestQueue) do
            ImGui.Text(string.format('%d.', i))
            ImGui.SameLine()
            if e.mode == 'make' then
                -- Editable batch count (mirrors Supply's Qty box, without the All toggle - a summon is
                -- always a specific count, not "everything the mule has"). Tweak the batch right here.
                ImGui.TextColored(0.85, 0.70, 1.0, 1.0, 'Make')
                ImGui.SameLine()
                ImGui.Text('Qty:')
                ImGui.SameLine()
                ImGui.SetNextItemWidth(70)
                e.qtyBuf = e.qtyBuf or tostring(e.qty or 100)
                e.qtyBuf = ImGui.InputText('##ts_req_mkqty_' .. i, e.qtyBuf, 8)
                e.qty = math.max(1, math.floor(tonumber(e.qtyBuf) or e.qty or 100))
                ImGui.SameLine()
                ImGui.Text(e.item)
            else
                -- [All] + Quantity. All is lit while the box is empty/0; type a number and it greys out
                -- (that exact count is used instead). Everything comes from the group.
                e.qtyBuf = e.qtyBuf or ''
                local isAll = (trim(e.qtyBuf) == '' or (tonumber(e.qtyBuf) or 0) <= 0)
                if themed_button('All##ts_req_all_' .. i, isAll and UI.green or UI.steel, 44, UI.btn_h, false) then
                    e.qtyBuf = ''
                end
                ImGui.SameLine()
                ImGui.Text('Qty:')
                ImGui.SameLine()
                ImGui.SetNextItemWidth(70)
                e.qtyBuf = ImGui.InputText('##ts_req_qty_' .. i, e.qtyBuf, 8)
                ImGui.SameLine()
                ImGui.Text(e.item)
            end
            if not state.busy then
                ImGui.SameLine()
                if ImGui.Button('Del##ts_req_rm_' .. i) then request_queue_remove(i) end
            end
        end
    end
end

local function render_window()
    if not state.windowOpen then return end

    if not state.sizeSet and ImGui.SetNextWindowSize then
        pcall(ImGui.SetNextWindowSize, 640, 680, ImGuiCond.FirstUseEver or 1)
        state.sizeSet = true
    end
    -- When the log is minimized/restored, contract/grow the whole window by the log's height so there's
    -- no dead space (the window is user-sized, not auto-resize, so we drive the change explicitly).
    if state.pendingLogResize and state.lastWinW and state.lastWinH and ImGui.SetNextWindowSize then
        pcall(ImGui.SetNextWindowSize, state.lastWinW, math.max(240, state.lastWinH + state.pendingLogResize), ImGuiCond.Always or 1)
        state.pendingLogResize = nil
    end

    local styleVars, styleCols = push_ui_style()
    pcall(function()   -- keep the window from being dragged into an unreadable sliver
        if ImGui.SetNextWindowSizeConstraints then
            ImGui.SetNextWindowSizeConstraints(ImVec2(360, 280), ImVec2(4000, 4000))
        end
    end)
    local open, shouldDraw = ImGui.Begin('LazCraft  [' .. (state.VERSION or '?') .. ']###tradeskill_suite_ui', state.windowOpen)
    state.windowOpen = open
    state.wasOpen = open
    if shouldDraw == nil then shouldDraw = open end

    if shouldDraw then
        -- Remember the live window size so a log minimize/restore can adjust it by the log's height.
        if ImGui.GetWindowSize then
            local w, h = ImGui.GetWindowSize()
            if w and h and w > 0 and h > 0 then state.lastWinW, state.lastWinH = w, h end
        end
        local ok, drawErr = pcall(function()

            -- ── Status bar (persistent, above the tabs) ─────────────────────
            do
                local running = state.busy
                if themed_button('Stop##ts_top_stop', UI.red, 64, UI.btn_h, not running) then
                    -- Full stop: abort the current job AND kill every continuation path so nothing
                    -- restarts. Without clearing pendingJob, a job already staged would start right
                    -- after (each executor resets stopRequested at its start), so STOP wouldn't stick.
                    state.queueRunning = false
                    state.levelRunning = false
                    state.pendingJob = nil
                    state.pauseRequested = false   -- a Stop while paused releases the pause spin, then stops
                    run_stop('UI Stop button')   -- sets stopRequested = true; check_stop() aborts the in-flight job
                end
                -- Pause / Resume, right next to Stop. Pause suspends at the next combine checkpoint and
                -- hands the toon to the player; Resume re-validates and continues at the current combine.
                ImGui.SameLine()
                if state.paused or state.pauseRequested then
                    if themed_button('Resume##ts_top_resume', UI.green, 74, UI.btn_h, not running) then
                        state.request_resume()
                    end
                else
                    if themed_button('Pause##ts_top_pause', UI.amber or UI.gold or UI.green, 74, UI.btn_h, not running) then
                        state.request_pause()
                    end
                end
                ImGui.SameLine()
                do   -- status lamp: green running / amber-pulse paused / grey idle
                    local lr, lg, lb = 0.42, 0.42, 0.42
                    if running then
                        if state.paused then
                            local t = 0.4 + 0.6 * math.abs(math.sin(mq.gettime() / 350))
                            lr, lg, lb = 0.95 * t, 0.72 * t, 0.20 * t
                        else
                            lr, lg, lb = 0.36, 0.80, 0.46
                        end
                    end
                    pcall(function()
                        local dl = ImGui.GetWindowDrawList()
                        local cx, cy = ImGui.GetCursorScreenPos()
                        local c = ImGui.GetColorU32(ImVec4(lr, lg, lb, 1))
                        local ok = pcall(function() dl:AddRectFilled(ImVec2(cx + 1, cy + 3), ImVec2(cx + 11, cy + 13), c, 0, 0) end)
                        if not ok then dl:AddRectFilled(cx + 1, cy + 3, cx + 11, cy + 13, c) end
                    end)
                    ImGui.Dummy(13, 16)
                    ImGui.SameLine()
                end
                if running then
                    if state.paused then
                        ImGui.TextColored(0.98, 0.84, 0.28, 1.0, 'PAUSED')
                    else
                        ImGui.TextColored(0.85, 0.66, 0.23, 1.0, 'RUNNING')
                    end
                else
                    ImGui.TextColored(0.45, 0.45, 0.45, 1.0, 'IDLE')
                end
                if state.statusMsg and state.statusMsg ~= '' then
                    ImGui.SameLine()
                    ImGui.TextDisabled('- ' .. state.statusMsg)
                end
                -- Global "Bank Trophies & Tools" button - right-aligned, above the tabs, so it works
                -- from any tab. Deposits every trophy AND returned tool you're holding in one trip.
                local _bankBtnW = 210
                ImGui.SameLine()
                ImGui.SetCursorPosX(math.max(ImGui.GetCursorPosX(), ImGui.GetWindowWidth() - _bankBtnW - 16))
                if themed_button('Bank Trophies, Tools & Kits##ts_bank_global', UI.blue, _bankBtnW, UI.btn_h, state.busy) then
                    state.pendingJob = { action = 'bank_trophies' }
                end
            end
            ImGui.Separator()

            -- ── Tabs ──────────────────────────────────────────────────────────
            if ImGui.BeginTabBar('##ts_tabs') then

                -- ── CRAFT TAB ─────────────────────────────────────────────────
                if ImGui.BeginTabItem('Craft##ts_tab_craft') then
                    local _tok, _terr = pcall(function()
                    state.activeTab = 'Craft'

                    -- Tradeskill picker (+ Radix as a special end-game activity)
                    state.radixRecipes = state.radixRecipes or {
                        -- top-level end-game combines
                        'Essence Fusion Chamber', 'Flask of Fruit Juice', 'Fizzlepop', 'Barbecue Ribs', 'Baked Potato',
                        -- Essence Fusion Chamber subcombines (deeper subs / other trees omitted by request)
                        'Fusion Chamber Housing', 'Fusion Chamber Base', 'Element Imbued Metal Sheet',
                        'Elemental Forging Temper',
                    }
                    local skillLabel = current_skill_name() or 'No tradeskills loaded'
                    if ImGui.BeginCombo('Tradeskill##ts_skill', skillLabel) then
                        -- Hide class-restricted skills for other classes (illusion-SAFE: Me.Class is never
                        -- changed by an illusion). Alchemy = Shaman, Make Poison = Rogue (from pathClassReq).
                        -- Tinkering is GNOME-only: gate it on SkillCap (illusion-proof - the cap is 0 for a
                        -- non-Gnome and >0 for a Gnome even at skill 0; Me.Race can't be used, it follows illusions).
                        local myClass = mq.TLO.Me.Class.Name() or ''
                        for i, name in ipairs(state.skills) do
                            -- Runic Tablets is an end-game (Research-based) craft, shown down in the
                            -- end-game section with Radix - not here among the leveling skills.
                            if name ~= 'Runic Tablets' then
                            local req = state.pathClassReq[name]
                            local show = (not req or req == myClass)
                            if show and name == 'Tinkering' then
                                show = ((mq.TLO.Me.SkillCap('Tinkering')() or 0) > 0)
                            end
                            if show then
                            -- Parity with the Leveling dropdown: show the live skill value, green at cap.
                            local sec = (state.iniSections or {})['Skill:' .. name]
                            local eqName = (sec and sec.Skill) or name
                            local sval = skill_value(eqName) or 0
                            local scap = mq.TLO.Me.SkillCap(eqName)() or 0
                            if scap <= 0 then scap = 300 end
                            local scapped = sval >= scap
                            local slbl = string.format('%s  (%d)', name, sval)
                            if scapped then ImGui.PushStyleColor(ImGuiCol.Text, 0.35, 0.85, 0.45, 1.0) end
                            if ImGui.Selectable(slbl .. '##ts_skill_' .. i, (not state.craftActivityRadix) and (not state.craftActivityFishing) and (not state.craftActivityBooze) and state.skillIndex == i) then
                                state.craftActivityRadix = false
                                state.craftActivityFishing = false
                                state.craftActivityBooze = false
                                state.skillIndex = i
                                state.itemIndex = 1
                            end
                            if scapped then ImGui.PopStyleColor(1) end
                            end
                            end
                        end
                        ImGui.Separator()
                        -- Runic Tablets: end-game Research-based craft, grouped with Radix. No skill
                        -- number (it's not a leveling path; Research level here is misleading).
                        do
                            local runicIdx
                            for i, nm in ipairs(state.skills) do if nm == 'Runic Tablets' then runicIdx = i; break end end
                            if runicIdx then
                                local sel = (not state.craftActivityRadix) and (not state.craftActivityFishing) and (not state.craftActivityBooze) and state.skillIndex == runicIdx
                                if ImGui.Selectable('Runic Tablets##ts_skill_runic', sel) then
                                    state.craftActivityRadix = false
                                    state.craftActivityFishing = false
                                    state.craftActivityBooze = false
                                    state.skillIndex = runicIdx
                                    state.itemIndex = 1
                                end
                            end
                        end
                        if ImGui.Selectable('Radix##ts_skill_radix', state.craftActivityRadix == true) then
                            state.craftActivityRadix = true
                            state.craftActivityFishing = false
                            state.craftActivityBooze = false
                            state.itemIndex = 1
                        end
                        if ImGui.Selectable('Fishing##ts_skill_fishing', state.craftActivityFishing == true) then
                            state.craftActivityFishing = true
                            state.craftActivityRadix = false
                            state.craftActivityBooze = false
                            state.itemIndex = 1
                        end
                        ImGui.EndCombo()
                    end

                    -- Fishing (leveling): a dropdown activity like Radix, but it isn't a recipe -
                    -- so when it's selected we render just its controls and skip the entire recipe
                    -- body below via an early return from the Craft-tab draw function (EndTabItem
                    -- lives outside this pcall, so returning here is safe).
                    if state.craftActivityFishing then
                        if not state.fishLists then state.loadFishLists() end
                        if not state.fishTrophyQty then state.fishTrophyQty = {} end
                        ImGui.TextColored(0.8, 0.8, 0.3, 1.0, 'Trophy fishing')
                        ImGui.SameLine()
                        state.help_marker('With Bounty of the Master Baiter, can summon poles and bait. If none, will travel to vendor, purchase bait and 5 poles, and loop until you have caught the desired quantity. Recommend getting the trophy!')
                        ImGui.Spacing()
                        if themed_button('Fish##ts_fish_here', UI.green, 190, UI.btn_h, state.busy) then
                            state.pendingJob = { action = 'fish', spot = 'here' }
                        end
                        ImGui.Spacing()
                        -- One button per trophy target. Add fish here as you unlock them:
                        -- { label = button text, fish = exact item name, spot = a FISH_SPOTS key }.
                        local FISH_TROPHIES = {
                            { label = 'Fish Gunthak (Trophy)', fish = 'Gunthak Gourami', spot = 'gunthak' },
                            { label = "Fish Dagnor's Cauldron (Trophy)", fish = 'Cauldron Trout', spot = 'dagnor' },
                            { label = 'Fish North Karana (Trophy)', fish = 'Thunder Salmon', spot = 'northkarana' },
                            { label = 'Fish Firiona Vie (Trophy)', fish = '8lb Fetid Bass', spot = 'firiona' },
                        }
                        for _, t in ipairs(FISH_TROPHIES) do
                            if themed_button(t.label .. '##ts_troph_' .. t.fish, UI.green, 190, UI.btn_h, state.busy) then
                                state.pendingJob = { action = 'fish', spot = t.spot, targetFish = t.fish,
                                    targetQty = tonumber(state.fishTrophyQty[t.fish] or '1') or 1 }
                            end
                            ImGui.SameLine()
                            state.fishTrophyQty[t.fish] = ImGui.InputText(t.fish .. ' (qty)##ts_trophqty_' .. t.fish,
                                state.fishTrophyQty[t.fish] or '1', 5)
                        end
                        if themed_button('Fish (GoD fishing)##ts_fish_natimbi', UI.green, 190, UI.btn_h, state.busy) then
                            state.pendingJob = { action = 'fish', spot = 'natimbi' }   -- Abysmal -> Nedaria -> Natimbi, fishes until you stop
                        end
                        if themed_button('Fish Hardcore Qeynos (Shard)##ts_fish_hardcore', UI.green, 220, UI.btn_h, state.busy) then
                            -- Rift chain -> instance, fishes until you land 1 Shard of a Broken Reality, then stops.
                            state.pendingJob = { action = 'fish', spot = 'hardcore', targetFish = 'Shard of a Broken Reality', targetQty = 1 }
                        end
                        ImGui.Spacing()
                        ImGui.Separator()
                        ImGui.TextDisabled('Once you have all four fish, combine them into the trophy:')
                        if themed_button('Make Fishing Trophy##ts_fish_maketrophy', UI.blue, 190, UI.btn_h, state.busy) then
                            local rrec = get_recipe('Fishing Trophy')
                            if not rrec then
                                printf_log('No recipe for Fishing Trophy - make sure the updated tradeskills.ini is in your lazcraft folder.')
                            else
                                state.pendingJob = {
                                    action = 'craft',
                                    skillSection = { Skill = 'Fishing' },   -- minimal; vendor mats resolve per-item
                                    recipe = rrec,
                                    quantity = 1,
                                    disposal = DISPOSAL.KEEP,               -- always keep the trophy
                                    kitPack = KIT_PACK_DEFAULT,
                                    stopOnTrivial = false,
                                }
                            end
                        end
                        ImGui.SameLine()
                        if themed_button('Stop##ts_fish_stop', UI.red, 90, UI.btn_h, not state.busy) then
                            state.pendingJob = nil
                            run_stop('UI Stop button')
                        end
                        ImGui.TextDisabled('Fishing to level (PoK, skill 200) is now on the Leveling tab.')

                        ImGui.Separator()
                        -- Catch handling. Hold a caught item on the cursor, then click Keep or
                        -- Destroy to classify it: it's added to that list (and removed from the
                        -- other). Neither button ever destroys the held item - both just bag it -
                        -- so a misclick can't nuke anything. Actual destroying only happens during
                        -- an active run, when a Destroy-listed item is caught.
                        local cur = mq.TLO.Cursor.Name() or ''
                        if cur ~= '' then
                            ImGui.Text('On cursor: ')
                            ImGui.SameLine()
                            ImGui.TextColored(0.85, 0.66, 0.23, 1.0, cur)
                        else
                            ImGui.TextDisabled('Hold a caught item on your cursor to classify it.')
                        end
                        if themed_button('Keep cursor item##ts_fish_keep', UI.blue, 150, UI.btn_h, cur == '') then
                            state.addFishItem('keep', cur)
                            mq.cmd('/autoinventory')
                        end
                        ImGui.SameLine()
                        if themed_button('Destroy cursor item##ts_fish_destroy', UI.red, 160, UI.btn_h, cur == '') then
                            state.addFishItem('destroy', cur)
                            mq.cmd('/autoinventory')   -- bag it, never /destroy from the panel
                        end

                        -- Current lists (click x to remove an entry).
                        local function draw_fish_bucket(label, bucket)
                            local set = (state.fishLists and state.fishLists[bucket]) or {}
                            local names = {}
                            for n in pairs(set) do names[#names + 1] = n end
                            table.sort(names)
                            if ImGui.CollapsingHeader(string.format('%s list (%d)##ts_fish_bucket_%s', label, #names, bucket)) then
                                if #names == 0 then
                                    ImGui.TextDisabled('  (empty)')
                                else
                                    for _, n in ipairs(names) do
                                        if ImGui.Button('x##ts_fish_rm_' .. bucket .. '_' .. n) then
                                            state.removeFishItem(bucket, n)
                                        end
                                        ImGui.SameLine()
                                        ImGui.Text(n)
                                    end
                                end
                            end
                        end
                        draw_fish_bucket('Destroy', 'destroy')
                        draw_fish_bucket('Keep', 'keep')
                        return
                    end

                    -- Skill level
                    local skillSecForDisplay = current_skill_section()
                    local eqSkillName = skillSecForDisplay and skillSecForDisplay.Skill
                    if eqSkillName and eqSkillName ~= '' then
                        local lvl = skill_value(eqSkillName)
                        ImGui.TextDisabled(string.format('%s skill: %d', eqSkillName, lvl or 0))
                    end

                    -- Item picker MERGED with search: open the combo to see the skill's items, or type
                    -- 2+ letters in the filter box at the top to find ANY recipe for this skill. Same
                    -- behavior as before - a filtered pick sets craftPick, a plain list pick sets itemIndex.
                    local items = current_skill_items()
                    if state.itemIndex > #items then state.itemIndex = 1 end
                    local itemLabel = current_item_name() or 'No items configured'
                    if ImGui.BeginCombo('Item##ts_item', itemLabel) then
                        ImGui.SetNextItemWidth(-1)
                        state.craftSearchBuf = ImGui.InputText('##ts_item_filter', state.craftSearchBuf or '', 64)
                        local q = trim(state.craftSearchBuf or ''):lower()
                        local sk = current_skill_name()
                        if #q >= 2 then
                            if q ~= state.craftSugQuery or sk ~= state.craftSugSkill then
                                state.craftSugQuery, state.craftSugSkill, state.craftSug = q, sk, {}
                                local pool = state.craftActivityRadix and (state.radixRecipes or {}) or (state.allRecipeNames or (function() state.allRecipeNames = state.build_recipe_names(); return state.allRecipeNames end)())
                                for _, rn in ipairs(pool) do
                                    local hit = rn:lower():find(q, 1, true)
                                    if hit and (state.craftActivityRadix or state.skill_name_for_recipe(rn) == sk) then
                                        state.craftSug[#state.craftSug + 1] = rn
                                        if #state.craftSug >= 20 then break end
                                    end
                                end
                            end
                            for _, rn in ipairs(state.craftSug or {}) do
                                if ImGui.Selectable(rn .. '##ts_craft_sug_' .. rn) then
                                    state.craftPick = rn
                                    state.craftSearchBuf = ''
                                    state.craftSugQuery = nil
                                end
                            end
                        else
                            state.craftSugQuery = nil
                            for i, name in ipairs(items) do
                                if ImGui.Selectable(name .. '##ts_item_' .. i, state.itemIndex == i and not state.craftPick) then
                                    state.itemIndex = i
                                    state.craftPick = nil   -- combo selection wins over a prior search pick
                                end
                            end
                        end
                        ImGui.EndCombo()
                    end
                    do
                        local previewRec = get_recipe(current_item_name())
                        -- End-game crafts (Radix, Runic Tablets) aren't leveling paths, so a trivial
                        -- number is meaningless/misleading there - only show it for normal skills.
                        local isEndGame = state.craftActivityRadix or (current_skill_name() == 'Runic Tablets')
                        if previewRec and previewRec.trivial and not isEndGame then
                            ImGui.SameLine()
                            ImGui.TextDisabled(string.format('Trivial: %d', previewRec.trivial))
                        end
                    end

                    -- Quantity for this recipe. Run it with Start below; batch it with + Queue (moved
                    -- next to Start/Stop). "Make now" and "Plan (BOM)" removed - Start does the same run,
                    -- and the ingredient table below already shows the bill of materials.
                    ImGui.Separator()
                    state.quantityBuf = ImGui.InputText('Quantity##ts_qty', state.quantityBuf, 8)

                    ImGui.Separator()

                    -- Disposal
                    local dispRec = get_recipe(current_item_name())
                    local isSellable = not dispRec or dispRec.sellable ~= false
                    -- When we ARRIVE at a new recipe that can't be sold (Tinkering/Pottery), auto-select KEEP
                    -- as the default - but only once, on the switch, so the user can still choose Destroy and
                    -- it sticks. Previously non-sellable recipes auto-armed DESTROY, which risked silently
                    -- destroying output. Keep is the safe default; Destroy stays available as a deliberate pick.
                    local curPick = current_item_name()
                    if curPick ~= state._dispLastPick then
                        state._dispLastPick = curPick
                        if not isSellable then state.disposalMode = DISPOSAL.KEEP end
                    end
                    -- Safety net: never leave SELL selected on a non-sellable item (falls back to KEEP).
                    if not isSellable and state.disposalMode == DISPOSAL.SELL then
                        state.disposalMode = DISPOSAL.KEEP
                    end
                    -- Radix is always KEEP (end-game outputs you'd never sell/destroy from here). Hide the
                    -- Sell/Destroy choice entirely on that page to avoid a costly mis-click.
                    if state.craftActivityRadix then
                        state.disposalMode = DISPOSAL.KEEP
                        ImGui.Text('Finished items:  Keep')
                    else
                    ImGui.Text('Finished items:')
                    ImGui.SameLine()
                    if not isSellable then
                        ImGui.PushStyleColor(ImGuiCol.Text, 0.5, 0.5, 0.5, 1.0)
                        ImGui.RadioButton('Sell##ts_disp_sell', false)
                        ImGui.PopStyleColor(1)
                    else
                        if ImGui.RadioButton('Sell##ts_disp_sell', state.disposalMode == DISPOSAL.SELL) then
                            state.disposalMode = DISPOSAL.SELL
                        end
                    end
                    ImGui.SameLine()
                    if ImGui.RadioButton('Destroy##ts_disp_destroy', state.disposalMode == DISPOSAL.DESTROY) then
                        state.disposalMode = DISPOSAL.DESTROY
                    end
                    ImGui.SameLine()
                    if ImGui.RadioButton('Keep##ts_disp_keep', state.disposalMode == DISPOSAL.KEEP) then
                        state.disposalMode = DISPOSAL.KEEP
                    end
                    end
                    -- Persist the Craft disposal choice per character when it changes (catches all three
                    -- radios + the auto-adjust for non-sellable items, in one place).
                    if state.disposalMode ~= state._savedDisposalMode then
                        state._savedDisposalMode = state.disposalMode
                        if state.save_settings and not state._loadingSettings then state.save_settings() end
                    end

                    -- Supply from group members (applies to BOTH Start and the queue). Off by default.
                    -- When ON, each craft first pulls its dropped-mat shortfall from the group in Marr
                    -- (needed = exact shortfall; all = sweep everything the group has), then crafts.
                    -- Given a soft gold accent + spacing so it doesn't blend into the disposal radios -
                    -- it's an important, easy-to-miss toggle.
                    ImGui.Spacing()
                    ImGui.PushStyleColor(ImGuiCol.Text, 0.96, 0.80, 0.34, 1.0)       -- warm gold label
                    ImGui.PushStyleColor(ImGuiCol.CheckMark, 0.98, 0.84, 0.28, 1.0)  -- gold checkmark
                    do
                        local _prev = state.craftSupplyFromGroup
                        state.craftSupplyFromGroup = ImGui.Checkbox('Supply from group members##ts_craft_supply', state.craftSupplyFromGroup)
                        if state.craftSupplyFromGroup ~= _prev and state.save_settings then state.save_settings() end
                    end
                    ImGui.PopStyleColor(2)
                    ImGui.SameLine()
                    state.help_marker('On Start, quickly checks your group for EVERY item this craft needs (bags + bank) and pulls whatever they have. Members just need to be in your current zone - no Marr trip. Anything nobody has is bought/crafted as normal.')
                    if state.craftSupplyFromGroup then
                        ImGui.Indent(24)
                        if ImGui.RadioButton('Only what I need##ts_craft_supply_needed', state.craftSupplyMode ~= 'all') then
                            state.craftSupplyMode = 'needed'
                        end
                        ImGui.SameLine()
                        if ImGui.RadioButton('Trade all mats##ts_craft_supply_all', state.craftSupplyMode == 'all') then
                            state.craftSupplyMode = 'all'
                        end
                        ImGui.SameLine()
                        ImGui.TextDisabled(state.craftSupplyMode == 'all'
                            and '(one big pull - fewer Marr trips, more bag use)'
                            or  '(exact shortfall - less bag use)')
                        ImGui.Unindent(24)
                    end

                    -- Cross-zone supply: if same-zone supply comes up short, ask the network and travel
                    -- to the other hub (Marr/PoK) if a holder is there. Ask-first, so no wasted trips.
                    do
                        local _prevXZ = state.crossZoneSupply
                        state.crossZoneSupply = ImGui.Checkbox('Cross-zone supply (Marr<->PoK)##ts_crosszone', state.crossZoneSupply)
                        if state.crossZoneSupply ~= _prevXZ and state.save_settings then state.save_settings() end
                    end
                    ImGui.SameLine()
                    state.help_marker('If nobody in your current zone has a needed mat, the crafter asks the whole network who does. If a holder is in the OTHER crafting hub (Marr or PoK, including its AFK mirror), it travels there to collect - but only after confirming they actually have it, so no wasted trips. Bots in any other zone are ignored.')

                    -- Placed right under Supply and given the same gold accent so the two "assist" toggles
                    -- read as a pair.
                    do
                        local dnm = current_item_name()
                        if dnm and state.draughtRecipes[dnm] then
                            if state.useDraught[dnm] == nil then state.useDraught[dnm] = true end   -- auto-fill on
                            ImGui.PushStyleColor(ImGuiCol.Text, 0.96, 0.80, 0.34, 1.0)
                            ImGui.PushStyleColor(ImGuiCol.CheckMark, 0.98, 0.84, 0.28, 1.0)
                            state.useDraught[dnm] = ImGui.Checkbox('Use Draught of the Craftsman##ts_draught_' .. dnm, state.useDraught[dnm])
                            ImGui.PopStyleColor(2)
                            ImGui.SameLine()
                            state.help_marker('Attempts to use a Draught of the Craftsman if it is in inventory and not on cooldown.')
                        end
                    end

                    -- (Pre-load dropped mats button moved down to the Start/Stop/+Queue row.)

                    -- When crafting Runic Tablets, surface the dropped spells the runes need so
                    -- they can be requested (pulled from a mule/bank) before crafting. Only the
                    -- 10 non-researchable ones - the other 7 you research on the Research tab.
                    if current_skill_name() == 'Runic Tablets' then
                        -- Each rune's class == the class of the spell it consumes, shown in ().
                        if ImGui.CollapsingHeader('Dropped Spells (pre-load these)##ts_craft_dropspells') then
                            ImGui.TextDisabled('Looted spells the runes consume. + queues a pull; Run All on the Request tab.')
                            local DROP_SPELLS = {
                                { 'Spell: Theft of Agony', 'Shadowknight' },
                                { 'Tome of Assault', 'Rogue' },
                                { 'Tome of Brutal Onslaught Discipline', 'Warrior' },
                                { 'Tome of Dragon Fang', 'Monk' },
                                { 'Tome of Jolting Snapkicks', 'Ranger' },
                                { 'Spell: Mana Weave', 'Wizard' },
                                { 'Tome of Overpowering Frenzy', 'Berserker' },
                                { 'Spell: Echo of Tashan', 'Enchanter' },
                                { 'Spell: Talisman of the Panther', 'Shaman' },
                                { 'Song: Echos of the Past', 'Bard' },
                            }
                            for i, sp in ipairs(DROP_SPELLS) do
                                if ImGui.Button('+##ts_craft_dropspell_' .. i) then request_queue_add(sp[1], 'stack') end
                                ImGui.SameLine()
                                ImGui.Text(sp[1])
                                ImGui.SameLine()
                                ImGui.TextDisabled('(' .. sp[2] .. ')')
                            end
                        end
                        if ImGui.CollapsingHeader('Researchable Spells (make these)##ts_craft_resspells') then
                            ImGui.TextDisabled('Runes consume these too - Research makes one via the research system.')
                            local RES_SPELLS = {
                                { 'Spell: Theft of Hate', 'Shadowknight', 'shadowknight' },
                                { 'Spell: Dark Salve', 'Necromancer', 'necromancer' },
                                { 'Spell: Renewal of Jerikor', 'Magician', 'magician' },
                                { 'Spell: Wave of Piety', 'Paladin', 'paladin' },
                                { "Spell: Sun's Corona", 'Druid', 'druid' },
                                { 'Spell: Healing of Mikkily', 'Beastlord', 'beastlord' },
                                { 'Spell: Panoply of Vie', 'Cleric', 'cleric' },
                            }
                            for i, sp in ipairs(RES_SPELLS) do
                                if themed_button('Research##ts_craft_resspell_' .. i, UI.green, 90, UI.btn_h, state.busy) then
                                    state.pendingJob = { action = 'research',
                                        items = { { name = sp[1], key = sp[1] .. '##' .. sp[3], qty = 1 } } }
                                end
                                ImGui.SameLine()
                                ImGui.Text(sp[1])
                                ImGui.SameLine()
                                ImGui.TextDisabled('(' .. sp[2] .. ')')
                            end
                        end
                        ImGui.Separator()
                    end

                    ImGui.Separator()

                    -- Recipe preview
                    local rec = get_recipe(current_item_name())
                    local qty = math.max(1, math.min(MAX_QUANTITY, tonumber(state.quantityBuf) or 1))
                    draw_recipe_preview(rec, qty)

                    -- Radix: per-recipe farmed-mat requests, right on the crafter. Each dropped mat this
                    -- combine needs gets a Request button that pulls the exact shortfall from the group in
                    -- Marr - no Request-tab round trip. NO-DROP mats are excluded (can't be traded).
                    if state.craftActivityRadix and rec then
                        local dmats = state.droppedMatsInTree(rec)
                        if #dmats > 0 then
                            ImGui.Spacing()
                            if ImGui.CollapsingHeader('Supply from group##ts_radix_supply') then
                                ImGui.SameLine()
                                state.help_marker('Pulls exact item number from other group members in Marrs!')
                                local plan = plan_requirements(rec.key or rec.name, qty)
                                local demand = (plan and plan.supplyDemand) or {}
                                for _, nm in ipairs(dmats) do
                                    local need = demand[nm] or 0
                                    local have = item_count(nm)
                                    local short = math.max(0, need - have)
                                    if themed_button('Request##radixmat_' .. nm, UI.blue, 90, UI.btn_h, state.busy or short == 0) then
                                        state.pendingJob = { action = 'reqexact', item = nm, n = need }
                                    end
                                    ImGui.SameLine()
                                    if short == 0 and need > 0 then
                                        ImGui.TextColored(0.35, 0.85, 0.45, 1.0, string.format('%s  (have %d/%d)', nm, have, need))
                                    else
                                        ImGui.Text(string.format('%s  (need %d, have %d)', nm, need, have))
                                    end
                                end
                            end
                        end
                    end

                    ImGui.Separator()

                    -- Status
                    if state.busy then
                        local liveSkill = eqSkillName and skill_value(eqSkillName)
                        if state.queueRunning then
                            ImGui.TextColored(0.3, 0.9, 0.4, 1.0, string.format('Queue %d/%d  |  Combines: %d/%d',
                                state.currentQueueIndex, #state.queue, state.doneCount, state.totalCount))
                        elseif liveSkill then
                            ImGui.TextColored(0.3, 0.9, 0.4, 1.0, string.format('Running: %d/%d  (%s: %d)',
                                state.doneCount, state.totalCount, eqSkillName, liveSkill))
                        else
                            ImGui.TextColored(0.3, 0.9, 0.4, 1.0, string.format('Running: %d/%d', state.doneCount, state.totalCount))
                        end
                    end

                    ImGui.Spacing()
                    ImGui.Separator()

                    -- Buttons, grouped: Run / Ingredients / Cleanup, each under a dim label so the row
                    -- of buttons reads as distinct clusters instead of one undifferentiated wall.
                    ImGui.TextDisabled('CRAFTING')
                    if themed_button('Start##ts_start', UI.green, UI.btn_w, UI.btn_h, state.busy) then
                        state.sessionStarted = false  -- reset session on manual start
                        run_start()
                    end
                    ImGui.SameLine()
                    if themed_button('Stop##ts_stop', UI.red, UI.btn_w, UI.btn_h, not state.busy) then
                        state.queueRunning = false
                        run_stop('UI Stop button')
                    end
                    ImGui.SameLine()
                    if themed_button('+ Queue##ts_queue_add_inline', UI.blue, 90, UI.btn_h, state.busy) then
                        queue_add()   -- batch the current recipe into the queue (unchanged behavior)
                    end
                    ImGui.SameLine()
                    if themed_button('Pre-load mats##ts_craft_preload', UI.amber, 150, UI.btn_h, state.busy) then
                        local q  = math.max(1, math.min(MAX_QUANTITY, tonumber(state.quantityBuf) or 1))
                        local nm = current_item_name()
                        if not get_recipe(nm) then
                            printf_log('No recipe data for %s.', tostring(nm))
                        else
                            state.pendingJob = { action = 'preload', recipeList = { { name = nm, combines = q } } }
                        end
                    end

                    -- Reagent buy/sell live here on Craft (seen when you're prepping a run).
                    -- Reload config / Bank trophies are on the Settings tab.
                    ImGui.Spacing()
                    ImGui.Separator()
                    ImGui.TextDisabled('INGREDIENTS')
                    if themed_button('Buy Ingredients##ts_buy', UI.blue, 150, UI.btn_h, state.busy) then
                        run_buy_all_reagents()
                    end
                    ImGui.SameLine()
                    if themed_button('Sell Ingredients##ts_sell', UI.blue, 150, UI.btn_h, state.busy) then
                        run_sell_all_reagents()
                    end

                    ImGui.Spacing()
                    ImGui.Separator()
                    local productName = current_item_name() or 'Item'
                    -- Cleanup (Sell all / Destroy all) is hidden on the Radix page - these are precious
                    -- end-game outputs; no reason to sell/destroy them here, and a mis-click is costly.
                    if not state.craftActivityRadix then
                    ImGui.TextDisabled('CLEANUP')
                    -- Sell all: non-destructive counterpart to Destroy all - navigates to a vendor and
                    -- sells every one of this product on hand, so an accidental overmake clears bags
                    -- without losing the value. Reuses the level-sell path with an explicit name.
                    if themed_button('Sell all ' .. productName .. '##ts_sell_all', UI.blue, 0, UI.btn_h, state.busy) then
                        if not get_recipe(current_item_name()) then
                            printf_log('No recipe data for %s.', tostring(productName))
                        else
                            state.pendingJob = { action = 'level_sell', mode = 'products', names = { current_item_name() } }
                        end
                    end
                    if themed_button('Destroy all ' .. productName .. '##ts_destroy_all', UI.red, 0, UI.btn_h, state.busy) then
                        run_destroy_all_product()
                    end
                    end

                    -- ===== Craft queue (batch several recipes, run in sequence) =====
                    -- Folded in from the old Queue tab. "+ Queue" above adds the current selection;
                    -- this list runs them in order. Distinct from the Request queue (supply) and the
                    -- Level plan (auto-sequenced grind).
                    ImGui.Separator()
                    ImGui.TextDisabled('Craft queue - runs these recipes in sequence (+ Queue adds the current one).')
                    ImGui.Spacing()
                    if themed_button('Start Queue##ts_queue_start', UI.green, 120, UI.btn_h, state.busy or #state.queue == 0) then
                        state.sessionStarted = false
                        queue_start()
                    end
                    ImGui.SameLine()
                    if themed_button('Clear Queue##ts_queue_clear', UI.red, 100, UI.btn_h, state.busy) then
                        queue_clear()
                    end
                    ImGui.SameLine()
                    if themed_button('Pre-load mats##ts_queue_preload', UI.amber, 130, UI.btn_h, state.busy or #state.queue == 0) then
                        -- The queue has FIXED quantities, so we can pull the exact total dropped-mat
                        -- shortfall for the WHOLE queue in one Marr's trip before Start Queue.
                        local recipeList = {}
                        for _, e in ipairs(state.queue) do
                            recipeList[#recipeList + 1] = { name = e.itemName, combines = e.qty or 1 }
                        end
                        state.pendingJob = { action = 'preload', recipeList = recipeList }
                    end
                    if #state.queue == 0 then
                        ImGui.TextDisabled('Queue is empty. Pick a recipe above and click + Queue.')
                    else
                        for i, entry in ipairs(state.queue) do
                            local isRunning = state.queueRunning and i == state.currentQueueIndex
                            local isDone = state.queueRunning and i < state.currentQueueIndex
                            if isRunning then
                                ImGui.TextColored(0.3, 0.9, 0.4, 1.0, string.format('▶ %d.', i))
                            elseif isDone then
                                ImGui.TextColored(0.5, 0.5, 0.5, 1.0, string.format('✓ %d.', i))
                            else
                                ImGui.Text(string.format('   %d.', i))
                            end
                            ImGui.SameLine()
                            local dispStr = entry.disposal == DISPOSAL.SELL and 'Sell' or
                                            entry.disposal == DISPOSAL.DESTROY and 'Destroy' or 'Keep'
                            local stopStr = entry.stopOnTrivial and ' [stop@triv]' or ''
                            ImGui.Text(string.format('%dx %s  [%s]%s', entry.qty, entry.itemName, dispStr, stopStr))
                            if not state.busy then
                                ImGui.SameLine()
                                if ImGui.Button('Up##q_up_' .. i) then queue_move_up(i) end
                                ImGui.SameLine()
                                if ImGui.Button('Dn##q_dn_' .. i) then queue_move_down(i) end
                                ImGui.SameLine()
                                if ImGui.Button('Del##q_rm_' .. i) then queue_remove(i) end
                            end
                        end
                    end

                    end)
                    if not _tok then ImGui.TextColored(0.95, 0.35, 0.35, 1.0, 'tab render error - see log'); printf_log('UI tab render error: %s', tostring(_terr)) end
                    ImGui.EndTabItem()
                end

                -- ── LEVELING TAB ─────────────────────────────────────────────────
                local _lvlSel = 0
                if state.forceLevelTab then
                    _lvlSel = (ImGuiTabItemFlags and ImGuiTabItemFlags.SetSelected) or 0
                    state.forceLevelTab = false
                end
                if ImGui.BeginTabItem('Leveling##ts_tab3', nil, _lvlSel) then
                    local _tok, _terr = pcall(function()
                    state.activeTab = 'Level'

                    -- Recommended path dropdown (class-restricted paths hidden for other classes)
                    local recPaths = {}
                    local myClass = mq.TLO.Me.Class.Name() or ''
                    local avail = {}
                    for k in pairs(RECOMMENDED_PATHS) do
                        local req = state.pathClassReq[k]
                        if not req or req == myClass then avail[k] = true end
                    end
                    -- Tinkering is GNOME-only: only offer it if the character can actually train it.
                    -- SkillCap is illusion-proof (0 for non-Gnomes, >0 for Gnomes even untrained), unlike
                    -- Me.Race which follows the active illusion.
                    if avail['Tinkering'] and (mq.TLO.Me.SkillCap('Tinkering')() or 0) <= 0 then
                        avail['Tinkering'] = nil
                    end
                    avail['Fishing'] = true   -- not a recipe path; special-cased below
                    avail['Alcohol Tolerance'] = true   -- ditto: no recipes, you just drink
                    avail['Welcome'] = true   -- the guide page (not a recipe path either)
                    -- Curated leveling order: it's a DEPENDENCY order, not just a grouping - skills that
                    -- feed others come first (e.g. Pottery needs Jewelcrafting + Brewing; Baking needs
                    -- Tailoring), so prerequisites are leveled before the skills that consume them. The
                    -- main group all caps at 300 (so auto-default = first main skill < 300); specialized
                    -- skills (incl. Fishing, which caps at 200) sit below a divider. '---' = separator,
                    -- 'Welcome' = the guide page.
                    local recOrder = {
                        'Welcome',
                        '---',
                        -- Fletching sits AFTER Blacksmithing: its mithril parts (arrow heads, bundled
                        -- shafts) and its tools (Mithril Working Knife, File) are all Blacksmithing
                        -- combines, so the smithing skill wants to come first.
                        'Jewelcrafting', 'Brewing', 'Tailoring', 'Blacksmithing', 'Fletching', 'Baking', 'Pottery',
                        '---',
                        'Fishing', 'Alcohol Tolerance', 'Research', 'Make Poison', 'Alchemy', 'Tinkering',
                    }

                    if ImGui.BeginCombo('Skill Path##ts_rec_path', state.recPathSelected ~= '' and state.recPathSelected or 'Select skill') then
                        for _, name in ipairs(recOrder) do
                            if name == '---' then
                                ImGui.Separator()
                            elseif avail[name] then
                                -- Capped skills show green with a ✓ - "woo, done!". Read the live skill
                                -- from the path's EQ skill. Fishing caps at 200; everything else at 300.
                                -- Also show the live skill value in the label, e.g. "Baking (247)".
                                local capped, val = false, nil
                                if name ~= 'Welcome' then
                                    -- EQ skill name = explicit Skill= override if the section has one
                                    -- (e.g. Runic Tablets -> Research), otherwise the path name itself
                                    -- (Baking, Tailoring, ... have no Skill= line and match 1:1). This
                                    -- was the bug: sec.Skill was nil for almost every skill, so nothing
                                    -- resolved and no check/number showed.
                                    local sec = (state.iniSections or {})['Skill:' .. name]
                                    local eqName = (name == 'Fishing') and 'Fishing'
                                        or (sec and sec.Skill) or name
                                    val = skill_value(eqName) or 0
                                    -- "Maxed" = you hit YOUR cap, even if it's under 300 (e.g. a Paladin's
                                    -- Research). Use the real SkillCap; fall back to 200 (Fishing) / 300.
                                    local lowCap = (name == 'Fishing' or name == 'Alcohol Tolerance')
                                    local cap = (name == 'Fishing') and 200 or (mq.TLO.Me.SkillCap(eqName)() or 0)
                                    if cap <= 0 then cap = lowCap and 200 or 300 end
                                    capped = val >= cap
                                end
                                local label = name
                                if val then label = label .. string.format('  (%d)', val) end
                                if capped then ImGui.PushStyleColor(ImGuiCol.Text, 0.35, 0.85, 0.45, 1.0) end
                                if ImGui.Selectable(label .. '##rp_' .. name, state.recPathSelected == name) then
                                    if state.recPathSelected ~= name then
                                        state.recPathSelected = name
                                        state.activeTab = 'Level'
                                        state.pendingTabSelect = true
                                        if name == 'Fishing' or name == 'Alcohol Tolerance' then
                                            state.levelPlan = {}       -- neither is a recipe plan
                                            state.levelStatusMsg = ''
                                            state.levelArmedSig = nil
                                        elseif name == 'Welcome' then
                                            state.levelPlan = {}       -- guide page, no plan
                                            state.levelStatusMsg = ''
                                            state.levelArmedSig = nil
                                        else
                                            level_load_recommended(name)
                                        end
                                    end
                                end
                                if capped then ImGui.PopStyleColor() end
                            end
                        end
                        ImGui.EndCombo()
                    end

                    if state.levelStatusMsg ~= '' then
                        ImGui.TextDisabled(state.levelStatusMsg)
                    end

                    -- Fishing isn't a recipe path - it runs the PoK fishing loop (skill -> 200).
                    -- Render its own control and skip the recipe-plan disposal/Start UI below.
                    if state.recPathSelected == 'Fishing' then
                        ImGui.Separator()
                        -- Current Fishing skill - green once it hits the 200 cap (Fishing maxes at 200, not 300).
                        local fishLvl = skill_value('Fishing') or 0
                        if fishLvl >= 200 then
                            ImGui.TextColored(0.35, 0.85, 0.35, 1.0, string.format('Fishing: %d  (max)', fishLvl))
                        else
                            ImGui.TextColored(0.8, 0.8, 0.3, 1.0, string.format('Fishing: %d  / 200', fishLvl))
                        end
                        ImGui.Spacing()
                        ImGui.TextWrapped('Fishing levels by fishing in PoK to skill 200: buys a pole + bait from Daeld Atand, equips the pole, navs to the spot, faces the water, and fishes. (Trophy fishing for specific fish lives on the Craft tab.)')
                        ImGui.Spacing()
                        if themed_button('Start Fishing##ts_level_fish', UI.green, UI.btn_w, UI.btn_h, state.busy) then
                            state.pendingJob = { action = 'fish', spot = 'pok' }
                        end
                        ImGui.SameLine()
                        if themed_button('Stop##ts_level_fish_stop', UI.red, 90, UI.btn_h, not state.busy) then
                            state.pendingJob = nil
                            run_stop('UI Stop button')
                        end
                        return   -- EndTabItem is outside this pcall, so returning here is safe
                    end

                    -- Alcohol Tolerance isn't a recipe path either - you just buy booze and drink it.
                    -- Same shape as Fishing: its own control, then skip the recipe-plan UI below.
                    if state.recPathSelected == 'Alcohol Tolerance' then
                        ImGui.Separator()
                        local atLvl = skill_value('Alcohol Tolerance') or 0
                        local atCap = mq.TLO.Me.SkillCap('Alcohol Tolerance')() or 0
                        if atCap <= 0 then atCap = 200 end
                        local drunk = mq.TLO.Me.Drunk() or 0
                        if atLvl >= atCap then
                            ImGui.TextColored(0.35, 0.85, 0.35, 1.0, string.format('Alcohol Tolerance: %d  (max)', atLvl))
                        else
                            ImGui.TextColored(0.8, 0.8, 0.3, 1.0, string.format('Alcohol Tolerance: %d  / %d', atLvl, atCap))
                        end
                        ImGui.TextDisabled(string.format('Drunk: %d', drunk))
                        ImGui.Spacing()
                        ImGui.TextWrapped('Buys a stack of Ale (falls back to other alcohols the merchant list knows) and drinks it until the skill caps. Stops drinking above 150 drunk and waits it off, then resumes.')
                        ImGui.Spacing()
                        if themed_button('Get Smashed!##ts_level_booze', UI.green, 140, UI.btn_h, state.busy) then
                            state.pendingJob = { action = 'booze' }
                        end
                        ImGui.SameLine()
                        if themed_button('Stop##ts_level_booze_stop', UI.red, 90, UI.btn_h, not state.busy) then
                            state.pendingJob = nil
                            run_stop('UI Stop button')
                        end
                        return   -- EndTabItem is outside this pcall, so returning here is safe
                    end

                    -- Welcome / guide page: teaches the flow and front-loads the summon prep. It's a real
                    -- dropdown entry so it's never hidden; the "Don't default" checkbox (saved per character)
                    -- controls whether we land here or jump straight to the first skill on load.
                    if state.recPathSelected == 'Welcome' then
                        ImGui.Separator()
                                                ImGui.TextColored(0.85, 0.75, 1.0, 1.0, 'Welcome to Lazcraft!')

                        -- Welcome / onboarding intro.
                        ImGui.Spacing()
                        ImGui.TextWrapped("Lazcraft runs on the character doing the combines. Designed to level you to 300 on each tradeskill. If you're in a group, it can connect to group members to request items via TradeskillListener.lua with your group boxes in Marr's. To get started, you can click the tab and select your tradeskill.")
                        ImGui.Spacing()
                        ImGui.TextWrapped('One thing to know: a path will consume all stocked resources fully. But leveling paths are completely configurable, so you can choose your own adventure.')
                        ImGui.Spacing()
                        ImGui.TextDisabled("I've designed this so that you do tradeskills that require another one first.")
                        ImGui.Separator()

                        -- One-tap: level every general tradeskill in dependency order, hands-free.
                        ImGui.TextColored(0.55, 0.90, 0.60, 1.0, 'Level Everything!')
                        ImGui.TextWrapped('Runs Jewelcrafting -> Brewing -> Tailoring -> Blacksmithing -> Fletching -> Baking -> Pottery in order, each until it hits 300 or runs out of mats. Stops after Pottery.')
                        ImGui.Spacing()
                        -- Parity with the per-skill dropdowns: same toggle, so arming it here arms the whole
                        -- chain (dropped-mat skills ask the group instead of looking empty and getting skipped).
                        state.levelSupplyFromGroup = ImGui.Checkbox('Supply from group members##ts_welcome_supply', state.levelSupplyFromGroup)
                        state.crossZoneSupply = ImGui.Checkbox('Cross-zone supply (Marr<->PoK)##ts_welcome_crosszone', state.crossZoneSupply)
                        if state.levelAllRunning then
                            ImGui.TextColored(0.55, 0.90, 0.60, 1.0, string.format('Running: %s (%d/%d)',
                                state.LEVEL_ALL_ORDER[state.levelAllIndex] or '?', state.levelAllIndex or 0, #state.LEVEL_ALL_ORDER))
                            if themed_button('Stop all##ts_levelall_stop', UI.red, 160, UI.btn_h, false) then
                                run_stop('Stop all tradeskills')
                            end
                        else
                            if themed_button('Start all tradeskills##ts_levelall_start', UI.green, 220, UI.btn_h, state.busy) then
                                state.level_all_start()
                            end
                        end
                        ImGui.Separator()

                        -- Pre-summon prep for Pottery, scaled by how many characters you're leveling.
                        ImGui.TextColored(0.95, 0.85, 0.4, 1.0, 'Pre-summon for Pottery (saves you a wait later)')
                        ImGui.TextWrapped("Pottery needs caster-summoned gems. The crafter requests the gems from your peer network, buys any outstanding ones itself, and hands them off to the casters that can make them. Keep your gem casters on the network in Marr's - Lazcraft handles the rest once you reach Pottery, and you can also queue these under Summon.")
                        ImGui.Spacing()
                        ImGui.Text('Characters to level:')
                        ImGui.SameLine()
                        ImGui.SetNextItemWidth(60)
                        if ImGui.BeginCombo('##ts_summon_count', tostring(state.summonCharCount or 1)) then
                            for n = 1, 6 do
                                if ImGui.Selectable(tostring(n) .. '##scc' .. n, (state.summonCharCount or 1) == n) then
                                    state.summonCharCount = n
                                    state.save_settings()
                                end
                            end
                            ImGui.EndCombo()
                        end
                        local cc = state.summonCharCount or 1

                        ImGui.Spacing()
                        ImGui.TextColored(0.7, 0.8, 1.0, 1.0, 'Enchanter:')
                        ImGui.SameLine()
                        ImGui.Text(string.format('%d Vial of Clear Mana', 1350 * cc))
                        ImGui.SameLine()
                        if themed_button('Start Summon##ts_summon_ench', UI.blue, 120, UI.btn_h, state.busy) then
                            state.pendingJob = { action = 'summon', items = { { item = 'Vial of Clear Mana', qty = 1350 * cc } } }
                        end

                        ImGui.TextColored(0.7, 0.9, 0.8, 1.0, 'Cleric:')
                        ImGui.Indent(16)
                        ImGui.Text(string.format('%d Imbued Amber', 500 * cc))
                        ImGui.Text(string.format('%d Imbued Rose Quartz', 250 * cc))
                        ImGui.Text(string.format('%d Imbued Emerald', 600 * cc))
                        ImGui.Unindent(16)
                        if themed_button('Start Summon All##ts_summon_cler', UI.blue, 150, UI.btn_h, state.busy) then
                            state.pendingJob = { action = 'summon', items = {
                                { item = 'Imbued Amber',       qty = 500 * cc },
                                { item = 'Imbued Rose Quartz', qty = 250 * cc },
                                { item = 'Imbued Emerald',     qty = 600 * cc },
                            } }
                        end
                        ImGui.TextDisabled('All three are vendor-bought gems (Star Rose Quartz for the last) - the cheapest, fully plat-only route. Estimates; you may need more.')

                        ImGui.Separator()
                        local dd = state.welcomeDontDefault and true or false
                        local newdd = ImGui.Checkbox('Don\'t open to this page (jump to the first skill under 300 instead)##ts_welcome_dd', dd)
                        if newdd ~= dd then state.welcomeDontDefault = newdd; state.save_settings() end
                        return   -- guide page only; skip the recipe-plan UI below
                    end

                    ImGui.Separator()

                    -- Batch size. Flags must be 8 (CharsNoBlank), matching the Craft tab's Quantity
                    -- field. It was 5 (CharsDecimal|CharsUppercase) - CharsUppercase is nonsense on a
                    -- number field, and the field never took keyboard focus: keys fell through to the
                    -- game (backspace opened the map) instead of reaching ImGui.
                    state.levelBatchBuf = ImGui.InputText('Per Run##ts_level_batch', state.levelBatchBuf, 8)

                    -- Supply from group: when a dropped mat runs out mid-level, auto-refill from the
                    -- group (one Marr's trip) and keep going, instead of stopping.
                    do
                        local _prev = state.levelSupplyFromGroup
                        state.levelSupplyFromGroup = ImGui.Checkbox('Supply from group members##ts_level_supply', state.levelSupplyFromGroup)
                        if state.levelSupplyFromGroup ~= _prev and state.save_settings then state.save_settings() end
                    end
                    ImGui.SameLine()
                    ImGui.TextDisabled('(checks the group for every needed item on Start; members must be in your zone)')
                    if state.levelSupplyFromGroup then
                        -- Unhide the refill-size choice only when supply is on. Default: only what's needed.
                        ImGui.Indent(24)
                        if ImGui.RadioButton('Only what I need##ts_level_supply_needed', state.levelSupplyMode ~= 'all') then
                            state.levelSupplyMode = 'needed'
                        end
                        ImGui.SameLine()
                        if ImGui.RadioButton('Trade all mats##ts_level_supply_all', state.levelSupplyMode == 'all') then
                            state.levelSupplyMode = 'all'
                        end
                        ImGui.SameLine()
                        ImGui.TextDisabled(state.levelSupplyMode == 'all'
                            and '(one big pull - fewer Marr trips, more bag use)'
                            or  '(exact batch each time - less bag use, more trips)')
                        ImGui.Unindent(24)
                    end

                    -- Disposal. Skills whose products can't be vendored (e.g. Pottery) are
                    -- locked to Destroy; skills with per-recipe disposal (e.g. Alchemy) show a
                    -- note instead of the radio. Everything else gets the Sell/Destroy/Keep radio.
                    ImGui.Spacing()
                    local levelSkill = (#state.levelPlan > 0 and state.levelPlan[1].skillName) or state.recPathSelected or ''
                    -- Auto-default to KEEP when arriving at a keep-default skill (e.g. Tinkering - sellable,
                    -- but Keep is the sensible default). Once, on the switch, so the user can still change it.
                    if state.keepDefaultSkills[levelSkill] and state._lvDispLastSkill ~= levelSkill then
                        state.levelDisposal = DISPOSAL.KEEP
                    end
                    state._lvDispLastSkill = levelSkill
                    if state.unsellableSkills[levelSkill] then
                        -- Truly can't sell (Pottery): Keep/Destroy only, default Keep.
                        if state.levelDisposal == DISPOSAL.SELL then state.levelDisposal = DISPOSAL.KEEP end
                        ImGui.Text('Finished items:')
                        ImGui.SameLine()
                        if ImGui.RadioButton('Destroy##lv_destroy_uns', state.levelDisposal == DISPOSAL.DESTROY) then
                            state.levelDisposal = DISPOSAL.DESTROY
                        end
                        ImGui.SameLine()
                        if ImGui.RadioButton('Keep##lv_keep_uns', state.levelDisposal == DISPOSAL.KEEP) then
                            state.levelDisposal = DISPOSAL.KEEP
                        end
                        ImGui.SameLine()
                        ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "(can't be sold)")
                    elseif state.fixedDisposalSkills[levelSkill] then
                        ImGui.Text('Finished items:')
                        ImGui.SameLine()
                        ImGui.TextColored(0.55, 0.75, 0.95, 1.0, 'set per recipe (kept/destroyed as marked below)')
                    else
                        ImGui.Text('Finished items:')
                        ImGui.SameLine()
                        if ImGui.RadioButton('Sell##lv_sell', state.levelDisposal == DISPOSAL.SELL) then
                            state.levelDisposal = DISPOSAL.SELL
                        end
                        ImGui.SameLine()
                        if ImGui.RadioButton('Destroy##lv_destroy', state.levelDisposal == DISPOSAL.DESTROY) then
                            state.levelDisposal = DISPOSAL.DESTROY
                        end
                        ImGui.SameLine()
                        if ImGui.RadioButton('Keep##lv_keep', state.levelDisposal == DISPOSAL.KEEP) then
                            state.levelDisposal = DISPOSAL.KEEP
                        end
                    end
                    -- Persist the Level disposal choice per character when it changes.
                    if state.levelDisposal ~= state._savedLevelDisposal then
                        state._savedLevelDisposal = state.levelDisposal
                        if state.save_settings and not state._loadingSettings then state.save_settings() end
                    end

                    -- Start / Stop / Clear
                    ImGui.Spacing()
                    -- Two-press Start: first press runs the preflight (shows craft vs skip in the
                    -- MQ window) and arms; an unchanged second press confirms and runs. The arm is
                    -- keyed to a signature of skill + the ordered plan, so any change re-previews
                    -- rather than firing on a stale confirm.
                    local levelArmed = state.levelArmedSig ~= nil
                    if themed_button((levelArmed and 'Confirm Start' or 'Start') .. '##ts_level_start',
                                     levelArmed and UI.amber or UI.green, UI.btn_w, UI.btn_h,
                                     state.busy or #state.levelPlan == 0) then
                        local fs = (state.iniSections or {})['Skill:' .. (state.levelPlan[1] and state.levelPlan[1].skillName or '')]
                        local sk = fs and fs.Skill and skill_value(fs.Skill) or 0
                        local sig = tostring(sk)
                        for _, e in ipairs(state.levelPlan) do sig = sig .. '|' .. e.itemName end
                        if state.levelArmedSig == sig then
                            state.levelArmedSig = nil
                            state.sessionStarted = false
                            -- Snapshot which rungs are being skipped (can't craft now) so they
                            -- stay red during the run without recomputing every frame.
                            state.levelSkipSet = {}
                            for _, e in ipairs(state.levelPlan) do
                                if e.trivial > sk and not state.canCraftNow(get_recipe(e.itemName)) then
                                    state.levelSkipSet[e.itemName] = true
                                end
                            end
                            -- Apply disposal: unsellable-skill rungs (Tinkering/Pottery) take the user's
                            -- Keep/Destroy choice (levelDisposal, defaults Keep) - no longer force-Destroy;
                            -- fixed-disposal skills keep the per-rung value from the path; everything else
                            -- takes the global radio.
                            for _, e in ipairs(state.levelPlan) do
                                if state.fixedDisposalSkills[e.skillName] then
                                    -- keep per-rung path value
                                else
                                    e.disposal = state.levelDisposal
                                end
                            end
                            level_plan_start()
                        else
                            -- First press: drop already-trivial rungs for good (they can't gain
                            -- skill), then preview + arm on what remains. Signature is rebuilt from
                            -- the pruned plan so the confirm press matches.
                            state.levelSkipSet = nil
                            for i = #state.levelPlan, 1, -1 do
                                if sk >= state.levelPlan[i].trivial then table.remove(state.levelPlan, i) end
                            end
                            if #state.levelPlan == 0 then
                                state.levelArmedSig = nil
                                state.levelStatusMsg = 'All rungs already trivial - nothing to level on this path.'
                                printf_log('Leveling: every rung is already trivial at skill %d - nothing to do.', sk)
                            else
                                local sig2 = tostring(sk)
                                for _, e in ipairs(state.levelPlan) do sig2 = sig2 .. '|' .. e.itemName end
                                local readyCount, skipCount = state.levelPreflight()
                                -- With "Supply from group" on, we can arm even when nothing's ready
                                -- on hand - the run will request the missing dropped mats from the
                                -- group. Without it, we still require at least one ready recipe.
                                local canArm = readyCount > 0 or state.levelSupplyFromGroup
                                state.levelArmedSig = canArm and sig2 or nil
                                if readyCount > 0 then
                                    state.levelStatusMsg = string.format('Preflight: %d ready, %d will skip - press Confirm Start.', readyCount, skipCount)
                                elseif state.levelSupplyFromGroup then
                                    state.levelStatusMsg = string.format('Preflight: 0 ready on hand, %d will be requested from the group - press Confirm Start.', skipCount)
                                else
                                    state.levelStatusMsg = 'No recipes ready - supply mats (see chat), then Start.'
                                end
                            end
                        end
                    end
                    ImGui.SameLine()
                    if themed_button('Stop##ts_level_stop', UI.red, UI.btn_w, UI.btn_h, not state.busy) then
                        state.levelRunning = false
                        state.levelSkipSet = nil
                        run_stop('UI Stop button (Level)')
                    end
                    ImGui.SameLine()
                    -- Refresh: re-read the recipe data from disk and reload the current skill's
                    -- path (picks up a re-scraped tradeskills.ini). Disabled during a run.
                    if themed_button('Refresh##ts_level_refresh', UI.steel, UI.btn_w, UI.btn_h,
                                     state.busy or state.recPathSelected == '' or state.recPathSelected == 'Welcome') then
                        state.levelArmedSig = nil
                        state.levelSkipSet = nil
                        load_config()
                        level_load_recommended(state.recPathSelected)
                    end

                    -- Quick inventory cleanup: sell every ingredient / every product
                    -- across the whole plan in one vendor trip.
                    ImGui.Spacing()
                    if themed_button('Sell Ingredients##ts_level_sell_ing', UI.steel, 140, UI.btn_h, state.busy or #state.levelPlan == 0) then
                        run_level_sell_ingredients()
                    end
                    ImGui.SameLine()
                    if themed_button('Sell Products##ts_level_sell_prod', UI.steel, 140, UI.btn_h, state.busy or #state.levelPlan == 0) then
                        run_level_sell_products()
                    end


                    -- Add recipe (right under controls)
                    if not state.busy then
                        ImGui.Spacing()
                        -- Get skill items from the level plan's skill, not the craft tab
                        local levelSkillName = #state.levelPlan > 0 and state.levelPlan[1].skillName or current_skill_name()
                        local levelSkillSec = levelSkillName and (state.iniSections or {})['Skill:' .. levelSkillName]
                        local levelItems = levelSkillSec and split_commas(levelSkillSec.Items) or current_skill_items()

                        -- Get current skill for filtering
                        local filterSkill = 0
                        if levelSkillSec and levelSkillSec.Skill then
                            filterSkill = skill_value(levelSkillSec.Skill) or 0
                        end
                        local filteredItems = {}
                        for _, name in ipairs(levelItems) do
                            local rec = get_recipe(name)
                            if rec and (not rec.trivial or rec.trivial > filterSkill) then
                                filteredItems[#filteredItems+1] = name
                            end
                        end
                        local addLabel = state.levelRecipeSelected ~= '' and state.levelRecipeSelected or 'Add recipe...'
                        if ImGui.BeginCombo('##lv_add_combo', addLabel) then
                            for _, name in ipairs(filteredItems) do
                                local rec = get_recipe(name)
                                local trivStr = rec and rec.trivial and string.format(' (%d)', rec.trivial) or ''
                                if ImGui.Selectable(name .. trivStr .. '##lv_add_' .. name, state.levelRecipeSelected == name) then
                                    state.levelRecipeSelected = name
                                end
                            end
                            ImGui.EndCombo()
                        end
                        ImGui.SameLine()
                        if themed_button('+ Add##lv_add', UI.blue, 60, UI.btn_h, state.levelRecipeSelected == '') then
                            local rec = get_recipe(state.levelRecipeSelected)
                            if rec then
                                local exists = false
                                for _, e in ipairs(state.levelPlan) do
                                    if e.itemName == state.levelRecipeSelected then exists = true; break end
                                end
                                if not exists then
                                    state.levelPlan[#state.levelPlan+1] = {
                                        skillName = levelSkillName or current_skill_name() or 'Custom',
                                        itemName  = state.levelRecipeSelected,
                                        trivial   = rec.trivial or 0,
                                        disposal  = state.levelDisposal,
                                    }
                                    table.sort(state.levelPlan, function(a,b) return a.trivial < b.trivial end)
                                    local pathKey = (state.recPathSelected and state.recPathSelected ~= '') and state.recPathSelected
                                                    or (levelSkillName or current_skill_name() or 'Custom')
                                    state.remember_path_add(pathKey, state.levelRecipeSelected)   -- persist per character
                                    state.levelStatusMsg = 'Added: ' .. state.levelRecipeSelected
                                    state.levelRecipeSelected = ''
                                end
                            end
                        end

                        -- Type-in add with autocomplete: enter ANY recipe name, validated to this
                        -- path's skill via the recipe's container. As you type 2+ letters, matching
                        -- recipe names list below - click one to add it, or type the full name + Add.
                        local function try_add_typed(typed)
                            typed = trim(typed or '')
                            local pathSkill = levelSkillName or current_skill_name()
                            if typed == '' then
                                state.levelStatusMsg = 'Type a recipe name first.'; return
                            end
                            local rec = get_recipe(typed)
                            if not rec then
                                state.levelStatusMsg = string.format('No recipe named "%s" in the database.', typed); return
                            end
                            local recSkill = state.skill_name_for_recipe(typed)
                            if not recSkill then
                                state.levelStatusMsg = string.format('Could not resolve the skill for "%s" - not added.', typed); return
                            elseif pathSkill and recSkill ~= pathSkill then
                                state.levelStatusMsg = string.format('"%s" is a %s recipe, not %s - not added.', typed, recSkill, pathSkill); return
                            end
                            for _, e in ipairs(state.levelPlan) do
                                if e.itemName == typed then
                                    state.levelStatusMsg = string.format('"%s" is already in the plan.', typed); return
                                end
                            end
                            state.levelPlan[#state.levelPlan+1] = {
                                skillName = pathSkill or 'Custom', itemName = typed,
                                trivial = rec.trivial or 0, disposal = state.levelDisposal,
                            }
                            table.sort(state.levelPlan, function(a,b) return a.trivial < b.trivial end)
                            local pathKey = (state.recPathSelected and state.recPathSelected ~= '') and state.recPathSelected or (pathSkill or 'Custom')
                            state.remember_path_add(pathKey, typed)
                            state.levelStatusMsg = 'Added: ' .. typed
                            state.levelTypeBuf = ''
                            state.levelSugQuery = nil   -- reset the autocomplete cache
                        end

                        state.levelTypeBuf = ImGui.InputText('##lv_type', state.levelTypeBuf or '', 64)
                        ImGui.SameLine()
                        if themed_button('Add typed##lv_type_add', UI.blue, 90, UI.btn_h, false) then
                            try_add_typed(state.levelTypeBuf)
                        end
                        ImGui.SameLine()
                        ImGui.TextDisabled('type 2+ letters for matches')

                        -- Autocomplete: recipe names containing what you typed, limited to THIS skill so
                        -- only addable recipes show. Recomputed only when the text or skill changes
                        -- (cached in state.levelSug), capped at 12. Click one to add it.
                        local q = trim(state.levelTypeBuf or ''):lower()
                        local sugSkill = levelSkillName or current_skill_name()
                        if #q >= 2 then
                            if q ~= state.levelSugQuery or sugSkill ~= state.levelSugSkill then
                                state.levelSugQuery = q
                                state.levelSugSkill = sugSkill
                                state.levelSug = {}
                                state.allRecipeNames = state.allRecipeNames or state.build_recipe_names()
                                for _, rn in ipairs(state.allRecipeNames) do
                                    if rn:lower():find(q, 1, true) and state.skill_name_for_recipe(rn) == sugSkill then
                                        state.levelSug[#state.levelSug + 1] = rn
                                        if #state.levelSug >= 12 then break end
                                    end
                                end
                            end
                            for _, rn in ipairs(state.levelSug or {}) do
                                if ImGui.Selectable(rn .. '##lv_sug_' .. rn) then try_add_typed(rn) end
                            end
                        else
                            state.levelSugQuery = nil
                        end
                    end

                    -- Running status
                    if state.busy and state.levelRunning then
                        local entry = state.levelPlan[state.levelCurrentIndex]
                        if entry then
                            local firstSec = (state.iniSections or {})['Skill:' .. (entry.skillName or '')]
                            local eqSkill = firstSec and firstSec.Skill
                            local curLvl2 = eqSkill and skill_value(eqSkill) or 0
                            ImGui.TextColored(0.3, 0.9, 0.4, 1.0, string.format(
                                'Crafting: %s  |  Skill: %d  |  %d/%d',
                                entry.itemName, curLvl2, state.doneCount, state.totalCount))
                        end
                    end

                    ImGui.Separator()

                    -- Plan list
                    local curLvl = 0
                    local eqSkillDisplayName = nil
                    if #state.levelPlan > 0 then
                        local firstSec = (state.iniSections or {})['Skill:' .. (state.levelPlan[1].skillName or '')]
                        local eqSkill = firstSec and firstSec.Skill
                        eqSkillDisplayName = eqSkill
                        curLvl = eqSkill and skill_value(eqSkill) or 0
                    end

                    if #state.levelPlan == 0 then
                        ImGui.Spacing()
                        ImGui.TextDisabled('Select a skill path above or add recipes manually.')
                    else
                        if eqSkillDisplayName then
                            -- Green when maxed for YOU - your real cap, even if under 300 (e.g. a Paladin's
                            -- Research). Fishing caps at 200; fall back to 300 if the TLO is unavailable.
                            local cap = (eqSkillDisplayName == 'Fishing') and 200 or (mq.TLO.Me.SkillCap(eqSkillDisplayName)() or 0)
                            if cap <= 0 then cap = (eqSkillDisplayName == 'Fishing') and 200 or HARD_SKILL_CAP end
                            if curLvl >= cap then
                                ImGui.TextColored(0.35, 0.85, 0.35, 1.0, string.format('%s: %d  (max)', eqSkillDisplayName, curLvl))
                            else
                                ImGui.TextColored(0.8, 0.8, 0.3, 1.0, string.format('%s: %d', eqSkillDisplayName, curLvl))
                            end
                        else
                            ImGui.Text(string.format('Skill: %d', curLvl))
                        end
                        ImGui.TextDisabled('X = remove a rung from the plan.')
                        ImGui.Spacing()
                        for i, entry in ipairs(state.levelPlan) do
                            local rec = get_recipe(entry.itemName)
                            local isActive = state.levelRunning and i == state.levelCurrentIndex
                            local isDone = curLvl >= entry.trivial
                            local trivStr = entry.trivial > 0 and string.format('Trivial (%d)', entry.trivial) or ''
                            -- After the first Start press (armed, not yet running) preview each rung:
                            -- green = ready (all non-vendor reagents on hand), red = will skip. The
                            -- limiting reagents are listed underneath, each green (have) or red (missing).
                            local armedPreview = (state.levelArmedSig ~= nil) and not state.levelRunning and not isDone
                            -- During the run, rungs snapshotted as un-craftable at confirm stay red
                            -- so the user can see they're being skipped (not recomputed live).
                            local inSkip = state.levelRunning and state.levelSkipSet and state.levelSkipSet[entry.itemName]
                                           and not isActive and not isDone
                            local lim = armedPreview and state.limitingMats(rec) or nil
                            local rowReady = false
                            if armedPreview then
                                rowReady = dropped_combines_available(rec) >= 1
                                for _, m in ipairs(lim) do if not m.ok then rowReady = false end end
                            end
                            -- When "Supply from group" is on, a short recipe isn't skipped - it'll be
                            -- requested. Show it yellow ("will request") instead of red ("skipped").
                            local willReq = state.levelSupplyFromGroup

                            -- Remove control: compact NEUTRAL X on the left - removing a recipe from
                            -- the plan isn't destructive, so it's steel (red is reserved for Destroy All).
                            -- Disabled mid-run so the running plan can't be edited out from under itself.
                            if themed_button('X##lv_rm_' .. i, UI.steel, 26, UI.btn_h, state.busy) then
                                local removedName = state.levelPlan[i] and state.levelPlan[i].itemName
                                local pathKey = (state.recPathSelected and state.recPathSelected ~= '') and state.recPathSelected
                                                or (state.levelPlan[i] and state.levelPlan[i].skillName)
                                level_plan_remove(i)
                                if removedName then state.forget_path_add(pathKey, removedName) end
                            end
                            ImGui.SameLine()

                            if isActive then
                                ImGui.TextColored(0.3, 0.9, 0.4, 1.0, '▶')
                            elseif isDone then
                                ImGui.TextColored(0.5, 0.5, 0.5, 1.0, '✓')
                            elseif inSkip then
                                if willReq then ImGui.TextColored(0.95, 0.80, 0.30, 1.0, '⟳')
                                else ImGui.TextColored(0.95, 0.35, 0.35, 1.0, '✗') end
                            elseif armedPreview then
                                if rowReady then ImGui.TextColored(0.3, 0.9, 0.4, 1.0, '●')
                                elseif willReq then ImGui.TextColored(0.95, 0.80, 0.30, 1.0, '⟳')
                                else ImGui.TextColored(0.95, 0.35, 0.35, 1.0, '✗') end
                            else
                                ImGui.TextColored(0.7, 0.7, 0.7, 1.0, '○')
                            end
                            ImGui.SameLine()

                            if isDone then
                                ImGui.TextColored(0.5, 0.5, 0.5, 1.0, entry.itemName)
                                ImGui.SameLine()
                                ImGui.TextColored(0.4, 0.4, 0.4, 1.0, trivStr)
                            elseif isActive then
                                ImGui.TextColored(0.3, 0.9, 0.4, 1.0, entry.itemName)
                                ImGui.SameLine()
                                ImGui.TextColored(0.2, 0.7, 0.3, 1.0, trivStr)
                            elseif inSkip then
                                if willReq then
                                    ImGui.TextColored(0.95, 0.80, 0.30, 1.0, entry.itemName)
                                    ImGui.SameLine()
                                    ImGui.TextColored(0.75, 0.62, 0.32, 1.0, trivStr)
                                    ImGui.SameLine()
                                    ImGui.TextColored(0.85, 0.72, 0.35, 1.0, '(will request from group)')
                                else
                                    ImGui.TextColored(0.95, 0.35, 0.35, 1.0, entry.itemName)
                                    ImGui.SameLine()
                                    ImGui.TextColored(0.7, 0.4, 0.4, 1.0, trivStr)
                                    ImGui.SameLine()
                                    ImGui.TextColored(0.7, 0.4, 0.4, 1.0, '(skipped - missing mats)')
                                end
                            elseif armedPreview then
                                if rowReady then ImGui.TextColored(0.3, 0.9, 0.4, 1.0, entry.itemName)
                                elseif willReq then ImGui.TextColored(0.95, 0.80, 0.30, 1.0, entry.itemName)
                                else ImGui.TextColored(0.95, 0.35, 0.35, 1.0, entry.itemName) end
                                ImGui.SameLine()
                                ImGui.TextDisabled(trivStr)
                                if rowReady then
                                    ImGui.SameLine()
                                    ImGui.TextColored(0.6, 0.8, 0.6, 1.0, string.format('(Count: %d)', state.craftableCount(rec)))
                                elseif willReq then
                                    ImGui.SameLine()
                                    ImGui.TextColored(0.85, 0.72, 0.35, 1.0, '(will request from group)')
                                end
                            else
                                ImGui.Text(entry.itemName)
                                ImGui.SameLine()
                                ImGui.TextDisabled(trivStr)
                            end

                            -- Estimated cost per run (one batch) to the right of the rung. Cached per
                            -- recipe+batch-qty so we don't walk the tree every frame for every row.
                            -- Shown on done rungs too (dimmed) - useful for planning/comparison at cap.
                            if rec then
                                local batchQ = level_batch_qty(rec)
                                local sig = entry.itemName .. '@' .. tostring(batchQ)
                                state._lvCost = state._lvCost or {}
                                local cached = state._lvCost[sig]
                                if cached == nil then
                                    local okc, plan = pcall(function() return plan_requirements(entry.itemName, batchQ) end)
                                    local cp, priced, items = 0, 0, 0
                                    if okc and plan and plan.buyDemand then
                                        for nm, q in pairs(plan.buyDemand) do
                                            if q > 0 then
                                                items = items + 1
                                                local info = (state.itemInfo or {})[nm]
                                                if info and info.price and info.price > 0 then
                                                    cp = cp + info.price * q; priced = priced + 1
                                                end
                                            end
                                        end
                                    end
                                    cached = { cp = cp, priced = priced, items = items }
                                    state._lvCost[sig] = cached
                                end
                                if cached.items > 0 and cached.priced > 0 then
                                    ImGui.SameLine()
                                    local partial = (cached.priced < cached.items) and '+' or ''
                                    local txt = string.format('(Est. cost per run: ~%d%s pp)', math.floor(cached.cp / 1000), partial)
                                    if isDone then ImGui.TextColored(0.45, 0.45, 0.45, 1.0, txt)
                                    else ImGui.TextColored(0.6, 0.7, 0.9, 1.0, txt) end
                                end
                            end

                            -- For per-recipe-disposal skills (e.g. Alchemy), show each rung's fate
                            -- so the mixed keep/destroy is visible at a glance.
                            if state.fixedDisposalSkills[entry.skillName] and not isDone then
                                ImGui.SameLine()
                                if entry.disposal == DISPOSAL.KEEP then
                                    ImGui.TextColored(0.4, 0.8, 0.5, 1.0, '· keep')
                                elseif entry.disposal == DISPOSAL.DESTROY then
                                    ImGui.TextColored(0.85, 0.5, 0.4, 1.0, '· destroy')
                                elseif entry.disposal == DISPOSAL.SELL then
                                    ImGui.TextColored(0.6, 0.7, 0.9, 1.0, '· sell')
                                end
                            end

                            -- (Per-row Sell/Destroy removed - Sell Ingredients / Sell Products at the
                            -- top of the tab cover this, and dropping them declutters the plan.)

                            -- Limiting (non-vendor) reagents, green = have / red = missing.
                            if armedPreview then
                                for _, m in ipairs(lim) do
                                    if m.ok then
                                        ImGui.TextColored(0.3, 0.9, 0.4, 1.0, '      - ' .. m.name)
                                    else
                                        local tag = m.maker
                                            and string.format(' (have %d, %s-made)', m.have, m.maker)
                                            or  string.format(' (have %d)', m.have)
                                        ImGui.TextColored(0.95, 0.35, 0.35, 1.0, '      - ' .. m.name .. tag)
                                    end
                                end
                            end
                        end
                    end

                    end)
                    if not _tok then ImGui.TextColored(0.95, 0.35, 0.35, 1.0, 'tab render error - see log'); printf_log('UI tab render error: %s', tostring(_terr)) end
                    ImGui.EndTabItem()
                end

                -- ── RESEARCH TAB ──────────────────────────────────────────────
                if ImGui.BeginTabItem('Research##ts_tab_research') then
                    local _tok, _terr = pcall(function()
                    state.activeTab = 'Research'
                    ImGui.TextDisabled('Craft 66-70 spells & tomes. Inks & quills auto-buy; pre-load parchments/vellums/manuals for now.')
                    ImGui.Spacing()

                    local classes = state.researchClasses or {}
                    if #classes == 0 then
                        ImGui.TextColored(0.95, 0.55, 0.35, 1.0, 'research.ini not loaded - no research data found.')
                    else
                        if not state.rsClass then
                            -- Default the picker to the CHARACTER'S class, not classes[1]
                            -- (which is alphabetical -> always 'bard', so a warrior would see
                            -- bard spells and think their tomes are missing). Fall back to the
                            -- first class only if this character's class has no research data.
                            local myCls = (mq.TLO.Me.Class.Name() or ''):lower()
                            state.rsClass = (state.researchIndex or {})[myCls] and myCls or classes[1]
                        end
                        state.rsTypeFilter = state.rsTypeFilter or 'both'
                        state.rsLevel      = state.rsLevel or 0
                        state.rsQtyBuf     = state.rsQtyBuf or '1'
                        state.rsQueue      = state.rsQueue or {}

                        -- Class picker
                        if ImGui.BeginCombo('Class##ts_rs_class', state.rsClass) then
                            for i, c in ipairs(classes) do
                                if ImGui.Selectable(c .. '##ts_rs_cls_' .. i, state.rsClass == c) then
                                    state.rsClass = c
                                end
                            end
                            ImGui.EndCombo()
                        end

                        local canTome = char_can_make_tomes()
                        local idx = (state.researchIndex or {})[state.rsClass] or {}

                        -- Which types does this class actually have? Offer a radio only for types that
                        -- exist - no "Spells" option for a spell-less class, no "Tomes" for a tome-less one.
                        local classHasTomes, classHasSpells = false, false
                        for _, names in pairs(idx) do
                            for _, nm in ipairs(names) do
                                if is_research_tome(nm) then classHasTomes = true else classHasSpells = true end
                            end
                            if classHasTomes and classHasSpells then break end
                        end
                        local showTomes  = canTome and classHasTomes   -- character must also be able to make tomes
                        local showSpells = classHasSpells

                        -- Keep the active filter valid for what's actually shown.
                        if state.rsTypeFilter == 'tomes'  and not showTomes  then state.rsTypeFilter = 'spells' end
                        if state.rsTypeFilter == 'spells' and not showSpells then state.rsTypeFilter = showTomes and 'tomes' or 'spells' end
                        if state.rsTypeFilter == 'both'   and not (showSpells and showTomes) then
                            state.rsTypeFilter = showSpells and 'spells' or 'tomes'
                        end

                        ImGui.Text('Type:')
                        ImGui.SameLine()
                        if showSpells and showTomes then
                            if ImGui.RadioButton('Spells##ts_rs_t1', state.rsTypeFilter == 'spells') then state.rsTypeFilter = 'spells' end
                            ImGui.SameLine()
                            if ImGui.RadioButton('Tomes##ts_rs_t2', state.rsTypeFilter == 'tomes') then state.rsTypeFilter = 'tomes' end
                            ImGui.SameLine()
                            if ImGui.RadioButton('Both##ts_rs_t3', state.rsTypeFilter == 'both') then state.rsTypeFilter = 'both' end
                        elseif showSpells then
                            state.rsTypeFilter = 'spells'
                            ImGui.TextDisabled('Spells only')
                            if classHasTomes and not canTome then
                                ImGui.SameLine()
                                ImGui.TextColored(0.9, 0.7, 0.3, 1.0, string.format("  %s can't make tomes.", mq.TLO.Me.Class.ShortName() or '?'))
                            end
                        elseif showTomes then
                            state.rsTypeFilter = 'tomes'
                            ImGui.TextDisabled('Tomes only')
                        else
                            ImGui.TextColored(0.9, 0.7, 0.3, 1.0, string.format('%s has nothing researchable here.', state.rsClass))
                        end

                        -- Level scope
                        local levels = {}
                        for lv in pairs(idx) do levels[#levels + 1] = lv end
                        table.sort(levels)
                        local lvLabel = state.rsLevel == 0 and 'All levels' or ('Level ' .. state.rsLevel)
                        if ImGui.BeginCombo('Scope##ts_rs_level', lvLabel) then
                            if ImGui.Selectable('All levels##ts_rs_lvall', state.rsLevel == 0) then state.rsLevel = 0 end
                            for _, lv in ipairs(levels) do
                                if ImGui.Selectable(string.format('Level %d##ts_rs_lv%d', lv, lv), state.rsLevel == lv) then
                                    state.rsLevel = lv
                                end
                            end
                            ImGui.EndCombo()
                        end

                        -- Build the filtered list { name, level }
                        local function type_ok(nm)
                            local tome = is_research_tome(nm)
                            if state.rsTypeFilter == 'spells' then return not tome end
                            if state.rsTypeFilter == 'tomes' then return tome end
                            return true
                        end
                        local list = {}
                        local function add_level(lv)
                            for _, nm in ipairs(idx[lv] or {}) do
                                if type_ok(nm) then list[#list + 1] = { name = nm, level = lv } end
                            end
                        end
                        if state.rsLevel == 0 then
                            for _, lv in ipairs(levels) do add_level(lv) end
                        else
                            add_level(state.rsLevel)
                        end

                        ImGui.Separator()

                        -- Qty + Craft All. Flags 8 (CharsNoBlank) like every other number field; this
                        -- was 6 (CharsHexadecimal|CharsUppercase), the same typo that made the Level
                        -- tab's Per Run field refuse keyboard focus.
                        state.rsQtyBuf = ImGui.InputText('Qty each##ts_rs_qty', state.rsQtyBuf, 8)
                        local q = math.max(1, math.floor(tonumber(state.rsQtyBuf) or 1))
                        ImGui.SameLine()
                        -- Queue All: drop every filtered spell/tome into the queue (no craft).
                        -- Skips anything already queued so a repeat press doesn't pile on.
                        if themed_button(string.format('Queue All (%d)##ts_rs_queueall', #list), UI.green, 150, UI.btn_h, #list == 0) then
                            for _, e in ipairs(list) do
                                if not (is_research_tome(e.name) and not canTome) then
                                    state.rs_queue_add(e.name, e.level, q, state.rsClass, false)
                                end
                            end
                        end

                        -- Left: the spell/tome list ("+" adds to the queue on the right).
                        -- Right: the persistent craft queue (survives class/level/type changes).
                        if ImGui.BeginTable('##ts_rs_split', 2, 0, 0, 0) then
                            ImGui.TableSetupColumn('list',  ImGuiTableColumnFlags.WidthStretch)
                            ImGui.TableSetupColumn('queue', ImGuiTableColumnFlags.WidthFixed, 360)
                            ImGui.TableNextRow()

                            -- ── LEFT: spell list ──
                            ImGui.TableNextColumn()
                            if #list == 0 then
                                ImGui.TextDisabled('  no matching spells/tomes for this class/level/type')
                            else
                                for i, e in ipairs(list) do
                                    local tome    = is_research_tome(e.name)
                                    local blocked = tome and not canTome
                                    if themed_button('+##ts_rs_one_' .. i, blocked and UI.steel or UI.blue, 26, UI.btn_h, blocked) then
                                        state.rs_queue_add(e.name, e.level, q, state.rsClass, true)
                                    end
                                    ImGui.SameLine()
                                    if tome then
                                        ImGui.TextColored(0.82, 0.70, 1.0, 1.0, string.format('[%d] %s  (tome)', e.level, e.name))
                                    else
                                        ImGui.Text(string.format('[%d] %s', e.level, e.name))
                                    end
                                end
                            end

                            -- ── RIGHT: persistent craft queue ──
                            ImGui.TableNextColumn()
                            local qn = #state.rsQueue
                            ImGui.Text(string.format('Queue (%d)', qn))

                            -- Start / Confirm Start, keyed to a signature of the queue so a
                            -- changed queue re-arms rather than firing on a stale confirm
                            -- (same pattern as the Level tab).
                            local sig = ''
                            for _, e in ipairs(state.rsQueue) do
                                sig = sig .. e.class .. '|' .. e.name .. '|' .. tostring(e.qty) .. ';'
                            end
                            local armed = (state.rsArmedSig ~= nil and state.rsArmedSig == sig)
                            if themed_button((armed and 'Confirm Start' or 'Start') .. '##ts_rs_qstart',
                                             armed and UI.amber or UI.green, 150, UI.btn_h, state.busy or qn == 0) then
                                if armed then
                                    state.rsArmedSig = nil
                                    local items, skipped = {}, 0
                                    for _, e in ipairs(state.rsQueue) do
                                        local key  = e.name .. '##' .. e.class
                                        local have = item_count(e.name)                  -- already in inventory
                                        local need = math.max(0, (e.qty or 1) - have)    -- one copy unless you queued more
                                        if need <= 0 then
                                            skipped = skipped + 1
                                        else
                                            items[#items + 1] = { name = e.name, key = key, qty = need }
                                        end
                                    end
                                    if skipped > 0 then
                                        printf_log('Research: skipping %d spell(s) you already have - queue a higher Qty each to make more.', skipped)
                                    end
                                    if #items > 0 then state.pendingJob = { action = 'research', items = items } end
                                else
                                    state.rsArmedSig = (qn > 0) and sig or nil
                                end
                            end
                            ImGui.SameLine()
                            if themed_button('Clear##ts_rs_qclear', UI.red, 90, UI.btn_h, state.busy or qn == 0) then
                                state.rsQueue = {}
                                state.rsArmedSig = nil
                            end

                            -- Pull in every still-missing spell from the group's checker output.
                            if themed_button('Load missing spells##ts_rs_loadmiss', UI.steel, 240, UI.btn_h, state.busy) then
                                state.rs_load_missing()
                                state.rsArmedSig = nil   -- queue changed; re-arm Start
                            end
                            if state.rsLoadMsg and state.rsLoadMsg ~= '' then
                                ImGui.TextDisabled(state.rsLoadMsg)
                            end

                            -- Browse a folder (e.g. Downloads) for files handed to you by others.
                            if ImGui.CollapsingHeader('Browse for a file##ts_rs_browse_hdr') then
                                if state.rsBrowseDir == nil then
                                    state.rsBrowseDir = (trim(mq.TLO.MacroQuest.Path() or '') ~= '')
                                        and (trim(mq.TLO.MacroQuest.Path()) .. '\\config') or ''
                                end
                                state.rsBrowseDir = ImGui.InputText('Folder##ts_rs_browsedir', state.rsBrowseDir or '', 256)
                                if ImGui.Button('Config##ts_rs_browsecfg') then
                                    state.rsBrowseDir = trim(mq.TLO.MacroQuest.Path() or '') .. '\\config'
                                    state.rsBrowseFiles = nil
                                end
                                ImGui.SameLine()
                                if ImGui.Button('Downloads##ts_rs_browsedl') then
                                    state.rsBrowseDir = state.rs_downloads_dir()
                                    state.rsBrowseFiles = nil
                                end
                                ImGui.SameLine()
                                if ImGui.Button('List##ts_rs_browselist') then
                                    local files, method = state.list_missing_in_dir(state.rsBrowseDir)
                                    state.rsBrowseFiles = files
                                    state.rsBrowseMethod = method
                                end
                                if state.rsBrowseFiles then
                                    if #state.rsBrowseFiles == 0 then
                                        ImGui.TextDisabled((state.rsBrowseMethod == 'none')
                                            and '  couldn\'t list this folder (no lfs/dir on this MQ build)'
                                            or  '  no *_missingspells.ini in that folder')
                                    else
                                        for bi, f in ipairs(state.rsBrowseFiles) do
                                            if themed_button('Load##ts_rs_bload_' .. bi, UI.green, 56, UI.btn_h, state.busy) then
                                                state.rs_load_missing_one(f.path)
                                                state.rsArmedSig = nil
                                            end
                                            ImGui.SameLine()
                                            ImGui.Text(f.char)
                                        end
                                    end
                                end
                            end

                            ImGui.Separator()
                            if qn == 0 then
                                ImGui.TextDisabled('  empty - use + or Queue All')
                            else
                                for i, e in ipairs(state.rsQueue) do
                                    if ImGui.Button('X##ts_rs_qrm_' .. i) then
                                        table.remove(state.rsQueue, i)
                                        state.rsArmedSig = nil
                                    end
                                    ImGui.SameLine()
                                    -- Green when the scroll is already in inventory - Start will skip it (or make
                                    -- only the shortfall vs the queued Qty). Checked live per entry, so it also
                                    -- covers queue spells from a class/level not currently shown on the left.
                                    local have = item_count(e.name) > 0
                                    if have then
                                        ImGui.TextColored(0.45, 0.85, 0.45, 1.0,
                                            string.format('[%d] %s x%d  (%s%s)  - have it', e.level, e.name, e.qty, e.class,
                                                is_research_tome(e.name) and ' tome' or ''))
                                    elseif is_research_tome(e.name) then
                                        ImGui.TextColored(0.82, 0.70, 1.0, 1.0, string.format('[%d] %s x%d  (%s tome)', e.level, e.name, e.qty, e.class))
                                    else
                                        ImGui.Text(string.format('[%d] %s x%d  (%s)', e.level, e.name, e.qty, e.class))
                                    end
                                end
                            end

                            ImGui.EndTable()
                        end
                    end

                    end)
                    if not _tok then ImGui.TextColored(0.95, 0.35, 0.35, 1.0, 'tab render error - see log'); printf_log('UI tab render error: %s', tostring(_terr)) end
                    ImGui.EndTabItem()
                end

                -- ── SUPPLY TAB ───────────────────────────────────────────────
                if ImGui.BeginTabItem('Supply##ts_tab_req') then
                    local _tok, _terr = pcall(function()
                    state.activeTab = 'Request'
                    ImGui.TextDisabled('Ask mules for farmed mats & parchments. Crafter stays put; mules come to it.')
                    ImGui.Spacing()

                    -- ===== Dropped materials =====
                    ImGui.TextColored(0.70, 0.85, 1.0, 1.0, 'Dropped Materials')

                    local bySkill = dropped_by_skill()
                    local skillNames = {}
                    for k in pairs(bySkill) do skillNames[#skillNames + 1] = k end
                    table.sort(skillNames)
                    skillNames[#skillNames + 1] = 'Research'   -- parchments live in this dropdown too
                    if state.reqSkillSelected == '' and #skillNames > 0 then
                        state.reqSkillSelected = skillNames[1]
                    end
                    local skLabel = state.reqSkillSelected ~= '' and state.reqSkillSelected or 'Select skill'
                    if ImGui.BeginCombo('By skill##ts_req_skill', skLabel) then
                        for i, nm in ipairs(skillNames) do
                            if ImGui.Selectable(nm .. '##ts_req_sk_' .. i, state.reqSkillSelected == nm) then
                                state.reqSkillSelected = nm
                            end
                        end
                        ImGui.EndCombo()
                    end
                    if state.reqSkillSelected == 'Research' then
                        -- Research parchments: queued as 'all' (hand over every one the mule holds).
                        for i, nm in ipairs(REQUEST_PARCHMENTS) do
                            if ImGui.Button('+##ts_req_parch_' .. i) then request_queue_add(nm, 'all') end
                            ImGui.SameLine()
                            ImGui.Text(nm)
                        end
                        ImGui.Spacing()
                        state.reqParchManualBuf = ImGui.InputText('##ts_req_parch_manual', state.reqParchManualBuf, 64)
                        ImGui.SameLine()
                        if ImGui.Button('Add##ts_req_parch_manual_add') then
                            request_queue_add(state.reqParchManualBuf, 'all')
                            state.reqParchManualBuf = ''
                        end
                        ImGui.SameLine()
                        ImGui.TextDisabled('parchment name')
                    else
                        local skList = bySkill[state.reqSkillSelected] or {}
                        if #skList == 0 then
                            ImGui.TextDisabled('  (no dropped mats in this path)')
                        else
                            for i, nm in ipairs(skList) do
                                if ImGui.Button('+##ts_req_skadd_' .. i) then request_queue_add(nm, 'stack') end
                                ImGui.SameLine()
                                ImGui.Text(nm)
                                -- User-added items get a remove control so a typo isn't permanent.
                                if state.isUserDrop(state.reqSkillSelected, nm) then
                                    ImGui.SameLine()
                                    if ImGui.Button('x##ts_req_skdel_' .. i) then
                                        state.removeUserDrop(state.reqSkillSelected, nm)
                                    end
                                end
                            end
                        end
                    end

                    ImGui.Spacing()
                    -- Searchable scan of every dropped mat in the ini
                    state.reqSearchBuf = ImGui.InputText('Search all##ts_req_search', state.reqSearchBuf, 64)
                    local term = trim(state.reqSearchBuf):lower()
                    if term ~= '' then
                        local shown = 0
                        for _, nm in ipairs(dropped_all()) do
                            if nm:lower():find(term, 1, true) then
                                shown = shown + 1
                                if shown <= 15 then
                                    if ImGui.Button('+##ts_req_alladd_' .. shown) then request_queue_add(nm, 'stack') end
                                    ImGui.SameLine()
                                    ImGui.Text(nm)
                                end
                            end
                        end
                        if shown == 0 then
                            ImGui.TextDisabled('  no matches')
                        elseif shown > 15 then
                            ImGui.TextDisabled(string.format('  ...%d more - refine search', shown - 15))
                        end
                    end

                    ImGui.Separator()


                    -- ===== Lazarus tradeskill items (server-specific end-game gear mats) =====
                    if ImGui.CollapsingHeader('Lazarus Tradeskill items##ts_req_lazhdr') then
                        ImGui.TextDisabled('High-end gear components. + queues it; set Stack/All and a source below.')
                        local LAZ_ITEMS = {
                            'Gem of Swirling Shadows', 'Sebilisian Seal of Command', 'Powder of Ro',
                            'Corrosive Bile', 'Variegated Silk', 'Variegated Rings', 'Variegated Leather',
                            'Upper Runic Fragment', 'Lower Runic Fragment', 'Center Runic Fragment',
                        }
                        for i, nm in ipairs(LAZ_ITEMS) do
                            if ImGui.Button('+##ts_req_lazadd_' .. i) then request_queue_add(nm, 'stack') end
                            ImGui.SameLine()
                            ImGui.Text(nm)
                        end
                    end  -- Lazarus tradeskill items collapsing header

                    ImGui.Separator()
                    ImGui.Spacing()

                    -- ===== Request queue (shared with the Summon tab) =====
                    state.render_request_queue()

                    -- ===== Add a dropped item to a skill (self-service curation) =====
                    ImGui.Separator()
                    ImGui.TextColored(0.70, 0.85, 1.0, 1.0, 'Add a dropped item to a skill')
                    ImGui.TextDisabled('Always shows in that skill\'s list above; saved across restarts.')
                    state.reqAddItemBuf = ImGui.InputText('Item##ts_req_additem', state.reqAddItemBuf or '', 64)
                    -- Skill picker: the tradeskills only (Research parchments are their own list).
                    local addSkills = {}
                    for k in pairs(dropped_by_skill()) do addSkills[#addSkills + 1] = k end
                    table.sort(addSkills)
                    if not state.reqAddSkill or state.reqAddSkill == '' then state.reqAddSkill = addSkills[1] or '' end
                    local addSkLabel = (state.reqAddSkill ~= '') and state.reqAddSkill or 'Select skill'
                    if ImGui.BeginCombo('Skill##ts_req_addskill', addSkLabel) then
                        for i, nm in ipairs(addSkills) do
                            if ImGui.Selectable(nm .. '##ts_req_addsk_' .. i, state.reqAddSkill == nm) then
                                state.reqAddSkill = nm
                            end
                        end
                        ImGui.EndCombo()
                    end
                    if themed_button('Add to skill##ts_req_addbtn', UI.green, 160, UI.btn_h, trim(state.reqAddItemBuf or '') == '' or state.reqAddSkill == '') then
                        if state.addUserDrop(state.reqAddSkill, state.reqAddItemBuf) then
                            printf_log('Added "%s" to %s dropped-materials list.', trim(state.reqAddItemBuf), state.reqAddSkill)
                            state.reqAddItemBuf = ''
                        end
                    end

                    end)
                    if not _tok then ImGui.TextColored(0.95, 0.35, 0.35, 1.0, 'tab render error - see log'); printf_log('UI tab render error: %s', tostring(_terr)) end
                    ImGui.EndTabItem()
                end

                -- ── SUMMON TAB ────────────────────────────────────────────────
                if ImGui.BeginTabItem('Summon##ts_tab_summon') then
                    local _tok, _terr = pcall(function()
                    state.activeTab = 'Summon'
                    ImGui.TextWrapped('This tab is for tradeskill items that casters make. Run this on the character that you do not want participating in the summon. Selecting Make will make the caster request items and Bring will deliver those items to you.')
                    ImGui.Spacing()

                    -- Casters / Priests picker. Cosmetic label - smart-divide picks the real producer
                    -- class per item. "Casters" = Enchanter-made supply; "Priests" = deity gem imbues.
                    if not state.reqMakeGroup then state.reqMakeGroup = 'Casters' end
                    if ImGui.BeginCombo('Type##ts_sum_makeclass', state.reqMakeGroup) then
                        for _, c in ipairs({ 'Casters', 'Priests' }) do
                            if ImGui.Selectable(c .. '##ts_sum_mkcls_' .. c, state.reqMakeGroup == c) then
                                state.reqMakeGroup = c
                            end
                        end
                        ImGui.EndCombo()
                    end

                    state.reqMakeQtyBuf = ImGui.InputText('Batch qty##ts_sum_makeqty', state.reqMakeQtyBuf or '100', 8)
                    local makeQty = math.max(1, math.floor(tonumber(state.reqMakeQtyBuf) or 100))

                    local function render_make_group(label, groupKey, hdrId)
                        if ImGui.CollapsingHeader(label .. '##' .. hdrId) then
                            for i, m in ipairs(MAKEABLE) do
                                if m.group == groupKey then
                                    if ImGui.Button('Make##ts_sum_makeadd_' .. i) then
                                        request_queue_add(m.item, 'make', makeQty)
                                    end
                                    ImGui.SameLine()
                                    if ImGui.Button('Bring##ts_sum_bring_' .. i) then
                                        request_queue_add(m.item, 'stack')
                                    end
                                    ImGui.SameLine()
                                    ImGui.Text(m.item)
                                    -- Read-only class tags on gems: which of your classes can make it.
                                    if m.group == 'gems' and m.classes then
                                        local abbr = { Cleric = 'Clr', Druid = 'Dru', Shaman = 'Shm', Wizard = 'Wiz' }
                                        local has = {}
                                        for _, c in ipairs(m.classes) do has[c] = true end
                                        local txt
                                        if has.Cleric and has.Druid and has.Shaman then
                                            txt = 'All'
                                        else
                                            local tags = {}
                                            for _, c in ipairs(m.classes) do tags[#tags + 1] = abbr[c] or c:sub(1, 3) end
                                            txt = table.concat(tags, ', ')
                                        end
                                        ImGui.SameLine()
                                        ImGui.TextDisabled('(' .. txt .. ')')
                                    end
                                end
                            end
                        end
                    end

                    if state.reqMakeGroup == 'Priests' then
                        render_make_group('Imbued Gems', 'gems', 'ts_grp_gems')
                    else
                        render_make_group('Mana Summons', 'mana', 'ts_grp_mana')
                        render_make_group('Metal and Clay', 'metal', 'ts_grp_metal')
                        render_make_group('Vials of Mana', 'vials', 'ts_grp_vials')
                    end

                    ImGui.Separator()
                    ImGui.Spacing()
                    -- ===== Request queue (shared with the Supply tab) =====
                    state.render_request_queue()

                    end)
                    if not _tok then ImGui.TextColored(0.95, 0.35, 0.35, 1.0, 'tab render error - see log'); printf_log('UI tab render error: %s', tostring(_terr)) end
                    ImGui.EndTabItem()
                end

                -- ── SETTINGS TAB ──────────────────────────────────────────────
                if ImGui.BeginTabItem('Stats##ts_tab_stats') then
                    local _stok, _sterr = pcall(function()
                    state.activeTab = 'Stats'

                    local started = state.sessionStartTime ~= nil
                    if not started then
                        ImGui.TextDisabled('No session yet - start a craft or leveling run.')
                    else
                        local secs  = math.max(1, math.floor(((mq.gettime() - state.sessionStartTime)) / 1000))
                        local hours = secs / 3600
                        local made  = state.sessionMade or 0
                        local fail  = state.sessionFailed or 0
                        local fizz  = state.sessionFizzles or 0
                        local desy  = state.sessionDesyncs or 0
                        local tries = made + fail

                        ImGui.Text('Session')
                        ImGui.Separator()
                        ImGui.TextDisabled(string.format('Elapsed: %02d:%02d:%02d%s',
                            math.floor(secs / 3600), math.floor(secs % 3600 / 60), secs % 60,
                            state.busy and '   (running)' or ''))
                        if state.sessionSkillName then
                            ImGui.TextDisabled('Tracking: ' .. tostring(state.sessionSkillName))
                        end

                        ImGui.Spacing()
                        ImGui.Text('Throughput')
                        ImGui.Separator()
                        ImGui.Text(string.format('Made: %d          Failed: %d', made, fail))
                        ImGui.TextColored(0.45, 0.85, 0.55, 1.0, string.format('Combines/hour: %.0f', made / hours))
                        if tries > 0 then
                            ImGui.TextDisabled(string.format('Success rate: %.1f%%', 100 * made / tries))
                        end

                        ImGui.Spacing()
                        ImGui.Text('Skill')
                        ImGui.Separator()
                        local s0  = state.sessionSkillStart
                        local now = state.sessionLastSkill
                        if s0 and now then
                            local gained = now - s0
                            ImGui.Text(string.format('%d  ->  %d   (+%d)', s0, now, gained))
                            local perHour = gained / hours
                            ImGui.TextColored(0.45, 0.85, 0.55, 1.0, string.format('Skill/hour: %.1f', perHour))
                            -- ETA to the character's REAL cap (a class may cap a skill below 300).
                            local cap = (state.sessionSkillName and mq.TLO.Me.SkillCap(state.sessionSkillName)()) or 0
                            if cap > 0 then
                                if now >= cap then
                                    ImGui.TextColored(0.45, 0.85, 0.55, 1.0, string.format('At cap (%d).', cap))
                                elseif perHour > 0.01 then
                                    local eta = (cap - now) / perHour
                                    ImGui.TextDisabled(string.format('Cap %d - ETA %.1f h at this rate.', cap, eta))
                                else
                                    ImGui.TextDisabled(string.format('Cap %d - no skill gain yet.', cap))
                                end
                            end
                        else
                            ImGui.TextDisabled('No skill tracked this session.')
                        end

                        ImGui.Spacing()
                        ImGui.Text('Quality')
                        ImGui.Separator()
                        ImGui.TextDisabled(string.format('Fizzles: %d%s', fizz,
                            tries > 0 and string.format('   (%.1f%% of attempts)', 100 * fizz / tries) or ''))
                        -- Desyncs are the canary when placement pace is turned up (Lightning).
                        if desy > 0 then
                            ImGui.TextColored(0.95, 0.65, 0.30, 1.0,
                                string.format('Desyncs: %d   (%.1f/hour)', desy, desy / hours))
                        else
                            ImGui.TextColored(0.45, 0.85, 0.55, 1.0, 'Desyncs: 0')
                        end

                        if state.busy and (state.totalCount or 0) > 0 then
                            ImGui.Spacing()
                            ImGui.Text('Current run')
                            ImGui.Separator()
                            ImGui.TextDisabled(string.format('%d / %d combines', state.doneCount or 0, state.totalCount))
                        end

                        ImGui.Spacing()
                        if themed_button('Reset Session##ts_stats_reset', UI.steel, 140, UI.btn_h, state.busy) then
                            state.sessionStarted = false
                            state.sessionStartTime = nil
                            state.sessionMade, state.sessionFailed = 0, 0
                            state.sessionFizzles, state.sessionDesyncs = 0, 0
                            state.sessionSkillStart, state.sessionLastSkill = nil, nil
                        end
                    end
                    end)
                    if not _stok then ImGui.TextColored(0.95, 0.35, 0.35, 1.0, 'tab render error - see log'); printf_log('UI Stats tab render error: %s', tostring(_sterr)) end
                    ImGui.EndTabItem()
                end

                if ImGui.BeginTabItem('Settings##ts_tab_settings') then
                    local _sok, _serr = pcall(function()
                    state.activeTab = 'Settings'

                    ImGui.Text('Speed')
                    ImGui.SameLine()
                    state.help_marker('Placement pace sets how fast items drop into the container. Fast (75ms) is the recommended default and tested solid. Blazing (50) is quickest; Medium (150) and Slow (300) give more margin if you see inventory desyncs on a slower connection.')
                    ImGui.Separator()
                    ImGui.Spacing()
                    -- Placement speed ladder: Blazing 50 / Fast 75 / Medium 150 / Slow 300. speedRow skips
                    -- any level a knob doesn't define, so these four show on Item placement. Fast is the
                    -- data-backed default; Slow (300) is the safety net for slower connections.
                    local speedOrder = { { 'blazing', 'Blazing' }, { 'fast', 'Fast' }, { 'medium', 'Medium' }, { 'slow', 'Slow' } }
                    local function speedRow(label, knob)
                        local cur = state.speedLevels[knob][state.speedSel[knob]]
                        ImGui.TextDisabled(string.format('%s: %dms', label, cur))
                        local first = true
                        for _, kv in ipairs(speedOrder) do
                            local key = kv[1]
                            if state.speedLevels[knob][key] ~= nil then
                                if not first then ImGui.SameLine() end
                                first = false
                                if ImGui.RadioButton(kv[2] .. '##spd_' .. knob, state.speedSel[knob] == key) then
                                    state.set_speed(knob, key)
                                end
                            end
                        end
                    end
                    speedRow('Item placement', 'placePace')

                    ImGui.Spacing()
                    ImGui.Separator()
                    ImGui.Text('Illusions (faction vendor zones)')
                    ImGui.SameLine()
                    state.help_marker('Applied in Felwithe and Jaggedpine to help with faction. If this does not help, consider using an alt to purchase instead.')
                    ImGui.Spacing()
                    do
                        ImGui.SetNextItemWidth(220)
                        local nm = ImGui.InputText('Name##ts_set_illu_name', state.illusionName or '', 64)
                        if nm ~= state.illusionName then state.illusionName = nm; state.save_settings() end
                        ImGui.SetNextItemWidth(120)
                        local cur = state.illusionType
                        if cur ~= 'Spell' and cur ~= 'Item' and cur ~= 'AA' then cur = 'Spell' end
                        if ImGui.BeginCombo('Type##ts_set_illu_type', cur) then
                            for _, t in ipairs({ 'Spell', 'Item', 'AA' }) do
                                if ImGui.Selectable(t .. '##illu_ty_' .. t, cur == t) then
                                    if state.illusionType ~= t then state.illusionType = t; state.save_settings() end
                                end
                            end
                            ImGui.EndCombo()
                        end
                    end

                    ImGui.Spacing()
                    ImGui.Text('Shrink (optional)')
                    ImGui.SameLine()
                    state.help_marker('Default is no shrink. Enter a Name and pick its Type - Spell (mems gem 8 + casts), Item (/useitem, only fires if you are carrying it), or AA (/aa act). Applied once per zone before a vendor/station approach to fit tight geometry. Blank Name = never pause to shrink.')
                    ImGui.Spacing()
                    do
                        ImGui.SetNextItemWidth(220)
                        local nm = ImGui.InputText('Name##ts_set_shrink_name', state.shrinkName or '', 64)
                        if nm ~= state.shrinkName then state.shrinkName = nm; state.save_settings() end
                        ImGui.SetNextItemWidth(120)
                        local cur = state.shrinkType
                        if cur ~= 'Spell' and cur ~= 'Item' and cur ~= 'AA' then cur = 'Item' end
                        if ImGui.BeginCombo('Type##ts_set_shrink_type', cur) then
                            for _, t in ipairs({ 'Spell', 'Item', 'AA' }) do
                                if ImGui.Selectable(t .. '##shrink_ty_' .. t, cur == t) then
                                    if state.shrinkType ~= t then state.shrinkType = t; state.save_settings() end
                                end
                            end
                            ImGui.EndCombo()
                        end
                    end

                    ImGui.Spacing()
                    ImGui.Separator()
                    ImGui.Text('Mithril Champion Arrows')
                    ImGui.SameLine()
                    state.help_marker("Mithril is sold only in Felwithe, which is faction-gated. Tick the box on a character that CAN'T shop there (e.g. an SK): its craft runs will request mithril from the group instead of trying to travel.\n\nOn a BOT that CAN shop there: set the number of combines the crafter will make and press Buy - it buys just the mithril for that many combines, then bring it over.")
                    ImGui.Spacing()
                    do
                        state.cantBuy = state.cantBuy or {}
                        state.groupBuyCombines = state.groupBuyCombines or '1000'

                        -- The tick: listing these in cantBuy makes plan_requirements treat mithril as
                        -- group-supplied instead of vendor-bought, so this character never walks to Felwithe.
                        if ImGui.Checkbox then
                            local was = state.cantBuy[state.FELWITHE_MATS[1]] and true or false
                            local now = ImGui.Checkbox("I can't shop in Felwithe##ts_set_felw", was)
                            if now ~= was then
                                for _, nm in ipairs(state.FELWITHE_MATS) do state.cantBuy[nm] = now or nil end
                                state.save_settings()
                            end
                        end

                        local q = ImGui.InputText('Qnty (combines)##ts_set_felw_qty', state.groupBuyCombines, 8)
                        if q ~= state.groupBuyCombines then state.groupBuyCombines = q; state.save_settings() end

                        if themed_button('Buy ingredients in Felwithe##ts_set_felw_buy', UI.green, 220, UI.btn_h, state.busy) then
                            state.pendingJob = { action = 'buy_felwithe' }
                        end
                        ImGui.TextDisabled(string.format('Buys the mithril for %s combines of Mithril Champion Arrows.',
                            tostring(tonumber(state.groupBuyCombines) or 1000)))
                    end

                    ImGui.Spacing()
                    ImGui.Separator()
                    ImGui.Text('Non-Stick Frying Pan (Jaggedpine)')
                    ImGui.SameLine()
                    state.help_marker("The Frying Pan Mold is sold only by Tallien Brightflash in Jaggedpine, which is faction-gated. Tick the box on a character that CAN'T shop there: its craft runs will request the mold from the group instead of trying to travel.\n\nOn a BOT that CAN shop there: set how many pans you'll make (one mold each) and press Buy, then bring the molds over.")
                    ImGui.Spacing()
                    do
                        state.cantBuy = state.cantBuy or {}
                        state.jaggedBuyQty = state.jaggedBuyQty or '1'

                        if ImGui.Checkbox then
                            local was = state.cantBuy[state.JAGGEDPINE_ITEM] and true or false
                            local now = ImGui.Checkbox("I can't shop in Jaggedpine##ts_set_jagged", was)
                            if now ~= was then
                                state.cantBuy[state.JAGGEDPINE_ITEM] = now or nil
                                state.save_settings()
                            end
                        end

                        local q = ImGui.InputText('Qnty (pans, max 6)##ts_set_jagged_qty', state.jaggedBuyQty, 8)
                        if q ~= state.jaggedBuyQty then state.jaggedBuyQty = q; state.save_settings() end

                        if themed_button('Buy mold in Jaggedpine##ts_set_jagged_buy', UI.green, 220, UI.btn_h, state.busy) then
                            state.pendingJob = { action = 'buy_jaggedpine' }
                        end
                        ImGui.TextDisabled(string.format('Buys %d x Frying Pan Mold (one per Non-Stick Frying Pan).',
                            math.max(1, math.min(6, tonumber(state.jaggedBuyQty) or 1))))
                    end

                    ImGui.Spacing()
                    ImGui.Separator()
                    ImGui.Text('Utilities')
                    ImGui.SameLine()
                    ImGui.TextColored(0.45, 0.75, 0.95, 1.0, 'LazCraft ' .. (state.VERSION or '?') .. '  (build ' .. (state.BUILD_TAG or '?') .. ')')
                    ImGui.Spacing()
                    if ImGui.Button('Reload Config##ts_set_reload', UI.btn_w, UI.btn_h) then
                        load_config()
                    end
                    ImGui.TextDisabled('Bank Trophies & Tools is at the top of the window (works from any tab).')
                    end)
                    if not _sok then ImGui.TextColored(0.95, 0.35, 0.35, 1.0, 'tab render error - see log'); printf_log('UI Settings tab render error: %s', tostring(_serr)) end
                    ImGui.EndTabItem()
                end

                -- ── TRAVEL TAB ───────────────────────────────────────────────
                if ImGui.BeginTabItem('Travel##ts_tab_dev') then
                    local _dok, _derr = pcall(function()
                    state.activeTab = 'Dev'
                    ImGui.Text('Travel routes')
                    ImGui.Separator()
                    ImGui.TextDisabled(string.format('Current zone: %s', current_zone() or '?'))
                    ImGui.Spacing()
                    ImGui.TextWrapped('Fire a travel to a location, without running a craft or purchasing from a vendor.')
                    ImGui.Spacing()
                    if ImGui.Button('Go to Thurgadin##ts_dev_thurg', 160, 0) then
                        state.pendingJob = { action = 'travel', dest = 'thurgadin' }
                        printf_log('Dev: travel to Thurgadin queued.')
                    end
                    ImGui.SameLine()
                    if ImGui.Button('Go to PoK##ts_dev_pok', 160, 0) then
                        state.pendingJob = { action = 'travel', dest = 'pok' }
                        printf_log('Dev: travel to Plane of Knowledge queued.')
                    end
                    if ImGui.Button('Go to Marr (Temple)##ts_dev_marr', 160, 0) then
                        state.pendingJob = { action = 'travel', dest = 'marr' }
                        printf_log('Dev: travel to Temple of Marr queued.')
                    end
                    ImGui.SameLine()
                    if ImGui.Button('Go to Jaggedpine##ts_dev_jp', 160, 0) then
                        state.pendingJob = { action = 'travel', dest = 'jaggedpine' }
                        printf_log('Dev: travel to Jaggedpine queued.')
                    end
                    if ImGui.Button('Go to Felwithe##ts_dev_fel', 160, 0) then
                        state.pendingJob = { action = 'travel', dest = 'felwithe' }
                        printf_log('Dev: travel to Northern Felwithe queued.')
                    end
                    if ImGui.Button('Go to West Freeport##ts_dev_fpt', 160, 0) then
                        state.pendingJob = { action = 'travel', dest = 'freeport' }
                        printf_log('Dev: travel to West Freeport queued.')
                    end
                    if ImGui.Button('Go to North Freeport##ts_dev_fptn', 160, 0) then
                        state.pendingJob = { action = 'travel', dest = 'freportn' }
                        printf_log('Travel to North Freeport queued.')
                    end
                    ImGui.SameLine()
                    if ImGui.Button('Go to Abysmal Sea##ts_dev_aby', 160, 0) then
                        state.pendingJob = { action = 'travel', dest = 'abysmal' }
                        printf_log('Dev: travel to Abysmal Sea queued.')
                    end
                    if ImGui.Button('Go to Natimbi##ts_dev_nat', 160, 0) then
                        state.pendingJob = { action = 'travel', dest = 'natimbi' }
                        printf_log('Dev: travel to Natimbi queued.')
                    end
                    if ImGui.Button('Go to Qeynos Hills (HC)##ts_dev_hcq', 180, 0) then
                        state.pendingJob = { action = 'travel', dest = 'hardcore' }
                        printf_log('Dev: travel to Hardcore Qeynos instance queued.')
                    end
                    ImGui.Spacing()
                    ImGui.Separator()
                    if ImGui.Button('Stop##ts_dev_stop', 160, 0) then
                        run_stop('UI Stop button')
                    end
                    end)
                    if not _dok then ImGui.TextColored(0.95, 0.35, 0.35, 1.0, 'tab render error - see log'); printf_log('UI Dev tab render error: %s', tostring(_derr)) end
                    ImGui.EndTabItem()
                end

                ImGui.EndTabBar()
            end

            -- ── Session strip + log (persistent, below the tabs) ────────────
            ImGui.Separator()
            if state.sessionStarted then
                local total = state.sessionMade + state.sessionFailed
                local pct = total > 0 and (state.sessionMade / total * 100) or 0
                ImGui.TextDisabled(string.format('Session:  made %d   failed %d   combines %d (%.0f%%)   skill %d\226\134\146%d',
                    state.sessionMade, state.sessionFailed, total, pct,
                    state.sessionSkillStart or 0, state.sessionLastSkill or state.sessionSkillStart or 0))
            else
                ImGui.TextDisabled('Session:  idle')
            end
            -- "Buy manually" shopping list: mats whose only vendor is in a zone we can't auto-travel
            -- to. Grouped by zone so one trip covers several. Cleared with the button.
            if state.manualBuys and #state.manualBuys > 0 then
                ImGui.Separator()
                ImGui.TextColored(0.95, 0.75, 0.35, 1.0, string.format('Buy manually (%d) - no auto-travel, by zone:', #state.manualBuys))
                for _, ln in ipairs(state.manual_buys_report()) do ImGui.TextWrapped(ln) end
                if themed_button('Clear list##ts_clear_manual', UI.steel, 120, UI.btn_h, false) then
                    state.manualBuys = {}
                end
            end
            ImGui.Separator()
            -- Log: collapsible (saves screen space) with its own darker background. Minimizing contracts
            -- the whole window by the log height; restoring grows it back (see pendingLogResize above).
            do
                local toggleLabel = state.logCollapsed and 'Show log' or 'Hide log'
                if themed_button(toggleLabel .. '##ts_log_toggle', UI.steel, 90, UI.btn_h, false) then
                    state.logCollapsed = not state.logCollapsed
                    state.pendingLogResize = state.logCollapsed and -176 or 176   -- 160 child + padding
                end
                if not state.logCollapsed then
                    ImGui.SameLine()
                    ImGui.TextDisabled(string.format('(%d lines)', #(state.log or {})))
                    if ImGui.PushStyleColor then ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.07, 0.08, 0.11, 1.0) end
                    if ImGui.BeginChild('##ts_logchild', 0, 160, true) then
                        local l = state.log or {}
                        for i = 1, #l do
                            ImGui.TextWrapped(l[i])
                        end
                    end
                    ImGui.EndChild()
                    if ImGui.PopStyleColor then ImGui.PopStyleColor(1) end
                end
            end

        end)
        if not ok then
            ImGui.TextColored(0.95, 0.35, 0.35, 1.0, 'UI error: ' .. tostring(drawErr))
        end
    end

    -- EQ-style double-hairline frame around the window (drawn last, over the content). Fully pcall-guarded
    -- and tries BOTH draw-list API shapes (ImVec2 args / raw-number args) plus both color forms, so it can
    -- never break the UI even if this MQ build's ImGui binding differs - worst case the frame just doesn't
    -- appear. Retint via the two colors below (deep outline + twin rules); gap is the +1 / +3 insets.
    pcall(function()
        if not (ImGui.GetWindowDrawList and ImGui.GetColorU32 and ImGui.GetWindowPos and ImGui.GetWindowSize) then return end
        local dl = ImGui.GetWindowDrawList()
        local px, py = ImGui.GetWindowPos()
        local sx, sy = ImGui.GetWindowSize()
        local x1, y1, x2, y2 = px, py, px + sx, py + sy
        local function C(r, g, b)
            local ok, v = pcall(function() return ImGui.GetColorU32(ImVec4(r, g, b, 1)) end)
            if ok then return v end
            return ImGui.GetColorU32(r, g, b, 1)
        end
        local function R(a, b, c, d, col)
            local ok = pcall(function() dl:AddRect(ImVec2(a, b), ImVec2(c, d), col, 0, 0, 1) end)
            if not ok then pcall(function() dl:AddRect(a, b, c, d, col, 0, 0, 1) end) end
        end
        local function L(a, b, c, d, col)
            local ok = pcall(function() dl:AddLine(ImVec2(a, b), ImVec2(c, d), col, 1) end)
            if not ok then pcall(function() dl:AddLine(a, b, c, d, col, 1) end) end
        end
        local function FILL(a, b, c, d, col)
            local ok = pcall(function() dl:AddRectFilled(ImVec2(a, b), ImVec2(c, d), col, 0, 0) end)
            if not ok then pcall(function() dl:AddRectFilled(a, b, c, d, col) end) end
        end

        -- twin-rule colour: teal-grey normally; pulses toward amber while PAUSED (attention cue)
        local rr, gg, bb = 0.227, 0.298, 0.333
        if state.paused then
            local t = 0.5 + 0.5 * math.abs(math.sin(mq.gettime() / 350))   -- gentle 0.5..1 pulse
            rr = 0.227 + (0.85 - 0.227) * t
            gg = 0.298 + (0.62 - 0.298) * t
            bb = 0.333 + (0.20 - 0.333) * t
        end
        local ink  = C(0.016, 0.031, 0.039)   -- deep outer outline
        local rule = C(rr, gg, bb)            -- the twin hairlines (amber-pulsing when paused)
        R(x1,     y1,     x2,     y2,     ink)    -- deep outline
        R(x1 + 1, y1 + 1, x2 - 1, y2 - 1, rule)   -- outer rule
        R(x1 + 3, y1 + 3, x2 - 3, y2 - 3, rule)   -- inner rule (2px gap)

        -- teal accent line just under the title bar
        local tbh = 22
        pcall(function() local h = ImGui.GetFrameHeight(); if h and h > 0 then tbh = h end end)
        L(x1 + 4, y1 + tbh, x2 - 4, y1 + tbh, C(0.31, 0.69, 0.77))

        -- small anvil mark, placed just AFTER the title text so it never overlaps the label or the X
        local tw = 60
        pcall(function() local w = ImGui.CalcTextSize('LazCraft  [' .. (state.VERSION or '?') .. ']'); if w then tw = w end end)
        local ax, ay = x1 + 12 + tw + 10, y1 + 6
        local metal = C(0.55, 0.62, 0.66)
        FILL(ax,     ay,     ax + 13, ay + 3, metal)   -- anvil face
        FILL(ax + 4, ay + 3, ax + 8,  ay + 6, metal)   -- waist
        FILL(ax + 1, ay + 6, ax + 12, ay + 9, metal)   -- base
    end)

    ImGui.End()
    pop_ui_style(styleVars, styleCols)
end

local function ui_command(...)
    local args = { ... }
    local arg = trim(args[1] or ''):lower()
    if arg == 'stop' then
        run_stop('/tsui stop command (external)')
    elseif arg == 'plan' then
        -- Join everything after "plan" as the recipe name (preserve case + spaces;
        -- only args[1] was lowercased). e.g. /tsui plan Misty Thicket Picnic
        local parts = {}
        for i = 2, #args do parts[#parts + 1] = args[i] end
        local recipeName = trim(table.concat(parts, ' '))
        if recipeName == '' then
            printf_log('Usage: /tsui plan <recipe name>   e.g. /tsui plan Misty Thicket Picnic')
        else
            plan_tree(recipeName, 1)
        end
    elseif arg == 'hide' or arg == 'close' then
        state.windowOpen = false
    elseif arg == 'show' or arg == 'open' then
        state.windowOpen = true
    elseif arg == 'toggle' then
        state.windowOpen = not state.windowOpen
    else
        state.windowOpen = true
    end
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

-- Load recipe/merchant/research config, then per-character settings, before the UI opens.
load_config()
state.load_settings()   -- per-character speed knobs + saved custom leveling-path recipes
-- (Startup peer-zone prewarm removed: firing /dobserve for every DanNet peer at load could flood the
--  command queue on a populated server and stall the client. peer_zone registers on-demand instead.)
state.statusMsg = ''    -- don't leave "Loaded ..." lingering in the status strip

-- Initial view: new users land on the Welcome guide page; veterans who ticked "Don't open to this
-- page" jump straight to the first main-group skill still under 300 (dependency order), so the tab
-- opens on "what should I level right now". If every main skill is maxed, fall back to the guide.
do
    local landed = false
    if state.welcomeDontDefault then
        local myClass = mq.TLO.Me.Class.Name() or ''
        local firstValid = nil
        -- Same order as the Skill Path dropdown (recOrder): Fletching after Blacksmithing, because
        -- fletching's mithril parts and tools are Blacksmithing combines. Keep the two lists in sync.
        for _, sk in ipairs({ 'Jewelcrafting', 'Brewing', 'Tailoring', 'Blacksmithing', 'Fletching', 'Baking', 'Pottery' }) do
            local req = state.pathClassReq[sk]
            if (not req or req == myClass) and RECOMMENDED_PATHS[sk] then
                firstValid = firstValid or sk
                -- EQ skill name = explicit Skill= override, else the path name (Baking/Tailoring match 1:1).
                -- Cap = the character's real SkillCap. Land on the first skill still below its cap.
                local sec = (state.iniSections or {})['Skill:' .. sk]
                local eqName = (sec and sec.Skill) or sk
                local cap = mq.TLO.Me.SkillCap(eqName)() or 0
                if cap <= 0 then cap = 300 end
                if (skill_value(eqName) or 0) < cap then
                    state.recPathSelected = sk
                    level_load_recommended(sk)
                    landed = true
                    break
                end
            end
        end
        -- Everything maxed? A user who ticked "don't open to Welcome" still shouldn't be dumped there -
        -- land on the first valid skill anyway.
        if not landed and firstValid then
            state.recPathSelected = firstValid
            level_load_recommended(firstValid)
            landed = true
        end
    end
    if not landed then state.recPathSelected = 'Welcome' end
end

pcall(function() mq.bind('/tsui', ui_command) end)

-- Test command for the upfront supply requests (the Request tab will drive the
-- same engine). Usage:  /tsreq stack Fine Silk   |   /tsreq all Superb Animal Pelt
pcall(function() mq.bind('/tsreq', function(mode, ...)
    if state.busy then printf('\ar[Tradeskill]\ax busy - try again when idle.'); return end
    mode = (mode or ''):lower()
    if mode ~= 'stack' and mode ~= 'all' then
        printf('\ar[Tradeskill]\ax usage: /tsreq stack|all <item name>'); return
    end
    local item = table.concat({...}, ' ')
    if item == '' then printf('\ar[Tradeskill]\ax name an item.'); return end
    state.pendingJob = { action = 'request', requests = { { item = item, mode = mode } } }
end) end)

-- Deposit the whole inventory stack of `name` back into a bank bag (keeps it in a bag for the next
-- test round). Used only by /laztestbank.
state.test_deposit = function(name)
    if item_count(name) <= 0 then printf_log('  deposit: no %s in bags', name); return end
    mq.cmdf('/itemnotify "%s" leftmouseup', name)
    mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) > 0 or mq.TLO.Window('QuantityWnd').Open() end)
    if mq.TLO.Window('QuantityWnd').Open() then   -- stackable pickup pops a split; take the whole stack
        mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
        mq.delay(500, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
    end
    if (mq.TLO.Cursor.ID() or 0) == 0 then printf_log('  deposit: could not pick up %s', name); return end
    -- Stow via the bank window's Auto button (BIGB_AutoButton) - the gesture TurboLoot uses. The
    -- /autobank COMMAND doesn't work on Laz, but clicking the bank's Auto button with the item on the
    -- cursor auto-deposits it (finds a home itself, no bag to open). Retry once if it doesn't settle.
    mq.cmd('/notify BigBankWnd BIGB_AutoButton leftmouseup')
    mq.delay(800, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
    if (mq.TLO.Cursor.ID() or 0) ~= 0 then
        mq.cmd('/notify BigBankWnd BIGB_AutoButton leftmouseup')
        mq.delay(600, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
    end
    if (mq.TLO.Cursor.ID() or 0) == 0 then printf_log('  deposit: %s -> bank (Auto button)', name)
    else printf_log('  deposit: bank Auto button did not stow %s (still on cursor)', name) end
end

-- TEST: /laztestbank [stackItem] [trophyItem] [rounds]  (defaults: Powder of Ro / Blacksmithing Trophy / 2)
-- Withdraws 5 (partial), then a whole stack, then the trophy, then deposits all back - N rounds. Watch for
-- '(opened bank bag N)': it should appear for the PARTIAL pull only, NOT the whole-stack or trophy pulls.
-- TEST: /laztestdq <peer> <item name>   e.g. /laztestdq Hezalo Powder of Ro
-- Reads the peer's count of that item via DanNet and reports it + the round-trip time. Try it with a
-- spacey name AND an apostrophe name (Kerafyrm's Bite XIII) to prove DanNet passes them cleanly.
mq.bind('/laztestdq', function(peer, ...)
    local itemName = table.concat({...}, ' ')
    if not peer or peer == '' or itemName == '' then
        printf_log('/laztestdq: usage  /laztestdq <peer> <item name>'); return
    end
    printf_log('=== /laztestdq: ask %s for FindItemCount[=%s] ===', peer, itemName)
    local t0 = mq.gettime()
    local n = state.peer_item_count(peer, itemName)
    local dt = mq.gettime() - t0
    if n < 0 then
        printf_log('  NO RESULT after %dms - DanNet did not return it (bad name escape or peer down). Listener stays for this.', dt)
    else
        printf_log('  %s has %d x %s   (via DanNet, %dms)', peer, n, itemName, dt)
    end
end)

-- TEST: /laztestgroup <item name>   e.g. /laztestgroup Powder of Ro
-- Queries every same-zone mule for that item via DanNet, two ways: (1) serial per-mule peer_item_count
-- (shows each mule's count + round-trip ms), and (2) the batched PARALLEL peer_item_counts that
-- group_check actually uses (shows total, holders, and total ms). Verify the counts match what the
-- mules really hold, and that the parallel path is fast.
-- TEST: /laztestcrosszone <item name>   e.g. /laztestcrosszone Velium Bar
-- Runs the cross-zone QUERY + holder-resolution only - NO travel, NO delivery. Reads every network
-- peer's zone (live /dquery), filters to reachable hubs other than ours, DanNet-queries them (bags+bank),
-- and prints who holds it + where + the best pick. Safe to spam - it never moves the crafter.
-- TEST: /laztestbankread <item name>   run with the bank CLOSED (fresh-zoned, no bank trip)
-- Sanity-check the crafter's OWN cold-bank read: the direct Lua TLO [1] is what bank_count now uses
-- (verified reading a closed bank correctly); [2] is a DanNet self-query for comparison. Both should
-- match what's actually banked.
mq.bind('/laztestbankread', function(...)
    local name = table.concat({...}, ' ')
    if name == '' then printf_log('usage: /laztestbankread <item name>  (run with bank CLOSED)'); return end
    local bankOpen = mq.TLO.Window('BigBankWnd').Open()
    printf_log('=== /laztestbankread: "%s"  (bank is %s) ===', name, bankOpen and 'OPEN' or 'CLOSED')
    if bankOpen then printf_log('  NOTE: bank is OPEN - close it and re-run to test the cold-read path.') end
    -- 1) plain Lua binding (the one that reads 0 cold on this build)
    local okL, luaN = pcall(function() return mq.TLO.FindItemBankCount('='..name)() end)
    printf_log('  [1] Lua mq.TLO.FindItemBankCount = %s', okL and tostring(luaN) or 'ERR')
    -- 2) DanNet query to OURSELF (comparison)
    local me = (mq.TLO.Me.Name() or ''):lower()
    local t0 = mq.gettime()
    local dN = state.dannet_query(me, string.format('FindItemBankCount[=%s]', name), 2000)
    printf_log('  [2] DanNet self-query (%s)       = %s  (%dms)', me, (dN == '') and 'NO REPLY' or dN, mq.gettime() - t0)
    printf_log('  -> both should equal the real banked count.')
end)

mq.bind('/laztestcrosszone', function(...)
    local item = table.concat({...}, ' ')
    if item == '' then printf_log('usage: /laztestcrosszone <item name>'); return end
    local origin = current_zone()
    printf_log('=== /laztestcrosszone: "%s"  (we are in %s) ===', item, origin)
    local allPeers = state.all_network_peers()
    printf_log('  %d network peer(s): %s', #allPeers, table.concat(allPeers, ', '))
    if #allPeers == 0 then printf_log('  no network peers (DanNet down?)'); return end
    -- live zones for all peers
    local t0 = mq.gettime()
    local zones = state.query_peer_zones(allPeers)
    printf_log('  zone read: %dms', mq.gettime() - t0)
    local peers, peerZone = {}, {}
    for _, pr in ipairs(allPeers) do
        local z = zones[pr]
        local reachable = z and state.CROSS_ZONES[z] and z ~= origin
        printf_log('    %s -> zone=%s  %s', pr, tostring(z or '?'), reachable and '(REACHABLE)' or (z == origin and '(our zone)' or '(not a hub)'))
        if reachable then peers[#peers + 1] = pr; peerZone[pr] = z end
    end
    if #peers == 0 then printf_log('  no reachable cross-zone peer to ask.'); return end
    -- DanNet item sweep (bags+bank) - same call the real path uses
    local t1 = mq.gettime()
    state.peer_item_counts(peers, { item })
    printf_log('  item sweep: %dms', mq.gettime() - t1)
    local best, bestZone, bestQty = nil, nil, 0
    local anyHolder = false
    for holder, qty in pairs(state.availHolders[item] or {}) do
        anyHolder = true
        local hz = peerZone[holder] or peerZone[tostring(holder):lower()]
        printf_log('    holder %s = %d  (zone %s)', holder, qty, tostring(hz or '?'))
        if hz and (qty or 0) > bestQty then best, bestZone, bestQty = holder, hz, qty end
    end
    if not anyHolder then printf_log('  no reachable peer holds %s.', item)
    elseif best then printf_log('  BEST PICK: %s in %s with %d (this is who the real run would travel to)', best, bestZone, bestQty)
    else printf_log('  holders found but none in a resolvable zone (investigate).') end
end)

mq.bind('/laztestgroup', function(...)
    local raw = table.concat({...}, ' ')
    if raw == '' then printf_log('usage: /laztestgroup <item>   OR   <item1>|<item2>|...   (| separates items)'); return end
    -- Split on | for MULTI-item: this reproduces the group_check batch that misattributed holders.
    local items = {}
    for it in raw:gmatch('([^|]+)') do
        it = it:gsub('^%s+',''):gsub('%s+$','')
        if it ~= '' then items[#items + 1] = it end
    end
    local mules = state.same_zone_peers()
    printf_log('=== /laztestgroup: %d item(s) across %d same-zone mule(s) ===', #items, #mules)
    if #mules == 0 then printf_log('  no same-zone mules (DanNet up? mules in YOUR zone?)'); return end
    -- GROUND TRUTH: serial per-mule per-item (each query fully isolated - can't misattribute).
    local serial = {}
    for _, it in ipairs(items) do
        serial[it] = 0
        for _, m in ipairs(mules) do
            local n = state.peer_item_count(m, it)
            if n > 0 then serial[it] = serial[it] + n; printf_log('  [serial] %s has %d %s', m, n, it) end
        end
    end
    -- BATCH: exactly what group_check uses (state.peer_item_counts on the whole item list). The holders
    -- printed here are what delivery would target - compare against the serial ground truth above.
    local avail = state.peer_item_counts(mules, items)
    for _, it in ipairs(items) do
        local hs = {}
        for h, q in pairs(state.availHolders[it] or {}) do hs[#hs + 1] = ('%s:%d'):format(h, q) end
        local ptot = avail[it] or 0
        local flag = (ptot == (serial[it] or 0)) and 'OK' or ('** MISMATCH (serial total=' .. (serial[it] or 0) .. ')')
        printf_log('  [batch] %s: total=%d holders=[%s]  %s', it, ptot, table.concat(hs, ', '), flag)
    end
end)

mq.bind('/laztestbank', function(a1, a2, a3)
    local stackName  = (a1 ~= nil and a1 ~= '') and a1 or 'Powder of Ro'
    local trophyName = (a2 ~= nil and a2 ~= '') and a2 or 'Blacksmithing Trophy'
    local rounds     = tonumber(a3) or 2
    printf_log('=== /laztestbank: %s (5 + whole) + %s, %d round(s) ===', stackName, trophyName, rounds)
    -- Start from a KNOWN state: close the bank if open (bags close with it), then open fresh so the
    -- opened-set is reset to MATCH reality. A stale set made ensure_bank_bag_open re-toggle an
    -- already-open bag SHUT between rounds - that was [a] grabbing the whole stack in round 2.
    if mq.TLO.Window('BigBankWnd').Open() then
        mq.cmd('/notify BigBankWnd DoneButton leftmouseup')
        mq.delay(700, function() return not mq.TLO.Window('BigBankWnd').Open() end)
    end
    if not state.reach_and_open_bank() then printf_log('  could not open bank - aborting.'); return end
    local pa, pb, pc, tTotal = 0, 0, 0, 0   -- pass counts per step + total time
    for r = 1, rounds do
        local t0 = mq.gettime()
        printf_log('--- round %d/%d ---', r, rounds)
        printf_log('[a] withdraw 5 x %s   (PARTIAL -> expect an open)', stackName)
        local ta = mq.gettime(); local ga = state.withdraw_count(stackName, 5); ta = mq.gettime() - ta
        printf_log('[b] withdraw a WHOLE stack of %s   (expect NO open; accept split default)', stackName)
        local tb = mq.gettime(); local gb = state.withdraw_count(stackName, 1000000); tb = mq.gettime() - tb
        printf_log('[c] withdraw 1 x %s   (non-stackable -> expect NO open)', trophyName)
        local tc = mq.gettime(); local gc = state.withdraw_count(trophyName, 1); tc = mq.gettime() - tc
        printf_log('[d] depositing everything back...')
        state.test_deposit(trophyName)
        state.test_deposit(stackName)
        if ga == 5 then pa = pa + 1 else printf_log('  ** [a] FAIL: got %d (want 5)', ga) end
        if gb > 0 then pb = pb + 1 else printf_log('  ** [b] FAIL: got %d (want a full stack)', gb) end
        if gc == 1 then pc = pc + 1 else printf_log('  ** [c] FAIL: got %d (want 1)', gc) end
        local dt = mq.gettime() - t0; tTotal = tTotal + dt
        printf_log('round %d: %dms total  [a]%dms [b]%dms [c]%dms  (a=%d b=%d c=%d)', r, dt, ta, tb, tc, ga, gb, gc)
    end
    mq.cmd('/notify BigBankWnd DoneButton leftmouseup')
    printf_log('=== SUMMARY: %d round(s) | [a] partial %d/%d | [b] whole %d/%d | [c] trophy %d/%d | avg round %dms ===',
        rounds, pa, rounds, pb, rounds, pc, rounds, (rounds > 0) and math.floor(tTotal / rounds) or 0)
end)

-- TEST: mirror of the listener's /ts_wtest so the crafter's withdraw is measured the SAME way -
-- repeated partial withdraw_count(item, count), score + time each round, no whole/trophy/deposit noise.
-- Usage on the crafter: /laztestwd <item> <count> [rounds]   e.g.  /laztestwd Glass Shard 5 10
mq.bind('/laztestwd', function(...)
    local args = { ... }
    if #args < 2 then printf_log('usage: /laztestwd <item> <count> [rounds]'); return end
    local rounds = 1
    if #args >= 3 and tonumber(args[#args]) and tonumber(args[#args - 1]) then
        rounds = math.max(1, math.floor(tonumber(args[#args]))); args[#args] = nil
    end
    local count = tonumber(args[#args]); args[#args] = nil
    if not count then printf_log('/laztestwd: expected a number for <count>'); return end
    count = math.max(1, math.floor(count))
    local item = table.concat(args, ' ')
    printf_log('/laztestwd: %s x%d - %d round(s)...', item, count, rounds)
    local passes, tsum = 0, 0
    for r = 1, rounds do
        local t0  = mq.gettime()
        local got = state.withdraw_count(item, count)   -- self-opens the bank; stow probe logs inside
        local dt  = mq.gettime() - t0
        tsum = tsum + dt
        local inBags = item_count(item)
        local ok = (got == count) and (inBags >= count)
        if ok then passes = passes + 1 end
        printf_log('  round %d/%d %s: withdrew %d, %d in bags (asked %d) in %dms - %s',
            r, rounds, item, got, inBags, count, dt, ok and 'PASS' or 'FAIL')
    end
    printf_log('/laztestwd: %d/%d PASS, avg %dms.', passes, rounds, (rounds > 0) and math.floor(tsum / rounds) or 0)
end)

pcall(function() mq.bind('/lazbank', function(action, ...)
    if state.busy then printf('\ar[Tradeskill]\ax busy - try again when idle.'); return end
    action = (action or ''):lower()
    local args = { ... }
    if action == 'deposit' then
        local name = table.concat(args, ' ')
        if name == '' then printf('\ar[Tradeskill]\ax usage: /lazbank deposit <item>'); return end
        state.pendingJob = { action = 'banktest', op = 'deposit', name = name }
    elseif action == 'withdraw' then
        local n = tonumber(table.remove(args)) or 1
        local name = table.concat(args, ' ')
        if name == '' then printf('\ar[Tradeskill]\ax usage: /lazbank withdraw <item> <count>'); return end
        state.pendingJob = { action = 'banktest', op = 'withdraw', name = name, n = n }
    else
        printf('\ar[Tradeskill]\ax usage: /lazbank deposit <item>  |  /lazbank withdraw <item> <count>')
    end
end) end)

-- TEST/utility: request an EXACT count of an item from the group's mules (exercises the whole
-- exact-delivery chain). Usage on the crafter: /lazreq <item> <count>  (item words joined by spaces).
pcall(function() mq.bind('/lazreq', function(...)
    if state.busy then printf('\ar[Tradeskill]\ax busy - try again when idle.'); return end
    local args = { ... }
    if #args < 2 then printf('\ar[Tradeskill]\ax usage: /lazreq <item> <count>'); return end
    local n = tonumber(table.remove(args)) or 1
    local name = table.concat(args, ' '):gsub('_', ' ')
    state.pendingJob = { action = 'reqexact', item = name, n = n }
end) end)

-- TEST: pre-load the DROPPED-mat shortfall for a recipe from the group (travel to Marr, request the
-- exact shortfall, return to PoK). Usage on the crafter: /lazpreload <item> [combines]
pcall(function() mq.bind('/lazpreload', function(...)
    if state.busy then printf('\ar[Tradeskill]\ax busy - try again when idle.'); return end
    local args = { ... }
    if #args < 1 then printf('\ar[Tradeskill]\ax usage: /lazpreload <item> [combines]'); return end
    local combines = tonumber(args[#args])
    if combines then table.remove(args) else combines = 1 end
    local name = table.concat(args, ' '):gsub('_', ' ')
    state.pendingJob = { action = 'preload', recipeList = { { name = name, combines = combines } } }
end) end)

mq.imgui.init(scriptName, render_window)
printf('\ag[Tradeskill]\ax UI open - \ay/lua run TradeskillSuite\ax or \ay/tsui toggle\ax')

while state.running do
    -- All-tradeskills chain: when the current skill's leveling run has ended on its own (cap / out of
    -- mats), roll to the next skill - or finish after Pottery. Guarded to fire only BETWEEN skills
    -- (levelRunning false, nothing busy or queued), never mid-run. A Stop clears levelAllRunning.
    if state.levelAllRunning and not state.levelRunning and not state.busy and not state.pendingJob then
        state.level_all_next()
    end
    if state.pendingJob then
        local job = state.pendingJob
        state.pendingJob = nil
        mq.cmd('/e3p on')   -- pause E3 for EVERY action (all of them nav-heavy) until the work is done
        -- Start of any run: stow anything stranded on the cursor (a trophy/quill left there by a prior
        -- run's ammo swap) before we do anything, so it can't ride in and block an equip or a pickup.
        if cursor_id() > 0 then mq.cmd('/autoinventory'); mq.delay(600, function() return cursor_id() == 0 end) end
        if job.action == 'sell_reagents' then
            run_sell_reagents(job)
        elseif job.action == 'request' then
            run_request_queue(job)
        elseif job.action == 'level_sell' then
            run_level_sell(job)
        elseif job.action == 'buy_reagents' then
            run_buy_reagents(job)
        elseif job.action == 'buy_felwithe' then
            state.run_buy_felwithe(job)
        elseif job.action == 'buy_jaggedpine' then
            state.run_buy_jaggedpine(job)
        elseif job.action == 'destroy_all' then
            local okD, errD = pcall(run_destroy_all_engine, job)
            if (not okD) and not tostring(errD):find('__TS_STOP__', 1, true) then error(errD) end
        elseif job.action == 'fish' then
            state.run_fish_engine(job)
        elseif job.action == 'booze' then
            state.run_booze_engine(job)
        elseif job.action == 'bank_trophies' then
            state.bank_all_trophies()
        elseif job.action == 'banktest' then
            state.busy = true
            pcall(function()
                if job.op == 'deposit' then state.deposit_to_bank(job.name)
                elseif job.op == 'withdraw' then state.withdraw_count(job.name, job.n)
                end
            end)
            state.busy = false
        elseif job.action == 'reqexact' then
            state.busy = true
            pcall(function()
                local got = request_supply(job.item, job.n)
                printf_log('Request complete: received %d x %s (asked %d).', got or 0, job.item, job.n)
            end)
            state.busy = false
        elseif job.action == 'preload' then
            state.busy = true
            pcall(function() state.preload_dropped(job.recipeList) end)
            state.busy = false
        elseif job.action == 'summon' then
            state.busy = true
            pcall(function() state.dispatch_makes(job.items) end)
            state.busy = false
        elseif job.action == 'research' then
            local origAmmo = mq.TLO.Me.Inventory('ammo').Name() or ''
            state.equip_modifier(state.tsModifier)   -- seat the modifier (e.g. Ethereal Quill) before combines
            local okRsr, errRsr = pcall(run_research_engine, job)
            if (mq.TLO.Me.Inventory('ammo').Name() or '') ~= origAmmo then   -- put your ammo item back on ANY exit
                state.savedSlots = { ammo = origAmmo }
                state.restore_saved_slots()
            end
            if (not okRsr) and not tostring(errRsr):find('__TS_STOP__', 1, true) then error(errRsr) end
        elseif job.action == 'research_kit' then
            local origAmmo = mq.TLO.Me.Inventory('ammo').Name() or ''
            state.equip_modifier(state.tsModifier)   -- seat the modifier before combines
            local okKit, errKit = pcall(run_research_kit, job)
            if (mq.TLO.Me.Inventory('ammo').Name() or '') ~= origAmmo then
                state.savedSlots = { ammo = origAmmo }
                state.restore_saved_slots()
            end
            if (not okKit) and not tostring(errKit):find('__TS_STOP__', 1, true) then error(errKit) end
        elseif job.action == 'travel' then
            if job.dest == 'thurgadin' then
                travel_to_thurgadin()
            elseif job.dest == 'pok' then
                travel_to_pok()
            elseif job.dest == 'marr' then
                travel_to_marr()
            elseif job.dest == 'jaggedpine' then
                travel_to_jaggedpine()
            elseif job.dest == 'felwithe' then
                travel_to_felwithe()
            elseif job.dest == 'freeport' then
                state.travel_to_freeport()
            elseif job.dest == 'freportn' then
                state.travel_to_freportn()
            elseif job.dest == 'abysmal' then
                state.travel_to_abysmal()
            elseif job.dest == 'natimbi' then
                state.travel_to_natimbi()
            elseif job.dest == 'hardcore' then
                state.travel_to_hardcore_qeynos()
            else
                printf_log('Dev travel: unknown destination "%s".', tostring(job.dest))
            end
        else
            -- Guard: a Stop during the pre-craft SUPPLY phase (ask_and_pull -> request_supply_grouped
            -- -> check_stop) throws __TS_STOP__ from OUTSIDE the crafting loop's own pcall. Without this
            -- guard it bubbled to the main chunk and killed the WHOLE script instead of aborting the job.
            local okRun, runErr = pcall(run_engine, job)
            if (not okRun) and not tostring(runErr):find('__TS_STOP__', 1, true) then
                error(runErr)
            end
            -- If running a queue, advance to next entry
            if state.queueRunning and not state.stopRequested then
                state.currentQueueIndex = state.currentQueueIndex + 1
                if state.currentQueueIndex <= #state.queue then
                    local entry = state.queue[state.currentQueueIndex]
                    local skillSec = (state.iniSections or {})['Skill:' .. (entry.skillName or '')]
                    local rec = get_recipe(entry.itemName)
                    if skillSec and rec then
                        printf_log('Queue: starting %d/%d - %dx %s', state.currentQueueIndex, #state.queue, entry.qty, entry.itemName)
                        state.pendingJob = {
                            action = 'craft',
                            skillSection = skillSec,
                            recipe = rec,
                            quantity = entry.qty,
                            disposal = entry.disposal,
                            kitPack = KIT_PACK_DEFAULT,
                            stopOnTrivial = entry.stopOnTrivial,
                        }
                    else
                        printf_log('ERROR: queue entry %d invalid (%s) - skipping', state.currentQueueIndex, entry.itemName or '?')
                    end
                else
                    printf_log('Queue complete! %d jobs finished.', #state.queue)
                    state.queueRunning = false
                    state.currentQueueIndex = 0
                end
            -- If running leveling plan, check skill and advance
            elseif state.levelRunning and not state.stopRequested then
                local entry = state.levelPlan[state.levelCurrentIndex]
                local firstSec = entry and (state.iniSections or {})['Skill:' .. (entry.skillName or '')]
                local eqSkill = firstSec and firstSec.Skill
                local curSkill = eqSkill and skill_value(eqSkill) or 0

                -- Skill cap: stop when the skill can no longer rise. Ceiling = the character's
                -- REAL, illusion-proof SkillCap (a class may cap a skill below 300, e.g. Brewing
                -- 200), floored by any PATH_MAX_SKILL, never above the hard cap. MUST match
                -- run_engine's in-combine check (it reads Me.SkillCap too) or this loop re-queues
                -- the same recipe at cap and grinds forever - the "prints 'stopping' 300x but keeps
                -- going" bug. Burning limited farmed mats on combines that can't raise skill is waste.
                local cap = state.level_skill_ceiling(eqSkill, entry and entry.skillName)
                local atCap = curSkill >= cap

                -- Pick the next recipe to craft, implementing the dropped-mat rule:
                -- "do we have the items for this recipe? if so craft it; if not,
                -- move to the next higher recipe; until the cap or out of mats."
                -- We re-evaluate from the CURRENT index (not index+1) so a recipe
                -- with pelts still on hand keeps going instead of being abandoned
                -- when a batch hits the size cap before the mats run out. A recipe
                -- qualifies only if it's still below trivial AND has >= 1 combine's
                -- worth of dropped mats (vendor-only recipes always pass the mat gate).
                local nextIndex = nil
                if not atCap then
                    for i = state.levelCurrentIndex, #state.levelPlan do
                        local cand = get_recipe(state.levelPlan[i].itemName)
                        if state.levelPlan[i].trivial > curSkill
                           and not (state.levelSkip and state.levelSkip[state.levelPlan[i].itemName])
                           and dropped_combines_available(cand) >= 1 then
                            nextIndex = i
                            break
                        end
                    end
                end

                if not atCap and not nextIndex and state.levelSupplyFromGroup then
                    nextIndex = state.level_group_select(curSkill, group_check)
                end

                if atCap then
                    printf_log('Reached %s skill cap (%d) - stopping to save materials.', entry.skillName, cap)
                    -- Terminal exit: no next recipe, so sell the whole leaving tree rather than
                    -- carrying its leftovers into the next skill path. (User stop is NOT handled
                    -- here - a manual stop leaves the bags exactly as they were.)
                    state.sell_between_recipes(entry, nil, nil, firstSec)
                    state.levelRunning = false
                elseif not nextIndex then
                    printf_log('Leveling done at %s skill %d (out of dropped mats or all remaining recipes are trivial).', eqSkill or '?', curSkill)
                    state.sell_between_recipes(entry, nil, nil, firstSec)
                    state.levelRunning = false
                else
                    local nextEntry = state.levelPlan[nextIndex]
                    local skillSec = (state.iniSections or {})['Skill:' .. (nextEntry.skillName or '')]
                    local rec = get_recipe(nextEntry.itemName)
                    if not skillSec or not rec then
                        printf_log('ERROR: level plan entry %d invalid - stopping.', nextIndex)
                        state.levelRunning = false
                    else
                        -- Moving to a NEW recipe: sell the leftover VENDOR mats from the old one so
                        -- they don't eat bag space for the rest of the run. Covers the whole tree
                        -- (subcombine mats + intermediates), not just the top recipe's direct
                        -- ingredients - that's where the clutter actually accumulates. Returned tools
                        -- and dropped/farmed mats are never sold. Anything the NEXT recipe's tree
                        -- needs is KEPT, so we don't sell a stack and re-buy it a minute later.
                        state.sell_between_recipes(entry, nextEntry, rec, firstSec)

                        state.levelCurrentIndex = nextIndex
                        printf_log('Leveling: skill %d → %s (trivial %d)', curSkill, nextEntry.itemName, nextEntry.trivial)
                        local batchSize = level_batch_qty(rec)
                        if nextEntry.maxBatch and batchSize > nextEntry.maxBatch then
                            printf_log('Ingredients do not stack - limiting to %d per batch.', nextEntry.maxBatch)
                            batchSize = nextEntry.maxBatch
                        end
                        state.pendingJob = {
                            action = 'craft',
                            skillSection = skillSec,
                            recipe = rec,
                            quantity = batchSize,
                            disposal = nextEntry.disposal,
                            kitPack = KIT_PACK_DEFAULT,
                            stopOnTrivial = true,
                            leveling = true,   -- leveling-tab run: no trophies
                            -- Reading A: when group supply is on, run_engine fast-checks the group for
                            -- THIS rung's items only (the one we're about to craft) and pulls what
                            -- members have - never speculatively for later rungs, so bag pressure stays
                            -- to just the current combine. Same fast /ts_check path the Craft tab uses.
                            supplyFromGroup = state.levelSupplyFromGroup,
                            supplyMode = state.levelSupplyMode,
                        }
                    end
                end
            end
        end
        if not state.pendingJob then
            state.restore_kit_pack()   -- run's done: put the slot-10 bag back where it started
            mq.cmd('/e3p off')   -- nothing else queued -> hand the toon back to E3
        end
    end
    mq.delay(10)
end

pcall(function() mq.unbind('/tsui') end)
pcall(function() mq.unbind('/tsreq') end)
mq.imgui.destroy(scriptName)
