# b_04_rs_mining_panel.R -- RS-derived annual mined-area panel per hex, 2000-2025.
# The `mine_data` swap-in for Barenblitt et al. in 2_build / 3_analysis.
#
# Sources (stitched by YEAR, not by raster grid -- the 10 m / 30 m seam is irrelevant at hex scale):
#   2000-2016  build_04_backdating.R's mine_onset_year_2000_2017_rulee (30 m, rule-e onset years
#              + flags). A pixel is mined in year Y once its onset <= Y (mining treated as
#              persistent forward, the same assumption the backdating relies on).
#              Masked to the CONFIRMED 2017 anchor (Rule B cur_2017 = raw17 AND raw18, 30 m share
#              >= 0.5, same aggregation as build_04) -- one-off 2017 blips get no onset year.
#   2017-2025  build_03b_temporal_rules.R's mine_status_ghana_c4_ruleB_2017_2025 (10 m):
#              Option 1 "ever mined" (entry_year <= Y) = main spec, consistent with pre-2017;
#              Option 2 "currently mined" (cur_{yr}, Rule B, can exit) = 2017+ only.
#              build_03's raw masks are kept as a baseline column (mined_ha_raw).
#
# Design: GEE exports AREA PER HEX BY ONSET YEAR x FLAG (Sections 3-4); every convention is built
# in R from those counts (Section 5), so thresholds can change without a new export.
#
# Conventions (columns of the output panel, all in ha of mined land, cumulative stock):
#   mined_ha_A          main spec: onset_year (2000-2017); onsets in 2000 = mined by 2000; 2017+ =
#                       Option 1 (ever mined under Rule B).
#   mined_ha_A_persist  robustness: as A, but pixels with persistent_loss == 0 dropped in EVERY year
#                       (2017+ too, via the np_{yr} bands).
#   mined_ha_cur        Option 2 (currently mined, Rule B), 2017+ only (NA before: no exits observable).
#   mined_ha_raw        build_03's raw masks, 2017+ only -- the pre-rule baseline.
#   unconf_ha           Option 1 area entering in 2025 (unconfirmable, no 2026 mask); 0 in other years.
#   mined_ha_B          "no mining before LATER_MIN": NA before LATER_MIN; from LATER_MIN on =
#                       stock + cumulative onset_from{LATER_MIN}. Stock = pixels already bare before
#                       LATER_MIN, pixels whose post-LATER_MIN loss is below STOCK_MAX_LOSS_X1000
#                       (no real later conversion -> mined earlier), and undated pixels. 2017+ as A.
#   new_ha_A / new_ha_B first differences (2017: mask minus 2016 stock, absorbs the 10/30 m seam).
#
# Workflow is NON-BLOCKING: each run submits whatever export is missing and stops; re-run once the
# task shows COMPLETED in the Tasks tab. Exports land in Drive (DRIVE_FOLDER) and are downloaded here.
#
# Reuses hex_{N}km_crosssection.rds's hex_sf AS-IS so hex_id lines up with every b_01/b_02/b_03/a_NN
# output. NOTE: that grid covers the b_01 study area (3,348 cells at 5 km), not all of Ghana.

####0. Parameters ####
HEX_SIZES_KM <- c(5)   # extend to c(5, 2, 1) once 5 km is confirmed end-to-end
ONSET_MIN  <- 2000L; ONSET_MAX <- 2017L
LATER_MIN  <- 2007L    # must match build_04_backdating.R
MASK_YEARS <- 2017:2025
YEARS      <- ONSET_MIN:max(MASK_YEARS)

LOSS_EDGES_X1000    <- c(25L, 50L, 100L)   # bins of loss_from{LATER_MIN}_x1000 exported per hex
STOCK_MAX_LOSS_X1000 <- 25L               # B: post-LATER_MIN loss below this -> stock. Must be 0 or
                                          # one of LOSS_EDGES_X1000 (changeable without re-export)

rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, tidyverse, sf, here, googledrive, conflicted)
conflicts_prefer(dplyr::filter, dplyr::select, dplyr::mutate, dplyr::lag, here::here)

EE_PROJECT    <- "rgee-auth-tillam"
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
ONSET_ASSET   <- file.path(EE_ASSET_HOME, sprintf("mine_onset_year_%d_%d_rulee", ONSET_MIN, ONSET_MAX))
MASK_PREFIX   <- "mine_mask_ghana_c4_"
STATUS_ASSET  <- file.path(EE_ASSET_HOME, sprintf("mine_status_ghana_c4_ruleB_%d_%d",
                                                  min(MASK_YEARS), max(MASK_YEARS)))   # build_03b
PROC_DIR      <- here("data", "processed")
RAW_DIR       <- here("outputs", "tables", "backdating")   # raw per-hex export CSVs
DRIVE_FOLDER  <- "ghana_mining_gee_exports"
B_ONSET <- sprintf("onset_from%d", LATER_MIN)
B_LOSS  <- sprintf("loss_from%d_x1000", LATER_MIN)
B_BARE  <- sprintf("bare_pre%d", LATER_MIN)
stopifnot(STOCK_MAX_LOSS_X1000 %in% c(0L, LOSS_EDGES_X1000))

####1. Authenticate ####
ee_Authenticate()
ee_Initialize(drive = TRUE, project = EE_PROJECT)
# ee_Initialize(drive = TRUE) does NOT hand googledrive a working token -- needs its own auth call.
googledrive::drive_auth()

asset_exists <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)
if (!asset_exists(ONSET_ASSET))
  stop(ONSET_ASSET, " not found -- run build_04_backdating.R Section 12 first (or wait for it)")
if (!asset_exists(STATUS_ASSET))
  stop(STATUS_ASSET, " not found -- run build_03b_temporal_rules.R first (or wait for it)")

# Task check in Python: pulling the task list into R overflows on Windows (seen 2026-11-13).
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

drive_download_export <- function(export_name, dest_path) {
  folder <- googledrive::drive_find(pattern = DRIVE_FOLDER, type = "folder", n_max = 1)
  if (nrow(folder) == 0) stop("Drive folder '", DRIVE_FOLDER, "' not found -- check googledrive::drive_user().")
  hit <- googledrive::drive_ls(folder[1, ]) |> filter(name == paste0(export_name, ".csv"))
  if (nrow(hit) == 0) return(FALSE)
  googledrive::drive_download(hit[1, ], path = dest_path, overwrite = TRUE)
  TRUE
}

# Local CSV -> done; on Drive -> download; running -> wait; else submit. Returns TRUE when local.
fetch_or_submit <- function(name, make_task) {
  dest <- file.path(RAW_DIR, paste0(name, ".csv"))
  if (file.exists(dest)) return(TRUE)
  if (drive_download_export(name, dest)) return(TRUE)
  if (task_running(name)) { message("  '", name, "' still running"); return(FALSE) }
  make_task()$start(); message("  submitted '", name, "'"); FALSE
}

####2. Area images ####
status <- ee$Image(STATUS_ASSET)
area   <- ee$Image$pixelArea()

# Confirmed 2017 anchor at 30 m: same 10 m -> 30 m aggregation as build_04 Section 4 (mean >= 0.5).
# A subset of build_04's raw anchor, so masking the onset asset == re-running build_04 on it.
anchor30 <- status$select("cur_2017")$unmask(0)$
  setDefaultProjection(status$projection())$
  reduceResolution(reducer = ee$Reducer$mean(), maxPixels = 64L)$
  reproject(ee$Projection("EPSG:32630")$atScale(30))$
  gte(0.5)
on <- ee$Image(ONSET_ASSET)$updateMask(anchor30)

# (a) 30 m onset bands: area by onset year x persistent_loss (A), and by onset_from{LATER_MIN} year x
#     loss bin / bare (B). Bin code 0..length(edges) by loss, length(edges)+1 = bare before LATER_MIN.
onset_y <- on$select("onset_year"); persist <- on$select("persistent_loss")
bands_a <- unlist(lapply(ONSET_MIN:ONSET_MAX, function(y) lapply(0:1, function(p)
  onset_y$eq(y)$And(persist$eq(p))$multiply(area)$rename(sprintf("A_%d_p%d", y, p)))), recursive = FALSE)
bands_a <- c(bands_a, list(onset_y$eq(0L)$multiply(area)$rename("A_undated")))

n_bins  <- length(LOSS_EDGES_X1000)
bin_img <- Reduce(function(acc, e) acc$add(on$select(B_LOSS)$gte(e)), LOSS_EDGES_X1000, ee$Image$constant(0L))
bin_img <- bin_img$where(on$select(B_BARE)$eq(1L), n_bins + 1L)
onset_b <- on$select(B_ONSET)
bands_b <- unlist(lapply(LATER_MIN:ONSET_MAX, function(y) lapply(0:(n_bins + 1L), function(b)
  onset_b$eq(y)$And(bin_img$eq(b))$multiply(area)$rename(sprintf("B_%d_b%d", y, b)))), recursive = FALSE)
bands_b <- c(bands_b, list(onset_b$eq(0L)$multiply(area)$rename("B_undated")))
onset_area <- ee$Image$cat(c(bands_a, bands_b))

# (b) 10 m mask bands per year: m = Option 1 (ever mined), np = its persistent_loss == 0 part (for
#     mined_ha_A_persist; 30 m flag read per 10 m pixel, nearest), cur = Option 2, raw = build_03
#     mask, u = Option 1 area entering in the last (unconfirmable) year.
np_flag <- persist$eq(0L)$unmask(0)
entry   <- status$select("entry_year")$unmask(0)
mask_bands <- unlist(lapply(MASK_YEARS, function(yr) {
  ever <- entry$gt(0)$And(entry$lte(yr))
  raw  <- ee$Image(file.path(EE_ASSET_HOME, paste0(MASK_PREFIX, yr)))$unmask(0)$gt(0)
  out <- list(ever$multiply(area)$rename(sprintf("m_%d", yr)),
              ever$And(np_flag)$multiply(area)$rename(sprintf("np_%d", yr)),
              status$select(sprintf("cur_%d", yr))$unmask(0)$multiply(area)$rename(sprintf("cur_%d", yr)),
              raw$multiply(area)$rename(sprintf("raw_%d", yr)))
  if (yr == max(MASK_YEARS)) out <- c(out, list(entry$eq(yr)$multiply(area)$rename(sprintf("u_%d", yr))))
  out
}), recursive = FALSE)
mask_area <- ee$Image$cat(mask_bands)

####3. Hex grid upload (once per resolution) ####
hex_fc_for <- function(res_tag) {
  hex_sf <- readRDS(here(PROC_DIR, sprintf("hex_%s_crosssection.rds", res_tag)))$hex_sf |>
    select(hex_id) |> st_transform(4326)
  hex_asset <- file.path(EE_ASSET_HOME, paste0("rs_hex_grid_", res_tag))
  k <- 10000L
  chunk_ids <- sprintf("%s_c%02d", hex_asset, seq_len(ceiling(nrow(hex_sf) / k)))
  missing <- !vapply(chunk_ids, asset_exists, logical(1))
  if (any(missing)) {
    for (i in which(missing)) {
      desc <- sprintf("rs_hex_%s_c%02d", res_tag, i)
      if (task_running(desc)) next
      idx <- ((i - 1L) * k + 1L):min(i * k, nrow(hex_sf))
      ee$batch$Export$table$toAsset(collection = sf_as_ee(hex_sf[idx, ]), description = desc,
                                    assetId = chunk_ids[i])$start()
      message("  submitted hex upload ", desc)
    }
    return(NULL)
  }
  Reduce(function(a, b) a$merge(b), lapply(chunk_ids, ee$FeatureCollection))
}

####4. Per-hex exports (two: 30 m onset bands, 10 m mask bands) ####
dir.create(RAW_DIR, recursive = TRUE, showWarnings = FALSE)
ready <- list()
for (hex_km in HEX_SIZES_KM) {
  res_tag <- paste0(hex_km, "km")
  message("\n=== hex ", res_tag, " ===")
  hex_fc <- hex_fc_for(res_tag)
  if (is.null(hex_fc)) { message("  hex grid upload pending -- re-run once COMPLETED"); next }

  export_for <- function(img, name, scale) function()
    ee$batch$Export$table$toDrive(
      collection = img$reduceRegions(collection = hex_fc, reducer = ee$Reducer$sum(), scale = scale,
                                     crs = "EPSG:32630", tileScale = 16L)$
        select(c("hex_id", img$bandNames()$getInfo()), retainGeometry = FALSE),
      description = name, folder = DRIVE_FOLDER, fileFormat = "CSV")

  n_on <- sprintf("b_04_rs_onset_area_rulee_conf_%s", res_tag)   # _conf = confirmed-2017 anchor
  n_mk <- sprintf("b_04_rs_mask_area_ruleB_%s", res_tag)
  ok_on <- fetch_or_submit(n_on, export_for(onset_area, n_on, 30L))
  ok_mk <- fetch_or_submit(n_mk, export_for(mask_area,  n_mk, 10L))
  if (ok_on && ok_mk) ready[[res_tag]] <- c(onset = n_on, mask = n_mk)
}
if (length(ready) == 0) stop("No resolution ready yet -- re-run once the exports show COMPLETED (not an error).",
                             call. = FALSE)

####5. Build the panel in R (all conventions) ####
build_panel <- function(files) {
  on_df <- read_csv(file.path(RAW_DIR, paste0(files[["onset"]], ".csv")), show_col_types = FALSE) |>
    select(hex_id, starts_with("A_"), starts_with("B_"))
  mk_df <- read_csv(file.path(RAW_DIR, paste0(files[["mask"]], ".csv")), show_col_types = FALSE) |>
    select(hex_id, starts_with(c("m_", "np_", "cur_", "raw_", "u_")))
  ha <- function(x) x / 1e4   # m^2 -> ha

  # A: new area per onset year, total and persistent only
  a_new <- on_df |> select(hex_id, matches("^A_\\d{4}_p[01]$")) |>
    pivot_longer(-hex_id, names_to = c("year", "p"), names_pattern = "A_(\\d{4})_p([01])", values_to = "m2") |>
    mutate(year = as.integer(year)) |>
    group_by(hex_id, year) |> summarise(new_A = ha(sum(m2)), new_A_p = ha(sum(m2[p == "1"])), .groups = "drop")

  # B: stock = bare + low-loss bins + undated; the rest is dated new area by onset_from year
  stock_bins <- which(c(0L, LOSS_EDGES_X1000) < STOCK_MAX_LOSS_X1000) - 1L   # bins below the threshold
  b_long <- on_df |> select(hex_id, matches("^B_\\d{4}_b\\d$")) |>
    pivot_longer(-hex_id, names_to = c("year", "bin"), names_pattern = "B_(\\d{4})_b(\\d)", values_to = "m2") |>
    mutate(year = as.integer(year), bin = as.integer(bin),
           to_stock = bin %in% stock_bins | bin == length(LOSS_EDGES_X1000) + 1L)
  b_stock <- b_long |> filter(to_stock) |> group_by(hex_id) |> summarise(stock_B = ha(sum(m2)), .groups = "drop") |>
    full_join(transmute(on_df, hex_id, und = ha(B_undated)), by = "hex_id") |>
    transmute(hex_id, stock_B = coalesce(stock_B, 0) + coalesce(und, 0))
  b_new <- b_long |> filter(!to_stock) |> group_by(hex_id, year) |> summarise(new_B = ha(sum(m2)), .groups = "drop")

  masks <- mk_df |> pivot_longer(-hex_id, names_to = c("kind", "year"), names_pattern = "(m|np|cur|raw|u)_(\\d{4})",
                                 values_to = "m2") |>
    mutate(year = as.integer(year), m2 = ha(m2)) |> pivot_wider(names_from = kind, values_from = m2)
  if (!"u" %in% names(masks)) masks$u <- NA_real_

  panel <- expand_grid(hex_id = union(on_df$hex_id, mk_df$hex_id), year = YEARS) |>
    left_join(a_new, by = c("hex_id", "year")) |>
    left_join(b_new, by = c("hex_id", "year")) |>
    left_join(b_stock, by = "hex_id") |>
    left_join(masks, by = c("hex_id", "year")) |>
    mutate(across(c(new_A, new_A_p, new_B, stock_B), ~ coalesce(.x, 0))) |>
    arrange(hex_id, year) |> group_by(hex_id) |>
    mutate(cum_A = cumsum(if_else(year <= ONSET_MAX - 1L, new_A, 0)),
           cum_A_p = cumsum(if_else(year <= ONSET_MAX - 1L, new_A_p, 0)),
           cum_B = cumsum(if_else(year >= LATER_MIN & year <= ONSET_MAX - 1L, new_B, 0)),
           mined_ha_A         = if_else(year < min(MASK_YEARS), cum_A, m),
           mined_ha_A_persist = if_else(year < min(MASK_YEARS), cum_A_p, m - np),
           mined_ha_B         = case_when(year < LATER_MIN ~ NA_real_,
                                          year < min(MASK_YEARS) ~ stock_B + cum_B,
                                          TRUE ~ m),
           mined_ha_cur       = if_else(year < min(MASK_YEARS), NA_real_, cur),
           mined_ha_raw       = if_else(year < min(MASK_YEARS), NA_real_, raw),
           unconf_ha          = coalesce(u, 0),
           new_ha_A = mined_ha_A - lag(mined_ha_A),
           new_ha_B = mined_ha_B - lag(mined_ha_B)) |>
    ungroup() |>
    select(hex_id, year, mined_ha_A, mined_ha_A_persist, mined_ha_B, mined_ha_cur, mined_ha_raw,
           unconf_ha, new_ha_A, new_ha_B)

  attr(panel, "meta") <- list(onset_asset = ONSET_ASSET, status_asset = STATUS_ASSET, later_min = LATER_MIN,
                              stock_max_loss_x1000 = STOCK_MAX_LOSS_X1000,
                              undated_ha_A = ha(sum(on_df$A_undated, na.rm = TRUE)), built = Sys.time())
  panel
}

for (res_tag in names(ready)) {
  panel <- build_panel(ready[[res_tag]])
  meta  <- attr(panel, "meta")
  out   <- here(PROC_DIR, sprintf("rs_mining_panel_hex%s_%d_%d", res_tag, min(YEARS), max(YEARS)))
  saveRDS(panel, paste0(out, ".rds")); write_csv(panel, paste0(out, ".csv"))

  # Quick checks: national totals by year per convention, and the 2016 -> 2017 seam
  tot <- panel |> group_by(year) |>
    summarise(across(c(mined_ha_A, mined_ha_A_persist, mined_ha_B, mined_ha_cur, mined_ha_raw, unconf_ha),
                     ~ round(sum(.x) / 100)), .groups = "drop")
  message("\n", res_tag, ": total mined area by year (km2) -- A (Opt 1) / A_persist / B / cur (Opt 2) / raw / unconf")
  print(as.data.frame(tot))
  message(sprintf("Undated (onset_year = 0, excluded from A): %.0f ha | B stock rule: loss < %d x1000, bare pre-%d, undated",
                  meta$undated_ha_A, STOCK_MAX_LOSS_X1000, LATER_MIN))
  message("Wrote ", out, ".rds/.csv")
}
message("\n=== b_04_rs_mining_panel.R: done ===")
