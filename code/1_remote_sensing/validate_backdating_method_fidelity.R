# validate_backdating_method_fidelity.R
#
# One-off robustness check, NOT tied to build_04_backdating.R's own config (unlike diag_04_
# backdating.R, which re-runs as a decision-ready report whenever build_04's anchor/ONSET_MIN/
# METHOD changes -- this script doesn't care about any of that). Question: when we replicate
# Barenblitt's own onset-dating formula (3yr-smoothed-NDVI-decline argmax) AND anchor it to THEIR
# OWN mining footprint (not ours), how close do we get to their own `classifica` dates?
#
# This matters because build_04_backdating.R's existing classifica comparison (14.3% exact / 51.0%
# +-1yr / 60.6% +-2yr, see explainer.md) anchors to OUR classifier's 2017 mask, not Barenblitt's
# footprint -- so any pixel our classifier doesn't spatially recognize just drops out of that
# comparison, conflating "we don't detect the same pixel at all" with "we date the same pixel
# differently." Anchoring to Barenblitt's own FullConversiontoMiningExtent2019.shp instead removes
# that confound almost entirely: every classifica point is, by construction, inside this anchor, so
# whatever dating disagreement remains is attributable to the algorithm/input-imagery side (most
# plausibly Landsat Collection 1 vs 2 -- their Step 1 masks via `pixel_qa`, the Collection 1 QA band
# name; this script reads Collection 2's `QA_PIXEL` collections, since Collection 1 is retired) --
# not to a spatial-footprint mismatch.
#
# Known asymmetry: FullConversiontoMiningExtent2019.shp cumulates through 2019; classifica
# (MiningConversion_2007-2017Vec.shp) only runs 2007-2017. Pixels mined only in 2018-2019 have no
# classifica value to compare against -- they're just unscored here, not an error.
#
# Output: outputs/tables/backdating/validate_backdating_fidelity_classifica.csv (per-point
# onset_year vs classifica, for scoring) + console exact/+-1/+-2 summary.
#
# Run INTERACTIVELY -- ee_Authenticate()/ee_Initialize() block on a browser login.
# Prerequisite: build_04_backdating.R's barenblitt_conversion_pts_c* chunk assets already uploaded
# (one-time upload, done by that script's own Section 10 -- reused here via load_conv_pts(), not
# re-uploaded).

#### 1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, sf, here, tidyverse, googledrive, conflicted)
conflicts_prefer(dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise, here::here)

EE_PROJECT    <- "rgee-auth-tillam"   # ID, never the numeric project number
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
DRIVE_FOLDER  <- "ghana_mining_gee_exports"

ee_Authenticate()
ee_Initialize(drive = TRUE, project = EE_PROJECT)
# ee_Initialize(drive = TRUE) does NOT hand googledrive a working token on its own -- same gotcha
# documented throughout this folder (diag_05/b_04/diag_04).
googledrive::drive_auth()

#### 2. Parameters -- the window matches classifica's OWN full range (07-17), not build_04's ####
#### ONSET_MAX=2016 (that 2016 ceiling exists only because 2017+ is OUR classifier's job; here ####
#### we're comparing directly to Barenblitt's own labels, so there's no reason to truncate early) ####
ONSET_MIN <- 2007L
ONSET_MAX <- 2017L
IMG_START <- ONSET_MIN - 2L   # 2005 -- see build_onset_year()'s own note below for why -2, not -1
IMG_END   <- ONSET_MAX + 2L   # 2019

#### 3. Anchor: Barenblitt's OWN cumulative footprint, not our classifier ####
# Full extent through 2019 (both artisanal + industrial -- classifica's own time-series shapefile
# has no mine_type field to filter by, and nothing in Barenblitt's methods section suggests Step 4
# only dated one type, so we don't filter here either). st_make_valid() per CLAUDE.md.
mining_2019_sf <- st_read(
  here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp"), quiet = TRUE
) |> st_make_valid()

asset_exists <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)

# Chunked upload: sf_as_ee() serializes the WHOLE object to GeoJSON and sends it to EE in one
# request, capped at 10 MB -- hit immediately on a direct whole-object call ("Request payload size
# exceeds the limit: 10485760 bytes", 2026-11-06). Barenblitt's mining-extent polygons are "clumps
# of contiguous classified pixels" (blocky, high-vertex-count boundaries), so unlike build_04's
# conv_pts chunking (53,793 simple POINTS, k=10000 per chunk was fine), POLYGONS need a much smaller
# k -- the ~3 MB on-disk .shp balloons well past 10 MB as verbose GeoJSON. k=1000 gives 8 chunks;
# if any individual chunk still exceeds the limit (uneven polygon complexity), drop k further.
mining_2019_base <- file.path(EE_ASSET_HOME, "barenblitt_mining_2019_ext")
k <- 1000L
n_chunks   <- ceiling(nrow(mining_2019_sf) / k)
chunk_ids  <- sprintf("%s_c%02d", mining_2019_base, seq_len(n_chunks))
chunk_missing <- !vapply(chunk_ids, asset_exists, logical(1))

if (any(chunk_missing)) {
  mining_2019_4326 <- st_transform(mining_2019_sf, 4326)
  for (i in which(chunk_missing)) {
    idx <- ((i - 1L) * k + 1L):min(i * k, nrow(mining_2019_4326))
    message("Uploading barenblitt_mining_2019_ext chunk ", i, "/", n_chunks, " (", length(idx), " polygons)...")
    upload_task <- ee$batch$Export$table$toAsset(
      collection  = sf_as_ee(mining_2019_4326[idx, ]),
      description = sprintf("barenblitt_mining_2019_ext_c%02d", i),
      assetId     = chunk_ids[i]
    )
    upload_task$start()
    message("  submitted chunk ", i, " -- wait for COMPLETED, then re-run")
  }
  stop("Chunk uploads submitted -- check the Code Editor Tasks tab, then re-run this script once ",
       "all show COMPLETED.")
}

mining_2019_ee <- Reduce(function(a, b) a$merge(b), lapply(chunk_ids, ee$FeatureCollection))

# No reduceResolution()/reproject() step here, unlike build_04's build_ever_mined(): that one
# downsamples an existing 10m RASTER (our classifier mask) to the 30m Landsat grid. Here the anchor
# is a VECTOR -- paint() rasterizes it lazily at whatever scale the computation below actually runs
# at (30m, via build_landsat_series()'s native Landsat composites), so no explicit resampling step
# is needed or correct.
ever_mined <- ee$Image()$byte()$paint(mining_2019_ee, 1)$selfMask()

#### 4. Landsat NDVI series + Barenblitt-replica dating (duplicated, not sourced, from ####
#### build_04_backdating.R/diag_04_backdating.R -- this project's convention: scripts coordinate ####
#### through data artifacts, never source() each other. Only the "barenblitt" branch is needed -- ####
#### no LandTrendr cross-check here, that's a different question from this script's.) ####
maskL2 <- function(img) {
  qa    <- img$select("QA_PIXEL")
  clear <- qa$bitwiseAnd(bitwShiftL(1L, 1L))$eq(0)$
    And(qa$bitwiseAnd(bitwShiftL(1L, 3L))$eq(0))$
    And(qa$bitwiseAnd(bitwShiftL(1L, 4L))$eq(0))
  sat <- img$select("QA_RADSAT")$eq(0)
  img$updateMask(clear)$updateMask(sat)
}

ROY <- list(RED = list(s = 0.9047, i = 0.0061), NIR = list(s = 0.8462, i = 0.0412),
            SWIR2 = list(s = 0.9071, i = 0.0172))   # Roy et al. (2016), OLI -> ETM+

ghana <- ee$FeatureCollection(file.path(EE_ASSET_HOME, "rs05_ghana"))$geometry()

build_landsat_series <- function(ever_mined, img_start, img_end, region = ghana) {
  prep <- function(id, bands, is_oli) {
    ee$ImageCollection(id)$
      filterBounds(region)$
      filterDate(sprintf("%d-01-01", img_start), sprintf("%d-01-01", img_end + 1L))$
      map(maskL2)$
      map(function(img) {
        sr <- img$select(bands, c("RED", "NIR", "SWIR2"))$multiply(0.0000275)$add(-0.2)
        if (is_oli) {
          sr <- sr$select("RED")$multiply(ROY$RED$s)$add(ROY$RED$i)$
            addBands(sr$select("NIR")$multiply(ROY$NIR$s)$add(ROY$NIR$i))$
            addBands(sr$select("SWIR2")$multiply(ROY$SWIR2$s)$add(ROY$SWIR2$i))
        }
        sr$addBands(sr$normalizedDifference(c("NIR", "RED"))$rename("NDVI"))$
          updateMask(ever_mined)$clip(region)$
          copyProperties(img, list("system:time_start"))
      })
  }
  tm <- c("SR_B3", "SR_B4", "SR_B7"); oli <- c("SR_B4", "SR_B5", "SR_B7")
  prep("LANDSAT/LT05/C02/T1_L2", tm, FALSE)$
    merge(prep("LANDSAT/LE07/C02/T1_L2", tm, FALSE))$
    merge(prep("LANDSAT/LC08/C02/T1_L2", oli, TRUE))
}

build_onset_year_barenblitt <- function(landsat, ever_mined, onset_min, onset_max, img_start, img_end) {
  yrs <- img_start:img_end
  annual_composite <- function(yr, band, reducer) {
    ee$Image(landsat$filter(ee$Filter$calendarRange(yr, yr, "year"))$select(band)$reduce(reducer))$
      rename(band)$set("year", yr)
  }
  ndvi_max <- lapply(yrs, function(y) annual_composite(y, "NDVI", ee$Reducer$max()))
  names(ndvi_max) <- as.character(yrs)
  avg_years <- (img_start + 1L):(img_end - 1L)
  ndvi_avg <- lapply(avg_years, function(y) {
    ndvi_max[[as.character(y - 1L)]]$add(ndvi_max[[as.character(y)]])$add(ndvi_max[[as.character(y + 1L)]])$
      divide(3)$multiply(-1)$rename("NDVI_avg")
  })
  names(ndvi_avg) <- as.character(avg_years)
  # deriv_years starts at img_start+2 -- img_start MUST be <= onset_min-2 (set in Section 2 above)
  # or onset_min itself never gets a valid derivative and the window's real floor silently becomes
  # onset_min+1 (same gotcha documented in diag_04_backdating.R's Section 8c).
  deriv_years <- (min(avg_years) + 1L):max(avg_years)
  deriv_col <- ee$ImageCollection(lapply(deriv_years, function(y) {
    d <- ndvi_avg[[as.character(y)]]$subtract(ndvi_avg[[as.character(y - 1L)]])$rename("NDVI_deriv")
    d$addBands(ee$Image$constant(y)$toInt()$rename("Year"))$updateMask(ever_mined)
  }))
  qm <- deriv_col$qualityMosaic("NDVI_deriv")
  qm$select("Year")$
    updateMask(qm$select("Year")$gte(onset_min))$updateMask(qm$select("Year")$lte(onset_max))$
    updateMask(ever_mined)$toInt16()$rename("onset_year")
}

landsat    <- build_landsat_series(ever_mined, IMG_START, IMG_END)
onset_year <- build_onset_year_barenblitt(landsat, ever_mined, ONSET_MIN, ONSET_MAX, IMG_START, IMG_END)

#### 5. Sample at Barenblitt's own classifica points, export, score ####
# load_conv_pts() reads the barenblitt_conversion_pts_c* chunk assets build_04_backdating.R's own
# Section 10 already uploaded (one point per classifica polygon, 53,793 total) -- durable EE assets,
# reused here as-is, not re-uploaded.
load_conv_pts <- function(max_chunks = 10L) {
  pts_base      <- file.path(EE_ASSET_HOME, "barenblitt_conversion_pts")
  candidate_ids <- sprintf("%s_c%02d", pts_base, seq_len(max_chunks))
  chunk_ids     <- Filter(asset_exists, candidate_ids)
  if (length(chunk_ids) == 0)
    stop("no barenblitt_conversion_pts_c* chunk assets found -- run build_04_backdating.R's ",
         "Section 10 upload step first (one-time, independent of this script).")
  Reduce(function(a, b) a$merge(b), lapply(chunk_ids, ee$FeatureCollection))
}
conv_pts <- load_conv_pts()

sampled <- onset_year$sampleRegions(collection = conv_pts, properties = list("classifica"),
                                     scale = 30L, tileScale = 8L)

dsn <- here("outputs", "tables", "backdating", "validate_backdating_fidelity_classifica.csv")
dir.create(dirname(dsn), recursive = TRUE, showWarnings = FALSE)

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
# ee_monitoring() has a known rgee bug (reads destination_uris before a RUNNING task has populated
# it) -- same workaround used throughout this folder, only ever read `state`.
poll_task <- function(task, interval = 15) {
  repeat {
    state <- ee$batch$Task$status(task)[["state"]]
    message("  task state: ", state, " (", format(Sys.time(), "%H:%M:%S"), ")")
    if (state %in% c("COMPLETED", "FAILED", "CANCELLED")) break
    Sys.sleep(interval)
  }
  if (state != "COMPLETED")
    stop("EE task ended in state '", state, "' -- check the Code Editor Tasks tab (project ", EE_PROJECT, ").")
  invisible(state)
}

if (drive_download_export("validate_backdating_fidelity", dsn)) {
  message("Found existing export on Drive -- skipping resubmission.")
} else {
  task <- ee$batch$Export$table$toDrive(
    collection = sampled$select(c("classifica", "onset_year")),
    description = "validate_backdating_fidelity", folder = DRIVE_FOLDER, fileFormat = "CSV"
  )
  task$start()
  message("Submitted -- BLOCKING until done (national, 53,793 points, scale=30).")
  poll_task(task)
  if (!drive_download_export("validate_backdating_fidelity", dsn))
    stop("Export completed but file not found in Drive folder '", DRIVE_FOLDER, "' -- check manually.")
}

d <- read_csv(dsn, col_types = cols(classifica = "i", onset_year = "i", .default = "c")) |>
  mutate(bar_year = 2000L + classifica, err = abs(onset_year - bar_year))

cat("\n=== Method-fidelity check: our dating formula, anchored to Barenblitt's OWN 2019 footprint,",
    "\n    vs their own classifica dates (", ONSET_MIN, "-", ONSET_MAX, ") ===\n", sep = "")
cat(sprintf("n scored (of 53,793 classifica points): %d\n", nrow(d)))
cat(sprintf("exact: %.1f%% | +-1yr: %.1f%% | +-2yr: %.1f%%\n",
            100 * mean(d$err == 0), 100 * mean(d$err <= 1), 100 * mean(d$err <= 2)))
cat("\nCompare against build_04_backdating.R's existing (classifier-anchored) numbers -- 14.3% / ",
    "51.0% / 60.6% -- and Barenblitt's own self-validation ceiling (algorithm vs independent visual\n",
    "review) -- 33.8% / 69.4% / 76.1% (notes/barenblitt_dataset_documentation.md). If this script's\n",
    "numbers land much closer to the self-validation ceiling than build_04's do, the classifier-\n",
    "anchored gap was mostly a spatial-footprint issue, not a dating-formula one.\n", sep = "")
