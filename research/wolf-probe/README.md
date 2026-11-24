# Wolf Probe

A read-only UE4SS script that records the state of Coen's wolf and human meshes while a vanilla bug happens. Version 0.1.0, run in game on 2026-09-30. Research code, not a mod for play. It led to version 1.0.3 of [Standing Planeshift](https://github.com/penicius-code/dawnwalker-standing-planeshift), which lives in its own repository.

**Question.** After wolf Haste followed by Shadowstep onto a wall, Coen turns human on the wall. Back on the ground and in Haste again, the wolf looks wrong: it stays in one pose and slides, and only transforming back and forth a few times clears it. Standing Planeshift's own log showed no layer change of its own at that moment, so the cause was somewhere that log did not look. What leaves the wolf stuck?

**How it was measured.** Every 0.1 seconds the probe logged, on change: wolf form, movement mode, gravity, time dilation, capsule size, and for each animated mesh (the human mesh and the wolf mesh) whether it is visible, its mesh asset, animation class, linked animation layers and current montage. Every 0.15 seconds it logged changes of gameplay tags, active abilities, gameplay cues, active effects, and any property whose name mentions wolf, form, gravity, wall, sprint, Shadowstep and similar words. A `STUCK?` line marked the moment the wolf did not move for 1.5 seconds while the move key was held, and Numpad 7 wrote a full snapshot. Output: `WolfProbe.log` next to `Dawnwalker.exe`. Nothing is written to the game.

**What was found and what it led to.** The wolf is a separate mesh. In wolf form the pawn's main mesh reference points at the wolf mesh, so Shadowstep out of wolf Haste plays its loop montage and links the wall animation layers on the wolf mesh, then turns Coen human and hides the wolf with that montage and those layers still on it. The next time the wolf is shown, it is stuck. The bug is in the game, not in the mod. Standing Planeshift 1.0.3 now stops that stale montage on the hidden wolf and unlinks the foreign layers once Coen is walking normally again; the fix was confirmed in game the same morning. A side finding: the check for a held move key read "not held" at every snapshot, so that input check is not reliable.

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/WolfProbe/
  Scripts/main.lua      the probe (657 lines)
  enabled.txt           tells UE4SS to load it
```

To run it, copy `package/` into the game folder like a mod and read `WolfProbe.log` afterwards. Delete the `WolfProbe` folder when done.

Back to the [mod list](../../README.md).
