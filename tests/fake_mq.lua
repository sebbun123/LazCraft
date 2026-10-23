-- A fake MacroQuest and ImGui, enough to run LazCraft outside the game.
-- Time is virtual: mq.delay advances a clock in frame-sized steps and runs anything scheduled for that
-- time, which is how tests type commands and click buttons while the script is "running".
local F = {
    now = 0, frameMs = 16,
    cmds = {}, binds = {}, pending = {}, scheduled = {}, render = nil, depth = 0, maxDepthSeen = 0,
    tlo = { ['Me.CleanName'] = 'Glanen', ['EverQuest.GameState'] = 'INGAME' },
    frame = {}, clicks = {}, printed = {},
    ticks = {},   -- functions(dtMs) run every frame, for things that move on their own
    events = {},
    inputs = {}, tab = 'Status',
}

local function run_due()
    local i = 1
    while i <= #F.scheduled do
        local s = F.scheduled[i]
        if s.at <= F.now then
            table.remove(F.scheduled, i)
            s.fn()
        else
            i = i + 1
        end
    end
end

function F.at(ms, fn)
    F.scheduled[#F.scheduled + 1] = { at = ms, fn = fn }
    table.sort(F.scheduled, function(a, b) return a.at < b.at end)
end

-- TLO: any chain of fields, called at the end, looks up F.tlo['A.B.C'].
local function tlo_proxy(path)
    return setmetatable({}, {
        __index = function(_, k) return tlo_proxy(path == '' and k or (path .. '.' .. k)) end,
        __call = function() return F.tlo[path] end,
    })
end

local mq = {
    TLO = tlo_proxy(''),
    configDir = nil,
    gettime = function() return F.now end,
    -- Like MQ, a bound command only runs inside mq.doevents().
    doevents = function()
        local due = F.pending
        F.pending = {}
        for _, call in ipairs(due) do call.fn(unpack(call.args)) end
    end,
    delay = function(ms, cond)
        if type(ms) ~= 'number' then error('fake mq.delay: tests only use numeric delays') end
        local target = F.now + ms
        repeat
            F.now = F.now + F.frameMs
            if F.now > 600000 then error('runaway: virtual clock passed 10 minutes') end
            for _, t in ipairs(F.ticks) do t(F.frameMs) end
            run_due()
            if cond and cond() then return end
        until F.now >= target
    end,
    cmd = function(s)
        F.cmds[#F.cmds + 1] = s
        local name, rest = s:match('^(/%S+)%s*(.*)$')
        if name and F.binds[name] then
            local args = {}
            for w in rest:gmatch('%S+') do args[#args + 1] = w end
            F.pending[#F.pending + 1] = { fn = F.binds[name], args = args }
        end
    end,
    bind = function(name, fn) F.binds[name] = fn end,
    -- Chat events: '#*#' matches anything. Like MQ, a matched line's handler runs inside mq.doevents().
    event = function(name, pattern, fn) F.events[name] = { pattern = pattern, fn = fn } end,
    unevent = function(name) F.events[name] = nil end,
    unbind = function(name) F.binds[name] = nil end,
    imgui = { init = function(_, fn) F.render = fn end },
}

-- ImGui: records what was drawn this frame; Button returns true once for each label in F.clicks.
local ImGui = setmetatable({}, { __index = function() return function() return false end end })
local function rec(kind, text) F.frame[#F.frame + 1] = kind .. ':' .. tostring(text) end
-- Begin/End and BeginChild/EndChild are counted; a frame must end where it started.
local function push() F.depth = F.depth + 1; if F.depth > F.maxDepthSeen then F.maxDepthSeen = F.depth end end
local function pop() F.depth = F.depth - 1 end
ImGui.Begin = function() push(); return true, true end
ImGui.End = function() pop() end
ImGui.BeginChild = function() push(); return true end
ImGui.EndChild = function() pop() end
ImGui.Text = function(t) rec('text', t) end
ImGui.TextDisabled = function(t) rec('disabled', t) end
ImGui.TextColored = function(_, _, _, _, t) rec('colored', t) end
ImGui.ProgressBar = function(_, _, _, overlay) rec('progress', overlay) end
-- Tabs: only F.tab's item is drawn (default 'Status'), like a real tab bar showing one tab at a time.
ImGui.BeginTabBar = function() push(); return true end
ImGui.EndTabBar = function() pop() end
ImGui.BeginTabItem = function(label)
    rec('tab', label)
    if label == (F.tab or 'Status') then push(); return true end
    return false
end
ImGui.EndTabItem = function() pop() end
-- Inputs: F.inputs[label] is what the user typed this frame (consumed once); returns value, changed.
ImGui.InputInt = function(label, v)
    rec('input', label .. '=' .. tostring(v))
    local typed = F.inputs[label]
    if typed ~= nil then F.inputs[label] = nil; return typed, typed ~= v end
    return v, false
end
ImGui.Checkbox = function(label, v)
    rec('checkbox', label .. '=' .. tostring(v))
    if F.clicks[label] then F.clicks[label] = nil; return not v, true end
    return v, false
end
ImGui.RadioButton = function(label, active)
    rec('radio', label .. (active and '*' or ''))
    if F.clicks[label] then F.clicks[label] = nil; return true end
    return false
end
-- InputText: F.inputs[label] is what the user typed this frame (consumed once).
ImGui.InputText = function(label, v)
    rec('inputtext', label .. '=' .. tostring(v))
    local typed = F.inputs[label]
    if typed ~= nil then F.inputs[label] = nil; return typed, true end
    return v, false
end
ImGui.Selectable = function(label, selected)
    rec('selectable', label .. (selected and '*' or ''))
    if F.clicks[label] then F.clicks[label] = nil; return true end
    return false
end
-- A combo is open when F.openCombo names it; its Selectables are drawn and clickable then.
ImGui.BeginCombo = function(label, preview)
    rec('combo', label .. '=' .. tostring(preview))
    if F.openCombo == label then push(); return true end
    return false
end
ImGui.EndCombo = function() pop() end
ImGui.Button = function(label)
    rec('button', (F.disabled or 0) > 0 and (label .. ' (off)') or label)
    if (F.disabled or 0) > 0 then return false end
    if F.clicks[label] then F.clicks[label] = nil; return true end
    return false
end
ImGui.SmallButton = function(label)
    rec('smallbutton', (F.disabled or 0) > 0 and (label .. ' (off)') or label)
    if (F.disabled or 0) > 0 then return false end
    if F.clicks[label] then F.clicks[label] = nil; return true end
    return false
end
-- Disabled blocks: controls inside are drawn greyed and never fire.
ImGui.BeginDisabled = function(on) if on ~= false then F.disabled = (F.disabled or 0) + 1 end; F.disStack = F.disStack or {}; F.disStack[#F.disStack + 1] = on ~= false end
ImGui.EndDisabled = function() local on = table.remove(F.disStack); if on then F.disabled = F.disabled - 1 end end
ImGui.SetWindowFontScale = function(s) rec('fontscale', s) end
-- a titled section line (2.43.0)
ImGui.SeparatorText = function(t) rec('heading', t) end
-- tables (only when a test sets ImGuiTableFlags, as MQ has them): Begin/End counted like windows
ImGui.BeginTable = function(id) rec('table', id); push(); return true end
ImGui.EndTable = function() pop() end
ImGui.TableNextRow = function() rec('row', '') end
ImGui.TableNextColumn = function() return true end
ImGui.TableSetupColumn = function(label) rec('column', label) end
ImGui.TableHeadersRow = function() end
-- style stacks: counted; a frame must leave them where it found them
ImGui.PushStyleColor = function() F.styles = (F.styles or 0) + 1 end
ImGui.PopStyleColor = function(n) F.styles = (F.styles or 0) - (n or 1) end
ImGui.PushStyleVar = function() F.vars = (F.vars or 0) + 1 end
ImGui.PopStyleVar = function(n) F.vars = (F.vars or 0) - (n or 1) end
ImGui.Image = function(id, size)
    rec('image', tostring(id) .. (type(size) == 'table' and string.format(' %dx%d', size.x or 0, size.y or 0) or ''))
end
ImGui.BeginGroup = function() F.groups = (F.groups or 0) + 1 end
ImGui.EndGroup = function() F.groups = (F.groups or 0) - 1 end

-- A line of game chat: queues every matching event for the next mq.doevents().
function F.say(line)
    for _, ev in pairs(F.events) do
        local lua = '^' .. ev.pattern:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('#%*#', '.*')
        if line:find(lua) then F.pending[#F.pending + 1] = { fn = ev.fn, args = { line } } end
    end
end

function F.draw()
    F.frame = {}
    local before = F.depth
    if F.render then F.render() end
    if F.depth ~= before then error(string.format('ImGui stack unbalanced: depth %d after the frame, %d before', F.depth, before)) end
    if (F.disabled or 0) ~= 0 or #(F.disStack or {}) ~= 0 then error('BeginDisabled without EndDisabled') end
    if (F.styles or 0) ~= 0 or (F.vars or 0) ~= 0 then error(string.format('style stacks unbalanced: %d colours, %d vars', F.styles or 0, F.vars or 0)) end
    if (F.groups or 0) ~= 0 then error('BeginGroup without EndGroup') end
    return F.frame
end

function F.frame_has(pattern)
    for _, line in ipairs(F.frame) do if line:find(pattern) then return true end end
    return false
end

function F.click(label)
    F.clicks[label] = true
    F.draw()
end

function F.install(configDir)
    mq.configDir = configDir
    package.loaded['mq'] = mq
    package.loaded['ImGui'] = ImGui
    _G.print = function(s) F.printed[#F.printed + 1] = s end
    _G.ImGuiCond = { FirstUseEver = 4 }
end

F.mq, F.ImGui = mq, ImGui
return F
