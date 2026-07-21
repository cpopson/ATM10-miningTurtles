-- setup.lua — on-screen job setup for the control station. Thin terminal driver:
-- it reads keyboard input and delegates all validation to jobspec.lua (which is
-- sim-tested). Returns { boxes = {...}, expect = N } to enqueue.

local JobSpec = require("jobspec")

local Setup = {}

local function prompt(label, default)
  term.write(label)
  if default ~= nil then term.write(" [" .. tostring(default) .. "]") end
  term.write(": ")
  local s = read()
  if s == "" and default ~= nil then return tostring(default) end
  return s
end

local function askInt(label, default)
  while true do
    local v = tonumber(prompt(label, default))
    if v and v >= 1 and v == math.floor(v) then return v end
    print("  need a whole number >= 1")
  end
end

-- Ask for one box's fields, re-asking until jobspec validates it.
local function readBox(turtles)
  while true do
    local fields = {
      pattern = prompt("Pattern (quarry)", "quarry"),
      width = prompt("Width  (+X, to the turtles' right)"),
      length = prompt("Length (+Z, behind the turtles)"),
      depth = prompt("Depth  (blocks down)"),
      turtles = turtles,
      origin = {
        x = prompt("Origin x", 0),
        y = prompt("Origin y", 1),
        z = prompt("Origin z", 0),
      },
    }
    local strips = prompt("Strips (blank = one per turtle)", "")
    if strips ~= "" then fields.strips = strips end
    local spec, err = JobSpec.validate(JobSpec.parse(fields))
    if spec then return spec end
    print("  invalid: " .. err .. " -- try again")
  end
end

-- Setup.run() -> { boxes = {box,...}, expect = N }. Turtle count is asked once
-- (shared across boxes); boxes are added until you decline another.
function Setup.run()
  print("=== cc-fleet-miner : job setup ===")
  local expect = askInt("Turtles in the fleet", 2)
  local boxes = {}
  while true do
    local spec = readBox(expect)
    boxes[#boxes + 1] = spec.box
    print("  box added (" .. #boxes .. " queued)")
    if prompt("Add another box? (y/N)", "n"):lower() ~= "y" then break end
  end
  return { boxes = boxes, expect = expect }
end

return Setup
