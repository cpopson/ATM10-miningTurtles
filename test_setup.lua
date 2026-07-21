-- test_setup.lua — suite for jobspec.lua (job-setup validation). Plain `lua`.
--
-- Run:  lua test_setup.lua

local JobSpec = require("jobspec")

local passed, failed = 0, 0

local function ok(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("  FAIL: " .. msg) end
end

local function eq(actual, expected, msg)
  if actual == expected then
    ok(true, msg)
  else
    ok(false, msg .. " (got " .. tostring(actual) .. " want " .. tostring(expected) .. ")")
  end
end

-- parse + validate in one go.
local function build(fields)
  return JobSpec.validate(JobSpec.parse(fields))
end

--------------------------------------------------------------------------------
-- 1. a valid string form normalizes to a typed box + expect
--------------------------------------------------------------------------------
local function s01_valid_normalizes()
  local spec, err = build({ pattern = "quarry", width = "6", length = "4", depth = "5", turtles = "3" })
  eq(err, nil, "s01: no error")
  ok(spec ~= nil, "s01: spec returned")
  eq(spec.box.width, 6, "s01: width coerced to int")
  eq(spec.box.length, 4, "s01: length")
  eq(spec.box.depth, 5, "s01: depth")
  eq(spec.expect, 3, "s01: turtle count")
end

--------------------------------------------------------------------------------
-- 2. defaults: pattern quarry, origin (0,1,0)
--------------------------------------------------------------------------------
local function s02_defaults()
  local spec = build({ width = 3, length = 3, depth = 2, turtles = 1 })
  eq(spec.box.pattern, "quarry", "s02: default pattern")
  eq(spec.box.origin.x, 0, "s02: default origin x")
  eq(spec.box.origin.y, 1, "s02: default origin y")
  eq(spec.box.origin.z, 0, "s02: default origin z")
  eq(spec.box.strips, nil, "s02: strips optional -> nil")
end

--------------------------------------------------------------------------------
-- 3. non-positive / non-integer dimensions are rejected
--------------------------------------------------------------------------------
local function s03_reject_bad_dims()
  local function badWidth(w)
    local spec, err = build({ width = w, length = 3, depth = 2, turtles = 1 })
    ok(spec == nil and err == "bad_width", "s03: width " .. tostring(w) .. " rejected")
  end
  badWidth(0); badWidth(-1); badWidth(1.5)
  local s2, e2 = build({ width = 3, length = 0, depth = 2, turtles = 1 })
  ok(s2 == nil and e2 == "bad_length", "s03: length 0 rejected")
  local s3, e3 = build({ width = 3, length = 3, depth = 0, turtles = 1 })
  ok(s3 == nil and e3 == "bad_depth", "s03: depth 0 rejected")
end

--------------------------------------------------------------------------------
-- 4. an unsupported pattern is rejected
--------------------------------------------------------------------------------
local function s04_unsupported_pattern()
  local spec, err = build({ pattern = "branch", width = 3, length = 3, depth = 2, turtles = 1 })
  ok(spec == nil and err == "unsupported_pattern", "s04: branch rejected (not built yet)")
end

--------------------------------------------------------------------------------
-- 5. a bad turtle count is rejected
--------------------------------------------------------------------------------
local function s05_bad_count()
  local s1, e1 = build({ width = 3, length = 3, depth = 2, turtles = 0 })
  ok(s1 == nil and e1 == "bad_count", "s05: 0 turtles rejected")
  local s2, e2 = build({ width = 3, length = 3, depth = 2, turtles = "x" })
  ok(s2 == nil and e2 == "bad_count", "s05: non-numeric turtles rejected")
end

--------------------------------------------------------------------------------
-- 6. strips must be within 1..width
--------------------------------------------------------------------------------
local function s06_bad_strips()
  local s1, e1 = build({ width = 4, length = 3, depth = 2, strips = "7", turtles = 2 })
  ok(s1 == nil and e1 == "bad_strips", "s06: strips > width rejected")
  local s2 = build({ width = 4, length = 3, depth = 2, strips = "2", turtles = 2 })
  eq(s2 and s2.box.strips, 2, "s06: strips within range accepted")
end

--------------------------------------------------------------------------------
-- 7. a bad origin coordinate is rejected
--------------------------------------------------------------------------------
local function s07_bad_origin()
  local spec, err = build({ width = 3, length = 3, depth = 2, turtles = 1, origin = { x = "a", y = 1, z = 0 } })
  ok(spec == nil and err == "bad_origin", "s07: non-numeric origin rejected")
end

--------------------------------------------------------------------------------

local scenarios = {
  s01_valid_normalizes,
  s02_defaults,
  s03_reject_bad_dims,
  s04_unsupported_pattern,
  s05_bad_count,
  s06_bad_strips,
  s07_bad_origin,
}

local scPassed, scFailed = 0, 0
for i, scenario in ipairs(scenarios) do
  local before = failed
  local runOk, err = pcall(scenario)
  if runOk and failed == before then
    scPassed = scPassed + 1
  else
    scFailed = scFailed + 1
    if not runOk then print("  ERROR in scenario " .. i .. ": " .. tostring(err)) end
  end
end

print(scPassed .. " passed, " .. scFailed .. " failed")
if os.exit then os.exit(scFailed == 0 and 0 or 1) end
