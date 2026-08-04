# Remote sensing — explainer

This folder is **Part 1** of the project: classify galamsey (illegal artisanal mine) presence
directly from satellite imagery via Google Earth Engine, so the RS-derived mine panel can eventually
replace Barenblitt as the `mine_data` source throughout Parts 2–3. It is the "swap-in" target the
build scripts are written around.

Three families of scripts:
- **`rs01` / `rs02`** — interactive **exploration and change-detection** tools (Landsat and
  Sentinel-2). Visual index maps and candidate-mine masks for individual districts; not a panel
  builder.
- **`rs05`** — the **production classifier**: a Random Forest on Google's AlphaEarth satellite
  embeddings that outputs annual mine-probability maps for 2017–2024.
- **`rs03`** — a **design doc, not an executable script**: `rs03_embedding_classifier_design.md`
  lays out the embedding-classifier plan (data sources, workflow, validation strategy, open risks)
  that `rs05` implements. **Numbering gap:** there is no `rs04` — the tasklist's original RS3
  ("compute spectral indices per year") and RS4 ("train RF classifier on spectral bands") script
  slots were superseded once the AlphaEarth embedding approach proved viable; indices are instead
  computed inline in `rs01`/`rs02` Section 6, and classification jumped straight to the embedding
  classifier in `rs05`.

All scripts require the GEE setup from `CLAUDE.md` (`RETICULATE_PYTHON` / `EARTHENGINE_PYTHON`) and
must be run interactively — `ee_Authenticate()` / `ee_Initialize()` open browser windows.

---

## rs01_landsat_gee.R

**Purpose:** Interactive Landsat 8/9 exploration of galamsey signatures at the district level.
Builds cloud-masked 2-year median composites, computes the galamsey spectral fingerprint, and does
simple two-date change detection — all as toggleable `Map$addLayer` overlays for visual review, not
saved rasters.

**What it does:**
- **Section 3** loads Ghana admin boundaries + Barenblitt shapefiles and flags known galamsey
  districts by name-matching a hotspot list.
- **Section 4–5** merges L8 + L9 (`LANDSAT/LC0{8,9}/C02/T1_L2`), masks clouds via the `QA_PIXEL`
  bitmask, and composites a 2-year window to fill Ghana's forest-belt cloud gaps. Displays a
  false-colour SWIR1–NIR–Red pair for two dates side by side (`compare_district`).
- **Section 6** appends the **galamsey index fingerprint** to a reflectance-scaled composite:
  low **NDVI** (vegetation cleared), high **BSI** (exposed laterite/tailings), high **MNDWI**
  (standing water in pits), high **NDTI** (turbid/sediment-laden ponds).
- **Section 7** two-date change detection: flags candidate pixels that **both** lost vegetation
  (`ΔNDVI < ndvi_drop`) **and** gained bare-soil signal (`ΔBSI > bsi_gain`). Thresholds are
  conservative defaults to be calibrated against known sites / Barenblitt.
- **Section 8** an interactive leaflet map of the Barenblitt 2019 mine polygons by type.

**Note:** an important detail is that indices must be computed on **surface reflectance** (the
`× 0.0000275 − 0.2` scaling), not raw DN — the additive offset changes the normalized-difference
ratios.

---

## rs02_sentinel2_gee.R

**Purpose:** The Sentinel-2 twin of `rs01`, mirroring its structure section-for-section so the two
sensors can be compared on the same districts. Same galamsey fingerprint, same change-detection
logic; Sentinel-2's finer resolution and denser revisit are the payoff.

**Key differences vs Landsat (`rs01`):**
- Single collection `COPERNICUS/S2_SR_HARMONIZED` (no L8/L9 merge).
- Cloud masking via the per-pixel **SCL** band (classes 3, 8, 9, 10, 11) instead of `QA_PIXEL`
  bitmask — more accurate for tropical haze.
- 10 m native resolution (vs 30 m).
- Reflectance scaling `DN / 10000` (no additive offset, unlike Landsat C2L2).
- Data from June 2015 only; first complete calendar year is 2016.

Index formulas and vis params are identical (both operate on 0–1 reflectance) so results are
directly comparable to `rs01`.

---

## rs05_embedding_classifier.R

**Purpose:** The **production mine detector**. Trains Random Forests on Google's AlphaEarth
satellite embeddings using the harmonised multi-source labels from `rs07_labels.R`
(Barenblitt / Maus / Tang), runs a source ablation scored on held-out SmallMinesDS 2022, then
applies the final classifier to each year 2017–2025 to produce annual mine-**probability** maps.
This is the script whose output is intended to become the RS mine panel.

**Two spatial frames (SW/national split, 2026-07-16):**
- **Ablation frame** = convex hull of the Barenblitt-source positives + 10 km (`study_area_utm`,
  SW belt): dense labels + the SmallMinesDS validation set live here, so ablation numbers stay
  comparable across runs (SW sampling is seeded and bit-identical to pre-split runs).
- **Final-model frame** = Ghana admin0 outline (`ghana_utm`): the final classifier keeps the
  northern Maus/Tang positives (capped at `N_POS_NORTH = 500`/source), trains against *nationally*
  sampled negatives (savanna / bare soil / farmland the SW never shows it), and the probability
  maps are exported for **all of Ghana** — the point is to test whether the approach picks up
  northern mining absent from existing datasets. **Northern predictions are unvalidated** (no
  reference data up there): check high-probability northern patches against imagery / Africa
  Mining Watch (d_08) before use.

**Workflow:**
1. Load rs07 artifacts (positives by source, exclusion mask, SmallMinesDS validation points).
2. Sample training-point *locations* locally in R (positives area-weighted per source at fixed
   counts, 2,000/1,000/1,000; negatives 1:3 outside the exclusion mask — one SW pool for the
   ablation, one national pool for the final model), upload points + both frames + validation
   points as EE assets, then read each vintage's embedding (2019 barenblitt/maus, 2021 tang) at
   the points. Every sample carries `cls`/`source`/`vintage`/`region` (`sw`/`north`/`national`).
3. **Ablation** (SW only): RF per source combo (barenblitt / maus / tang / human / all) + local
   cosine-similarity baselines, all scored on balanced SmallMinesDS 2022 points →
   `outputs/tables/rs05_ablation_smallminesds2022.csv`.
4. Train the final binary + PROBABILITY `smileRandomForest(200)` classifiers on the national set
   (all positives + national negatives; SW ablation negatives excluded to avoid double-weighting
   the SW and skewing the class ratio). In-sample 80/20 check is reported but flagged as inflated —
   the honest score is the SmallMinesDS ablation row; spatial CV runs locally on the exported
   training CSV.
5. Apply the probability classifier to each year 2017–2025 → single-band uint8 `mine_prob`
   (integer percent) maps clipped to Ghana, exported to EE assets
   (`ghana_mining/mine_prob_ghana_{yr}`; Drive export behind `PROB_TO_DRIVE`, currently off).

**Parameters:** `EMBED_YEARS = 2017:2025`, `N_POS = c(barenblitt=2000, maus=1000, tang=1000)`,
`N_POS_NORTH = 500`, `NEG_RATIO = 3`, `N_TREES = 200`, `EXPORT_SCALE = 10 m`, `SEED = 42`.

**Outputs:** EE assets `mine_prob_ghana_{2017..2025}` (national, uint8 percent); Drive →
`data/raw/embedding/`: `mine_embedding_training_samples.csv` (full national training set with 64
bands + `cls`/`source`/`vintage`/`region`, for local spatial CV),
`rs05_pos_embeddings_trainpts.csv` + `rs05_val_embeddings_2022.csv` (SW positives / validation
embeddings for the local similarity baselines; cached — delete to force re-export);
`outputs/tables/rs05_ablation_smallminesds2022.csv`.

**Design notes:** `code/1_remote_sensing/rs03_embedding_classifier_design.md`.
