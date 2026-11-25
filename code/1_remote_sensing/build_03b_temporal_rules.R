# build_03b_temporal_rules.R -- temporal-consistency rule (Rule B) on build_03's annual masks.
#
# Reads the 9 deployed mine_mask_ghana_c4_{2017..2025} assets and exports ONE asset with the two
# "what counts as mined" definitions agreed 2026-11-25 (notes/2026-11-18_what_counts_as_mined.md):
#   cur_{yr}    Option 2, "currently mined": Rule B (forward-only) smoothed status, 0/1. Can exit.
#   entry_year  Option 1, "ever mined": first year cur_{yr} == 1 (0 = never). Mined in year Y iff
#               0 < entry_year <= Y. Same definition as the pre-2017 backdated layer.
#
# Rule B, per pixel (raw = deployed mask):
#   2017       cur = raw17 AND raw18 (no prior state, so a disagreement defaults to not-mined;
#              this is the CONFIRMED anchor b_04 masks the backdated onset layer with)
#   2018-2024  raw[T] == raw[T+1] -> cur = raw[T]; else cur = cur[T-1]
#   2025       cur = raw25 (no 2026 to confirm) -> entry_year == 2025 = UNCONFIRMED entries
# Differs from the tested diag_03 version only at 2017 (there: 2017 = raw).
# Rationale + design discussion: code/1_remote_sensing/documentation/explainer.md ("Temporal-consistency rule").
#
# Does NOT need build_04 to be re-run: the backdating is per pixel, and the confirmed 2017 footprint
# is a subset of the raw one, so masking the existing onset asset (b_04 Section 2) is equivalent.
#
# Run INTERACTIVELY (ee_Authenticate blocks on a browser login). Non-blocking: submits the export
# and stops; RUN_CHECK prints national totals (raw vs Option 1 vs Option 2) from the live image.

####1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, here, tidyverse, conflicted)
conflicts_prefer(dplyr::filter, dplyr::select, dplyr::mutate, dplyr::lag, here::here)

EE_PROJECT    <- "rgee-auth-tillam"                       # ID, never the numeric project number
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)

ee_Authenticate()
ee_Initialize(drive = TRUE, project = EE_PROJECT)

####2. Parameters ####
MASK_YEARS  <- 2017:2025                 # build_03's EMBED_YEARS
MASK_PREFIX <- "mine_mask_ghana_c4_"
OUT_ASSET   <- file.path(EE_ASSET_HOME, sprintf("mine_status_ghana_c4_ruleB_%d_%d",
                                                min(MASK_YEARS), max(MASK_YEARS)))
EXPORT_SCALE <- 10L                      # = build_03's EXPORT_SCALE
RUN_EXPORT   <- TRUE
RUN_CHECK    <- TRUE                     # quick national totals (scale 100 -> ~+3-8% vs native)

asset_exists <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)
GHANA <- ee$FeatureCollection(paste0(EE_ASSET_HOME, "/rs05_ghana"))$geometry()

####3. Raw masks ####
k <- as.character(MASK_YEARS)
mask_ids <- file.path(EE_ASSET_HOME, paste0(MASK_PREFIX, MASK_YEARS))
missing <- mask_ids[!vapply(mask_ids, asset_exists, logical(1))]
if (length(missing)) stop("missing mask assets: ", paste(basename(missing), collapse = ", "))
raw <- setNames(lapply(mask_ids, function(id) ee$Image(id)$unmask(0)$gt(0)), k)

####4. Rule B (Option 2) and entry year (Option 1) ####
cur <- list()
n <- length(k)
cur[[k[1]]] <- raw[[k[1]]]$And(raw[[k[2]]])                       # confirmed 2017 anchor
for (i in 2:n) {
  if (i == n) { cur[[k[i]]] <- raw[[k[i]]]; next }                 # 2025: unconfirmable, raw
  agree <- raw[[k[i]]]$eq(raw[[k[i + 1]]])
  cur[[k[i]]] <- cur[[k[i - 1]]]$where(agree, raw[[k[i]]])        # agree -> raw[T], else carry
}

# entry_year: walk backwards so the earliest year with cur == 1 wins
entry_year <- ee$Image$constant(0L)
for (y in rev(MASK_YEARS)) entry_year <- entry_year$where(cur[[as.character(y)]]$eq(1L), y)

raw_any <- Reduce(function(a, b) a$Or(b), raw)
status <- ee$Image$cat(c(lapply(k, function(y) cur[[y]]$rename(paste0("cur_", y))),
                         list(entry_year$rename("entry_year"))))$
  toInt16()$updateMask(raw_any)                                    # never-flagged pixels masked

####5. Quick national check (optional) ####
if (RUN_CHECK) {
  area_km2 <- ee$Image$pixelArea()$divide(1e6)
  bands <- unlist(lapply(MASK_YEARS, function(y) {
    yc <- as.character(y)
    list(raw[[yc]]$multiply(area_km2)$rename(paste0("raw_", y)),
         cur[[yc]]$multiply(area_km2)$rename(paste0("cur_", y)),
         entry_year$gt(0)$And(entry_year$lte(y))$multiply(area_km2)$rename(paste0("ever_", y)))
  }), recursive = FALSE)
  stats <- ee$Image$cat(bands)$reduceRegion(reducer = ee$Reducer$sum(), geometry = GHANA,
                                            scale = 100, maxPixels = 1e13, tileScale = 8)$getInfo()
  chk <- tibble(year = MASK_YEARS,
                raw  = map_dbl(MASK_YEARS, ~ stats[[paste0("raw_", .x)]]),
                opt2_current = map_dbl(MASK_YEARS, ~ stats[[paste0("cur_", .x)]]),
                opt1_ever    = map_dbl(MASK_YEARS, ~ stats[[paste0("ever_", .x)]])) |>
    mutate(across(-year, ~ round(.x, 1)),
           d_raw = raw - dplyr::lag(raw), d_opt2 = opt2_current - dplyr::lag(opt2_current))
  cat("\n=== National mined area (km2, scale 100): raw vs Option 2 (Rule B) vs Option 1 (ever) ===\n")
  print(as.data.frame(chk))
  chk_dir <- here("outputs", "tables", "embedding_product")
  dir.create(chk_dir, recursive = TRUE, showWarnings = FALSE)
  write_csv(chk, file.path(chk_dir, "build03b_national_check_scale100.csv"))
  cat("2025 entries in Option 1 are unconfirmed (no 2026 mask).\n")
}

####6. Export ####
if (RUN_EXPORT) {
  if (asset_exists(OUT_ASSET)) {
    message("[skip] ", OUT_ASSET, " exists -- delete it to re-export")
  } else {
    task <- ee$batch$Export$image$toAsset(
      image            = status,
      description      = basename(OUT_ASSET),
      assetId          = OUT_ASSET,
      region           = GHANA$bounds(),
      scale            = EXPORT_SCALE,
      crs              = "EPSG:4326",                               # = build_03's mask exports
      maxPixels        = 1e13,
      pyramidingPolicy = list(".default" = "mode")                  # categorical bands
    )
    task$start()
    message("Submitted: ", OUT_ASSET, " (cur_2017..cur_2025 + entry_year). Then re-run b_04.")
  }
}
