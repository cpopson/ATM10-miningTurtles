-- jobspec.lua — pure job-setup validation for the control station.
--
-- Turns typed setup inputs into a validated box + turtle count. The setup driver
-- (setup.lua) reads strings from the keyboard and calls parse() then validate();
-- keeping the rules here (no term/read) makes them testable under plain `lua`.

local JobSpec = {}

-- Patterns the coordinator can dispatch today. Branch/tunnel slot in here later.
JobSpec.SUPPORTED = { quarry = true }

local function toInt(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then return tonumber(v) end
  return nil
end

local function isPosInt(n)
  return type(n) == "number" and n >= 1 and n == math.floor(n)
end

local function isInt(n)
  return type(n) == "number" and n == math.floor(n)
end

-- parse(fields) -> raw. Coerce the string form (from read()) into typed values.
-- No validation here — just typing. Missing fields stay nil for validate() to
-- default or reject.
function JobSpec.parse(fields)
  fields = fields or {}
  local o = fields.origin or {}
  return {
    pattern = fields.pattern,
    width = toInt(fields.width),
    length = toInt(fields.length),
    depth = toInt(fields.depth),
    strips = fields.strips ~= nil and fields.strips ~= "" and toInt(fields.strips) or nil,
    turtles = toInt(fields.turtles),
    origin = (fields.origin ~= nil) and { x = toInt(o.x), y = toInt(o.y), z = toInt(o.z) } or nil,
  }
end

-- validate(raw) -> spec, err
--   spec = { box = { pattern, origin, width, length, depth, strips? }, expect = turtles }
-- box.id is left nil so coordinator:enqueue assigns a collision-free id.
function JobSpec.validate(raw)
  raw = raw or {}
  local pattern = raw.pattern or "quarry"
  if not JobSpec.SUPPORTED[pattern] then return nil, "unsupported_pattern" end
  if not isPosInt(raw.width) then return nil, "bad_width" end
  if not isPosInt(raw.length) then return nil, "bad_length" end
  if not isPosInt(raw.depth) then return nil, "bad_depth" end

  local origin = raw.origin or { x = 0, y = 1, z = 0 }
  if not (isInt(origin.x) and isInt(origin.y) and isInt(origin.z)) then
    return nil, "bad_origin"
  end

  if raw.strips ~= nil then
    if not (isPosInt(raw.strips) and raw.strips <= raw.width) then
      return nil, "bad_strips"
    end
  end

  if not isPosInt(raw.turtles) then return nil, "bad_count" end

  return {
    box = {
      pattern = pattern,
      origin = { x = origin.x, y = origin.y, z = origin.z },
      width = raw.width,
      length = raw.length,
      depth = raw.depth,
      strips = raw.strips,
    },
    expect = raw.turtles,
  }
end

return JobSpec
