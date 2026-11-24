# Compatibility: other authors' mods in the test setup

The mods in this repository were built and tested in a game with many mods by other authors. Some of those were changed locally for personal use: key layouts, settings, and fixes for crashes or bugs found while testing. This page lists those local changes in words, so that it is clear what the test setup looked like.

- None of these changes is published here or anywhere else, except the one marked "published". This repository contains no code, files or assets of other authors.
- No mod in this repository needs any of these changes. The only places where a mod here notices another author's mod are listed at the end.
- Authors are named with their Nexus Mods names where the project notes record them; otherwise the table says so.
- The changes were made in late September and October 2026. "Retired" means the change, or the whole mod, was later removed from the test setup.

## Local changes

| Mod (author, Nexus Mods id) | What was changed locally | Kind | State |
|---|---|---|---|
| Run from Combat (Hess117, 167) | A pursuit-based escape: enemies chase, lose track of Coen or catch up again; dodge and Shadowstep while fleeing; a cheaper enemy query. | feature, performance | **published** on Nexus Mods as [Run from Combat - Pursuit Edit](https://www.nexusmods.com/thebloodofdawnwalker/mods/763) with the original author's permission and credit. Not in this repository. |
| AutoHealthRegen (author not recorded, 46) | Separate regeneration rates for human and vampire form, and a reworked update loop. | feature, crash fix | retired |
| Better Artery Strike (Lilyhunte, 680) | Higher instant-kill chances in the pak's four skill levels. | tuning | in use |
| Better Autosaver (hort, 564) | Default hotkeys moved to free keys. | key layout | in use |
| Clean Image (author not recorded, 303) | An experimental stability rewrite of its update loop. | crash fix | retired |
| Coen Retexture (author not recorded, 598) | A personal mix of two of its texture packs. | textures | retired |
| Configurable Combat Overhaul (author not recorded, 166) | A food-healing-only configuration. | tuning | retired (replaced by [Immersive Healing](mods/immersive-healing/README.md)) |
| Configurable Economy (Crimsab) | A price preset for traders. | tuning | in use |
| Controller Tweaks (oOCamilleOo, 203) | The original shoulder and trigger layout restored as default. | key layout | in use |
| Uncapped Cutscenes - Animation Fix (author not recorded, 22) | Quieter logging. | performance | in use |
| Fang Prompt (WinterElfeas, 468) | Icon choice and folder layout. | packaging | in use |
| Focus Customizer (Saigofu, 546) | A stability rework of its update loop plus personal settings. | crash fix | in use |
| Headcovers (author not recorded) | Behaviour options for headgear and a fix for a wardrobe error. | feature, bug fix | in use |
| Knyaz Army Disguise (author not recorded) | The same headgear options plus a compatibility fix for the UE4SS build used here. | feature, bug fix | in use |
| Open Doors (Aloncifer, 140), MinimapOwn and Loot Rarity Sort (authors not recorded) | Key assignments changed to free keys for other mods. | key layout | in use |
| Infamy Tweaks (Caites, 507) | A logging option and settings. | feature | retired |
| Lasting Blood (author not recorded, 231) | Fixes so clothes get the longer blood fade, and a clothing option; its mouth and body settings left to [Blood Wash](mods/blood-wash/README.md). | bug fix | in use |
| Movement Tweaks (Caites, 345) | Speed-step hotkeys, later a version driven by the settings menu. | feature | the hotkey version retired, the menu version in use |
| SIGHT Sprint during Focus (author not recorded) | A rewrite that works without a particular UE4SS hook setting, and a key change. | compatibility | in use |
| Slow-mo And Pause (Caites, 367) | Key and visual settings. | tuning, key layout | in use |
| TBOD Photo Mode (Botan, 361) | A custom key layout and one extra option. | key layout | in use |
| Time Freeze (author and origin not recorded) | A key change. | key layout | in use |
| True Vampire (nickraven, 728) | Stability fixes for its update loop and personal settings. | crash fix | in use |
| Yet Another Deadline (Saigofu, 576) | Personal time-cost settings written into its defaults. | tuning | in use |

A load-safety review on 2026-10-24 also prepared small fixes for Better Enemy UI, FLY, Dynamic HUD (Koriik), Look Where You Aim and Faster Attacks, plus Lasting Blood, Time Freeze, True Vampire and MinimapOwn from the table. They exist only in a separate working copy and were never installed.

## Where a mod in this repository notices another author's mod

| Mod here | Other author's mod | What happens |
|---|---|---|
| [Blood Wash](mods/blood-wash/README.md) | Lasting Blood | Both can keep blood on Coen. In the test setup Lasting Blood's mouth and body settings were left empty so that Blood Wash controls them. With an unchanged Lasting Blood the end result is the same: Blood Wash rewrites the fade time within 5 seconds. |
| [Door Closer](mods/door-closer/README.md) | Open Doors | If Open Doors is installed, Door Closer adds two small hooks so that a door closed by key stays closed until Coen walks up to it. The local key change to Open Doors plays no part in this. |
| [Immersive Healing](mods/immersive-healing/README.md) | Configurable Combat Overhaul | Both can scale food healing; use only one. |
| [Level Ceiling](mods/level-ceiling/README.md) | No Level Scaling (Easy) by Caites | Designed to run next to it, unchanged. Not required. |

Back to the [mod list](README.md).
