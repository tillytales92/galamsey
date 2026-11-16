# validate_backdating_method_fidelity.R -- one-off check, independent of build_04's settings
#
# Question: on Barenblitt et al.'s OWN footprint (FullConversiontoMiningExtent2019.shp), how well do
# three dating methods reproduce their yearly labels (classifica)?
#   - Barenblitt replica (ours), LandTrendr (200/4/100 segment version), CCDC (minObs 3, chisq 0.8)
# Using their footprint instead of our 2017 mask removes the "we don't detect the pixel at all"
# confound, so what remains is purely dating disagreement (method, season, Collection 2 vs 1).
#
# Window: methods may date 2007-2018; scored against classifica + 1 (2008-2018), because their loss
# year is labelled with the earlier year and ours with the later one. Pixels mined only in 2018-19
# have no classifica and are unscored.
# Caveat: classifica comes from the method our replica copies, so the test favours the replica.
# Their GEE code (github.com/abarenblitt/GhanaArtisanalMining, "Ghana NDVI Anomaly Timeline") uses
# all months (one continuous filterDate 2002-01-01 to 2019-06-30), so no season filter here either.
#
# Output: outputs/tables/backdating/validate_backdating_fidelity_3methods.csv
#   (per point: classifica, onset_bar, onset_lt, onset_cc; 0 = no year) + console summary.
# 2026-11-16: + rule a1 from diag_06_onset_2002_check.R (Barenblitt replica, but a year with fewer
#   than A1_MIN_OBS clear observations counts as missing). Separate, cheap export (no CCDC re-run):
#   validate_backdating_fidelity_a1.csv = classifica, onset_bar, onset_bar_a1 on the same points.
#   Question: does a1 shrink the 19% of points the replica dates >= 4 yrs before classifica + 1?
#   Answer: yes (19% -> 7%), but only by dating everything later; 2008-2012 mines got worse. Rejected.
#   + rule e (same day): 1-obs years interpolated instead of masked -> validate_backdating_fidelity_e.csv
# Run interactively. Submits a Drive export and stops; re-run once COMPLETED to download and score
# (twice if neither CSV exists yet: the 3-method export first, then the a1 export).
# Needs build_04's barenblitt_conversion_pts_c* assets (uploaded once by its Section 10).

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

#### 2. Parameters -- window = classifica's range (07-17) + 1, not build_04's ####
ONSET_MIN <- 2007L
ONSET_MAX <- 2018L            # = classifica 17 + 1 (scoring shifts classifica by +1, see header)
IMG_START <- ONSET_MIN - 2L   # 2005 -- see onset_bar()'s note below for why -2, not -1
IMG_END   <- 2019L            # candidate years run to IMG_END - 1 = 2018

LT_MIN_MAGNITUDE <- 200; LT_MAX_DURATION <- 4; LT_MIN_PREVAL <- 100   # = build_04_backdating.R
CCDC_MIN_OBS <- 3L; CCDC_CHISQ <- 0.8                                  # = Barenblitt et al. (2021)
CCDC_LAMBDA  <- 0.002   # EE default 20 assumes 0-10000 reflectance; indices here are -1..1
A1_MIN_OBS   <- 2L      # rule a1: years with fewer clear obs are missing (strict 3-of-3 mean kept)

#### 3. Anchor: Barenblitt's OWN cumulative footprint, not our classifier ####
# Full extent through 2019 (both artisanal + industrial -- classifica's own time-series shapefile
# has no mine_type field to filter by, and nothing in Barenblitt's methods section suggests Step 4
# only dated one type, so we don't filter here either). st_make_valid() per CLAUDE.md.
mining_2019_sf <- st_read(
  here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp"), quiet = TRUE) |>
  st_make_valid()

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

#### 4. Landsat series + the three dating methods (duplicated, not sourced: scripts coordinate ####
#### through data artifacts, never source() each other) ####
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
        sr$normalizedDifference(c("NIR", "RED"))$rename("NDVI")$
          addBands(sr$normalizedDifference(c("NIR", "SWIR2"))$rename("NBR"))$
          updateMask(ever_mined)$clip(region)$
          copyProperties(img, list("system:time_start"))
      })
  }
  tm <- c("SR_B3", "SR_B4", "SR_B7"); oli <- c("SR_B4", "SR_B5", "SR_B7")
  prep("LANDSAT/LT05/C02/T1_L2", tm, FALSE)$
    merge(prep("LANDSAT/LE07/C02/T1_L2", tm, FALSE))$
    merge(prep("LANDSAT/LC08/C02/T1_L2", oli, TRUE))
}

# Empty year -> 1-band fully masked image, not a 0-band one (see build_04_backdating.R Section 5).
annual_composite <- function(ls, yr, band, reducer) {
  col   <- ls$filter(ee$Filter$calendarRange(yr, yr, "year"))$select(band)
  empty <- ee$Image$constant(0)$toFloat()$updateMask(ee$Image$constant(0))
  ee$Image(ee$Algorithms$If(col$size()$gt(0), col$reduce(reducer), empty))$rename(band)
}

# Annual max NDVI, masked where the year has fewer than min_obs clear observations. min_obs = 1 is
# identical to annual_composite(..., max). A masked year masks every 3yr mean it enters (strict).
annual_max_n <- function(ls, yr, min_obs) {
  col   <- ls$filter(ee$Filter$calendarRange(yr, yr, "year"))$select("NDVI")
  empty <- ee$Image$constant(0)$toFloat()$updateMask(ee$Image$constant(0))
  ee$Image(ee$Algorithms$If(col$size()$gt(0), col$max()$updateMask(col$count()$gte(min_obs)), empty))$rename("NDVI")
}

# Rule e: annual max NDVI as deployed, except that a year with exactly ONE clear observation is
# replaced by linear interpolation between the nearest years with >= 2 observations (kept as is if
# there is no such year on one side). A one-year V (green, 1 low obs, green) disappears; a real step
# (green, 1 low obs, bare) keeps a loss. Unlike a1, no year is masked, so no candidate year is lost.
annual_max_e <- function(ls) {
  yrs <- IMG_START:IMG_END; k <- as.character(yrs)
  mx <- setNames(lapply(yrs, function(y) annual_max_n(ls, y, 1L)), k)
  ct <- setNames(lapply(yrs, function(y) {
    col <- ls$filter(ee$Filter$calendarRange(y, y, "year"))$select("NDVI")
    ee$Image(ee$Algorithms$If(col$size()$gt(0), col$count(), ee$Image$constant(0L)))$unmask(0)$rename("n")
  }), k)
  sentinel <- ee$Image$constant(-9)$toFloat()
  # forward pass: nearest well-observed (>= 2 obs) year BEFORE y; backward pass: nearest AFTER y
  pv <- pyr <- nv <- nyr <- list()
  lv <- sentinel; ly <- sentinel
  for (y in k) {
    pv[[y]] <- lv; pyr[[y]] <- ly
    good <- ct[[y]]$gte(2L)
    lv <- lv$where(good, mx[[y]]$unmask(-9)); ly <- ly$where(good, ee$Image$constant(as.numeric(y))$toFloat())
  }
  lv <- sentinel; ly <- sentinel
  for (y in rev(k)) {
    nv[[y]] <- lv; nyr[[y]] <- ly
    good <- ct[[y]]$gte(2L)
    lv <- lv$where(good, mx[[y]]$unmask(-9)); ly <- ly$where(good, ee$Image$constant(as.numeric(y))$toFloat())
  }
  setNames(lapply(k, function(y) {
    has  <- pv[[y]]$neq(-9)$And(nv[[y]]$neq(-9))
    frac <- ee$Image$constant(as.numeric(y))$toFloat()$subtract(pyr[[y]])$divide(nyr[[y]]$subtract(pyr[[y]]))
    iv   <- pv[[y]]$add(nv[[y]]$subtract(pv[[y]])$multiply(frac))
    mx[[y]]$where(ct[[y]]$eq(1L)$And(has), iv)$rename("NDVI")
  }), k)
}

# Barenblitt replica (min_obs = 1), rule a1 (min_obs = A1_MIN_OBS) or rule e (interp_1obs = TRUE).
# deriv_years starts at IMG_START+2, so IMG_START must be <= ONSET_MIN-2 or the window's real floor
# silently becomes ONSET_MIN+1 (documented gotcha).
onset_bar <- function(ls, min_obs = 1L, interp_1obs = FALSE) {
  yrs <- IMG_START:IMG_END
  ndvi_max <- if (interp_1obs) annual_max_e(ls) else
    setNames(lapply(yrs, function(y) annual_max_n(ls, y, min_obs)), yrs)
  avg_years <- (IMG_START + 1L):(IMG_END - 1L)
  ndvi_avg <- setNames(lapply(avg_years, function(y) {
    ndvi_max[[as.character(y - 1L)]]$add(ndvi_max[[as.character(y)]])$add(ndvi_max[[as.character(y + 1L)]])$
      divide(3)$multiply(-1)
  }), avg_years)
  deriv_col <- ee$ImageCollection(lapply((min(avg_years) + 1L):max(avg_years), function(y) {
    ndvi_avg[[as.character(y)]]$subtract(ndvi_avg[[as.character(y - 1L)]])$rename("NDVI_deriv")$
      addBands(ee$Image$constant(y)$toInt()$rename("Year"))$updateMask(ever_mined)
  }))
  yr <- deriv_col$qualityMosaic("NDVI_deriv")$select("Year")
  yr$updateMask(yr$gte(ONSET_MIN)$And(yr$lte(ONSET_MAX)))$updateMask(ever_mined)$toInt16()
}

# LandTrendr, build_04's segment version: greatest-loss segment, masked unless it passes all gates.
onset_lt <- function(ls) {
  lt_series <- ee$ImageCollection(lapply(IMG_START:IMG_END, function(y) {
    annual_composite(ls, y, "NBR", ee$Reducer$median())$multiply(-1000)$toInt()$rename("LOSS")$
      set("system:time_start", ee$Date$fromYMD(y, 7L, 1L)$millis())
  }))
  arr <- ee$Algorithms$TemporalSegmentation$LandTrendr(
    timeSeries = lt_series, maxSegments = 6L, spikeThreshold = 0.9, vertexCountOvershoot = 3L,
    preventOneYearRecovery = TRUE, recoveryThreshold = 0.25, pvalThreshold = 0.05,
    bestModelProportion = 0.75, minObservationsNeeded = 6L)$select("LandTrendr")
  verts  <- arr$arrayMask(arr$arraySlice(0L, 3L, 4L))
  v_year <- verts$arraySlice(0L, 0L, 1L)$arrayProject(list(1L))
  v_fit  <- verts$arraySlice(0L, 2L, 3L)$arrayProject(list(1L))
  seg_mag <- v_fit$arraySlice(0L, 1L)$subtract(v_fit$arraySlice(0L, 0L, -1L))   # + = loss (series is -NBR)
  seg_dur <- v_year$arraySlice(0L, 1L)$subtract(v_year$arraySlice(0L, 0L, -1L))
  seg_pre <- v_fit$arraySlice(0L, 0L, -1L)$multiply(-1)
  seg_yod <- v_year$arraySlice(0L, 0L, -1L)$add(1)
  amax <- seg_mag$arrayArgmax()$arrayFlatten(list(list("i")))
  yod  <- seg_yod$arrayGet(amax)
  yod$updateMask(seg_mag$arrayGet(amax)$gt(LT_MIN_MAGNITUDE)$
                   And(seg_dur$arrayGet(amax)$lt(LT_MAX_DURATION))$
                   And(seg_pre$arrayGet(amax)$gt(LT_MIN_PREVAL)))$
    updateMask(yod$gte(ONSET_MIN)$And(yod$lte(ONSET_MAX)))$updateMask(ever_mined)$round()$toInt16()
}

# CCDC: onset = break with the largest NDVI loss inside the window (magnitude = observed - predicted).
onset_cc <- function(ls) {
  cc <- ee$Algorithms$TemporalSegmentation$Ccdc(
    collection = ls$select(c("NDVI", "NBR")), breakpointBands = list("NDVI", "NBR"),
    minObservations = CCDC_MIN_OBS, chiSquareProbability = CCDC_CHISQ, dateFormat = 1L,
    lambda = CCDC_LAMBDA)
  t_break <- cc$select("tBreak")
  mag     <- cc$select("NDVI_magnitude")
  pad   <- ee$Image(ee$Array(list(0.0)))   # keeps the array non-empty for pixels with no segments
  valid <- t_break$gte(ONSET_MIN)$And(t_break$lt(ONSET_MAX + 1L))$And(mag$lt(0))
  score <- mag$multiply(-1)$multiply(valid)$arrayCat(pad, 0L)
  tb    <- t_break$arrayCat(pad, 0L)
  amax  <- score$arrayArgmax()$arrayFlatten(list(list("i")))
  tb$arrayGet(amax)$floor()$updateMask(score$arrayGet(amax)$gt(0))$updateMask(ever_mined)$toInt16()
}

landsat <- build_landsat_series(ever_mined, IMG_START, IMG_END)
onsets  <- onset_bar(landsat)$unmask(0)$rename("onset_bar")$     # 0 = method gave no year
  addBands(onset_lt(landsat)$unmask(0)$rename("onset_lt"))$
  addBands(onset_cc(landsat)$unmask(0)$rename("onset_cc"))$
  toInt16()$updateMask(ever_mined)
METHOD_COLS <- c("onset_bar", "onset_lt", "onset_cc")

#### 5. Sample at Barenblitt's own classifica points, export (non-blocking), score ####
# load_conv_pts() reads the barenblitt_conversion_pts_c* chunk assets build_04_backdating.R's own
# Section 10 already uploaded (one point per classifica polygon, 53,793 total).
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

EXPORT_NAME <- "validate_backdating_fidelity_3methods"
dsn <- here("outputs", "tables", "backdating", paste0(EXPORT_NAME, ".csv"))
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
# Task check runs in Python: pulling the task list into R overflows on Windows (seen 2026-11-13).
reticulate::py_run_string(paste(
  "import ee",
  "def ee_task_running(desc):",
  "    try:",
  "        tasks = ee.data.getTaskList()",
  "    except Exception:",
  "        tasks = [t.status() for t in ee.batch.Task.list()]",
  "    return any(t.get('description') == desc and t.get('state') in ('READY', 'RUNNING') for t in tasks)",
  sep = "\n"))
task_running <- function(desc) isTRUE(reticulate::py$ee_task_running(desc))

if (!file.exists(dsn) && !drive_download_export(EXPORT_NAME, dsn)) {
  if (task_running(EXPORT_NAME))
    stop("'", EXPORT_NAME, "' is still running -- re-run once it shows COMPLETED (not an error).", call. = FALSE)
  sampled <- onsets$sampleRegions(collection = conv_pts, properties = list("classifica"),
                                  scale = 30L, tileScale = 8L)
  ee$batch$Export$table$toDrive(
    collection = sampled$select(c("classifica", METHOD_COLS)),
    description = EXPORT_NAME, folder = DRIVE_FOLDER, fileFormat = "CSV")$start()
  stop("Submitted '", EXPORT_NAME, "' -- not waiting. Re-run the script once it shows COMPLETED ",
       "(not an error).", call. = FALSE)
}

read_scored <- function(path, cols) {
  read_csv(path, show_col_types = FALSE) |>
    mutate(truth = 2001L + as.integer(classifica)) |>   # classifica + 1: our label convention
    pivot_longer(any_of(cols), names_to = "method", values_to = "onset") |>
    mutate(method = recode(method, onset_bar = "barenblitt_replica", onset_bar_a1 = "replica_a1",
                           onset_lt = "landtrendr", onset_cc = "ccdc"),
           onset = if_else(onset == 0, NA_real_, as.numeric(onset)), err = onset - truth)
}
print_scores <- function(d) {
  cat(sprintf("points scored: %d (of 53,793 classifica points)\n", n_distinct(d$`system:index`)))
  d |> group_by(method) |>
    summarise(coverage    = round(100 * mean(!is.na(onset)), 1),
              exact       = round(100 * mean(err[!is.na(err)] == 0), 1),
              pm1         = round(100 * mean(abs(err[!is.na(err)]) <= 1), 1),
              pm2         = round(100 * mean(abs(err[!is.na(err)]) <= 2), 1),
              pm1_of_all  = round(100 * sum(abs(err) <= 1, na.rm = TRUE) / n(), 1),
              mean_signed = round(mean(err, na.rm = TRUE), 2), .groups = "drop") |>
    print(width = Inf)
  cat("\n--- signed difference (method - (classifica + 1)), % of dated points, +-4 = 4 or more ---\n")
  d |> filter(!is.na(err)) |> mutate(diff = pmax(pmin(err, 4), -4)) |>
    count(method, diff) |> group_by(method) |> mutate(pct = round(100 * n / sum(n), 1)) |> select(-n) |>
    pivot_wider(names_from = diff, values_from = pct, values_fill = 0) |> print(width = Inf)
}

d <- read_scored(dsn, METHOD_COLS)
cat("\n=== Method fidelity on Barenblitt et al.'s 2019 footprint vs classifica + 1 (",
    ONSET_MIN, "-", ONSET_MAX, ") ===\n", sep = "")
print_scores(d)

cat("\nREAD THIS: classifica comes from Barenblitt et al.'s own NDVI method, which the replica copies, so this\n",
    "comparison favours the replica. pm1_of_all (within +-1 as a share of ALL points) combines coverage\n",
    "and accuracy -- the measure that matters for a panel that needs a year for every mined pixel.\n", sep = "")

#### 6. Single-observation rules vs the deployed replica, same points (one small export each, no CCDC) ####
# a1 (2026-11-16 result): >= 4 yrs early fell 19% -> 7%, but only by shifting dates later across the
#    board -- +-1 for classifica + 1 = 2008-2012 fell from 47-76% to 30-48%, because masked years
#    remove the early candidates. Rejected; kept here as the record.
# e: interpolates 1-obs years instead of masking them (annual_max_e) -- the current candidate.
VARIANTS <- list(
  a1 = list(col = "onset_bar_a1", label = sprintf("rule a1 (years with < %d clear obs = missing)", A1_MIN_OBS),
            img = function() onset_bar(landsat, A1_MIN_OBS)),
  e  = list(col = "onset_bar_e", label = "rule e (1-obs years interpolated between >= 2-obs neighbours)",
            img = function() onset_bar(landsat, interp_1obs = TRUE))
)
for (v in names(VARIANTS)) {
  V <- VARIANTS[[v]]
  ex_name <- paste0("validate_backdating_fidelity_", v)
  dsn_v   <- here("outputs", "tables", "backdating", paste0(ex_name, ".csv"))
  if (!file.exists(dsn_v) && !drive_download_export(ex_name, dsn_v)) {
    if (task_running(ex_name))
      stop("'", ex_name, "' is still running -- re-run once it shows COMPLETED (not an error).", call. = FALSE)
    onsets_v <- onset_bar(landsat)$unmask(0)$rename("onset_bar")$
      addBands(V$img()$unmask(0)$rename(V$col))$
      toInt16()$updateMask(ever_mined)
    ee$batch$Export$table$toDrive(
      collection = onsets_v$sampleRegions(collection = conv_pts, properties = list("classifica"),
                                          scale = 30L, tileScale = 8L)$
        select(c("classifica", "onset_bar", V$col)),
      description = ex_name, folder = DRIVE_FOLDER, fileFormat = "CSV")$start()
    stop("Submitted '", ex_name, "' -- not waiting. Re-run the script once it shows COMPLETED ",
         "(not an error).", call. = FALSE)
  }

  dv <- read_scored(dsn_v, c("onset_bar", V$col)) |>
    mutate(method = if_else(method == "barenblitt_replica", method, v))   # rule column -> "a1" / "e"
  cat("\n=== ", V$label, " vs deployed replica, same points ===\n", sep = "")
  print_scores(dv)

  wide <- dv |> select(`system:index`, truth, method, onset, err) |>
    pivot_wider(names_from = method, values_from = c(onset, err))
  cat("\n--- share dated >= 4 yrs before classifica + 1, by the deployed replica's onset year ---\n")
  wide |> filter(!is.na(onset_barenblitt_replica)) |>
    group_by(onset = onset_barenblitt_replica) |>
    summarise(points = n(),
              early4_replica = round(100 * mean(err_barenblitt_replica <= -4), 1),
              early4_rule    = round(100 * mean(.data[[paste0("err_", v)]] <= -4, na.rm = TRUE), 1),
              rule_undated   = round(100 * mean(is.na(.data[[paste0("onset_", v)]])), 1), .groups = "drop") |>
    print(n = Inf)
  # The check that sank a1: accuracy by the TRUE year -- a rule must not trade early mines for late ones.
  cat("\n--- within +-1 yr by classifica + 1 (the true year) ---\n")
  wide |> group_by(truth) |>
    summarise(points = n(),
              pm1_replica = round(100 * mean(abs(err_barenblitt_replica) <= 1, na.rm = TRUE), 1),
              pm1_rule    = round(100 * mean(abs(.data[[paste0("err_", v)]]) <= 1, na.rm = TRUE), 1), .groups = "drop") |>
    print(n = Inf)
}
