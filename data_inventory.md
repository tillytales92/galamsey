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

**Status (availability):** ✅ available · 🔄 in progress (downloading/building) · ⬜ not yet acquired.
**Use:** **Current** = wired into the analysis now · **Potential** = candidate, planned, or acquired
but not yet used.

*See also: `galamsey_tasklist.md` (task status); `notes/barenblitt_dataset_documentation.md` and
`notes/girard_gold_suitability_documentation.md` (extended dataset notes);
`code/0_data/gold_deposits.md` (hydro-geomorphic instrument plan);
`code/0_data/rivers_exploration.Rmd` (river-definition exploration).*

---

## 1. Mining extent & activity — the outcome / labels

The dependent variable of the whole project: where and when land was converted to mining. Barenblitt
is the current source; the two remote-sensing detectors below are being developed to **replace** it
(the `mine_data` swap point in Part 2/3 scripts).

| Dataset | Source | Coverage | Years | Status | Use | Script |
|---------|--------|----------|-------|--------|-----|--------|
| Barenblitt — annual mining extent | Barenblitt et al. (2021), RF on Landsat | SW Ghana | 2007–2017 | ✅ | Current | `2_build/b_01_cross_section.R` |
| Barenblitt — full mining extent 2019 | Barenblitt et al. (2021) | SW Ghana | 2019 (cross-section) | ✅ | Current | `2_build/b_01_cross_section.R` |
| RS embedding mine-probability panel | Google AlphaEarth embeddings + RF (this project) | SW Ghana study area | 2017–2024 (annual) | 🔄 | Potential (will replace Barenblitt) | `1_remote_sensing/rs05_embedding_classifier.R` |
| Africa Mining Watch — early detections | MLP detector (GeoJSON boxes + rectpolys) | SW Ghana (pilot bbox, not national) | 2025 snapshot | ✅ | Potential | `0_data/d_08_africa_mining_watch.R` |
| Maus et al. — global mining polygons | Maus et al. (2022), global mining-footprint delineation | Ghana subset (577 of 44,929 global polygons) | static snapshot | ✅ | Potential | `0_data/d_09_mining_mausetal.R` |

**Why several:** Barenblitt is the validated benchmark but is **positive-labels-only** at 75.6%
producer accuracy and covers SW Ghana only. `rs05` (AlphaEarth embeddings) is the intended production
replacement, giving an annual 2017–2024 panel; Africa Mining Watch and Maus et al. are alternative
ML/global detection layers held for validation/ensemble comparison against Barenblitt and rs05 (EDA
done for both 2026-07-07; full accuracy comparison still open — see `galamsey_tasklist.md`).

**Barenblitt notes.**
- Polygons are **clumps of contiguous classified pixels**, not exact outlines of individual galamsey
  ponds — shape and area reflect the pixel resolution of the underlying classification. Classification
  code is on GitHub ([abarenblitt/GhanaArtisanalMining](https://github.com/abarenblitt/GhanaArtisanalMining))
  as JavaScript runnable in Google Earth Engine.
- **Year assignment (time series):** the conversion year is the year of steepest NDVI decline (max
  first derivative of a 3-year centred rolling NDVI average), **not** the year of first mining onset.
  Annual composites use Jan–Jun (dry season) only, so mining starting in H2 may register the next year.
- The **2019 extent** is the RF-classified mine mask with **no year field** and is the **only**
  Barenblitt source with a `mine_type` field (artisanal vs industrial); the time series does not.

---

## 2. Formal mine licences & ownership

Legal/industrial mining context — used to relate galamsey to formal concessions.

| Dataset | Source | Coverage | Years | Status | Use | Script |
|---------|--------|----------|-------|--------|-----|--------|
| Ghana Mining Repository — licences (KML) | Minerals Commission repository | All Ghana | 2025 snapshot | ✅ | Potential | — (inspect raw files) |
| Ghana Mining Repository — applications (KML) | Minerals Commission repository | All Ghana | 2025 snapshot | ✅ | Potential | — (inspect raw files) |
| Ghana Mining Repository — licence & owner reports (Excel) | Minerals Commission repository | All Ghana | 2025 snapshot | ✅ | Potential | — (inspect raw files) |
| **Historical mine-licence register** | Minerals Commission / PMMC archive | All Ghana | licence issue dates (historical) | ⬜ | Potential | — |

**Note:** the Excel reports include licence **grant dates**, so this is not purely a cross-section,
but temporal coverage is uneven. A **historical licence register with issue dates** is what the
"does galamsey accelerate after the first formal mine appears?" event study (D3c in `a_04`) needs —
currently blocked because the 2025 snapshot has no establishment-year field.

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
See §"Key Data Caveats" on the 1:10M scale limitation.

---

## 4. Rivers & hydrology

Two representations of the river network, plus a sub-basin partition, are in use; the remaining
candidates add real-water observation and finer river topology. (See `code/0_data/rivers_exploration.Rmd`
for the full river-definition comparison.)

| Dataset | Source | Coverage | Years | Resolution | Status | Use | Script |
|---------|--------|----------|-------|-----------|--------|-----|--------|
| OSM waterways (lines) | OpenStreetMap / Geofabrik | Ghana | current snapshot | vector | ✅ | Current | `0_data/d_03_waterways.R` |
| MERIT Hydro (`dir`/`upa`/`wth`/`elv`) | Yamazaki et al. (2019) | Study area + Ankobra tiles | static | ~90 m | ✅ | Current | `0_data/d_04_merit.R` |
| JRC Global Surface Water | `JRC/GSW1_4/GlobalSurfaceWater` (GEE) | Global | 1984–2021 | 30 m | ⬜ | Potential | — |
| HydroBASINS (level-9 sub-basins) | WWF/HydroSHEDS `WWF/HydroSHEDS/v1/Basins/hybas_9` (GEE) | Study area | static | ~sub-basin polygons | ✅ | Current | `0_data/d_01_download_gee.R` (download) → `0_data/d_07_hydrobasins.R` (hex assignment) |
| HydroSHEDS / HydroRIVERS | WWF / Lehner et al. | Global | static | 15 arc-sec | ⬜ | Potential | — |

**Why several:** **OSM** gives real, named rivers (distance-to-river, display) but is gap-prone.
**MERIT Hydro** is a modelled, gap-free channel network that reaches small tributaries and provides
the **D8 flow direction** for the upstream→downstream hex graph (must be traced on its native 4326
grid). **JRC** would validate MERIT channels and flag actual standing water incl. mining ponds.
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
| MERIT-DEM | Yamazaki et al. (2017) | Study area + Ankobra tiles | static | ~90 m | ✅ | Potential | `0_data/d_04_merit.R` |

**Why two:** the `elevatr` DEM supplies the per-hex `elev_mean` / `slope_mean` covariates (in use).
MERIT-DEM (morphologically intact, unlike MERIT Hydro's flow-adjusted `elv`) is the base for the
placer/valley-bottom indices (HAND, MRVBF, SPI/STI) in `d_06`/`d_04` — currently **disabled**
(`if(FALSE)`), hence Potential.

---

## 6. Vegetation indices — agricultural-productivity outcome

NDVI/EVI as the downstream outcome for the waterborne-degradation event study and productivity
descriptives.

| Dataset | Source (GEE collection) | Coverage | Years | Resolution | Status | Use | Script |
|---------|-------------------------|----------|-------|-----------|--------|-----|--------|
| Landsat annual NDVI | `LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_NDVI` | All Ghana | 1995–2025 | 30 m | 🔄 | Potential — **not used for now** (high NA share) | `0_data/d_01_download_gee.R` |
| Landsat annual EVI | `LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_EVI` | All Ghana | 1995–2025 | 30 m | 🔄 | Potential — **not used for now** (high NA share) | `0_data/d_01_download_gee.R` |
| MODIS VI (NDVI + EVI) | `MODIS/061/MOD13Q1` (QA-filtered 16-day series; annual mean derived locally) | All Ghana | 2000–2025 | 250 m | ✅ | Current | `0_data/d_01_download_gee.R` |

**Why both sensors:** **Landsat** is finer (30 m, back to 1995) but ~30–36% NA/year (cloud);
**MODIS** (`MOD13Q1`, 250 m, from 2000) is coarser than Landsat but QA-filtered to ~16% NA, so it
is far more complete year-to-year. The event study is built on MODIS peak (max) NDVI/EVI, masked by
ESA CCI land cover: `a_05_event_study_1.Rmd` (Q0, own-hex) heads with `evi_modis_veg_narrow_max`,
`a_05_event_study_2.Rmd` (Q1, upstream→downstream) with `ndvi_modis_cropland_max`; the full
NDVI/EVI × {veg-narrow, no-mine-crop, cropland} outcome grid is looped as robustness in both (and in
`_3.Rmd`, Q2).
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
| MODIS land cover (IGBP `LC_Type1`) | `MODIS/061/MCD12Q1` | All Ghana | **2001–2020**\* | 500 m | 🔄 | Current | `0_data/d_01_download_gee.R` |
| ESA WorldCover | `ESA/WorldCover/v200` (Sentinel-1/2) | Global | 2020, 2021 | 10 m | ⬜ | Potential | — |
| Google Dynamic World | `GOOGLE/DYNAMICWORLD/V1` (Sentinel-2) | Global | 2015–present | 10 m | ⬜ | Potential | — |
| Hansen Global Forest Change | `UMD/hansen/global_forest_change_2025_v1_13` | All Ghana (national, single static image) | 2000–2025 | 30 m | 🔄 | Potential | `0_data/d_01_download_gee.R` |

**ESA CCI (300 m, 1995–2022) is now the preferred land-cover source** and the mask for the peak-EVI
outcome: its finer grid and more granular legend separate evergreen (50) / deciduous (60/62) tree
cover and rainfed cropland (10) from mosaics (30/40), which is what the forest / cropland outcome
masks need. It covers the full VI history (from 1995) and does not stop at 2020 the way the MODIS
stack does. MODIS MCD12Q1 (IGBP) is retained as the coarser comparison. Classification diagnostics
for both (national + Ankobra maps, composition, trends, 5 km-hex mask-coverage, interactive leaflet)
are in `d_05_ndvi.R`.

**There is no separate "Landsat land cover".** The `*_landsat_forestcrop` panel columns do **not**
use a Landsat land-cover product — they apply a MODIS/CCI land-cover layer resampled to the Landsat
30 m VI grid (`b_03a_vi_panel.R`). Two reasons the MODIS product in particular is weak, motivating
the CCI switch and the finer products above as **future replacements**:

1. **MODIS 500 m IGBP under-detects Ghana's forest** — it labels most of SW Ghana as "savanna", so
   class 2 (Evergreen Broadleaf Forest) is only ~6–11% of land pixels and rarely fires, leaving the
   `*_forestcrop` VI columns ~80% NA at 5 km (see `d_05_ndvi.R` forestcrop diagnostics).
2. **The MODIS stack currently ends 2020** (`\*` above): 2021–2024 layers are missing from
   `modis_lc_ghana_stack.tif` even though `d_01` requests `LCOVER_YEARS = 2001:2024` — re-download
   + re-stack in `d_01` Sec 9 to recover them.

A 10 m product (ESA WorldCover / Dynamic World) or Hansen tree-cover/loss would give a far better
"forest around mines" mask and a cropland mask for the agricultural channel. **Hansen download
activated 2026-07-07** (`d_01` Sec 6c, national extent since it is a single static image, not a
per-year time series) but not yet used as a land-cover mask or event-study outcome — see
`galamsey_tasklist.md`'s "Add Hansen Global Forest Change as an event-study outcome" item.

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

## 9. Raw satellite imagery — RS Part 1 inputs

The source imagery/embeddings feeding the mine detectors in §1.

| Dataset | Source (GEE collection) | Coverage | Years | Resolution | Status | Use | Script |
|---------|-------------------------|----------|-------|-----------|--------|-----|--------|
| Landsat 5/7/8/9 surface reflectance | `LANDSAT/LC0{8,9}/C02/T1_L2` (+ archive) | All Ghana | 1995–2025 | 30 m | 🔄 | Current (Part 1) | `1_remote_sensing/rs01_landsat_gee.R` |
| Sentinel-2 surface reflectance | `COPERNICUS/S2_SR_HARMONIZED` | All Ghana | 2015–2025 | 10 m | 🔄 | Current (Part 1) | `1_remote_sensing/rs02_sentinel2_gee.R` |
| AlphaEarth satellite embeddings | `GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL` | All Ghana | 2017–2024 | 10 m, 64-band | 🔄 | Current (Part 1) | `1_remote_sensing/rs05_embedding_classifier.R` |

**Why several:** Landsat gives the long historical archive; Sentinel-2 the finest recent imagery
(from mid-2015, full revisit from mid-2017); the AlphaEarth **embeddings** are the feature space for
the production RF mine classifier (§1).

---

## 10. Administrative & spatial units

| Dataset | Source | Coverage | Years | Status | Use | Script |
|---------|--------|----------|-------|--------|-----|--------|
| Admin boundaries (admin0/1/2) | HDX `gha_admin{0,1,2}` | All Ghana | current | ✅ | Current | all scripts |
| 2010 Enumeration Areas | Ghana Statistical Service `GhanaEAs_2010` | All Ghana | 2010 | ✅ | Potential | (unit option in `b_01`) |

**Note:** admin2 has 260 districts (`adm2_name`); its `valid_on`/`valid_to` NA date columns crash
`sf_as_ee()` — always `select(adm2_name, geometry)` before GEE. EAs are the finest census unit, held
for future census/labour merges.

---

## 11. Economic & socioeconomic

Mostly not yet acquired — several motivating-facts subsections (D3–D6 in `a_04`) are blocked on these.
The lower block lists **candidate proxies** that are readily available (mostly via GEE / open portals)
and could substitute or complement the survey data.

| Dataset | Source | Coverage | Years | Status | Use | Script |
|---------|--------|----------|-------|--------|-----|--------|
| Gold price | Yahoo Finance `GC=F` futures (via `quantmod`) | Global | 2007–2017 used (API back to 2000) | ✅ | Current | `a_01`, `a_04` |
| COCOBOD cocoa yields | Ghana Cocoa Board (data request) | Districts (TBD) | TBD | ⬜ | Potential (D5c) | `a_04` |
| AReNA DHS-GIS Database (incl. MapSPAM crop production + DHS NDVI) | IFPRI, via Harvard Dataverse (`doi:10.7910/DVN/OQIPRW`) | 60 countries incl. Ghana — DHS clusters | compiled 2020 (varies by layer) | ⬜ | Potential — VI-proxy validation | — |
| MapSPAM 2020 v2.0 (crop production/yield/area) | IFPRI, via Harvard Dataverse (`doi:10.7910/DVN/SWPENT`) | Global (subset to Ghana) | 2020 | ⬜ | Potential — gridded agric.-productivity covariate | — |
| Ghana census microdata | GSS / IPUMS International | All Ghana | 2000, 2010, 2021 | ⬜ | Potential (D6a–b) | `a_04` |
| GLSS 7 (Living Standards Survey) | Ghana Statistical Service | All Ghana | 2016/17 | ⬜ | Potential (D6c) | `a_04` |
| Nighttime lights | VIIRS `NOAA/VIIRS/DNB/MONTHLY_V1`, DMSP | All Ghana | 1992–present | ⬜ | Potential | — |
| Gridded population | WorldPop | All Ghana | 2000–2020 | ⬜ | Potential | — |
| Relative Wealth Index | Meta / Data for Good | Sub-national | 2021 | ⬜ | Potential | — |
| DHS (geocoded clusters) | USAID DHS Program | Ghana | 2003/08/14/22 | ⬜ | Potential | — |

**Note:** the global gold price is a proxy (no Ghana-specific series) but reasonable, since artisanal
miners sell at prices closely tied to the world spot price. Nightlights / WorldPop / RWI / DHS are
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

## 12. Contamination & water quality — candidates for validating the mechanism

The waterborne hypothesis (upstream mining → downstream degradation) is currently tested only
*indirectly* through NDVI. Direct contamination data would validate the channel itself.

| Dataset | Source | Coverage | Years | Status | Use | Script |
|---------|--------|----------|-------|--------|-----|--------|
| In-situ water quality (Hg, turbidity, TSS) | Water Resources Commission / field campaigns / literature | River gauging points | varies | ⬜ | Potential | — |
| Sentinel-2 turbidity / NDTI | `COPERNICUS/S2_SR_HARMONIZED` | All Ghana | 2015– | 🔄 | Potential | `rs01`/`rs02` |

**Note:** in-situ mercury/turbidity measurements are the gold-standard validation but sparse and hard
to obtain; **remotely-sensed turbidity** (NDTI / MNDWI-gated water) is a scalable proxy already partly
computed in the RS index pipeline and could be extracted for downstream reaches.

---

## Key Data Caveats

- **Barenblitt coverage is SW Ghana only** (~104,730 km²). Absent Barenblitt data in northern
  districts means "not surveyed", not "no mining". Add a caption note; never use northern districts as
  true zeroes.
- **Barenblitt producer accuracy is 75.6%** — ~1 in 4 real mines were missed. Positive labels only;
  absence is not a clean negative.
- **Barenblitt time series carries no `mine_type`** — the artisanal/industrial split is only possible
  via the 2019 cross-section.
- **Girard geology is 1:10M scale** — no meaningful signal below ~5 km; omit / down-weight
  `gold_suit_share` at 1–2 km grids.
- **MODIS land cover under-detects forest and ends 2020.** IGBP class 2 (Evergreen Broadleaf Forest)
  is rare in the MODIS classification of SW Ghana (~6–11% of land pixels, shrinking), so `*_forestcrop`
  VI columns are ~80% NA at 5 km; and the stack currently spans only 2001–2020 (2021–2024 missing).
  A finer land-cover product (ESA WorldCover / Dynamic World / Hansen) would fix both.
- **MERIT flow direction must not be reprojected** — trace the flow graph on the native EPSG:4326 grid.
- **MERIT coverage** currently spans the study-area + Ankobra tiles, not all of Ghana; ~5.5% of mined
  ha sits off the channel network at `ROUTE_KM2 = 10`.
- **HydroBASINS `basin_num` (SE-clustering key) is only populated at 5 km and 2 km** — the 1 km grid
  falls back to the older 25 km centroid-block stand-in since `d_07_hydrobasins.R` hasn't been run
  there. HydroBASINS level-9 is also GEE's finest available level (not level 12); some basins are
  hex-sized singletons (18 at 5 km), which caps how far finer basin-level clustering alone can fix
  small-cluster SE inflation — see `event_study_design.md`'s SE-clustering section.
- **Landsat VI is cloud-gappy** (~30–36% NA/year) vs MODIS (~16%); prefer MODIS as the headline
  outcome, Landsat as finer-grained robustness.
- **Admin shapefile** `valid_on`/`valid_to` NA date columns crash `sf_as_ee()` — always
  `select(adm2_name, geometry)` before GEE.
- **"Gold mine" is a contextual inference, not a spectrometric identification.** The classifier
  identifies open-cast mining activity from bare exposed land and mine-pond spectral signatures; it
  cannot distinguish gold from other minerals. The attribution rests on the study area being the
  Birimian/Tarkwaian gold belts and on training pixels from known gold sites. Non-gold industrial
  mines at the periphery (manganese at Nsuta, bauxite at Awaso) could be captured in the industrial
  category.
