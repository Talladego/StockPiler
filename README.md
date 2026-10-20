# StockPiler

StockPiler keeps the potions and plants you care about in stock. Watch an item, set how many you want, and let it grow, buy, and brew toward that amount.

**Version 1.0.1**

## Install

1. Download `StockPiler-1.0.1.zip` from [Releases](https://github.com/Talladego/StockPiler/releases).
2. Unzip it into `Interface/AddOns/` so the folder is `Interface/AddOns/StockPiler/`.
3. Reload the UI.
4. Open the window with `/stp` or `/stockpiler`.

LibSlash is optional. Without it, the window still loads, but the slash commands need to be bound yourself.

## What it does

- **Potions.** Lists recipes you have learned. Watch one to keep it in stock. Hover the scroll icon for the recipe. Forget removes that recipe from the list.
- **Plants.** Lists plants you have harvested or refined into a seed, and can grow again. Watch one to keep some in your bags. Plant watches are filled after potion watches.
- **Watch.** Set a target amount and a priority. Lower numbers are filled first. Plants always wait until potions are done.
- **AutoGrow.** Plants and refines the materials a watch still needs. Each potion watch has its own AutoGrow box.
- **Additives.** Applies soil, water, or nutrients from your crafting bag at the right stage of a grow.
- **Upgrade seeds.** Grows a lower-level seed up to the level a watch needs, then up toward the highest level your Cultivation can use.
- **AutoBuy.** While a vendor is open, buys the seeds, plants, and vials you are short. Reserve is gold left untouched. Budget is the most it may spend until you press Reset.
- **AutoBrew.** Brews a watch that is ready until it reaches its target. It waits while you are planting, refining, or harvesting.
- **Level up skills.** While Cultivation or Apothecary is under 200, practice rows appear on Watch after your real watches are stocked. Practice brews are not added to your known potions.
- **Craft button.** One action-bar button. It brews when a potion is ready, harvests when a plot is ready, and stays dark when there is nothing to do.

Automation starts off. Turn on only the parts you want.

## Commands

| Command | What it does |
| :--- | :--- |
| `/stp` | Open or close the window |
| `/stockpiler` | Same as `/stp` |
| `/stp potions` | Open the Potions tab |
| `/stp plants` | Open the Plants tab |
| `/stp watch` | Open the Watch tab |
| `/stp help` | Show the command list |
| `/stp chat on` | All StockPiler chat messages |
| `/stp chat quiet` | Changes, harvests, and brews only |
| `/stp chat off` | No StockPiler chat |

`/stp chat` by itself tells you which mode is on.

## License

StockPiler is MIT-licensed. See [LICENSE](LICENSE).
