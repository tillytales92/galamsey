# Event Study — Design and Implementation Notes

**Core hypothesis:** upstream galamsey mining degrades agricultural/vegetation productivity
downstream via waterborne contamination (mercury, sediment, turbidity). NDVI is the outcome proxy.

**Runnable code:** `a_05_event_study.Rmd` (this directory).  
**Panel source:** `2_build/b_03e_assemble_eventpanel.R` → `data/processed/event_panel_{1|2|5}km.rds`.  
**Resolution:** set via `params$resolution_km`; see resolution analysis below — **5 km is primary**.

**Two questions share one panel:**

| | Q1 — Waterborne degradation | Q2 — Mining diffusion |
|---|---|---|
| Outcome | downstream NDVI | own-hex mining (intensity + onset) |
| Treatment | upstream mining onset | neighbour mining onset |
| Right neighbour | directed upstream (flow graph) | adjacency (queen) + upstream river-corridor |
| Placebo | downstream onset | downstream onset |

Q2 is the `a_02` D2d spatial-lag regression upgraded from naïve TWFE on the neighbour stock to a
staggered event study with pre-trends and heterogeneity-robust estimators.

---

## Conceptual framework — neighbour definitions

The schematic in `a_05_event_study.Rmd` (`schematic-neighbours` chunk) shows a synthetic 5 km hex
grid split by northing into upstream (UP) and downstream (DN) neighbours of a focal hex, with a
synthetic river. It is a two-group illustration only; northing ≠ flow direction in Ghana's river
network.

**TODO — five-group MERIT extension** (replace the northing schematic once confirmed):

| Group | Treatment role |
|-------|---------------|
| upstream-all | Q1 treatment: any reachable upstream hex starts mining |
| nearest-upstream | Q1 variant: immediate 1-hop D8 predecessors only |
| lateral | Q1/Q2 comparison: queen-adjacent minus 1-hop up/down (no water link) |
| nearest-downstream | Q2 placebo: immediate 1-hop D8 successors |
| downstream-all | Q2 placebo: all reachable downstream hexes |

Rebuild using `hex_sf` + `hex_flow_edges_{N}km.csv` (the actual MERIT D8 graph) so labels match
the event-study treatment columns exactly.

---

## Data foundations

### Panel

`event_panel_{N}km.rds` is assembled by the build pipeline:

| Script | Output | Re-run when |
|--------|--------|-------------|
| `b_03a_vi_panel.R` | `hex_{N}km_vi_panel.rds` | New GEE rasters downloaded |
| `b_03b_own_mining.R` | `hex_{N}km_own_mining.rds` | Barenblitt data updated |
| `b_03c_flow_graph.R` | `hex_flow_edges_{N}km.csv` | New resolution or MERIT rerun |
| `b_03d_flow_exposure.R` | `hex_{N}km_flow_exposure.rds` | Flow edges changed or new vars |
| `b_03e_assemble_eventpanel.R` | `event_panel_{N}km.{csv,rds}` | Any upstream change |

`b_03c` loops over `RESOLUTIONS <- c(1, 2, 5)` and writes flow edges for all resolutions whose
`hex_{N}km_crosssection.rds` cache exists; no code change needed to extend to 1/2 km — just run it.

**Panel dimensions (as of 2026-06-26):**

| Resolution | Hexes | Rows | Ever-mined | Adj-mining hexes |
|-----------|-------|------|------------|-----------------|
| 1 km | 80,716 | 2,502,196 | 3,522 | 8,726 |
| 2 km | 20,386 | 631,966 | 1,690 | 4,152 |
| 5 km | 3,348 | 103,788 | 652 | 1,431 |

Flow graph populated at all three resolutions. Upstream columns (up/down/nearest) are NA until
`b_03c` runs (or when the edge file is absent).

### Resolution analysis

**5 km is the primary grid.** Key constraints:

| Issue | 1 km | 2 km | 5 km |
|-------|------|------|------|
| Flow graph (Q1) | ✓ (since b_03c run) | ✓ | ✓ |
| Gold suitability valid | ✗ (1:10M scale) | ✗ | ✓ |
| MODIS pixel coverage | ~3–4 px/hex (noisy) | ~14 px/hex (sparse) | ~87 px/hex (good) |
| Adjacency diffusion ID | ✗ (mine expansion, not spread) | ✓ (robustness) | ✓ (headline) |

2 km is worth running as a Q2 adjacency robustness check; footnote the gold-suitability caveat.
1 km is problematic on multiple fronts — at most a descriptive panel.

### Full variable inventory

| Column | Description | Status |
|--------|-------------|--------|
| `own_new_ha` | Annual new artisanal mining ha in focal hex | ✓ all resolutions |
| `own_stock_ha` | Cumulative own mining ha | ✓ |
| `own_onset_year` | First year `own_new_ha > 0` | ✓ |
| `adj_new_ha` | Sum of `own_new_ha` over queen-adjacent neighbours (focal excluded) | ✓ |
| `adj_stock_ha` | Cumulative adj mining ha | ✓ |
| `adj_onset_year` | First year `adj_new_ha > 0` | ✓ |
| `up_new_ha` | Sum of `own_new_ha` over all reachable upstream hexes (D8 graph, full catchment) | ✓ 5km; ✓ all |
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
| `lateral_new_ha` | Sum of `own_new_ha` over queen-adj neighbours minus 1-hop up/down | ✓ |
| `lateral_stock_ha` | Cumulative lateral mining ha | ✓ |
| `lateral_onset_year` | First year `lateral_new_ha > 0` | ✓ |
| `ndvi_modis`, `evi_modis` | Annual mean MODIS VI (all pixels in hex) | ✓ (~16% NA) |
| `ndvi_landsat`, `evi_landsat` | Annual mean Landsat VI (all pixels in hex) | ✓ (~30–36% NA) |
| `*_forestcrop`, `*_nominecrop` | Same VI restricted to forest-crop / no-mine-crop pixels | ✓ (high NA) |
| `elev_mean`, `slope_mean` | Mean elevation/slope from DEM | ✓ |
| `gold_suit_share` | Share of hex in gold-suitable geology (Girard 1:10M) | ✓ 5km only |
| `dist_river_km` | Distance to nearest waterway (km) | ✓ |

**`nearest_up_onset_year` is hydrological, not geographic.** "Immediate upstream" = hexes whose
D8 flow drains directly into the focal hex (`igraph::neighbors(g, v, mode = "in")`). A hex can
have multiple such predecessors; "nearest" means graph distance = 1 hop, not spatial proximity. The
upstream neighbour can lie in any cardinal/diagonal direction — topography decides, not northing.

**`adj_onset_year` contamination.** The ever-treated group under `adj_onset_year` is a superset:
it includes hexes that were already mining when a neighbour started, concurrently, or after.
For a clean spillover sample restrict to `is.na(own_onset_year) | own_onset_year > treat_onset`
(not yet mining at treatment time). The `control-pool-composition` chunk in the Rmd reports this
breakdown for every treatment definition.

### Control groups

**Prefer not-yet-treated over never-treated.** Barenblitt covers SW Ghana only at 75.6% producer
accuracy → "never-treated" conflates "never surveyed" with "no mining". Not-yet-treated compares
eventual entrants to each other, which is safer. Run `nevertreated` as a sensitivity check.

### SE clustering

Sub-basin clustering is ideal (treatment and contamination are spatially correlated along rivers).
Current stand-in: 25 km centroid blocks (`paste0("b_", round(cx/25000), "_", round(cy/25000))`).
Replace with a real basin ID once HydroBASINS or MERIT `upa` pour-points are overlaid.

### Helpers

Two shared functions defined in the `helpers` chunk:

- **`run_cs(data, yname, gcol, xformla, cluster, control, min_e, max_e)`** — wraps `did::att_gt`
  (DR, not-yet-treated, universal base period) + `aggte(type="dynamic")` + `aggte(type="group")`.
- **`first_cross(df, stock_col, mbar)`** — returns `df` with a new `g_thr` column = first year the
  named stock column exceeds `mbar`; 0 = never crosses (C&S never-treated convention).

---

## Control variables in the C&S estimator

`att_gt` uses `xformla` in both legs of the doubly-robust (DR) estimator: propensity score (what
predicts treatment cohort) and outcome regression (what predicts NDVI pre-treatment). DR is
consistent if either leg is correct.

**Current baseline:** `xf = ~ elev_mean + slope_mean` (or `~ 1` when terrain absent).

**Candidate additions:**

| Variable | Rationale | Caveat |
|----------|-----------|--------|
| `gold_suit_share` | Primary selection predictor — gold-bearing geology drives earlier treatment timing | Girard 1:10M; no sub-grid signal below 5 km. **5 km only.** |
| `dist_river_km` | River proximity predicts both downstream exposure likelihood and baseline riparian NDVI | Partly absorbed by the flow-graph treatment definition; still improves PS balance |
| Pre-period NDVI mean (1995–2006) | Conditions on baseline vegetation density | Not yet in the panel; compute from VI stack as a static covariate |

**Extended formula for robustness check:**
```r
xf_ext <- ~ elev_mean + slope_mean + gold_suit_share + dist_river_km
```
Run `run_cs(..., xformla = xf_ext)` alongside baseline for V2c upstream. Stable ATT = good balance;
sign flip = confounding concern.

---

## Q1 — Upstream mining → downstream NDVI

### Version 1 — continuous distributed lag (robustness / dose-response)

Three TWFE specs that cleanly separate the stock and flow channels. TWFE is biased under
heterogeneous dynamics (forbidden comparisons); V2 (C&S) is the headline. V1 is the transparent
dose-response companion run via `did_multiplegt_dyn` for robustness.

**Collinearity note:** `up_stock_ha_{t-1} = Σ_{s<t} up_new_ha_s`, so including both stock and
flow lags in the same equation creates collinearity (lags are the most recent components of the
cumulative sum). The three sub-specs below separate them.

| Sub-spec | Estimand | Estimator |
|----------|----------|-----------|
| **1a — stock only** | Long-run: does cumulative upstream mining depress NDVI levels? | TWFE in levels |
| **1b — flow lags only** | Short-run: does new upstream mining lower NDVI growth? | TWFE on ΔNDVI, 0–3 lags |
| **1c — joint** | Both channels simultaneously; collinearity caveat applies | TWFE on ΔNDVI |
| **1d — dCDH** | Continuous dose, heterogeneity-robust | `did_multiplegt_dyn` (optional) |

Each sub-spec runs upstream (treatment) vs downstream (placebo) in parallel. Divergence between 1a
and 1b identifies whether the effect is level-depression (accumulated stock) or flow-driven
(incremental new mining).

**Missing stock term in the placebo (known asymmetry):** V1 upstream originally included
`poly(lag_stock_up, 2)` but the downstream placebo omitted the analogous `poly(lag_stock_down, 2)`.
The symmetric placebo (both include their respective stock polynomials) is the correct comparison.
The 1c joint spec in the current Rmd is symmetric on this point.

### Version 2 — absorbing treatment at a stock threshold (headline)

Treatment = first year the mining stock in a given exposure dimension crosses $\bar m$. C&S,
not-yet-treated controls, NDVI in levels. Three exposure dimensions in parallel:

- **Upstream** (treatment): waterborne contamination hypothesis
- **Adjacent** (comparison): land-adjacency / dust / visual disturbance — symmetric, no flow direction
- **Downstream** (placebo): if upstream → NDVI, downstream onset should have no effect

**mbar grid:** `c(0, 10, 25, 50)` ha. The sweep is the credibility check — a real effect should
be stable across thresholds. `mbar = 0` is equivalent to "any mining" (onset crossing).

**Own-mining confounder:** V2 uses the full panel including hex-years where the focal hex is itself
mining. Any NDVI drop detected could be own land-clearing rather than upstream contamination. V2c
(below) fixes this.

### Version 2c — absorbing threshold, censored to pre-own-entry (headline causal spec)

V2 with the own-mining confounder removed: each hex is dropped from its sample the moment it starts
mining (`year < own_onset_year`). Treatment is still first-crossing of a stock threshold, but
identified purely from pre-own-entry variation.

Six exposure dimensions in treatment → comparison → placebo order:

1. Upstream — all reachable (treatment)
2. Upstream — 1-hop nearest (treatment variant)
3. Adjacent — all queen (comparison)
4. Lateral — queen minus 1-hop up/down (comparison, no water link)
5. Downstream — 1-hop nearest (placebo)
6. Downstream — all reachable (placebo)

Guards (`has_near_flow`, `has_lateral`) make the Rmd degrade gracefully if the 1-hop / lateral
columns are absent in older panels.

**Stability table:** built dynamically via `row_groups` list + loop over `pack_rows()` — no
hardcoded row numbers, so it survives if exposure dimensions are absent.

**Interpretation:** If V2c upstream is negative and significant while V2c downstream is null, the
effect survives both (a) the threshold absorbing-treatment design and (b) removal of own
land-clearing → cleanest evidence for the waterborne contamination mechanism.

### Version 3 — mechanism: upstream onset clock, censored to pre-own-entry

Does NDVI fall when an upstream hex starts mining, **before the focal hex itself mines**? Censor
each hex at its own onset; treatment = upstream onset year; downstream onset = directional placebo.

**Gap plot first:** report `T_own - T_up` distribution before running C&S. If there is little
spread (the two clocks are collinear), V3 is weakly identified and V2c is the only viable headline.

**Four treatment definitions:**

| gname | Description | Role |
|-------|-------------|------|
| `g_up` = `up_onset_year` | All reachable upstream onset | Primary treatment |
| `g_nearest` = `nearest_up_onset_year` | Immediate 1-hop upstream onset | Local signal |
| `g_down` = `down_onset_year` | All reachable downstream onset | Placebo |
| `g_nearest_down` = `nearest_down_onset_year` | Immediate 1-hop downstream onset | Symmetric local placebo |

**`nearest_*_onset_year` join fix (critical):** These columns are time-invariant per hex but were
originally joined year-by-year (via `b_03e` using `by = c("hex_id", "year")`). Years outside the
mining window get NA; after `replace_na(..., 0L)` the same hex shows 0 in some years and the actual
onset year in others — making `gname` non-constant within a unit, which C&S `validate_args()` rejects.

**Fix:** resolve to hex-level scalars before joining, then join by `hex_id` only:
```r
nearest_scalar <- panel |>
  filter(!is.na(nearest_up_onset_year)) |>
  distinct(hex_id, nearest_up_onset_year)
# ... left_join(nearest_scalar, by = "hex_id")
```
`up_onset_year` and `down_onset_year` are unaffected because they are already joined by `hex_id`
only in `b_03e`. **The permanent fix is also in `b_03e_assemble_eventpanel.R`** (nearest columns
extracted as hex-level scalars, not year-keyed rows).

---

## Q2 — Neighbour mining → own mining (D2d, upgraded)

Does mining **spread**? Outcome = own-hex mining; treatment = neighbour mining onset. Q2 is the
`a_02_spatial_clustering.R` D2d regression (TWFE of new mining on lagged neighbour stock) upgraded
to a staggered event study with pre-trends and heterogeneity-robust estimators.

**Identification caveats (must carry):** own and neighbour mining share gold-geology + river
fundamentals (the same common-suitability confound D2d's geography-weighted Moran null addressed);
mining is spatially clustered, so neighbour- and own-onset co-move mechanically. **Pre-trends are
the defence:** flat pre + jump post = diffusion; co-trending = common fundamentals. Adjacency is
symmetric (can't separate A→B from B→A); the **directed upstream** design is the clean diffusion test.

### D2d reproduction — naïve TWFE (baseline, the "before")

The original D2d: new mining (and any-mining LPM) on the lagged neighbour stock. Kept as the
baseline the event study improves on; its coefficient is **not** a clean causal effect.

### Directed: upstream onset → own mining (headline)

Treatment = `up_onset_year`; placebo = `down_onset_year`. Clean identification because downstream
onset cannot plausibly cause upstream mining through river channels. Pre-period flat + post-period
jump = diffusion along the river corridor.

### Adjacency benchmark (symmetric)

Treatment = `adj_onset_year`; C&S with not-yet-treated controls. Symmetric — cannot separate A→B
from B→A. Useful as a magnitude comparison and to show the event-study approach yields pre-trend-flat
estimates even for the noisier adjacency definition. **Interpret pre-trends with the reflection
caveat** (adjacent hexes share suitability fundamentals).

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

- **Sub-basin clustering** is a 25 km block stand-in. Swap in a real basin ID (HydroBASINS /
  MERIT `upa` pour-points) for the headline SEs.
- **Window:** Barenblitt is 2007–2017; the usable event window is its overlap with the NDVI stack
  (see the `overlap` chunk). Onsets before NDVI coverage have no pre-period and are dropped by `did`.
- **Coverage / accuracy:** Barenblitt is SW-Ghana only at 75.6% producer accuracy → onset measured
  with error and "never-treated" conflates "never surveyed"; prefer not-yet-treated controls.
- **Off-network galamsey** (~5.5% of mined ha at `ROUTE_KM2 = 10`) is unattributed upstream; the
  `d_04_merit.R` 11j threshold sweep documents sensitivity to the routing cutoff.
- **Cropland masking:** NDVI is an all-pixel hex mean; `*_forestcrop` / `*_nominecrop` columns exist
  but have high NA (~80–94% for forest-crop). Restricting to cropland pixels (the *agricultural*
  channel) would need a better land-cover mask.
- **Gold suitability at sub-5 km resolutions:** Girard geology is 1:10M scale — no meaningful
  spatial signal below ~5 km. Omit `gold_suit_share` from `xformla` at 1/2 km.
- **V1 collinearity:** stock and flow lags compete for the same variation (stock = cumulative sum of
  lags). Run the three sub-specs (1a/1b/1c) separately; never combine stock polynomial + flow lags
  without flagging this limitation.
- **dCDH** (`did_multiplegt_dyn`) runs only if `DIDmultiplegtDYN` is installed (`HAS_DCDH`).
- **Pre-period NDVI baseline** (1995–2006 hex mean) is not yet in the panel; flagged as a to-do
  for the DR outcome regression.
