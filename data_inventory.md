---
output:
  html_document: default
  pdf_document: default
---
# Data Inventory — Ghana Mining Project

Datasets are grouped **by purpose**. Where several datasets serve the same role (e.g. rivers from
OSM *and* MERIT Hydro; vegetation from Landsat *and* MODIS), they are listed together with a note on
why more than one source is kept and how they trade off.

**Status legend:** ✅ available · 🔄 in progress · ⬜ not yet acquired.

*See also: `galamsey_tasklist.md` (task status); `notes/barenblitt_dataset_documentation.md` and
`notes/girard_gold_suitability_documentation.md` (extended dataset notes);
`code/0_data/gold_deposits.md` (hydro-geomorphic instrument plan).*

---

## 1. Mining extent & activity — the outcome / labels

The dependent variable of the whole project: where and when land was converted to mining. Barenblitt
is the current source; the two remote-sensing detectors below are being developed to **replace** it
(the `mine_data` swap point in Part 2/3 scripts).

| Dataset | Source | Coverage | Years | Status | Script |
|---------|--------|----------|-------|--------|--------|
| Barenblitt — annual mining extent | Barenblitt et al. (2021), RF on Landsat | SW Ghana | 2007–2017 | ✅ | `2_build/b_01_cross_section.R` |
| Barenblitt — full mining extent 2019 | Barenblitt et al. (2021) | SW Ghana | 2019 (cross-section) | ✅ | `2_build/b_01_cross_section.R` |
| RS embedding mine-probability panel | Google AlphaEarth embeddings + RF (this project) | SW Ghana study area | 2017–2024 (annual) | 🔄 | `1_remote_sensing/rs05_embedding_classifier.R` |
| Africa Mining Watch — early detections | MLP detector (GeoJSON boxes + rectpolys) | Ghana | 2025 snapshot | ✅ exploratory | — (inspect raw GeoJSON directly) |

**Why several:** Barenblitt is the validated benchmark but is **positive-labels-only** at 75.6%
producer accuracy and covers SW Ghana only. `rs05` (AlphaEarth embeddings) is the intended
production replacement, giving an annual 2017–2024 panel; Africa Mining Watch is an alternative
early ML detection layer held for comparison.

**Barenblitt notes.**
- Polygons are **clumps of contiguous classified pixels**, not exact outlines of individual galamsey
  ponds — shape and area reflect the pixel resolution of the underlying classification. Classification
  code is on GitHub ([abarenblitt/GhanaArtisanalMining](https://github.com/abarenblitt/GhanaArtisanalMining))
  as JavaScript runnable in Google Earth Engine.
- **Year assignment (time series):** the conversion year is the year of steepest NDVI decline (max
  first derivative of a 3-year centred rolling NDVI average), **not** the year of first mining onset
  — there can be a lag between actual onset and peak vegetation signal. Annual composites use Jan–Jun
  (dry season) only, so mining starting in H2 may register in the following year's composite.
- The **2019 extent** is the RF-classified mine mask with **no year field** — a single cross-section
  of all pixels ever classified as mines by the end of the observation period. It is the **only**
  Barenblitt source with a `mine_type` field (artisanal vs industrial); the time series does not carry
  it.

---

## 2. Formal mine licences & ownership

Legal/industrial mining context — used to relate galamsey to formal concessions.

| Dataset | Source | Coverage | Years | Status | Script |
|---------|--------|----------|-------|--------|--------|
| Ghana Mining Repository — licences (KML) | Minerals Commission repository | All Ghana | 2025 snapshot | ✅ | — (inspect raw files) |
| Ghana Mining Repository — applications (KML) | Minerals Commission repository | All Ghana | 2025 snapshot | ✅ | — (inspect raw files) |
| Ghana Mining Repository — licence & owner reports (Excel) | Minerals Commission repository | All Ghana | 2025 snapshot | ✅ | — (inspect raw files) |

**Note:** the Excel reports include licence **grant dates**, so this is not purely a cross-section;
however temporal coverage appears uneven across years and needs investigation before use as a panel.
There is no historical licence register, so a first-formal-mine event study (D3c) is currently
blocked.

---

## 3. Gold geology & suitability — the exogenous instrument (Girard)

The exclusion-restriction candidate: exogenous variation in where gold *can* be mined.

| Dataset | Source | Coverage | Years | Resolution | Status | Script |
|---------|--------|----------|-------|-----------|--------|--------|
| Gold-suitable geology — polygon (Layer 1) | Girard et al. (2022) | Africa-wide | static | 1:10M vector | ✅ | `0_data/d_06_gold_deposits.R` |
| Gold-suitable geology — raster | Girard et al. (2022) | Africa-wide | static | raster | ✅ | `0_data/d_06_gold_deposits.R` |
| Gold suitability × PRIO-Grid (Layer 2) | Girard et al. (2022) + PRIO-GRID | Africa-wide | static | 0.5° (~55 km) | ✅ | `0_data/d_06_gold_deposits.R` |

**Why two layers:** Layer 1 is the raw binary geology polygon (fine but categorical); Layer 2 is the
PRIO-Grid *share* of each 0.5° cell that is gold-suitable (a continuous instrument at a coarse grain).
See §"Key Data Caveats" on the 1:10M scale limitation.

---

## 4. Rivers & hydrology

Two representations of the river network, kept for different jobs.

| Dataset | Source | Coverage | Years | Resolution | Status | Script |
|---------|--------|----------|-------|-----------|--------|--------|
| OSM waterways (lines) | OpenStreetMap / Geofabrik | Ghana | current snapshot | vector | ✅ | `0_data/d_03_waterways.R` |
| MERIT Hydro (`dir`/`upa`/`wth`/`elv`) | Yamazaki et al. (2019) | Study area + Ankobra tiles | static | ~90 m | ✅ | `0_data/d_04_merit.R` |

**Why two:** **OSM** gives real, named rivers (used for distance-to-river and display) but is
gap-prone and misses small tributaries. **MERIT Hydro** is a modelled, gap-free channel network that
reaches the small tributaries galamsey targets, and — critically — provides the **D8 flow direction**
used to build the directed upstream→downstream hex flow graph (the event-study treatment). MERIT
routing must be traced on its native EPSG:4326 grid. `d_03_waterways.R` §5–7 documents the OSM-vs-MERIT
comparison.

---

## 5. Terrain & elevation

| Dataset | Source | Coverage | Years | Resolution | Status | Script |
|---------|--------|----------|-------|-----------|--------|--------|
| DEM + slope | AWS Terrain Tiles via `elevatr` | Ghana + 10 km buffer | static | z11 (~76 m) | ✅ | `0_data/d_02_elevation.R` |
| MERIT-DEM | Yamazaki et al. (2017) | Study area + Ankobra tiles | static | ~90 m | ✅ | `0_data/d_04_merit.R` |

**Why two:** the `elevatr` DEM supplies per-hex `elev_mean` / `slope_mean` covariates (§`b_01`).
MERIT-DEM (morphologically intact, unlike MERIT Hydro's flow-adjusted `elv`) is the base for the
placer/valley-bottom indices (HAND, MRVBF, SPI/STI) in `d_06_gold_deposits.R` / `d_04_merit.R`.

---

## 6. Vegetation indices — agricultural-productivity outcome

NDVI/EVI as the downstream outcome for the waterborne-degradation event study and the productivity
descriptives.

| Dataset | Source (GEE collection) | Coverage | Years | Resolution | Status | Script |
|---------|-------------------------|----------|-------|-----------|--------|--------|
| Landsat annual NDVI | `LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_NDVI` | All Ghana | 1995–2025 | 250 m | 🔄 | `0_data/d_01_download_gee.R` |
| Landsat annual EVI | `LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_EVI` | All Ghana | 1995–2025 | 250 m | 🔄 | `0_data/d_01_download_gee.R` |
| MODIS VI (NDVI + EVI) | `MODIS/061/MOD13A2` (QA-filtered annual mean) | All Ghana | 2000–2025 | 1 km | 🔄 | `0_data/d_01_download_gee.R` |

**Why both sensors:** **Landsat** is finer (250 m, back to 1995) but has heavy cloud-driven
missingness (~30–36% NA/year in the panel); **MODIS** is coarser (1 km, from 2000) but far more
complete (~16% NA) and gives ~87 pixels per 5 km hex vs a handful at finer grids. The event study
uses `ndvi_modis` as the headline outcome; Landsat is the finer-grained robustness source.
Missingness diagnostics: `0_data/d_05_ndvi.R`.

---

## 7. Land cover

| Dataset | Source (GEE collection) | Coverage | Years | Resolution | Status | Script |
|---------|-------------------------|----------|-------|-----------|--------|--------|
| MODIS land cover (IGBP `LC_Type1`) | `MODIS/061/MCD12Q1` | All Ghana | 2001–2024 | 500 m | 🔄 | `0_data/d_01_download_gee.R` |

**Use:** cropland / forest masking of NDVI (to isolate the agricultural channel) and the
`*_forestcrop` / `*_nominecrop` VI columns in the event panel.

---

## 8. Climate & precipitation

| Dataset | Source (GEE collection) | Coverage | Years | Resolution | Status | Script |
|---------|-------------------------|----------|-------|-----------|--------|--------|
| CHIRPS v2.0 rainfall (annual total) | `UCSB-CHG/CHIRPS/DAILY` summed to annual | Ghana | 1990–2025 | ~5.5 km | 🔄 | `0_data/d_01_download_gee.R` |

**Use:** intended for the climate-shock trigger analysis (D3b, currently blocked pending extraction);
SPEI/SPI drought indices can be derived from it.

---

## 9. Raw satellite imagery — RS Part 1 inputs

The source imagery/embeddings feeding the mine detectors in §1.

| Dataset | Source (GEE collection) | Coverage | Years | Resolution | Status | Script |
|---------|-------------------------|----------|-------|-----------|--------|--------|
| Landsat 5/7/8/9 surface reflectance | `LANDSAT/LC0{8,9}/C02/T1_L2` (+ archive) | All Ghana | 1995–2025 | 30 m | 🔄 | `1_remote_sensing/rs01_landsat_gee.R` |
| Sentinel-2 surface reflectance | `COPERNICUS/S2_SR_HARMONIZED` | All Ghana | 2015–2025 | 10 m | 🔄 | `1_remote_sensing/rs02_sentinel2_gee.R` |
| AlphaEarth satellite embeddings | `GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL` | All Ghana | 2017–2024 | 10 m, 64-band | 🔄 | `1_remote_sensing/rs05_embedding_classifier.R` |

**Why several:** Landsat gives the long historical archive; Sentinel-2 gives the finest recent
imagery (from mid-2015); the AlphaEarth **embeddings** are the feature space for the production RF
mine classifier (§1). Sentinel-2 has a full 5-day revisit only from mid-2017.

---

## 10. Administrative & spatial units

| Dataset | Source | Coverage | Years | Status | Script |
|---------|--------|----------|-------|--------|--------|
| Admin boundaries (admin0/1/2) | HDX `gha_admin{0,1,2}` | All Ghana | current | ✅ | all scripts |
| 2010 Enumeration Areas | Ghana Statistical Service `GhanaEAs_2010` | All Ghana | 2010 | ✅ | (unit option in `b_01`) |

**Note:** admin2 has 260 districts (`adm2_name`). The admin shapefile's `valid_on`/`valid_to` NA date
columns crash `sf_as_ee()` — always `select(adm2_name, geometry)` before GEE. EAs are the finest
census unit, held for future census/labour merges.

---

## 11. Economic & socioeconomic

Mostly not yet acquired — several motivating-facts subsections (D3–D6 in `a_04`) are blocked on these.

| Dataset | Source | Coverage | Years | Status | Script |
|---------|--------|----------|-------|--------|--------|
| Gold price | Yahoo Finance `GC=F` front-month futures (via `quantmod`) | Global | 2007–2017 used (API back to 2000) | ✅ (API) | `a_01_incidence_maps.R`, `a_04_motivating_facts.R` |
| COCOBOD cocoa yields | Ghana Cocoa Board (data request) | Districts (TBD) | TBD | ⬜ | `a_04_motivating_facts.R` |
| Ghana census microdata | GSS / IPUMS International | All Ghana | 2000, 2010, 2021 | ⬜ | `a_04_motivating_facts.R` |
| GLSS 7 (Living Standards Survey) | Ghana Statistical Service | All Ghana | 2016/17 | ⬜ | `a_04_motivating_facts.R` |

**Note:** the global gold price is only a proxy (no Ghana-specific series exists) but is reasonable
because artisanal miners sell at prices closely tied to the world spot price.

---

## Key Data Caveats

- **Barenblitt coverage is SW Ghana only** (~104,730 km²). Absent Barenblitt data in northern
  districts means "not surveyed", not "no mining". Always add a caption note; never use northern
  districts as true zeroes.
- **Barenblitt producer accuracy is 75.6%** — about 1 in 4 real mines were missed. Use as positive
  labels only; do not treat absence as clean negatives.
- **Barenblitt time series carries no `mine_type`** (`MiningConversion_2007-2017Vec.shp` has only the
  year, `classifica`). The artisanal/industrial split is only possible via the 2019 cross-section
  (`FullConversiontoMiningExtent2019.shp`).
- **Girard geology is 1:10M scale** — no meaningful spatial signal below ~5 km. At the 5 km hex scale
  most cells are either fully inside or fully outside the gold-suitable polygon; omit / down-weight
  `gold_suit_share` at 1–2 km grids.
- **MERIT flow direction must not be reprojected.** Reprojecting the categorical D8 `dir` band
  corrupts routing — trace the flow graph on the native EPSG:4326 grid.
- **MERIT coverage** currently spans the study-area + Ankobra tiles, not all of Ghana; ~5.5% of mined
  ha sits off the channel network at `ROUTE_KM2 = 10` (unattributed upstream).
- **Landsat VI is cloud-gappy** (~30–36% NA/year) vs MODIS (~16%); prefer MODIS as the headline
  outcome, Landsat as finer-grained robustness.
- **Admin shapefile** has `valid_on`/`valid_to` date columns with NAs that crash `sf_as_ee()`. Always
  `select(adm2_name, geometry)` before passing to GEE functions.
- **"Gold mine" is a contextual inference, not a spectrometric identification.** The Random Forest
  classifier identifies open-cast mining activity from bare exposed land and mine-pond spectral
  signatures — it cannot distinguish gold mining from other mineral extraction. The gold-mine
  attribution rests on (a) the study area being the Birimian/Tarkwaian gold belts where commercial
  extraction of other minerals is rare, and (b) training pixels being manually selected from known
  galamsey and industrial gold-mine sites. The artisanal/industrial separation uses elevation change
  and texture, not mineral type. Non-gold industrial mines at the study-area periphery (manganese at
  Nsuta, bauxite at Awaso) could in principle be captured in the industrial category.
