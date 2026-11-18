# d_09_weather.R -- rainfall + temperature per hex / district, monthly and annual, 1990-2025.
#
# Sources (both reduced to unit means server-side in GEE; no rasters are downloaded):
#   CHIRPS v2.0 daily   UCSB-CHG/CHIRPS/DAILY, ~5.5 km, rainfall (mm) -> monthly totals
#   ERA5-Land monthly   ECMWF/ERA5_LAND/MONTHLY_AGGR, ~11 km, 2 m air temperature (K -> deg C):
#                       temperature_2m (monthly mean), _max / _min (monthly max / min of hourly values)
# Supersedes d_01_download_gee.R Section 7 (CHIRPS annual rasters for the study bounds only, never
# downloaded) for analysis use.
#
# Units: the b_01 hex grids (same rs_hex_grid_{N}km assets as b_04_rs_mining_panel.R, uploaded here
# if missing) and the 260 districts (gha_admin2).
#
# Workflow is NON-BLOCKING: each run submits whatever export is missing and stops; re-run once the
# tasks show COMPLETED (Drive folder DRIVE_FOLDER), then it downloads and builds the outputs.
#
# Outputs: data/processed/weather/weather_{unit}_{Y0}_{Y1}_{monthly,annual}.{rds,csv}
#   monthly: unit_id, year, month, precip_mm, t2m_c, t2m_max_c, t2m_min_c
#   annual:  unit_id, year, precip_mm (sum), t2m_c (mean of months), t2m_max_c (hottest month max),
#            t2m_min_c (coldest month min), precip_wet_mm (MAR-OCT), plus anomalies vs BASE_YEARS:
#            precip_z (z-score), precip_ratio (share of the base mean), t2m_anom_c (deviation)

####0. Parameters ####
YEARS        <- 1990:2025
BASE_YEARS   <- 1991:2020   # WMO climate normal, for anomalies
WET_MONTHS   <- 3:10        # March-October: both southern rainy seasons + the northern one
HEX_SIZES_KM <- c(5)        # must exist as data/processed/hex_{N}km_crosssection.rds (b_01)
DO_DISTRICTS <- TRUE
REDUCE_SCALE <- 1000L       # m; finer than both sources so small units still get an area-weighted mean

rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, tidyverse, sf, here, googledrive, conflicted)
conflicts_prefer(dplyr::filter, dplyr::select, dplyr::mutate, here::here)

EE_PROJECT    <- "rgee-auth-tillam"
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
DRIVE_FOLDER  <- "ghana_mining_gee_exports"
RAW_DIR       <- here("data", "raw", "weather")
OUT_DIR       <- here("data", "processed", "weather")
dir.create(RAW_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

####1. Authenticate ####
ee_Authenticate()
ee_Initialize(drive = TRUE, project = EE_PROJECT)
googledrive::drive_auth()   # ee_Initialize(drive = TRUE) does not hand googledrive a token

asset_exists <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)
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

####2. Units as EE FeatureCollections (property unit_id) ####
# Hex grid: same chunked assets as b_04_rs_mining_panel.R (property hex_id) -- uploaded if missing.
hex_fc_for <- function(res_tag) {
  hex_sf <- readRDS(here("data", "processed", sprintf("hex_%s_crosssection.rds", res_tag)))$hex_sf |>
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
  Reduce(function(a, b) a$merge(b), lapply(chunk_ids, ee$FeatureCollection))$
    map(function(ft) ft$set("unit_id", ft$get("hex_id")))
}
# Districts: 260 polygons, small enough to send inline. select() first: the admin shapefile's
# valid_on/valid_to NA dates crash sf_as_ee() (CLAUDE.md caveat).
district_fc <- function() {
  st_read(here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin2.shp"), quiet = TRUE) |>
    st_make_valid() |> select(unit_id = adm2_name, geometry) |> st_transform(4326) |>
    st_simplify(dTolerance = 0.002, preserveTopology = TRUE) |>   # ~200 m: keeps the payload small
    sf_as_ee()
}

####3. Monthly climate images, one 48-band image per year ####
chirps <- ee$ImageCollection("UCSB-CHG/CHIRPS/DAILY")$select("precipitation")
era5   <- ee$ImageCollection("ECMWF/ERA5_LAND/MONTHLY_AGGR")$
  select(c("temperature_2m", "temperature_2m_max", "temperature_2m_min"))

# ERA5-Land is land-only: coastal units whose sample points fall only on sea cells got no temperature
# (39 hexes, 2 districts in the first run). Masked cells are filled with the mean of the land cells
# within FILL_RADIUS_PX ERA5 pixels (~11 km each), computed on ERA5's own grid; land cells are unchanged.
# t2m_land_share = share of the unit on real (unfilled) ERA5 land cells, 0 = fully filled.
FILL_RADIUS_PX <- 2L
era5_proj <- era5$first()$projection()
fill_coast <- function(img) img$unmask(img$focalMean(radius = FILL_RADIUS_PX, kernelType = "square", units = "pixels")$
                                         reproject(era5_proj))
land_share <- era5$first()$select("temperature_2m")$mask()$reproject(era5_proj)$rename("t2m_land_share")

year_image <- function(yr) {
  ee$Image$cat(c(lapply(1:12, function(m) {
    start <- ee$Date$fromYMD(yr, m, 1L); end <- start$advance(1L, "month")
    p <- chirps$filterDate(start, end)$sum()$rename(sprintf("precip_%02d", m))
    t <- fill_coast(era5$filterDate(start, end)$first())$subtract(273.15)$
      rename(sprintf(c("t2m_%02d", "t2mmax_%02d", "t2mmin_%02d"), m))
    p$addBands(t)
  }), list(land_share)))
}
# One FeatureCollection with a row per unit x year: reduceRegions per year, tagged and flattened.
climate_fc <- function(units) {
  per_year <- lapply(YEARS, function(yr) {
    year_image(yr)$reduceRegions(collection = units, reducer = ee$Reducer$mean(), scale = REDUCE_SCALE,
                                 crs = "EPSG:32630", tileScale = 4L)$
      map(function(ft) ft$set("year", yr))
  })
  Reduce(function(a, b) a$merge(b), per_year)
}
band_names <- c(sprintf("precip_%02d", 1:12), sprintf("t2m_%02d", 1:12),
                sprintf("t2mmax_%02d", 1:12), sprintf("t2mmin_%02d", 1:12), "t2m_land_share")
EXPORT_VERSION <- "v2"   # v2 (2026-11-17): coastal temperature fill + t2m_land_share; v1 CSVs left as they are

####4. Exports ####
units <- list()
for (hex_km in HEX_SIZES_KM) units[[paste0("hex", hex_km, "km")]] <- local({ km <- hex_km; function() hex_fc_for(paste0(km, "km")) })
if (DO_DISTRICTS) units[["districts"]] <- district_fc

ready <- character()
for (u in names(units)) {
  message("\n=== ", u, " ===")
  fc <- units[[u]]()
  if (is.null(fc)) { message("  unit upload pending -- re-run once COMPLETED"); next }
  name <- sprintf("d_09_weather_%s_%d_%d_%s", u, min(YEARS), max(YEARS), EXPORT_VERSION)
  ok <- fetch_or_submit(name, function()
    ee$batch$Export$table$toDrive(collection = climate_fc(fc), description = name, folder = DRIVE_FOLDER,
                                  fileFormat = "CSV", selectors = as.list(c("unit_id", "year", band_names))))
  if (ok) ready[u] <- name
}
if (length(ready) == 0) stop("No unit ready yet -- re-run once the exports show COMPLETED (not an error).",
                             call. = FALSE)

####5. Monthly + annual tables, anomalies ####
for (u in names(ready)) {
  wide <- read_csv(file.path(RAW_DIR, paste0(ready[[u]], ".csv")), show_col_types = FALSE)
  land <- wide |> group_by(unit_id) |> summarise(t2m_land_share = first(t2m_land_share), .groups = "drop")
  monthly <- wide |> select(-t2m_land_share) |>
    pivot_longer(-c(unit_id, year), names_to = c("var", "month"), names_pattern = "(.+)_(\\d{2})") |>
    mutate(month = as.integer(month),
           var = recode(var, precip = "precip_mm", t2m = "t2m_c", t2mmax = "t2m_max_c", t2mmin = "t2m_min_c")) |>
    pivot_wider(names_from = var, values_from = value) |>
    arrange(unit_id, year, month)

  annual <- monthly |> group_by(unit_id, year) |>
    summarise(precip_wet_mm = sum(precip_mm[month %in% WET_MONTHS]),   # before precip_mm is overwritten
              precip_mm     = sum(precip_mm),
              t2m_c         = mean(t2m_c),
              t2m_max_c     = max(t2m_max_c),
              t2m_min_c     = min(t2m_min_c), .groups = "drop") |>
    group_by(unit_id) |>
    mutate(base_p  = mean(precip_mm[year %in% BASE_YEARS], na.rm = TRUE),
           sd_p    = sd(precip_mm[year %in% BASE_YEARS], na.rm = TRUE),
           precip_z     = (precip_mm - base_p) / sd_p,
           precip_ratio = precip_mm / base_p,
           t2m_anom_c   = t2m_c - mean(t2m_c[year %in% BASE_YEARS], na.rm = TRUE)) |>
    ungroup() |> select(-base_p, -sd_p) |>
    left_join(land, by = "unit_id")

  # After the coastal fill this should be 0; t2m_land_share == 0 marks units that are fully filled.
  n_na_t <- n_distinct(annual$unit_id[is.na(annual$t2m_c)])
  message(sprintf("%s: %d units with temperature fully filled from nearby land cells (t2m_land_share = 0)",
                  u, sum(land$t2m_land_share == 0, na.rm = TRUE)))
  base <- file.path(OUT_DIR, sprintf("weather_%s_%d_%d", u, min(YEARS), max(YEARS)))
  saveRDS(monthly, paste0(base, "_monthly.rds")); write_csv(monthly, paste0(base, "_monthly.csv"))
  saveRDS(annual,  paste0(base, "_annual.rds"));  write_csv(annual,  paste0(base, "_annual.csv"))
  message(sprintf("%s: %d units x %d years | mean annual rainfall %.0f mm, mean t2m %.1f C | %d units without temperature",
                  u, n_distinct(annual$unit_id), n_distinct(annual$year),
                  mean(annual$precip_mm, na.rm = TRUE), mean(annual$t2m_c, na.rm = TRUE), n_na_t))
  message("Wrote ", base, "_{monthly,annual}.{rds,csv}")
}
message("\n=== d_09_weather.R: done ===")
