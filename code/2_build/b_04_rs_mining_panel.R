# b_04_rs_mining_panel.R -- SKETCH, still untested against real data. mine_onset_year_2005_2016_
# barenblitt landed 2026-11-05 (code/1_remote_sensing/build_04_backdating.R Section 12) -- this is
# the first real run. HEX_SIZES_KM narrowed to 5 km only below: get one real CSV + confirm column
# names before extending to 2/1 km, where hex counts and the upload chunk size (k=10000, untested
# for polygons) are both unconfirmed.
#
# Builds the RS-derived annual mined-area panel (2005-2025) per hex, the `mine_data` swap-in
# target for Barenblitt referenced throughout 2_build/3_analysis (see
# code/1_remote_sensing/explainer.md). Two sources, stitched by YEAR not by raster grid (10m vs
# 30m seam is irrelevant at hex scale -- decided 2026-11-04):
#   2005-2016: mine_onset_year_2005_2016_barenblitt -- a pixel counts as mined in year Y if
#              onset_year > 0 (dated) and onset_year <= Y (mining treated as persistent forward,
#              never reverting, same assumption the backdating itself relies on).
#   2017-2025: mine_mask_ghana_c4_{yr} directly (already annual binaries).
# Area is computed server-side as sum(pixelArea()) per hex, not pixel-count * fixed cell size --
# robust to the 10m/30m resolution difference without needing a shared grid.
#
# NOT YET DECIDED: whether/how to use the onset layer's confidence bands (reference_tier,
# ndvi_deriv, lt_agree) to filter or flag 2005-2016 area -- deferred until real values exist to
# look at. Currently unfiltered (every onset_year > 0 pixel counts), see MIN_CONFIDENCE below.
#
# Reuses hex_{N}km_crosssection.rds's hex_sf AS-IS (does not rebuild the grid) so hex_id lines up
# with every existing b_01/b_02/b_03/a_NN output.

####0. Parameters ####
HEX_SIZES_KM <- c(5)   # narrowed to the coarsest resolution for the first real run (2026-11-05) --
                        # extend to c(5, 2, 1) once this confirms end-to-end (must match
                        # HEX_SIZES_KM already built by b_01_cross_section.R)
YEARS        <- 2005:2025
MIN_CONFIDENCE <- NULL   # TODO once real data exists: e.g. exclude lt_agree==1 (disagree) from
                          # 2005-2016 area. NULL = no filtering, count every dated pixel.

rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, tidyverse, sf, here, googledrive, conflicted)
conflicts_prefer(dplyr::filter, dplyr::select, dplyr::mutate, here::here)

EE_PROJECT    <- "rgee-auth-tillam"
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
ONSET_ASSET   <- file.path(EE_ASSET_HOME, "mine_onset_year_2005_2016_barenblitt")
MASK_PREFIX   <- "mine_mask_ghana_c4_"
PROC_DIR      <- here("data", "processed")
DRIVE_FOLDER  <- "ghana_mining_gee_exports"

####1. Authenticate ####
ee_Authenticate()
ee_Initialize(drive = TRUE, project = EE_PROJECT)
# ee_Initialize(drive = TRUE) does NOT hand googledrive a working token on its own -- needs its
# own explicit auth call (same pattern as build_02_embedding_classifier.R / d_01_download_gee.R /
# d_04_merit.R), or drive_find()/drive_download() below silently run as the wrong Google account
# (or no account) and return zero matches.
googledrive::drive_auth()

asset_exists <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)
if (!asset_exists(ONSET_ASSET))
  stop(ONSET_ASSET, " not found -- run build_04_backdating.R Section 12 first")

# ee_monitoring() has a known rgee bug (build_04_backdating.R/diag_04_backdating.R/
# diag_05_mining_by_region.qmd): reads destination_uris before a still-RUNNING task has
# populated that field. Reused workaround -- only ever read `state`.
poll_task <- function(task, interval = 15) {
  repeat {
    state <- ee$batch$Task$status(task)[["state"]]
    message("    task state: ", state, " (", format(Sys.time(), "%H:%M:%S"), ")")
    if (state %in% c("COMPLETED", "FAILED", "CANCELLED")) break
    Sys.sleep(interval)
  }
  if (state != "COMPLETED")
    stop("EE task ended in state '", state, "' -- check the Code Editor Tasks tab (project ", EE_PROJECT, ").")
  invisible(state)
}

# Resolve the export folder ONCE and list its contents, rather than a blind drive_find(pattern=)
# over the whole Drive (same idiom as build_02_embedding_classifier.R's score-export fallback) --
# more robust and avoids false/missing matches if the pattern isn't unique Drive-wide.
drive_download_export <- function(name_pattern, dest_path) {
  export_folder <- googledrive::drive_find(pattern = DRIVE_FOLDER, type = "folder", n_max = 1)
  if (nrow(export_folder) == 0)
    stop("Export folder '", DRIVE_FOLDER, "' not found -- check googledrive::drive_user().")
  contents <- googledrive::drive_ls(export_folder[1, ])
  hit <- contents[grepl(name_pattern, contents$name, fixed = TRUE), ]
  if (nrow(hit) == 0) return(invisible(FALSE))
  googledrive::drive_download(hit[1, ], path = dest_path, overwrite = TRUE)
  invisible(TRUE)
}

####2. Annual mined-area image, one band per year (server-side, all of YEARS in one stack) ####
onset_img <- ee$Image(ONSET_ASSET)$select("onset_year")

year_area_band <- function(yr) {
  if (yr <= 2016) {
    mined <- onset_img$gt(0)$And(onset_img$lte(yr))
  } else {
    mask_id <- file.path(EE_ASSET_HOME, paste0(MASK_PREFIX, yr))
    if (!asset_exists(mask_id)) {
      message("  [skip] ", mask_id, " not found -- year ", yr, " will be all-NA in the panel")
      return(NULL)
    }
    mined <- ee$Image(mask_id)$unmask(0)$gt(0)
  }
  mined$multiply(ee$Image$pixelArea())$rename(paste0("y", yr))
}

year_bands  <- Filter(Negate(is.null), lapply(YEARS, year_area_band))
annual_area <- ee$Image$cat(year_bands)

####3. Per hex resolution: upload the EXISTING hex grid, reduceRegions, export ####
for (hex_km in HEX_SIZES_KM) {
  res_tag <- paste0(hex_km, "km")
  message("\n=== hex ", res_tag, " ===")

  cache_path <- here(PROC_DIR, sprintf("hex_%s_crosssection.rds", res_tag))
  if (!file.exists(cache_path)) {
    message("  [skip] ", cache_path, " not found -- run b_01_cross_section.R first")
    next
  }
  hex_sf <- readRDS(cache_path)$hex_sf |> select(hex_id) |> st_transform(4326)

  hex_asset <- file.path(EE_ASSET_HOME, paste0("rs_hex_grid_", res_tag))
  if (!asset_exists(hex_asset)) {
    message("  Uploading hex grid (", nrow(hex_sf), " cells)...")
    # chunked upload (same rationale as build_04_backdating.R Section 10) -- size unconfirmed
    # for 1km (could be tens of thousands of cells); drop to a smaller k if this payload-errors.
    k <- 10000L
    chunk_ids <- sprintf("%s_c%02d", hex_asset, seq_len(ceiling(nrow(hex_sf) / k)))
    chunk_tasks <- list()
    for (i in seq_along(chunk_ids)) {
      idx <- ((i - 1L) * k + 1L):min(i * k, nrow(hex_sf))
      t <- ee$batch$Export$table$toAsset(collection = sf_as_ee(hex_sf[idx, ]),
                                         description = sprintf("rs_hex_%s_c%02d", res_tag, i),
                                         assetId = chunk_ids[i])
      t$start(); message("    submitted chunk ", i, " -- waiting for COMPLETED...")
      chunk_tasks[[i]] <- t
    }
    for (t in chunk_tasks) poll_task(t)
  }
  chunk_ids <- Filter(asset_exists, sprintf("%s_c%02d", hex_asset, 1:10))
  hex_fc <- Reduce(function(a, b) a$merge(b), lapply(chunk_ids, ee$FeatureCollection))

  reduced <- annual_area$reduceRegions(collection = hex_fc, reducer = ee$Reducer$sum(),
                                        scale = 10, tileScale = 16L)
  out_dir <- here("outputs", "tables", "backdating")
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  out_csv <- here(out_dir, paste0("b_04_rs_mining_panel_", res_tag, ".csv"))
  export_name <- paste0("b_04_rs_mining_panel_", res_tag)

  task <- ee$batch$Export$table$toDrive(
    collection = reduced$select(c("hex_id", paste0("y", YEARS))),
    description = export_name,
    folder = DRIVE_FOLDER, fileFormat = "CSV")
  task$start()
  message("  Submitted reduceRegions export -- waiting for COMPLETED...")
  poll_task(task)

  if (!drive_download_export(export_name, out_csv))
    stop("Export completed but file not found in Drive folder '", DRIVE_FOLDER, "' -- check manually.")
  message("  Downloaded -> ", out_csv, ". Area sums are in m^2 (sum of pixelArea()) -- divide by ",
          "1e4 for hectares once loaded, matching the rest of the project's area convention.")
}

message("\n=== b_04_rs_mining_panel.R: done for HEX_SIZES_KM = ", paste(HEX_SIZES_KM, collapse = ", "),
        ". Inspect the downloaded CSV(s) in outputs/tables/backdating/, then write Section 4 to ",
        "pivot into the long/wide panel shape b_01_cross_section.R's Barenblitt CSVs already use ",
        "-- not written yet, no real column names/values to design against until now. ===")
