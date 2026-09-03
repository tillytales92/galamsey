# Remote sensing — explainer

This folder is **Part 1** of the project: classify galamsey (illegal artisanal mine) presence
directly from satellite imagery via Google Earth Engine, so the RS-derived mine panel can eventually
replace Barenblitt as the `mine_data` source throughout Parts 2–3. It is the "swap-in" target the
build scripts are written around.

> **File-set current as of 2026-09-03.** The *methodology* prose in the `build_02` and
> `validate_external_references` sections below still describes the old binary `all`-sources model
> at cutoff 55 — the deployed model is now 4-class (`c4` = mine/urban/water/other), `no_maus`
> label combo, cutoff **45**, with a GHSL-100m epoch-matched urban mask (settled 2026-08-18; see
> the `project_4class_urban_confusion` memory + `notes/2026-08-18_*`). `embedding_classifier_approach.md`
> and these sections get one combined rewrite after `build_03` + `build_04` are done.

**Reorganised 2026-08-04** into three role prefixes (mirroring the `d_`/`b_`/`a_` convention used in
Parts 0/2/3), replacing the old flat `rsNN` numbering — which had drifted out of dependency order
(the labels script, rs07, had to run *before* the classifier, rs05) and mixed pipeline stages,
one-off exploration, and external-dataset EDA under a single numbering scheme:

- **`explore_*`** — interactive exploration, not a pipeline dependency. Currently just
  `explore_landsat_sentinel.R`.
- **`build_*`** — the actual sequential pipeline that produces the RS mine panel, numbered because
  order matters: labels → classifier → panel (not yet built) → backdating (prototype).
- **`validate_*`** — sanity-checks and validation. No execution-order dependency between them, so
  unnumbered. **Redefined 2026-08-05:** previously this bucket also held EDA on Maus/Barenblitt
  *training* sources (`validate_mausetal.R`), which wasn't really validation. Retired that; the two
  genuinely independent references for Ghana (Africa Mining Watch, SmallMinesDS) are merged into
  `validate_external_references.R`. Note the prefix does double duty — some scripts genuinely test
  against never-trained-on data (`validate_external_references`, `validate_ground_truth_comparison`,
  `validate_spatial_leakage`, `validate_site_timeseries`), others are internal model scoring/tuning
  (`validate_scoring`, `validate_min_patch_size_filter`, `validate_true_mines_urban_mask_100m`), and
  `validate_gee_assets` is a pipeline utility.
  **Consolidated 2026-09-03:** `validate_ablation_sources.R` + `validate_probability_threshold.R` +
  `validate_threshold_comparison.R` → one `validate_scoring.R` (repointed off the stale binary CSVs
  onto the current c4 / class-scheme files). Archived to `notes/archive/` the same day:
  `validate_kumasi_urban_check.js`, `validate_low_cutoff_mask_comparison.js`,
  `validate_ghsl_100m_val_scores.R` (urban-confusion investigation, resolved) and
  `trial_4class_classifier.R` (superseded by `build_02`'s native c4 — kept as the provenance
  record for the still-live `mc4_train_pts_tagged` EE asset).

A fourth kind of script that used to live here — a one-off output figure made *from* the classifier's
results (the former `rs08_visualisation.R`) — has moved to `code/3_analysis/a_06_awomaso_case_study.R`,
since that folder's `a_NN_*` convention is specifically for output figures/tables/reports. The old
design doc (`rs03_embedding_classifier_design.md`) is archived to `notes/archive/` — superseded by
`embedding_classifier_approach.md` (the maintained plain-language explainer) now that `build_02`
implements what it proposed.

All GEE scripts require the setup from `CLAUDE.md` (`RETICULATE_PYTHON` / `EARTHENGINE_PYTHON`) and
must be run interactively — `ee_Authenticate()` / `ee_Initialize()` open browser windows.

---

## explore_landsat_sentinel.R

**Purpose:** Interactive Landsat 8/9 + Sentinel-2 exploration of galamsey spectral signatures at the
district level. Builds cloud-masked 2-year median composites, computes the galamsey spectral
fingerprint, and does simple two-date change detection — all as toggleable `Map$addLayer` overlays
for visual review, not saved rasters. Not a panel-builder.

**Merged 2026-08-04** from the former `rs01_landsat_gee.R` (Landsat) and `rs02_sentinel2_gee.R`
(Sentinel-2), which mirrored each other section-for-section (same district-comparison / index /
change-detection logic, just different collections, cloud masks, and reflectance scaling) — one
sensor-parameterized script replaces two near-duplicates. Pass `sensor = "landsat"` or `sensor = "s2"`
to `compare_district()` / `view_indices()` / `detect_mining_change()`.

**What it does:**
- **Section 3** loads Ghana admin boundaries + Barenblitt shapefiles and flags known galamsey
  districts by name-matching a hotspot list.
- **Section 4** sensor-specific composite builders (Landsat: L8+L9 merge, `QA_PIXEL` bitmask cloud
  mask; Sentinel-2: single collection, per-pixel `SCL` cloud mask — more accurate for tropical haze)
  behind a `SENSORS` dispatch table, so everything below is written once and works for either sensor.
- **Section 5** displays a false-colour SWIR1–NIR–Red pair for two dates side by side, per sensor.
- **Section 6** appends the **galamsey index fingerprint** to a reflectance-scaled composite:
  low **NDVI** (vegetation cleared), high **BSI** (exposed laterite/tailings), high **MNDWI**
  (standing water in pits), high **NDTI** (turbid/sediment-laden ponds). Index formulas are identical
  for both sensors once on 0–1 reflectance.
- **Section 7** two-date change detection: flags candidate pixels that **both** lost vegetation
  (`ΔNDVI < ndvi_drop`) **and** gained bare-soil signal (`ΔBSI > bsi_gain`). Thresholds are
  conservative defaults to be calibrated against known sites / Barenblitt.
- **Section 8** an interactive leaflet map of the Barenblitt 2019 mine polygons by type.

**Note:** indices must be computed on **surface reflectance** (Landsat's `× 0.0000275 − 0.2` scaling,
Sentinel-2's `/ 10000`), not raw DN — the scaling changes the normalized-difference ratios. Sentinel-2
data starts June 2015; first complete calendar year is 2016.

---

## build_01_labels.R

**Purpose:** Harmonise three external mining-label sources (Barenblitt, Maus, Tang & Werner) plus a
held-out validation source (SmallMinesDS) into the artifacts `build_02_embedding_classifier.R`
consumes. Offline script (no GEE / no auth).

**Renamed from `rs07_labels.R`** (2026-08-04) — it has to run *before* the classifier that depends on
it, so the old numbering (rs07 before rs05) had the pipeline's dependency order backwards.

**What it does:** erodes each source's polygons inward to their trustworthy cores (Maus −50m, Tang
−40m, matching their measured positional error; Barenblitt kept as-is), salvages small sites that
vanish under erosion as interior points, unions **all** raw footprints (including industrial mines
and SmallMinesDS patches) + a 1km buffer into an exclusion mask (negatives are only ever sampled
outside it), and converts SmallMinesDS's 2022 masks into a balanced point-level validation set.

**Outputs:** `data/processed/labels/*.rds` (positives by source, exclusion mask, SmallMinesDS
validation registry + points), `labels_summary.csv`, `labels_qa.gpkg`, plus QA maps in
`outputs/figures/labels/`.

**Design + full walkthrough:** `embedding_classifier_approach.md` §4–5 (erosion/exclusion logic,
vintage matching) is the maintained explanation of *why*; this section here is just *what*.

---

## build_02_embedding_classifier.R

**Purpose:** The **production mine detector**. Trains Random Forests on Google's AlphaEarth
satellite embeddings using `build_01_labels.R`'s harmonised multi-source labels, runs a source
ablation scored on held-out SmallMinesDS 2022, then applies the final classifier to each year
2017–2025 to produce annual mine-**probability** maps. This is the script whose output is intended
to become the RS mine panel.

**Renamed from `rs05_embedding_classifier.R`** (2026-08-04) to sort after `build_01_labels.R`, the
script it depends on. **Important:** the actual EE asset names and cached local CSV filenames this
script reads/writes (`rs05_train_pts`, `rs05_study_area`, `rs05_ghana`, `rs05_val_pts_2022`,
`rs05_pos_embeddings_trainpts.csv`, `rs05_val_embeddings_2022.csv`,
`rs05_ablation_smallminesds2022.csv`) were deliberately left unchanged — renaming them would make the
script's own reuse-if-exists checks think nothing exists yet and force a wasteful re-upload/re-export
of assets and CSVs that already exist from prior runs. Only the script filename and prose changed.

**Two spatial frames:** the ablation stays inside the SW study area (dense labels + SmallMinesDS
validation live there, so ablation numbers stay comparable across runs); the final classifier is
**national** (SW + capped northern Maus/Tang positives, nationally-sampled negatives), since a key
motivation for running this classifier at all is testing whether it picks up northern mining that
existing datasets miss. Northern predictions are **unvalidated** — no reference data exists up there.

**Status as of 2026-08-04:** ablation ran 2026-07-15 (OA .84–.88 across source combos; `all` is the
final model). National probability-map export is in progress — Section 9 checks each year's asset
before submitting and skips ones that already exist, so re-running just fills in whatever is still
missing rather than re-doing everything.

**Full methodology, results, and honest limitations:** `embedding_classifier_approach.md` — read this
for the reasoning, not just the code comments.

**Section 9:** scores the actual deployed classifier against held-out SmallMinesDS-2022 at
continuous probability → `data/raw/embedding/c4_national_val_probability_scores_2022.csv` (feeds
`validate_scoring.R` Part 3). **Section 10** exports the national probability map, **tiled**:
one EE asset per (year, tile), `mine_prob_ghana_c4_{yr}_t{NN}` (150 km tiles, ~17 per year), because
c4's array-typed MULTIPROBABILITY output is too expensive to export whole-country per year. A few
oversized (year, tile) cells go out as a 3×3 sub-grid (`_t{NN}s{MM}`) and are stitched back by
Section 10b's `recombine_split_tiles()`. `validate_gee_assets.R` checks completeness.

---

## build_03_embedding_panel.R

**Purpose:** Postprocess `build_02`'s c4 probability tiles into a clean **annual binary mine mask**
per year, 2017–2025 → EE assets `mine_mask_ghana_c4_{yr}`. **Sketch, not yet run** as of
2026-09-03.

**Pipeline per year:** mosaic the year's tiles → threshold at `prob >= 45` → mask out GHSL-100m
epoch-matched urban land (nearest real epoch from `{1975…2020,2025}`, `built_surface > 2000` ≈ 20%
built) → subtract Barenblitt industrial polygons (`minetype == 2`) → export. Two steps are
**deliberately stubbed** behind `APPLY_*` flags: the min-patch-size filter (needs
`validate_min_patch_size_filter.js` run first to pick `MIN_PATCH_SIZE`) and a temporal-consistency
rule (never designed past "≥2 consecutive years"). Runnable end-to-end today as a v0 without them.

**Scope stop:** ends at the annual 2017–2025 mask — does **not** aggregate to the hex × year panel.
That waits until after `build_04` backdates the mask to 2000–2016, so the panel is built from the
merged 2000–2025 surface (see `build_04` header + the `project_rs_pipeline_next_steps` memory).

---

## build_04_backdating_prototype.js

**Purpose:** Extend the classifier's "ever mined 2017–2025" footprint backward to 2000–2016 — a
period the embedding era can't reach (AlphaEarth only starts 2017) — by using CCDC change detection
on the 1997–2018 Landsat archive to date when each already-known mine pixel first broke from its
background trend. GEE Code Editor prototype (JavaScript), not yet ported to R or run nationally.

**Renamed from `rs09_backdating_prototype.js`** (2026-08-04) — reserved slot in the `build_*`
sequence, after `build_02_embedding_classifier.R` whose probability assets it reads.

**Caveats baked into the script:** only dates pixels still visible as mined in 2017+ (mines that
opened and fully revegetated before 2017 are invisible to it); a detected "break" is a spectral
disturbance, not necessarily the mining event itself (pre-mining clearing would get dated instead);
currently in `TUNE = true` mode (clipped to a single AOI for fast iteration) — needs parameter tuning
before a national run, and a validation hook against Barenblitt's per-parcel conversion years
(`MiningConversion_2007-2017Vec.shp`) is stubbed but not wired up.

---

## validate_scoring.R

**Purpose:** All SmallMinesDS-2022 scoring of the embedding classifier in one place — consolidates
(2026-09-03) `validate_ablation_sources.R` + `validate_threshold_comparison.R` +
`validate_probability_threshold.R`, repointed off the stale binary CSVs onto the current c4 /
class-scheme files. Offline (no GEE). Three parts:

- **Part 1 — label-source ablation:** which training-label combo (`barenblitt` / `maus` / `tang` /
  `human` / `no_maus` / `all`) generalises best, now split by class scheme (binary / c3 / c4) since
  `build_02`'s rewrite runs the full 3×6 grid. OA/kappa bars, PA/UA scatter, the "does dropping a
  source dominate on BOTH PA and UA" decision-rule checks, single-source precision check, plus
  `build_02` §7c's matched-precision table surfaced. Reads
  `outputs/tables/rs05_ablation_smallminesds2022.csv` (18 rows) +
  `class_scheme_matched_precision_comparison.csv`.
- **Part 2 — cross-scheme cutoff sweep:** full 0–100 PA/UA/F1 sweep for binary vs c3 vs c4 side by
  side (all SW ablation-scope, apples-to-apples). Reads
  `data/raw/embedding/{binary,c3,c4}_val_probability_scores_2022.csv` → writes
  `outputs/tables/class_scheme_threshold_sweep.csv`.
- **Part 3 — deployed model PR/ROC:** cutoff sweep + precision-recall curve + ROC/AUC for the
  *actual* deployed national c4/`no_maus` model (`data/raw/embedding/c4_national_val_probability_scores_2022.csv`).
  Annotates where the settled cutoff **45** sits; reports F1-max and Youden's-J for reference only
  (the cutoff was chosen 2026-08-18, not re-derived here).

The old `validate_probability_threshold.R` Section 6 (an EE round-trip GHSL urban-mask sweep against
the stale binary 2022 asset) is **dropped** — that question is settled.

**Output:** `outputs/figures/scoring/*.png`, `outputs/tables/class_scheme_threshold_sweep.csv`.

---

## validate_gee_assets.R

**Purpose:** Read-only inventory + completeness check for every EE asset the pipeline depends on
(`build_02` §5 support assets; the `mine_prob_ghana_c4_{yr}_t{NN}` probability tiles; `build_03`'s
`mine_mask_ghana_c4_{yr}` output). Rebuilds the expected tile grid with the same logic as
`build_02` §10a, probes each expected asset with `ee$data$getAsset()`, and prints a year × tile
presence matrix + per-year completeness + an explicit list of any gaps, then a full `listAssets`
folder inventory grouped by family. Run this to confirm `build_02` is done before starting
`build_03`.

---

## validate_ground_truth_comparison.R + .js

**Purpose:** Uploads AOI-scoped subsets of raw (un-eroded) Barenblitt / Maus / Tang polygons +
SmallMinesDS real mask outlines as small EE assets (`.R`), then a ready-to-paste Code Editor script
(`.js`) overlays all four plus a mosaic of `build_02`'s c4 2022 probability tiles (cutoff 45) on a
live Sentinel-2 2022 composite — open-ended visual judgment of which sources actually fit the
imagery, in Code Editor's native pan/zoom rather than a fixed metric. AOI is Awomaso-centred,
~41×41 km. Not yet run against the c4 output.

---

## validate_spatial_leakage.R

**Purpose:** Cheap diagnostic for the RS6 spatial-CV backlog item. AlphaEarth embeddings are
spatially autocorrelated, so a SmallMinesDS validation point sitting near a training positive may
be "easy" even though never literally trained on — if so, the whole project's accuracy numbers are
optimistic exactly where it matters least (the northern predictions, the reason the classifier runs
nationally). For each validation point it computes distance to the nearest training-positive point
and checks whether accuracy at the deployed cutoff degrades with that distance. Flat = reassuring.
Not yet run.

---

## validate_min_patch_size_filter.js

**Purpose:** Code Editor script testing the cheap post-hoc spatial filter for `build_03` §6a — does
removing small, spatially-isolated connected patches (`connectedPixelCount`) from the classified
mine mask clean up residual urban/edge false positives without a retrain? Tests cutoff 25 and 45
(both + the 100 m GHSL mask) across a range of patch-size thresholds over Kumasi. Its result sets
`build_03`'s `MIN_PATCH_SIZE`. **Not yet run** — `build_03` runs without the filter until it is.

---

## validate_true_mines_urban_mask_100m.js

**Purpose:** Code Editor script — how many SmallMinesDS-2022 true-mine validation points sit on
GHSL-flagged urban land, using the epoch-matched 100 m `GHS_BUILT_S` product. Confirmed the
mechanics `build_03` §5 ports: 11 usable epochs 1975–2025 (2030 excluded as projected);
`built_surface` scales with pixel area, so the 10 m threshold 20 rescales to 2000 at 100 m for the
same 20%-built definition; `nearestEpochYear()` / `builtSurfaceForYear()` helpers. Kept only as the
port reference until `build_03` §5 is confirmed working, then archive.

---

## validate_external_references.R

**Purpose:** The two genuinely independent (never-trained-on) mining references for Ghana —
Africa Mining Watch (AMW) early ML detections and SmallMinesDS expert masks — in one script.
**Merged 2026-08-05** from `validate_africa_mining_watch.R` + `validate_smallminesds_peek.R`,
which played the same structural role: unlike Barenblitt/Maus/Tang (all training-label sources),
neither AMW nor SmallMinesDS ever enters `build_02_embedding_classifier.R`'s training data, so
they're the only sources that can meaningfully validate the classifier rather than just
cross-check one training input against another.

**What it does:**
- **Part 1** (offline) — AMW EDA: confidence-score distributions, spatial coverage map, rectpoly
  footprint-size distribution. AMW is SW-Ghana pilot data only ("early_data" in the folder name),
  not national. Ported from the former `validate_africa_mining_watch.R` (itself relocated from
  `code/0_data/d_08_africa_mining_watch.R`, 2026-08-04).
- **Part 2** (offline) — SmallMinesDS visual sanity check: example image+mask patches (S2 true
  colour + binary mining mask) and an interactive leaflet view of where the labelled patches
  sit. Ported from the former `validate_smallminesds_peek.R` (renamed from
  `rs06_smallminesds_peek.R`, 2026-08-04).
- **Part 2b** (offline) — **new 2026-08-10**: district coverage of the full SmallMinesDS patch
  registry (all 4,270 patches, both epochs — not just Part 2's small visual-peek subset).
  **91% of patches sit in just 5 districts** (Amansie Central 1,034 / Amansie West 780 / Amansie
  South 728 / Upper Denkyira West 698 / Bekwai Municipal 652 — the Amansie–Bekwai–Obuasi gold
  belt, Ashanti + Central regions); 11 more districts are touched with single/double-digit counts,
  almost certainly patches straddling a district boundary rather than real independent coverage.
  **This matters because `validate_scoring.R` scores everything against SmallMinesDS** — so this
  5-district cluster is the *only* ground truth the classifier's accuracy numbers are actually
  measured against. National predictions outside it — especially northern Ghana, a key reason the
  classifier is run nationally at all — rest entirely on the classifier generalising, with no
  measured accuracy to back that up. Same caveat structure as AMW being SW-Ghana-only (Part 1),
  just quantified at the district level instead of asserted qualitatively.
- **Part 3** (needs rgee/EE, `RUN_PART3 <- FALSE` by default) — **new, limited to SmallMinesDS
  for now** (AMW dropped from this part 2026-08-05 — its site-level polygons and unconfirmed
  imagery vintage don't suit a per-pixel comparison the way SmallMinesDS's precisely-dated,
  pixel-resolution masks do). Defaults to Part 2's full `pick` (4 high-mining-share + 4
  nearest-10%-share patches, 8 total); pulls `mine_prob_ghana_2022` for each patch's exact
  extent and shows 4 panels per patch: S2 true colour + SmallMinesDS mining overlay, the
  SmallMinesDS mask alone in red (titled with its mining %), then one standalone panel per
  `PROB_THRESHOLDS_SHOWN` (default 55 vs. 90) — the classifier's own predicted mask at that
  cutoff, in blue (titled with its own predicted %), same solid-fill style as the SmallMinesDS
  panel but a contrasting colour — so shapes are compared *across* panels (does the blue shape
  at 55 vs. 90 resemble the red reference shape?) rather than stacked as an overlay within one.
  Lets cutoff choices be checked visually against `validate_probability_threshold.R`'s aggregate
  PA/UA numbers, and compared between obvious and ambiguous patches, not just trusted from the
  aggregate stats.

**Retired the same day: `validate_mausetal.R`** (EDA on Maus et al., relocated from
`code/0_data/d_09_mining_mausetal.R`, 2026-08-04). Maus is a *training* source for
`build_01_labels.R`, so comparing it to Barenblitt (also a training source) was training-input-
vs-training-input, not validation. Its content is superseded by `build_01_labels.R`'s own QA
(`labels_summary.csv`, `labels_overview_map`) plus the `build_02` Section 7 ablation, which is
the actual empirical test of whether Maus/Tang help.

**Output:** `outputs/figures/external_references/*.png` (incl. Part 2b's
`smallminesds_district_coverage.png` bar chart + `smallminesds_district_coverage_map.png`
choropleth) + one leaflet `.html`.

---

## validate_site_timeseries.R

**Purpose:** A parameterized site inspector for `build_02`'s `mine_prob_ghana_{yr}` output:
pull probability rasters directly from the EE assets for a chosen AOI and produce (1) a
before/after map panel and (2) a probability **time series** across all exported years — the
temporal-consistency QA check (does an AOI's probability move the way real mining should — rise
on entry, plateau, not flicker noise year to year?) flagged as a gap in an earlier discussion of
how to assess the classifier's quality.

**Replaces `validate_awomaso_case_study.R`** (2026-08-05): that script read one-off, manually
exported rasters for exactly 3 years (2017/2021/2024) from `data/raw/awomaso_figure/`; this
reads all 9 years directly from EE for *any* site, so it generalizes beyond Awomaso and needs no
manual export step. `data/raw/awomaso_figure/` is left in place, just no longer read by anything.

**History:** originally `rs08_visualisation.R` here → moved to
`code/3_analysis/a_06_awomaso_case_study.R` (2026-08-04) → moved back (2026-08-05) as
`validate_awomaso_case_study.R` → rewritten the same day as this general-purpose version.

**Caveat:** written without an interactive rgee session to test against — the `reduceRegion()`
band-name conventions and `ee_as_rast()` calls follow standard EE/rgee patterns but haven't been
run end-to-end. Section 3 (time series) is the higher-value, lower-risk half; if Section 4 (map
panel) breaks, the time series still stands alone.

**Outputs:** `outputs/figures/site_timeseries/{site}_probability_timeseries.png`,
`outputs/figures/site_timeseries/{site}_map_panel.png`.

---

## Archived / relocated, no longer in this folder

- `rs03_embedding_classifier_design.md` → `notes/archive/`. Superseded by
  `embedding_classifier_approach.md` now that `build_02` implements the plan; kept for the original
  design rationale, not as current documentation.
- **Archived 2026-09-03** to `notes/archive/` (urban-confusion investigation, resolved 2026-08-18):
  `validate_kumasi_urban_check.js`, `validate_low_cutoff_mask_comparison.js`,
  `validate_ghsl_100m_val_scores.R`. Also `trial_4class_classifier.R` — superseded by `build_02`'s
  native c4 training, kept as the provenance record for the still-live `mc4_train_pts_tagged` EE
  asset (do not delete that asset; `validate_min_patch_size_filter.js` retrains from it).
- **Consolidated 2026-09-03** into `validate_scoring.R` (originals deleted, not archived — pure
  refactor): `validate_ablation_sources.R`, `validate_probability_threshold.R`,
  `validate_threshold_comparison.R`.
- Earlier archived (see `notes/archive/`): `validate_ntrees_ablation.R`,
  `validate_ghsl_100m_epochs.js`, `validate_positive_training_urban_check.js`,
  `validate_true_mines_urban_mask.js` (10 m version), `trial_multiclass_classifier.R`.
