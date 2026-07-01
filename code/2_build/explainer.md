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
rasters   Barenblitt  MERIT    flow edges  anything
change      change    updated   added/     changes
                               updated
```

---

## b_03a_vi_panel.R

**Purpose:** Extract annual vegetation index zonal means per hex per year from Landsat and
MODIS raster stacks. The slowest step (~4–5 hours at 1 km); only re-run if rasters change.

**Inputs:**
- `data/raw/ndvi/ndvi_ghana_stack.tif` — Landsat NDVI annual composites (1995–2025, 250 m)
- `data/raw/evi/evi_ghana_stack.tif` — Landsat EVI
- `data/raw/modis_vi/modis_ndvi_ghana_stack.tif` — MODIS MOD13A2 NDVI (2000–2025, 1 km)
- `data/raw/modis_vi/modis_evi_ghana_stack.tif` — MODIS EVI
- `data/raw/land_cover/land_cover_ghana_stack.tif` — MODIS MCD12Q1 IGBP land cover (2001–2024)
- `data/raw/barenblitt/` — both shapefiles (for the no-mine mask)
- `hex_{N}km_crosssection.rds` — for hex geometries and study extent

**Output — `data/processed/`:**

| File | Contents |
|------|----------|
| `hex_{N}km_vi_panel.rds` | tibble: hex × year × 12 VI columns (see below) |

**Variables (all are zonal means over hex pixels):**

| Variable | Source | Mask |
|----------|--------|------|
| `ndvi_landsat` | Landsat 250 m | All pixels |
| `evi_landsat` | Landsat 250 m | All pixels |
| `ndvi_modis` | MODIS 1 km | All pixels |
| `evi_modis` | MODIS 1 km | All pixels |
| `ndvi_landsat_forestcrop` | Landsat 250 m | IGBP class 2 (Evergreen Broadleaf Forest) only; NA outside 2001–2024 |
| `evi_landsat_forestcrop` | Landsat 250 m | IGBP class 2 |
| `ndvi_modis_forestcrop` | MODIS 1 km | IGBP class 2 |
| `evi_modis_forestcrop` | MODIS 1 km | IGBP class 2 |
| `ndvi_landsat_nominecrop` | Landsat 250 m | Cumulative Barenblitt footprint excluded — captures spillover externalities, not direct land-clearing |
| `evi_landsat_nominecrop` | Landsat 250 m | No-mine mask |
| `ndvi_modis_nominecrop` | MODIS 1 km | No-mine mask |
| `evi_modis_nominecrop` | MODIS 1 km | No-mine mask |

**Re-run when:** new GEE raster downloads land.

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
Only channel cells (upstream drainage area > `ROUTE_KM2 = 10 km²`) source edges, so the
graph follows drainage divides rather than routing over ridges. Runs on the native 4326
MERIT grid — reprojecting D8 pointer codes corrupts routing.

**Inputs:**
- `data/raw/merit/merit_hydro_studyarea*.tif` — native 4326 MERIT Hydro GeoTIFF(s), bands: dir, upa, wth, elv. Downloaded by `d_04_merit.R` Secs 4–5.
- `hex_{N}km_crosssection.rds` — for hex geometries (only `hex_sf` is used; the file already exists on disk from prior b_01 runs and does not need to be re-run)

**Outputs — `data/processed/merit/`:**

| File | Contents |
|------|----------|
| `hex_flow_edges_{N}km.csv` | Directed edge list: one row per hex pair |
| `hex_downstreamness_{N}km.csv` | Per-hex downstreamness scalar |

**Variables in `hex_flow_edges_{N}km.csv`:**

| Variable | Description |
|----------|-------------|
| `from_hex` | Upstream hex ID |
| `to_hex` | Downstream hex ID |
| `n_crossings` | Number of MERIT cells that cross this hex boundary |
| `flow_weight` | Net flow weight (sum of upa at crossing cells, dominant direction minus reverse) |

**Variables in `hex_downstreamness_{N}km.csv`:**

| Variable | Description |
|----------|-------------|
| `hex_id` | Hex identifier |
| `mean_log_upa` | Mean log(upstream area) over channel cells within the hex — cardinal downstreamness scalar; rises monotonically downstream |
| `n_chan_cells` | Number of channel cells within the hex |

**Re-run when:** MERIT data updated, or new hex resolution added.

---

## b_03d_flow_exposure.R

**Purpose:** Propagate own-hex mining upstream and downstream over the MERIT flow graph to
produce the event-study treatment variable. Also computes 1-hop (immediate neighbour) flow
aggregates and a lateral variable (queen-adjacent minus 1-hop up/down) for mechanism
separation. If flow edges are absent for a given resolution (1 km and 2 km until b_03c has
been run), writes an NA stub so b_03e can always assemble.

**Inputs:**
- `hex_{N}km_own_mining.rds` — from b_03b
- `data/processed/merit/hex_flow_edges_{N}km.csv` — from b_03c (optional; NA stub written if absent)
- `hex_{N}km_crosssection.rds` — for `hex_sf` geometries (used for `poly2nb` queen adjacency in lateral computation)

**Output — `data/processed/`:**

| File | Contents |
|------|----------|
| `hex_{N}km_flow_exposure.rds` | tibble: flow-graph hexes × years 2007:2017 (or NA stub for all columns) |

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
- `hex_{N}km_vi_panel.rds` — from b_03a
- `hex_{N}km_own_mining.rds` — from b_03b
- `hex_{N}km_flow_exposure.rds` — from b_03d
- `hex_{N}km_crosssection.rds` — covariates only (`gold_suit_share`, `dist_river_km`, `elev_mean`, `slope_mean`)

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

*Vegetation indices (12 columns — see b_03a for full definitions):*
`ndvi_landsat`, `evi_landsat`, `ndvi_modis`, `evi_modis`,
`ndvi_landsat_forestcrop`, `evi_landsat_forestcrop`, `ndvi_modis_forestcrop`, `evi_modis_forestcrop`,
`ndvi_landsat_nominecrop`, `evi_landsat_nominecrop`, `ndvi_modis_nominecrop`, `evi_modis_nominecrop`

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

*Time-invariant covariates (from b_01 crosssection):*

| Variable | Description |
|----------|-------------|
| `elev_mean` | Mean elevation (m) |
| `slope_mean` | Mean slope (degrees) |
| `gold_suit_share` | Share of hex overlapping gold-suitable geology (0–1) |
| `dist_river_km` | Distance to nearest natural waterway (km) |

**Re-run when:** any upstream cache changes, or C&S specification changes (e.g. different `first_treat` encoding).
