# LazCraft

Tradeskill automation for EverQuest Project Lazarus, as a MacroQuest Lua script. It plans a craft from the
recipe data (what you have, what to buy and where, what to make first), travels, banks, shops, and makes it -
at kits and world stations - and can use your other characters as workers that bring, buy or summon what a
recipe needs.

LazCraft 1.10 is the rewrite that was called LazCraft2 during testing. It replaces the old LazCraft.

## Install / update

Use the AdventureTime Patcher: https://github.com/sebbun123/AdventureTimePatcher/releases/latest

Pick **LazCraft**, choose your MacroQuest folder, and click **Update Now**. It installs to
`<MacroQuest>/lua/lazcraft/`, checks every file against `manifest.txt` before changing anything, keeps a backup of
what it replaces in `config/LazCraftPatcher_backup/`, and never touches `settings/` or `logs/`.

Updating from the old LazCraft: its files that 1.10 no longer uses (the top-level `tradeskills.ini`,
`merchants.ini`, `research.ini`, `stations.ini`, `fishing.ini`, `TradeskillListener.lua`, `update.bat`) are moved to
that backup folder.

## Running

- Crafter: `/lua run lazcraft`
- Worker (another character, working for the crafter): `/lua run lazcraft worker <crafter>`
- Commands: `/lc show | hide | go | cancel | pause | resume | stop | quit`, `/lc make <combines> <recipe>`,
  `/lc plan <combines> <recipe>`, `/lc level <skill>` and more - `/lc` alone lists them.

Every character on the network has to run the same LazCraft version: LazCraft2 and 1.10 do not talk to each other.

## Files

- `settings/LazCraft_<Name>.ini` - each character's settings (the window's Settings tab edits them live)
- `settings/data_cache.lua` - the recipe data, prepared once for quick starts (safe to delete)
- `logs/LazCraft_<Name>.log` - every step, for reports
- `NOTES.md` - how it works and why, rule by rule
