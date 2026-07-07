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

**Purpose:** The **production mine detector**. Trains a Random Forest on Google's AlphaEarth
satellite embeddings using Barenblitt 2019 artisanal polygons as positive labels, then applies it to
each year 2017–2024 to produce annual mine-**probability** maps. This is the script whose output is
intended to become the RS mine panel.

**Workflow:**
1. Load Barenblitt 2019 **artisanal** polygons (`minetype == 1`) as positive training labels;
   study area = the convex hull of **all** Barenblitt 2019 polygons (artisanal + industrial, not
   just the artisanal training subset) — constrains sampling to the SW-Ghana survey region so
   negatives are real not-mine, not unsurveyed northern Ghana.
2. Build a binary label raster (1 = confirmed mine, 0 = non-mine in-study-area) and stack it with
   the 64-band `GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL` mosaic for the 2019 training year.
3. `stratifiedSample()` draws 2,000 mine + 6,000 non-mine points (1:3 ratio).
4. Train two `smileRandomForest(200)` classifiers — one binary (for maps), one PROBABILITY (for
   thresholding).
5. Assess accuracy on a random 80/20 split (confusion matrix, kappa, per-class producer/consumer
   accuracy). **Caveat flagged in-script:** the random split overstates accuracy under spatial
   autocorrelation — real spatial CV by district is a to-do (export the training CSV and run it in R).
6. Apply the probability classifier to each year 2017–2024 → single-band `mine_prob` maps, clipped
   to the study area, exported to Drive.

**Parameters:** `EMBED_YEARS = 2017:2024`, `TRAIN_YEAR = 2019`, `N_TREES = 200`,
`EXPORT_SCALE = 10 m`, `SEED = 42`.

**Outputs (to Google Drive → `data/raw/embedding/`):** `mine_prob_ghana_{2017..2024}.tif` +
`mine_embedding_training_samples.csv`. Section 10 (commented) stacks the downloaded probability maps
into `mine_prob_stack`, per its own comment "for `rs06_embedding_panel.R`" — that script does not
exist yet in this folder, so Section 10's output is currently unconsumed until it's written.

**Design notes:** `code/1_remote_sensing/rs03_embedding_classifier_design.md`.
