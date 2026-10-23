-- Theme: the window's colours and corners, AdventureTime's four themes (2.43.0). Pushed once around each window
-- (Begin..End) and popped after; a colour or style slot this build does not have is simply not pushed, and exactly
-- what went on comes off (a missing slot never unbalances ImGui's stacks).
--   Theme.NAMES                       in the order the Settings tab lists them
--   Theme.get(name) -> theme          an unknown name is Midnight
--   Theme.push(ImGui, name) -> cols, vars     Theme.pop(ImGui, cols, vars)
--   Theme.palette(name) -> { label, accent, sel, head, rowA, rowB, line }   colours the window draws with itself
-- Colours are 0-255 RGBA as AT writes them; ImGui gets 0-1 floats.
local Theme = {}

Theme.NAMES = { 'Midnight', 'Slate', 'Ember', 'Glass' }

local THEMES = {
    Midnight = {   -- deep blue-black, soft corners
        cols = { WindowBg = { 18, 20, 27, 242 }, TitleBg = { 24, 28, 40, 255 }, TitleBgActive = { 38, 54, 84, 255 },
                 Border = { 46, 54, 72, 255 }, FrameBg = { 32, 36, 48, 255 }, FrameBgHovered = { 48, 54, 72, 255 },
                 Button = { 44, 50, 66, 255 }, ButtonHovered = { 62, 72, 96, 255 }, ButtonActive = { 80, 95, 125, 255 },
                 TableRowBg = { 22, 24, 32, 255 }, TableRowBgAlt = { 27, 30, 40, 255 },
                 ResizeGrip = { 0, 0, 0, 0 }, ResizeGripHovered = { 62, 72, 96, 140 }, ResizeGripActive = { 80, 95, 125, 190 },
                 ScrollbarBg = { 0, 0, 0, 0 }, ScrollbarGrab = { 44, 50, 66, 200 }, ScrollbarGrabHovered = { 62, 72, 96, 230 },
                 Separator = { 66, 78, 104, 230 } },
        vars = { WindowRounding = 6, FrameRounding = 4, ChildRounding = 4, WindowBorderSize = 1, ScrollbarSize = 10,
                 ScrollbarRounding = 5, GrabRounding = 4, PopupRounding = 6, WindowTitleAlign = 0.5 },
        pal = { label = { 157, 180, 224 }, accent = { 74, 111, 165 }, sel = { 52, 64, 90 } } },
    Slate = {      -- neutral grey, square, hairline border
        cols = { WindowBg = { 26, 27, 30, 240 }, TitleBg = { 34, 35, 39, 255 }, TitleBgActive = { 52, 54, 60, 255 },
                 Border = { 70, 72, 78, 255 }, FrameBg = { 40, 42, 46, 255 }, FrameBgHovered = { 56, 58, 64, 255 },
                 Button = { 52, 54, 60, 255 }, ButtonHovered = { 72, 75, 82, 255 }, ButtonActive = { 92, 96, 104, 255 },
                 TableRowBg = { 30, 31, 35, 255 }, TableRowBgAlt = { 35, 36, 41, 255 },
                 ResizeGrip = { 0, 0, 0, 0 }, ResizeGripHovered = { 72, 75, 82, 140 }, ResizeGripActive = { 92, 96, 104, 190 },
                 ScrollbarBg = { 0, 0, 0, 0 }, ScrollbarGrab = { 52, 54, 60, 200 }, ScrollbarGrabHovered = { 72, 75, 82, 230 },
                 Separator = { 84, 86, 92, 230 } },
        vars = { WindowRounding = 0, FrameRounding = 0, ChildRounding = 0, WindowBorderSize = 1, ScrollbarSize = 9,
                 ScrollbarRounding = 0, GrabRounding = 0, PopupRounding = 0, WindowTitleAlign = 0.5 },
        pal = { label = { 196, 200, 207 }, accent = { 111, 117, 127 }, sel = { 60, 63, 69 } } },
    Ember = {      -- near-black ground, warm edges
        cols = { WindowBg = { 22, 18, 16, 244 }, TitleBg = { 36, 26, 20, 255 }, TitleBgActive = { 92, 54, 24, 255 },
                 Border = { 96, 62, 34, 255 }, FrameBg = { 40, 30, 24, 255 }, FrameBgHovered = { 62, 44, 30, 255 },
                 Button = { 54, 38, 26, 255 }, ButtonHovered = { 84, 58, 34, 255 }, ButtonActive = { 122, 80, 40, 255 },
                 TableRowBg = { 26, 21, 18, 255 }, TableRowBgAlt = { 32, 26, 22, 255 },
                 ResizeGrip = { 0, 0, 0, 0 }, ResizeGripHovered = { 84, 58, 34, 140 }, ResizeGripActive = { 122, 80, 40, 190 },
                 ScrollbarBg = { 0, 0, 0, 0 }, ScrollbarGrab = { 54, 38, 26, 200 }, ScrollbarGrabHovered = { 84, 58, 34, 230 },
                 Separator = { 120, 78, 42, 230 } },
        vars = { WindowRounding = 8, FrameRounding = 6, ChildRounding = 6, WindowBorderSize = 1, ScrollbarSize = 10,
                 ScrollbarRounding = 6, GrabRounding = 6, PopupRounding = 8, WindowTitleAlign = 0.5 },
        pal = { label = { 232, 168, 104 }, accent = { 184, 112, 46 }, sel = { 74, 50, 32 } } },
    Glass = {      -- heavy transparency, no border
        cols = { WindowBg = { 12, 14, 20, 170 }, TitleBg = { 16, 20, 30, 190 }, TitleBgActive = { 30, 42, 66, 210 },
                 Border = { 0, 0, 0, 0 }, FrameBg = { 30, 34, 46, 160 }, FrameBgHovered = { 48, 54, 72, 190 },
                 Button = { 40, 46, 62, 170 }, ButtonHovered = { 60, 70, 94, 200 }, ButtonActive = { 78, 92, 122, 220 },
                 TableRowBg = { 0, 0, 0, 0 }, TableRowBgAlt = { 255, 255, 255, 10 },
                 ResizeGrip = { 0, 0, 0, 0 }, ResizeGripHovered = { 255, 255, 255, 40 }, ResizeGripActive = { 255, 255, 255, 70 },
                 ScrollbarBg = { 0, 0, 0, 0 }, ScrollbarGrab = { 255, 255, 255, 40 }, ScrollbarGrabHovered = { 255, 255, 255, 70 },
                 Separator = { 255, 255, 255, 50 } },
        vars = { WindowRounding = 10, FrameRounding = 8, ChildRounding = 8, WindowBorderSize = 0, ScrollbarSize = 8,
                 ScrollbarRounding = 6, GrabRounding = 6, PopupRounding = 10, WindowTitleAlign = 0.5 },
        pal = { label = { 188, 208, 240 }, accent = { 111, 143, 200 }, sel = { 70, 86, 120 } } },
}

function Theme.get(name)
    return THEMES[name or ''] or THEMES.Midnight
end

function Theme.valid(name)
    return THEMES[name or ''] ~= nil
end

-- the colours the window draws with itself (headings, progress, the picked row, table heads), 0-1 floats
function Theme.palette(name)
    local t = Theme.get(name)
    local function f(c, a) return { c[1] / 255, c[2] / 255, c[3] / 255, a or 1 } end
    return { label = f(t.pal.label), accent = f(t.pal.accent), sel = f(t.pal.sel), head = f(t.cols.TitleBg),
             line = f(t.cols.Separator, t.cols.Separator[4] / 255) }
end

-- every slot pushed, in this order; the ones a theme leaves out borrow from one it has (as AT does)
local SLOTS = {
    { 'WindowBg' }, { 'TitleBg' }, { 'TitleBgActive' }, { 'TitleBgCollapsed', 'TitleBg' }, { 'Border' },
    { 'FrameBg' }, { 'FrameBgHovered' }, { 'FrameBgActive', 'FrameBgHovered' },
    { 'Button' }, { 'ButtonHovered' }, { 'ButtonActive' },
    { 'TableRowBg' }, { 'TableRowBgAlt' }, { 'TableHeaderBg', 'TitleBg' }, { 'TableBorderLight', 'Separator' },
    { 'TableBorderStrong', 'Separator' },
    { 'ResizeGrip' }, { 'ResizeGripHovered' }, { 'ResizeGripActive' },
    { 'ScrollbarBg' }, { 'ScrollbarGrab' }, { 'ScrollbarGrabHovered' }, { 'ScrollbarGrabActive', 'ButtonActive' },
    { 'Separator' },
    { 'Tab', 'TitleBg' }, { 'TabHovered', 'ButtonHovered' }, { 'TabActive', 'TitleBgActive' },
    { 'TabUnfocused', 'TitleBg' }, { 'TabUnfocusedActive', 'FrameBg' },
    { 'Header', 'Button' }, { 'HeaderHovered', 'ButtonHovered' }, { 'HeaderActive', 'ButtonActive' },
    { 'PopupBg', 'WindowBg' }, { 'MenuBarBg', 'TitleBg' }, { 'CheckMark', 'ButtonActive' },
    { 'SliderGrab', 'Button' }, { 'SliderGrabActive', 'ButtonActive' },
}
local VARS = { 'WindowRounding', 'FrameRounding', 'ChildRounding', 'WindowBorderSize', 'ScrollbarSize',
               'ScrollbarRounding', 'GrabRounding', 'PopupRounding' }

-- -> cols, vars pushed (0, 0 where the build has no ImGuiCol / ImGuiStyleVar, as in the tests)
function Theme.push(ImGui, name)
    local t = Theme.get(name)
    local cols, vars = 0, 0
    -- plain global names, as AdventureTime reads them: in MQ neither rawget(_G, ...) (2.43.1) nor _G[...] (2.43.2-2.43.5
    -- log: "0 colours and 0 style vars pushed; tables off") finds them, while plain ImVec2 / IM_COL32 draw the
    -- progress bars. A colour goes as one IM_COL32 value, as AT pushes it (floats where there is no IM_COL32: tests).
    local Col, Var = ImGuiCol, ImGuiStyleVar
    if Col and ImGui.PushStyleColor then
        local packed = IM_COL32
        local function col(slot, c)
            if not Col[slot] or not c then return end
            local ok
            if packed then ok = pcall(function() ImGui.PushStyleColor(Col[slot], packed(c[1], c[2], c[3], c[4])) end)
            else ok = pcall(ImGui.PushStyleColor, Col[slot], c[1] / 255, c[2] / 255, c[3] / 255, c[4] / 255) end
            if ok then cols = cols + 1 end
        end
        for _, s in ipairs(SLOTS) do col(s[1], t.cols[s[1]] or (s[2] and t.cols[s[2]])) end
        -- the progress bars' fill: the theme's accent
        col('PlotHistogram', { t.pal.accent[1], t.pal.accent[2], t.pal.accent[3], 255 })
    end
    if Var and ImGui.PushStyleVar then
        for _, k in ipairs(VARS) do
            if Var[k] and t.vars[k] ~= nil and pcall(ImGui.PushStyleVar, Var[k], t.vars[k]) then vars = vars + 1 end
        end
        -- a centred title: the one two-float var here
        if Var.WindowTitleAlign and t.vars.WindowTitleAlign and pcall(ImGui.PushStyleVar, Var.WindowTitleAlign, t.vars.WindowTitleAlign, 0.5) then
            vars = vars + 1
        end
    end
    return cols, vars
end

function Theme.pop(ImGui, cols, vars)
    if (vars or 0) > 0 then pcall(ImGui.PopStyleVar, vars) end
    if (cols or 0) > 0 then pcall(ImGui.PopStyleColor, cols) end
end

return Theme
