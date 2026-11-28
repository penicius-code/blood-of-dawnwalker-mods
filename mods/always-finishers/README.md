# Always Finishers

Raises the enemy health threshold below which a killing blow plays a finisher. Single-player only.
Version 0.5.1 | Status: 0.5.0 tested in game on 2026-10-12 (6 of 9 kills were finishers at a 50 % threshold); the 0.5.1 save-reload fix is tested in game, not extensively

Published on Nexus Mods as "Always Finishers - Higher Finisher HP Threshold": <https://www.nexusmods.com/thebloodofdawnwalker/mods/749>

The files in `package/` are the files of the 0.5.1 download on Nexus Mods.

## What and why

The game marks an enemy as "ready for a finisher" once its health falls below a threshold set per enemy type: about 20 % for guards with longswords and 10 % for heavies and rogues. Coen's next hit then plays a finisher. A blow that goes from above the threshold straight to zero plays none, so finishers are rare. This mod raises the threshold (30 % by default) and keeps low-health enemies marked as ready.

How it works: one loop on the game thread asks the combat system which enemies are fighting Coen. For each, the enemy type's AI configuration gets `FinishersHPPercentage` raised to the setting, never lowered; the vanilla value is kept and written back when the mod is switched off. With `Rearm = 1` an enemy at or below the threshold that the game did not mark (for example while blinded by Dirty Trick) is marked, and an enemy that is already marked is marked again when Coen hits it, because the game starts a finisher only when the mark switches on during an attack. How the game decides was measured with [Finisher Probe](../../research/finisher-probe/README.md).

0.5.1 fixes a report that the mod stopped working after loading a save: a load replaces the AI configurations with fresh vanilla copies, and 0.5.0 kept writing to the old ones. 0.5.1 re-attaches to the live copy whenever it changes, drops everything on a map load and re-checks the value every 2 seconds.

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/AlwaysFinishers/
  Scripts/main.lua      the mod (405 lines)
  config.ini            settings
  mod_settings.ini      page for the optional in-game settings menu
  README.txt            short readme shipped with the mod
  enabled.txt           tells UE4SS to load the mod
```

## Requirements

| Requirement | Link |
|---|---|
| UE4SS for Dawnwalker | [Nexus Mods, mod 18](https://www.nexusmods.com/thebloodofdawnwalker/mods/18) |
| Mod Setting Menu (optional, adds an in-game settings page) | [Nexus Mods, mod 271](https://www.nexusmods.com/thebloodofdawnwalker/mods/271) |
| Gameplay > Combat > Finishers switched on in the game settings | |

Requirements are not bundled. Install them first from their own pages.

## Install

1. Install UE4SS for Dawnwalker.
2. Copy the contents of `package/` into the game folder, so that this file exists:
   `The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\ue4ss\Mods\AlwaysFinishers\Scripts\main.lua`
3. Start the game; with Mod Setting Menu installed, the page "Always Finishers" appears. To confirm in the log, set `Logging = 1`: `UE4SS.log` then shows `[AlwaysFinishers] 0.5.1 loaded` and the threshold written for each enemy type met.

## Uninstall / roll back

1. Close the game.
2. Delete the folder `Dawnwalker\Binaries\Win64\ue4ss\Mods\AlwaysFinishers`.
3. Saves are not affected: the thresholds are changed in memory only.
4. To switch it off without removing it, set Enabled to Off on the Mod Setting Menu page or `Enabled = 0` in `config.ini`: the vanilla thresholds are written back. There is no hotkey.

## Configuration

`config.ini`, section `[Settings]`, read again every 2 seconds. The same settings are on the Mod Setting Menu page.

| Key | Default | Meaning |
|---|---|---|
| `Enabled` | `1` | `0` = off, the game's own thresholds are restored |
| `Threshold` | `30` | enemy health % at which finishers become possible; never below the game's own value |
| `Rearm` | `1` | keep low-health enemies marked as ready for a finisher, also when blinded |
| `TickMs` | `100` | milliseconds between enemy checks |
| `Logging` | `0` | `1` = `[AlwaysFinishers]` lines in `UE4SS.log`, for bug reports |
| `Toast` | `1` | unused in this release (there is no hotkey) |

## Known issues

- No finisher for a blow from above the threshold straight to zero, for ability kills (Wide Swing, Charge, Artery Strike), for bleed kills, with fists, or during Shadowstorm and other slow motion.
- On an enemy stunned by Dirty Trick, finishers can play without killing; the kill comes once the stun ends. A fix for this was tried in an earlier 0.5.1 build and reverted.
- Some kills at or below the threshold still get no finisher; the cause is not known.
- The header comment of `main.lua` still describes a Numpad * toggle from the development copy; the released script has no key binding.

## Changelog

| Version | Date | Change |
|---|---|---|
| 0.5.1 | 2026-10-22 | Keeps working after loading a save: the threshold is re-applied after every load (reported by a user on 2026-10-20). Tested in game, not extensively. |
| 0.5.0 | 2026-10-12 | Built; released as a beta by 2026-10-20: marked enemies are marked again when hit by an attack. |
| 0.2.0 | 2026-10-12 | Re-arm: enemies under Dirty Trick can be finished. |
| 0.1.0 | 2026-10-12 | First build: raised threshold. |

Back to the [mod list](../../README.md).
