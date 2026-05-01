# colony-autofulfill

ComputerCraft scripts for running a MineColonies colony from a wall of monitors. Three independent scripts, one per CC computer:

1. **`startup.lua`** — auto-fulfills colony requests from your AE2 network (with a reloadable blacklist).
2. **`requests-display.lua`** — paginated live view of every open request on a 5x5 monitor.
3. **`buildings-display.lua`** — list of every building with level, style, and position on a 5x5 monitor.

All three target **Advanced Peripherals** (Colony Integrator + ME Bridge for the fulfillment, Colony Integrator only for the displays). Tested against the snake_case peripheral types (`colony_integrator` / `me_bridge`) used in current AP versions; older camelCase names are tried as fallback.

## Hardware

- 1× Advanced Computer
- 1× Colony Integrator — placed **inside the colony's claimed border**
- 1× ME Bridge — touching AE2 cable, with FE/RF power
- 9× Advanced Monitor in a 3x3 grid (optional but strongly recommended)
- 1× pair of wireless connectors if your AE2 base is far from the colony
- 1× buffer chest on one face of the ME Bridge with a hopper feeding into a MineColonies **Post Box**
- Optional: Chat Box for in-game alerts on missing items

All peripherals can sit direct-adjacent to the computer (no modems required), or be networked via wired modems if you need to spread them out. The script auto-discovers peripherals by type — no name configuration.

## Install

Each script runs on its own CC computer.

### Auto-fulfill computer (needs ME Bridge + Colony Integrator)

```
wget https://raw.githubusercontent.com/TargetedEntropy/colony-autofulfill/robust-autofulfill/install.lua install.lua
install.lua
reboot
```

That installs `startup.lua`, `blacklist.txt`, and `probe.lua`.

### Requests display computer (needs Colony Integrator + 5x5 monitor)

```
wget https://raw.githubusercontent.com/TargetedEntropy/colony-autofulfill/robust-autofulfill/requests-display.lua startup.lua
reboot
```

### Buildings display computer (needs Colony Integrator + 5x5 monitor)

```
wget https://raw.githubusercontent.com/TargetedEntropy/colony-autofulfill/robust-autofulfill/buildings-display.lua startup.lua
reboot
```


## Robust auto-fulfill branch notes

The `robust-autofulfill` branch keeps the same basic loop — read MineColonies requests, choose an AE2 alternative, export stocked items, schedule crafts, and display status — but hardens the fulfillment computer against the common ways these peripherals fail:

- tolerant handling for several Advanced Peripherals method/return shapes (`exportItem`, `craftItem`, `isItemCrafting`, etc.)
- fallback request fingerprints when MineColonies does not expose stable request ids
- request+item cooldowns instead of a broad global item cooldown by default, so two builders can request the same common item without starving each other
- throttled missing/error logs so chat and monitors do not drown during an outage
- safer export/craft count limits
- smarter alternative choice: tools prefer better tiers, generic materials prefer abundant/low-value stock and avoid spending valuable gear unless you explicitly allow it
- inline comments in `blacklist.txt` are accepted

Main tuning keys in `startup.lua`: `dedupe_ttl`, `request_item_cooldown`, `item_cooldown`, `max_export_stack`, `max_craft_batch`, and `missing_log_ttl`.

## Configuration (auto-fulfill)

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

## Displays

### Requests display

Polls `colony.getRequests()` every 5 seconds. Renders a paginated table:

```
== ColonyName — Open Requests ==
Total: 23   Updated: 12:31:08

TARGET                  ITEM                              CNT   STATE
Builder Duran W. Good.  1 Stone Bricks                    1     IN_PROGRESS
Waiter Zain M. Goseb.   Fuel                              128   IN_PROGRESS
Farmer Reyansh B. Cou.  1-64 Durum Wheat                  64    IN_PROGRESS
...

Page 1 / 2
```

State is color-coded: orange = `REQUESTED`, yellow = `IN_PROGRESS`, lime = `IN_DELIVERY`, red = `FAILED`. Pages auto-rotate every 8 seconds.

### Buildings display

Polls `colony.getBuildings()` every 30 seconds:

```
== ColonyName — Buildings ==
Total: 23   Updated: 12:31:08

BUILDING            LEVEL    STYLE        POS
Town Hall           5 / 5    frontier     (123, 64, -45)
Builder             3 / 5    frontier     (130, 64, -42)
Builder             2 / 5    frontier     (135, 64, -42)
Tavern              4 / 5    frontier     (140, 64, -45)
University          3 / 5    frontier     (115, 64, -55)
...
```

Level is color-coded: maxed = lime, ≥60% = green, ≥30% = yellow, lower = orange.

> **Note:** `getBuildings()` shape isn't documented for AP. The script tries multiple field names (`name`/`type`/`id`, `level`/`currentLevel`, etc.) and falls back gracefully. On its first poll it dumps the first 2 building entries to `buildings-shape.txt` on the computer — if column values come back blank or wrong, paste that file back so the script can be patched.

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
