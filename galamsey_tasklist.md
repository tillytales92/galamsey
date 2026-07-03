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
     area for each outcome — replaces the current MODIS MCD12Q1 mask (see below).
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
    a named-list config at the top of the reworked b_03a. Blocked on the ESA CCI download (below).
  - Justification given: peak EVI correlates strongly with gross primary production (Shi et al. 2017)
    and crop yields (Azzari et al. 2017; Johnson 2016).
  - **Robustness checks to also implement:** alternative land-use masks (**Digital Earth Africa
    2022**) and alternative aggregation schemes (e.g. mean vs. max, different windows).
  - **Implementation note:** this restructures `b_03a_vi_panel.R` non-trivially — it currently just
    extracts an already-annual, GEE-side-aggregated raster. The new pipeline needs either (a) 16-day
    composites downloaded/exported from GEE and zonal-meaned per hex per 16-day period locally, then
    maxed to annual; or (b) the per-16-day zonal mean done server-side in GEE before export. Scope
    before implementing — also ripples into `b_03e_assemble_eventpanel.R`.
- [ ] **Switch land cover to ESA CCI** (needed for step 3 of the peak-EVI pipeline above, not just
  a `*_forestcrop` fix). MODIS MCD12Q1 under-detects forest in the study area (~6–11% of land pixels
  classified as Evergreen Broadleaf Forest, driving ~80% NA in the `*_forestcrop` VI columns) and
  the local stack currently stops at 2020. ESA CCI (Defourny et al. 2024, 300 m, yearly) is the
  specified replacement (see `data_inventory.md` §7) — needs downloading, not yet in `d_01`.
  PARTIAL 2026-07-03: download notebook `0_data/download_land_cover_ghana.ipynb` drafted (DE Africa
  STAC `cci_landcover`, 1992–2022, via pystac-client/odc-stac; no GEE). Study area = **Ankobra
  river basin proxy** built from the OSM waterways lines (connected Ankobra network → 5 km-buffered
  convex hull; bbox ≈ 2.45–1.77°W, 4.85–6.48°N); saves `data/raw/land_cover/cci_landcover_ankobra_{year}.tif`.
  Not yet run — notebook Python env is missing its packages (`requirements.txt`).
- [ ] Re-download / re-stack the missing 2021–2024 MODIS land-cover layers (`d_01_download_gee.R`
  Sec 9) — `LCOVER_YEARS = 2001:2024` is requested but `modis_lc_ghana_stack.tif` only has
  2001–2020.
- [ ] Acquire a historical mine-licence register with issue dates (Minerals Commission / PMMC) —
  needed for D3c below.
- [ ] Wire CHIRPS rainfall into the D3b climate-shock trigger analysis (downloaded, not yet used).
- [ ] Acquire COCOBOD cocoa yields (D5c), census microdata / GLSS 7 (D6a–c) — see
  `data_inventory.md` §11 for candidate open-data substitutes (nightlights, WorldPop, RWI, DHS).

### Remote Sensing (`code/1_remote_sensing/`)

- [ ] **Review the Barenblitt et al. GitHub classification code**
  ([abarenblitt/GhanaArtisanalMining](https://github.com/abarenblitt/GhanaArtisanalMining)) —
  cross-check its methodology (training sample selection, RF specification, artisanal/industrial
  split) against the `rs05` AlphaEarth embedding classifier.
- [ ] **Review Africa Mining Watch data** (`data/raw/africa_mining_watch_early_data/`) — compare
  its early ML detections against Barenblitt and the AlphaEarth classifier as a validation/ensemble
  source.
- [ ] RS6 — spatial cross-validation (by district) for the embedding classifier (todo below).
- [ ] RS7 — threshold probability maps into a binary presence panel (todo below).

### Build (`code/2_build/`)

- [ ] Run `b_03a_vi_panel.R` under the current modular pipeline structure (slow — ~4–5h at 1 km).
- [ ] Extend the MERIT D8 hex flow graph beyond the current study-area clip to all of Ghana.
- [ ] Replace the 25 km centroid-block SE-clustering stand-in with a real sub-basin ID
  (HydroBASINS or MERIT `upa` pour-points) — flagged throughout `event_study_design.md`.

### Analysis (`code/3_analysis/`)

- [ ] **Re-run the event-study results once the updated NDVI/EVI measures are available.**
  `a_05_event_study.Rmd` currently loops over NDVI/EVI × {base, no-mine-crop, forest-crop} built
  from the MODIS land-cover mask; once the Digital Earth Africa / ESA-CCI-based masks and
  aggregation-scheme robustness pipeline above are in place, the outcome definitions will change
  and every Q1 design (V1–V3b) needs to be refit against the revised measures. See
  `4_presentation/methodology_explainer.md` §9 for what each design shows.
- [ ] Knit `a_05_event_study.Rmd` at least once with the current (pre-revision) outcomes — the
  multi-outcome integration is written but not yet executed (compute-heavy; deferred).
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
  results are shown) — needs a fresh `a_05` knit for the `es_v3*` artifacts to exist.
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
│   └── d_03_waterways.R          ← in progress: UPDATED 2026-06-25 — Sec 0b: timestamped download to data/raw/shapefiles/osm_extracts/waterways_ghana_YYYY-MM-DD.gpkg; skips download if timestamped file exists (FORCE_DOWNLOAD=FALSE default). Sec 0c: filters to natural watercourses (NATURAL_WATERWAYS incl. flowline) → writes data/processed/waterways/waterways_natural.shp (pipeline input for b_01_cross_section + a_01 + a_02). PREREQUISITE for b_01_cross_section. Secs 1–7 EDA unchanged. Sec 8 (added 2026-06-29): named OSM rivers (waterway=="river") merged per river + 5 km galamsey hexes (artisanal ha, plasma sqrt fill) overlaid; rivers drawn on top for overlap legibility; labels for rivers >15 km; saves outputs/figures/maps/waterways_galamsey_map.png; guards on hex_5km_crosssection.rds + mining_extent_by_hex5km_2019.csv. Not yet run
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
│   ├── b_03a_vi_panel.R                ← todo: VI extraction component. Writes hex_{N}km_vi_panel.rds — tibble(hex_id, year, 12 VI cols). Raster zonal means (overall/forest-crop/no-mine × Landsat+MODIS × NDVI+EVI) per hex per year. Slow (~4–5h at 1km). Re-run only when GEE rasters change. Not yet run under new modular structure.
│   ├── b_03b_own_mining.R              ← done: Own-hex + adjacency mining component. Writes hex_{N}km_own_mining.rds — tibble(hex_id, year, own_new_ha, adj_new_ha) covering all hexes × 2007:2017. Run 2026-06-26; all three resolutions complete.
│   ├── b_03c_flow_graph.R              ← done: D8 hex flow graph builder. Loops over RESOLUTIONS c(1,2,5); traces D8 channel cells on native 4326 MERIT grid; nets bidirectional pairs; removes feedback arcs → DAG. Writes hex_flow_edges_{N}km.csv + hex_downstreamness_{N}km.csv. Run 2026-06-26; all three resolutions complete.
│   ├── b_03d_flow_exposure.R           ← done: Upstream/downstream flow exposure component. Writes hex_{N}km_flow_exposure.rds — tibble(hex_id, year, up_new_ha, down_new_ha, nearest_up_new_ha, nearest_down_new_ha, lateral_new_ha, nearest_up_onset_year, nearest_down_onset_year). Run 2026-06-26 (session 2): all three resolutions complete. 1km: 3,689 hexes with upstream mining / 8,759 downstream / 2,516 lateral. 2km: 1,920/4,679/1,698. 5km: 829/2,170/1,016.
│   ├── b_03e_assemble_eventpanel.R     ← done: Final assembly. Reads vi_panel + own_mining + flow_exposure + crosssection (covariates). Expands to full year spine, computes all stock+onset columns, adds C&S bookkeeping. Writes event_panel_{N}km.{csv,rds}. Run 2026-06-26 (session 2): all three resolutions complete with flow graph populated. Columns include nearest_up_stock_ha, nearest_down_stock_ha, lateral_stock_ha, lateral_onset_year.
├── 3_analysis/
│   ├── a_01_incidence_maps.R       ← in progress: D1a–D1e implemented; D1a–D1d outputs produced; D1e (Lorenz) code written, not yet run. Map waterways now filtered to natural watercourses only (drop canal/drain/ditch), matching d03. Writes data/processed/n_surveyed_districts.rds (nrow of survey_districts_sf) for galamsey_motivation.qmd to read — avoids heavy spatial ops in the presentation setup chunk
│   ├── a_02_spatial_clustering.R   ← in progress: REFACTORED 2026-06-25 — build half removed (Secs 1-4, ~220 lines; was duplicating b_01_cross_section). Now reads hex_5km_crosssection.rds + mining_timeseries_by_hex5km_long.csv from b_01_cross_section. D2a–D2e all implemented (D2f event-study DELETED — moved to a_05). D2d-Asym + D2e-Perm DELETED 2026-06-29 (northing proxy unreliable; superseded by a_05 MERIT estimates). D2e-Schematic moved to a_05_event_study.Rmd. Reads waterways_natural.shp from processed/. MUST re-run b_01_cross_section first
│   ├── a_03_firststage_diagnostics.Rmd ← in progress: presentation layer, fully restructured. Reads d03_maup_results.rds; renders Part A (fit ladder × grid: AUC table+plot, full metrics) + Part B (geography-weighted null × grid: p_excess table+plot) + NEW Part C (M5 spatial-spline null @5km & 2km: intro on what the spline does/how it differs, stats table w/ Hex(km) col, M4-vs-M5 null-draw distribution vs observed Moran's I FACETED by resolution, residual Moran's I table, mining-propensity-net-of-covariates surface map FACETED by resolution, discussion of the obs–null gap = contagion vs non-smooth sub-grid covariate) + Appendix. Interpretation gained an M5 bullet. Old Tests 1–4 / Fix 1–5 sections removed. Not yet knitted (needs d03c run first)
│   ├── a_04_motivating_facts.R     ← in progress: D3a, D5a, D5b outputs produced; D3b/D3c/D4a/D5c/D6a-c blocked on data. D4b hex-build DELETED 2026-06-25 (moved to a_05 via b_03_event_panel)
│   ├── a_05_event_study.Rmd        ← in progress (created 23/06): IMPLEMENTS the event study, reads event_panel_5km.rds. Added 2026-06-29: "Conceptual framework — neighbour definitions" section with two-group schematic (inherited from a_02 D2e-Schematic) + TODO comment for five-group MERIT extension (upstream-all, nearest-up, lateral, nearest-down, downstream-all). Q1 upstream→NDVI = V2 (C&S absorbing, up_stock_ha threshold sweep mbar∈{0,10,25,50}, headline) + V3 (mechanism: upstream clock censored to pre-own-entry + downstream placebo + T_own−T_up gap) + V1 (feols distributed-lag on up_new_ha + downstream placebo + optional did_multiplegt_dyn dose). Q2 neighbour→own-mining (D2d upgraded) = naïve D2d TWFE reproduction (own_new_ha ~ adj_stock_lag) + directed upstream-onset→own_new_ha C&S headline w/ downstream placebo + adjacency-onset benchmark + onset-hazard TWFE LPM. C&S via did::att_gt/aggte, not-yet-treated, SEs clustered on 25km block_id (sub-basin stand-in — TODO real basin id). Guards: has_upstream skips Q1 if flow edges absent; HAS_DCDH for DIDmultiplegtDYN. Not yet knitted. UPDATED 2026-06-30: schematic now five-group (upstream-all/1-hop, lateral, downstream-1-hop/all via st_intersects with river); V1 dCDH fixed (needs library(polars) — DIDmultiplegtDYN 2.3.0 uses bare `pl` without importing it) + replaced text dump with 5 full-vs-censored event-study plots + compact summary table (ATE, p(pre-trend), p(effects), switchers); V2 dynamic plots now overlay mbar∈{10,25,50} thresholds; V2c REMOVED; Q2 COMMENTED OUT (HTML comment + eval=FALSE on all chunks); V3 upstream clock reworked → nearest 1-hop upstream onset is headline (tex T_i^UP), all-reachable demoted to robustness, gap diag uses T_own−T_nearest_up; control-groups chunk + candidate-controls prose deleted. UPDATED 2026-07-01: schematic now saved to outputs/figures/event_study/d2e_schematic.png (was spatial_clustering/); panelview section reworked → per-(exposure,threshold) panelviews at mbar∈{0,25} for up_stock_ha + nearest_up_stock_ha (full panel only; censored dropped, rendering issue TODO); V2 plots refactored into v2_dynplot() helper (added mbar=0 ">0 ha" curve; outline-only CI ribbons); added Version 3b (faithful tex two-clock TWFE: feols i(k_own,ref=-1)+i(j_up,ref=-1) → β/δ decomposition, es_v3b_twoclock.png/es_v3b_coefficients.md); added static-export layer — save_es()/save_md() helpers + tidy_feols_md(); every headline figure/table also written to outputs/figures/event_study/ (V1 flowlag/joint/dCDH, V2 5 dynamic plots + stability table, V3 3 plots + gap + table, composition table, panelviews, overlap window) for the presentation deck; export-manifest chunk added. UPDATED 2026-07-02 (2nd revision): multi-outcome looping INTEGRATED directly into the main V1-V3b code blocks (no longer a separate "Outcome robustness" section, which was deleted). New `outcomes-setup` chunk (right after load-panel) defines OUTCOMES = {ndvi_modis, evi_modis, ndvi_modis_nominecrop, evi_modis_nominecrop, ndvi_modis_forestcrop, evi_modis_forestcrop} (kept only if present/non-all-NA) + extra_outcomes = OUTCOMES minus the NDVI headline. Every Q1 design now loops over OUTCOMES: V1 1b/1c (make_dl generalized to d_<outcome> via across(); NDVI headline etable()+filenames UNCHANGED, other outcomes get their own etable() [print()'d inside a for loop] + per-outcome .md exports); V1 dCDH (run_dcdh() takes a yname arg; dcdh_extra_full/dcdh_extra_cens nested outcome->dim lists; NDVI headline unchanged; other outcomes' plots under results='asis' subheaders, summary table in a new q1-v1-dcdh-table-alloutcomes chunk grouped by outcome+treatment); V2 (new run_v2_exposures()/v2_rows_from_exposures() helpers; NDVI headline v2_up/v2_near_up/etc + 5 plots UNCHANGED; new q1-v2-alloutcomes chunk builds a combined stability table across all outcomes [es_v2_stability_table_alloutcomes.md] + q1-v2-outcome-plots adds 2 outcome-overlay plots at mbar=25 [es_v2_outcomes_{upstream,downstream}.png] using new outcome_dynplot() helper); V3 (new run_v3_defs()/v3_rows_from_defs() helpers; NDVI headline v3_nearest/v3_up/etc UNCHANGED; new q1-v3-alloutcomes[-plots] chunks add a combined table [es_v3_results_table_alloutcomes.md] + per-outcome ggdid() plots under subheaders); V3b (fit_v3b() now takes yname; NDVI headline unchanged; new q1-v3b-alloutcomes chunk builds ONE combined plot faceted outcome(rows) x clock(cols) [es_v3b_twoclock_alloutcomes.png]). All existing NDVI-only filenames the presentation deck depends on are preserved unchanged; new outputs use _<outcome> or _alloutcomes suffixes. Verified via knitr::purl()+parse() (syntax-only, no execution per user instruction) + manual definition-before-use ordering checks (extra_outcomes, run_v2_exposures, run_v3_defs, censored, has_nearest all confirmed defined before first use) + no duplicate chunk labels (41 chunks total). NOT run — will take substantially longer than the NDVI-only version (up to ~60 dCDH runs); user explicitly deferred execution
│   └── a_06_dataset_panel.R        ← TODO: file not yet created
├── 4_presentation/
│   ├── galamsey_motivation.qmd     ← UPDATED 2026-07-01: Part 4 event-study methodology sequence added (logic → neighbour-roles schematic → NEW "Three Ways to Capture Rivers" [OSM / MERIT upa-channels / MERIT D8 flow dir] → MERIT flow direction → channel filter & upstream exposure → hex×year panel → 3 versions). Figures rebalanced to dominant right column; land-use-channel example + panel controls list added. Clickable figures (fig.link → full-size annex slides) + min-width:0 CSS fix for side-by-side. UPDATED 2026-07-01: added event-study RESULTS section (tex order) — composition table, upstream panelviews (mbar 0/25), V1 dCDH plot+table (TWFE omitted from deck), V2 upstream/lateral/downstream plots + stability table; 4 new annex slides. V3/V3b result slides still TODO; needs a_05 knit for the es_* artifacts to appear
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
