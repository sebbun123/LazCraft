local mq = require('mq')

local running = true
-- Items queued by /ts_qadd, delivered as one batch on /ts_qrun (one bank trip, one trade window).
local pendingBatch = {}
-- Summon/produce jobs queued by /ts_make, drained one at a time by the main loop so a crafter can
-- ask for several summons in a row and each is made in turn instead of the second clobbering the first.
local makeQueue = {}

-- The listener self-terminates only after this many ms of INACTIVITY. Picking up
-- a job, each cast in a batch, and each med-poll all push it forward via
-- bump_alive(), so a request can run as long as it needs - this is just a safety
-- net for a job that hangs or a listener that never got a job, not a time cap.
local IDLE_TIMEOUT  = 600000
local aliveDeadline = mq.gettime() + IDLE_TIMEOUT
local function bump_alive() aliveDeadline = mq.gettime() + IDLE_TIMEOUT end

-- Terminal exit. Always hand E3 back to the toon before we stop, so a finished
-- listener never leaves its character frozen (E3 paused). /e3p off is idempotent --
-- a no-op when E3 is already active -- so it's safe to call from any exit path, and
-- routing every stop through here keeps that guarantee in one place.
local function stop_listener()
    mq.cmd('/e3p off')
    running = false
end

-- File logging: mirror every listener line to TradeskillListener_log.txt in this
-- script's folder. Fresh file each /lua run, timestamped, flushed per line so it
-- survives a crash. Mirrors the crafter's logging so a supply-chain run can be
-- reconstructed from both sides. The mule's name goes in the header since each
-- mule writes its own copy.
local LOG_FILE_PATH
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
        if luaPath and luaPath ~= '' then dir = luaPath .. '\\' end
    end
    -- Write into <lazcraft>\Logs\ - the SAME folder the suite and MerchantScanner use, not the lua
    -- root. If we're run from the lua root, hop into the lazcraft subfolder so all logs land together.
    -- Per-character name so parallel toons don't clobber each other's log.
    if dir and dir ~= '' and not dir:lower():match('lazcraft[/\\]$') then
        dir = dir .. 'lazcraft\\'
    end
    local logDir = (dir or '') .. 'Logs\\'
    pcall(function() os.execute('mkdir "' .. logDir:gsub('\\+$', '') .. '" 2>nul') end)
    local who = '?'
    pcall(function() who = mq.TLO.Me.Name() or '?' end)
    LOG_FILE_PATH = logDir .. 'TradeskillListener_' .. who .. '_log.txt'
    local fh = io.open(LOG_FILE_PATH, 'w')   -- 'w' = truncate: fresh each run
    if fh then
        fh:write(string.format('=== TradeskillListener log (%s) - started %s ===\n',
            who, os.date('%Y-%m-%d %H:%M:%S')))
        fh:close()
    else
        LOG_FILE_PATH = nil   -- couldn't open the file; disable file logging quietly
    end
end

local function log_to_file(line)
    if not LOG_FILE_PATH then return end
    local fh = io.open(LOG_FILE_PATH, 'a')
    if not fh then return end
    fh:write(string.format('[%s] %s\n', os.date('%H:%M:%S'), line))
    fh:close()
end

local function log(msg, ...)
    if select('#', ...) > 0 then msg = string.format(msg, ...) end
    printf('\ag[TSListener]\ax %s', msg)
    log_to_file(msg)
end

local function trim(s) return s:match('^%s*(.-)%s*$') end

local function decode(s)
    -- Reverse the crafter's encode(): apostrophe sentinel back to "'", underscores
    -- back to spaces. (The old trailing-apostrophe strip was a band-aid for the
    -- unencoded-apostrophe bug and is no longer needed.)
    s = tostring(s or '')
    s = s:gsub('XAPOSX', "'")
    s = s:gsub('_', ' ')
    return trim(s)
end

local function item_count(name)
    local ok, n = pcall(function() return mq.TLO.FindItemCount('=' .. name)() end)
    return (ok and type(n) == 'number') and n or 0
end

local function bank_count(name)
    local ok, n = pcall(function() return mq.TLO.FindItemBankCount('=' .. name)() end)
    return (ok and type(n) == 'number') and n or 0
end

-- Peer-execute abstraction (mirrors the crafter). We reply to the requester over the same
-- network it used. Prefer E3 (/e3bct), then EQBC (/bct), then DanNet (/dex). Detected once.
local peerKind
local function peer_cmdf(char, fmt, ...)
    local cmd = fmt:format(...)
    if not peerKind then
        if mq.TLO.Plugin('mq2mono')() then peerKind = 'e3'
        elseif mq.TLO.Plugin('MQ2EQBC')() then peerKind = 'eqbc'
        else peerKind = 'dannet' end
        log('Peer network: %s', peerKind == 'e3' and 'E3 (/e3bct)' or peerKind == 'eqbc' and 'EQBC (/bct)' or 'DanNet (/dex)')
    end
    if peerKind == 'e3' then mq.cmdf('/e3bct %s %s', char, cmd)
    elseif peerKind == 'eqbc' then mq.cmdf('/bct %s %s', char, cmd)
    else mq.cmdf('/dex %s %s', char, cmd) end
end

-- Marr (freeporttemple) has a fountain right at the zone-in with no navmesh under it - a listener
-- that zones in there and immediately /nav id's to the crafter gets hung trying to path across it.
-- The soulbinder spot IS on the mesh and is reachable from the zone-in by a straight /nav loc, so
-- when we're still NEAR the zone-in we hop there first to get clear of the fountain. Once we're past
-- it there's no reason to go back, so this only fires within MARR_ZONEIN_R of the zone-in.
local MARR_ZONE       = 'freeporttemple'
local MARR_ZONEIN     = { y = -132, x = -1, z = 35.12 }        -- the fountain trap at zone-in
local MARR_ZONEIN_R   = 200                                     -- only hop when this close to it
local MARR_SOULBINDER = { y = 242.70, x = -84.82, z = -7.07 }  -- safe, on-mesh; route through here

local function dist3(a)
    local dx = (mq.TLO.Me.X() or 0) - a.x
    local dy = (mq.TLO.Me.Y() or 0) - a.y
    local dz = (mq.TLO.Me.Z() or 0) - a.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

local function clear_marr_zonein()
    if (mq.TLO.Zone.ShortName() or '') ~= MARR_ZONE then return end
    if dist3(MARR_ZONEIN) > MARR_ZONEIN_R then return end   -- already past the fountain, nav direct
    log('Near the Marr zone-in fountain - hopping to the soulbinder spot first to get clear...')
    mq.cmdf('/nav loc %.2f %.2f %.2f', MARR_SOULBINDER.y, MARR_SOULBINDER.x, MARR_SOULBINDER.z)
    mq.delay(2000, function() return mq.TLO.Navigation.Active() end)
    local deadline = mq.gettime() + 20000
    while mq.gettime() < deadline do
        if not mq.TLO.Navigation.Active() then break end
        if dist3(MARR_SOULBINDER) < 20 then break end
        mq.doevents(); mq.delay(100)
    end
    mq.cmd('/nav stop'); mq.delay(200)
end

local function nav_to_banker()
    mq.cmd('/target npc banker')
    mq.delay(500, function() return (mq.TLO.Target.ID() or 0) > 0 end)
    if (mq.TLO.Target.ID() or 0) == 0 then
        mq.cmd('/target npc banker radius 200')
        mq.delay(500, function() return (mq.TLO.Target.ID() or 0) > 0 end)
    end
    if (mq.TLO.Target.ID() or 0) == 0 then log('No banker found.'); return false end
    if (mq.TLO.Target.Distance() or 999) > 10 then
        clear_marr_zonein()
        mq.cmdf('/nav id %d', mq.TLO.Target.ID())
        mq.delay(1000, function() return mq.TLO.Navigation.Active() end)
        local deadline = mq.gettime() + 15000
        while mq.gettime() < deadline do
            if not mq.TLO.Navigation.Active() then break end
            mq.doevents()
            mq.delay(100)
        end
    end
    return (mq.TLO.Target.Distance() or 999) <= 10
end

local function open_bank()
    if mq.TLO.Window('BigBankWnd').Open() then return true end
    mq.cmd('/click right target')
    mq.delay(1000, function() return mq.TLO.Window('BigBankWnd').Open() end)
    return mq.TLO.Window('BigBankWnd').Open()
end

local function close_bank()
    if mq.TLO.Window('BigBankWnd').Open() then
        mq.cmd('/notify BigBankWnd DoneButton leftmouseup')
        mq.delay(300)
    end
end

-- Set the split (QuantityWnd) to exactly n. The window ONLY pops if the bank bag is open (closed
-- bag -> whole stack), and the amount MUST be set via the /invoke SetText datatype-setter (NOT
-- /notify settext, which is invalid and takes the full stack). Poll until the field reads n.
local function set_split_qty(n)
    local want = tostring(n)
    mq.cmdf('/invoke ${Window[QuantityWnd/QTYW_SliderInput].SetText[%d]}', n)
    local deadline, ticks = mq.gettime() + 1500, 0
    repeat
        if (mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text() or '') == want then return true end
        mq.delay(40); ticks = ticks + 1
        if ticks % 8 == 0 then mq.cmdf('/invoke ${Window[QuantityWnd/QTYW_SliderInput].SetText[%d]}', n) end
    until mq.gettime() > deadline
    return (mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text() or '') == want
end

-- Withdraw from the bank. If `n` is given, pull EXACTLY n (open the bag so the split pops, then set
-- the amount with SetText); if `n` is nil, pull a whole stack (legacy top-up behavior). Returns the
-- number actually withdrawn.
local function withdraw_item(name, n)
    local upper = name:upper()
    local exact = n ~= nil
    if exact then n = math.max(1, math.floor(n)) end
    local before = item_count(name)
    local withdrawn = 0
    for b = 1, 24 do
        if withdrawn > 0 then break end  -- one stack (or one exact pull) per call
        local bankSlot = mq.TLO.Me.Bank(b)
        if (bankSlot.ID() or 0) > 0 then
            local slots = bankSlot.Container() or 0
            if slots > 0 then
                for s = 1, slots do
                    if withdrawn > 0 then break end
                    if (bankSlot.Item(s).Name() or ''):upper() == upper then
                        log('Withdrawing %s%s from bank%d slot%d', exact and (n .. 'x ') or '', name, b, s)
                        if exact then
                            local slotStack = bankSlot.Item(s).Stack() or 1
                            if n >= slotStack then
                                -- want the whole slot stack (<= n): grab it plainly, NO split/bag-open
                                -- (this is the common 1-from-1 case; the bag-open dance only broke it).
                                mq.cmdf('/nomodkey /itemnotify in bank%d %d leftmouseup', b, s)
                                mq.delay(1000, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
                            else
                                -- true partial: retry open+grab (re-toggle self-corrects) until the
                                -- split pops, putting back any whole-stack grab between tries.
                                local gotSplit = false
                                for _ = 1, 4 do
                                    mq.cmdf('/itemnotify bank%d rightmouseup', b)
                                    mq.delay(450)
                                    mq.cmdf('/itemnotify in bank%d %d leftmouseup', b, s)
                                    mq.delay(800, function() return mq.TLO.Window('QuantityWnd').Open() or (mq.TLO.Cursor.ID() or 0) > 0 end)
                                    if mq.TLO.Window('QuantityWnd').Open() then gotSplit = true; break end
                                    if (mq.TLO.Cursor.ID() or 0) > 0 then
                                        mq.cmd('/autoinventory'); mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                                    end
                                    mq.delay(150)
                                end
                                if gotSplit then
                                    if not set_split_qty(n) then
                                        log('withdraw_item: could not set qty %d for %s - cancelling (no over-pull)', n, name)
                                        mq.cmd('/keypress esc'); mq.delay(300, function() return not mq.TLO.Window('QuantityWnd').Open() end)
                                    else
                                        mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
                                        mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
                                    end
                                end
                            end
                        else
                            mq.cmdf('/nomodkey /itemnotify in bank%d %d leftmouseup', b, s)   -- whole stack
                            mq.delay(1000, function() return (mq.TLO.Cursor.ID() or 0) > 0 or mq.TLO.Window('QuantityWnd').Open() end)
                            if mq.TLO.Window('QuantityWnd').Open() then
                                mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
                                mq.delay(500, function() return not mq.TLO.Window('QuantityWnd').Open() end)
                            end
                        end
                        if (mq.TLO.Cursor.ID() or 0) > 0 then
                            mq.cmd('/autoinventory')
                            mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                        end
                        withdrawn = item_count(name) - before
                    end
                end
            else
                if (bankSlot.Name() or ''):upper() == upper then
                    log('Withdrawing %s from top-level bank%d', name, b)
                    mq.cmdf('/nomodkey /itemnotify bank%d leftmouseup', b)   -- single top-level item: whole
                    mq.delay(500, function() return (mq.TLO.Cursor.ID() or 0) > 0 or mq.TLO.Window('QuantityWnd').Open() end)
                    if mq.TLO.Window('QuantityWnd').Open() then
                        mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
                        mq.delay(500, function() return not mq.TLO.Window('QuantityWnd').Open() end)
                    end
                    if (mq.TLO.Cursor.ID() or 0) > 0 then
                        mq.cmd('/autoinventory')
                        mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                    end
                    withdrawn = item_count(name) - before
                end
            end
        end
    end
    return withdrawn
end

local function find_item_slot(name)
    local upper = name:upper()
    for i = 1, 10 do
        local bag = mq.TLO.Me.Inventory('pack' .. i)
        local slots = bag.Container() or 0
        if slots > 0 then
            for s = 1, slots do
                if (bag.Item(s).Name() or ''):upper() == upper then
                    return i, s
                end
            end
        end
    end
    return nil, nil
end


local function nav_to_char(name)
    local id = mq.TLO.Spawn('pc "' .. name .. '"').ID() or 0
    if id == 0 then log('Cannot find %s.', name); return false end
    clear_marr_zonein()   -- get off the dead patch before pathing to the crafter
    mq.cmdf('/nav id %d', id)
    mq.delay(2000, function() return mq.TLO.Navigation.Active() end)
    local deadline = mq.gettime() + 20000
    while mq.gettime() < deadline do
        if not mq.TLO.Navigation.Active() then break end
        mq.doevents()
        mq.delay(100)
    end
    return (mq.TLO.Spawn('pc "' .. name .. '"').Distance() or 999) < 15
end

local function trade_item(toChar, itemName, qty)
    log('trade_item called: toChar=%s item=%s qty=%d', toChar, itemName, qty)
    if not nav_to_char(toChar) then log('Could not reach %s.', toChar); return false end
    mq.cmdf('/target pc %s', toChar)
    mq.delay(500, function() return (mq.TLO.Target.Name() or ''):lower() == toChar:lower() end)
    if (mq.TLO.Target.Name() or ''):lower() ~= toChar:lower() then
        log('Could not target %s.', toChar); return false
    end
    mq.cmd('/face fast')
    mq.delay(200)

    -- E3 stays PAUSED for the whole trade. We used to /e3p off here so E3 would click the Trade
    -- button to confirm - but a live E3 also grabs the cursor / re-targets / moves the toon DURING our
    -- pickup, which broke the 2nd item in a batch (its split/grab failed while E3 was active). Instead
    -- we keep E3 off and click TRDW_Trade_Button ourselves at the end. E3 never touches the cursor, so
    -- every item's pickup is clean.
    -- Pick up items and drop them ON the target; that's what opens/fills the trade window. We place
    -- EXACTLY qty: whole stacks until the last piece, then a partial (split via SetText) for the
    -- remainder. If a needed partial can't be set, we STOP rather than dump a whole stack (never
    -- over-deliver) - so worst case we hand over slightly less, never more.
    local placed = 0
    local slotsUsed = 0
    while slotsUsed < 8 and placed < qty do
        local bagNum, slotNum = find_item_slot(itemName)
        if not bagNum then break end
        local slotStack = mq.TLO.Me.Inventory('pack' .. bagNum).Item(slotNum).Stack() or 1
        local want = math.min(qty - placed, slotStack)

        if want >= slotStack then
            -- take the whole slot stack (no split needed)
            mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', bagNum, slotNum)
            mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) > 0 or mq.TLO.Window('QuantityWnd').Open() end)
            if mq.TLO.Window('QuantityWnd').Open() then
                mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
                mq.delay(500, function() return not mq.TLO.Window('QuantityWnd').Open() end)
            end
        else
            -- partial: pop the split dialog with the right-click TOGGLE then left-click the slot - the
            -- SAME gesture the bank withdraw uses successfully. (Ctrl+click grabs a whole stack or a
            -- single, it does NOT open a partial-count split - that was a wrong turn.) Retry with a
            -- re-toggle each attempt; put back any whole grab between tries. Never place more than asked.
            local gotSplit = false
            for _ = 1, 4 do
                mq.cmdf('/itemnotify pack%d rightmouseup', bagNum)
                mq.delay(450)
                mq.cmdf('/itemnotify in pack%d %d leftmouseup', bagNum, slotNum)
                mq.delay(800, function() return mq.TLO.Window('QuantityWnd').Open() or (mq.TLO.Cursor.ID() or 0) > 0 end)
                if mq.TLO.Window('QuantityWnd').Open() then gotSplit = true; break end
                if (mq.TLO.Cursor.ID() or 0) > 0 then
                    mq.cmd('/autoinventory'); mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                end
                mq.delay(150)
            end
            if gotSplit then
                if not set_split_qty(want) then
                    log('trade_item: could not set partial %d of %s - stopping short (no over-deliver).', want, itemName)
                    mq.cmd('/keypress esc'); mq.delay(300, function() return not mq.TLO.Window('QuantityWnd').Open() end)
                    break
                end
                mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
                mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
            else
                -- Split wouldn't open after retries. Rather than deliver NOTHING (the 0-delivery bug),
                -- fall back to handing over the WHOLE slot stack. The crafter gets more than the exact
                -- ask, which is harmless for stackable mats (excess sits in bags / gets used or sold) and
                -- far better than a failed craft. Grab the stack BY NAME (/itemnotify "name") - this does
                -- NOT need the bag window open, unlike the by-slot "in packN" gesture that just failed in
                -- the split loop above (if the bag closed, every "in packN" pickup fails, which is why both
                -- the split AND a by-slot whole-grab came up empty). By-name is what the suite uses reliably.
                log('trade_item: split would not open for %s - handing over the whole stack (%d) instead of nothing.', itemName, slotStack)
                if (mq.TLO.Cursor.ID() or 0) > 0 then
                    mq.cmd('/autoinventory'); mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                end
                mq.cmdf('/nomodkey /itemnotify "%s" leftmouseup', itemName)
                mq.delay(900, function() return (mq.TLO.Cursor.ID() or 0) > 0 or mq.TLO.Window('QuantityWnd').Open() end)
                if mq.TLO.Window('QuantityWnd').Open() then
                    -- a split popped (stackable): accept to take the whole stack
                    mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
                    mq.delay(500, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
                end
                if (mq.TLO.Cursor.ID() or 0) == 0 then
                    log('trade_item: whole-stack grab of %s also failed - stopping short.', itemName)
                    break
                end
                -- fall through: cursor now holds the stack; the place-on-target below delivers it
            end
        end
        if (mq.TLO.Cursor.ID() or 0) == 0 then
            log('Failed to pick up %s.', itemName); break
        end
        local stackSize = mq.TLO.Cursor.Stack() or 1

        -- drop it on the target (opens trade window / next slot)
        mq.cmd('/notify TargetWindow Target_HP leftmouseup')
        mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
        if (mq.TLO.Cursor.ID() or 0) > 0 then
            mq.cmd('/click left target')
            mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
        end
        if (mq.TLO.Cursor.ID() or 0) > 0 then
            log('Could not place %s on %s.', itemName, toChar)
            mq.cmd('/autoinventory')
            break
        end

        placed = placed + stackSize
        slotsUsed = slotsUsed + 1
    end

    if placed == 0 then
        log('Placed nothing.')
        if mq.TLO.Window('TradeWnd').Open() then
            mq.cmd('/notify TradeWnd TRDW_Cancel_Button leftmouseup')
        end
        return false, 0
    end

    -- Confirm the trade OURSELVES by clicking the Trade button - E3 stays paused the whole time (a live
    -- E3 grabs the cursor mid-pickup and breaks the next item). Click our side; the receiver's listener
    -- clicks theirs. Wait for the window to close = both sides accepted.
    log('Placed %d %s - clicking Trade to confirm...', placed, itemName)
    mq.delay(300)
    mq.cmd('/notify TradeWnd TRDW_Trade_Button leftmouseup')
    mq.delay(8000, function() return not mq.TLO.Window('TradeWnd').Open() end)
    if mq.TLO.Window('TradeWnd').Open() then
        -- one more click in case the first landed before the receiver was ready, then give up cleanly
        mq.cmd('/notify TradeWnd TRDW_Trade_Button leftmouseup')
        mq.delay(4000, function() return not mq.TLO.Window('TradeWnd').Open() end)
    end
    if mq.TLO.Window('TradeWnd').Open() then
        log('Trade window still open after confirm - cancelling.')
        mq.cmd('/notify TradeWnd TRDW_Cancel_Button leftmouseup')
        return false, 0
    end
    return true, placed
end

-- Multi-item version of trade_item: fill ONE trade window with up to 8 stacks drawn
-- from SEVERAL items, then let E3 confirm. Same per-slot pick-up/drop-on-target
-- mechanics as trade_item (proven) - the only difference is we walk a list of items
-- instead of stacks of one. Respects a per-item cap (stack mode = 1000, all = no cap)
-- and the running 'delivered' tally so we never over-hand a stack-mode item.
-- Returns the number of units placed THIS trip (0 = nothing placed / failed).
local function trade_batch_window(toChar, items, cap, delivered)
    if not nav_to_char(toChar) then log('Could not reach %s.', toChar); return 0 end
    mq.cmdf('/target pc %s', toChar)
    mq.delay(500, function() return (mq.TLO.Target.Name() or ''):lower() == toChar:lower() end)
    if (mq.TLO.Target.Name() or ''):lower() ~= toChar:lower() then
        log('Could not target %s.', toChar); return 0
    end
    mq.cmd('/face fast')
    mq.delay(200)
    mq.cmd('/e3p off')   -- live E3 confirms the trade; re-paused on every exit below
    mq.delay(200)

    local slotsUsed = 0
    local placedThisTrip = 0
    for _, b in ipairs(items) do
        while slotsUsed < 8 and (delivered[b.item] or 0) < (cap[b.item] or math.huge) do
            local bagNum, slotNum = find_item_slot(b.item)
            if not bagNum then break end   -- no more of this item in bags
            local slotStack = mq.TLO.Me.Inventory('pack' .. bagNum).Item(slotNum).Stack() or 1
            local want = math.min((cap[b.item] or math.huge) - (delivered[b.item] or 0), slotStack)

            if want >= slotStack then
                -- take the whole slot stack (no split needed)
                mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', bagNum, slotNum)
                mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) > 0 or mq.TLO.Window('QuantityWnd').Open() end)
                if mq.TLO.Window('QuantityWnd').Open() then
                    mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
                    mq.delay(500, function() return not mq.TLO.Window('QuantityWnd').Open() end)
                end
            else
                -- partial: the split only pops with the bag open AND good timing, and the first grab
                -- after opening often misses. Retry: re-issue the bag-open each attempt (right-click
                -- toggles, so alternating self-corrects whether it started open or closed), grab, and
                -- if a whole stack came instead of the split, put it back and try again.
                local gotSplit = false
                for _ = 1, 4 do
                    mq.cmdf('/itemnotify pack%d rightmouseup', bagNum)
                    mq.delay(450)
                    mq.cmdf('/itemnotify in pack%d %d leftmouseup', bagNum, slotNum)
                    mq.delay(800, function() return mq.TLO.Window('QuantityWnd').Open() or (mq.TLO.Cursor.ID() or 0) > 0 end)
                    if mq.TLO.Window('QuantityWnd').Open() then gotSplit = true; break end
                    if (mq.TLO.Cursor.ID() or 0) > 0 then   -- whole stack came; put back and retry
                        mq.cmd('/autoinventory'); mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                    end
                    mq.delay(150)
                end
                if gotSplit then
                    if not set_split_qty(want) then
                        log('batch: could not set partial %d of %s - stopping this item.', want, b.item)
                        mq.cmd('/keypress esc'); mq.delay(300, function() return not mq.TLO.Window('QuantityWnd').Open() end)
                        break
                    end
                    mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
                    mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
                else
                    log('batch: split would not open for a partial of %s after retries - stopping this item.', b.item)
                    break   -- cursor already emptied in the loop; no over-deliver
                end
            end
            if (mq.TLO.Cursor.ID() or 0) == 0 then log('Failed to pick up %s.', b.item); break end
            local stackSize = mq.TLO.Cursor.Stack() or 1

            mq.cmd('/notify TargetWindow Target_HP leftmouseup')
            mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
            if (mq.TLO.Cursor.ID() or 0) > 0 then
                mq.cmd('/click left target')
                mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
            end
            if (mq.TLO.Cursor.ID() or 0) > 0 then
                log('Could not place %s on %s.', b.item, toChar)
                mq.cmd('/autoinventory')
                break
            end

            delivered[b.item] = (delivered[b.item] or 0) + stackSize
            placedThisTrip = placedThisTrip + stackSize
            slotsUsed = slotsUsed + 1
        end
        if slotsUsed >= 8 then break end   -- window full; caller starts another trip
    end

    if slotsUsed == 0 then
        if mq.TLO.Window('TradeWnd').Open() then
            mq.cmd('/notify TradeWnd TRDW_Cancel_Button leftmouseup')
        end
        mq.cmd('/e3p on')
        return 0
    end

    log('Placed %d unit(s) across %d slot(s) - waiting for trade to complete...', placedThisTrip, slotsUsed)
    mq.delay(8000, function() return not mq.TLO.Window('TradeWnd').Open() end)
    if mq.TLO.Window('TradeWnd').Open() then
        log('Trade window still open - cancelling.')
        mq.cmd('/notify TradeWnd TRDW_Cancel_Button leftmouseup')
        mq.cmd('/e3p on')
        return 0   -- items return to bags; caller's no-progress guard will stop the loop
    end
    mq.cmd('/e3p on')
    return placedThisTrip
end

-- Deliver a whole batch of items in ONE bank trip + as few trades as possible.
-- Phase 1: walk to the banker once and withdraw every item toward its target
--          (stack mode -> top up to 1000; all mode -> pull the bank dry).
-- Phase 2: walk to the crafter and hand everything over, 8 stacks per trade window,
--          repeating only when there's more than a window's worth. A /ts_have ping
--          before each trip keeps the crafter waiting. Returns total units delivered.
local function deliver_batch(toChar, batch)
    -- Per-item cap: exact qty when given, else stack (1000) or all (everything).
    local cap = {}
    for _, b in ipairs(batch) do
        cap[b.item] = (b.qty and b.qty > 0) and b.qty or ((b.mode == 'all') and math.huge or 1000)
    end

    -- Phase 1: one bank trip.
    local needBank = false
    for _, b in ipairs(batch) do
        if bank_count(b.item) > 0 and item_count(b.item) < cap[b.item] then needBank = true end
    end
    if needBank then
        log('Batch: one bank trip for %d item(s)...', #batch)
        if nav_to_banker() and open_bank() then
            for _, b in ipairs(batch) do
                bump_alive()   -- a big multi-item withdraw shouldn't trip the idle timer
                if cap[b.item] ~= math.huge then
                    -- exact/stack: pull only the shortfall toward the cap (exact withdraw)
                    local short = cap[b.item] - item_count(b.item)
                    if short > 0 and bank_count(b.item) > 0 then
                        withdraw_item(b.item, math.min(short, bank_count(b.item)))
                    end
                else
                    -- all: pull the bank dry (whole stacks)
                    while item_count(b.item) < cap[b.item] and bank_count(b.item) > 0 do
                        local before = item_count(b.item)
                        withdraw_item(b.item)
                        if item_count(b.item) <= before then break end   -- bags full / no progress
                    end
                end
            end
            close_bank()
        end
        -- A withdraw can leave the last item on the cursor (/autoinventory frequently no-ops while
        -- the bank window is open). Now that the bank's closed, drain the cursor so Phase 2's bag
        -- scan actually finds everything we pulled - otherwise the item rides the cursor and reads
        -- as "0 delivered."
        local dg = 0
        while (mq.TLO.Cursor.ID() or 0) > 0 and dg < 10 do
            dg = dg + 1
            mq.cmd('/autoinventory')
            mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
        end
    end

    -- Phase 2: trade each item in its OWN single-item trade. Packing several items into one trade
    -- window is unreliable (only the first item, which opens the window, places cleanly); single-item
    -- trades are rock-solid. The expensive part - the bank trip - was already consolidated in Phase 1,
    -- so we still make just one bank run; we just hand items over one clean trade at a time.
    local delivered = {}
    for _, b in ipairs(batch) do
        bump_alive()
        if find_item_slot(b.item) then
            local want = cap[b.item]
            if want == math.huge then want = item_count(b.item) end   -- 'all': give everything on hand
            want = math.min(want, item_count(b.item))
            if want > 0 then
                peer_cmdf(toChar, '/ts_have %s 0', b.encoded)   -- keep the crafter waiting
                local ok, placed = trade_item(toChar, b.item, want)
                delivered[b.item] = (delivered[b.item] or 0) + (placed or 0)
                -- 'all' with more than one trade window's worth: keep going until bags are clear.
                while cap[b.item] == math.huge and find_item_slot(b.item) and (placed or 0) > 0 do
                    peer_cmdf(toChar, '/ts_have %s 0', b.encoded)
                    ok, placed = trade_item(toChar, b.item, item_count(b.item))
                    delivered[b.item] = (delivered[b.item] or 0) + (placed or 0)
                end
            else
                log('  %s: nothing tradeable in bags (bags %d, bank %d) - skipping.', b.item, item_count(b.item), bank_count(b.item))
            end
        else
            -- The check said we had this (bags+bank), but it's not in a tradeable bag slot now. Usually
            -- a bank item whose withdraw didn't land in bags (stuck on cursor, or bags full). Log it so a
            -- "check said yes, delivered 0" mismatch is visible instead of a silent skip.
            log('  %s: not found in a tradeable slot (bags %d, bank %d) - could not deliver.', b.item, item_count(b.item), bank_count(b.item))
        end
    end

    local total = 0
    for item, q in pairs(delivered) do
        total = total + q
        log('  delivered %d %s', q, item)
    end
    log('Batch complete: %d unit(s) to %s.', total, toChar)
    return total
end

-- ---------------------------------------------------------------------------
-- Producer (/ts_make): a caster mule MAKES an item on request instead of
-- pulling it from the bank. Buy the vendor reagent, chain-cast the spell that
-- converts it, then trade the result back via the existing trade_item path.
-- First entry: an enchanter turning Large Block of Clay into Magic Clay for
-- pottery 200+. Add more entries (cleric imbues, etc.) keyed by output name.
-- ---------------------------------------------------------------------------
-- Each entry: the spell to cast, the gem to mem it in, how many the cast yields
-- (perCast), and the list of vendor reagents it consumes per cast (name + count).
-- A cast can need more than one reagent (the mana vials use a gem + a poison vial).
local PRODUCE = {
    ['Large Block of Magic Clay'] = {
        spell   = 'Superior Mass Enchant Clay',
        gem     = 8,
        perCast = 100,
        reagents = { { name = 'Large Block of Clay', per = 100 } },
    },
    ['Enchanted Electrum Bar'] = {
        spell   = 'Superior Mass Enchant Electrum',
        gem     = 8,
        perCast = 100,
        reagents = { { name = 'Electrum Bar', per = 100 } },
    },
    ['Enchanted Silver Bar'] = {
        spell   = 'Superior Mass Enchant Silver',
        gem     = 8,
        perCast = 100,
        reagents = { { name = 'Silver Bar', per = 100 } },
    },
    ['Enchanted Gold Bar'] = {
        spell   = 'Superior Mass Enchant Gold',
        gem     = 8,
        perCast = 100,
        reagents = { { name = 'Gold Bar', per = 100 } },
    },
    ['Enchanted Platinum Bar'] = {
        spell   = 'Superior Mass Enchant Platinum',
        gem     = 8,
        perCast = 100,
        reagents = { { name = 'Platinum Bar', per = 100 } },
    },
    ['Enchanted Velium Bar'] = {
        spell   = 'Superior Mass Enchant Velium',   -- NOTE: spell name inferred from pattern; confirm exact Laz name
        gem     = 8,
        perCast = 100,
        reagents = { { name = 'Velium Bar', per = 100 } },
    },
    ['Vial of Clear Mana'] = {
        spell   = 'Mass Clarify Mana',
        gem     = 8,
        perCast = 5,
        reagents = { { name = 'Emerald', per = 5 }, { name = 'Poison Vial', per = 5 } },
    },
    ['Vial of Purified Mana'] = {
        spell   = 'Mass Purify Mana',
        gem     = 8,
        perCast = 5,
        reagents = { { name = 'Ruby', per = 20 }, { name = 'Poison Vial', per = 5 } },
    },
    ['Vial of Distilled Mana'] = {
        spell   = 'Mass Distill Mana',
        gem     = 8,
        perCast = 5,
        reagents = { { name = 'Sapphire', per = 10 }, { name = 'Poison Vial', per = 5 } },
    },
    ["Crude Spellcaster's Empowering Essence"] = {
        spell   = "Focus Mass Crude Spellcaster's Empowering Essence",
        gem     = 8,
        perCast = 5,
        reagents = {},   -- pure summon: nothing to buy
    },
    ["Refined Spellcaster's Empowering Essence"] = {
        spell   = "Focus Mass Refined Spellcaster's Empowering Essence",
        gem     = 8,
        perCast = 5,
        reagents = {},   -- pure summon: nothing to buy
    },
    ["Intricate Spellcaster's Empowering Essence"] = {
        spell   = "Focus Mass Intricate Spellcaster's Empowering Essence",
        gem     = 8,
        perCast = 5,
        reagents = {},   -- pure summon: nothing to buy
    },
    -- Cleric gem imbues: cast consumes 5 of the base gem and yields 5 imbued. Amber and
    -- Emerald are vendor-bought; Black Pearl is DROPPED (farmed/mule-supplied, like the JC
    -- endgame gems), so its reagent is flagged dropped -> never bought, imbued from on-hand.
    ['Imbued Rose Quartz'] = {
        spell   = 'Mass Imbue Rose Quartz',            -- spell has NO "Star"; the reagent gem does
        gem     = 8,
        perCast = 5,
        reagents = { { name = 'Star Rose Quartz', per = 5 } },   -- vendor-bought; produces Imbued Rose Quartz
    },
    -- Remaining deity-idol gems (one idol per character's deity). Buyable gems get bought+imbued;
    -- farmed gems (dropped=true) are imbued from whatever's on hand / mule-supplied, never bought.
    ['Imbued Amber']         = { spell = 'Mass Imbue Amber',         gem = 8, perCast = 5, reagents = { { name = 'Amber',         per = 5 } } },
    ['Imbued Jade']          = { spell = 'Mass Imbue Jade',          gem = 8, perCast = 5, reagents = { { name = 'Jade',          per = 5 } } },
    ['Imbued Peridot']       = { spell = 'Mass Imbue Peridot',       gem = 8, perCast = 5, reagents = { { name = 'Peridot',       per = 5 } } },
    ['Imbued Topaz']         = { spell = 'Mass Imbue Topaz',         gem = 8, perCast = 5, reagents = { { name = 'Topaz',         per = 5 } } },
    ['Imbued Opal']          = { spell = 'Mass Imbue Opal',          gem = 8, perCast = 5, reagents = { { name = 'Opal',          per = 5 } } },
    ['Imbued Sapphire']      = { spell = 'Mass Imbue Sapphire',      gem = 8, perCast = 5, reagents = { { name = 'Sapphire',      per = 5 } } },
    ['Imbued Ruby']          = { spell = 'Mass Imbue Ruby',          gem = 8, perCast = 5, reagents = { { name = 'Ruby',          per = 5 } } },
    ['Imbued Emerald']       = { spell = 'Mass Imbue Emerald',       gem = 8, perCast = 5, reagents = { { name = 'Emerald',       per = 5 } } },
    -- Farmed / not vendor-sold - imbued from supplied gems (dropped), never bought:
    ['Imbued Black Pearl']   = { spell = 'Mass Imbue Black Pearl',  gem = 8, perCast = 5, reagents = { { name = 'Black Pearl',   per = 5, dropped = true } } },
    ['Imbued Plains Pebble'] = { spell = 'Mass Imbue Plains Pebble', gem = 8, perCast = 5, reagents = { { name = 'Plains Pebble', per = 5, dropped = true } } },
    ['Imbued Ivory']         = { spell = 'Mass Imbue Ivory',         gem = 8, perCast = 5, reagents = { { name = 'Ivory',         per = 5, dropped = true } } },
    ['Imbued Fire Opal']     = { spell = 'Mass Imbue Fire Opal',     gem = 8, perCast = 5, reagents = { { name = 'Fire Opal',     per = 5, dropped = true } } },
    ['Imbued Black Sapphire']= { spell = 'Mass Imbue Black Sapphire',gem = 8, perCast = 5, reagents = { { name = 'Black Sapphire',per = 5, dropped = true } } },
    ['Imbued Diamond']       = { spell = 'Mass Imbue Diamond',       gem = 8, perCast = 5, reagents = { { name = 'Diamond',       per = 5, dropped = true } } },
}

-- Invert merchants.ini into reagent -> { vendorName, ... }. Sections are
-- "[VendorName##zone]" with Item=price lines and a _Zone= field we skip.
local vendorsOf = {}
do
    -- Prefer this script's own folder (the Lazcraft package), then legacy <MQ>\config.
    local dir
    local okSrc, src = pcall(function() return debug.getinfo(1, 'S').source end)
    if okSrc and src then dir = tostring(src):gsub('^@', ''):match('^(.*[/\\])') end
    local mqPath = trim(mq.TLO.MacroQuest.Path() or '')
    local cands = {}
    -- The config lives in the Lazcraft package folder now. The listener runs from the lua ROOT,
    -- so look in <root>\lazcraft first (both slash styles), then next to the listener, then the
    -- legacy <MQ>\config location - so a stale root copy can't shadow the real merchant map.
    if dir and dir ~= '' then
        cands[#cands + 1] = dir .. 'lazcraft\\merchants.ini'
        cands[#cands + 1] = dir .. 'lazcraft/merchants.ini'
        cands[#cands + 1] = dir .. 'merchants.ini'
    end
    if mqPath ~= '' then cands[#cands + 1] = mqPath .. '\\lazcraft\\merchants.ini' end
    if mqPath ~= '' then cands[#cands + 1] = mqPath .. '\\config\\merchants.ini' end
    local path
    for _, c in ipairs(cands) do
        local tf = io.open(c, 'r')
        if tf then tf:close(); path = c; break end
    end
    local fh = path and io.open(path, 'r')
    if fh then
        local vendor = nil
        for raw in fh:lines() do
            local line = raw:gsub('\r$', '')
            local sec = line:match('^%[(.-)%]$')
            if sec then
                vendor = sec:match('^(.-)##') or sec
            elseif vendor then
                local k = line:match('^(.-)=')
                if k then
                    k = trim(k)
                    if k ~= '' and k:sub(1, 1) ~= '_' then
                        vendorsOf[k] = vendorsOf[k] or {}
                        vendorsOf[k][#vendorsOf[k] + 1] = vendor
                    end
                end
            end
        end
        fh:close()
        local nkeys = 0
        for _ in pairs(vendorsOf) do nkeys = nkeys + 1 end
        log('Loaded merchants.ini vendor map from %s (%d items).', path, nkeys)
    else
        log('merchants.ini not found - /ts_make cannot buy reagents.')
    end
end

local function nav_to_vendor(vendorName)
    local id = mq.TLO.Spawn('npc "' .. vendorName .. '"').ID() or 0
    if id == 0 then return false end
    if (mq.TLO.Spawn('id ' .. id).Distance() or 999) > 12 then
        clear_marr_zonein()
        mq.cmdf('/nav id %d', id)
        mq.delay(2000, function() return mq.TLO.Navigation.Active() end)
        local deadline = mq.gettime() + 20000
        while mq.gettime() < deadline do
            if not mq.TLO.Navigation.Active() then break end
            mq.doevents(); mq.delay(100)
        end
    end
    mq.cmdf('/target id %d', id)
    mq.delay(500, function() return (mq.TLO.Target.ID() or 0) == id end)
    return (mq.TLO.Target.Distance() or 999) <= 12
end

local function merchant_open() return mq.TLO.Window('MerchantWnd').Open() end

local function open_merchant()
    if merchant_open() then return true end
    for _ = 1, 3 do
        mq.cmd('/click right target')
        mq.delay(2500, function() return merchant_open() end)
        if merchant_open() then
            mq.delay(5000, function() return mq.TLO.Merchant.ItemsReceived() end)
            return true
        end
    end
    return false
end

local function close_merchant()
    if merchant_open() then
        mq.TLO.Window('MerchantWnd').DoClose()
        mq.delay(1500, function() return not merchant_open() end)
    end
end

-- Buy qty of name from the open merchant, using the quantity window to grab it
-- in one shot. Returns true once we hold target = start+qty.
local function buy_from_merchant(name, qty)
    if qty <= 0 then return true end
    local target = item_count(name) + qty
    local list = mq.TLO.Window('MerchantWnd/MW_ItemList')
    local row = tonumber(list.List('=' .. name, 2)() or 0) or 0
    if row == 0 then
        log('%s not sold by this merchant.', name)
        return false
    end
    list.Select(row)()
    mq.delay(1500, function()
        return (mq.TLO.Window('MerchantWnd/MW_SelectedItemLabel').Text() or ''):upper() == name:upper()
    end)
    local remaining = target - item_count(name)
    while remaining > 0 do
        bump_alive()   -- buying is activity; a large purchase shouldn't trip the idle timer
        mq.cmd('/notify MerchantWnd MW_Buy_Button leftmouseup')
        mq.delay(800, function() return mq.TLO.Window('QuantityWnd').Open() or item_count(name) >= target end)
        if mq.TLO.Window('QuantityWnd').Open() then
            mq.TLO.Window('QuantityWnd/QTYW_SliderInput').SetText(tostring(remaining))()
            mq.delay(500, function() return mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text() == tostring(remaining) end)
            mq.TLO.Window('QuantityWnd/QTYW_Accept_Button').LeftMouseUp()
            mq.delay(2000, function() return item_count(name) >= target end)
        else
            mq.delay(500, function() return item_count(name) > (target - remaining) end)
        end
        if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory'); mq.delay(300) end
        local newRemaining = target - item_count(name)
        if newRemaining >= remaining then
            log('No buy progress on %s (%d/%d).', name, item_count(name), target)
            return false
        end
        remaining = newRemaining
    end
    return true
end

-- /memspell overwrites whatever is in the gem; memming takes a few seconds, so
-- poll the gem until it shows our spell. No separate unmem needed.
local function mem_spell(gem, spellName)
    if (mq.TLO.Me.Gem(gem).Name() or '') == spellName then return true end
    mq.cmdf('/memspell %d "%s"', gem, spellName)
    mq.delay(10000, function() return (mq.TLO.Me.Gem(gem).Name() or '') == spellName end)
    if (mq.TLO.Me.Gem(gem).Name() or '') ~= spellName then
        log('Could not memorize %s into gem %d.', spellName, gem)
        return false
    end
    return true
end

-- Enchanter mana-regen clicky, used once each time we sit to med to speed the sit.
-- Must be the EXACT in-game item name, apostrophe included; set to '' for a character
-- that doesn't have the tome. The pcall guards the lookup in case MQ's TLO parser
-- trips on the apostrophe, and an on-cooldown /useitem is harmlessly ignored by the
-- game, so clicking once per med cycle (a no-op when not ready) is safe.
local MANA_TOME = "Tome of Nife's Mercy"

local function use_mana_tome()
    if MANA_TOME == '' then return end
    local okC, cnt = pcall(function() return mq.TLO.FindItemCount('=' .. MANA_TOME)() end)
    if not okC or (cnt or 0) <= 0 then return end   -- not carrying it (or name didn't resolve)
    -- Check the clicky's cooldown before using it. Gated this way it's safe to poll
    -- every med tick - it fires once, then stays quiet until the reuse timer is up.
    local okR, ready = pcall(function() return mq.TLO.Me.ItemReady(MANA_TOME)() end)
    if not okR or not ready then return end         -- on cooldown / not ready
    log('Clicking %s to speed mana regen...', MANA_TOME)
    mq.cmdf('/useitem "%s"', MANA_TOME)
    -- Wait for the cast to BEGIN, then for it to FINISH, before returning - the caller
    -- sits right after, and sitting mid-cast would interrupt the tome. If it turns out
    -- to be instant (no cast bar), the begin-wait just times out and we move on.
    mq.delay(3000, function() return (mq.TLO.Me.Casting.ID() or 0) > 0 end)
    if (mq.TLO.Me.Casting.ID() or 0) > 0 then
        mq.delay(12000, function() return (mq.TLO.Me.Casting.ID() or 0) == 0 end)
    end
    mq.delay(300)   -- let the buff/effect land
end

-- Pause and med when mana drops under 30%, resume when back over 90%. Cheap for
-- Enchant Clay, but keeps pricier producer spells from running dry.
local function med_if_low()
    if (mq.TLO.Me.PctMana() or 100) < 30 then
        log('Mana low (%d%%) - sitting to med...', mq.TLO.Me.PctMana() or 0)
        use_mana_tome()   -- click the regen clicky BEFORE sitting (it's a cast, fire it standing)
        mq.cmd('/sit')
        local deadline = mq.gettime() + 300000
        while mq.gettime() < deadline do
            if (mq.TLO.Me.PctMana() or 100) > 90 then break end
            bump_alive()   -- medding is activity; don't let the idle timer expire
            mq.doevents(); mq.delay(1000)
        end
        log('Mana back to %d%% - resuming.', mq.TLO.Me.PctMana() or 0)
    end
    if mq.TLO.Me.Sitting() then mq.cmd('/stand'); mq.delay(500) end
end

-- Cast until we hold wantTotal of product. Target-driven (verifies the count
-- climbed each cast) so it's robust to fizzles and per-cast yield.
-- Stow anything sitting on the cursor back into bags. A leftover stack on the
-- cursor blocks the next cast, which was capping a big batch partway through.
local function clear_cursor()
    local guard = 0
    while (mq.TLO.Cursor.ID() or 0) > 0 and guard < 10 do
        guard = guard + 1
        -- Stow only when NOT casting: /autoinventory won't stow reliably mid-cast (the summoned stack
        -- sits on the cursor). Wait for the exact "safe to stow" state - casting done AND something on
        -- the cursor - then dump to bags. Condition-based, not a guessed delay: it fires the instant
        -- both are true, so the stack never gets a chance to pile up.
        mq.delay(15000, function()
            return (mq.TLO.Me.Casting.ID() or 0) == 0 and (mq.TLO.Cursor.ID() or 0) > 0
        end)
        if (mq.TLO.Cursor.ID() or 0) == 0 then break end   -- nothing to stow (cleared already)
        mq.cmd('/autoinventory')
        mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
    end
end

local function cast_until(cfg, product, wantTotal)
    local attempts = 0
    -- Budget = ideal cast count + a buffer for the occasional genuine miss (interrupt, real fizzle).
    -- The loop exits the instant we reach wantTotal, so a roomy buffer never overshoots. (The old
    -- "lots of fizzles" were not real misses - the summoned stack sat on the cursor uncounted because
    -- /autoinventory won't stow mid-cast; clear_cursor now waits for Me.Casting to clear before stowing,
    -- so item_count reflects each cast's output and casts stop being miscounted as fizzles.)
    local idealCasts = math.ceil(wantTotal / cfg.perCast)
    local maxAttempts = idealCasts + 10
    while item_count(product) < wantTotal and attempts < maxAttempts do
        attempts = attempts + 1
        bump_alive()   -- each cast is activity; keeps the listener alive through a long batch
        local short
        for _, r in ipairs(cfg.reagents) do
            if item_count(r.name) < r.per then short = r.name; break end
        end
        if short then
            log('Out of %s - stopping.', short); break
        end
        med_if_low()
        -- Free the cursor before casting, or the cast won't fire. /autoinventory silently no-ops
        -- while a merchant/bank window is open (e.g. a lingering reagent-buy window), so close those
        -- first, then stow - this is what was leaving the cursor stuck between casts.
        close_merchant(); close_bank()
        clear_cursor()
        -- Wait for the gem's recast to actually be met before casting. Without this
        -- we'd /cast into a refreshing gem, nothing would start, and we'd wrongly
        -- call it a fizzle. Generous window; returns as soon as it's ready.
        mq.delay(30000, function() return mq.TLO.Me.SpellReady(cfg.spell)() end)
        if mq.TLO.Me.Sitting() then mq.cmd('/stand'); mq.delay(500) end
        local before = item_count(product)
        mq.cmdf('/cast %d', cfg.gem)
        -- Give the cast plenty of time to BEGIN (or the product to appear, for an
        -- instant cast) before we judge it - this is what was firing too early.
        mq.delay(6000, function()
            return (mq.TLO.Me.Casting.ID() or 0) > 0 or item_count(product) > before
        end)
        -- Then wait for it to finish.
        local cd = mq.gettime() + 15000
        while mq.gettime() < cd do
            if (mq.TLO.Me.Casting.ID() or 0) == 0 then break end
            mq.doevents(); mq.delay(100)
        end
        mq.delay(800)    -- let the result land
        close_merchant(); close_bank()
        clear_cursor()   -- try to stow (cursor-aware count already credited it if it didn't stow)
        local nowCount = item_count(product)
        if nowCount > before then
            log('Made %d %s (%d/%d).', nowCount - before, product, nowCount, wantTotal)
        else
            log('Cast yielded no %s - retrying.', product)
        end
    end
    -- The summoned stack tends to sit/accumulate on the cursor rather than auto-stowing. Make a
    -- determined effort to stow it before returning so it's in bags (counted and ready to deliver),
    -- not stuck on the cursor blocking the next action. Retry a few times with settle in between.
    for _ = 1, 5 do
        if (mq.TLO.Cursor.ID() or 0) == 0 then break end
        mq.delay(600)
        clear_cursor()
    end
    -- Final stow done; return the in-bags count (clear_cursor waited out any last cast, so the stack
    -- is stowed and counted, not stranded on the cursor).
    return item_count(product)
end

-- Make needQty of product: mem the spell, buy the reagent rounded up to a full
-- cast (need 102 -> buy/make 200), then cast it down. Returns how many we hold.
local function produce(product, needQty)
    local cfg = PRODUCE[product]
    if not cfg then log('No producer recipe for %s.', product); return 0 end
    local have = item_count(product)
    if have >= needQty then return have end

    local shortfall = needQty - have
    local casts     = math.ceil(shortfall / cfg.perCast)
    local buyQty    = casts * cfg.perCast

    if not mem_spell(cfg.gem, cfg.spell) then return item_count(product) end

    -- Buy every reagent this recipe consumes (a cast can use more than one, e.g.
    -- a gem + a poison vial). Each may live at a different vendor. A reagent flagged
    -- dropped is farmed/mule-supplied (e.g. Black Pearl), never sold - skip the buy and
    -- cast from whatever's on hand; cast_until stops when it runs out.
    for _, r in ipairs(cfg.reagents) do
        local needReagent = casts * r.per - item_count(r.name)
        if needReagent > 0 and not r.dropped then
            local vendors = vendorsOf[r.name]
            if not vendors then log('No vendor known for %s.', r.name); return item_count(product) end
            local bought = false
            for _, vname in ipairs(vendors) do
                if (mq.TLO.Spawn('npc "' .. vname .. '"').ID() or 0) > 0 then   -- in this zone
                    if nav_to_vendor(vname) and open_merchant() then
                        log('Buying %d %s from %s...', needReagent, r.name, vname)
                        bought = buy_from_merchant(r.name, needReagent)
                        close_merchant()
                        if bought then break end
                    end
                end
            end
            if not bought then
                log('Could not buy %s - no in-zone vendor reachable.', r.name)
                return item_count(product)
            end
        elseif needReagent > 0 and r.dropped then
            log('%s is dropped/supplied - imbuing the %d on hand (need %d for a full batch).',
                r.name, item_count(r.name), casts * r.per)
        end
    end

    log('Casting %s to make up to %d %s...', cfg.spell, buyQty, product)
    return cast_until(cfg, product, have + buyQty)
end

local crafterName = nil
local requestedItem = nil
local requestedEncoded = nil

mq.bind('/ts_need', function(sender, encoded, recipient, wantStr, keep)
    if not sender or not encoded then return end
    bump_alive()
    local item = decode(encoded)
    -- Optional 3rd arg: deliver to a DIFFERENT character than the requester (e.g. the crafter
    -- asks us to hand Black Pearl to the cleric). Responses still go to the requester (sender)
    -- so the crafter tracks completion. No recipient given -> deliver to the requester.
    local deliverTo = (recipient and recipient ~= '') and recipient or sender
    -- Optional 4th arg: the EXACT count wanted. nil / 0 / non-numeric -> legacy "one stack" delivery.
    local want = tonumber(wantStr)
    if want and want <= 0 then want = nil end
    log('/ts_need from %s for %s%s (deliver to %s)', sender, want and (want .. 'x ') or '', item, deliverTo)
    crafterName = sender
    requestedItem = item
    requestedEncoded = encoded   -- bind args arrive clean (no trailing apostrophe)

    local bags = item_count(item)
    local bank = bank_count(item)
    log('Bags: %d  Bank: %d', bags, bank)

    -- Top up from bank toward the target (the exact `want`, or a full stack in legacy mode).
    local target = want or 1000
    if bags < target and bank > 0 then
        log('Topping up from bank toward %d (have %d, bank %d)...', target, bags, bank)
        if nav_to_banker() and open_bank() then
            if want then
                -- pull EXACTLY the shortfall (capped at what's banked)
                local shortfall = want - item_count(item)
                if shortfall > 0 then withdraw_item(item, math.min(shortfall, bank_count(item))) end
            else
                -- legacy: pull whole stacks toward 1000
                while item_count(item) < 1000 and bank_count(item) > 0 do
                    local before = item_count(item)
                    withdraw_item(item)
                    if item_count(item) <= before then break end  -- no progress, bail
                end
            end
            close_bank()
            bags = item_count(item)
            log('After withdraw: %d in bags', bags)
        end
    end

    if bags == 0 then
        log('No %s available.', item)
        peer_cmdf(sender, '/ts_none %s', requestedEncoded)
        if keep ~= '1' then stop_listener() end   -- stay up if more items are coming this batch
        return
    end

    -- Deliver EXACTLY `want` if asked (capped at what we actually have); else one stack (legacy).
    local qty = want and math.min(bags, want) or math.min(bags, 1000)
    -- Ping the crafter so it knows we're en route and extends its wait.
    peer_cmdf(sender, '/ts_have %s %d', requestedEncoded, qty)
    log('Delivering %d %s to %s...', qty, item, deliverTo)
    local ok, placed = trade_item(deliverTo, item, qty)
    if ok then
        -- report what we ACTUALLY placed (may be < qty if a partial split couldn't be set), so the
        -- crafter's running total and "remaining" are exact.
        peer_cmdf(sender, '/ts_done %s %d', requestedEncoded, placed or qty)
    else
        peer_cmdf(sender, '/ts_fail %s', requestedEncoded)
    end
    if keep ~= '1' then stop_listener() end   -- stay up if more items are coming this batch
end)

-- FAST AVAILABILITY CHECK: report how many of an item we have (bags + bank) and reply immediately.
-- No bank open, no walking, no trade - pure data over the peer net, so it's sub-second. The crafter
-- fires this to every group member in parallel on craft start, then only queues a (slow) delivery
-- from members who actually have the item. FindItemBankCount reads the bank while it's CLOSED, which
-- is what makes this cheap. Replies with /ts_avail <encoded> <count>.
mq.bind('/ts_check', function(sender, encoded)
    if not sender or not encoded then return end
    bump_alive()
    local item = decode(encoded)
    local bags = item_count(item)
    local bank = bank_count(item)
    local total = bags + bank
    local myName = mq.TLO.Me.Name() or '?'
    peer_cmdf(sender, '/ts_avail %s %d %s', encoded, total, myName)
    log('/ts_check from %s for %s -> have %d (bags %d + bank %d)', sender, item, total, bags, bank)
    -- Do NOT stop the listener here: a delivery request usually follows immediately, and bouncing
    -- the listener between check and deliver would add the startup delay back. The crafter's normal
    -- keep/stop flow (or the idle timeout) shuts us down.
end)

-- Batched check: the crafter sends ONE /ts_check_multi with many items (pipe-separated encoded names)
-- instead of one /ts_check per item. Cuts peer traffic ~N-fold (a 30-item recipe = 1 command, not 30).
-- We reply with the SAME per-item /ts_avail the crafter already tallies, so only the request side is
-- batched - the proven reply path is unchanged. A single over-long command line is the only risk, so
-- the crafter chunks the list; each chunk is one /ts_check_multi.
mq.bind('/ts_check_multi', function(sender, list)
    if not sender or not list then return end
    bump_alive()
    local myName = mq.TLO.Me.Name() or '?'
    local n = 0
    for encoded in tostring(list):gmatch('[^|]+') do
        local item = decode(encoded)
        local total = item_count(item) + bank_count(item)
        peer_cmdf(sender, '/ts_avail %s %d %s', encoded, total, myName)
        if total > 0 then log('/ts_check_multi from %s: %s -> have %d', sender, item, total) end
        n = n + 1
    end
    log('/ts_check_multi from %s: answered %d item(s).', sender, n)
end)

-- "All" mode: hand over EVERY stack of an item we own -- bank included. We pull
-- the bank dry into our bags, trade it all over (up to 8 stacks per trip), and
-- repeat if our bags filled before the bank emptied. We ping /ts_have before each
-- trip so the crafter keeps waiting, and /ts_done with the grand total at the end.
mq.bind('/ts_need_all', function(sender, encoded, keep)
    if not sender or not encoded then return end
    bump_alive()
    local item = decode(encoded)
    log('/ts_need_all from %s for %s', sender, item)
    crafterName = sender
    requestedEncoded = encoded

    local totalDelivered = 0
    local rounds = 0
    while rounds < 25 do
        rounds = rounds + 1

        -- Pull every stack from the bank into bags (until the bank is clear of
        -- this item, or our bags fill and withdraw stops making progress).
        if bank_count(item) > 0 then
            if nav_to_banker() and open_bank() then
                while bank_count(item) > 0 do
                    local before = item_count(item)
                    withdraw_item(item)
                    if item_count(item) <= before then break end  -- bags full / no progress
                end
                close_bank()
            end
        end

        if item_count(item) == 0 then break end  -- nothing on hand to deliver

        -- Deliver everything in bags. trade_item moves up to 8 stacks per trip;
        -- loop until our bags are clear of this item.
        while item_count(item) > 0 do
            peer_cmdf(sender, '/ts_have %s 0', requestedEncoded)  -- still delivering
            local before = item_count(item)
            if not trade_item(sender, item, before) then break end
            local moved = before - item_count(item)
            totalDelivered = totalDelivered + moved
            if moved == 0 then break end  -- no progress, bail
        end

        if bank_count(item) == 0 then break end  -- bank empty too: fully done
    end

    if totalDelivered == 0 then
        log('No %s anywhere.', item)
        peer_cmdf(sender, '/ts_none %s', requestedEncoded)
    else
        log('Delivered all %d %s to %s.', totalDelivered, item, sender)
        peer_cmdf(sender, '/ts_done %s %d', requestedEncoded, totalDelivered)
    end
    if keep ~= '1' then stop_listener() end   -- stay up if more items are coming this batch
end)

-- Batch protocol: the crafter sends one /ts_qadd per item to build a list (no action),
-- then /ts_qrun to execute it as a single bank trip + trade. This avoids cramming a long
-- item list into one command line, and lets the mule grab everything in one go.
mq.bind('/ts_qadd', function(encoded, mode, qtyStr)
    if not encoded then return end
    bump_alive()
    local item = decode(encoded)
    local qty = tonumber(qtyStr)
    pendingBatch[#pendingBatch + 1] = { item = item, encoded = encoded,
        mode = (mode == 'all') and 'all' or 'stack', qty = (qty and qty > 0) and math.floor(qty) or nil }
    log('Batch queue + %s (%s%s) [%d total]', item, mode or 'stack',
        (qty and qty > 0) and (' x' .. math.floor(qty)) or '', #pendingBatch)
end)

mq.bind('/ts_qrun', function(sender)
    if not sender then return end
    bump_alive()
    crafterName = sender
    local batch = pendingBatch
    pendingBatch = {}                      -- clear for the next batch
    if #batch == 0 then
        log('/ts_qrun from %s but nothing queued.', sender)
        peer_cmdf(sender, '/ts_qdone 0')
        return
    end
    log('/ts_qrun from %s: delivering %d queued item(s) as one batch.', sender, #batch)
    local total = deliver_batch(sender, batch)
    peer_cmdf(sender, '/ts_qdone %d', total)
    -- Stay alive (keep) - the crafter sends /ts_cancel when it's done with us.
end)

mq.bind('/ts_make', function(sender, encoded, qtyStr)
    if not sender or not encoded then return end
    bump_alive()
    local item = decode(encoded)
    local qty  = tonumber(qtyStr) or 0
    log('/ts_make from %s for %d %s', sender, qty, item)
    crafterName = sender
    requestedEncoded = encoded
    if qty <= 0 then peer_cmdf(sender, '/ts_makefail %s %s', mq.TLO.Me.Name() or '?', encoded); return end

    -- Capability ≠ scribed: a class match doesn't mean THIS toon has the spell. Check the spellbook
    -- up front and bail immediately (with our name) so the crafter can reassign this share to another
    -- capable caster instead of us silently casting nothing.
    local cfgCheck = PRODUCE[item]
    if cfgCheck and cfgCheck.spell and (mq.TLO.Me.Book(cfgCheck.spell)() or 0) == 0 then
        log('Cannot make %s - "%s" is not in my spellbook.', item, cfgCheck.spell)
        peer_cmdf(sender, '/ts_makefail %s %s', mq.TLO.Me.Name() or '?', encoded)
        return
    end

    -- Tell the crafter we accepted the job so it can stop waiting and queue the next one.
    peer_cmdf(sender, '/ts_makestart %s', encoded)

    -- QUEUE it rather than making it inline. The main loop drains the queue one job at a time,
    -- so several /ts_make requests in a row are made sequentially (first, then second, ...) instead
    -- of the second arriving mid-cast and clobbering the first. We do NOT stop here - the listener
    -- stays up to work the queue and is closed by /ts_cancel once the crafter's whole batch is done.
    makeQueue[#makeQueue + 1] = { item = item, qty = qty, sender = sender, encoded = encoded }
    log('Queued make: %d %s [%d in queue]', qty, item, #makeQueue)
end)

mq.bind('/ts_cancel', function(sender)
    if sender == crafterName then stop_listener() end
end)

-- TEST: pull an EXACT count from THIS toon's own bank. Usage on the mule: /ts_wtest <item> <count>
-- (item words joined by _ or spaces). Verifies the exact-withdraw before it's wired into delivery.
mq.bind('/ts_wtest', function(...)
    local args = { ... }
    if #args < 2 then log('usage: /ts_wtest <item> <count>'); return end
    local count = tonumber(args[#args]); args[#args] = nil
    local item = table.concat(args, ' '):gsub('_', ' ')
    if not count then log('/ts_wtest: last arg must be a number'); return end
    log('/ts_wtest: pulling %d x %s from bank...', count, item)
    if nav_to_banker() and open_bank() then
        local got = withdraw_item(item, count)
        close_bank()
        log('/ts_wtest: withdrew %d x %s (asked %d).', got, item, count)
    else
        log('/ts_wtest: could not reach/open bank.')
    end
end)

mq.cmd('/e3p on')   -- pause E3 for the whole time the listener operates
log('Listening...')
local madeAnything   = false
local makeIdleSince  = nil
while running and mq.gettime() < aliveDeadline do
    mq.doevents()

    -- Work queued summon/produce jobs one at a time, in the order requested. Each cast inside
    -- produce() pumps mq.doevents() and bump_alive(), so further /ts_make requests that arrive
    -- mid-cast get queued behind the current one rather than interrupting it.
    if #makeQueue > 0 then
        local job = table.remove(makeQueue, 1)
        bump_alive()
        log('Making %d %s for %s (%d still queued)...', job.qty, job.item, job.sender, #makeQueue)
        produce(job.item, job.qty)
        local onHand = item_count(job.item)
        if onHand <= 0 then
            log('Failed to make any %s.', job.item)
            peer_cmdf(job.sender, '/ts_makefail %s %s', mq.TLO.Me.Name() or '?', job.encoded)
        else
            log('Finished making %s - %d on hand.', job.item, onHand)
            peer_cmdf(job.sender, '/ts_madedone %s %d', job.encoded, onHand)
            mq.cmdf('/tell %s All finished making %s - %d on hand. Request it to have it delivered.', job.sender, job.item, onHand)
        end
        madeAnything, makeIdleSince = true, nil
        bump_alive()
    elseif madeAnything then
        -- Queue drained after doing makes. The crafter can't /ts_cancel us (our production is
        -- async), so close ourselves - but wait a short grace window first in case another summon
        -- request is still on its way, so a trailing /ts_make isn't dropped.
        makeIdleSince = makeIdleSince or mq.gettime()
        if (mq.gettime() - makeIdleSince) > 15000 then
            log('Make queue drained and idle - closing listener.')
            stop_listener()
        end
    end

    -- Incoming trade from another character (e.g. a mule delivering to us): confirm OUR side by
    -- clicking the Trade button, keeping E3 paused. (Was /e3p off to let E3 accept - but a live E3 can
    -- grab the cursor / drive the toon; clicking the button ourselves is deterministic and leaves E3
    -- untouched. This is the RECEIVER half; trade_item's confirm is the SENDER half.)
    if mq.TLO.Window('TradeWnd').Open() then
        log('Incoming trade - clicking Trade to accept.')
        mq.delay(300)
        mq.cmd('/notify TradeWnd TRDW_Trade_Button leftmouseup')
        mq.delay(8000, function() return not mq.TLO.Window('TradeWnd').Open() end)
        if mq.TLO.Window('TradeWnd').Open() then
            mq.cmd('/notify TradeWnd TRDW_Trade_Button leftmouseup')
            mq.delay(4000, function() return not mq.TLO.Window('TradeWnd').Open() end)
        end
        log('Trade window closed.')
    end
    mq.delay(100)
end
mq.cmd('/e3p off')  -- resume E3 before we close out
log('Done.')
