-- nav.lua — position/heading tracking + world-collision-safe movement.
--
-- The ONLY module allowed to touch a turtle backend. All movement, digging,
-- inspection, fuel, and inventory go through the injected `backend` so the
-- same code runs against a real CC:Tweaked turtle or the `mockturtle` sim.
--
-- Heading convention (fixed project-wide):
--   0 = N (-Z), 1 = E (+X), 2 = S (+Z), 3 = W (-X)
-- Coordinates match Minecraft/GPS axes.
--
-- Targets the Lua 5.1/5.2 common subset (CC:Tweaked is Cobalt ~5.1); also runs
-- under desktop Lua 5.4 for tests.

-- Shared geometry. mockturtle.lua MUST define these identically — any drift
-- here is exactly the bug probe.lua exists to catch.
local DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 } -- +X on East
local DZ = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 } -- -Z on North

local Nav = {}
Nav.__index = Nav

-- Nav.new(backend, startPose, opts) -> nav
--   backend   : injected turtle API subset (real `turtle` global or a mock). Required.
--   startPose : optional {x,y,z,h}; defaults to origin facing north. Copied, not aliased.
--   opts      : optional { maxDigRetries = 16 }
-- Does not touch the backend at construction (so tests can assert a clean start).
function Nav.new(backend, startPose, opts)
  assert(backend, "nav: backend is required")
  startPose = startPose or {}
  opts = opts or {}
  local self = setmetatable({}, Nav)
  self.b = backend
  self.pose = {
    x = startPose.x or 0,
    y = startPose.y or 0,
    z = startPose.z or 0,
    h = startPose.h or 0,
  }
  self.opts = { maxDigRetries = opts.maxDigRetries or 16 }
  self.digCount = 0
  self.dug = {} -- log of {x,y,z,h,face} for each successful dig
  return self
end

--------------------------------------------------------------------------------
-- State queries (pure reads of tracked state — never call the backend)
--------------------------------------------------------------------------------

function Nav:getPos()
  return self.pose.x, self.pose.y, self.pose.z
end

function Nav:getPosT()
  return { x = self.pose.x, y = self.pose.y, z = self.pose.z }
end

function Nav:getHeading()
  return self.pose.h
end

function Nav:getPose()
  return { x = self.pose.x, y = self.pose.y, z = self.pose.z, h = self.pose.h }
end

--------------------------------------------------------------------------------
-- Turning (update tracked heading after the backend call returns)
--------------------------------------------------------------------------------

function Nav:turnRight()
  self.b.turnRight()
  self.pose.h = (self.pose.h + 1) % 4
  return true
end

function Nav:turnLeft()
  self.b.turnLeft()
  self.pose.h = (self.pose.h + 3) % 4 -- +3, never -1, so it stays non-negative
  return true
end

-- turnTo(target) — minimal rotation to face `target` (0..3).
function Nav:turnTo(target)
  local diff = (target - self.pose.h) % 4
  if diff == 1 then
    self:turnRight()
  elseif diff == 2 then
    self:turnRight()
    self:turnRight()
  elseif diff == 3 then
    self:turnLeft()
  end
  return true
end

--------------------------------------------------------------------------------
-- Inspection / detection (pass-through, no state change)
--------------------------------------------------------------------------------
-- inspect returns (present, data|nil). Real CC returns a string as the 2nd
-- value on failure ("No block to inspect"), so we only surface `data` when
-- present is truthy — callers never index a string.

function Nav:inspect()
  local present, data = self.b.inspect()
  if present then return true, data end
  return false, nil
end

function Nav:inspectUp()
  local present, data = self.b.inspectUp()
  if present then return true, data end
  return false, nil
end

function Nav:inspectDown()
  local present, data = self.b.inspectDown()
  if present then return true, data end
  return false, nil
end

function Nav:detect()
  return self.b.detect()
end

function Nav:detectUp()
  return self.b.detectUp()
end

function Nav:detectDown()
  return self.b.detectDown()
end

--------------------------------------------------------------------------------
-- Digging (call backend; track blocks dug; no position change)
--------------------------------------------------------------------------------

function Nav:_logDig(face)
  self.digCount = self.digCount + 1
  local dug = self:getPose()
  dug.face = face
  self.dug[#self.dug + 1] = dug
end

function Nav:dig()
  local ok, err = self.b.dig()
  if ok then self:_logDig("front") end
  return ok, err
end

function Nav:digUp()
  local ok, err = self.b.digUp()
  if ok then self:_logDig("up") end
  return ok, err
end

function Nav:digDown()
  local ok, err = self.b.digDown()
  if ok then self:_logDig("down") end
  return ok, err
end

--------------------------------------------------------------------------------
-- Fuel
--------------------------------------------------------------------------------

function Nav:getFuelLevel()
  return self.b.getFuelLevel() -- may be the string "unlimited" — returned verbatim
end

-- hasFuel(n) — true if fuel is unlimited or numerically >= n. Guards against
-- doing arithmetic on the string "unlimited".
function Nav:hasFuel(n)
  local level = self.b.getFuelLevel()
  if level == "unlimited" then return true end
  return level >= n
end

-- refuel(count) -> ok, level. Consumes items in the currently selected slot(s)
-- via the backend, then reports the new fuel level.
function Nav:refuel(count)
  local ok, err = self.b.refuel(count)
  return ok, self.b.getFuelLevel(), err
end

--------------------------------------------------------------------------------
-- Core: world-collision-safe movement primitive
--------------------------------------------------------------------------------
-- tryMove runs the retry loop shared by all four movers. Pose updates ONLY on a
-- confirmed successful backend move — the invariant that makes round trips close.
--
--   moveFn   : backend move (forward/back/up/down)
--   digFn    : backend dig for that direction, or nil (back can't dig)
--   detectFn : backend detect for that direction, or nil
--   dx,dy,dz : tracked-pose delta applied on success
local function tryMove(self, moveFn, digFn, detectFn, dx, dy, dz)
  if not self:hasFuel(1) then
    return false, "no_fuel"
  end

  local attempts = self.opts.maxDigRetries + 1
  for _ = 1, attempts do
    local ok = moveFn()
    if ok then
      self.pose.x = self.pose.x + dx
      self.pose.y = self.pose.y + dy
      self.pose.z = self.pose.z + dz
      return true
    end

    -- Move failed. Figure out why and try to clear the way.
    if digFn == nil then
      -- back(): no dig available. Caller should turn-and-forward instead.
      return false, "blocked_back"
    end

    if detectFn and detectFn() then
      -- A block is in the way.
      local dok = digFn()
      if not dok then
        -- Unbreakable (bedrock) or nothing there to dig — give up now rather
        -- than burn every retry on something we can't clear.
        return false, "blocked_unbreakable"
      end
      -- Dug it; loop and retry. A falling gravel/sand column refills the cell,
      -- so we may dig several times before the move succeeds.
    else
      -- Move failed but nothing detected: likely a mob/entity. CC dig also
      -- attacks, so try that, then retry.
      digFn()
    end
  end

  return false, "blocked_retry_exceeded"
end

-- Heading is read fresh each call so a turn between moves is respected.
function Nav:forward()
  local h = self.pose.h
  return tryMove(self, self.b.forward, self.b.dig, self.b.detect, DX[h], 0, DZ[h])
end

function Nav:back()
  local h = self.pose.h
  return tryMove(self, self.b.back, nil, nil, -DX[h], 0, -DZ[h])
end

function Nav:up()
  return tryMove(self, self.b.up, self.b.digUp, self.b.detectUp, 0, 1, 0)
end

function Nav:down()
  return tryMove(self, self.b.down, self.b.digDown, self.b.detectDown, 0, -1, 0)
end

--------------------------------------------------------------------------------
-- High-level helpers
--------------------------------------------------------------------------------

-- goTo(x,y,z, order) — travel to a target by digging straight lines.
--   order : permutation of "xyz" giving axis travel order (default "yxz":
--           vertical first to avoid dropping into gravel, then X, then Z).
-- Returns true on success, or false,err,pose at the point it stalled. Does not
-- restore heading.
function Nav:goTo(x, y, z, order)
  order = order or "yxz"

  local function stepX()
    local d = x - self.pose.x
    if d == 0 then return true end
    self:turnTo(d > 0 and 1 or 3)
    for _ = 1, math.abs(d) do
      local ok, err = self:forward()
      if not ok then return false, err end
    end
    return true
  end

  local function stepZ()
    local d = z - self.pose.z
    if d == 0 then return true end
    self:turnTo(d > 0 and 2 or 0)
    for _ = 1, math.abs(d) do
      local ok, err = self:forward()
      if not ok then return false, err end
    end
    return true
  end

  local function stepY()
    local d = y - self.pose.y
    local move = d > 0 and self.up or self.down
    for _ = 1, math.abs(d) do
      local ok, err = move(self)
      if not ok then return false, err end
    end
    return true
  end

  local steps = { x = stepX, y = stepY, z = stepZ }
  for i = 1, #order do
    local axis = order:sub(i, i)
    local step = steps[axis]
    if step then
      local ok, err = step()
      if not ok then return false, err, self:getPose() end
    end
  end
  return true
end

-- returnTo(pose) — go to pose.x/y/z then face pose.h. Used by probe.
function Nav:returnTo(pose)
  local ok, err = self:goTo(pose.x, pose.y, pose.z)
  if not ok then return false, err, self:getPose() end
  self:turnTo(pose.h)
  return true
end

return Nav
