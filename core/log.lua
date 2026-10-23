-- Logging: one place that decides what is printed, kept for the window, and written to disk.
--   Log.info('Bought %d %s', n, name)   -- printf-style; levels: debug, info, warn, error
--   Log.recent(20)                      -- last lines for the window, oldest first
--
-- Two levels: the console (and the window) shows `level` and above; the file gets `fileLevel` and above,
-- so the file can hold every step while the console stays quiet. File lines carry the seconds since start
-- (to the millisecond) so timings can be read straight off the log. The file stays open for the session,
-- and the previous session's file is kept as <name>.prev.log.
local Log = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local COLOR  = { debug = '\a-w', info = '\aw', warn = '\ay', error = '\ar' }

local S = {
    level     = 'info',
    fileLevel = 'debug',
    keep      = 200,         -- lines kept in memory for the window
    recent    = {},
    printer   = print,
    prefix    = '\ag[LC]\ax ',
    clock     = nil,         -- ms clock (mq.gettime); file lines show seconds since start when set
    t0        = 0,
    file      = nil,
    path      = nil,
}

function Log.setup(opts)
    opts = opts or {}
    if opts.level and LEVELS[opts.level] then S.level = opts.level end
    if opts.fileLevel and LEVELS[opts.fileLevel] then S.fileLevel = opts.fileLevel end
    if opts.printer then S.printer = opts.printer end
    if opts.keep then S.keep = opts.keep end
    if opts.prefix then S.prefix = opts.prefix end
    if opts.clock then S.clock = opts.clock; S.t0 = opts.clock() end
end

function Log.set_level(level) if LEVELS[level] then S.level = level end end
function Log.set_file_level(level) if LEVELS[level] then S.fileLevel = level end end
function Log.level() return S.level end

-- Start a log file. The previous one is kept as .prev.log. Returns true, or false and the reason.
function Log.open_file(path)
    Log.close_file()
    local prev = path:gsub('%.log$', '') .. '.prev.log'
    os.remove(prev)
    os.rename(path, prev)    -- fails harmlessly when there is no previous file
    local fh, err = io.open(path, 'w')
    if not fh then return false, err end
    S.file, S.path = fh, path
    fh:write(string.format('LazCraft log started %s\n', os.date('%Y-%m-%d %H:%M:%S')))
    fh:flush()
    return true
end

function Log.close_file()
    if S.file then pcall(function() S.file:close() end) end
    S.file, S.path = nil, nil
end

function Log.file_path() return S.path end

local function format(fmt, ...)
    if select('#', ...) == 0 then return tostring(fmt) end
    local ok, msg = pcall(string.format, fmt, ...)
    if ok then return msg end
    -- A bad format string must never take the script down; log what we were given instead.
    local parts = { tostring(fmt) }
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, ' ')
end

function Log.write(level, fmt, ...)
    local rank = LEVELS[level] or LEVELS.info
    local toConsole = rank >= LEVELS[S.level]
    local toFile = S.file ~= nil and rank >= LEVELS[S.fileLevel]
    if not toConsole and not toFile then return end
    local msg = format(fmt, ...)
    local time = os.date('%H:%M:%S')
    -- the file first: if printing ever takes the client down, the line that did it is already saved
    if toFile then
        local secs = S.clock and string.format(' %9.3f', (S.clock() - S.t0) / 1000) or ''
        S.file:write(string.format('%s%s %-5s %s\n', time, secs, level:upper(), msg))
        S.file:flush()
    end
    if toConsole then
        -- the game's chat line has a fixed buffer: a 12-row leveling path summary (about 3,000 characters) took the
        -- client down as it printed (2.32.0 log, 00:18:02). The console gets CONSOLE_MAX; the file gets it all.
        local shown = msg
        if #shown > Log.CONSOLE_MAX then shown = shown:sub(1, Log.CONSOLE_MAX) .. ' ... (the rest is in the log file)' end
        local r = S.recent
        r[#r + 1] = { time = time, level = level, text = shown }
        if #r > S.keep then table.remove(r, 1) end
        S.printer(S.prefix .. (COLOR[level] or '') .. shown .. '\ax')
    end
end

Log.CONSOLE_MAX = 600

function Log.debug(fmt, ...) Log.write('debug', fmt, ...) end
function Log.info(fmt, ...)  Log.write('info', fmt, ...) end
function Log.warn(fmt, ...)  Log.write('warn', fmt, ...) end
function Log.error(fmt, ...) Log.write('error', fmt, ...) end

-- The last n console lines (or all kept), oldest first. Returns the live entries; callers must not modify them.
function Log.recent(n)
    local r = S.recent
    if not n or n >= #r then return r end
    local out = {}
    for i = #r - n + 1, #r do out[#out + 1] = r[i] end
    return out
end

function Log.clear() S.recent = {} end

return Log
