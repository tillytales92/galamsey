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
event-study design — is documented separately in [`../4_presentation/methodology_explainer.md`](../4_presentation/methodology_explainer.md).**
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

## a_05_event_study.Rmd

**Purpose:** The **event-study report** — the causal core of the downstream-impact analysis. Reads
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
