# LazCraft notes

## Running
- The window (crafter): a strip on top that is always there - the job, its preflight, Go / Cancel, Pause / Stop -
  then tabs. Craft: a tradeskill dropdown lists that skill's recipes, lowest trivial first (old recipes take
  their container's Skill= from containers.ini); typing narrows it (words in any order, or an id); pick one, set
  combines (it shows what they make: 5 combines x 10 each = 50), choose what happens to the product (Keep, Sell,
  Destroy), then Plan or Make. Command: `/lc make <combines> [keep|sell|destroy] [trivial] <recipe>`.
  Leveling: a skill dropdown (with your value); its skills.ini path, one row per recipe (trivial, container, id; a
  recipe with several variants has a picker), each with its own combines, product choice (the rung's by default)
  and Make. A leveling Make stops at that recipe's trivial. On top, the skill in big colored text (value / cap) with a bar
  naming the next row; rows you are past are greyed out with their controls off, the next row is marked.
  Your own path: X takes a row off (a skills.ini rung stays off until Restore path); "Add a recipe" finds any recipe
  of that skill (2+ letters) and adds it by its trivial, sold by default. Saved per character in
  settings/LazCraft_<Name>_paths.ini (Add=<id>, <keep|sell|destroy> / Remove=<rung>); /lc level uses it too.
  Clean up (each row): that recipe's leftovers, by hand after a Go. The preview lists every item: the product is
  sold here (DESTROYED only when the merchant will not take it AND the item data gives it no sell value);
  ingredients a merchant sells are sold; farmed ones (ore, gems, drops) and tools are never touched; anything
  another row not at its trivial still needs is kept. A product stack in the Ammo slot comes off first.
  Estimates: under the skill bar, what the whole path still takes; on each row not done, "to trivial ~N combines,
  ~Xpp" (to the cap when lower). Combines a point come from data/rates.ini (shipped, from the logs) plus
  settings/rates.ini (shared by every character, learned from each Make that raises the skill): the recipe's own
  rate once it has 3+ points, else runs of any recipe within 25 of that skill, else a guess marked "?". Cost is
  the plan's merchant price a combine; "+ drops" when some ingredient has no price. A row's Combines start at
  that estimate plus a tenth (2.42.3; one pass for most rows, a repeat pass covers bad luck; the bags still cap a pass); a count you type stays.
  Research: the 66-70 spells and tomes of data/research.ini by class (yours first), level and type. Each row says
  held (bags + bank) and scribed (a spell this character has); Make, or Make all shown (every row not held, Qty
  each). Qty is spells in hand: what is held counts, the rest is made round after round - a failure is bought
  and made again - until held, or a round makes none. Command: `/lc have <n> <recipe>` does the same for any
  recipe. Raw parchments are drops: the supply phase asks the network for them.
  Radix (2.46.0): its own tab - the skills.ini [Collection:Radix] recipes in two sections: Precombines (Precombines=:
  Flask of Fruit Juice, Fizzlepop, Barbecue Ribs, Baked Potato - low trivials, never a Draught) and the Essence Fusion
  Chamber with what goes into it (trivials 400-500, from recipes_local.ini). Each row: trivial, held (bags + bank), and
  for the Chamber section a Draught tick. Ticked: a Draught of the Craftsman (skills.ini Draught=, its buff DraughtBuff=) is clicked before each
  combine of that recipe, so a failure gives the ingredients back - one attempt a Draught. Its cooldown (a minute) is
  waited out rather than combining unprotected; none left stops the run before that combine; ticked with none at Go
  does nothing. Still up after a combine: used for the next, no new click (the log says so). DraughtOn= ticks recipes
  at first (the Essence Fusion Chamber), OneAtATime= makes one per Go. What Radix makes is always kept, never sold or
  destroyed; every make shows its plan and waits for Go. Command: `/lc radix <n> [draught|nodraught] <recipe>`.
  Bank tradeskill gear (2.46.0; was Bank trophies, Settings > Money): for when the crafting is done - every trophy and
  leveling aid (skills.ini Trophy=, Clicky=), every tool recipes hand back more often than they use up (File, Smithy
  Hammer, needles, knives; not Empty Vial or Copper Sheet), and every empty tradeskill kit inside a bag go into this
  zone's bank. A kit in a pack slot stays (a bag in use); a kit with anything in it stays, said, with every kit of
  its name. A queue with entries: nothing happens. Command: `/lc bankgear` (or banktrophies).
  A kit never goes by Auto Bank, which would not take it and with no room swapped a bank bag out onto the cursor
  (2.46.2, Mortician's log). As the old LazCraft did: the first EMPTY slot inside a bank bag big enough for it
  (bags nest on Lazarus), read empty again just before the click; else an empty top-level bank slot (2.46.3). No room:
  the kit stays in the bags, said; anything that comes out of the bank goes straight back.
  Queue (under the Craft and Research lists - one queue shown in both): "+ Queue" on the picked recipe (its
  combines and product choice) or on a research row (Qty in hand; "Queue all shown" for the list). Entries
  have a count, Up, Down and X; Run queue makes them one after another under one Go (the network asked once at
  the preflight), and a finished entry comes off. A craft entry is combines, as Make; a research entry is
  spells in hand, failures made again. Saved per character in settings/LazCraft_<Name>_queue.ini. Nothing runs on by itself. Summon:
  every producers.ini item by group, who can make it (me and/or workers); Make casts it here, a worker's button
  orders it from them. Workers: the cards, Ask, Start a worker by name. Log. Travel: a button per travel.ini zone.
  Settings. Every button only queues a job; Make, Plan and Travel wait for Go in the strip.
- Crafter: `/lua run lazcraft`
- Worker: `/lua run lazcraft worker <crafter>`
- Commands: `/lc show | hide | test | go | cancel | pause | resume | stop | log on|off|debug|info | quit`
- Block checks: `/lc inv <item>`, `/lc pickup <n> <item>`, `/lc stow`, `/lc close <window>`, `/lc bag <n>`,
  `/lc bagtest <times> [gap <ms>] <item>` (repeats a 5-item split from a closed bag and reports timings and lost clicks;
  if clicks stop being taken it probes every 100ms and logs how long they were ignored and after how many moves)
  `/lc navtest <trips> [dist <n>] <npc>, <npc>` (travels between the NPCs in turn: arrival distance, open the merchant,
  confirm it is that merchant and its list arrived, close; default dist 10)
  `/lc buytest <times> <n> <npc>, <item>` (goes to the merchant, then buys n and sells n back each time, confirmed by the bag count)
  `/lc combinetest <times> <kit>, <product>, <ingredient>, ...` (kit in a top-level slot and empty; places one of each
  ingredient in slot order, /combine, stows what comes back, checks the kit is empty)
  `/lc stationtest <times> <station>, <product>, <ingredient>, ...` (finds the nearest station by its clickable name -
  Forge, Oven, Brewing Barrel - goes to it, opens it, places one of each, /combine enviro, stows, checks it is empty)
  `/lc banktest <times> <n> <item>` (goes to the nearest banker, opens the bank, takes n out and puts n back each time)
  `/lc withdraw <n|all> <item>`, `/lc deposit <n|all> <item>` (nearest banker, open, move, close)
- Planning: `/lc plan <combines> <recipe name, label or id>` shows the whole plan (tree, bank pulls, buys by zone and
  merchant, combine order, route) as the preflight. A name with several recipes lists them; pick one by id.
- Making: `/lc make <combines> <recipe>` - the plan as the preflight, then on Go: plan again (blocks if anything
  changed), then the route zone by zone (travel, the bank trip in the bank zone, one stop per merchant), then
  every step in order (subcombines first) at its kit or station, N combines each, report per step. A step that runs
  short (earlier skill failures) stops there and the next steps make what they can; the report says what ran out.
- Travel: `/lc travel <zone short name>` - the hops from travel.ini as the preflight, then each hop on Go.
- Workers: `/lua run lazcraft worker <crafter>` on the other character, or `/lc worker <name>` from the crafter.
  The crafter's Workers tab (and `/lc workers`) lists each worker's card: zone, idle/busy, what it can cast.
- Fetch (test): `/lc fetch <worker> <n> <item>` on the crafter - the worker comes to you (any zone travel.ini reaches) and trades them over.
- Order (test): `/lc order <worker> <n> <item>` on the crafter - the worker gets them (bags, bank, buy, make, cast, as
  the planner would for you), says how and what it is doing, then comes and trades them over.
  Item names: exact in any case, or the one name holding every word typed; several matches are listed to pick from.

## Data
- `data/recipes.ini`: one section per RECIPE (id-keyed): Name, Label (variants), Container, Containers (all the
  page lists), Skill, Trivial, Yield, In (used up), Tools (come back from every combine), FailBack (used up by a
  success, given back by a failure), Also (made as well). H ids come from the Lazarus Alla harvest
  (`tools/parse_harvest.py <lazarus_cache> <out> containers.ini [old recipes.ini]`); O ids are the old converted
  data (`config/recipes_converted.ini`), kept only where the harvest has not reached or hides an ingredient.
  `data/recipes_local.ini` adds or replaces recipes by id.
- Product disposal (2.21.0): Destroy takes the product off the cursor as each combine hands it back (never a
  subcombine, a tool or salvage, never anything already in the bags); Sell sells what the run made at the nearest
  merchants.ini merchant in the zone - at the end, and mid-run when the bags are down to 3 free slots (an open
  kit's own slots do not count); Keep stops a run that fills the bags, with the reason. Stop at trivial reads the
  skill (skills.ini EQSkill=) before each combine of the recipe; the skill is logged at its start and end.
- Harvest facts: "Returned on Fail" + listed under Creates = a tool; "Returned on Fail" alone = FailBack. Alla hides
  items nobody has discovered ("Undiscovered Item"). A hidden ingredient is filled from the old data when exactly
  one old recipe for that product has every visible item plus as many others as are hidden (`Filled=` shows which);
  otherwise the recipe is not used. A hidden product is taken from the recipe's name.
- Harvest as of 2.19.2: 12,580 of 21,801 recipe pages -> 10,605 H recipes, plus 6,719 O kept (17,325 with local).
  A page names a container by its game label; containers.ini Names= maps those (Baking = Oven, proven by Rat
  Kabobs in game; Tailoring = Sewing Kit, from the old data). Containers no section knows yet are listed at the
  end of parse_problems.txt; their recipes block at the preflight until one is added. Cultural sewing kits
  (Erudite, Feir`Dal, Vale; Worn works the same) are their own kits, used only by their own recipes; Marble and
  Collapsible Mortar and Pestle work as a Mortar and Pestle. Recipes made only in the class research books are
  left out (containers.ini Type=skip; spells are bought to 65 on Lazarus) - 314 of them, 280 of whose spells
  have a Spell Research Kit recipe anyway. Left for later: 94 recipes with a single unknown container.
- `data/merchants.ini`: MerchantScanner's format ([Npc##zone] _Zone=, item=1).
- `data/items.ini` (2.27.0, `tools/parse_items.py` from the Alla item pages): each item's Alla id, value, and the
  merchants that sell it, with prices, in the zones `tools/zones.ini` maps (the ones travel.ini reaches). Those
  merchants join merchants.ini's (4,477 more); the plan shows "Cost: about ..." from these prices (a guide - the
  real price depends on charisma and faction). Items no merchant sells are made (a recipe), summoned, or farmed
  (drops, forage, fishing, quests) - the plan says which. Drops are not in the pages (the site loads them later).
- `data/travel.ini`: zone hops ([from>to], How=aa|say|door), [Bankers] Zones=, and [Arrive] <zone>=<npc or y x z>
  (where to go first after zoning in). The hops are data: edit or add one without touching code.
- Planner rules: own storage first (bags, then bank); buy what is sold (never craft what can be bought); else a
  subcombine (best-supplied recipe); else a held item, which blocks the plan if bags + bank do not cover it.
  "make N" = N combines. Subcombines deepest first, grouped by container. Shopping (2.25.0): every set of up to
  3 zones that sells it all is tried; the fewest zone changes wins (here -> shopping zones -> a zone with the
  stations; staying put is 0), then the fewest merchants (one that sells everything, then two, else greedy).
  On arrival the merchants are visited nearest first; a planned one that is not up, or farther than another
  here who sells the same items, is swapped; one that does not sell an item after all hands it to another here.
- `data/nav.ini` (2.23.0): per zone, the old LazCraft's ways around geometry - PoK hubs and the merchant pocket,
  the Plane of Marr side docks, and the Thurgadin/Felwithe merchant spots (header in the file says how each
  works). Every walk (go_spawn/go_loc) in a listed zone goes through blocks/routes.lua first: docks, pocket,
  hubs (leave through the one we stand in, approach through the destination's), then a merchant's spot. Each
  leg is logged; one that cannot be reached is said and the walk goes on. A player is never sent to a spot.
  Every stuck spot is appended to `logs/navstuck.log` (kept across runs): where to add the next hub.
- Repeat to trivial (2.23.0, Leveling rows and `/lc make N repeat <recipe>`): the whole run is one pass;
  passes go on, each planned fresh (buy again), until the skill reaches the trivial. Ends early with the reason
  only when a pass makes no combines; 100 passes at most. Every trivial stop (2.23.2) is the trivial or this
  character's cap for the skill when lower (Me.SkillCap, never above 300 - the old LazCraft's rule); the
  Leveling tab shows a cap under 300 and greys rows past it.
- Bags (2.24.0): how many of an item fit in one slot comes from `data/stacks.ini` (2.26.0: every item a recipe
  uses, 9,236, from the Alla item pages - `tools/parse_items.py`; Ruby and Mushroom are two items each that
  stack differently, so left out) and what the game shows - a merchant window, a stack in the
  bags - learned into `settings/stacks.ini` (shared by every character, never replaced by an update; it
  wins). Before shopping the plan counts the new slots it takes; when the combines asked for do not fit it
  makes the most that do and says so (a pass of repeat to trivial the same). At each merchant: stackables
  first, non-stacking items last, each buy cut to what fits (keeping a slot for each item still to buy).
  An item nobody has seen yet counts one slot until its merchant shows the truth. Later: one merchant
  scan over every harvested ingredient fills the list in.
- Stow (2.33.0): /autoinventory takes 0ms in game, but right after a combine the client can ignore it for over
  2s (2.27.0 and 2.32.0 logs; the same command in cleanup took at once). A stow is sent again every 500ms,
  for up to 6s, before it gives up.
- Delivery (2.33.3): the crafter's 'come' carries where it stands (y x z). The worker walks there with /nav loc
  first - a far character's spawn is not kept up to date and /nav id to it has no path (2.32.0 logs: 534 and 427
  away) - then finds the crafter's spawn close by and trades.
- Console lines (2.33.2): capped at 600 characters (" ... (the rest is in the log file)") - the game's chat line has
  a fixed buffer and a 12-row path summary (~3,000 characters) took the client down as it printed. The file
  gets every line in full, and is written before the console. A path's summary is a count; each row logs its own.
- Not ours (2.33.1): something on the cursor this step did not put there (a mouse program, a click by hand -
  2.32.0 log: a Brazier, a stack of brews) is put away and said ("... is on the cursor (not ours)"), and the
  step carries on: before a pickup, a bank withdraw, a combine, a kit move, taking gear off. A pickup that got
  something else instead (it landed during the click) is tried again, up to 3 times.
- Combine (2.33.0): a /combine with no answer after 1.5s while the container still holds exactly what it did is
  sent again (2.32.0 log: one went unanswered for 5s); a container that changed is never combined twice.
- Stations (2.29.0): a station step tries this zone's stations from containers.ini (At= lines) - the one that
  worked last in the run first, then nearest first. "Someone else is using that" is clicked once more (the old
  LazCraft found it also fires for a stale one with nobody there), then the next one; nothing waits on a busy
  station. All busy here: the next place with that station, fewest hops first - this zone's AFK mirror
  (travel.ini [Mirror]: Lazy Lady Linda, "enter"; confirmed by the zoning or "You have entered"), then other
  zones and their mirrors - until one opens; none: the job stops naming the places tried.
- Trophies (2.30.0, skills.ini Trophy= then Clicky=): per skill, best first, the tradeskill trophies then the leveling aids
  (the old LazCraft's tables). The plan picks the best one worn, in the bags, or in the bank (taken on the bank
  trip) and says so; none is fine. It is worn in Ammo before the skill's first step (blocks/gear.lua); what
  was in Ammo goes back at the end. An item the plan uses itself (a Smithy Hammer tool) is never worn.
  `/lc banktrophies` (Settings tab button) banks every one in the bags.
- Money (2.30.0): the plan's cost (Alla prices) against the coin carried - the Craft tab shows it as you pick,
  the Leveling rows show it per row (or per pass), the preflight blocks when it is short, and each pass of
  repeat-to-trivial checks again and stops with the reason.
- Leveling path (2.31.0): Run path (Leveling tab) / `/lc level <skill>` makes each row with repeat to trivial,
  one after another, under one Go (Make.chain); Run all skills / `/lc level all` goes through skills.ini
  [LevelAll]. A row already past is over at once; one that cannot finish is said and the path goes on. The
  preflight plans every row and says which will be passed as things stand (a farmed ingredient you lack).
- Workers tab (2.32.0): every character the network sees (DanNet's peer list, else EQBC's names) plus every
  worker heard from. Zones: a worker's card, else a DanNet query every 10s. In a safe zone (travel.ini [Safe])
  and not working yet: a Start button; Start all starts every one of those. Out in the world, or zone not known
  (E3/EQBC cannot be asked): greyed, no button - the Name box still starts anyone by hand.
- Tests (outside the game): `luajit lazcraft/tests/run.lua`

## Layout
| Folder | What lives there |
| --- | --- |
| `core/` | log, INI reading, config loading, job runner, E3 pause, result type |
| `blocks/` | one owner per game object. Built: inventory, windows, cursor, spawns, nav, routes, merchant, combine, kit, station, bank, travel, kitslot, cast, peers, trade |
| `engine/` | planner (works out a make), make (carries it out), crew (worker cards), handoff (fetching from a worker). To come: worker requests, leveling |
| `ui/` | the window |
| `data/` | shipped config: containers, skills, producers, lists (recipes and merchants come from the harvest) |
| `tests/` | fake game and tests |
| `settings/` | per-character settings, `LazCraft_<Name>.ini` |
| `logs/` | per-character logs |

**Every file LazCraft reads or writes lives inside `lua/lazcraft/`.** Nothing goes in the MQ config folder or anywhere else.
New kinds of file get their own folder here; tests clean up whatever they write.

Per-character settings: `lua/lazcraft/settings/LazCraft_<Name>.ini`, written on every start so it lists every value.
A file left in the MQ config folder by 2.00.6 or earlier is moved in on the first start, then deleted.
The window's **Settings** tab edits them live: a change applies at once and is saved straight away (no restart).
There is one pace setting, `ItemPaceMs` (default 0 = no wait): the shortest time from one item starting to
the next (a pickup, putting it in a kit, stowing). Time already spent counts, so it only waits the difference:
at 100, a 20ms pickup-to-slot waits 80 before the next item; a 130ms one waits nothing; nothing waits after the
last item. The log shows each wait and the resulting gap: `paced 66ms: 99ms between item starts (ItemPaceMs 100)`. The cursor block keeps it, since every item move starts there. Lost clicks are not paced away; the
click ladder (re-click next frame, then reopen the bag) handles them.
The game only acts once a frame (about 33ms at 30fps). A pace ends on the frame nearest its target, so it is never
more than half a frame off either way and averages exactly what is set. Waits for something to happen end the moment it does.

Logs: `lua/lazcraft/logs/LazCraft_<Name>.log`, on by default (every report is read from it); the previous session is kept as `.prev.log`.
The file gets every step (each command sent, each confirmation with how long it took, a state snapshot when something fails);
the console shows normal messages. `/lc log debug` shows every step in the console too, `/lc log info` goes back, `/lc log off|on` stops or starts the file.

## Rules
1. Blocks act, then confirm, and return `R.ok(...)` or `R.fail(why, detail)`. Nothing throws to signal a normal failure.
2. Only a block's owner touches its game object.
3. Every wait goes through `ctx:wait` / `ctx:pace` / `ctx:checkpoint`, so Stop and Pause land at safe points.
4. Pacing is a setting and is exact: `ctx:pace(75)` waits 75ms, nothing is added on top.
5. Commands and the window only set flags or queue jobs; the main loop does the work.
6. The job runner owns the E3 pause. After /e3p on it waits for a cast E3 already began to finish (bags do
   not open while casting - 2.12.1 in game), up to 15s, then /stopcast, confirmed.
7. No globals and no game data in code: data comes from `data/`.
8. Desync handling is designed on its own later; no workaround delays in the meantime.
9. The client shows the result of a click in the same frame (logs read "after 0ms"). A click that changed nothing by
   the next frame was lost, so it is sent again, up to 3 times. If the bag still ignores clicks, it is closed and
   reopened (up to 3 times). Fix it and move on: no fixed waits stand in for this, so a slow connection never
   slows down a fast one and no uncounted pauses build up.
10. Nothing is carried over from the old LazCraft just because it was there. Only the plain way to use the game's API
    and checks that confirm a result come across; a fix comes back only when a log shows the problem it fixes.
11. A job that touches the toon has a cleanup step that leaves it tidy however the job ended (done, failed or stopped).
12. What a combine hands back comes onto the cursor one item at a time, with gaps (Rat Kabobs: the returned
    Skewers first, the kabob 165-343ms later). The recipe says what to expect: a success brings the product
    (yield) and the tools, a failure brings the tools. The combine is over once those are in the bags (a
    condition, capped at 3s, so it never hangs). Something that never comes back is logged; if it was a tool,
    the next combine stops the step short ("out of Skewers"). Each failure logs what came back, named as
    tool, salvage or other. Known game behaviour (Jacob): tools always come back from a failure; salvage is
    a chance of getting one of the ingredients back (or nothing), so "other" is warned about.
14. A tool is needed once per plan (it comes back), and is found like an ingredient: bags, then a bank pull,
    then buy, then make (2.06.3: a File in the bank was counted as on hand, never pulled, and Studs stopped).
13. Salvage is chance, so it is not waited for. Anything that lands on the cursor after a combine is over is
    stowed before the next pickup or combine and logged. A pickup never clicks with something on the cursor.
    Before a combine is fired, the container must hold exactly what was placed, slot for slot.
15. Travel: a hop is done when the zone has changed and the client is in game again, then the navmesh is loaded
    (a check, not a settle delay), then the zone's arrival spot. Every wait has a cap. An AA is fired standing
    still and not casting, once; never again mid-cast; again only if the cast never started or was interrupted.
    A porter is targeted before the nav to it (in game: a /say right after /target is ignored) and spoken to
    once arrival is measured; the keyword is said again if nothing happens. Seen in game: a porter or a stone
    zones us about 3-4s after the say or click; Marr's Calling shows as casting 82-322ms after /aa act and
    zones us about 10.5s later. A door is clicked again only while still in the old zone with nothing under way
    (a click toggles).
16. Kits: a kit already in any top-level slot is used where it is. Otherwise it goes into pack10 (the last bag
    to fill): pack10 empty -> in; an empty bag or kit there -> swapped (it takes the kit's old spot); a bag
    with items -> its items go one by one into free slots in the other bags, then the swap; a single item ->
    stowed. A bag a slot refuses (too small) goes to another free slot that fits. At the end, done or not, the
    original pack10 bag goes back in pack10 and every kit back where it was found; the items emptied out of
    it, or a single item that was in pack10, stay where they landed. The slots are read afterwards: "put back"
    is only logged when it is true. In game, a stack clicked in an open bag asks how many; the whole stack is
    accepted. The bag that started in pack10 can itself be a kit a later step needs (2.09.0: Tackle Box).
    Before anything goes into a bag, the bag is checked first: too small for it (Size vs SizeCapacity), or a
    tradeskill-only bag (lists.ini TradeskillOnlyBags: Artisan's Adept Attache) and not a tradeskill item ->
    straight to a slot that takes it. A refusal looks like a lost click (2.12.0: 12 clicks, 3 reopens of
    pack2 for a Rucksack it could not hold), so it is never tried.
17. Bank deposits: the exact amount is picked up from the bags, then the bank window's Auto Bank button
    (`/notify BigBankWnd BIGB_AutoButton leftmouseup`): the client picks the slot, topping up stacks of it
    first, like /autoinventory for bags. Confirmed by the cursor emptying and the bank count; pressed again only
    if nothing left the cursor; if it never does (bank full) it goes back to the bags with the reason.
18. A kit the plan needs but you do not carry comes from the bank on the bank trip (any variant; BuyOrder
    variants first), else is bought: the first variant in containers.ini's BuyOrder sold somewhere travel
    reaches. It is kept in the bags afterwards (a "bank all tradeskill items" job comes later). None of those
    blocks the preflight with the reason.
19. Producers (producers.ini): an item is found in storage, then bought, then made by a subcombine, then cast
    (Jacob's order: casting takes a while). A cast is planned only when this character has the spell scribed
    (the book, not the class). An item can have several spells (producers.ini: Spell=<spell> | <amount> |
    <reagents>, one line each - metals and clay: Enchant 1, Mass Enchant 5, Greater Mass Enchant 20, Superior
    Mass Enchant 100; Superior Mass Enchant Velium is confirmed). The ones this character has are used biggest
    first without making more than needed (30 = 1 x 20 + 2 x 5); only when nothing smaller is scribed does a
    big one make extra. Each cast uses its reagents in full. A cast that makes a different amount from the data
    is warned about once. The cast block: a spell already memorized is cast
    from its gem, else memorized into gem 8 and the gem read until it shows it; sit below 30% mana and stand
    above 90%; cast only standing, still and with the gem ready; wait the cast out, then stow the product from
    the cursor; a fizzle or interruption is cast again within casts + 10. Other characters casting for you
    (workers, trades) is Phase B.
20. Workers (Phase B), the AdventureTime way: each side says what it knows, nobody polls (no /dquery). A worker
    sends its card (zone, idle/busy, what its spellbook can cast) to its crafter on start, when its zone or
    idle/busy changes, and when the crafter says hello; bye on exit. The crafter says hello on start to every
    worker it remembers (settings Workers=) and to the group; one that has not answered 3s after a hello shows
    as not answering. `/lc worker <name>` says hello first and runs LazCraft there only if no card comes
    back in 3s (an old card proves nothing after a /lua stop). Messages are `/lc_<verb> <from> <args>` with names encoded (spaces, apostrophes, commas;
    '-' = empty). Network: Auto = DanNet, then E3, then EQBC (AdventureTime's detection); no plugin is loaded
    for you. Every message in and out is in the log. Phase B decisions: the crafter casts it itself when it can,
    else asks a worker; a worker gets its own reagents (money check later); only the amount needed is handed
    over (a choice of all or X later); the worker comes to the crafter (travels to its zone, walks over) and
    hands it over; the crafter stays put.
21. Trades (worker gives, crafter takes): the crafter stays put and sends come <id> <n> <item> <zone>. The
    worker answers at once (coming), travels to that zone if it is not there (travel.ini), walks to within 10,
    and says where it is every 10s on the way; 30s without a word from it = it is not coming. On arrival it
    says arrived, targets the crafter (within 15), loads up to 8 stacks (exact amounts; the drop is Target_HP,
    then /click left target if the cursor still holds it - which one worked is logged), then says loaded <id>
    <k> <units>. The crafter clicks Trade only after loaded (no fallback timer) and says accepted; the worker's
    click completes it. Done = the crafter's count went up by the units, then it says got. A failed request
    is cancelled (items go back to the worker) and tried once more for what is missing, unless it cannot work
    (no way there, out of the item, went quiet). A confirmation box after Trade is reported, not clicked.
    Every message carries the request id.
22. Orders (B3): the crafter sends ask <id> <n> <item>; the worker queues a get job (the planner's plan_item:
    the item is found like an ingredient - bags, bank, buy, subcombine, cast - with a gather step that does
    nothing in game), answers yes with how, or no with the first problem. While queued or working it says what
    it is doing (its job status) on every change and every 10s; 30s of silence = stopped. Done: made <id>
    <have>, and it holds them; the crafter then fetches (rule 21). A crafter that calls a request off stops
    that job on the worker (running or queued); the rest of its queue carries on.
23. Workers in a make (B4): an item made by casting is cast by this character when it has the spell; else by
    a worker whose card lists it (answering, idle ones first) - exactly the amount needed, its own reagents
    (we buy none); else the plan blocks. At Go the order goes out before the route, so the worker works while
    we bank, shop and craft. Just before the first step that needs it we wait for made, it comes, trades.
    Stopped or failed: open orders are called off. A job stopped mid-cast stops the cast (/stopcast): an
    interrupted cast uses no reagents, and nothing lands on the cursor after the job is gone.
24. Supply (2.34.0): an item we are short of that no merchant sells and no recipe makes (ore, a drop) is asked
    for on the network (DanNet /dquery to everyone: zone, FindItemCount, FindItemBankCount; one question at a
    time per character - DanNet hands back the last answer whatever the question - up to 6s; an answer counts
    only when QReceived moved on). At the preflight, and again at every pass after the first (the first pass
    after Go uses the preflight's answers - 2.40.3). A NULL count goes to the end of that character's questions
    (asked straight again, 25 of 40 never came back and held up the rest). An item a character did not answer
    for keeps its count from the last survey, else it is named as not answered - never "nobody has it".
    Who brings it:
    someone in a safe zone (travel.ini [Safe]) - one who has it all, our zone first; else the fewest
    characters, most first. That character is said hello and, if no card comes back, LazCraft is started
    there as our worker (30s for its card); then it is ordered like rule 23 (its bags first, then a bank
    trip) and brings it to the spot we stand on. Nobody in a safe zone has enough: the plan blocks, naming
    who has it elsewhere and where. Without DanNet nobody is asked (said once).
    Dear items (2.38.0): an ingredient a merchant sells for more than Settings > "Ask the network first over"
    (RequestOverPP, default 20pp a unit, Alla's price; 0 = off) is asked for the same way before buying; what
    the network has in safe zones is brought, the rest is bought.
    Who (2.39.1): characters already working for us first, then our zone, then the most held. One that does
    not come up as our worker (30s) is left out for the session (until it sends a card) and the plan is made
    again with the others. All of this happens before any travel or shopping.
    Collecting (2.39.2): workers never travel after us. A worker in another zone is collected in its zone (we
    go there first); one in our zone before the route leaves it, or - when the route stays here - just before
    the step that needs it (it works while we shop).
25. Salvage (2.35.5): the Salvage AA hands back an ingredient of a failed combine 48-115ms after the rest, with
    no chat message. Left alone it lands while the next combine is being placed and the client and server
    disagree on a slot (the old LazCraft's desyncs). After every failure the cursor is watched SALVAGE_MS (300)
    more; a combine refused although everything showed placed is cleared and placed again once.

26. Marr (2.39.3): the first walk in a zone with a travel.ini [Arrive] spot (Marr: Soulbinder Tomas, off the
    fountain) goes there first and straight - no docks - unless within 30; once per visit (a zone change or
    the AFK mirror starts a new one), crafter and worker alike. After that every walk across the X sign takes
    both side docks (2.40.2, the old LazCraft's rule: limited to "within 100 of a dock", the walks from Tomas
    went round the four pillars and through the water). nav.ini SideDocks' third field can still limit it.

27. Summoned items (2.41.0): summoning is delivering that takes longer. At Go, every item a worker makes with a
    spell that the whole job needs is ordered from its caster at once (handoff 'summon'), 1:1 with the counts
    asked for: each leveling row not at its trivial its Combines (lowest row first), each queue entry its count,
    a Make its combines - less what the crafter holds (bags and bank; the plan counts them). What the worker
    already holds counts too: it casts only the rest (2.41.1). The worker works it in rounds - reagents for as many casts as fit in its bags, bought
    with its own coin (checked first: short = the order ends, "not enough money"), then cast. Anything else in
    its queue (a delivery, an order) goes first: between casts and while meditating the round stops and the
    order goes back behind it. Bags full: it waits until a give frees room. Every 'working' word carries its
    count of the item; a pass takes what it needs as soon as the worker holds that many (waiting, with the count
    shown, only while it does not); an order that ended with fewer: the pass orders them as before. At the end
    (or Stop) the rest is called off; what was made stays with the worker and the next plan counts it. The
    Workers tab shows each open order (held, taken, ordered, what it is doing).
28. One visit (2.41.2): when a pass takes an item from a worker, every other item of that pass the same worker
    has ready (an order made, or a summon order holding enough) is taken right then too, while it stands next
    to us; one not ready yet is collected before its own step. AFK mirror: it has the same short name, so a
    worker could walk to the crafter's spot in the zone while the crafter stood in the mirror (2.41.1 log). The
    mirror has an "Exit Portal" NPC; travel:in_mirror() looks for it. A 'come' says whether the crafter is in
    the mirror; a worker outside it goes in first (travel.ini [Mirror]); one inside it with the crafter outside walks into
    the Exit Portal, which ports it out (2.41.3), then the arrival spot (Marr: Tomas) as after any zone-in.
29. Worker versions (2.41.4): a running Lua keeps the code it started with, so a worker not restarted after an
    update runs the old code (2.41.x logs: Shela on 2.40.2 an hour later - no summon orders). Its card carries
    its version; the crafter warns once per version seen, and the Workers tab shows it with Restart (/lua stop
    there, then the usual start). Arrival spot (Tomas): only after zoning in - the zone LazCraft starts in
    is not a new visit (2.41.3 log: Shela walked 408 to Tomas from the merchants at start).
30. Queues shop once (2.41.5): the queue, the Research tab and /lc have (Make.batch) take every raw item their
    entries need - from the bank and the merchants - in one route before making any of them (as many entries
    as fit in the bags; then the next group). Each entry then finds it all in the bags; what it still lacks
    (a failure ate it) it gets itself. Leveling paths still buy as they go, pass by pass. Each entry's needs are
    worked out once and added up (2.41.6: working the whole list out again per entry took 27s for 14 spells).
    The container stays open from one entry to the next - its bags too, and the kit stays in its slot; it is
    closed when the queue goes shopping again, changes container, or ends (2.41.6).
    Passes (2.41.7): a research entry whose combine failed (the failure ate the materials) is made again in
    the next pass, after the others, with every entry that failed - gathered in one trip again (up to 20
    passes). Only an entry whose job could not run (nothing to buy, ...) ends with the reason.
31. 2.41.8 (2.41.7 logs): a worker's summon orders never step aside for each other - only for a delivery or an
    order (Ejtou's two orders swapped places 300+ times and nothing was cast). A pass takes a summoned item from
    the order placed ahead whoever its plan picked (Emerald was ordered ahead from Ejtou, who held 875, then
    ordered again from Shylain). Supply: a character that answered only part for an item (bags but not bank) is
    not "has none"; when a plan is short of it, the characters that answered other questions but not that one
    are asked again (just them) before the row is passed (Shylain's 2162 Vial of Clear Mana in her bank).
32. 2.41.9 casters: the crafter remembers who casts what (settings/LazCraft_<Me>_casters.ini: each worker's last
    card, its class from the card or a DanNet query for one never started, and Lacks = started for an item and its
    card did not list it). A summoned item with no running caster goes to one that cast it before, else one of a
    class producers.ini names (Classes=) - not running, in a safe zone, not lacking it, not failed to start this
    session. The Make starts it like a supplier; a card without the item fails "missing spell" naming the spell
    (buy and scribe it there), is remembered, and the plan is made again without it. Summon tab: "could:" under
    each item with Start buttons (safe zone), and "spell not scribed on:". Workers tab: class and "cast before".
33. 2.42.0 faction, step 1: Thurgadin, Jaggedpine and Felwithe (travel.ini [Faction] Zones=) sell only with
    faction. Each merchant there is conned (/consider - the standard lines, confirmed for Lazarus; merchants'
    refusals differ, so the con is the check) before buying, and the standing saved per character per merchant
    (settings/LazCraft_<Me>_factions.ini). Apprehensively or better buys. Too low: saved, Marr's Calling out,
    the run fails naming the merchant; the next plan leaves that merchant out ("sold only by merchants your faction
    is too low with"). After shopping in a faction zone - bought or not - Marr's Calling straight out (crafter and
    worker alike). Northern Felwithe's route, from the old LazCraft: PoK Kelethin stone (a door with no Near: its
    own spot) -> Greater Faydark -> a run hop (walk to Near, face Heading, run until the zone line). Southern
    Felwithe has no route yet. Next: a worker with the faction buys it (step 2), then coin for the worker (step 3).
34. 2.42.1 (2.41.9 log): repeat to trivial sizes each later pass to the points left - the points at this
    recipe's rate (core/rates, just updated by the pass before) x1.25, at least 10, never more than the row (pass 2
    of Unfired Idol (Emerald) asked another 564 combines - 552 clay, 564 vials, 559 summoned emeralds - for 281 ->
    282; pass 1 had made 255 -> 281 in 564, ~21.7 a point against the 16.7 estimated). Each skill point is logged
    with the combines it took, the data for balancing the estimates.
35. 2.42.2 rates: the Leveling estimate is a skill-up model, not per-recipe averages. EQEmu's chance - p2 by the
    raw skill alone ((200 - skill)/2 % to 174, 12.5 - 0.08 x (skill - 175) % above), a failure 0.75 as likely to
    raise it as a success, success 95% from 10 under the trivial falling 0.85% a point - fitted to all 87 logged
    passes (6493 combines, 6 skills, 0 -> 300): K = 1.07 overall, each skill within 16% on rows held out. A
    character's own runs pull its factor per skill ((combines + K x 1000) / (model + 1000), settings/rates.ini
    [Factors] <who>|<skill>); learning fast from early rows did worse than K, so it moves slowly. The per-point log
    lines (2.42.1) are the data to refine the curve's shape next.
36. 2.42.3: row Combines = the estimate plus a tenth (was a quarter), a later pass the same: the model is close
    enough, and repeat to trivial covers bad luck with a pass sized to the points left.
    Unsold (2.42.2 log: the Stein row failed - merchants.ini and the Alla pages say Borik Darkanvil in Marr sells Jar
    of Lacquer; his 36 items there do not): a merchant whose complete list lacks an item the data says it sells is
    learned (settings/unsold.ini, every character) and taken out of the merchants list; a pass that hit one and
    found nobody else here selling it is planned again (up to 3 times) - the new plan buys it in another zone.
37. 2.42.4 faction, step 2 (2.42.3 log: Mithril Champion Arrows - one Felwithe trip per merchant, each too low, no
    worker sent). A con works from anywhere in the zone: every merchant on the zone's list is conned on arrival,
    no walking, all saved; any too low and nothing is bought, Marr's out, and the pass is planned again. A merchant
    too low for us is then bought from by a worker (world.buyer: one known to have the faction there, then one
    running, then one in a safe zone that can be started; never one known too low with every seller) - a supply
    order: it plans and buys itself (its own cons, Marr's after), comes back and trades. A worker's cons go to its
    crafter (peers 'faction'), so the crafter's factions file learns who to send; a worker too low as well is
    saved and the next one is asked. Coin for the worker is step 3.
38. 2.42.5 (2.42.4 log: Antilerd went to Felwithe for 1228 Large Brick of Mithril, came back, then went again for 2457
    Small Brick ordered at the same moment): a worker's order is planned with every other order still queued from
    the same crafter (each with a clean plan of its own, another item) - one route buys all of it; their own jobs
    then find it in the bags and say made at once.
39. 2.42.6: tradeskills this character cannot train - skill cap 0 (Me.SkillCap: Alchemy shaman only, Make Poison
    rogue, Tinkering gnome) - are left out of the Craft and Leveling lists and Level all; /lc level says why. Said
    once at start ("Tradeskills <me> cannot train (skill cap 0) ..."), so a log shows what was hidden.
40. 2.42.7 worker window: who it works for, what it is doing, Pause / Resume. A pause holds the job at its next safe
    point (never mid-trade: it holds once the trade is done) and starts nothing new; E3 is left as it is. The crafter
    is told - card 'paused', every heartbeat 'paused on <me> (by hand)' - and waits (it only gives up on silence).
    No close on a worker: the crafter's Close all (strip, /lc closeall) quits LazCraft on every worker, then here.
41. 2.42.8 rates (the Mithril Champion Arrows log, 202 -> 300 point by point): success is EQEmu's formula - skill -
    0.75 x trivial + 51.5 % (trivial 68+; else skill - trivial + 66), 5-95% - which the run matched band by band
    (6% at 205, 55% at 255, 94% at 295). A failure raises Fletching/Blacksmithing/Make Poison as often as a success
    (FAIL_UP 1: their third stat, no -15), the INT/WIS skills 0.7. K 1.04: every skill in the logs within 9% of it.
    AFK mirror (2.42.6 log: Mortician in Marr's, Shela in its mirror at the same spot, neither noticed - "not in
    freeporttemple" twice; no log ever showed the Exit Portal found): the portal is looked up as any spawn,
    ${Spawn[Exit Portal]} (what the user's /echo found), not only as an NPC; each check's result is logged on change.
42. 2.42.9 (2.42.6 log: Cobalt and Tungsten Ore on hand for 1 of 20 Alloy Reinforced Bank Vaults - 1 made, twice,
    while Antilerd and Shela held hundreds): a held item short for the whole count is asked of the network even when
    some is on hand - the survey covers what all the combines need, then the count is cut only to what the network
    and the bags together cover.
43. 2.42.10: a worker started with no crafter named (/lua run lazcraft worker) no longer quits (in game that looked
    like a crash): it waits - its window says so - and works for the first crafter whose hello comes (the crafter's
    start, or its Workers tab: Ask workers); a later crafter's hello is ignored, as before.
    Queues (2.42.8 log, a 32-spell research queue): the one-trip gathering failed on the way (the nav to Klonopin
    wedged) and every entry then shopped - and asked 13 characters for Fine Runic Parchment Solution, 6-8s - for
    itself. A gathering trip that fails on the way is made again (3 in all; not for a plan problem, money, bags or
    faction); an item a survey found nobody with is not asked again for 5 minutes.
44. 2.42.11: Research wears the Ethereal Quill (the old LazCraft's research modifier; skills.ini Trophy=), then the
    Geerlok Automated Quill. Every run now says when nothing to wear was found ("Wear for <skill>: none of yours ...")
    - before, only a preflight did, and a research queue went without a word.
45. 2.42.12 spellbooks (engine/books): every character on the network not running is read once over DanNet, with
    no LazCraft there - class, level, then Me.Book[<spell>] for each summoned item its class can cast (producers.ini
    Classes=); under level 66 only the level is kept. Saved in the casters file (Casts=, Lacks=, Level=, Checked=1).
    Workers tab: class and level, casts, "missing" in red, and Check spellbooks (after scribing). A plan short of a
    summoned item nobody can cast reads those books again first (once a job) and plans again. A NULL book answer
    is asked once more before it counts as not scribed; a supply survey's questions and these never cross (the
    books wait, the roster skips a character being read, and a number is never taken as a zone or class).
46. 2.42.13 avoid boxes (nav.ini Avoid<n>=y x, y x, ... | margin; blocks/routes rule 5): Marr's fountain, from the
    user's /loc at four corners round it. Every stretch of a walk (here -> legs -> there) is checked on the map:
    standing in the box, step out to its nearest edge (+margin) first; a stretch that would cross it goes round by
    its corners pushed out by the margin, the shorter way. The walk off the zone-in to Tomas keeps it too. MQ2Nav
    still picks its own path between legs (it cannot be seen), so legs start and end clear of the box. A second box
    over the band of pillars by the docks replaced Marr's SideDocks (the code still reads SideDocks= for any zone).
    Boxes are gone round in the order the walk meets them; each new stretch is checked again.
47. 2.42.14 summon order counts: whatever we take from a worker, by any request, comes off its summon order's held
    count for that item, and its 'made' word sets the count to its bags. A worker that comes with fewer than its
    order said ("ran out") gets the rest ordered for the pass, like summon short (Lopan log: 125 said, 2 held).
    A trade that does not complete logs who has Trade on (MyTradeReady / HisTradeReady) - proof before any fix.
48. 2.42.15 the route starts where the workers are collected from: a worker in another zone is collected from
    there before the route (engine/make), so the planner plans shopping and the craft zone from that zone
    (world.worker_zone), not from where we stand (Lopan log: PoK -> Marr's for Tungsten Ore -> back to PoK).
49. 2.42.16 a combine whose message comes late: once the container has changed after a send (the game took it),
    the combine is never sent again and its message is waited for up to Combine.MS. Before, the 1.5s resend check
    saw the empty container and failed the combine with "no combine message" (Lopan log: two gorget runs ended
    that way, product on the cursor at 1.7s and 1.9s).
50. 2.42.16 after-row clean-up in a leveling path (engine/cleanup after_row): when a row ends, its product is sold
    (destroyed when the row says destroy), products of its sub-combines too, and its ingredients a merchant sells
    for under 20pp a unit (RequestOverPP when set); dearer ones, farmed ones, tools and anything a row not at its
    trivial still needs stay. Nothing to do is a debug line; a failure is said and the path goes on. Each pass
    also logs its route and merchant stops ("Route: ...").
51. 2.42.17 avoid box heights: a corner may carry z (nav.ini Avoid<n>=y x z, ...); the walk round that box goes at
    the corners' floor height. Without it the height is a guess between the walk's ends - Avoid2's corner at
    -31.42 had no nav path (2.42.16 log); the user's /loc gives -48.57.
52. 2.43.0 the window (ui/window, ui/theme): AdventureTime's four themes (Midnight, Slate, Ember, Glass) pushed once
    around each window and popped after - only the slots the build has, exactly what went on comes off. Theme= is
    a per-character setting (Settings: Look); the crafter sends it to every running worker when it changes and to a
    worker when its first card comes (crew on_up); the worker saves it. Layout as the mockup: a header (logo from
    ui/logo.png via mq.CreateTexture, else an LC mark - logged once at debug), the job panel (name, phase pill,
    status, progress, preflight, Go/Cancel, Pause/Stop greyed when idle; Close all on the right), then the tabs with
    titled section lines (SeparatorText, else a rule and coloured text) and striped tables (BeginTable; without
    ImGuiTableFlags - the tests - the cells are plain lines). Craft: recipes in trivial bands of 50 (a search across
    every skill: by skill), the picked recipe's ingredient table from a quiet plan (actions.preview, the estimate's
    5s world read): Need, Have, From. A skill's recipes of unknown trivial now sort last. Summon is as it was.
53. 2.43.1 when the inventory is cleared: only after a path row at its trivial (or the skill cap). A row that failed,
    or ended short of its trivial, keeps everything it bought and made (the Mithril Champion Arrows log: a kit that
    did not open failed the row after an hour of subcombines, and the clean-up sold the 2034 Fletchings, Arrow Heads
    and Shafts it had made). Stop never cleans up. A row that failed on the way (not a final reason: cannot get it,
    plan changed, not enough money, bags full, no faction) is made once more from what is in the bags (ROW_TRIES 2).
    A kit right-click waits up to RESEND_MS (500) for the kit to open before the next, 4 in all, as bags do: three
    right-clicks 33ms apart straight after closing the Forge with Esc were all lost. What a row not at its trivial
    still needs is kept all the way down its subcombines (Cleanup.needs): Metal Bits at trivial, Banded Mail not -
    Metal Bits' parts go, Banded Mail's (Sheet Metal and what it is made of) stay. The Clean up button keeps the same.
54. 2.43.2 MQ's ImGui enums (ImGuiCol, ImGuiStyleVar, ImGuiTableFlags...) are read through _G, never rawget: in game
    rawget found none of them, so 2.43.0/2.43.1 pushed no theme (only the window's own coloured text changed) and
    drew every table as plain lines (the Baking path a mess). The window logs once at debug what the theme pushed
    and whether tables are on. Progress bars are drawn (Window:bar): a rounded track, the theme's accent fill with a
    lighter top band, centred text with a shadow; the stock ProgressBar where the draw list is not there.
55. 2.43.3 where a worker is collected from: only a worker sitting still (idle, or not running) in a safe zone gives
    the plan a zone to start in (world.worker_zone); one busy elsewhere is on its way somewhere, so the route starts
    where we stand. The Make never follows a worker into a zone that is not safe; it is collected at its step,
    wherever it is then (the log: a run called Lunafeet's Felwithe errand off, Lunafeet carried on to gfaydark, the
    next run's route went to gfaydark and would have crafted there).
56. 2.43.4 "You cannot combine these items in this container" (a mouse from another computer clicking into ours):
    take the container's contents out, /cleanup (every window and bag closed), open the container again, take out
    whatever it still holds, place again - up to REFUSED_TRIES. A merchant window that does not open gets a /cleanup
    before each new ask. /lc givepp <n> <name> gives platinum to a player next to us (Trade:give_pp), every step
    logged: inventory window, the platinum slot, the amount read back, coins on the cursor (Me.CursorPlatinum),
    the drop, the trade window's money field, our Trade click, then up to 60s for them to click Trade by hand;
    done only when our purse is down by exactly n, otherwise cancelled and the coins put back. The worker top-up
    (faction step 3) waits for a log of this. The logo is the emblem cut from its background (ui/emblem.png),
    64 tall in the crafter window and 36 in the worker's, as wide as its shape.
57. 2.43.5 salvage that lands while a combine is placed (2.43.1 log, both refusal spirals: a failed combine's
    salvage came back 440ms-1.5s after it, past the 300ms watch; the game still held it in the container and
    refused the next combine): anything landing on the cursor while placing, or an item that will not go in,
    empties the container and places it all again (up to LATE_RESTARTS), logged. The watch stays 300ms (a longer
    one costs every failure; this costs only the rare late one); what lands after the combine is sent is the
    /cleanup recovery's. The Leveling tab's "Clean up finished rows" does every row at its trivial (the recipe
    picked in it) under one preview and one Go, one merchant trip; what a row not at its trivial needs stays.
58. 2.43.6 the ImGui enums (ImGuiCol, ImGuiStyleVar, ImGuiTableFlags...) are read by their plain global names, as
    AdventureTime reads them: the 2.43.5 log still said "0 colours and 0 style vars pushed; tables off" with
    _G[...] (rule 54 was wrong - _G finds nothing in MQ either), while plain ImVec2 and IM_COL32 drew the progress
    bars. Colours are pushed as one IM_COL32 value, as AT pushes them.
59. 2.43.7 a merchant's list is trusted only with what we came for on it: the data (merchants.ini, the Alla pages) is
    nearly always right, and Merchant.ItemsReceived is not (2.43.6 log: Audri Deepfacet, 153 items in 17 opens,
    said complete at 7 and at 10 - Platinum Bar, bought from her twice that run, was saved as not sold there and
    the plan went to the Abysmal Sea). The open waits up to LIST_MS for each item we came to buy; one still not there
    gets the window closed and opened again once; only then is it saved to settings/unsold.ini. An item saved there
    that a merchant's list does show is taken off and the merchant put back. A settings/unsold.ini from before this
    (no [Meta] Version=2) is moved to unsold_old.ini once and we start empty.
60. 2.43.8 a product /autoinventory puts on an empty worn slot (face, neck, head, wrist, finger) is made but not in the
    bags: the sale sells what the bags hold, says how many went on a worn slot, and does not count them as still
    to sell (2.43.7 log: a Veil, a Necklace and a Tiara row each "sold 82 of 83, none left" and failed). What is
    worn stays worn - taking it off is the user's call.
61. 2.43.9 a worker outside a safe zone (travel.ini [Safe]) is out playing: it takes no order, no summon and no come
    (each answered no / failed with "in <zone>, not a safe zone", logged), and the crafter does not pick a running
    worker or caster outside a safe zone for a faction buy or a cast (2.43.7 Lunafeet log: in sebilis, it took a
    Frying Pan Mold order and ported out to Jaggedpine).
62. 2.43.10 an item /autoinventory will not stow (2.43.7 log: Brut Champagne twice, Patty Melt once - 30 sends each, ~98
    slots free by the client's count, E3 could not stow it either) is clicked by hand into a free slot of a bag that
    takes it (big enough; tradeskill-only bags only for tradeskill items), and every bag is logged first (free slots,
    tradeskill-only, size it holds, whether it takes the item) with the item's size and tradeskill flag - the proof
    of why the game would not. No bag takes it: said, and the cursor is stuck as before.
63. 2.43.11 core/snapshot: the game as it stands, into the log - where we are and the target, E3, the cursor, the open
    windows, every bag (free slots, tradeskill-only, size) and what is in it, the worn slots, and the last 30 lines of
    game chat (kept from a catch-all event). Taken by /lc snap, when a job fails, and when the game refuses a combine:
    the details the user cannot always give are in the log.
64. 2.44.0 the Craft tab's trivial filter: with a tradeskill picked, Min and/or Max (empty = no limit); a recipe with no
    known trivial is left out while a limit is set, counted ("+N with no known trivial"), and shown on Show them.
65. 2.44.0 Supply: a short item some characters never answered for says "no answer about it from <names>", never "nobody
    on the network has any"; and "nobody had it" is held (NONE_MS, not asked again) only when everyone answered.
66. 2.44.0 the live status file: logs/LazCraft_<name>_status.txt rewritten about once a second (Settings: Write a live
    status file) - who and for whom, the job and its step, where, the target, E3, the cursor, open windows, the last
    10 chat lines. One read says what it is doing right now.
67. 2.44.0 several drivers: a crafter answers another crafter's hello with 'driver' - that one is never started as a
    worker (/lua run would stop its own run), ordered from (its bags are not supply) or picked to cast or buy. A worker
    works for every crafter that says hello: the first stays its own (theme, window), every one gets its card and bye,
    and their orders queue on its one runner. It keeps what it holds for each crafter (made for an order, summoned,
    until given): another crafter's summon counts only what is not held for someone else, and an order is bought on
    top of it. Only 2.44.0+ crafters answer as drivers - every driver on the network must run it.
68. 2.45.0 the Research tab by level: a divider per level (what is in it, how many held) with a fold toggle and Queue
    for that level's not-held rows; no Lvl column; names without the "Spell: "/"Song: "/"Skill: " they all start with
    (full name on hover, tomes tagged); a row's Qty box shows only under the mouse or when its Qty is not 1.
    2.45.1: held means bags + bank only - a scribed spell is not greyed, counted or tagged; rows have + Queue and no
    Make; no header row; the fold toggle is an arrow button, with no (?) on the divider.
    2.45.2: the divider's Queue sits against the right edge, a rule running from the title out to it.
69. 2.45.4 producers.ini imbues by class, from what each class has scribed: Druid makes only Emerald and Plains
    Pebble; Shaman Amber, Diamond, Ivory, Jade, Sapphire; Wizard Fire Opal; Cleric twelve (no Jade, Ivory, Fire Opal).
70. 2.46.4 a combine whose message never comes (2.46.3 logs, Vadar/Mazkanata/Cadbane: most rows ended "no answer ...
    container: kit empty, cursor: <the product>"; the failure snapshot's chat has the combine before and none for this
    one, all of it 23s late - a client stall lost the line): once Combine.MS is up, a container that changed with the
    product on the cursor is a success, warned ("counted a success"), and the combine goes on as one. Anything else on
    the cursor (a tool, salvage) or nothing still fails "no answer" - a failure cannot be told from that.
71. 2.46.4 a kit in a top-level slot is never opened as a bag: on Lazarus its right-click raises the tradeskill window,
    never a PackN window (2.46.3 Cadbane log: bought Ceramic Lining Sketches landed in the Planar Fletching Kit in pack9;
    "pack9 did not open (4 right-clicks)" failed three Casserole Dish runs, and the Jeweler's Kit could not go back into
    it). blocks/kitslot opens such a kit the kit's way (right-click, Experiment) for its own moves, and before a step
    opens its container, every stack of the step's ingredients and tools inside such a kit is moved whole into a free
    slot of a plain bag (pack10 last) - said, and with no room the step stops naming the kit.
72. 2.46.4 the preflight's bag room leaves out pack10's free slots when a kit step will borrow pack10 (its kit is not in
    a top-level slot and pack10 holds a plain bag): the swap takes that bag away (2.46.3 Cadbane log: "needs 7, 13 free",
    the buys filled every other bag, then "no free slot in the other bags for The Scent of Marr from pack10"). The Bags
    line says so ("not counting the N free in pack10: the kit goes there").
73. 2.46.4 a container that already holds something when a step starts is emptied first, said (2.46.3 Vadar log: the
    Fletching Kit was already open with a Small Brick of Mithril in slot 1 - "slot taken" before a single click). A
    "slot taken" mid-step empties it and places it all again, as "not placed" does (LATE_RESTARTS).
74. 2.46.4 a preflight check of level 'done' (core/jobs) ends the job as done before Go, logged at info: Clean up with
    nothing to sell or destroy was an ERROR, a failed job and a snapshot in every 2.46.3 log.
75. 2.46.5 late salvage and desyncs (2.46.3 Vadar log, ItemPaceMs 0: combine 6 failed, a second salvage - Bundled Arrow
    Shafts - landed ~500ms after it, inside a pickup of combine 7; the cursor block put it away as "not ours", so the
    round was never marked late; the game then said "Inventory Desyncronization detected: Resending slot data..." and
    refused, and clicks on its stale view put a whole stack of 984 Fletchings into the kit). Now:
    - blocks/cursor counts strays - what it puts away that nobody picked up ("not ours", a wrong pickup) - and the game's
      desync lines (an event). Any of either while a round is placed marks the round late: emptied and placed again.
    - A desync is waited out before anything is clicked again: no desync line for DESYNC_QUIET_MS (1s, capped at 6s),
      then the container comes out as it really is. Also before a round when one came since the last look (during the
      last combine's returns), and before clearing after a refusal.
    SALVAGE_MS stays 300 (rule 57): a later one is caught by the round check instead of costing every failure.
76. 2.46.7 burst, then listen (core/pace). Rules 8 and 9 said no workaround delays and no fixed waits; the 2.46.5 Vadar
    log is why that changes for inventory clicks: a pickup and its drop went out in the same frame, the server had not
    finished the first ("Inventory Desyncronization detected", source 4811 -> 33 -> 5813 - pack5 slot 2, the cursor,
    kit slot 4) and refused the combine, at combine 3, with no late salvage at all. Every desync line in that log names
    slot 33 (the cursor): they come from pickups and drops, never the /combine, ~200ms after the move. The client shows
    every move done at once, so reading the bags proves nothing (combine 3's "holds what was placed" passed); the game's
    desync line is the only signal. (2.46.6 put a learned gap on every click - ~0.9s a combine; never released.)
    - The floor: never two inventory clicks closer than ClickFloorMs (34, a frame) - Cursor:gap, on the click ladder's
      sends, a stow's first /autoinventory, the quantity window's Accept, the /combine.
    - The window: after the last item goes in, the game gets QuietMs to say it is out of step before the /combine
      (Cursor:quiet; ends at the first desync line). A desync there places the round again (rule 75) instead of
      combining on a view the server does not share.
    - ClickPace auto (default): QuietMs starts at 300 (or what this character learned); any trouble in a combine - a
      desync, a refusal, a stray on the cursor, an item that did not go in - widens it once (x1.5, up to 1500); 25 clean
      combines in a row narrow it 25 (to 150). Each change is logged ("Pace: quiet window 300 -> 450ms before each
      combine (desync)") and saved in the character's settings. ClickPace fixed: used as set.
    - A wrong view can outlast timing: the 2.46.5 log's first desync was a click on a stack the client still showed in
      pack5 slot 2 and the server had in pack1 slot 6. Settle-then-clear (rule 75) is what fixes that, not the window.
    - The job panel shows the window while a job runs ("auto quiet 300ms"); Settings > Pacing edits all three.
    ItemPaceMs (rule in Running) stays: it spaces item starts, off by default.
77. 2.46.8 after a desync, /cleanup before combining again (the user's rule, known from play). 2.46.7 Vadar log, twice: a
    desync on the kit's own slots (5813 -> 33) shut its Pack10 window while its combine window stayed up; the recovery
    settled, cleared and placed again, listened (quiet), and every /combine pack10 got MQ's "Window 'pack10' not open" -
    three sends, then "no answer", and the run was over. Now one reset (engine/make reset_container) serves every
    desync, every refusal and a shut kit window: desync lines waited out, the container emptied, /cleanup, the
    container opened again, anything it still shows taken out - logged "<container>: clearing, /cleanup and opening it
    again before the next combine". Also:
    - Before each /combine into a kit, its own PackN window must be open (not only ContainerCombine_Items); shut, the
      reset runs and the round is placed again (REFUSED_TRIES in all).
    - blocks/combine hears "Window '...' not open" as a result of its own ('closed'): nothing combined, nothing comes
      back; make treats it as a refusal (the reset), never as silence.
    A late round with no desync (a stray, an item that did not go in) still only empties and places again: no /cleanup.
78. 2.46.9 the data cache (core/datacache, settings/data_cache.lua). 2.46.8 Shela log: the log opened, and data/ was read
    148.8s later (Vadar, another machine: 1.8s). MQ runs a Lua script MQ2Lua.yaml turboNum VM instructions a frame (2000
    on this machine) and parks it until the next frame, so the parse - recipes.ini alone is 4.9MB, 137,602 lines - costs
    frames, many of them. The frame limiter was off: it is not a background thing, every start paid it.
    - A start loads the cache instead: Lua compiles it in C (no VM instructions), running it costs about two a value.
    - It is good while the data files read (each one's size, and its time when LuaFileSystem is there), the parse code
      (core/config.lua, core/ini.lua, core/datacache.lua) and its FORMAT are the same; else the start parses as before and
      saves a new one ("Data: read data/ in Ns (cache: ...) - saving it", then "Data: loaded from the cache in Ns").
      An update that leaves the parse code alone keeps the cache.
    - Shared tables stay shared, a table holding itself too; big tables are filled statement by statement, cut into
      functions under LuaJIT's 65,536 constants each. Written to a temp file per character, then renamed into place.
    - Any trouble with it (missing, broken, stale) is a parse, never a failed start. Safe to delete.
    - The in-game tests run the real init, so they make or use the same file: it is the same data, so it is left there.
    The first start after the data or the parse code changes costs the parse and the save; every one after is quick.
79. 2.46.9 spellbooks (engine/books): a character that does not answer is left out of the scan for the session (2.46.8
    Shela log: Menanu - on DanNet, never answering, likely a client on another machine - asked every 15s all session). A
    recheck asked for by name (a plan short of a summoned item) or Check spellbooks still asks it.
## Versions
Releases are 1.xx.x - no beta tag since 1.10.0.
1.10.0 (2026-10-23): LazCraft2 became LazCraft, out of beta - the next LazCraft, not a product of its own. Everything above marked
2.xx.x was a LazCraft2 version (2.46.9 was the last); the old LazCraft (lc-* builds, /tsui) is what 1.10 replaces.
- Folder lua/lazcraft (the old LazCraft's; move that one aside first), /lua run lazcraft, /lua run lazcraft worker.
- Command /lc (was /lc2); peer messages /lc_<verb> (were /lc2_<verb>): every character must run 1.10 together - a
  LazCraft2 and a 1.10 do not hear each other. The old LazCraft's commands (/ts_*, /laz*, /tsui) do not clash.
- Files settings/LazCraft_<Name>*.ini, logs/LazCraft_<Name>.log; log tag [LC]. Nothing carried over from LazCraft2's
  files (the user's call: few settings); shared learned files (rates, stacks, unsold) start fresh too.

## Known limits
- `/e3p off` is sent when a job ends even if you had paused E3 by hand before it started.
- `/lua stop lazcraft` in the middle of a job kills the script before it can resume E3; use `/lc quit` (it stops the job first), or `/e3p off` by hand afterwards.
