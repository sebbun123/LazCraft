-- The window (2.43.0: themed, AdventureTime-style). It only reads (the runner's snapshot, the crew's cards, what
-- `actions` returns) and hands clicks to `actions`, which queue jobs; it never does anything in game itself.
--
-- Layout: a header that is always there (the logo, who and where, Close all; the job panel with its preflight,
-- Go / Cancel, Pause / Stop), then tabs: Craft, Leveling, Research, Summon, Workers (crafter), Log, Travel,
-- Settings. A tab whose action is missing is left out. Sections are titled lines (---- Name ----), lists are
-- striped tables, states are pills. The theme (ui/theme) is pushed once around the window.
--
-- Everything drawn that a build may not have (tables, SeparatorText, the draw list, textures) falls back to plain
-- text, so a missing ImGui feature costs looks, never the window.
local Theme = require('ui.theme')

local Window = {}
Window.__index = Window

local LEVEL_COLOR = {
    debug = { 0.58, 0.60, 0.65 }, info = { 0.86, 0.87, 0.89 },
    warn = { 0.90, 0.76, 0.35 }, error = { 0.93, 0.50, 0.50 },
}
local CHECK_COLOR = {
    ok = { 0.49, 0.81, 0.49 }, warn = { 0.90, 0.76, 0.35 }, block = { 0.93, 0.54, 0.54 },
}
local MUTED = { 0.58, 0.60, 0.65 }
-- pills, 0-255
local PILL = { ok = { 124, 207, 124 }, warn = { 230, 194, 90 }, bad = { 236, 138, 138 }, muted = { 150, 155, 165 },
               info = { 150, 180, 230 } }
local PHASE = {   -- the job's phase: its pill
    planning = { 'Checking', 'info' }, preflight = { 'Checking', 'info' }, awaiting = { 'Waiting for Go', 'warn' },
    running = { 'Running', 'ok' },
}
local LOG_LINES = 200
local LOG_SHOW = { { 'all', 'Every line' }, { 'info', 'Info and up' }, { 'warn', 'Warnings only' } }
local LOG_RANK = { debug = 1, info = 2, warn = 3, error = 4 }

-- deps: ImGui, runner, log, version, role, crew, settings (live table), settingsMeta, onSetting(key, value),
--       mq (textures), me, logoPath, logoAspect (width / height), crafter() -> name,
--       actions = { search(q, skill) -> recipes, total; skills() -> names; plan(recipe, n), make(recipe, n),
--                   preview(recipe, n) -> ingredient rows; estimate(recipe, n) -> cost, coin;
--                   held() / hold(on) (a worker's Pause), closeAll() (the crafter's Close all),
--                   summon() -> rows { group, item, me, workers = { names } }, refreshSummon(),
--                   cast(item, n), order(worker, item, n), startWorker(name),
--                   zones() -> { zone, ... }, here() -> zone, travel(zone) }
function Window.new(deps)
    local self = setmetatable({}, Window)
    for k, v in pairs(deps) do self[k] = v end
    self.actions = self.actions or {}
    self.visible = true
    self.drawError = nil
    self.query, self.lastKey, self.results, self.total, self.picked, self.combines = '', nil, {}, 0, nil, 1
    self.skill = nil       -- craft: the tradeskill picked (nil = all, search only)
    self.disposal = 'keep'   -- craft: what happens to the product
    self.lvlSkill, self.lvlRows, self.lvlState = nil, {}, {}   -- leveling: the skill shown, its rows, each row's choices
    self.counts = {}       -- summon: item -> count typed
    self.rs = { type = 'both', level = 0, qty = 1, counts = {} }   -- research: class, type, level shown, Qty each
    self.workerName = ''
    self.logShow = 'info'
    self.logoTex = nil     -- nil = not tried yet, false = none (the "LC" mark instead)
    self.pal = Theme.palette(self.settings and self.settings.Theme)
    return self
end

local DISPOSALS = { 'keep', 'sell', 'destroy' }
local function cap(s) return s:sub(1, 1):upper() .. s:sub(2) end

local function colored(ImGui, c, text)
    ImGui.TextColored(c[1], c[2], c[3], 1.0, text)
end

-- InputText returns the text, or (text, changed) on newer builds.
local function input_text(ImGui, label, text)
    local v = ImGui.InputText(label, text or '')
    if type(v) == 'string' then return v end
    return text or ''
end

local function input_count(ImGui, label, cur, width)
    if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(width or 90) end
    local val = ImGui.InputInt(label, cur, 1, 10)
    if type(val) ~= 'number' then return cur end
    return math.max(1, math.floor(val))
end

-- ---------------------------------------------------------------- drawing helpers

-- A line in the log the first time something is drawn (2.43.1): the client went down on the first 2.43.0 start;
-- the log file is flushed line by line, so the last of these names what was being drawn when it did.
function Window:once(key, fmt, ...)
    self.seen = self.seen or {}
    if self.seen[key] then return end
    self.seen[key] = true
    if self.log and self.log.debug then self.log.debug('Window: ' .. fmt, ...) end
end

-- One colour pushed (0-1 floats in): as one IM_COL32 value, as AdventureTime pushes it; floats where there is no
-- IM_COL32 (tests). -> true when it went on (the caller pops it)
local function push_col(ImGui, slot, r, g, b, a)
    if not slot then return false end
    if IM_COL32 then
        return pcall(function() ImGui.PushStyleColor(slot, IM_COL32(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
            math.floor(b * 255 + 0.5), math.floor(a * 255 + 0.5))) end)
    end
    return pcall(ImGui.PushStyleColor, slot, r, g, b, a)
end

-- A titled section line: ---- Name ----, in the theme's label colour (AT's ui_heading).
function Window:heading(text)
    local ImGui, p = self.ImGui, self.pal
    local Col = ImGuiCol
    if ImGui.Spacing then ImGui.Spacing() end
    if self.sepTextOK ~= false and ImGui.SeparatorText then
        local pushed = Col and push_col(ImGui, Col.Text, p.label[1], p.label[2], p.label[3], 1.0)
        local ok = pcall(ImGui.SeparatorText, text)
        if pushed then pcall(ImGui.PopStyleColor, 1) end
        if ok then self.sepTextOK = true; return end
        self.sepTextOK = false
    end
    ImGui.Separator()
    colored(ImGui, p.label, text)
end

-- A smaller title inside a list (a trivial band), muted.
function Window:subheading(text)
    local ImGui = self.ImGui
    local Col = ImGuiCol
    if self.sepTextOK ~= false and ImGui.SeparatorText then
        local pushed = Col and push_col(ImGui, Col.Text, MUTED[1], MUTED[2], MUTED[3], 1.0)
        local ok = pcall(ImGui.SeparatorText, text)
        if pushed then pcall(ImGui.PopStyleColor, 1) end
        if ok then return end
    end
    ImGui.TextDisabled('-- ' .. text .. ' --')
end

-- A rounded pill (AT's ui_pill): a tinted ground, the word in its colour. Plain coloured text where the draw
-- list is not there.
function Window:pill(text, kind)
    local ImGui = self.ImGui
    local c = PILL[kind] or PILL.muted
    local ok = pcall(function()
        local tw = ImGui.CalcTextSize(text)
        if type(tw) ~= 'number' then tw = tw.x end
        local fs = ImGui.GetFontSize()
        local pw, ph = tw + 14, fs + 3
        local cx, cy = ImGui.GetCursorScreenPos()
        local dl = ImGui.GetWindowDrawList()
        dl:AddRectFilled(ImVec2(cx, cy), ImVec2(cx + pw, cy + ph), IM_COL32(c[1], c[2], c[3], 46), ph * 0.5)
        dl:AddText(ImVec2(cx + 7, cy + 1), IM_COL32(c[1], c[2], c[3], 255), text)
        ImGui.Dummy(pw, ph)
    end)
    if not ok then ImGui.TextColored(c[1] / 255, c[2] / 255, c[3] / 255, 1.0, text) end
end

-- A progress bar (2.43.1): a rounded track in the frame colour, a rounded fill in the theme's accent with a lighter
-- top edge, the text centred over both with a soft shadow; the stock ProgressBar where the draw list is not there.
-- w = nil fills the line.
function Window:bar(frac, text, w)
    local ImGui = self.ImGui
    frac = math.max(0, math.min(1, tonumber(frac) or 0))
    local ok = pcall(function()
        local fs = ImGui.GetFontSize()
        local h = fs + 6
        local aw = w
        if not aw then
            local a = ImGui.GetContentRegionAvail()
            aw = type(a) == 'number' and a or a.x
        end
        local x, y = ImGui.GetCursorScreenPos()
        local dl = ImGui.GetWindowDrawList()
        local a, r = self.pal.accent, h * 0.5
        local c = function(v) return math.floor(v * 255 + 0.5) end
        local ar, ag, ab = c(a[1]), c(a[2]), c(a[3])
        dl:AddRectFilled(ImVec2(x, y), ImVec2(x + aw, y + h), IM_COL32(0, 0, 0, 90), r)
        dl:AddRect(ImVec2(x, y), ImVec2(x + aw, y + h), IM_COL32(ar, ag, ab, 70), r)
        if frac > 0 then
            local fw = math.max(h, aw * frac)
            dl:AddRectFilled(ImVec2(x, y), ImVec2(x + fw, y + h), IM_COL32(ar, ag, ab, 215), r)
            -- a lighter band along the top of the fill
            dl:AddRectFilled(ImVec2(x + r * 0.5, y + 2), ImVec2(x + fw - r * 0.5, y + h * 0.42),
                IM_COL32(math.min(255, ar + 60), math.min(255, ag + 60), math.min(255, ab + 60), 70), r * 0.6)
        end
        if text and text ~= '' then
            local tw = ImGui.CalcTextSize(text)
            if type(tw) ~= 'number' then tw = tw.x end
            local tx, ty = x + (aw - tw) * 0.5, y + 3
            dl:AddText(ImVec2(tx + 1, ty + 1), IM_COL32(0, 0, 0, 170), text)
            dl:AddText(ImVec2(tx, ty), IM_COL32(236, 238, 242, 255), text)
        end
        ImGui.Dummy(aw, h)
    end)
    if not ok then ImGui.ProgressBar(frac, w or -1, 0, text) end
end

-- A small (?) after the item before it, carrying the long explanation.
function Window:help(text)
    local ImGui = self.ImGui
    ImGui.SameLine()
    ImGui.TextDisabled('(?)')
    pcall(function() if ImGui.IsItemHovered() then ImGui.SetTooltip(text) end end)
end

-- A button greyed out (and dead) while it cannot act.
function Window:button(label, on)
    local ImGui = self.ImGui
    local dim = on == false and ImGui.BeginDisabled
    if dim then ImGui.BeginDisabled(true) end
    local pressed = ImGui.Button(label)
    if dim then ImGui.EndDisabled() end
    return pressed and on ~= false
end

-- A striped table. cols = { { 'Head', w = px } (fixed) or { 'Head' } (stretch) }; body() draws the rows
-- (self:row() then self:cell() before each cell). headers = false leaves the header row out. BeginTable and
-- EndTable always pair; where the build has no tables, the body is drawn as plain lines (each cell on the same
-- line as the last).
function Window:table(id, cols, body, headers)
    local ImGui = self.ImGui
    local TF, CF = ImGuiTableFlags, ImGuiTableColumnFlags
    local flags = TF and ((TF.RowBg or 0) + (TF.SizingStretchProp or 0) + (TF.PadOuterX or 0)) or 0
    if TF and ImGui.BeginTable then
        -- a real table: BeginTable false (clipped, hidden) means nothing is drawn and no EndTable
        if not ImGui.BeginTable(id, #cols, flags) then return end
    else
        -- no tables in this build (or the tests): the cells as plain lines
        self.noTable = true
        local ok, err = pcall(body)
        self.noTable = false
        if not ok then error(err, 0) end
        return
    end
    local ok, err = pcall(function()
        for _, c in ipairs(cols) do
            if CF then
                if c.w then ImGui.TableSetupColumn(c[1], CF.WidthFixed, c.w)
                else ImGui.TableSetupColumn(c[1], CF.WidthStretch, c.s or 1) end
            else
                ImGui.TableSetupColumn(c[1])
            end
        end
        if headers ~= false then ImGui.TableHeadersRow() end
        body()
    end)
    ImGui.EndTable()
    if not ok then error(err, 0) end
end

function Window:row()
    if self.noTable then self.firstCell = true; return end
    self.ImGui.TableNextRow()
end

function Window:cell()
    local ImGui = self.ImGui
    if self.noTable then
        if not self.firstCell then ImGui.SameLine() end
        self.firstCell = false
        return
    end
    ImGui.TableNextColumn()
end

-- The logo (ui/emblem.png, 2.43.4: the emblem cut from its background), `size` tall and as wide as its shape
-- (logoAspect), or an "LC" mark when the texture cannot be made; which one is logged once.
function Window:logo(size)
    local ImGui = self.ImGui
    if self.settings and self.settings.ShowLogo == '0' then
        self:once('nologo', 'ShowLogo=0 - the LC mark instead of the logo')
        self.logoTex = false
    end
    if self.logoTex == nil then
        self.logoTex = false
        self:once('logo1', 'making the logo texture from %s', tostring(self.logoPath))
        local ok, tex = pcall(function()
            return self.mq and self.mq.CreateTexture and self.logoPath and self.mq.CreateTexture(self.logoPath) or nil
        end)
        if ok and tex then
            self.logoTex = tex
            if self.log then self.log.debug('Window: logo loaded from %s', tostring(self.logoPath)) end
        elseif self.log then
            self.log.debug('Window: no logo (%s) - the LC mark instead', ok and 'mq.CreateTexture gave nothing' or tostring(tex))
        end
    end
    if self.logoTex then
        self:once('logo2', 'drawing the logo (ImGui.Image)')
        local ok, err = pcall(function() ImGui.Image(self.logoTex:GetTextureID(), ImVec2(math.floor(size * (self.logoAspect or 1) + 0.5), size)) end)
        if ok then self:once('logo3', 'logo drawn'); return end
        self.logoTex = false
        if self.log then self.log.debug('Window: the logo did not draw (%s) - the LC mark instead', tostring(err)) end
    end
    if ImGui.SetWindowFontScale then ImGui.SetWindowFontScale(1.8) end
    colored(ImGui, self.pal.label, 'LC')
    if ImGui.SetWindowFontScale then ImGui.SetWindowFontScale(1.0) end
end

-- the cursor moved to the right edge, leaving `w` for what comes next on this line
local function to_right(ImGui, w)
    pcall(function()
        local a = ImGui.GetContentRegionAvail()
        local ax = type(a) == 'number' and a or (a and a.x)
        if ax and ax > w then ImGui.SetCursorPosX(ImGui.GetCursorPosX() + ax - w) end
    end)
end

-- ---------------------------------------------------------------- the header

function Window:header()
    local ImGui, A = self.ImGui, self.actions
    self:logo(64)
    ImGui.SameLine()
    if ImGui.BeginGroup then ImGui.BeginGroup() end
    colored(ImGui, self.pal.label, 'LazCraft')
    ImGui.SameLine()
    ImGui.TextDisabled(tostring(self.version))
    local parts = { tostring(self.me or '?'), self.role or 'crafter' }
    local here = A.here and A.here()
    if here and here ~= '' then parts[#parts + 1] = here end
    if self.role == 'crafter' and self.crew and self.crew.board then
        local n = 0
        for _, e in pairs(self.crew.board) do if not e.gone then n = n + 1 end end
        parts[#parts + 1] = string.format('%d worker%s running', n, n == 1 and '' or 's')
    end
    ImGui.TextDisabled(table.concat(parts, ', '))
    if ImGui.EndGroup then ImGui.EndGroup() end
    -- the crafter's Close all (2.42.7, as AdventureTime's): LazCraft quits on every worker and here
    if A.closeAll then
        ImGui.SameLine()
        to_right(ImGui, 78)
        if ImGui.Button('Close all##lc_closeall') then A.closeAll() end
    end
end

-- The job: its name and phase, status, progress, the preflight while it is looked at, Go / Cancel, Pause / Stop.
function Window:job_panel()
    local ImGui, v = self.ImGui, self.runner:view()
    local a = v.active
    local showChecks = a and a.checks and #a.checks > 0 and (a.phase == 'awaiting' or a.phase == 'preflight')
    -- the box's height: the lines it will hold
    local lh, fh = 17, 22
    pcall(function()
        lh = tonumber(ImGui.GetTextLineHeightWithSpacing()) or lh
        fh = tonumber(ImGui.GetFrameHeightWithSpacing()) or fh
    end)
    local h = fh + fh + 14   -- the title row (a pill), the buttons, padding
    if a then
        if a.status ~= '' then h = h + lh end
        if a.total > 0 then h = h + fh end
    elseif v.last then h = h + lh end
    if v.queued > 0 then h = h + lh end
    if showChecks then h = h + 164 end
    local failed
    if ImGui.BeginChild('##lc_job', 0, h, true) then
        local ok, err = pcall(function()
            if a then
                colored(ImGui, self.pal.label, a.name)
                ImGui.SameLine()
                local ph = v.paused and { 'Paused', 'warn' } or PHASE[a.phase] or { a.phase, 'muted' }
                self:pill(ph[1], ph[2])
                -- the quiet window as it is now (core/pace, 2.46.7): an auto one moves as the run goes
                local st = self.settings or {}
                if a.phase == 'running' and st.QuietMs then
                    ImGui.SameLine()
                    self:pill(string.format('%s %sms', (st.ClickPace or 'auto') == 'fixed' and 'quiet' or 'auto quiet', tostring(st.QuietMs)), 'muted')
                end
                if a.status ~= '' then ImGui.Text(a.status) end
                if a.total > 0 then self:bar(a.done / a.total, string.format('%d / %d', a.done, a.total)) end
            else
                colored(ImGui, MUTED, 'Nothing running')
                ImGui.SameLine()
                self:pill('Idle', 'muted')
                if v.last then
                    local c = v.last.ok and CHECK_COLOR.ok or CHECK_COLOR.block
                    colored(ImGui, c, string.format('Last: %s - %s', v.last.name, v.last.ok and 'done' or ('failed: ' .. tostring(v.last.why))))
                end
            end
            if v.queued > 0 then ImGui.TextDisabled(string.format('%d queued', v.queued)) end
            -- the preflight while it is being looked at; BeginChild and EndChild always pair
            if showChecks then
                if ImGui.BeginChild('##lc_checks', 0, 160, true) then
                    pcall(function()
                        for _, c in ipairs(a.checks) do colored(ImGui, CHECK_COLOR[c.level] or CHECK_COLOR.ok, tostring(c.text)) end
                    end)
                end
                ImGui.EndChild()
            end
            if a and a.phase == 'awaiting' then
                if ImGui.Button('Go') then self.runner:approve() end
                ImGui.SameLine()
                if ImGui.Button('Cancel') then self.runner:cancel() end
                ImGui.SameLine()
            end
            if v.paused then
                if ImGui.Button('Resume') then self.runner:resume() end
            else
                if self:button('Pause', a ~= nil) then self.runner:pause() end
            end
            ImGui.SameLine()
            if self:button('Stop', a ~= nil or v.queued > 0) then self.runner:stop() end
        end)
        if not ok then failed = err end
    end
    ImGui.EndChild()
    if failed then error(failed, 0) end
end

-- ---------------------------------------------------------------- Craft

-- the band a trivial falls in: 0-49, 50-99, ...
local function band_of(t)
    if not t then return 'Trivial not known' end
    local lo = math.floor(t / 50) * 50
    return string.format('Trivial %d - %d', lo, lo + 49)
end

function Window:craft_tab()
    local ImGui, A = self.ImGui, self.actions
    self:heading('Find')
    -- tradeskill dropdown: the list below only holds that skill's recipes (lowest trivial first)
    if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(200) end
    if ImGui.BeginCombo('Tradeskill##lc_skill', self.skill or 'All (type to search)') then
        if ImGui.Selectable('All (type to search)##lc_sk_all', self.skill == nil) then self.skill = nil end
        for _, sk in ipairs(A.skills and A.skills() or {}) do
            if ImGui.Selectable(sk .. '##lc_sk_' .. sk, self.skill == sk) then self.skill = sk end
        end
        ImGui.EndCombo()
    end
    if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(200) end
    self.query = input_text(ImGui, 'Search##lc_q', self.query)
    -- a tradeskill picked: its trivials from Min and/or up to Max (2.44.0); a box left empty has no limit
    local range
    if self.skill then
        self.trivMin, self.trivMax = self.trivMin or '', self.trivMax or ''
        ImGui.Text('Trivial')
        ImGui.SameLine()
        if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(60) end
        self.trivMin = input_text(ImGui, 'to##lc_tmin', self.trivMin)
        ImGui.SameLine()
        if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(60) end
        self.trivMax = input_text(ImGui, '##lc_tmax', self.trivMax)
        local lo, hi = tonumber(self.trivMin), tonumber(self.trivMax)
        if lo or hi then range = { min = lo, max = hi, unknown = self.trivUnknown } end
        self:help('Min only: that trivial and up. Max only: up to it. Both: between. Empty: every trivial.')
    end
    local key = (self.skill or '') .. '|' .. self.query .. '|' .. tostring(range and range.min) .. '|' .. tostring(range and range.max)
        .. '|' .. tostring(range and range.unknown)
    if key ~= self.lastKey then
        self.lastKey = key
        self.results, self.total, self.hiddenTriv = A.search(self.query, self.skill, range)
        self.results, self.total, self.hiddenTriv = self.results or {}, self.total or 0, self.hiddenTriv or 0
        self.picked = nil
    end

    local count = self.total > #self.results and string.format('%d - the first %d shown, type to narrow it', self.total, #self.results)
        or (self.total > 0 and string.format('%d', self.total) or nil)
    self:heading(count and ('Recipes  (' .. count .. ')') or 'Recipes')
    if self.skill == nil and self.query == '' then ImGui.TextDisabled('Pick a tradeskill, or type part of a name') end
    if (self.query ~= '' or self.skill) and #self.results == 0 then ImGui.TextDisabled('No recipe matches') end
    if (self.hiddenTriv or 0) > 0 then
        ImGui.TextDisabled(string.format('+%d with no known trivial', self.hiddenTriv))
        ImGui.SameLine()
        if self:button('Show them##lc_tunk') then
            self.trivUnknown = true
        end
    elseif self.trivUnknown and range then
        if self:button('Hide no-trivial##lc_tunk_off') then
            self.trivUnknown = nil
        end
    end
    -- the list scrolls in its own box, so the picked recipe below stays in view; Begin/EndChild always pair.
    -- A tradeskill's recipes come in trivial bands; a search across all of them, by tradeskill.
    if #self.results > 0 then
        local failed
        if ImGui.BeginChild('##lc_results', 0, 230, false) then
            local ok, err = pcall(function()
                local groups, order = {}, {}
                for _, r in ipairs(self.results) do
                    local g = self.skill and band_of(r.trivial) or (r.skill or 'Other')
                    if not groups[g] then groups[g] = {}; order[#order + 1] = g end
                    table.insert(groups[g], r)
                end
                local SF = ImGuiSelectableFlags
                for gi, g in ipairs(order) do
                    self:subheading(g)
                    self:table('##lc_rg' .. gi, { { 'Recipe' }, { 'Trivial', w = 52 }, { 'Made in', w = 120 }, { 'Yield', w = 40 } }, function()
                        for _, r in ipairs(groups[g]) do
                            self:row(); self:cell()
                            if ImGui.Selectable(r.label .. '##lc_r' .. r.id, self.picked == r, SF and SF.SpanAllColumns or 0) then self.picked = r end
                            self:cell(); ImGui.Text(r.trivial and tostring(r.trivial) or '?')
                            self:cell(); ImGui.TextDisabled(r.container or '?')
                            self:cell(); ImGui.Text(tostring(r.yield or 1))
                        end
                    end, gi == 1)
                end
            end)
            if not ok then failed = err end
        end
        ImGui.EndChild()
        if failed then error(failed, 0) end
    end

    local r = self.picked
    if r then
        self:heading(string.format('%s  [%s]', r.label, r.id))
        local skName, skVal = nil, nil
        if A.skillOf then skName, skVal = A.skillOf(r) end
        ImGui.TextDisabled(string.format('%s, %s, trivial %s%s%s', r.container or '?', r.skill or '?', r.trivial and tostring(r.trivial) or '?',
            (r.yield or 1) > 1 and string.format(', makes %d a combine', r.yield) or '',
            skName and string.format(', your %s %s%s', skName, skVal and tostring(skVal) or '?',
                (skVal and r.trivial and skVal >= r.trivial) and ' (already at its trivial)' or '') or ''))
        -- what n combines need, what is held and where the rest comes from (a quiet plan, actions.preview)
        local rows = A.preview and A.preview(r, self.combines)
        if rows and #rows > 0 then
            self:table('##lc_ings', { { 'Ingredient' }, { 'Need', w = 48 }, { 'Have', w = 48 }, { 'From', s = 1.3 } }, function()
                for _, x in ipairs(rows) do
                    self:row()
                    self:cell(); ImGui.Text(x.name)
                    self:cell(); ImGui.Text(tostring(x.need))
                    self:cell()
                    if x.have >= x.need then colored(ImGui, CHECK_COLOR.ok, tostring(x.have)) else ImGui.TextDisabled(tostring(x.have)) end
                    self:cell()
                    if x.kind == 'short' then colored(ImGui, CHECK_COLOR.block, x.from) else ImGui.TextDisabled(x.from) end
                end
            end)
        else
            local ins, tools = {}, {}
            for _, i in ipairs(r.ins or {}) do ins[#ins + 1] = i.n .. ' ' .. i.name end
            for _, t in ipairs(r.tools or {}) do tools[#tools + 1] = t.n .. ' ' .. t.name end
            ImGui.Text('Uses: ' .. (#ins > 0 and table.concat(ins, ', ') or 'nothing'))
            if #tools > 0 then ImGui.Text('Tools: ' .. table.concat(tools, ', ')) end
        end
        self.combines = input_count(ImGui, 'Combines##lc_n', self.combines, 90)
        ImGui.SameLine()
        if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(100) end
        if ImGui.BeginCombo('Then##lc_disp', cap(self.disposal)) then
            for _, d in ipairs(DISPOSALS) do
                if ImGui.Selectable(cap(d) .. '##lc_disp_' .. d, self.disposal == d) then self.disposal = d end
            end
            ImGui.EndCombo()
        end
        self:help('What happens to what it makes: Keep it, Sell it to a merchant here, or Destroy it.')
        -- what the combines come to: the yield is per combine, so 5 combines of a 10-yield recipe make 50
        local y = r.yield or 1
        ImGui.TextDisabled(y > 1 and string.format('= %d combines x %d each = %d %s', self.combines, y, self.combines * y, r.name)
            or string.format('= %d %s', self.combines, r.name))
        if A.estimate then
            local cost, coin = A.estimate(r, self.combines)
            ImGui.SameLine()
            if cost and cost > 0 then
                local text = string.format('Cost: about %s to buy, you carry %s', A.money(cost), A.money(coin))
                if coin < cost then colored(ImGui, CHECK_COLOR.block, text .. ' (not enough)') else ImGui.TextDisabled(text) end
            elseif cost == 0 then ImGui.TextDisabled('Cost: nothing to buy') end
        end
        if ImGui.Button('Plan##lc_plan') then A.plan(r, self.combines) end
        ImGui.SameLine()
        if ImGui.Button('Make##lc_make') then
            A.make(r, self.combines, { disposal = self.disposal })
        end
        if A.queueAdd then
            ImGui.SameLine()
            if ImGui.Button('+ Queue##lc_q_add') then A.queueAdd('craft', r, self.combines, self.disposal) end
        end
    end
    self:queue_panel()
end

-- RADIX (2.46.0): the pinnacle combines on Lazarus, on their own tab. Each recipe with what is held (bags + bank)
-- and a Draught tick: a Draught of the Craftsman clicked before each of its combines, so a failure gives the
-- ingredients back. Picked: its ingredients (need / have / from), the combines, Plan and Make. What it makes is
-- always kept. A recipe made one at a time (skills.ini OneAtATime=) is fixed at one combine per Go.
function Window:radix_tab()
    local ImGui, A = self.ImGui, self.actions
    local d = A.radixDraught()
    local state
    if d.up then state = 'up now'
    elseif d.have > 0 and d.ready then state = 'ready'
    elseif d.have > 0 then state = string.format('ready in %d:%02d', math.floor(d.secs / 60), d.secs % 60) end
    local line = string.format('%s: %d in the bags%s', d.name, d.have, state and (' - ' .. state) or '')
    if d.have == 0 and not d.up then colored(ImGui, CHECK_COLOR.block, line) else ImGui.Text(line) end
    self:help('Ticked under Draught: one is clicked before each combine of that recipe - a failed combine then gives the '
        .. 'ingredients back. Its cooldown is long: a combine waits for it, and none left stops the run before that combine.')
    local rows = A.radixRows() or {}
    local SF = ImGuiSelectableFlags
    -- two sections (skills.ini Precombines=): the low-trivial turn-ins, no Draught; then the Essence Fusion Chamber
    -- and what goes into it
    local function section(title, pre, id)
        self:heading(title)
        local cols = { { 'Recipe' }, { 'Trivial', w = 52 }, { 'Have', w = 48 }, { 'Made in', w = 110 } }
        if not pre then cols[#cols + 1] = { 'Draught', w = 60 } end
        self:table(id, cols, function()
            for i, row in ipairs(rows) do
                if (row.pre and true or false) == pre then
                    self:row(); self:cell()
                    if row.recipe then
                        if ImGui.Selectable(row.name .. '##lc_rx' .. i, self.radixPick == row.name, SF and SF.SpanAllColumns or 0) then
                            self.radixPick = row.name
                        end
                    else
                        ImGui.TextDisabled(row.name .. ' (not in the recipe data)')
                    end
                    self:cell(); ImGui.Text(row.recipe and row.recipe.trivial and tostring(row.recipe.trivial) or '?')
                    self:cell(); ImGui.Text(tostring(A.researchHeld and A.researchHeld(row.name) or '?'))
                    self:cell(); ImGui.TextDisabled(row.recipe and row.recipe.container or '?')
                    if not pre then
                        self:cell()
                        local on = A.radixDraughtOn(row.name)
                        local v = ImGui.Checkbox('##lc_rxd' .. i, on)
                        if v ~= on then A.radixDraughtOn(row.name, v) end
                    end
                end
            end
        end)
    end
    section('Precombines', true, '##lc_radix_pre')
    section('Essence Fusion Chamber', false, '##lc_radix')
    local pick
    for _, row in ipairs(rows) do if row.name == self.radixPick then pick = row end end
    local r = pick and pick.recipe
    if not r then return end
    self:heading(string.format('%s  [%s]', r.label, r.id))
    ImGui.TextDisabled(string.format('%s%s, trivial %s%s', r.container or '?', r.skill and (', ' .. r.skill) or '',
        r.trivial and tostring(r.trivial) or '?', (r.yield or 1) > 1 and string.format(', makes %d a combine', r.yield) or ''))
    local one = A.radixOneAtATime and A.radixOneAtATime(r.name)
    self.radixN = self.radixN or {}
    local n = one and 1 or (self.radixN[r.name] or 1)
    local rowsP = A.preview and A.preview(r, n)
    if rowsP and #rowsP > 0 then
        self:table('##lc_rx_ings', { { 'Ingredient' }, { 'Need', w = 48 }, { 'Have', w = 48 }, { 'From', s = 1.3 } }, function()
            for _, x in ipairs(rowsP) do
                self:row()
                self:cell(); ImGui.Text(x.name)
                self:cell(); ImGui.Text(tostring(x.need))
                self:cell()
                if x.have >= x.need then colored(ImGui, CHECK_COLOR.ok, tostring(x.have)) else ImGui.TextDisabled(tostring(x.have)) end
                self:cell()
                if x.kind == 'short' then colored(ImGui, CHECK_COLOR.block, x.from) else ImGui.TextDisabled(x.from) end
            end
        end)
    end
    if one then
        ImGui.Text('Combines: 1')
        self:help('Made one at a time: one combine per Go.')
    else
        self.radixN[r.name] = input_count(ImGui, 'Combines##lc_rx_n', n, 90)
        n = self.radixN[r.name]
    end
    if pick.pre then
        -- a precombine: low trivial, no Draught
    elseif A.radixDraughtOn(r.name) then
        ImGui.TextDisabled(string.format('A %s before each combine (up to %d)', d.name, n))
    else
        colored(ImGui, CHECK_COLOR.warn or CHECK_COLOR.block, 'No Draught: a failed combine eats the ingredients')
    end
    if ImGui.Button('Plan##lc_rx_plan') then A.plan(r, n) end
    ImGui.SameLine()
    if ImGui.Button('Make##lc_rx_make') then A.radixMake(r, n) end
end

-- The queue, under the Craft and Research lists (one queue, shown in both): each entry with its count, up,
-- down and X; Run queue (one Go, entries one after another; a finished one comes off) and Clear.
function Window:queue_panel()
    local ImGui, A = self.ImGui, self.actions
    if not A.queueList then return end
    local list = A.queueList() or {}
    self:heading(string.format('Queue (%d)', #list))
    if #list == 0 then
        ImGui.TextDisabled('empty - "+ Queue" on a recipe or a research row adds to it')
        return
    end
    local acted = false
    self:table('##lc_queue', { { '#', w = 22 }, { 'Recipe' }, { 'Count', w = 96 }, { 'Then', w = 80 }, { '', w = 104 } }, function()
        for i, e in ipairs(list) do
            if acted then return end
            local key = tostring(e.id)
            self:row()
            self:cell(); ImGui.TextDisabled(tostring(i) .. '.')
            self:cell()
            local label = e.recipe and e.recipe.label or (e.recipeId .. ' (not in the data)')
            ImGui.Text(label)
            self:cell()
            local n = input_count(ImGui, '##lc_q_n_' .. key, e.n, 88)
            if n ~= e.n then A.queueSetN(e.id, n) end
            self:cell()
            ImGui.TextDisabled(e.kind == 'craft' and ('combines' .. (e.disposal ~= 'keep' and (', ' .. e.disposal) or '')) or 'in hand')
            self:cell()
            if self:button('Up##lc_q_u_' .. key, i > 1) then A.queueMove(e.id, -1); acted = true; return end
            ImGui.SameLine()
            if self:button('Dn##lc_q_d_' .. key, i < #list) then A.queueMove(e.id, 1); acted = true; return end
            ImGui.SameLine()
            if ImGui.Button('X##lc_q_x_' .. key) then A.queueRemove(e.id); acted = true; return end
        end
    end, false)
    if acted then return end
    if ImGui.Button('Run queue##lc_q_run') then A.queueRun() end
    ImGui.SameLine()
    if ImGui.Button('Clear##lc_q_clear') then A.queueClear() end
end

-- ---------------------------------------------------------------- Summon (as it was; only the theme changed)

function Window:summon_tab()
    local ImGui, A = self.ImGui, self.actions
    if A.refreshSummon and ImGui.Button('Re-read spellbook##lc_sumref') then A.refreshSummon() end
    local group
    for _, row in ipairs(A.summon() or {}) do
        if row.group ~= group then
            group = row.group
            ImGui.Separator()
            ImGui.Text(group)
        end
        local who = {}
        if row.me then who[#who + 1] = 'me' end
        for _, w in ipairs(row.workers or {}) do who[#who + 1] = w end
        if #who == 0 then
            ImGui.TextDisabled('  ' .. row.item .. ' - nobody running has the spell')
        else
            ImGui.Text(string.format('  %s - %s', row.item, table.concat(who, ', ')))
            local key = row.item
            self.counts[key] = input_count(ImGui, 'Count##lc_c_' .. key, self.counts[key] or 1)
            if row.me then
                ImGui.SameLine()
                if ImGui.Button('Make##lc_m_' .. key) then A.cast(row.item, self.counts[key]) end
            end
            for _, w in ipairs(row.workers or {}) do
                ImGui.SameLine()
                if ImGui.Button(w .. '##lc_o_' .. key .. '_' .. w) then A.order(w, row.item, self.counts[key]) end
            end
        end
        -- not running but could (2.41.9): cast it before, or of a class that can; Start for one in a safe zone
        if #(row.could or {}) > 0 then
            local parts = {}
            for _, c in ipairs(row.could) do
                parts[#parts + 1] = string.format('%s (%s%s)', c.name, c.why, c.safe and '' or ', not in a safe zone')
            end
            ImGui.TextDisabled('    could: ' .. table.concat(parts, ', '))
            for _, c in ipairs(row.could) do
                if c.safe and A.startWorker then
                    ImGui.SameLine()
                    if ImGui.Button('Start ' .. c.name .. '##lc_sc_' .. row.item .. '_' .. c.name) then A.startWorker(c.name) end
                end
            end
        end
        if #(row.lacking or {}) > 0 then
            colored(ImGui, CHECK_COLOR.warn, '    spell not scribed on: ' .. table.concat(row.lacking, ', ') .. ' (buy and scribe it there)')
        end
    end
end

-- ---------------------------------------------------------------- Leveling

-- Leveling: one skill's path from skills.ini. Each row is one recipe with its own combines, product choice and
-- Make; a Make stops at that recipe's trivial. Nothing runs on by itself.
-- A row's combines start at the estimate to its trivial (core/rates) plus LEVEL_PAD, so most rows take one
-- pass; a count you type stays yours. No estimate (a row already past): LEVEL_N.
Window.LEVEL_PAD = 1.10   -- 2.42.3: the model is close; a repeat pass covers bad luck
Window.LEVEL_N = 10

-- a row still on its default count follows the estimate
local function auto_n(st, e)
    if st.auto and e and e.combines > 0 then st.n = math.max(1, math.ceil(e.combines * Window.LEVEL_PAD)) end
end

function Window:level_tab()
    local ImGui, A = self.ImGui, self.actions
    local skills = A.levelSkills() or {}
    if not self.lvlSkill then self.lvlSkill = skills[1] end
    if not self.lvlSkill then return ImGui.Text('No leveling paths in skills.ini') end
    local function label(sk)
        local name, v, skCap = A.skillValue(sk)
        if not v then return sk end
        return string.format('%s (%s %d%s)', sk, name, v, (skCap and skCap < 300) and string.format(', cap %d', skCap) or '')
    end
    if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(260) end
    if ImGui.BeginCombo('Skill##lc_lvl', label(self.lvlSkill)) then
        for _, sk in ipairs(skills) do
            if ImGui.Selectable(label(sk) .. '##lc_lvl_' .. sk, sk == self.lvlSkill) then self.lvlSkill = sk end
        end
        ImGui.EndCombo()
    end
    local skill = self.lvlSkill
    -- the path: every row of a skill as the rows below are set (recipe, combines, product)
    local function path_rows(sk)
        self.lvlRows[sk] = self.lvlRows[sk] or A.levelRows(sk) or {}
        self.lvlState[sk] = self.lvlState[sk] or {}
        local list = {}
        for i, row in ipairs(self.lvlRows[sk]) do
            local st = self.lvlState[sk][row.key or i]
            if not st then st = { n = Window.LEVEL_N, auto = true, disposal = row.rung.disposal or 'keep', pick = 1 }; self.lvlState[sk][row.key or i] = st end
            st.rep = true   -- a path runs every row until its trivial (Make.chain): the rows show it
            local r = row.recipes[st.pick] or row.recipes[1]
            if r then list[#list + 1] = { key = row.key or i, recipe = r, st = st } end
        end
        local est = A.levelEstimate and A.levelEstimate(sk, list)
        local out = {}
        for _, x in ipairs(list) do
            auto_n(x.st, est and est.rows[x.key])
            out[#out + 1] = { recipe = x.recipe, n = x.st.n, disposal = x.st.disposal }
        end
        return out
    end
    local skName, val, skCap = A.skillValue(skill)
    self.lvlRows[skill] = self.lvlRows[skill] or A.levelRows(skill) or {}
    self.lvlState[skill] = self.lvlState[skill] or {}
    local function row_recipe(i, row)
        local st = self.lvlState[skill][row.key or i]
        return st and row.recipes[st.pick] or row.recipes[1]
    end
    local function is_done(r)
        return val and r and r.trivial and val >= math.min(r.trivial, skCap or r.trivial) or false
    end
    -- the first row still worth doing: the one the header points at
    local nextRow
    for i, row in ipairs(self.lvlRows[skill]) do
        local r = row_recipe(i, row)
        if r and not is_done(r) then nextRow = i; break end
    end
    if val then
        local top = skCap or 300
        self:heading(string.format('%s  %d / %d', skName or skill, val, top))
        local nr = nextRow and row_recipe(nextRow, self.lvlRows[skill][nextRow])
        local over = val >= top and 'at your cap'
            or nr and string.format('next: row %d, %s (trivial %s)', nextRow, nr.label, nr.trivial and tostring(nr.trivial) or '?')
            or 'past every row on this path'
        self:bar(val / top, over)
    else
        self:heading(skill)
        ImGui.TextDisabled(skill .. ': skill not known')
    end
    -- what the path still takes (core/rates: the skill-up model, tuned by your runs of the skill; ? = none yet)
    local est
    if A.levelEstimate then
        local list = {}
        for i, row in ipairs(self.lvlRows[skill]) do
            local r = row_recipe(i, row)
            if r then list[#list + 1] = { key = row.key or i, recipe = r } end
        end
        est = A.levelEstimate(skill, list)
    end
    local total = est and est.total.combines > 0 and string.format('to the end ~%d combines, ~%s%s%s', est.total.combines, A.money(est.total.cost),
        est.total.unknown and ' + drops' or '', est.total.guess and ' (?)' or '') or nil
    self:heading(string.format('Path  (%d rows%s)', #self.lvlRows[skill], total and (', ' .. total) or ''))
    if A.chain then
        if ImGui.Button('Run path##lc_lv_path') then A.chain(path_rows(skill), 'Level ' .. skill) end
        ImGui.SameLine()
        if ImGui.Button('Run all skills##lc_lv_all') then
            local rows, names = {}, {}
            for _, sk in ipairs(A.levelAllOrder and A.levelAllOrder() or {}) do
                names[#names + 1] = sk
                for _, r in ipairs(path_rows(sk)) do rows[#rows + 1] = r end
            end
            A.chain(rows, 'Level all: ' .. table.concat(names, ', '))
        end
        self:help('Each row until its trivial, then the next, under one Go. A row\'s leftovers are sold after it (its product, '
            .. 'cheap ingredients); what a later row needs is kept. ? = the skill-up model alone, none of your runs yet.')
    end
    if A.levelCleanupDone then
        local done, nDone = {}, 0
        for i, row in ipairs(self.lvlRows[skill]) do
            local r = row_recipe(i, row)
            if r and is_done(r) then done[i] = r; nDone = nDone + 1 end
        end
        if A.chain then ImGui.SameLine() end
        if self:button(string.format('Clean up finished rows (%d)##lc_lv_cldone', nDone), nDone > 0) then A.levelCleanupDone(skill, done) end
        self:help('Every row at its trivial in one go: one preview, one Go, one merchant trip - their products and cheap '
            .. 'ingredients sold, what a row not at its trivial still needs kept. Each row\'s own Clean up does just that row.')
    end
    local stop = false
    self:table('##lc_lvl_rows', { { '#', w = 22 }, { 'Recipe' }, { 'Triv', w = 36 }, { 'Combines', w = 96 }, { 'Then', w = 80 },
                                    { '', w = 58 }, { '', w = 168 } }, function()
        for i, row in ipairs(self.lvlRows[skill]) do
            if stop then return end
            local key = skill .. '_' .. i
            local st = self.lvlState[skill][row.key or i]
            if not st then st = { n = Window.LEVEL_N, auto = true, disposal = row.rung.disposal or 'keep', pick = 1, rep = false }; self.lvlState[skill][row.key or i] = st end
            self:row()
            self:cell(); ImGui.TextDisabled(tostring(i) .. '.')
            self:cell()
            if #row.recipes == 0 then
                ImGui.TextDisabled(row.rung.recipe .. ' - no recipe by that name in the data')
                if A.levelDrop then
                    self:cell(); self:cell(); self:cell(); self:cell(); self:cell()
                    if ImGui.Button('X##lc_lv_x_' .. key) then A.levelDrop(skill, row); self.lvlRows[skill] = nil; stop = true; return end
                end
            else
                local r = row.recipes[st.pick] or row.recipes[1]
                local done = is_done(r)
                local name = r.label .. (row.added and ' (added)' or '')
                if done then ImGui.TextDisabled(name) else ImGui.Text(name) end
                if #row.recipes > 1 then
                    ImGui.SameLine()
                    if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(90) end
                    if ImGui.BeginCombo('##lc_lv_v_' .. key, '[' .. r.id .. ']') then
                        for j, v in ipairs(row.recipes) do
                            local ins = {}
                            for _, x in ipairs(v.ins or {}) do ins[#ins + 1] = x.n .. ' ' .. x.name end
                            if ImGui.Selectable(string.format('[%s] %s##lc_lv_vs_%s_%d', v.id, table.concat(ins, ', '), key, j), j == st.pick) then st.pick = j end
                        end
                        ImGui.EndCombo()
                    end
                end
                local e = est and est.rows[row.key or i]
                if not done then auto_n(st, e) end
                self:cell(); ImGui.Text(r.trivial and tostring(r.trivial) or '?')
                -- a row you are past is greyed out and its controls are off (the Craft tab still makes the item)
                local dim = done and ImGui.BeginDisabled
                self:cell()
                if dim then ImGui.BeginDisabled(true) end
                local typed = input_count(ImGui, '##lc_lv_n_' .. key, st.n, 88)
                if typed ~= st.n then st.n, st.auto = typed, false end
                if dim then ImGui.EndDisabled() end
                if e and not done then
                    pcall(function()
                        if ImGui.IsItemHovered() then
                            ImGui.SetTooltip(string.format('to its trivial ~%d%s combines, ~%s%s', e.combines, e.source == 'guess' and '?' or '',
                                A.money(e.cost), e.unknown and ' + drops' or ''))
                        end
                    end)
                end
                self:cell()
                if dim then ImGui.BeginDisabled(true) end
                if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(76) end
                if ImGui.BeginCombo('##lc_lv_d_' .. key, cap(st.disposal)) then
                    for _, d in ipairs(DISPOSALS) do
                        if ImGui.Selectable(cap(d) .. '##lc_lv_d_' .. key .. '_' .. d, st.disposal == d) then
                            st.disposal = d
                            if A.levelDisposal then A.levelDisposal(skill, row, d) end
                        end
                    end
                    ImGui.EndCombo()
                end
                if dim then ImGui.EndDisabled() end
                self:cell()
                if done then self:pill((skCap and val >= skCap) and 'cap' or 'done', 'ok')
                elseif i == nextRow then self:pill('next', 'warn')
                elseif e then ImGui.TextDisabled(string.format('~%d%s', e.combines, e.source == 'guess' and '?' or '')) end
                self:cell()
                if dim then ImGui.BeginDisabled(true) end
                st.rep = ImGui.Checkbox('Rep##lc_lv_r_' .. key, st.rep)
                ImGui.SameLine()
                if ImGui.Button('Make##lc_lv_m_' .. key) then
                    A.make(r, st.n, { disposal = st.disposal, stopAtTrivial = true, repeatToTrivial = st.rep or nil })
                end
                if dim then ImGui.EndDisabled() end
                -- leftovers of this recipe (sell, or destroy what no merchant takes) - by hand, after a Go
                if A.levelCleanup then
                    ImGui.SameLine()
                    if ImGui.Button('Clean up##lc_lv_cl_' .. key) then A.levelCleanup(skill, r) end
                end
                if A.levelDrop then
                    ImGui.SameLine()
                    if ImGui.Button('X##lc_lv_x_' .. key) then A.levelDrop(skill, row); self.lvlRows[skill] = nil; stop = true; return end
                end
            end
        end
    end)
    if stop then return end
    -- this character's own additions: any recipe of this skill, placed by its trivial (saved per character)
    if A.levelAdd then
        self:heading('Add a recipe')
        local changes = A.levelChanges and A.levelChanges(skill) or 0
        if changes > 0 then
            if ImGui.Button(string.format('Restore path (%d change%s)##lc_lv_restore', changes, changes == 1 and '' or 's')) then
                A.levelRestore(skill)
                self.lvlRows[skill] = nil
                return
            end
            ImGui.SameLine()
            ImGui.TextDisabled('back to the skills.ini path')
        end
        if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(260) end
        self.lvlAddQ = ImGui.InputText('Add a recipe##lc_lv_q', self.lvlAddQ or '')
        local q = self.lvlAddQ or ''
        if #q < 2 then
            ImGui.TextDisabled('type 2+ letters of a ' .. skill .. ' recipe to add it to this path')
        else
            local have = {}
            for _, row in ipairs(self.lvlRows[skill]) do for _, r in ipairs(row.recipes) do have[r.id] = true end end
            local list = A.search(q, skill) or {}
            local shown = 0
            for _, r in ipairs(list) do
                if shown >= 10 then break end
                shown = shown + 1
                local label = string.format('%s - trivial %s, %s [%s]%s##lc_lv_add_%s', r.label, r.trivial and tostring(r.trivial) or '?',
                    r.container or '?', r.id, have[r.id] and ' (on the path)' or '', r.id)
                if ImGui.Selectable(label, false) and not have[r.id] then
                    A.levelAdd(skill, r)
                    self.lvlRows[skill] = nil
                    self.lvlAddQ = ''
                    return
                end
            end
            if #list == 0 then ImGui.TextDisabled('no ' .. skill .. ' recipe matches') end
            if #list > shown then ImGui.TextDisabled(string.format('%d more - type more to narrow it', #list - shown)) end
        end
    end
end

-- ---------------------------------------------------------------- Research

-- Research: the 66-70 spells and tomes of research.ini by class. Each row: held (bags + bank), scribed (a spell
-- this character has), its Qty and Make; Make all shown makes every row shown not held, Qty each. Qty counts
-- spells in hand: a failure is made again (Make.batch).
local function is_tome(name) return not (name:sub(1, 6) == 'Spell:' or name:sub(1, 5) == 'Song:') end

-- "Spell: Icebane" -> "Icebane": the kind every name starts with is said once, by the tab (and a tome's tag).
local function short_name(name) return (name:gsub('^%a+: ', '', 1)) end
local QTY_LINGER = 30   -- frames the Qty box stays after the mouse leaves its row

-- A level's rows. Qty, - and + show only on the row under the mouse (or one whose Qty is not 1); the rest of
-- the time the row shows "x1", so a long list is names and buttons.
function Window:research_rows(rows, lv)
    local ImGui, A, rs = self.ImGui, self.actions, self.rs
    rs.hover = rs.hover or {}
    local function hovered()
        local ok, h = pcall(function() return ImGui.IsItemHovered() or ImGui.IsItemActive() end)
        return ok and h == true
    end
    self:table('##lc_rs_rows_' .. lv, { { '' }, { '', w = 36 }, { '', w = 64 }, { '', w = 96 }, { '', w = 64 } }, function()
        for _, e in ipairs(rows) do
            local held = A.researchHeld(e.recipe.name) or 0
            local tome = is_tome(e.name)
            local key = rs.class .. '_' .. e.recipe.id
            local over = false
            self:row()
            self:cell()
            local name = short_name(e.name)
            if held > 0 then ImGui.TextDisabled(name) else ImGui.Text(name) end
            if hovered() then over = true; pcall(ImGui.SetTooltip, e.name) end
            self:cell(); ImGui.Text(e.recipe.trivial and tostring(e.recipe.trivial) or '?')
            if hovered() then over = true end
            self:cell()
            if held > 0 then self:pill('held ' .. held, 'info') elseif tome then self:pill('tome', 'muted') end
            self:cell()
            local n = rs.counts[key] or 1
            if n ~= 1 or (rs.hover[key] or 0) > 0 then
                rs.counts[key] = input_count(ImGui, '##lc_rs_n_' .. key, n, 88)
                if hovered() then over = true end
            else
                ImGui.TextDisabled('x1')
                if hovered() then over = true end
            end
            self:cell()
            if A.queueAdd then
                if ImGui.Button('+ Queue##lc_rs_q_' .. key) then A.queueAdd('research', e.recipe, rs.counts[key] or 1, 'keep') end
                if hovered() then over = true end
            end
            rs.hover[key] = over and QTY_LINGER or math.max(0, (rs.hover[key] or 0) - 1)
        end
    end, false)
end

function Window:research_tab()
    local ImGui, A, rs = self.ImGui, self.actions, self.rs
    local classes = A.researchClasses() or {}
    if #classes == 0 then return ImGui.Text('No research data (data/research.ini)') end
    if not rs.class then
        local mine = A.researchMyClass and A.researchMyClass() or ''
        rs.class = classes[1]
        for _, c in ipairs(classes) do if c == mine then rs.class = c end end
    end
    self:heading(string.format('%s%s', cap(rs.class), rs.level == 0 and '' or (' ' .. rs.level)))
    if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(160) end
    if ImGui.BeginCombo('Class##lc_rs_class', rs.class) then
        for _, c in ipairs(classes) do
            if ImGui.Selectable(c .. '##lc_rs_c_' .. c, c == rs.class) then rs.class = c; rs.level = 0 end
        end
        ImGui.EndCombo()
    end
    ImGui.SameLine()
    if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(90) end
    local levels = A.researchLevels(rs.class) or {}
    if ImGui.BeginCombo('Level##lc_rs_lv', rs.level == 0 and 'All' or tostring(rs.level)) then
        if ImGui.Selectable('All##lc_rs_lv_all', rs.level == 0) then rs.level = 0 end
        for _, lv in ipairs(levels) do
            if ImGui.Selectable(lv .. '##lc_rs_lv_' .. lv, rs.level == lv) then rs.level = lv end
        end
        ImGui.EndCombo()
    end
    for _, t in ipairs({ { 'spells', 'Spells' }, { 'tomes', 'Tomes' }, { 'both', 'Both' } }) do
        ImGui.SameLine()
        if ImGui.RadioButton(t[2] .. '##lc_rs_t_' .. t[1], rs.type == t[1]) then rs.type = t[1] end
    end
    local shown = {}
    for _, e in ipairs(A.researchRows(rs.class) or {}) do
        local tome = is_tome(e.name)
        if (rs.level == 0 or e.level == rs.level) and (rs.type == 'both' or (rs.type == 'tomes') == tome) then
            shown[#shown + 1] = e
        end
    end
    rs.qty = input_count(ImGui, 'Qty each##lc_rs_qty', rs.qty)
    ImGui.SameLine()
    local todo = {}
    for _, e in ipairs(shown) do
        if (A.researchHeld(e.recipe.name) or 0) < rs.qty then todo[#todo + 1] = { recipe = e.recipe, qty = rs.qty } end
    end
    if ImGui.Button(string.format('Make all shown (%d not held)##lc_rs_all', #todo)) and #todo > 0 then
        A.researchMake(todo, string.format('Research %s: %d', rs.class, #todo))
    end
    if A.queueAdd then
        ImGui.SameLine()
        if ImGui.Button(string.format('Queue all shown (%d)##lc_rs_qall', #todo)) then
            for _, t in ipairs(todo) do A.queueAdd('research', t.recipe, t.qty, 'keep') end
        end
    end
    self:help('Qty is spells in hand: a failure is bought and made again. Held = bags + bank; held ones are skipped.')
    if #shown == 0 then ImGui.TextDisabled('Nothing for this class, level and type') end
    -- ONE BLOCK PER LEVEL (2.45.0): a divider with what is in it, a fold toggle and Queue for that level; the
    -- rows under it. The level is the divider, so the rows lose their Lvl column.
    rs.closed = rs.closed or {}
    local groups, order = {}, {}
    for _, e in ipairs(shown) do
        if not groups[e.level] then groups[e.level] = {}; order[#order + 1] = e.level end
        local g = groups[e.level]; g[#g + 1] = e
    end
    table.sort(order)
    for i, lv in ipairs(order) do
        local rows, fold = groups[lv], rs.class .. '_' .. lv
        local spells, tomes, held, need = 0, 0, 0, {}
        for _, e in ipairs(rows) do
            if is_tome(e.name) then tomes = tomes + 1 else spells = spells + 1 end
            local h = A.researchHeld(e.recipe.name) or 0
            if h > 0 then held = held + 1 end
            if h < rs.qty then need[#need + 1] = { recipe = e.recipe, qty = rs.qty } end
        end
        if i > 1 and ImGui.Spacing then ImGui.Spacing() end
        -- the fold toggle: an arrow where the build has them (right = folded, down = open), else a - / + button
        local flip
        if ImGui.ArrowButton and ImGuiDir then
            local ok, r = pcall(ImGui.ArrowButton, '##lc_rs_fold_' .. fold, rs.closed[fold] and ImGuiDir.Right or ImGuiDir.Down)
            flip = ok and r
        else
            flip = ImGui.Button((rs.closed[fold] and '+' or '-') .. '##lc_rs_fold_' .. fold)
        end
        if flip then rs.closed[fold] = not rs.closed[fold] end
        local what = {}
        if spells > 0 then what[#what + 1] = spells .. (spells == 1 and ' spell' or ' spells') end
        if tomes > 0 then what[#what + 1] = tomes .. (tomes == 1 and ' tome' or ' tomes') end
        if held > 0 then what[#what + 1] = held .. ' held' end
        local title = string.format('Level %d  -  %s', lv, table.concat(what, ', '))
        local qtext = string.format('Queue %d', #need)
        ImGui.SameLine()
        -- QUEUE ON THE RIGHT (2.45.2): title, a rule out to the button, the button against the right edge. Measured
        -- before anything is drawn; where the build cannot measure (or the tests), the divider as before.
        local geo
        if A.queueAdd then
            local ok, g = pcall(function()
                local function num(v) if type(v) == 'number' then return v end; return v.x end
                local w = num(ImGui.GetContentRegionAvail())
                local pad, padY = 4, 3
                pcall(function() local st = ImGui.GetStyle(); pad, padY = st.FramePadding.x, st.FramePadding.y end)
                local x, y = ImGui.GetCursorScreenPos()
                local g = { w = w, lw = num(ImGui.CalcTextSize(title)), bw = num(ImGui.CalcTextSize(qtext)) + pad * 2,
                            x = x, y = y, mid = y + padY + ImGui.GetFontSize() * 0.5, sp = 10 }
                for _, k in ipairs({ 'w', 'lw', 'bw', 'x', 'mid' }) do assert(type(g[k]) == 'number') end
                return g
            end)
            if ok and g.w > g.lw + g.bw + g.sp * 2 then geo = g end
        end
        local off = #need == 0
        local function queue_button()
            if off and ImGui.BeginDisabled then ImGui.BeginDisabled(true) end
            if ImGui.SmallButton(qtext .. '##lc_rs_qlv_' .. fold) and not off then
                for _, t in ipairs(need) do A.queueAdd('research', t.recipe, t.qty, 'keep') end
            end
            if off and ImGui.EndDisabled then ImGui.EndDisabled() end
        end
        if geo then
            pcall(ImGui.AlignTextToFramePadding)
            colored(ImGui, MUTED, title)
            pcall(function()
                local x0, x1 = geo.x + geo.lw + geo.sp, geo.x + geo.w - geo.bw - geo.sp
                if x1 > x0 then
                    ImGui.GetWindowDrawList():AddLine(ImVec2(x0, geo.mid), ImVec2(x1, geo.mid), IM_COL32(150, 154, 166, 90), 1)
                end
            end)
            ImGui.SameLine(0, geo.w - geo.lw - geo.bw)
            queue_button()
        else
            if A.queueAdd then queue_button(); ImGui.SameLine() end
            self:subheading(title)
        end
        if not rs.closed[fold] then self:research_rows(rows, lv) end
    end
    self:queue_panel()
end

-- ---------------------------------------------------------------- Workers

local WORKER_PILL = { ok = 'ok', waiting = 'warn', ['not answering'] = 'bad', stopped = 'bad' }
local STATE_PILL = { idle = 'muted', busy = 'warn', paused = 'warn' }

function Window:workers_tab()
    local ImGui, A = self.ImGui, self.actions
    -- every character the network sees: Start for anyone in a safe zone who is not working yet; anyone out in
    -- the world (or whose zone is not known) is greyed out and not started from here
    local rows = A.roster and A.roster() or self.crew:view()
    local startable, running, others = {}, {}, {}
    for _, r in ipairs(rows) do
        if r.running then running[#running + 1] = r else others[#others + 1] = r end
        if r.safe and not r.running then startable[#startable + 1] = r.name end
    end
    if ImGui.Button('Ask workers') then self.crew:hello() end
    if A.checkBooks then
        ImGui.SameLine()
        if A.bookBusy and A.bookBusy() then ImGui.TextDisabled('reading spellbooks...')
        elseif ImGui.Button('Check spellbooks##lc_books') then A.checkBooks() end
    end
    if A.startWorker then
        ImGui.SameLine()
        if self:button(string.format('Start all (%d)##lc_wall', #startable), #startable > 0) then
            for _, n in ipairs(startable) do A.startWorker(n) end
        end
    end
    if #rows == 0 then ImGui.TextDisabled('Nobody on the network yet') end
    local function where(r)
        return (r.class and (r.class .. (r.level and (' ' .. r.level) or '')) or '?')
    end

    self:heading(string.format('Running  (%d)', #running))
    if #running > 0 then
        self:table('##lc_w_run', { { 'Name', w = 90 }, { 'Class', w = 110 }, { 'Zone', w = 110 }, { 'State', w = 76 }, { 'Casts' }, { '', w = 64 } }, function()
            for _, r in ipairs(running) do
                self:row()
                self:cell(); ImGui.Text(r.name)
                self:cell(); ImGui.TextDisabled(where(r))
                self:cell(); ImGui.TextDisabled(r.zone or '?')
                self:cell()
                local word = r.state or '?'
                local kind = WORKER_PILL[r.status] ~= 'ok' and WORKER_PILL[r.status] or STATE_PILL[word] or 'info'
                self:pill((WORKER_PILL[r.status] and WORKER_PILL[r.status] ~= 'ok') and r.status or word, kind)
                self:cell()
                ImGui.TextDisabled(#(r.items or {}) > 0 and table.concat(r.items, ', ') or 'nothing')
                if #(r.lacks or {}) > 0 then colored(ImGui, CHECK_COLOR.block, 'missing: ' .. table.concat(r.lacks, ', ')) end
                if r.old then colored(ImGui, CHECK_COLOR.warn, string.format('runs %s, not this version', r.version or 'an older version')) end
                self:cell()
                if r.old and A.restartWorker then
                    if ImGui.Button('Restart##lc_wr_' .. r.name) then A.restartWorker(r.name) end
                end
            end
        end)
    end

    -- summon orders placed at Go (worked between everything else on that worker)
    local sm = A.summons and A.summons() or {}
    if #sm > 0 then
        self:heading('Summon orders')
        self:table('##lc_w_sum', { { 'Worker', w = 90 }, { 'Item' }, { 'Made', w = 130 }, { '', w = 120 } }, function()
            for _, o in ipairs(sm) do
                self:row()
                self:cell(); ImGui.Text(o.worker)
                self:cell(); ImGui.Text(o.item)
                self:cell()
                local have = o.have or 0
                self:bar(o.n > 0 and have / o.n or 0, string.format('%d / %d', have, o.n))
                self:cell()
                if o.failed then colored(ImGui, CHECK_COLOR.warn, tostring(o.failed))
                else ImGui.TextDisabled(o.done and 'all made' or string.format('%d taken%s', o.taken or 0, o.status and (', ' .. o.status) or '')) end
            end
        end)
    end

    self:heading(string.format('On the network  (%d not running)', #others))
    if #others > 0 then
        self:table('##lc_w_net', { { 'Name', w = 90 }, { 'Class', w = 110 }, { 'Zone', w = 110 }, { 'Casts' }, { '', w = 64 } }, function()
            for _, r in ipairs(others) do
                self:row()
                self:cell()
                if r.safe then ImGui.Text(r.name) else ImGui.TextDisabled(r.name) end
                self:cell(); ImGui.TextDisabled(where(r))
                self:cell()
                ImGui.TextDisabled((r.zone or 'zone unknown') .. (r.safe == false and ' (not safe)' or ''))
                self:cell()
                local before = #(r.castBefore or {}) > 0 and table.concat(r.castBefore, ', ') or nil
                if before then ImGui.TextDisabled(before) elseif #(r.lacks or {}) == 0 then ImGui.TextDisabled('-') end
                if #(r.lacks or {}) > 0 then colored(ImGui, CHECK_COLOR.block, 'missing: ' .. table.concat(r.lacks, ', ')) end
                if r.status then ImGui.TextDisabled(r.status) end
                self:cell()
                if r.safe and A.startWorker then
                    if ImGui.Button('Start##lc_ws_' .. r.name) then A.startWorker(r.name) end
                end
            end
        end)
    end
    if A.startWorker then
        self:heading('Start by name')
        if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(160) end
        self.workerName = input_text(ImGui, 'Name##lc_wname', self.workerName)
        ImGui.SameLine()
        if ImGui.Button('Start##lc_wstart') and self.workerName ~= '' then A.startWorker(self.workerName) end
    end
end

-- ---------------------------------------------------------------- Log, Travel, Settings

function Window:log_tab()
    local ImGui = self.ImGui
    local cur = 'Info and up'
    for _, s in ipairs(LOG_SHOW) do if s[1] == self.logShow then cur = s[2] end end
    if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(150) end
    if ImGui.BeginCombo('Show##lc_logshow', cur) then
        for _, s in ipairs(LOG_SHOW) do
            if ImGui.Selectable(s[2] .. '##lc_logshow_' .. s[1], self.logShow == s[1]) then self.logShow = s[1] end
        end
        ImGui.EndCombo()
    end
    local min = self.logShow == 'warn' and 3 or (self.logShow == 'info' and 2 or 1)
    local lines = {}
    for _, e in ipairs(self.log.recent(LOG_LINES)) do
        if (LOG_RANK[e.level] or 2) >= min then lines[#lines + 1] = e end
    end
    ImGui.SameLine()
    if ImGui.Button('Copy##lc_logcopy') then
        local out = {}
        for _, e in ipairs(lines) do out[#out + 1] = e.time .. '  ' .. e.text end
        pcall(ImGui.SetClipboardText, table.concat(out, '\n'))
    end
    -- BeginChild and EndChild must always pair, so the lines are drawn under their own pcall.
    if ImGui.BeginChild('##lc_log', 0, 0, true) then
        pcall(function()
            for _, e in ipairs(lines) do
                colored(ImGui, LEVEL_COLOR[e.level] or LEVEL_COLOR.info, e.time .. '  ' .. e.text)
            end
        end)
    end
    ImGui.EndChild()
end

function Window:travel_tab()
    local ImGui, A = self.ImGui, self.actions
    local here = A.here and A.here() or '?'
    self:heading('In ' .. here)
    local list = {}
    for _, z in ipairs(A.zones() or {}) do if z ~= here then list[#list + 1] = z end end
    self:table('##lc_travel', { { 'Zone' }, { '', w = 50 } }, function()
        for _, z in ipairs(list) do
            self:row()
            self:cell(); ImGui.Text(z)
            self:cell()
            if ImGui.Button('Go##lc_t_' .. z) then A.travel(z) end
        end
    end, false)
end

-- One row per setting, under its section. A change is handed to onSetting, which applies and saves it at once.
function Window:settings_tab()
    local ImGui = self.ImGui
    local set, meta = self.settings or {}, self.settingsMeta or {}
    local section
    local function head(name)
        if name ~= section then
            section = name
            self:heading(name)
            if name == 'Money' and self.actions and self.actions.bankTrophies then
                if ImGui.Button('Bank tradeskill gear##lc_banktrophies') then self.actions.bankTrophies() end
                self:help('When the crafting is done: every trophy and leveling aid, every tool a recipe hands back (File, '
                    .. 'Smithy Hammer...) and every empty tradeskill kit inside a bag go into the bank here. A kit in a pack '
                    .. 'slot, or with anything in it, stays. Nothing happens while the queue has entries.')
            end
        end
    end
    for _, m in ipairs(meta) do
        head(m.section or 'Other')
        local id = m.label .. '##' .. m.key
        if m.kind == 'theme' then
            local cur = Theme.valid(set[m.key]) and set[m.key] or 'Midnight'
            if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(150) end
            if ImGui.BeginCombo(id, cur) then
                for _, name in ipairs(Theme.NAMES) do
                    if ImGui.Selectable(name .. '##lc_theme_' .. name, name == cur) and name ~= cur then self.onSetting(m.key, name) end
                end
                ImGui.EndCombo()
            end
        elseif m.kind == 'ms' then
            local cur = tonumber(set[m.key]) or 0
            if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(120) end
            local val, changed = ImGui.InputInt(m.label .. ' (ms)##' .. m.key, cur, 10, 100)
            if changed == nil then changed = val ~= cur end
            if changed and type(val) == 'number' and val ~= cur then self.onSetting(m.key, tostring(math.max(0, math.floor(val)))) end
        elseif m.kind == 'pp' then
            local cur = tonumber(set[m.key]) or 0
            if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(120) end
            local val, changed = ImGui.InputInt(m.label .. ' (pp)##' .. m.key, cur, 1, 10)
            if changed == nil then changed = val ~= cur end
            if changed and type(val) == 'number' and val ~= cur then self.onSetting(m.key, tostring(math.max(0, math.floor(val)))) end
        elseif m.kind == 'bool' then
            local cur = set[m.key] == '1'
            local val, pressed = ImGui.Checkbox(id, cur)
            if pressed == nil then pressed = val ~= cur end
            if pressed and val ~= cur then self.onSetting(m.key, val and '1' or '0') end
        elseif m.kind == 'choice' then
            if ImGui.SetNextItemWidth then ImGui.SetNextItemWidth(150) end
            if ImGui.BeginCombo(id, tostring(set[m.key])) then
                for _, c in ipairs(m.choices) do
                    if ImGui.Selectable(c .. '##' .. m.key .. '_' .. c, set[m.key] == c) and set[m.key] ~= c then self.onSetting(m.key, c) end
                end
                ImGui.EndCombo()
            end
        end
        if m.help then self:help(m.help) end
    end
end

-- ---------------------------------------------------------------- the window

function Window:tabs()
    local A = self.actions
    local list = {}
    if A.search then list[#list + 1] = { 'Craft', self.craft_tab } end
    if A.radixRows then list[#list + 1] = { 'Radix', self.radix_tab } end
    if A.levelSkills then list[#list + 1] = { 'Leveling', self.level_tab } end
    if A.researchClasses then list[#list + 1] = { 'Research', self.research_tab } end
    if A.summon then list[#list + 1] = { 'Summon', self.summon_tab } end
    if self.crew and self.role == 'crafter' then list[#list + 1] = { 'Workers', self.workers_tab } end
    list[#list + 1] = { 'Log', self.log_tab }
    if A.zones then list[#list + 1] = { 'Travel', self.travel_tab } end
    list[#list + 1] = { 'Settings', self.settings_tab }
    return list
end

function Window:body()
    local ImGui = self.ImGui
    self:once('h1', 'drawing the header')
    self:header()
    self:once('h2', 'drawing the job panel')
    self:job_panel()
    self:once('h3', 'header and job panel drawn')
    -- Every Begin is paired with its End even when a tab's drawing fails; the error is raised afterwards.
    local failed
    if ImGui.BeginTabBar('##lc_tabs') then
        for _, tab in ipairs(self:tabs()) do
            if ImGui.BeginTabItem(tab[1]) then
                self:once('tab1' .. tab[1], 'drawing the %s tab', tab[1])
                local ok, err = pcall(tab[2], self)
                ImGui.EndTabItem()
                self:once('tab2' .. tab[1], '%s tab drawn', tab[1])
                if not ok then failed = failed or err end
            end
        end
        ImGui.EndTabBar()
    end
    if failed then error(failed, 0) end
end

-- the theme in force: this character's setting (a worker's comes from its crafter)
function Window:theme_name()
    local name = self.settings and self.settings.Theme
    return Theme.valid(name) and name or 'Midnight'
end

-- A window drawn with the theme pushed around it; a drawing error is reported once, never every frame.
function Window:themed(title, open, w, h, fn)
    local ImGui = self.ImGui
    local name = self:theme_name()
    if name ~= self.palName then self.pal, self.palName = Theme.palette(name), name end
    if ImGui.SetNextWindowSize and ImGuiCond then ImGui.SetNextWindowSize(w, h, ImGuiCond.FirstUseEver) end
    self:once('theme' .. name, 'pushing the %s theme', name)
    local cols, vars = Theme.push(ImGui, name)
    -- once per theme, what landed (2.43.1: the first 2.43 run themed nothing and drew no tables - this line says so)
    if self.saidTheme ~= name and self.log and self.log.debug then
        self.saidTheme = name
        self.log.debug('Window: theme %s - %d colours and %d style vars pushed; tables %s', name, cols, vars,
            ImGuiTableFlags and 'on' or 'off (plain lines)')
    end
    self:once('themed' .. name, '%s theme: %d colours and %d style vars pushed', name, cols, vars)
    local a, b
    if open ~= nil then a, b = ImGui.Begin(title, open) else a, b = ImGui.Begin(title) end
    local show = b
    if show == nil then show = a end
    if show then
        local ok, err = pcall(fn)
        if not ok and err ~= self.drawError then
            self.drawError = err
            self.log.error('Window error: %s', tostring(err))
        end
    end
    ImGui.End()
    Theme.pop(ImGui, cols, vars)
    self:once('frame1', 'first frame done')
    return a
end

-- A worker's window (2.42.7; themed 2.43.0): who it is and works for, what it is doing, and Pause / Resume - a
-- pause holds the job at its next safe point (never mid-trade) and starts nothing new; the crafter is told and
-- waits. No close: the crafter's Close all closes every worker.
function Window:draw_worker(crafter)
    local ImGui, A = self.ImGui, self.actions
    self:themed('LazCraft ' .. self.version .. ' - worker###lazcraftw', nil, 360, 200, function()
        local v = self.runner:view()
        local held = A.held and A.held()
        self:logo(36)
        ImGui.SameLine()
        if ImGui.BeginGroup then ImGui.BeginGroup() end
        colored(ImGui, self.pal.label, tostring(self.me or 'Worker'))
        if (crafter or '') == '' then
            colored(ImGui, CHECK_COLOR.warn, 'Waiting for a crafter (its Workers tab: Ask workers)')
        else
            ImGui.TextDisabled('Working for ' .. tostring(crafter) .. ', theme from ' .. tostring(crafter))
        end
        if ImGui.EndGroup then ImGui.EndGroup() end
        ImGui.SameLine()
        to_right(ImGui, 90)
        if held then self:pill('Paused', 'warn') elseif v.active then self:pill('Working', 'info') else self:pill('Idle', 'muted') end
        self:heading('Now')
        if v.active then
            ImGui.Text(v.active.name)
            if v.active.status ~= '' then ImGui.TextDisabled(v.active.status) end
            if v.active.total > 0 then
                self:bar(v.active.done / v.active.total, string.format('%d / %d', v.active.done, v.active.total))
            end
        else
            ImGui.TextDisabled('Idle')
        end
        if v.queued > 0 then ImGui.TextDisabled(string.format('%d queued', v.queued)) end
        if held then
            colored(ImGui, CHECK_COLOR.warn, (v.active and not v.paused) and 'Pausing once this trade is done'
                or string.format('Paused - %s waits', tostring(crafter)))
            if ImGui.Button('Resume##lc_wres') then A.hold(false) end
        else
            if ImGui.Button('Pause##lc_wpause') then A.hold(true) end
        end
    end)
end

function Window:draw()
    if not self.visible then return end
    local open = self:themed('LazCraft ' .. self.version .. '###lazcraft', true, 640, 760, function() self:body() end)
    if open == false then self.visible = false end
end

return Window
