---
output:
  html_document: default
  pdf_document: default
---
# Galamsey Task List
*Sree Ayyar · Hema Balarama · Yoshiki Wiskamp · Till Meissner — May 2026*

---

## Overview

The project has two sequential phases:

1. **Remote Sensing** — Detect and classify gold mine presence across all of Ghana, 1995–2025, using satellite imagery. This pipeline does not yet exist at full spatial/temporal scale; Barenblitt et al. (2021) data covers SW Ghana, 2007–2017 & (2019 cross-section), and serves as ground truth and as an interim data source for Part 2.

2. **Descriptives & Analysis** — Use the mine panel to produce facts about galamsey incidence, spatial dynamics, and economic impacts. Currently uses Barenblitt data; will be re-run on the extended RS panel once Part 1 is complete.

---

## Outstanding Tasks — Punch List

A concise, actionable list organized by pipeline stage. Full per-script status is in the Code
Structure / Part 1 / Part 2 sections below and in `code/*/explainer.md` files; dataset-level detail
and candidate future sources are in `data_inventory.md`.

**Pipeline:** `0_data` → `1_remote_sensing` → `2_build` → `3_analysis` → `4_presentation`

### Data (`code/0_data/`)

- [ ] **River data source verification outstanding.** Which definition of "river" should feed the
  `dist_river_km` covariate and the upstream/downstream event-study treatment — OSM waterways,
  MERIT Hydro (and at which `upa` threshold), or a remotely-sensed measure? See
  `code/0_data/rivers_exploration.Rmd` for the exploration, the small-stream-dilution vs.
  sample-loss trade-off, and the open questions for a geologist. **Blocked on:** geologist review.
- [ ] **NDVI/EVI measurement choice outstanding — rebuild as a "peak EVI" pipeline (Vashold et al.
  2026 methodology).** *(PARTIAL 2026-07-03: steps 1–2 done + the download restructured — `d_01`
  Sec 5c now downloads the FULL QA-masked 16-day MOD13Q1 series (250 m, `modis_{ndvi,evi}_16day_ghana_{yr}.tif`,
  ~23 bands via `toBands()`, no GEE `.mean()`); Landsat NDVI/EVI also moved 250 m → 30 m; Sec 9 derives
  the annual-mean stacks locally for backward compat. Steps 3–5 below — ESA CCI mask, per-16-day zonal
  mean, annual-max "peak" reduction (to build in `b_03a`) — remain to do.)*
  The OLD pipeline exported a GEE-side **annual mean** of the 16-day composites (`.mean()` in Sec 5c),
  then took a zonal mean per hex in `b_03a_vi_panel.R`. Replace with this 4-step construction:
  1. **Source:** raw EVI (Didan 2015), 16-day composites, **250 m** — i.e. **MOD13Q1**
     (`MODIS/061/MOD13Q1`), not MOD13A2 (1 km). ✅ done 2026-07-03.
  2. **QA/cloud filtering** on each 16-day composite. ✅ done 2026-07-03 (GEE-side `updateMask(SummaryQA ≤ 1)`, now kept per-16-day, not collapsed).
  3. **Mask with yearly ESA CCI land cover** (Defourny et al. 2024, 300 m) to isolate the relevant
     area for each outcome — replaces the current MODIS MCD12Q1 mask (see below). ✅ DATA READY
     2026-07-06: ESA CCI downloaded (all-Ghana 1995–2022) + stacked → `cci_landcover_ghana_stack.tif`;
     the mask still has to be APPLIED in the reworked `b_03a` (steps 4–5).
  4. **Aggregate to the MEAN EVI at 16-day intervals, per hex/basin** — i.e. do the spatial
     (zonal-mean) reduction to hex level *at each 16-day step*, not after an annual pixel-level mean.
  5. **Take the ANNUAL MAXIMUM** of that 16-day hex-level series — "peak EVI" — as the actual annual
     outcome variable. **This is a max, not a mean**, and the order of operations matters: spatial
     aggregation happens first (per 16-day period), annual aggregation second (by hex).
  - **TARGET OUTCOME MATRIX (2026-07-03, user spec):** produce BOTH annual mean AND annual max, for
    BOTH NDVI and EVI, for FOUR masks — `overall` (none), `nominecrop` (exclude Barenblitt mining
    pixels — a mining mask, NOT ESA CCI), `forestcrop` (ESA CCI forest classes), `cropland` (ESA CCI
    cropland classes) → 2×2×4 = **16 MODIS columns**/hex/yr. Naming `{index}_modis_{mask}_{stat}`
    (overall = `{index}_modis_{stat}`); current columns are effectively the `_mean` versions. Design:
    build the masked 16-day per-hex series ONCE per (index×mask), then take both mean and max off it
    (keeps them comparable + mask-first for both). Compute-heavy (~26 yr × ~23 periods × 2 idx × 4
    masks of masked zonal extraction). ESA CCI class sets (to VERIFY against the official UN-LCCS
    legend + Ghana reality; mosaic classes 30/40/100 are the ambiguous boundary that drives coverage):
    forest ≈ {50, 60/61/62, 90, (100?)}; cropland ≈ {10, 11, 12, 20, 30, (40?)}. Put the class sets in
    a named-list config at the top of the reworked b_03a. UNBLOCKED 2026-07-06 — ESA CCI downloaded
    + stacked (see below); this is now the next task to build.
  - Justification given: peak EVI correlates strongly with gross primary production (Shi et al. 2017)
    and crop yields (Azzari et al. 2017; Johnson 2016).
  - **Robustness checks to also implement:** alternative land-use masks (**Digital Earth Africa
    2022**) and alternative aggregation schemes (e.g. mean vs. max, different windows).
  - **Implementation note:** this restructures `b_03a_vi_panel.R` non-trivially — it currently just
    extracts an already-annual, GEE-side-aggregated raster. The new pipeline needs either (a) 16-day
    composites downloaded/exported from GEE and zonal-meaned per hex per 16-day period locally, then
    maxed to annual; or (b) the per-16-day zonal mean done server-side in GEE before export. Scope
    before implementing — also ripples into `b_03e_assemble_eventpanel.R`.
- [~] **Switch land cover to ESA CCI** (needed for step 3 of the peak-EVI pipeline above, not just
  a `*_forestcrop` fix). MODIS MCD12Q1 under-detects forest in the study area (~6–11% of land pixels
  classified as Evergreen Broadleaf Forest, driving ~80% NA in the `*_forestcrop` VI columns) and
  the local stack currently stops at 2020. ESA CCI (Defourny et al. 2024, 300 m, yearly) is the
  specified replacement (see `data_inventory.md` §7).
  **DOWNLOADED + STACKED 2026-07-06:** `0_data/download_land_cover_ghana.ipynb` run against
  **Digital Earth Africa** (DE Africa STAC `cci_landcover`, via odc-stac; `configure_rio(aws_unsigned)`
  fix applied), **all-Ghana 1995–2022** (28 layers, 300 m) → `data/raw/land_cover/esa/cci_landcover_ghana_{year}.tif`.
  Stacked in `d_01_download_gee.R` Sec 9 → `data/raw/land_cover/esa/cci_landcover_ghana_stack.tif`.
  Classification diagnostics (national + Ankobra maps, composition, trends, 5 km-hex mask-coverage,
  plus an interactive leaflet map of the Ankobra basin toggling 2005/2020, with CartoDB/satellite
  basemaps and click-to-query land-cover class) added to `d_05_ndvi.R`,
  mirroring the MODIS MCD12Q1 block. **Remaining:** apply CCI as the
  outcome mask in the reworked `b_03a` (peak-EVI steps 4–5) — that is the parent task above.
- [ ] Re-download / re-stack the missing 2021–2024 MODIS land-cover layers (`d_01_download_gee.R`
  Sec 9) — `LCOVER_YEARS = 2001:2024` is requested but `modis_lc_ghana_stack.tif` only has
  2001–2020.
- [ ] Acquire a historical mine-licence register with issue dates (Minerals Commission / PMMC) —
  needed for D3c below.
- [ ] Wire CHIRPS rainfall into the D3b climate-shock trigger analysis (downloaded, not yet used).
- [ ] Acquire COCOBOD cocoa yields (D5c), census microdata / GLSS 7 (D6a–c) — see
  `data_inventory.md` §11 for candidate open-data substitutes (nightlights, WorldPop, RWI, DHS).
- [~] **Review the Maus et al. global mining-polygon dataset** (`data/raw/mining_mausetal/
  global_mining_polygons_v2.gpkg`) as another candidate validation/ensemble source alongside AMW
  and rs05. **EDA done 2026-07-07:** `code/0_data/d_09_mining_mausetal.R` filters the global
  layer (44,929 polygons worldwide) to Ghana server-side (577 polygons, ~187,400 ha total — ALL
  mining land use, not gold-specific, no artisanal/industrial split, single static snapshot) and
  produces an area histogram, a Ghana map, and a first-look Barenblitt-2019 overlap check
  (`outputs/figures/mining_mausetal/`). Findings: smooth log-normal size distribution (unlike
  AMW's tile-size spike, since these are pre-dissolved polygons); same river/drainage spatial
  clustering as AMW + Barenblitt, plus a couple of isolated northern/eastern industrial-looking
  sites outside the SW-Ghana galamsey belt; by POLYGON COUNT only 41.9% intersect Barenblitt 2019,
  but by AREA it's 93.2% — the largest polygons are concentrated inside Barenblitt's coverage,
  small ones outside it drive the low count-based number. **Remaining:** the full validation/
  ensemble comparison against Barenblitt + AMW + rs05 AlphaEarth (accuracy stats, not just overlap).

### Remote Sensing (`code/1_remote_sensing/`)

- [ ] **Review the Barenblitt et al. GitHub classification code**
  ([abarenblitt/GhanaArtisanalMining](https://github.com/abarenblitt/GhanaArtisanalMining)) —
  cross-check its methodology (training sample selection, RF specification, artisanal/industrial
  split) against the `rs05` AlphaEarth embedding classifier.
- [~] **Review Africa Mining Watch data** (`data/raw/africa_mining_watch_early_data/`) — compare
  its early ML detections against Barenblitt and the AlphaEarth classifier as a validation/ensemble
  source. **EDA done 2026-07-07:** `code/0_data/d_08_africa_mining_watch.R` loads both AMW geojsons
  (69,095 raw detection_boxes + 2,488 merged rectpolys, both pre-thresholded at confidence > 0.99,
  SW-Ghana-only bbox — "early_data" is a pilot run, not national coverage) and produces confidence
  distributions, a detections map, a site-area histogram, and a first-look Barenblitt-2019 overlap
  check (`outputs/figures/africa_mining_watch/`). Findings: confidence piles up near 1.0 (threshold
  not very binding); detections trace a clear river/stream network pattern; site sizes spike at
  ~10.24 ha (min/unmerged-tile size) with a long tail to ~176,900 ha (one large outlier worth
  checking); only 8.4% of AMW sites intersect Barenblitt 2019 (91.6% fall outside Barenblitt's
  survey area entirely, so neither confirmed nor refuted). **Remaining:** the full validation/
  ensemble comparison against Barenblitt + rs05 AlphaEarth (accuracy stats, not just overlap counts).
- [ ] RS6 — spatial cross-validation (by district) for the embedding classifier (todo below).
- [ ] RS7 — threshold probability maps into a binary presence panel (todo below).

### Build (`code/2_build/`)

- [ ] Run `b_03a_vi_panel.R` under the current modular pipeline structure (slow — ~4–5h at 1 km).
- [ ] Extend the MERIT D8 hex flow graph beyond the current study-area clip to all of Ghana.
- [~] Replace the 25 km centroid-block SE-clustering stand-in with a real sub-basin ID
  (HydroBASINS or MERIT `upa` pour-points) — flagged throughout `event_study_design.md`.
  **2026-07-06: HydroBASINS download added** — `d_01_download_gee.R` Sec 6b now submits a table
  export of `WWF/HydroSHEDS/v1/Basins/hybas_9` (level-9 sub-basins; NOTE: "hybas_9" = level 9, not
  level 12 — the finest level GEE hosts as a ready FeatureCollection), filtered to `export_region`
  → `data/raw/hydrobasins/hydrobasins_hybas9_studyarea.geojson` (downloaded; 453 basins in region).
  **2026-07-06: `d_07_hydrobasins.R` written + run** — offline script owning the HydroBASINS layer:
  spatial-joins each hex centroid to its level-9 sub-basin (nearest-basin fallback for 53 coastal-edge
  hexes) → `data/processed/hydrobasins/hex_basin_5km.csv` (`hex_id, HYBAS_ID, PFAF_ID, MAIN_BAS,
  basin_num`); plus EDA (partition map + hexes-per-basin histogram + `basin_summary.csv`).
  **Cluster count verified: 280 level-9 basins cover the 3,348-hex grid** (median 10 hex/basin, 18
  singletons; 42 coarser MAIN_BAS as fallback) — ample for clustered/CS SEs.
  **2026-07-06: merge into `b_03e_assemble_eventpanel.R` CONFIRMED working** — ran `b_03e` after the
  5/2 km VI extraction (below) and `event_panel_5km.rds` reports "Sub-basin SE clusters (HydroBASINS
  L9): 280 basins / 42 main-basins" (`basin_id`/`main_basin`/`pfaf_id`/`basin_num` columns present).
  **2026-07-06: generalized `d_07_hydrobasins.R` to loop over `RESOLUTIONS <- c(5, 2, 1)`** (was
  hardcoded to 5 km only), matching the sibling `b_03c`/`b_03d` convention — it only needs each
  resolution's `hex_{N}km_crosssection.rds`, not the VI panel, so 1 km works even though its VI
  panel is deferred. Re-run: 5 km reproduced identical numbers (280 basins/42 main-basins, confirms
  the refactor is correctness-neutral); **2 km → 287 basins/43 main-basins**; **1 km → 287
  basins/43 main-basins**. Outputs now resolution-suffixed throughout (`hex_basin_{N}km.csv`,
  `basin_partition_map_{N}km.png`, `hexes_per_basin_hist_{N}km.png`, `basin_summary_{N}km.csv`);
  the old unsuffixed 5 km files were byte-identical duplicates and deleted. Re-ran `b_03e` —
  `event_panel_2km.rds` now also carries basin columns (287/43); 1 km still skipped (VI panel
  deferred). **Remaining:** switch the event-study cluster var from the 25 km centroid-block
  stand-in to `basin_num` (`load-panel` chunk, identical across `a_05_event_study_{1,2,3}.Rmd` /
  `event_study_design.md` / `methodology_explainer.md`).

### Analysis (`code/3_analysis/`)

- [ ] **Re-run the event-study results once the updated NDVI/EVI measures are available.**
  `a_05_event_study_1.Rmd` (Q0) and `a_05_event_study_2.Rmd` (Q1) currently loop over NDVI/EVI ×
  {base, no-mine-crop, forest-crop} built from the MODIS land-cover mask; once the Digital Earth
  Africa / ESA-CCI-based masks and aggregation-scheme robustness pipeline above are in place, the
  outcome definitions will change and every Q0/Q1 design (V1–V3b) needs to be refit against the
  revised measures. See `4_presentation/methodology_explainer.md` §9 for what each design shows.
- [ ] Knit `a_05_event_study_1.Rmd`, `_2.Rmd`, and `_3.Rmd` at least once each with the current
  (pre-revision) outcomes — the multi-outcome integration is written but not yet executed
  (compute-heavy, especially `_2`; deferred). **2026-07-08: split from the single combined
  `a_05_event_study.Rmd` into `_1` (Q0, own-hex mining → own-hex vegetation), `_2` (Q1, upstream
  mining → downstream vegetation), `_3` (Q2, neighbour mining → own mining) — each is now
  self-contained and independently knittable. Q2, which had been fully disabled since 2026-06-30,
  was restored to working order (`eval=FALSE`/HTML-comment removed) as part of the split; it has
  not been re-run/re-reviewed since restoration.**
- [ ] **Add Hansen Global Forest Change as an event-study outcome** (`UMD/hansen/global_forest_change`,
  30 m, 2000–2023 — already listed as a candidate land-cover source in `data_inventory.md` §7, but
  not yet used as an *outcome* in its own right). Distinct from the NDVI/EVI greenness proxies:
  Hansen gives annual **forest loss** (and cover) directly, so it could serve as a more literal
  "did the forest actually disappear near this mine" outcome alongside the vegetation-index measures.
- [ ] **Add a simple "own-hex" event study as a sanity check**, before/alongside the
  upstream/downstream designs (V1–V3b). Treatment = mining **within the focal hex itself**
  (`own_onset_year`/`own_new_ha`, already in the panel — no new data needed), not anything
  upstream/downstream. Question: is there a detectable NDVI/EVI (and Hansen forest-loss) effect in
  the hex that is *actually mined*, full stop? This is the most basic version of the design — no
  flow-graph, no directionality, no waterborne-mechanism story — so if it doesn't show an effect,
  that is a strong signal something is wrong upstream of the fancier designs (panel construction,
  outcome definition, event-time coding); if it does, it is the natural baseline the
  upstream/downstream results should be read against.
- [ ] Knit `a_03_firststage_diagnostics.Rmd` (needs `b_02_firststage_models.R` run first).
- [ ] D3b, D3c, D4a, D5c, D6a–c remain blocked on the data items listed above.

### Presentation (`code/4_presentation/`)

- [ ] Add V3 / V3b event-study result slides to `galamsey_motivation.qmd` (currently only V1/V2
  results are shown) — needs a fresh `a_05_event_study_2.Rmd` (Q1) knit for the `es_v3*` artifacts
  to exist.
- [ ] Once the NDVI/EVI robustness pipeline and river-definition question are resolved, update
  `4_presentation/methodology_explainer.md` accordingly (it currently documents the MODIS-based
  outcome and the MERIT-`upa`-threshold river definition as provisional).

---

## Code Structure

```
code/
├── 0_data/
│   ├── d_05_ndvi.R               ← in progress: QC diagnostics for Landsat + MODIS NDVI/EVI stacks — per-year NA counts (table + line chart across all 4 products) + spatial NA-frequency maps; MODIS land cover (MCD12Q1) section: plot_lc() helper (terra legend via levels()+type="classes"); Ghana-wide maps (2010 + most recent); Ankobra basin section (boundary = OSM "Ankobra" waterways → convex hull + 20 km UTM buffer): ggplot2+patchwork side-by-side maps 2005+2020 (shared legend, river overlay, col_scale shared across panels), bar chart (2019), time trend for 4 classes: Evergreen Broadleaf Forest / Woody Savanna / Savanna / Cropland (2001–2024). ADDED 2026-07-02: forestcrop-missingness diagnostics — quantifies why the *_forestcrop event-panel columns (built in b_03a_vi_panel.R) are ~80% NA at 5 km. CAUSE 1 (temporal): land_cover_ghana_stack.tif only spans 2001–2020 (2021–2024 layers MISSING despite d_01 requesting LCOVER_YEARS=2001:2024), so every VI year outside 2001–2020 is 100% NA. CAUSE 2 (spatial): IGBP class-2 (Evergreen Broadleaf Forest) is only ~6–11% of land pixels and shrinking, so just ~25–38% of 5 km hexes hold any class-2 pixel → the rest NA (rising 62%→75% over 2001–2020). Writes outputs/figures/ndvi/forestcrop_missingness.png. ADDED 2026-07-03: Ankobra-basin forestcrop mask-definition comparison — for the 5 km hexes intersecting the basin, computes the hex-year NA rate under 4 mask definitions (class-2-only baseline vs forest=IGBP 1–5 vs cropland=12,14 vs forest+cropland) to quantify how broadening the land-cover mask reduces missingness. Summary table + line chart; writes outputs/figures/ndvi/forestcrop_maskdefs_ankobra.png
│   ├── d_01_download_gee.R           ← in progress: GEE exports for NDVI + EVI (Landsat composites, 30 m; changed from 250 m 2026-07-03 — needs re-export) + MODIS VI/MOD13Q1 (NDVI+EVI annual mean of QA-masked 16-day composites, 250 m, 2000–2025; changed from MOD13A2/1 km 2026-07-03 — needs re-export) + MODIS Land Cover/MCD12Q1 (LC_Type1 IGBP, 500 m, 2001–2024) + CHIRPS. Reorganised 2026-07-03: source-explicit Drive/local filenames (landsat_ndvi_/landsat_evi_/modis_ndvi_/modis_evi_/modis_lc_); Landsat NDVI+EVI now share data/raw/landsat_vi/; MODIS VI exported as two single-band files (no longer a 2-band bundle); land cover → modis_lc_ghana_stack.tif; land cover promoted to its own Section 6 (VIs=5, CHIRPS=7, monitor=7b, download=8, stacking=9). Single Drive folder ghana_mining_gee_exports. Sec 9 loads TIFs into raster stacks (land cover saved as INT1U). Export region now RESTRICTED to the Barenblitt study area (SW Ghana) + 25 km buffer (Section 3, same bbox logic as d_04_merit.R) via `export_region <- study_bounds`, because the full-Ghana 30 m Landsat export tiled into multiple GeoTIFFs (~1.6 GB/yr); full-Ghana `ghana_bounds` block retained but commented out for easy scale-up. MODIS VI 5c now downloads the FULL QA-masked 16-day series (modis_{ndvi,evi}_16day_ghana_{yr}.tif, ~23 bands via toBands(), no GEE .mean()) — required for the peak-EVI pipeline (mask each 16-day step by ESA CCI → per-hex mean → annual max); Sec 9 derives the annual-mean stacks modis_{ndvi,evi}_ghana_stack.tif locally so b_03a/d_05/a_05 keep working (annual_mean_stack() is tile-robust: groups files by year, terra::vrt()-mosaics any GEE tile shards before the per-pixel mean over the 16-day bands)
│   ├── d_02_elevation.R          ← in progress: BASIC terrain layer only — elevatr DEM for Ghana → slope. Downloads against a 10 km-buffered boundary; bathymetry clamped to 0; Z+buffer in filenames. DEM pinned to z11 ~76 m. Writes two rasters to data/processed/elevation/ (UTM30N DEM + slope). Per-hex extraction REMOVED — now happens in 2_build/b_02_hex_frame.R which stores elev_mean/slope_mean directly in the cache RDS. MRVBF/HAND/hydro in d_06_gold_deposits.R.
│   ├── d_06_gold_deposits.R      ← in progress: TWO-PART script. Part 1 (Secs A–E): hydro-geomorphic alluvial-gold potential — WhiteboxTools breach→D8 flow dir/accum→streams+Strahler→HAND; SAGA MRVBF; reads DEM from d_02_elevation.R; plan in gold_deposits.md. Part 2 (Secs F–I): Girard et al. (2022a) gold-suitability EDA — merged from deleted 3_other/gold_suitability.R (2026-06-25): Layer 1 polygon + Layer 2 PRIO-Grid clipped to Ghana, comparison maps, Barenblitt validation overlay, district-level aggregation + choropleth/bar chart, outputs gold_suitability_by_district.csv + 3 PNGs. Secs J–L TODO (placer indicators, MERIT Hydro, per-hex extraction → belongs in b_02_hex_frame.R). Not yet run
│   ├── d_04_merit.R              ← in progress: COMBINED MERIT pipeline (download_download+analysis re-merged 19/06). Runs STUDY-AREA-WIDE (full Barenblitt extent + 25km buffer): Sec 1-4 rgee auth + study-area bbox + submit GEE exports MERIT-DEM(dem) + MERIT Hydro(dir/upa/wth/elv) at 90m NATIVE EPSG:4326 to Drive as merit_{dem,hydro}_studyarea (REGION_TAG); Sec 5 fetch (read_merit() mosaics multi-tile GeoTIFFs via vrt); Sec 6 reproject LOCALLY to UTM30N (dir/upa/wth=nearest, elv=bilinear; DEM on shared hydro grid); Sec 7 D8 dir + stream network from upa (7a freq table fixed 22/06: as_tibble(col.name=) is not a real arg → setNames(c("code","count")); studyarea_flow_network.png). Sec 8 HAND (WBT), Sec 9 MRVBF (SAGA), Sec 10 SPI/STI/HAND-zones/Strahler are DISABLED (if(FALSE) guards — heavy at study-area scale; flip to files_ready to enable; still carry inert ankobra_* output names). Sec 11 REWRITTEN 22/06 to run study-area-wide on the canonical d03 5km hex grid (was: Ankobra crop on a local test grid). Loads hex_5km_crosssection.rds → uses its hex_sf/hex_id (so all outputs key to d03; STOPs if cache absent), rasterizes the d03 hexes onto the native 4326 MERIT grid. Sec 11 D8 hex flow graph — directed up/down hex relationships from MERIT dir/upa (channel-only edges at ROUTE_KM2=10 km² — DECOUPLED from the 50 km² "river" label per the 11g off-network diagnostic: 50 dropped 23% of mined-ha as routing sources vs 5.5% at 10; routing-derived overlays 11f/11h/11i also use ROUTE_KM2; Sec 7-10 stay at STREAM_KM2=50; immediate neighbours): (11.0) interactive leaflet preview of upa channel masks at 5/10/20/50 km² thresholds (toggleable, default 50) over satellite+light basemaps w/ toggleable OSM-waterways overlay (studyarea_channel_network_upa.html); rasterize hex ids → per-cell D8 downstream lookup via matrix offsets → cross-hex edges → net dominant direction (hex_flow_edges_5km.csv — feeds 2_build/b_04_event_panel.R FLOW_EDGES_PATH); downstreamness scalar = mean log(upa) per hex (hex_downstreamness_5km.csv); DAG validation + downstreamness-vs-northing Spearman (11e uses mean_log_upa as the cardinal check + reports topo-rank rho only to document its ~0 arbitrariness); 11f = 2-panel map (topo downstream_rank | mean_log_upa), MERIT channels red overlay, studyarea_hex_flow_rank.png; 11g = event-study treatment builder: per-hex UPSTREAM galamsey exposure via graph reachability (subcomponent mode="in" on the DAG g) — up_mining_ha (raw) + up_mining_ha_decay (exp(-hops/DECAY_HOPS)) + own_mining_ha (direct land-clearing control) + rank/mean_log_upa, hex_upstream_exposure_5km.csv; includes off-network diagnostic (galamsey hexes + mined-ha touching no channel cell at upa=50/20/10/5). 11h = 3-panel exposure map (own-hex source | raw upstream | distance-decayed; plasma LOG10 fill w/ 0→grey so no-mining is separable from low-mining — replaces sqrt, which the Ankobra-basin outliers washed out; pink source outlines REMOVED; white MERIT channels, studyarea_hex_upstream_exposure.png); 11i = interactive leaflet (studyarea_hex_exposure_leaflet.html): toggleable exposure hexes (raw + decayed, full popups + hover labels + highlight) with QUANTILE-BINNED plasma (colorBin, outlier-robust; 0/NA→grey legend "none"), MERIT channel raster, directed flow edges, over satellite/light basemaps + legend (galamsey-polygon layer REMOVED). 11j (added 23/06) = ROUTE_KM2 sensitivity sweep: rebuilds the flow graph + per-hex upstream exposure at ROUTE_KM2 ∈ {2,5,10,20}, reports per-cut edge count / feedback-arc share / off-network mined-ha / total attributed ha (hex_flow_threshold_sweep_5km.csv) + cross-threshold Spearman corr of per-hex up_mining_ha. Rationale: a channel threshold is load-bearing (graph = river network respecting divides; cut=0 routes over hillslopes + leaks mining across basins), so the question is the VALUE not whether to filter — sweep shows if the headline cut is immaterial; consider lowering to ~5 km². Feeds the upstream-mining→downstream-NDVI event study (d05). Replaces d03's northing-as-downstream proxy + swap into d03 make_dir_nb. Needs igraph. NOTE: traces on NATIVE 4326 dir/upa (reprojecting D8 pointer corrupts routing — confirmed cell-level cycles on UTM grid). FLAG: Sec 10d Strahler (WBT on reprojected dir) has same corruption — re-point at native dir before trusting. Sec 1-6 run; Sec 7 fixed + running; Sec 11 rewritten, not yet run on full study area
│   ├── d_03_waterways.R          ← in progress: UPDATED 2026-06-25 — Sec 0b: timestamped download to data/raw/shapefiles/osm_extracts/waterways_ghana_YYYY-MM-DD.gpkg; skips download if timestamped file exists (FORCE_DOWNLOAD=FALSE default). Sec 0c: filters to natural watercourses (NATURAL_WATERWAYS incl. flowline) → writes data/processed/waterways/waterways_natural.shp (pipeline input for b_01_cross_section + a_01 + a_02). PREREQUISITE for b_01_cross_section. Secs 1–7 EDA unchanged. Sec 8 (added 2026-06-29): named OSM rivers (waterway=="river") merged per river + 5 km galamsey hexes (artisanal ha, plasma sqrt fill) overlaid; rivers drawn on top for overlap legibility; labels for rivers >15 km; saves outputs/figures/maps/waterways_galamsey_map.png; guards on hex_5km_crosssection.rds + mining_extent_by_hex5km_2019.csv. Not yet run
│   ├── d_07_hydrobasins.R        ← done: CREATED + RUN 2026-07-06. Offline (no GEE) script owning the HydroBASINS level-9 layer downloaded by d_01 Sec 6b. Reads hydrobasins_hybas9_studyarea.geojson (453 basins) + hex_5km_crosssection.rds; assigns each hex CENTROID to its containing sub-basin via st_join(st_within), nearest-basin fallback for the 53 coastal-edge hexes. Writes data/processed/hydrobasins/hex_basin_5km.csv (hex_id, HYBAS_ID, PFAF_ID, MAIN_BAS, basin_num = compact 1..K factor for the did/polars backend). EDA: basin-partition map (Barenblitt galamsey + rivers overlay, outputs/figures/hydrobasins/basin_partition_map.png), hexes-per-basin histogram, basin_summary.csv. VERIFIED cluster count: 280 level-9 basins over the 3348-hex grid (median 10 hex/basin, max 97, 18 singletons; 42 coarser MAIN_BAS as fallback) — ample for clustered/CS SEs. Feeds b_03e_assemble_eventpanel.R (merge pending) → a_05 cluster-var swap (pending)
│   ├── d_08_africa_mining_watch.R ← done: CREATED + RUN 2026-07-07. Offline EDA-only script (no processed outputs) on the Africa Mining Watch early ML detections (data/raw/africa_mining_watch_early_data/), a pilot/SW-Ghana-only run (69,095 raw detection_boxes, MLP64-16 classifier, pre-thresholded confidence>0.99; merged into 2,488 rectpolys site footprints). Confidence-score histograms (both files pile up near 1.0 — threshold not very binding), a detections map (blue boxes + orange merged footprints, clear river/stream-network spatial pattern), a site-area histogram (UTM30N hectares; spike at ~10.24 ha = min/unmerged-tile size, long tail to ~176,900 ha), and a first-look Barenblitt-2019 overlap check (8.4% of AMW sites intersect Barenblitt's SW-Ghana extent; 91.6% fall outside it entirely — neither confirmed nor refuted). Outputs: outputs/figures/africa_mining_watch/*.png. NOT a full validation/ensemble comparison (no accuracy stats vs. Barenblitt/rs05) — that remains open.
│   └── d_09_mining_mausetal.R    ← done: CREATED + RUN 2026-07-07. Offline EDA-only script (no processed outputs) on the Maus et al. GLOBAL mining-polygon gpkg (data/raw/mining_mausetal/global_mining_polygons_v2.gpkg, 44,929 polygons worldwide, fields ISO3_CODE/COUNTRY_NAME/AREA) — filters to Ghana via a server-side GDAL SQL query (WHERE ISO3_CODE='GHA', avoids loading the global layer) → 577 polygons, ~187,400 ha total (ALL mining land use, not gold-specific, no artisanal/industrial split, single static snapshot). Area histogram (UTM30N hectares vs. the AREA field, confirmed AREA is km^2; smooth log-normal distribution, unlike AMW's tile-size spike), a Ghana map (same river/drainage clustering as AMW + Barenblitt, plus isolated northern/eastern industrial-looking sites), and a first-look Barenblitt-2019 overlap check — polygon-count overlap only 41.9% but AREA-weighted overlap 93.2% (biggest polygons cluster inside Barenblitt's SW-Ghana coverage). Outputs: outputs/figures/mining_mausetal/*.png. NOT a full validation/ensemble comparison — that remains open.
├── 1_remote_sensing/
│   ├── rs01_landsat_gee.R        ← in progress: imagery download + Phase 1/2 (Landsat 8/9)
│   ├── rs02_sentinel2_gee.R      ← in progress: imagery download + Phase 1/2 (Sentinel-2); Section 8 has leaflet Barenblitt overlay
│   ├── rs03_embedding_classifier_design.md ← design doc: AlphaEarth embedding classifier approach
│   ├── rs05_embedding_classifier.R ← in progress: stratified sampling + RF training + annual probability map exports
│   ├── rs03_spectral_indices.R   ← TODO: file not yet created
│   ├── rs04_classification.R     ← TODO: file not yet created
│   ├── rs05_validation.R         ← TODO: file not yet created
│   ├── rs06_apply_classifier.R   ← TODO: file not yet created
│   └── rs07_export_panel.R       ← TODO: file not yet created
├── 2_build/
│   ├── b_01_cross_section.R    ← todo: UNIFIED cross-section builder (created 2026-06-25; replaces b_01_mining_by_unit.R + b_02_hex_frame.R). Loops over districts + hex{1,2,5}km. Writes mining_*_by_{unit}_*.csv (area_ha col) + hex_{N}km_crosssection.rds = list(hex_analysis, hex_sf, lw, nb, study_area). Reads waterways_natural.shp from d_03_waterways.R (prerequisite). Not yet run
│   ├── b_02_firststage_models.R    ← in progress: compute layer for the MAUP-robustness Rmd. Runs nested ladder M1(baseline)→M2(river spline+spatial lags)→M3(+terrain)→M4(+all-4 interactions) across 1/2/5 km grids; per model×grid computes fit metrics (McFadden/AUC/Brier/AIC) + geography-weighted Moran's I null; M5 thin-plate spline at 5+2km. Writes d03_maup_results.rds. Reads hex_{res}km_crosssection.rds from b_01_cross_section. Bug fix 2026-06-25: drop pre-existing elev_mean/slope_mean from cached hex_analysis before terrain join (left_join was producing .x/.y suffixes → filter() failed). M5_ONLY mode running; full ladder needs b_01_cross_section + z11 hex_terrain at 1/2/5km
│   ├── b_03a_vi_panel.R                ← in progress: REWRITTEN 2026-07-06 as the peak-EVI pipeline (Vashold et al. 2026, see task above). Reads MODIS MOD13Q1 16-day series (not annual-mean); masks each 16-day composite with that year's ESA CCI land cover (Landsat VI dropped — not used for now, high NA share, see data_inventory.md §6); per-hex zonal MEAN at each 16-day step; ANNUAL MEAN + MAX off that series. 6 masks (overall, nominecrop [Barenblitt], cropland, forest, veg_narrow, veg_broad) × 2 indices × 2 stats = 24 VI cols + urban_share (ESA CCI class 190 share) = 25 cols. Writes hex_{N}km_vi_panel.rds. Restructured 2026-07-06 to read+CCI-mask each 16-day raster ONCE per (index,year,mask) instead of once per resolution (was 3x redundant reads/masks — a genuine perf bug found after the first full run was too slow); extract-per-resolution now the only resolution-specific step. Compute-heavy; re-run only when GEE/CCI rasters change. **2026-07-06: RUN COMPLETE for 5/2 km**
(~4.5h; `RESOLUTIONS` temporarily `c(5, 2)`) — `hex_{5,2}km_vi_panel.rds` written with all 25 columns.
NA rates: `_mean`/`_max` overall & nominecrop ~0.1–0.2%; `cropland` 3.6% (5km) / 9.5% (2km);
`veg_narrow` 1.3%/2.2%; `veg_broad` 0.9%/1.7%; `forest` 52%/71% (still the highest-NA mask — CCI
forest classes are genuinely sparse at these resolutions, but well below the old MODIS-class-2
~80%); `urban_share` 11.5% NA (years outside CCI's 1995–2022 span). **1 km DEFERRED** — even after
the read/mask fix, `terra::extract()` over the 1 km grid's 80,716 hexes projected the full
3-resolution run to 30+ hours (vs. the "overnight" expectation). Stale pre-rework 1km file moved to
`hex_1km_vi_panel_STALE_pre20260706.rds` so `b_03e` doesn't pick it up. 1 km needs its own run,
ideally after profiling/switching the zonal-stats engine (candidate: `exactextractr`, typically much
faster for many-polygon zonal means) — revert `RESOLUTIONS` to `c(5, 2, 1)` once that's sorted.
│   ├── b_03b_own_mining.R              ← done: Own-hex + adjacency mining component. Writes hex_{N}km_own_mining.rds — tibble(hex_id, year, own_new_ha, adj_new_ha) covering all hexes × 2007:2017. Run 2026-06-26; all three resolutions complete.
│   ├── b_03c_flow_graph.R              ← done: D8 hex flow graph builder. Loops over RESOLUTIONS c(1,2,5); traces D8 channel cells on native 4326 MERIT grid; nets bidirectional pairs; removes feedback arcs → DAG. Writes hex_flow_edges_{N}km{S}.csv + hex_downstreamness_{N}km{S}.csv for S in {"" (ROUTE_KM2=10, primary), "_upa50" (ROUTE_KM2=50, alt)}. Run 2026-06-26; re-run 2026-07-06 with the dual-threshold rework — all 3 resolutions × 2 thresholds complete, primary numbers unchanged (confirms the refactor is correctness-neutral).
│   ├── b_03d_flow_exposure.R           ← done: Upstream/downstream flow exposure component. Writes hex_{N}km_flow_exposure{S}.rds for each ROUTE_KM2 threshold suffix S. Run 2026-06-26 (session 2): all three resolutions complete. 1km: 3,689 hexes with upstream mining / 8,759 downstream / 2,516 lateral. 2km: 1,920/4,679/1,698. 5km: 829/2,170/1,016. Re-run 2026-07-06 for both thresholds — primary (ROUTE_KM2=10) numbers match exactly; _upa50 alt populated for all 3 resolutions. **REWRITTEN 2026-07-10 → HOP RINGS.** New user param `K_HOPS = 3`. Exposure is now built as DISJOINT rings: ring k = hexes at shortest-path distance EXACTLY k on the flow graph (`igraph::ego(order=k, mindist=k)`), for k=1..K_HOPS, upstream (mode="in") and downstream (mode="out"). Ring 1 keeps the historical names (nearest_up_*, nearest_down_*, lateral_*); rings 2-3 are up_hop{k}_new_ha / down_hop{k}_new_ha / lateral_hop{k}_new_ha. up_new_ha/down_new_ha (full catchment, k=Inf, via subcomponent) unchanged. Rings partition the within-K set, so cumulative "within k hops" exposure is recovered downstream by summing rings (cumsum is linear; cumulative onset = pmin over ring onsets) — rings are a sufficient statistic for the nested sets AND let hop-1/2/3 enter one regression to trace attenuation with hydrological distance. LATERAL REDEFINED (breaking): was queen-adj minus the 1-HOP up/down sets, now queen ring k minus ALL up/down hexes within K_HOPS (max hop, not k) — guarantees no hex is ever both lateral and flow-treated at any radius, and makes lateral rings sum to the cumulative lateral set. Queen rings via `spdep::nblag(maxlag=K)` (guarded: nblag rejects maxlag=1). The nearest_*_onset_year computation was DELETED here and is now derived uniformly in b_03e from the *_new_ha columns (same quantity: min{year : ring_new_ha>0} == min own_onset over ring members, since own_new_ha>=0). Re-run 2026-07-10, 5km both thresholds (~3.2 min): ring 1 up/down/lateral = 502/743/828 hexes, ring 2 = 427/820/1496, ring 3 = 370/893/1866. 2km + 1km re-run same session.
│   ├── b_03e_assemble_eventpanel.R     ← done: Final assembly. Reads vi_panel + own_mining + flow_exposure + crosssection (covariates). Expands to full year spine, computes all stock+onset columns, adds C&S bookkeeping. Writes event_panel_{N}km.{csv,rds}. Run 2026-06-26 (session 2): all three resolutions complete with flow graph populated. Columns include nearest_up_stock_ha, nearest_down_stock_ha, lateral_stock_ha, lateral_onset_year. UPDATED 2026-07-06: optional per-resolution merge of hydrobasins/hex_basin_{N}km.csv (from d_07) — adds basin_id (HYBAS_ID L9), main_basin (MAIN_BAS, coarser), pfaf_id, basin_num (compact 1..K factor for did/polars) as the SE-clustering keys, joined by hex_id like the optional _upa50 block; diagnostic prints the basin/main-basin cluster count. **Re-run 2026-07-06** (after the peak-EVI extraction + dual-threshold flow graph, above) — `event_panel_{5,2}km.{csv,rds}` now carry the 25 peak-VI columns, both ROUTE_KM2 thresholds, and (5 km only) basin SE-clustering columns. 1 km skipped cleanly ("missing inputs: hex_1km_vi_panel.rds") since its VI panel is deferred. **UPDATED 2026-07-10 for the b_03d hop rings.** `compute_flow_cols()` no longer hardcodes column names: it DISCOVERS every `*_new_ha` column in the exposure cache and gives each a matching `*_stock_ha` (within-hex cumsum) and `*_onset_year` (first year > 0) via one code path, so raising `K_HOPS` in b_03d needs no edit here. All-NA columns (flow stub, or lateral when the crosssection cache is missing) stay NA instead of becoming a run of zeroes. New helpers: `stock_of`/`onset_of` (name mapping), `detect_k_hops()` (infers K from the `*_hop{k}_new_ha` names; returns 1 for a pre-rings cache), `flow_col_order()` (canonical (new, stock, onset) triplet order; also drives the `_upa50` name list, which was previously typed out by hand). Panel goes 76 → 112 columns at 5 km (36 ring columns: 3 dims × 2 rings × 3 stats × 2 thresholds). VERIFIED 2026-07-10 against the pre-refactor panel: all 15 historical flow columns + own/adj columns bit-identical; 0 columns dropped; sum of rings <= full-catchment column; sum of ring stocks == stock of summed rings. `lateral_new_ha` changed as intended (stricter): shrank in 7.7% of hex-years, 188 hexes lost `lateral_onset_year` (1016 → 828) — those were queen-adjacent hexes that sit 2-3 hops up/down the channel. Backup of the pre-rings caches in `data/processed/_bak_pre_rings/`.
├── 3_analysis/
│   ├── a_01_incidence_maps.R       ← in progress: D1a–D1e implemented; D1a–D1d outputs produced; D1e (Lorenz) code written, not yet run. Map waterways now filtered to natural watercourses only (drop canal/drain/ditch), matching d03. Writes data/processed/n_surveyed_districts.rds (nrow of survey_districts_sf) for galamsey_motivation.qmd to read — avoids heavy spatial ops in the presentation setup chunk
│   ├── a_02_spatial_clustering.R   ← in progress: REFACTORED 2026-06-25 — build half removed (Secs 1-4, ~220 lines; was duplicating b_01_cross_section). Now reads hex_5km_crosssection.rds + mining_timeseries_by_hex5km_long.csv from b_01_cross_section. D2a–D2e all implemented (D2f event-study DELETED — moved to a_05). D2d-Asym + D2e-Perm DELETED 2026-06-29 (northing proxy unreliable; superseded by a_05 MERIT estimates). D2e-Schematic moved to a_05_event_study.Rmd (2026-06-29), then duplicated into a_05_event_study_2.Rmd (Q1) and a_05_event_study_3.Rmd (Q2) when that file was split 2026-07-08 (Q0 doesn't need the neighbour-role schematic). Reads waterways_natural.shp from processed/. MUST re-run b_01_cross_section first
│   ├── a_03_firststage_diagnostics.Rmd ← in progress: presentation layer, fully restructured. Reads d03_maup_results.rds; renders Part A (fit ladder × grid: AUC table+plot, full metrics) + Part B (geography-weighted null × grid: p_excess table+plot) + NEW Part C (M5 spatial-spline null @5km & 2km: intro on what the spline does/how it differs, stats table w/ Hex(km) col, M4-vs-M5 null-draw distribution vs observed Moran's I FACETED by resolution, residual Moran's I table, mining-propensity-net-of-covariates surface map FACETED by resolution, discussion of the obs–null gap = contagion vs non-smooth sub-grid covariate) + Appendix. Interpretation gained an M5 bullet. Old Tests 1–4 / Fix 1–5 sections removed. Not yet knitted (needs d03c run first)
│   ├── a_04_motivating_facts.R     ← in progress: D3a, D5a, D5b outputs produced; D3b/D3c/D4a/D5c/D6a-c blocked on data. D4b hex-build DELETED 2026-06-25 (moved to a_05 via b_03_event_panel)
│   ├── a_05_event_study_1.Rmd      ← in progress: **SPLIT OUT 2026-07-08** from the single combined `a_05_event_study.Rmd` (history below). Q0 — own-hex mining → own-hex vegetation (mechanics sanity check): treatment = mining within the focal hex itself, no flow graph/directionality. Q0a (onset clock, no threshold) + Q0b (own_stock_ha mbar sweep 0/10/25/50 ha), looped over OUTCOMES, C&S via did::att_gt. Self-contained (own copy of load-panel/outcomes-setup/helpers subset — no cross-sourcing). **Added 2026-07-08 (2nd revision): `panelview-thresholds` chunk** (own_stock_ha at mbar=0/25, mirroring `_2.Rmd`'s upstream panelviews; needs `panelView`, added back to this file's package list) — `es_q0_panelview_own_mbar{0,25}.png`. **Added 2026-07-08 (3rd revision): `run_cs()`'s `clustervars` default fixed from hardcoded `"main_basin"` (42 clusters, unstable at event_time==2 — traced via `cluster_se_diagnostic.R` to 2 of those 42 basins holding 79% of the e=+2-eligible hexes, effective cluster count ≈3) to `"block_num"`** (real HydroBASINS `basin_num`/280 clusters where present, old 25km-block fallback otherwise — same fix applied identically to `_2.Rmd`/`_3.Rmd`; also fixed the `load-panel` chunk's `n_clusters` diagnostic to match, was reporting `main_basin`'s count). See `event_study_design.md`'s SE-clustering section for the full root-cause writeup. **Added 2026-07-08 (4th revision, user-driven): panelview thresholds changed to mbar=0/10** (was 0/25) and its outcome/completeness column switched to `ndvi_modis_nominecrop_max`; **`OUTCOMES` headline mask switched from `cropland` to `nominecrop`** throughout (excludes ever-mined pixels via the Barenblitt footprint directly, rather than relying on ESA-CCI reclassification — isolates the within-hex spillover signal from the mechanical on-mine VI collapse; NA ~0.1% vs cropland's ~3.6-9.5%). Fixed all downstream hardcoded `ndvi_modis_cropland_max`/`q0a_fits[["evi_modis_cropland_max"]]` references to match (the latter was also a pre-existing NDVI/EVI mislabel bug, now reads `ndvi_modis_nominecrop_max` as its "NDVI (peak)" title actually claims). Caveats section rewritten: no-mine-crop masking note replaces the cropland-masking note, and the "own-hex effects have no spillover interpretation" caveat now notes they DO carry a narrow within-hex spillover interpretation under `nominecrop`. **Added 2026-07-08 (5th revision, user-driven): `OUTCOMES` narrowed to EVI peak (max) only, 3 masks** — `evi_modis_veg_narrow_max` (new HEADLINE), `evi_modis_nominecrop_max`, `evi_modis_cropland_max` (dropped NDVI entirely, dropped mean variants, dropped the unmasked overall columns). `veg_narrow`'s definition (union of `b_03a_vi_panel.R`'s `CCI_MASKS$cropland` {10,11,12,20,30} and `CCI_MASKS$forest` {50,60,61,62,70,90} — "dense cropland + tree cover only", nests `cropland ⊂ veg_narrow ⊂ veg_broad`) written out in prose directly above the `outcomes-setup` chunk. `mbar_grid` changed from `c(0,10,25,50)` to `c(0,5,10)` (Q0b); `v2_dynplot()`/`v2_thresh_cols` updated to the 3-threshold palette to match (previously hardcoded mbar_25/mbar_50 lookups would have errored against the new grid). All headline lookups (`q0a-plot`, `q0b-plot`, panelview outcome/completeness column, `Q0B_MBAR` representative-threshold constant) repointed to `evi_modis_veg_narrow_max`; `Q0B_MBAR` changed 25→10. **Added 2026-07-08 (6th revision, user-driven): NDVI added back alongside EVI** — `OUTCOMES` now 6 columns, peak-only, {NDVI,EVI} x {veg_narrow, no-mine-crop, cropland}; `evi_modis_veg_narrow_max` stays the headline (listed first; all hardcoded lookups unchanged). Re-added the "NDVI vs EVI ATT magnitudes not directly comparable" caveat (dropped during the EVI-only revision, needed again now both indices are mixed in the all-outcomes overlay plots) and fixed a stale caveat line that still referenced "the overall/unmasked outcomes in OUTCOMES" (no longer exist). **Added 2026-07-08 (7th revision, user-driven): `q0b-plot` now produces one `v2_dynplot` (0/5/10 ha stock-threshold overlay) PER MASK** — `veg_narrow` (kept, same `es_q0b_headline.png` filename/title), `nominecrop` (new, `es_q0b_nominecrop.png`), `cropland` (new, `es_q0b_cropland.png`) — all on the headline EVI (peak) index, via a `q0b_mask_specs` list + `imap()` loop; `p_q0b_headline` still points at the veg_narrow plot for any downstream reference. "Two versions" prose fixed to say `mbar_grid` (0/5/10 ha) instead of the stale 0/10/25/50 and now mentions the per-mask breakdown. The existing all-outcomes-at-one-threshold plot (`p_q0b_outcomes`, `Q0B_MBAR = 5`) is unchanged. **Added 2026-07-08 (8th revision): replaced the single combined all-outcomes plot (`p_q0b_outcomes`, one plot mixing all 6 outcomes at `Q0B_MBAR=5`) with a new `q0b-outcome-plots` chunk (`results='asis'`) producing one plot per (threshold × mask) — 2 thresholds (`Q0B_MBARS <- range(mbar_grid)`, currently 0 and 10 ha, the endpoints rather than the single middle value) × 3 masks = 6 plots, each overlaying only the NDVI/EVI pair within that mask** (rather than all 6 outcomes across 3 masks on one axis, which made cross-index comparison hard). Fully derived from `OUTCOMES`/`mbar_grid` — an `outcome_meta` tibble parses each outcome column into `{index, mask, stat}` components (mirrors the `vi-missingness` chunk's parser) and the mbar/mask loops read off `mbar_grid`'s range and the parsed mask set, so this needs no hardcoded column names and adapts automatically if `OUTCOMES`/`mbar_grid` change again. Saves `es_q0b_outcomes_mbar{0,10}_{mask}.png` (6 files). Fixed a caveat-section reference to the now-removed `p_q0b_outcomes` object to describe the new per-mask structure instead. Not yet knitted. **Added 2026-07-08 (9th revision, user-driven): Q0a (onset-clock design, no threshold) DELETED entirely** — `q0a-fit`/`q0a-plot` chunks and the `first_treat_own`-based fit removed, since Q0a was judged redundant with Q0b's `mbar=0` case (which already captures any own-hex onset); the "Two versions" intro prose replaced with a single "Design" paragraph. **Panelview generalised to all 3 `mbar_grid` thresholds** — `panelview-thresholds` chunk now builds `pv_specs` programmatically from a `pv_mbar_grid <- c(0,5,10)` literal (was hardcoded to just mbar=0 and mbar=10), giving 3 panelviews total (`es_q0_panelview_own_mbar{0,5,10}.png`) instead of 2. **`q0b-outcome-plots` chunk changed from `Q0B_MBARS <- range(mbar_grid)` (endpoints only, 0/10) to `Q0B_MBARS <- mbar_grid`** (all three thresholds) — now produces 3 masks × 3 thresholds = 9 outcome-comparison plots (was 6). **Added a new dCDH (`did_multiplegt_dyn`) section** — `## dCDH — continuous dose (own_stock_ha)`, mirroring `_2.Rmd`'s V1 dCDH battery but simplified to Q0's single treatment dimension (`own_stock_ha`, no upstream/downstream/lateral split, no full-vs-censored panel split since own-hex stock IS the treatment being tested): `HAS_DCDH` guard (same `DIDmultiplegtDYN`+`polars`-attached pattern as `_2.Rmd`) added to the `setup` chunk, one `did_multiplegt_dyn` fit per outcome (`q0-dcdh` chunk), one event-study plot per outcome (`q0-dcdh-plot`, `es_q0_dcdh_{outcome}.png`), and a compact ATE/p(pre-trend)/p(effects)/switchers summary table (`q0-dcdh-table`, `es_q0_dcdh_summary.md`) — plus a `q0-dcdh-guard` chunk printing a skip notice when the packages aren't installed. Caveats section updated: removed the now-stale `p_q0a_outcomes`/Q0a references, added the `HAS_DCDH` package-footprint line (mirroring `_2.Rmd`), and updated the "trimmed package set" caveat to note DIDmultiplegtDYN/polars are now conditionally used. Not yet knitted.
│   ├── a_05_event_study_2.Rmd      ← in progress (created 23/06 as the combined `a_05_event_study.Rmd`; split out as `_2` 2026-07-08): IMPLEMENTS Q1 — upstream mining → downstream vegetation, reads event_panel_{N}km.rds. History (all as the combined file, pre-split): Added 2026-06-29 the "Conceptual framework — neighbour definitions" schematic (inherited from a_02 D2e-Schematic; later five-group). Q1 = V2 (C&S absorbing, up_stock_ha threshold sweep mbar∈{0,10,25,50}, headline) + V3 (mechanism: upstream clock censored to pre-own-entry + downstream placebo + T_own−T_up gap) + V1 (feols distributed-lag on up_new_ha + downstream placebo + optional did_multiplegt_dyn dose) + V3b (faithful tex two-clock TWFE, added 2026-07-01). C&S via did::att_gt/aggte, not-yet-treated; SEs clustered on 25km block_id until 2026-07-06, then real HydroBASINS level-9 `basin_num` (from d_07_hydrobasins.R) with the old stand-in as fallback. UPDATED 2026-06-30: V1 dCDH fixed (needs `library(polars)` — DIDmultiplegtDYN 2.3.0 uses bare `pl` without importing it) + full-vs-censored event-study plots + compact ATE/p(pre-trend)/p(effects)/switchers summary table; V2c REMOVED. UPDATED 2026-07-01: panelview section (per-(exposure,threshold) panelviews at mbar∈{0,25}); v2_dynplot() helper; static-export layer (save_es()/save_md()/tidy_feols_md()) — every headline figure/table also written to outputs/figures/event_study/. UPDATED 2026-07-02: multi-outcome looping integrated directly into V1–V3b (OUTCOMES = NDVI/EVI × {cropland, no-mine-crop, forest, veg-broad} × {max, mean}; ndvi_modis_cropland_max stays headline with unchanged filenames, other outcomes get per-outcome exports / combined alloutcomes tables+plots). NOT run at full multi-outcome scale (up to ~60 dCDH runs) — execution explicitly deferred; knit still pending as of the 2026-07-08 split. **UPDATED 2026-07-13: cumulative "≤3 hops" exposures + interactive overlays.** Added `derive-le3` chunk (after `load-panel`) building `up_le3_*` (treatment) and `down_le3_*` (placebo) as the rowSums of the three disjoint ring stocks + pmin of ring onsets (Inf→NA); added both to the `EXPOSURES` table + `exposure_cols` palette, so the whole C&S sweep / overall table / composition table / overlays pick them up automatically. Motivated by `ring1_dominance_diagnostic.R` (new): ring-1 dominance of the within-3 clock falls 57%→27% as mbar 0→20, and at mbar≥10 ~⅓ of treated hexes are invisible to the 1-hop definition — so the cumulative treatment is a genuinely different design at higher thresholds, not a dose rescaling. **Made the section-4.2 exposure/threshold overlays interactive**: `dyn_overlay_interactive()` wraps the ggplot with `plotly::ggplotly()` + a legendgroup fix (one legend click toggles a whole exposure's ribbon/line/points; double-click isolates), displayed via `show_overlay()` (governed by new `INTERACTIVE` flag); static PNGs still exported for the deck from the underlying ggplot. plotly.js injected once via the `widget-dep` chunk; widgets emitted as `htmltools::renderTags()$html` inside the existing `results='asis'` tabset loops. VERIFIED by full 5km knit (17.9 min): 28 interactive widgets, 0 static fallbacks, le3 exposures flow through legends+tables, composition counts sane. Cumulative def currently lives only in `_2.Rmd`; promote to `b_03e` if `_2b` dCDH / other Q-files need it. **UPDATED 2026-07-13 (2nd): never-mined-themselves restricted sample.** Added `## Restricted sample — hexes never mined themselves` subsection under Estimator 1 (after Threshold stability): re-runs the C&S sweep on `panel_clean = filter(is.na(own_onset_year))` so a surviving upstream ATT is clean downstream spillover, not the hex's own clearing (hex-level complement to the pixel-level nominecrop mask). All exposures + both routings + full mbar sweep, headline veg_narrow outcome only. Chunks `cs-fit-clean`/`cs-clean-table`/`cs-clean-overlay` (interactive overlay via `show_overlay`); exports `es_q1_cs_overall_cleansample.md` + `es_q1_cs_expoverlay_clean_*.png`. Validated 5km: 3348→2696 hexes (652 self-mined dropped); at mbar=10 clean-sample treated hexes = 26 (1-hop) vs 81 (≤3 hops) vs 182 (all-reachable) — the cumulative def is what keeps the treatment estimable on the thin clean sample. The 3-hop cumulative half of the request was already satisfied by the EXPOSURES edit (it flows through the whole Estimator-1 sweep).
│   ├── a_05_event_study_3.Rmd      ← in progress: **SPLIT OUT 2026-07-08** from the combined `a_05_event_study.Rmd` (history above, under `_2`) AND **restored to working order** — Q2 (neighbour mining → own mining, D2d upgraded) had been fully disabled (HTML-commented + `eval=FALSE` on every chunk) since 2026-06-30 while Q1 was the active focus; all chunks are live again in this file. Contents: naïve D2d TWFE reproduction (own_new_ha ~ adj_stock_lag) + directed upstream-onset→own_new_ha C&S headline w/ downstream placebo (the clean diffusion test) + adjacency-onset benchmark (symmetric) + onset-hazard TWFE LPM. Not yet re-run/re-reviewed since restoration — treat first knit as provisional.
│   ├── a_06_dataset_panel.R        ← TODO: file not yet created
│   ├── cluster_se_diagnostic.R     ← done (created 2026-07-08, run by user same day): standalone diagnostic, not part of the a_NN_* pipeline / not sourced by anything. Refits Q0a (own-hex onset → own-hex NDVI, `first_treat_own`, `did::att_gt`) three times on the 5km panel under `clustervars =` `main_basin` (42 clusters, then-current `run_cs()` default) / `basin_num` (280 clusters, HydroBASINS level-9) / a reconstructed old 25km centroid-block stand-in. **Confirmed the hypothesis**: at event_time==2, ATT was identical across specs (-0.0164) but SE was 0.161 (main_basin) vs 0.038 (basin_num) vs 0.033 (old block) — a ~4-5x inflation. `reach_e2` breakdown: 1,690 hexes reach e=+2; main_basin touched 34/43 of its clusters (79%, actually the highest coverage ratio of the three) but 2 basins (1090023660, 1090023770) held 78.8% of those hexes between them → effective cluster count (inverse-Herfindahl) ≈3, not 34 — severe size imbalance, not sparse coverage, breaks the multiplier bootstrap. basin_num (138 clusters touch the cell) and old_block (87) have no comparably dominant cluster. **Result: `run_cs()`'s `clustervars` default fixed 2026-07-08 from `"main_basin"` to `"block_num"`** in all three a_05_event_study_*.Rmd files (see those entries + `event_study_design.md` SE-clustering section). Also includes a quick faceted map of all three cluster assignments (`outputs/figures/event_study/cluster_se_diagnostic_map.png`). **Note 2026-07-08 (later same day):** `a_05_event_study_1.Rmd` briefly had its `run_cs()` default changed to the literal `"basin_num"` (by the user, directly in the Rmd) instead of `"block_num"`; reverted back to `"block_num"` for consistency with `_2.Rmd`/`_3.Rmd` and to keep the 1km graceful-fallback behavior (raw `basin_num` is all-NA at 1km, since `d_07_hydrobasins.R` hasn't been run there — `block_num` degrades to the centroid-block stand-in instead of erroring).
│   ├── mask_missingness_e2_diagnostic.R ← todo (created 2026-07-08, not yet run): standalone diagnostic, not part of the a_NN_* pipeline / not sourced by anything. Follow-up to `cluster_se_diagnostic.R` — user reports event_time==2 is STILL noisy for the current `evi_modis_veg_narrow_max`/`evi_modis_cropland_max` outcomes even under `block_num` clustering, and asked whether switching the HydroBASINS download (`d_01_download_gee.R` Sec 6b) to level 10/11 would help. This script separates two possible mechanisms that call for opposite remedies: (A) cluster CONCENTRATION (same failure mode as the main_basin problem, recurring at smaller scale — finer basins might help, but risk fragmenting into hex-sized singleton basins, which level 9 already has 18 of at 5km, degenerating cluster-robust inference toward none) vs (B) MASK-DRIVEN SMALL-N (cropland ~3.6-9.5% NA / veg_narrow ~1.3-2.2% NA vs nominecrop's ~0.1% NA — `run_cs()` drops non-finite outcome rows before fitting, so a high-NA mask can shrink the usable e=+2 sample regardless of cluster count; no re-basinning fixes this). For each of the 3 EVI masks, on the same `first_treat_own` design: reports ELIGIBLE hexes at e=+2 (cohort-based, mask-independent), USABLE hexes (also non-NA on that outcome — mask-dependent), distinct/effective `block_num` clusters among USABLE hexes only, and the actual fitted SE at e=+2 plus the full event-time SE profile for context. Defaults to the 2km panel (matching the Rmd's `params$resolution_km` default); change `RES` to 5 for the primary grid. User will run it themselves.
│   └── ring1_dominance_diagnostic.R ← done (created + run 2026-07-13): standalone diagnostic, not part of the a_NN_* pipeline. For each mbar in {0,5,10,20}, classifies within-3-hop upstream-treated hexes by what trips the cumulative-stock threshold — ring 1 alone (le3 onset == 1-hop onset), rings 2-3 advance the clock (aggregate crosses earlier), or rings 2-3 create the treatment (ring 1 never crosses). RESULT (5km): ring-1 dominance falls 56.9%→27.5% as mbar 0→20; at mbar≥10 ~⅓ of treated hexes are invisible to the 1-hop definition and another ~⅓ have their onset pulled earlier by rings 2-3 → the cumulative `up_le3` treatment is a genuinely different design at higher thresholds, not a dose rescaling. Reconciles the changelog's earlier "74.3%" figure as the same statistic on the conditional (ring-1-ever-mines) denominator. Justifies the `up_le3_*`/`down_le3_*` exposures added to `a_05_event_study_2.Rmd` same day. Result table also in `event_study_design.md` (hop-ring caveat point 2).
├── 4_presentation/
│   ├── galamsey_motivation.qmd     ← UPDATED 2026-07-01: Part 4 event-study methodology sequence added (logic → neighbour-roles schematic → NEW "Three Ways to Capture Rivers" [OSM / MERIT upa-channels / MERIT D8 flow dir] → MERIT flow direction → channel filter & upstream exposure → hex×year panel → 3 versions). Figures rebalanced to dominant right column; land-use-channel example + panel controls list added. Clickable figures (fig.link → full-size annex slides) + min-width:0 CSS fix for side-by-side. UPDATED 2026-07-01: added event-study RESULTS section (tex order) — composition table, upstream panelviews (mbar 0/25), V1 dCDH plot+table (TWFE omitted from deck), V2 upstream/lateral/downstream plots + stability table; 4 new annex slides. V3/V3b result slides still TODO; needs an `a_05_event_study_2.Rmd` (Q1) knit for the es_* artifacts to appear (`a_05_event_study.Rmd` split into `_1`/`_2`/`_3` 2026-07-08 — see `code/3_analysis/` entries above)
│   ├── galamsey_motivation_slides.tex
│   └── galamsey_motivation.html
```

---

## Status Key

| Symbol | Meaning |
|--------|---------|
| `done` | Script exists and output produced |
| `in progress` | Script started, not finalized |
| `todo` | Not yet started |
| `blocked` | Waiting on data or upstream task |

---

## Part 1 — Remote Sensing Pipeline

**Goal:** Produce an annual mine-presence raster/panel for all of Ghana, 1995–2025.

**Current data:** Barenblitt et al. (2021) shapefiles — SW Ghana, 2007–2017 (annual time series) + full 2019 extent. Used as training labels for the classifier.

| ID | Task | Status | Script |
|----|------|--------|--------|
| RS1 | Download Landsat 5/7/8/9 imagery via GEE (1995–2025, all Ghana) | in progress | `rs01_landsat_gee.R` |
| RS2 | Download Sentinel-2 imagery via GEE (2017–2025, all Ghana) | in progress | `rs02_sentinel2_gee.R` |
| RS3 | Compute spectral indices (NDVI, MNDWI, BSI, bare-soil bands) per year | todo | `rs03_spectral_indices.R` |
| RS4 | Train Random Forest classifier using Barenblitt labels as ground truth | todo | `rs04_classification.R` |
| RS5 | AlphaEarth embedding classifier: training samples + RF + annual probability maps 2017–2024 | in progress | `rs05_embedding_classifier.R` |
| RS6 | Spatial CV + accuracy assessment for embedding classifier (by district) | todo | `rs06_embedding_validation.R` |
| RS7 | Threshold probability maps → binary mine presence panel (hex / district × year) | todo | `rs07_embedding_panel.R` |

---

## Part 2 — Descriptives & Analysis

**Current data:** Barenblitt shapefiles (SW Ghana, 2007–2019) + Girard gold-suitability layers.
**Eventual data:** Extended RS panel from Part 1 (all Ghana, 1995–2025).

> Scripts in this section should be written to accept a `mine_data` input so the data source can be swapped from Barenblitt to the RS panel without rewriting analysis code.

---

### Section 0 — Instrument Validity (First Stage)

| ID | Task | Status | Script |
|----|------|--------|--------|
| D0a | First-stage regression: does gold-suitable geology (Girard) predict actual mining presence (Barenblitt)? LPM at 1 km pixel level, SEs clustered by district | removed | _superseded by the hex first stage in `a_02_spatial_clustering.R` (D2c-FS) + `2_build/b_03_firststage_models.R`_ |
| D0b | Residual map: pixels with more/less mining than geology alone predicts | removed | _superseded by `a_02_spatial_clustering.R` + `2_build/b_03_firststage_models.R`_ |

---

### Section 1.1 — Incidence of Galamsey (1995–2025)

*Key years: 2000, 2010, 2021 (census). Current Barenblitt coverage: 2007–2019, SW Ghana.*

| ID | Task | Status | Script |
|----|------|--------|--------|
| D1a | Small-multiple maps + animated GIFs: cumulative/annual mining extent (hex5km + hex10km + districts, all years) | done | `a_01_incidence_maps.R` |
| D1b | Map: artisanal vs industrial side-by-side choropleth (hex5km + hex10km + districts, 2019 extent) | done | `a_01_incidence_maps.R` |
| D1c | Time-series graphs: national cumulative land-cover fraction; unit shares; annual flows by top units (districts) | done | `a_01_incidence_maps.R` |
| D1d | Summary stats + top-20 extent bar (districts) + national series vs gold price | done | `a_01_incidence_maps.R` |
| D1e | Lorenz curve: concentration of galamsey across districts (cumulative share of districts vs share of total mining extent) | in progress | `a_01_incidence_maps.R` |

---

### Section 1.2 — Spatial Clustering and Expansion of Galamsey

*See `methodology.md` for full procedure notes and results.*

| ID | Task | Status | Script |
|----|------|--------|--------|
| D2a | Global Moran's I time series (annual new mining, 2007–2017); patchwork composite with annual conversion bars | done | `a_02_spatial_clustering.R` |
| D2b | Moran's I: raw → geology-controlled → geology+river-controlled (3-way comparison table) | done | `a_02_spatial_clustering.R` |
| D2bc | Geography-weighted null: decompose observed Moran's I (0.488) into geography-explained vs excess (~18× above joint null 95th pct) | done | `a_02_spatial_clustering.R` |
| D2c-FS | First-stage LPM: dist_river_km + gold_suit_share → any mine presence; CSV + tex/md tables now include joint robust-Wald F-stat (significance ≠ predictive strength) | done | `a_02_spatial_clustering.R` |
| D2d | Spatial lag regression: cumulative neighbour stock at t−1 predicts new mining at t (hex + year FE; both ha and LPM significant at p < 10⁻¹³) | done | `a_02_spatial_clustering.R` |
| D2d-Asym | Asymmetric spatial lag: DROPPED 2026-06-29 — northing proxy unreliable for Ghana's river network; directional claims delegated to a_05 (MERIT D8) | removed | `a_02_spatial_clustering.R` |
| D2e | Upstream vs downstream spread along rivers — bar chart at leads 1–3; downstream > upstream at leads 2–3 | done | `a_02_spatial_clustering.R` |
| D2e-Perm | Permutation test for D2e: DROPPED 2026-06-29 — formalises a badly-proxied quantity; rigorous test belongs in a_05 | removed | `a_02_spatial_clustering.R` |
| D2f | Event study: mean cumulative mining in upstream vs downstream neighbours ±3 yrs around focal onset; normalised to t = −1 | done | `a_02_spatial_clustering.R` |
| D2bc-M5 | M5 robustness test: extend first-stage to M4 + s(easting_km, northing_km); check residual Moran's I and null p_excess at 5 km to address omitted-geography and residual-autocorrelation critiques. PASSED at k=60 & k=100 (p_excess=0). The d03d test script (now removed) had full diagnostics (deviance explained, coef survival, concurvity, k.check, surface/SE maps, gam.check, spatial-scale, spatial-block CV); the result is documented in CHANGELOG/18_06_session. INTEGRATED into 2_build/b_03_firststage_models.R (compute_m5, 5km + 2km) + a_03_firststage_diagnostics.Rmd Part C (lean: stats, null distribution, residual Moran's I, surface map, gap discussion) | in progress | `2_build/b_03_firststage_models.R` + `a_03_firststage_diagnostics.Rmd` |

---

### Section 2 — Motivating Facts

#### 2.1 What Triggers Expansion of Galamsey?

| ID | Task | Status | Script |
|----|------|--------|--------|
| D3a | National galamsey trend vs gold price time series | done | `a_04_motivating_facts.R` |
| D3b | Event-study: does galamsey expansion coincide with climate shocks? | blocked | `a_04_motivating_facts.R` |
| D3c | Does galamsey begin/accelerate after first gold mine appears in an area? | blocked | `a_04_motivating_facts.R` |

#### 2.2 Is There Reversion from Galamsey?

| ID | Task | Status | Script |
|----|------|--------|--------|
| D4a | Do areas that transition to galamsey eventually revert? | blocked | `a_04_motivating_facts.R` |
| D4b | Event-time plot: galamsey land share by district around year of first mine | done | `a_04_motivating_facts.R` |

#### 2.3 Does Galamsey Impact Agricultural Productivity?

| ID | Task | Status | Script |
|----|------|--------|--------|
| D5a | NDVI/EVI binned scatter vs distance to nearest mine (0.5 km bins, n-weighted LOESS) | done | `a_04_motivating_facts.R` |
| D5b | Event study: NDVI/EVI around mine onset, normalised to t = −1, by distance band (Mine/0–1/1–5/5–20 km) | done | `a_04_motivating_facts.R` |
| D5c | Cocoa yields (COCOBOD data) around galamsey areas | blocked | `a_04_motivating_facts.R` |

#### 2.4 Does Galamsey Shift Labor Away from Agriculture?

| ID | Task | Status | Script |
|----|------|--------|--------|
| D6a | Does formal/urban employment rise commensurately in high-galamsey districts? | blocked | `a_04_motivating_facts.R` |
| D6b | Is there an increase in people reporting (formal) mining employment? | blocked | `a_04_motivating_facts.R` |
| D6c | Ultimately: is labor moving into informal mining? | blocked | `a_04_motivating_facts.R` |

---

### Section 3 — Constructing a Dataset

| ID | Task | Status | Script |
|----|------|--------|--------|
| D7a | Construct hexagon (1–3km) or 2010 enumeration-area panel with land-use variables | todo | `a_06_dataset_panel.R` |
| D7b | Include mining intensity and agricultural intensity (NDVI/EVI) over time | todo | `a_06_dataset_panel.R` |
| D7c | Merge census variables: labor allocation, wealth, population density (2000, 2010, 2021) | todo | `a_06_dataset_panel.R` |

---

## Data Inventory

*Full dataset notes (including caveats and methodology) are in `data_inventory.md`.*

| Dataset | Temporal Coverage | Status |
|---------|-------------------|--------|
| Barenblitt et al. (2021) — annual mining extent | 2007–2017 | available |
| Barenblitt et al. (2021) — full mining extent 2019 | 2019 | available |
| Girard et al. (2022) — gold-suitable geology (polygon + PRIO-Grid) | static | available |
| Ghana admin boundaries (admin0/1/2) | — | available |
| OSM waterways | — | available |
| Landsat 5/7/8/9 via GEE | 1995–2025 | in progress |
| Sentinel-2 via GEE | 2017–2025 | in progress |
| Landsat Annual NDVI + EVI (250 m composites) | 1995–2025 | in progress |
| MODIS MOD13Q1 NDVI + EVI (250 m, 16-day → annual mean, QA-masked) | 2000–2025 | in progress |
| MODIS MCD12Q1 Land Cover Type 1 — IGBP (500 m, annual) | 2001–2024 | in progress |
| ESA CCI Land Cover — UN-LCCS (300 m, annual, via Digital Earth Africa) | 1995–2022 | downloaded + stacked |
| CHIRPS v2.0 rainfall | 1990–2025 | in progress |
| Ghana Mining Repository 2025 — licenses (KML + Excel) | 2025 snapshot | available — needs investigation |
| Ghana census microdata | 2000, 2010, 2021 | not yet acquired |
| COCOBOD cocoa yields | TBD | not yet acquired |
| Gold price index | 1995–2025 | not yet acquired |
| GLSS 7 (Ghana Living Standards Survey) | 2016/17 | not yet acquired |

---

*Last updated: 2026-06-26 — b_03_event_panel.R superseded by four modular scripts (b_03a–d); each writes a persistent .rds to data/processed/ so components can be rebuilt independently in a new R session. b_03_event_panel.R retained for reference.*

*Last updated: 2026-06-25 — code reorganised + renamed: `0_data/` → `d_NN_*`; `3_analysis/` split into `build/` (`b_NN_*`, artifact builders) and top-level `a_NN_*` (analysis/output). Deleted obsolete scripts `data_inventory.R`, `3_other/first_stage.R`, `d03d_m5_smoother_test.R`. Data-artifact filenames (e.g. `hex_5km_crosssection.rds`) intentionally unchanged. Scripts coordinate via data artifacts, not `source()`. Pending: split the still-hybrid `a_02_spatial_clustering.R` build half into `2_build/b_02_hex_frame.R` (needs an interactive R verification run).*

*Earlier (2026-06-11): tasklist restructured — data inventory moved to `data_inventory.md`; methodology notes moved to `methodology.md`; presentation moved to `code/4_presentation/`.*
