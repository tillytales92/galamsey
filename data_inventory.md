---
output:
  html_document: default
  pdf_document: default
---
# Data Inventory — Ghana Mining Project

Datasets are grouped **by purpose**. Where several datasets serve the same role (e.g. rivers from
OSM *and* MERIT Hydro; vegetation from Landsat *and* MODIS), they are listed together with a note on
why more than one source is kept and how they trade off. Each theme lists **datasets in the pipeline
today** and, below them, **potential/future sources** that could be added or would improve the
current ones.

**Status (availability):** ✅ available · 🔄 in progress (downloading/building) ·
⬜ not yet acquired (source identified, straightforward to pull) ·
🔒 not yet acquired (needs a formal request, or existence/access itself uncertain).
**Use:** **Current** = wired into the analysis now · **Potential** = candidate, planned, or acquired
but not yet used.

*See also: `galamsey_tasklist.md` (task status); `notes/barenblitt_dataset_documentation.md` and
`notes/girard_gold_suitability_documentation.md` (extended dataset notes);
`code/0_data/gold_deposits.md` (hydro-geomorphic instrument plan);
`code/0_data/rivers_exploration.Rmd` (river-definition exploration);
`code/1_remote_sensing/explainer.md` (script-by-script status/rationale for the RS mine-detection
pipeline) and `code/1_remote_sensing/embedding_classifier_approach.md` (plain-language methodology
write-up of §1's classifier + backdating).*

---

## 1. Mining extent & activity — the outcome / labels

The dependent variable of the whole project: where and when land was converted to mining. Barenblitt
is the current source; the RS panel below (this project's own classifier + backdating) is being
developed to **replace** it (the `mine_data` swap point in Part 2/3 scripts) — see "Why we had to
build our own product" below for why none of the existing shapefiles were enough on their own. For
the full script-by-script detail behind the summary here, see
`code/1_remote_sensing/explainer.md` (current status/config of every RS script) and
`code/1_remote_sensing/embedding_classifier_approach.md` (the plain-language methodology write-up).

| Dataset | Source | Coverage | Years | Status | Use | Script |
|---------|--------|----------|-------|--------|-----|--------|
| **RS mine-detection panel (this project)** | Random Forest on Google AlphaEarth embeddings (`build_02`) + NDVI-decline backdating (`build_04`) | All Ghana (classifier, 2017–2025); SW Ghana (Barenblitt hull) only for backdated years + all validation | 2005–2025 (2017–2025 classified directly; 2005–2016 backdated) | ✅ | Potential (will replace Barenblitt as `mine_data`; first real 5 km hex panel built 2026-11-05) | `1_remote_sensing/build_02_embedding_classifier.R` → `build_03_embedding_panel.R` → `build_04_backdating.R` → `2_build/b_04_rs_mining_panel.R` |
| Barenblitt — annual mining extent | Barenblitt et al. (2021), RF on Landsat. Paper: [doi.org/10.1016/j.scitotenv.2021.146644](https://doi.org/10.1016/j.scitotenv.2021.146644); data: [Mendeley Data](https://doi.org/10.17632/s4rfcckr39.2); code: [GitHub](https://github.com/abarenblitt/GhanaArtisanalMining) | SW Ghana | 2007–2017 | ✅ | Current (outcome label; also a configured industrial-footprint source, `IND_BARENBLITT_SHP`) | `2_build/b_01_cross_section.R` |
| Barenblitt — full mining extent 2019 | Barenblitt et al. (2021) — same sources as above | SW Ghana | 2019 (cross-section) | ✅ | Current (outcome label; only source with an artisanal/industrial split) | `2_build/b_01_cross_section.R` |
| Tang & Werner — mining polygons | Tang & Werner (2023), *Communications Earth & Environment* 4:134, hand-drawn contours, 0.15–10 m imagery, global (DOI not yet recorded here — check the paper if needed) | Ghana (1,907 polygons), mixed ~2019–22 vintage | static snapshot | ✅ | Current (artisanal training label, `no_maus` combo; industrial-mine footprint source at 3 named mines) | `1_remote_sensing/build_01_labels.R` / `build_03_embedding_panel.R` |
| Maus et al. — global mining polygons | Maus et al. (2022), *Scientific Data* 9:433, global mining-footprint delineation. Data: [Zenodo](https://doi.org/10.5281/zenodo.6806817) | Ghana subset (577 of 44,929 global polygons) | static snapshot | ✅ | Current (industrial-mine footprint source only — **dropped as an artisanal training label** 2026-08-18, `no_maus` won every matched-precision comparison) | `1_remote_sensing/build_01_labels.R` / `build_03_embedding_panel.R` |
| ICMM Global Mining Dataset | International Council on Mining & Metals. Data: [icmm.com/global-datasets/mining-metals-facilities](https://www.icmm.com/global-datasets/mining-metals-facilities) | Ghana (16 named points, 14 used after confidence filtering) | static snapshot | ✅ | Current (locates each known industrial mine by point; Maus/Tang & Werner then supply the footprint polygon around it) | `1_remote_sensing/build_03_embedding_panel.R` |
| SmallMinesDS | Ofori-Ampofo et al. (2025), *IEEE GRSL*, dense expert masks, 10 m. DOI: [10.1109/LGRS.2025.3566356](https://doi.org/10.1109/LGRS.2025.3566356); data: [HuggingFace `ellaampy/SmallMinesDS`](https://huggingface.co/datasets/ellaampy/SmallMinesDS) (CC-BY-SA-4.0) | 5 SW districts | Jan 2016 + Jan 2022 (2 epochs) | ✅ | Current (held-out validation — never enters training; primary accuracy benchmark) | `1_remote_sensing/build_01_labels.R` / `diag_02_scoring.R` |
| Africa Mining Watch — early detections | MLP detector (GeoJSON boxes + rectpolys). [africaminingwatch.org](https://www.africaminingwatch.org/) | SW Ghana (pilot bbox, not national) | 2025 snapshot | ✅ | Current, but **own EDA only** (confidence/coverage stats, Part 1) — deliberately NOT compared against our classifier output (dropped from the per-pixel overlay in Part 3, 2026-08-05: site-level polygons + unconfirmed imagery vintage don't suit that check); SmallMinesDS gets that treatment instead, not AMW | `1_remote_sensing/diag_02_external_references.R` |

**How the RS panel was built, and how its two eras differ** (brief — see
`embedding_classifier_approach.md` for the full walkthrough):

- **2017–2025 is a genuinely new, independent detection method** (`build_02`): a Random Forest
  trained on Google AlphaEarth's annual satellite embeddings (10 m, 64-band summary of everything
  the satellites saw that year), learning 4 classes (mine / urban / water / other — urban and water
  assigned at training time from GHSL `built_surface` + JRC water `occurrence`, with "mine always
  wins"). **Training data:** Barenblitt + Tang & Werner polygons (Maus was tried and ablated out —
  `no_maus` won every matched-precision comparison, 2026-08-18), held-out against SmallMinesDS. Run
  nationally per year → annual mine-probability tiles; `build_03` thresholds those (cutoff 70) and
  knocks out permanent water, roads, urban land, and named industrial mines → an annual binary mask.
  Barenblitt's polygons feed this only as *training labels* — the detection method itself owes it
  nothing.

- **2005–2016 is the opposite: not a new method at all, but a direct port of Barenblitt's own
  dating algorithm** (`build_04`), because AlphaEarth embeddings don't exist before 2017 so there is
  nothing new to classify on. Barenblitt's public GEE script
  ([abarenblitt/GhanaArtisanalMining](https://github.com/abarenblitt/GhanaArtisanalMining)) dates a
  conversion as the year of **steepest decline in a 3-year centred rolling NDVI average** — not
  necessarily the year mining actually started, just the year of the sharpest vegetation-loss
  *disturbance* (and since the underlying composites are Jan–Jun/dry-season only, mining that starts
  in H2 can register a year late). `build_04` replicates that exact method, pixel by pixel, but only
  applies it to pixels the *classifier* already knows are mined by 2017 (the "anchor") — so it's
  Barenblitt's dating logic running on our detection's footprint, extending the panel backward to
  where no embeddings exist. Being the same method, it inherits the same caveat, which is why its
  robustness to the choice of onset-year window is currently being tested (see
  `code/1_remote_sensing/explainer.md`'s `diag_04_backdating.R`/`build_04_backdating.R` sections).

**Why we had to build our own product** (condensed from `embedding_classifier_approach.md` §1):
none of the existing Ghana mining shapefiles give an **annual, national** panel, which is what the
economic analysis needs as its treatment clock, not a snapshot:
- **Barenblitt** — the best available before this project, but SW Ghana only, 2007–2017 only (no
  updates since), and 75.6% producer accuracy (positive labels only).
- **Maus et al. / Tang & Werner** — each a single snapshot (not a time series), no usable
  artisanal/industrial split for Ghana, and incomplete ASM coverage (Tang: case-study only; Maus:
  drawn around known *industrial* sites, so riverine galamsey is systematically under-drawn).
- **Africa Mining Watch** — a pilot bounding box only (not national), a single 2025 snapshot.

So instead of picking one, all three (Barenblitt + Maus + Tang & Werner) were harmonised as
candidate *training* labels (`build_01_labels.R`), with SmallMinesDS held back as an independent
*referee* never used in training — and a classifier trained on AlphaEarth embeddings generalises
from the learned *signature* of mining to produce the annual, national panel none of the source
shapefiles could supply on their own.

### 1.1 Raw satellite imagery — the classifier's inputs

Moved here from its own section (2026-11-06) — this is an *input* to §1's classifier, not a
separate final dataset in its own right.

| Dataset | Source (GEE collection) | Coverage | Years | Resolution | Status | Use | Script |
|---------|-------------------------|----------|-------|-----------|--------|-----|--------|
| Landsat 5/7/8/9 surface reflectance | `LANDSAT/LC0{8,9}/C02/T1_L2` (+ archive) | All Ghana | 1995–2025 | 30 m | 🔄 | Current (Part 1) | `1_remote_sensing/explore_landsat_sentinel.R` |
| Sentinel-2 surface reflectance | `COPERNICUS/S2_SR_HARMONIZED` | All Ghana | 2015–2025 | 10 m | 🔄 | Current (Part 1) | `1_remote_sensing/explore_landsat_sentinel.R` |
| AlphaEarth satellite embeddings | `GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL` | All Ghana | 2017–2025 | 10 m, 64-band | 🔄 | Current (Part 1) | `1_remote_sensing/build_02_embedding_classifier.R` |

**Why several:** Landsat gives the long historical archive (feeds `build_04`'s backdating);
Sentinel-2 the finest recent imagery (from mid-2015, full revisit from mid-2017); the AlphaEarth
**embeddings** are the feature space for the production RF mine classifier above.

---

## 2. Formal mine licences & ownership

Legal/industrial mining context — used to relate galamsey to formal concessions.

| Dataset | Source | Coverage | Years | Status | Use | Script |
|---------|--------|----------|-------|--------|-----|--------|
| Ghana Mining Repository — active licences (KML) | Minerals Commission data, via [ghana.revenuedev.org/map](https://ghana.revenuedev.org/map) | All Ghana, 1,279 granted/mapped concessions | per-licence `start_date` 1995–2025, `expiry_date` 2012–2055 | ✅ | Potential — EDA only, see note (not yet a covariate) | `0_data/d_12_mining_repository.R` |
| Ghana Mining Repository — pending applications (KML) | same | All Ghana, 6,894 pending/unmapped-code applications | per-application `application_date` 1997–2025 — but 81% (5,614 of 6,894) are 2022–2025, see note | ✅ | Potential — EDA only | `0_data/d_12_mining_repository.R` |
| Ghana Mining Repository — license register (Excel) | same | All Ghana, 1,786 rows (superset of the active KML's codes + 507 non-spatial licence types) | per-licence `start_date`, same field/range as active KML (1995–2025) | ✅ | Potential — EDA only | `0_data/d_12_mining_repository.R` |
| Ghana Mining Repository — owner register (Excel) | same | All Ghana, 20,494 companies/individuals | per-owner `Incorporation Date` (range not yet checked) | ✅ | Potential — EDA only | `0_data/d_12_mining_repository.R` |
| **Historical mine-licence register** | Minerals Commission / PMMC archive | All Ghana | licence issue dates (historical) | 🔒 | Potential | — |

**Note:** the table above was wrong in two ways until 2026-11-06 — (1) `d_12_mining_repository.R`
already exists and does real EDA (parsing, cross-file join-key checks, a `gold` dummy, 5 figures in
`outputs/figures/mining_repository/`) on all four files, not just "inspect raw files"; (2) this
*is* a real time series, not a flat 2025 snapshot — checking the cleaned outputs directly
(`data/processed/mining_repository/`) shows `start_date` in **both** the active-licence KML and the
license register spans **1995–04–19 to 2025–10–03** (confirmed, not assumed), with a real if thin
pre-2010 tail (2 rows in 1995, 13 in 1997, etc.) under a heavy recent skew (2019–2025 = ~64% of
rows). One thing worth checking before trusting it fully: **392 of 1,786 rows share the exact value
`2025-01-01`** — plausibly a default/placeholder rather than a genuine issue date; `d_12` extracts
the field but doesn't yet analyze its completeness/range, so this hasn't been resolved.

**Pending-applications backlog:** 6,894 pending vs. 1,279 granted licences (~5.4×) — a real
backlog, but mostly recent rather than decades-old: 81% of pending applications (5,614 of 6,894)
were filed 2022–2025 alone, against a thin trickle before that (single/double digits per year back
to 1997). Plausibly tied to Ghana's galamsey regularization/crackdown push in that window, but that
specific link hasn't been checked — flagging as a hypothesis, not a confirmed cause.

**Source / update check:** [ghana.revenuedev.org/map](https://ghana.revenuedev.org/map) — presents
Minerals Commission cadastre data, but note the domain itself is a third-party portal (RevenueDev),
not a `gov.gh` site, so this is Minerals Commission *data*, accessed via someone else's interface,
not a direct government download — worth keeping in mind for provenance. Since the backlog above
shows this register is actively changing (granted/pending counts will keep moving), re-check that
portal for a newer export before treating the 09-11-2025 snapshot as current.

This changes the D3c picture (`a_04`'s "does galamsey accelerate after the first formal mine
appears?" event study): it was recorded as **blocked** because "the 2025 snapshot has no
establishment-year field" — that's no longer accurate, the field exists and goes back decades. The
**remaining** blocker is narrower: confirming `start_date` means *first issuance* rather than
*most recent renewal* (which the 2025-01-01 pileup above makes worth checking first), not acquiring
a wholly separate historical register. The 🔒 row above is kept for a genuinely separate
PMMC/archival source, in case `start_date` turns out not to answer D3c on its own.

---

## 3. Gold geology & suitability — the exogenous instrument (Girard)

The exclusion-restriction candidate: exogenous variation in where gold *can* be mined.

| Dataset | Source | Coverage | Years | Resolution | Status | Use | Script |
|---------|--------|----------|-------|-----------|--------|-----|--------|
| Gold-suitable geology — polygon (Layer 1) | Girard et al. (2022) | Africa-wide | static | 1:10M vector | ✅ | Current | `0_data/d_06_gold_deposits.R` |
| Gold-suitable geology — raster | Girard et al. (2022) | Africa-wide | static | raster | ✅ | Current | `0_data/d_06_gold_deposits.R` |
| Gold suitability × PRIO-Grid (Layer 2) | Girard et al. (2022) + PRIO-GRID | Africa-wide | static | 0.5° (~55 km) | ✅ | Current | `0_data/d_06_gold_deposits.R` |

**Why two layers:** Layer 1 is the raw binary geology polygon (fine but categorical); Layer 2 is the
PRIO-Grid *share* of each 0.5° cell that is gold-suitable (a continuous instrument at a coarse grain).
**Caveat:** Girard geology is 1:10M scale — no meaningful spatial signal below ~5 km; omit or
down-weight `gold_suit_share` at 1–2 km grids.

---

## 4. Rivers & hydrology

Two representations of the river network, plus a sub-basin partition, are in use; the remaining
candidates add real-water observation and finer river topology. (See `code/0_data/rivers_exploration.Rmd`
for the full river-definition comparison.)

| Dataset | Source | Coverage | Years | Resolution | Status | Use | Script |
|---------|--------|----------|-------|-----------|--------|-----|--------|
| OSM waterways (lines) | OpenStreetMap, via [Geofabrik](https://download.geofabrik.de/africa.html) | Ghana | current snapshot | vector | ✅ | Current | `0_data/d_03_waterways.R` |
| MERIT Hydro (`dir`/`upa`/`wth`/`elv`) | Yamazaki et al. (2019), *Water Resources Research* 55:5053–5073. DOI: [10.1029/2019WR024873](https://doi.org/10.1029/2019WR024873) | Study area + Ankobra tiles | static | ~90 m | ✅ | Current | `0_data/d_04_merit.R` |
| JRC Global Surface Water | [`JRC/GSW1_4/GlobalSurfaceWater`](https://developers.google.com/earth-engine/datasets/catalog/JRC_GSW1_4_GlobalSurfaceWater) (GEE) | Global | 1984–2021 | 30 m | ✅ | **Current** — `occurrence>=90` knocks out permanent water + a coast strip in `build_03_embedding_panel.R` (`APPLY_WATER_MASK`, deployed 2026-09-09); corrected here 2026-11-06, was wrongly listed as not-yet-acquired | `1_remote_sensing/build_03_embedding_panel.R` |
| HydroBASINS (level-9 sub-basins) | WWF/HydroSHEDS [`WWF/HydroSHEDS/v1/Basins/hybas_9`](https://developers.google.com/earth-engine/datasets/catalog/WWF_HydroSHEDS_v1_Basins_hybas_9) (GEE) | Study area | static | ~sub-basin polygons | ✅ | Current | `0_data/d_01_download_gee.R` (download) → `0_data/d_07_hydrobasins.R` (hex assignment) |
| HydroSHEDS / HydroRIVERS | WWF / Lehner & Grill (2013), *Hydrological Processes* 27:2171–2186. DOI: [10.1002/hyp.9740](https://doi.org/10.1002/hyp.9740) | Global | static | 15 arc-sec | ⬜ | Potential | — |

**Why several:** **OSM** gives real, named rivers (distance-to-river, display) but is gap-prone.
**MERIT Hydro** is a modelled, gap-free channel network that reaches small tributaries and provides
the **D8 flow direction** for the upstream→downstream hex graph (must be traced on its native 4326
grid). **JRC** is used for exactly the role once planned for it — flagging actual standing water —
though currently as a *postprocessing knockout in the RS classifier* (§1), not yet as a
cross-validation check on MERIT's channels in Part 2/3's own hex covariates; that original
"validate MERIT channels" use is still open.
**HydroBASINS** now supplies real **sub-basin IDs** for the event-study SE clustering — downloaded
2026-07-06 (`d_01` Sec 6b, 453 basins in the study region) and assigned to hexes by `d_07_hydrobasins.R`
(280 level-9 basins over the 5 km grid, `basin_num` factor), replacing the earlier 25 km
centroid-block stand-in (`event_study_design.md` SE-clustering section; the stand-in remains a
fallback where `basin_num` is unpopulated, e.g. the deferred 1 km grid). **HydroRIVERS** (vector
river lines/topology) remains a candidate, distinct from the already-integrated HydroBASINS polygons.

---

## 5. Terrain & elevation

| Dataset | Source | Coverage | Years | Resolution | Status | Use | Script |
|---------|--------|----------|-------|-----------|--------|-----|--------|
| DEM + slope | AWS Terrain Tiles via `elevatr` | Ghana + 10 km buffer | static | z11 (~76 m) | ✅ | Current | `0_data/d_02_elevation.R` |
| MERIT-DEM | Yamazaki et al. (2017), *Geophysical Research Letters* 44:5844–5853. DOI: [10.1002/2017GL072874](https://doi.org/10.1002/2017GL072874) | Study area + Ankobra tiles | static | ~90 m | ✅ | Potential | `0_data/d_04_merit.R` |

**Why two:** the `elevatr` DEM supplies the per-hex `elev_mean` / `slope_mean` covariates — confirmed
genuinely in use (`elev_mean`/`slope_mean` are extracted and joined in `b_01_cross_section.R`).
MERIT-DEM is the base for the placer/valley-bottom indices (HAND, MRVBF, SPI/STI) `d_06`/`d_04`
compute (checked 2026-11-06: genuinely written to disk, but consumed nowhere downstream) — a parked
idea, not actively pursued. See `code/0_data/gold_deposits.md` for the full placer-geomorphology
plan and rationale; not re-explained here.

---

## 6. Vegetation indices — agricultural-productivity outcome

NDVI/EVI as the downstream outcome for the waterborne-degradation event study and productivity
descriptives.

| Dataset | Source (GEE collection) | Coverage | Years | Resolution | Status | Use | Script |
|---------|-------------------------|----------|-------|-----------|--------|-----|--------|
| MODIS VI (NDVI + EVI) | `MODIS/061/MOD13Q1` (QA-filtered 16-day series; annual mean derived locally) | All Ghana | 2000–2025 | 250 m | ✅ | Current | `0_data/d_01_download_gee.R` |
| Landsat annual VI (NDVI + EVI) | `LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_NDVI` + `_ANNUAL_EVI` | All Ghana | 1995–2025 | 30 m | 🔄 | Potential — **not used for now** (high NA share) | `0_data/d_01_download_gee.R` |

**Why both sensors:** **MODIS** (`MOD13Q1`, 250 m, from 2000) is the one actually in use — QA-filtered
to ~16% NA/year, far more complete than **Landsat** (finer at 30 m, back to 1995, but ~30–36%
NA/year from cloud). The event study is built on MODIS peak (max) NDVI/EVI, masked by ESA CCI land
cover — checked against the actual scripts 2026-11-06, since this had gone stale: `a_05_event_study_1.Rmd`
(Q0, own-hex) now heads with the **`no-mine-crop`** mask (`evi_modis_nominecrop_max`, headline since
2026-07-16) — `veg_narrow` was its *former* headline and has since been dropped there entirely;
`a_05_event_study_2.Rmd` (Q1, upstream→downstream) heads with **`evi_modis_veg_narrow_max`** (EVI,
the `veg_narrow` cropland-union-forest mask) — i.e. the two files' headlines are NOT what they were
when this note was last written (veg_narrow moved from `_1`'s headline to `_2`'s, and NDVI/cropland
is not actually either file's headline). The full NDVI/EVI × {veg-narrow, no-mine-crop, cropland}
outcome grid is still looped as robustness in both.
**Landsat VI is downloaded but not used for now** — its ~30–36% NA/year (cloud) share is too high for
the annual panel; it is retained as the finer-grained (30 m), longer-history (from 1995) alternative
to revisit once a better cloud-gap-filling composite is in place. Missingness diagnostics:
`0_data/d_05_ndvi.R`. *(MODIS VI upgraded from the 1 km `MOD13A2` to the 250 m `MOD13Q1` on
2026-07-03 — same bands and `SummaryQA` scheme and scale factor; re-export complete, full
2000–2025 16-day series and annual stacks are on disk.)*

**Export region (2026-07-03):** `d_01` now restricts **all** its GEE exports to the Barenblitt study
area (SW Ghana + 25 km buffer) via a single `export_region` variable — the full-Ghana 30 m Landsat
export tiled into multiple GeoTIFFs, and the study area is all the analysis needs. The full-Ghana
region is retained but commented out (one-line scale-up). The existing land-cover / CHIRPS files on
disk are still national (not re-exported, since their data is unchanged); re-running those sections
would produce study-area versions.

**MODIS VI is now downloaded as the full QA-masked 16-day series** (`modis_{ndvi,evi}_16day_ghana_{yr}.tif`,
~23 bands/yr), not a GEE-side annual mean — this is what the peak-EVI outcome (ESA CCI mask per
16-day step → per-hex mean → annual max) requires. `d_01` Section 9 derives the annual-mean stacks
(`modis_{ndvi,evi}_ghana_stack.tif`) from them locally, so the current annual-outcome scripts are
unaffected.

---

## 7. Land cover

| Dataset | Source | Coverage | Years | Resolution | Status | Use | Script |
|---------|--------|----------|-------|-----------|--------|-----|--------|
| ESA CCI land cover (UN-LCCS) | ESA/C3S CCI via Digital Earth Africa STAC (`cci_landcover`) | All Ghana | 1995–2022 | 300 m | ✅ | Current (peak-EVI outcome mask) | `0_data/download_land_cover_ghana.ipynb`; stacked in `d_01` Sec 9 |
| ForTy — Forest Typology | DeepMind/Google Research/WRI/IIASA. [Blog](https://deepmind.google/blog/beyond-tree-cover-mapping-the-worlds-forest-types/); [EE catalog](https://developers.google.com/earth-engine/datasets/catalog/projects_nature-trace_assets_forest_typology_forest_typology_2020_v1_0_collection) | Global, clipped to Ghana | **2020 only** — blog describes an annual 2017–2025 series, but its EE asset ID isn't confirmed, so this project uses the fixed 2020 baseline | resolution not recorded here | ✅ | Current, but narrowly — see note | `1_remote_sensing/explore_mining_vs_forest_type_app.js` |
| MODIS land cover (IGBP `LC_Type1`) | `MODIS/061/MCD12Q1` | All Ghana | **2001–2020**\* | 500 m | 🔄 | Current | `0_data/d_01_download_gee.R` |
| Hansen Global Forest Change | `UMD/hansen/global_forest_change_2025_v1_13` | All Ghana (national, single static image) | 2000–2025 | 30 m | 🔄 | Potential | `0_data/d_01_download_gee.R` |
| ESA WorldCover | `ESA/WorldCover/v200` (Sentinel-1/2) | Global | 2020, 2021 | 10 m | ⬜ | Potential | — |
| Google Dynamic World | `GOOGLE/DYNAMICWORLD/V1` (Sentinel-2) | Global | 2015–present | 10 m | ⬜ | Potential | — |

**ESA CCI (300 m, 1995–2022) is the preferred land-cover source** and the mask for the peak-EVI
outcome — its finer legend separates evergreen/deciduous tree cover and rainfed cropland from
mosaics, covers the full VI history, and doesn't stop at 2020 like the MODIS stack. MODIS MCD12Q1
(IGBP) is retained only as a coarser comparison. Diagnostics for both: `d_05_ndvi.R`.

**No separate "Landsat land cover" exists** — the `*_landsat_forestcrop` panel columns just resample
the MODIS/CCI layer onto the Landsat 30 m grid (`b_03a_vi_panel.R`). MODIS motivated the CCI switch:
it under-detects Ghana's forest (Evergreen Broadleaf ~6–11% of pixels), leaving `*_forestcrop` ~80%
NA at 5 km, and its stack still ends 2020 (`\*` above) despite `d_01` requesting through 2024. A 10 m
product (ESA WorldCover / Dynamic World) or Hansen tree-cover/loss would improve both the forest and
cropland masks — Hansen is downloaded (since 2026-07-07) but not yet used as either; see
`galamsey_tasklist.md`.

**ForTy would be valuable specifically for cocoa-land loss.** It's already used for forest-type
attribution generally — the mining-vs-ForTy demo (`explore_mining_vs_forest_type_app.js`) found
76.9% of Nkotumso's mining growth traced back to forest — but ForTy's classes don't isolate cocoa
as its own category, so a genuine **cocoa-specific loss** breakdown needs an additional layer
(Hansen + a cocoa-specific classifier, e.g. Kalischek et al.'s cocoa map) layered on top — identified
as a next step, not started.

---

## 8. Climate & precipitation

| Dataset | Source (GEE collection) | Coverage | Years | Resolution | Status | Use | Script |
|---------|-------------------------|----------|-------|-----------|--------|-----|--------|
| CHIRPS v2.0 rainfall (annual total) | `UCSB-CHG/CHIRPS/DAILY` → annual | Ghana | 1990–2025 | ~5.5 km | 🔄 | Potential | `0_data/d_01_download_gee.R` |
| ERA5-Land reanalysis (temp, PET) | `ECMWF/ERA5_LAND/MONTHLY` | Global | 1950–present | ~9 km | ⬜ | Potential | — |

**Use:** CHIRPS is downloaded but not yet wired in — intended for the climate-shock trigger (D3b,
blocked on extraction). Building a **SPEI/SPI drought index** (a candidate expansion trigger) needs
potential evapotranspiration, which CHIRPS lacks — hence **ERA5-Land** as a companion.

---

## 9. Administrative & spatial units

| Dataset | Source | Coverage | Years | Status | Use | Script |
|---------|--------|----------|-------|--------|-----|--------|
| Admin boundaries (admin0/1/2) | HDX `gha_admin{0,1,2}` | All Ghana | current | ✅ | Current | all scripts |
| 2010 Enumeration Areas | Ghana Statistical Service `GhanaEAs_2010` | All Ghana | 2010 | ✅ | Potential | (unit option in `b_01`) |

**Note:** admin2 has 260 districts (`adm2_name`); its `valid_on`/`valid_to` NA date columns crash
`sf_as_ee()` — always `select(adm2_name, geometry)` before GEE. EAs are the finest census unit, held
for future census/labour merges.

---

## 10. Economic & socioeconomic

Mostly not yet acquired — several motivating-facts subsections (D3–D6 in `a_04`) are blocked on these.
The lower block lists **candidate proxies** that are readily available (mostly via GEE / open portals)
and could substitute or complement the survey data.

| Dataset | Source | Coverage | Years | Status | Use | Script |
|---------|--------|----------|-------|--------|-----|--------|
| Gold price | Yahoo Finance `GC=F` futures (via `quantmod`) | Global | 2007–2017 used (API back to 2000) | ✅ | Current | `a_01`, `a_04` |
| COCOBOD cocoa yields | Ghana Cocoa Board (data request) | Districts (TBD) | TBD | 🔒 | Potential (D5c) | `a_04` |
| AReNA DHS-GIS Database (incl. MapSPAM crop production + DHS NDVI) | IFPRI, via Harvard Dataverse (`doi:10.7910/DVN/OQIPRW`) | 60 countries incl. Ghana — DHS clusters | compiled 2020 (varies by layer) | ⬜ | Potential — VI-proxy validation | — |
| MapSPAM 2020 v2.0 (crop production/yield/area) | IFPRI, via Harvard Dataverse (`doi:10.7910/DVN/SWPENT`) | Global (subset to Ghana) | 2020 | ⬜ | Potential — gridded agric.-productivity covariate | — |
| Ghana census microdata | GSS / IPUMS International | All Ghana | 2000, 2010, 2021 | 🔒 | Potential (D6a–b) | `a_04` |
| GLSS 7 (Living Standards Survey) | Ghana Statistical Service | All Ghana | 2016/17 | 🔒 | Potential (D6c) | `a_04` |
| Nighttime lights | VIIRS `NOAA/VIIRS/DNB/MONTHLY_V1`, DMSP | All Ghana | 1992–present | ⬜ | Potential | — |
| Gridded population | WorldPop | All Ghana | 2000–2020 | ⬜ | Potential | — |
| DHS (geocoded clusters) | USAID DHS Program | Ghana | 2003/08/14/22 | ⬜ | Potential | — |

**Note:** the global gold price is a proxy (no Ghana-specific series) but reasonable, since artisanal
miners sell at prices closely tied to the world spot price. Nightlights / WorldPop / DHS are
open, gridded proxies for local economic activity, population exposure, and wealth — cheaper
alternatives to the (blocked) survey microdata for the labour/welfare questions.

**AReNA DHS-GIS (IFPRI, 2020)** links DHS clusters to >1,000 geo-referenced layers on agricultural
production, agroecology, climate and infrastructure, split across 13 files. Two are directly relevant
here: **DHS_SPAM** (MapSPAM crop production / yield / harvested-area, ~10 km grid) and **DHS_NDVI** —
co-located at the same DHS clusters, so it offers an independent **agricultural-production benchmark
for the NDVI/EVI proxy** (§6): where SPAM crop output/yield is high, the VI signal should track it.
**Caveat:** the unit is the DHS *cluster* (point), not our hex grid, and Ghana clusters are jittered
(±2–5 km) for confidentiality — so it validates the VI↔production relationship at cluster resolution
rather than plugging into the hex panel directly. The underlying MapSPAM raster can be pulled
separately if a gridded crop-production covariate is wanted. Ties into the existing DHS row above.

**MapSPAM 2020 v2.0 Release 2 (IFPRI, `doi:10.7910/DVN/SWPENT`)** is that underlying raster, pulled
directly rather than through the DHS-cluster link above: a cross-entropy allocation of national/
sub-national crop statistics to a global **~5 arcmin (~10 km) grid**, for the **2020** crop year.
Files (CSV + GeoTIFF) give **harvested area, physical area, production, and yield**, each split by
farming technology (irrigated / rainfed high-input / rainfed low-input / rainfed subsistence, summed
to "all technologies"). Because it is a native grid (not jittered DHS points), it can plug directly
into the hex panel as a gridded agricultural-productivity covariate or outcome-validation layer for
the NDVI/EVI proxy (§6) — unlike the AReNA row above, no DHS-cluster matching or jitter caveat
applies. Single cross-section (2020 only), so it cannot itself provide a time series.

---

## 11. Contamination & water quality — candidates for validating the mechanism

The waterborne hypothesis (upstream mining → downstream degradation) is currently tested only
*indirectly* through NDVI. Direct contamination data would validate the channel itself.

| Dataset | Source | Coverage | Years | Status | Use | Script |
|---------|--------|----------|-------|--------|-----|--------|
| Sentinel-2 turbidity / NDTI | `COPERNICUS/S2_SR_HARMONIZED` | All Ghana | 2015– | 🔄 | Potential | `1_remote_sensing/explore_landsat_sentinel.R` |
| In-situ water quality (Hg, turbidity, TSS) | Water Resources Commission / field campaigns / literature | River gauging points | varies | 🔒 | Potential | — |

**Note:** in-situ mercury/turbidity measurements are the gold-standard validation but sparse and hard
to obtain; **remotely-sensed turbidity** (NDTI / MNDWI-gated water) is a scalable proxy already partly
computed in the RS index pipeline and could be extracted for downstream reaches.

---

## Key Data Caveats

Dataset-specific caveats (Barenblitt, Girard, land cover, the admin shapefile's crash-prone date
columns) now live in their own sections rather than duplicated here (2026-11-06 cleanup). What
remains is genuinely cross-cutting, or not resolved anywhere else yet.

- **MERIT Hydro's flow direction must not be reprojected** — trace the flow graph on its native
  EPSG:4326 grid; coverage is also still study-area + Ankobra tiles only, not all of Ghana.
- **HydroBASINS `basin_num` (the SE-clustering key) is only populated at 5 km and 2 km** — the 1 km
  grid falls back to an older 25 km centroid-block stand-in. Level-9 is also GEE's finest available
  level; some basins are hex-sized singletons (18 at 5 km), capping how far basin-level clustering
  alone can fix small-cluster SE inflation — see `event_study_design.md`.
- **"Gold mine" is a contextual inference, not a spectrometric identification.** The classifier
  identifies open-cast mining activity from bare exposed land and mine-pond spectral signatures; it
  cannot distinguish gold from other minerals. The attribution rests on the study area being the
  Birimian/Tarkwaian gold belts and on training pixels from known gold sites. Non-gold industrial
  mines at the periphery (manganese at Nsuta, bauxite at Awaso) could be captured in the industrial
  category.

**Our own RS mining product (§1) is not yet validated as a Barenblitt replacement.** Cumulative
mining through 2007 runs ~20× Barenblitt's own figure, narrowing to ~2× by 2016 — read as
left-censoring at the backdating window's floor, not a bug, but robustness checks (`ONSET_MIN` =
2000/2007 reruns, a method-fidelity check anchored to Barenblitt's own footprint) are submitted/
written but not yet landed. `b_04_rs_mining_panel.R`'s hex panel also only exists at 5 km, scoped to
the Barenblitt hull — not yet national or finer-resolution.

**Open decision: spatial aggregation unit.** Hexagons (5/2/1 km) and admin units (district/EA) are
both already built throughout Part 2 (`b_01_cross_section.R` writes both) — which one, or whether
both stay, for the final analysis hasn't been decided.
