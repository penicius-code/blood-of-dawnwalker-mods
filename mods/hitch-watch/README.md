# Hitch Watch (in-game)

An always-on, read-only stutter monitor that runs inside the game and writes what it sees to a log file. Single-player only.
Version 0.1.1 | Status: in use; first run on 2026-09-29 (main menu), and a logged 2-hour play session on 2026-10-10 with no crash. Not published on Nexus Mods.

## What and why

With 60 or more script mods installed, a stutter can come from any of them. Hitch Watch measures every frame and, when one takes far longer than normal, writes down which mods printed something to the UE4SS log during that frame. A mod that stalls the game on a timer shows up as a hitch that repeats with a fixed period.

`HitchWatch.log` in the mod folder holds:

- a session header: every mod UE4SS started and every mod deployed by Vortex (name, Nexus id, version), plus what changed since the previous session;
- each hitch (a frame at least twice the normal frame time and at least `HitchMs` longer), with the UE4SS log lines printed around it;
- recurring hitches: the same period 5 or more times in a row, announced once with period and size, then counted;
- loading stalls of 1.5 seconds or more with the lines around them;
- the first line of each mod's first Lua error, then counts;
- every `SummaryMinutes` of play: frames per second, frame time percentiles, dropped frames, hitches, chatty log tags, and the monitor's own cost.

Numpad / writes a `MARK` line: press it when something felt wrong, to find the moment in the log later.

How it works: one Lua call per frame (a clock read and a few sums), a state check once per second, and a read of the new UE4SS log text every 0.5 seconds. No hooks, no object scans; only the engine object and one default object are kept between frames. It never changes anything in the game.

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/HitchWatch/
  Scripts/main.lua      the monitor (683 lines)
  config.ini            settings (read at game start)
  enabled.txt           tells UE4SS to load the mod
```

## Requirements

| Requirement | Link |
|---|---|
| UE4SS for Dawnwalker | [Nexus Mods, mod 18](https://www.nexusmods.com/thebloodofdawnwalker/mods/18) |

Requirements are not bundled. Install them first from their own pages.

## Install

1. Install UE4SS for Dawnwalker.
2. Copy the contents of `package/` into the game folder, so that this file exists:
   `The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\ue4ss\Mods\HitchWatch\Scripts\main.lua`
3. Start the game. `HitchWatch.log` appears in the mod folder with a `=== SESSION` header.

## Uninstall / roll back

1. Close the game.
2. Delete the folder `Dawnwalker\Binaries\Win64\ue4ss\Mods\HitchWatch` (this also removes its log and state files).
3. Saves are not affected: the monitor only reads.

## Configuration

`config.ini`, read at game start.

| Key | Default | Meaning |
|---|---|---|
| `HitchMs` | `25` | a frame counts as a hitch when it is at least 2x the normal frame time and this many ms longer |
| `SummaryMinutes` | `5` | minutes of play between summary lines |
| `TailLog` | `1` | `1` = read `UE4SS.log` to name mods near hitches, count errors and list mod changes; `0` = frame times only |
| `MaxLogMB` | `2` | size at which `HitchWatch.log` is renamed to `HitchWatch.old.log` |

## Known issues

- It cannot see crashes inside the game's native code; for those, check the game's crash folder.
- Mods installed by hand as pak files are not listed in the session header (Lua cannot list folders).
- Frame times come from a clock with 1 ms resolution.
- The log line for a mark still says "Numpad 8", the key of an earlier build; the key is Numpad /.

## Changelog

| Version | Date | Change |
|---|---|---|
| 0.1.1 | 2026-09-29 | Errors logged before the game's event loop starts are written under the session header. |
| 0.1.0 | 2026-09-29 | First version, built after [Hitch Probe](../../research/hitch-probe/README.md) found a mod that stalled the game every 10 seconds. |

Back to the [mod list](../../README.md).
