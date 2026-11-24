# Investigations

Shorter research runs for The Blood of Dawnwalker. Each one was a small read-only UE4SS script written to answer one question before building or fixing something. Their code is not published; the five probes with code are in [`research/`](../research). All runs took place between 2026-09-29 and 2026-10-10.

## Wolf animations (Wolf Anim Probe)

[Wolf Form](../mods/wolf-form/README.md) keeps Coen's Haste wolf on screen at walking speed, which vanilla never does, so it was unclear whether the wolf has slow animations at all. The probe dumped, on a key press, Coen's wolf mesh with its skeleton, animation class and linked layers, any wolf characters nearby, and every loaded animation made for a wolf skeleton. The dumps (2026-10-04, once as human and once as a wolf) showed that the wolf's locomotion layer has its own sets for idle, start, walk and run cycles, stops, turns and jumps (85 wolf animations were loaded), while sprint has none of its own. That is why Wolf Form plays the Haste gallop while sprinting. Each dump caused a 260 to 320 ms hitch because it scans all objects, which is acceptable for a key press but not for a loop.

## Haste effects (Haste Probe)

The question was what exactly Haste changes on screen and in sound, so that the same effect could be added to the slow motion of another author's mod, Slow-mo And Pause by Caites. The probe logged every 0.15 seconds the changes of Coen's tags, abilities, gameplay cues, effects, movement profile and any property whose name mentions sprint, haste, travel, field of view or blur. Four Haste runs on 2026-09-29 showed only three changes: a particle effect added to Coen, the camera's field of view easing from 90 to 95, and Coen's own time dilation rising from 1 to about 3.33. There is no gameplay cue, no post-process change and no sound posted from Blueprint code, so the Haste sound stayed unknown. The result was used only in a local edit of that mod, which is not published.

## Artery Strike chances (Artery Probe)

The plan was a day and night version of another author's pak mod, Better Artery Strike by Lilyhunte: more instant-kill chance at night, less by day. The probe tried to hook the functions that compute the chance and the damage. On 2026-09-29 it showed that hooks on Blueprint functions fail in the UE4SS build used here, and that the native chance and damage functions are never called through reflection, so the result cannot be changed from a hook. It also confirmed how day and night can be told apart (the active loadout and the `Player.IsVampire` tag switch together) and recorded the player's damage multipliers by day and by night. The planned mod was not built; the chances were changed by hand in a local copy of the pak instead, which is not published.

## What removes dead bodies (Body Probe)

The idea was a mod that keeps dead bodies in the world longer. The probe watched every dead character once per second and logged when and how it disappeared, and hooked the functions that could remove it. On 2026-10-10 it showed that bodies vanish with the population despawn, 35 to 55 m away and 300 to 360 seconds after death, without a lifespan timer, without being hidden first and without any hook firing. Blocking that despawn from Lua is not safe, so a second approach was tried: a frozen copy of the body left in its place. Copying the body parts worked, but copying cloth garments crashed the game twice. The mod was shelved. One finding was reused: the game's own "get all actors of class" call returns the character list in about 0.00 ms instead of 34 to 44 ms for an object search, and [Blood Vials](../mods/blood-vials/README.md) 1.3.0 uses it to find spawned corpses.

## Human-form Haste (Fervour Probe)

The idea was a "Fervour Form" mod that keeps the look of Mercurial Fervour, the human version of Haste, while Coen walks. The probe logged every frame the Haste ability's state, global and per-actor time dilation, speed and movement profile, the pressed keys and Coen's tags. On 2026-10-06 it showed that the "slow world" look of Haste is Coen's own time dilation of 3.33, owned by native code, and a separate screen effect. A test build then found that the game resets Coen's time dilation to 1 every frame outside Haste, so writing it from Lua only gave a flickering speed-up, and the screen effect could not be resolved from Lua. Fervour Form was paused.

## Invisible blocker (Doll Probe)

After a look was changed with another author's wardrobe mod, Style Without Sacrifice (WardrobeTransmog) by oOCamilleOo, an invisible solid object stayed in the world: Coen could stand on it and NPCs got stuck on it. Reading the strings of that mod's DLL pointed to the preview doll it spawns for the wardrobe screen, which seemed to stay in the world, hidden but with collision. A probe was written on 2026-10-10 to list those dolls with their collision and to switch collision off, but it was never run: the problem was reported to the author and the wardrobe mod was disabled.

## Stuck soundtrack (Music Probe)

One music track played in a loop for over 30 minutes on one save, through fast travel and waiting until day, while an older save played normally. The probe read the game's music subsystem on a key press: the main music state, the area state and the stacks of pushed music states. On 2026-09-30 it showed that no quest music was stuck on the stack; instead the main music state was stuck on "Cutscene", apparently left over from a cutscene whose end never reset it. A second key that sets the state back to "None" stopped the loop but left silence; setting it to "Exploration" brought the normal music back, and the game's own music changes worked again afterwards. The probe stayed installed as an idle fix-on-demand tool with on and off switches.

Back to the [mod list](../README.md).
