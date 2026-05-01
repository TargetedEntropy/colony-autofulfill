-- One-shot installer. Wgets the latest startup.lua, blacklist.txt,
-- and probe.lua from the repo into the current directory.
--
-- Usage on the CC computer:
--   wget https://raw.githubusercontent.com/TargetedEntropy/colony-autofulfill/robust-autofulfill/install.lua install.lua
--   install.lua

local BASE = "https://raw.githubusercontent.com/TargetedEntropy/colony-autofulfill/robust-autofulfill/"
local FILES = { "startup.lua", "blacklist.txt", "probe.lua" }

for _, f in ipairs(FILES) do
  if fs.exists(f) then
    print("Removing existing " .. f)
    fs.delete(f)
  end
  print("Fetching " .. f)
  shell.run("wget", BASE .. f, f)
end

print("\n========================================")
print("Installed:")
for _, f in ipairs(FILES) do
  print("  " .. f .. (fs.exists(f) and "" or "  [MISSING — wget failed]"))
end
print("========================================")
print("Edit blacklist.txt to taste, then `reboot` to start.")
print("Run `probe.lua` instead of rebooting if you want to dump the API surface first.")
