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
  -- ME Bridge output target. This is the side/peripheral name used by exportItem.
  -- Run `startup setup` to change it without editing Lua.
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

  -- Domum Ornamentum variants on MC 1.21.1 store identity in data components.
  -- Colony Integrator fingerprints may not match ME Bridge fingerprints, so this
  -- script uses component-aware matching/export before falling back.
  domum_match_me_variant   = true,
  domum_require_components = true,
  domum_disable_crafting   = false,
  domum_craft_plain_shapes = true,

  -- Verification matters because some ME Bridge/AP versions return boolean true
  -- for a successful method call even when zero items actually moved. Domum is
  -- verified by default so the script does not lie, cooldown the request, and
  -- then leave the courier staring into an empty post box like a cursed ledger.
  verify_exports           = true,
  domum_verify_exports     = true,
  verify_wait_seconds      = 0.15,
  unconfirmed_retry_seconds = 20,

  me_batch_yield_every     = 12,

  blacklist_path           = "blacklist.txt",
  config_path              = "autofulfill_config.lua",
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


local function hasMeaningfulData(v)
  if v == nil then return false end
  if type(v) == "table" then return next(v) ~= nil end
  if type(v) == "string" then return v ~= "" end
  return true
end

local function copyDefaults(dst, src)
  dst = dst or {}
  for k, v in pairs(src) do
    if dst[k] == nil then dst[k] = v end
  end
  return dst
end

local function unserial(s)
  if textutils and textutils.unserialise then return textutils.unserialise(s) end
  return nil
end

local function readLineDefault(prompt, default)
  if default ~= nil and tostring(default) ~= "" then
    write(prompt .. " [" .. tostring(default) .. "]: ")
  else
    write(prompt .. ": ")
  end
  local s = trim(read())
  if s == "" then return default end
  return s
end

local function readNumber(prompt, default)
  while true do
    local s = readLineDefault(prompt, default)
    local n = tonumber(s)
    if n then return math.floor(n) end
    print("Please enter a number.")
  end
end

local function readBool(prompt, default)
  local d = default and "y" or "n"
  while true do
    local s = lower(readLineDefault(prompt .. " (y/n)", d))
    if s == "y" or s == "yes" or s == "true" then return true end
    if s == "n" or s == "no" or s == "false" then return false end
    print("Please enter y or n.")
  end
end

local function saveConfig(cfg)
  local path = cfg.config_path or CONFIG.config_path or "autofulfill_config.lua"
  local h = fs.open(path, "w")
  if not h then error("could not write " .. path) end
  h.write("return ")
  h.write(serial(cfg))
  h.write("\n")
  h.close()
end

local function loadConfigFile(path)
  path = path or CONFIG.config_path or "autofulfill_config.lua"
  if fs.exists(path) then
    local ok, cfg = pcall(dofile, path)
    if ok and type(cfg) == "table" then return copyDefaults(cfg, CONFIG) end
    local h = fs.open(path, "r")
    local text = h and h.readAll() or nil
    if h then h.close() end
    local parsed = text and unserial(text)
    if type(parsed) == "table" then return copyDefaults(parsed, CONFIG) end
  end
  return nil
end

local function runSetup(existing)
  term.clear()
  term.setCursorPos(1, 1)
  print("Colony Autofulfill Setup")
  print("This fulfills colony requests into a Post Box/buffer via an ME Bridge.")
  print("")
  local cfg = copyDefaults(existing or {}, CONFIG)
  cfg.export_side = readLineDefault("ME Bridge export side/peripheral target", cfg.export_side)
  cfg.poll_seconds = readNumber("Poll seconds", cfg.poll_seconds)
  cfg.dashboard_seconds = readNumber("Dashboard refresh seconds", cfg.dashboard_seconds)
  cfg.chat_verbosity = readLineDefault("Chat verbosity: all, missing, off", cfg.chat_verbosity)
  cfg.craft_only_full_amount = readBool("Only export when full requested amount is available", cfg.craft_only_full_amount)
  cfg.domum_match_me_variant = readBool("Enable Domum Ornamentum component-aware matching", cfg.domum_match_me_variant)
  cfg.domum_require_components = readBool("Require Domum components instead of display-name fallback", cfg.domum_require_components)
  cfg.domum_disable_crafting = readBool("Disable AE crafting for Domum Ornamentum variants", cfg.domum_disable_crafting)
  cfg.domum_craft_plain_shapes = readBool("Allow AE crafting of untextured Domum base shapes", cfg.domum_craft_plain_shapes)
  cfg.verify_exports = readBool("Verify exports by checking AE stock before/after", cfg.verify_exports)
  cfg.domum_verify_exports = readBool("Always verify Domum Ornamentum exports", cfg.domum_verify_exports)
  cfg.verify_wait_seconds = readNumber("Verification wait tenths of a second", math.floor((tonumber(cfg.verify_wait_seconds) or 0.15) * 10)) / 10
  cfg.config_path = cfg.config_path or CONFIG.config_path or "autofulfill_config.lua"
  saveConfig(cfg)
  print("")
  print("Saved " .. cfg.config_path)
  print("Output target: " .. tostring(cfg.export_side))
  print("Poll seconds: " .. tostring(cfg.poll_seconds))
  print("Domum matching: " .. tostring(cfg.domum_match_me_variant))
  print("Export verification: " .. tostring(cfg.verify_exports))
  print("Press Enter to start.")
  read()
  return cfg
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

local function refreshMonitor()
  if monitor then return monitor end
  monitor = peripheral.find("monitor")
  return monitor
end

local args = { ... }
if args[1] == "setup" or args[1] == "--setup" then
  CONFIG = runSetup(loadConfigFile(CONFIG.config_path))
else
  local loaded = loadConfigFile(CONFIG.config_path)
  if loaded then CONFIG = loaded end
end

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
  unconfirmed        = 0,
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

local function looksLikeToolName(name)
  local s = shortName(name)
  for word in pairs(TOOL_WORDS) do
    if s:find(word) then return true end
  end
  return false
end

local function looksLikeToolRequest(alts)
  for _, alt in ipairs(alts or {}) do
    if looksLikeToolName(alt.name) then return true end
  end
  return false
end

local function hasToolAlternative(alts)
  -- MineColonies may offer tools/armor as acceptable alternatives for requests
  -- like "has a tool". Do not auto-ship those; this script cannot judge
  -- durability/enchantments/colony policy safely. The old robust build called
  -- this helper without defining it, which crashed startup before the first poll.
  return looksLikeToolRequest(alts)
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

local function sleepIfNeeded(counter)
  if CONFIG.me_batch_yield_every and CONFIG.me_batch_yield_every > 0 then
    if counter and counter > 0 and counter % CONFIG.me_batch_yield_every == 0 then sleep(0) end
  end
end

local function isDomumName(name)
  return type(name) == "string" and string.sub(name, 1, 17) == "domum_ornamentum:"
end

local function copyFilterField(dst, src, fromKey, toKey)
  if type(src) == "table" and hasMeaningfulData(src[fromKey]) then dst[toKey or fromKey] = src[fromKey] end
end

local function makeFilter(src)
  if type(src) == "string" then return { name = src } end
  local f = {}
  if type(src) == "table" then
    f.name = tostring(src.name or src.item or src.id or "")
    copyFilterField(f, src, "nbt")
    copyFilterField(f, src, "tag", "nbt")
    copyFilterField(f, src, "components")
    copyFilterField(f, src, "dataComponents", "components")
    copyFilterField(f, src, "data_components", "components")
    copyFilterField(f, src, "component_hash")
    copyFilterField(f, src, "fingerprint")
    if type(src.item) == "table" then
      if f.name == "" then f.name = tostring(src.item.name or src.item.id or "") end
      copyFilterField(f, src.item, "nbt")
      copyFilterField(f, src.item, "tag", "nbt")
      copyFilterField(f, src.item, "components")
      copyFilterField(f, src.item, "dataComponents", "components")
      copyFilterField(f, src.item, "data_components", "components")
      copyFilterField(f, src.item, "component_hash")
      copyFilterField(f, src.item, "fingerprint")
    end
  end
  if f.name == "" then f.name = tostring(src or "") end
  return f
end

local function filterName(filter)
  if type(filter) == "table" then return tostring(filter.name or "") end
  return tostring(filter or "")
end

local function opFilter(filter)
  local f = {}
  for k, v in pairs(makeFilter(filter)) do
    if string.sub(tostring(k), 1, 1) ~= "_" then f[k] = v end
  end
  return f
end

local function filterWithCount(filter, count)
  local f = opFilter(filter)
  f.count = count
  return f
end

local function filterIdentity(filter)
  if type(filter) == "table" and filter._identity then return filter._identity end
  local f = makeFilter(filter)
  if hasMeaningfulData(f.fingerprint) then return "fp:" .. tostring(f.fingerprint) end
  if hasMeaningfulData(f.components) then return "cmp:" .. filterName(f) .. ":" .. serial(f.components) end
  if hasMeaningfulData(f.nbt) then return "nbt:" .. filterName(f) .. ":" .. serial(f.nbt) end
  return filterName(f)
end

local function filterLabel(filter)
  local f = makeFilter(filter)
  local s = filterName(f)
  if f._mode == "domum-plain-shape" then s = s .. " [plain-shape]"
  elseif f._mode == "domum-colony-components" then s = s .. " [colony-components]"
  elseif f._mode == "domum-exact-fp" then s = s .. " [me-fp]"
  elseif f._mode == "domum-exact-components" then s = s .. " [me-components]"
  elseif f._mode == "domum-request-fp" then s = s .. " [request-fp]"
  elseif f._mode == "domum-exact-name-selected" then s = s .. " [single-variant]"
  elseif hasMeaningfulData(f.components) then s = s .. " [components]"
  elseif hasMeaningfulData(f.nbt) then s = s .. " [nbt]"
  elseif hasMeaningfulData(f.fingerprint) then s = s .. " [fingerprint]" end
  return s
end

local function resultCount(result)
  if type(result) == "number" then return result end
  if type(result) == "table" then
    local n = tonumber(firstField(result, { "count", "amount", "exported", "transferred", "qty", "quantity", "moved" }, 0)) or 0
    if n > 0 then return n end
  end
  return 0
end

local function resultClaimsSuccess(result)
  if type(result) == "boolean" then return result end
  if type(result) == "table" then return firstField(result, { "ok", "success", "successful" }, false) and true or false end
  if type(result) == "number" then return result > 0 end
  return false
end

local function rawResultLabel(result)
  if type(result) == "table" then return serial(result) end
  return tostring(result)
end

local function getStock(filter)
  local ok, info = call(me, { "getItem", "get_item" }, opFilter(filter))
  if not ok or not info then return 0, false end
  if type(info) == "number" then return info, false end
  if type(info) ~= "table" then return 0, false end
  local count = tonumber(firstField(info, { "count", "amount", "qty", "quantity" }, 0)) or 0
  local craftable = firstField(info, { "isCraftable", "craftable", "is_craftable" }, false) and true or false
  return count, craftable
end


local function shouldVerifyExport(filter)
  local name = filterName(filter)
  return CONFIG.verify_exports or (CONFIG.domum_verify_exports and isDomumName(name))
end

local function isCraftable(filter, stockFlag)
  if stockFlag then return true end
  local ok, result = call(me, { "isItemCraftable", "is_item_craftable", "isCraftable" }, opFilter(filter))
  if ok then return result and true or false end
  return false
end

local function alreadyCrafting(filter)
  local key = filterIdentity(filter)
  local expiry = state.crafting[key]
  if expiry and nowMs() < expiry then return true end
  state.crafting[key] = nil

  local ok, busy = call(me, { "isItemCrafting", "is_item_crafting", "isCrafting" }, opFilter(filter))
  if ok then return busy and true or false end
  return false
end

local function exportItem(filter, count)
  count = clampCount(count, CONFIG.max_export_stack)
  local verify = shouldVerifyExport(filter)
  local before = nil
  if verify then before = getStock(filter) end

  local ok, result, _, _, method = call(me, { "exportItem", "export_item" }, filterWithCount(filter, count), CONFIG.export_side)
  if not ok then return 0, tostring(result), false end

  local claimed = resultCount(result)
  if claimed <= 0 and resultClaimsSuccess(result) and not verify then claimed = count end

  if verify then
    if CONFIG.verify_wait_seconds and CONFIG.verify_wait_seconds > 0 then sleep(CONFIG.verify_wait_seconds) end
    local after = getStock(filter)
    local moved = 0
    if before and after and before > after then moved = math.min(count, before - after) end
    if moved > 0 then return moved, nil, true end

    local raw = rawResultLabel(result)
    if resultClaimsSuccess(result) or claimed > 0 then
      return 0, ("unconfirmed %s export via %s; AE before/after %s/%s; bridge returned %s"):format(filterLabel(filter), tostring(method), tostring(before), tostring(after), raw), false
    end
    return 0, ("no movement via %s; AE before/after %s/%s; bridge returned %s"):format(tostring(method), tostring(before), tostring(after), raw), false
  end

  if claimed > 0 then return claimed, nil, false end
  return 0, "unexpected " .. tostring(method) .. " result: " .. rawResultLabel(result), false
end

local function craftItem(filter, count)
  count = clampCount(count, CONFIG.max_craft_batch)
  local ok, result = call(me, { "craftItem", "craft_item" }, filterWithCount(filter, count))
  if not ok then return false, tostring(result) end
  if result == false or result == nil then return false, tostring(result) end
  return true, result
end

local function getComponentsFrom(x)
  if type(x) ~= "table" then return nil end
  if type(x.components) == "table" then return x.components end
  if type(x.dataComponents) == "table" then return x.dataComponents end
  if type(x.data_components) == "table" then return x.data_components end
  if type(x.item) == "table" then
    if type(x.item.components) == "table" then return x.item.components end
    if type(x.item.dataComponents) == "table" then return x.item.dataComponents end
    if type(x.item.data_components) == "table" then return x.item.data_components end
  end
  return nil
end

local function textureDataOf(components)
  if type(components) ~= "table" then return nil end
  return components["domum_ornamentum:texture_data"]
      or components["domum_ornamentum:texture"]
      or components.texture_data
      or components.textureData
end

local function blockStateOf(components)
  if type(components) ~= "table" then return nil end
  return components["minecraft:block_state"] or components.block_state or components.blockState
end

local function domumComponentsMatch(resourceComponents, variantComponents)
  local wantTex, haveTex = textureDataOf(resourceComponents), textureDataOf(variantComponents)
  if hasMeaningfulData(wantTex) or hasMeaningfulData(haveTex) then
    return serial(wantTex) == serial(haveTex)
  end
  local wantState, haveState = blockStateOf(resourceComponents), blockStateOf(variantComponents)
  if hasMeaningfulData(wantState) or hasMeaningfulData(haveState) then
    return serial(wantState) == serial(haveState)
  end
  return serial(resourceComponents) == serial(variantComponents)
end

local function getItemVariantsByName(name)
  local variants = {}
  local ok, result = call(me, { "getItems", "get_items", "listItems", "list_items" }, { name = name })
  if ok and type(result) == "table" then
    if type(result.items) == "table" then result = result.items end
    for _, v in pairs(result) do
      if type(v) == "table" and (v.name or v.displayName or v.count or v.fingerprint or v.components) then
        if tostring(v.name or name) == name or not v.name then
          if not v.name then v.name = name end
          table.insert(variants, v)
        end
      end
    end
  end
  return variants
end


local function domumPlainShapeFilter(resource)
  local f = makeFilter(resource)
  if not isDomumName(filterName(f)) then return nil end
  f.components = nil
  f.dataComponents = nil
  f.data_components = nil
  f.nbt = nil
  f.fingerprint = nil
  f.component_hash = nil
  f._mode = "domum-plain-shape"
  f._identity = "domum-shape:" .. filterName(f)
  return f
end

local function findDomumVariant(resource)
  local base = makeFilter(resource)
  local name = filterName(base)
  local wantComponents = getComponentsFrom(resource) or base.components
  local variants = getItemVariantsByName(name)
  if not hasMeaningfulData(wantComponents) then
    if hasMeaningfulData(base.fingerprint) then
      for _, v in ipairs(variants) do
        if tostring(v.fingerprint or "") == tostring(base.fingerprint) then return v, variants, "fingerprint" end
      end
      return nil, variants, "request has fingerprint but no matching AE2 variant fingerprint"
    end
    return nil, variants, "request has no Domum components or fingerprint; display name ignored for Domum safety"
  end
  local matches = {}
  for _, v in ipairs(variants) do
    if domumComponentsMatch(wantComponents, getComponentsFrom(v)) then table.insert(matches, v) end
  end
  if #matches == 0 then return nil, variants, "no AE2 variant with matching Domum texture components" end
  table.sort(matches, function(a, b) return (tonumber(a.count) or 0) > (tonumber(b.count) or 0) end)
  return matches[1], variants, "components"
end

local function domumVariantFilter(variant, mode)
  local f = makeFilter(variant)
  if mode == "components" and hasMeaningfulData(f.components) then f._mode = "domum-exact-components"; return f end
  if mode == "fingerprint" and hasMeaningfulData(f.fingerprint) then f._mode = "domum-exact-fp"; return f end
  f.components = nil; f.fingerprint = nil; f.component_hash = nil; f.nbt = nil; f._mode = "domum-exact-name-selected"; return f
end

local function domumResourceComponentFilter(resource, baseFilter)
  local comps = getComponentsFrom(resource) or (type(baseFilter) == "table" and baseFilter.components)
  if not hasMeaningfulData(comps) then return nil end
  return { name = filterName(baseFilter), components = comps, _mode = "domum-colony-components", _identity = "domum-cmp:" .. filterName(baseFilter) .. ":" .. serial(comps) }
end

local function domumResourceFingerprintFilter(resource, baseFilter)
  local fp = nil
  if type(resource) == "table" then
    fp = resource.fingerprint or (type(resource.item) == "table" and resource.item.fingerprint)
  end
  fp = fp or (type(baseFilter) == "table" and baseFilter.fingerprint)
  if not hasMeaningfulData(fp) then return nil end
  return { name = filterName(baseFilter), fingerprint = tostring(fp), _mode = "domum-request-fp", _identity = "domum-fp:" .. filterName(baseFilter) .. ":" .. tostring(fp) }
end

local function exportDomum(resource, desired)
  local base = makeFilter(resource)
  local directFp = domumResourceFingerprintFilter(resource, base)
  if directFp then
    local exported, err = exportItem(directFp, desired)
    if exported and exported > 0 then return exported, nil, directFp end
  end
  local direct = domumResourceComponentFilter(resource, base)
  if direct then
    local exported, err = exportItem(direct, desired)
    if exported and exported > 0 then return exported, nil, direct end
  end
  local variant, variants, why = findDomumVariant(resource)
  if not variant then return 0, why or "no matching Domum variant" end
  local f = domumVariantFilter(variant, "components")
  local exported, err = exportItem(f, desired)
  if exported and exported > 0 then return exported, nil, f end
  f = domumVariantFilter(variant, "fingerprint")
  exported, err = exportItem(f, desired)
  if exported and exported > 0 then return exported, nil, f end
  if CONFIG.domum_require_components then return 0, err or "matching Domum variant could not be exported" end
  f = domumVariantFilter(variant, "name")
  exported, err = exportItem(f, desired)
  if exported and exported > 0 then return exported, nil, f end
  return 0, err or "matching Domum variant could not be exported"
end

-- ---------- cooldowns ----------
local function purgeExpiring(map)
  local now = nowMs()
  for k, expiry in pairs(map) do
    if type(expiry) == "number" and now >= expiry then map[k] = nil end
  end
end

local function onAnyCooldown(reqKey, filter)
  local key = filterIdentity(filter)
  local now = nowMs()
  if state.request_item_cd[reqKey .. "|" .. key] and now < state.request_item_cd[reqKey .. "|" .. key] then return true end
  if CONFIG.item_cooldown and CONFIG.item_cooldown > 0 and state.item_cd[key] and now < state.item_cd[key] then return true end
  return false
end

local function markHandled(reqKey, filter)
  local key = filterIdentity(filter)
  local now = nowMs()
  state.handled[reqKey] = now + CONFIG.dedupe_ttl * 1000
  state.request_item_cd[reqKey .. "|" .. key] = now + CONFIG.request_item_cooldown * 1000
  if CONFIG.item_cooldown and CONFIG.item_cooldown > 0 then
    state.item_cd[key] = now + CONFIG.item_cooldown * 1000
  end
end

-- ---------- fulfillment ----------
local function chooseAlternative(req, alts, reqKey)
  if hasToolAlternative(alts) then return "blocked" end

  local stocked, craftables = {}, {}
  local sawUsable, skippedByCooldown = false, false

  for _, alt in ipairs(alts or {}) do
    if alt.name and not isBlacklisted(alt) then
      local filter = makeFilter(alt)
      local name = filterName(filter)
      if onAnyCooldown(reqKey, filter) then
        skippedByCooldown = true
      elseif CONFIG.domum_match_me_variant and isDomumName(name) then
        -- Domum stored variants are component-bearing custom blocks. The Architects
        -- Cutter recipes themselves output the plain Domum block id; material
        -- choices are cutter inputs, not part of the recipe JSON. So stocked
        -- variants need exact component/fingerprint export, but AE crafting must
        -- target the uncomponented shape id.
        local variant, variants = findDomumVariant(alt)
        if variant then
          sawUsable = true
          table.insert(stocked, { filter = filter, resource = alt, stock = tonumber(variant.count or variant.amount) or requestCount(req), score = lowValueScore(name) + 1000, domum = true })
        elseif CONFIG.domum_craft_plain_shapes then
          local plain = domumPlainShapeFilter(filter)
          local stock, stockCraftable = getStock(plain)
          local craftable = isCraftable(plain, stockCraftable)
          if stock > 0 or craftable then sawUsable = true end
          if stock > 0 then table.insert(stocked, { filter = plain, resource = alt, stock = stock, score = lowValueScore(name) + 900 }) end
          if craftable then table.insert(craftables, { filter = plain, resource = alt, score = lowValueScore(name) + 900, domum_plain = true }) end
        end
      else
        local stock, stockCraftable = getStock(filter)
        local craftable = isCraftable(filter, stockCraftable)
        if stock > 0 or craftable then sawUsable = true end

        local score = lowValueScore(name)
        if stock > 0 then
          table.insert(stocked, { filter = filter, resource = alt, stock = stock, score = score })
        end
        if craftable then
          table.insert(craftables, { filter = filter, resource = alt, score = score })
        end
      end
    end
  end

  if #stocked > 0 then
    table.sort(stocked, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      return a.stock > b.stock
    end)
    return "stock", stocked[1]
  end

  if #craftables > 0 then
    table.sort(craftables, function(a, b) return a.score > b.score end)
    return "craft", craftables[1]
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

  local kind, choice = chooseAlternative(req, alts, key)

  if kind == "stock" then
    local filter = choice.filter
    local label = filterLabel(filter)
    local name = filterName(filter)
    local exported, err, usedFilter
    if choice.domum and CONFIG.domum_match_me_variant then
      exported, err, usedFilter = exportDomum(choice.resource or filter, math.min(desired, CONFIG.max_export_stack))
      if usedFilter then filter = usedFilter; label = filterLabel(filter) end
    else
      local stock = getStock(filter)
      local toSend = math.min(desired, stock, CONFIG.max_export_stack)
      if CONFIG.craft_only_full_amount and stock < desired then return end
      exported, err = exportItem(filter, toSend)
    end
    if exported and exported > 0 then
      state.fulfilled = state.fulfilled + 1
      markHandled(key, filter)
      log(("EXPORT %dx %s -> %s (%s)"):format(exported, label, target, desc), "info")
    else
      local msg = err or "buffer full, no stock movement, or bridge refused"
      if tostring(msg):find("unconfirmed", 1, true) then
        state.unconfirmed = state.unconfirmed + 1
        if CONFIG.unconfirmed_retry_seconds and CONFIG.unconfirmed_retry_seconds > 0 then
          state.request_item_cd[key .. "|" .. filterIdentity(filter)] = nowMs() + CONFIG.unconfirmed_retry_seconds * 1000
        end
        logThrottled(state.error_seen, "unconfirmed:" .. name, CONFIG.error_log_ttl, ("EXPORT UNCONFIRMED %s (%s)"):format(label, msg), "missing")
      else
        rememberError("export:" .. name, ("EXPORT FAILED %s (%s)"):format(label, msg))
      end
    end
    return
  end

  if kind == "craft" then
    local filter = choice.filter
    local label = filterLabel(filter)
    local name = filterName(filter)
    if CONFIG.domum_disable_crafting and isDomumName(name) and not (filter and filter._mode == "domum-plain-shape") then
      state.deferred = state.deferred + 1
      return
    end
    if alreadyCrafting(filter) then
      state.deferred = state.deferred + 1
      return
    end
    local ok, err = craftItem(filter, desired)
    if ok then
      state.crafting[filterIdentity(filter)] = now + (CONFIG.request_item_cooldown * 1000)
      state.scheduled = state.scheduled + 1
      markHandled(key, filter)
      log(("CRAFT %dx %s for %s (%s)"):format(desired, label, target, desc), "info")
    else
      rememberError("craft:" .. name, ("CRAFT FAILED %s (%s)"):format(label, err or "bridge refused"))
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
  if not refreshMonitor() then return end
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
  setColor(colors.yellow);    writeAt(2, 12, ("Unconfirm: %d"):format(state.unconfirmed))
  setColor(state.last_poll_ok and colors.lime or colors.red)
  writeAt(2, 13, "Poll:      " .. (state.last_poll_ok and "ok" or "failed"))

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

parallel.waitForAll(supervised("fulfill", fulfillLoop), supervised("dashboard", dashboardLoop))
