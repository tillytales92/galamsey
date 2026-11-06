# Remote sensing — explainer

This folder is **Part 1** of the project: classify galamsey (illegal artisanal mine) presence
directly from satellite imagery via Google Earth Engine, so the RS-derived mine panel can eventually
replace Barenblitt as the `mine_data` source throughout Parts 2–3. It is the "swap-in" target the
build scripts are written around.

> **File-set current as of 2026-11-05.** Deployed model: 4-class (`c4` = mine/urban/water/other),
> `no_maus` label combo, cutoff **70**, GHSL-100m epoch-matched urban mask at **500**/10000, JRC
> GSW permanent-water/coast and GRIP4 road buffers, **plus industrial-mine exclusion (ICMM/Maus,
> reworked 2026-10-27, `APPLY_INDUSTRIAL <- TRUE`)** — no longer deferred; the deployed
> `mine_mask_ghana_c4_{yr}` assets already have named industrial mines subtracted, confirmed
> visually via `validate_finalproduct.js`. `build_03` has fully exported 2017–2025 (GEE Partner
> tier approved 2026-09-28, eliminating the earlier Contributor-tier quota throttling). `build_04`
> (backdating, 2005–2016) is deployed (Barenblitt method, `ONSET_MIN=2005`) and validated — see
> `diag_04_backdating.R`'s section below for the actual numbers. `code/2_build/b_04_rs_mining_panel.R`
> has produced its first real hex-panel CSV (5km, bar_hull-scoped). `embedding_classifier_approach.md`
> still reflects the 2026-09-15 c4/no_maus training config, which hasn't changed.

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
  `diag_02_external_references.R`. Note the prefix does double duty — some scripts genuinely test
  against never-trained-on data (`diag_02_external_references`, `validate_finalproduct`,
  `validate_site_timeseries`), others are internal model scoring/tuning
  (`diag_02_scoring`, `validate_min_patch_size_filter`, `validate_true_mines_urban_mask_100m`), and
  `validate_gee_assets` is a pipeline utility. **Renamed again 2026-11-03:** the "re-run as a
  decision-ready report when a build_NN stage changes" scripts (`diag_02_scoring`,
  `diag_02_external_references`, `diag_03_product_overlap`) got the new `diag_NN_*` prefix instead
  of `validate_*`, which is now reserved for one-off interactive Code-Editor scripts; the same pass
  archived `validate_spatial_leakage.R` (RS6 spatial-CV backlog item still open, just parked) to
  `notes/archive/`, plus several temporal-consistency investigation scripts whose questions had
  been fully answered.
  **Consolidated 2026-09-03:** `validate_ablation_sources.R` + `validate_probability_threshold.R` +
  `validate_threshold_comparison.R` → one `diag_02_scoring.R` (repointed off the stale binary CSVs
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
`diag_02_scoring.R` Part 3; Section 10's tiled export is what `build_03` reads.

**Full methodology, results, and honest limitations:** `embedding_classifier_approach.md` — read this
for the reasoning, not just the code comments.

**Section 9:** scores the actual deployed classifier against held-out SmallMinesDS-2022 at
continuous probability → `data/raw/embedding/c4_national_val_probability_scores_2022.csv` (feeds
`diag_02_scoring.R` Part 3). **Section 10** exports the national probability map, **tiled**:
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
GRIP4 Africa roads → **mask out named industrial mines** → export.

**Industrial-mine exclusion (Section 7, reworked 2026-10-27, `APPLY_INDUSTRIAL <- TRUE`, deployed):**
replaces an earlier, never-deployed Minerals-Commission-lease-based "gate + confirm" rule (dropped —
the lease shapefile ships degenerate 2-point-ring geometry that crashes `sf`/`sf_as_ee()`). Current
method: **ICMM's "Global Mining Dataset"** (`data/raw/mining_icmm/global_mining_dataset_1.5_corrected.kmz`)
supplies the *named, located* industrial mines for Ghana (High/Moderate confidence only, with
per-mine location corrections — e.g. a corrected Obuasi point kept *alongside* the original, not
replacing it). ICMM gives points, not footprints, so each named mine's real digitized extent is then
selected from **Maus et al. 2022 v2** or **Tang & Werner 2023** (per-mine source assignment,
`IND_MINE_CONFIG`), using one of three spatial rules depending on the mine: `buffer` (polygons within
a fixed radius, default 4 km, some mines override to 1 km), `touching_only` (polygons touching the
ICMM point), or `contiguous` (touching polygons *and* everything spatially connected to them — whole
mine complex, not just the seed polygon touching the point). A polygon independently claimed by more
than one mine is assigned to whichever mine's point is nearest (fixes e.g. Iduapriem vs. Tarkwa
sharing a Maus polygon). Result: **14 named Ghana industrial mines**, each dissolved to one footprint,
subtracted from every year's mask. The same selection is also persisted as its own standalone,
reusable dataset by `make_industrial_mines_dataset.R` → `data/processed/ghana_industrial_mines.gpkg`
(14 rows: mine, icmm_id, commodity, confidence, source, area_km2) — mirrors Section 7's logic exactly,
kept in sync by hand (see that script's own header), used e.g. by `a_01_incidence_maps_rs.R`'s
artisanal-vs-industrial map. Confirmed deployed on the live `mine_mask_ghana_c4_{yr}` assets via
`validate_finalproduct.js` visual QA (2026-11-04). Min-patch-size filtering and a temporal-consistency
rule remain stubbed behind `APPLY_*` flags — the min-patch-size question is now **closed** (see
`validate_min_patch_size_filter.js` below): the residual flagged area is coherent multi-pixel
patches, not scattered noise, so size filtering was rejected as a real lever.

**Recall check** (`diag_03_product_overlap.R`, 2019 deployed mask vs. Barenblitt): **85.8%**
artisanal recall — matches the pre-full-stack estimate, i.e. the water/road masks didn't cost real
detections. Still over-predicts Barenblitt by 2.1–2.5× nationally — **this number predates the
2026-10-27 industrial-exclusion rework above and hasn't been recomputed since**, so the over-
prediction ratio today is plausibly lower than 2.1–2.5×, not confirmed (see
`validate_fp_source_breakdown.R` below for the rest of the FP residual).

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

**Method (`METHOD`), two options, one deployed:**
- **`"barenblitt"` — DEPLOYED** (decided 2026-11-04, reversing the earlier LandTrendr-as-deploy
  plan below). Barenblitt et al.'s own "NDVI Anomaly Timeline" method, ported line-for-line from
  their GEE script (Collection 1 → Collection 2): annual max-NDVI, 3-year moving average, first
  difference, `qualityMosaic` on the derivative. No magnitude gate — always assigns a year
  wherever a 3-yr window exists. Chosen over LandTrendr because its tolerance accuracy (±1/±2yr
  vs `classifica`) matches or beats LandTrendr's, and it dates ~93–100% of the footprint vs
  LandTrendr's ~32–34%.
- **`"landtrendr"` — cross-check only, not deployed.** LandTrendr segmentation of an annual
  median-NBR series; onset = year of the largest drop in the *fitted* (denoised) trajectory,
  gated by `LT_MIN_MAGNITUDE`. Feeds the deployed layer's `lt_agree` confidence band (does the
  independent method land within ±2yr of Barenblitt's pick?) but never supplies a dating.

**Not comparable to Barenblitt's reported 33.8% exact / 69.4% ±1yr / 76.1% ±2yr:** that accuracy
is against independent analyst visual interpretation (Collect Earth / Google Earth Pro, 1 ha
blocks, model output hidden; Barenblitt et al. 2021, §2.6/§3.3), whereas scoring against
`classifica` measures agreement with their algorithm's output, not accuracy against real
conversion dates.

**Why LandTrendr over CCDC** (the original prototype's method; decided 2026-09-03): 2000–2016 is
Landsat 5 + SLC-off Landsat 7 over a cloudy country — often under 10 clear observations/year. CCDC's
harmonic fit needs denser data than that era has; LandTrendr needs only one composite per year and
is far less parameter-fragile at low observation counts. Barenblitt's own method is itself a
degenerate LandTrendr (a fixed 2-segment assumption + a 3-year smoother instead of a fitted
trajectory).

**Status as of 2026-11-05: DEPLOYED, `ONSET_MIN=2005`.** National 4-band asset
`mine_onset_year_2005_2016_barenblitt` (`onset_year`, `ndvi_deriv_x1000` confidence, `reference_tier`
— 0=no_reference for 2005-06/1=classifica_comparable for ≥2007, `lt_agree`) exported and landed.
`ONSET_MIN` moved from 2007→2005 after confirming the earlier 2007 cutoff was a `classifica`
label-floor artifact (classifica can't contain a year <2007), not a real imagery-quality cliff —
see `diag_04_backdating.R`'s own window-sweep below. Full validation results (same session) are
under `diag_04_backdating.R`.

**Caveats baked into the script:** only dates pixels still visible as mined in 2017+ (mines that
opened and fully revegetated before 2017 are invisible to it); a detected "break" is a spectral
disturbance, not necessarily the mining event itself (clearing that preceded mining on the same
pixel gets dated instead); output is 30 m (Landsat's native resolution, vs. the 10 m mask), with
the anchor footprint aggregated to majority-mined per 30 m cell; pre-2012 timing is biased early
(sparser cloud-free imagery available) — the same caveat Barenblitt make of their own layer.

---

## diag_04_backdating.R

**Purpose:** Decision-ready diagnostics for `build_04_backdating.R` — re-run whenever the anchor,
`METHOD`, `ONSET_MIN`/`MAX`, or `LT_MIN_MAGNITUDE` changes. Eight capabilities: score an
already-downloaded classifica CSV; submit+score a new method/window combo end-to-end; a fast
subsample pre-check; a `LT_MIN_MAGNITUDE` sweep; a scene-coverage (clear-obs/year) diagnostic;
a yearly expansion TREND comparison vs Barenblitt; a backdating/classifier seam continuity check;
a spatial-vs-timing disagreement decomposition.

**Section 8c (added 2026-11-06) — `run_yearly_expansion_trend(onset_min, ...)`:** re-runs Section
8's trend comparison at an arbitrary `ONSET_MIN`. Motivated by a 2026-11-06 observation that the
deployed layer's cumulative mining through 2007 is **~20x** Barenblitt's own cumulative that year
(66.6 vs 3.3 km², from `yearly_expansion_vs_barenblitt.csv`), narrowing to ~2.1x by 2016 — a
left-censoring signature (real pre-2005 mining has nowhere to go but the window floor). Tests
`onset_min=2000` (does the pileup just relocate to ~2001–2003?) and `onset_min=2007` (Barenblitt's
own window, directly comparable, no `reference_tier=0` years at all).

Prefers the REAL exported asset (`mine_onset_year_{min}_{max}_barenblitt`) when it exists — same
full-national-resolution asset the 2005–2016 deploy used — and only falls back to a from-scratch,
`bar_hull`-restricted recompute (via `build_onset_year()`, same helper Section 4 uses) as a rough
preview while that export is still running. **Decided 2026-11-06: do the robust version** — two
more full `build_04_backdating.R` runs (not just this diagnostic), at `ONSET_MIN=2000`
(`IMG_START` must also drop to `1998` — see that script's own updated `IMG_START` comment for why)
and `ONSET_MIN=2007` (`IMG_START` can stay `1999`), `ONSET_MAX=2016` unchanged both times. Each
submits the same 3 batch tasks the 2005 deploy did (Sections 10/11/12) under names now safely
suffixed by `_min{X}_max{Y}` (fixed 2026-11-06 — they were hardcoded before and would have
collided with the 2005 run's files on Drive/locally). Expect ~1hr per national export (Section 12),
same as the 2005 run. **Not yet submitted** — needs the user's interactive EE session, editing
those two constants by hand between runs (not committed — the file's canonical state stays at the
deployed `ONSET_MIN=2005`/`IMG_START=1999`).

**Validation results (2026-11-05), deployed asset, within `bar_hull` (Barenblitt's own SW
study-area hull):**
- **Pixel-level, vs `classifica`:** exact 14.3%, ±1yr 51.0%, ±2yr 60.6% (n=37,689) — see the
  caveat above on what this number does and doesn't mean.
- **Annual-expansion trend vs Barenblitt, 2007–2016:** annual-growth r=0.62, cumulative r=0.99.
  The cumulative figure is not very informative on its own (two series that both trend upward
  over a decade are mechanically highly correlated regardless of whether specific years line up)
  — the annual r=0.62 is the real signal, and sits right at the edge of significance for n=10.
  2007–2013 tracks well; 2014–2016 diverges (Barenblitt peaks 2014 then declines, ours keeps
  accelerating) — plausibly Barenblitt's own classifica confirmation lag near the end of their
  study period, but not confirmed (their own 2017 count doesn't show the same drop, which argues
  against a simple right-censoring story).
- **Backdating/classifier seam (2005–2025, `bar_hull`):** growth continues past the 2017 handoff
  without an implausible jump, though the very first classifier-era year (2017) isn't a clean
  comparison to the backdated series' last point — native-10m vs the backdated layer's
  30m-majority-rule reprojection differ by construction, so part of any apparent jump there is a
  resolution artifact, not real growth.
- **Spatial vs timing decomposition** (all 53,793 Barenblitt conversion points, not just the
  ones that survive a plain sampleRegions() join): 60.9% both methods agree + dated, 18.6% we
  recognize the pixel as a mine but couldn't confidently date it, 14.9% genuine spatial miss
  (never detected by us in any year 2017–2025), 5.6% detected, just after our 2017 anchor.
  Conditional on spatial agreement, timing accuracy is exact 16.5% / ±1yr 58.6% / ±2yr 69.7% —
  better than the unconditional number, but timing error remains a real, substantial factor on
  its own, not just an artifact of spatial disagreement.

**Overall read:** good enough to build on (`b_04_rs_mining_panel.R`), not a validated layer —
consistent with how this project has always treated Barenblitt comparisons (*agreement*, not
*accuracy*; their own producer accuracy is 75.6%, so part of any gap may be on their side too).
The 2005–2016 portion of any downstream panel carries real, non-trivial dating uncertainty.

---

## validate_backdating_method_fidelity.R

**Purpose:** a one-off question, deliberately kept OUT of `diag_04_backdating.R` since it isn't
tied to `build_04`'s own config the way everything in that script is (2026-11-06 naming-convention
call: `validate_*` = one-off, no re-run-on-config-change relationship; `diag_NN_*` = re-run when a
build stage changes). Isolates *method fidelity* from *spatial-footprint agreement*: anchors our
replicated Barenblitt dating formula to Barenblitt's **own** `FullConversiontoMiningExtent2019.shp`
footprint (uploaded once as `barenblitt_mining_2019_ext`) instead of our classifier's 2017 mask —
so every `classifica` point is, by construction, inside the anchor, and whatever dating
disagreement remains can't be blamed on "we didn't even detect that pixel."

**Motivated by a 2026-11-06 conversation** working through why `diag_04_backdating.R`'s existing
classifica accuracy (14.3%/51.0%/60.6% exact/±1/±2yr, classifier-anchored) looked low. Also
confirmed (separately, not part of this script's own comparison) a structural, unfixable
input-data mismatch with Barenblitt's own pipeline: their Step 1 cloud-masks via `pixel_qa`
(Landsat **Collection 1**'s QA band name), while this script (like `build_04`) reads Collection 2's
`QA_PIXEL` collections, since Collection 1 is now retired by USGS.

**Caveat:** `FullConversiontoMiningExtent2019.shp` cumulates through 2019; `classifica`
(`MiningConversion_2007-2017Vec.shp`) only runs 2007–2017, so pixels mined only in 2018–2019 are
simply unscored here (no error, just no reference to compare against). Window used:
`ONSET_MIN=2007`/`ONSET_MAX=2017` (classifica's own full range — unlike `build_04`'s `ONSET_MAX=2016`,
there's no reason to truncate early here since this isn't feeding our classifier's handoff at all).

**RUN 2026-11-06 — result: footprint-matching closes a real chunk of the gap.** Scored against the
same 53,793 classifica points, footprint-matched vs. the existing classifier-anchored comparison:

| | Coverage | Exact | ±1yr | ±2yr |
|---|---|---|---|---|
| Classifier-anchored (existing) | 70.1% (37,689/53,793) | 14.3% | 51.0% | 60.6% |
| **Footprint-matched (this script)** | **89.2% (48,006/53,793)** | **17.1%** | **58.3%** | **71.3%** |

Every metric improved, and scorable coverage nearly doubled — consistent with a real chunk of the
original gap being the spatial-detection confound (points our classifier never recognized at all),
not purely a dating-algorithm difference. Median absolute error 1yr, mean 2.16yr — most remaining
disagreement is small. The residual gap is plausibly the Collection 1-vs-2 mismatch above, but that
hasn't been separately tested here, just offered as the most likely remaining candidate.
(Deliberately NOT compared to Barenblitt's own self-validation ceiling, 33.8/69.4/76.1% —
that's their algorithm vs. independent human judgment, a different comparison type that doesn't
belong in this algorithm-vs-algorithm-output series; mentioned here only so it isn't re-added later.)

Output: `outputs/tables/backdating/validate_backdating_fidelity_classifica.csv`.

---

## diag_05_data_prep.R + diag_05_mining_by_region.qmd

**Split 2026-11-06** into two files, on request, so the report can be re-rendered without a live EE
session: `diag_05_data_prep.R` does the `ee_Authenticate()`/`ee_Initialize()`, the district
`reduceRegions()` exports (district + protected-area overlap), and **also** builds every ggplot and
calls `ggsave()` — it writes PNGs to `outputs/figures/diag_05/` and report-ready CSVs (already
arranged/sliced, e.g. `top10_districts.csv`, `region_increase.csv`) plus a small `diag05_meta.rds`
(the year range) to `outputs/tables/diag_05/`. `diag_05_mining_by_region.qmd` only
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

---

## diag_02_scoring.R

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

## diag_03_product_overlap.R

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

## validate_spatial_leakage.R -- ARCHIVED 2026-11-03 (notes/archive/, question still open, just parked)

**Purpose:** Cheap diagnostic for the RS6 spatial-CV backlog item. AlphaEarth embeddings are
spatially autocorrelated, so a SmallMinesDS validation point sitting near a training positive may
be "easy" even though never literally trained on — if so, the whole project's accuracy numbers are
optimistic exactly where it matters least (the northern predictions, the reason the classifier runs
nationally). For each validation point it computes distance to the nearest training-positive point
and checks whether accuracy at the deployed cutoff degrades with that distance. Flat = reassuring.
Not yet run. **Also stale as written** (2026-11-03 review): points at the old `mine_prob_ghana_2022`
single-binary-model asset and `PROB_THRESHOLD <- 55`, not the current `mine_prob_ghana_c4_{yr}`
tiled asset / cutoff 45 -- needs repointing to the deployed model before it can answer the question
for real.

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

## diag_02_external_references.R

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
  **This matters because `diag_02_scoring.R` scores everything against SmallMinesDS** — so this
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
- **Consolidated 2026-09-03** into `diag_02_scoring.R` (originals deleted, not archived — pure
  refactor): `validate_ablation_sources.R`, `validate_probability_threshold.R`,
  `validate_threshold_comparison.R`.
- Earlier archived (see `notes/archive/`): `validate_ntrees_ablation.R`,
  `validate_ghsl_100m_epochs.js`, `validate_positive_training_urban_check.js`,
  `validate_true_mines_urban_mask.js` (10 m version), `trial_multiclass_classifier.R`.
