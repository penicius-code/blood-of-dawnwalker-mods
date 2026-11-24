# Finisher Probe

A read-only UE4SS script that logs, for every kill, why the killing blow did or did not play a finisher. Research code, not a mod for play. The version here is 0.3.0; the results below come from runs of 0.1.0 (2026-10-03) and 0.2.0 (2026-10-12). 0.3.0 adds full tag reading and time dilation lines; it ran next to the Always Finishers tests later on 2026-10-12, where it showed the stun tag on an enemy blinded by Dirty Trick.

**Question.** In vanilla, finishers are rare. What decides whether a killing blow plays one: the enemy's health, a flag, the distance, the number of enemies, a game setting? The enemy side could be read from the game's data beforehand: an AI condition compares the enemy's health with `FinishersHPPercentage` in its AI configuration (0.2 for normal humans) and then sets a "ready for finisher" flag through a native function. The player side is decided in native code and could only be observed.

**How it was measured.** One loop on the game thread, every 0.1 seconds while enemies are fighting Coen. Three hooks, registered 15 seconds after start: Coen's combat montage start (each finisher), the native function that sets the ready flag, and the one that reads it. Per enemy the probe logged every health drop with Coen's last montage, distance and the ready flag, and one `KILL` line per death: finisher yes or no, health before the blow, size of the blow, when the flag was set, distance, tags, Coen's fighting style and the first condition that failed. Once per session it logged the game's Finishers setting, the combat configuration and each enemy type's AI configuration. Output: `FinisherProbe.log` next to `Dawnwalker.exe`. Nothing is written to the game.

**What was found and what it led to.** In 19 kills at night with claws and the vampire sword, 4 were finishers. Every finisher followed the same pattern: an attack took the enemy to or below the threshold without killing it, the ready flag switched on, and the finisher started 0.1 to 0.3 seconds later in the middle of the combo. No finisher came from a blow that went from above the threshold straight to zero (7 kills), from ability kills such as Wide Swing, Charge or Artery Strike (4), or from a bleed tick after the flag was set (4). Fists have no finisher table at all. The number of other enemies alive and distances up to 1.6 m did not matter. The thresholds per enemy type were 0.2 for longsword guards and 0.1 for heavies and rogues. This led directly to [Always Finishers](../../mods/always-finishers/README.md): raise the threshold, and switch the ready flag on again when an attack lands. The earlier 0.1.0 run measured how finishers cut off limbs (the cut landed 0.37 to 0.58 seconds after the finisher started) for an experiment with head-only finishers that did not work and is not published.

```text
package/Dawnwalker/Binaries/Win64/ue4ss/Mods/FinisherProbe/
  Scripts/main.lua      the probe (732 lines)
  enabled.txt           tells UE4SS to load it
```

To run it, copy `package/` into the game folder like a mod, fight some humans with Gameplay > Combat > Finishers on, and read the `KILL` lines in `FinisherProbe.log`. Delete the `FinisherProbe` folder when done.

Back to the [mod list](../../README.md).
