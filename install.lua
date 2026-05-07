-- One-shot installer. Wgets the latest startup.lua, blacklist.txt,
-- and probe.lua from the repo into the current directory.
--
-- Usage on the CC computer:
--   wget https://raw.githubusercontent.com/TargetedEntropy/colony-autofulfill/main/install.lua install.lua
--   install.lua

local BASE = "https://raw.githubusercontent.com/TargetedEntropy/colony-autofulfill/main/"
local FILES = { "startup.lua", "blacklist.txt", "probe.lua" }

for _, f in ipairs(FILES) do
  if fs.exists(f) then
    print("Removing existing " .. f)
    fs.delete(f)
  end
  print("Fetching " .. f)
  shell.run("wget", BASE .. f, f)
end

print("")
print("========================================")
print("Installed:")
for _, f in ipairs(FILES) do
  print("  " .. f .. (fs.exists(f) and "" or "  [MISSING - wget failed]"))
end
print("========================================")
print("Run `startup setup` to choose ME export side and other options.")
print("Then edit blacklist.txt to taste and `reboot` to start.")
print("Run `probe.lua` if you want to dump the AP API surface first.")
