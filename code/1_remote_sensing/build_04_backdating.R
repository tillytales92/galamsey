# build_04_backdating.R -- RUN INTERACTIVELY
# Backdates the 2017 embedding-classifier mine footprint (build_03's mine_mask_ghana_c4_2017) to
# per-pixel ONSET YEARS for ONSET_MIN-ONSET_MAX, by dating each mined pixel's vegetation-loss
# break in the Landsat archive.
#
# Deployed (Section 7, 2026-11-17): Barenblitt replica + RULE E. Annual max-NDVI, but a year with
#   exactly ONE clear observation is replaced by linear interpolation between the nearest years
#   with >= 2 -> 3yr moving average -> first difference -> qualityMosaic picks the steepest loss.
#   Rule e removes most single-image fake dips (the 2002 pile-up) without dropping any year.
#   Validation + rule comparison: code/1_remote_sensing/explainer.md (backdating section).
# Cross-check (Section 6): LandTrendr, feeds the lt_agree flag only.
#
# Bands (Section 12): two onset conventions + credibility flags --
#   onset_year           rule-e onset, 2000-2017 (main spec in b_04)
#   onset_from{LATER_MIN}  rule-e steepest loss restricted to LATER_MIN-2017 ("no mining before
#                        LATER_MIN"; same rule-e series as onset_year, only the candidate years differ)
#   loss_from{LATER_MIN}_x1000  size of that loss (small = probably earlier mining, b_04 can send to stock)
#   persistent_loss      1 = some candidate-year loss stays >= PERSIST_DROP below the 3 years before
#                        it over the 3 years after (rule f, used as a FLAG). Imagery runs to
#                        PERSIST_END so 2015-2017 onsets get a full 3-year confirmation window.
#   + ndvi_deriv_x1000, reference_tier, lt_agree, n_obs_years, n_computable_years,
#     n_interp_years, bare_pre{LATER_MIN}, start_ndvi_x1000
#
# CAVEATS: only dates pixels mined in 2017; a break is a spectral disturbance, not necessarily
# the mining event; 30 m Landsat vs the 10 m mask (majority-mined per 30 m cell).
#
# Prereq: build_03_embedding_panel.R has exported mine_mask_ghana_c4_2017.
# TUNE <- TRUE clips everything to TUNE_AOI for fast iteration.

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

METHOD <- "barenblitt"   # "landtrendr" | "barenblitt" -- which method's classifica CSV Section 10
                          # exports (deploy is always the rule-e Barenblitt replica).

MASK_PREFIX <- "mine_mask_ghana_c4_"
MASK_YEARS  <- 2017L   # anchor = mined-as-of-2017 only; 2018+ is dated by build_03 itself

ONSET_MIN  <- 2000L
ONSET_MAX  <- 2017L    # 2017 = anchor-mask year (was 2016: masked 8.9% of the footprint as undatable)
LATER_MIN  <- 2007L    # "no mining before LATER_MIN" convention (2026-11-17: 2007 = start of
                       # Barenblitt et al.'s dated series; was 2005). Also names the bands below.
IMG_START  <- 1998L    # must be <= ONSET_MIN - 2 (3yr MA + first difference need 2 years of padding)
IMG_END    <- 2018L    # dating window end (unchanged from the validated runs)
PERSIST_END <- 2020L   # imagery end for the persistence check ONLY (2017 onset -> 2018-2020 window)
PERSIST_DROP <- 0.15   # persistent_loss: median annual max y+1..y+3 >= this below y-3..y-1
BARE_NDVI    <- 0.4    # bare_pre{LATER_MIN}: median rule-e annual max in the 3 years before LATER_MIN below this
BARE_YEARS   <- (LATER_MIN - 3L):(LATER_MIN - 1L)
B_ONSET_LATER <- sprintf("onset_from%d", LATER_MIN)          # band names
B_LOSS_LATER  <- sprintf("loss_from%d_x1000", LATER_MIN)
B_BARE        <- sprintf("bare_pre%d", LATER_MIN)
EXPORT_SCALE <- 30L    # Landsat native

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
# Matched to Barenblitt et al. (2021)'s LandTrendr comparison (mag > 200, dur < 4, preval > 100 on
# NBR*1000, LT-GEE change-map convention): greatest-magnitude loss segment, masked if it fails a gate.
LT_MIN_MAGNITUDE <- 200
LT_MAX_DURATION  <- 4
LT_MIN_PREVAL    <- 100
START_NDVI_YEARS <- 1998:2002   # window for the start_ndvi_x1000 band (Section 8)

TUNE <- FALSE   # TRUE clips to TUNE_AOI. Sections 10/11/12 are guarded by !TUNE.
TUNE_AOI <- ee$Geometry$Rectangle(c(-2.05, 5.98, -1.87, 6.15))   # Awomaso

# 2026-11-17: Sections 10/11 off by default -- rule e's fidelity vs classifica was already scored by
# validate_backdating_method_fidelity.R (Section 6). Flip on to re-score the deployed asset itself.
RUN_ONSET_EXPORT       <- FALSE   # submit Section 10's onset-vs-classifica CSV for METHOD
RUN_VALIDATION         <- FALSE   # upload/merge the classifica validation points (Section 10)
RUN_DROPOUT_DIAGNOSTIC <- FALSE   # submit Section 11's LandTrendr dropout breakdown
RUN_NATIONAL_EXPORT    <- TRUE    # submit the deployed national asset (Section 12)

# New name (2026-11-17) -- the pre-rule-e asset mine_onset_year_2000_2017_barenblitt is kept as is.
OUT_ASSET <- sprintf("%s/mine_onset_year_%d_%d_rulee", EE_ASSET_HOME, ONSET_MIN, ONSET_MAX)

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
# Roy et al. (2016) OLS coefficients, OLI -> ETM+ (Table 2). Derived for C1 SR; applied to C2 SR.
ROY <- list(RED   = list(s = 0.9047, i = 0.0061),
            NIR   = list(s = 0.8462, i = 0.0412),
            SWIR2 = list(s = 0.9071, i = 0.0172))

# Collection runs to PERSIST_END; every dating step below selects years <= IMG_END itself.
prep_col <- function(id, bands, is_oli) {
  ee$ImageCollection(id)$
    filterBounds(aoi)$
    filterDate(sprintf("%d-01-01", IMG_START), sprintf("%d-01-01", PERSIST_END + 1L))$
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

YRS   <- IMG_START:IMG_END       # dating window
YRS_P <- IMG_START:PERSIST_END   # persistence window
# A year with NO scene over the region would reduce to a ZERO-band image and break every
# add/multiply across years -- fall back to a 1-band, fully masked image instead.
annual_composite <- function(yr, band, reducer) {
  col   <- landsat$filter(ee$Filter$calendarRange(yr, yr, "year"))$select(band)
  empty <- ee$Image$constant(0)$toFloat()$updateMask(ee$Image$constant(0))
  ee$Image(ee$Algorithms$If(col$size()$gt(0), col$reduce(reducer), empty))$
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
  # Segments run vertex to vertex (LT-GEE's change-map logic): keep only the vertex columns,
  # then pair each vertex with the next one.
  arr   <- lt$select("LandTrendr")
  verts <- arr$arrayMask(arr$arraySlice(0L, 3L, 4L))           # 4 x nVertices
  # arrayProject(1) drops the redundant length-1 axis-0 left by arraySlice(0, ...).
  v_year <- verts$arraySlice(0L, 0L, 1L)$arrayProject(list(1L))
  v_fit  <- verts$arraySlice(0L, 2L, 3L)$arrayProject(list(1L))

  seg_mag <- v_fit$arraySlice(0L, 1L)$subtract(v_fit$arraySlice(0L, 0L, -1L))    # + = loss (series is -NBR)
  seg_dur <- v_year$arraySlice(0L, 1L)$subtract(v_year$arraySlice(0L, 0L, -1L))
  seg_pre <- v_fit$arraySlice(0L, 0L, -1L)$multiply(-1)                          # NBR*1000 at segment start
  seg_yod <- v_year$arraySlice(0L, 0L, -1L)$add(1)                               # first year after the start vertex

  amax         <- seg_mag$arrayArgmax()$arrayFlatten(list(list("i")))   # greatest-magnitude segment
  max_mag_lt   <- seg_mag$arrayGet(amax)$rename("mag")
  dur_lt       <- seg_dur$arrayGet(amax)$rename("dur")
  preval_lt    <- seg_pre$arrayGet(amax)$rename("preval")
  onset_lt_raw <- seg_yod$arrayGet(amax)$rename("onset_year")   # pre-mask, used by Section 11

  lt_pass <- max_mag_lt$gt(LT_MIN_MAGNITUDE)$
    And(dur_lt$lt(LT_MAX_DURATION))$
    And(preval_lt$gt(LT_MIN_PREVAL))
  onset_year_lt <- onset_lt_raw$
    updateMask(lt_pass)$
    updateMask(onset_lt_raw$gte(ONSET_MIN)$And(onset_lt_raw$lte(ONSET_MAX)))$
    updateMask(ever_mined)$
    round()$toInt16()
}

####7. Barenblitt replica + rule e -- DEPLOYED (Section 12). ####
{
  k_p <- as.character(YRS_P)
  # Raw annual max-NDVI (Barenblitt's step 4) and clear-observation counts per year.
  ndvi_raw <- setNames(lapply(YRS_P, function(y) annual_composite(y, "NDVI", ee$Reducer$max())), k_p)
  n_clear  <- setNames(lapply(YRS_P, function(y) {
    col <- landsat$filter(ee$Filter$calendarRange(y, y, "year"))$select("NDVI")
    ee$Image(ee$Algorithms$If(col$size()$gt(0), col$count(), ee$Image$constant(0L)))$unmask(0)$rename("n")
  }), k_p)

  # Rule e: forward/backward passes carry the nearest well-observed (>= 2 obs) value and year;
  # a 1-obs year with a well-observed year on BOTH sides gets the linear interpolation. Same logic
  # as validate_backdating_vs_classifier_groundtruth.R's annual_max_e (duplicated, not sourced).
  # Note: the passes span YRS_P, so a 1-obs 2018 can interpolate towards 2019 (post-2013 1-obs
  # years are rare, so dating is effectively unchanged vs the validated 1998-2018 runs).
  sentinel <- ee$Image$constant(-9)$toFloat()
  pv <- pyr <- nv <- nyr <- list()
  lv <- sentinel; ly <- sentinel
  for (y in k_p) {
    pv[[y]] <- lv; pyr[[y]] <- ly
    good <- n_clear[[y]]$gte(2L)
    lv <- lv$where(good, ndvi_raw[[y]]$unmask(-9)); ly <- ly$where(good, ee$Image$constant(as.numeric(y))$toFloat())
  }
  lv <- sentinel; ly <- sentinel
  for (y in rev(k_p)) {
    nv[[y]] <- lv; nyr[[y]] <- ly
    good <- n_clear[[y]]$gte(2L)
    lv <- lv$where(good, ndvi_raw[[y]]$unmask(-9)); ly <- ly$where(good, ee$Image$constant(as.numeric(y))$toFloat())
  }
  interp <- setNames(lapply(k_p, function(y)
    n_clear[[y]]$eq(1L)$And(pv[[y]]$neq(-9))$And(nv[[y]]$neq(-9))), k_p)
  ndvi_e <- setNames(lapply(k_p, function(y) {
    frac <- ee$Image$constant(as.numeric(y))$toFloat()$subtract(pyr[[y]])$divide(nyr[[y]]$subtract(pyr[[y]]))
    iv   <- pv[[y]]$add(nv[[y]]$subtract(pv[[y]])$multiply(frac))
    ndvi_raw[[y]]$where(interp[[y]], iv)$rename("NDVI")
  }), k_p)

  # Dating uses the rule-e series over YRS only (Sections 8+ read ndvi_max).
  ndvi_max <- ndvi_e[as.character(YRS)]

  # 3-year moving average, x -1 so a decline reads positive (NDVI_avg).
  avg_years <- (IMG_START + 1L):(IMG_END - 1L)
  ndvi_avg <- setNames(lapply(avg_years, function(y) {
    ndvi_max[[as.character(y - 1L)]]$add(ndvi_max[[as.character(y)]])$add(ndvi_max[[as.character(y + 1L)]])$
      divide(3)$multiply(-1)$rename("NDVI_avg")
  }), avg_years)

  # first difference NDVI_deriv[y] = NDVI_avg[y] - NDVI_avg[y-1]; carry Year band.
  deriv_years <- (min(avg_years) + 1L):max(avg_years)
  deriv_list <- setNames(lapply(deriv_years, function(y) {
    ndvi_avg[[as.character(y)]]$subtract(ndvi_avg[[as.character(y - 1L)]])$rename("NDVI_deriv")$
      addBands(ee$Image$constant(y)$toInt()$rename("Year"))$updateMask(ever_mined)
  }), deriv_years)

  # qualityMosaic over candidate years only: per pixel keep the year with the steepest loss.
  pick_onset <- function(y0, y1) {
    qm <- ee$ImageCollection(unname(deriv_list[as.character(intersect(deriv_years, y0:y1))]))$
      qualityMosaic("NDVI_deriv")
    list(year  = qm$select("Year")$updateMask(ever_mined)$toInt16()$rename("onset_year"),
         deriv = qm$select("NDVI_deriv")$updateMask(ever_mined)$rename("ndvi_deriv"))
  }
  main <- pick_onset(ONSET_MIN, ONSET_MAX)
  onset_year_dep <- main$year
  ndvi_deriv_dep <- main$deriv      # magnitude of the winning loss (no gate; near zero = likely noise)

  later <- pick_onset(LATER_MIN, ONSET_MAX)
  onset_later <- later$year$rename(B_ONSET_LATER)
  loss_later  <- later$deriv$rename("loss_later")

  # persistent_loss: any candidate year whose loss persists (windows clipped to the imagery; a fully
  # masked window counts as not persistent). Uses the rule-e series out to PERSIST_END.
  med <- function(ys) ee$ImageCollection(unname(ndvi_e[intersect(as.character(ys), k_p)]))$median()
  persistent_loss <- ee$ImageCollection(lapply(ONSET_MIN:ONSET_MAX, function(y) {
    med((y - 3L):(y - 1L))$subtract(med((y + 1L):(y + 3L)))$gte(PERSIST_DROP)$unmask(0)$toInt16()$rename("p")
  }))$max()$rename("persistent_loss")$updateMask(ever_mined)

  bare_ndvi    <- med(BARE_YEARS)
  bare_pre <- bare_ndvi$lt(BARE_NDVI)$toInt16()$rename(B_BARE)$updateMask(ever_mined)

  n_interp_years <- ee$Image$cat(unname(lapply(interp[as.character(YRS)], function(im) im$toInt16())))$
    reduce(ee$Reducer$sum())$rename("n_interp_years")
}

####8. Confidence/uncertainty bands for the deployed onset layer ####
# None of this is ground-truth validation -- these flag uncertainty, not resolve it.
#   reference_tier: 0 = no_reference (onset < 2007, no classifica comparison possible at all),
#                   1 = classifica_comparable (onset >= 2007), 9 = undated sentinel (Section 12).
#   lt_agree: 0 = agree (LandTrendr cleared its own gate, within +-2yr of the deployed onset),
#             1 = disagree (LandTrendr cleared its gate, >2yr off), 2 = no_lt_signal, 9 = undated.
dep_dated <- onset_year_dep$mask()

reference_tier <- ee$Image$constant(0L)$toInt16()$rename("reference_tier")$
  where(onset_year_dep$gte(2007L), ee$Image$constant(1L))$
  updateMask(dep_dated)

lt_cleared      <- onset_year_lt$mask()           # LandTrendr cleared its own LT_MIN_MAGNITUDE gate
onset_lt_filled <- onset_year_lt$unmask(-9999)     # sentinel so the diff below never sees a masked value
lt_diff         <- onset_lt_filled$subtract(onset_year_dep)$abs()

lt_agree <- ee$Image$constant(2L)$toInt16()$rename("lt_agree")$              # default: no_lt_signal
  where(lt_cleared, ee$Image$constant(1L))$                                  # LT fired: default disagree
  where(lt_cleared$And(lt_diff$lte(2L)), ee$Image$constant(0L))$             # LT fired, within +-2yr: agree
  updateMask(dep_dated)

# Data-support flags (flags, NOT masks -- the panel decides what to do with them):
#   n_obs_years: years in IMG_START..IMG_END with >= 1 clear observation.
#   n_computable_years: candidate years whose NDVI_deriv could be computed at all (4 consecutive
#     observed years y-2..y+1).
#   start_ndvi_x1000: median rule-e annual max NDVI over START_NDVI_YEARS (low = already bare).
# Rule e only changes VALUES of observed years, never which years are observed, so the masks of
# ndvi_max are the raw observation masks.
has_obs <- lapply(YRS, function(y) ndvi_max[[as.character(y)]]$mask()$unmask(0)$rename(paste0("has", y)))
names(has_obs) <- as.character(YRS)
# unname(): a named R list reaches Python as a dict, which cat() rejects
n_obs_years <- ee$Image$cat(unname(has_obs))$reduce(ee$Reducer$sum())$rename("n_obs_years")
n_computable_years <- ee$Image$cat(lapply(deriv_years, function(y) {
  has_obs[[as.character(y - 2L)]]$multiply(has_obs[[as.character(y - 1L)]])$
    multiply(has_obs[[as.character(y)]])$multiply(has_obs[[as.character(y + 1L)]])
}))$reduce(ee$Reducer$sum())$rename("n_computable_years")
start_ndvi <- ee$ImageCollection(unname(ndvi_max[as.character(START_NDVI_YEARS)]))$median()$
  rename("start_ndvi")

####9. Quick sanity-check sample (TUNE mode only) ####
# Band values side by side for a handful of mined pixels in TUNE_AOI, before a national export.
if (TUNE) {
  sample_img <- onset_year_dep$rename("onset")$
    addBands(ndvi_deriv_dep$multiply(1000)$round()$rename("ndvi_deriv_x1000"))$
    addBands(onset_later)$
    addBands(loss_later$multiply(1000)$round()$rename(B_LOSS_LATER))$
    addBands(persistent_loss)$
    addBands(bare_pre)$
    addBands(n_interp_years)$
    addBands(reference_tier)$
    addBands(lt_agree)$
    addBands(onset_year_lt$rename("onset_lt"))$
    addBands(n_obs_years)$
    addBands(n_computable_years)$
    addBands(start_ndvi$multiply(1000)$round()$rename("start_ndvi_x1000"))$
    # dropNulls drops a pixel if ANY band is masked -- sentinel inside the footprint, NA in R below.
    unmask(-9999)$updateMask(ever_mined)

  # numPixels is drawn from the WHOLE TUNE_AOI box, then dropNulls discards non-mined pixels.
  sample_pts <- sample_img$sample(region = TUNE_AOI, scale = EXPORT_SCALE,
                                   numPixels = 3000, seed = 1, geometries = FALSE, dropNulls = TRUE)
  tune_check <- purrr::map_dfr(sample_pts$getInfo()$features, ~ tibble::as_tibble(.x$properties)) |>
    mutate(across(everything(), ~ if_else(.x == -9999, NA, .x)))
  print(tune_check, n = 30, width = Inf)

  if (nrow(tune_check) > 0) {
    cat(sprintf(paste0("\nTUNE summary (%d pixels): dated %.0f%% | persistent_loss %.0f%% | bare_pre_later %.0f%% | ",
                       "onset != onset_later %.0f%% | mean n_interp_years %.2f\n"),
                nrow(tune_check), 100 * mean(!is.na(tune_check$onset)),
                100 * mean(tune_check$persistent_loss == 1, na.rm = TRUE),
                100 * mean(tune_check[[B_BARE]] == 1, na.rm = TRUE),
                100 * mean(tune_check$onset != tune_check[[B_ONSET_LATER]], na.rm = TRUE),
                mean(tune_check$n_interp_years, na.rm = TRUE)))
    print(tune_check |> count(onset_lt_agree = lt_agree))
    print(ggplot(tune_check, aes(onset, fill = factor(persistent_loss))) +
      geom_histogram(binwidth = 1, boundary = 0) +
      scale_fill_manual(values = c("0" = "#d94fd0", "1" = "#450457"), name = "persistent_loss") +
      labs(title = "TUNE sample: rule-e onset year", x = "onset_year", y = "count") +
      theme_minimal())
  }
}

####10. Validation vs Barenblitt et al. classifica (RUN_VALIDATION) ####
# classifica = 2-digit conversion year (07..17 -> 2007..2017). Upload the annual polygons as
# points (one per polygon) once, then sample the onset raster at each. Guarded by !TUNE.
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

  conv_pts <- Reduce(function(a, b) a$merge(b), lapply(chunk_ids, ee$FeatureCollection))
  if (RUN_ONSET_EXPORT) {
    onset_year <- if (METHOD == "landtrendr") onset_year_lt else onset_year_dep
    sampled  <- onset_year$sampleRegions(collection = conv_pts,
                                         properties = list("classifica"),
                                         scale = EXPORT_SCALE, tileScale = 8L)
    task <- ee$batch$Export$table$toDrive(
      collection = sampled$select(c("classifica", "onset_year")),
      # window + rule suffixed so it never collides with earlier scored CSVs
      description = sprintf("build_04_onset_vs_barenblitt_%s_rulee_min%d_max%d", METHOD, ONSET_MIN, ONSET_MAX),
      folder = "ghana_mining_gee_exports", fileFormat = "CSV")
    task$start()
    message("Submitted onset-vs-classifica export. Fetch it with util_fetch_drive_exports.R. ",
            "Score against classifica + 1 (our label convention), undated (0) excluded:\n",
            "  d <- subset(d, onset_year > 0); e <- abs(d$onset_year - (2001 + d$classifica))\n",
            "  mean(e == 0); mean(e <= 1); mean(e <= 2)")
  }
}

####11. Dropout diagnostic (RUN_DROPOUT_DIAGNOSTIC) ####
# Splits classifica points LandTrendr leaves undated into not_ever_mined vs no_confident_break.
if (!TUNE && RUN_DROPOUT_DIAGNOSTIC) {
  if (!exists("conv_pts"))
    stop("conv_pts not built -- run with RUN_VALIDATION <- TRUE first (needs the bconv_c* chunk assets)")

  ever_mined_flag <- ever_mined_10$
    setDefaultProjection(mask_proj)$
    reduceResolution(reducer = ee$Reducer$mean(), maxPixels = 64L)$
    reproject(landsat_proj)$
    gte(0.5)$
    rename("ever_mined_flag")            # deliberately NOT selfMask()'d

  diag_img <- ever_mined_flag$
    addBands(max_mag_lt$unmask(-9999)$rename("max_mag"))$
    addBands(dur_lt$unmask(-9999)$rename("dur"))$
    addBands(preval_lt$unmask(-9999)$rename("preval"))$
    addBands(onset_lt_raw$unmask(-9999)$rename("onset_raw"))

  diag_sampled <- diag_img$sampleRegions(collection = conv_pts, properties = list("classifica"),
                                         scale = EXPORT_SCALE, tileScale = 8L)
  diag_task <- ee$batch$Export$table$toDrive(
    collection = diag_sampled$select(c("classifica", "ever_mined_flag", "max_mag", "dur", "preval", "onset_raw")),
    description = sprintf("build_04_dropout_diagnostic_landtrendr_min%d_max%d", ONSET_MIN, ONSET_MAX),
    folder = "ghana_mining_gee_exports", fileFormat = "CSV")
  diag_task$start()
  message("Submitted dropout-diagnostic export -> outputs/tables/backdating/.")
}

####12. Export national onset raster (flip TUNE <- FALSE first) ####
# 12 Int16 bands, each with its own sentinel (0 is a real value for several):
#   onset_year            rule-e onset 2000-2017. 0 = mined but undated.
#   ndvi_deriv_x1000      winning loss x1000. -9999 = undated.
#   onset_from{LATER_MIN}         rule-e onset restricted to LATER_MIN-2017. 0 = undated.
#   loss_from{LATER_MIN}_x1000    that loss x1000. -9999 = undated.
#   persistent_loss       0/1, defined for every mined pixel.
#   reference_tier        0 = no_reference, 1 = classifica_comparable, 9 = undated.
#   lt_agree              0 = agree, 1 = disagree, 2 = no_lt_signal, 9 = undated.
#   n_obs_years, n_computable_years, n_interp_years   counts (0 is real).
#   bare_pre{LATER_MIN}   0/1, 9 = no clear obs in the 3 years before LATER_MIN.
#   start_ndvi_x1000      median rule-e 1998-2002 annual max x1000. -9999 = no clear obs.
if (!TUNE && RUN_NATIONAL_EXPORT) {
  if (asset_exists(OUT_ASSET)) {
    message("[skip] ", OUT_ASSET, " exists -- delete it to re-export")
  } else {
    deploy_image <- onset_year_dep$unmask(0)$rename("onset_year")$
      addBands(ndvi_deriv_dep$multiply(1000)$round()$toInt16()$unmask(-9999)$rename("ndvi_deriv_x1000"))$
      addBands(onset_later$unmask(0)$rename(B_ONSET_LATER))$
      addBands(loss_later$multiply(1000)$round()$toInt16()$unmask(-9999)$rename(B_LOSS_LATER))$
      addBands(persistent_loss$unmask(0)$rename("persistent_loss"))$
      addBands(reference_tier$unmask(9L)$rename("reference_tier"))$
      addBands(lt_agree$unmask(9L)$rename("lt_agree"))$
      addBands(n_obs_years$unmask(0)$rename("n_obs_years"))$
      addBands(n_computable_years$unmask(0)$rename("n_computable_years"))$
      addBands(n_interp_years$unmask(0)$rename("n_interp_years"))$
      addBands(bare_pre$unmask(9L)$rename(B_BARE))$
      addBands(start_ndvi$multiply(1000)$round()$unmask(-9999)$rename("start_ndvi_x1000"))$
      updateMask(ever_mined)$
      toInt16()

    task <- ee$batch$Export$image$toAsset(
      image            = deploy_image,
      description      = basename(OUT_ASSET),
      assetId          = OUT_ASSET,
      region           = ghana$bounds(),
      scale            = EXPORT_SCALE,
      crs              = "EPSG:4326",
      maxPixels        = 1e13,
      pyramidingPolicy = list(".default" = "mode")   # categorical years/codes in every band
    )
    task$start()
    message("Submitted: ", OUT_ASSET, " (12 bands -- see Section 12 header for sentinel coding)")
  }
}

# NEXT: b_04_rs_mining_panel.R merges this asset with build_03's mine_mask_ghana_c4_{2017..2025}
# into the hex x year panel, in two conventions: A = onset_year (pre-LATER_MIN onsets = starting
# stock), B = onset_from{LATER_MIN} ("no mining before LATER_MIN"); persistent_loss == 0 as a
# robustness drop.
message("\n=== build_04_backdating.R: done (deployed = Barenblitt replica + rule e) ===")
