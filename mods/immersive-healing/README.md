# Immersive Healing

Food and salves heal slowly over a longer time instead of refilling health in seconds; stamina drinks last longer. Single-player only.
Version build 13 | Status: build 13 tested in game on 2026-10-11 (stamina drink duration); the food and salve changes were tested on 2026-09-28 (builds 9 and 10)

Published on Nexus Mods as "Immersive Healing Longer Food Buff Duration": <https://www.nexusmods.com/thebloodofdawnwalker/mods/679>

## What and why

Food effects last 5 minutes and heal at 5 % of the vanilla rate. Regenerative salves heal at 8 % of the vanilla rate for 60 seconds. Mending ointments restore a fixed 2, 4 or 8 % of maximum health by tier instead of 30, 50 or 75 %. Stamina drinks (cocktails, alcohol, plain drinks) keep their stamina bonus for 3 minutes instead of 30 seconds. Stacking the same dish is optional and off by default.

In vanilla, food refills health in seconds, which makes it a second set of potions. This mod makes eating a slow background heal and keeps salves and ointments as small top-ups.

How it works: the mod looks up the consumable items the game has loaded, follows each one to its gameplay effect, and changes that effect's default values before it is applied. It runs once on world entry, after a load or respawn, and when `config.ini` changes. The original values are stored, so changing a setting never stacks on top of an earlier change, and `Enabled = 0` puts the vanilla values back while the game runs. Blood and vampire effects are never touched.

The mod was first released as "Lingering Meals". If an active `ue4ss\Mods\LingeringMeals` folder is still installed, Immersive Healing prints a warning and stays off, so the two never apply their changes twice.

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/ImmersiveHealing/
  Scripts/main.lua      the mod (665 lines)
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
   `The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\ue4ss\Mods\ImmersiveHealing\Scripts\main.lua`
3. If you used Lingering Meals before, delete `Dawnwalker\Binaries\Win64\ue4ss\Mods\LingeringMeals`.
4. Start the game and eat something: the food effect runs for 5 minutes.

## Uninstall / roll back

1. Close the game.
2. Delete the folder `Dawnwalker\Binaries\Win64\ue4ss\Mods\ImmersiveHealing`.
3. Saves are not affected: the mod changes effect values in memory only, and the next start without it uses the vanilla values.
4. To switch it off without removing it, set `Enabled = 0` in `config.ini`.

## Configuration

`config.ini`, section `[Settings]`, checked every 5 seconds. The same settings are on the Mod Setting Menu page "Immersive Healing".

| Key | Default | Meaning |
|---|---|---|
| `Enabled` | `1` | `0` = vanilla food, medicine and drink effects |
| `FoodDurationSeconds` | `300` | length of a food effect; `0` = use `DurationMultiplier` on the vanilla length |
| `DurationMultiplier` | `3` | used only when `FoodDurationSeconds` is `0` |
| `FoodHealMultiplier` | `0.05` | food healing strength; `1` = vanilla |
| `StackLimit` | `1` | how many of the same dish can run at once; `1` = no stacking |
| `StackExpiration` | `1` | with stacking: `0` all stacks end together, `1` one stack ends and the rest continue |
| `MedicineHealMultiplier` | `0.08` | salve healing per second; `1` = vanilla |
| `OintmentSmallHealPercent` | `2` | small ointment, instant heal in % of max health (vanilla 30) |
| `OintmentMediumHealPercent` | `4` | mending ointment and ancient healing salve (vanilla 50) |
| `OintmentBigHealPercent` | `8` | big ointment (vanilla 75) |
| `MedicineDurationSeconds` | `60` | length of a salve effect (vanilla 15); `0` = use `MedicineDurationMultiplier` |
| `MedicineDurationMultiplier` | `1` | used only when `MedicineDurationSeconds` is `0` |
| `StaminaDurationSeconds` | `180` | length of a stamina drink effect (vanilla 30); `0` = vanilla |
| `Logging` | `0` | `1` writes details to `UE4SS.log` and `ImmersiveHealing.log` next to `Dawnwalker.exe` |

## Compatibility

| Item | Status | Notes |
|---|---|---|
| Configurable Combat Overhaul, food healing option | do not combine | Both scale food healing, so the two reductions multiply. Use one of them, or set `FoodHealMultiplier = 1`. |
| Lingering Meals (the earlier name of this mod) | replaced | Immersive Healing stays off while the old folder is active. |

## Known issues

- The item tooltip still shows the vanilla duration.
- Stamina tonics and the other combat tonics are timed by the game in a different way and stay vanilla.
- Only the length of the stamina drink bonus changes. Scaling its strength was tried in build 13 and dropped: the game computes that value in a way the mod cannot change.

## Changelog

| Version | Date | Change |
|---|---|---|
| build 13 | 2026-10-11 | Stamina drinks last 3 minutes instead of 30 seconds (`StaminaDurationSeconds`). |
| build 12 | 2026-09-28 | Renamed from Lingering Meals. Salves 0.2 %/s for 60 s (build 11 healed 3x for 180 s); ointments 2 / 4 / 8 %; stacking off by default. |
| build 11 | 2026-09-28 | First release, as Lingering Meals. |

Back to the [mod list](../../README.md).
