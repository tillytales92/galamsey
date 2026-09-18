# Remote sensing — explainer

This folder is **Part 1** of the project: classify galamsey (illegal artisanal mine) presence
directly from satellite imagery via Google Earth Engine, so the RS-derived mine panel can eventually
replace Barenblitt as the `mine_data` source throughout Parts 2–3. It is the "swap-in" target the
build scripts are written around.

> **File-set current as of 2026-09-15.** Deployed model: 4-class (`c4` = mine/urban/water/other),
> `no_maus` label combo, cutoff **70** (raised from 45 on 2026-09-09 for FP control), GHSL-100m
> epoch-matched urban mask at **500**/10000 (tightened from 2000), plus JRC GSW permanent-water/
> coast and GRIP4 road buffers; industrial-mine exclusion is deferred. `build_03` has run:
> 2017–2024 masks are exported, 2025 is pending — Earth Engine's noncommercial monthly compute
> quota (Contributor tier) is exhausted, so the export task is queued rather than blocked outright
> and should land once restricted-mode throttling eases or the quota resets 2026-10-01. `build_04`
> (backdating, 2000–2016) is implemented and bug-fixed but not yet validated end-to-end — same
> quota block, this time on the chunked Barenblitt validation-point upload (2/6 chunks landed).
> **`embedding_classifier_approach.md` was rewritten the same day** to match (c4/no_maus training
> config, the matched-precision scheme comparison, build_03/build_04 in plain language) — both docs
> are current as of 2026-09-15.

**Reorganised 2026-08-04** into three role prefixes (mirroring the `d_`/`b_`/`a_` convention used in
Parts 0/2/3), replacing the old flat `rsNN` numbering — which had drifted out of dependency order
(the labels script, rs07, had to run *before* the classifier, rs05) and mixed pipeline stages,
one-off exploration, and external-dataset EDA under a single numbering scheme:

- **`explore_*`** — interactive exploration, not a pipeline dependency. Currently just
  `explore_landsat_sentinel.R`.
- **`build_*`** — the actual sequential pipeline that produces the RS mine panel, numbered because
  order matters: labels → classifier → panel → backdating (2000–2016). See each script's section
  below for current status — the hex × year panel step itself is not yet named/built.
- **`validate_*`** — sanity-checks and validation. No execution-order dependency between them, so
  unnumbered. **Redefined 2026-08-05:** previously this bucket also held EDA on Maus/Barenblitt
  *training* sources (`validate_mausetal.R`), which wasn't really validation. Retired that; the two
  genuinely independent references for Ghana (Africa Mining Watch, SmallMinesDS) are merged into
  `validate_external_references.R`. Note the prefix does double duty — some scripts genuinely test
  against never-trained-on data (`validate_external_references`, `validate_finalproduct`,
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

**Status as of 2026-09-15:** rewritten and rerun 2026-08-18 to settle a model-selection question
raised by an urban-confusion investigation — a full grid of 3 class schemes (binary / c3 / c4) × 6
source combos, all scored on SmallMinesDS-2022. **c4 (4-class: mine/urban/water/other) + `no_maus`
(Maus dropped as a training source) won on every matched-precision comparison**; c3 actually scored
*worse than binary*, a genuine finding, not just "weaker than c4". Deployed as the national model;
all 153/153 `mine_prob_ghana_c4_{2017..2025}_t{01..17}` probability tiles are complete on EE
(`validate_gee_assets.R` confirms). Section 9's SmallMinesDS scoring CSV feeds
`validate_scoring.R` Part 3; Section 10's tiled export is what `build_03` reads.

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
per year, 2017–2025 → EE assets `mine_mask_ghana_c4_{yr}`.

**Status as of 2026-09-15:** v1 config settled and deployed (full FP-reduction investigation in
`notes/2026-09-07_build03_fp_postprocessing_plan.md` + `notes/2026-09-08_build03_config_decision.md`).
2017–2024 masks are exported; **2025 is still pending** — the EE noncommercial quota (Contributor
tier) ran out mid-month, so the export task is queued rather than blocked outright and should land
once restricted-mode throttling eases or the quota resets 2026-10-01.

**Pipeline per year:** mosaic the year's probability tiles → threshold at **`prob >= 70`** (raised
from the original 45 on 2026-09-09 — deployment-scale QA had found the 45-cutoff mask over-flagged
national area ~5× vs. Barenblitt; the cutoff bump alone does ~95% of that fix, at a recall cost of
0.95→0.84 within the Barenblitt hull) → mask out GHSL-100m epoch-matched urban land at
**`built_surface > 500`/10000** (tightened from 2000; Dynamic World was tried as a second urban
signal and dropped — it chewed into real pit clusters for little extra FP removal once the cutoff
was already at 70) → mask out JRC Global Surface Water permanent water (`occurrence >= 90`) plus a
150 m buffer around *wide* water bodies only (a morphological opening excludes river channels from
the buffer, so riparian galamsey — most of it — is never masked) → mask out a 35 m buffer around
GRIP4 Africa roads → export. Barenblitt industrial-polygon subtraction was reworked into a "gate +
confirm" rule (large-scale Minerals Commission lease ∩ (Maus ASM ≥1 km² ∪ Barenblitt industrial))
but is **deferred** (`APPLY_INDUSTRIAL <- FALSE`) — the lease shapefile ships degenerate
2-point-ring geometry that crashes `sf`/`sf_as_ee()`, and an earlier upload of the candidate
polygon over-masked some areas on visual QA. Min-patch-size filtering and a temporal-consistency
rule remain stubbed behind `APPLY_*` flags — the min-patch-size question is now **closed** (see
`validate_min_patch_size_filter.js` below): the residual flagged area is coherent multi-pixel
patches, not scattered noise, so size filtering was rejected as a real lever.

**Recall check** (`validate_product_overlap.R`, 2019 deployed mask vs. Barenblitt): **85.8%**
artisanal recall — matches the pre-full-stack estimate, i.e. the water/road masks didn't cost real
detections. Still over-predicts Barenblitt by 2.1–2.5× nationally, expected given industrial
exclusion is deferred and some FP residual remains (see `validate_fp_source_breakdown.R` below).

**Scope stop:** ends at the annual 2017–2025 mask — does **not** aggregate to the hex × year panel.
That waits until after `build_04` backdates the mask to 2000–2016, so the panel is built from the
merged 2000–2025 surface (see `build_04` below + the `project_rs_pipeline_next_steps` memory).

---

## build_04_backdating.R

**Purpose:** Extend `build_03`'s "ever mined 2017–2025" mask backward to per-pixel **onset years
for 2000–2016** — a period the embedding era can't reach (AlphaEarth only starts 2017) — by dating
each already-known mine pixel's vegetation-loss break in the Landsat 5/7/8 archive (1999–2018
imagery window).

**Rewritten from JS to R** (`build_04_backdating_prototype.js` → `build_04_backdating.R`, committed
2026-09-03) as an rgee script, with the anchor footprint switched from the old stale
`mine_prob_ghana_{yr}` binary-model asset names to `build_03`'s current `mine_mask_ghana_c4_{yr}`
masks. The old JS CCDC prototype is archived at
`notes/archive/build_04_backdating_prototype_ccdc.js`.

**Method switch (`METHOD`), two options:**
- **`"landtrendr"` (v1, the deploy path)** — LandTrendr segmentation of an annual median-NBR series
  (index inverted so vegetation loss reads as a rise); onset = the year of the single largest drop
  in the *fitted* (denoised) trajectory within 2000–2016, gated by a minimum disturbance magnitude.
- **`"barenblitt"` (v0, a replication)** — Barenblitt et al.'s own "NDVI Anomaly Timeline" method,
  ported line-for-line from their GEE script (Collection 1 → Collection 2): annual max-NDVI,
  3-year moving average, first difference, `qualityMosaic` on the derivative. Kept so results are
  directly comparable to their reported 33.8% exact-year / 69.4% ±1yr / 76.1% ±2yr accuracy against
  their own `MiningConversion_2007-2017` layer.

**Why LandTrendr over CCDC** (the original prototype's method; decided 2026-09-03): 2000–2016 is
Landsat 5 + SLC-off Landsat 7 over a cloudy country — often under 10 clear observations/year. CCDC's
harmonic fit needs denser data than that era has; LandTrendr needs only one composite per year and
is far less parameter-fragile at low observation counts. Barenblitt's own method is itself a
degenerate LandTrendr (a fixed 2-segment assumption + a 3-year smoother instead of a fitted
trajectory).

**Status as of 2026-09-15:** both methods are implemented and runnable in `TUNE` mode (clipped to
an Awomaso AOI). A LandTrendr array-dimension bug was found and fixed 2026-09-14 (`arraySlice()`
left a redundant axis that broke `arrayArgmax()`/`arrayFlatten()` downstream — fixed with
`arrayProject()`), but **the fix itself is still untested against a known site** — that's the next
check once EE capacity frees up, before trusting any onset year. Section 8's validation against
Barenblitt's `classifica` field (per-polygon conversion year, 2007–2017) uploads ~54k polygon
centroids as 6 chunked point assets (works around EE's table-upload payload limit); **2 of 6
chunks have landed**, the rest are queued behind the same exhausted EE quota blocking `build_03`'s
2025 export — Section 8 re-submits only the missing chunks and stops until all 6 exist, then merges
them server-side (`$merge()`) and samples the onset raster at the merged points.

**Caveats baked into the script:** only dates pixels still visible as mined in 2017+ (mines that
opened and fully revegetated before 2017 are invisible to it); a detected "break" is a spectral
disturbance, not necessarily the mining event itself (clearing that preceded mining on the same
pixel gets dated instead); output is 30 m (Landsat's native resolution, vs. the 10 m mask), with
the anchor footprint aggregated to majority-mined per 30 m cell; pre-2012 timing is biased early
(sparser cloud-free imagery available) — the same caveat Barenblitt make of their own layer.

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

## validate_finalproduct.R + .js

**Renamed 2026-09-17** from `validate_ground_truth_comparison.{R,js}` — "ground truth comparison"
undersold what the `.js` had grown into (full deployed-product QA: interactive cutoff/urban-threshold
tuning and a multi-site year comparison, not just a source-vs-source look).

**Purpose:** Uploads raw (un-eroded) Barenblitt / Maus / Tang polygons + SmallMinesDS real mask
outlines as EE assets (`.R`), then a hand-maintained (not auto-generated — see below) Code Editor
script (`.js`) overlays all four plus a mosaic of `build_02`'s c4 probability tiles, `build_03`'s
deployed mask asset, and Ghana admin-1 region outlines on a live Sentinel-2 composite — open-ended
visual judgment of which sources actually fit the imagery and where each post-processing step
(cutoff → +GHSL → +GSW/roads) removes area, in Code Editor's native pan/zoom rather than a fixed
metric.

**NATIONAL as of 2026-09-17** (was AOI-scoped, Awomaso-centred ~41×41 km): the `.js` gained a
`CHECK_SITES` dropdown that moves the Sentinel-2 composite to other sites, but the four reference-
product outlines stayed clipped to the original box and rendered nothing elsewhere. `validate_
finalproduct.R` now uploads all four nationally instead, using a chunked-and-persisted upload
(ported from `build_02_embedding_classifier.R`'s `upload_as_asset()`) since Barenblitt/Maus/Tang at
national scope are large enough to blow EE's ~10 MB inline-upload limit — the same failure
`build_02` hit uploading ~7,391 Barenblitt polygons. `gt_compare_smallminesds_aoi` was renamed to
`gt_compare_smallminesds` to match (no longer AOI-scoped). The `.js` no longer needs regenerating
by the `.R` script — an earlier version of `validate_finalproduct.R` auto-wrote the `.js` from a
template each run (old Section 7), but the `.js` has since been hand-built well past what that
template ever produced (see below), so that step was removed; re-running the `.R` script now only
refreshes the 4 EE assets.

**`.js` current state (2026-09-16/17 sliders + dropdown rewrite):** the fixed `{45,60,70}` cutoff-
comparison array is gone, replaced by two continuously-adjustable sliders (cutoff 0–100, GHSL urban
threshold 0–10000, top-right) driving one live raw/+GHSL layer pair plus the filter-cascade delta
layers. A YEAR slider (top-left, merged from the standalone `mine_prob_ghana_c4_{yr}_t0N` tile
script) auto-detects which years have both prob tiles and a deployed mask asset, so a year stuck
mid-export is skipped rather than erroring. The `CHECK_SITES` dropdown (top-center) moves the S2
composite (and, as of the national-assets fix above, the reference outlines) to named sites.
Area-stat prints (`printAreaStats()`) fire once on load and via a button thereafter — not on every
slider drag — to avoid a burst of `reduceRegion` calls.

**Originally rewritten 2026-09-09** to drop Dynamic World / permutation cruft, after its §2d (a live
cutoff × GHSL sweep scored against a Barenblitt-overlap recall proxy) directly produced the
`build_03` config decision: `CUTOFF 70` / `URBAN_THRESHOLD_100M 500` (see
`notes/2026-09-08_build03_config_decision.md`).

---

## validate_fp_source_breakdown.R

**Purpose:** Attributes `build_02`'s flagged area (probability tiles, not the post-cutoff mask) to
candidate false-positive sources at a sweep of cutoffs, so the `build_03` post-processing config is
chosen from evidence rather than eyeballing. Categories, checked in a fixed priority order so the
"disjoint" breakdown sums to 100% of flagged area: permanent/seasonal water (JRC GSW), rivers
(MERIT Hydro ≥30 m), roads (GRIP4 Africa), three **nested** urban rows (GHSL >2000 = what
`build_03` masks, the GHSL 1000–2000 ring = the increment a lower threshold would add, Dynamic
World built-probability = built-up neither GHSL band catches), plus an `unexplained` remainder
decomposed by Dynamic World land-cover class for diagnosis only (never maskable — cropland can't be
excluded).

**Written 2026-09-08**, superseding an earlier single-cutoff pass that had no roads layer and
missed most of the real urban signal. **Result (2022, run 2026-09-08):** total flagged 2944→1035
km² from cutoff 45→70; water/roads/GHSL-urban are nearly gone by 70; Dynamic World `urban_dw` is
the largest *named* FP category and persists (404→113 km²) — directly motivated dropping DW from
`build_03`'s urban mask (see that section above) since it removed pit clusters for little extra
gain past cutoff 70. `unexplained` falls 1755→833 km² but its *share* of the total rises 60%→80%.

**Re-run 2026-09-14 (cutoff-70 config, adds the `river` category):** `river` is real but small —
19.1 km² (1.84% of 1035.3 km² total flagged), rising in relative share with cutoff (more
persistent/harder to threshold away than road/urban FP, i.e. some genuine spectral confusion, not
just noise) — **turbid-river differential rule deprioritized** as a result: real but not worth the
engineering lift right now, revisit only if it shows up as spatially problematic in the hex-panel
event study. The dominant residual is `unexplained` (80.5%, 833 km²), ~46% Dynamic-World "trees"
class — but a direct visual spot-check of that area (2026-09-14) did **not** look like a real
problem, casting doubt on whether Dynamic World's own land-cover classification is reliable enough
to trust as a diagnostic layer here. **Open:** what the 833 km² unexplained remainder actually is
is unresolved — needs a direct visual/S2 spot-check of unexplained polygons, not DW-class
attribution, before deciding whether it's a real problem.

**Output:** long CSV (cutoff × category) + a disjoint-category pivot.

---

## validate_product_overlap.R

**Purpose:** Benchmarks our RS mine layer against every external mining product available for
Ghana — Barenblitt (SW-hull only, positive-labels-only), Maus et al. 2022 (global, industrial-
biased), Tang & Werner 2023 (global, better small-mine coverage) — all ~2019 snapshots, so only
our 2019 layer is compared. **None is ground truth**; every number is read as agreement/
triangulation, not accuracy. Reports, per region × product × cutoff: `both` (agreement), `our_only`
(our FP + their omissions + real growth since ~2019), `prod_only` (our omissions or relict
footprint no longer mined), plus recall/agreement/over-prediction ratios. A `deployed` cutoff row
reads `build_03`'s actual exported mask (cutoff 70 + full post-processing stack) as-is, distinct
from the raw cutoff-sweep rows (which use a `MASK` switch — `ghsl`/`dw`/`ghsl_dw`/`none` — for
apples-to-apples threshold comparison, independent of what's actually deployed).

**Renamed from `validate_barenblitt_overlap.R`** (2026-09-08) when extended from a Barenblitt-only
comparison to all three reference products.

**Result (2026-09-14, `deployed` row vs. `bar_hull`):** Barenblitt-artisanal recall **85.8%**
(Barenblitt-all 82.7%), matching the pre-full-stack 0.84 estimate — the water/road masks in
`build_03` didn't cost recall. `agree_frac` vs. the union of all three products = 85.2% (most of
what we flag matches a known product, not hallucinated). Still over-predicts Barenblitt by
2.1–2.5×, expected given industrial exclusion is still deferred plus residual FP (see
`validate_fp_source_breakdown.R` above). National `our_km2` (732.9) barely exceeds `bar_hull`-only
coverage (729.0) — only ~4 km² of detections sit outside the Barenblitt hull, flagged as worth a
closer look (little evidence of new northern mining vs. under-detection there — unresolved).
**Caveat:** the CSV's cutoff-sweep rows (45–80) use `MASK="ghsl_dw"` (includes the since-dropped
DW urban knockout), not the deployed GHSL-only recipe — don't read those as literal "what-if
cutoff X" numbers; only the `deployed` row reflects the actual current pipeline.

**Output:** `outputs/tables/product_overlap.csv` + console tables (one per region).

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
- **Archived 2026-09-03**: `build_04_backdating_prototype.js` (the CCDC-based JS prototype) →
  `notes/archive/build_04_backdating_prototype_ccdc.js`, superseded by the LandTrendr-based
  `build_04_backdating.R` rewrite (see that section above for why CCDC was rejected).
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
