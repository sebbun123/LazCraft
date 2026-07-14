# LazCraft

*All things LazCraft*

Welcome to the GitHub for LazCraft. Download the current version, report bugs, and let me know what's not working for you.

LazCraft is designed to be a one-stop crafting solution on Project Lazarus. It handles purchasing, handing off items, and even instructing casters to make summoned items. On the leveling path, it has pre-designed and suggested recipes — but it's completely configurable, so you can design your own leveling path with just a few seconds of effort.

The idea behind using LazCraft to level up a tradeskill is that you select a tradeskill and start it up. LazCraft handles all buying of kits (or going to your bank to grab them). It'll put the containers in Slot 10, and move any bags that might be lurking there. And when you're done, a quick button press will throw the containers and trophies back into the bank.

## Installation

Download the files. Place `TradeskillListener.lua` into your E3 Lua folder. The remaining files go into your `Lua > LazCraft` folder. If this is your first time using LazCraft, create a new folder and name it `LazCraft`.

In-game: type `/lua run Lazcraft` to start the Lua. Enjoy!

## Crafting Tab

This is where you'll be focused after you've hit 300 on most of the tradeskills. It has a dropdown where you can select a tradeskill and a short selection of items — but you can also search LazCraft's 11k+ recipes. It'll auto-swap your trophies prior to trying a combine, and once you're done with the combine, will replace whatever it's misplaced during the process.

## Leveling Tab

The Leveling Tab is where you go to level up your tradeskills. You'll get a welcome page when you first start it up. Read it, and after that pick which tradeskill you want to work on. Each tradeskill has a small selection of pre-selected suggested combines. You can remove them, add your own, or just start crafting.

Each recipe is iterative, meaning that if you pick Qty 100, it'll go and buy enough ingredients (or get them from your bots in a safe AFK zone) for 100 combines. If you're still below the trivial, it'll do it again. And again. Once that item is trivial, it'll move to the next and repeat until you're at the max your character can reach for that tradeskill (or the max your selected path can get you).

It'll use Geerloks you have on you, but it won't go searching too hard for them. I don't generally recommend bothering.

## Research

The Research Tab is for crafting spells. It does it very fast. As a note: casters can make spells only, while pure melee can make tomes *and* spells. I'd recommend spending the effort to get a melee up.

## Supply

Supply is how you request your bots to do things. You can ask casters to summon tradeskill items, or request your bots to check their bank for an item. There's a pre-selected list to make this easy — but, like all things LazCraft, you can request anything by typing it into the menu. You can choose a quantity from your bots, or just ask for literally every single one of that item.

## Stats

An easy way to verify your progress in each tradeskill.

## Settings

This contains your character-specific settings. If you're a necro and can't shop in Felwithe, you can skip traveling there and send a bot to do it for you. You can also add illusion items if you think they'll help.

## Travel

These are locations already mapped for traveling to vendor purchases. It's likely not very helpful, but it's there for people who might need to manually do something.

## TradeskillListener.lua

This is the true magic behind LazCraft's requests. It tells your characters what to do with the requests, and it's also behind requesting items from your group members. It's set to time itself out.
