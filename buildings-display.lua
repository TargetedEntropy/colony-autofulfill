-- ============================================================
-- buildings-display.lua
--
-- Shows all colony buildings + their levels on an Advanced
-- Monitor (5x5 recommended). Color-codes by level.
--
-- Note: getBuildings() return shape isn't documented for AP, so
-- this script tries multiple field names defensively. On its
-- first poll it writes the first 2 building entries to
-- buildings-shape.txt locally — if rendering looks wrong, paste
-- that file back so the script can be patched.
--
-- Hardware on this computer:
--   * Colony Integrator (inside colony border)
--   * Advanced Monitor (5x5)
--
-- Install on a fresh CC computer:
--   wget https://raw.githubusercontent.com/TargetedEntropy/colony-autofulfill/main/buildings-display.lua startup.lua
--   reboot
-- ============================================================

local CONFIG = {
  poll_seconds   = 30,    -- buildings change rarely
  rotate_seconds = 10,
  text_scale     = 0.5,
  shape_dump_path = "buildings-shape.txt",
}

-- ---------- peripherals ----------
local function findAny(types)
  for _, t in ipairs(types) do
    local p = peripheral.find(t)
    if p then return p end
  end
end

local colony  = findAny({ "colony_integrator", "colonyIntegrator" })
local monitor = peripheral.find("monitor")
assert(colony,  "Colony Integrator not found.")
assert(monitor, "Monitor not found.")

monitor.setTextScale(CONFIG.text_scale)
monitor.setBackgroundColor(colors.black)
monitor.clear()

-- ---------- state ----------
local state = {
  buildings   = {},
  page        = 1,
  total_pages = 1,
  shape_dumped = false,
}

-- ---------- field probes ----------
-- The exact return shape of getBuildings() varies across AP versions.
-- These helpers try several common field names and fall back gracefully.
local function field(t, ...)
  for i = 1, select("#", ...) do
    local k = select(i, ...)
    if t[k] ~= nil then return t[k] end
  end
end

local function buildingName(b)
  -- Try most-specific to least-specific. Strip "minecolonies:" prefix
  -- and capitalize for display.
  local n = field(b, "name", "type", "id", "schematicName", "building")
  if not n then return "?" end
  n = tostring(n)
  n = n:gsub("^minecolonies:", "")
  n = n:gsub("_", " ")
  -- Title-case each word
  n = n:gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end)
  return n
end

local function buildingLevel(b)
  return tonumber(field(b, "level", "currentLevel", "buildingLevel")) or 0
end

local function buildingMaxLevel(b)
  return tonumber(field(b, "maxLevel", "max_level", "maximumLevel")) or 5
end

local function buildingStyle(b)
  return field(b, "style", "schematicStyle") or ""
end

local function buildingPos(b)
  local loc = field(b, "location", "position", "pos")
  if type(loc) == "table" then
    local x = field(loc, "x", "X")
    local y = field(loc, "y", "Y")
    local z = field(loc, "z", "Z")
    if x and y and z then return ("(%d, %d, %d)"):format(x, y, z) end
  end
  return ""
end

-- ---------- helpers ----------
local function abbreviate(s, n)
  s = tostring(s or "")
  if #s <= n then return s end
  return s:sub(1, n - 1) .. "."
end

local function pad(s, n)
  s = tostring(s or "")
  if #s >= n then return s:sub(1, n) end
  return s .. string.rep(" ", n - #s)
end

local function levelColor(level, max)
  if max <= 0 then return colors.white end
  local pct = level / max
  if pct >= 1.0  then return colors.lime end
  if pct >= 0.6  then return colors.green end
  if pct >= 0.3  then return colors.yellow end
  return colors.orange
end

local function dumpShape(buildings)
  if state.shape_dumped or not buildings or #buildings == 0 then return end
  local f = fs.open(CONFIG.shape_dump_path, "w")
  if not f then return end
  f.writeLine("-- First 2 buildings, full shape — paste back if display fields are wrong --")
  for i = 1, math.min(2, #buildings) do
    f.writeLine(("entry %d:"):format(i))
    f.writeLine(textutils.serialise(buildings[i], { compact = false }))
    f.writeLine("")
  end
  f.close()
  state.shape_dumped = true
end

local function pollBuildings()
  local ok, b = pcall(colony.getBuildings)
  if not ok or type(b) ~= "table" then return end
  dumpShape(b)
  -- Sort: Town Hall first, then alphabetical, then by level desc
  table.sort(b, function(a, c)
    local an, cn = buildingName(a), buildingName(c)
    if an == "Town Hall" then return true end
    if cn == "Town Hall" then return false end
    if an ~= cn then return an < cn end
    return buildingLevel(a) > buildingLevel(c)
  end)
  state.buildings = b
end

-- ---------- rendering ----------
local function draw()
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  local w, h = monitor.getSize()

  local name = "?"
  pcall(function() name = colony.getColonyName() end)
  local title = "== " .. name .. " — Buildings =="
  monitor.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), 1)
  monitor.setTextColor(colors.yellow)
  monitor.write(title)

  monitor.setCursorPos(2, 2)
  monitor.setTextColor(colors.lightGray)
  monitor.write(("Total: %d   Updated: %s"):format(#state.buildings, textutils.formatTime(os.time(), true)))

  local col_name  = math.floor((w - 2) * 0.32)
  local col_lvl   = 8
  local col_style = math.floor((w - 2) * 0.20)
  local col_pos   = math.max(10, (w - 2) - col_name - col_lvl - col_style - 2)

  monitor.setCursorPos(2, 4)
  monitor.setTextColor(colors.cyan)
  monitor.write(pad("BUILDING", col_name)  .. " " ..
                pad("LEVEL",    col_lvl)   .. " " ..
                pad("STYLE",    col_style) .. " " ..
                pad("POS",      col_pos))

  local rows_per_page = h - 6
  if rows_per_page < 1 then rows_per_page = 1 end
  state.total_pages = math.max(1, math.ceil(#state.buildings / rows_per_page))
  if state.page > state.total_pages then state.page = 1 end

  local start_i = (state.page - 1) * rows_per_page + 1
  local end_i   = math.min(start_i + rows_per_page - 1, #state.buildings)

  for i = start_i, end_i do
    local b = state.buildings[i] or {}
    local y = 5 + (i - start_i)
    monitor.setCursorPos(2, y)

    local n = abbreviate(buildingName(b), col_name)
    local lvl = buildingLevel(b)
    local maxlvl = buildingMaxLevel(b)
    local lvl_str = ("%d / %d"):format(lvl, maxlvl)
    local style = abbreviate(buildingStyle(b), col_style)
    local pos = abbreviate(buildingPos(b), col_pos)

    monitor.setTextColor(colors.white)
    monitor.write(pad(n, col_name) .. " ")
    monitor.setTextColor(levelColor(lvl, maxlvl))
    monitor.write(pad(lvl_str, col_lvl) .. " ")
    monitor.setTextColor(colors.lightGray)
    monitor.write(pad(style, col_style) .. " ")
    monitor.write(pad(pos, col_pos))
  end

  monitor.setCursorPos(2, h)
  monitor.setTextColor(colors.lightGray)
  if state.total_pages > 1 then
    monitor.write(("Page %d / %d"):format(state.page, state.total_pages))
  end
end

-- ---------- loops ----------
local function pollLoop()
  while true do
    pcall(pollBuildings)
    pcall(draw)
    sleep(CONFIG.poll_seconds)
  end
end

local function rotateLoop()
  while true do
    sleep(CONFIG.rotate_seconds)
    state.page = (state.page % state.total_pages) + 1
    pcall(draw)
  end
end

local function supervised(name, fn)
  return function()
    while true do
      local ok, err = pcall(fn)
      if ok then return end
      print(("ERROR in %s: %s"):format(name, tostring(err)))
      sleep(5)
    end
  end
end

parallel.waitForAll(supervised("poll", pollLoop), supervised("rotate", rotateLoop))
