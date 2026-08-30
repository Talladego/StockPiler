# StockPiler

Apothecary stock planner for [Return of Reckoning](https://www.returnofreckoning.com/) (Warhammer Online). Watch potions, grow plants, load recipes, and brew from the hotbar.

**Version:** 0.8.75

## Install

1. Copy the `StockPiler` folder into `Interface\AddOns\`.
2. Enable it in the Addon list.
3. `/reloadui`.

Optional: [LibSlash](https://www.curseforge.com/) (`/stockpiler`, `/stp`), PotionBar (effect classify), CraftValueTip (seed/plant data).

## Open

- `/stockpiler` or `/stp`
- `/stp potions` · `/stp watch`
- `/stp help` · `/stp debug` · `/stp scan` · `/stp growplan`

`/sp` is Scenario Chat, not this addon.

## Tabs

| Tab | Purpose |
| :--- | :--- |
| Potions | Catalog, bag counts, learned recipes |
| Watch | Targets, Craftable*, AutoGrow, Load |

Settings are per character. Bag counts are local bags only.

## Hotbar macros

Created on first login. Drag them onto a bar if they are not there.

| Macro | Click | Ctrl-click |
| :--- | :--- | :--- |
| **StockPiler Harvest** | Harvest the next grown plot | Toggle AutoGrow |
| **StockPiler Brew** | Load the furthest-behind Ready-to-craft watch; later clicks brew it | Cancel brew session |

Each harvest and each brew needs a click (`PerformCrafting`). AutoGrow plants, applies additives, and refines without clicks.

Brew will not fire while Load is running, or if the Apothecary recipe is incomplete or unstable.

## AutoGrow

When on (Harvest overlay, or Ctrl-click Harvest): plants from the grow queue, applies additives, refines plants back to the seed buffer. Harvest still uses the Harvest macro.

Shortage chat uses recipe yield (Lasting is 2 potions per brew). Potent crits do not count toward that Lasting watch; the plan rebuilds if you are still short.

## Debug

`/stp debug` toggles `StockPiler|` lines in `logs/uilog.log`. Load steps always write there. `/stp growtrace` toggles AutoGrow decision traces.
