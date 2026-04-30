-- ============================================================
-- colony-autofulfill — MineColonies <-> AE2 auto-fulfillment
-- with monitor dashboard and a reloadable blacklist.
--
-- See README.md for setup. Hardware:
--   * Advanced Computer (running this as startup.lua)
--   * Advanced Peripherals: Colony Integrator (inside colony
--     border), ME Bridge (on AE2 + powered), optional Chat Box
--   * 3x3 Advanced Monitor (optional, auto-found)
--   * Buffer chest on ME Bridge's CONFIG.export_side, hopper
--     -> Post Box
--   * Wireless Connector pair if your AE2 base is far away
-- ============================================================

local CONFIG = {
  export_side        = "north",
  poll_seconds       = 15,
  dashboard_seconds  = 2,
  log_capacity       = 12,
  chat_verbosity     = "missing",   -- "all" | "missing" | "off"
  loop_restart_delay = 5,
  dedupe_ttl         = 60,          -- per-request cooldown
  item_cooldown      = 120,         -- per-item cooldown — see README "Tuning"
  blacklist_path     = "blacklist.txt",
}

-- ---------- peripheral discovery ----------
local function findAny(types)
  for _, t in ipairs(types) do
    local p = peripheral.find(t)
    if p then return p end
  end
end

local colony  = findAny({ "colony_integrator", "colonyIntegrator" })
local me      = findAny({ "me_bridge", "meBridge" })
local monitor = peripheral.find("monitor")
local chat    = findAny({ "chatBox", "chat_box" })
assert(colony, "Colony Integrator not found. Place it inside colony border + adjacent to (or networked with) the computer.")
assert(me,     "ME Bridge not found. Place it on AE2 cable, powered, adjacent to the computer.")

-- ---------- shared state ----------
local state = {
  recent_log         = {},
  fulfilled          = 0,
  scheduled          = 0,
  missing            = 0,
  blocked            = 0,    -- count this poll of requests skipped because all alternatives are blacklisted
  deferred           = 0,    -- count this poll of requests skipped due to item cooldown
  crafting           = {},   -- item name -> true
  handled            = {},   -- req.id -> os.epoch("local") ms
  cooldown           = {},   -- item name -> os.epoch("local") ms (last export)
  blacklist          = { names = {}, tags = {} },
  blacklist_mtime    = 0,
  last_request_count = 0,
}

-- ---------- logging ----------
local function pushLog(msg)
  table.insert(state.recent_log, 1, ("%s %s"):format(textutils.formatTime(os.time(), true), msg))
  while #state.recent_log > CONFIG.log_capacity do
    table.remove(state.recent_log)
  end
end

local function shouldChat(level)
  if not chat or CONFIG.chat_verbosity == "off" then return false end
  if CONFIG.chat_verbosity == "all" then return true end
  return level == "missing"
end

local function log(msg, level)
  level = level or "info"
  print(msg)
  pushLog(msg)
  if shouldChat(level) then pcall(chat.sendMessage, msg, "Colony") end
end

-- ---------- blacklist ----------
local function loadBlacklist()
  local b = { names = {}, tags = {} }
  if not fs.exists(CONFIG.blacklist_path) then return b, 0 end

  local f = fs.open(CONFIG.blacklist_path, "r")
  while true do
    local line = f.readLine()
    if not line then break end
    line = line:match("^%s*(.-)%s*$") or ""
    if line ~= "" and line:sub(1, 1) ~= "#" then
      if line:sub(1, 4) == "tag:" then
        b.tags[line:sub(5)] = true
      else
        b.names[line] = true
      end
    end
  end
  f.close()

  local attrs = fs.attributes(CONFIG.blacklist_path)
  return b, (attrs and attrs.modified) or os.epoch("local")
end

local function reloadBlacklistIfChanged()
  if not fs.exists(CONFIG.blacklist_path) then
    if state.blacklist_mtime ~= 0 then
      state.blacklist = { names = {}, tags = {} }
      state.blacklist_mtime = 0
      log("blacklist removed; nothing blocked")
    end
    return
  end
  local attrs = fs.attributes(CONFIG.blacklist_path)
  local mt = (attrs and attrs.modified) or 0
  if mt ~= state.blacklist_mtime then
    local b
    b, mt = loadBlacklist()
    state.blacklist = b
    state.blacklist_mtime = mt
    local n, t = 0, 0
    for _ in pairs(b.names) do n = n + 1 end
    for _ in pairs(b.tags)  do t = t + 1 end
    log(("blacklist loaded: %d items, %d tags"):format(n, t))
  end
end

local function isBlacklisted(alt)
  if state.blacklist.names[alt.name] then return true end
  if alt.tags then
    for _, t in ipairs(alt.tags) do
      -- Tags from MineColonies arrive prefixed "minecraft:item/<actual>".
      -- Match against both the prefixed and stripped form so users can write
      -- either "tag:c:ores/netherite" or "tag:minecraft:item/c:ores/netherite".
      if state.blacklist.tags[t] then return true end
      local short = t:gsub("^minecraft:item/", "")
      if state.blacklist.tags[short] then return true end
    end
  end
  return false
end

-- ---------- tool tier (for picking best alt when multiple are stocked) ----------
local TIER_PREFIXES = {
  { prefix = "netherite_", tier = 5 },
  { prefix = "diamond_",   tier = 4 },
  { prefix = "iron_",      tier = 3 },
  { prefix = "stone_",     tier = 2 },
  { prefix = "golden_",    tier = 1 },
  { prefix = "gold_",      tier = 1 },
  { prefix = "wooden_",    tier = 1 },
  { prefix = "wood_",      tier = 1 },
}

local function tierOf(name)
  local short = name:match(":(.+)") or name
  for _, t in ipairs(TIER_PREFIXES) do
    if short:find("^" .. t.prefix) then return t.tier end
  end
  return 0
end

-- ---------- ME helpers ----------
local function alreadyCrafting(name)
  if state.crafting[name] then return true end
  local ok, busy = pcall(me.isCrafting, { name = name })
  return ok and busy
end

local function getStock(name)
  local ok, info = pcall(me.getItem, { name = name })
  if not ok or not info then return 0, false end
  return info.count or 0, info.isCraftable or false
end

local function onCooldown(name)
  local last = state.cooldown[name]
  if not last then return false end
  return (os.epoch("local") - last) < (CONFIG.item_cooldown * 1000)
end

-- ---------- fulfillment ----------
local function chooseAlternative(req)
  local needed = req.minCount or req.count or 1
  local stocked, craftables = {}, {}
  local sawAlt, allBlocked = false, true
  local skippedByCooldown = false

  for _, alt in ipairs(req.items or {}) do
    sawAlt = true
    if isBlacklisted(alt) then
      -- skip; don't count against allBlocked? — actually do, because if
      -- every alt is blacklisted, this request can't be fulfilled.
    else
      allBlocked = false
      if onCooldown(alt.name) then
        skippedByCooldown = true
      else
        local stock, craftable = getStock(alt.name)
        if stock >= needed then
          table.insert(stocked, { name = alt.name, count = stock, tier = tierOf(alt.name) })
        end
        if craftable then
          table.insert(craftables, alt.name)
        end
      end
    end
  end

  if sawAlt and allBlocked then return "blocked" end

  if #stocked > 0 then
    table.sort(stocked, function(a, b)
      if a.tier ~= b.tier then return a.tier > b.tier end
      return a.count > b.count
    end)
    return "stock", stocked[1].name
  end

  if #craftables > 0 then
    return "craft", craftables[1]
  end

  if skippedByCooldown then
    return "cooldown"
  end
end

local function fulfill(req)
  if not req.items or #req.items == 0 then return end

  local now = os.epoch("local")
  if state.handled[req.id] and (now - state.handled[req.id]) < (CONFIG.dedupe_ttl * 1000) then
    return
  end

  local desc = req.desc or req.name or "?"
  local target = req.target or "?"
  local desired = req.count or req.minCount or 1

  local kind, itemName = chooseAlternative(req)

  if kind == "stock" then
    local stock = getStock(itemName)
    local toSend = math.min(desired, stock)
    local exported = me.exportItem({ name = itemName, count = toSend }, CONFIG.export_side)
    if exported and exported > 0 then
      state.fulfilled = state.fulfilled + 1
      state.handled[req.id] = now
      state.cooldown[itemName] = now
      log(("EXPORT %dx %s -> %s (%s)"):format(exported, itemName, target, desc))
    else
      log(("EXPORT FAILED %s (buffer full?)"):format(itemName), "missing")
    end
    return
  end

  if kind == "craft" then
    if alreadyCrafting(itemName) then return end
    local ok = me.craftItem({ name = itemName, count = desired })
    if ok then
      state.crafting[itemName] = true
      state.scheduled = state.scheduled + 1
      state.handled[req.id] = now
      state.cooldown[itemName] = now
      log(("CRAFT %dx %s for %s"):format(desired, itemName, desc))
    else
      log(("CRAFT FAILED %s"):format(itemName), "missing")
    end
    return
  end

  if kind == "blocked" then
    state.blocked = state.blocked + 1
    return
  end

  if kind == "cooldown" then
    state.deferred = state.deferred + 1
    return
  end

  state.missing = state.missing + 1
  log(("MISSING %s for %s"):format(desc, target), "missing")
end

-- ---------- main fulfill loop ----------
local function fulfillLoop()
  log("Auto-fulfill running for: " .. colony.getColonyName())
  reloadBlacklistIfChanged()

  while true do
    reloadBlacklistIfChanged()

    for name in pairs(state.crafting) do
      if not alreadyCrafting(name) then state.crafting[name] = nil end
    end

    local now = os.epoch("local")
    local ttlMs = CONFIG.dedupe_ttl * 1000
    for id, ts in pairs(state.handled) do
      if (now - ts) > ttlMs then state.handled[id] = nil end
    end
    local cdMs = CONFIG.item_cooldown * 1000
    for name, ts in pairs(state.cooldown) do
      if (now - ts) > cdMs then state.cooldown[name] = nil end
    end

    state.deferred = 0
    state.blocked = 0

    local ok, requests = pcall(colony.getRequests)
    if ok and requests then
      state.last_request_count = #requests
      for _, req in ipairs(requests) do
        pcall(fulfill, req)
      end
    end

    sleep(CONFIG.poll_seconds)
  end
end

-- ---------- dashboard ----------
local function setColor(c) if monitor then monitor.setTextColor(c) end end

local function writeAt(x, y, text)
  monitor.setCursorPos(x, y)
  monitor.write(text)
end

local function center(y, text, color)
  local w = monitor.getSize()
  setColor(color or colors.white)
  writeAt(math.max(1, math.floor((w - #text) / 2) + 1), y, text)
end

local function happinessColor(h)
  if h >= 7 then return colors.lime end
  if h >= 5 then return colors.yellow end
  return colors.red
end

local function drawDashboard()
  if not monitor then return end
  monitor.setBackgroundColor(colors.black)
  monitor.setTextScale(0.5)
  monitor.clear()
  local w, h = monitor.getSize()

  center(1, "== " .. colony.getColonyName() .. " ==", colors.yellow)

  setColor(colors.white)
  writeAt(2, 3, ("Citizens: %d / %d"):format(colony.amountOfCitizens(), colony.maxOfCitizens()))

  local happy = colony.getHappiness() or 0
  setColor(happinessColor(happy))
  writeAt(2, 4, ("Happy:    %.1f / 10"):format(happy))

  setColor(colors.white);     writeAt(2, 6,  ("Pending:   %d"):format(state.last_request_count))
  setColor(colors.lime);      writeAt(2, 7,  ("Filled:    %d"):format(state.fulfilled))
  setColor(colors.cyan);      writeAt(2, 8,  ("Crafts:    %d"):format(state.scheduled))
  setColor(colors.lightBlue); writeAt(2, 9,  ("In flight: %d"):format(state.deferred))
  setColor(colors.purple);    writeAt(2, 10, ("Blocked:   %d"):format(state.blocked))
  setColor(colors.orange);    writeAt(2, 11, ("Missing:   %d"):format(state.missing))

  setColor(colors.cyan)
  writeAt(2, 13, "Recent:")
  setColor(colors.lightGray)
  for i, line in ipairs(state.recent_log) do
    local y = 13 + i
    if y > h then break end
    writeAt(2, y, line:sub(1, w - 2))
  end
end

local function dashboardLoop()
  while true do
    pcall(drawDashboard)
    sleep(CONFIG.dashboard_seconds)
  end
end

-- ---------- run ----------
local function supervised(name, fn)
  return function()
    while true do
      local ok, err = pcall(fn)
      if ok then return end
      log(("ERROR in %s: %s"):format(name, tostring(err)), "missing")
      sleep(CONFIG.loop_restart_delay)
    end
  end
end

if monitor then
  parallel.waitForAll(supervised("fulfill", fulfillLoop), supervised("dashboard", dashboardLoop))
else
  supervised("fulfill", fulfillLoop)()
end
