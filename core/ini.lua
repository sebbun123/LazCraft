-- INI reading and writing.
-- Files are read in ONE read and split in memory: per-line reads crawl in game on Windows.
-- Opening retries briefly because antivirus or OneDrive can lock a file that was just written.
local Ini = {}

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end
Ini.trim = trim

-- Read a whole file. `sleep(ms)` is used between retries (pass mq.delay in game).
-- Returns the text, or nil and a reason.
function Ini.read_file(path, sleep, tries)
    tries = tries or 4
    local lastErr
    for attempt = 1, tries do
        local fh, err = io.open(path, 'r')
        if fh then
            local text = fh:read('*a') or ''
            fh:close()
            return text
        end
        lastErr = err
        -- A missing file is final; only a file that exists but is locked is worth waiting for.
        if tostring(err):find('No such file', 1, true) then break end
        if attempt < tries and sleep then sleep(250) end
    end
    return nil, lastErr
end

-- Parse INI text into ordered sections.
-- Returns { order = { 'Forge', ... }, sections = { Forge = { name =, keys = { {k, v}, ... }, map = { k = v } } } }
-- Lines starting with ';' or '#' are comments. Keys keep their case; a repeated key keeps every
-- occurrence in `keys` and the last one in `map`.
function Ini.parse(text)
    local doc = { order = {}, sections = {} }
    local cur
    for line in (text or ''):gmatch('[^\r\n]+') do
        local s = trim(line)
        local c = s:sub(1, 1)
        if s ~= '' and c ~= ';' and c ~= '#' then
            local name = s:match('^%[(.+)%]$')
            if name then
                name = trim(name)
                cur = doc.sections[name]
                if not cur then
                    cur = { name = name, keys = {}, map = {} }
                    doc.sections[name] = cur
                    doc.order[#doc.order + 1] = name
                end
            elseif cur then
                local eq = s:find('=', 1, true)
                if eq then
                    local k, v = trim(s:sub(1, eq - 1)), trim(s:sub(eq + 1))
                    if k ~= '' then
                        cur.keys[#cur.keys + 1] = { k, v }
                        cur.map[k] = v
                    end
                end
            end
        end
    end
    return doc
end

function Ini.load(path, sleep)
    local text, err = Ini.read_file(path, sleep)
    if not text then return nil, err end
    return Ini.parse(text)
end

-- Write sections back out: list of { name =, keys = { {k, v}, ... } }. Windows line endings.
function Ini.write(path, sections, header)
    local out = {}
    if header then out[#out + 1] = header end
    for _, sec in ipairs(sections) do
        out[#out + 1] = '[' .. sec.name .. ']'
        for _, kv in ipairs(sec.keys) do out[#out + 1] = kv[1] .. '=' .. tostring(kv[2]) end
        out[#out + 1] = ''
    end
    local fh, err = io.open(path, 'wb')
    if not fh then return false, err end
    fh:write(table.concat(out, '\r\n'))
    fh:close()
    return true
end

-- Comma-separated list value -> array of trimmed, non-empty strings.
function Ini.list(v)
    local out = {}
    for part in (v or ''):gmatch('[^,]+') do
        local t = trim(part)
        if t ~= '' then out[#out + 1] = t end
    end
    return out
end

return Ini
