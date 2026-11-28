# Wolf Form

Coen can stay in wolf form outside Haste and switch between wolf and human with a key. Single-player only.
Version 0.2.0 (named "Wolf Form Beta" in the settings menu) | Status: 0.1.4 tested in game on 2026-10-04 (no crash, no errors, 19 of 19 holds after Haste came back); 0.2.0 (one setting removed, menu page renamed) tested in game, not extensively

Published on Nexus Mods as "Wolf Form": <https://www.nexusmods.com/thebloodofdawnwalker/mods/724>

## What and why

In vanilla the wolf exists only at full Haste speed: as soon as Coen slows down he turns human. With this mod:

- P switches between wolf and human, no Haste needed (at night only, by default).
- Optional: Coen stays a wolf when a wolf Haste ends (`HoldAfterHaste`, off by default).
- Combat, dialogue, cutscenes, Shadowstep, climbing, crouching, interacting and dawn turn him human, and he stays human until the key is pressed again.
- While sprinting as a wolf, the Haste gallop plays (the wolf has no sprint animation of its own).

How it works: the wolf belongs to the Haste ability. The mod calls that ability's own function that shows or hides the wolf (`SetupWolfForm`), the same one the game uses. Blueprint functions cannot be hooked in this UE4SS build, so the end of Haste cannot be blocked; the mod calls the function again on the first frame after Haste drops the wolf. While the wolf is held, the walk-to-run transition animations are switched off (the wolf's legs froze on them), and for sprinting two entries of the wolf's animation set are swapped and swapped back afterwards. Everything runs in one loop on the game thread.

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/WolfForm/
  Scripts/main.lua      the mod (793 lines)
  config.ini            settings
  mod_settings.ini      page for the optional in-game settings menu
  enabled.txt           tells UE4SS to load the mod
```

## Requirements

| Requirement | Link |
|---|---|
| UE4SS for Dawnwalker | [Nexus Mods, mod 18](https://www.nexusmods.com/thebloodofdawnwalker/mods/18) |
| Mod Setting Menu (optional, adds an in-game settings page) | [Nexus Mods, mod 271](https://www.nexusmods.com/thebloodofdawnwalker/mods/271) |
| The wolf form upgrade for Haste, earned in the game | |

Requirements are not bundled. Install them first from their own pages.

## Install

1. Install UE4SS for Dawnwalker.
2. Copy the contents of `package/` into the game folder, so that this file exists:
   `The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\ue4ss\Mods\WolfForm\Scripts\main.lua`
3. Start the game, wait for night, stand outdoors out of combat and press P: Coen turns into the wolf.

## Uninstall / roll back

1. Close the game.
2. Delete the folder `Dawnwalker\Binaries\Win64\ue4ss\Mods\WolfForm`.
3. Saves are not affected: the mod stores nothing in them.
4. To switch it off without removing it, set `Enabled = 0` in `config.ini`.

## Configuration

`config.ini`, section `[Settings]`, read again every 2 seconds (the key needs a restart). The same settings are on the Mod Setting Menu page "Wolf Form Beta".

| Key | Default | Meaning |
|---|---|---|
| `Enabled` | `1` | `0` = vanilla (wolf only during Haste) |
| `ToggleKey` | `P` | UE4SS key name, for example `NUM_SEVEN`; empty = no key |
| `HoldAfterHaste` | `0` | `1` = Coen stays a wolf after a wolf Haste |
| `NightOnly` | `1` | `1` = wolf form only at night |
| `NoSpeedUpTransitions` | `1` | `1` = no walk-to-run transition animations while a wolf |
| `Logging` | `0` | `1` = `WolfForm.log` next to `Dawnwalker.exe` |

The defaults match the Nexus Mods release; the rest of the files come from the development copy, because the release archive was not at hand. The in-game tests used `ToggleKey = NUM_SEVEN` (Numpad 7).

## Known issues

- A short human flash when a wolf Haste ends: the game drops the wolf first, and the mod can only call it back on the next frame.
- The front legs do not move correctly at sprint speed. Not retested with vanilla sprint speed.
- Keyboard only, no controller binding.

## Changelog

| Version | Date | Change |
|---|---|---|
| 0.2.0 | 2026-10-05 | Released as "Wolf Form Beta": the gallop setting was removed (gallop only while sprinting), `HoldAfterHaste` off by default. |
| 0.1.4 | 2026-10-04 | Sprint gallop swaps two animation entries instead of overwriting one (the overwritten one could get unloaded). |
| 0.1.3 | 2026-10-04 | Waits for the game to hide the wolf before calling it back; Haste gallop while sprinting. |
| 0.1.2 | 2026-10-04 | Everything on one game-thread loop; 0.1.1 crashed with a background loop. |
| 0.1.1 | 2026-10-04 | Shorter flash; walk-to-run transitions off while a wolf. |
| 0.1.0 | 2026-10-04 | First build: wolf by key and after Haste. |

Back to the [mod list](../../README.md).
