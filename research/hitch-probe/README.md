# Hitch Probe

A read-only UE4SS script that measures frame times and what common engine lookups cost. Version 0.1.0, run in game on 2026-09-29. Research code, not a mod for play.

**Question.** On 2026-09-29 the game hitched for a moment every few seconds while running around, with a heavily modded setup. Which mod causes a hitch on a timer, and how expensive are the engine lookups that script mods use all the time (finding an object by path, finding the first or all objects of a class)?

**How it was measured.** The probe runs one function per frame on the game thread and measures the time between frames. A frame at least twice the normal length and at least 25 ms longer counts as a hitch and is logged with the gap to the previous hitch, so a timer in some mod shows up as a fixed period. Every 30 seconds in the world it logs frames per second, frame time percentiles and dropped frames (paused frames and loading stalls are left out). 20 seconds after world entry, and on Numpad 8, it runs a lookup benchmark, one group per frame with its own time subtracted: `StaticFindObject` (hits and a miss), `FindFirstOf` and `FindAllOf` on several classes, a property read, a function call, `GetFullName` and a file read. All results go to `UE4SS.log` with the tag `[HitchProbe]`.

**What was found and what it led to.** One hitch of about 38 ms extra every 10.0 seconds, always at the same point of the wall clock and with no drift over 6 minutes. That pattern pointed to a timer on the game thread based on the system clock, and reading the installed mods' code found it: a crafting menu mod that searched all objects for its menu widget every 10 seconds until the menu had been opened once. Each such search (`FindAllOf` or `FindFirstOf`) cost 34 to 44 ms in the benchmark. After the mod was removed, no recurring pattern was left. The numbers became the working rules for every later mod in this repository: no object searches inside loops, look objects up through live references instead, and keep nothing but engine singletons between ticks. The same rules are checked by the linter in [`tools/lualint.py`](../../tools/lualint.py), and the probe was replaced by the always-on monitor [Hitch Watch](../../mods/hitch-watch/README.md).

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/HitchProbe/
  Scripts/main.lua      the probe (318 lines)
  enabled.txt           tells UE4SS to load it
```

To run it, copy `package/` into the game folder like a mod, play a few minutes, and read the `[HitchProbe]` lines in `UE4SS.log` before the next launch overwrites it. Delete the `HitchProbe` folder afterwards.

Back to the [mod list](../../README.md).
