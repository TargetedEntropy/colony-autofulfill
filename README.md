# colony-autofulfill

ComputerCraft scripts for running a MineColonies colony from a wall of monitors.

> **Heads up:** if you're running the **MineColonies Compatibility** addon ([gisellevonbingen-Minecraft/MineColonies_Compatibility](https://github.com/gisellevonbingen-Minecraft/MineColonies_Compatibility), CurseForge `minecolonies-compatibility`), it has **native AE2 / Refined Storage / Simple Storage / Create Stock Link integration** — couriers can pull from your storage network and trigger autocrafting directly. **That's the right answer for AE2 fulfillment**, and the auto-fulfill script in this repo is the workaround you'd build *without* that mod. See [Native AE2 fulfillment](#native-ae2-fulfillment-recommended) below before installing the script.

Three scripts, each on its own CC computer:

1. **`startup.lua`** — auto-fulfills colony requests from your AE2 network (with a reloadable blacklist). **Skip this if the compat mod's native integration covers you.**
2. **`requests-display.lua`** — paginated live view of every open request on a 5x5 monitor. Useful regardless of how requests get fulfilled.
3. **`buildings-display.lua`** — list of every building with level, style, and position on a 5x5 monitor. Same — independent of fulfillment method.

All three target **Advanced Peripherals** (Colony Integrator + ME Bridge for fulfillment, Colony Integrator only for the displays). Tested against snake_case peripheral types (`colony_integrator` / `me_bridge`); older camelCase names tried as fallback.

## Native AE2 fulfillment (recommended)

If you have **MineColonies Compatibility** installed, do this and skip `startup.lua` entirely:

1. **Craft an "ME Terminal for Colonist"** — it's an AE2 *cable bus part* (looks/installs like a regular ME Terminal). Recipe in JEI/EMI.
2. **Place it on AE2 cable inside your Warehouse building's footprint.** The cable must be part of your live AE2 network — extend cable from your main system into the Warehouse, optionally via a Wireless Connector pair.
3. **Open the Warehouse → "Network Storage" tab → click "Refresh."** The terminal should show up. That's the link.
4. **Autocrafting works automatically** — every AE2 pattern in the network is available to MineColonies' request system.

> **Critical gotcha:** the Warehouse must have been built (or rebuilt) **after** the compat mod was installed/updated. If "Network Storage" tab is missing or empty after Refresh, deconstruct the Warehouse and rebuild it.

The blacklist concern doesn't go away with the mod — if a smelter requests "any smeltable ore" and your network has 1.2M ancient debris, it ships. Mitigations: AE2 priority/security to wall off precious items into a sub-network the colony can't see, or run this repo's `startup.lua` *with cooldowns disabled and only the blacklist active* alongside the mod. Test before deciding.

## Display computers

The display scripts are useful no matter how fulfillment is set up.

### Requests display (Colony Integrator + 5x5 monitor)

```
wget https://raw.githubusercontent.com/TargetedEntropy/colony-autofulfill/main/requests-display.lua startup.lua
reboot
```

Paginated table of open colony requests, polled every 5s, page rotates every 8s:

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

State color-coded: orange = `REQUESTED`, yellow = `IN_PROGRESS`, lime = `IN_DELIVERY`, red = `FAILED`.

### Buildings display (Colony Integrator + 5x5 monitor)

```
wget https://raw.githubusercontent.com/TargetedEntropy/colony-autofulfill/main/buildings-display.lua startup.lua
reboot
```

```
== ColonyName — Buildings ==
Total: 23   Updated: 12:31:08

BUILDING            LEVEL    STYLE        POS
Town Hall           5 / 5    frontier     (123, 64, -45)
Builder             3 / 5    frontier     (130, 64, -42)
Tavern              4 / 5    frontier     (140, 64, -45)
University          3 / 5    frontier     (115, 64, -55)
...
```

Level color-coded: maxed = lime, ≥60% = green, ≥30% = yellow, lower = orange. Polls every 30s.

> `getBuildings()` shape isn't documented for AP. The script tries multiple field names defensively and dumps the first 2 entries to `buildings-shape.txt` on first poll — if columns look wrong, paste that file back.

## CC-driven auto-fulfill (fallback, no compat mod)

If you can't or don't want to use the native integration, this section is for you.

### Hardware

- 1× Advanced Computer
- 1× Colony Integrator — placed **inside the colony's claimed border**
- 1× ME Bridge — touching AE2 cable, with FE/RF power
- 9× Advanced Monitor in a 3x3 grid (optional but recommended)
- 1× pair of wireless connectors if your AE2 base is far from the colony
- 1× buffer chest on one face of the ME Bridge with a hopper (or modular router) feeding into a MineColonies **Post Box** *or* directly into the Warehouse
- Optional: Chat Box for in-game alerts on missing items

All peripherals can sit direct-adjacent to the computer (no modems required), or be networked via wired modems. The script auto-discovers peripherals by type — no name configuration.

### Install

```
wget https://raw.githubusercontent.com/TargetedEntropy/colony-autofulfill/main/install.lua install.lua
install.lua
reboot
```

Installs `startup.lua`, `blacklist.txt`, and `probe.lua`.

### Configuration

Open `startup.lua`, scroll to the `CONFIG` table at the top:

| key                  | default      | meaning |
|----------------------|--------------|---------|
| `export_side`        | `"north"`    | Face of the ME Bridge that points at the buffer chest. One of `top`/`bottom`/`north`/`south`/`east`/`west`. |
| `poll_seconds`       | `15`         | How often to poll `colony.getRequests()`. |
| `dashboard_seconds`  | `2`          | Monitor refresh rate. |
| `chat_verbosity`     | `"missing"`  | `"all"` shouts every export to chat; `"missing"` only when nothing satisfies a request; `"off"` silences chat. |
| `dedupe_ttl`         | `60`         | Seconds to ignore a specific `req.id` after we ship it. |
| `item_cooldown`      | `120`        | Seconds to ignore _any_ request for a given item after we last shipped that item. **The main lever for tuning duplicate shipments.** |
| `loop_restart_delay` | `5`          | Pause before restarting a crashed loop. |
| `blacklist_path`     | `"blacklist.txt"` | Where to read the blacklist from. |

### Blacklist

`blacklist.txt` lists items that should **never** be exported, even when a MineColonies request lists them as an acceptable alternative. The classic case: a smelter requests "any smeltable ore" — without a blacklist, your 1.2M ancient debris ships in chunks of 64 until it's gone.

Format:
```
# Comments and blank lines ignored
minecraft:ancient_debris            # exact item ID
minecraft:netherite_ingot
tag:c:ores/netherite_scrap          # match by tag (with or without "minecraft:item/" prefix)
```

The file is **reloaded automatically every poll cycle** — edit and save while the script is running, no reboot needed. The script logs `blacklist loaded: N items, M tags` on each pickup.

Default blacklist covers the netherite chain + diamond/diamond_block.

### Dashboard

```
== ColonyName ==

Citizens: 17 / 17
Happy:    6.4 / 10        (red <5, yellow <7, green ≥7)

Pending:    12            (open colony requests this poll)
Filled:    347            (cumulative successful exports)
Crafts:     12            (cumulative autocrafts scheduled)
In flight:   8            (this poll: requests skipped due to item cooldown)
Blocked:     3            (this poll: requests with all alternatives blacklisted)
Missing:    21            (cumulative requests we couldn't fulfill at all)

Recent:
  12:04:31 EXPORT 64x minecraft:coal -> Waiter Zain M. (Fuel)
  12:04:30 CRAFT 16x minecraft:stick for Builder Duran W. (Sticks)
  ...
```

A healthy colony has Pending → Filled climbing through the day, with In-flight rising and falling each cycle as cooldowns expire. Sustained nonzero **Missing** means you're short on stock + autocraft pattern for something — search the recent log for what.

### Tuning `item_cooldown`

This is the lever that controls duplicate shipments. After exporting `minecraft:stone_bricks`, the script ignores any further request for stone bricks for `item_cooldown` seconds. Reason: MineColonies opens a separate request per outstanding unit, all visible in `getRequests()` at once, and they remain open until the courier has actually delivered.

- **Too low** (< hopper + courier round trip): your buffer chest piles up with the same item, then once the courier finally syncs, MineColonies thinks it has way more than it asked for.
- **Too high**: when the colony genuinely needs more, it waits longer than necessary.

Default 120s works for most setups. If your buffer chest still piles up, raise to 180–240. If your colony seems starved waiting for refills, lower to 90.

## Diagnostics

`probe.lua` is a one-shot script that dumps the actual peripheral API surface for your AP version, samples a few real `getRequests` entries, and uploads everything to a paste service so you can read it from a browser:

```
probe.lua
```

Writes `probe-output.txt` locally and prints a paste.rs URL.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Asserts on startup with "Colony Integrator not found" | Block is outside the colony border, or no peripheral connection (modem not active, or block not adjacent to computer). |
| Asserts with "ME Bridge not found" | Bridge isn't networked to AE2, isn't powered (needs FE/RF on top of AE2 channel), or isn't connected to the computer. |
| Dashboard shows "Filled: 0" but Pending climbs | `export_side` doesn't match your buffer chest. Check faces. |
| Same item ships repeatedly, buffer overflows | `item_cooldown` is too low. Bump it. |
| `Missing` keeps climbing for one item | No stock + no autocraft pattern. Add a pattern, or accept manual fulfillment. |
| Monitor stays blank | All monitor blocks must be Advanced Monitors and form a contiguous grid. Break and replace until seam lines disappear. |
| Native compat-mod "Network Storage" tab is empty after Refresh | Warehouse predates the mod. Deconstruct + rebuild the Warehouse. |
| GitHub raw URL serves stale content after a fix is pushed | CDN cache (~5min). Use a commit-pinned URL: `raw.githubusercontent.com/.../<commit-sha>/<file>`. |
