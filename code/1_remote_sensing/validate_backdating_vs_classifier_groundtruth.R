# validate_backdating_vs_classifier_groundtruth.R
#
# Question: how well do the backdating methods recover the right year, (a) with the dense imagery of
# 2018-2025 and, optionally, (b) with that imagery thinned to pre-2013 sparsity?
#
# GROUND TRUTH: build_03's own year-by-year embedding-classifier masks. A pixel NOT mined in
# mine_mask_ghana_c4_2017 that first appears in mine_mask_ghana_c4_{2018..2025} gets that year.
# Independent of any vegetation-index logic, so not circular -- but it is the classifier's FIRST
# DETECTION, not the true conversion year, and pixels can flicker (`persistent` flag, not a filter).
#
# Switches (Section 2):
#   THIN_TARGET   NULL = dense imagery only. A number (e.g. 2.5) = ALSO run every method on the same
#                 pixels with each pixel keeping each clear observation with probability
#                 THIN_TARGET / (its clear obs that year): ~THIN_TARGET obs/yr, some years with none,
#                 like 1999-2012 (mean 1.3-3.6/yr, scene_coverage_anchor2017.csv).
#   INCLUDE_CCDC  add CCDC (Barenblitt's comparison settings: minObservations 3, chi-square 0.8). It
#                 was rejected 2026-09-03 as too data-hungry; the thinned run tests exactly that.
#   TEST_REGION   "aoi" (Awomaso box, fast) / "bar_hull" / "ghana". CCDC fits every image, so start small.
#   RULE_VARIANTS c("e") / c("e", "f") = run only the replica + these rules (2026-11-16; no LandTrendr/CCDC
#                 re-run). Rule f = the largest loss that PERSISTS (median annual max over y+1..y+3 at least
#                 PERSIST_DROP below y-3..y-1), on the rule-e series; 0 where no loss persists. Scored also as
#                 f_fb = f, else the rule-e year (the planned build_04 onset + persistent_loss flag). Rule e =
#                 the replica with every 1-obs year's annual max replaced by linear interpolation between
#                 the nearest >= 2-obs years (see diag_06_onset_2002_check.R / validate_backdating_method_
#                 fidelity.R). The thinned run is the decisive test: thinning creates exactly the sparse
#                 1-obs years e targets, against a reference year that is not NDVI-based. bar_thin here
#                 should match the _ccdc run's bar_thin where the regions overlap (same thinning seed).
# Methods: Barenblitt replica (deployed) and LandTrendr in build_04_backdating.R's segment version
# (mag > 200, dur < 4, preval > 100), always; CCDC optional.
#
# Caveats: thinning is random in time (real early gaps cluster in the wet season, so the dry-season
# bias of early annual-max NDVI isn't reproduced); one random draw. CCDC onset = break with the most
# negative NDVI magnitude (observed - predicted) -- if CCDC dates almost nothing, check that sign.
#
# History: the first version (2026-11-13, dense only, LandTrendr = old single-year >100 gate) wrote
# EE asset validate_classifier_gt_2018_2025_bar_hull and
# validate_backdating_vs_classifier_groundtruth_bar_hull.csv (persistent: Barenblitt 39.8/83.1/90.2%
# exact/+-1/+-2, LandTrendr 60.0/90.3/94.9% at 24% coverage). This version writes *_v2_{RUN_TAG} names
# (different bands), so it never reads or overwrites those.
#
# Output: EE asset validate_classifier_gt_v2_{RUN_TAG}, then
#   outputs/tables/backdating/validate_backdating_vs_classifier_groundtruth_v2_{RUN_TAG}.csv + console tables.
# Run INTERACTIVELY. Non-blocking: submits the export and stops; re-run once it shows COMPLETED.
# Prerequisite: build_03_embedding_panel.R's mine_mask_ghana_c4_{2017..2025} assets exist.

#### 1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, here, tidyverse, sf, conflicted)
conflicts_prefer(dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise, here::here)

EE_PROJECT    <- "rgee-auth-tillam"   # ID, never the numeric project number
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
MASK_PREFIX   <- "mine_mask_ghana_c4_"

ee_Authenticate()
ee_Initialize(project = EE_PROJECT)   # no Drive needed: results go via an EE asset

ghana <- ee$FeatureCollection(file.path(EE_ASSET_HOME, "rs05_ghana"))$geometry()
asset_exists <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)

#### 2. Parameters ####
GT_YEARS       <- 2018:2025
TEST_ONSET_MIN <- min(GT_YEARS)
TEST_ONSET_MAX <- max(GT_YEARS)
IMG_START_TEST <- TEST_ONSET_MIN - 2L   # 2016 -- same -2 convention as build_04_backdating.R
IMG_END_TEST   <- 2026L                 # capped at what's available "now": less right-context for 2024-2025

THIN_TARGET  <- 2.5    # NULL = dense only; a number = also run thinned (expected clear obs per pixel-year)
THIN_SEED    <- 42L
INCLUDE_CCDC <- TRUE
RULE_VARIANTS <- c("e", "f")   # 2026-11-16: NULL = classic run (bar + LT [+ CCDC]); otherwise bar + these rules only.
                               # c("e") reads/writes the *_e run; c("e", "f") the *_ef run (no LT/CCDC re-run either way)
PERSIST_DROP  <- 0.15         # rule f: median annual max over y+1..y+3 must sit >= this below y-3..y-1

LT_MIN_MAGNITUDE <- 200; LT_MAX_DURATION <- 4; LT_MIN_PREVAL <- 100   # = build_04_backdating.R
CCDC_MIN_OBS <- 3L; CCDC_CHISQ <- 0.8                                  # = Barenblitt et al. (2021)
CCDC_LAMBDA  <- 0.002   # EE default 20 assumes 0-10000 reflectance; indices here are -1..1 -> 20/10000

TEST_REGION <- "bar_hull"
TEST_AOI    <- ee$Geometry$Rectangle(c(-2.05, 5.98, -1.87, 6.15))   # build_04's TUNE_AOI (Awomaso)
region_test <- switch(TEST_REGION,
  ghana    = ghana,
  aoi      = TEST_AOI,
  bar_hull = {
    suppressMessages(sf_use_s2(FALSE))   # raw Barenblitt geometries trip s2 validity
    hull <- st_read(here("data", "raw", "barenblitt", "MiningConversion_2007-2017Vec.shp"), quiet = TRUE) |>
      st_make_valid() |> st_zm(drop = TRUE) |> st_geometry() |> st_combine() |> st_convex_hull() |>
      st_transform(4326)
    sf_as_ee(st_sf(geometry = hull))$geometry()
  },
  stop('TEST_REGION must be "aoi", "bar_hull" or "ghana"'))

STATES  <- if (is.null(THIN_TARGET)) "full" else c("full", "thin")
METHODS <- if (!is.null(RULE_VARIANTS)) c("bar", RULE_VARIANTS) else c("bar", "lt", if (INCLUDE_CCDC) "cc")
RUN_TAG <- paste0(TEST_REGION,
                  if (!is.null(THIN_TARGET)) sprintf("_k%02d", round(THIN_TARGET * 10)),
                  if (!is.null(RULE_VARIANTS)) paste0("_", paste(RULE_VARIANTS, collapse = "")) else if (INCLUDE_CCDC) "_ccdc")   # e.g. bar_hull_k25_ef

#### 3. Pseudo-ground truth: first year each pixel appears in build_03's masks, 2018-2025, ####
#### among pixels NOT mined in the 2017 anchor (avoids circularity with the historical backdating) ####
mask30 <- function(yr) {
  mask_id <- file.path(EE_ASSET_HOME, paste0(MASK_PREFIX, yr))
  ee$Image(mask_id)$unmask(0)$setDefaultProjection(ee$Image(mask_id)$projection())$
    reduceResolution(reducer = ee$Reducer$mean(), maxPixels = 64L)$
    reproject(ee$Projection("EPSG:32630")$atScale(30))$gte(0.5)
}
not_mined_2017 <- mask30(2017L)$Not()

# toInt16(): multiply(y) gives each year a different value range (Short<0,2018>, ...), which EE
# refuses to combine ("Expected a homogeneous image collection", 2026-11-13).
year_imgs      <- lapply(GT_YEARS, function(y) mask30(y)$selfMask()$multiply(y)$toInt16()$rename("year"))
first_detected <- ee$ImageCollection(year_imgs)$min()$rename("first_detected_year")$updateMask(not_mined_2017)

# persistent = stays mined in every year from its first detection to 2025 (flag, not a filter)
persistent <- ee$Image$cat(lapply(GT_YEARS, function(y) {
  mask30(y)$eq(0)$And(ee$Image$constant(y)$gte(first_detected))
}))$reduce(ee$Reducer$sum())$eq(0)$rename("persistent")
ever_mined_test <- first_detected$mask()

#### 4. Landsat series, dense and (optionally) thinned. Duplicated from build_04, not sourced ####
maskL2 <- function(img) {
  qa    <- img$select("QA_PIXEL")
  clear <- qa$bitwiseAnd(bitwShiftL(1L, 1L))$eq(0)$
    And(qa$bitwiseAnd(bitwShiftL(1L, 3L))$eq(0))$
    And(qa$bitwiseAnd(bitwShiftL(1L, 4L))$eq(0))
  img$updateMask(clear)$updateMask(img$select("QA_RADSAT")$eq(0))
}
ROY <- list(RED = list(s = 0.9047, i = 0.0061), NIR = list(s = 0.8462, i = 0.0412),
            SWIR2 = list(s = 0.9071, i = 0.0172))   # Roy et al. (2016), OLI -> ETM+

build_landsat_series <- function(ever_mined, img_start, img_end, region) {
  prep <- function(id, bands, is_oli) {
    ee$ImageCollection(id)$filterBounds(region)$
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

# Per pixel and year: keep each clear observation with probability target / n_clear(pixel, year).
# Each image gets its own random field (seed from its timestamp): drops independent across images/pixels.
thin_series <- function(landsat, yrs, target, seed) {
  per_year <- lapply(yrs, function(y) {
    col_y <- landsat$filter(ee$Filter$calendarRange(y, y, "year"))
    p_y   <- ee$Image$constant(target)$divide(col_y$select("NDVI")$count())$min(1)
    col_y$map(function(img) {
      s <- ee$Number(img$get("system:time_start"))$divide(1000)$add(seed)$mod(2147483647)$toInt()
      img$updateMask(ee$Image$random(s)$lt(p_y))
    })
  })
  Reduce(function(a, b) a$merge(b), per_year)
}

landsat <- list(full = build_landsat_series(ever_mined_test, IMG_START_TEST, IMG_END_TEST, region_test))
if ("thin" %in% STATES)
  landsat$thin <- thin_series(landsat$full, IMG_START_TEST:IMG_END_TEST, THIN_TARGET, THIN_SEED)

#### 5. Dating methods ####
# Empty year -> 1-band fully masked image, not a 0-band one (see build_04_backdating.R Section 5).
annual_composite <- function(ls, yr, band, reducer) {
  col   <- ls$filter(ee$Filter$calendarRange(yr, yr, "year"))$select(band)
  empty <- ee$Image$constant(0)$toFloat()$updateMask(ee$Image$constant(0))
  ee$Image(ee$Algorithms$If(col$size()$gt(0), col$reduce(reducer), empty))$rename(band)
}

# Rule e's annual max: as deployed, but a year with exactly ONE clear observation is replaced by linear
# interpolation between the nearest years with >= 2 (kept as is if there is none on one side). Forward
# and backward passes carry the nearest well-observed value/year. Same code as validate_backdating_
# method_fidelity.R's annual_max_e (duplicated, not sourced).
annual_max_e <- function(ls, yrs) {
  k  <- as.character(yrs)
  mx <- setNames(lapply(yrs, function(y) annual_composite(ls, y, "NDVI", ee$Reducer$max())), k)
  ct <- setNames(lapply(yrs, function(y) {
    col <- ls$filter(ee$Filter$calendarRange(y, y, "year"))$select("NDVI")
    ee$Image(ee$Algorithms$If(col$size()$gt(0), col$count(), ee$Image$constant(0L)))$unmask(0)$rename("n")
  }), k)
  sentinel <- ee$Image$constant(-9)$toFloat()
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

onset_bar <- function(ls, interp_1obs = FALSE) {
  yrs <- IMG_START_TEST:IMG_END_TEST
  ndvi_max <- if (interp_1obs) annual_max_e(ls, yrs) else
    setNames(lapply(yrs, function(y) annual_composite(ls, y, "NDVI", ee$Reducer$max())), yrs)
  avg_years <- (IMG_START_TEST + 1L):(IMG_END_TEST - 1L)
  ndvi_avg <- setNames(lapply(avg_years, function(y) {
    ndvi_max[[as.character(y - 1L)]]$add(ndvi_max[[as.character(y)]])$add(ndvi_max[[as.character(y + 1L)]])$
      divide(3)$multiply(-1)
  }), avg_years)
  deriv_col <- ee$ImageCollection(lapply((min(avg_years) + 1L):max(avg_years), function(y) {
    ndvi_avg[[as.character(y)]]$subtract(ndvi_avg[[as.character(y - 1L)]])$rename("NDVI_deriv")$
      addBands(ee$Image$constant(y)$toInt()$rename("Year"))$updateMask(ever_mined_test)
  }))
  yr <- deriv_col$qualityMosaic("NDVI_deriv")$select("Year")
  yr$updateMask(yr$gte(TEST_ONSET_MIN)$And(yr$lte(TEST_ONSET_MAX)))$updateMask(ever_mined_test)$toInt16()
}

onset_lt <- function(ls) {
  lt_series <- ee$ImageCollection(lapply(IMG_START_TEST:IMG_END_TEST, function(y) {
    annual_composite(ls, y, "NBR", ee$Reducer$median())$multiply(-1000)$toInt()$rename("LOSS")$
      set("system:time_start", ee$Date$fromYMD(y, 7L, 1L)$millis())
  }))
  arr <- ee$Algorithms$TemporalSegmentation$LandTrendr(
    timeSeries = lt_series, maxSegments = 6L, spikeThreshold = 0.9, vertexCountOvershoot = 3L,
    preventOneYearRecovery = TRUE, recoveryThreshold = 0.25, pvalThreshold = 0.05,
    bestModelProportion = 0.75, minObservationsNeeded = 6L)$select("LandTrendr")
  verts  <- arr$arrayMask(arr$arraySlice(0L, 3L, 4L))   # vertex columns only
  v_year <- verts$arraySlice(0L, 0L, 1L)$arrayProject(list(1L))
  v_fit  <- verts$arraySlice(0L, 2L, 3L)$arrayProject(list(1L))
  seg_mag <- v_fit$arraySlice(0L, 1L)$subtract(v_fit$arraySlice(0L, 0L, -1L))   # + = loss (series is -NBR)
  seg_dur <- v_year$arraySlice(0L, 1L)$subtract(v_year$arraySlice(0L, 0L, -1L))
  seg_pre <- v_fit$arraySlice(0L, 0L, -1L)$multiply(-1)                         # NBR*1000 at segment start
  seg_yod <- v_year$arraySlice(0L, 0L, -1L)$add(1)
  amax <- seg_mag$arrayArgmax()$arrayFlatten(list(list("i")))                   # greatest-loss segment
  yod  <- seg_yod$arrayGet(amax)
  yod$updateMask(seg_mag$arrayGet(amax)$gt(LT_MIN_MAGNITUDE)$
                   And(seg_dur$arrayGet(amax)$lt(LT_MAX_DURATION))$
                   And(seg_pre$arrayGet(amax)$gt(LT_MIN_PREVAL)))$
    updateMask(yod$gte(TEST_ONSET_MIN)$And(yod$lte(TEST_ONSET_MAX)))$updateMask(ever_mined_test)$
    round()$toInt16()
}

onset_cc <- function(ls) {
  cc <- ee$Algorithms$TemporalSegmentation$Ccdc(
    collection = ls$select(c("NDVI", "NBR")), breakpointBands = list("NDVI", "NBR"),
    minObservations = CCDC_MIN_OBS, chiSquareProbability = CCDC_CHISQ, dateFormat = 1L,
    lambda = CCDC_LAMBDA)
  t_break <- cc$select("tBreak")          # per-segment break date, fractional year (0 = no break)
  mag     <- cc$select("NDVI_magnitude")  # per-segment change, observed - predicted
  # score = NDVI loss for breaks inside the window, else 0. A 0 is appended so pixels with no
  # segments (too few observations) still have a non-empty array to argmax over.
  pad   <- ee$Image(ee$Array(list(0.0)))
  valid <- t_break$gte(TEST_ONSET_MIN)$And(t_break$lt(TEST_ONSET_MAX + 1L))$And(mag$lt(0))
  score <- mag$multiply(-1)$multiply(valid)$arrayCat(pad, 0L)
  tb    <- t_break$arrayCat(pad, 0L)
  amax  <- score$arrayArgmax()$arrayFlatten(list(list("i")))
  tb$arrayGet(amax)$floor()$updateMask(score$arrayGet(amax)$gt(0))$updateMask(ever_mined_test)$toInt16()
}

# Rule f: as rule e, but a year can only win if its loss PERSISTS -- the median annual max over the 3
# years after it sits at least PERSIST_DROP below the median over the 3 years before (windows clipped
# to the imagery; a fully masked window = not persistent). Masked where no loss persists (-> 0).
# Mirrors the R test in diag_06's sample (2026-11-16): f(0.15)+e, +-1 vs classifica 76% vs 70% deployed.
onset_f <- function(ls) {
  yrs <- IMG_START_TEST:IMG_END_TEST; k <- as.character(yrs)
  v   <- annual_max_e(ls, yrs)
  med <- function(ys) ee$ImageCollection(unname(v[intersect(as.character(ys), k)]))$median()
  avg_years <- (IMG_START_TEST + 1L):(IMG_END_TEST - 1L)
  ma <- setNames(lapply(avg_years, function(y) {
    v[[as.character(y - 1L)]]$add(v[[as.character(y)]])$add(v[[as.character(y + 1L)]])$divide(3)$multiply(-1)
  }), avg_years)
  deriv_col <- ee$ImageCollection(lapply((min(avg_years) + 1L):max(avg_years), function(y) {
    persist <- med((y - 3L):(y - 1L))$subtract(med((y + 1L):(y + 3L)))$gte(PERSIST_DROP)
    ma[[as.character(y)]]$subtract(ma[[as.character(y - 1L)]])$rename("NDVI_deriv")$
      addBands(ee$Image$constant(y)$toInt()$rename("Year"))$
      updateMask(persist)$updateMask(ever_mined_test)
  }))
  yr <- deriv_col$qualityMosaic("NDVI_deriv")$select("Year")
  yr$updateMask(yr$gte(TEST_ONSET_MIN)$And(yr$lte(TEST_ONSET_MAX)))$updateMask(ever_mined_test)$toInt16()
}

method_fns <- list(bar = onset_bar, e = function(ls) onset_bar(ls, interp_1obs = TRUE), f = onset_f,
                   lt = onset_lt, cc = onset_cc)[METHODS]

#### 6. Export per-pixel results as an asset (non-blocking) ####
# Not sample() (keeps too few mined points) and not one big reduction over the Landsat archive (times
# out, 2026-11-13): export the per-pixel raster (tiled), then histogram the cheap saved raster.
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

TEST_ASSET <- file.path(EE_ASSET_HOME, paste0("validate_classifier_gt_v2_", RUN_TAG))
if (!asset_exists(TEST_ASSET)) {
  if (task_running(basename(TEST_ASSET)))
    stop("'", basename(TEST_ASSET), "' is still running -- re-run once it shows COMPLETED (not an error).", call. = FALSE)
  test_img <- first_detected$toInt16()$rename("gt_year")$addBands(persistent$toInt16())
  for (st in STATES) {
    for (m in METHODS)   # 0 = method gave no year
      test_img <- test_img$addBands(method_fns[[m]](landsat[[st]])$unmask(0)$toInt16()$rename(paste0(m, "_", st)))
    test_img <- test_img$addBands(landsat[[st]]$select("NDVI")$count()$unmask(0)$toInt16()$rename(paste0("nobs_", st)))
  }
  ee$batch$Export$image$toAsset(
    image = test_img$updateMask(ever_mined_test), description = basename(TEST_ASSET), assetId = TEST_ASSET,
    region = region_test, scale = 30L, crs = "EPSG:32630", maxPixels = 1e13,
    pyramidingPolicy = list(".default" = "mode"))$start()
  stop("Submitted '", basename(TEST_ASSET), "' -- not waiting. Re-run the script once it shows ",
       "COMPLETED in the Tasks tab (not an error).", call. = FALSE)
}
a <- ee$Image(TEST_ASSET)

#### 7. Count every pixel: one frequency histogram per imagery state ####
# Years 2018-2025 -> digits 1..8 (0 = no year): code = gt, then one digit per method, then persistent.
dig <- function(b) a$select(b)$toInt32()$subtract(2017L)$max(0L)
und <- function(x) if_else(x == 0L, NA_integer_, 2017L + x)
hist_state <- function(st) {
  k <- length(METHODS)
  code <- dig("gt_year")$multiply(as.integer(10^(k + 1)))
  for (i in seq_along(METHODS))
    code <- code$add(dig(paste0(METHODS[i], "_", st))$multiply(as.integer(10^(k + 1 - i))))
  code <- code$add(a$select("persistent")$toInt32())$updateMask(a$select("gt_year")$mask())$rename("code")
  h <- code$reduceRegion(reducer = ee$Reducer$frequencyHistogram(), geometry = region_test, scale = 30L,
                         crs = "EPSG:32630", maxPixels = 1e11, tileScale = 16L)$getInfo()
  out <- tibble(code = as.integer(names(h$code)), n_pixels = unlist(h$code)) |>
    mutate(imagery = st, first_detected_year = 2017L + code %/% as.integer(10^(k + 1)),
           persistent = code %% 10L)
  for (i in seq_along(METHODS))
    out[[METHODS[i]]] <- und((out$code %/% as.integer(10^(k + 1 - i))) %% 10L)
  select(out, imagery, first_detected_year, all_of(METHODS), persistent, n_pixels)
}
d <- map_dfr(STATES, hist_state)
dsn <- here("outputs", "tables", "backdating", paste0("validate_backdating_vs_classifier_groundtruth_v2_", RUN_TAG, ".csv"))
dir.create(dirname(dsn), recursive = TRUE, showWarnings = FALSE)
write_csv(d, dsn)

n_yrs <- IMG_END_TEST - IMG_START_TEST + 1L
obs <- a$select(paste0("nobs_", STATES))$reduceRegion(reducer = ee$Reducer$mean(), geometry = region_test,
         scale = 30L, crs = "EPSG:32630", maxPixels = 1e11, tileScale = 16L)$getInfo()
cat("\nMean clear obs per pixel-year:", paste(sprintf("%s %.1f", STATES, unlist(obs[paste0("nobs_", STATES)]) / n_yrs),
                                               collapse = " | "),
    if (!is.null(THIN_TARGET)) sprintf("(thin target %.1f)", THIN_TARGET), "\n")

#### 8. Score ####
# f_fb = the planned build_04 onset: the persistent loss (f) where there is one, else the rule-e year.
SCORED <- METHODS
if (all(c("e", "f") %in% METHODS)) { d <- mutate(d, f_fb = coalesce(f, e)); SCORED <- c(METHODS, "f_fb") }
long <- d |> pivot_longer(all_of(SCORED), names_to = "method", values_to = "onset") |>
  mutate(method = recode(method, bar = "barenblitt", e = "rule_e", f = "rule_f", f_fb = "rule_f_else_e",
                         lt = "landtrendr", cc = "ccdc"))
if ("f" %in% METHODS)
  cat(sprintf("\nRule f: no persistent loss for %.1f%% of all pixels (full) / %.1f%% (thin)\n",
              100 * sum(d$n_pixels[d$imagery == "full" & is.na(d$f)]) / sum(d$n_pixels[d$imagery == "full"]),
              100 * sum(d$n_pixels[d$imagery == "thin" & is.na(d$f)]) / max(1, sum(d$n_pixels[d$imagery == "thin"]))))
score <- function(x) {
  x |> group_by(method, imagery) |>
    summarise(coverage = round(100 * sum(n_pixels[!is.na(onset)]) / sum(n_pixels), 1),
              exact = round(100 * sum(n_pixels[!is.na(onset) & onset == first_detected_year]) / sum(n_pixels[!is.na(onset)]), 1),
              pm1   = round(100 * sum(n_pixels[!is.na(onset) & abs(onset - first_detected_year) <= 1]) / sum(n_pixels[!is.na(onset)]), 1),
              pm2   = round(100 * sum(n_pixels[!is.na(onset) & abs(onset - first_detected_year) <= 2]) / sum(n_pixels[!is.na(onset)]), 1),
              mean_signed = round(weighted.mean((onset - first_detected_year)[!is.na(onset)], n_pixels[!is.na(onset)]), 2),
              pm1_of_all  = round(100 * sum(n_pixels[!is.na(onset) & abs(onset - first_detected_year) <= 1]) / sum(n_pixels), 1),
              .groups = "drop") |>
    arrange(method, imagery)
}
n_states <- length(STATES)
cat(sprintf("\n=== %s: persistent ground truth (%d px) ===\n", RUN_TAG, round(sum(d$n_pixels[d$persistent == 1]) / n_states)))
cat("exact/pm1/pm2 = among pixels the method dates; pm1_of_all = within +-1 as a share of ALL pixels\n")
score(long |> filter(persistent == 1)) |> print(n = Inf, width = Inf)
cat(sprintf("\n=== %s: all ground truth (%d px) ===\n", RUN_TAG, round(sum(d$n_pixels) / n_states)))
score(long) |> print(n = Inf, width = Inf)

cat("\n--- signed difference (method - ground truth), persistent, % of dated pixels (+-4 = 4 or more) ---\n")
long |> filter(persistent == 1, !is.na(onset)) |>
  mutate(diff = pmax(pmin(onset - first_detected_year, 4L), -4L)) |>
  group_by(method, imagery, diff) |> summarise(px = sum(n_pixels), .groups = "drop") |>
  group_by(method, imagery) |> mutate(pct = round(100 * px / sum(px), 1)) |> select(-px) |>
  pivot_wider(names_from = diff, values_from = pct, values_fill = 0) |> print(n = Inf, width = Inf)

cat("\n--- by ground-truth year, persistent, +-1yr among dated (edges 2018/2025 are truncated) ---\n")
long |> filter(persistent == 1, !is.na(onset)) |>
  group_by(method, imagery, first_detected_year) |>
  summarise(pm1 = round(100 * sum(n_pixels[abs(onset - first_detected_year) <= 1]) / sum(n_pixels), 1), .groups = "drop") |>
  pivot_wider(names_from = first_detected_year, values_from = pm1) |> print(n = Inf, width = Inf)

cat("\nREAD THIS: with thinning on, the full-vs-thin drop per method is the result -- small for barenblitt\n",
    "means the dense-era accuracy carries over to the sparse early record; a big drop puts a number on how\n",
    "much worse the pre-2013 dates are. CCDC's THIN coverage and accuracy vs the other two is the test of\n",
    "the 2026-09-03 'too data-hungry' rejection. Still pseudo-ground truth: agreement with the classifier's\n",
    "first detection, best case for imagery quality in the full run.\n", sep = "")
