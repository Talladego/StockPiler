# StockPiler

StockPiler keeps the potions and plants you care about in stock. Watch an item, set how many you want, and let it grow, buy, and brew toward that amount.

**Version 1.1.0**

## Install

1. Download `StockPiler-1.1.0.zip` from [Releases](https://github.com/Talladego/StockPiler/releases).
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
- **Craft button.** Shown on screen by default. It brews when a potion is ready, harvests when a plot is ready, and stays dark when there is nothing to do. Drag it when it is idle, move or resize it in the Layout Editor, or hide it from the Watch tab. The Craft Macro checkbox on Watch adds a hotbar macro you place yourself. Turning that checkbox off removes the macro from your bars. Turning it back on does not put it back.
- **Recipe links.** Right-click a potion on Potions or Watch and choose Link in chat, or Shift+left-click its name, icon, or row, to put `[StockPiler Recipe: <name>]` in the chat box (press Enter to send). Copy string puts a plain recipe line in the chat box so you can copy it. Clicking a link, or `/stp apply`, opens a preview of the potion and its ingredients. Learn recipe adds it to Known Potions. Cancel, the close button, and Escape leave your saved recipes unchanged. If you already know that recipe, Learn stays off. If you already know the potion, a different recipe is kept as an alternative and does not change your name, icon, or active recipe.
- **Plant stock.** Hover Stock on a plant watch to see harvested plants and seeds in bags separately. The Stock number stays the harvested-plant count. If StockPiler does not know which seed grows that plant, the tip says so.

Automation starts off. Turn on only the parts you want.

## Commands

| Command | What it does |
| :--- | :--- |
| `/stp` | Open or close the window |
| `/stockpiler` | Same as `/stp` |
| `/stp help` | Show the command list |
| `/stp button` | Show the Craft button scale |
| `/stp button <scale>` | Set the Craft button scale (0.50–2.00, or 50%–200%) |
| `/stp button timer [on\|off]` | Centered grow countdown on the Craft button |
| `/stp button reset` | Restore the Craft button (shown, unlocked, scale 1.00, timer on, centered) |
| `/stp chat` | Show the current chat mode |
| `/stp chat on` | All StockPiler chat messages |
| `/stp chat quiet` | Changes, harvests, and brews only |
| `/stp chat off` | No StockPiler chat |
| `/stp link` | Insert a recipe chat link for the last shared potion |
| `/stp apply <recipe>` | Open a preview of a pasted recipe. Learn adds it |

## License

StockPiler is MIT-licensed. See [LICENSE](LICENSE).
