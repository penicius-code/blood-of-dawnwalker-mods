# The Blood of Dawnwalker mods

UE4SS Lua mods for The Blood of Dawnwalker: blood, healing, wolf form, combat and quality-of-life changes, plus the research scripts and the linter behind them. Single-player only.
Tested in game between 2026-09-28 and 2026-10-12; the exact game build of each test was not written down, and the project notes from mid-October 2026 list game version 1.0.5. Every mod has its own README with install, rollback, compatibility and known issues.

**Featured:** [Standing Planeshift](https://github.com/penicius-code/dawnwalker-standing-planeshift)

> Unofficial fan-made modifications, not affiliated with or endorsed by Rebel Wolves or Bandai Namco Entertainment. No game files are included.

## Mods

Status: `tested` (this version was tested in game) | `earlier version tested` (the changes in this version were not tested in game; details in the mod's README) | `in use` (runs in the author's game, no written test record)

<details>
<summary><strong>Published on Nexus Mods</strong> (8)</summary>

| Mod | What it does | Requires | Status | Details |
|---|---|---|---|---|
| Standing Planeshift 1.0.3 | Coen stands upright on walls during Shadowstep; repairs a stuck-wolf bug | UE4SS | `tested` | [README](mods/standing-planeshift/README.md) (own repository), [Nexus](https://www.nexusmods.com/thebloodofdawnwalker/mods/676) |
| Immersive Healing build 13 | Food and salves heal slowly over a longer time; stamina drinks last longer | UE4SS | `tested` | [README](mods/immersive-healing/README.md), [Nexus](https://www.nexusmods.com/thebloodofdawnwalker/mods/679) |
| Blood Wash 0.8.2 | Blood stays on Coen; hotkeys play gestures that wash it off | UE4SS | `earlier version tested` | [README](mods/blood-wash/README.md), [Nexus](https://www.nexusmods.com/thebloodofdawnwalker/mods/708) |
| Blood Vials 1.4.1 | Draw blood from bodies into two vials and drink it later | UE4SS | `tested` | [README](mods/blood-vials/README.md), [Nexus](https://www.nexusmods.com/thebloodofdawnwalker/mods/710) |
| Wolf Form 0.2.0 | Stay in wolf form outside Haste, or switch by key | UE4SS | `earlier version tested` | [README](mods/wolf-form/README.md), [Nexus](https://www.nexusmods.com/thebloodofdawnwalker/mods/724) |
| Level Ceiling 1.1.0 | Caps how far enemies can be above Coen's level | UE4SS | `earlier version tested` | [README](mods/level-ceiling/README.md), [Nexus](https://www.nexusmods.com/thebloodofdawnwalker/mods/725) |
| Always Finishers 0.5.1 | Raises the health threshold for finishers | UE4SS | `earlier version tested` | [README](mods/always-finishers/README.md), [Nexus](https://www.nexusmods.com/thebloodofdawnwalker/mods/749) |
| No Lock Reticle 0.4.4 | Hides the lock-on reticle and fades enemy health bars | UE4SS | `earlier version tested` | [README](mods/no-lock-reticle/README.md), [Nexus](https://www.nexusmods.com/thebloodofdawnwalker/mods/750) |

</details>

<details>
<summary><strong>Finished, not published elsewhere</strong> (3)</summary>

| Mod | What it does | Requires | Status | Details |
|---|---|---|---|---|
| Door Closer 1.1.0 | Tap a key to close the nearest door; optionally force locked doors | UE4SS | `tested` | [README](mods/door-closer/README.md) |
| Corruption Rate 0.1.0 | Keeps only a set share of every corruption gain | UE4SS | `in use` | [README](mods/corruption-rate/README.md) |
| Hitch Watch 0.1.1 | Always-on stutter monitor that names the mods active around each hitch | UE4SS | `in use` | [README](mods/hitch-watch/README.md) |

</details>

The Mod Setting Menu is optional for every mod that has a `mod_settings.ini`; it adds an in-game settings page.

## Research

Small read-only scripts written to find out how a game system works before building a mod. Each README has the question, how it was measured, and what it found and led to.

| Probe | Question | Led to |
|---|---|---|
| [Hitch Probe](research/hitch-probe/README.md) | What causes a timed stutter, and what do engine lookups cost? | 34 to 44 ms per object search; the lookup rules used from then on, Hitch Watch, the linter |
| [Wolf Probe](research/wolf-probe/README.md) | Why does the wolf get stuck after wolf Haste plus Shadowstep? | The repair in Standing Planeshift 1.0.3 |
| [Shadowstep Probe](research/shadowstep-probe/README.md) | What decides where Shadowstep can aim, and can a dodge start while fleeing? | Options in another author's mod (see [COMPATIBILITY.md](COMPATIBILITY.md)) |
| [Finisher Probe](research/finisher-probe/README.md) | Why does a killing blow play a finisher or not? | Always Finishers |
| [Blood Probe](research/blood-probe/README.md) | How does blood on Coen work, and why is it gone in dialogues? | Blood Wash |

Shorter investigations without published code: [docs/investigations.md](docs/investigations.md).

## Install a mod (general steps)

1. Install the requirements listed for that mod (see [Common requirements](#common-requirements)).
2. Copy the contents of the mod's `package/` folder into the game folder, so that the folders line up with the game's own folders, for example `The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\ue4ss\Mods\BloodWash\Scripts\main.lua`.
3. Start the game once and check the log: `Dawnwalker\Binaries\Win64\ue4ss\UE4SS.log`.

## Common requirements

| Requirement | Minimum version | Where to get it |
|---|---|---|
| UE4SS for Dawnwalker | the build current in late September 2026 (the notes name 1.2.1-rc6) | [Nexus Mods, mod 18](https://www.nexusmods.com/thebloodofdawnwalker/mods/18) |
| Mod Setting Menu (optional) | 1.0.7.1 | [Nexus Mods, mod 271](https://www.nexusmods.com/thebloodofdawnwalker/mods/271) |

These are not bundled in this repository. Install them from their own pages.

## Uninstall / roll back

Each mod README lists exactly which folder it adds. Delete that folder under `Dawnwalker\Binaries\Win64\ue4ss\Mods\` to remove the mod. To return to an unmodified game, also remove UE4SS and let the game launcher verify the game files.

## Compatibility with other mods

The mods were tested next to many mods by other authors, some of them changed locally for personal use. [COMPATIBILITY.md](COMPATIBILITY.md) lists those changes in words and the few places where a mod here notices another author's mod. No mod here needs any of them.

## Repo layout

```text
mods/<mod>/README.md       per-mod documentation
mods/<mod>/package/        folder tree that mirrors the game install folder (the source is the Lua and ini files in it)
research/<probe>/          research scripts with their findings
docs/investigations.md     shorter investigations, no code
tools/lualint.py           Lua checker for these mods, with tests (tools/test_lualint.py)
COMPATIBILITY.md           local changes to other authors' mods, in words only
```

## Checks

Every push runs a Lua 5.4 syntax check of all Lua files, the project's own linter `tools/lualint.py` with its unit tests, and a secret scan. The linter checks syntax without a Lua interpreter and flags patterns that crashed or stalled the game while these mods were built: hooks on Blueprint functions, a load call that silently does nothing, object searches inside loops, game objects kept across loads, and loops that hand work between threads. Errors fail the build; warnings and notes are printed for review.

## Licence and credits

My code is MIT-licensed, see [LICENSE](LICENSE). Game files, names and trademarks belong to their owners; none are included here. The mods are loaded by UE4SS; the optional settings pages use Mod Setting Menu by mmarcussa.

Built with AI assistance (Claude); designed, tested and maintained by me.
