# Blood Probe

A UE4SS script that records how the blood on Coen's body works, why it disappears in dialogues, and what the game knows about Coen standing in water. Version 0.1.0, run in game on 2026-09-29. Read-only except one test key. Research code, not a mod for play.

**Question.** The combat blood on Coen's body and clothes is gone as soon as a dialogue starts. Why, and can a hotkey clear it on purpose? And is there a reliable sign that Coen is in water, for a "wash only near water" option?

**How it was measured.** Twice a second, on the game thread, the probe logged changes of the blood decal sampler on Coen (its counters and array sizes), the decal value written into each of his mesh materials, the view target and cinematic mode (the dialogue camera), and the movement mode and physics volume. When Coen first appeared it logged his class chain, his components, the functions of the decal sampler and the full table of character material parameters, then hooked the functions that spawn, remove and clear blood decals. Numpad 6 (and every change of view target) wrote a full snapshot of every material parameter on every mesh, the sampler state and what Coen's capsule overlapped. Numpad 3 was the only write: it called the sampler's own clear function on Coen. Output: `BloodProbe.log` next to `Dawnwalker.exe`.

**What was found and what it led to.** The dialogue wipe is a native clear at the moment cinematic mode starts: the decal counter dropped to 0 exactly then, and the hooked clear function never fired, so the game does it in C++ and no setting controls it. Numpad 3 visibly removed the body blood, so the clear call works from Lua. Mouth blood is a separate system, a character material parameter, with its own clear function. For water, Coen never switches to swimming and the physics volume never reports water; what works is that his capsule overlaps the water actor's mesh in every water snapshot and never on land. This led to [Blood Wash](../../mods/blood-wash/README.md), whose hotkeys use the same clear calls. The probe also had a bug of its own: the component list came back empty because a result it treated as an engine array was a plain Lua table.

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/BloodProbe/
  Scripts/main.lua      the probe (844 lines)
  enabled.txt           tells UE4SS to load it
```

To run it, copy `package/` into the game folder like a mod and read `BloodProbe.log` afterwards. Numpad 3 and 6 are also Blood Wash's keys, so do not run both. Delete the `BloodProbe` folder when done.

Back to the [mod list](../../README.md).
