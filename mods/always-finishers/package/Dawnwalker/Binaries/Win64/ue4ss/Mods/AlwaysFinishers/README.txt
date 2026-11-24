ALWAYS FINISHERS 0.5.1 (beta)
The Blood of Dawnwalker, UE4SS mod

Finishers trigger at a higher enemy health. Vanilla: about 20% for guards, 10% for heavies and rogues.

REQUIREMENTS
  UE4SS for Dawnwalker (Nexus mod 18, required)
  Mod Setting Menu (Nexus mod 271, optional, adds an in-game settings page)

INSTALL
  Vortex: install the archive, choose Root (game folder) if asked, deploy.
  Manual: extract the archive into the game folder (the one with the Dawnwalker and Engine folders)
  so this file exists:
    Dawnwalker\Binaries\Win64\ue4ss\Mods\AlwaysFinishers\Scripts\main.lua

USAGE
  Switch it on and off in the Mod Setting Menu.
  Settings: Mod Setting Menu, or Mods\AlwaysFinishers\config.ini (re-read every 2 seconds):
    Enabled      1
    Threshold   30  enemy HP percent where finishers become possible (never below the game's own value)
    Rearm        1  keep enemies at or below the threshold marked for a finisher (also when blinded)
    TickMs     100  check interval
    Logging      0  [AlwaysFinishers] lines in ue4ss\UE4SS.log (bug reports)

LIMITS
  A blow from above the threshold straight to zero gets no finisher. None on ability, bleed or Shadowstorm kills.

CHANGELOG
  0.5.1  Keeps working after loading a save: the threshold is re-applied after every load
         (0.5.0 lost it until the game was relaunched). Untested by the author, please report.
  0.5.0  First release (beta).

UNINSTALL
  Delete the AlwaysFinishers folder. No game files or saves are changed.
