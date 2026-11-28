# Level Ceiling

Enemies far above Coen's level are brought down toward his level when they start fighting him. Single-player only.
Version 1.1.0 | Status: 1.0.0 tested in game from 2026-09-28 to 2026-10-04 (21 enemies changed in 10 fights with 0 failures; the cap itself verified on 2026-10-04); the 1.1.0 addition "raise weaker enemies" is tested in game

Published on Nexus Mods as "Level Ceiling": <https://www.nexusmods.com/thebloodofdawnwalker/mods/725>

## What and why

A red quest or a walk into a higher area can put Coen against enemies many levels above him, which then kill him in one or two hits and soak up damage. This mod caps the gap: by default an enemy can be at most 3 levels above Coen, a boss at most 6. Enemies at or below his level are never touched. Optionally, enemies far below Coen can be raised (off by default).

```text
gap       = enemy level - Coen's level   (only when above 0)
new level = Coen + min(cap, ceil(gap x GapKept %))      cap: NormalCap or BossCap
```

At Coen level 20 with the defaults: 22 stays 22, 24 becomes 23, 40 becomes 23, a level 45 boss becomes 26.

How it works: the enemy gets the stat table row of its new level for every stat its stat profile takes from that table (health, damage, stamina, resistances), so it fights like a native enemy of that level, and its health percentage is kept. Only enemies that the game's combat system lists as fighting Coen are looked at, at most 4 checks and 1 change per tick. If an enemy's stats do not match its own stat table, it is left alone and one line is logged. Coen is never changed. The mod uses no hooks and no object scans.

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/LevelCeiling/
  Scripts/main.lua      the mod (804 lines)
  config.ini            settings
  mod_settings.ini      page for the optional in-game settings menu
  enabled.txt           tells UE4SS to load the mod
```

## Requirements

| Requirement | Link |
|---|---|
| UE4SS for Dawnwalker | [Nexus Mods, mod 18](https://www.nexusmods.com/thebloodofdawnwalker/mods/18) |
| Mod Setting Menu (optional, adds an in-game settings page) | [Nexus Mods, mod 271](https://www.nexusmods.com/thebloodofdawnwalker/mods/271) |

Requirements are not bundled. Install them first from their own pages.

## Install

1. Install UE4SS for Dawnwalker.
2. Copy the contents of `package/` into the game folder, so that this file exists:
   `The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\ue4ss\Mods\LevelCeiling\Scripts\main.lua`
3. Start the game. `UE4SS.log` shows `Level Ceiling 1.1.0 loaded`; after a fight against a stronger enemy, `LevelCeiling.log` next to `Dawnwalker.exe` shows a line such as `Lv 40 -> 23`.

## Uninstall / roll back

1. Close the game.
2. Delete the folder `Dawnwalker\Binaries\Win64\ue4ss\Mods\LevelCeiling`.
3. Lowered enemies return to their own level when they respawn. The mod writes nothing else.
4. To switch it off without removing it, set `Enabled = 0`: enemies in the current fight go back to their own level, new ones are left alone.

## Configuration

`config.ini`, section `[Settings]`, checked every 5 seconds; a fight in progress is updated right away. The same settings are on the Mod Setting Menu page.

| Key | Default | Meaning |
|---|---|---|
| `Enabled` | `1` | `0` = off |
| `NormalCap` | `3` | most levels a normal enemy can be above Coen (0 to 10) |
| `BossCap` | `6` | the same for bosses (0 to 15) |
| `GapKept` | `100` | share of the level gap kept before the cap, in %; `50` = an enemy 4 levels above ends up 2 above |
| `LighterHealth` | `0` | `1` = enemies above Coen hit like their new level but get the health of a lower level |
| `HealthGapPercent` | `35` | with `LighterHealth`: share of the levels above Coen that count for health |
| `RaiseWeaker` | `0` | `1` = enemies more than `FloorGap` levels below Coen are raised to Coen minus `FloorGap` |
| `FloorGap` | `5` | see `RaiseWeaker` (0 to 20) |
| `CombatLog` | `1` | a few lines per fight in `LevelCeiling.log` next to `Dawnwalker.exe` (rotated at 2 MB) |

## Compatibility

| Item | Status | Notes |
|---|---|---|
| No Level Scaling (Easy) by Caites | designed to run with it | That mod lowers enemies to their area level; this one caps enemies above Coen. Both together give a floor and a ceiling. Level Ceiling also works without it. |

## Known issues

- An enemy fights at its own level for the first 0.5 to 2 seconds, until its stat table has been read.
- Experience and loot from a lowered enemy probably follow the lower level (not checked).
- The health bar keeps its segment count; only the total changes.
- Reloading the mod while the game runs loses its memory of changed enemies. Restart the game instead.

## Changelog

| Version | Date | Change |
|---|---|---|
| 1.1.0 | 2026-10-05 | Optional "raise weaker enemies" (`RaiseWeaker`, `FloorGap`). Menu page rewritten with an explanation for every setting. |
| 1.0.0 | 2026-09-28 | First version. Default `GapKept` raised from 50 to 100 on 2026-09-29, so enemies up to 3 levels above Coen stay untouched. |

The engine details used here were partly learned by reading the Bloodbound mod (deathkawa) and Configurable Combat Overhaul; no code was copied from either.

Back to the [mod list](../../README.md).
