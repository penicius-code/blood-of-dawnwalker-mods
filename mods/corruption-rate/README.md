# Corruption Rate

Keeps only a set share of every corruption gain, so Coen's vampire corruption grows more slowly. Single-player only.
Version 0.1.0 | Status: in use, tested; its log during the Blood Vials tests on 2026-10-10 and 2026-10-11 shows gains cut to the set share (20 % then). Not published on Nexus Mods.

## What and why

Corruption (the Vrakhiri mutation charge) rises with every drink of blood, with the blood that keeps coming after a drink, and with vials and some items. In a long playthrough it can rise faster than the story pace. With this mod only `GainPercent` of each gain is kept: 10 % by default, so corruption grows at a tenth of the vanilla speed.

How it works: every 0.2 seconds the mod reads the corruption level and charge from the game. Whatever the charge rose since the last read, the unwanted share is taken back. The write sets the value one unit short and lets the game's own function add the last unit; otherwise a save would keep the game's value instead of the written one. This write method follows the one used by the BetterCorruption mod. Left alone: corruption that other code adds through the game's own function (story rewards, other mods' corrections), drops in the charge, level changes other than one level-up during a gain, and the first 5 seconds after a load. Everything runs in one loop on the game thread.

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/CorruptionRate/
  Scripts/main.lua      the mod (448 lines)
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
   `The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\ue4ss\Mods\CorruptionRate\Scripts\main.lua`
3. Start the game. `UE4SS.log` shows the load line; with `Logging = 1`, `CorruptionRate.log` next to `Dawnwalker.exe` gets one line per gain with the raw and the kept amount.

## Uninstall / roll back

1. Close the game.
2. Delete the folder `Dawnwalker\Binaries\Win64\ue4ss\Mods\CorruptionRate`.
3. The reduced corruption is part of the save; removing the mod does not add the removed share back. From then on corruption grows at the game's own speed.

## Configuration

`config.ini`, section `[Settings]`, read again every 2 seconds. The same settings are on the Mod Setting Menu page "Corruption Rate".

| Key | Default | Meaning |
|---|---|---|
| `Enabled` | `1` | `0` = corruption grows at the game's own speed |
| `GainPercent` | `10` | share of each gain that is kept, in %; `100` = vanilla; values up to `300` were added for testing |
| `Logging` | `0` | `1` = one summary line per gain in `CorruptionRate.log` |

## Compatibility

| Item | Status | Notes |
|---|---|---|
| [Blood Vials](../blood-vials/README.md) (this collection) | works | Blood Vials reads `GainPercent` and adds only that share of its own corruption. |
| BetterCorruption | designed to run alongside it | Its own corrections use the game's function and are left alone. |

## Known issues

- Values above 100 % are untested; the game may cap the charge.

## Changelog

| Version | Date | Change |
|---|---|---|
| 0.1.0 | 2026-10-06 | First version. On 2026-10-11 the `GainPercent` range was widened to 0-300 % for testing. |

Back to the [mod list](../../README.md).
