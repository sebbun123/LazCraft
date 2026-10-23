-- Inventory: read-only questions about what is in the bags.
--   count(name)       how many are in bags and loose pack slots (not worn, not on the cursor)
--   find(name, skip)  every place it sits: { {pack=, slot=, stack=}, ... }  (slot nil = loose in a pack slot);
--                     `skip` = a pack number to leave out (the kit, when taking ingredients out to put in it)
--   free_slots()      the client's own free-slot count
--   bag(pack)         { name, slots, used, open } for one pack slot that holds a bag, or nil
--   client_total(name)  the client's own count (FindItemCount) minus the cursor; only for cross-checks
--
-- Rules it keeps:
--   * FindItemCount also counts worn gear and the cursor, so counting walks the bags itself.
--   * Names are compared without case: some UI labels differ in case from the item name.
-- Not a rule: the old code claimed per-slot reads go blank while a tradeskill window is open. Tested in game
-- (2.03.1, Brew Barrel open): slot-by-slot and the client's total agreed. stationtest keeps checking it.
local Inventory = {}
Inventory.__index = Inventory

Inventory.PACKS = 10   -- general inventory slots pack1..pack10

function Inventory.new(mq)
    return setmetatable({ mq = mq }, Inventory)
end

local function lower(s) return (s or ''):lower() end

local function stack_of(item)
    local n = item.Stack() or 1
    return n < 1 and 1 or n
end

function Inventory:find(name, skip)
    local want, out = lower(name), {}
    local Me = self.mq.TLO.Me
    for pk = 1, Inventory.PACKS do
        local slot = Me.Inventory('pack' .. pk)
        if pk ~= skip and (slot.ID() or 0) > 0 then
            local cap = slot.Container() or 0
            if cap > 0 then
                for i = 1, cap do
                    local it = slot.Item(i)
                    if (it.ID() or 0) > 0 and lower(it.Name()) == want then
                        out[#out + 1] = { pack = pk, slot = i, stack = stack_of(it) }
                    end
                end
            elseif lower(slot.Name()) == want then
                out[#out + 1] = { pack = pk, slot = nil, stack = stack_of(slot) }
            end
        end
    end
    return out
end

function Inventory:count(name, skip)
    local total = 0
    for _, p in ipairs(self:find(name, skip)) do total = total + p.stack end
    return total
end

function Inventory:client_total(name)
    local TLO = self.mq.TLO
    local total = TLO.FindItemCount('=' .. name)() or 0
    if lower(TLO.Cursor.Name()) == lower(name) then total = total - (TLO.Cursor.Stack() or 1) end
    return math.max(0, total)
end

-- Every item in the bags at once: counts[lower name] = total. One pass over the bags, for planning (where
-- asking item by item would re-read every slot for every item).
function Inventory:snapshot()
    local counts = {}
    local Me = self.mq.TLO.Me
    local function add(it)
        local k = lower(it.Name())
        if k ~= '' then counts[k] = (counts[k] or 0) + stack_of(it) end
    end
    for pk = 1, Inventory.PACKS do
        local slot = Me.Inventory('pack' .. pk)
        if (slot.ID() or 0) > 0 then
            local cap = slot.Container() or 0
            if cap > 0 then
                for i = 1, cap do
                    local it = slot.Item(i)
                    if (it.ID() or 0) > 0 then add(it) end
                end
            else
                add(slot)
            end
        end
    end
    return counts
end

function Inventory:free_slots()
    return self.mq.TLO.Me.FreeInventory() or 0
end

function Inventory:bag(pack)
    local b = self.mq.TLO.Me.Inventory('pack' .. pack)
    local cap = b.Container() or 0
    if (b.ID() or 0) == 0 or cap == 0 then return nil end
    return { pack = pack, name = b.Name(), slots = cap, used = b.Items() or 0,
             open = self.mq.TLO.Window('Pack' .. pack).Open() == true }
end

return Inventory
