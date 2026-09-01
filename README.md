# StockPiler

Apothecary stock planner for [Return of Reckoning](https://www.returnofreckoning.com/) (Warhammer Online). Watch potions, grow plants, load recipes, and brew from the hotbar.

**Version:** 0.10.10

## Status

Core grow → harvest → refine → brew automation is in a good place for daily use. The **0.10.x** line adds a refine operation ledger, harvest-owned seed buffer maintenance, brew grow reserves, WorkCoordinator mutex (auto plant/refine vs user harvest/load/brew), and debug probes (`/stp growplan`, `/stp buyplan`, `/stp brewplan`).

**Validated in play (0.10.10):** one refine op per tick; no post-burn duplicate batches; seed buffer lands at the configured floor (e.g. Goldweed 8 → plant cycle → **5 at buffer=5**); AutoBuy skips growable seeds; brew defers while grow ops run.

**Next (near term):** UX/UI polish, more soak testing across seed lines and brew loads.

**Later (features):** surplus seed trim above buffer; plant stockpiling (hold harvested plants for brew instead of converting); automated Cultivating / Apothecary skill-up (see [Future auto-skill](#future-auto-skill-not-implemented)).

## Install

1. Copy the `StockPiler` folder into `Interface\AddOns\`.
2. Enable it in the Addon list.
3. `/reloadui`.

Optional: [LibSlash](https://www.curseforge.com/) (`/stockpiler`, `/stp`), PotionBar (effect classify).

## Open

- `/stockpiler` or `/stp`
- `/stp potions` · `/stp watch`
- `/stp quiet` · `/stp help` · `/stp debug` · `/stp seedmap` · `/stp growplan` · `/stp buyplan` · `/stp brewplan` · `/stp perf` · `/stp audit`

`/sp` is Scenario Chat, not this addon. Power-user probes (`spec`, `db`, `scan`) work but are omitted from `/stp help`.

### Chat verbosity

| Command | What it does |
| :--- | :--- |
| `/stp quiet` | Cycle chat: **ALL** → **QUIET** → **OFF** → ALL |
| `/stp quiet all` | Most actions and state changes (plant, refine, stage, learn, harvest, load, brew, settings) |
| `/stp quiet quiet` | User-triggered only: settings, harvest, load, brew |
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
| `refine\|` | Each refine convert batch (`outstanding=` counts in-flight ops; replaces `credit=`) |
| `ledger\|` | Refine op register/reconcile/reset (FIFO pipeline accounting) |
| `pipeline\|` | Refine delivery health (waiting/progressing/deviation) |
| `reserve\|` | Brew grow reserve when pipeline blocks plants (`brewAvail` may be negative) |
| `brew\|` | Load begin/loaded/fail, macro load/perform, one-click toggle |
| `buy\|` | Store visit start/end, job list, purchase, wait (busy), stop (reserve/budget/cap), skip (no-match/acquired/snapshot/buyback) |
| `settings\|` | Watch enable/target/autoGrow, AutoGrow/Additives/AutoBuy/Brew toggles, seed buffer, buy chips |
| `AutoGrow\|` | Queue rebuilds, tick state, `/stp growplan` dumps |
| `work\|` | WorkCoordinator completion breadcrumbs |

`/stp growplan` one-shots a full plan dump to uilog (includes `LEDGER` lines per seed line). `/stp buyplan` one-shots the AutoBuy job list. `/stp brewplan` one-shots the brew queue with per-watch why lines and grow reservations. `/stp perf` is the hitch logger (session-only).

## Saved data

| File | Contents |
| :--- | :--- |
| `user/settings/GLOBAL/StockPiler/` | Account knowledge (learn-only): brew / plant / harvest / refine / additives → `items`, `grows`, `refines`, `recipes`, `potions` |
| Shared Profile `.../StockPiler/` | UI prefs + `characters[CharacterName]` watches / AutoGrow / AutoBuy |

On upgrade to **0.9.0**, account knowledge is flushed and must be relearned (no migration from older `observedMats` / `observedPotions` / CraftValueTip data). On a Shared Profile, watches and toggles are keyed by character name. Flush both folders if you want a clean relearn.

### 0.10.x (current)

**0.10.10:** Refine overshoot fix — one `SendUseItem` per tick; no re-fire during settle/outstanding; grow-cycle uses raw bag+in-flight+in-ground credit; burn-stale waits `PIPELINE_GRACE_SEC` without immediate re-queue.

**0.10.9:** `/stp brewplan` — one-shot brew queue dump (next pick, per-watch why, raw vs reserved craftable, grow reservations).

**0.10.8:** AutoBuy debug — `/stp buyplan`, visit job lines, skip/no-match logging. Brew-shield refine (`uses=1` when `live=0`, no in-ground seeds, plants available); in-ground seed credit for brew grow reserve (`inGround` in grow plan ledger).

**0.10.7:** Post-burn buffer overshoot — live-aware harvest buffer gate (`SeedLineHarvestBufferSatisfied`); post-burn settle cooldown (`REFINE_SETTLE_SEC`); orphan delivery reconcile (`ledger| orphan-delivery`); seed buffer slider no longer triggers immediate refine.

**0.10.6:** Post-harvest fix — harvested seed line refined first; stale ledger ops burn on pipeline deviation (`ledger| burn-stale`); split actionable vs awaiting-delivery maintenance (grow-cycle defer only when actionable); replant held while same-line `outstanding > 0`.

**0.10.5:** Four-operation pipeline — Harvest owns post-harvest seed buffer (bypasses brew-short); `plantAvail = plantHave − outstanding`; per-seed-line plant hold until buffer credit settles; defer grow-cycle while harvest maintenance pending; plant-need refine (1 op when live=0); uproot triggers same buffer maintenance; harvest blocked during brew session.

**0.10.4:** Refine operation ledger — FIFO per-`SendUseItem` ops trusted until bags confirm; credit-aware post-harvest buffer (`seedAvail = live + outstanding`); plant hold stalls on live seeds only; brew reserves in-flight refines; pipeline deviation toasts; `ledger|`, `pipeline|`, `reserve|` debug prefixes.

**0.10.3:** Fix refine-credit deadlock — release plant/harvest hold once seed need is satisfied; decay pending when credited; 10s stale-credit timeout; coalesce macro refresh.

**0.10.2:** Durable seed refine credit until bags catch up — stops grow-cycle re-fire while pending decays and seedHave stays flat (no more 7 spores vs buffer 4).

**0.10.1:** Stop AutoGrow over-refine — queue plant-need only counts empty plots that want fill; credit in-flight refine toward seed need (no spam while bags lag).

**0.10.0:** WorkCoordinator (auto plant/refine vs user harvest/load/brew), refine policy (plant-need without surplus stall; post-harvest buffer only), brew/grow time+material mutex, combat/RvR lake defer for full bag snaps, chat quiet = settings/harvest/load/brew, slash trim, drop Watch “Converting material” status.

### 0.9.x (prior release)

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

Four operations (0.10.5): **Plant** uses live seeds only (refines first if needed). **Harvest** maintains the seed buffer after each harvest or uproot (`seedAvail = live + outstanding`; bypasses brew-short). **Refine** reserves plants per in-flight op (`plantAvail = plantHave − outstanding`). **Brew** never consumes seeds; blocks auto ops while a brew session is loaded. Replant for a seed line is held until its post-harvest buffer credit settles.

Shortage chat uses observed yield (bottles of that exact potion per successful brew). A crit (Potent) or an empty cauldron (fail) is not a success for that watch; the plan rebuilds if you are still short.

AutoBuy (Watch tab, off by default) purchases those same Watch shortages from an NPC vendor: flasks, butcher mats, and other non-growable slots. Growable plants and seeds are handled by AutoGrow, not AutoBuy. It never buys growable plants or refine byproducts, and it does not use the Auction House. Spending stops at the gold reserve or the per-visit budget. Confirm on Buy does not apply.

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

### Planned features (not implemented)

| Feature | Intent |
| :--- | :--- |
| **Surplus trim** | When seeds exceed buffer + committed plant queue, stop refining or optionally convert/sell excess (today buffer is a floor only). |
| **Plant stockpiling** | Keep harvested plants in bags for brewing when watch demand exists, instead of always converting back to seeds at buffer maintenance. |
| **Auto skill-up** | Separate Cultivating / Apothecary leveling sessions (see below). |

### Future auto-skill (not implemented)

- **Cultivating:** plant low seeds, use additives for crit / super-crit / fail, harvest; Super-Crit may teach higher-tier plants; respect seed buffer on fails.
- **Apothecary:** brew unstable cheap recipes to skill; need confirmed fail chat + safety so Watch recipes stay separate from skill-up cauldron sessions.

## Debug

`/stp debug` / `on` / `off` toggles structured `StockPiler| plant|` / `harvest|` / `refine|` / `ledger|` / `pipeline|` / `reserve|` / `brew|` / `buy|` / `settings|` / `AutoGrow|` lines in `logs/uilog.log`. Refine lines use `outstanding=` (in-flight ops), not `credit=`. Pipeline deviation toasts appear in quiet/all chat modes. Verbose brew `[Load]` breadcrumbs stay under the same gate. `/stp growplan` one-shots a full plan dump (includes `LEDGER` per seed line). `/stp buyplan` one-shots the AutoBuy job list. `/stp brewplan` one-shots the brew queue with per-watch why lines. `/stp perf on 100` logs FRAME hitches; `/stp perf summary` prints top trail signatures. `/stp audit` reports saved-data health; `/stp audit fix` prunes orphan refine byproducts. `/stp seedmap` prints learned grows and refines.

### Perf bisect (after `/reloadui`)

1. `/stp perf on 100` — stand at plots with Watch open + AutoGrow on for 2 minutes
2. `/stp perf summary` — note dominant trails
3. `/stp audit` then `/stp audit fix` if orphan byproducts reported
4. Repeat with Watch closed to isolate UI rebuild cost
5. Toggle AutoGrow off to isolate ProcessTick vs hotbar appearance refresh
