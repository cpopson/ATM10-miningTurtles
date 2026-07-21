-- test_store.lua — suite for the store contract, driven against mockstore.lua.
-- Runs under plain `lua`.
--
-- Run:  lua test_store.lua

local MockStore = require("mockstore")

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

local function deepEq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

--------------------------------------------------------------------------------
-- 1. save then load round-trips a nested table
--------------------------------------------------------------------------------
local function s01_save_load_roundtrip()
  local s = MockStore.new()
  local orig = {
    phase = "running",
    jobs = { ["q-s1"] = { status = "mining", attempts = 0, assignedTo = 5 } },
    queue = { "q-s2", "q-s3" },
    flags = { paused = false, stopped = true },
  }
  eq(s.save("coordinator", orig), true, "s01: save ok")
  local got = s.load("coordinator")
  ok(deepEq(got, orig), "s01: loaded table equals original")
end

--------------------------------------------------------------------------------
-- 2. loading an absent name returns nil
--------------------------------------------------------------------------------
local function s02_load_missing_nil()
  local s = MockStore.new()
  eq(s.load("nope"), nil, "s02: missing -> nil")
end

--------------------------------------------------------------------------------
-- 3. save overwrites
--------------------------------------------------------------------------------
local function s03_overwrite()
  local s = MockStore.new()
  s.save("k", { v = 1 })
  s.save("k", { v = 2 })
  eq(s.load("k").v, 2, "s03: second save wins")
end

--------------------------------------------------------------------------------
-- 4. delete removes it
--------------------------------------------------------------------------------
local function s04_delete()
  local s = MockStore.new()
  s.save("k", { v = 1 })
  eq(s.delete("k"), true, "s04: delete ok")
  eq(s.load("k"), nil, "s04: gone after delete")
end

--------------------------------------------------------------------------------
-- 5. serialize boundary: mutations don't leak in or out
--------------------------------------------------------------------------------
local function s05_isolation()
  local s = MockStore.new()
  local orig = { list = { 1, 2, 3 } }
  s.save("k", orig)
  orig.list[4] = 99          -- mutate AFTER save
  orig.added = "later"
  local got = s.load("k")
  eq(got.list[4], nil, "s05: post-save mutation didn't leak in")
  eq(got.added, nil, "s05: post-save key didn't leak in")
  got.list[1] = 999          -- mutate the loaded copy
  local got2 = s.load("k")
  eq(got2.list[1], 1, "s05: mutating a loaded copy didn't corrupt storage")
end

--------------------------------------------------------------------------------
-- 6. a corrupt file loads as nil,"corrupt"
--------------------------------------------------------------------------------
local function s06_corrupt_load()
  local s = MockStore.new()
  s.save("k", { v = 1 })
  s:_corrupt("k")
  local t, err = s.load("k")
  eq(t, nil, "s06: corrupt -> nil")
  eq(err, "corrupt", "s06: corrupt -> reason")
end

--------------------------------------------------------------------------------

local scenarios = {
  s01_save_load_roundtrip,
  s02_load_missing_nil,
  s03_overwrite,
  s04_delete,
  s05_isolation,
  s06_corrupt_load,
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
