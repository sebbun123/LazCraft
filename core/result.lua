-- Every block and job step returns one of these instead of throwing or returning bare booleans,
-- so a caller always knows WHY something did not happen.
--   R.ok(value)            success, with an optional value
--   R.fail(why, detail)    failure: `why` is a short fixed reason ('stopped', 'timeout', 'vendor refused'),
--                          `detail` is free text for the log
local R = {}

function R.ok(value)
    return { ok = true, value = value }
end

function R.fail(why, detail)
    return { ok = false, why = why or 'failed', detail = detail }
end

-- One line for the log: "ok" or "failed: timeout (bank window never opened)".
function R.describe(r)
    if not r then return 'no result' end
    if r.ok then return 'ok' end
    if r.detail and r.detail ~= '' then
        return string.format('failed: %s (%s)', tostring(r.why), tostring(r.detail))
    end
    return 'failed: ' .. tostring(r.why)
end

return R
