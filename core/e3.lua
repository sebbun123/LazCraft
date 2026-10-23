-- E3 pause, owned by the job runner. E3 drives the character (targets, moves, grabs the cursor), so it
-- is paused while a job that touches the toon runs and resumed afterwards. Counted, so nested holders
-- cannot hand the toon back early; release() always lets go, for script exit.
local E3 = {}
E3.__index = E3

function E3.new(cmd, log)
    return setmetatable({ cmd = cmd, log = log, depth = 0 }, E3)
end

function E3:pause()
    self.depth = self.depth + 1
    if self.depth == 1 then
        self.cmd('/e3p on')
        if self.log then self.log.debug('E3 paused') end
    end
end

function E3:resume()
    if self.depth == 0 then return end
    self.depth = self.depth - 1
    if self.depth == 0 then
        self.cmd('/e3p off')
        if self.log then self.log.debug('E3 resumed') end
    end
end

function E3:release()
    if self.depth > 0 then
        self.depth = 0
        self.cmd('/e3p off')
        if self.log then self.log.debug('E3 released') end
    end
end

function E3:held() return self.depth > 0 end

return E3
