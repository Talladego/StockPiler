# Changelog

Newest sections first. The release workflow reads the `## X.Y.Z` section for the version it packs and refuses to publish when that section is missing.

## 1.1.4

- The Craftable count turns green only when a watched potion is ready to brew and its ingredients cover the target. Brew on that row follows the same rule.
- Watch status stays yellow while ingredients can still be grown, or while shared flasks are waiting on those plants.
- AutoGrow keeps planting while watched potions still need grown ingredients, even when shared materials already cover the bottle count.
- Harvesting, refining, and planting no longer close open quest, trainer, flight master, bank, or other NPC windows. Refining waits until the window closes.
- Zoning while cultivation is active no longer leaves backpack items or mounts unusable.
- AutoBuy prints its purchase queue in chat when the queue changes, remembers vendor prices for cost estimates, and formats gold, silver, and brass with coin icons.
- SkillUp AutoBuy only tops up the seed line it is planting (for example L100 Thief's Nettle), not leftover lower-tier seeds still short of the seed buffer.
- SkillUp no longer queues vials while Apothecary is waiting on the seed buffer or Cultivation; that was announcing a vial buy and clearing it when those mains were planted.
- Turning Optimistic mode off warns in chat when rare Potent recipes may queue large material purchases, and sizes material buys even before your first Potent proc.
- Watch finishes painting status, icons, priority, and Brew after login and when you open the tab. A potion or plant you just mark watched shows up immediately.
- Tooltips no longer keep a leftover "Right-click opens the StockPiler window" line. Checkbox tips open upward, recipe and Watch status tips open downward, and item tips sit like bag tips.
- A material you can grow is not treated as something you must buy when the recipe names a butcher ingredient. Brew still uses that butcher ingredient first when it is in your bags.
- A recipe tip shows a repeated ingredient once, with a count, instead of repeating the whole section.
- Bug fixes.
- Performance improvements.

## 1.1.3

- Shared recipes now prefer growable plants over butcher or vendor ingredients when known, and learning a shared recipe updates its ingredient list.
- AutoBuy now respects craft bag space (keeping one slot free) and prints a chat notice when paused by Reserve, Budget, or a full craft bag.
- Craft button and action bar macro now flash when a plant finishes growing.
- Bug fixes.
- Performance improvements.

## 1.1.2

- Fixes broken window title, chat, and tooltip text in 1.1.1.
- Cleaner `/stp help` command list.
- Bug fixes.
- Performance improvements.

## 1.1.1

- A recipe is saved when you brew it.
- Practice plots and surplus plantings use a basic additive. Plots grown for a watch or a seed upgrade use the best additive you have.
- Crafting messages follow the language of your client.
- Bug fixes.
- Performance improvements.

## 1.1.0

- Share a recipe from Potions or Watch: right-click and choose Link in chat, or Shift+left-click the potion's name, icon, or row. Copy string puts a plain recipe line in the chat box. `/stp link` repeats the last recipe you chose Link in chat for. Clicking a chat link, or `/stp apply`, opens a preview of the potion, its ingredients, and their crafting bonuses. Learn recipe adds it to Known Potions and does not create a watch. Cancel, the close button, and Escape leave your saved recipes unchanged. A different recipe for a potion you already know is stored as an alternative and does not replace your active recipe.
- Known Potions remember each variant's rarity and level, such as regular versus Potent on the same recipe, and color potion names by that rarity even when none are in your bags.
- Hovering Stock on a plant watch shows harvested plants and seeds in bags on separate lines. The Stock column stays the harvested-plant count. If the seed link is unknown, the tip says so.
- Refining a plant StockPiler has not seen before teaches its plant-to-seed link and adds that plant to Known plants, the same way harvesting does.
- `/stp harvest`, `/stp potions`, `/stp plants`, and `/stp watch` were removed. Use the window tabs. Harvesting still needs the craft button.
- A Craft button appears on screen by default. Drag it when it is idle, move or resize it in the Layout Editor, or hide it from the Watch tab. It starts unlocked. Shift+left-click locks it. `/stp button` sets the size (0.50-2.00, or 50%-200%) and the centered grow countdown.
- Turning the Craft Macro checkbox off removes the macro from your bars and deletes it. Turning it back on creates the macro again but does not put it back on a bar.
- The Craft button and hotbar macro show a red tint when StockPiler is waiting on you, and a grow countdown while plots are still growing. The tip explains what is missing when nothing is ready.
- AutoBrew keeps the Apothecary window hidden while it brews.
- Optional WarBoard chip (when WarBoard is installed): left-click opens or closes StockPiler; hover shows the Craft tip plus a click hint.
- Bug fixes.
- Performance improvements.

## 1.0.0

Initial public release.

StockPiler keeps the potions and plants you care about in stock. Watch an item, set how many you want, and let it grow, buy, and brew toward that amount.

- Potions lists learned recipes. Plants lists plants you have harvested and can grow again. Plant watches are filled after potion watches.
- Watch sets a target amount and a priority. Lower numbers are filled first.
- AutoGrow plants and refines what a watch still needs, and can apply soil, water, or nutrients. Upgrade seeds grow up to the level a watch needs.
- AutoBuy, while a vendor is open, buys the seeds, plants, and vials you are short. Reserve is gold left untouched. Budget is the most it may spend until you press Reset.
- AutoBrew brews a watch that is ready until it reaches its target, and waits while you are planting, refining, or harvesting.
- While Cultivation or Apothecary is under 200, practice rows appear on Watch after your real watches are stocked.
- One craft button brews when a potion is ready, harvests when a plot is ready, and stays dark when there is nothing to do. Automation starts off.
