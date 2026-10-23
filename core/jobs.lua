-- The job runner: ONE queue, ONE running job.
--
-- A job is a table:
--   name       shown in the window and the log
--   plan       function(ctx) -> R            optional; work out what to do (no game actions)
--   preflight  function(ctx, plan) -> checks optional; checks = { {level='ok'|'warn'|'block'|'done', text=...} }
--                                           ('done': nothing to do - the job ends as done, before Go)
--   execute    function(ctx, plan) -> R      required; does the work through the blocks
--   cleanup    function(ctx) -> R          optional; runs after execute however it ended (also after Stop),
--                                           to leave the toon tidy. Its waits ignore Stop and Pause but
--                                           still time out.
--   confirm    true -> wait for Go after preflight
--   usesToon   true -> E3 is paused while it executes
--
-- Inside a job, everything that waits goes through ctx:wait / ctx:pace / ctx:checkpoint. That is where
-- Stop and Pause take effect, so they always land at a safe point and never as a thrown error.
-- Commands and the window only set flags or add to the queue; the main loop calls runner:step().
local R = require('core.result')

local Jobs = {}
Jobs.__index = Jobs

local SLICE_MS = 50       -- longest single sleep, so Stop and Pause are noticed quickly
local HISTORY_KEEP = 20

local Ctx = {}
Ctx.__index = Ctx

function Ctx:status(text) self.state.status = text or '' end

function Ctx:progress(done, total)
    self.state.done, self.state.total = done or 0, total or 0
end

function Ctx:stopped() return not self.cleanup and self.runner.stopRequested end

-- Hold here while paused. Returns false if Stop was pressed, true to carry on.
-- A cleanup context never holds and never stops.
function Ctx:checkpoint()
    local r = self.runner
    if self.cleanup then return true end
    if r.paused and not r.stopRequested then
        local h = self.pauseHooks
        if h and h.onPause then pcall(h.onPause) end
        while r.paused and not r.stopRequested do
            r.doevents()
            r.delay(SLICE_MS)
        end
        if h and h.onResume and not r.stopRequested then pcall(h.onResume) end
    end
    return not r.stopRequested
end

-- A block doing something the game keeps doing on its own (like travelling) says how to halt it on
-- Pause and pick it up again on Resume. Call with no arguments to clear.
function Ctx:while_paused(onPause, onResume)
    self.pauseHooks = (onPause or onResume) and { onPause = onPause, onResume = onResume } or nil
end

-- Wait up to `ms` for `cond` to return true.
--   With cond:    R.ok() as soon as it is true, R.fail('timeout') when time runs out.
--   Without cond: a pace. The game only acts once a frame, so a pace steps frame by frame and ends on
--                 the frame NEAREST its target (never more than half a frame off either way; on average
--                 exactly `ms`), rather than always on the frame after it, which ran a whole frame long.
--   Either way:   R.fail('stopped') if Stop is pressed. Time spent paused does not count.
-- The returned result carries .ms: how long the wait actually took, for the log.
function Ctx:wait(ms, cond)
    local t0 = self.runner.now()
    local res = self:wait_inner(ms, cond)
    res.ms = self.runner.now() - t0
    return res
end

function Ctx:wait_inner(ms, cond)
    local r = self.runner
    local remaining = ms or 0
    while true do
        if r.stopRequested and not self.cleanup then return R.fail('stopped') end
        if r.paused and not self.cleanup then
            if not self:checkpoint() then return R.fail('stopped') end
        end
        if cond then
            local ok, met = pcall(cond)
            if not ok then return R.fail('error', tostring(met)) end
            if met then return R.ok() end
        end
        if remaining <= 0 then
            if cond then return R.fail('timeout') end
            return R.ok()
        end
        -- A pace: if the target is nearer now than one frame from now, this frame is the nearest one.
        if not cond and r.frameMs and remaining * 2 <= r.frameMs then return R.ok() end
        local t0 = r.now()
        r.doevents()
        -- A pace steps one frame at a time (a 1ms sleep returns on the next frame, reliably; a part-frame
        -- sleep was seen in game to run into the frame after) and stops on the frame nearest its target.
        -- It measures the frame from its own first step, so it never depends on another wait having slept.
        local want = (not cond) and 1 or math.min(SLICE_MS, remaining)
        r.delay(want)
        local slept = r.now() - t0
        remaining = remaining - slept
        -- How long a frame takes right now: a 1ms sleep returns on the next frame, so what it took IS one
        -- frame. Used by the pace check above.
        if want <= 5 and slept > 0 then r.frameMs = slept end
    end
end

-- Pacing: exactly the time asked for, nothing added.
function Ctx:pace(ms) return self:wait(ms) end

Jobs.CAST_WAIT_MS = 15000   -- a cast E3 started before the pause is let finish within this
Jobs.STOPCAST_MS = 2000     -- /stopcast shows within this

function Jobs.new(deps)
    assert(deps and deps.delay and deps.now and deps.log, 'jobs: delay, now and log are required')
    return setmetatable({
        delay = deps.delay, now = deps.now, doevents = deps.doevents or function() end,
        log = deps.log, e3 = deps.e3, casting = deps.casting, stopcast = deps.stopcast,
        queue = {}, active = nil, last = nil, history = {}, nextId = 1,
        stopRequested = false, paused = false, decision = nil,
    }, Jobs)
end

function Jobs:add(job)
    assert(type(job) == 'table' and type(job.execute) == 'function', 'jobs: a job needs an execute function')
    job.name = job.name or 'Job'
    job.id = self.nextId
    self.nextId = self.nextId + 1
    self.queue[#self.queue + 1] = job
    self.log.info('Queued: %s', job.name)
    return job.id
end

function Jobs:busy() return self.active ~= nil end

-- Stop the running job at its next safe point and drop everything queued behind it.
function Jobs:stop()
    local dropped = #self.queue
    self.queue = {}
    if self.active then
        self.stopRequested = true
        self.log.warn('Stopping %s%s', self.active.job.name,
            dropped > 0 and string.format(' and clearing %d queued', dropped) or '')
    elseif dropped > 0 then
        self.log.warn('Cleared %d queued job(s)', dropped)
    end
end

-- Stop one job by its id: the running one at its next safe point (the queue behind it stays), or a queued
-- one taken out. Used when whoever asked for it calls it off.
function Jobs:drop(id)
    if self.active and self.active.job.id == id then
        self.stopRequested = true
        self.log.warn('Stopping %s (called off)', self.active.job.name)
        return true
    end
    for i, j in ipairs(self.queue) do
        if j.id == id then
            table.remove(self.queue, i)
            self.log.info('Dropped: %s (called off)', j.name)
            return true
        end
    end
    return false
end

function Jobs:pause()
    if self.active and not self.paused then
        self.paused = true
        self.log.info('Paused %s', self.active.job.name)
    end
end

function Jobs:resume()
    if self.paused then
        self.paused = false
        self.log.info('Resumed')
    end
end

function Jobs:approve()
    if self.active and self.active.phase == 'awaiting' then self.decision = 'go' end
end

function Jobs:cancel()
    if self.active and self.active.phase == 'awaiting' then self.decision = 'cancel' end
end

-- Read-only snapshot for the window.
function Jobs:view()
    local a = self.active
    return {
        active = a and {
            name = a.job.name, phase = a.phase, status = a.status, done = a.done, total = a.total,
            checks = a.checks,
        } or nil,
        queued = #self.queue, paused = self.paused, last = self.last,
    }
end

-- Run a job step function, turning any Lua error into R.fail('error') with the traceback in the log.
function Jobs:call(fn, ...)
    local ok, res = xpcall(fn, debug.traceback, ...)
    if not ok then
        self.log.error('%s', tostring(res))
        return R.fail('error', (tostring(res):match('^[^\n]*')))
    end
    if res == nil then return R.ok() end
    if res == false then return R.fail('failed') end
    if type(res) ~= 'table' or res.ok == nil then return R.ok(res) end
    return res
end

function Jobs:finish(res)
    local a = self.active
    local secs = (self.now() - a.started) / 1000
    local job = a.job
    if res.ok then
        local summary = type(res.value) == 'table' and res.value.summary or nil
        self.log.info('Done: %s%s (%.1fs)', job.name, summary and (' - ' .. tostring(summary)) or '', secs)
    elseif res.why == 'stopped' or res.why == 'cancelled' then
        self.log.warn('%s: %s', job.name, res.why)
    else
        self.log.error('%s %s', job.name, R.describe(res))
        -- what the game looked like when it failed (core/snapshot, 2.43.11)
        if self.on_fail then pcall(self.on_fail, job, res) end
    end
    self.last = { name = job.name, ok = res.ok, why = res.why, detail = res.detail, secs = secs }
    self.history[#self.history + 1] = self.last
    if #self.history > HISTORY_KEEP then table.remove(self.history, 1) end
    self.active, self.paused, self.decision = nil, false, nil
    self.stopRequested = false   -- a Stop belongs to the job it interrupted
end

function Jobs:run_execute()
    local a = self.active
    a.phase, self.decision = 'running', nil
    -- A Pause pressed before Go holds here; nothing has touched the game yet.
    if not a.ctx:checkpoint() then return self:finish(R.fail('stopped')) end
    if a.job.usesToon and self.e3 then
        self.e3:pause()
        a.holdsE3 = true
        -- A cast E3 started before the pause carries on, and while casting, bags do not open (2.12.1 in game:
        -- "pack2 did not open" right after the previous job handed E3 back). Let it land; stop it past the cap.
        if self.casting and self.casting() then
            self.log.debug('%s: waiting for a cast to finish', a.job.name)
            local w = a.ctx:wait(Jobs.CAST_WAIT_MS, function() return not self.casting() end)
            if not w.ok and w.why ~= 'timeout' then self:release_e3(); return self:finish(w) end
            if self.casting() and self.stopcast then
                self.log.info('%s: still casting after %ds - /stopcast', a.job.name, Jobs.CAST_WAIT_MS / 1000)
                self.stopcast()
                a.ctx:wait(Jobs.STOPCAST_MS, function() return not self.casting() end)
            end
            if self.casting() then
                self:release_e3()
                return self:finish(R.fail('still casting', 'a cast would not stop'))
            end
            self.log.debug('  cast over after %dms', w.ms or 0)
        end
    end
    self.log.debug('%s: executing', a.job.name)
    local res = self:call(a.job.execute, a.ctx, a.plan)
    self.log.debug('%s: execute %s', a.job.name, R.describe(res))
    if a.job.cleanup then
        self.log.debug('%s: cleanup', a.job.name)
        local cctx = setmetatable({ runner = self, state = a, log = self.log, cleanup = true }, Ctx)
        local c = self:call(a.job.cleanup, cctx, a.plan)
        if not c.ok then self.log.warn('%s cleanup %s', a.job.name, R.describe(c)) end
    end
    self:release_e3()
    if self.stopRequested and res.ok then res = R.fail('stopped') end
    self:finish(res)
end

function Jobs:release_e3()
    local a = self.active
    if a and a.holdsE3 then
        a.holdsE3 = false
        self.e3:resume()
    end
end

-- Last resort when the runner itself hit an error: hand E3 back and clear the job so the loop goes on.
function Jobs:abort(err)
    self.log.error('Job runner error: %s', tostring(err))
    if not self.active then return end
    self:release_e3()
    local ok = pcall(self.finish, self, R.fail('error', (tostring(err):match('^[^\n]*'))))
    if not ok then self.active, self.paused, self.decision, self.stopRequested = nil, false, nil, false end
end

-- Called once per main-loop pass. Starts the next job, or moves a waiting one on.
function Jobs:step()
    local a = self.active
    if a then
        if a.phase == 'awaiting' then
            if self.stopRequested or self.decision == 'cancel' then
                self:finish(R.fail(self.stopRequested and 'stopped' or 'cancelled'))
            elseif self.decision == 'go' then
                self:run_execute()
            end
        end
        return
    end

    local job = table.remove(self.queue, 1)
    if not job then return end
    self.stopRequested, self.paused, self.decision = false, false, nil
    a = { job = job, phase = 'planning', status = '', done = 0, total = 0, started = self.now() }
    a.ctx = setmetatable({ runner = self, state = a, log = self.log }, Ctx)
    self.active = a
    self.log.info('Starting: %s', job.name)

    if job.plan then
        self.log.debug('%s: planning', job.name)
        local res = self:call(job.plan, a.ctx)
        if not res.ok then return self:finish(res) end
        a.plan = res.value
    end

    if job.preflight then
        a.phase = 'preflight'
        self.log.debug('%s: preflight', job.name)
        local res = self:call(job.preflight, a.ctx, a.plan)
        if not res.ok then return self:finish(res) end
        local checks = {}
        for _, c in ipairs(type(res.value) == 'table' and res.value or {}) do
            if type(c) == 'table' then checks[#checks + 1] = { level = c.level or 'ok', text = tostring(c.text) } end
        end
        a.checks = checks
        local firstBlock, nothing
        for _, c in ipairs(checks) do
            if c.level == 'ok' then self.log.debug('Preflight: %s', c.text) end
            if c.level == 'block' then
                self.log.error('Preflight: %s', c.text)
                firstBlock = firstBlock or c.text
            elseif c.level == 'warn' then
                self.log.warn('Preflight: %s', c.text)
            elseif c.level == 'done' then
                self.log.info('Preflight: %s', c.text)
                nothing = nothing or c.text
            end
        end
        if firstBlock then return self:finish(R.fail('preflight', firstBlock)) end
        -- nothing to do is not a failure (2.46.3 logs: "Clean up ... failed: preflight (Nothing to clean up)", an
        -- ERROR and a snapshot for rows already clean): the job is done before it starts
        if nothing then return self:finish(R.ok({ summary = nothing })) end
    end

    if self.stopRequested then return self:finish(R.fail('stopped')) end
    if job.confirm then
        a.phase = 'awaiting'
        self.log.info('%s is ready - press Go (or /lc go) to start, Cancel (or /lc cancel) to drop it', job.name)
        return
    end
    self:run_execute()
end

return Jobs
