# Changelog

Newest sections first. The release workflow reads the `## X.Y.Z` section for the version it packs and refuses to publish when that section is missing.

## 1.1.0

- Share a recipe from Potions or Watch: right-click and choose Link in chat, or Shift+left-click the potion's name, icon, or row. Copy string puts a plain recipe line in the chat box. `/stp link` repeats the last recipe you chose Link in chat for. Clicking a chat link, or `/stp apply`, opens a preview of the potion, its ingredients, and their crafting bonuses. Learn recipe adds it to Known Potions and does not create a watch. Cancel, the close button, and Escape leave your saved recipes unchanged. A different recipe for a potion you already know is stored as an alternative and does not replace your active recipe.
- Known Potions remember each variant's rarity and level, such as regular versus Potent on the same recipe, and color potion names by that rarity even when none are in your bags.
- Hovering Stock on a plant watch shows harvested plants and seeds in bags on separate lines. The Stock column stays the harvested-plant count. If the seed link is unknown, the tip says so.
- Refining a plant StockPiler has not seen before teaches its plant-to-seed link and adds that plant to Known plants, the same way harvesting does.
- `/stp harvest`, `/stp potions`, `/stp plants`, and `/stp watch` were removed. Use the window tabs. Harvesting still needs the craft button.
- A Craft button appears on screen by default. Drag it when it is idle, move or resize it in the Layout Editor, or hide it from the Watch tab. It starts unlocked. Shift+left-click locks it. `/stp button` sets the size (0.50–2.00, or 50%–200%) and the centered grow countdown.
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
