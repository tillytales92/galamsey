# Event Study — Design and Implementation Notes

**Core hypothesis:** upstream galamsey mining degrades agricultural/vegetation productivity
downstream via waterborne contamination (mercury, sediment, turbidity). NDVI/EVI are the outcome
proxies. Q0 is a mechanics sanity check that precedes this hypothesis test; Q2 asks a related but
distinct question (does mining itself spread to neighbouring hexes, rather than just degrading
their vegetation).

**Runnable code — split 2026-07-08 into three self-contained, independently-knittable files**
(this directory), replacing the single combined `a_05_event_study.Rmd`:

- **`a_05_event_study_1.Rmd`** — **Q0**.
- **`a_05_event_study_2.Rmd`** — **Q1** (the bulk of the original document — V1 through V3b).
- **`a_05_event_study_3.Rmd`** — **Q2**, restored to working order as part of the split (it had
  been fully disabled, HTML-commented + `eval=FALSE`, since 2026-06-30).

Each file duplicates the shared setup it needs (package loading, `save_es`/`save_md`/
`save_md_grouped` export helpers, the `load-panel` chunk, the relevant subset of the C&S helper
functions) rather than sourcing a shared script — no script in this repo `source()`s another. Code
specific to one question is *not* duplicated into the others: the neighbour-role schematic and the
`spdep`/`fixest`/`panelView`/`DIDmultiplegtDYN` dependencies only appear in the files that use
them (`_1` needs none of them; `_2` needs all of them; `_3` needs `spdep`+`fixest` only).

**Panel source:** `2_build/b_03e_assemble_eventpanel.R` → `data/processed/event_panel_{1|2|5}km.rds`.  
**Resolution:** set via `params$resolution_km`; see resolution analysis below — **5 km is primary**.

**Three questions share one panel:**

| | Q0 — Mechanics sanity check | Q1 — Waterborne degradation | Q2 — Mining diffusion |
|---|---|---|---|
| Outcome | own-hex vegetation | downstream vegetation (NDVI/EVI) | own-hex mining (intensity + onset) |
| Treatment | own-hex mining onset | upstream mining onset | neighbour mining onset |
| Right neighbour | none (no flow graph) | directed upstream (flow graph) | adjacency (queen) + upstream river-corridor |
| Placebo | — | downstream onset | downstream onset |
| File | `a_05_event_study_1.Rmd` | `a_05_event_study_2.Rmd` | `a_05_event_study_3.Rmd` |

**Q0** exists to validate the panel/estimator mechanics before trusting Q1/Q2's spillover claims:
if mining within a hex doesn't measurably depress that hex's own vegetation, something is wrong
upstream of the fancier designs (panel construction, outcome definition, event-time coding). It
requires no flow graph, so it works even before `b_03c_flow_graph.R`/`b_03d_flow_exposure.R` have
been run for a given resolution.

**Q2** is the `a_02` D2d spatial-lag regression upgraded from naïve TWFE on the neighbour stock to
a staggered event study with pre-trends and heterogeneity-robust estimators.

---

## Conceptual framework — neighbour definitions

The schematic in `a_05_event_study_2.Rmd`/`a_05_event_study_3.Rmd` (`schematic-neighbours` chunk,
identical in both — Q0 doesn't need it) shows a synthetic 5 km hex grid with a synthetic river and
**five treatment groups**: upstream-all-reachable, upstream-1-hop, lateral (queen-adjacent, off
the flow path), downstream-1-hop, downstream-all-reachable. This is the real five-group MERIT
extension — the two-group northing-only illustration it originally replaced (2026-06-30) is gone.

| Group | Treatment role |
|-------|---------------|
| upstream-all | Q1 treatment: any reachable upstream hex starts mining |
| nearest-upstream (1-hop) | Q1 headline variant: immediate D8 predecessors only |
| lateral | Q1/Q2 comparison: queen-adjacent minus 1-hop up/down (no water link) |
| nearest-downstream (1-hop) | Q1/Q2 placebo: immediate D8 successors |
| downstream-all | Q1/Q2 placebo: all reachable downstream hexes |

Built from `hex_sf` + `hex_flow_edges_{N}km.csv` (the actual MERIT D8 graph), so labels match the
event-study treatment columns exactly.

---

## Data foundations

### Panel

`event_panel_{N}km.rds` is assembled by the build pipeline:

| Script | Output | Re-run when |
|--------|--------|-------------|
| `b_03a_vi_panel.R` | `hex_{N}km_vi_panel.rds` | New GEE rasters / ESA CCI download changes |
| `b_03b_own_mining.R` | `hex_{N}km_own_mining.rds` | Barenblitt data updated |
| `b_03c_flow_graph.R` | `hex_flow_edges_{N}km{S}.csv` | New resolution or MERIT rerun |
| `b_03d_flow_exposure.R` | `hex_{N}km_flow_exposure{S}.rds` | Flow edges changed or new vars |
| `d_07_hydrobasins.R` | `hydrobasins/hex_basin_{N}km.csv` | HydroBASINS download changes |
| `b_03e_assemble_eventpanel.R` | `event_panel_{N}km.{csv,rds}` | Any upstream change |

`b_03c` loops over `RESOLUTIONS <- c(1, 2, 5)` and writes flow edges for all resolutions whose
`hex_{N}km_crosssection.rds` cache exists; no code change needed to extend to 1/2 km — just run it.
`b_03c`/`b_03d` also carry a second `ROUTE_KM2 = 50` threshold (`_upa50`-suffixed columns) as an
alt routing-cutoff robustness set alongside the primary `ROUTE_KM2 = 10`; **not currently wired
into any Q1 design** (would need a second treatment-definition dimension threaded through Q1).

**Panel dimensions (as of 2026-06-26):**

| Resolution | Hexes | Rows | Ever-mined | Adj-mining hexes |
|-----------|-------|------|------------|-----------------|
| 1 km | 80,716 | 2,502,196 | 3,522 | 8,726 |
| 2 km | 20,386 | 631,966 | 1,690 | 4,152 |
| 5 km | 3,348 | 103,788 | 652 | 1,431 |

Flow graph populated at all three resolutions. Upstream columns (up/down/nearest) are NA until
`b_03c`/`b_03d` run for that resolution (`has_upstream` guards every Q1/Q2 chunk that needs them).
The 25-column peak-VI panel (below) is currently built for **5 km and 2 km only** — 1 km is
deferred pending a faster zonal-stats engine (see `b_03a_vi_panel.R`'s tasklist entry).
HydroBASINS SE-clustering columns (`basin_num` etc.) are populated for 5 km and 2 km; 1 km has not
had `d_07_hydrobasins.R` run for it.

### Resolution analysis

**5 km is the primary grid.** Key constraints:

| Issue | 1 km | 2 km | 5 km |
|-------|------|------|------|
| Flow graph (Q1) | ✓ (since b_03c run) | ✓ | ✓ |
| Peak-VI panel (Q0/Q1 outcomes) | ✗ (deferred) | ✓ | ✓ |
| Gold suitability valid | ✗ (1:10M scale) | ✗ | ✓ |
| Adjacency diffusion ID | ✗ (mine expansion, not spread) | ✓ (robustness) | ✓ (headline) |

2 km is worth running as a Q2 adjacency robustness check; footnote the gold-suitability caveat.
1 km is problematic on multiple fronts — at most a descriptive panel, and currently missing
outcomes entirely (no VI panel).

### Full variable inventory

| Column | Description | Status |
|--------|-------------|--------|
| `own_new_ha` | Annual new artisanal mining ha in focal hex | ✓ all resolutions |
| `own_stock_ha` | Cumulative own mining ha | ✓ |
| `own_onset_year` / `first_treat_own` | First year `own_new_ha > 0` | ✓ |
| `adj_new_ha` | Sum of `own_new_ha` over queen-adjacent neighbours (focal excluded) | ✓ |
| `adj_stock_ha` | Cumulative adj mining ha | ✓ |
| `adj_onset_year` / `first_treat_adj` | First year `adj_new_ha > 0` | ✓ |
| `up_new_ha` | Sum of `own_new_ha` over all reachable upstream hexes (D8 graph, full catchment) | ✓ |
| `up_stock_ha` | Cumulative upstream mining ha | ✓ |
| `up_onset_year` | First year any upstream mining | ✓ |
| `down_new_ha` | Analogous for all reachable downstream | ✓ |
| `down_stock_ha` | Cumulative downstream mining ha | ✓ |
| `down_onset_year` | First year any downstream mining | ✓ |
| `nearest_up_onset_year` | Min onset year among immediate 1-hop upstream predecessors | ✓ |
| `nearest_down_onset_year` | Min onset year among immediate 1-hop downstream successors | ✓ |
| `nearest_up_new_ha` | Sum of `own_new_ha` over 1-hop upstream neighbours per year | ✓ |
| `nearest_up_stock_ha` | Cumulative `nearest_up_new_ha` | ✓ |
| `nearest_down_new_ha` | Sum of `own_new_ha` over 1-hop downstream neighbours per year | ✓ |
| `nearest_down_stock_ha` | Cumulative `nearest_down_new_ha` | ✓ |
| `up_hop{2,3}_{new_ha,stock_ha,onset_year}` | Same, over hexes at flow-graph distance **exactly** 2 / 3 upstream | ✓ |
| `down_hop{2,3}_{new_ha,stock_ha,onset_year}` | Same, downstream | ✓ |
| `lateral_new_ha` | Sum of `own_new_ha` over queen-adj neighbours minus **all** up/down hexes within `K_HOPS` | ✓ |
| `lateral_stock_ha` | Cumulative lateral mining ha | ✓ |
| `lateral_onset_year` | First year `lateral_new_ha > 0` | ✓ |
| `lateral_hop{2,3}_{new_ha,stock_ha,onset_year}` | Queen ring 2 / 3 minus all up/down hexes within `K_HOPS` | ✓ |
| `{ndvi,evi}_modis_cropland_{max,mean}` | Peak/mean VI, ESA-CCI agricultural pixels only — **headline mask** | ✓ (~3.6–9.5% NA) |
| `{ndvi,evi}_modis_nominecrop_{max,mean}` | Peak/mean VI, non-mine pixels only | ✓ (~0.1% NA) |
| `{ndvi,evi}_modis_forest_{max,mean}` | Peak/mean VI, ESA-CCI tree-cover pixels only | ✓ (~48–52% NA, sparsest) |
| `{ndvi,evi}_modis_veg_broad_{max,mean}` | Peak/mean VI, any vegetated land | ✓ (~1–2% NA) |
| `{ndvi,evi}_modis_{overall,veg_narrow}_{max,mean}` | Two more masks, in the panel but not currently in `OUTCOMES` | ✓ |
| `urban_share` | Share of hex's ESA CCI pixels in the urban class (190) | ✓ (~11.5% NA past CCI's 2022 span) |
| `elev_mean`, `slope_mean` | Mean elevation/slope from DEM | ✓ |
| `gold_suit_share` | Share of hex in gold-suitable geology (Girard 1:10M) | ✓ 5km only |
| `dist_river_km` | Distance to nearest waterway (km) | ✓ |
| `basin_id`, `main_basin`, `pfaf_id`, `basin_num` | HydroBASINS level-9 sub-basin SE-clustering keys | ✓ 5km, 2km |

**VI outcomes were reworked 2026-07-06** from a single unrestricted hex-mean `ndvi_modis`/
`evi_modis` (12 columns total, MODIS-IGBP land-cover masks) to the **peak-EVI methodology**
(Vashold et al. 2026): mask each 16-day MODIS composite by that year's ESA CCI land cover, take
the per-hex mean at each 16-day step, then reduce to both an annual **mean** and annual **max**
("peak") — 25 columns total. **Headline stat = max** (tracks GPP/crop yields better than an annual
mean); **headline mask = cropland** (isolates the agricultural damage channel specifically, rather
than diluting the signal with forest/urban/water pixels). `OUTCOMES` in the `outcomes-setup` chunk
(shared verbatim by `_1` and `_2`) currently loops NDVI/EVI × {cropland-max, cropland-mean} — the
no-mine-crop/forest/veg-broad variants are written but commented out to bound runtime; uncomment to
add them back.

**ESA CCI year clamp.** ESA CCI land cover only runs 1995–2022, but the VI panel runs to 2025.
`b_03a_vi_panel.R`'s `mask_vi_year()` **clamps** the CCI year for 2023–2025 to 2022 rather than
going NA (a "land cover didn't change" assumption) — so mask NA rates go flat, not missing, past
2022. Only `urban_share` (built directly off the CCI raster, unclamped) is genuinely NA past 2022.

**`nearest_up_onset_year` is hydrological, not geographic.** "Immediate upstream" = hexes whose
D8 flow drains directly into the focal hex. A hex can have multiple such predecessors; "nearest"
means graph distance = 1 hop, not spatial proximity. The upstream neighbour can lie in any
cardinal/diagonal direction — topography decides, not northing.

**Hop rings (added 2026-07-10, `K_HOPS = 3` in `b_03d_flow_exposure.R`).** Exposure now comes as
disjoint rings: ring *k* = hexes at **shortest-path distance exactly *k*** along the flow graph.
Ring 1 keeps its historical names (`nearest_up_*`, `nearest_down_*`, `lateral_*`); rings 2–3 use
`*_hop{k}_*`. `up_new_ha` / `down_new_ha` remain the *k* = ∞ full-catchment columns. Three things
follow:

1. **Rings are a sufficient statistic for the nested sets.** Cumulative "within 3 hops" exposure is
   recovered without rebuilding anything: `up_le3_new_ha = nearest_up_new_ha + up_hop2_new_ha +
   up_hop3_new_ha`, and the same for stocks (cumsum is linear). Cumulative onset is
   `pmin(..., na.rm = TRUE)` over the ring onsets. Put ring 1/2/3 in one regression to trace
   attenuation with hydrological distance; the nested version is collinear by construction.
2. **Ring-1 dominance of the cumulative clock is threshold-dependent — strong at m̄ = 0, gone by
   m̄ = 20.** At the *any-onset* level (m̄ = 0) ring 1 sets the within-3 onset for most hexes, so a
   cumulative C&S cohort structure differs from the 1-hop one mainly in *dose*, not *clock*. But at
   a higher stock threshold the clock is a threshold-*crossing* time on the summed stock, and the
   three hexes' aggregate — not ring 1 alone — sets it. Diagnostic at 5 km (ROUTE_KM2 = 10),
   fraction of within-3 upstream-treated hexes classified by what trips m̄:

   | m̄ (ha) | ring 1 sets clock | rings 2–3 advance clock | rings 2–3 *create* treatment | extra treated hexes vs 1-hop |
   |---|---|---|---|---|
   | 0  | 56.9% | 19.7% | 23.4% | +153 |
   | 5  | 34.9% | 35.1% | 30.0% | +122 |
   | 10 | 32.3% | 35.4% | 32.3% | +114 |
   | 20 | 27.5% | 37.6% | 34.9% | +103 |

   ("ring 1 sets clock" = within-3 onset year equals the 1-hop onset year; the 74.3% figure quoted
   before is the same statistic on the *conditional* denominator — hexes where ring 1 ever mines —
   which hides the 23–35% of treated hexes where ring 1 never crosses m̄.) So at m̄ ≥ 10 the
   cumulative-within-3 treatment is a genuinely different design from 1-hop, not a dose rescaling:
   ~⅓ of treated hexes are invisible to the 1-hop definition and another ~⅓ have their onset pulled
   earlier by rings 2–3. **The cumulative treatment is worth featuring specifically at m̄ ≥ 10.**
   Diagnostic script: `code/3_analysis/ring1_dominance_diagnostic.R` (see changelog 2026-07-13).

   These cumulative treatments are implemented as the `up_le3_*` (treatment) and `down_le3_*`
   (symmetric placebo) exposures — derived in `a_05_event_study_2.Rmd`'s `derive-le3` chunk (a
   `rowSums` of the three ring stocks + `pmin` of the ring onsets, `Inf`→`NA`), **not** in the panel
   build. If Q2b's continuous-dose spec or the other Q-files need them, promote `up_le3_new_ha` /
   `down_le3_new_ha` into `b_03e_assemble_eventpanel.R` and rebuild. The rings still buy the most in
   the continuous-dose spec (Version 1), where the full dose gradient — not just the crossing — is used.
3. **A hop is not a distance, and its length scales with the grid.** Flow edges join geographically
   adjacent hexes, so *k* hops ≈ *k* hex-widths **along a meandering channel**: ~3 km on the 1 km
   grid, ~15 km on the 5 km grid. **Hop-*k* coefficients are not comparable across resolutions.**

**`lateral_*` changed on 2026-07-10 and is now stricter.** It was queen-adjacent minus the *1-hop*
up/down sets; it is now queen ring *k* minus **all** up/down hexes within `K_HOPS` (the max hop, not
*k*). This guarantees no hex is ever simultaneously lateral and flow-treated at any radius, and makes
the lateral rings sum to the cumulative lateral set exactly as the flow rings do. Effect at 5 km:
`lateral_new_ha` shrank in 7.7% of hex-years and 188 hexes lost their `lateral_onset_year` — these
were queen-adjacent hexes that turn out to sit 2–3 hops up or down the channel. Any lateral result
computed before this date is on the older, contaminated comparison group.

**`adj_onset_year` contamination.** The ever-treated group under `adj_onset_year` is a superset:
it includes hexes that were already mining when a neighbour started, concurrently, or after.
For a clean spillover sample restrict to `is.na(own_onset_year) | own_onset_year > treat_onset`
(not yet mining at treatment time). The `control-pool-composition` chunk in `_2` reports this
breakdown for every treatment definition it uses. **Implemented (2026-07-13):** `_2`'s
`## Restricted sample — hexes never mined themselves` subsection (under Estimator 1) re-runs the
whole C&S sweep on the stricter `filter(is.na(own_onset_year))` cut (never mined themselves, not
just not-yet-mined), all exposures × both routings × full m̄ sweep, headline outcome only. Note the
cut thins the 1-hop upstream cell hard (5 km, m̄ = 10: only 26 clean treated hexes vs 81 for the
`up_le3` ≤3-hop cumulative) — another reason the cumulative treatment earns its place here.

### Control groups

**Prefer not-yet-treated over never-treated.** Barenblitt covers SW Ghana only at 75.6% producer
accuracy → "never-treated" conflates "never surveyed" with "no mining". Not-yet-treated compares
eventual entrants to each other, which is safer. This is `run_cs()`'s default (`control =
"notyettreated"`) in all three files.

### SE clustering

**Real HydroBASINS level-9 sub-basins** (`basin_num`, from `d_07_hydrobasins.R`, run 2026-07-06)
now supply SE clustering when present for the current resolution — **280 basins at 5 km, 287 at
2 km**, both well above the ~30-cluster comfort floor for cluster-robust/CS SEs. Falls back — with
a `warning()` — to the old 25 km centroid-block stand-in (`paste0("b_", round(cx/25000), "_",
round(cy/25000))`) if `basin_num` is absent for a resolution (e.g. 1 km, which `d_07` hasn't been
run for yet). Identical logic in the `load-panel` chunk of all three files, which aliases both onto
`block_id`/`block_num` so downstream code needs only one column name regardless of which source fed it.

**`run_cs()`'s `clustervars` default was fixed to `block_num` 2026-07-08.** It had been hardcoded to
the literal string `"main_basin"` — the much coarser HydroBASINS `MAIN_BAS` grouping (42–43
clusters) recommended 2026-07-06 on cluster-*count* grounds — which silently diverged from the
`load-panel` chunk's own stated intent (its comment already claimed `clustervars = "block_num"`).
A user-observed SE anomaly in Q0a (event_time == 2 giving SE ≈ 0.16 under `main_basin` vs. ≈ 0.03–0.04
under `basin_num`/the old block scheme, same point estimate) traced to this: `main_basin`'s cluster
*count* looked adequate (42, and 34/43 of them touched the event_time==2 sample — a 79% coverage
ratio, the highest of the three schemes tested), but two of those 34 basins held 79% of the eligible
hexes between them, giving an effective cluster count (inverse-Herfindahl, $1/\sum p_i^2$) of roughly
**3**, not 34 — exactly the kind of severe size imbalance that makes `did::att_gt`'s multiplier
bootstrap (`bstrap = TRUE`) erratic. `basin_num`'s much larger absolute cluster count (138 basins
touch that same event-time cell, vs. `main_basin`'s 34) doesn't have this failure mode. See
`cluster_se_diagnostic.R` for the reproducible three-way comparison.

### Helpers

Shared functions defined in each file's `helpers` chunk (each file keeps only the subset it uses):

- **`run_cs(data, yname, gcol, xformla, cluster = "block_num", control, min_e, max_e)`** — wraps
  `did::att_gt` (DR, not-yet-treated, universal base period) + `aggte(type="dynamic")` +
  `aggte(type="group")`. Used by all three files (Q0, Q1, Q2). `cluster` default fixed to
  `"block_num"` 2026-07-08 (see the SE-clustering note above).
- **`first_cross(df, stock_col, mbar)`** — returns `df` with a new `g_thr` column = first year the
  named stock column exceeds `mbar`; 0 = never crosses (C&S never-treated convention). Used by Q0
  (`_1`) and Q1 (`_2`) for the stock-threshold sweep; Q2 (`_3`) doesn't sweep thresholds.
- **`cs_row`/`tidy_dyn`/`v2_dynplot`/`outcome_dynplot`** — tidying/plotting helpers for the C&S
  dynamic ATT, shared by Q0 and Q1 (Q2 uses `did::ggdid()` directly instead).
- **`run_v2_exposures`/`v2_rows_from_exposures`/`run_v3_defs`/`v3_rows_from_defs`** — Q1-only
  (`_2`), drive the multi-outcome loop over `OUTCOMES` for V2 and V3.

---

## Control variables in the C&S estimator

`att_gt` uses `xformla` in both legs of the doubly-robust (DR) estimator: propensity score (what
predicts treatment cohort) and outcome regression (what predicts the outcome pre-treatment). DR is
consistent if either leg is correct.

**Current baseline (all three files):** `xf = ~ elev_mean + slope_mean` (or `~ 1` when terrain
absent).

**Candidate additions (not yet implemented):**

| Variable | Rationale | Caveat |
|----------|-----------|--------|
| `gold_suit_share` | Primary selection predictor — gold-bearing geology drives earlier treatment timing | Girard 1:10M; no sub-grid signal below 5 km. **5 km only.** |
| `dist_river_km` | River proximity predicts both downstream exposure likelihood and baseline riparian NDVI | Partly absorbed by the flow-graph treatment definition; still improves PS balance |
| Pre-period NDVI mean (1995–2006) | Conditions on baseline vegetation density | Not yet in the panel; compute from VI stack as a static covariate |

**Extended formula for robustness check:**
```r
xf_ext <- ~ elev_mean + slope_mean + gold_suit_share + dist_river_km
```
Run `run_cs(..., xformla = xf_ext)` alongside baseline. Stable ATT = good balance; sign flip =
confounding concern.

---

## Q0 — Own-hex mining → own-hex vegetation (`a_05_event_study_1.Rmd`)

**Purpose:** validate the panel/estimator mechanics before trusting Q1/Q2. Treatment = mining
within the focal hex itself (`own_onset_year`/`own_new_ha`/`own_stock_ha`); no flow graph, no
directionality. Runs over every outcome in `OUTCOMES`.

- **Q0a** — treatment clock = `first_treat_own` (any own-hex mining, no threshold). The cleanest
  version; should show a clear negative post-onset break in vegetation if the pipeline works.
- **Q0b** — treatment clock = first year `own_stock_ha` crosses $\bar m$, swept over `mbar_grid`
  (0/10/25/50 ha). Checks whether the effect scales with *how much* of the hex is mined.

Own-hex effects should be the **largest** in magnitude of the three questions (direct
land-clearing, not a spillover) — they set the scale for what a real Q1 waterborne effect could
plausibly look like, and are the baseline Q1/Q2 results should be read against, not a headline
finding in their own right.

---

## Q1 — Upstream mining → downstream vegetation (`a_05_event_study_2.Rmd`)

Every version below (V1 through V3b) is estimated once per outcome in `OUTCOMES`; the headline
mask/stat is `ndvi_modis_cropland_max` (own filenames unchanged for the presentation deck).

### Version 1 — continuous distributed lag (dose, robustness)

Two TWFE specs that separate the stock and flow channels (there is no separate "stock only" 1a
sub-spec currently implemented — only 1b/1c below — plus a dCDH continuous-dose companion). TWFE is
biased under heterogeneous dynamics (forbidden comparisons); V2 (C&S) is the headline.

**Collinearity note:** `up_stock_ha_{t-1} = Σ_{s<t} up_new_ha_s`, so including both stock and
flow lags in the same equation creates collinearity (lags are the most recent components of the
cumulative sum). The two sub-specs below separate them.

| Sub-spec | Estimand | Estimator |
|----------|----------|-----------|
| **1b — flow lags only** | Short-run: does new upstream mining lower NDVI growth? | TWFE on ΔNDVI, 0–3 lags |
| **1c — joint** | Flow lags + lagged stock control (poly degree 2); collinearity caveat applies | TWFE on ΔNDVI |
| **dCDH** | Continuous dose, heterogeneity-robust, full panel vs. pre-own-entry censored overlay | `did_multiplegt_dyn` (optional, needs `DIDmultiplegtDYN` + `polars` both installed) |

Each sub-spec runs upstream/upstream-1-hop (treatment) vs. lateral (comparison) vs.
downstream/downstream-1-hop (placebo) in parallel — five exposure dimensions, not three; adjacency
is excluded throughout Q1 (see V2 below).

### Version 2 — absorbing treatment at a stock threshold (headline)

Treatment = first year the mining stock in a given exposure dimension crosses $\bar m$. C&S,
not-yet-treated controls, outcome in levels. **Five** exposure dimensions in treatment →
comparison → placebo order (this absorbs what used to be a separate "V2c" pre-own-entry-censored
design — V2c was removed 2026-06-30 and its six-dimension structure merged into V2's headline):

1. Upstream — all reachable (treatment)
2. Upstream — 1-hop nearest (treatment variant)
3. Lateral — queen minus 1-hop up/down (comparison, no water link)
4. Downstream — 1-hop nearest (placebo)
5. Downstream — all reachable (placebo)

**Adjacent (queen) is excluded from V2**, unlike the pre-2026-06-30 design — plain queen adjacency
aggregates upstream + lateral + downstream neighbours into one number, confounding treatment and
placebo signals. Use the five-dimension list above instead.

**mbar grid:** `c(0, 10, 25, 50)` ha. The sweep is the credibility check — a real effect should
be stable across thresholds. `mbar = 0` is equivalent to "any mining" (onset crossing). Run for
every outcome in `OUTCOMES`; the $\bar m = 25$ ha threshold gets a dedicated outcome-overlay plot.

**Interpretation:** if V2 upstream is negative and significant while V2 downstream is null across
outcomes, the effect is robust to both the threshold-sweep and the vegetation-index/masking choice.

### Version 3 — mechanism: nearest-upstream onset clock, censored to pre-own-entry

Does NDVI fall when an upstream hex starts mining, **before the focal hex itself mines**? Each hex
is censored at its own onset (`year < own_onset_year`); **headline treatment = nearest 1-hop
upstream onset** ($T_i^{\text{UP}}$, the tex's "nearest upstream hex" — promoted to headline
2026-06-30, demoting all-reachable upstream to a robustness check); downstream onset (1-hop and
all-reachable) = directional placebos.

**Gap plot first:** report `T_own - T_{nearest\_up}` distribution before running C&S. If there is
little spread (the two clocks are collinear), V3 is weakly identified.

**Four treatment definitions:**

| gname | Description | Role |
|-------|-------------|------|
| `g_nearest` = `nearest_up_onset_year` | Immediate 1-hop upstream onset | **Headline** |
| `g_up` = `up_onset_year` | All reachable upstream onset | Robustness (broader exposure) |
| `g_nearest_down` = `nearest_down_onset_year` | Immediate 1-hop downstream onset | Placebo |
| `g_down` = `down_onset_year` | All reachable downstream onset | Placebo |

**`nearest_*_onset_year` join fix.** These columns are time-invariant per hex; C&S needs a
constant `gname` within a unit, so both `_1`/`_2`/`_3` resolve them to hex-level scalars before
joining (`distinct(hex_id, nearest_up_onset_year)` then `left_join(by = "hex_id")`), not the
year-keyed join that would otherwise leave a hex showing 0 in some years and its real onset year
in others. The permanent fix already lives in `b_03e_assemble_eventpanel.R` (nearest columns
extracted as hex-level scalars at build time).

### Version 3b — faithful two-clock TWFE (added 2026-07-01)

Implements the tex V3 equation literally as a single joint TWFE regression on the pre-own-entry
sample: the hex's own-entry clock $\beta_k = \mathbf 1[t - T_i = k]$ (pre-period only) and the
nearest-upstream clock $\delta_j = \mathbf 1[t - T_i^{\text{UP}} = j]$, both normalised to event
time $-1$, estimated jointly via `feols(y ~ i(k_own, ref=-1) + i(j_up, ref=-1) | hex_id + year)`.
$\beta_k$ traces the pre-entry decline common to all eventual enterers; $\delta_j$ isolates the
part that follows the nearest upstream neighbour's onset. Read jointly: $\beta_k \approx 0,\
\delta_j < 0$ = pure waterborne; $\beta_k < 0,\ \delta_j < 0$ = mixed; $\beta_k < 0,\ \delta_j
\approx 0$ = common pre-entry decline unrelated to upstream status. Trades V3's Callaway–Sant'Anna
robustness for a literal reproduction of the tex's $\beta$-vs-$\delta$ decomposition.

---

## Q2 — Neighbour mining → own mining (`a_05_event_study_3.Rmd`)

**Restored to working order 2026-07-08** — Q2 had been fully disabled (HTML-commented,
`eval=FALSE` on every chunk) since 2026-06-30 while Q1 was the active focus. All chunks are live
again; not yet re-run/re-reviewed against the current panel since restoration.

Does mining **spread**? Outcome = own-hex mining; treatment = neighbour mining onset.

**Identification caveats (must carry):** own and neighbour mining share gold-geology + river
fundamentals (the same common-suitability confound `a_02`'s geography-weighted Moran null
addressed); mining is spatially clustered, so neighbour- and own-onset co-move mechanically.
**Pre-trends are the defence:** flat pre + jump post = diffusion; co-trending = common
fundamentals. Adjacency is symmetric (can't separate A→B from B→A); the **directed upstream**
design is the clean diffusion test.

### D2d reproduction — naïve TWFE (baseline, the "before")

The original D2d: new mining (and any-mining LPM) on the lagged neighbour stock. Kept as the
baseline the event study improves on; its coefficient is **not** a clean causal effect.

### Directed: upstream onset → own mining (headline)

Treatment = `up_onset_year`; placebo = `down_onset_year`. Clean identification because downstream
onset cannot plausibly cause upstream mining through river channels. Pre-period flat + post-period
jump = diffusion along the river corridor.

### Adjacency benchmark (symmetric)

Treatment = `adj_onset_year` (`first_treat_adj`); C&S with not-yet-treated controls. Symmetric —
cannot separate A→B from B→A. Useful as a magnitude comparison. **Interpret pre-trends with the
reflection caveat** (adjacent hexes share suitability fundamentals).

### Extensive margin — onset hazard (transparent TWFE LPM)

Among hex-years **still at risk** (before own onset, inclusive of onset year), does an already-active
upstream or adjacent neighbour raise the probability the hex starts mining this year?

```r
hz <- panel |>
  filter(is.na(own_onset_year) | year <= own_onset_year) |>
  mutate(own_onset_event = as.integer(!is.na(own_onset_year) & year == own_onset_year),
         up_active  = as.integer(!is.na(up_onset_year)  & year >= up_onset_year),
         adj_active = as.integer(!is.na(adj_onset_year) & year >= adj_onset_year))
feols(own_onset_event ~ up_active + adj_active | hex_id + year, hz, cluster = ~ block_id)
```

This is a transparent linear check on the extensive margin; TWFE is appropriate here because the
outcome is binary and the regressor is a permanent switch (absorbing active status).

---

## Caveats

- **Sub-basin clustering** now uses real HydroBASINS level-9 sub-basins (`basin_num`, from
  `d_07_hydrobasins.R`, run 2026-07-06) at 5 km and 2 km — 280/287 clusters respectively, well
  above the ~30-cluster comfort floor. Falls back to the old 25 km centroid-block stand-in — with
  a warning — for a resolution `d_07` hasn't been run for (currently 1 km).
- **Window:** Barenblitt is 2007–2017; the usable event window is its overlap with the NDVI stack
  (see the `overlap` chunk in `_1`/`_2`). Onsets before NDVI coverage have no pre-period and are
  dropped by `did`.
- **Coverage / accuracy:** Barenblitt is SW-Ghana only at 75.6% producer accuracy → onset measured
  with error and "never-treated" conflates "never surveyed"; prefer not-yet-treated controls.
- **Off-network galamsey** (~5.5% of mined ha at `ROUTE_KM2 = 10`) is unattributed upstream; the
  `d_04_merit.R` 11j threshold sweep documents sensitivity to the routing cutoff. The panel also
  carries a `ROUTE_KM2 = 50` alt flow graph (`_upa50`-suffixed columns) as a robustness cut, but
  it is not yet wired into any Q1 design.
- **Cropland masking is resolved** (2026-07-06/07): `cropland` (ESA-CCI agricultural pixels) is
  now the headline mask, isolating the agricultural damage channel specifically rather than
  averaging over the whole hex. `overall`/`veg_narrow` remain in the panel but are outside the
  default `OUTCOMES` loop.
- **ESA CCI year clamp:** land-cover masks are only genuinely re-derived through 2022; VI years
  2023–2025 reuse the 2022 CCI classification (`mask_vi_year()` clamps rather than going NA).
  `urban_share` is the one column that goes genuinely NA past 2022.
- **Gold suitability at sub-5 km resolutions:** Girard geology is 1:10M scale — no meaningful
  spatial signal below ~5 km. Omit `gold_suit_share` from `xformla` at 1/2 km.
- **V1 collinearity:** stock and flow lags compete for the same variation (stock = cumulative sum
  of lags). Run 1b/1c separately; never combine stock polynomial + flow lags without flagging this
  limitation.
- **dCDH** (`did_multiplegt_dyn`) runs only if both `DIDmultiplegtDYN` and `polars` are installed
  (`HAS_DCDH`, `_2` only) — DIDmultiplegtDYN 2.3.0 references polars' `pl` as a bare symbol without
  importing it, so `polars` must be `library()`-attached, not just installed.
- **Multi-outcome runtime (`_1`/`_2`):** every design loops over `OUTCOMES` (NDVI/EVI × masks ×
  stat) rather than a single NDVI column — expect a substantially longer knit than a single-outcome
  version, dCDH especially. Trim `OUTCOMES` in the `outcomes-setup` chunk for a faster run. NDVI vs
  EVI ATT *magnitudes* are not directly comparable (different index scales) — compare
  sign/significance/event-time shape instead.
- **Pre-period VI baseline** (1995–2006 hex mean) is not yet in the panel; flagged as a to-do for
  the DR outcome regression (see "Candidate additions" above).
- **None of `_1`/`_2`/`_3` have been knitted yet** as of the 2026-07-08 split; `_3` in particular
  has not been re-run since its Q2 code was restored from its disabled state.
