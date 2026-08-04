---
output:
  html_document: default
  pdf_document: default
---
# Galamsey Task List
*Sree Ayyar · Hema Balarama · Yoshiki Wiskamp · Till Meissner — May 2026*

> **Update policy (2026-07-15):** this file is updated only when explicitly requested — not after
> every code change. Keep entries to STATUS, not history: what a script does, its state, and what
> remains. Per-script history lives in `CHANGELOG.md` (and, verbatim pre-cleanup, in
> `notes/archive/galamsey_tasklist_full_2026-07-15.md`); per-script detail in script headers and
> `code/*/explainer.md`.

---

## Overview

The project has two sequential phases:

1. **Remote Sensing** — Detect and classify gold mine presence across all of Ghana, 1995–2025, from satellite imagery. Barenblitt et al. (2021) (SW Ghana, 2007–2017 + 2019 cross-section) serves as ground truth and interim data source.
2. **Descriptives & Analysis** — Facts about galamsey incidence, spatial dynamics, and economic impacts. Currently on Barenblitt data; re-run on the RS panel once Part 1 is complete.

---

## Outstanding Tasks — Punch List

**Pipeline:** `0_data` → `1_remote_sensing` → `2_build` → `3_analysis` → `4_presentation`

### Data (`code/0_data/`)

- [ ] **River definition** for `dist_river_km` + flow treatment (OSM vs MERIT `upa` threshold vs RS measure) — see `rivers_exploration.Rmd`. **Blocked on geologist review.**
- [~] **Peak-EVI outcome pipeline** (Vashold et al. 2026): built in `b_03a_vi_panel.R` and run at 5/2 km. Remaining: 1 km run (needs a faster zonal engine, e.g. `exactextractr`); verify the ESA CCI class sets against the UN-LCCS legend; robustness with alternative masks (DE Africa 2022) and aggregation schemes.
- [ ] Re-download/re-stack the missing 2021–2024 MODIS land-cover layers (`d_01` Sec 9 requests 2001:2024, stack ends 2020).
- [ ] Acquire: historical mine-licence register (D3c), COCOBOD cocoa yields (D5c), census microdata / GLSS 7 (D6a–c). Wire CHIRPS into D3b (downloaded, unused).
- [~] **Maus et al. polygons** — EDA done (`d_09`, 2026-07-07: 577 Ghana polygons; 41.9% count- but 93.2% area-overlap with Barenblitt). Remaining: full validation/ensemble comparison vs Barenblitt + AMW + rs05.

### Remote Sensing (`code/1_remote_sensing/`)

- [ ] Review the Barenblitt GitHub classification code against the rs05 classifier.
- [~] **Africa Mining Watch** — EDA done (`d_08`, 2026-07-07: SW-Ghana pilot, 8.4% Barenblitt overlap). Remaining: full validation/ensemble comparison.
- [ ] RS6 — spatial cross-validation for the embedding classifier.
- [ ] RS7 — threshold probability maps → binary presence panel.
- [x] **RS8 — harmonised labels (`rs07_labels.R`)**: built + run 2026-07-14 (9,690 positives + 185 salvage points; exclusion mask 4.6% of Ghana; SmallMinesDS validation registry + points). §11 interactive leaflet QA map added 2026-07-15 (script not re-run since — cosmetic only). Consumed by rs05's successful 2026-07-15 run.
- [~] **RS5 — embedding classifier (`rs05_embedding_classifier.R`): RAN 2026-07-15.** RF ablation vs held-out SmallMinesDS-2022 complete (OA .84–.88; `all` = final model, PA .896/UA .862; circularity defused — see CHANGELOG); 8 annual probability maps (uint8 percent) exporting as EE assets (`ghana_mining/mine_prob_ghana_{yr}`) + training CSV to Drive. **Remaining:** sim_mean/sim_max baseline rows (new local implementation, needs its two small CSV exports run once); download training CSV → spatial CV (RS6); optional ROC/threshold sweep for the panel-step cut.

### Build (`code/2_build/`)

- [ ] Run `b_01_cross_section.R` under the current structure (downstream of `d_03_waterways.R`); then `b_02_firststage_models.R` full ladder.
- [ ] Run `b_03a_vi_panel.R` at 1 km (see peak-EVI item above).
- [ ] Extend the MERIT D8 hex flow graph beyond the study-area clip to all of Ghana.
- [x] Sub-basin SE clustering: HydroBASINS level-9 built (`d_07`), merged into panels (`b_03e`), and used by `run_cs()` via `block_num` (= `basin_num` where present) since 2026-07-08.

### Analysis (`code/3_analysis/`)

- [ ] Re-fit all event-study designs once the outcome revisions (peak-EVI robustness, river definition) settle.
- [ ] Knit `a_05_event_study_1.Rmd` and `_3.Rmd` at least once (`_2.Rmd` knitted at 5 km 2026-07-13; `_3` not re-reviewed since its 2026-07-08 restoration — treat first knit as provisional).
- [ ] Add Hansen Global Forest Change as an event-study outcome (literal forest-loss outcome alongside the VI proxies).
- [ ] Knit `a_03_firststage_diagnostics.Rmd` (needs `b_02_firststage_models.R` run first).
- [ ] D3b, D3c, D4a, D5c, D6a–c blocked on the data items above.

### Presentation (`code/4_presentation/`)

- [ ] Add V3/V3b event-study result slides to `galamsey_motivation.qmd` (es_* artifacts exist since the 2026-07-13 `_2.Rmd` knit).
- [ ] Update `methodology_explainer.md` once the outcome + river-definition questions are resolved.

---

## Code Structure

One line per script: role + status. Detail in script headers + `code/*/explainer.md`.

```
code/
├── 0_data/
│   ├── d_01_download_gee.R        ← in progress: GEE exports (Landsat VI 30m, MOD13Q1 16-day series, MODIS LC, CHIRPS, HydroBASINS) + local stacking; study-area-restricted
│   ├── d_02_elevation.R           ← in progress: DEM (elevatr z11) → slope rasters; per-hex extraction lives in 2_build
│   ├── d_03_waterways.R           ← in progress: OSM waterways download + natural-watercourse filter → waterways_natural.shp (PREREQUISITE for b_01); EDA + rivers map. Not yet run
│   ├── d_04_merit.R               ← in progress: MERIT DEM/Hydro download + D8 hex flow graph (native-4326 tracing), upstream-exposure builder, leaflet previews, ROUTE_KM2 sweep
│   ├── d_05_ndvi.R                ← in progress: VI stack QC diagnostics + MODIS/ESA-CCI land-cover diagnostics (incl. Ankobra leaflet) + forestcrop-missingness analyses
│   ├── d_06_gold_deposits.R       ← in progress: hydro-geomorphic placer indicators (WBT/SAGA) + Girard gold-suitability EDA. Not yet run
│   ├── d_07_hydrobasins.R         ← done: hex → HydroBASINS L9 sub-basin (SE clustering), 5/2/1 km (280/287/287 basins)
│   ├── d_08_africa_mining_watch.R ← done: AMW early-detections EDA (SW pilot; 8.4% Barenblitt overlap)
│   └── d_09_mining_mausetal.R     ← done: Maus v2 Ghana EDA (577 polygons; area-overlap 93.2%)
├── 1_remote_sensing/
│   ├── rs01_landsat_gee.R         ← in progress: Landsat 8/9 imagery download, Phase 1/2
│   ├── rs02_sentinel2_gee.R       ← in progress: Sentinel-2 download; Sec 8 leaflet Barenblitt overlay
│   ├── rs03_embedding_classifier_design.md ← design doc for the AlphaEarth approach
│   ├── rs05_embedding_classifier.R ← RAN 2026-07-15: AlphaEarth embeddings + RF (vintage-matched positives, exclusion-masked negatives — locations sampled locally, uploaded as EE assets under ghana_mining/). RF ablation scored on SmallMinesDS-2022 (OA .84–.88, 'all' = final model); prob-map assets 2017–2024 exporting (uint8 percent, PROB_TO_ASSET; Drive off). Remaining: similarity-baseline rows (local impl.), spatial CV
│   ├── rs05_approach_explainer.md  ← done 2026-07-15: plain-language methods explainer (+ HTML; schematic figures in outputs/figures/rs05_explainer/) incl. the why-not-Maus/Tang comparison
│   ├── rs06_smallminesds_peek.R   ← done: SmallMinesDS visual sanity check (not a pipeline stage)
│   ├── rs07_labels.R              ← done: label harmonisation (Barenblitt+Maus+Tang positives, exclusion mask, SmallMinesDS hold-out registry + validation points; leaflet QA map §11 added 2026-07-15, not yet re-run)
│   └── (planned slots rs03_spectral_indices / rs04_classification / rs05_validation / rs06_apply_classifier / rs07_export_panel ← TODO, uncreated; rs06/rs07 numbers now collide with the created scripts — rename slots when built)
├── 2_build/
│   ├── b_01_cross_section.R       ← todo: unified cross-section builder (districts + hex{1,2,5}km → CSVs + hex_{N}km_crosssection.rds). Not yet run
│   ├── b_02_firststage_models.R   ← in progress: M1–M5 first-stage ladder → d03_maup_results.rds; M5_ONLY ran, full ladder needs b_01 outputs
│   ├── b_03a_vi_panel.R           ← in progress: peak-EVI/NDVI pipeline (16-day MOD13Q1 × 6 CCI masks × mean/max = 25 cols). RUN 5/2 km 2026-07-06; 1 km deferred (perf)
│   ├── b_03b_own_mining.R         ← done: own/adjacent mining component, all 3 resolutions
│   ├── b_03c_flow_graph.R         ← done: D8 hex flow graph (ROUTE_KM2 = 10 primary + 50 alt), all 3 resolutions
│   ├── b_03d_flow_exposure.R      ← done: hop-ring exposure builder (K_HOPS=3 disjoint up/down/lateral rings + full catchment), re-run 2026-07-10
│   └── b_03e_assemble_eventpanel.R ← done: panel assembly (column-agnostic stocks/onsets, basin cluster keys, both thresholds); event_panel_{5,2}km current, 1 km awaits its VI panel
├── 3_analysis/
│   ├── a_01_incidence_maps.R      ← in progress: D1a–D1d produced; D1e (Lorenz) written, not run
│   ├── a_02_spatial_clustering.R  ← in progress: D2a–D2e (build half moved to b_01; re-run b_01 first)
│   ├── a_03_firststage_diagnostics.Rmd ← in progress: presentation layer for b_02 results; not yet knitted
│   ├── a_04_motivating_facts.R    ← in progress: D3a, D5a, D5b produced; rest blocked on data
│   ├── a_05_event_study_1.Rmd     ← in progress: Q0 own-hex mining → own-hex vegetation (C&S threshold sweep + dCDH; peak-VI outcomes, veg_narrow headline). Not yet knitted
│   ├── a_05_event_study_2.Rmd     ← in progress: Q1 upstream mining → downstream vegetation (C&S sweep incl. ≤3-hop cumulative exposures, restricted never-self-mined sample, interactive plotly overlays, V1/V3/V3b, dCDH). Knitted at 5 km 2026-07-13
│   ├── a_05_event_study_3.Rmd     ← in progress: Q2 neighbour mining → own mining; restored 2026-07-08, first knit pending/provisional
│   ├── a_06_dataset_panel.R       ← TODO: not yet created (Section 3 / D7)
│   ├── cluster_se_diagnostic.R    ← done: SE-clustering diagnostic (led to block_num fix)
│   ├── mask_missingness_e2_diagnostic.R ← todo: mask-NA vs cluster-concentration diagnostic (user to run)
│   └── ring1_dominance_diagnostic.R ← done: ring-1 dominance by threshold (justifies the ≤3-hop exposures)
└── 4_presentation/
    ├── galamsey_motivation.qmd    ← in progress: motivation deck incl. event-study methodology + results; V3/V3b slides pending
    ├── galamsey_motivation_slides.tex ← LaTeX/Beamer version
    └── methodology_explainer.md   ← conceptual methods explainer (update after outcome/river decisions)
```

---

## Status Key

| Symbol | Meaning |
|--------|---------|
| `done` | Script exists and output produced |
| `in progress` | Script started, not finalized |
| `todo` | Not yet started |
| `blocked` | Waiting on data or upstream task |

---

## Part 1 — Remote Sensing Pipeline

**Goal:** Produce an annual mine-presence raster/panel for all of Ghana, 1995–2025.

**Current data:** Barenblitt et al. (2021) shapefiles — SW Ghana, 2007–2017 (annual time series) + full 2019 extent. Used as training labels for the classifier.

| ID | Task | Status | Script |
|----|------|--------|--------|
| RS1 | Download Landsat 5/7/8/9 imagery via GEE (1995–2025, all Ghana) | in progress | `rs01_landsat_gee.R` |
| RS2 | Download Sentinel-2 imagery via GEE (2017–2025, all Ghana) | in progress | `rs02_sentinel2_gee.R` |
| RS3 | Compute spectral indices (NDVI, MNDWI, BSI, bare-soil bands) per year | todo | `rs03_spectral_indices.R` |
| RS4 | Train Random Forest classifier using Barenblitt labels as ground truth | todo | `rs04_classification.R` |
| RS5 | AlphaEarth embedding classifier: training samples + RF + annual probability maps 2017–2024 | run 2026-07-15 (ablation validated; map assets exporting; sim baselines + spatial CV pending) | `rs05_embedding_classifier.R` |
| RS6 | Spatial CV + accuracy assessment for embedding classifier (by district) | todo | `rs06_embedding_validation.R` |
| RS7 | Threshold probability maps → binary mine presence panel (hex / district × year) | todo | `rs07_embedding_panel.R` |
| RS8 | Harmonise external labels (Barenblitt + Maus + Tang & Werner + SmallMinesDS hold-out) → positives, exclusion mask, validation registry | done | `rs07_labels.R` |

---

## Part 2 — Descriptives & Analysis

**Current data:** Barenblitt shapefiles (SW Ghana, 2007–2019) + Girard gold-suitability layers.
**Eventual data:** Extended RS panel from Part 1 (all Ghana, 1995–2025).

> Scripts in this section should be written to accept a `mine_data` input so the data source can be swapped from Barenblitt to the RS panel without rewriting analysis code.

---

### Section 0 — Instrument Validity (First Stage)

| ID | Task | Status | Script |
|----|------|--------|--------|
| D0a | First-stage regression: gold-suitable geology → mining presence | removed | _superseded by D2c-FS + `b_02_firststage_models.R`_ |
| D0b | Residual map: mining vs geology prediction | removed | _superseded, as above_ |

---

### Section 1.1 — Incidence of Galamsey (1995–2025)

| ID | Task | Status | Script |
|----|------|--------|--------|
| D1a | Small-multiple maps + animated GIFs: cumulative/annual mining extent | done | `a_01_incidence_maps.R` |
| D1b | Artisanal vs industrial side-by-side choropleth (2019 extent) | done | `a_01_incidence_maps.R` |
| D1c | Time-series graphs: national cumulative fraction; unit shares; annual flows | done | `a_01_incidence_maps.R` |
| D1d | Summary stats + top-20 extent bar + national series vs gold price | done | `a_01_incidence_maps.R` |
| D1e | Lorenz curve: concentration of galamsey across districts | in progress | `a_01_incidence_maps.R` |

---

### Section 1.2 — Spatial Clustering and Expansion of Galamsey

| ID | Task | Status | Script |
|----|------|--------|--------|
| D2a | Global Moran's I time series (annual new mining, 2007–2017) + LISA | done | `a_02_spatial_clustering.R` |
| D2b | Moran's I: raw → geology-controlled → geology+river-controlled | done | `a_02_spatial_clustering.R` |
| D2bc | Geography-weighted null: observed I ~18× above joint null 95th pct | done | `a_02_spatial_clustering.R` |
| D2c-FS | First-stage LPM: river distance + gold suitability → mine presence | done | `a_02_spatial_clustering.R` |
| D2d | Spatial lag regression: neighbour stock t−1 → new mining t | done | `a_02_spatial_clustering.R` |
| D2d-Asym / D2e-Perm | Northing-proxy directional tests | removed | _superseded by a_05 MERIT designs_ |
| D2e | Upstream vs downstream spread along rivers (leads 1–3) | done | `a_02_spatial_clustering.R` |
| D2f | Event study around focal onset (upstream vs downstream stock) | done | `a_02_spatial_clustering.R` |
| D2bc-M5 | Spatial thin-plate-spline robustness (M4 + s(easting, northing)); passed at 5 km, integrated | in progress | `b_02_firststage_models.R` + `a_03_firststage_diagnostics.Rmd` |

---

### Section 2 — Motivating Facts

#### 2.1 What Triggers Expansion of Galamsey?

| ID | Task | Status | Script |
|----|------|--------|--------|
| D3a | National galamsey trend vs gold price time series | done | `a_04_motivating_facts.R` |
| D3b | Event-study: expansion vs climate shocks | blocked | `a_04_motivating_facts.R` |
| D3c | Does galamsey follow first formal gold mine in an area? | blocked | `a_04_motivating_facts.R` |

#### 2.2 Is There Reversion from Galamsey?

| ID | Task | Status | Script |
|----|------|--------|--------|
| D4a | Do galamsey areas eventually revert? | blocked | `a_04_motivating_facts.R` |
| D4b | Event-time plot: galamsey land share around year of first mine | done | `a_04_motivating_facts.R` |

#### 2.3 Does Galamsey Impact Agricultural Productivity?

| ID | Task | Status | Script |
|----|------|--------|--------|
| D5a | NDVI/EVI binned scatter vs distance to nearest mine | done | `a_04_motivating_facts.R` |
| D5b | Event study: NDVI/EVI around mine onset by distance band | done | `a_04_motivating_facts.R` |
| D5c | Cocoa yields (COCOBOD) around galamsey areas | blocked | `a_04_motivating_facts.R` |

#### 2.4 Does Galamsey Shift Labor Away from Agriculture?

| ID | Task | Status | Script |
|----|------|--------|--------|
| D6a | Formal/urban employment in high-galamsey districts | blocked | `a_04_motivating_facts.R` |
| D6b | Reported (formal) mining employment | blocked | `a_04_motivating_facts.R` |
| D6c | Labor movement into informal mining | blocked | `a_04_motivating_facts.R` |

---

### Section 3 — Constructing a Dataset

| ID | Task | Status | Script |
|----|------|--------|--------|
| D7a | Hexagon (1–3 km) or EA panel with land-use variables | todo | `a_06_dataset_panel.R` |
| D7b | Mining intensity + agricultural intensity (NDVI/EVI) over time | todo | `a_06_dataset_panel.R` |
| D7c | Merge census variables (2000, 2010, 2021) | todo | `a_06_dataset_panel.R` |

---

## Data Inventory

*Full dataset notes (including caveats and methodology) are in `data_inventory.md`.*

| Dataset | Temporal Coverage | Status |
|---------|-------------------|--------|
| Barenblitt et al. (2021) — annual mining extent | 2007–2017 | available |
| Barenblitt et al. (2021) — full mining extent 2019 | 2019 | available |
| Maus et al. (2022) v2 global mining polygons | 2019 snapshot | available |
| Tang & Werner (2023) global mining polygons | ~2019–2022 mixed | available |
| SmallMinesDS (Ofori-Ampofo et al. 2025) — ASGM masks | Jan 2016 + Jan 2022 | available (held-out validation) |
| Africa Mining Watch early detections | pilot snapshot | available |
| Girard et al. (2022) — gold-suitable geology (polygon + PRIO-Grid) | static | available |
| Ghana admin boundaries (admin0/1/2) | — | available |
| OSM waterways | — | available |
| MERIT DEM / Hydro (dir, upa, wth, elv) | static | available |
| HydroBASINS level 9 | static | available |
| Landsat 5/7/8/9 via GEE | 1995–2025 | in progress |
| Sentinel-2 via GEE | 2017–2025 | in progress |
| Landsat annual NDVI + EVI (30 m) | 1995–2025 | in progress (not used for now) |
| MODIS MOD13Q1 NDVI + EVI (250 m, 16-day) | 2000–2025 | available |
| MODIS MCD12Q1 Land Cover (500 m, annual) | 2001–2020 (stack) | in progress (2021–24 missing) |
| ESA CCI Land Cover (300 m, annual, via DE Africa) | 1995–2022 | downloaded + stacked |
| CHIRPS v2.0 rainfall | 1990–2025 | downloaded, unused |
| Ghana Mining Repository 2025 — licenses | 2025 snapshot | needs investigation |
| Ghana census microdata | 2000, 2010, 2021 | not yet acquired |
| COCOBOD cocoa yields | TBD | not yet acquired |
| GLSS 7 | 2016/17 | not yet acquired |

---

*Last major revision: 2026-07-15 — condensed from the accumulated-history version (archived at
`notes/archive/galamsey_tasklist_full_2026-07-15.md`); switched to on-request updates only.*
