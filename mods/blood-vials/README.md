# Blood Vials

Draw blood from dead or unconscious humans and animals into two vials and drink it later to refill Coen's blood bar. Single-player only.
Version 1.4.1 | Status: tested in game on 2026-10-11 (human blood corruption; drinking and drawing tested since 0.1.0); not checked: corruption from the animal vial (none expected), the corruption charge after a save and reload, a drink that crosses a level boundary, drinking by day, unconscious bodies

Published on Nexus Mods as "Blood Vials": <https://www.nexusmods.com/thebloodofdawnwalker/mods/710>

## What and why

Coen carries two vials outside the inventory, one for human blood and one for animal blood.

- `]` near a dead or unconscious human or animal (within 1.5 m) draws its blood into the matching vial, with a crouching animation. A body gives up to 3 draws, then "The blood has gone cold". Monsters are declined.
- `[` drinks a dose with a drinking animation. A human dose refills 20 % of the blood bar, an animal dose 10 %. Like a vanilla vial, a drink also mends segments lost to permanent damage and carries over into the next segment.
- Human blood also adds corruption, the same amount as a vanilla human blood vial. Animal blood adds none.
- One vial holds one body, which is two drinks. When both vials hold blood, the human vial is drunk first.

How it works: on a key press the mod asks the game's AI system for bodies in range, and the game's own character list for corpses spawned without an AI record. The game's creature table says whether a body is human, animal or monster. A drink refills the bar through the game's own blood bar function. The animations are existing game animations played on Coen. Messages use the game's own on-screen notice. Nothing polls in the background.

The vial contents are kept in `state.txt` in the mod folder (written by the mod). They are not tied to save games.

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/BloodVials/
  Scripts/main.lua      the mod (1,184 lines)
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
   `The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\ue4ss\Mods\BloodVials\Scripts\main.lua`
3. Start the game, stand next to a dead body and press `]`: Coen crouches, the matching vial fills and a notice appears on screen.

Upgrading: copy over the previous version. Your vials (`state.txt`) are kept. The new `config.ini` replaces yours, so keep a copy if you changed settings.

## Uninstall / roll back

1. Close the game.
2. Delete the folder `Dawnwalker\Binaries\Win64\ue4ss\Mods\BloodVials` (this also removes the vial contents in `state.txt`).
3. Saves keep what the drinks did (blood bar, corruption), as with vanilla vials. Nothing else of the mod is stored in a save.

## Configuration

`config.ini`, section `[Settings]`. Read on every key press; the keys only at game start. The same settings are on the Mod Setting Menu page.

| Key | Default | Meaning |
|---|---|---|
| `DrinkKey`, `ExtractKey` | `OEM_FOUR` (`[`), `OEM_SIX` (`]`) | UE4SS key names; restart to change |
| `Range` | `150` | how close Coen has to be to the body, in cm (50 to 500) |
| `MaxExtract` | `3` | draws per body (1 to 10) |
| `Capacity` | `1` | bodies per vial |
| `DosesPerFill` | `2` | drinks per body |
| `HumanRestore`, `AnimalRestore` | `20`, `10` | % of the blood bar per drink |
| `HumanCorruption` | `1.5` | corruption per human drink (0 = off); with Corruption Rate installed only its share is added |
| `DrinkFirst` | `1` | `1` human vial first, `2` animal vial first |
| `HealDamage` | `1` | `1` = a drink also mends permanent damage like vanilla vials |
| `Gesture`, `Anim`, `AnimTime` | `1`, `5`, `1.15` | drinking animation on/off, which one, and its length in seconds |
| `ExtractAnim`, `ExtractSpeed` | `2`, `1.38` | drawing animation (0 = none) and its play speed |
| `Scan` | `1` | also check the game's character list when the AI query finds no body (needed for spawned corpses) |
| `Logging` | `0` | `1` = `[BloodVials]` lines in `UE4SS.log` |

`config.ini` documents the remaining animation timing keys.

## Compatibility

| Item | Status | Notes |
|---|---|---|
| [Corruption Rate](../corruption-rate/README.md) (this collection) | works | Blood Vials reads its `GainPercent` and adds only that share of `HumanCorruption`, like a vanilla vial under Corruption Rate. |

## Known issues

- Which bodies were already drained is remembered only until the game is closed.
- The 1.5 corruption per human drink was measured from one vanilla human vial; the config file calls it a guess.

## Changelog

| Version | Date | Change |
|---|---|---|
| 1.4.1 | 2026-10-11 | Human blood corruption matched to a vanilla human vial (1.5, scaled by Corruption Rate when installed). |
| 1.4.0 | 2026-10-10 | Human blood adds corruption. |
| 1.3.0 | 2026-10-10 | Spawned corpses are found through a native list; no more 40 ms hitch on the key press. |
| 1.2.0 | 2026-10-03 | First release: several draws per body, "The blood has gone cold"; drinks set to 20 % / 10 % (2026-10-02). |
| 1.1.0 | 2026-09-30 | A drink fills damaged segments like a vanilla vial. |
| 1.0.0 | 2026-09-30 | Drawing animation chosen. |
| 0.1.0 | 2026-09-30 | First build: draw blood into vials. |

Back to the [mod list](../../README.md).
