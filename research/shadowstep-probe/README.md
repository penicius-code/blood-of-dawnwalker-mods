# Shadowstep Probe

A UE4SS script that records how the game decides where Shadowstep can aim and whether a dodge can start, with two small opt-in experiments. Version 0.1.0, run in game on 2026-09-30. Research code, not a mod for play.

It was written for the pursuit edit of another author's mod, Run from Combat (see [COMPATIBILITY.md](../../COMPATIBILITY.md)), not for [Standing Planeshift](https://github.com/penicius-code/dawnwalker-standing-planeshift), which was released on 2026-09-28, the day before this probe was written. The two only share the game system they look at: Shadowstep.

**Question.** In the pursuit edit, Coen flees with his weapon sheathed while enemies still hunt him. Two things went wrong in that phase: Shadowstep would only target enemies (the combat version that appears behind a target) instead of a point in the world, and the dodge button crouched instead of dodging. Which state makes Shadowstep pick the combat mode, and can a dodge still be started?

**How it was measured.** Every 0.1 seconds on the game thread the probe logged, on change: the fleeing phase of the other mod (read from its shared variables), the player's combat component, the combat system's view (in combat, number of aggressive enemies, boss), 27 gameplay tags on Coen, the counts of the combat configuration's player effects, and the Shadowstep component. Each aim was logged from start to end with the time spent in each target state. Numpad / wrote a full snapshot plus the activation rules of the dodge, crouch and Shadowstep abilities. Numpad * cycled two experiments, the only writes the probe makes: A removed the player's "effectively in combat" effect whenever present; B, while fleeing, started a dodge through the combat component when Coen began to crouch. Output: `ShadowstepProbe.log` next to `Dawnwalker.exe`.

**What was found and what it led to.** Shadowstep's mode follows the enemies' combat state, not the player's: in the middle of one aim the combat system switched to "not in combat" and the same aim changed from enemy-only to a free world target. Removing the player's "effectively in combat" effect (experiment A) changed nothing, so that effect is not the switch. A dodge while fleeing works: the combat component's dodge call succeeded 9 times out of 9 without unblocking combat, while the crouch still toggled for a frame. While fleeing, the button sends only the crouch input, not the dodge input. These results shaped the pursuit edit's "dodge and Shadowstep while fleeing" options: a crouch press while fleeing starts a dodge, and a Shadowstep while fleeing briefly ends combat for the game so that it can aim at the world. The run had no crash.

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/ShadowstepProbe/
  Scripts/main.lua      the probe (441 lines)
  enabled.txt           tells UE4SS to load it
```

To run it, copy `package/` into the game folder like a mod and read `ShadowstepProbe.log` afterwards. Without the pursuit edit installed, the fleeing phase reads as `-` and experiment B never fires. Delete the `ShadowstepProbe` folder when done.

Back to the [mod list](../../README.md).
