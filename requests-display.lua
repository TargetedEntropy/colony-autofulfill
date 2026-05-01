-- ============================================================
-- requests-display.lua
--
-- Shows all open MineColonies requests on an Advanced Monitor
-- (5x5 recommended). Auto-paginates if there are more requests
-- than fit on screen.
--
-- Hardware on this computer:
--   * Colony Integrator (inside colony border, adjacent to or
--     networked with the computer)
--   * Advanced Monitor (5x5 of advanced monitor blocks)
--
-- Install on a fresh CC computer:
--   wget https://raw.githubusercontent.com/TargetedEntropy/colony-autofulfill/main/requests-display.lua startup.lua
--   reboot
-- ============================================================

local CONFIG = {
  poll_seconds   = 5,
  rotate_seconds = 8,    -- time per page when paginating
  text_scale     = 0.5,  -- 0.5 packs more onto a 5x5
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
  requests = {},
  page     = 1,
  total_pages = 1,
}

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

local function stateColor(st)
  if not st then return colors.white end
  if st == "IN_DELIVERY"   then return colors.lime end
  if st == "IN_PROGRESS"   then return colors.yellow end
  if st == "REQUESTED"     then return colors.orange end
  if st == "FAILED"        then return colors.red end
  if st == "COMPLETED"     then return colors.gray end
  return colors.white
end

local function pollRequests()
  local ok, reqs = pcall(colony.getRequests)
  if ok and reqs then state.requests = reqs end
end

-- ---------- rendering ----------
local function draw()
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  local w, h = monitor.getSize()

  -- Title
  local name = "?"
  pcall(function() name = colony.getColonyName() end)
  local title = "== " .. name .. " — Open Requests =="
  monitor.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), 1)
  monitor.setTextColor(colors.yellow)
  monitor.write(title)

  -- Subtitle
  monitor.setCursorPos(2, 2)
  monitor.setTextColor(colors.lightGray)
  monitor.write(("Total: %d   Updated: %s"):format(#state.requests, textutils.formatTime(os.time(), true)))

  -- Column widths sized to monitor (proportional, sums to w-1)
  local col_target = math.floor((w - 2) * 0.32)
  local col_item   = math.floor((w - 2) * 0.50)
  local col_count  = math.floor((w - 2) * 0.08)
  local col_state  = math.max(8, (w - 2) - col_target - col_item - col_count)

  -- Header row
  monitor.setCursorPos(2, 4)
  monitor.setTextColor(colors.cyan)
  monitor.write(pad("TARGET", col_target) .. " " ..
                pad("ITEM",   col_item)   .. " " ..
                pad("CNT",    col_count)  .. " " ..
                pad("STATE",  col_state))

  -- Pagination
  local rows_per_page = h - 6
  if rows_per_page < 1 then rows_per_page = 1 end
  state.total_pages = math.max(1, math.ceil(#state.requests / rows_per_page))
  if state.page > state.total_pages then state.page = 1 end

  local start_i = (state.page - 1) * rows_per_page + 1
  local end_i   = math.min(start_i + rows_per_page - 1, #state.requests)

  for i = start_i, end_i do
    local req = state.requests[i] or {}
    local y = 5 + (i - start_i)
    monitor.setCursorPos(2, y)

    local target = abbreviate(req.target, col_target)
    local item   = abbreviate(req.desc or req.name, col_item)
    local count  = tostring(req.count or 1)
    local st     = abbreviate(req.state, col_state)

    monitor.setTextColor(colors.white)
    monitor.write(pad(target, col_target) .. " ")
    monitor.write(pad(item,   col_item)   .. " ")
    monitor.write(pad(count,  col_count)  .. " ")
    monitor.setTextColor(stateColor(req.state))
    monitor.write(pad(st, col_state))
  end

  -- Footer
  monitor.setCursorPos(2, h)
  monitor.setTextColor(colors.lightGray)
  if state.total_pages > 1 then
    monitor.write(("Page %d / %d"):format(state.page, state.total_pages))
  end
end

-- ---------- loops ----------
local function pollLoop()
  while true do
    pcall(pollRequests)
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
