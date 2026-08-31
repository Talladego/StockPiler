# StockPiler

Apothecary stock planner for [Return of Reckoning](https://www.returnofreckoning.com/) (Warhammer Online). Watch potions, grow plants, load recipes, and brew from the hotbar.

**Version:** 0.9.48

## Install

1. Copy the `StockPiler` folder into `Interface\AddOns\`.
2. Enable it in the Addon list.
3. `/reloadui`.

Optional: [LibSlash](https://www.curseforge.com/) (`/stockpiler`, `/stp`), PotionBar (effect classify).

## Open

- `/stockpiler` or `/stp`
- `/stp potions` · `/stp watch`
- `/stp quiet` · `/stp help` · `/stp debug` · `/stp scan` · `/stp seedmap` · `/stp growplan` · `/stp growwhy` · `/stp growtrace` · `/stp perf`

`/sp` is Scenario Chat, not this addon.

### Chat verbosity

| Command | What it does |
| :--- | :--- |
| `/stp quiet` | Cycle chat: **ALL** → **QUIET** → **OFF** → ALL |
| `/stp quiet all` | Plant/harvest/learn/stage spam on |
| `/stp quiet quiet` | Only manual enable/disable (AutoGrow, Additives, AutoBuy) |
| `/stp quiet off` | No status chat (slash replies still print) |

### AutoGrow decision debugging

| Command | What it does |
| :--- | :--- |
| `/stp growtrace` | Toggle live decision traces to `logs/uilog.log` (queue rebuilds, plants, refines) |
| `/stp growplan` | One-shot full plan dump (watches, ranked demand, ASSIGN/SKIP, plots) → uilog |
| `/stp growwhy` | Refresh plan + print last queue/plant/refine decisions (chat summary; full lines in uilog) |

When analyzing suboptimal grow picks, enable `growtrace`, let AutoGrow act, then `/stp growwhy` and share the `AutoGrow|` / `decision` lines from uilog.

## Saved data

| File | Contents |
| :--- | :--- |
| `user/settings/GLOBAL/StockPiler/` | Account knowledge (learn-only): brew / plant / harvest / refine / additives → `items`, `grows`, `refines`, `recipes`, `potions` |
| Shared Profile `.../StockPiler/` | UI prefs + `characters[CharacterName]` watches / AutoGrow / AutoBuy |

On upgrade to **0.9.0**, account knowledge is flushed and must be relearned (no migration from older `observedMats` / `observedPotions` / CraftValueTip data). On a Shared Profile, watches and toggles are keyed by character name. Flush both folders if you want a clean relearn.

## Tabs

| Tab | Purpose |
| :--- | :--- |
| Potions | Catalog, bag counts, learned recipes |
| Watch | Targets, Craftable*, AutoGrow, AutoBuy, One-Click Brew, Load/Brew |

Bag counts are local bags only.

## Hotbar macros

Created on first login. Drag them onto a bar if they are not there.

| Macro | Click | Ctrl-click |
| :--- | :--- | :--- |
| **StockPiler Harvest** | Harvest the next grown plot | Toggle AutoGrow |
| **StockPiler Brew** | Load the furthest-behind Ready-to-craft watch; later clicks brew it | Toggle One-Click Brew |

Watch Craft column buttons mirror Load → Brew (or faded Idle). Enable via **Enable One-Click Brew** on the Watch tab (same setting as Ctrl-click Brew).

Each harvest and each brew needs a click (`PerformCrafting`). AutoGrow plants, applies additives, and refines without clicks.

The brew macro will not fire while Load is running, or if the loaded recipe is incomplete or unstable. The stock Apothecary Brew button is not blocked.

## AutoGrow

When on (Harvest overlay, or Ctrl-click Harvest): plants from the grow queue, applies additives, refines plants back to the seed buffer. Harvest still uses the Harvest macro. Refine byproducts such as Arboreal Resin are not planted: AutoGrow grows extra of the recipe’s other plants and converts the surplus (plant→seed yields resin). If the recipe has no growable ingredients, it prefers same-level extenders, then any seed already in bags at that crafting level.

Shortage chat uses observed yield (bottles of that exact potion per successful brew). A crit (Potent) or an empty cauldron (fail) is not a success for that watch; the plan rebuilds if you are still short.

AutoBuy (Watch tab, off by default) purchases those same Watch shortages from an NPC vendor: flasks, butcher mats, missing seeds, and other non-growable slots. It never buys growable plants or refine byproducts, and it does not use the Auction House. Spending stops at the gold reserve or the per-visit budget. Confirm on Buy does not apply.

## Domain notes (cultivation / apothecary)

Reference for observed server behavior and Crafting-chat lines. Useful if we later add automated Cultivating / Apothecary skill-up. StockPiler today learns from bags + events; chat cues supplement Critical / fail flags (`StockPilerCraftChat`).

### Cultivation harvest outcomes

| Outcome | Typical effect | Crafting chat |
| :--- | :--- | :--- |
| Success | Normal plant yield (often 2 at high tier) | `You have harvested N Name.` |
| Critical Success | Yield +1 vs a normal harvest of the same seed | `Critical Success.` then the harvest line |
| Fail | Seed lost, no plant | `Your creation failed.` |

Plot phase spam (ignored by the chat allowlist): `Cultivation plot advanced to next phase.`, `Cultivation plot flowering completed.`

**Super-Critical (leveling, not skill 200 watches):** low-level seeds can Super-Critical into a **higher-tier plant** so players can climb materials while skilling. Level **200** seeds do not Super-Critical (tooltips show Fail Chance, not Super-Critical). Seeds may also list Fail Chance / Super-Critical Chance on the item itself.

### Cultivation additives

AutoGrow classifies additives from `craftingBonus` (see `StockPilerAdditives.lua`):

| Role | Typical bonuses (examples) |
| :--- | :--- |
| Soil | Stage grow time down, **Critical Chance** up (e.g. Arid Soil) |
| Watering | Stage grow time down, **Super-Critical Chance** up (e.g. Rusted Tin Watering Can) |
| Nutrient | Stage grow time down, **Fail Chance** down (e.g. Clotted Gore) |

"Use Additives" applies the best usable Soil / Watering / Nutrient from the crafting bag at the right growth stages (skill-gated).

### Apothecary brew outcomes

| Outcome | Typical effect | Crafting chat / detection |
| :--- | :--- | :--- |
| Success | Expected potion (exact uid for the watch) | `You created Name.` + bag delta |
| Critical Success | **Potent** (better) potion | `Critical Success.` then `You created Potent …` (quality from item name; not "main kept") |
| Main kept | Main ingredient remains in the cauldron | Inferred from cauldron contents after brew (chat does not label this clearly) |
| Fail | No potion (mats consumed / destroyed) | Engine `FAIL` + empty bag delta; exact chat line for unstable recipes still to confirm (`Your creation failed.` / `Critical Failure.` / other) |

Recipe identity is the ingredient fingerprint; Potent / good / volatile share one recipe with per-uid `outcomes`. Watch stock and Craftable* are exact uniqueID only. Mat profiles still store full craft bonuses (including `DESTROY_ON_FAIL`); that flag is omitted from recipe fingerprints so Artisan's vs Fabricated vials do not split into duplicate rows.

**Same potion, different recipes:** e.g. Draught via Multiplier vs Stimulant (resin or goldweed) are separate fingerprints. Potions tab columns show fingerprint stats (Power, Stability, Super-Crit, Yield); effect/rank/buff/duration stay in the icon tooltip. Watch the row for the path you want. Prefer enabling one recipe-watch per potion uid (bag stock is shared). Legacy watches on `uid:N` remap to `uid:N|rk:<activeRecipe>` on load.

### Future auto-skill (not implemented)

- **Cultivating:** plant low seeds, use additives for crit / super-crit / fail, harvest; Super-Crit may teach higher-tier plants; respect seed buffer on fails.
- **Apothecary:** brew unstable cheap recipes to skill; need confirmed fail chat + safety so Watch recipes stay separate from skill-up cauldron sessions.

## Debug

`/stp debug` toggles `StockPiler|` lines in `logs/uilog.log` (including brew/load steps and CraftChat cues). `/stp growtrace` toggles live AutoGrow traces independently; `/stp growplan` and `/stp growwhy` still one-shot to uilog. `/stp perf` is separate. `/stp seedmap` prints learned grows (seed→plants) and refines (plant→seed + resin).
