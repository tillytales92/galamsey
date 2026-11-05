# build_04_backdating.R -- SKETCH, RUN INTERACTIVELY, EXPECT TO DEBUG THE ARRAY OPS
# Backdates the 2017-2025 embedding-classifier mine footprint (build_03's
# mine_mask_ghana_c4_{yr}) to per-pixel ONSET YEARS for ONSET_MIN-2016, by dating each
# ever-mined pixel's vegetation-loss break in the Landsat archive.
#
# Two methods, both always computed:
#   - Barenblitt replica (Section 7) -- DEPLOYED (Section 12). Annual max-NDVI -> 3yr
#     moving average -> first difference -> qualityMosaic picks the steepest-loss year.
#     No magnitude gate (always assigns a year). Ported from Barenblitt et al. (2021)'s
#     own GEE script (abarenblitt/GhanaArtisanalMining). Chosen as deploy over LandTrendr
#     because its tolerance accuracy (+-1/+-2yr) against `classifica` matches or beats
#     LandTrendr's, and it dates ~93-100% of the footprint vs LandTrendr's ~32-34%.
#   - LandTrendr (Section 6) -- cross-check only, NOT deployed. Segmentation of an
#     annual -NBR series; onset = year of the largest drop in the fitted trajectory,
#     gated by LT_MIN_MAGNITUDE. Chosen over CCDC (too data-hungry for this era's sparse
#     Landsat 5/7 imagery). Feeds `lt_agree` (Section 8), a confidence flag on the
#     deployed Barenblitt dates.
#
# CAVEATS:
#   - Only dates pixels still visible as mined in 2017+ (the anchor mask).
#   - A break is a spectral DISTURBANCE, not necessarily the mining event itself.
#   - 30 m Landsat vs the 10 m mask: aggregated majority-mined per 30 m cell.
#   - NOT validated against ground truth. `classifica` (Section 10) is Barenblitt's own
#     algorithm's output -- agreement with it means agreement with another algorithm,
#     nothing stronger. See `reference_tier`, Section 8.
#
# Prereq: build_03_embedding_panel.R has exported mine_mask_ghana_c4_{2017..2025}.
# Run INTERACTIVELY: ee_Authenticate()/ee_Initialize() block on a browser login.
# TUNE <- TRUE clips everything (including Sections 8/8b/9) to TUNE_AOI for fast
# iteration -- flip to FALSE only once you're ready for the full national run.

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

METHOD <- "barenblitt"   # "landtrendr" | "barenblitt" -- which method's classifica CSV Section
                          # 8/8b exports (deploy is always barenblitt, see header; this doesn't
                          # change that).

MASK_PREFIX <- "mine_mask_ghana_c4_"
MASK_YEARS  <- 2017L   # anchor = mined-as-of-2017 only, not the 2017-2025 union -- a pixel first
                        # mined in 2018+ is already correctly dated by build_03 itself, and
                        # including it here would just force a spurious "no break"/invented
                        # pre-2017 onset.

ONSET_MIN <- 2005L   # output onset-year window start. Compromise between Barenblitt's own 2007
                      # start and the original 2000: classifica agreement improves at 2007, but
                      # that's mostly a label-floor artifact (classifica never has a year < 2007)
                      # rather than evidence 2000-2006 imagery is worse -- scene-coverage data
                      # shows no real cliff at 2007, only at 2013 (Landsat 8). See `reference_tier`
                      # (Section 8): nothing dated 2005-2006 has ANY classifica comparison at all.
ONSET_MAX <- 2016L   # 2017+ conversions are the embeddings' job
IMG_START <- 1999L   # imagery context window (padding for the 3yr MA / LandTrendr fit),
                      # independent of ONSET_MIN -- candidate onset years are gated separately.
IMG_END   <- 2018L
EXPORT_SCALE <- 30L   # Landsat native

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
LT_MIN_MAGNITUDE <- 100   # min drop in inverted-NBR*1000 units to accept a disturbance

TUNE <- FALSE   # TRUE clips to TUNE_AOI for fast iteration. Sections 10/11/12 are all guarded by
                # !TUNE below -- conv_pts spans the whole SW hull, so running them against an
                # AOI-restricted onset raster would silently return near-empty results.
TUNE_AOI <- ee$Geometry$Rectangle(c(-2.05, 5.98, -1.87, 6.15))   # Awomaso

RUN_ONSET_EXPORT       <- TRUE    # submit Section 10's onset-vs-classifica CSV for METHOD
RUN_VALIDATION         <- TRUE    # upload/merge the classifica validation points (Section 10)
RUN_DROPOUT_DIAGNOSTIC <- TRUE    # submit Section 11's LandTrendr dropout breakdown
RUN_NATIONAL_EXPORT    <- TRUE   # submit the deployed 4-band national asset (Section 12)

OUT_ASSET <- sprintf("%s/mine_onset_year_%d_%d_barenblitt", EE_ASSET_HOME, ONSET_MIN, ONSET_MAX)

ghana <- ee$FeatureCollection(file.path(EE_ASSET_HOME, "rs05_ghana"))$geometry()
aoi   <- if (TUNE) TUNE_AOI else ghana

asset_exists <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)

####4. Anchor footprint: mined-as-of-2017 (MASK_YEARS), at 30 m ####
mask_ids <- file.path(EE_ASSET_HOME, sprintf("%s%d", MASK_PREFIX, MASK_YEARS))
mask_ids <- Filter(asset_exists, mask_ids)
if (length(mask_ids) == 0)
  stop("no mine_mask_ghana_c4_{yr} assets found -- run build_03_embedding_panel.R first")
message(sprintf("Anchor footprint from %d annual mask(s)", length(mask_ids)))

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

####6. LandTrendr -- onset = year of largest FITTED NBR drop. Cross-check only (see header). ####
{
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
  # single largest year-over-year rise (= NBR drop = vegetation loss).
  arr    <- lt$select("LandTrendr")
  # arraySlice(0, ...) leaves a redundant length-1 axis-0 -- arrayProject(1) drops it so these
  # become true 1D time series. Without this, arrayArgmax()/arrayFlatten() error with
  # "Coordinate labels had 1 lists of names, but image has 2 dimensions".
  years  <- arr$arraySlice(0L, 0L, 1L)$arrayProject(list(1L))   # nYears
  fitted <- arr$arraySlice(0L, 2L, 3L)$arrayProject(list(1L))   # nYears

  fit_lo <- fitted$arraySlice(0L, 0L, -1L)             # years 0..n-2
  fit_hi <- fitted$arraySlice(0L, 1L)                  # years 1..n-1
  delta  <- fit_hi$subtract(fit_lo)                    # loss between t-1 and t (+ = loss)
  d_year <- years$arraySlice(0L, 1L)                   # the later year t

  in_win  <- d_year$gte(ONSET_MIN + 1L)$And(d_year$lte(ONSET_MAX))
  delta_w <- delta$arrayMask(in_win)
  year_w  <- d_year$arrayMask(in_win)

  amax         <- delta_w$arrayArgmax()$arrayFlatten(list(list("i")))
  max_mag_lt   <- delta_w$arrayReduce(ee$Reducer$max(), list(0L))$arrayFlatten(list(list("m")))
  onset_lt_raw <- year_w$arrayGet(amax)$rename("onset_year")   # pre-mask, used by Section 11

  onset_year_lt <- onset_lt_raw$
    updateMask(max_mag_lt$gte(LT_MIN_MAGNITUDE))$
    updateMask(ever_mined)$
    round()$toInt16()
}

####7. Barenblitt -- their "NDVI Anomaly Timeline", C1 -> C2. DEPLOYED (Section 12). ####
{
  # Their step 4: annual MAX-NDVI (greenest pixel of the year).
  ndvi_max <- lapply(YRS, function(y) annual_composite(y, "NDVI", ee$Reducer$max()))
  names(ndvi_max) <- as.character(YRS)

  # 3-year moving average, x -1 so a decline reads positive (NDVI_avg).
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
  qm <- deriv_col$qualityMosaic("NDVI_deriv")
  bar_in_window <- qm$select("Year")$gte(ONSET_MIN)$And(qm$select("Year")$lte(ONSET_MAX))

  onset_year_bar <- qm$select("Year")$
    updateMask(bar_in_window)$
    updateMask(ever_mined)$
    toInt16()$rename("onset_year")

  # Magnitude of the derivative that WON the qualityMosaic pick -- same role as LandTrendr's
  # max_mag_lt. Barenblitt's method has no gate, so a near-zero value flags likely noise.
  ndvi_deriv_bar <- qm$select("NDVI_deriv")$
    updateMask(bar_in_window)$
    updateMask(ever_mined)$
    rename("ndvi_deriv")
}

####8. Confidence/uncertainty bands for the deployed Barenblitt onset layer ####
# None of this is ground-truth validation (see header) -- these flag uncertainty, not resolve it.
#   reference_tier: 0 = no_reference (onset 2005-2006, no classifica comparison possible at all),
#                   1 = classifica_comparable (onset >= 2007), 9 = undated sentinel (Section 12).
#   ndvi_deriv (Section 7): continuous confidence score, no fixed cutoff applied here.
#   lt_agree: 0 = agree (LandTrendr cleared its own gate, within +-2yr of Barenblitt),
#             1 = disagree (LandTrendr cleared its gate, >2yr off), 2 = no_lt_signal (LandTrendr
#             found no confident break), 9 = undated sentinel.
bar_dated <- onset_year_bar$mask()

reference_tier <- ee$Image$constant(0L)$toInt16()$rename("reference_tier")$
  where(onset_year_bar$gte(2007L), ee$Image$constant(1L))$
  updateMask(bar_dated)

lt_cleared      <- onset_year_lt$mask()           # LandTrendr cleared its own LT_MIN_MAGNITUDE gate
onset_lt_filled <- onset_year_lt$unmask(-9999)     # sentinel so the diff below never sees a masked value
lt_diff         <- onset_lt_filled$subtract(onset_year_bar)$abs()

lt_agree <- ee$Image$constant(2L)$toInt16()$rename("lt_agree")$              # default: no_lt_signal
  where(lt_cleared, ee$Image$constant(1L))$                                  # LT fired: default disagree
  where(lt_cleared$And(lt_diff$lte(2L)), ee$Image$constant(0L))$             # LT fired, within +-2yr: agree
  updateMask(bar_dated)

####9. Quick sanity-check sample (TUNE mode only) ####
# A numeric preview of what the deployed raster (Section 12) would look like, for a handful of
# ever-mined pixels in TUNE_AOI -- not a map (build_04_backdating_prototype.js already covers
# that), just the band values side by side so the reference_tier/2007 boundary, ndvi_deriv's
# scale, and lt_agree's categories can be eyeballed before committing to a national export.
if (TUNE) {
  sample_img <- onset_year_bar$rename("onset_bar")$
    addBands(ndvi_deriv_bar$multiply(1000)$round()$rename("ndvi_deriv_x1000"))$
    addBands(reference_tier)$
    addBands(lt_agree)$
    addBands(onset_year_lt$rename("onset_lt"))

  # numPixels is drawn from the WHOLE TUNE_AOI bounding box, then dropNulls discards anything
  # that misses the (much smaller) mined footprint -- so this needs to be large relative to how
  # sparse mining is in the box, not just the number of rows actually wanted.
  sample_pts <- sample_img$sample(region = TUNE_AOI, scale = EXPORT_SCALE,
                                   numPixels = 3000, seed = 1, geometries = FALSE, dropNulls = TRUE)
  tune_check <- purrr::map_dfr(sample_pts$getInfo()$features, ~ tibble::as_tibble(.x$properties))
  print(tune_check, n = Inf)

  if (nrow(tune_check) > 0) {
    print(ggplot(tune_check, aes(onset_bar, fill = factor(reference_tier))) +
      geom_histogram(binwidth = 1, boundary = 0) +
      scale_fill_manual(values = c("0" = "#d94fd0", "1" = "#450457"),
                         labels = c("0" = "no_reference", "1" = "classifica_comparable"),
                         name = "reference_tier") +
      labs(title = "TUNE sample: Barenblitt onset year", x = "onset_bar", y = "count") +
      theme_minimal())

    lt_compare <- tune_check |> filter(!is.na(onset_lt)) |> mutate(diff = onset_bar - onset_lt)
    if (nrow(lt_compare) > 0) {
      print(ggplot(lt_compare, aes(diff, fill = factor(lt_agree))) +
        geom_histogram(binwidth = 1, boundary = 0) +
        scale_fill_manual(values = c("0" = "#2171B5", "1" = "#D94701"),
                           labels = c("0" = "agree (<=2yr)", "1" = "disagree (>2yr)"),
                           name = "lt_agree") +
        labs(title = "TUNE sample: Barenblitt - LandTrendr onset year", x = "onset_bar - onset_lt", y = "count") +
        theme_minimal())
    } else {
      message("No pixels with onset_lt defined in this sample -- LandTrendr didn't clear its ",
              "magnitude gate anywhere in the current draw.")
    }
  }
}

####10. Validation vs Barenblitt classifica (RUN_VALIDATION) ####
# classifica = 2-digit conversion year (07..17 -> 2007..2017). Upload the annual polygons as
# points (one per polygon) once, then sample the onset raster at each. Guarded by !TUNE --
# conv_pts spans the whole SW hull, not just TUNE_AOI (see TUNE's own comment).
if (!TUNE && RUN_VALIDATION) {
  pts_base <- file.path(EE_ASSET_HOME, "barenblitt_conversion_pts")
  conv_shp <- here("data", "raw", "barenblitt", "MiningConversion_2007-2017Vec.shp")
  n_conv   <- nrow(st_read(conv_shp, quiet = TRUE))    # cheap: row count only
  k        <- 10000L
  chunk_ids <- sprintf("%s_c%02d", pts_base, seq_len(ceiling(n_conv / k)))
  chunk_missing <- !vapply(chunk_ids, asset_exists, logical(1))

  if (any(chunk_missing)) {
    message("Uploading barenblitt_conversion_pts (one point per annual polygon)...")
    conv <- st_read(conv_shp, quiet = TRUE) |>
      st_make_valid() |>
      transmute(classifica = as.integer(classifica)) |>
      st_point_on_surface() |>
      st_transform(4326)
    for (i in which(chunk_missing)) {
      idx <- ((i - 1L) * k + 1L):min(i * k, n_conv)
      t <- ee$batch$Export$table$toAsset(collection = sf_as_ee(conv[idx, ]),
                                         description = sprintf("bconv_c%02d", i),
                                         assetId = chunk_ids[i])
      t$start(); message("  submitted chunk ", i, " -- wait for COMPLETED, then re-run")
    }
    stop("chunk uploads submitted -- re-run Section 10 once they show COMPLETED to sample")
  }

  # no separate merge/export step -- $merge() combines the chunk table assets
  # into one FeatureCollection server-side, valid for sampleRegions() as-is.
  conv_pts <- Reduce(function(a, b) a$merge(b), lapply(chunk_ids, ee$FeatureCollection))
  if (RUN_ONSET_EXPORT) {
    onset_year <- if (METHOD == "landtrendr") onset_year_lt else onset_year_bar
    sampled  <- onset_year$sampleRegions(collection = conv_pts,
                                         properties = list("classifica"),
                                         scale = EXPORT_SCALE, tileScale = 8L)
    task <- ee$batch$Export$table$toDrive(
      collection = sampled$select(c("classifica", "onset_year")),
      description = sprintf("build_04_onset_vs_barenblitt_%s", METHOD),
      folder = "ghana_mining_gee_exports", fileFormat = "CSV")
    task$start()
    message("Submitted onset-vs-classifica export -> outputs/tables/backdating/. Prefer ",
            "diag_04_backdating.R's request_classifica_export() for new runs (handles the ",
            "download+scoring too). To score by hand:\n",
            "  d$bar_year <- 2000 + d$classifica; d$err <- abs(d$onset_year - d$bar_year)\n",
            "  mean(d$err==0); mean(d$err<=1); mean(d$err<=2)")
  }
}

####11. Dropout diagnostic (RUN_DROPOUT_DIAGNOSTIC) ####
# sampleRegions() drops a classifica point wherever the sampled band is masked there, which
# conflates two causes: the pixel was never flagged as ever-mined, vs it WAS but LandTrendr found
# no confident break. Samples ever_mined_flag unmasked (always valid) + the pre-mask
# max_mag_lt/onset_lt_raw (sentinel -9999) so every point survives the export; split in R:
#   ever_mined_flag == 0                                       -> not_ever_mined
#   ever_mined_flag == 1 & (max_mag == -9999 | max_mag < 100)  -> no_confident_break
#   ever_mined_flag == 1 & max_mag >= 100                      -> dated (Section 10's export)
if (!TUNE && RUN_DROPOUT_DIAGNOSTIC) {
  if (!exists("conv_pts"))
    stop("conv_pts not built -- run with RUN_VALIDATION <- TRUE first (needs the bconv_c* chunk assets)")

  ever_mined_flag <- ever_mined_10$
    setDefaultProjection(mask_proj)$
    reduceResolution(reducer = ee$Reducer$mean(), maxPixels = 64L)$
    reproject(landsat_proj)$
    gte(0.5)$
    rename("ever_mined_flag")            # deliberately NOT selfMask()'d -- see header note above

  diag_img <- ever_mined_flag$
    addBands(max_mag_lt$unmask(-9999)$rename("max_mag"))$
    addBands(onset_lt_raw$unmask(-9999)$rename("onset_raw"))

  diag_sampled <- diag_img$sampleRegions(collection = conv_pts, properties = list("classifica"),
                                         scale = EXPORT_SCALE, tileScale = 8L)
  diag_task <- ee$batch$Export$table$toDrive(
    collection = diag_sampled$select(c("classifica", "ever_mined_flag", "max_mag", "onset_raw")),
    # hardcoded "landtrendr" (not METHOD) -- this diagnostic is always about
    # onset_lt_raw/max_mag_lt regardless of what METHOD is set to.
    description = "build_04_dropout_diagnostic_landtrendr",
    folder = "ghana_mining_gee_exports", fileFormat = "CSV")
  diag_task$start()
  message("Submitted dropout-diagnostic export (all classifica points, none dropped) -> ",
          "outputs/tables/backdating/. To score by hand:\n",
          "  d$bar_year <- 2000 + d$classifica\n",
          "  d$case <- ifelse(d$ever_mined_flag == 0, \"not_ever_mined\",\n",
          "                    ifelse(d$max_mag == -9999 | d$max_mag < 100, \"no_confident_break\",\n",
          "                           \"dated\"))\n",
          "  table(d$case)")
}

####12. Export national onset raster (flip TUNE <- FALSE first) ####
# 4 bands, each with its own undated sentinel (0 is a real category for reference_tier/lt_agree):
#   onset_year: Barenblitt's deployed onset year. 0 = ever-mined but undated.
#   ndvi_deriv_x1000: ndvi_deriv_bar x1000, rounded (preserves precision through toInt16()).
#                      -9999 = undated.
#   reference_tier: 0 = no_reference, 1 = classifica_comparable, 9 = undated. See Section 8.
#   lt_agree: 0 = agree, 1 = disagree, 2 = no_lt_signal, 9 = undated. See Section 8.
if (!TUNE && RUN_NATIONAL_EXPORT) {
  if (asset_exists(OUT_ASSET)) {
    message("[skip] ", OUT_ASSET, " exists -- delete it to re-export")
  } else {
    deploy_image <- onset_year_bar$unmask(0)$rename("onset_year")$
      addBands(ndvi_deriv_bar$multiply(1000)$round()$toInt16()$unmask(-9999)$rename("ndvi_deriv_x1000"))$
      addBands(reference_tier$unmask(9L)$rename("reference_tier"))$
      addBands(lt_agree$unmask(9L)$rename("lt_agree"))$
      updateMask(ever_mined)$
      toInt16()

    task <- ee$batch$Export$image$toAsset(
      image            = deploy_image,
      description      = sprintf("mine_onset_year_%d_%d_barenblitt", ONSET_MIN, ONSET_MAX),
      assetId          = OUT_ASSET,
      region           = ghana$bounds(),
      scale            = EXPORT_SCALE,
      crs              = "EPSG:4326",
      maxPixels        = 1e13,
      pyramidingPolicy = list(".default" = "mode")   # categorical years/codes in every band
    )
    task$start()
    message("Submitted: ", OUT_ASSET, " (4 bands -- see Section 12 header for sentinel coding)")
  }
}

# NEXT (separate script): merge mine_onset_year_{ONSET_MIN}_{ONSET_MAX}_barenblitt with build_03's
# mine_mask_ghana_c4_{2017..2025} into one continuous annual "mined" surface, then aggregate to the
# hex x year panel (b_01_cross_section grid) -- NOT by resampling to a common pixel grid (10m vs 30m
# seam is irrelevant at hex scale), but by computing per-hex mined area from each era's own native
# raster and concatenating the resulting year-rows.
message("\n=== build_04_backdating.R: done (deployed=barenblitt, cross-check=landtrendr) ===")
