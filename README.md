# StockPiler

Apothecary stock planner for [Return of Reckoning](https://www.returnofreckoning.com/) (Warhammer Online). Watch potions, grow plants, load recipes, and brew from the hotbar.

**Version:** 0.9.94

## Install

1. Copy the `StockPiler` folder into `Interface\AddOns\`.
2. Enable it in the Addon list.
3. `/reloadui`.

Optional: [LibSlash](https://www.curseforge.com/) (`/stockpiler`, `/stp`), PotionBar (effect classify).

## Open

- `/stockpiler` or `/stp`
- `/stp potions` · `/stp watch`
- `/stp quiet` · `/stp help` · `/stp debug` · `/stp scan` · `/stp seedmap` · `/stp growplan` · `/stp perf` · `/stp audit`

`/sp` is Scenario Chat, not this addon.

### Chat verbosity

| Command | What it does |
| :--- | :--- |
| `/stp quiet` | Cycle chat: **ALL** → **QUIET** → **OFF** → ALL |
| `/stp quiet all` | Plant/harvest/learn/stage spam on |
| `/stp quiet quiet` | Only manual enable/disable (AutoGrow, Additives, AutoBuy) |
| `/stp quiet off` | No status chat (slash replies still print) |

### Debug logging (`/stp debug`)

| Command | What it does |
| :--- | :--- |
| `/stp debug` | Toggle debug uilog on/off (**persists** across relog) |
| `/stp debug on` | Enable (persisted) |
| `/stp debug off` | Disable (persisted) |

When ON, writes structured op lines to `logs/uilog.log` (search `StockPiler|`):

| Prefix | When |
| :--- | :--- |
| `plant\|` | Each successful plant (plot, seed, reason, seeds left, garden empty/ready/growing) |
| `harvest\|` | Harvest start, done (gains / crit), or fail (Critical Failure) |
| `refine\|` | Each refine convert batch |
| `brew\|` | Load begin/loaded/fail, macro load/perform, one-click toggle |
| `buy\|` | Store visit start/end, purchase, wait (busy), stop (reserve/budget/cap) |
| `settings\|` | Watch enable/target/autoGrow, AutoGrow/Additives/AutoBuy/Brew toggles, seed buffer, buy chips |
| `AutoGrow\|` | Queue rebuilds, tick state, `/stp growplan` dumps |

`/stp growplan` still one-shots a full plan dump to uilog. `/stp growwhy` and `/stp growtrace` were removed (use `/stp debug`).

## Saved data

| File | Contents |
| :--- | :--- |
| `user/settings/GLOBAL/StockPiler/` | Account knowledge (learn-only): brew / plant / harvest / refine / additives → `items`, `grows`, `refines`, `recipes`, `potions` |
| Shared Profile `.../StockPiler/` | UI prefs + `characters[CharacterName]` watches / AutoGrow / AutoBuy |

On upgrade to **0.9.0**, account knowledge is flushed and must be relearned (no migration from older `observedMats` / `observedPotions` / CraftValueTip data). On a Shared Profile, watches and toggles are keyed by character name. Flush both folders if you want a clean relearn.

**0.9.49:** Fixed Watch toggles / seed buffer / AutoBuy chips resetting to defaults on login (a bind-time persist wipe). Re-set them once after `/reloadui`; they should stick afterward.

**0.9.50:** AutoBuy no longer overshoots material need (stale bag/spec counts after each purchase). Container matching requires skill tier. Reserve uses a visit money estimate; budget still caps spend per store visit.

**0.9.51:** Auto-merge duplicate learned recipes that differ only by legacy fingerprint noise (e.g. DESTROY_ON_FAIL bonus ref 15). Re-brewing no longer adds a second Potions row for the same loadout.

**0.9.52:** Grow/brew material guard — One-Click Brew respects AutoGrow seed-conversion reserves (strict by default). Refine only runs pre-plant or post-harvest, not idle while crops grow. `/stp growwhy` includes reservation breakdown. No extra bag refresh on macro clicks.

**0.9.53:** One-Click Brew load path skips `AddCraftingContainer` when slot 0 already has a flask (fixes spurious "Already has container" chat after brew/reload). Load retries advance when the slot fills instead of re-adding.

**0.9.54:** Fix startup crash: `RepairDuplicateRecipeFingerprints` called `RecipesTable` before the local helper was defined.

**0.9.55:** Fix startup crash: same forward-reference bug for `EnsureBrewStats`, `PotionActiveRecipeKey`, and `PotionRecipeKeys` in the recipe merge/dedupe path.

**0.9.56:** AutoGrow grow-cycle refine no longer blocked by brew surplus cap when seeds are needed to plant (fixes no-plant stall at 29/40 stabilizers with 0 seeds). `/stp growwhy` shows grow-cycle refine diagnostics.

**0.9.57:** AutoGrow refine policy — pre-plant converts only enough plants for empty plots; seed buffer refill and byproduct convert wait until after a successful harvest (aborted crops can refund seeds).

**0.9.58:** Post-harvest refine targets the seed buffer only (not max(emptyPlots, buffer)), so replanting does not keep converting one extra plant between each plot.

**0.9.59:** After harvest, keep buffer refill active until 4 seeds remain in bags *after* replanting (do not clear harvest when buffer is filled then immediately planted).

**0.9.60:** Post-harvest refine wants emptyPlots+seedBuffer in one pass (so 4 empty + buffer 4 with 2 on hand → refine 6, plant 4, leave 4). Re-arm harvest refine after the last plot is planted if the buffer is still short.

**0.9.61:** AutoGrow continues after plant targets are met when the seed buffer is short — plant remaining seeds for a buffer grow cycle (no longer blocked by brew-stocked plants that cannot be refined).

**0.9.62:** At plant-target + short buffer (e.g. 40 plants / 3 seeds), refine only the buffer gap (1) instead of planting leftover seeds. Harvest macro waits until harvest animation and post-harvest refine settle before the next harvest.

**0.9.63:** AutoGrow sizes plots from learned harvest yield (observed plants per harvest; default 1 until sampled). Level-200 double yields no longer plant one seed per missing plant.

**0.9.64:** Harvest loot no longer full-scans bags on every inventory event (fixes multi-second frametime spikes). Post-harvest refine targets empty plots only; seed buffer refill is surplus-gated while plant stock is still short of brew need.

**0.9.65:** Grow-cycle refine sizes seeds with learned harvest yield (ceil(plantDeficit / yield), capped by empty plots) so high-yield harvests do not over-convert into leftover seed stacks.

**0.9.66:** Mutual exclusion for cultivation — plant blocked while harvest op active (stage / pending notify / short lock); harvest macro blocked while plant AddCraftingItem pending or harvest cycle busy (safer under macro spam).

**0.9.94:** Persist craft-button checkbox overlays (ActionButton.UpdateInventory was hiding them); RequestRefresh applies immediately; Brew toggle syncs Watch One-Click Brew checkbox.

**0.9.93:** Hotbar craft buttons use checkbox-only mode indicators (no glow/anim); Cultivating/Apothecary switch between stock window open and hijacked Harvest/Brew by toggle; appearance refresh only on toggle/hotbar change (not cultivation bursts); hijacked Harvest/Brew tooltips unchanged.

**0.9.92:** Fix forward-reference crashes in macro ready cache and cultivation UI coalesce (`isBrewMacroEnabled`, `NowSecLocal`).

**0.9.91:** Break macro/hotbar appearance feedback loop (coalesce cultivation-driven glow refresh); guard Watch list rebuilds; snap-only bag flushes skip plan invalidation; prune orphan refine byproducts; `/stp audit` + `/stp perf summary`.

**0.9.90:** Fix post-login stock counts stuck at 0 — bag snap throttle no longer blocks the first inventory resnap or extends coalesce forever during cultivation bursts; force resnap on zone load and when opening the Watch tab while counts are stale.

**0.9.89:** Throttle cultivation-driven bag snaps and Watch repopulates (~10s stage ticks); stop full macro refresh on every plot stage change; remove per-inventory MarkAllPlotsWantFill spam.

**0.9.88:** Stop hotbar appearance refresh loop — cache game-action binds, skip rebind on glow-only refresh, drop SetButtonData on every hotbar event (fixes sustained 140–700ms frametime spikes / client crash).

**0.9.87:** Grow-cycle and queue refine respect brew surplus — harvested stabilizers stay in bags for brewing when still short; only plants above watch need convert back to seeds.

**0.9.86:** Fix hotbar appearance refresh storm (`SetActionData` targeted update + debounced full refresh); perf baseline stable.

**0.9.84:** Fix constant frametime stutter from per-frame cult/apo casting overlay hook; craft skills use checkbox overlay like macros. Glow/binding skip no-op updates.
**0.9.83:** Fix frametime stutter from hotbar appearance refresh on every UpdateInventory / animation tick; AutoGrow plants again while a brew board is loaded (idle); `/stp perf <ms>` sets hitch threshold.
**0.9.82:** Harvest/Brew glow only when the click would actually perform or start a load (not while busy, loading, grow-blocked, or mats missing).
**0.9.81:** Cultivating skill harvest uses the same hotbar `PERFORM_CRAFTING` path as the Harvest macro (`PerformCrafting()` is a silent no-op for cultivation).
**0.9.80:** Cultivating skill harvest uses `PerformCrafting` first (fixes false-success `WindowGameAction` that armed the lock without harvesting). One-Click Brew no longer keeps a stale “loaded” session after a main-kept brew or closes Apo on bag-miss (that dumped leftovers out of the crafting bag).
**0.9.79:** Stock Cultivating / Apothecary hotbar skills share AutoGrow / One-Click Brew with the macros — Ctrl-click toggles; while on, click harvests/brews (same checkbox + glow) instead of opening craft windows. Macros unchanged.

**0.9.78:** Last-seed AutoGrow warning uses yellow chat text; critical harvest failure that wipes bags/garden/plant mats posts a red “Lost seed line” alert.

**0.9.77:** Watch tab / `/stp clearwatches` — clear this character’s entire watch list (confirm dialog), for orphans left after forgetting recipes. Fix AutoGrow byproduct refine crash (`queue` nil in OnUpdate). Also: brew-spam plan throttle, harvest busy-gate fix, craftable rounding, settings toggles always logged to uilog.

**0.9.76:** Frametime hitch hardening for brew/harvest spam — snapshot indexes for seed/refinable counts (no per-call bag walks); soft post-brew count delta + coalesced flush instead of sync full snapshot; `/stp perf` logs FRAME lines even with an empty trail.

**0.9.75:** AutoGrow plant queue books empty plots from plant need covered by seeds + refinable plants (not seed-bag count alone), so a 4th plot is assigned when the 4th seed still needs refining.

**0.9.74:** Fix blank Potions/Watch list rows after tab restore — WAR ListBox labels need a populate while the tab is visible; prime both tabs on first open and re-populate after tab switches.

**0.9.73:** Persist last open StockPiler tab across reload/login. Shift-click Target / Seed buffer / Reserve / Budget for ±10. Removed the Watch-tab top Harvest button (use macro or per-row Craft).

**0.9.72:** AutoBuy review — structured `buy|` debug ops; skip buying while brew/harvest/plant/bag-work busy; live money vs reserve re-check; acquire-key fallback (no rebuy loop); per-visit purchase cap; job list cached until bag snapshot changes.

**0.9.71:** Quieter debug — `[Plan]` logs one rebuild summary (full dump still via `/stp growplan`); idle brew macro no longer spam-closes apo every click.

**0.9.70:** `/stp debug` state persists in profile SavedVariables. Quieter brew debug (no full bag dump; short potion keys). Idle AutoGrow tick no longer flip-flops plant-skip spam.

**0.9.69:** Quieter `/stp debug` — no per-tick plant-skip spam; short watch keys; harvest start no longer duplicates ready=; refine op lines always include seedUid.

**0.9.68:** Unified `/stp debug` op logging — each plant/harvest/refine/brew action and watch/settings change writes one `StockPiler| <kind>|` line to uilog. Removed `/stp growwhy` and `/stp growtrace` (use debug + `/stp growplan`).

**0.9.67:** One-Click Brew spam harden — `IsBusy` covers load job + apo PERFORMING + short post-perform lock; `BeginForRow` no longer cancels an in-flight load on spam.

## Tabs

| Tab | Purpose |
| :--- | :--- |
| Potions | Catalog, bag counts, learned recipes |
| Watch | Targets, Craftable*, AutoGrow, AutoBuy, One-Click Brew, Load/Brew |

Bag counts are local bags only.

## Hotbar macros and craft skills

Created on first login. Drag macros onto a bar if they are not there. Stock **Cultivating** / **Apothecary** skills on the hotbar share the same toggles (checkbox overlay when hijacked).

| Control | Click (feature on) | Click (feature off) | Ctrl-click |
| :--- | :--- | :--- | :--- |
| **StockPiler Harvest** macro | Harvest the next grown plot | Harvest if ready (macro always harvests) | Toggle AutoGrow |
| **Cultivating** skill | Harvest (does not open window) | Open Cultivation | Toggle AutoGrow |
| **StockPiler Brew** macro | Load / brew furthest-behind Ready watch | No-op when disabled | Toggle One-Click Brew |
| **Apothecary** skill | Load / brew (does not open window) | Open Apothecary | Toggle One-Click Brew |

When hijacked, hover shows the same Harvest/Brew tooltips as the macros. When off, stock tradeskill tooltips apply.

Watch Craft column buttons mirror Load → Brew (or faded Idle). Enable via **Enable AutoGrow** / **Enable One-Click Brew** on the Watch tab (same settings as Ctrl-click).

Each harvest and each brew needs a click (`PerformCrafting`). AutoGrow plants, applies additives, and refines without clicks.

The brew path will not fire while Load is running, or if the loaded recipe is incomplete or unstable. The stock Apothecary Brew button is not blocked.

## AutoGrow

When on (checkbox overlay on Harvest macro or Cultivating skill, or Ctrl-click either): plants from the grow queue, applies additives, refines plants back to the seed buffer. Harvest uses the Harvest macro or hijacked Cultivating skill. Refine byproducts such as Arboreal Resin are not planted: AutoGrow grows extra of the recipe’s other plants and converts the surplus (plant→seed yields resin). If the recipe has no growable ingredients, it prefers same-level extenders, then any seed already in bags at that crafting level.

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

`/stp debug` / `on` / `off` toggles structured `StockPiler| plant|` / `harvest|` / `refine|` / `brew|` / `settings|` / `AutoGrow|` lines in `logs/uilog.log`. Verbose brew `[Load]` breadcrumbs stay under the same gate. `/stp growplan` one-shots a full plan dump. `/stp perf on 100` logs FRAME hitches; `/stp perf summary` prints top trail signatures. `/stp audit` reports saved-data health; `/stp audit fix` prunes orphan refine byproducts. `/stp seedmap` prints learned grows and refines.

### Perf bisect (after `/reloadui`)

1. `/stp perf on 100` — stand at plots with Watch open + AutoGrow on for 2 minutes
2. `/stp perf summary` — note dominant trails
3. `/stp audit` then `/stp audit fix` if orphan byproducts reported
4. Repeat with Watch closed to isolate UI rebuild cost
5. Toggle AutoGrow off to isolate ProcessTick vs hotbar appearance refresh
