# validate_fp_source_breakdown.R
# Step 0 of notes/2026-09-07_build03_fp_postprocessing_plan.md -- REWORKED 2026-09-08 into a
# CUTOFF SWEEP, and with the two FP-source layers the first pass was missing (see
# notes/2026-09-07_mask_overflagging_findings.md: 83% of flagged area landed in "unexplained"
# only because there was no roads layer and urban was GHSL>2000 alone).
#
# What it does now: mosaics build_02's mine_prob_ghana_c4_{YEAR}_t{NN} PROBABILITY tiles (not the
# post-cutoff mine_mask_ghana_c4_{YEAR} asset), then for each cutoff in CUTOFFS thresholds the
# mosaic and overlays the flagged set against candidate FP-source layers, reporting at SCALE m
# over Ghana:
#   - total flagged km2
#   - OVERLAPPING breakdown : flagged km2 (and % of total) in each category. Categories overlap
#     (a pixel can be both "river" and "seasonal water"), so these do NOT sum to 100%.
#   - DISJOINT breakdown    : each flagged pixel assigned to its first-matching category in a
#     fixed priority order. Sums to 100%. This is the actionable one.
#   - unexplained flagged area, split north / south of the Barenblitt convex hull, AND further
#     decomposed by Dynamic World annual land cover (bare / crops / trees / grass / shrub / ...).
#     DW land cover is DIAGNOSTIC ONLY -- not a maskable category (we would never mask cropland);
#     it just tells us what the diffuse unexplained remainder physically is. NB: DW's "built" and
#     "bare" classes are known to over-fire on mine sites and dry exposed soil, so a large
#     unexpl_dw:bare / unexpl_dw:built share may be DW co-confused with our classifier, not proof.
#   - reference rows: flagged km2 the current Barenblitt minetype==2 exclusion removes, and
#     (when INCLUDE_LEASES) flagged km2 inside Minerals-Commission large-scale leases.
#
# Categories (priority order, = disjoint assignment order):
#   water_perm       JRC GSW occurrence >= 75, buffered (also absorbs the coastline edge)
#   water_seas       25 < occurrence < 75
#   river            MERIT Hydro width >= 30 m, buffered
#   road             GRIP4 Africa roads, buffered  (or a local OSM extract via ROADS_SOURCE="local")
#   urban_ghsl       GHSL BUILT_S (epoch nearest YEAR) built_surface > 2000  <- what build_03 masks NOW
#   urban_ghsl_ring  GHSL 1000-2000  <- the increment if the build_03 threshold drops 2000 -> 1000
#   urban_dw         Dynamic World annual mean P(built) > DW_BUILT_MIN       <- INDEPENDENT 10 m check
#   industrial       large-scale mining leases (OFF by default -- sf_as_ee issue, see the note)
# The three urban rows are nested (>2000, then the 1000-2000 ring, then DW-only) and ranked so each
# disjoint bucket is a pure INCREMENT over the ones above it:
#   urban_ghsl       = already masked
#   urban_ghsl_ring  = extra flagged area a 10% threshold would remove (2000 was set 2026-08-18 to
#                      spare Kumasi/Accra edges + near-settlement mines -- price the ring first)
#   urban_dw         = built-up per Dynamic World that NEITHER GHSL band catches (residual/peri-urban
#                      the current mask leaves in). That quantity is the whole reason for this rerun.
#
# Output: outputs/tables/fp_source_breakdown_{YEAR}.csv (LONG: one row per cutoff x category)
#         + a console table, a disjoint-km2 pivot (category x cutoff), and a DW-land-cover pivot
#         of the unexplained remainder (class x cutoff).
#
# Run INTERACTIVELY -- ee_Authenticate() / ee_Initialize() block on a browser login.
# Prerequisite: build_02_embedding_classifier.R Section 10 exported mine_prob_ghana_c4_{YEAR}_t*.

#### 1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, sf, here, tidyverse, janitor, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, here::here
)

UTM30N        <- 32630
EE_PROJECT    <- "rgee-auth-tillam"                       # ID, never the numeric project number
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)

#### 2. Parameters ####
YEAR    <- 2022L
SCALE   <- 100L                                           # reduceRegion scale (m); QA used 100 m
CUTOFFS <- c(45L, 55L, 60L, 70L, 80L)                     # probability thresholds to sweep

FINAL_SCHEME <- "c4"
PROB_PREFIX  <- sprintf("mine_prob_ghana_%s_", FINAL_SCHEME)   # build_02 Section 10 export prefix
TILE_KM      <- 150                                       # MUST match the build_02 run being read

# buffers (metres)
WATER_PERM_BUF_M <- 150      # also absorbs the coastline edge (open ocean is not in JRC GSW, but
                             #   coastal GSW-permanent water is, and the edge pixel is within ~150 m)
RIVER_BUF_M      <- 120      # riparian zone around major rivers
ROAD_BUF_M       <- 35

# thresholds
GSW_PERM_MIN    <- 75L       # JRC GSW occurrence (%) for "permanent"
GSW_SEAS_MIN    <- 25L       # 25 < occurrence <= 75 -> "seasonal"
MERIT_WTH_MIN   <- 30        # MERIT Hydro river width (m) to count as a "major" river
GHSL_BUILT_MIN  <- 2000      # built_surface (of 10000) ~= 20% built -- what build_03 masks NOW
GHSL_RING_MIN   <- 1000      # 10-20% built ring: what lowering the build_03 threshold to 1000 adds.
                             #   Kept as a SEPARATE category so the sweep prices the ring before
                             #   any build_03 change -- 2000 was set 2026-08-18 to spare Kumasi/
                             #   Accra edges + near-settlement mines; the 2026-09-07 plan wants the
                             #   ring measured first (see project_4class_urban_confusion).
DW_BUILT_MIN    <- 0.20      # Dynamic World annual mean P(built); 0.2 ~ "built-up in >=1/5 obs"

# Roads -------------------------------------------------------------------------------------------
# "grip4" : ee.FeatureCollection GRIP4 Africa (sat-io community catalog). Native, reproducible,
#           but ~2018 vintage and thin on minor/laterite rural roads -- treat the road km2 as a
#           LOWER bound. If the asset id 404s, check awesome-gee-community-datasets for the current
#           GRIP4 path, or switch to "local".
# "local" : point ROADS_PATH at a downloaded OSM roads layer (geofabrik gis_osm_roads_free_1.shp,
#           or an oex `roads` export matching how data/raw/shapefiles/osm_waterways was made).
# "none"  : skip the roads category.
ROADS_SOURCE    <- "grip4"
GRIP4_ASSET     <- "projects/sat-io/open-datasets/GRIP4/Africa"
ROADS_PATH      <- NA_character_
ROADS_CLASS_COL <- NULL      # e.g. "fclass" (geofabrik) / "highway" (raw OSM); NULL = use all rows
ROADS_KEEP      <- c("motorway", "trunk", "primary", "secondary", "tertiary", "unclassified",
                     "residential", "track",
                     "motorway_link", "trunk_link", "primary_link", "secondary_link")

# Minerals Commission large-scale leases (industrial-exclusion rework candidate), from d_12.
# Left OFF -- sf_as_ee on the lease polygons throws a TypeError; revisit separately. The
# Barenblitt minetype==2 reference row (a shapefile, works fine) still runs regardless.
INCLUDE_LEASES <- FALSE
LEASES_PATH    <- here("data", "processed", "mining_repository", "active_licenses_clean.gpkg")
LEASE_TYPES    <- c("Mining Lease", "Restricted Mining Lease")

BARENBLITT_SHP <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")

out_csv <- here("outputs", "tables", sprintf("fp_source_breakdown_%d.csv", YEAR))
dir.create(dirname(out_csv), recursive = TRUE, showWarnings = FALSE)

#### 3. Authenticate ####
ee_Authenticate()
ee_Initialize(drive = TRUE, project = EE_PROJECT)
ee_check()

#### 4. Helpers + base layers ####
ghana <- ee$FeatureCollection(file.path(EE_ASSET_HOME, "rs05_ghana"))$geometry()
pxkm2 <- ee$Image$pixelArea()$divide(1e6)$rename("area")  # km2 per pixel

out_ee_ok <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)

sum_km2 <- function(binary_img, region = ghana) {
  v <- pxkm2$updateMask(binary_img)$reduceRegion(
    reducer = ee$Reducer$sum(), geometry = region, scale = SCALE,
    maxPixels = 1e13, bestEffort = FALSE, tileScale = 4
  )$get("area")$getInfo()
  if (is.null(v)) 0 else as.numeric(v)
}

# km2 of `binary_img` broken down by the annual dominant Dynamic World class (`dw_label_mode`,
# built in Section 6). Returns a tibble (dw_class, km2). Pixels with no DW observation in YEAR are
# dropped by the updateMask -> the caller reports the shortfall vs the total as "(no DW obs)".
dw_decomp <- function(binary_img, region = ghana) {
  g <- pxkm2$addBands(dw_label_mode$updateMask(binary_img))$reduceRegion(
    reducer  = ee$Reducer$sum()$group(groupField = 1L, groupName = "dw"),
    geometry = region, scale = SCALE, maxPixels = 1e13, bestEffort = FALSE, tileScale = 4
  )$getInfo()
  map_dfr(g$groups, ~ tibble(dw_class = DW_CLASS[as.character(.x$dw)], km2 = .x$sum))
}

# geometry-only sf -> ee. Drops every attribute column (date cols with NAs / list-cols crash
# sf_as_ee -- see CLAUDE.md), drops empty geoms, forces a plain EPSG:4326 CRS. Caller must have
# already transformed x to lon/lat.
geom_as_ee <- function(x) {
  g <- st_zm(st_geometry(x), drop = TRUE)
  g <- g[!st_is_empty(g)]
  sfx <- st_sf(geometry = g)
  st_crs(sfx) <- st_crs(4326)
  sf_as_ee(sfx)
}

buf <- function(binary_img, metres) {
  binary_img$unmask(0)$focal_max(radius = metres, kernelType = "circle", units = "meters")$gt(0)
}

#### 5. Probability mosaic (rebuild the build_02 export tile grid, mirror build_03 Section 4) ####
ghana_utm <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin",
                          "gha_admin0.shp"), quiet = TRUE) |>
  select(geometry) |>
  st_make_valid() |>
  st_union() |>
  st_transform(UTM30N) |>
  st_simplify(dTolerance = 100)

tile_grid_utm <- st_make_grid(ghana_utm, cellsize = TILE_KM * 1000, square = TRUE)
tiles_utm     <- tile_grid_utm[lengths(st_intersects(tile_grid_utm, ghana_utm)) > 0]
tile_ids      <- sprintf("t%02d", seq_along(tiles_utm))
message(sprintf("Reconstructed %d tiles at TILE_KM=%d", length(tile_ids), TILE_KM))

assetIds <- file.path(EE_ASSET_HOME, sprintf("%s%d_%s", PROB_PREFIX, YEAR, tile_ids))
present  <- keep(assetIds, out_ee_ok)
if (length(present) == 0)
  stop(sprintf("no %s prob tiles found for %d -- has build_02 Section 10 finished?", FINAL_SCHEME, YEAR))
if (length(present) < length(assetIds))
  warning(sprintf("%d/%d prob tiles missing for %d -- mosaic will have gaps",
                  length(assetIds) - length(present), length(assetIds), YEAR))
prob <- ee$ImageCollection(as.list(present))$mosaic()$rename("mine_prob")   # 0-100 uint8

#### 6. Candidate FP-source category masks (cutoff-independent -- built ONCE) ####
gsw <- ee$Image("JRC/GSW1_4/GlobalSurfaceWater")$select("occurrence")$unmask(0)
cat_water_perm <- buf(gsw$gte(GSW_PERM_MIN), WATER_PERM_BUF_M)
cat_water_seas <- gsw$gt(GSW_SEAS_MIN)$And(gsw$lt(GSW_PERM_MIN))

merit_wth <- ee$Image("MERIT/Hydro/v1_0_1")$select("wth")$unmask(0)
cat_river <- buf(merit_wth$gte(MERIT_WTH_MIN), RIVER_BUF_M)

# -- roads --
cat_road <- NULL
if (ROADS_SOURCE == "grip4") {
  grip      <- ee$FeatureCollection(GRIP4_ASSET)$filterBounds(ghana)
  roads_img <- ee$Image()$byte()$paint(featureCollection = grip, color = 1)$unmask(0)
  cat_road  <- buf(roads_img$gt(0), ROAD_BUF_M)
  message(sprintf("roads: GRIP4 Africa filtered to Ghana bounds, buffered %d m (LOWER bound -- thin on rural roads)", ROAD_BUF_M))
} else if (ROADS_SOURCE == "local" && !is.na(ROADS_PATH)) {
  roads_sf <- st_read(Sys.glob(ROADS_PATH)[1], quiet = TRUE) |> st_zm(drop = TRUE)
  if (!is.null(ROADS_CLASS_COL) && ROADS_CLASS_COL %in% names(roads_sf))
    roads_sf <- roads_sf[roads_sf[[ROADS_CLASS_COL]] %in% ROADS_KEEP, ]
  roads_sf <- roads_sf |> st_transform(4326) |> st_simplify(dTolerance = 20) |> st_make_valid()
  message(sprintf("roads: local layer, %d features after filtering/simplifying", nrow(roads_sf)))
  roads_img <- ee$Image()$byte()$paint(featureCollection = geom_as_ee(roads_sf), color = 1)$unmask(0)
  cat_road  <- buf(roads_img$gt(0), ROAD_BUF_M)
} else {
  message("roads category skipped (ROADS_SOURCE = 'none' or ROADS_PATH unset)")
}

# -- urban: GHSL epoch-matched. Two categories: the >2000 mask build_03 applies now, and the
#    1000-2000 ring that lowering the threshold to 1000 would add (priced separately, see header) --
GHSL_EPOCHS <- seq(1975L, 2025L, 5L)
ghsl_epoch  <- GHSL_EPOCHS[which.min(abs(YEAR - GHSL_EPOCHS))]
message(sprintf("urban_ghsl: GHSL BUILT_S epoch %d (nearest to %d); >%d masked now, %d-%d ring priced separately",
                ghsl_epoch, YEAR, GHSL_BUILT_MIN, GHSL_RING_MIN, GHSL_BUILT_MIN))
ghsl_built <- ee$ImageCollection("JRC/GHSL/P2023A/GHS_BUILT_S")$
  filterDate(sprintf("%d-01-01", ghsl_epoch), sprintf("%d-01-01", ghsl_epoch + 1L))$
  first()$select("built_surface")
cat_urban_ghsl      <- ghsl_built$gt(GHSL_BUILT_MIN)
cat_urban_ghsl_ring <- ghsl_built$gt(GHSL_RING_MIN)$And(ghsl_built$lte(GHSL_BUILT_MIN))

# -- urban: Dynamic World annual mean P(built), independent 10 m cross-check --
dw_ic <- ee$ImageCollection("GOOGLE/DYNAMICWORLD/V1")$
  filterDate(sprintf("%d-01-01", YEAR), sprintf("%d-01-01", YEAR + 1L))$
  filterBounds(ghana)

dw_built     <- dw_ic$select("built")$mean()$unmask(0)
cat_urban_dw <- dw_built$gt(DW_BUILT_MIN)
message(sprintf("urban_dw: Dynamic World %d mean P(built) > %.2f", YEAR, DW_BUILT_MIN))

# annual dominant DW class per pixel (mode of the per-scene `label` band) -- for the diagnostic
# decomposition of the unexplained remainder in Section 9. Class ints per the DW band spec.
dw_label_mode <- dw_ic$select("label")$mode()$rename("dw")
DW_CLASS <- c("0" = "water", "1" = "trees", "2" = "grass", "3" = "flooded_veg",
              "4" = "crops", "5" = "shrub_scrub", "6" = "built", "7" = "bare",
              "8" = "snow_ice")

# -- large-scale mining leases (OFF for now) --
cat_lease <- NULL
if (INCLUDE_LEASES && file.exists(LEASES_PATH)) {
  leases_sf <- st_read(LEASES_PATH, quiet = TRUE)
  if ("type_simplified" %in% names(leases_sf))
    leases_sf <- leases_sf[leases_sf$type_simplified %in% LEASE_TYPES, ]
  leases_sf <- leases_sf |>
    st_zm(drop = TRUE) |> st_make_valid() |> st_cast("MULTIPOLYGON", warn = FALSE) |>
    st_transform(4326)
  leases_sf <- leases_sf[!st_is_empty(leases_sf), ]
  message(sprintf("large-scale leases: %d polygons", nrow(leases_sf)))
  cat_lease <- ee$Image()$byte()$paint(featureCollection = geom_as_ee(leases_sf), color = 1)$
    unmask(0)$gt(0)
} else {
  message("INCLUDE_LEASES is FALSE (or gpkg missing) -- skipping the industrial/leases category")
}

#### 7. Ordered category list ####
cats <- list(
  water_perm      = cat_water_perm,
  water_seas      = cat_water_seas,
  river           = cat_river,
  road            = cat_road,
  urban_ghsl      = cat_urban_ghsl,       # GHSL >2000  -- masked by build_03 now
  urban_ghsl_ring = cat_urban_ghsl_ring,  # GHSL 1000-2000 -- increment if threshold drops to 1000
  urban_dw        = cat_urban_dw,         # Dynamic World built that neither GHSL band catches
  industrial      = cat_lease
)
cats <- cats[!map_lgl(cats, is.null)]
message("categories in play (priority order): ", paste(names(cats), collapse = " > "))
cls_name <- c("0" = "unexplained", setNames(names(cats), as.character(seq_along(cats))))

#### 8. Barenblitt hull + industrial reference layer ####
bar_all <- st_read(BARENBLITT_SHP, quiet = TRUE) |> st_make_valid() |> clean_names()

# convex hull only -- st_combine (merge, no topological union) + s2 off avoids the degenerate-edge
# error st_union hits on the raw Barenblitt polygons.
old_s2 <- sf_use_s2(); suppressMessages(sf_use_s2(FALSE))
bar_hull <- bar_all |> st_geometry() |> st_combine() |> st_convex_hull() |> st_transform(4326)
suppressMessages(sf_use_s2(old_s2))
bar_hull_ee <- geom_as_ee(bar_hull)$geometry()

bar_ind_sf  <- bar_all |> filter(mine_type == 2) |> st_transform(4326)
bar_ind_img <- ee$Image()$byte()$paint(featureCollection = geom_as_ee(bar_ind_sf), color = 1)$unmask(0)$gt(0)

#### 9. Per-cutoff breakdown ####
breakdown_for_cutoff <- function(cut) {
  message(sprintf("--- cutoff %d ---", cut))
  mine_bin  <- prob$gte(cut)$selfMask()                 # 1 = flagged, else masked
  total_km2 <- sum_km2(mine_bin)

  overlap_km2 <- map_dbl(cats, ~ sum_km2(mine_bin$updateMask(.x$gt(0))))

  disjoint <- mine_bin$unmask(0)$multiply(0)$rename("cls")
  for (i in seq_along(cats))
    disjoint <- disjoint$where(disjoint$eq(0L)$And(cats[[i]]$gt(0)), i)
  disjoint <- disjoint$updateMask(mine_bin)             # 0 = unexplained, 1..k = category index

  grouped <- pxkm2$addBands(disjoint)$reduceRegion(
    reducer  = ee$Reducer$sum()$group(groupField = 1L, groupName = "cls"),
    geometry = ghana, scale = SCALE, maxPixels = 1e13, bestEffort = FALSE, tileScale = 4
  )$getInfo()
  disj <- map_dfr(grouped$groups, ~ tibble(cls = .x$cls, disjoint_km2 = .x$sum)) |>
    mutate(category = cls_name[as.character(cls)]) |>
    select(category, disjoint_km2)

  unexpl_img   <- disjoint$eq(0L)$updateMask(mine_bin)
  unexpl_total <- sum_km2(unexpl_img)
  unexpl_south <- sum_km2(unexpl_img, region = bar_hull_ee)
  unexpl_north <- unexpl_total - unexpl_south

  # DW land-cover decomposition of the unexplained remainder (diagnostic only)
  dw_u <- dw_decomp(unexpl_img) |> arrange(desc(km2))
  dw_no_obs <- unexpl_total - sum(dw_u$km2)
  dw_rows <- bind_rows(
    dw_u |> transmute(category = paste0("  unexpl_dw: ", dw_class), overlap_km2 = km2),
    tibble(category = "  unexpl_dw: (no DW obs)", overlap_km2 = dw_no_obs)
  ) |> mutate(disjoint_km2 = NA_real_)

  flagged_in_bar_ind <- sum_km2(mine_bin$updateMask(bar_ind_img))
  flagged_in_leases  <- if (!is.null(cat_lease)) sum_km2(mine_bin$updateMask(cat_lease$gt(0))) else NA_real_

  cat_rows <- tibble(category = names(cats), overlap_km2 = as.numeric(overlap_km2)) |>
    left_join(disj, by = "category") |>
    mutate(disjoint_km2 = replace_na(disjoint_km2, 0))

  extra <- bind_rows(
    tibble(
      category = c("unexplained", "  unexplained_south_of_barenblitt",
                   "  unexplained_north_of_barenblitt"),
      overlap_km2  = c(unexpl_total, unexpl_south, unexpl_north),
      disjoint_km2 = c(unexpl_total, NA_real_, NA_real_)
    ),
    dw_rows,
    tibble(
      category = c("TOTAL_flagged", "ref: flagged in Barenblitt minetype==2",
                   "ref: flagged in large-scale leases"),
      overlap_km2  = c(total_km2, flagged_in_bar_ind, flagged_in_leases),
      disjoint_km2 = NA_real_
    )
  )

  bind_rows(cat_rows, extra) |>
    mutate(cutoff       = cut,
           overlap_pct  = 100 * overlap_km2  / total_km2,
           disjoint_pct = 100 * disjoint_km2 / total_km2) |>
    select(cutoff, category, overlap_km2, disjoint_km2, overlap_pct, disjoint_pct)
}

res <- map_dfr(CUTOFFS, breakdown_for_cutoff)
write_csv(res, out_csv)

#### 10. Console report ####
cat(sprintf("\n=== FP-source breakdown, mine_prob_ghana_c4_%d, %d m, cutoff sweep ===\n", YEAR, SCALE))
res |>
  mutate(across(where(is.numeric), ~ round(.x, 2))) |>
  as.data.frame() |>
  print(row.names = FALSE)

cat("\n--- disjoint km2 pivot (category x cutoff; category rows sum to TOTAL_flagged per cutoff) ---\n")
res |>
  filter(category %in% c(names(cats), "unexplained")) |>
  select(cutoff, category, disjoint_km2) |>
  bind_rows(res |> filter(category == "TOTAL_flagged") |>
              transmute(cutoff, category, disjoint_km2 = overlap_km2)) |>
  pivot_wider(names_from = cutoff, values_from = disjoint_km2, names_prefix = "cut") |>
  mutate(across(where(is.numeric), ~ round(.x, 1))) |>
  as.data.frame() |>
  print(row.names = FALSE)

cat("\n--- DW land cover of the UNEXPLAINED remainder (km2, and % of unexplained, by cutoff) ---\n")
unexpl_by_cut <- res |> filter(category == "unexplained") |> select(cutoff, unexpl = overlap_km2)
res |>
  filter(str_starts(category, "  unexpl_dw: ")) |>
  mutate(dw_class = str_remove(category, "  unexpl_dw: ")) |>
  left_join(unexpl_by_cut, by = "cutoff") |>
  mutate(val = sprintf("%.0f (%.0f%%)", overlap_km2, 100 * overlap_km2 / unexpl)) |>
  select(cutoff, dw_class, val) |>
  pivot_wider(names_from = cutoff, values_from = val, names_prefix = "cut") |>
  as.data.frame() |>
  print(row.names = FALSE)

cat(sprintf("\nWrote %s\n", out_csv))
cat("\nReading it (disjoint rows, each a pure increment over the ones above):\n",
    " urban_ghsl      = already masked by build_03\n",
    " urban_ghsl_ring = extra area a 2000->1000 GHSL threshold would remove\n",
    " urban_dw        = built-up per Dynamic World that NEITHER GHSL band catches\n",
    " road            = GRIP4-attributable (LOWER bound -- thin on rural roads)\n",
    " unexplained     = none of the above; watch it shrink across the cutoff sweep vs the named rows\n",
    " unexpl_dw:*     = what Dynamic World calls the unexplained remainder. bare/built here may be\n",
    "                   DW co-confused with our classifier on dry soil / mine sites -- not proof of FP;\n",
    "                   a big crops/trees share is stronger evidence of genuine farmland/veg FP.\n",
    sep = "")
