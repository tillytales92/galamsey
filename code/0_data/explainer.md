# Data acquisition & covariate builders — explainer

Scripts in this folder (`d_NN_*`) **acquire raw data** and **build the exogenous covariate
layers** that the rest of the pipeline consumes. They either download from an external source
(Google Earth Engine, Geofabrik/OSM, AWS terrain tiles) or process a downloaded raster/shapefile
into a derived layer written to `data/raw/` or `data/processed/`. Nothing here `source()`s a
sibling; scripts coordinate only through files on disk.

Most GEE scripts must be run **interactively** — `ee_Authenticate()` / `ee_Initialize(drive = TRUE)`
open browser windows and cannot run unattended. See the repo `CLAUDE.md` for the `RETICULATE_PYTHON`
/ `EARTHENGINE_PYTHON` environment setup.

**Rough dependency order:** `d_01` (VI/land-cover/precip rasters) and `d_02` (DEM) are the base
downloads; `d_03` builds the waterways layer that `b_01` needs; `d_04` builds the MERIT flow graph
that the event-panel pipeline needs; `d_05` and `d_06` are diagnostic / instrument-EDA scripts that
read what the others produced. There is no strict global ordering beyond "download before you
process".

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
| Landsat NDVI | `LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_NDVI` | 250 m | 1995–2025 | `data/raw/ndvi/ndvi_ghana_{year}.tif` + `ndvi_ghana_stack.tif` |
| Landsat EVI | `LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_EVI` | 250 m | 1995–2025 | `data/raw/evi/evi_ghana_{year}.tif` + `evi_ghana_stack.tif` |
| MODIS VI | `MODIS/061/MOD13A2` (NDVI+EVI, QA-filtered annual mean) | 1 km | 2000–2025 | `data/raw/modis_vi/modis_{ndvi,evi}_ghana_stack.tif` |
| MODIS land cover | `MODIS/061/MCD12Q1` (IGBP `LC_Type1`) | 500 m | 2001–2024 | `data/raw/land_cover/land_cover_ghana_stack.tif` |
| CHIRPS precip | `UCSB-CHG/CHIRPS/DAILY` summed to annual mm | ~5.5 km | 1990–2025 | `data/raw/chirps/chirps_ghana_{year}.tif` |

**Workflow (numbered sections in the script):** Secs 1–6 submit all export tasks; Sec 6b is an
optional blocking monitor; Sec 7 downloads completed exports from Drive (uncomment once the EE
Tasks tab shows COMPLETED); Sec 8 stacks the downloaded TIFs into multi-layer GeoTIFFs.

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

**Purpose:** Diagnostic script (no processed outputs) to **understand the three vegetation / land-
cover products before use** — missingness patterns and land-cover composition. Answers "how much of
each NDVI/EVI product is NA, by year and by pixel?" and "what does MODIS land cover look like
Ghana-wide vs in the Ankobra basin, and how has it changed?"

**Reads:** the Landsat/MODIS VI stacks and the land-cover stack built by `d_01`.

**Produces (interactive plots, not saved by default):**
- `% NA` by year for all four VI products; per-pixel NA-frequency maps.
- IGBP land-cover categorical maps (Ghana 2010 + most recent year), 2019 class-composition bars,
  cropland vs forest time trends.
- The same land-cover analysis restricted to a hydrologically-defined Ankobra basin polygon (OSM
  "Ankobra" river → convex hull → 20 km buffer).

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
