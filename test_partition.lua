-- test_partition.lua — suite for partition.lua. Runs under plain `lua`.
-- Run:  lua test_partition.lua

local Partition = require("partition")

local passed, failed = 0, 0

local function ok(cond, msg)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("  FAIL: " .. msg)
  end
end

local function eq(actual, expected, msg)
  if actual == expected then
    ok(true, msg)
  else
    ok(false, msg .. " (got " .. tostring(actual) .. " want " .. tostring(expected) .. ")")
  end
end

local function widthsEq(ws, expected, msg)
  if #ws ~= #expected then
    ok(false, msg .. " (len " .. #ws .. " want " .. #expected .. ")")
    return
  end
  for i = 1, #expected do
    if ws[i] ~= expected[i] then
      ok(false, msg .. " (index " .. i .. " got " .. tostring(ws[i]) .. " want " .. expected[i] .. ")")
      return
    end
  end
  ok(true, msg)
end

local function sum(t)
  local s = 0
  for _, v in ipairs(t) do s = s + v end
  return s
end

-- A standard box helper.
local function box(W, L, D, id)
  return { id = id, origin = { x = 0, y = 0, z = 0 }, width = W, length = L, depth = D }
end

--------------------------------------------------------------------------------
-- 1. widths math (frozen examples)
--------------------------------------------------------------------------------
local function s01_widths_examples()
  widthsEq(Partition.widths(7, 3), { 3, 2, 2 }, "s01: W=7,n=3")
  widthsEq(Partition.widths(5, 2), { 3, 2 }, "s01: W=5,n=2")
  widthsEq(Partition.widths(6, 3), { 2, 2, 2 }, "s01: W=6,n=3")
  widthsEq(Partition.widths(2, 5), { 1, 1 }, "s01: W=2,n=5 (capped at W)")
  widthsEq(Partition.widths(1, 3), { 1 }, "s01: W=1,n=3")
end

--------------------------------------------------------------------------------
-- 2. coverage tiles the box exactly (no gap, no overlap)
--------------------------------------------------------------------------------
local function s02_coverage_and_nonoverlap()
  local jobs = Partition.split(box(7, 4, 3), 3)
  eq(#jobs, 3, "s02: 3 strips")
  -- widths sum to W
  local total = 0
  for _, j in ipairs(jobs) do total = total + j.width end
  eq(total, 7, "s02: widths sum to W")
  -- strips are contiguous and non-overlapping in X
  for i = 1, #jobs - 1 do
    eq(jobs[i].region.x1 + 1, jobs[i + 1].region.x0, "s02: strip " .. i .. " abuts next")
  end
  -- first strip starts at origin.x, last ends at origin.x + W - 1
  eq(jobs[1].region.x0, 0, "s02: first strip at origin.x")
  eq(jobs[#jobs].region.x1, 6, "s02: last strip ends at W-1")
  -- z and y ranges cover the full box on every strip
  for _, j in ipairs(jobs) do
    eq(j.region.z0, 0, "s02: z0")
    eq(j.region.z1, 3, "s02: z1 = L-1")
    eq(j.region.y0, -3, "s02: y0 = -D")
    eq(j.region.y1, -1, "s02: y1 = -1")
  end
end

--------------------------------------------------------------------------------
-- 3. balance: widths differ by at most 1
--------------------------------------------------------------------------------
local function s03_balance()
  local cases = { { 7, 3 }, { 10, 4 }, { 13, 5 }, { 8, 3 } }
  for _, c in ipairs(cases) do
    local ws = Partition.widths(c[1], c[2])
    local lo, hi = ws[1], ws[1]
    for _, w in ipairs(ws) do
      if w < lo then lo = w end
      if w > hi then hi = w end
    end
    ok(hi - lo <= 1, "s03: W=" .. c[1] .. ",n=" .. c[2] .. " balanced (" .. lo .. ".." .. hi .. ")")
    eq(sum(ws), c[1], "s03: W=" .. c[1] .. ",n=" .. c[2] .. " sum")
  end
end

--------------------------------------------------------------------------------
-- 4. W < N -> W jobs of width 1
--------------------------------------------------------------------------------
local function s04_W_less_than_N()
  local jobs, count = Partition.split(box(2, 5, 2), 5)
  eq(count, 2, "s04: only 2 jobs when W < N")
  eq(jobs[1].width, 1, "s04: strip 1 width 1")
  eq(jobs[2].width, 1, "s04: strip 2 width 1")
end

--------------------------------------------------------------------------------
-- 5. single turtle -> one full-width job
--------------------------------------------------------------------------------
local function s05_single_turtle()
  local jobs = Partition.split(box(5, 3, 2), 1)
  eq(#jobs, 1, "s05: one job")
  eq(jobs[1].width, 5, "s05: full width")
  eq(jobs[1].length, 3, "s05: length")
  eq(jobs[1].depth, 2, "s05: depth")
end

--------------------------------------------------------------------------------
-- 6. edge cases
--------------------------------------------------------------------------------
local function s06_edges()
  eq(#Partition.widths(0, 3), 0, "s06: W=0 -> no widths")
  eq(#Partition.widths(5, 0), 0, "s06: n=0 -> no widths")
  eq(#Partition.widths(5, -1), 0, "s06: n<0 -> no widths")
  local jobs, count = Partition.split(box(0, 3, 2), 3)
  eq(count, 0, "s06: W=0 -> no jobs")
  eq(#jobs, 0, "s06: empty jobs")
end

--------------------------------------------------------------------------------
-- 7. origin prefix-sum math (with a non-zero box origin)
--------------------------------------------------------------------------------
local function s07_origin_math()
  local b = { id = "q", origin = { x = 10, y = 64, z = -5 }, width = 7, length = 4, depth = 3 }
  local jobs = Partition.split(b, 3) -- widths {3,2,2}
  eq(jobs[1].origin.x, 10, "s07: strip 1 x = origin.x")
  eq(jobs[2].origin.x, 13, "s07: strip 2 x = origin.x + 3")
  eq(jobs[3].origin.x, 15, "s07: strip 3 x = origin.x + 5")
  eq(jobs[1].origin.y, 64, "s07: y unchanged")
  eq(jobs[1].origin.z, -5, "s07: z unchanged")
  eq(jobs[3].region.x1, 16, "s07: last strip ends at origin.x + W - 1")
end

--------------------------------------------------------------------------------
-- 8. deterministic ids (idempotency prerequisite)
--------------------------------------------------------------------------------
local function s08_deterministic_ids()
  local a = Partition.split(box(7, 4, 3, "job42"), 3)
  local b = Partition.split(box(7, 4, 3, "job42"), 3)
  for i = 1, #a do
    eq(a[i].id, b[i].id, "s08: id stable at strip " .. i)
  end
  eq(a[1].id, "job42-s1", "s08: id format")
  eq(a[3].id, "job42-s3", "s08: id format last")
  -- default prefix when box has no id
  local c = Partition.split(box(3, 2, 1), 2)
  eq(c[1].id, "quarry-s1", "s08: default prefix")
end

--------------------------------------------------------------------------------

local scenarios = {
  s01_widths_examples,
  s02_coverage_and_nonoverlap,
  s03_balance,
  s04_W_less_than_N,
  s05_single_turtle,
  s06_edges,
  s07_origin_math,
  s08_deterministic_ids,
}

local scPassed, scFailed = 0, 0
for i, scenario in ipairs(scenarios) do
  local before = failed
  local runOk, err = pcall(scenario)
  if runOk and failed == before then
    scPassed = scPassed + 1
  else
    scFailed = scFailed + 1
    if not runOk then
      print("  ERROR in scenario " .. i .. ": " .. tostring(err))
    end
  end
end

print(scPassed .. " passed, " .. scFailed .. " failed")
if os.exit then os.exit(scFailed == 0 and 0 or 1) end
