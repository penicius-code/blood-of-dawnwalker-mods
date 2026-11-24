# No Lock Reticle

Hides the combat lock-on reticle and fades enemy health bars to set opacities. Single-player only.
Version 0.4.4 | Status: 0.4.3 tested in game on 2026-10-12 (reticle hidden, bars faded, no flash on enemy attacks); 0.4.4 only removes a diagnostic and was not installed for testing; the boss bar fade was not seen in a boss fight

Published on Nexus Mods as "No Lock Reticle": <https://www.nexusmods.com/thebloodofdawnwalker/mods/750>

## What and why

The lock-on reticle and the enemy health bars cover a lot of the screen in fights. This mod hides the reticle and fades the bars:

- lock-on reticle: 0 % (gone)
- health bar of the targeted enemy: 35 %
- health bars of the other enemies in combat: 25 %
- boss bar at the top of the screen: 50 %

How it works: every 100 ms the mod finds the player's reticle widget and the enemy bar widgets again and sets the opacity of each widget's root, only when the value differs. The game's own animations move the child images, and the root opacity applies over them. A second reticle and bar that the game shows briefly when an enemy attacks follow the same settings (that was the "flash" fixed in 0.4.3). Nothing is kept between ticks except the engine object, and there is no hotkey.

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/NoLockReticle/
  Scripts/main.lua      the mod (381 lines)
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
   `The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\ue4ss\Mods\NoLockReticle\Scripts\main.lua`
3. Start the game and lock on to an enemy: no reticle appears and the enemy's bar is faint.

## Uninstall / roll back

1. Close the game.
2. Delete the folder `Dawnwalker\Binaries\Win64\ue4ss\Mods\NoLockReticle`.
3. Saves are not affected: only widget opacity is changed, in memory.
4. To switch it off without removing it, set `Enabled = 0`: the widgets are set back to full opacity.

## Configuration

`config.ini`, section `[Settings]`, read again every 2 seconds. The same settings are on the Mod Setting Menu page.

| Key | Default | Meaning |
|---|---|---|
| `Enabled` | `1` | `0` = everything as the game shows it |
| `Opacity` | `0` | lock-on reticle in %; `100` = the game's own |
| `BarOpacity` | `35` | health bar of the targeted enemy |
| `OtherBarOpacity` | `25` | health bars of all other enemies in combat |
| `BossBarOpacity` | `50` | boss bar; `100` = left alone |
| `Logging` | `0` | `1` = `[NoLockReticle]` lines in `UE4SS.log`, for bug reports |
| `TickMs` | `100` | check interval |

The defaults match the Nexus Mods release; the rest of the files come from the development copy, because the release archive was not at hand.

## Compatibility

| Item | Status | Notes |
|---|---|---|
| Dynamic HUD | works | Checked on 2026-10-11: Dynamic HUD changes child widgets, this mod the root, so the opacities multiply. |
| Small Lock Dot | works | A texture mod; it can stay installed. |
| Other HUD mods that change the same widgets | not tested | They may overwrite each other. |

## Changelog

| Version | Date | Change |
|---|---|---|
| 0.4.4 | 2026-10-19 | Released (built 2026-10-12). Removes a diagnostic that caused a 40 ms hitch once per launch. |
| 0.4.3 | 2026-10-12 | The helper reticle and bar shown on enemy attacks follow the settings (no more flash). |
| 0.4.0 | 2026-10-11 | Optional boss bar fade. |
| 0.3.0 | 2026-10-11 | Bars over all other enemies in combat fade too. |
| 0.2.0 | 2026-10-11 | The targeted enemy's health bar fades. |
| 0.1.0 | 2026-10-11 | First build: reticle hidden. |

Back to the [mod list](../../README.md).
