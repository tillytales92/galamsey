# diag_04_backdating.R
#
# Decision-ready diagnostics for build_04_backdating.R -- meant to be re-run any time the anchor
# (MASK_YEARS), METHOD, ONSET_MIN/MAX, or LT_MIN_MAGNITUDE changes, not a one-off exploration. Eight
# capabilities:
#   1. Score an already-downloaded classifica-comparison / dropout-diagnostic CSV (local, no EE).
#   2. Run a NEW method/window/anchor/magnitude combo end-to-end and get a scored result
#      automatically -- submits the EE export, BLOCKS until it finishes, downloads it from Drive,
#      and scores it, all in one call (request_classifica_export()). No manual Drive-folder hunting
#      or download step.
#   3. A fast, synchronous subsample check (quick_window_check()) for "does this look promising"
#      before committing to the full (slower) export in (2).
#   4. A sweep of (3) across LandTrendr's min_magnitude threshold (magnitude_sweep(), Section 6b) --
#      coverage-vs-accuracy curve for tuning LT_MIN_MAGNITUDE, same logic as the window question but
#      for the magnitude gate.
#   5. The scene-coverage diagnostic (mean/p10 clear-obs/year) -- R port of
#      validate_backdating_scene_coverage.js -- that .js has been DELETED (2026-11-03), fully
#      superseded by this section, no standalone Code-Editor use to preserve.
#   6. Yearly expansion TREND comparison (Section 8) -- does our annual newly-dated area move in
#      the same year-to-year pattern as Barenblitt's own annual converted area (classifica), within
#      their shared study-area hull? A shape/trend question, distinct from (1)-(4)'s pixel-level
#      exact/+-1/+-2 accuracy scoring.
#   7. Backdating/classifier seam continuity check (Section 9) -- once Barenblitt's classifica
#      window ends (2017, fixed, no later years exist in their source data), does OUR growth stay
#      plausible comparing independently classified build_03 years (2017-2020, no backdating
#      involved) against the backdated series' own final-year growth? Flags a real discontinuity
#      at the handoff before b_04_rs_mining_panel.R stitches both eras into one panel.
#   8. Spatial vs TIMING disagreement with Barenblitt classifica (Section 10) -- splits "why does
#      our annual area differ from theirs" into whether we even recognize the same PIXEL as a mine
#      at all (spatial) vs, given both do, whether we agree on WHEN (timing) -- the plain
#      exact/+-1/+-2 scoring in (1)/(2) conflates both.
#
# NAMING (decided 2026-11-03): "diag_NN_*" = a decision-ready comparison/report script tied to one
# build_NN stage, re-run on change -- as opposed to "validate_*" (one-off interactive Code-Editor
# scripts) and "build_NN_*" (writes durable GEE assets). See also diag_03_temporal_consistency.R
# (renamed from validate_temporal_consistency_rules.R the same session).
#
# OUTPUT LOCATION (decided 2026-11-03): all CSVs this script reads or writes live in
# outputs/tables/backdating/, NOT data/raw/barenblitt/ -- that folder is reserved for Barenblitt's
# own original shapefiles (genuinely raw external data); these CSVs are OUR derived diagnostic
# exports, so they belong under outputs/ like every other derived table in this project
# (outputs/tables/ already holds this exact genre -- barenblitt_overlap.csv, fp_source_breakdown_
# 2022.csv, etc. -- backdating/ just groups this stage's growing set of variants together). The
# three CSVs produced earlier this session were moved there from data/raw/barenblitt/ accordingly.
#
# Functions 2 and 3 duplicate (don't source()) the relevant build_04_backdating.R logic (Sections
# 4-6/6b/8), per this project's convention that scripts coordinate through data artifacts, never
# by sourcing each other -- see CLAUDE.md.

pacman::p_load(here, tidyverse, conflicted)
conflicts_prefer(dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise, here::here)

OUT_DIR <- here("outputs", "tables", "backdating")
if (!dir.exists(OUT_DIR)) dir.create(OUT_DIR, recursive = TRUE)

#### 1. Local: score an already-downloaded classifica-comparison / dropout-diagnostic CSV ####
score_classifica_csv <- function(path, label) {
  d <- read_csv(path, col_types = cols(classifica = "i", onset_year = "i", .default = "c")) |>
    mutate(bar_year = 2000L + classifica, err = abs(onset_year - bar_year))
  tibble(
    method = label, n = nrow(d),
    exact = round(100 * mean(d$err == 0), 1),
    pm1   = round(100 * mean(d$err <= 1), 1),
    pm2   = round(100 * mean(d$err <= 2), 1)
  )
}

score_dropout_csv <- function(path) {
  read_csv(path, col_types = cols(.default = "c")) |>
    mutate(
      ever_mined_flag = as.integer(ever_mined_flag),
      max_mag         = as.numeric(max_mag),
      case = case_when(
        ever_mined_flag == 0L          ~ "not_ever_mined",
        is.na(max_mag) | max_mag < 100 ~ "no_confident_break",
        TRUE                            ~ "dated"
      )
    ) |>
    count(case) |>
    mutate(pct = round(100 * n / sum(n), 1))
}

report_existing_exports <- function(
  dropout_path = file.path(OUT_DIR, "build_04_dropout_diagnostic_landtrendr.csv")
) {
  # scores EVERY classifica-comparison CSV sitting in OUT_DIR, not just two fixed filenames --
  # covers both the old build_04_backdating.R naming (build_04_onset_vs_barenblitt_<method>.csv,
  # implicitly the 2000-2016 window) and the new diag04_<method>_min<...>_max<...>_anchor<...>.csv
  # naming from request_classifica_export()/fetch_classifica_export() -- so dropping a freshly
  # downloaded file into OUT_DIR and re-running this section picks it up automatically, no manual
  # path wiring needed.
  csvs <- list.files(OUT_DIR, pattern = "^(build_04_onset_vs_barenblitt_|diag04_).*\\.csv$", full.names = TRUE)
  csvs <- csvs[!grepl("dropout_diagnostic", csvs)]

  if (length(csvs) == 0) {
    message("No onset-vs-classifica CSVs found in ", OUT_DIR, " -- run build_04_backdating.R ",
            "Section 8 (RUN_ONSET_EXPORT <- TRUE) or request_classifica_export() below first.")
  } else {
    labels <- basename(csvs) |> str_remove("\\.csv$") |>
      str_remove("^build_04_onset_vs_barenblitt_") |> str_remove("^diag04_")
    comparison <- map2_dfr(csvs, labels, score_classifica_csv)
    cat("\n=== Classifica comparison (exact/+-1yr/+-2yr agreement with Barenblitt's own labels) ===\n")
    print(comparison, n = Inf)
    cat("NOTE: this measures agreement with Barenblitt's recorded conversion year (classifica), NOT\n",
        "their published .338/.694/.761 -- that figure is their algorithm vs independent analyst\n",
        "visual interpretation, a different and not-comparable reference.\n", sep = "")
  }

  if (file.exists(dropout_path)) {
    cat("\n=== LandTrendr dropout breakdown (why a classifica point didn't get scored) ===\n")
    print(score_dropout_csv(dropout_path), n = Inf)
    cat("not_ever_mined = no overlap with our footprint at all; no_confident_break = in footprint\n",
        "but the magnitude gate rejected it; dated = scored in the comparison table above.\n", sep = "")
  } else {
    message("No dropout-diagnostic CSV found at ", dropout_path, " -- run build_04_backdating.R ",
            "Section 8b (METHOD <- \"landtrendr\", RUN_DROPOUT_DIAGNOSTIC <- TRUE) first.")
  }
}

report_existing_exports()   # scores whatever's already in outputs/tables/backdating/ right now

#### 2. Environment (rgee) -- needed for everything below this point ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)
library(reticulate)
pacman::p_load(rgee, googledrive)

EE_PROJECT    <- "rgee-auth-tillam"   # ID, never the numeric project number
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
MASK_PREFIX   <- "mine_mask_ghana_c4_"
DRIVE_FOLDER  <- "ghana_mining_gee_exports"

ee_Authenticate()
ee_Initialize(drive = TRUE, project = EE_PROJECT)
# ee_Initialize(drive = TRUE) does NOT hand googledrive a working token on its own -- needs its
# own explicit auth call (same gotcha hit + fixed 2026-11-05 in diag_05_mining_by_region.qmd /
# b_04_rs_mining_panel.R), or drive_find()/drive_download() below silently run as the wrong
# Google account (or no account) and return zero matches.
googledrive::drive_auth()

# Resolve the export folder ONCE and list its contents, rather than a blind drive_find(pattern=)
# over the whole Drive (same idiom as build_02_embedding_classifier.R's score-export fallback,
# ported into diag_05/b_04 2026-11-05) -- more robust than fetch_classifica_export()'s original
# bare drive_find(), which was never actually exercised yet this session.
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

ghana <- ee$FeatureCollection(file.path(EE_ASSET_HOME, "rs05_ghana"))$geometry()

maskL2 <- function(img) {
  qa    <- img$select("QA_PIXEL")
  clear <- qa$bitwiseAnd(bitwShiftL(1L, 1L))$eq(0)$
    And(qa$bitwiseAnd(bitwShiftL(1L, 3L))$eq(0))$
    And(qa$bitwiseAnd(bitwShiftL(1L, 4L))$eq(0))
  sat <- img$select("QA_RADSAT")$eq(0)
  img$updateMask(clear)$updateMask(sat)
}

#### 3. Shared building blocks (ported from build_04_backdating.R Sections 4-6/6b/8 -- duplicated ####
#### on purpose, see header) ####
asset_exists <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)

build_ever_mined <- function(anchor_year) {
  mask_id10    <- file.path(EE_ASSET_HOME, paste0(MASK_PREFIX, anchor_year))
  mask_proj    <- ee$Image(mask_id10)$projection()
  landsat_proj <- ee$Projection("EPSG:32630")$atScale(30)
  ee$Image(mask_id10)$unmask(0)$
    setDefaultProjection(mask_proj)$
    reduceResolution(reducer = ee$Reducer$mean(), maxPixels = 64L)$
    reproject(landsat_proj)$
    gte(0.5)$
    selfMask()
}

ROY <- list(RED = list(s = 0.9047, i = 0.0061), NIR = list(s = 0.8462, i = 0.0412),
            SWIR2 = list(s = 0.9071, i = 0.0172))   # Roy et al. (2016), OLI -> ETM+

build_landsat_series <- function(ever_mined, img_start, img_end, region = ghana) {
  # `region` defaults to the whole country (fine for request_classifica_export()'s batch export --
  # batch tasks get distributed per-tile memory, no issue). quick_window_check() passes a small
  # region instead: filtering to all of Ghana's ~20yr x 3-sensor scene archive regardless of how
  # few points you're sampling is exactly what blows EE's much stricter INTERACTIVE compute memory
  # limit ("User memory limit exceeded", hit 2026-11-03) -- restricting bounds shrinks the
  # collection itself, not just the eventual sample count.
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
        sr$addBands(sr$normalizedDifference(c("NIR", "SWIR2"))$rename("NBR"))$
          addBands(sr$normalizedDifference(c("NIR", "RED"))$rename("NDVI"))$
          updateMask(ever_mined)$clip(region)$
          copyProperties(img, list("system:time_start"))
      })
  }
  tm <- c("SR_B3", "SR_B4", "SR_B7"); oli <- c("SR_B4", "SR_B5", "SR_B7")
  prep("LANDSAT/LT05/C02/T1_L2", tm, FALSE)$
    merge(prep("LANDSAT/LE07/C02/T1_L2", tm, FALSE))$
    merge(prep("LANDSAT/LC08/C02/T1_L2", oli, TRUE))
}

build_onset_year <- function(method, landsat, ever_mined, onset_min, onset_max, img_start, img_end,
                              min_magnitude = 100) {
  yrs <- img_start:img_end
  annual_composite <- function(yr, band, reducer) {
    ee$Image(landsat$filter(ee$Filter$calendarRange(yr, yr, "year"))$select(band)$reduce(reducer))$
      rename(band)$set("year", yr)
  }
  if (method == "landtrendr") {
    lt_series <- ee$ImageCollection(lapply(yrs, function(y) {
      annual_composite(y, "NBR", ee$Reducer$median())$multiply(-1000)$toInt()$rename("LOSS")$
        set("system:time_start", ee$Date$fromYMD(y, 7L, 1L)$millis())
    }))
    lt <- ee$Algorithms$TemporalSegmentation$LandTrendr(
      timeSeries = lt_series, maxSegments = 6L, spikeThreshold = 0.9, vertexCountOvershoot = 3L,
      preventOneYearRecovery = TRUE, recoveryThreshold = 0.25, pvalThreshold = 0.05,
      bestModelProportion = 0.75, minObservationsNeeded = 6L
    )
    arr    <- lt$select("LandTrendr")
    years  <- arr$arraySlice(0L, 0L, 1L)$arrayProject(list(1L))
    fitted <- arr$arraySlice(0L, 2L, 3L)$arrayProject(list(1L))
    delta  <- fitted$arraySlice(0L, 1L)$subtract(fitted$arraySlice(0L, 0L, -1L))
    d_year <- years$arraySlice(0L, 1L)
    in_win  <- d_year$gte(onset_min + 1L)$And(d_year$lte(onset_max))
    delta_w <- delta$arrayMask(in_win); year_w <- d_year$arrayMask(in_win)
    amax    <- delta_w$arrayArgmax()$arrayFlatten(list(list("i")))
    max_mag <- delta_w$arrayReduce(ee$Reducer$max(), list(0L))$arrayFlatten(list(list("m")))
    year_w$arrayGet(amax)$rename("onset_year")$
      updateMask(max_mag$gte(min_magnitude))$updateMask(ever_mined)$round()$toInt16()
  } else if (method == "barenblitt") {
    ndvi_max <- lapply(yrs, function(y) annual_composite(y, "NDVI", ee$Reducer$max()))
    names(ndvi_max) <- as.character(yrs)
    avg_years <- (img_start + 1L):(img_end - 1L)
    ndvi_avg <- lapply(avg_years, function(y) {
      ndvi_max[[as.character(y - 1L)]]$add(ndvi_max[[as.character(y)]])$add(ndvi_max[[as.character(y + 1L)]])$
        divide(3)$multiply(-1)$rename("NDVI_avg")
    })
    names(ndvi_avg) <- as.character(avg_years)
    deriv_years <- (min(avg_years) + 1L):max(avg_years)
    deriv_col <- ee$ImageCollection(lapply(deriv_years, function(y) {
      d <- ndvi_avg[[as.character(y)]]$subtract(ndvi_avg[[as.character(y - 1L)]])$rename("NDVI_deriv")
      d$addBands(ee$Image$constant(y)$toInt()$rename("Year"))$updateMask(ever_mined)
    }))
    qm <- deriv_col$qualityMosaic("NDVI_deriv")
    qm$select("Year")$
      updateMask(qm$select("Year")$gte(onset_min))$updateMask(qm$select("Year")$lte(onset_max))$
      updateMask(ever_mined)$toInt16()$rename("onset_year")
  } else stop('method must be "landtrendr" or "barenblitt"')
}

poll_task <- function(task, interval = 10) {
  # replaces rgee's ee_monitoring() -- that function errors ("character vector expected") trying
  # to read destination_uris while the task is still RUNNING, before that field is populated (hit
  # 2026-11-03, task EAIDOA6TDZ6URZIUXUKFPWWK). This only ever reads `state`, which is always safe.
  repeat {
    state <- ee$batch$Task$status(task)[["state"]]
    message("  task state: ", state, " (", format(Sys.time(), "%H:%M:%S"), ")")
    if (state %in% c("COMPLETED", "FAILED", "CANCELLED")) break
    Sys.sleep(interval)
  }
  if (state != "COMPLETED")
    stop("EE task ended in state '", state, "' -- check the Code Editor Tasks tab (project ",
         "rgee-auth-tillam) for the failure reason.")
  invisible(state)
}

load_conv_pts <- function(max_chunks = 10L) {
  pts_base      <- file.path(EE_ASSET_HOME, "barenblitt_conversion_pts")
  candidate_ids <- sprintf("%s_c%02d", pts_base, seq_len(max_chunks))
  exists_fn     <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)
  chunk_ids     <- Filter(exists_fn, candidate_ids)
  if (length(chunk_ids) == 0)
    stop("no barenblitt_conversion_pts_c* chunk assets found -- run build_04_backdating.R Section 8's ",
         "upload step first (one-time, independent of method/window/anchor).")
  Reduce(function(a, b) a$merge(b), lapply(chunk_ids, ee$FeatureCollection))
}

#### 4. Full automated run: submit -> block until done -> auto-download from Drive -> score ####
request_classifica_export <- function(method, onset_min, onset_max, anchor_year = 2017L,
                                       min_magnitude = 100, export_scale = 30L) {
  # min_magnitude only matters for method=="landtrendr" (barenblitt has no magnitude gate) -- suffix
  # the label with it ONLY when non-default, so default-100 runs keep the existing filenames already
  # on disk (no accidental cache-miss / re-download of files from earlier sessions) and only a real
  # magnitude-sweep run gets a distinguishing _mag<N> suffix.
  label <- sprintf("%s_min%d_max%d_anchor%d", method, onset_min, onset_max, anchor_year)
  if (method == "landtrendr" && min_magnitude != 100) label <- paste0(label, sprintf("_mag%d", min_magnitude))
  img_start <- onset_min - 1L; img_end <- onset_max + 2L   # same +-padding as build_04.R's fixed values

  message("Building onset_year for ", label, " ...")
  ever_mined <- build_ever_mined(anchor_year)
  landsat    <- build_landsat_series(ever_mined, img_start, img_end)
  onset_year <- build_onset_year(method, landsat, ever_mined, onset_min, onset_max, img_start, img_end,
                                  min_magnitude = min_magnitude)
  conv_pts   <- load_conv_pts()
  sampled    <- onset_year$sampleRegions(collection = conv_pts, properties = list("classifica"),
                                          scale = export_scale, tileScale = 8L)

  description <- paste0("diag04_", label)
  task <- ee_table_to_drive(collection = sampled$select(c("classifica", "onset_year")),
                             description = description, folder = DRIVE_FOLDER,
                             fileFormat = "CSV", timePrefix = FALSE)
  task$start()
  message("Submitted '", description, "' -- BLOCKING until the batch task finishes (minutes, not ",
          "seconds; the LandTrendr/Barenblitt computation over the full point set is the slow part). ",
          "The task keeps running on EE's side even if you interrupt this R session.")
  poll_task(task)
  fetch_classifica_export(method, onset_min, onset_max, anchor_year, min_magnitude = min_magnitude)
}

#### 4b. Recovery -- download+score an ALREADY-COMPLETED task without needing its R `task` object ####
# Use this directly if request_classifica_export() crashed/was interrupted AFTER submitting but
# BEFORE downloading (e.g. the poll_task()/ee_monitoring() crash on 2026-11-03) -- the GEE task
# itself keeps running/finishes independently of this R session, so nothing was lost; this just
# finds it on Drive by its deterministic filename (no task object needed) and picks up from there.
# Also what request_classifica_export() itself calls internally once polling confirms COMPLETED --
# one shared, independently-callable download+score path instead of two.
fetch_classifica_export <- function(method, onset_min, onset_max, anchor_year = 2017L, min_magnitude = 100) {
  label <- sprintf("%s_min%d_max%d_anchor%d", method, onset_min, onset_max, anchor_year)
  if (method == "landtrendr" && min_magnitude != 100) label <- paste0(label, sprintf("_mag%d", min_magnitude))
  description <- paste0("diag04_", label)
  dsn         <- file.path(OUT_DIR, paste0(description, ".csv"))

  message("Searching Drive folder '", DRIVE_FOLDER, "' for '", description, "' ...")
  if (!drive_download_export(description, dsn))
    stop("No file matching '", description, "' found in Drive folder '", DRIVE_FOLDER, "' -- confirm ",
         "the task actually shows COMPLETED in the Code Editor Tasks tab (project rgee-auth-tillam).")
  message("Downloaded to ", dsn)
  score_classifica_csv(dsn, label)
}

#### 5. Fast synchronous subsample check -- no Drive export, answers "is this worth a full run" ####
quick_window_check <- function(method, onset_min, onset_max, anchor_year = 2017L,
                                min_magnitude = 100, n_sample = 3000L, export_scale = 30L, seed = 1L) {
  img_start <- onset_min - 1L; img_end <- onset_max + 2L

  ever_mined <- build_ever_mined(anchor_year)
  # fixed `seed` -> the SAME n_sample points are drawn every call, so a sweep across min_magnitude
  # (or onset_min/onset_max) values is comparing the same point set each time, not re-sampling noise.
  conv_pts   <- load_conv_pts()$randomColumn("rand", seed)$sort("rand")$limit(n_sample)
  # bounding box of just the sampled points (+5km buffer so edge points keep full source pixels) --
  # NOT ghana -- filtering the Landsat collection to the whole country regardless of how few points
  # you're sampling is what blows EE's interactive memory limit (see build_landsat_series() note).
  region     <- conv_pts$geometry()$bounds()$buffer(5000)
  landsat    <- build_landsat_series(ever_mined, img_start, img_end, region = region)
  onset_year <- build_onset_year(method, landsat, ever_mined, onset_min, onset_max, img_start, img_end,
                                  min_magnitude = min_magnitude)
  sampled    <- onset_year$sampleRegions(collection = conv_pts, properties = list("classifica"),
                                          scale = export_scale, tileScale = 8L)

  message("Sampling ", n_sample, " points synchronously (getInfo(), no Drive export), restricted ",
          "to their bounding box (not national) -- should finish well under the ~5-min interactive ",
          "timeout at this size.")
  info <- sampled$select(c("classifica", "onset_year"))$getInfo()
  # sampleRegions() DROPS a feature wherever onset_year is masked there (see build_04_backdating.R's
  # Section 8b header comment) -- so nrow(d) out of n_sample IS the coverage number at this
  # min_magnitude: a stricter gate masks more pixels, so fewer of the n_sample points survive to be
  # scored at all. That's what magnitude_sweep() below reads as "coverage".
  d <- map_dfr(info$features, ~ as_tibble(.x$properties)) |>
    mutate(bar_year = 2000L + classifica, err = abs(onset_year - bar_year))

  tibble(
    method = sprintf("%s (subsample n_sample=%d, min=%d, max=%d, min_magnitude=%d)",
                      method, n_sample, onset_min, onset_max, min_magnitude),
    n_sample = n_sample,
    n = nrow(d),
    coverage_pct = round(100 * nrow(d) / n_sample, 1),
    exact = round(100 * mean(d$err == 0), 1),
    pm1   = round(100 * mean(d$err <= 1), 1),
    pm2   = round(100 * mean(d$err <= 2), 1)
  )
}

#### 6. Example: does matching Barenblitt's own 2007 start (vs our 2000) help? SETTLED 2026-11-04. ####
# ANSWER: yes -- ONSET_MIN <- 2007L adopted as the deployed default in build_04_backdating.R. See
# that script's own ONSET_MIN comment for the two converging lines of evidence (national classifica
# sweep here + the build_04_backdating_prototype.js big-disagreement check). Calls left below as a
# worked example of the quick-check-then-full-export pattern, not because the question is still open.
#quick_window_check(method = "barenblitt", onset_min = 2007, onset_max = 2016)
# quick_window_check(method = "landtrendr", onset_min = 2007, onset_max = 2016)
# -- if a window looks promising on the subsample, get the real national number:
# request_classifica_export(method = "barenblitt", onset_min = 2007, onset_max = 2016)
# request_classifica_export(method = "landtrendr", onset_min = 2007, onset_max = 2016)

#### 6b. LT_MIN_MAGNITUDE sweep -- coverage vs accuracy tradeoff, same quick-check-first pattern ####
# Same logic as Section 6, applied to LandTrendr's magnitude gate instead of the onset window.
# LT_MIN_MAGNITUDE is currently a single hand-picked constant (100, build_04_backdating.R) never
# formally tuned. quick_window_check()'s `n`/coverage_pct already measures coverage for free (a
# stricter gate masks more onset_year pixels, so sampleRegions() drops more of the fixed n_sample
# points -- see that function's header note) -- this just loops it over a range of thresholds with
# everything else (onset_min/max, anchor, the n_sample point set) held fixed, so the curve isn't
# confounded by anything else moving. barenblitt is NOT included -- it has no magnitude gate.
magnitude_sweep <- function(magnitudes = c(0, 25, 50, 75, 100, 150, 200, 300, 400),
                             onset_min = 2007L, onset_max = 2016L, anchor_year = 2017L,
                             n_sample = 3000L, seed = 1L) {
  map_dfr(magnitudes, function(m) {
    message("min_magnitude = ", m, " ...")
    quick_window_check(method = "landtrendr", onset_min = onset_min, onset_max = onset_max,
                        anchor_year = anchor_year, min_magnitude = m, n_sample = n_sample, seed = seed)
  }) |>
    mutate(min_magnitude = magnitudes, .before = 1)
}
# Not auto-run (EE calls). Usage:
sweep_result <- magnitude_sweep()
print(sweep_result, n = Inf)
# ggplot(sweep_result, aes(min_magnitude)) +
#   geom_line(aes(y = coverage_pct, color = "coverage")) +
#   geom_line(aes(y = exact, color = "exact")) + geom_line(aes(y = pm1, color = "+-1yr")) +
#   geom_line(aes(y = pm2, color = "+-2yr")) +
#   geom_vline(xintercept = 100, linetype = "dashed", color = "grey50") +   # current LT_MIN_MAGNITUDE
#   labs(y = "%", color = NULL, title = "LandTrendr min_magnitude: coverage vs accuracy tradeoff")
# -- once a candidate threshold looks like a real knee (not just n_sample=3000 noise), confirm at
# national scale the same way Section 6 confirmed the window:
# request_classifica_export(method = "landtrendr", onset_min = 2007, onset_max = 2016, min_magnitude = <N>)

#### 7. Scene-coverage per year (formerly validate_backdating_scene_coverage.js, now deleted) ####
ANCHOR_YEAR    <- 2017L   # matches build_04_backdating.R's MASK_YEARS decision (2026-11-03)
COVERAGE_YEARS <- 1999:2018

ever_mined_cov <- build_ever_mined(ANCHOR_YEAR)
landsat_cov <- ee$ImageCollection("LANDSAT/LT05/C02/T1_L2")$filterBounds(ghana)$
  filterDate("1999-01-01", "2019-01-01")$map(maskL2)$
  map(function(img) img$select(list("SR_B4"), list("NIR"))$updateMask(ever_mined_cov)$
        copyProperties(img, list("system:time_start")))$
  merge(ee$ImageCollection("LANDSAT/LE07/C02/T1_L2")$filterBounds(ghana)$
          filterDate("1999-01-01", "2019-01-01")$map(maskL2)$
          map(function(img) img$select(list("SR_B4"), list("NIR"))$updateMask(ever_mined_cov)$
                copyProperties(img, list("system:time_start"))))$
  merge(ee$ImageCollection("LANDSAT/LC08/C02/T1_L2")$filterBounds(ghana)$
          filterDate("1999-01-01", "2019-01-01")$map(maskL2)$
          map(function(img) img$select(list("SR_B5"), list("NIR"))$updateMask(ever_mined_cov)$
                copyProperties(img, list("system:time_start"))))

count_bands <- map(COVERAGE_YEARS, function(yr) {
  landsat_cov$filter(ee$Filter$calendarRange(yr, yr, "year"))$select("NIR")$count()$rename(paste0("n_", yr))
})
combined_cov <- ee$Image$cat(count_bands)

message("Computing mean + p10 clear-obs count per year, ", min(COVERAGE_YEARS), "-", max(COVERAGE_YEARS),
        ", over the ever-mined-as-of-", ANCHOR_YEAR, " footprint nationally (one reduceRegion call, ",
        "scale=300 -- should return in well under a minute).")

cov_reducer <- ee$Reducer$mean()$combine(reducer2 = ee$Reducer$percentile(list(10L)), sharedInputs = TRUE)
cov_stats <- combined_cov$reduceRegion(
  reducer = cov_reducer, geometry = ghana, scale = 300, maxPixels = 1e10, tileScale = 8L
)$getInfo()

coverage_df <- tibble(
  year       = COVERAGE_YEARS,
  mean_n_obs = map_dbl(COVERAGE_YEARS, ~ cov_stats[[paste0("n_", .x, "_mean")]]),
  p10_n_obs  = map_dbl(COVERAGE_YEARS, ~ cov_stats[[paste0("n_", .x, "_p10")]])
)
write_csv(coverage_df, file.path(OUT_DIR, paste0("scene_coverage_anchor", ANCHOR_YEAR, ".csv")))

cat("\n=== Clear Landsat observations/year, ever-mined-as-of-", ANCHOR_YEAR,
    " footprint (national) ===\n", sep = "")
coverage_df |>
  mutate(
    mean_n_obs = round(mean_n_obs, 1), p10_n_obs = round(p10_n_obs, 1),
    note = case_when(year == 2007 ~ "<- Barenblitt classifica starts here",
                      year == 2000 ~ "<- our current ONSET_MIN", TRUE ~ "")
  ) |>
  print(n = Inf)

p_coverage <- coverage_df |>
  pivot_longer(cols = c(mean_n_obs, p10_n_obs), names_to = "stat", values_to = "n_obs") |>
  mutate(stat = recode(stat, mean_n_obs = "mean", p10_n_obs = "p10 (worst-case tail)")) |>
  ggplot(aes(year, n_obs, color = stat)) +
  geom_vline(xintercept = c(2000, 2007), linetype = "dashed", color = "grey60") +
  annotate("text", x = 2000, y = Inf, label = "ONSET_MIN", vjust = 1.5, hjust = -0.1, size = 3, color = "grey40") +
  annotate("text", x = 2007, y = Inf, label = "Barenblitt starts", vjust = 1.5, hjust = -0.1, size = 3, color = "grey40") +
  geom_line(linewidth = 1) + geom_point(size = 2) +
  scale_color_manual(values = c("mean" = "#2171B5", "p10 (worst-case tail)" = "#D94701")) +
  labs(title = paste0("Clear Landsat observations/year, ever-mined-as-of-", ANCHOR_YEAR, " footprint"),
       x = NULL, y = "# clear observations", color = NULL) +
  theme_minimal(base_size = 12) + theme(legend.position = "bottom")
print(p_coverage)
ggsave(file.path(OUT_DIR, paste0("scene_coverage_anchor", ANCHOR_YEAR, ".png")), p_coverage,
       width = 8, height = 5)

cat("\nREAD THIS: if mean/p10 are flat (or rising) from 2000 through 2006 relative to 2007+, there is\n",
    "no data-driven reason to defer to Barenblitt's 2007 start. If 2000-2006 shows a clear drop --\n",
    "especially in p10, which is what actually bites LandTrendr's minObservationsNeeded=6 and\n",
    "Barenblitt's need for 4 consecutive clean years -- that's direct evidence for restricting\n",
    "ONSET_MIN to 2007 (or wherever the drop starts) via quick_window_check()/request_classifica_\n",
    "export() above, rather than matching Barenblitt's window by assumption alone.\n", sep = "")

#### 8. Yearly expansion TREND vs Barenblitt classifica (2026-11-05) ####
# Different question from Sections 4-6's point-level exact/+-1/+-2 scoring (same pixel, same
# year?) -- this asks whether our annual NEWLY-dated area moves in the same year-to-year PATTERN
# as Barenblitt's own annual converted area. A shape/trend comparison, not a pixel-level accuracy
# one. Restricted to bar_hull (Barenblitt's SW study-area convex hull, same construction as
# diag_03_product_overlap.R/validate_fp_source_breakdown.R's bar_hull) -- comparing against our
# NATIONAL total would be meaningless, Barenblitt never surveyed the north at all (CLAUDE.md:
# absent Barenblitt data there means "not surveyed", not "no mining").
#
# ASYMMETRIC by design (2026-11-05): our side covers the FULL 2005-2016 onset window (no
# reference_tier restriction -- that band exists to flag classifica-comparability, not to gate
# what we plot); Barenblitt's own classifica field simply has no data before 2007, so their line
# starts later and 2005-2006 are left NA (a real gap), never replace_na(0) -- a 0 would falsely
# claim "we know Barenblitt recorded zero conversions those years" when the truth is "classifica
# cannot speak to those years at all" (same distinction the reference_tier band itself encodes).
# Both sides stop at 2016 -- 2017+ is the embedding classifier's own job, a different method
# (Section 9 picks that up separately).
pacman::p_load(sf)
# s2 OFF -- raw Barenblitt geometries have degenerate/near-duplicate edges that trip s2's stricter
# validity checks on st_convex_hull()/st_transform() below (same gotcha documented in
# diag_03_product_overlap.R/validate_fp_source_breakdown.R's own bar_hull construction; hit here
# 2026-11-05 with "Loop 849 edge 0 has duplicate near loop 851 edge 1"). Planar ops are fine at
# this extent (one country-scale hull).
suppressMessages(sf_use_s2(FALSE))

FULL_YEARS    <- 2005:2016   # our side's full range; Barenblitt's own data determines where ITS
                              # line actually starts (see header) -- not imposed as a floor here.
SCALE_TREND   <- 30L   # native Landsat scale; falls back to 100 below if this times out

bar_ts_shp <- here("data", "raw", "barenblitt", "MiningConversion_2007-2017Vec.shp")
bar_ts     <- st_read(bar_ts_shp, quiet = TRUE) |> st_make_valid()

geom_as_ee <- function(x) {                      # attribute-free sf (lon/lat) -> ee FC
  g <- st_zm(st_geometry(x), drop = TRUE)
  g <- g[!st_is_empty(g)]
  sfx <- st_sf(geometry = g)
  st_crs(sfx) <- st_crs(4326)
  sf_as_ee(sfx)
}
bar_hull    <- bar_ts |> st_geometry() |> st_combine() |> st_convex_hull() |> st_transform(4326)
bar_hull_ee <- geom_as_ee(st_sf(geometry = bar_hull))$geometry()

bar_annual <- bar_ts |>
  mutate(year = 2000L + as.integer(classifica), km2 = as.numeric(st_area(geometry)) / 1e6) |>
  st_drop_geometry() |>
  filter(year <= max(FULL_YEARS)) |>   # exclude their 2017 (out of scope here, see header); no
  group_by(year) |>                     # lower bound imposed -- classifica simply has none before
  summarise(bar_km2 = sum(km2), .groups = "drop")   # 2007, so the line naturally starts there.

onset_img  <- ee$Image(file.path(EE_ASSET_HOME, "mine_onset_year_2005_2016_barenblitt"))
area_bands <- ee$Image$cat(lapply(FULL_YEARS, function(yr) {
  onset_img$select("onset_year")$eq(yr)$
    multiply(ee$Image$pixelArea())$divide(1e6)$rename(paste0("y", yr))
}))
reduce_trend <- function(scale) {
  area_bands$reduceRegion(reducer = ee$Reducer$sum(), geometry = bar_hull_ee, scale = scale,
                           maxPixels = 1e10, tileScale = 8L)$getInfo()
}
our_stats <- tryCatch(reduce_trend(SCALE_TREND), error = function(e) {
  message("scale=", SCALE_TREND, " timed out -- retrying at scale=100 (coarser, fine for a trend ",
          "comparison, not for exact area totals)")
  reduce_trend(100L)
})
our_annual <- tibble(year = FULL_YEARS, our_km2 = map_dbl(FULL_YEARS, ~ our_stats[[paste0("y", .x)]]))

# our side is always defined for every FULL_YEARS year (no NA risk); bar_km2/bar_cum are genuinely
# NA before Barenblitt's own data starts (2007) -- geom_line() skips NA, so the Barenblitt line
# will visibly "set in" at 2007 rather than falsely reading as zero mining before then. bar_cum
# restarts accumulating from Barenblitt's own first year, same reasoning.
trend <- left_join(our_annual, bar_annual, by = "year") |>
  arrange(year) |>
  mutate(
    our_cum = cumsum(our_km2),
    bar_cum = if_else(year < min(bar_annual$year), NA_real_, cumsum(replace_na(bar_km2, 0)))
  )
write_csv(trend, file.path(OUT_DIR, "yearly_expansion_vs_barenblitt.csv"))

cor_annual <- cor(trend$our_km2, trend$bar_km2, use = "complete.obs")   # 2007-2016 overlap only
cor_cum    <- cor(trend$our_cum, trend$bar_cum, use = "complete.obs")   # (Barenblitt's own range)

trend_long <- trend |>
  select(year, our_km2, bar_km2, our_cum, bar_cum) |>
  pivot_longer(-year, names_to = "series", values_to = "km2") |>
  mutate(
    source = if_else(str_starts(series, "our"), "Ours (RS backdating)", "Barenblitt classifica"),
    metric = if_else(str_ends(series, "cum"), "Cumulative", "Annual new area")
  )

p_trend <- ggplot(trend_long, aes(year, km2, color = source)) +
  geom_line(linewidth = 1) + geom_point(size = 2) +
  facet_wrap(~ metric, scales = "free_y", ncol = 1) +
  scale_color_manual(values = c("Ours (RS backdating)" = "#CD4071", "Barenblitt classifica" = "#450457")) +
  labs(title = "Mining expansion trend, 2005-2016 (Barenblitt study-area hull only)",
       subtitle = sprintf("Barenblitt classifica starts 2007 -- correlation over that overlap: annual r = %.2f, cumulative r = %.2f",
                           cor_annual, cor_cum),
       x = NULL, y = "Area (km2)", color = NULL) +
  theme_minimal(base_size = 12) + theme(legend.position = "bottom")
print(p_trend)
ggsave(file.path(OUT_DIR, "yearly_expansion_vs_barenblitt.png"), p_trend, width = 8, height = 7)

cat("\n=== Yearly expansion trend vs Barenblitt classifica (bar_hull only, our side 2005-2016, theirs 2007-2016) ===\n")
print(trend, n = Inf)
cat(sprintf("\nCorrelation, ANNUAL new area (2007-2016 overlap): r = %.2f\n", cor_annual))
cat(sprintf("Correlation, CUMULATIVE area (2007-2016 overlap):  r = %.2f\n", cor_cum))
cat("\nREAD THIS: this compares TRENDS (does the shape of expansion match), not pixel-level\n",
    "accuracy (Sections 4-6 already measure that -- see classifica comparison above). Caveats:\n",
    "(1) bar_hull-only, a national comparison would be meaningless (see header); (2) Barenblitt's\n",
    "own producer accuracy is ~75.6% -- a dip in THEIR recorded area some year may be under-\n",
    "labeling that year, not a real slowdown; (3) correlation is necessarily computed over their\n",
    "2007-2016 overlap only -- our 2005-2006 points have nothing to compare against.\n", sep = "")

#### 8c. Yearly expansion TREND at alternate ONSET_MIN windows (2026-11-06) ####
# Tests whether Section 8's apparent pileup at 2005-2006 (the two years with zero classifica
# cross-check) is a property of the METHOD (the floor moves with it) or specific to ONSET_MIN=2005.
# Two windows: onset_min=2000 (does the floor just move to ~2001-2003?) and onset_min=2007
# (Barenblitt's own window start -- directly comparable, no reference_tier=0 years at all).
#
# Prefers the REAL exported asset (mine_onset_year_{min}_{max}_barenblitt, built by a full
# build_04_backdating.R run at that ONSET_MIN/IMG_START -- see explainer.md) when it exists -- same
# full-resolution, full-national asset the 2005-2016 deploy used, not a cheaper approximation. Only
# falls back to recomputing onset_year_bar from scratch (via build_onset_year(), bar_hull-restricted,
# same as Section 4's request_classifica_export()) as an immediate rough check while that export is
# still running (each takes ~1hr) or hasn't been submitted yet.
run_yearly_expansion_trend <- function(onset_min, onset_max = 2016L, anchor_year = 2017L, scale = SCALE_TREND) {
  out_asset <- file.path(EE_ASSET_HOME, sprintf("mine_onset_year_%d_%d_barenblitt", onset_min, onset_max))
  if (asset_exists(out_asset)) {
    message("Using deployed asset ", out_asset, " (full national resolution).")
    onset_img <- ee$Image(out_asset)
  } else {
    message(out_asset, " not found -- recomputing on the fly over bar_hull only (rough check; ",
            "submit the real build_04_backdating.R export for the robust version).")
    # img_start = onset_min - 2L, NOT request_classifica_export()'s onset_min - 1L: build_onset_year()'s
    # "barenblitt" branch needs deriv_years to start AT onset_min itself (deriv_years starts at
    # img_start + 2) or the window's actual floor is silently pushed one year later than requested --
    # exactly the off-by-one that would confound this specific pileup-location question.
    img_start <- onset_min - 2L
    img_end   <- onset_max + 2L
    ever_mined <- build_ever_mined(anchor_year)
    # region = bar_hull_ee (not the default whole-of-Ghana `ghana`) -- this is a synchronous
    # interactive reduceRegion below, not a batch export; restricting the Landsat series to the hull
    # we're reducing over avoids the "User memory limit exceeded" interactive ceiling the header's
    # quick_window_check() note already warns about for national-extent interactive calls.
    landsat   <- build_landsat_series(ever_mined, img_start, img_end, region = bar_hull_ee)
    onset_img <- build_onset_year("barenblitt", landsat, ever_mined, onset_min, onset_max, img_start, img_end)
  }

  years <- onset_min:onset_max
  area_bands <- ee$Image$cat(lapply(years, function(yr) {
    onset_img$select("onset_year")$eq(yr)$
      multiply(ee$Image$pixelArea())$divide(1e6)$rename(paste0("y", yr))
  }))
  reduce_trend_x <- function(s) {
    area_bands$reduceRegion(reducer = ee$Reducer$sum(), geometry = bar_hull_ee, scale = s,
                             maxPixels = 1e10, tileScale = 8L)$getInfo()
  }
  stats <- tryCatch(reduce_trend_x(scale), error = function(e) {
    message("scale=", scale, " timed out -- retrying at scale=100")
    reduce_trend_x(100L)
  })
  our_annual_x <- tibble(year = years, our_km2 = map_dbl(years, ~ stats[[paste0("y", .x)]]))

  trend_x <- left_join(our_annual_x, bar_annual, by = "year") |>
    arrange(year) |>
    mutate(
      our_cum = cumsum(our_km2),
      bar_cum = if_else(year < min(bar_annual$year), NA_real_, cumsum(replace_na(bar_km2, 0)))
    )

  label <- sprintf("min%d_max%d", onset_min, onset_max)
  write_csv(trend_x, file.path(OUT_DIR, paste0("yearly_expansion_vs_barenblitt_", label, ".csv")))

  cor_annual_x <- cor(trend_x$our_km2, trend_x$bar_km2, use = "complete.obs")
  cor_cum_x    <- cor(trend_x$our_cum, trend_x$bar_cum, use = "complete.obs")

  trend_long_x <- trend_x |>
    select(year, our_km2, bar_km2, our_cum, bar_cum) |>
    pivot_longer(-year, names_to = "series", values_to = "km2") |>
    mutate(
      source = if_else(str_starts(series, "our"), "Ours (RS backdating)", "Barenblitt classifica"),
      metric = if_else(str_ends(series, "cum"), "Cumulative", "Annual new area")
    )
  p_trend_x <- ggplot(trend_long_x, aes(year, km2, color = source)) +
    geom_line(linewidth = 1) + geom_point(size = 2) +
    facet_wrap(~ metric, scales = "free_y", ncol = 1) +
    scale_color_manual(values = c("Ours (RS backdating)" = "#CD4071", "Barenblitt classifica" = "#450457")) +
    labs(title = sprintf("Mining expansion trend, %d-%d (Barenblitt study-area hull only)", onset_min, onset_max),
         subtitle = sprintf("Barenblitt classifica starts 2007 -- correlation over overlap: annual r = %.2f, cumulative r = %.2f",
                             cor_annual_x, cor_cum_x),
         x = NULL, y = "Area (km2)", color = NULL) +
    theme_minimal(base_size = 12) + theme(legend.position = "bottom")
  print(p_trend_x)
  ggsave(file.path(OUT_DIR, paste0("yearly_expansion_vs_barenblitt_", label, ".png")), p_trend_x, width = 8, height = 7)

  cat(sprintf("\n=== Yearly expansion trend vs Barenblitt classifica, ONSET_MIN=%d (bar_hull only) ===\n", onset_min))
  print(trend_x, n = Inf)
  cat(sprintf("\nCorrelation, ANNUAL (2007-2016 overlap): r = %.2f | CUMULATIVE: r = %.2f\n", cor_annual_x, cor_cum_x))
  invisible(trend_x)
}

trend_2000 <- run_yearly_expansion_trend(onset_min = 2000L)   # does the floor pileup just move to ~2001-2003?
trend_2007 <- run_yearly_expansion_trend(onset_min = 2007L)   # Barenblitt's own window -- directly comparable

#### 9. Continuity check at the backdating/classifier seam (2026-11-05) ####
# Barenblitt's classifica field is fixed at 2007-2017 (confirmed by Section 8's full year
# breakdown -- exactly 11 rows exist in the source shapefile, nothing earlier/later) -- there is
# no way to extend THEIR side.
#
# Our side CAN be extended past 2016, but NOT by comparing cumulative-onset-through-2016
# (trend$our_cum) against mine_mask_ghana_c4_2017 -- that's CIRCULAR, not a real transition: the
# onset layer's entire anchor footprint IS mine_mask_ghana_c4_2017 (reprojected to 30m), so "our
# 2017 total" is mechanically ~= cumulative-dated-through-2016 + the undated residual. There's no
# jump to find there by construction. The genuine test: do INDEPENDENTLY classified years
# (2017-2025, straight from build_03, zero backdating involved) continue growing at a plausible
# pace, or jump?
#
# trend$our_cum (Section 8) is already the FULL unrestricted 2005-2016 series -- Section 8 used
# to be restricted to reference_tier==1 and this section separately recomputed an unrestricted
# version just for itself; now that Section 8 itself is unrestricted (2026-11-05), reused here
# directly instead of a duplicate EE call.
EXT_YEARS <- 2017:2025   # full build_03 range, not just a few years past the seam

reduce_one <- function(img, scale) {
  img$reduceRegion(reducer = ee$Reducer$sum(), geometry = bar_hull_ee, scale = scale,
                    maxPixels = 1e10, tileScale = 8L)$getInfo()
}

running_ext <- ee$Image(0)$rename("cum")
ext_bands <- list()
for (yr in EXT_YEARS) {
  mine_yr      <- ee$Image(file.path(EE_ASSET_HOME, paste0(MASK_PREFIX, yr)))$unmask(0)
  running_ext  <- running_ext$Or(mine_yr)$rename(paste0("cum_", yr))
  ext_bands[[as.character(yr)]] <- running_ext$multiply(ee$Image$pixelArea())$divide(1e6)$rename(paste0("y", yr))
}
ext_img   <- ee$Image$cat(unname(ext_bands))   # ext_bands is a NAMED list (keyed by year, for the
                                                 # loop's own lookup) -- reticulate converts a named
                                                 # R list to a Python dict, which ee$Image$cat()
                                                 # rejects ("Unrecognized argument type ... dict");
                                                 # unname() strips that before the EE call.
ext_stats <- tryCatch(reduce_one(ext_img, SCALE_TREND), error = function(e) reduce_one(ext_img, 100L))
ext_cum   <- tibble(year = EXT_YEARS, cum_km2 = map_dbl(EXT_YEARS, ~ ext_stats[[paste0("y", .x)]]))

# Red = trend's full 2005-2016 backdated series (our_cum -- unrestricted since Section 8's own
# rewrite, 2026-11-05), blue = 2017-2025 classifier.
seam <- bind_rows(
  trend |> transmute(year, cum_km2 = our_cum, series = "backdated (2005-2016, full)"),
  ext_cum |> mutate(series = "build_03 classifier (independent, no backdating)")
) |> arrange(year) |> group_by(series) |> mutate(yoy_km2 = cum_km2 - dplyr::lag(cum_km2)) |> ungroup()

cat("\n=== Backdating/classifier seam, bar_hull only ===\n")
print(seam, n = Inf)
write_csv(seam, file.path(OUT_DIR, "backdating_classifier_seam.csv"))
cat(sprintf(
  paste0("\nREAD THIS: compare the 'build_03 classifier' series' own yoy_km2 values (2017-2025) to the\n",
         "backdated series' final-year growth (2015->2016 was +%.1f km2). If classifier-era growth looks\n",
         "wildly different in scale or keeps accelerating well past that, that's worth understanding before\n",
         "trusting a panel that stitches both eras together (b_04_rs_mining_panel.R) -- though note the\n",
         "very first blue point (2017) is NOT a clean comparison to the red line's last point: 2017 is\n",
         "measured at native 10m (no reprojection) while the backdated series is reprojected to 30m via\n",
         "majority rule (CLAUDE.md's 10m/30m resolution-seam caveat) -- so some of the apparent red-to-\n",
         "blue jump is a resolution artifact, not real growth. The genuine growth signal is the blue\n",
         "line's own slope, not the handoff point itself.\n"),
  trend$our_km2[trend$year == 2016]
))

p_seam <- seam |>
  ggplot(aes(year, cum_km2, color = series)) +
  geom_line(linewidth = 1) + geom_point(size = 2) +
  geom_vline(xintercept = 2016.5, linetype = "dashed", color = "grey50") +
  annotate("text", x = 2016.5, y = Inf, label = "backdating ends / classifier begins",
           vjust = 1.5, hjust = -0.05, size = 3, color = "grey40") +
  labs(title = "Cumulative mined area through the backdating/classifier seam (bar_hull only)",
       x = NULL, y = "Cumulative area (km2)", color = NULL) +
  theme_minimal(base_size = 12) + theme(legend.position = "bottom")
print(p_seam)
ggsave(file.path(OUT_DIR, "backdating_classifier_seam.png"), p_seam, width = 8, height = 5)

#### 10. Spatial vs TIMING disagreement with Barenblitt classifica (2026-11-05) ####
# Separates WHY annual area differs into two distinct questions, which Section 8's area trend and
# the plain classifica scoring (Sections 1/4) both conflate:
#   (a) SPATIAL -- does our classifier even recognize the same PIXEL as ever being a mine at all?
#   (b) TIMING  -- given both recognize it, do they agree on WHEN?
# Already known from local data alone (no EE needed, see conversation): of the 53793 total
# Barenblitt conversion points, only 37689 (70.1%) survive into the existing classifica CSV --
# sampleRegions() silently DROPS the rest because onset_img is masked there (our 2017 anchor has
# no mine at all at that location). That's a pure SPATIAL disagreement. This section splits that
# 29.9% further: never detected by us in ANY year 2017-2025 (a true spatial miss) vs detected,
# just LATER than our 2017 anchor (a build_03 detection-timing story, not backdating's fault).
# Reuses onset_img (already loaded in Section 8) -- no recomputation, just a different sample.
conv_pts_all <- load_conv_pts()

mask_ids_union   <- Filter(asset_exists, file.path(EE_ASSET_HOME, paste0(MASK_PREFIX, 2017:2025)))
ever_mined_union <- ee$ImageCollection(lapply(mask_ids_union, ee$Image))$
  map(function(im) im$unmask(0))$max()$rename("ever_mined_union_1725")   # 10m, 0/1, unmasked

# -1 = not even in the 2017 anchor (sentinel 0 is already "anchor but undated" -- see Section 12
# of build_04_backdating.R); unmask(-1) here, applied AFTER select(), turns "outside the anchor
# entirely" into its own visible category instead of a silently dropped row.
spatial_img <- onset_img$select("onset_year")$unmask(-1L)$rename("onset_year")$
  addBands(ever_mined_union)

spatial_sampled <- spatial_img$sampleRegions(collection = conv_pts_all, properties = list("classifica"),
                                              scale = 30L, tileScale = 8L)
spatial_task <- ee_table_to_drive(
  collection = spatial_sampled$select(c("classifica", "onset_year", "ever_mined_union_1725")),
  description = "diag04_spatial_vs_timing", folder = DRIVE_FOLDER, fileFormat = "CSV", timePrefix = FALSE)
spatial_task$start()
message("Submitted 'diag04_spatial_vs_timing' -- BLOCKING until done (all 53793 points, none dropped).")
poll_task(spatial_task)

spatial_dsn <- file.path(OUT_DIR, "diag04_spatial_vs_timing.csv")
if (!drive_download_export("diag04_spatial_vs_timing", spatial_dsn))
  stop("Export completed but file not found in Drive folder '", DRIVE_FOLDER, "' -- check manually.")

d_spatial <- read_csv(spatial_dsn, col_types = cols(classifica = "i", onset_year = "i",
                                                     ever_mined_union_1725 = "i")) |>
  mutate(
    bar_year = 2000L + classifica,
    case = case_when(
      onset_year == -1L & ever_mined_union_1725 == 0L ~ "never_detected (any year 2017-2025)",
      onset_year == -1L & ever_mined_union_1725 == 1L ~ "detected_later (not in 2017 anchor, but 2018-2025 union)",
      onset_year == 0L  ~ "anchor_but_undated",
      TRUE ~ "dated"
    )
  )

cat("\n=== Spatial breakdown: why a Barenblitt point isn't 'dated' at all ===\n")
d_spatial |> count(case) |> mutate(pct = round(100 * n / sum(n), 1)) |> print(n = Inf)

d_dated <- d_spatial |> filter(case == "dated") |> mutate(err = abs(onset_year - bar_year))
cat("\n=== TIMING agreement, CONDITIONAL on spatial agreement (the 'dated' rows only) ===\n")
tibble(
  n = nrow(d_dated),
  exact = round(100 * mean(d_dated$err == 0), 1),
  pm1   = round(100 * mean(d_dated$err <= 1), 1),
  pm2   = round(100 * mean(d_dated$err <= 2), 1)
) |> print()
cat("\nCompare this pm2 to the UNCONDITIONAL classifica scoring (report_existing_exports() above) --\n",
    "if conditional pm2 is notably higher, most of the earlier 60.6% number's shortfall was spatial\n",
    "disagreement dragging it down, not timing error on the pixels we actually agree are mines.\n",
    "If conditional pm2 is close to the same number, timing error is the real limiting factor even\n",
    "once spatial disagreement is set aside.\n", sep = "")
write_csv(d_spatial |> select(classifica, bar_year, onset_year, ever_mined_union_1725, case),
          file.path(OUT_DIR, "diag04_spatial_vs_timing_scored.csv"))

message("\n=== diag_04_backdating.R: done ===")
