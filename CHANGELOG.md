# Changelog

Newest sections first. The release workflow reads the `## X.Y.Z` section for the version it packs and refuses to publish when that section is missing.

## 1.0.1

- Recipe linking: right-click a potion on Potions or Watch and choose Link in chat to insert `[StockPiler Recipe: <name>]`. Copy string puts a plain recipe line in the chat box. Clicking a link adds that recipe to Known Potions when you do not already have it, and does not create a watch. If you already know the potion, a different recipe is stored as an alternative and does not change the potion name, icon, or active recipe. A recipe you already have is left unchanged. `/stp link` repeats the last recipe you chose Link in chat for (this session). `/stp apply` is an advanced command for a pasted plain string. A material stat of zero is kept in the link, so importing it does not add a second copy of that recipe. Does not auto-send chat.
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
