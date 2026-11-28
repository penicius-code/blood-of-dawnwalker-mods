# Blood Wash

Blood stays on Coen's body and mouth for a set time, and hotkeys play short gestures that wash it off. Single-player only.
Version 0.8.2 | Status: 0.8.0 tested in game on 2026-10-03; the 0.8.2 changes (shoulder brush gesture, speed sliders) are installed and tested in game, not extensively, and the brush timings are estimates

Published on Nexus Mods as "Blood Wash": <https://www.nexusmods.com/thebloodofdawnwalker/mods/708>

## What and why

In vanilla the combat blood on Coen and the feeding blood on his mouth fade on their own after a short time, and the game wipes them at the start of dialogues. This mod makes the blood last (20 minutes by default, adjustable) and gives the player the job of cleaning up:

- Numpad 3: wash body and clothes. Coen brushes his shoulder and the blood goes during the gesture.
- Numpad 6: wipe the mouth. Coen rubs his mouth and the blood goes mid-gesture.
- Numpad 9: the same mouth wipe, crouching (the standing version plays while moving).
- In dialogue, cutscenes and wolf form no gesture can play, so the blood goes at once.
- Voracious Bite leaves blood on the mouth too (vanilla does that only for a normal feed).

How it works: body blood is the game's skinned decal system on the character; the mod clears it with the game's own clear call and sets the fade time on every material of Coen's decal sampler. Mouth blood is a character material parameter; the mod clears it with the game's own function and, once per second, puts it back if the game drops it suddenly before its time is up. The gestures are animations already in the game, made for Coen's skeleton, played on the upper body or the whole body.

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/BloodWash/
  Scripts/main.lua      the mod (868 lines)
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
   `The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\ue4ss\Mods\BloodWash\Scripts\main.lua`
3. Start the game, get into a fight and press Numpad 3 afterwards: Coen brushes the blood off.

Upgrading from 0.8.1 or older: take the new `config.ini` too, or the new options will not show up.

## Uninstall / roll back

1. Close the game.
2. Delete the folder `Dawnwalker\Binaries\Win64\ue4ss\Mods\BloodWash`.
3. Saves are not affected: the game does not save blood, and a loaded save always starts clean.
4. Turning `PermanentBlood` off needs a game restart to bring the game's own fade times back.

## Configuration

`config.ini`, section `[Settings]`. Read on every key press, so changes apply without a restart, except the keys. Most settings are also on the Mod Setting Menu page.

| Key | Default | Meaning |
|---|---|---|
| `BodyKey`, `MouthKey`, `CrouchKey` | `NUM_THREE`, `NUM_SIX`, `NUM_NINE` | UE4SS key names; empty = key off; restart to change |
| `BodyGesture`, `MouthGesture` | `1` | `0` = instant wipe without animation |
| `CrouchWipe` | `1` | `1` crouching gesture, `2` instant, `0` key does nothing |
| `BodyHands` | `0` | `1` = Numpad 3 plays the older hands-together gesture instead of the shoulder brush |
| `MouthBrush` | `0` | `1` = Numpad 6 plays the shoulder brush too |
| `BodyRate`, `WipeRate`, `CrouchRate` | `1.0` | gesture speed per key (menu sliders 0.5 to 4) |
| `PermanentBlood` | `1` | long-lasting blood: mouth lasts `MouthSeconds`, body and clothes `BodySeconds` |
| `MouthSeconds`, `BodySeconds` | `1200` | how long the blood lasts before it fades, in seconds |
| `KeepMouthBlood` | `1` | puts mouth blood back when it vanishes suddenly before its time is up (wolf form, some abilities) |
| `BiteBlood` | `1` | Voracious Bite leaves blood on the mouth |
| `DialogueClearsMouth` | `0` | `1` = mouth blood is wiped for good when a dialogue or cutscene starts |
| `TestKey` | empty | audition key for picking animations; cleans nothing |
| `Logging` | `0` | `1` = `[BloodWash]` lines in `UE4SS.log` |

`config.ini` also holds the timing of each gesture (`...ClearAt`, `...StopAt`, `StopBlend`) and, under "Advanced", the animation and slot each gesture uses.

## Known issues

- The game still wipes body blood at the start of every dialogue or cutscene. Mouth blood is kept.
- A loaded save always starts clean, because the game does not save blood.
- Keyboard keys only.

## Changelog

| Version | Date | Change |
|---|---|---|
| 0.8.2 | 2026-10-13 | Numpad 3 plays a shoulder brush (old pose: `BodyHands = 1`). Speed sliders per key. Optional shoulder brush for the mouth wipe (`MouthBrush`). Audition key `TestKey`. |
| 0.8.1 | 2026-10-03 | Short blood times fade again (0.7.x restored the fade forever). Separate mouth and body times. Voracious Bite leaves blood. |
| 0.7.2 | not recorded | Each key's animation can be switched off. |
| 0.7.1 | 2026-10-03 | First release. |

The script header lists the development steps from 0.2.0 on.

Back to the [mod list](../../README.md).
