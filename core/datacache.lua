-- DataCache: the parsed data/ (Config.load) saved as a Lua file, so a start loads it instead of parsing ~150k lines
-- (2.46.9).
--   load(opts)   opts = { dataDir, path, code = { parse code files }, who, log, clock,
--                         parse = function(onRead) -> cfg, problems }  (onRead(file) for each data file it reads)
--                R: cfg, problems, how ('cache' | 'parsed') - never fails: any trouble with the cache parses as before
--
-- Why (2.46.8 Shela log: the log opened at 23:03:52, the data was read 148.8s later; Vadar, another machine, 1.8s):
-- MQ runs a Lua script MQ2Lua.yaml turboNum VM instructions a frame (2000 here) and parks it until the next frame, so
-- a start costs frames in proportion to the instructions the parse takes - recipes.ini alone is 4.9MB, 137,602 lines.
-- Compiling a Lua file is done in C and costs no VM instructions; running it costs about two a value. So:
--   * Valid only for the same data files (each one's size, and its time when LuaFileSystem is there), the same
--     parse code (core/config.lua, core/ini.lua, this file) and the same cache format. Anything else: parse, then save again.
--   * The files Config.load read are learned by watching the parse (opts.read), so a new data file needs no list here.
--   * Shared tables (the same table under two keys) stay shared; so does a table that contains itself.
--   * Written to a temp file, then renamed into place: a character starting at the same moment reads the old cache,
--     the new one, or none - never half of one (a broken one fails to compile and is parsed past).
--   * The file is split into many small functions: LuaJIT allows 65,536 constants in one function.
local DataCache = {}

DataCache.FORMAT = 1          -- bump when the file's layout changes
DataCache.BIG = 200           -- a table with more entries than this is filled statement by statement (splittable)
DataCache.BATCH_CONSTS = 20000  -- constants (roughly) per generated function, well under LuaJIT's 65,536

local NOLOG = { info = function() end, debug = function() end, warn = function() end }

local KEYWORDS = {}
for w in ('and break do else elseif end false for function goto if in local nil not or repeat return then true until while')
        :gmatch('%S+') do KEYWORDS[w] = true end

-- the size of a file (and its modification time when LuaFileSystem is there), cheaply: no read
local function stamp(path)
    local fh = io.open(path, 'rb')
    if not fh then return 'missing' end
    local size = fh:seek('end') or -1
    fh:close()
    local ok, lfs = pcall(require, 'lfs')
    local mtime = ok and lfs and lfs.attributes and lfs.attributes(path, 'modification') or nil
    return mtime and string.format('%d@%d', size, mtime) or tostring(size)
end

-- the key: the cache format, the code that does the parsing (opts.code: config.lua, ini.lua, this file - an update
-- that leaves them alone keeps the cache, one that changes them makes it again), and every data file read
local function key_for(dataDir, files, code)
    local parts = { 'format ' .. DataCache.FORMAT }
    for _, p in ipairs(code or {}) do parts[#parts + 1] = 'code ' .. (p:match('[^\\/]+$') or p) .. '=' .. stamp(p) end
    local sorted = {}
    for f in pairs(files) do sorted[#sorted + 1] = f end
    table.sort(sorted)
    for _, f in ipairs(sorted) do parts[#parts + 1] = f .. '=' .. stamp(dataDir .. f) end
    return table.concat(parts, '|'), sorted
end

-- ---------------------------------------------------------------- writing
local function num(v)
    if v ~= v then return '(0/0)' end
    if v == math.huge then return 'math.huge' end
    if v == -math.huge then return '(-math.huge)' end
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format('%d', v) end
    return string.format('%.17g', v)
end

local function scalar(v)
    local t = type(v)
    if t == 'string' then return string.format('%q', v) end
    if t == 'number' then return num(v) end
    if t == 'boolean' then return v and 'true' or 'false' end
    return nil
end

-- Serialize `root` into the text of a Lua file returning { key = key, files = files, build = function() -> root }.
-- Returns text, or nil and why (a function, userdata or thread in the data).
function DataCache.serialize(root, key, files)
    -- 1. which tables go to the registry T: the root, any reached twice (or within itself), any too big to inline
    local seen, reg, regList, onStack = {}, {}, {}, {}
    local bad
    local function count(t)
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end
    local function visit(t)
        if seen[t] then
            if not reg[t] then reg[t] = true; regList[#regList + 1] = t end
            return
        end
        seen[t] = true
        onStack[t] = true
        for k, v in pairs(t) do
            if type(k) == 'table' then bad = bad or 'a table used as a key' end
            if type(v) == 'table' then
                if onStack[v] and not reg[v] then reg[v] = true; regList[#regList + 1] = v end
                visit(v)
            elseif scalar(v) == nil then
                bad = bad or ('a ' .. type(v) .. ' value under ' .. tostring(k))
            end
            if type(k) ~= 'table' and scalar(k) == nil then bad = bad or ('a ' .. type(k) .. ' key') end
        end
        onStack[t] = nil
        if count(t) > DataCache.BIG and not reg[t] then reg[t] = true; regList[#regList + 1] = t end
    end
    visit(root)
    if bad then return nil, bad end
    if not reg[root] then reg[root] = true; table.insert(regList, 1, root) end
    local idx = {}
    for i, t in ipairs(regList) do idx[t] = i end

    -- 2. expressions: a registry table is T[i]; any other table is an inline constructor
    local consts = 0
    local function keystr(k)
        if type(k) == 'string' and k:match('^[%a_][%w_]*$') and not KEYWORDS[k] then return k, false end
        consts = consts + 1
        return '[' .. scalar(k) .. ']', true
    end
    local expr
    expr = function(v)
        if type(v) ~= 'table' then consts = consts + 1; return scalar(v) end
        if idx[v] then consts = consts + 1; return 'T[' .. idx[v] .. ']' end
        local parts, n = {}, #v
        -- an array with a hole: # can land past it, and a positional nil would shift every later value - all keyed then
        for i = 1, n do if v[i] == nil then n = 0; break end end
        for i = 1, n do parts[#parts + 1] = expr(v[i]) end
        for k, x in pairs(v) do
            local arrayPart = type(k) == 'number' and k >= 1 and k <= n and k == math.floor(k)
            if not arrayPart then
                local ks, bracket = keystr(k)
                if not bracket then consts = consts + 1 end
                parts[#parts + 1] = ks .. '=' .. expr(x)
            end
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end

    -- 3. statements, cut into functions of about BATCH_CONSTS constants
    local out = {
        '-- LazCraft data cache (core/datacache). Made from data/ - safe to delete; the next start makes it again.',
        'local T = {}',
        'local F = {}',
    }
    local body, cur = {}, nil
    local function flush()
        if #body == 0 then return end
        out[#out + 1] = 'F[#F + 1] = function()\nlocal t\n' .. table.concat(body, '\n') .. '\nend'
        body, cur, consts = {}, nil, 0
    end
    local function stmt(s)
        body[#body + 1] = s
        if consts >= DataCache.BATCH_CONSTS then flush() end
    end
    -- every registry table exists before anything refers to it (each index is a constant too)
    for i = 1, #regList do consts = consts + 1; stmt(string.format('T[%d] = {}', i)) end
    flush()
    for i, t in ipairs(regList) do
        for k, v in pairs(t) do
            if cur ~= i then body[#body + 1] = string.format('t = T[%d]', i); cur = i; consts = consts + 1 end
            local ks
            if type(k) == 'string' and k:match('^[%a_][%w_]*$') and not KEYWORDS[k] then ks = '.' .. k; consts = consts + 1
            else ks = '[' .. scalar(k) .. ']'; consts = consts + 1 end
            stmt('t' .. ks .. ' = ' .. expr(v))
            if consts == 0 then cur = nil end   -- a flush started a new function: t must be set again there
        end
    end
    flush()
    local fileList = {}
    for _, f in ipairs(files) do fileList[#fileList + 1] = string.format('%q', f) end
    out[#out + 1] = string.format('return { format = %d, key = %s, files = { %s },\n    build = function() for i = 1, #F do F[i]() end return T[%d] end }',
        DataCache.FORMAT, string.format('%q', key), table.concat(fileList, ', '), idx[root])
    return table.concat(out, '\n') .. '\n'
end

local function write(path, text, who)
    -- one temp file per character: two starting at once never write into the same one
    local tmp = string.format('%s.%s.tmp', path, (tostring(who or 'x'):gsub('[^%w]', '')))
    local fh, err = io.open(tmp, 'wb')
    if not fh then return false, err end
    fh:write(text)
    fh:close()
    os.remove(path)
    local ok, rerr = os.rename(tmp, path)
    if not ok then os.remove(tmp); return false, rerr end
    return true
end

-- ---------------------------------------------------------------- loading
local function try_cache(o)
    local chunk = loadfile(o.path)
    if not chunk then return nil, 'none' end
    local ok, head = pcall(chunk)
    if not ok or type(head) ~= 'table' or head.format ~= DataCache.FORMAT or type(head.files) ~= 'table' then
        return nil, 'unreadable'
    end
    local files = {}
    for _, f in ipairs(head.files) do files[f] = true end
    local key = key_for(o.dataDir, files, o.code)
    if key ~= head.key then return nil, 'data or the parse code changed' end
    local ok2, data = pcall(head.build)
    if not ok2 or type(data) ~= 'table' or type(data.cfg) ~= 'table' then return nil, 'unreadable' end
    return data
end

function DataCache.load(o)
    local log = o.log or NOLOG
    local clock = o.clock or os.clock
    local t0 = clock()
    local data, why = try_cache(o)
    if data then
        log.info('Data: loaded from the cache in %.1fs', (clock() - t0) / (o.clock and 1000 or 1))
        return data.cfg, data.problems or {}, 'cache'
    end
    -- parse as always, watching which files it reads
    local files = {}
    local cfg, problems = o.parse(function(file) files[file] = true end)
    local t1 = clock()
    log.info('Data: read data/ in %.1fs (cache: %s) - saving it for the next start', (t1 - t0) / (o.clock and 1000 or 1), why)
    local key, list = key_for(o.dataDir, files, o.code)
    local text, err = DataCache.serialize({ cfg = cfg, problems = problems }, key, list)
    if text then
        local ok, werr = write(o.path, text, o.who)
        if ok then
            log.debug('Data: cache saved to %s (%d KB, %.1fs)', o.path, math.floor(#text / 1024), (clock() - t1) / (o.clock and 1000 or 1))
        else
            log.warn('Data: could not save the cache to %s (%s) - every start reads data/', o.path, tostring(werr))
        end
    else
        log.warn('Data: not cached (%s) - every start reads data/', tostring(err))
    end
    return cfg, problems, 'parsed'
end

return DataCache
