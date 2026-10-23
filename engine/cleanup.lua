-- Cleanup: what one recipe of a leveling path leaves behind, done by hand (a button on each row; nothing runs
-- on its own, and nothing happens before Go).
--   Cleanup.job(env, recipe, keep, opts) -> job; its preview lists every item and what happens to it
--   Cleanup.job_many(env, name, recipes, keep, opts) -> one job for several recipes (2.43.5: the Leveling tab's
--     "Clean up finished rows" - every row at its trivial under one preview and one Go, one merchant trip; an item
--     two rows share is listed once, a product of one row that another uses goes as a product)
--     env  = { blocks, cfg, planner, log }
--     keep = { lower item name = why } - items another row of the path still needs (that row not at its trivial)
--     opts = { maxPrice = copper: an ingredient is sold only when a merchant sells it for less than this a unit
--              (dearer ones are kept - 2.42.16, the after-row clean-up: 20pp, what they charge),
--              destroyProduct = the row says destroy: its product is destroyed, not sold,
--              subs = true: products of its sub-combines (an ingredient a recipe makes and no merchant sells)
--              go as the product does }
--   Cleanup.after_row(env, ctx, recipe, keep, opts) -> R: the same, run inside a leveling path after each row
--     (2.42.16): nothing to do is a debug line, not an error; a failure is said and the path goes on.
--
-- Rules it keeps:
--   * The recipe's product is sold to a merchant here. One the merchant will not take is DESTROYED - only when
--     the item data gives it no sell value too (the data alone is not proof: a missing value reads as 0; the
--     merchant's refusal alone is not either: a lost click looks the same). A stack of it worn in Ammo (a
--     throwing item /autoinventory topped up there) comes off first.
--   * Its ingredients are sold only when a merchant sells them (they can be bought again) - never ore, gems,
--     drops or anything else nobody sells, which stay.
--   * Tools are never touched; nothing in the bank; nothing worn but the product in Ammo.
--   * An item another row still needs is kept, and the preview says which row.
--   * A sale or destroy that fails is said and the item kept; the rest carries on.
local R = require('core.result')

local Cleanup = {}

local function lower(s) return (s or ''):lower() end

-- What happens to each item: { sell = { {name, n} }, destroy = { {name, n} }, kept = { {name, n, why} } }
function Cleanup.plan(env, recipe, keep, opts)
    return Cleanup.plan_many(env, { recipe }, keep, opts)
end

function Cleanup.plan_many(env, recipes, keep, opts)
    local B, cfg = env.blocks, env.cfg
    keep = keep or {}
    opts = opts or {}
    local out = { sell = {}, destroy = {}, kept = {} }   -- destroy: filled at the merchant (refused, no value)
    local function have(name)
        local n = B.inventory:count(name)
        if B.gear and lower(B.gear:worn('ammo') or '') == lower(name) then
            local ok, s = pcall(function() return env.mq.TLO.Me.Inventory('ammo').Stack() end)
            n = n + (ok and tonumber(s) or 1)
        end
        return n
    end
    local seen = {}
    local function consider(name, isProduct)
        local k = lower(name)
        if seen[k] then return end
        seen[k] = true
        local n = have(name)
        if n <= 0 then return end
        if keep[k] then out.kept[#out.kept + 1] = { name = name, n = n, why = keep[k] }; return end
        local it = cfg.items and cfg.items[k]
        local value = it and tonumber(it.value)
        local vendors = env.planner:vendors(name)
        -- a sub-combine's product (made by a recipe, sold by nobody) goes as the product does
        if not isProduct and opts.subs and #vendors == 0 and cfg.recipesByName and cfg.recipesByName[k] then isProduct = true end
        if isProduct then
            if opts.destroyProduct then out.destroy[#out.destroy + 1] = { name = name, n = n }
            else out.sell[#out.sell + 1] = { name = name, n = n, unknown = value == nil, destroyIfRefused = not value or value == 0 } end
        elseif #vendors > 0 then
            local price = opts.maxPrice and env.planner.unit_price and env.planner:unit_price(name, vendors)
            if value == 0 then out.kept[#out.kept + 1] = { name = name, n = n, why = 'no merchant buys it' }
            elseif opts.maxPrice and (not price or price >= opts.maxPrice) then
                out.kept[#out.kept + 1] = { name = name, n = n, why = price and string.format('%dpp a unit to buy again (%dpp or more is kept)',
                    math.floor(price / 1000), math.floor(opts.maxPrice / 1000)) or 'its price is not known' }
            else out.sell[#out.sell + 1] = { name = name, n = n, unknown = value == nil } end
        else
            out.kept[#out.kept + 1] = { name = name, n = n, why = 'no merchant sells it (farmed)' }
        end
    end
    -- every product first (one row's product used by another goes as a product), then tools (never touched),
    -- then ingredients
    for _, recipe in ipairs(recipes) do consider(recipe.name, true) end
    for _, recipe in ipairs(recipes) do
        for _, t in ipairs(recipe.tools or {}) do seen[lower(t.name)] = true end
    end
    for _, recipe in ipairs(recipes) do
        for _, i in ipairs(recipe.ins or {}) do consider(i.name, false) end
    end
    return out
end

function Cleanup.lines(p)
    local lines = {}
    for _, s in ipairs(p.sell) do
        lines[#lines + 1] = { level = s.destroyIfRefused and 'warn' or 'ok', text = string.format('Sell %d %s%s', s.n, s.name,
            s.destroyIfRefused and ' - DESTROYED if the merchant will not take it (no sell value in the item data)'
            or (s.unknown and ' (no price known - kept if the merchant will not take it)' or '')) }
    end
    for _, d in ipairs(p.destroy) do
        lines[#lines + 1] = { level = 'warn', text = string.format('Destroy %d %s (the row says destroy)', d.n or 0, d.name) }
    end
    for _, k in ipairs(p.kept) do
        lines[#lines + 1] = { level = 'ok', text = string.format('Keep %d %s - %s', k.n, k.name, k.why) }
    end
    if #p.sell == 0 and #p.destroy == 0 then lines[#lines + 1] = { level = 'done', text = 'Nothing to clean up' } end
    return lines
end

function Cleanup.job(env, recipe, keep, opts)
    return Cleanup.job_many(env, 'Clean up ' .. recipe.label, { recipe }, keep, opts)
end

function Cleanup.job_many(env, name, recipes, keep, opts)
    local B, log = env.blocks, env.log
    local p
    local opened = {}
    local products = {}
    for _, r in ipairs(recipes) do products[lower(r.name)] = r.name end
    return {
        name = name, confirm = true, usesToon = true,
        preflight = function()
            p = Cleanup.plan_many(env, recipes, keep, opts)
            local lines = Cleanup.lines(p)
            if #recipes > 1 then
                local names = {}
                for _, r in ipairs(recipes) do names[#names + 1] = r.label end
                table.insert(lines, 1, { level = 'ok', text = string.format('%d rows at their trivial: %s', #recipes, table.concat(names, ', ')) })
            end
            return lines
        end,
        execute = function(ctx)
            p = Cleanup.plan_many(env, recipes, keep, opts)   -- again: the bags may have changed while waiting for Go
            local sold, destroyed, problems = 0, 0, {}
            -- a product worn in Ammo comes off first (the merchant and /destroy work from the bags)
            local worn = B.gear and lower(B.gear:worn('ammo') or '')
            if worn and products[worn] then
                local u = B.gear:unequip(ctx, 'ammo')
                if u.ok then log.info('Took the %s stack out of the Ammo slot', products[worn])
                else problems[#problems + 1] = 'Ammo: ' .. R.describe(u) end
            end
            if #p.sell > 0 then
                local zone = B.travel:zone()
                local function nearest()
                    local best
                    for _, npc in ipairs((env.cfg.merchantsByZone or {})[zone] or {}) do
                        local sp = B.spawns:find(npc)
                        if sp and (not best or sp.distance < best.distance) then best = sp end
                    end
                    return best
                end
                local m, e = B.spawns:await(ctx, 'a merchant', nearest)
                if e then return e end
                if not m then
                    problems[#problems + 1] = 'no merchant from merchants.ini in ' .. zone .. ' - nothing sold'
                else
                    ctx:status('Selling to ' .. m.name)
                    local g = B.nav:go_spawn(ctx, m.id, 10)
                    if not g.ok then return g end
                    local o = B.merchant:open(ctx, m.id)
                    if not o.ok then return o end
                    for _, s in ipairs(p.sell) do
                        if not ctx:checkpoint() then B.merchant:close(ctx); return R.fail('stopped') end
                        local n = B.inventory:count(s.name)
                        if n > 0 then
                            local r = B.merchant:sell(ctx, s.name, n)
                            if r.ok then sold = sold + n; log.info('Sold %d %s to %s', n, s.name, m.name)
                            else
                                if r.why == 'stopped' then B.merchant:close(ctx); return r end
                                if s.destroyIfRefused and B.inventory:count(s.name) > 0 then
                                    log.info('%s: the merchant will not take it (%s) and it has no sell value - destroying it', s.name, R.describe(r))
                                    p.destroy[#p.destroy + 1] = { name = s.name }
                                else
                                    log.warn('Kept %s: %s', s.name, R.describe(r)); problems[#problems + 1] = s.name .. ' not sold'
                                end
                            end
                        end
                    end
                    B.merchant:close(ctx)
                end
            end
            if #p.destroy > 0 and B.gear then   -- a product to destroy worn in Ammo: off first, like a sale
                for _, d in ipairs(p.destroy) do
                    if lower(B.gear:worn('ammo') or '') == lower(d.name) and not products[lower(d.name)] then
                        local u = B.gear:unequip(ctx, 'ammo')
                        if not u.ok then problems[#problems + 1] = 'Ammo: ' .. R.describe(u) end
                    end
                end
            end
            for _, d in ipairs(p.destroy) do
                while true do
                    if not ctx:checkpoint() then return R.fail('stopped') end
                    local places = B.inventory:find(d.name)
                    if #places == 0 then break end
                    local got = B.cursor:pick_up(ctx, d.name, places[1].stack)
                    local pk = got.openedPack or (got.value and got.value.openedPack)
                    if pk then opened[pk] = true end
                    if not got.ok then log.warn('Kept %s: %s', d.name, R.describe(got)); problems[#problems + 1] = d.name .. ' not destroyed'; break end
                    local held = B.cursor:item()
                    if not held or lower(held.name) ~= lower(d.name) then
                        problems[#problems + 1] = d.name .. ': something else was picked up'
                        B.cursor:stow(ctx)
                        break
                    end
                    local x = B.combine:destroy(ctx, held)
                    if not x.ok then log.warn('Kept %s: %s', d.name, R.describe(x)); problems[#problems + 1] = d.name .. ' not destroyed'; B.cursor:stow(ctx); break end
                    destroyed = destroyed + held.stack
                    log.info('Destroyed %d %s', held.stack, d.name)
                end
            end
            local s = string.format('sold %d, destroyed %d%s', sold, destroyed, #problems > 0 and ('; ' .. table.concat(problems, '; ')) or '')
            return R.ok({ summary = s })
        end,
        cleanup = function(ctx)
            if B.merchant:is_open() then B.merchant:close(ctx) end
            B.cursor:stow(ctx)
            for pk in pairs(opened) do B.windows:close_bag(ctx, pk) end
            return R.ok()
        end,
    }
end

-- Every item a recipe needs, all the way down (2.43.1): its ingredients and tools, and theirs for every recipe that
-- makes one of them - a row not at its trivial keeps all of these, so another row's clean-up never sells a part it
-- will make or use (the user's rule: Metal Bits at trivial, Banded Mail not - Metal Bits' parts go, Banded Mail's
-- stay, down to what its subcombines are made of; an item a merchant sells is bought, so its parts are not
-- counted). -> { lower name = true }
function Cleanup.needs(cfg, recipe, out, depth)
    out = out or {}
    depth = depth or 0
    if not recipe or depth > 6 then return out end
    for _, list in ipairs({ recipe.ins or {}, recipe.tools or {} }) do
        for _, x in ipairs(list) do
            local k = lower(x.name)
            if not out[k] then
                out[k] = true
                -- one a merchant sells is bought, never made (the planner's rule): its own parts are not needed
                local sold = cfg and cfg.merchants and #(cfg.merchants[k] or {}) > 0
                for _, id in ipairs(not sold and cfg and cfg.recipesByName and cfg.recipesByName[k] or {}) do
                    Cleanup.needs(cfg, cfg.recipes[id], out, depth + 1)
                end
            end
        end
    end
    return out
end

-- Inside a leveling path, after a row: the row's leftovers go so the bags do not fill up row after row (2.42.16;
-- the Blacksmithing log: products and spare ingredients of nine rows left 4 slots free for the tenth).
function Cleanup.after_row(env, ctx, recipe, keep, opts)
    local log = env.log
    local p = Cleanup.plan(env, recipe, keep, opts)
    for _, k in ipairs(p.kept) do log.debug('Clean-up after %s: keep %d %s - %s', recipe.label, k.n, k.name, k.why) end
    if #p.sell == 0 and #p.destroy == 0 then
        log.debug('Clean-up after %s: nothing to sell or destroy', recipe.label)
        return R.ok({ summary = 'nothing to clean up' })
    end
    local parts = {}
    for _, s in ipairs(p.sell) do parts[#parts + 1] = string.format('sell %d %s', s.n, s.name) end
    for _, d in ipairs(p.destroy) do parts[#parts + 1] = string.format('destroy %d %s', d.n or 0, d.name) end
    log.info('Clean-up after %s: %s', recipe.label, table.concat(parts, ', '))
    local job = Cleanup.job(env, recipe, keep, opts)
    local r = job.execute(ctx)
    local c = job.cleanup(ctx)
    if r.ok and c and not c.ok then return c end
    return r
end

return Cleanup
