# colony-autofulfill

A ComputerCraft script that auto-fulfills MineColonies requests from an AE2 network. Polls the colony, exports stocked items into a Post Box buffer, schedules autocrafts when patterns exist, and shows a live dashboard on a monitor.

Targets **Advanced Peripherals** (Colony Integrator + ME Bridge). Tested against the snake_case peripheral types (`colony_integrator` / `me_bridge`) used in current AP versions; older camelCase names are tried as fallback.

## Hardware

- 1× Advanced Computer
- 1× Colony Integrator — placed **inside the colony's claimed border**
- 1× ME Bridge — touching AE2 cable, with FE/RF power
- 9× Advanced Monitor in a 3x3 grid (optional but strongly recommended)
- 1× pair of wireless connectors if your AE2 base is far from the colony
- 1× buffer chest on one face of the ME Bridge with a hopper feeding into a MineColonies **Post Box**
- Optional: Chat Box for in-game alerts on missing items

All peripherals can sit direct-adjacent to the computer (no modems required), or be networked via wired modems if you need to spread them out. The script auto-discovers peripherals by type — no name configuration.

## Install (on the CC computer)

```
wget https://raw.githubusercontent.com/TargetedEntropy/colony-autofulfill/main/install.lua install.lua
install.lua
reboot
```

That installs `startup.lua`, `blacklist.txt`, and `probe.lua` into the root of the computer. After reboot it runs as a startup task.

## Configuration

Open `startup.lua`, scroll to the `CONFIG` table at the top:

| key                  | default      | meaning |
|----------------------|--------------|---------|
| `export_side`        | `"north"`    | Face of the ME Bridge that points at the buffer chest. One of `top`/`bottom`/`north`/`south`/`east`/`west`. |
| `poll_seconds`       | `15`         | How often to poll `colony.getRequests()`. |
| `dashboard_seconds`  | `2`          | Monitor refresh rate. |
| `chat_verbosity`     | `"missing"`  | `"all"` shouts every export to chat; `"missing"` only when nothing satisfies a request; `"off"` silences chat. |
| `dedupe_ttl`         | `60`         | Seconds to ignore a specific `req.id` after we ship it. |
| `item_cooldown`      | `120`        | Seconds to ignore _any_ request for a given item after we last shipped that item. **The main lever for tuning duplicate shipments** — see Tuning below. |
| `loop_restart_delay` | `5`          | Pause before restarting a crashed loop. |
| `blacklist_path`     | `"blacklist.txt"` | Where to read the blacklist from. |

## Blacklist

`blacklist.txt` lists items that should **never** be exported, even when a MineColonies request lists them as an acceptable alternative. The classic case: a smelter requests "any smeltable ore" — without a blacklist, your 1.2M ancient debris ships in chunks of 64 until it's gone.

Format:
```
# Comments and blank lines ignored
minecraft:ancient_debris            # exact item ID
minecraft:netherite_ingot
tag:c:ores/netherite_scrap          # match by tag (with or without "minecraft:item/" prefix)
```

The file is **reloaded automatically every poll cycle** — edit and save while the script is running, no reboot needed. The script logs `blacklist loaded: N items, M tags` whenever it picks up a change.

Default blacklist covers the netherite chain + diamond/diamond_block. Extend as needed.

## Dashboard

```
== ColonyName ==

Citizens: 17 / 17
Happy:    6.4 / 10        (color-coded: red <5, yellow <7, green ≥7)

Pending:    12            (open colony requests this poll)
Filled:    347            (cumulative successful exports)
Crafts:     12            (cumulative autocrafts scheduled)
In flight:   8            (this poll: requests skipped — same item still on cooldown)
Blocked:     3            (this poll: requests with all alternatives blacklisted)
Missing:    21            (cumulative requests we couldn't fulfill at all)

Recent:
  12:04:31 EXPORT 64x minecraft:coal -> Waiter Zain M. (Fuel)
  12:04:30 CRAFT 16x minecraft:stick for Builder Duran W. (Sticks)
  ...
```

A healthy colony has Pending → Filled climbing through the day, with In-flight rising and falling each cycle as cooldowns expire. Sustained nonzero **Missing** means you're short on stock + autocraft pattern for something — search the recent log for what.

## Tuning `item_cooldown`

This is the lever that controls duplicate shipments. After exporting `minecraft:stone_bricks`, the script ignores any further request for stone bricks for `item_cooldown` seconds. Reason: MineColonies opens a separate request per outstanding unit, all visible in `getRequests()` at once, and they remain open until the courier has actually delivered.

- **Too low** (< hopper + courier round trip): you'll see your buffer chest pile up with the same item, then once the courier finally syncs, MineColonies thinks it has way more than it asked for.
- **Too high**: when the colony genuinely needs more, it waits longer than necessary.

Default 120s works for most setups. If your buffer chest still piles up, raise to 180–240. If your colony seems starved waiting for refills, lower to 90.

## Diagnostics

`probe.lua` is a one-shot script that dumps the actual peripheral API surface for your AP version, samples a few real `getRequests` entries, and uploads everything to a paste service so you can read it from a browser. Useful when something behaves unexpectedly:

```
probe.lua
```

It writes `probe-output.txt` locally and prints a paste.rs URL at the end.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Asserts on startup with "Colony Integrator not found" | Block is outside the colony border, or no peripheral connection (modem not active, or block not adjacent to computer). |
| Asserts with "ME Bridge not found" | Bridge isn't networked to AE2, isn't powered (needs FE/RF on top of AE2 channel), or isn't connected to the computer. |
| Dashboard shows "Filled: 0" but Pending climbs | `export_side` doesn't match your buffer chest. Check faces. |
| Same item ships repeatedly, buffer overflows | `item_cooldown` is too low. Bump it. |
| `Missing` keeps climbing for one item | No stock + no autocraft pattern. Add a pattern, or accept manual fulfillment. |
| Monitor stays blank | All 9 monitor blocks must be Advanced Monitors and form a contiguous 3x3 grid. Break and replace until seam lines disappear. |
