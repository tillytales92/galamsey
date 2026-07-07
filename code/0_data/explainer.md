# Data acquisition & covariate builders — explainer

Scripts in this folder (`d_NN_*`) **acquire raw data** and **build the exogenous covariate
layers** that the rest of the pipeline consumes. They either download from an external source
(Google Earth Engine, Geofabrik/OSM, AWS terrain tiles) or process a downloaded raster/shapefile
into a derived layer written to `data/raw/` or `data/processed/`. Nothing here `source()`s a
sibling; scripts coordinate only through files on disk.

Most GEE scripts must be run **interactively** — `ee_Authenticate()` / `ee_Initialize(drive = TRUE)`
open browser windows and cannot run unattended. See the repo `CLAUDE.md` for the `RETICULATE_PYTHON`
/ `EARTHENGINE_PYTHON` environment setup.

**Rough dependency order:** `d_01` (VI/land-cover/precip rasters, plus the HydroBASINS table
export) and `d_02` (DEM) are the base downloads; `d_03` builds the waterways layer that `b_01`
needs; `d_04` builds the MERIT flow graph that the event-panel pipeline needs; `d_07` turns the
`d_01`-exported HydroBASINS layer into the per-hex sub-basin clustering key that `b_03e` needs;
`d_05` and `d_06` are diagnostic / instrument-EDA scripts that read what the others produced.
`download_land_cover_ghana.ipynb` is a standalone Python/Jupyter download (Digital Earth Africa
STAC, not GEE) for ESA CCI land cover, which `d_01` Sec 9 then stacks alongside the GEE rasters.
There is no strict global ordering beyond "download before you process".

---

## d_01_download_gee.R

**Purpose:** The single GEE download hub for all environmental **raster time series**. Submits
Earth Engine export tasks to Google Drive, downloads the completed exports, and stacks the annual
GeoTIFFs into multi-layer rasters for fast loading. Pure download + stack — no per-hex extraction
or derived indices here. (MERIT-DEM / MERIT Hydro downloads live in `d_04_merit.R` instead, because
they are tightly coupled to their processing.)

**Datasets downloaded (all clipped to the Ghana bounding box, EPSG:4326):**

| Product | Source collection | Res. | Years | Output |
|---------|-------------------|------|-------|--------|
| Landsat NDVI | `LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_NDVI` | 30 m | 1995–2025 | `data/raw/landsat_vi/landsat_ndvi_ghana_{year}.tif` + `landsat_ndvi_ghana_stack.tif` |
| Landsat EVI | `LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_EVI` | 30 m | 1995–2025 | `data/raw/landsat_vi/landsat_evi_ghana_{year}.tif` + `landsat_evi_ghana_stack.tif` |
| MODIS VI | `MODIS/061/MOD13Q1` (NDVI+EVI, QA-filtered 16-day series → local annual mean) | 250 m | 2000–2025 | `data/raw/modis_vi/modis_{ndvi,evi}_16day_ghana_{year}.tif` → `modis_{ndvi,evi}_ghana_stack.tif` |
| MODIS land cover | `MODIS/061/MCD12Q1` (IGBP `LC_Type1`) | 500 m | 2001–2024 | `data/raw/land_cover/modis_lc_ghana_stack.tif` |
| HydroBASINS | `WWF/HydroSHEDS/v1/Basins/hybas_9` (level-9 sub-basins, table export, not a raster) | — | static | `data/raw/hydrobasins/hydrobasins_hybas9_studyarea.geojson` |
| CHIRPS precip | `UCSB-CHG/CHIRPS/DAILY` summed to annual mm | ~5.5 km | 1990–2025 | `data/raw/chirps/chirps_ghana_{year}.tif` |
| ESA CCI land cover | Defourny et al. 2024 UN-LCCS, via Digital Earth Africa STAC — **not GEE**, downloaded separately by `download_land_cover_ghana.ipynb` | 300 m | 1995–2022 | `data/raw/land_cover/esa/cci_landcover_ghana_{year}.tif` → stacked by `d_01` Sec 9 |

**Workflow (numbered sections in the script):** Secs 1–7 submit all export tasks (5/5b/5c =
Landsat + MODIS vegetation indices, 6 = MODIS land cover, 6b = HydroBASINS table export, 7 =
CHIRPS); Sec 7b is an optional blocking monitor; Sec 8 downloads completed exports from Drive
(uncomment once the EE Tasks tab shows COMPLETED); Sec 9 stacks the downloaded TIFs into
multi-layer GeoTIFFs — including the separately-downloaded ESA CCI yearly rasters (from
`download_land_cover_ghana.ipynb`) into `cci_landcover_ghana_stack.tif`, alongside the GEE-sourced
stacks. MODIS VI (Sec 5c) exports the QA-masked **16-day** MOD13Q1 composites (not a GEE-side
annual mean); the annual mean stack is derived locally in Sec 9 for backward compatibility, while
the 16-day files themselves feed the peak-EVI pipeline (`b_03a`, masked by the ESA CCI stack).

**Re-run when:** the VI/land-cover/precip window needs extending, or a collection is updated.

---

## d_02_elevation.R

**Purpose:** Download the Ghana DEM and derive a slope raster — the **basic terrain layer only**.
(The hydro-geomorphic indices — HAND, MRVBF, flow direction — live in `d_06_gold_deposits.R`; the
MERIT-based flow graph lives in `d_04_merit.R`.) Per-hex extraction of `elev_mean` / `slope_mean`
is **not** done here — that happens in `b_01_cross_section.R`, which reads these rasters.

**Source:** `elevatr` → AWS Terrain Tiles (Mapzen/Tilezen), zoom `Z = 11` (~76 m at Ghana's
latitude).

**Key design choices:**
- The DEM is downloaded against a `BUFFER_KM = 10` km-buffered country outline so that hexes
  straddling the coast / Côte d'Ivoire border still have full DEM coverage.
- Sub-sea "elevation" (offshore bathymetry in the terrain tiles) is clamped to 0.
- Slope is computed **after** reprojecting to UTM30N so horizontal and vertical units agree.
- Filenames carry `Z` and the buffer, so changing either forces a clean re-download.

**Outputs:**

| File | Contents |
|------|----------|
| `data/raw/elevation/ghana_dem_z{Z}_buf{BUFFER_KM}km.tif` | Raw DEM (EPSG:4326) |
| `data/processed/elevation/ghana_elevation_utm30n_buf{BUFFER_KM}km.tif` | DEM (EPSG:32630) |
| `data/processed/elevation/ghana_slope_utm30n_buf{BUFFER_KM}km.tif` | Slope (degrees, EPSG:32630) |
| `outputs/figures/maps/{elevation,slope}_utm30n.png` | Diagnostic maps |

**Re-run when:** the buffer / zoom changes, or the DEM is needed at a new coverage.

---

## d_03_waterways.R

**Purpose:** Three jobs in one script. **(1) Download** all `waterway=*` line features for Ghana
from the Geofabrik OSM extract; **(2) Build** the processed natural-watercourses-only shapefile
that the pipeline reads (`b_01`, `a_01`, `a_02` all read this file — no inline waterway filtering
anywhere else); **(3) EDA** assessing which waterway types matter for alluvial gold and whether the
choice of river measure (OSM all-types vs OSM natural-only vs MERIT-modelled channels) moves the
per-hex distance-to-river regressor or the first-stage fit.

**"Natural" watercourses** = `river, stream, brook, wadi, tidal_channel, stream_pool, flowline`
(vs artificial canals/drains/ditches, which cannot host alluvial gold).

**Outputs:**

| File | Contents |
|------|----------|
| `data/raw/shapefiles/osm_extracts/waterways_ghana_YYYY-MM-DD.gpkg` | Raw OSM extract (timestamped; only re-fetched if `FORCE_DOWNLOAD` or absent) |
| `data/processed/waterways/waterways_natural.shp` | **Natural watercourses only — the pipeline input** |
| `outputs/figures/waterways/*` | Type counts, classification map, distance/fit comparison CSVs + PNGs |
| `outputs/figures/maps/waterways_galamsey_map.png` | Main rivers over 5 km artisanal-mining hexes |

**Prerequisite for full EDA:** Sections 5–8 read the `hex_5km_crosssection.rds` cache and the MERIT
Ankobra raster; they skip gracefully if those are absent. Section 1's `waterways_natural.shp` write
has no prerequisites.

**Re-run when:** OSM data needs refreshing, or the natural-type list changes.

---

## d_04_merit.R

**Purpose:** The MERIT hydro-geomorphic workhorse. Exports MERIT-DEM + MERIT Hydro from GEE for the
full Barenblitt study area, reprojects locally, and — most importantly for the analysis pipeline —
builds the **directed hex-to-hex D8 flow graph** on the canonical 5 km grid (Sec 11). An edge
`hex_A → hex_B` means water flows from A into B (A upstream, B downstream). This is what replaces
`a_02`'s crude "lower northing = downstream" proxy and feeds the event-study treatment definitions.

**Two MERIT products (do not confuse):** MERIT-DEM (error-reduced 90 m elevation — use for slope /
MRVBF) and MERIT Hydro (pre-conditioned routing: `dir` D8 flow direction, `upa` upstream drainage
area, `wth` river width, `elv` hydro-adjusted elevation — use for flow direction / streams / HAND).

**Critical design decisions (confirmed during the earlier Ankobra test run):**
- **Native-grid routing.** The flow graph is traced on the **raw EPSG:4326** `dir`/`upa` bands, never
  the UTM working file — reprojecting a categorical D8 pointer relocates cells and corrupts routing.
  Sec 11e validates this by checking cell-level acyclicity.
- **Channel-only edges.** Only cells with `upa > ROUTE_KM2 = 10 km²` source edges, so the graph
  follows drainage channels (which respect divides) rather than routing over ridges. `ROUTE_KM2` is
  decoupled from the 50 km² "river" label; Sec 11j sweeps it over {2,5,10,20} and reports exposure
  robustness.
- **Net dominant direction.** Bidirectional edge pairs (D8 noise near braids/boundaries) are netted
  to the dominant direction; residual hex-graph cycles are broken via a feedback-arc set to yield a
  usable DAG.

**Section map:** Secs 1–5 env/auth/export/fetch; Sec 6 reproject to UTM30N; Sec 7 flow direction +
stream network; **Secs 8–10 (HAND / MRVBF / SPI-STI / Strahler) are DISABLED** (`if(FALSE)`) —
heavy at study-area scale, kept as reference implementations; Sec 11 the hex flow graph + upstream
galamsey-exposure builder.

**Key outputs — `data/processed/merit/`:**

| File | Contents |
|------|----------|
| `hex_flow_edges_5km.csv` | Directed hex-to-hex edge list (`from_hex`, `to_hex`, `n_crossings`, `flow_weight`) — the flow graph, consumed by `b_03c`/`b_03d` |
| `hex_downstreamness_5km.csv` | Per-hex `mean_log_upa` (cardinal downstreamness scalar) + channel-cell count |
| `hex_upstream_exposure_5km.csv` | Per-hex raw + distance-decayed upstream galamsey exposure (event-study treatment prototype) |
| `hex_flow_threshold_sweep_5km.csv` | `ROUTE_KM2` sensitivity sweep (edges, off-network mined ha, attributed ha) |

Plus diagnostic PNGs and interactive leaflet HTML in `outputs/figures/merit/`.

**Background:** read `code/0_data/gold_deposits.md` first for the full conceptual framework.

**Re-run when:** MERIT data updates, or a new hex resolution is added (extend Sec 11 beyond 5 km).

---

## d_05_ndvi.R

**Purpose:** Diagnostic script (no processed outputs) to **understand the vegetation / land-cover
products before use** — missingness patterns and land-cover composition, for BOTH MODIS MCD12Q1
and ESA CCI. Answers "how much of each NDVI/EVI product is NA, by year and by pixel?", "what does
land cover look like Ghana-wide vs in the Ankobra basin, and how has it changed?", and "how much
does switching the outcome mask from MODIS to the finer ESA CCI grid reduce hex-year NA rates?"

**Reads:** the Landsat/MODIS VI stacks, the MODIS MCD12Q1 land-cover stack, and the ESA CCI
land-cover stack (`cci_landcover_ghana_stack.tif`) — all built by `d_01`.

**Produces (interactive plots, not saved by default):**
- `% NA` by year for all four VI products; per-pixel NA-frequency maps.
- IGBP (MODIS MCD12Q1) land-cover categorical maps (Ghana 2010 + most recent year), 2019
  class-composition bars, cropland vs forest time trends.
- The same land-cover analysis restricted to a hydrologically-defined Ankobra basin polygon (OSM
  "Ankobra" river → convex hull → 20 km buffer).
- A parallel ESA CCI block (added 2026-07-06) mirroring the MODIS diagnostics above — national +
  Ankobra UN-LCCS classification maps, composition bars, and time trends — plus a mask-coverage
  diagnostic comparing candidate CCI forest/cropland mask definitions' hex-year NA rates on the
  5 km grid (the choice that feeds `b_03a`'s outcome masks), and an interactive leaflet map of the
  Ankobra basin toggling the 2005 vs. 2020 CCI classification (CartoDB/satellite basemaps,
  click-to-query class code), saved to `outputs/figures/ndvi/cci_ankobra_leaflet_2005_2020.html`.

**Re-run when:** new VI/land-cover downloads land and you want to re-check coverage before building
the VI panel (`b_03a`).

---

## d_06_gold_deposits.R

**Purpose:** Two-part gold-potential characterisation.

**Part 1 — Alluvial (placer) gold potential (Secs A–E).** A WhiteboxTools/SAGA hydro-geomorphic
chain on the `d_02` DEM: breach depressions → D8 flow pointer + accumulation → stream network +
Strahler order → HAND (height above nearest drainage) → MRVBF (valley-bottom flatness). These flag
where eroded gold settles (floodplains, terraces, confluences). Outputs to `data/processed/hydro/`,
filenames carrying the buffer. Secs J–L are TODO skeletons (SPI/STI placer indicators, MERIT Hydro
alternative, per-hex extraction).

**Part 2 — Girard gold-suitability instrument EDA (Secs F–I).** Compares the two Girard layers —
Layer 1 (binary gold-suitable geology polygon) and Layer 2 (0.5° PRIO-Grid share) — overlays
Barenblitt 2019 artisanal mining as an **instrument-validation check** (almost all artisanal mining
falls within gold-suitable bedrock), and aggregates to district level.

**Key outputs:**

| File | Contents |
|------|----------|
| `data/processed/hydro/ghana_{breached,d8pointer,d8accum,streams,strahler,hand,mrvbf}_*.tif` | Hydro-geomorphic layers |
| `data/processed/gold_suitability_by_district.csv` | Per-district gold-suitable-geology share |
| `outputs/figures/maps/gold_suitability_*.png` | Layer 1 vs Layer 2 comparison, mining-validation overlay, district maps |

**Engines:** WhiteboxTools (`whitebox::install_whitebox()`) and SAGA GIS (for MRVBF only).
**Prerequisite:** `d_02_elevation.R` must have built the reprojected DEM.

**Companion doc:** `code/0_data/gold_deposits.md` — the conceptual plan (what alluvial-gold
landforms are, why each matters, how the tools produce each layer).

---

## d_07_hydrobasins.R

**Purpose:** Turns the HydroBASINS level-9 sub-basin export (from `d_01` Sec 6b) into a per-hex
sub-basin ID — the SE-clustering key that replaces the 25 km centroid-block stand-in used in
`a_05`'s event study. Owns the HydroBASINS dataset end-to-end (parallel to how `d_03` owns OSM and
`d_04` owns MERIT): no GEE/auth needed here, it's an offline join against the already-downloaded
geojson. Loops over `RESOLUTIONS <- c(5, 2, 1)` km like the sibling `b_03c`/`b_03d` scripts; each
resolution only needs its own `hex_{N}km_crosssection.rds` (from `b_01`), not the VI panel.

**Part 1 — Diagnostics (Secs 2, 2b, 2c, 2d):** assigns each hex to a basin by centroid
(`st_within`; centroids falling outside every polygon — coastal edge — get the nearest basin by
`st_nearest_feature`), then reports cluster-count diagnostics (number of distinct level-9 basins =
number of SE clusters, hexes-per-basin distribution, singleton-basin share, a <30-cluster
warning), a categorical map of the basin partition with the Barenblitt galamsey extent and
natural rivers overlaid, and a hexes-per-basin histogram.

**Part 2 — Build artifact (Sec 2b write):** writes the per-hex lookup consumed downstream.

**Inputs:**
- `data/raw/hydrobasins/hydrobasins_hybas9_studyarea.geojson` — from `d_01` Sec 6b export
- `data/raw/barenblitt/FullConversiontoMiningExtent2019.shp` — optional, map overlay only
- `data/processed/waterways/waterways_natural.shp` — optional, map overlay only
- `hex_{N}km_crosssection.rds` — for hex geometries, per resolution

**Outputs — `data/processed/hydrobasins/`:**

| File | Contents |
|------|----------|
| `hex_basin_{N}km.csv` | `hex_id, HYBAS_ID, PFAF_ID, MAIN_BAS, basin_num` — `basin_num` is a compact `1..K` integer factor of `HYBAS_ID` (the `did`/`polars` SE-clustering backend can't take the large-integer `HYBAS_ID` or a string cluster column directly); `MAIN_BAS` is kept for an optional coarser robustness clustering |
| `outputs/figures/hydrobasins/basin_partition_map_{N}km.png` | Basin partition map |
| `outputs/figures/hydrobasins/hexes_per_basin_hist_{N}km.png` | Hexes-per-basin histogram |
| `outputs/figures/hydrobasins/basin_summary_{N}km.csv` | Per-basin hex counts + `SUB_AREA` |

**Downstream wiring:** `b_03e_assemble_eventpanel.R` merges `hex_basin_{N}km.csv` into
`event_panel_{N}km.rds`; `a_05_event_study.Rmd` replaces the `block_id` placeholder with
`basin_num`.

**Re-run when:** HydroBASINS export updates, or a new hex resolution is added.
