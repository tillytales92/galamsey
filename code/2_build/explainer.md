# Build pipeline — explainer

Scripts in this folder convert raw and processed data into the analysis-ready datasets
consumed by `code/3_analysis/`. Each script writes its output to `data/processed/` and
reads only from `data/raw/`, `data/processed/`, or other scripts' outputs — never by
`source()`-ing a sibling script. Execution order is: **b_01 → b_02** (independent of b_03);
**b_03a → b_03b → b_03c → b_03d → b_03e** (sequential within the event-panel sub-pipeline).

---

## b_01_cross_section.R

**Purpose:** The single entry point for all spatial cross-sectional data. Builds mine
presence, mine area, and first-stage covariates for every spatial unit (districts and hex
grids at 1, 2, 5 km). All downstream scripts read the files it writes — run this first
whenever a new resolution is needed or a covariate definition changes.

**Prerequisite:** `d_03_waterways.R` must have run to write
`data/processed/waterways/waterways_natural.shp`.

**Inputs:**
- `data/raw/barenblitt/FullConversiontoMiningExtent2019.shp` — 2019 mine extent
- `data/raw/barenblitt/MiningConversion_2007-2017Vec.shp` — annual time series
- `data/raw/shapefiles/hdx_gh_admin/gha_admin{0,2}.shp` — admin boundaries
- `data/raw/goldsuitability/Gold_suitable_geology/gold_suitable_geology.shp` — Girard instrument
- `data/processed/waterways/waterways_natural.shp` — natural watercourses
- `data/processed/elevation/` — terrain rasters from `d_02_elevation.R` (optional; elev/slope left NA if absent)

**Outputs — `data/processed/`:**

| File | Contents |
|------|----------|
| `mining_extent_by_districts_2019.csv` | District × Artisanal / Industrial / Total mine area (ha), 2019 |
| `mining_timeseries_by_districts_2007_2017_{wide,long}.csv` | District × year mine area (ha) |
| `mining_extent_by_hex{N}km_2019.csv` | Hex × mine area (ha), 2019 |
| `mining_timeseries_by_hex{N}km_2007_2017_{wide,long}.csv` | Hex × year mine area (ha) |
| `hex_{N}km_crosssection.rds` | Named list — the primary cache for all hex-level work |

**Contents of `hex_{N}km_crosssection.rds`:**
- `hex_sf` — sf object: one row per hex, geometry + `hex_id`
- `hex_analysis` — tibble: per-hex covariates (see variables below)
- `lw` — spdep listw spatial weights object (queen contiguity)
- `nb` — spdep nb neighbour list
- `study_area` — sf polygon of the Barenblitt convex hull clipped to Ghana

**Variables in `hex_analysis`:**

| Variable | Description |
|----------|-------------|
| `hex_id` | Unique hex identifier, e.g. `hex_1234` |
| `area_ha` | Hex area in hectares |
| `mine_ha` | Total artisanal mine area (ha) within hex, 2007–2019 |
| `any_art` | Binary: 1 if any artisanal mining present |
| `gold_suit_share` | Share of hex area overlapping Girard gold-suitable geology (0–1) |
| `dist_river_km` | Distance to nearest natural waterway (km) |
| `elev_mean` | Mean elevation (m) — NA if terrain rasters absent |
| `slope_mean` | Mean slope (degrees) — NA if terrain rasters absent |
| `lag_gold_suit` | Spatial lag of `gold_suit_share` (queen weights) |
| `lag_dist_river` | Spatial lag of `dist_river_km` |

**Re-run when:** covariate definitions change, new resolution added, waterways updated.

---

## b_02_firststage_models.R

**Purpose:** Runs the MAUP-robustness model ladder (M1–M5) across hex resolutions 1, 2,
and 5 km. Each model is a logistic LPM of artisanal mine presence on geology and river
distance covariates, with increasing complexity. Results are cached so
`a_03_firststage_diagnostics.Rmd` only has to render — it never re-fits models.

**Inputs:**
- `hex_{N}km_crosssection.rds` — from b_01

**Model ladder:**

| Model | Specification |
|-------|--------------|
| M1 | `any_art ~ gold_suit_share + dist_river_km` |
| M2 | M1 + natural spline on river distance + spatial lags of both covariates |
| M3 | M2 + `elev_mean + slope_mean` |
| M4 | M3 + all four pairwise interactions |
| M5 | M4 + thin-plate spline on hex centroids (absorbs smooth spatial structure) |

**Output — `data/processed/`:**

| File | Contents |
|------|----------|
| `d03_maup_results.rds` | `list(fit_grid, sim_grid, int_grid, m5, meta)` — fit metrics (McFadden R², AUC, Brier, AIC), geography-weighted Moran's I null draws, and M5 spline diagnostics per resolution |

**Re-run when:** model specification changes, or new resolution added.

---

## The b_03 event-panel sub-pipeline

`b_03a` through `b_03e` together produce `event_panel_{N}km.rds` — the hex × year panel
used by `a_05_event_study.Rmd`. The pipeline is split into five independent-cache stages
so that slow components (raster extraction, spatial intersection) only need to re-run when
their specific inputs change. Each stage writes its own `.rds` to `data/processed/`; a new
R session can start from any stage by reading the prior stage's file from disk.

**Execution order and rebuild triggers:**

```
b_03a  →  b_03b  →  b_03c  →  b_03d  →  b_03e
  ↑           ↑         ↑          ↑          ↑
rasters   Barenblitt  MERIT    flow edges  anything (a-d)
change      change    updated   added/     changes
                               updated
```

---

## b_03a_vi_panel.R

**Purpose:** Peak-EVI / peak-NDVI zonal extraction per hex per year (Vashold et al. 2026
methodology; **rewritten 2026-07-06**, superseding the earlier "extract an already-annual
MODIS raster" version). Per (index, year, mask): reads the MODIS MOD13Q1 **16-day** composite
stack (not an annual-mean raster), masks each 16-day layer, reduces to hex level (zonal
**mean**) at each 16-day step, then takes **both the annual mean and the annual max ("peak")**
of that per-hex 16-day series — spatial reduction happens first, temporal reduction second.
Landsat VI is no longer used (dropped for now — high NA share; see `data_inventory.md` §6).
Compute-heavy; `RESOLUTIONS` is currently `c(5, 2)` — **1 km is deferred** (`terra::extract()`
over the 80,716-hex 1 km grid projected to 30+ hours even after a read/mask perf fix; run it
separately, ideally after switching to a faster zonal-stats engine such as `exactextractr`).

**Inputs:**
- `data/raw/modis_vi/modis_{ndvi,evi}_16day_ghana_{yr}.tif` — MODIS MOD13Q1 16-day composites, QA-masked server-side, 250 m (~23 bands/yr)
- `data/raw/land_cover/esa/cci_landcover_ghana_stack.tif` — ESA CCI land cover (yearly, 300 m), resampled once onto the MODIS VI grid
- `data/raw/barenblitt/` — both shapefiles (for the no-mine mask)
- `hex_{N}km_crosssection.rds` — for hex geometries and study extent

**Output — `data/processed/`:**

| File | Contents |
|------|----------|
| `hex_{N}km_vi_panel.rds` | tibble: hex × year × 24 VI columns + `urban_share` (25 columns) |

**Variables:** column naming is `{index}_modis[_{mask}]_{stat}` for `index` in {`ndvi`, `evi`},
`stat` in {`mean`, `max`}, `mask` in {overall (no suffix), `nominecrop`, `cropland`, `forest`,
`veg_narrow`, `veg_broad`} — 2 × 2 × 6 = 24 columns, values in the native VI range [-0.2, 1.0].

| Mask | Definition |
|------|-----------|
| `overall` | No mask — all classified pixels |
| `nominecrop` | Cumulative Barenblitt mine extent excluded (a mining mask, not ESA CCI) — captures spillover externalities, not direct land-clearing |
| `cropland` | ESA CCI classes 10, 11, 12, 20, 30 |
| `forest` | ESA CCI classes 50, 60, 61, 62, 70, 90 |
| `veg_narrow` | `cropland` ∪ `forest` classes ("productive green") |
| `veg_broad` | `veg_narrow` + mosaics/shrubland/grassland/sparse & flooded veg (excludes urban 190, bare 200/201/202, water 210, snow 220, lichen/moss 140) |

Plus `urban_share` — fraction of a hex's classified ESA CCI pixels that are urban (class 190)
that year; NA for VI years outside CCI's 1995–2022 coverage (not clamped, unlike the VI masks).

**Re-run when:** the 16-day rasters, the CCI stack, or the hex grids change.

---

## b_03b_own_mining.R

**Purpose:** Compute annual new mining area for each hex (own-hex) and for its queen-contiguity
neighbours (adjacency), from Barenblitt 2007–2017. The `st_intersection` loop is
moderately slow (~30–60 min at 1 km).

**Inputs:**
- `data/raw/barenblitt/MiningConversion_2007-2017Vec.shp`
- `hex_{N}km_crosssection.rds` — for hex geometries

**Output — `data/processed/`:**

| File | Contents |
|------|----------|
| `hex_{N}km_own_mining.rds` | tibble: all hexes × years 2007:2017, 0-filled |

**Variables:**

| Variable | Description |
|----------|-------------|
| `hex_id` | Hex identifier |
| `year` | Year (2007–2017) |
| `own_new_ha` | New artisanal mine area added within the hex in that year (ha) |
| `adj_new_ha` | Sum of `own_new_ha` across all queen-contiguous neighbour hexes |

Stock columns (`own_stock_ha`, `adj_stock_ha`) and onset year columns are computed in
b_03e to keep all cumsum logic in one place.

**Re-run when:** Barenblitt data updates, or adjacency definition changes (e.g. rook vs queen).

---

## b_03c_flow_graph.R

**Purpose:** Build directed hex-to-hex flow graphs from MERIT Hydro's D8 flow direction
raster. An edge A → B means water flows from hex A into hex B (A upstream, B downstream).
Only channel cells (upstream drainage area > `ROUTE_KM2`) source edges, so the
graph follows drainage divides rather than routing over ridges. Runs on the native 4326
MERIT grid — reprojecting D8 pointer codes corrupts routing.

Builds **two treatment definitions per resolution**, at two `ROUTE_KM2` channel-source
thresholds (`ROUTE_CONFIGS`, see `d_04_merit.R` Sec 11j sweep): **10 km²** (primary,
unsuffixed output files — reaches small tributaries, 5.5% of mined ha off-network) and
**50 km²** (alt/robustness, `_upa50`-suffixed files — trunk-stream only, closer to the OSM
natural-river network, 23% of mined ha off-network). Per-hex upstream-exposure ranking is
stable across a finer {2,5,10,20} km² sweep, so 50 km² is a genuinely coarser network, not
noise around 10.

**Inputs:**
- `data/raw/merit/merit_hydro_studyarea*.tif` — native 4326 MERIT Hydro GeoTIFF(s), bands: dir, upa, wth, elv. Downloaded by `d_04_merit.R` Secs 4–5.
- `hex_{N}km_crosssection.rds` — for hex geometries (only `hex_sf` is used; the file already exists on disk from prior b_01 runs and does not need to be re-run)

**Outputs — `data/processed/merit/`** (per resolution N × threshold suffix S in {`""` (primary, ROUTE_KM2=10), `"_upa50"` (alt, ROUTE_KM2=50)}):

| File | Contents |
|------|----------|
| `hex_flow_edges_{N}km{S}.csv` | Directed edge list: one row per hex pair |
| `hex_downstreamness_{N}km{S}.csv` | Per-hex downstreamness scalar |

**Variables in `hex_flow_edges_{N}km{S}.csv`:**

| Variable | Description |
|----------|-------------|
| `from_hex` | Upstream hex ID |
| `to_hex` | Downstream hex ID |
| `n_crossings` | Number of MERIT cells that cross this hex boundary |
| `flow_weight` | Net flow weight (sum of upa at crossing cells, dominant direction minus reverse) |

**Variables in `hex_downstreamness_{N}km{S}.csv`:**

| Variable | Description |
|----------|-------------|
| `hex_id` | Hex identifier |
| `mean_log_upa` | Mean log(upstream area) over channel cells within the hex — cardinal downstreamness scalar; rises monotonically downstream |
| `n_chan_cells` | Number of channel cells within the hex |

**Re-run when:** MERIT data updated, new hex resolution added, or `ROUTE_KM2` thresholds change.

---

## b_03d_flow_exposure.R

**Purpose:** Propagate own-hex mining upstream and downstream over the MERIT flow graph to
produce the event-study treatment variable. Also computes 1-hop (immediate neighbour) flow
aggregates and a lateral variable (queen-adjacent minus 1-hop up/down) for mechanism
separation. Runs once per `ROUTE_KM2` threshold config from b_03c (`ROUTE_SUFFIXES <- c("",
"_upa50")`) — the primary (10 km²) and alt (50 km²) flow graphs each get their own exposure
cache. If flow edges are absent for a given resolution/threshold, writes an NA stub so b_03e
can always assemble.

**Inputs:**
- `hex_{N}km_own_mining.rds` — from b_03b
- `data/processed/merit/hex_flow_edges_{N}km{S}.csv` — from b_03c, S in {`""`, `"_upa50"`} (optional; NA stub written if absent)
- `hex_{N}km_crosssection.rds` — for `hex_sf` geometries (used for `poly2nb` queen adjacency in lateral computation)

**Output — `data/processed/`** (per threshold suffix S in {`""`, `"_upa50"`}):

| File | Contents |
|------|----------|
| `hex_{N}km_flow_exposure{S}.rds` | tibble: flow-graph hexes × years 2007:2017 (or NA stub for all columns) |

**Variables:**

| Variable | Description |
|----------|-------------|
| `hex_id` | Hex identifier |
| `year` | Year (2007–2017) |
| `up_new_ha` | New mine ha summed across **all** hydrologically upstream hexes (full catchment) |
| `down_new_ha` | New mine ha summed across all downstream hexes (full catchment) |
| `nearest_up_new_ha` | New mine ha in the hex's **immediate 1-hop upstream** neighbours only (no recursion) |
| `nearest_down_new_ha` | New mine ha in the hex's **immediate 1-hop downstream** neighbours only |
| `lateral_new_ha` | New mine ha in queen-contiguous neighbours that are **neither** 1-hop upstream **nor** 1-hop downstream — pure land-use spillover, no water link |
| `nearest_up_onset_year` | Earliest own-onset year among 1-hop upstream neighbours (time-invariant per hex) |
| `nearest_down_onset_year` | Earliest own-onset year among 1-hop downstream neighbours (time-invariant per hex) |

Stock columns (`up_stock_ha`, `down_stock_ha`, `nearest_up_stock_ha`, `nearest_down_stock_ha`,
`lateral_stock_ha`) and onset year columns (`up_onset_year`, `down_onset_year`,
`lateral_onset_year`) are computed in b_03e via cumsum over the full panel spine.

**Re-run when:** flow edges added or updated for a given resolution, or lateral/1-hop definition changes.

---

## b_03e_assemble_eventpanel.R

**Purpose:** Join all four upstream caches into the final hex × year event-study panel.
Expands to the full year range (union of VI years and mining years), computes all stock and
onset columns via cumsum, and adds Callaway–Sant'Anna event-time bookkeeping columns.
Runs in seconds — re-run freely whenever any upstream cache or model specification changes.

**Inputs:**
- `hex_{N}km_vi_panel.rds` — from b_03a (25 VI/urban columns)
- `hex_{N}km_own_mining.rds` — from b_03b
- `hex_{N}km_flow_exposure.rds` — from b_03d, ROUTE_KM2=10 (primary)
- `hex_{N}km_flow_exposure_upa50.rds` — from b_03d, ROUTE_KM2=50 (alt robustness; optional — joined with an `_upa50` suffix on every column if present)
- `hex_{N}km_crosssection.rds` — covariates only (`gold_suit_share`, `dist_river_km`, `elev_mean`, `slope_mean`)
- `data/processed/hydrobasins/hex_basin_{N}km.csv` — from `d_07_hydrobasins.R` (optional; per-hex HydroBASINS level-9 sub-basin id — the SE-clustering key that replaces the 25 km centroid-block stand-in)

**Outputs — `data/processed/`:**

| File | Contents |
|------|----------|
| `event_panel_{N}km.csv` | Full panel as flat CSV |
| `event_panel_{N}km.rds` | `list(panel, hex_sf, vi_cols, vi_years, mining_years)` |

**Complete variable inventory of `event_panel_{N}km`:**

*Identifiers:*

| Variable | Description |
|----------|-------------|
| `hex_id` | Hex identifier string, e.g. `hex_1234` |
| `hex_num` | Integer part of hex_id |
| `year` | Calendar year (1995–2025) |

*Vegetation indices (24 columns + `urban_share` = 25 — see b_03a for full definitions):*
`{ndvi,evi}_modis_{mean,max}`, `{ndvi,evi}_modis_nominecrop_{mean,max}`,
`{ndvi,evi}_modis_cropland_{mean,max}`, `{ndvi,evi}_modis_forest_{mean,max}`,
`{ndvi,evi}_modis_veg_narrow_{mean,max}`, `{ndvi,evi}_modis_veg_broad_{mean,max}`,
`urban_share`

*Own-hex mining:*

| Variable | Description |
|----------|-------------|
| `own_new_ha` | New mine area added in this hex × year (ha); 0 outside 2007–2017 |
| `own_stock_ha` | Cumulative mine area (ha); frozen at 2017 level after 2017 |
| `own_onset_year` | First year own_new_ha > 0; NA if never mined |
| `ever_mined` | Logical: TRUE if own_onset_year is not NA |
| `event_time_own` | `year − own_onset_year`; NA for never-treated hexes |
| `first_treat_own` | `own_onset_year`, or 0 for never-treated (C&S convention) |

*Adjacency (queen-contiguity neighbours):*

| Variable | Description |
|----------|-------------|
| `adj_new_ha` | Sum of `own_new_ha` across queen neighbours in this year |
| `adj_stock_ha` | Cumulative adjacency exposure (ha) |
| `adj_onset_year` | First year any queen neighbour was mined |
| `first_treat_adj` | `adj_onset_year`, or 0 (C&S convention) |

*Upstream — full catchment (hydrological):*

| Variable | Description |
|----------|-------------|
| `up_new_ha` | New mine ha summed across all flow-reachable upstream hexes; NA if no flow graph |
| `up_stock_ha` | Cumulative upstream mining exposure (ha) |
| `up_onset_year` | First year any upstream hex was mined |

*Upstream — 1-hop only (present when flow graph available):*

| Variable | Description |
|----------|-------------|
| `nearest_up_new_ha` | New mine ha in immediate upstream neighbour hexes only (no full-catchment recursion) |
| `nearest_up_stock_ha` | Cumulative sum of `nearest_up_new_ha` |
| `nearest_up_onset_year` | Earliest own-onset year among 1-hop upstream neighbours (time-invariant) |

*Downstream — full catchment (hydrological):*

| Variable | Description |
|----------|-------------|
| `down_new_ha` | New mine ha summed across all downstream hexes |
| `down_stock_ha` | Cumulative downstream mining (ha) |
| `down_onset_year` | First year any downstream hex was mined |

*Downstream — 1-hop only (present when flow graph available):*

| Variable | Description |
|----------|-------------|
| `nearest_down_new_ha` | New mine ha in immediate downstream neighbour hexes only |
| `nearest_down_stock_ha` | Cumulative sum of `nearest_down_new_ha` |
| `nearest_down_onset_year` | Earliest own-onset year among 1-hop downstream neighbours (time-invariant) |

*Lateral — queen neighbours minus 1-hop up/down (present when flow graph available):*

| Variable | Description |
|----------|-------------|
| `lateral_new_ha` | New mine ha in queen-adjacent neighbours that are neither 1-hop upstream nor downstream — no water connection; land-use spillover / dust / labour |
| `lateral_stock_ha` | Cumulative sum of `lateral_new_ha` |
| `lateral_onset_year` | First year `lateral_new_ha > 0` |

*ROUTE_KM2=50 robustness (present only when `hex_{N}km_flow_exposure_upa50.rds` exists):*

Mirrors all 15 up/down/lateral columns above (`up_new_ha` … `lateral_onset_year`), each with
an `_upa50` suffix (e.g. `up_new_ha_upa50`), built from the coarser 50 km² channel-source
threshold flow graph instead of the primary 10 km² one.

*Sub-basin SE-clustering keys (from `d_07_hydrobasins.R`; present only when
`hydrobasins/hex_basin_{N}km.csv` exists):*

| Variable | Description |
|----------|-------------|
| `basin_id` | HydroBASINS level-9 sub-basin ID (`HYBAS_ID`) |
| `main_basin` | Coarser HydroBASINS main-basin ID (`MAIN_BAS`) — fallback cut with fewer, larger clusters |
| `pfaf_id` | Pfafstetter code |
| `basin_num` | Compact `1..K` factor of `basin_id`, for the `did`/`polars` SE-clustering backend |

*Time-invariant covariates (from b_01 crosssection):*

| Variable | Description |
|----------|-------------|
| `elev_mean` | Mean elevation (m) |
| `slope_mean` | Mean slope (degrees) |
| `gold_suit_share` | Share of hex overlapping gold-suitable geology (0–1) |
| `dist_river_km` | Distance to nearest natural waterway (km) |

**Re-run when:** any upstream cache changes, C&S specification changes (e.g. different
`first_treat` encoding), or the hydrobasins cache is updated.
