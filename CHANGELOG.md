# Changelog

Newest sections first. The release workflow reads the `## X.Y.Z` section for the version it packs and refuses to publish when that section is missing.

## 1.0.1

- Refining a plant StockPiler has not seen before teaches its plant-to-seed link and adds that plant to Known plants, the same way a harvest does. Known conversions still record. An unrelated gain, a seed packet, a stack move, or more than one possible output is not saved, and an unknown result does not mark the plant convert-failed.
- The `/stp harvest`, `/stp potions`, `/stp plants`, and `/stp watch` commands were removed. Use the window tabs instead. Harvesting still needs the craft button.
- `/stp reset` restores settings defaults for this character (toggles, watches, HUD prefs). Learned recipes and plants are kept.
- Floating Craft HUD: idle drag, Shift+left-click lock (same as Layout Editor), optional grow countdown, Watch HUD Button / scale chip / Craft Macro checkbox. Default scale 1.0.
- Craft HUD stays fully on-screen while dragging; grow cooldown tint matches stock action bars (`20,20,50` @ 0.75).
- Craft/macro tips paint all rows on first hover (extra DefaultTooltip rows are pre-warmed).
- Hotbar Craft presses briefly squash the HUD icon via EventBus; unplaced-Craft chat warns once until the macro is on a bar.
- Harvest critical-fail chat prints on that harvest (no longer delayed until the next click).
- Craft macro and HUD show a red tint when StockPiler is waiting on you (vendor / buy). Grow countdown uses the stock cooldown wipe and centered timer text.
- When nothing is ready, the craft tip explains AutoGrow off and lists short watches (including per-watch AutoGrow off).
- Optimistic mode off also accounts for harvest critical failures (plant extra seeds) once a seed has enough harvest samples.
- Optional WarBoard chip (when WarBoard is installed): left-click opens or closes StockPiler; hover shows the Craft tip plus a click hint.
- Unplaced Craft chat line says "Craft macro" instead of "Craft".
- AutoBrew keeps the Apothecary window hidden while it brews, including on the first brew after login and right after a brew ends. Pressing the Apothecary ability during a brew is ignored until the brew finishes.

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
