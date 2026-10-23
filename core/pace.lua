-- Pace: burst, then listen (2.46.7). Items go in fast, a frame apart at least; before the /combine the game gets a
-- quiet window to say it is out of step, and that window is learned per character.
--   new({ get, set, log })   get(key) / set(key, value) read and write the character's settings
--   floor_ms()               ClickFloorMs: the least time between two inventory clicks (fixed; default a frame)
--   quiet_ms()               QuietMs: how long to listen for desync lines before a /combine
--   auto()                   ClickPace is 'auto' (QuietMs is learned) rather than 'fixed'
--   hit(why)                 the game complained (desync, refusal, a stray on the cursor): widen the window
--   clean()                  a combine went through with nothing wrong: count it; enough in a row narrow the window
--
-- Why (2.46.5 Vadar log): every desync line names slot 33 - the cursor - so they come from pickups and drops, never
-- from the /combine; each showed ~200ms after the move that caused it (combine 3: the drop at 14.669, the lines at
-- ~14.88). The client shows every move done at once, so reading the bags proves nothing (combine 3's "the kit holds
-- what was placed" passed and the server refused it); the game's desync line is the only signal. A gap on every click
-- (2.46.6) paid ~0.9s a combine for it; one window before the /combine pays it once. A pickup and its drop in one
-- frame (combine 3) are never allowed: the floor.
-- The window widens fast on trouble (x BACKOFF, up to MAX_MS) and narrows slowly (STEP_MS after EASE_AFTER clean
-- combines in a row, down to MIN_MS) - TCP's congestion window. Saved in the character's settings: the next run
-- starts where this one ended.
local Pace = {}
Pace.__index = Pace

Pace.FLOOR_MS = 34      -- about a frame at 30fps: never two clicks in one frame
Pace.START_MS = 300     -- the quiet window to begin with: past the ~200ms the desync lines took in the 2.46.5 log
Pace.MIN_MS = 150
Pace.MAX_MS = 1500
Pace.BACKOFF = 1.5
Pace.STEP_MS = 25
Pace.EASE_AFTER = 25    -- clean combines in a row before the window comes down a step

local NOLOG = { info = function() end, debug = function() end }

function Pace.new(deps)
    return setmetatable({ get = deps.get, set = deps.set, log = deps.log or NOLOG, streak = 0 }, Pace)
end

local function clamp(v) return math.max(Pace.MIN_MS, math.min(Pace.MAX_MS, math.floor(v + 0.5))) end

function Pace:auto() return (self.get('ClickPace') or 'auto'):lower() ~= 'fixed' end

function Pace:floor_ms()
    local v = tonumber(self.get('ClickFloorMs'))
    return v and math.max(0, math.floor(v)) or Pace.FLOOR_MS
end

function Pace:quiet_ms()
    local v = tonumber(self.get('QuietMs'))
    if not v then return Pace.START_MS end
    if self:auto() then return clamp(v) end
    return math.max(0, math.floor(v))   -- fixed: exactly what was set, 0 included
end

function Pace:change(to, why)
    local from = self:quiet_ms()
    if to == from then return end
    self.set('QuietMs', tostring(to))
    self.log.info('Pace: quiet window %d -> %dms before each combine (%s)', from, to, why)
end

function Pace:hit(why)
    self.streak = 0
    if not self:auto() then return end
    self:change(clamp(math.max(self:quiet_ms(), Pace.MIN_MS) * Pace.BACKOFF), why)
end

function Pace:clean()
    if not self:auto() then return end
    self.streak = self.streak + 1
    if self.streak < Pace.EASE_AFTER then return end
    self.streak = 0
    if self:quiet_ms() > Pace.MIN_MS then
        self:change(clamp(self:quiet_ms() - Pace.STEP_MS), string.format('%d clean combines in a row', Pace.EASE_AFTER))
    end
end

return Pace
