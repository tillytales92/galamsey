# Analysis & outputs — explainer

Scripts in this folder (`a_NN_*`) **produce the outputs** — figures, tables, and rendered reports —
that go into the presentation deck and the paper. Each reads analysis-ready artifacts from
`data/processed/` (written by `code/2_build/`) plus a few raw shapefiles for map display; none writes
to `data/processed/` except small summary CSVs and the presentation-embed exports.

**Independence:** once the build pipeline has run, the `a_NN_*` scripts are independent of each other
and can run in any order. They follow the `mine_data` abstraction — written to take Barenblitt
shapefiles today, ready to swap in the RS panel once Part 1 is complete.

**The methodology behind the statistical content of `a_02`, `a_03`, and `a_05` — Moran's I, LISA,
the geography-weighted null, the M1–M5 ladder, the spatial spline, the spatial lag model, and every
event-study design — is documented separately in [`../4_presentation/methodology_explainer.md`](../../4_presentation/documentation/methodology_explainer.md).**
This file describes *what each script does and emits*; the methodology file describes *how the
methods work and what they do and do not show*.

Two design/notes docs also live here: [`event_study_design.md`](event_study_design.md) (the full
conceptual spec that `a_05` implements) and `Event Study Notes.tex`.

---

## a_01_incidence_maps.R

**Purpose:** Section 1.1 — the descriptive **incidence-of-galamsey** figures. Where is mining, how
much, and how has it grown? Produces choropleth maps and summary charts for two spatial units
(10 km hexagons + districts) from a single parametric function set.

**Inputs:** the `b_01` processed CSVs (`mining_timeseries_by_{hex10km,districts}_2007_2017_long.csv`,
`mining_extent_by_{hex10km,districts}_2019.csv`) + admin/waterways shapefiles for display. Run
`b_01_cross_section.R` (or the `b_01_mining_by_unit.R` preprocessor) at `hex10km` and `districts`
first.

**Outputs (in `outputs/figures/`):**

| ID | Output |
|----|--------|
| D1a | Small-multiple maps — cumulative + annual mining extent by year (plasma, sqrt scale), per unit; plus animated GIFs |
| D1b | Artisanal-vs-industrial side-by-side choropleths, per unit |
| D1c | Land-cover-fraction time series (national cumulative share; per-district bar + top-12 annual flows) |
| D1d | Summary statistics (console), top-20 extent bar, national annual conversions vs world gold price (dual axis) |
| D1e | Lorenz curve — concentration of galamsey across districts |

**Architecture note:** a `unit_configs` list drives every section, so both units loop through one
function definition. `HEX_SIZE` (default 10 km) must match the `b_01` run that produced the CSVs.
Also saves `data/processed/n_surveyed_districts.rds` (used by the presentation deck).

---

## a_02_spatial_clustering.R

**Purpose:** Section 1.2 — the **spatial-clustering / economic-spillover** analysis. Establishes that
galamsey is spatially clustered, that geography alone cannot explain the clustering, and that mining
begets neighbouring mining — the empirical core of the "spillover" argument. Operates on the 5 km
hex grid.

**Input:** the `hex_5km_crosssection.rds` cache from `b_01` (hex grid, cross-section frame, spatial
weights `lw`/`nb`, study-area polygon) + the 5 km annual mining panel, plus raw shapefiles for maps
and the first-stage refit.

**Sections (outputs to `outputs/figures/spatial_clustering/`):**

| ID | What it does | Method (see methodology_explainer) |
|----|--------------|-----------|
| D2_Map | Descriptive incidence map (artisanal share per 5 km hex) | — |
| D2a | Global Moran's I on annual new mining, by year + full-series summary; LISA hotspot/coldspot map | Global Moran's I, LISA |
| D2b | Moran's I of raw share vs residuals after geology / geology+river controls | Partialling-out |
| D2c-FS | First stage: OLS LPM of mine presence on geography (`.tex` + `.md` tables) | Linear probability first stage |
| D2bc | Geography-weighted null: 500 simulated mine assignments weighted by fitted geography, no spillover term | Simulation null (decomposition) |
| D2d | Spatial-lag regression: annual new mining on neighbour cumulative stock at t−1, two-way FE | Spatial lag model |
| D2e | Upstream-vs-downstream spread of onset along rivers (northing proxy for flow) | Directional diffusion |

**Architecture note:** the `spdep` weights (`nb`/`lw`) are built once (queen contiguity, keyed to
`hex_sf` row order) and reused across D2a–D2e; any vector passed to `moran.test()` / `lag.listw()`
must be re-ordered to match `hex_sf$hex_id` via `arrange(match(...))`. Regression tables are emitted
in both `.tex` (for Beamer) and `.md` (for the reveal.js deck) from the same fitted models so the two
decks can never disagree. **D2e's northing proxy is superseded by the MERIT flow graph** (`d_04`) —
the event study uses real hydrological direction.

---

## a_03_firststage_diagnostics.Rmd

**Purpose:** Renders the **first-stage strength & MAUP-robustness** report from the cached model
grid. Answers two questions together: (1) is the geography first stage strong enough to be a
meaningful control for the geography-weighted null? and (2) are the clustering conclusions robust to
the Modifiable Areal Unit Problem — i.e. do they hold at 1, 2, and 5 km grain?

**This document only renders** — all heavy computation (fitting M1–M5 and simulating the null on each
grid) lives in `code/2_build/b_02_firststage_models.R`, which writes `d03_maup_results.rds`.

**Structure:** Part A — fit quality (AUC) climbing the M1→M4 ladder across grids; Part B — the
geography-weighted null vs observed Moran's I per model × grid (`p_excess ≈ 0` = clustering survives
the control); Part C — the M5 thin-plate-spline null at 5 km & 2 km (the most conservative, omitted-
geography null) + the fitted spatial-propensity surface; Appendix — which interactions carry M4 by
grain. See the methodology file for the M1–M5 definitions and what the spline can/cannot show.

---

## a_04_motivating_facts.R

**Purpose:** Section 2 — the **motivating facts** exploring galamsey's drivers and consequences.
Structured to the tasklist (D3–D6); several subsections are intentionally **blocked** pending data
acquisition, with in-script acquisition notes documenting the intended approach and sources.

**Subsections:**

| ID | Question | Status |
|----|----------|--------|
| D3a | Galamsey expansion vs gold-price shocks (dual-axis TS + lagged Spearman) | ✓ implemented |
| D3b | Expansion vs climate/rainfall shocks | BLOCKED — CHIRPS not yet acquired |
| D3c | Acceleration after first formal mine appears | PARTIALLY BLOCKED — no establishment-year field |
| D4a | Reversion from galamsey | BLOCKED by data design — Barenblitt records onsets, not presence; needs RS panel |
| D5a | NDVI/EVI binned scatter vs distance to nearest mine (2019) | ✓ implemented |
| D5b | Event study: NDVI/EVI around mine onset by distance band (pixel-level, normalised to t=−1) | ✓ implemented |
| D5c | Cocoa yields around galamsey | BLOCKED — COCOBOD data not acquired |
| D6a–c | Labour shift out of agriculture | BLOCKED — census/GLSS microdata not acquired |

**Inputs:** Barenblitt shapefiles, the Landsat NDVI/EVI stacks (`d_01`), gold price via Yahoo
Finance, and (optionally) the district panel CSV. Implemented outputs go to
`outputs/figures/motivating_facts/`. D5b is a **pixel-level** distance-banded event study — distinct
from the hex-level Callaway–Sant'Anna designs in `a_05`.

---

## a_05_event_study_{1,2,2b,3}.Rmd

Split on 2026-07-08 into self-contained reports that share one panel:

| File | Question | Knitted |
|---|---|---|
| `a_05_event_study_1.Rmd` | Q0: own-hex mining → own-hex vegetation (mechanics sanity check) | yes |
| `a_05_event_study_2.Rmd` | Q1 part 1: upstream mining → downstream vegetation (C&S, stock-threshold sweep) | yes |
| `a_05_event_study_2b.Rmd` | Q1 part 2: same question, dCDH continuous dose | yes |
| `a_05_event_study_3.Rmd` | Q2: neighbour mining → own mining | not yet |

One-off diagnostics behind design choices here (C&S clustering level, ring-1 dominance of the
within-3-hop clock) are archived in `notes/archive/` (`cluster_se_diagnostic.R`,
`mask_missingness_e2_diagnostic.R`, `ring1_dominance_diagnostic.R`); results are in
`event_study_design.md`.

**Purpose:** The **event-study reports** — the causal core of the downstream-impact analysis. Reads
the shared hex × year panel (`event_panel_{1,2,5}km.rds`, resolution set via `params$resolution_km`)
and estimates two questions that share it:

- **Q1 — Waterborne degradation:** does **upstream** mining onset depress **downstream NDVI**?
  (treatment = upstream mining; placebo = downstream mining; the clean directional test uses the
  MERIT D8 flow graph.)
- **Q2 — Mining diffusion:** does **neighbour** mining onset cause **own-hex** mining? (the `a_02`
  D2d spatial-lag regression upgraded from naïve TWFE to a staggered event study — currently
  commented out in the Rmd as of 2026-06-30).

**Estimators implemented:** Callaway–Sant'Anna (`did::att_gt` → dynamic/group `aggte`,
not-yet-treated controls, doubly-robust) as the headline; TWFE distributed-lag and
de Chaisemartin–D'Haultfœuille (`did_multiplegt_dyn`) as robustness. Every headline figure/table is
also written to `outputs/figures/event_study/` (PNG + markdown) so the presentation deck can embed
them without re-running estimation.

The five event-study designs (V1 distributed lag, V2 absorbing stock-threshold, V2c pre-own-entry
censored, V3 upstream-onset clock, V3b two-clock TWFE), the neighbour-role definitions, and the
control/clustering choices are specified in [`event_study_design.md`](event_study_design.md) and
explained method-by-method in the methodology file. **Run order:** the panel must be built by the
`b_03a → b_03e` sub-pipeline first (which itself needs the `d_04` flow graph for the upstream
columns).

---

## a_01_incidence_maps_rs.R

**Purpose:** Remote-sensing counterpart of `a_01_incidence_maps.R`'s D1a/D1b maps (same palette and
layout) on the 5 km hex grid: cumulative mining maps and artisanal vs industrial.
**Outputs:** `outputs/figures/maps/hex5km_rs/`.
**Stale input:** it still reads the 2026-11-05 panel `outputs/tables/backdating/b_04_rs_mining_panel_5km.csv`,
not the current `data/processed/rs_mining_panel_hex5km_2000_2025.{rds,csv}` written by `b_04`
(different columns); repoint before re-running.

---

## a_06_mining_by_region_data.R + a_06_mining_by_region.qmd

**Moved 2026-11-25** from `code/1_remote_sensing/` (was `diag_05_data_prep.R` + `diag_05_mining_by_region.qmd`):
it describes the finished mining product rather than diagnosing a build stage. Output folders keep their
old names (`outputs/{figures,tables}/diag_05/`).

**Split 2026-11-06** into two files, on request, so the report can be re-rendered without a live EE
session: `a_06_mining_by_region_data.R` does the `ee_Authenticate()`/`ee_Initialize()`, the district
`reduceRegions()` exports (district + protected-area overlap), and **also** builds every ggplot and
calls `ggsave()` — it writes PNGs to `outputs/figures/diag_05/` and report-ready CSVs (already
arranged/sliced, e.g. `top10_districts.csv`, `region_increase.csv`) plus a small `diag05_meta.rds`
(the year range) to `outputs/tables/diag_05/`. `a_06_mining_by_region.qmd` only
`read_csv()`/`kable()`s those tables and `knitr::include_graphics()`s those PNGs — no `rgee`, `sf`,
or `googledrive` in its dependency list, so it renders offline. Run the `.R` script first (in
RStudio, interactively, for the EE browser login), then render the `.qmd`. The three canonical
outputs consumed elsewhere (`outputs/tables/mining_by_district.csv`, `mining_by_region.csv`,
`mining_protected_overlap_by_district.csv` — the last one feeds
`explore_mining_vs_forest_type_app.js`'s `DISTRICT_PROTECTED_STATS`) are unchanged in content and
path, just now written by the `.R` script instead of the `.qmd`.

**Purpose:** District/region-level overview of cumulative galamsey extent (`mine_mask_ghana_c4_{yr}`,
2017–2025, union-to-date) — national sanity check, region distribution/ranking/growth, top-10
districts, and how much of each district's mining falls inside a WDPA/WDOECM **Designated**
protected area (national parks, forest reserves — mostly the latter). Pulls protected areas
directly from the **public GEE catalog** (`WCMC/WDPA/current/polygons` + `WCMC/WDOECM/current/polygons`,
filtered to Ghana + Designated) — no upload needed, always current; `upload_protected_areas.R`
(a local WDPA/WDOECM Jul 2026 extract) is kept only as a fallback, not the primary path.

**Originally rewritten from `.Rmd` to Quarto `.qmd`** (2026-11-05), styled to match
`code/4_presentation/galamsey_motivation.qmd`'s colour identity (galawine `#450457` + the project's
plasma `MINING_PALETTE`) as a single scrollable HTML report, not a slide deck (a reveal.js format
was considered and rejected — this report's dense per-district tables and multi-panel figures don't
suit slide-by-slide presentation). The original `.Rmd`'s `MIN_MINING_KM2` cutoff-selection content
(a district-level distribution histogram + candidate-cutoff table) was **dropped** — that question
is settled (`explore_mining_vs_forest_type_app.js` already hardcodes `MIN_MINING_KM2 <- 1`) — and is
archived at `notes/archive/diag_05_mining_by_region.Rmd` if that reasoning is ever needed again.

**Feeds `explore_mining_vs_forest_type_app.js`'s `DISTRICT_PROTECTED_STATS`:** the protected-area
section's output CSV (`outputs/tables/mining_protected_overlap_by_district.csv`) is converted to a
plain JS object literal and pasted directly into the app — deliberately **not** computed live in
the app itself. An earlier version did reduce a painted WDPA/WDOECM mask inside the app's
`showStats()` and it measurably slowed every "Generate stats" click (painting the whole merged
collection per click, not just the handful of sites near the selected district); since this stat is
cross-sectional, there's no reason to ever recompute it per click, so a static lookup replaced the
live `reduceRegion`.

**Known rgee gotchas worked around (apply to any new script following this pattern):**
`ee_extract()` calls `ee$Image$reduceRegions(image=img, ...)`, a calling convention the installed
earthengine-api no longer accepts — bypassed throughout by calling `reduceRegions()`/`reduceRegion()`
directly; `ee$Filter$and()` doesn't exist in the Python client (`and` is a reserved keyword there,
unlike JS) — use `ee$Filter$And()`.
