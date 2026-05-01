-- ============================================================
-- colony-autofulfill — MineColonies <-> AE2 auto-fulfillment
-- Robust branch: safer request identity, API-shape tolerant AE2 calls,
-- less duplicate shipping, smarter alternative choice, and quieter errors.
--
-- Hardware:
--   * Advanced Computer (running this as startup.lua)
--   * Advanced Peripherals Colony Integrator + ME Bridge
--   * Optional Advanced Monitor dashboard and Chat Box alerts
--   * Buffer chest on ME Bridge's CONFIG.export_side -> Post Box
-- ============================================================

local CONFIG = {
  export_side              = "north",
  poll_seconds             = 15,
  dashboard_seconds        = 2,
  log_capacity             = 14,
  chat_verbosity           = "missing", -- "all" | "missing" | "off"
  loop_restart_delay       = 5,

  -- Request-level duplicate protection. Stable request ids are used when AP
  -- exposes them; otherwise a fingerprint of target/description/items is used.
  dedupe_ttl               = 180,

  -- Extra safety against repeated exports for the same request+item while the
  -- Post Box / courier pipeline catches up. Unlike the old global item cooldown,
  -- this does not block different citizens/builders requesting the same item.
  request_item_cooldown    = 240,

  -- Legacy global item cooldown is kept but disabled by default because it can
  -- starve unrelated requests for common materials. Set >0 if your colony keeps
  -- duplicating shipments aggressively.
  item_cooldown            = 0,

  -- Missing/chat spam throttles.
  missing_log_ttl          = 300,
  error_log_ttl            = 60,

  -- Export/craft guardrails.
  max_export_stack         = 64,
  max_craft_batch          = 256,
  craft_only_full_amount   = true,

  blacklist_path           = "blacklist.txt",
}

-- ---------- small compatibility helpers ----------
local unpack = unpack or table.unpack

local function nowMs()
  if os.epoch then return os.epoch("local") end
  return math.floor(os.clock() * 1000)
end

local function trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function serial(v)
  if textutils and textutils.serialise then return textutils.serialise(v) end
  return tostring(v)
end

local function tableCount(t)
  local n = 0
  if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
  return n
end

local function clampCount(n, maxn)
  n = tonumber(n) or 1
  if n < 1 then n = 1 end
  if maxn and maxn > 0 and n > maxn then n = maxn end
  return math.floor(n)
end

-- ---------- peripheral discovery ----------
local function findAny(types)
  for _, t in ipairs(types) do
    local p = peripheral.find(t)
    if p then return p, t end
  end
end

local colony, colonyType = findAny({ "colony_integrator", "colonyIntegrator" })
local me, meType         = findAny({ "me_bridge", "meBridge" })
local monitor            = peripheral.find("monitor")
local chat               = findAny({ "chatBox", "chat_box" })
assert(colony, "Colony Integrator not found. Place it inside the colony border and connect it to this computer.")
assert(me,     "ME Bridge not found. Place it on powered AE2 cable and connect it to this computer.")

-- ---------- shared state ----------
local state = {
  recent_log         = {},
  fulfilled          = 0,
  scheduled          = 0,
  missing            = 0,
  blocked            = 0,
  deferred           = 0,
  errors             = 0,
  crafting           = {}, -- item name -> expiry ms
  handled            = {}, -- request key -> expiry ms
  request_item_cd    = {}, -- request key .. "|" .. item -> expiry ms
  item_cd            = {}, -- item name -> expiry ms, optional legacy safety
  missing_seen       = {}, -- request key -> next log ms
  error_seen         = {}, -- error key -> next log ms
  blacklist          = { names = {}, tags = {} },
  blacklist_mtime    = -1,
  last_request_count = 0,
  last_poll_ok       = false,
  last_error         = "",
}

-- ---------- logging ----------
local function pushLog(msg)
  table.insert(state.recent_log, 1, ("%s %s"):format(textutils.formatTime(os.time(), true), tostring(msg)))
  while #state.recent_log > CONFIG.log_capacity do table.remove(state.recent_log) end
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
  if shouldChat(level) then pcall(chat.sendMessage, tostring(msg), "Colony") end
end

local function logThrottled(bucket, key, ttlSeconds, msg, level)
  local now = nowMs()
  local nextAt = bucket[key]
  if nextAt and now < nextAt then return end
  bucket[key] = now + ((ttlSeconds or 60) * 1000)
  log(msg, level)
end

local function rememberError(key, msg)
  state.errors = state.errors + 1
  state.last_error = tostring(msg)
  logThrottled(state.error_seen, key, CONFIG.error_log_ttl, "ERROR " .. tostring(msg), "missing")
end

-- ---------- blacklist ----------
local function normaliseTag(tag)
  tag = trim(tag)
  tag = tag:gsub("^#", "")
  tag = tag:gsub("^minecraft:item/", "")
  return tag
end

local function loadBlacklist()
  local b = { names = {}, tags = {} }
  if not fs.exists(CONFIG.blacklist_path) then return b, 0 end

  local f = fs.open(CONFIG.blacklist_path, "r")
  if not f then return b, 0 end
  while true do
    local line = f.readLine()
    if not line then break end
    line = line:gsub("%s+#.*$", "")
    line = trim(line)
    if line ~= "" and line:sub(1, 1) ~= "#" then
      if line:sub(1, 4) == "tag:" then
        local tag = normaliseTag(line:sub(5))
        if tag ~= "" then b.tags[tag] = true end
      else
        b.names[lower(line)] = true
      end
    end
  end
  f.close()

  local attrs = fs.attributes(CONFIG.blacklist_path)
  return b, (attrs and attrs.modified) or nowMs()
end

local function reloadBlacklistIfChanged()
  local mt = 0
  if fs.exists(CONFIG.blacklist_path) then
    local attrs = fs.attributes(CONFIG.blacklist_path)
    mt = (attrs and attrs.modified) or 1
  end
  if mt == state.blacklist_mtime then return end

  local b
  b, mt = loadBlacklist()
  state.blacklist = b
  state.blacklist_mtime = mt
  log(("blacklist loaded: %d items, %d tags"):format(tableCount(b.names), tableCount(b.tags)))
end

local function altTags(alt)
  local tags = alt and (alt.tags or alt.tagNames or alt.itemTags or alt.item_tags)
  if type(tags) ~= "table" then return {} end
  return tags
end

local function isBlacklisted(alt)
  if not alt or not alt.name then return true end
  if state.blacklist.names[lower(alt.name)] then return true end
  for _, t in ipairs(altTags(alt)) do
    local raw = tostring(t)
    if state.blacklist.tags[raw] then return true end
    if state.blacklist.tags[normaliseTag(raw)] then return true end
  end
  return false
end

-- ---------- request / item normalisation ----------
local function firstField(t, fields, default)
  if type(t) ~= "table" then return default end
  for _, f in ipairs(fields) do
    local v = t[f]
    if v ~= nil then return v end
  end
  return default
end

local function itemName(raw)
  if type(raw) == "string" then return raw end
  if type(raw) ~= "table" then return nil end
  local v = firstField(raw, { "name", "id", "item", "itemName", "item_name" })
  if type(v) == "table" then return itemName(v) end
  return v and tostring(v) or nil
end

local function normaliseAlt(raw)
  if type(raw) ~= "table" and type(raw) ~= "string" then return nil end
  local name = itemName(raw)
  if not name or name == "" then return nil end
  local alt = type(raw) == "table" and raw or {}
  return {
    name = name,
    displayName = firstField(alt, { "displayName", "display_name", "label", "display" }, name),
    tags = altTags(alt),
    raw = raw,
  }
end

local function requestItems(req)
  local raw = firstField(req, { "items", "itemList", "item_list", "alternatives", "acceptableItems" }, {})
  local out = {}
  if type(raw) == "table" then
    for _, v in ipairs(raw) do
      local alt = normaliseAlt(v)
      if alt then table.insert(out, alt) end
    end
    if #out == 0 then
      local alt = normaliseAlt(raw)
      if alt then table.insert(out, alt) end
    end
  else
    local alt = normaliseAlt(raw)
    if alt then table.insert(out, alt) end
  end
  return out
end

local function requestCount(req)
  return clampCount(firstField(req, { "count", "minCount", "min_count", "amount", "quantity", "qty" }, 1), CONFIG.max_craft_batch)
end

local function requestDesc(req)
  return tostring(firstField(req, { "desc", "description", "name", "displayName", "shortDisplayString" }, "?"))
end

local function requestTarget(req)
  local t = firstField(req, { "target", "citizen", "requester", "requesterName", "buildingName" }, "?")
  if type(t) == "table" then
    t = firstField(t, { "name", "displayName", "id" }, serial(t))
  end
  return tostring(t or "?")
end

local function requestKey(req, alts)
  local id = firstField(req, { "id", "requestId", "request_id", "token" })
  if id ~= nil and tostring(id) ~= "" then return "id:" .. tostring(id) end
  local names = {}
  for _, a in ipairs(alts or requestItems(req)) do table.insert(names, a.name) end
  table.sort(names)
  return "fp:" .. requestTarget(req) .. "|" .. requestDesc(req) .. "|" .. tostring(requestCount(req)) .. "|" .. table.concat(names, ",")
end

-- ---------- item scoring ----------
local TIER_PREFIXES = {
  { prefix = "netherite_", tier = 6 },
  { prefix = "diamond_",   tier = 5 },
  { prefix = "iron_",      tier = 4 },
  { prefix = "stone_",     tier = 3 },
  { prefix = "golden_",    tier = 2 },
  { prefix = "gold_",      tier = 2 },
  { prefix = "wooden_",    tier = 1 },
  { prefix = "wood_",      tier = 1 },
}

local TOOL_WORDS = { pickaxe=true, axe=true, shovel=true, hoe=true, sword=true, helmet=true, chestplate=true, leggings=true, boots=true, shears=true, bow=true, crossbow=true }
local LOW_VALUE_HINTS = { cobblestone=true, dirt=true, gravel=true, sand=true, stick=true, plank=true, log=true, coal=true, charcoal=true, torch=true }

local function shortName(name)
  return tostring(name or ""):match(":([^:]+)$") or tostring(name or "")
end

local function tierOf(name)
  local s = shortName(name)
  for _, t in ipairs(TIER_PREFIXES) do
    if s:find("^" .. t.prefix) then return t.tier end
  end
  return 0
end

local function looksLikeToolRequest(alts)
  for _, alt in ipairs(alts or {}) do
    local s = shortName(alt.name)
    for word in pairs(TOOL_WORDS) do
      if s:find(word) then return true end
    end
  end
  return false
end

local function lowValueScore(name)
  local s = shortName(name)
  for hint in pairs(LOW_VALUE_HINTS) do
    if s:find(hint) then return 50 end
  end
  return 0
end

-- ---------- ME bridge wrappers ----------
local function call(obj, methodNames, ...)
  for _, m in ipairs(methodNames) do
    local fn = obj[m]
    if type(fn) == "function" then
      local ok, a, b, c = pcall(fn, ...)
      if ok then return true, a, b, c, m end
      return false, a, nil, nil, m
    end
  end
  return false, "method missing: " .. table.concat(methodNames, "/")
end

local function getStock(name)
  local ok, info = call(me, { "getItem", "get_item" }, { name = name })
  if not ok or not info then return 0, false end
  if type(info) == "number" then return info, false end
  if type(info) ~= "table" then return 0, false end
  local count = tonumber(firstField(info, { "count", "amount", "qty", "quantity" }, 0)) or 0
  local craftable = firstField(info, { "isCraftable", "craftable", "is_craftable" }, false) and true or false
  return count, craftable
end

local function isCraftable(name, stockFlag)
  if stockFlag then return true end
  local ok, result = call(me, { "isItemCraftable", "is_item_craftable", "isCraftable" }, { name = name })
  if ok then return result and true or false end
  return false
end

local function alreadyCrafting(name)
  local expiry = state.crafting[name]
  if expiry and nowMs() < expiry then return true end
  state.crafting[name] = nil

  local ok, busy = call(me, { "isItemCrafting", "is_item_crafting", "isCrafting" }, { name = name })
  if ok then return busy and true or false end
  return false
end

local function exportItem(name, count)
  count = clampCount(count, CONFIG.max_export_stack)
  local ok, result, _, _, method = call(me, { "exportItem", "export_item" }, { name = name, count = count }, CONFIG.export_side)
  if not ok then return 0, tostring(result) end
  if type(result) == "number" then return result, nil end
  if type(result) == "boolean" then return result and count or 0, nil end
  if type(result) == "table" then
    local n = tonumber(firstField(result, { "count", "amount", "exported", "transferred" }, 0)) or 0
    if n > 0 then return n, nil end
    if firstField(result, { "ok", "success" }, false) then return count, nil end
    return 0, serial(result)
  end
  return 0, "unexpected " .. tostring(method) .. " result: " .. tostring(result)
end

local function craftItem(name, count)
  count = clampCount(count, CONFIG.max_craft_batch)
  local ok, result = call(me, { "craftItem", "craft_item" }, { name = name, count = count })
  if not ok then return false, tostring(result) end
  if result == false or result == nil then return false, tostring(result) end
  return true, result
end

-- ---------- cooldowns ----------
local function purgeExpiring(map)
  local now = nowMs()
  for k, expiry in pairs(map) do
    if type(expiry) == "number" and now >= expiry then map[k] = nil end
  end
end

local function onAnyCooldown(reqKey, name)
  local now = nowMs()
  if state.request_item_cd[reqKey .. "|" .. name] and now < state.request_item_cd[reqKey .. "|" .. name] then return true end
  if CONFIG.item_cooldown and CONFIG.item_cooldown > 0 and state.item_cd[name] and now < state.item_cd[name] then return true end
  return false
end

local function markHandled(reqKey, name)
  local now = nowMs()
  state.handled[reqKey] = now + CONFIG.dedupe_ttl * 1000
  state.request_item_cd[reqKey .. "|" .. name] = now + CONFIG.request_item_cooldown * 1000
  if CONFIG.item_cooldown and CONFIG.item_cooldown > 0 then
    state.item_cd[name] = now + CONFIG.item_cooldown * 1000
  end
end

-- ---------- fulfillment ----------
local function chooseAlternative(req, alts, reqKey)
  local needed = requestCount(req)
  local stocked, craftables = {}, {}
  local allBlocked, sawUsable, skippedByCooldown = true, false, false
  local toolRequest = looksLikeToolRequest(alts)

  for _, alt in ipairs(alts) do
    if not isBlacklisted(alt) then
      allBlocked = false
      if onAnyCooldown(reqKey, alt.name) then
        skippedByCooldown = true
      else
        local stock, stockCraftable = getStock(alt.name)
        local craftable = isCraftable(alt.name, stockCraftable)
        if stock > 0 or craftable then sawUsable = true end
        if stock >= needed then
          local score
          if toolRequest then
            score = (tierOf(alt.name) * 1000000) + stock
          else
            score = (lowValueScore(alt.name) * 1000000) + stock - (tierOf(alt.name) * 10000)
          end
          table.insert(stocked, { name = alt.name, stock = stock, score = score })
        end
        if craftable then
          local score = (toolRequest and tierOf(alt.name) or lowValueScore(alt.name)) * 1000000 - tierOf(alt.name) * 10000
          table.insert(craftables, { name = alt.name, score = score })
        end
      end
    end
  end

  if #alts > 0 and allBlocked then return "blocked" end

  if #stocked > 0 then
    table.sort(stocked, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      return a.stock > b.stock
    end)
    return "stock", stocked[1].name
  end

  if #craftables > 0 then
    table.sort(craftables, function(a, b) return a.score > b.score end)
    return "craft", craftables[1].name
  end

  if skippedByCooldown then return "cooldown" end
  if sawUsable then return "partial" end
  return "missing"
end

local function fulfill(req)
  local alts = requestItems(req)
  if #alts == 0 then return end

  local key = requestKey(req, alts)
  local now = nowMs()
  if state.handled[key] and now < state.handled[key] then return end

  local desc = requestDesc(req)
  local target = requestTarget(req)
  local desired = requestCount(req)

  local kind, item = chooseAlternative(req, alts, key)

  if kind == "stock" then
    local stock = getStock(item)
    local toSend = math.min(desired, stock, CONFIG.max_export_stack)
    if CONFIG.craft_only_full_amount and stock < desired then return end
    local exported, err = exportItem(item, toSend)
    if exported and exported > 0 then
      state.fulfilled = state.fulfilled + 1
      markHandled(key, item)
      log(("EXPORT %dx %s -> %s (%s)"):format(exported, item, target, desc), "info")
    else
      rememberError("export:" .. item, ("EXPORT FAILED %s (%s)"):format(item, err or "buffer full or bridge refused"))
    end
    return
  end

  if kind == "craft" then
    if alreadyCrafting(item) then
      state.deferred = state.deferred + 1
      return
    end
    local ok, err = craftItem(item, desired)
    if ok then
      state.crafting[item] = now + (CONFIG.request_item_cooldown * 1000)
      state.scheduled = state.scheduled + 1
      markHandled(key, item)
      log(("CRAFT %dx %s for %s (%s)"):format(desired, item, target, desc), "info")
    else
      rememberError("craft:" .. item, ("CRAFT FAILED %s (%s)"):format(item, err or "bridge refused"))
    end
    return
  end

  if kind == "blocked" then
    state.blocked = state.blocked + 1
    return
  end

  if kind == "cooldown" or kind == "partial" then
    state.deferred = state.deferred + 1
    return
  end

  state.missing = state.missing + 1
  logThrottled(state.missing_seen, key, CONFIG.missing_log_ttl, ("MISSING %s for %s"):format(desc, target), "missing")
end

-- ---------- main fulfill loop ----------
local function getColonyName()
  local ok, name = pcall(colony.getColonyName)
  if ok and name then return tostring(name) end
  return "Colony"
end

local function fulfillLoop()
  log(("Auto-fulfill running for: %s (%s + %s)"):format(getColonyName(), tostring(colonyType), tostring(meType)))
  reloadBlacklistIfChanged()

  while true do
    reloadBlacklistIfChanged()
    purgeExpiring(state.handled)
    purgeExpiring(state.request_item_cd)
    purgeExpiring(state.item_cd)
    purgeExpiring(state.crafting)

    state.deferred = 0
    state.blocked = 0

    local ok, requests = pcall(colony.getRequests)
    if ok and type(requests) == "table" then
      state.last_poll_ok = true
      state.last_request_count = #requests
      for _, req in ipairs(requests) do
        local worked, err = pcall(fulfill, req)
        if not worked then rememberError("request", "request skipped: " .. tostring(err)) end
      end
    else
      state.last_poll_ok = false
      rememberError("poll", "colony.getRequests failed: " .. tostring(requests))
    end

    sleep(CONFIG.poll_seconds)
  end
end

-- ---------- dashboard ----------
local function setColor(c) if monitor then monitor.setTextColor(c) end end

local function writeAt(x, y, text)
  monitor.setCursorPos(x, y)
  monitor.write(tostring(text or ""))
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

local function safeNumber(method, default)
  local fn = colony[method]
  if type(fn) ~= "function" then return default or 0 end
  local ok, v = pcall(fn)
  if ok and tonumber(v) then return tonumber(v) end
  return default or 0
end

local function drawDashboard()
  if not monitor then return end
  monitor.setBackgroundColor(colors.black)
  monitor.setTextScale(0.5)
  monitor.clear()
  local w, h = monitor.getSize()

  center(1, "== " .. getColonyName() .. " ==", colors.yellow)

  setColor(colors.white)
  writeAt(2, 3, ("Citizens: %d / %d"):format(safeNumber("amountOfCitizens"), safeNumber("maxOfCitizens")))

  local happy = safeNumber("getHappiness", 0)
  setColor(happinessColor(happy))
  writeAt(2, 4, ("Happy:    %.1f / 10"):format(happy))

  setColor(colors.white);     writeAt(2, 6,  ("Pending:   %d"):format(state.last_request_count))
  setColor(colors.lime);      writeAt(2, 7,  ("Filled:    %d"):format(state.fulfilled))
  setColor(colors.cyan);      writeAt(2, 8,  ("Crafts:    %d"):format(state.scheduled))
  setColor(colors.lightBlue); writeAt(2, 9,  ("Deferred:  %d"):format(state.deferred))
  setColor(colors.purple);    writeAt(2, 10, ("Blocked:   %d"):format(state.blocked))
  setColor(colors.orange);    writeAt(2, 11, ("Missing:   %d"):format(state.missing))
  setColor(state.last_poll_ok and colors.lime or colors.red)
  writeAt(2, 12, "Poll:      " .. (state.last_poll_ok and "ok" or "failed"))

  setColor(colors.cyan)
  writeAt(2, 14, "Recent:")
  setColor(colors.lightGray)
  for i, line in ipairs(state.recent_log) do
    local y = 14 + i
    if y > h then break end
    writeAt(2, y, line:sub(1, w - 2))
  end
end

local function dashboardLoop()
  while true do
    local ok, err = pcall(drawDashboard)
    if not ok then rememberError("dashboard", "dashboard failed: " .. tostring(err)) end
    sleep(CONFIG.dashboard_seconds)
  end
end

-- ---------- run ----------
local function supervised(name, fn)
  return function()
    while true do
      local ok, err = pcall(fn)
      if ok then return end
      rememberError("loop:" .. name, ("loop %s crashed: %s"):format(name, tostring(err)))
      sleep(CONFIG.loop_restart_delay)
    end
  end
end

if monitor then
  parallel.waitForAll(supervised("fulfill", fulfillLoop), supervised("dashboard", dashboardLoop))
else
  supervised("fulfill", fulfillLoop)()
end
