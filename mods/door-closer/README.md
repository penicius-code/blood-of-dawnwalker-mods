# Door Closer

Tap a key to close the nearest open door; optionally hold it at a locked door to force it open. Single-player only.
Version 1.1.0 | Status: tested in game on 2026-10-03 (closing doors, forcing a locked door); not tested: the quest door warning, a shop locked by time of day, the "This door needs a key" message. Not published on Nexus Mods.

## What and why

Doors in the game stay open once pushed; the game closes them itself only when combat starts. This mod closes them on request:

- Tap Numpad 5 near an open door (within 3.5 m): the door swings shut.
- With `Bash = 1` (off by default): hold Numpad 5 at a plain locked or time-locked door to force it open. Doors that need a key stay locked. A door that belongs to a quest asks for a second hold first. The broken lock is saved with the door.

How it works: everything runs on the key press only, with no background loop. The mod finds the nearest door, releases any forced-open state and calls the door's own close function (animated or instant). Forcing sets the door's state to open and calls its own open function. No game object is kept between presses.

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/DoorCloser/
  Scripts/main.lua      the mod (456 lines)
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
   `The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\ue4ss\Mods\DoorCloser\Scripts\main.lua`
3. Start the game, open a door, step back and tap Numpad 5: the door closes and a short notice shows its state.

## Uninstall / roll back

1. Close the game.
2. Delete the folder `Dawnwalker\Binaries\Win64\ue4ss\Mods\DoorCloser`.
3. Closing a door changes nothing permanent. A door forced open with `Bash = 1` keeps its broken lock in that save; removing the mod does not restore the lock.

## Configuration

`config.ini`, section `[Settings]`, read on every key press (the keys need a restart). `Method`, `Bash`, `QuestWarning`, `ShowInfo` and `Logging` are also on the Mod Setting Menu page.

| Key | Default | Meaning |
|---|---|---|
| `Key` | `NUM_FIVE` | UE4SS key name; empty = off |
| `HoldKey` | empty | Unreal name of the same key for the hold check; empty = derived from `Key` |
| `Range` | `350` | how far away a door may be, in cm |
| `Method` | `1` | `1` animated close, `2` instant close |
| `Bash` | `0` | `1` = hold the key at a locked door to force it open |
| `HoldMs` | `500` | how long the key must be held to force a door |
| `QuestWarning` | `1` | with `Bash`: quest doors need a second hold within 10 seconds |
| `ShowInfo` | `1` | notices show the door's lock state and quest tag count |
| `Logging` | `0` | `1` = `[DoorCloser]` lines in `UE4SS.log` |

## Compatibility

| Item | Status | Notes |
|---|---|---|
| OpenDoors by Aloncifer | works | Tested with it on 2026-09-28. When its folder is present, Door Closer adds two small hooks so that OpenDoors does not throw a door closed by key wide open again until Coen walks up to it. |

## Known issues

- Which doors count as quest doors is a guess based on the door's quest tags.
- The hold check for keyboard keys was written without prior proof that the game reports them; forcing a door worked in the 2026-10-03 test.

## Changelog

| Version | Date | Change |
|---|---|---|
| 1.1.0 | 2026-10-03 | Optional forcing of locked doors (`Bash`), quest door warning, info notices. One door scan per press instead of two. |
| 1.0.0 | not recorded | Test diagnostics removed. |
| 0.3.0 | 2026-09-28 | First working version (tested with OpenDoors). |

Back to the [mod list](../../README.md).
