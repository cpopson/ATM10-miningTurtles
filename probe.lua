-- probe.lua — real-turtle smoke test. Drives a short out-and-back round trip
-- through nav over the REAL turtle backend and checks it lands exactly on its
-- start pose.
--
-- This is the only real-vs-sim convention oracle: the simulator is built to the
-- same heading/delta convention as nav, so it can't catch a mismatch between
-- that convention and the actual turtle. Only the real world can. A drift or
-- wrong turn here means the convention baked into nav.lua disagrees with the
-- turtle's real turnRight/forward semantics — fix it in nav before building
-- patterns on top.
--
-- Run in-game:  probe

local Nav = require("nav")

local LEGS = 3   -- blocks out (and back)
-- probe is the foundational standalone check, so it degrades gracefully if
-- config.lua hasn't been synced yet.
local okConfig, Config = pcall(require, "config")
local MIN_FUEL = (okConfig and Config.minFuel) or 8

-- Colour helpers (Advanced turtle only; plain turtles just print).
local function colour(c)
  if term and term.isColor and term.isColor() then term.setTextColor(c) end
end
local function reset()
  if term and term.isColor and term.isColor() then term.setTextColor(colors.white) end
end

-- The ONLY reference to the real `turtle` global in the whole codebase.
local nav = Nav.new(turtle, { x = 0, y = 0, z = 0, h = 0 })

-- Fuel guard.
local fuel = nav:getFuelLevel()
if fuel ~= "unlimited" and fuel < MIN_FUEL then
  nav:refuel()
  fuel = nav:getFuelLevel()
  if fuel ~= "unlimited" and fuel < MIN_FUEL then
    colour(colors and colors.red)
    print("FAIL: needs fuel (have " .. tostring(fuel) .. ", need " .. MIN_FUEL ..
      "). Put coal/charcoal in a slot and `refuel all`.")
    reset()
    return
  end
end

local origin = nav:getPose()
print(string.format("probe: origin (%d,%d,%d) h=%d", origin.x, origin.y, origin.z, origin.h))

-- Outbound: drive forward, digging anything in the way. Manual (not returnTo)
-- so we exercise the dig-and-move path on the real backend.
for i = 1, LEGS do
  local ok, err = nav:forward()
  if not ok then
    colour(colors and colors.red)
    print("FAIL: outbound leg " .. i .. "/" .. LEGS .. " blocked: " .. tostring(err))
    reset()
    return
  end
  print("  out " .. i .. "/" .. LEGS)
end

-- Return home and restore heading (exercises goTo + turnTo).
print("probe: returning...")
local rok, rerr = nav:returnTo(origin)
if not rok then
  colour(colors and colors.red)
  print("FAIL: return blocked: " .. tostring(rerr))
  reset()
  return
end

-- Verify.
local final = nav:getPose()
if final.x == origin.x and final.y == origin.y
   and final.z == origin.z and final.h == origin.h then
  colour(colors and colors.green)
  print("PASS: closed to origin (" .. final.x .. "," .. final.y .. "," ..
    final.z .. ") h=" .. final.h)
  reset()
else
  colour(colors and colors.red)
  print(string.format(
    "FAIL: drift  final (%d,%d,%d) h=%d  vs origin (%d,%d,%d) h=%d",
    final.x, final.y, final.z, final.h,
    origin.x, origin.y, origin.z, origin.h))
  print("  A wrong turn/drift is a convention mismatch to fix in nav.lua.")
  reset()
end
