---
output:
  html_document: default
  pdf_document: default
---
# Galamsey Task List
*Sree Ayyar · Hema Balarama · Yoshiki Wiskamp · Till Meissner — May 2026*

> **Update policy (2026-07-15):** this file is updated only when explicitly requested — not after
> every code change. Keep entries to STATUS, not history: what a script does, its state, and what
> remains. Per-script history lives in `CHANGELOG.md`; per-script detail in script headers and
> `code/*/explainer.md`; full dataset notes in `data_inventory.md`.
>
> **Revised 2026-11-06** — previous version (last substantively updated mid-July) had drifted badly
> out of date on the Remote Sensing side in particular (pre-reorg script names, a deployed classifier
> described as "todo"). This pass rewrites Part 1 and the RS/Data punch-list items against verified
> current state; Part 2/3's D-series tables were spot-checked but not re-audited line by line.

---

## Overview

The project has two sequential phases:

1. **Remote Sensing** — detect and classify gold mine presence across all of Ghana via Google Earth
   Engine. **Deployed**: a Random Forest on Google AlphaEarth embeddings (4-class, `no_maus` label
   combo, cutoff 70), classifying 2017–2025 directly and backdated to 2005–2016 by replicating
   Barenblitt et al.'s own NDVI-decline dating method. **Not yet validated as a Barenblitt
   replacement** — see Part 1 below.
2. **Descriptives & Analysis** — facts about galamsey incidence, spatial dynamics, and economic
   impacts. Currently runs on Barenblitt data; re-run on the RS panel once Part 1 is validated.

---

## Outstanding Tasks — Punch List

**Pipeline:** `0_data` → `1_remote_sensing` → `2_build` → `3_analysis` → `4_presentation`

### Data (`code/0_data/`)

- [ ] **River definition** for `dist_river_km` + flow treatment (OSM vs MERIT `upa` threshold vs RS measure) — see `rivers_exploration.Rmd`. **Blocked on geologist review.**
- [~] **Peak-EVI outcome pipeline**: built in `b_03a_vi_panel.R`, run at 5/2 km, 1 km deferred (perf). Remaining: 1 km run; verify ESA CCI class sets against UN-LCCS legend; robustness vs DE Africa 2022 masks.
- [ ] Re-download/re-stack the missing 2021–2024 MODIS land-cover layers (`d_01` Sec 9 requests 2001:2024, stack ends 2020).
- [🔒] Acquire: historical mine-licence register (D3c — partially unblocked, see below), COCOBOD cocoa yields (D5c), census microdata / GLSS 7 (D6a–c). Wire CHIRPS into D3b (downloaded, unused).
- [x] **Ghana Mining Repository EDA** (`d_12_mining_repository.R`): KML + Excel cadastre parsed, cross-file joins verified. `start_date` genuinely spans 1995–2025 (not a flat snapshot) — **this may partially unblock D3c**, pending confirmation it means first issuance, not latest renewal (a `2025-01-01` pileup in 392/1,786 rows needs checking first). See `data_inventory.md` §2.
- [ ] Decide spatial aggregation unit for final analysis — hexagons (5/2/1 km), admin units (district/EA), or both; both are already built throughout Part 2. See `data_inventory.md`'s Key Data Caveats.

### Remote Sensing (`code/1_remote_sensing/`)

Full script-by-script status: `code/1_remote_sensing/explainer.md` (re-run/re-read this, not this
section, for anything below day-to-day). Current pipeline: `build_01_labels.R` → `build_02_embedding_classifier.R`
→ `build_03_embedding_panel.R` → `build_04_backdating.R` → `2_build/b_04_rs_mining_panel.R`.

- [x] **Classifier deployed**: `build_02`/`build_03` fully exported 2017–2025 (c4/no_maus, cutoff 70, GHSL/GSW/GRIP4 knockouts, ICMM/Maus/Tang&Werner industrial-mine exclusion — 14 named mines).
- [x] **Backdating deployed**: `build_04` exported `mine_onset_year_2005_2016_barenblitt`. Validated against classifica: 14.3%/51.0%/60.6% exact/±1/±2yr (conditional on spatial agreement: 16.5%/58.6%/69.7%).
- [~] **Backdating window robustness** (2026-11-06): found the deployed layer's cumulative mining through 2007 runs ~20× Barenblitt's own figure (narrowing to ~2× by 2016) — read as left-censoring at `ONSET_MIN`, consistent with Barenblitt's own documented pre-2012 early-detection bias. **NEXT SESSION:** two more full `build_04` runs (`ONSET_MIN`=2000, 2007) were submitted 2026-11-06 — check the Code Editor Tasks tab / Drive for `mine_onset_year_{2000,2007}_2016_barenblitt` and the two new classifica-accuracy CSVs (`build_04_onset_vs_barenblitt_barenblitt_min{2000,2007}_max2016.csv`), then score via `diag_04_backdating.R`'s `report_existing_exports()` / Section 8c. `validate_backdating_method_fidelity.R` (anchors the dating formula to Barenblitt's own 2019 footprint instead of ours) is also still written but not run.
- [ ] **`b_04_rs_mining_panel.R`** has a real 5 km hex CSV, scoped to the Barenblitt hull only. Not yet extended to 2/1 km or national extent; panel long/wide assembly (Section 4) not yet written; `MIN_CONFIDENCE` filtering policy undecided.
- [ ] Industrial-mine exclusion confirmed deployed and visually QA'd, but not formally scored.
- [ ] Spatial cross-validation for the embedding classifier (by district) — not started.
- [ ] Score Maus/Tang & Werner/SmallMinesDS against each other more formally (currently informal EDA-level comparisons only).

### Build (`code/2_build/`)

- [x] `b_01_cross_section.R` run (hex 1/2/5 km + district caches exist). `b_02_firststage_models.R` full ladder run (`d03_maup_results.rds` exists). `b_03a`–`e` event panels exist at 1/2/5 km.
- [ ] Extend the MERIT D8 hex flow graph beyond the study-area clip to all of Ghana.
- [ ] `b_04_rs_mining_panel.R` — see Remote Sensing section above; this is the main open Build item now.

### Analysis (`code/3_analysis/`)

- [x] `a_05_event_study_1.Rmd` knitted (2026-07-16). `a_05_event_study_2.Rmd` knitted (2026-07-13). `a_05_event_study_2b.Rmd` knitted (2026-07-09, not in previous version of this list).
- [ ] `a_05_event_study_3.Rmd` not yet knitted — treat as provisional until it is.
- [ ] Re-fit all event-study designs once outcome revisions (peak-EVI robustness, river definition) settle.
- [ ] Add Hansen Global Forest Change as an event-study outcome.
- [x] `a_01_incidence_maps_rs.R` (new) — RS-panel equivalent of `a_01_incidence_maps.R`, built and run.
- [ ] D3b, D4a, D5c, D6a–c still blocked on the data items above; D3c partially unblocked (see Data section).

### Presentation (`code/4_presentation/`)

- [ ] Add V3/V3b event-study result slides to `galamsey_motivation.qmd`.
- [ ] Update `methodology_explainer.md` once the outcome + river-definition questions are resolved.

---

## Code Structure

```
code/
├── 0_data/            d_NN_* — raw-data acquisition & covariate builders
│                      (d_01 GEE downloads, d_02 elevation, d_03 waterways, d_04 MERIT,
│                       d_05 NDVI/land-cover QC, d_06 gold geology, d_07 HydroBASINS,
│                       d_10 forest-loss onset, d_11 protected areas, d_12 mining repository)
├── 1_remote_sensing/  explore_*/build_*/validate_*/diag_* — see explainer.md, not itemized here
│                      (drifts too fast to keep a duplicate list in sync — this is the second
│                       time that's happened; don't re-add one)
├── 2_build/           b_NN_* — writes data/processed/ artifacts
│                      (b_01 cross-sections, b_02 first-stage models, b_03a–e event panel,
│                       b_04 RS mining panel — new, in progress)
├── 3_analysis/        a_NN_* — figures, tables, reports (Barenblitt-based + a_01_..._rs.R RS twin)
└── 4_presentation/    Quarto/LaTeX slides summarizing motivation & findings
```

---

## Status Key

| Symbol | Meaning |
|--------|---------|
| `[x]` / `done` | Script exists and output produced |
| `[~]` / `in progress` | Script started, not finalized |
| `[ ]` / `todo` | Not yet started |
| `[🔒]` / `blocked` | Waiting on data or upstream task |

---

## Part 1 — Remote Sensing Pipeline

**Goal:** an annual mine-presence panel for all of Ghana, as far back as reliably possible.

**Status:** deployed and internally validated (see Punch List above), but **not yet validated as a
Barenblitt replacement** — a real gap between the two products exists and is only partly explained
(left-censoring at the backdating window floor, a Landsat Collection 1 vs 2 mismatch with
Barenblitt's own pipeline). `mine_data` has not been switched over in any Part 2/3 script.

| Stage | Task | Status | Script |
|-------|------|--------|--------|
| 1 | Harmonise external labels (Barenblitt + Tang & Werner; Maus tried, ablated out) + SmallMinesDS hold-out | done | `build_01_labels.R` |
| 2 | Train RF on AlphaEarth embeddings, export annual probability tiles 2017–2025 | done | `build_02_embedding_classifier.R` |
| 3 | Threshold + postprocess (water/road/urban/industrial knockouts) → annual binary mask | done | `build_03_embedding_panel.R` |
| 4 | Backdate 2005–2016 via Barenblitt-replica NDVI-decline dating | done, robustness pending | `build_04_backdating.R` |
| 5 | Assemble hex × year panel | 5 km only, bar_hull-scoped | `2_build/b_04_rs_mining_panel.R` |
| — | Spatial CV / district-level accuracy assessment | not started | — |

---

## Part 2 — Descriptives & Analysis

**Current data:** Barenblitt shapefiles (SW Ghana, 2007–2019) + Girard gold-suitability layers.
**Eventual data:** the RS panel from Part 1, once validated.

> Scripts in this section should be written to accept a `mine_data` input so the data source can be swapped from Barenblitt to the RS panel without rewriting analysis code.

*The D-series tables below (Sections 0–3) were spot-checked but not line-by-line re-audited in this
revision — most of this work predates the mid-July pivot to Part 1 and hasn't changed since. Flag
anything that looks wrong rather than assume it's current.*

---

### Section 0 — Instrument Validity (First Stage)

| ID | Task | Status | Script |
|----|------|--------|--------|
| D0a | First-stage regression: gold-suitable geology → mining presence | removed | _superseded by D2c-FS + `b_02_firststage_models.R`_ |
| D0b | Residual map: mining vs geology prediction | removed | _superseded, as above_ |

---

### Section 1.1 — Incidence of Galamsey

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
| D2e | Upstream vs downstream spread along rivers (leads 1–3) | done | `a_02_spatial_clustering.R` |
| D2f | Event study around focal onset (upstream vs downstream stock) | done | `a_02_spatial_clustering.R` |
| D2bc-M5 | Spatial thin-plate-spline robustness (M4 + s(easting, northing)) | in progress | `b_02_firststage_models.R` + `a_03_firststage_diagnostics.Rmd` |

---

### Section 2 — Motivating Facts

#### 2.1 What Triggers Expansion of Galamsey?

| ID | Task | Status | Script |
|----|------|--------|--------|
| D3a | National galamsey trend vs gold price time series | done | `a_04_motivating_facts.R` |
| D3b | Event-study: expansion vs climate shocks | blocked | `a_04_motivating_facts.R` |
| D3c | Does galamsey follow first formal gold mine in an area? | partially unblocked — see Data punch list | `a_04_motivating_facts.R` |

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
| D7a | Hexagon or EA panel with land-use variables | todo | `a_06_dataset_panel.R` |
| D7b | Mining intensity + agricultural intensity (NDVI/EVI) over time | todo | `a_06_dataset_panel.R` |
| D7c | Merge census variables (2000, 2010, 2021) | todo | `a_06_dataset_panel.R` |

---

*Full dataset inventory (sources, links, caveats) lives in `data_inventory.md` — not duplicated here.*

---

*Last major revision: 2026-11-06 — Part 1 and the Data/RS punch-list items rewritten against verified
current state (previous version, from 2026-07-15, had drifted to describing a pre-reorg,
not-yet-deployed classifier as the current one). Part 2/3 spot-checked, not re-audited.*
