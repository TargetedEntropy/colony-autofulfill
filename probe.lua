-- ============================================================
-- Probe script — runs once, dumps the things we couldn't verify
-- from docs alone. Auto-discovers Advanced Peripherals devices,
-- so no editing required. Just wget + run.
--
-- Output is captured + uploaded to paste.rs (HTTP-based, like
-- termbin but works over HTTP since CC has no raw TCP). The
-- paste URL is printed at the end. Also written to ./probe-output.txt
-- as a local fallback in case the upload fails.
-- ============================================================

-- ---------- output capture ----------
local _print = print
local _buffer = {}
print = function(...)
  local parts = { ... }
  for i = 1, #parts do parts[i] = tostring(parts[i]) end
  table.insert(_buffer, table.concat(parts, "\t"))
  _print(...)
end

local function hr(label) print(("\n===== %s ====="):format(label)) end
local function dump(label, v)
  print(label .. ": " .. textutils.serialise(v, { compact = false }))
end

hr("peripherals attached")
for _, n in ipairs(peripheral.getNames()) do
  print(("  %s -> %s"):format(n, peripheral.getType(n)))
end

-- Try the common AP type names; some versions vary capitalization.
local function findAny(types)
  for _, t in ipairs(types) do
    local p = peripheral.find(t)
    if p then return p, t end
  end
  return nil
end

local colony, colonyType = findAny({ "colonyIntegrator", "colony_integrator", "colony" })
local me,     meType     = findAny({ "meBridge", "me_bridge" })

print("\nresolved colony peripheral type: " .. tostring(colonyType))
print("resolved ME bridge peripheral type: " .. tostring(meType))

if not colony then
  print("\n!! Colony Integrator not found. Make sure the block is placed INSIDE the colony border, has a wired modem attached + activated, and is wired to the computer.")
end
if not me then
  print("\n!! ME Bridge not found. Make sure it's adjacent to AE2 cable, powered, has a wired modem attached + activated, and is wired to the computer.")
end
if not colony or not me then
  print("\nProbe cannot continue without both. Paste the 'peripherals attached' list above so we can see what types are actually exposed.")
  return
end

hr("colony method surface")
for _, m in ipairs({
  "getColonyName", "amountOfCitizens", "maxOfCitizens",
  "getHappiness", "getRequests", "isUnderAttack",
  "getCitizens", "getBuildings",
}) do
  print(("  %s: %s"):format(m, type(colony[m])))
end

hr("colony scalar values")
local function safe(fn) local ok, v = pcall(fn); return ok and v or ("ERR: "..tostring(v)) end
print("  name:     " .. tostring(safe(colony.getColonyName)))
print("  citizens: " .. tostring(safe(colony.amountOfCitizens)) .. " / " .. tostring(safe(colony.maxOfCitizens)))
print("  happy:    " .. tostring(safe(colony.getHappiness)))

hr("first 3 requests (full shape)")
local ok, requests = pcall(colony.getRequests)
if not ok then
  print("  getRequests ERROR: " .. tostring(requests))
elseif #requests == 0 then
  print("  (no open requests right now — go open a build menu or hire a worker so the colony asks for something, then re-run)")
else
  print(("  total: %d"):format(#requests))
  for i = 1, math.min(3, #requests) do
    dump("  req " .. i, requests[i])
  end
end

hr("ME bridge — ALL methods exposed")
local meMethods = peripheral.getMethods(peripheral.getName(me)) or {}
table.sort(meMethods)
for _, m in ipairs(meMethods) do print("  " .. m) end

local function tryCall(label, fn, ...)
  local args = { ... }
  local ok, res = pcall(function() return fn(table.unpack(args)) end)
  if ok then dump("  " .. label, res)
  else      print("  " .. label .. " ERROR: " .. tostring(res)) end
  return ok, res
end

hr("ME getItem shape (cobblestone probe)")
if me.getItem then tryCall("getItem", me.getItem, { name = "minecraft:cobblestone" })
else print("  getItem: NOT EXPOSED") end

hr("ME listItems / getItems sample (first 2)")
local items
for _, methodName in ipairs({ "listItems", "getItems", "items", "listItem" }) do
  if me[methodName] then
    local ok, res = pcall(me[methodName])
    if ok and type(res) == "table" then
      items = res
      print(("  via %s — total stacks: %d"):format(methodName, #items))
      break
    else
      print(("  %s exists but call failed: %s"):format(methodName, tostring(res)))
    end
  end
end
if items then
  for i = 1, math.min(2, #items) do dump("  item " .. i, items[i]) end
else
  print("  (no working list-items method found — paste the method surface above)")
end

hr("craftable sample (first 2)")
local craftable
for _, methodName in ipairs({ "getCraftableItems", "listCraftableItems", "getCraftable" }) do
  if me[methodName] then
    local ok, res = pcall(me[methodName])
    if ok and type(res) == "table" then
      craftable = res
      print(("  via %s — total craftable: %d"):format(methodName, #craftable))
      break
    end
  end
end
if craftable then
  for i = 1, math.min(2, #craftable) do dump("  craftable " .. i, craftable[i]) end
else
  print("  (no working craftable-list method found)")
end

hr("isItemCrafting return shape")
if me.isItemCrafting then
  tryCall("isItemCrafting", me.isItemCrafting, { name = "minecraft:cobblestone" })
else
  print("  isItemCrafting: NOT EXPOSED")
end

print("\nProbe complete.")

-- ---------- save + upload ----------
local body = table.concat(_buffer, "\n")

-- Save locally first as a fallback.
local f = fs.open("probe-output.txt", "w")
if f then f.write(body) f.close() end

local function tryPaste(url, contentType)
  local h, err = http.post(url, body, { ["Content-Type"] = contentType or "text/plain" })
  if not h then return nil, tostring(err) end
  local response = h.readAll()
  h.close()
  return response and response:gsub("%s+$", "")
end

_print("\n========================================")
_print("Local copy: probe-output.txt")

local pasteUrl, err = tryPaste("https://paste.rs/", "text/plain")
if pasteUrl and pasteUrl:match("^https?://") then
  _print("Uploaded to: " .. pasteUrl)
else
  _print("paste.rs upload failed: " .. tostring(err or pasteUrl))
  -- Fallback: 0x0.st (different format but often works when paste.rs blips)
  local fallback, err2 = tryPaste("https://0x0.st/", "text/plain")
  if fallback and fallback:match("^https?://") then
    _print("Fallback uploaded to: " .. fallback)
  else
    _print("0x0.st also failed: " .. tostring(err2 or fallback))
    _print("Use `edit probe-output.txt` to view locally, or copy via floppy.")
  end
end
_print("========================================")
