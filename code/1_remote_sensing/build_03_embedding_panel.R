# build_03_embedding_panel.R  — SKETCH, NOT YET RUN
# Postprocessing for build_02_embedding_classifier.R's c4/no_maus probability maps: mosaic each
# year's export tiles, threshold, mask out urban confusion, (eventually) filter small/inconsistent
# patches, exclude industrial mining, and persist a clean annual MINE MASK per year, 2017-2025.
#
# SCOPE NOTE (2026-08-19): this script's output stops at the annual 2017-2025 mine mask. It does
# NOT aggregate to the hex x year panel -- that was the plan's original Step 8, but the user
# pointed out build_04_backdating_prototype.js (CCDC onset-year dating, 2000-2016) has to run
# BEFORE aggregation, not after: build_04 extends this same "ever mined" mask backward to
# 2000-2016 (mine_onset_year_2000_2016), and the hex x year panel needs to be built from the
# MERGED 2000-2025 surface, not just 2017-2025. So the pipeline is now:
#   build_02 (train/export c4 probability tiles)
#     -> build_03 (THIS script: threshold/mask/filter -> annual 2017-2025 mine mask)
#     -> build_04 (CCDC backdate the 2017-2025 mask -> onset years for 2000-2016; needs
#        reworking first -- it still reads the OLD pre-tiling binary asset names
#        mine_prob_ghana_{yr}, not this script's output or build_02's new tiled c4 assets)
#     -> [not yet named] merge 2000-2016 onset years + 2017-2025 direct annual masks into one
#        continuous surface, THEN aggregate to the hex x year panel (b_01_cross_section-style grid)
#
# STATUS: Sections 1-4 (setup, tile-grid rebuild, mosaic, threshold) and Section 7 (industrial
# exclusion) are real, runnable logic. Section 5 (GHSL 100m mask) ports validate_true_mines_
# urban_mask_100m.js's tested nearestEpochYear()/builtSurfaceForYear() logic into R. Sections 6a
# (min-patch-size) and 6b (temporal-consistency) are DELIBERATELY STUBBED (guarded off by their
# APPLY_* flags below) -- min-patch-size needs validate_min_patch_size_filter.js run first to pick
# an actual MIN_PATCH_SIZE, and the temporal-consistency rule has never been designed past "require
# >=2 consecutive years." Nothing downstream depends on either yet, so this script is runnable
# end-to-end today as a v0 (cutoff + GHSL mask + industrial exclusion only) and upgradeable in
# place once those two land.
#
# Run INTERACTIVELY: ee_Authenticate()/ee_Initialize() block on a browser login. Prerequisite:
# build_02_embedding_classifier.R Section 10 has completed (or partially completed -- Section 3
# below warns about missing tiles per year rather than failing outright).

####1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, tidyverse, sf, here, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  here::here
)

UTM30N <- 32630
EE_PROJECT <- "rgee-auth-tillam"   # see build_02 Section 1 -- ID, never the numeric project number

####2. Authenticate ####
rgee::ee_Authenticate()
rgee::ee_Initialize(drive = TRUE, project = EE_PROJECT)
ee_check()

####3. Parameters ####

EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
FINAL_SCHEME  <- "c4"
PROB_PREFIX   <- sprintf("mine_prob_ghana_%s_", FINAL_SCHEME)   # build_02 Section 10's export prefix
MASK_PREFIX   <- sprintf("mine_mask_ghana_%s_", FINAL_SCHEME)   # this script's output prefix
EMBED_YEARS   <- 2017:2025
EXPORT_SCALE  <- 10L

CUTOFF                    <- 45L     # settled 2026-08-18, see project_4class_urban_confusion memory
URBAN_THRESHOLD_100M      <- 2000    # out of 10000 -- rescaled 20%-built equivalent of the 10m
                                      # product's threshold 20 (out of 100), confirmed in
                                      # validate_ghsl_100m_epochs.js / validate_true_mines_urban_mask_100m.js
GHSL_100M_EPOCHS          <- c(1975, 1980, 1985, 1990, 1995, 2000, 2005, 2010, 2015, 2020, 2025)
                                      # 2030 excluded -- confirmed likely a projected, not observed, epoch

# TILE_KM MUST MATCH whatever build_02's Section 10a used for the run whose tiles you're reading --
# there's no persisted record of it anywhere else, so if build_02 was re-run with a different
# TILE_KM since, update this to match or the tile-ID reconstruction below won't find the assets.
TILE_KM <- 150

APPLY_MIN_PATCH_FILTER     <- FALSE   # TODO: flip on once validate_min_patch_size_filter.js has run
MIN_PATCH_SIZE             <- NA_real_  # TODO: fill in from that script's result (connectedPixelCount threshold)
APPLY_TEMPORAL_CONSISTENCY <- FALSE   # TODO: rule undesigned past ">=2 consecutive years" -- placeholder only

APPLY_INDUSTRIAL           <- TRUE    # subtract large-scale mining -- see Section 7 (gate + confirm)
IND_LEASES_GPKG    <- here("data", "processed", "mining_repository", "active_licenses_clean.gpkg")
IND_MAUS_GPKG      <- here("data", "raw", "mining_mausetal", "global_mining_polygons_v2.gpkg")
IND_BARENBLITT_SHP <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")

out_ee_ok <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)

####4. Rebuild the export tile grid (must mirror build_02 Section 10a exactly) ####
# Duplicated rather than read from a saved grid, matching this project's convention that scripts
# coordinate through data ARTIFACTS, never by sourcing each other -- ghana_utm is cheap to rebuild
# and the tile grid is a pure function of it + TILE_KM.
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
message(sprintf("Reconstructed %d tiles at TILE_KM=%d (must match the build_02 run being read)",
                length(tile_ids), TILE_KM))

ghana_ee <- ee$FeatureCollection(file.path(EE_ASSET_HOME, "rs05_ghana"))$geometry()

####5. Per-year: mosaic tiles -> threshold -> GHSL 100m mask ####

nearest_epoch_year <- function(yr) GHSL_100M_EPOCHS[which.min(abs(yr - GHSL_100M_EPOCHS))]

built_surface_for_year <- function(yr) {
  epoch <- nearest_epoch_year(yr)
  message(sprintf("  year %d -> nearest GHSL 100m epoch: %d", yr, epoch))
  ee$ImageCollection("JRC/GHSL/P2023A/GHS_BUILT_S")$
    filterDate(sprintf("%d-01-01", epoch), sprintf("%d-01-01", epoch + 1L))$
    first()$select("built_surface")
}

year_mosaic <- function(yr) {
  assetIds <- file.path(EE_ASSET_HOME, sprintf("%s%d_%s", PROB_PREFIX, yr, tile_ids))
  present  <- keep(assetIds, out_ee_ok)
  if (length(present) == 0)
    stop(sprintf("no %s tiles found for %d -- has build_02 Section 10 finished for this year?", FINAL_SCHEME, yr))
  if (length(present) < length(assetIds))
    warning(sprintf("%d/%d tiles missing for %d -- mosaic will have gaps",
                    length(assetIds) - length(present), length(assetIds), yr))
  ee$ImageCollection(as.list(present))$mosaic()$rename("mine_prob")
}

# c4/no_maus's mine_prob band is already the array-extracted, 0-100 uint8 scalar band build_02
# Section 10 wrote (mine_prob_of() + arrayGet() happened at EXPORT time, not here) -- everything
# from here down operates on ordinary scalar images, not the expensive array type that caused the
# 2026-08-19 stuck export. Thresholding/masking a scalar mosaic at national scale should be cheap
# by comparison; if this section turns out slow too, apply build_02 Section 10a's tiling pattern
# here as well.
build_year_mask <- function(yr) {
  message(sprintf("=== %d ===", yr))
  prob_img <- year_mosaic(yr)

  mine_bin <- prob_img$gte(CUTOFF)

  built_100m  <- built_surface_for_year(yr)
  urban_mask  <- built_100m$gt(URBAN_THRESHOLD_100M)   # 1 = urban, mask OUT
  mine_masked <- mine_bin$updateMask(urban_mask$Not())   # $Not() -- 'not' is reserved in Python EE

  # Hybrid rule (mine_prob > urban_prob) DELIBERATELY DROPPED -- confirmed redundant vs. the GHSL
  # mask alone at cutoff 45 (identical result in the Kumasi test, 2026-08-18). Do not reintroduce
  # without re-running that comparison; it would also require Section 10 to export an urban_prob
  # band it currently doesn't.

  if (APPLY_MIN_PATCH_FILTER) {
    stopifnot("MIN_PATCH_SIZE not set -- run validate_min_patch_size_filter.js first" = !is.na(MIN_PATCH_SIZE))
    mine_masked <- mine_masked$updateMask(
      mine_masked$connectedPixelCount(MIN_PATCH_SIZE + 1, FALSE)$gte(MIN_PATCH_SIZE)
    )
  }

  mine_masked
}

year_masks <- map(EMBED_YEARS, build_year_mask) |> set_names(as.character(EMBED_YEARS))

####6. Temporal-consistency rule (placeholder -- rule not yet designed) ####
if (APPLY_TEMPORAL_CONSISTENCY) {
  stop("APPLY_TEMPORAL_CONSISTENCY is on but the rule (>=2 consecutive years?) has never been ",
       "designed past that one sentence -- decide the exact logic (which 2 years? edge behaviour ",
       "at 2017/2025?) before implementing, don't guess it here.")
}
# When this gets designed: probably an ee$ImageCollection$toBands() or explicit pairwise $and()
# over year_masks, keeping a pixel only where it's masked-in in >=2 consecutive years. Left
# unimplemented deliberately.

####7. Industrial-mine exclusion -- (Maus GH U Barenblitt mine_type==2) INT large-scale Mining Leases ####
# Galamsey/artisanal mining is the research target; large-scale operations are subtracted from the
# final mask. The OLD filter (Barenblitt mine_type==2 alone) was SW-Ghana-only and ~50 km2 --
# missing Ahafo/Kenyasi, Chirano, Bibiani and ~1/3 of the big-miner concessions. This "gate +
# confirm" version (chosen 2026-09-08; local analysis in notes/, see project_rs_pipeline_next_steps):
#   gate    = d_12 Minerals Commission "Mining Lease" concessions -- the large-scale class ONLY
#             (NOT "Restricted Mining Lease": that's sand & gravel / <25 acres / small-scale).
#   confirm = a mapped industrial DISTURBANCE footprint inside the gate: Maus et al. 2022 v2
#             (Ghana subset) UNION Barenblitt mine_type==2.
#   exclude where BOTH hold -> ~472 km2 nationally, covers 33/44 major-miner leases, and leaves
#   alone galamsey that sits outside a mapped footprint or outside a granted large-scale lease.
if (APPLY_INDUSTRIAL) {
  ind_old_s2 <- sf_use_s2(); suppressMessages(sf_use_s2(FALSE))   # lease gpkg has degenerate 2-pt rings

  # -> valid, polygon-only, sliver-free (EE's geometry parser rejects 2-point rings, which
  # st_simplify(preserveTopology = FALSE) would otherwise create from tiny concession slivers).
  clean_utm <- function(g, min_m2 = 100) {
    g <- st_make_valid(g)
    if (inherits(g, "sfc")) g <- st_sf(geometry = g)
    if (any(st_geometry_type(g) == "GEOMETRYCOLLECTION"))
      g <- suppressWarnings(st_collection_extract(g, "POLYGON"))
    g <- g[!st_is_empty(g), , drop = FALSE]
    a <- as.numeric(st_area(g)); g <- g[!is.na(a) & a >= min_m2, , drop = FALSE]
    st_make_valid(g)
  }
  diss <- function(g) st_union(st_geometry(clean_utm(g)))

  bar_ind <- st_read(IND_BARENBLITT_SHP, quiet = TRUE) |>
    janitor::clean_names() |> filter(mine_type == 2) |> st_zm(drop = TRUE) |> st_transform(UTM30N)

  maus_lyr <- sf::st_layers(IND_MAUS_GPKG)$name[1]
  maus_gh  <- st_read(IND_MAUS_GPKG, quiet = TRUE,
                      query = sprintf("SELECT * FROM \"%s\" WHERE ISO3_CODE = 'GHA'", maus_lyr)) |>
    st_zm(drop = TRUE) |> st_transform(UTM30N)

  leases <- st_read(IND_LEASES_GPKG, quiet = TRUE) |>
    filter(type_simplified == "Mining Lease") |> st_zm(drop = TRUE) |> st_transform(UTM30N)
  message(sprintf("Industrial: %d Barenblitt-ind + %d Maus-GH polys, %d large-scale Mining Leases",
                  nrow(bar_ind), nrow(maus_gh), nrow(leases)))

  footprint <- st_union(c(diss(maus_gh), diss(bar_ind)))          # Maus U Barenblitt-industrial
  candidate <- st_intersection(footprint, diss(leases)) |>        # gate + confirm
    clean_utm() |> st_geometry() |> st_union() |>
    st_simplify(dTolerance = 20, preserveTopology = TRUE)
  candidate <- clean_utm(candidate) |> st_transform(4326)
  message(sprintf("Industrial-exclusion polygon: %.1f km2",
                  as.numeric(sum(st_area(st_transform(candidate, UTM30N)))) / 1e6))

  suppressMessages(sf_use_s2(ind_old_s2))

  industrial_ee   <- sf_as_ee(candidate)
  industrial_mask <- ee$Image()$byte()$paint(industrial_ee, 1)$unmask(0)$Not()   # 1 = keep, 0 = industrial
  year_masks_final <- map(year_masks, ~ .x$updateMask(industrial_mask))
} else {
  message("APPLY_INDUSTRIAL is FALSE -- no large-scale-mine exclusion")
  year_masks_final <- year_masks
}

####8. Persist the annual mine mask per year (EE assets) ####
# National, single export per year (not tiled -- see the Section 5 comment on why this should be
# cheap now that the array-typed classification cost was already paid at build_02 export time).

FORCE_REEXPORT <- FALSE

export_year_mask <- function(yr) {
  asset_name <- paste0(MASK_PREFIX, yr)
  assetId    <- file.path(EE_ASSET_HOME, asset_name)
  if (out_ee_ok(assetId) && !FORCE_REEXPORT) {
    message(sprintf("  [skip] %s already exists (FORCE_REEXPORT <- TRUE to overwrite)", assetId))
    return(invisible(NULL))
  }
  if (out_ee_ok(assetId)) ee$data$deleteAsset(assetId)
  task <- ee$batch$Export$image$toAsset(
    image            = year_masks_final[[as.character(yr)]]$toUint8(),
    description      = paste0(asset_name, "_asset"),
    assetId          = assetId,
    scale            = EXPORT_SCALE,
    region           = ghana_ee$bounds(),
    crs              = "EPSG:4326",
    maxPixels        = 1e13,
    pyramidingPolicy = list(".default" = "mode")   # categorical 0/1 mask: no averaging
  )
  task$start()
  message(sprintf("  Submitted: %s", assetId))
  task
}

mask_tasks <- map(EMBED_YEARS, export_year_mask)
message(sprintf("\nSubmitted %d/%d annual mine-mask exports.",
                sum(!map_lgl(mask_tasks, is.null)), length(EMBED_YEARS)))
message("Monitor: code.earthengine.google.com -> Tasks tab")

# NEXT (not this script): rework build_04_backdating_prototype.js to read mine_mask_ghana_c4_{yr}
# (this script's output) instead of the stale mine_prob_ghana_{yr} binary-model names it currently
# hardcodes, port it from JS to R, run it to get mine_onset_year_2000_2016, THEN write the
# merge-plus-hex-aggregation script that was originally sketched as this script's Step 8.
