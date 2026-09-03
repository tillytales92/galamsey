# build_04_backdating.R  -- SKETCH, RUN INTERACTIVELY, EXPECT TO DEBUG THE ARRAY OPS
# =============================================================================
# Backdate the 2017-2025 embedding-classifier mine footprint (build_03's
# mine_mask_ghana_c4_{yr}) to per-pixel ONSET YEARS for 2000-2016, by dating
# each ever-mined pixel's vegetation-loss break in the Landsat archive.
#
# TWO METHODS behind METHOD (Section 3):
#   "landtrendr"  (v1, deploy)  -- LandTrendr segmentation of an annual NBR series;
#                                  onset = year of the largest drop in the FITTED
#                                  (denoised) trajectory inside 2000-2016.
#   "barenblitt"  (v0, replication) -- Barenblitt et al. (2021) "NDVI Anomaly
#                                  Timeline" exactly: annual max-NDVI, 3-year
#                                  moving average, first difference, qualityMosaic
#                                  on the derivative -> year of steepest NDVI loss.
#                                  Ported from their GEE script
#                                  (abarenblitt/GhanaArtisanalMining, file
#                                  "Ghana NDVI Anomaly Timeline"), Collection 1 ->
#                                  Collection 2. Kept so our result is directly
#                                  comparable to their MiningConversion_2007-2017
#                                  layer and their reported 33.8% exact / 69.4%
#                                  +/-1yr / 76.1% +/-2yr accuracy.
#
# WHY LandTrendr over CCDC (decided 2026-09-03): the 2000-2016 window is Landsat 5
# + SLC-off Landsat 7 over a cloudy country -- often <10 clear obs/yr. CCDC's
# harmonic fit needs exactly the dense observations that era lacks; it is strong
# 2015+, which the embeddings already cover. LandTrendr needs only one composite
# per year, gives a disturbance MAGNITUDE (to drop weak/ambiguous breaks), and is
# far less parameter-fragile in low-data conditions. Barenblitt's own method is a
# degenerate LandTrendr (fixed 2-segment assumption + a 3yr smoother instead of a
# fitted trajectory) -- v0 here, not the deploy path.
#
# CAVEATS (carry into any output that uses the result):
#   - Only dates pixels still visible as mined in 2017+ (the anchor mask). Mines
#     that opened AND fully revegetated before 2017 never enter it.
#   - A break is a spectral DISTURBANCE, not necessarily the mining event: forest
#     clearing that PRECEDED mining on the same pixel dates the clearing.
#   - 30 m Landsat vs the 10 m mask: mask aggregated majority-mined per 30 m cell.
#   - Pre-2012 timing is biased early (sparse cloud-free imagery) -- Barenblitt say
#     the same of their own layer.
#
# Prereq: build_03_embedding_panel.R has exported mine_mask_ghana_c4_{2017..2025}.
# Run INTERACTIVELY: ee_Authenticate()/ee_Initialize() block on a browser login.
# Keep TUNE <- TRUE (clips to a small AOI) while checking the Section 6/7 array
# extraction against a known site; flip to FALSE only for the national export.
# =============================================================================

####1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, tidyverse, sf, here, conflicted)
conflicts_prefer(dplyr::filter, dplyr::select, dplyr::mutate, here::here)

UTM30N     <- 32630
EE_PROJECT <- "rgee-auth-tillam"   # ID, never the numeric project number

####2. Authenticate ####
rgee::ee_Authenticate()
rgee::ee_Initialize(drive = TRUE, project = EE_PROJECT)
ee_check()

####3. Parameters ####
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)

METHOD      <- "landtrendr"        # "landtrendr" (v1) | "barenblitt" (v0)
MASK_PREFIX <- "mine_mask_ghana_c4_"
MASK_YEARS  <- 2017:2025           # build_03 output years -> the anchor footprint

ONSET_MIN   <- 2000L               # output onset-year window (inclusive)
ONSET_MAX   <- 2016L               # 2017+ conversions are the embeddings' job
IMG_START   <- 1999L               # imagery window: padded so the 3-yr MA /
IMG_END     <- 2018L               # LandTrendr segments have context at the edges
EXPORT_SCALE <- 30L                # Landsat native

# LandTrendr (v1) -----------------------------------------------------------
LT_PARAMS <- list(
  maxSegments            = 6L,
  spikeThreshold         = 0.9,
  vertexCountOvershoot    = 3L,
  preventOneYearRecovery = TRUE,
  recoveryThreshold      = 0.25,
  pvalThreshold          = 0.05,
  bestModelProportion    = 0.75,
  minObservationsNeeded   = 6L
)
LT_MIN_MAGNITUDE <- 100            # min drop in inverted-NBR*1000 units to accept a
                                    # disturbance (drops trivial noise vertices);
                                    # tune against a known site in TUNE mode.

# Barenblitt (v0) ---------------------------------------------------------------
# no tunables -- the method is fixed by their script (3yr MA, first difference).

TUNE     <- TRUE
TUNE_AOI <- ee$Geometry$Rectangle(c(-2.05, 5.98, -1.87, 6.15))   # Awomaso
RUN_VALIDATION <- FALSE            # Section 8: score onset vs Barenblitt classifica

OUT_ASSET <- sprintf("%s/mine_onset_year_2000_2016_%s", EE_ASSET_HOME, METHOD)

ghana <- ee$FeatureCollection(file.path(EE_ASSET_HOME, "rs05_ghana"))$geometry()
aoi   <- if (TUNE) TUNE_AOI else ghana

asset_exists <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)

####4. Anchor footprint: union of build_03's annual masks, at 30 m ####
mask_ids <- file.path(EE_ASSET_HOME, sprintf("%s%d", MASK_PREFIX, MASK_YEARS))
mask_ids <- Filter(asset_exists, mask_ids)
if (length(mask_ids) == 0)
  stop("no mine_mask_ghana_c4_{yr} assets found -- run build_03_embedding_panel.R first")
message(sprintf("Anchor footprint from %d annual masks", length(mask_ids)))

ever_mined_10 <- ee$ImageCollection(lapply(mask_ids, ee$Image))$
  map(function(im) im$unmask(0))$max()$gt(0)                     # 10 m, 0/1

mask_proj <- ee$Image(mask_ids[[1]])$projection()                 # native 10 m grid
landsat_proj <- ee$Projection("EPSG:32630")$atScale(30)
ever_mined <- ever_mined_10$
  setDefaultProjection(mask_proj)$
  reduceResolution(reducer = ee$Reducer$mean(), maxPixels = 64L)$
  reproject(landsat_proj)$
  gte(0.5)$
  selfMask()

####5. Annual Landsat index series (C2 L2, cloud-masked, L8->L7 harmonised) ####
# QA_PIXEL bits (Collection 2): 1 dilated cloud, 3 cloud, 4 cloud shadow. (bit 2
# cirrus is L8-only -- skip it so it doesn't blank every L5/L7 scene.)
maskL2 <- function(img) {
  qa    <- img$select("QA_PIXEL")
  clear <- qa$bitwiseAnd(bitwShiftL(1L, 1L))$eq(0)$
    And(qa$bitwiseAnd(bitwShiftL(1L, 3L))$eq(0))$
    And(qa$bitwiseAnd(bitwShiftL(1L, 4L))$eq(0))
  sat <- img$select("QA_RADSAT")$eq(0)
  img$updateMask(clear)$updateMask(sat)
}
# Roy et al. (2016) OLS coefficients, OLI -> ETM+ (Table 2). Derived for C1 SR;
# applied to C2 SR here per community practice -- residual bias is small next to
# LandTrendr's segmentation tolerance. Only the bands NBR/NDVI need are corrected.
ROY <- list(RED   = list(s = 0.9047, i = 0.0061),
            NIR   = list(s = 0.8462, i = 0.0412),
            SWIR2 = list(s = 0.9071, i = 0.0172))

prep_col <- function(id, bands, is_oli) {
  ee$ImageCollection(id)$
    filterBounds(aoi)$
    filterDate(sprintf("%d-01-01", IMG_START), sprintf("%d-01-01", IMG_END + 1L))$
    map(maskL2)$
    map(function(img) {
      sr <- img$select(bands, c("RED", "NIR", "SWIR2"))$
        multiply(0.0000275)$add(-0.2)
      if (is_oli) {
        sr <- sr$select("RED")$multiply(ROY$RED$s)$add(ROY$RED$i)$
          addBands(sr$select("NIR")$multiply(ROY$NIR$s)$add(ROY$NIR$i))$
          addBands(sr$select("SWIR2")$multiply(ROY$SWIR2$s)$add(ROY$SWIR2$i))
      }
      sr$addBands(sr$normalizedDifference(c("NIR", "RED"))$rename("NDVI"))$
        addBands(sr$normalizedDifference(c("NIR", "SWIR2"))$rename("NBR"))$
        updateMask(ever_mined)$
        clip(aoi)$
        copyProperties(img, list("system:time_start"))
    })
}
tm  <- c("SR_B3", "SR_B4", "SR_B7")   # L5/L7: red, nir, swir2
oli <- c("SR_B4", "SR_B5", "SR_B7")   # L8:    red, nir, swir2
landsat <- prep_col("LANDSAT/LT05/C02/T1_L2", tm,  FALSE)$
  merge(prep_col("LANDSAT/LE07/C02/T1_L2", tm,  FALSE))$
  merge(prep_col("LANDSAT/LC08/C02/T1_L2", oli, TRUE))

# one composite per year --------------------------------------------------------
YRS <- IMG_START:IMG_END
annual_composite <- function(yr, band, reducer) {
  ee$Image(landsat$
    filter(ee$Filter$calendarRange(yr, yr, "year"))$
    select(band)$
    reduce(reducer))$
    rename(band)$
    set("year", yr)$
    set("system:time_start", ee$Date$fromYMD(yr, 7L, 1L)$millis())
}
# clear-obs density -- SW Ghana clouds + L7 SLC-off make this the FIRST thing to
# check before trusting any onset year.
n_obs <- landsat$select("NIR")$count()

# =============================================================================
####6. METHOD "landtrendr" -- onset = year of largest FITTED NBR drop ####
# =============================================================================
if (METHOD == "landtrendr") {

  # LandTrendr wants the segmentation index oriented so vegetation LOSS = an
  # INCREASE. NBR drops on disturbance, so feed -NBR (scaled to integer-ish units).
  lt_series <- ee$ImageCollection(lapply(YRS, function(y) {
    annual_composite(y, "NBR", ee$Reducer$median())$
      multiply(-1000)$toInt()$rename("LOSS")$
      set("system:time_start", ee$Date$fromYMD(y, 7L, 1L)$millis())
  }))

  lt <- ee$Algorithms$TemporalSegmentation$LandTrendr(
    timeSeries             = lt_series,
    maxSegments            = LT_PARAMS$maxSegments,
    spikeThreshold         = LT_PARAMS$spikeThreshold,
    vertexCountOvershoot    = LT_PARAMS$vertexCountOvershoot,
    preventOneYearRecovery = LT_PARAMS$preventOneYearRecovery,
    recoveryThreshold      = LT_PARAMS$recoveryThreshold,
    pvalThreshold          = LT_PARAMS$pvalThreshold,
    bestModelProportion    = LT_PARAMS$bestModelProportion,
    minObservationsNeeded   = LT_PARAMS$minObservationsNeeded
  )

  # lt$select("LandTrendr") is a 2D array band: 4 rows x nYears cols
  #   row 0 = year, row 1 = source (-NBR*1000), row 2 = FITTED, row 3 = isVertex.
  # We take the FITTED row (denoised), difference consecutive years, and pick the
  # single largest year-over-year rise (= NBR drop = vegetation loss). This is
  # deliberately the same "argmax of the derivative" extraction Barenblitt use --
  # just on the LandTrendr-fitted trajectory instead of a 3yr moving average.
  arr    <- lt$select("LandTrendr")
  years  <- arr$arraySlice(0L, 0L, 1L)                 # 1 x nYears
  fitted <- arr$arraySlice(0L, 2L, 3L)                 # 1 x nYears

  fit_lo <- fitted$arraySlice(1L, 0L, -1L)             # years 0..n-2
  fit_hi <- fitted$arraySlice(1L, 1L)                  # years 1..n-1
  delta  <- fit_hi$subtract(fit_lo)                    # loss between t-1 and t (+ = loss)
  d_year <- years$arraySlice(1L, 1L)                   # the later year t

  in_win  <- d_year$gte(ONSET_MIN + 1L)$And(d_year$lte(ONSET_MAX))
  delta_w <- delta$arrayMask(in_win)
  year_w  <- d_year$arrayMask(in_win)

  amax    <- delta_w$arrayArgmax()$arrayFlatten(list(list("i")))          # scalar idx
  max_mag <- delta_w$arrayReduce(ee$Reducer$max(), list(0L))$arrayFlatten(list(list("m")))
  onset   <- year_w$arrayGet(amax)$rename("onset_year")

  onset_year <- onset$
    updateMask(max_mag$gte(LT_MIN_MAGNITUDE))$
    updateMask(ever_mined)$
    round()$toInt16()
}

# =============================================================================
####6b. METHOD "barenblitt" -- their "NDVI Anomaly Timeline", C1 -> C2 ####
# =============================================================================
if (METHOD == "barenblitt") {

  # Their step 4: annual MAX-NDVI (greenest pixel of the year).
  ndvi_max <- lapply(YRS, function(y) annual_composite(y, "NDVI", ee$Reducer$max()))
  names(ndvi_max) <- as.character(YRS)

  # 3-year moving average, x -1 so a decline reads positive (NDVI_avg).
  # only defined for interior years -> IMG_START+1 .. IMG_END-1
  avg_years <- (IMG_START + 1L):(IMG_END - 1L)
  ndvi_avg <- lapply(avg_years, function(y) {
    a <- ndvi_max[[as.character(y - 1L)]]
    b <- ndvi_max[[as.character(y)]]
    c <- ndvi_max[[as.character(y + 1L)]]
    a$add(b)$add(c)$divide(3)$multiply(-1)$rename("NDVI_avg")$set("year", y)
  })
  names(ndvi_avg) <- as.character(avg_years)

  # first difference NDVI_deriv[y] = NDVI_avg[y] - NDVI_avg[y-1]; carry Year band.
  deriv_years <- (min(avg_years) + 1L):max(avg_years)
  deriv_col <- ee$ImageCollection(lapply(deriv_years, function(y) {
    d <- ndvi_avg[[as.character(y)]]$select("NDVI_avg")$
      subtract(ndvi_avg[[as.character(y - 1L)]]$select("NDVI_avg"))$
      rename("NDVI_deriv")
    d$addBands(ee$Image$constant(y)$toInt()$rename("Year"))$updateMask(ever_mined)
  }))

  # qualityMosaic: per pixel keep the year with the max derivative (steepest loss).
  qm    <- deriv_col$qualityMosaic("NDVI_deriv")
  onset_year <- qm$select("Year")$
    updateMask(qm$select("Year")$gte(ONSET_MIN))$
    updateMask(qm$select("Year")$lte(ONSET_MAX))$
    updateMask(ever_mined)$
    toInt16()$rename("onset_year")
}

####7. Inspect (TUNE mode) ####
Map$centerObject(TUNE_AOI, 12)
Map$addLayer(n_obs, list(min = 0, max = 400, palette = c("red", "yellow", "green")),
             "clear-obs count", FALSE)
Map$addLayer(ever_mined, list(palette = "grey"), "ever mined 2017-2025", FALSE)
Map$addLayer(onset_year,
             list(min = ONSET_MIN, max = ONSET_MAX,
                  palette = c("#450457", "#8b5a9e", "#d94fd0", "#f9c5dd", "#FCFDBF")),
             sprintf("onset year 2000-2016 (%s)", METHOD))
message("Inspect a known site: onset should match the visible clearing year in a ",
        "Landsat median time-slider, and be flat/plausible across neighbours.")

####8. Validation vs Barenblitt classifica (RUN_VALIDATION) ####
# Barenblitt MiningConversion_2007-2017Vec: classifica = 2-digit conversion year
# (07..17 -> 2007..2017). Overlap with our window is 2007-2016. Upload the annual
# polygons as POINTS (point-on-surface, tiny) once, then sample our onset raster.
if (RUN_VALIDATION) {
  pts_id <- file.path(EE_ASSET_HOME, "barenblitt_conversion_pts")
  if (!asset_exists(pts_id)) {
    message("Uploading barenblitt_conversion_pts (one point per annual polygon)...")
    conv <- st_read(here("data", "raw", "barenblitt", "MiningConversion_2007-2017Vec.shp"),
                    quiet = TRUE) |>
      st_make_valid() |>
      transmute(classifica = as.integer(classifica)) |>
      st_point_on_surface() |>
      st_transform(4326)
    # chunked table upload (same rationale as build_02 Section 5) -- ~54k points
    n <- nrow(conv); k <- 10000L
    for (i in seq_len(ceiling(n / k))) {
      idx <- ((i - 1L) * k + 1L):min(i * k, n)
      tmp_id <- sprintf("%s_c%02d", pts_id, i)
      if (!asset_exists(tmp_id)) {
        t <- ee$batch$Export$table$toAsset(collection = sf_as_ee(conv[idx, ]),
                                           description = sprintf("bconv_c%02d", i),
                                           assetId = tmp_id)
        t$start(); message("  submitted chunk ", i, " -- wait for COMPLETED, then re-run")
      }
    }
    stop("chunk uploads submitted -- re-run Section 8 once they show COMPLETED to merge + sample")
  }

  conv_pts <- ee$FeatureCollection(pts_id)
  sampled  <- onset_year$sampleRegions(collection = conv_pts,
                                       properties = list("classifica"),
                                       scale = EXPORT_SCALE, tileScale = 8L)
  task <- ee$batch$Export$table$toDrive(
    collection = sampled$select(c("classifica", "onset_year")),
    description = sprintf("build_04_onset_vs_barenblitt_%s", METHOD),
    folder = "ghana_mining_gee_exports", fileFormat = "CSV")
  task$start()
  message("Submitted onset-vs-classifica sample export. Once downloaded, score in R:\n",
          "  d <- readr::read_csv(<file>)\n",
          "  d$bar_year <- 2000 + d$classifica\n",
          "  d$err <- abs(d$onset_year - d$bar_year)\n",
          "  mean(d$err == 0); mean(d$err <= 1); mean(d$err <= 2)   # vs Barenblitt .338/.694/.761")
}

####9. Export national onset raster (flip TUNE <- FALSE first) ####
if (!TUNE) {
  if (asset_exists(OUT_ASSET)) {
    message("[skip] ", OUT_ASSET, " exists -- delete it to re-export")
  } else {
    task <- ee$batch$Export$image$toAsset(
      image            = onset_year$unmask(0)$updateMask(ever_mined)$toInt16(),  # 0 = undated
      description      = sprintf("mine_onset_year_2000_2016_%s", METHOD),
      assetId          = OUT_ASSET,
      region           = ghana$bounds(),
      scale            = EXPORT_SCALE,
      crs              = "EPSG:4326",
      maxPixels        = 1e13,
      pyramidingPolicy = list(".default" = "mode")   # categorical years
    )
    task$start()
    message("Submitted: ", OUT_ASSET, "  (0 = ever-mined but undated: converted 2017+, ",
            "or pre-2000, or disturbance magnitude below LT_MIN_MAGNITUDE)")
  }
}

# NEXT (separate script): merge mine_onset_year_2000_2016_{METHOD} (2000-2016) with
# build_03's mine_mask_ghana_c4_{2017..2025} into one continuous annual "mined"
# surface 2000-2025, then aggregate to the hex x year panel (b_01_cross_section grid).
message("\n=== build_04_backdating.R (", METHOD, "): done ===")
