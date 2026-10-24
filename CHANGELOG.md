# Changelog

Newest sections first. The release workflow reads the `## X.Y.Z` section for the version it packs and refuses to publish when that section is missing.

## 1.1.0

- Recipe linking: right-click a potion on Potions or Watch and choose Link in chat to insert `[StockPiler Recipe: <name>]`. Shift+left-click the potion's name, icon, or row puts the same chat link in the box. Ordinary clicks stay as they are. Plants and practice rows do not link. Copy string puts a plain recipe line in the chat box. Clicking a link, or using /stp apply, opens a preview of the potion and its ingredients, including crafting bonuses. Learn recipe adds it to Known Potions and does not create a watch. Cancel, the close button, and Escape leave saved recipes unchanged. If you already know that recipe, Learn stays off. A different recipe for a potion you already know is stored as an alternative and does not change the potion name, icon, or active recipe. A recipe you already have is left unchanged. `/stp link` repeats the last recipe you chose Link in chat for (this session). A material stat of zero is kept in the link, so learning it does not add a second copy of that recipe. Does not auto-send chat.
- Multi-ingredient recipe links survive sending and opening the preview.
- A recipe link can be learned only when it includes a main ingredient and a container, so a cut or incomplete link does not add a one-ingredient recipe. A grammar mark in the potion name is left out of the link.
- Link in chat, Copy string, and /stp link skip a recipe that has no container. They say that it needs a main ingredient and a container.
- Known Potions keep each variant's rarity and level (regular vs Potent on the same recipe). Recipe links can carry those values; older links without them still import. Name tint uses the saved rarity when bags have no sample.
- Hovering Stock on a plant watch shows harvested plants and seeds in bags on separate lines. The Stock column stays the harvested-plant count. If the seed link is unknown, the tip says so.
- Refining a plant StockPiler has not seen before teaches its plant-to-seed link and adds that plant to Known plants, the same way a harvest does. Known conversions still record. An unrelated gain, a seed packet, a stack move, or more than one possible output is not saved, and an unknown result does not mark the plant convert-failed.
- `/stp harvest`, `/stp potions`, `/stp plants`, and `/stp watch` were removed. Use the window tabs. Harvesting still needs the craft button.
- A Craft button appears on screen by default. Drag it when it is idle, move or resize it in the Layout Editor, or hide it from the Watch tab. It starts unlocked. Shift+left-click locks it. `/stp button` sets the size (0.50–2.00; numbers up to 10 clamp; above 10 up to 200 is a percent) and the centered grow countdown.
- Turning the Craft Macro checkbox off removes the macro from your bars and deletes it. Turning it back on creates the macro again but does not put it back on a bar.
- The Craft button and hotbar macro show a red tint when StockPiler is waiting on you, and a grow countdown while plots are still growing. The tip explains what is missing when nothing is ready. A hotbar Craft press briefly squashes the on-screen button.
- Optimistic mode off also accounts for harvest critical failures once a seed has enough samples. A harvest critical failure is reported on that harvest.
- Optional WarBoard chip (when WarBoard is installed): left-click opens or closes StockPiler; hover shows the Craft tip plus a click hint.
- Unplaced Craft chat says "Craft macro" and warns once per UI load, after your hotbars have loaded.
- AutoBrew keeps the Apothecary window hidden while it brews, including on the first brew after login and right after a brew ends. Pressing the Apothecary ability during a brew is ignored until the brew finishes.
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
