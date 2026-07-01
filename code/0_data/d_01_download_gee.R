# d_01_download_gee.R
# GEE-based environmental covariate downloads for Ghana. Pure download + stack script:
# no derived layers or per-hex extraction here — those live in d_0N_* siblings and
# 2_build/b_02_hex_frame.R.
#
# NOTE: MERIT-DEM + MERIT Hydro GEE exports are handled in d_04_merit.R, not here.
# That script immediately processes the exports into hydro-geomorphic layers (HAND,
# flow direction, hex flow graph), so the download and compute are tightly coupled
# and cannot sensibly be separated.
#
# Downloads:
#   NDVI       — Landsat C02 T1 L2 Annual composite, 250 m, Ghana, 1995–2025
#                → data/raw/ndvi/ndvi_ghana_{year}.tif + ndvi_ghana_stack.tif
#   EVI        — Landsat C02 T1 L2 Annual composite, 250 m, Ghana, 1995–2025
#                → data/raw/evi/evi_ghana_{year}.tif  + evi_ghana_stack.tif
#   MODIS VI   — MOD13A2 QA-filtered annual mean, 1 km, Ghana, 2000–2025 (NDVI + EVI)
#                → data/raw/modis_vi/modis_vi_ghana_{year}.tif (2 bands per file)
#                  stacked into modis_ndvi_ghana_stack.tif + modis_evi_ghana_stack.tif
#   Land cover — MCD12Q1 IGBP annual, 500 m, Ghana, 2001–2024
#                → data/raw/land_cover/land_cover_ghana_{year}.tif + *_stack.tif
#   CHIRPS     — Daily precipitation summed to annual totals (~5.5 km), Ghana, 1990–2025
#                → data/raw/chirps/chirps_ghana_{year}.tif
#
# Workflow:
#   Secs 1–6  submit all GEE export tasks to Google Drive.
#   Sec 6b    optional blocking monitor (uncomment to poll task completion).
#   Sec 7     download completed exports from Drive (uncomment once tasks show COMPLETED).
#   Sec 8     stack downloaded TIFs into multi-layer GeoTIFFs for fast loading.
#
# Run ee_Authenticate() / ee_Initialize(drive = TRUE) interactively —
# they open browser windows and cannot run unattended.

####1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, googledrive, tidyverse, sf, here, janitor, terra, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)

####2. Authenticate ####
rgee::ee_Authenticate()
rgee::ee_Initialize(drive = TRUE)
ee_check()
googledrive::drive_auth()

####3. Study Area ####
gha_country <- st_read(
  here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp"),
  quiet = TRUE) |>
  st_transform(4326)

# Bounding box used as the export region: simpler than a dissolved polygon and
# avoids the sf_as_ee() date-column crash documented in CLAUDE.md.
# Exported rasters cover the full Ghana bounding box; mask to country outline
# in analysis scripts as needed.
bbox_ghana <- st_bbox(gha_country)
ghana_bounds <- ee$Geometry$Rectangle(
  coords   = c(bbox_ghana[["xmin"]], bbox_ghana[["ymin"]],
               bbox_ghana[["xmax"]], bbox_ghana[["ymax"]]),
  proj     = "EPSG:4326",
  geodesic = FALSE)

cat(sprintf("Ghana bounding box: %.3f°W – %.3f°E, %.3f°N – %.3f°N\n",
            bbox_ghana[["xmin"]], bbox_ghana[["xmax"]],
            bbox_ghana[["ymin"]], bbox_ghana[["ymax"]]))

####4. Parameters ####
DRIVE_FOLDER <- "ghana_mining_gee_exports"  # top-level Google Drive folder

NDVI_YEARS   <- 1995:2025  # Landsat composite available from 1984; 1995 aligns with RS pipeline
CHIRPS_YEARS <- 1990:2025  # CHIRPS daily starts 1981-01-01

out_ndvi   <- here("data", "raw", "ndvi")
out_chirps <- here("data", "raw", "chirps")
dir.create(out_ndvi,   recursive = TRUE, showWarnings = FALSE)
dir.create(out_chirps, recursive = TRUE, showWarnings = FALSE)

MODIS_VI_YEARS <- 2000:2025   # MOD13A2 starts 2000-02-18; covers Barenblitt window + margin
LCOVER_YEARS   <- 2001:2024   # MCD12Q1 starts 2001; ~1 yr processing lag → 2024 is safe

out_modis_vi   <- here("data", "raw", "modis_vi")
out_land_cover <- here("data", "raw", "land_cover")
dir.create(out_modis_vi,   recursive = TRUE, showWarnings = FALSE)
dir.create(out_land_cover, recursive = TRUE, showWarnings = FALSE)

####5. NDVI — Landsat C02 T1 L2 Annual Composite (30 m) ####
#
# Collection: LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_NDVI
# Band:       NDVI, float, already scaled to [-1, 1] — no scaling factor needed.
# Compositing: pre-computed annual composite by GEE; one image per calendar year.
#   Quality filters applied by GEE before compositing:
#     - Landsat 7 excluded after 2017-01-01 (scan-line corrector failure drift)
#     - Landsat 8 excluded before 2013-05-01 (pointing issues)
#     - Daytime scenes only (WRS_ROW < 122)
# No further QA masking needed — use first() to retrieve the single annual image.
# Resolution: 30 m (Landsat native); export at 30 m.

message("=== Submitting NDVI export tasks ===")
ndvi_tasks <- map(NDVI_YEARS, \(yr) {
  annual_ndvi <- ee$ImageCollection("LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_NDVI")$
    filterBounds(ghana_bounds)$
    filterDate(paste0(yr, "-01-01"), paste0(yr + 1L, "-01-01"))$
    select("NDVI")$
    first()$                   # one composite image per year
    rename(paste0("ndvi_", yr))

  task <- ee$batch$Export$image$toDrive(
    image          = annual_ndvi,
    description    = paste0("ndvi_ghana_", yr),
    folder         = DRIVE_FOLDER,
    fileNamePrefix = paste0("ndvi_ghana_", yr),
    scale          = 250,
    region         = ghana_bounds,
    crs            = "EPSG:4326",
    maxPixels      = 1e10,
    fileFormat     = "GeoTIFF"
  )
  task$start()
  message(sprintf("  Submitted: ndvi_ghana_%d", yr))
  task
})

message(sprintf("Submitted %d NDVI tasks to Drive folder '%s'.",
                length(ndvi_tasks), DRIVE_FOLDER))

####5b. EVI — Landsat C02 T1 L2 Annual Composite (250 m) ####
#
# Collection: LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_EVI
# Band:       EVI, float, already scaled to [-1, 1].
# Same sensor coverage and quality filters as the NDVI composite:
#   - Landsat 7 excluded after 2017-01-01
#   - Landsat 8 excluded before 2013-05-01
#   - Daytime scenes only (WRS_ROW < 122)
# EVI adds a canopy background correction and uses the blue band to reduce
# aerosol influence — more informative than NDVI in densely vegetated areas.

out_evi <- here("data", "raw", "evi")
dir.create(out_evi, recursive = TRUE, showWarnings = FALSE)

message("\n=== Submitting EVI export tasks ===")
evi_tasks <- map(NDVI_YEARS, \(yr) {
  annual_evi <- ee$ImageCollection("LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_EVI")$
    filterBounds(ghana_bounds)$
    filterDate(paste0(yr, "-01-01"), paste0(yr + 1L, "-01-01"))$
    select("EVI")$
    first()$
    rename(paste0("evi_", yr))

  task <- ee$batch$Export$image$toDrive(
    image          = annual_evi,
    description    = paste0("evi_ghana_", yr),
    folder         = DRIVE_FOLDER,
    fileNamePrefix = paste0("evi_ghana_", yr),
    scale          = 250,
    region         = ghana_bounds,
    crs            = "EPSG:4326",
    maxPixels      = 1e10,
    fileFormat     = "GeoTIFF"
  )
  task$start()
  message(sprintf("  Submitted: evi_ghana_%d", yr))
  task
})

message(sprintf("Submitted %d EVI tasks to Drive folder '%s'.",
                length(evi_tasks), DRIVE_FOLDER))

####5c. MODIS VI — MOD13A2.061 Terra Vegetation Indices 16-Day 1km ####
#
# Collection: MODIS/061/MOD13A2
# Bands:      NDVI, EVI — raw integer * 0.0001 → range [-0.2, 1.0]
# QA:         SummaryQA: 0=good, 1=marginal, 2=snow/ice, 3=cloudy; keep ≤ 1.
# Compositing: annual mean of QA-masked 16-day composites (23 per year).
#   Mean preferred over max here: captures sustained greenness/degradation
#   rather than peak-season values; consistent with the event-study outcome.
# Both NDVI and EVI are exported in a single 2-band file per year to halve
# the task count; Section 8 splits them into separate stacks on download.
# Resolution: 1000 m (native MOD13A2).

message("\n=== Submitting MODIS VI (MOD13A2) export tasks ===")
modis_vi_tasks <- map(MODIS_VI_YEARS, \(yr) {
  annual_vi <- ee$ImageCollection("MODIS/061/MOD13A2")$
    filterBounds(ghana_bounds)$
    filterDate(paste0(yr, "-01-01"), paste0(yr + 1L, "-01-01"))$
    map(function(img) {
      qa <- img$select("SummaryQA")
      img$updateMask(qa$lte(1L))$select(list("NDVI", "EVI"))
    })$
    mean()$                        # annual mean of QA-filtered 16-day composites
    multiply(0.0001)$              # apply MODIS scale factor → [-0.2, 1.0]
    rename(list(paste0("ndvi_", yr), paste0("evi_", yr)))

  task <- ee$batch$Export$image$toDrive(
    image          = annual_vi,
    description    = paste0("modis_vi_ghana_", yr),
    folder         = DRIVE_FOLDER,
    fileNamePrefix = paste0("modis_vi_ghana_", yr),
    scale          = 1000,
    region         = ghana_bounds,
    crs            = "EPSG:4326",
    maxPixels      = 1e10,
    fileFormat     = "GeoTIFF"
  )
  task$start()
  message(sprintf("  Submitted: modis_vi_ghana_%d", yr))
  task
})

message(sprintf("Submitted %d MODIS VI tasks to Drive folder '%s'.",
                length(modis_vi_tasks), DRIVE_FOLDER))

####5d. MODIS Land Cover — MCD12Q1.061 Land Cover Type Yearly 500m ####
#
# Collection: MODIS/061/MCD12Q1
# Band:       LC_Type1 — IGBP classification, 17 classes (uint8, no scale factor).
#   Key classes for Ghana: 2=tropical forest, 8=woody savanna, 9=savanna,
#   10=grasslands, 12=croplands, 14=cropland/natural vegetation mosaic.
# Already annual — one image per calendar year; first() retrieves it.
# Primary use in d06: cropland mask for Q1 NDVI (restrict NDVI to agricultural
#   pixels to isolate the agricultural-welfare channel of upstream mining).
# Resolution: 500 m (native MCD12Q1).

message("\n=== Submitting MODIS Land Cover (MCD12Q1) export tasks ===")
lc_tasks <- map(LCOVER_YEARS, \(yr) {
  annual_lc <- ee$ImageCollection("MODIS/061/MCD12Q1")$
    filterBounds(ghana_bounds)$
    filterDate(paste0(yr, "-01-01"), paste0(yr + 1L, "-01-01"))$
    select("LC_Type1")$
    first()$
    rename(paste0("lc_", yr))

  task <- ee$batch$Export$image$toDrive(
    image          = annual_lc,
    description    = paste0("land_cover_ghana_", yr),
    folder         = DRIVE_FOLDER,
    fileNamePrefix = paste0("land_cover_ghana_", yr),
    scale          = 500,
    region         = ghana_bounds,
    crs            = "EPSG:4326",
    maxPixels      = 1e10,
    fileFormat     = "GeoTIFF"
  )
  task$start()
  message(sprintf("  Submitted: land_cover_ghana_%d", yr))
  task
})

message(sprintf("Submitted %d MODIS Land Cover tasks to Drive folder '%s'.",
                length(lc_tasks), DRIVE_FOLDER))

####6. CHIRPS — Daily Precipitation → Annual Totals ####
#
# Collection: UCSB-CHG/CHIRPS/DAILY (Climate Hazards Group InfraRed Precipitation
#             with Station data, v2.0)
# Band:       precipitation (mm/day)
# Aggregate:  Sum across all days in the calendar year → mm/year
# Resolution: 5566 m (~0.05°, native CHIRPS resolution)
# Coverage:   1981-01-01 onward, 50°S–50°N

message("\n=== Submitting CHIRPS export tasks ===")
chirps_tasks <- map(CHIRPS_YEARS, \(yr) {
  annual_sum <- ee$ImageCollection("UCSB-CHG/CHIRPS/DAILY")$
    filterBounds(ghana_bounds)$
    filterDate(paste0(yr, "-01-01"), paste0(yr, "-12-31"))$
    select("precipitation")$
    sum()$                     # annual total in mm
    rename(paste0("chirps_", yr))

  task <- ee$batch$Export$image$toDrive(
    image          = annual_sum,
    description    = paste0("chirps_ghana_", yr),
    folder         = DRIVE_FOLDER,
    fileNamePrefix = paste0("chirps_ghana_", yr),
    scale          = 5566,
    region         = ghana_bounds,
    crs            = "EPSG:4326",
    maxPixels      = 1e10,
    fileFormat     = "GeoTIFF"
  )
  task$start()
  message(sprintf("  Submitted: chirps_ghana_%d", yr))
  task
})

message(sprintf("Submitted %d CHIRPS tasks to Drive folder '%s'.",
                length(chirps_tasks), DRIVE_FOLDER))

####6b. Monitor tasks (optional — blocks R until all complete) ####
# Uncomment to poll GEE for task completion. Each task typically takes
# 5–20 min. With many tasks, check the Tasks tab rather than blocking R.
#
# walk(ndvi_tasks,       ee_monitoring)
# walk(evi_tasks,        ee_monitoring)
# walk(modis_vi_tasks,   ee_monitoring)
# walk(lc_tasks,         ee_monitoring)
# walk(chirps_tasks,     ee_monitoring)

####7. Download from Google Drive ####
# Run AFTER all GEE tasks show "COMPLETED" in the Tasks tab.
# Skips files already present locally (overwrite = FALSE).

download_from_drive <- function(drive_folder, prefix, local_dir) {
  message(sprintf("Looking for '%s*' in Drive folder '%s'...", prefix, drive_folder))

  # Locate the Drive folder
  folder_dribble <- tryCatch(
    googledrive::drive_ls(path = drive_folder, pattern = paste0("^", prefix)),
    error = function(e) {
      message("  Could not access Drive folder: ", conditionMessage(e))
      return(tibble())
    }
  )

  if (nrow(folder_dribble) == 0) {
    message("  No files found. Check that GEE tasks have completed.")
    return(invisible(NULL))
  }

  message(sprintf("  Found %d file(s). Downloading...", nrow(folder_dribble)))

  walk(seq_len(nrow(folder_dribble)), \(i) {
    dest <- file.path(local_dir, folder_dribble$name[i])
    if (!file.exists(dest)) {
      googledrive::drive_download(
        file      = folder_dribble[i, ],
        path      = dest,
        overwrite = FALSE
      )
      message(sprintf("  Downloaded: %s", folder_dribble$name[i]))
    } else {
      message(sprintf("  Skipping (already exists): %s", folder_dribble$name[i]))
    }
  })

  message(sprintf("  Done. Files in: %s", local_dir))
}

# -- Uncomment once GEE tasks complete ----------------------------------------
# download_from_drive(DRIVE_FOLDER, "ndvi_ghana_",       out_ndvi)
# download_from_drive(DRIVE_FOLDER, "evi_ghana_",        out_evi)
#download_from_drive(DRIVE_FOLDER, "modis_vi_ghana_",   out_modis_vi)
#download_from_drive(DRIVE_FOLDER, "land_cover_ghana_", out_land_cover)
# download_from_drive(DRIVE_FOLDER, "chirps_ghana_",     out_chirps)

message("\n=== d_01_download.R: export tasks submitted ===")
message(sprintf(
  "  NDVI (Landsat):     %d tasks (ndvi_ghana_1995 … 2025, 250 m)", length(ndvi_tasks)
))
message(sprintf(
  "  EVI  (Landsat):     %d tasks (evi_ghana_1995  … 2025, 250 m)", length(evi_tasks)
))
message(sprintf(
  "  MODIS VI (1 km):    %d tasks (modis_vi_ghana_2000 … 2025, NDVI+EVI)", length(modis_vi_tasks)
))
message(sprintf(
  "  Land cover (500 m): %d tasks (land_cover_ghana_2001 … 2024, IGBP LC_Type1)", length(lc_tasks)
))
message(sprintf(
  "  CHIRPS:             %d tasks (chirps_ghana_1990 … 2025)", length(chirps_tasks)
))
message("  Monitor: code.earthengine.google.com → Tasks tab")
message("  Download: uncomment Section 7 once all tasks show COMPLETED")

####8. Load Downloaded TIFs into Raster Stacks ####
# Run AFTER Section 7 has downloaded all files locally.
# terra::rast() on a character vector reads and stacks all layers in one call.
# Layers are named by year for easy subsetting: ndvi_stack[["ndvi_2010"]]
# CRS is EPSG:4326 as exported; reproject to UTM30N (EPSG:32630) in analysis
# scripts when metric distances or area calculations are needed.

stack_from_dir <- function(dir, pattern, prefix) {
  files <- sort(list.files(dir, pattern = pattern, full.names = TRUE))
  if (length(files) == 0) {
    message(sprintf("No %s files found in %s — run Section 7 first.", prefix, dir))
    return(NULL)
  }
  stk   <- terra::rast(files)
  years <- as.integer(stringr::str_extract(basename(files), "\\d{4}"))
  names(stk) <- paste0(prefix, "_", years)
  message(sprintf("%s stack: %d layers (%d–%d), %.0f m res, CRS EPSG:4326",
                  toupper(prefix), terra::nlyr(stk),
                  min(years), max(years),
                  mean(terra::res(stk)) * 111320))  # degrees → approx metres at equator
  stk
}

ndvi_stack <- stack_from_dir(out_ndvi, "^ndvi_ghana_\\d{4}\\.tif$", "ndvi")
evi_stack  <- stack_from_dir(out_evi,  "^evi_ghana_\\d{4}\\.tif$",  "evi")

# Save stacks as multi-layer GeoTIFFs in their respective raw data folders.
# Skips the write if the stack could not be built (NULL) or if the file
# already exists — re-run manually if you want to force an overwrite.
if (!is.null(ndvi_stack)) {
  ndvi_out <- file.path(out_ndvi, "ndvi_ghana_stack.tif")
  if (!file.exists(ndvi_out)) {
    terra::writeRaster(ndvi_stack, ndvi_out, overwrite = FALSE)
    message(sprintf("Saved: %s", ndvi_out))
  } else {
    message(sprintf("Skipping (already exists): %s", ndvi_out))
  }
}

if (!is.null(evi_stack)) {
  evi_out <- file.path(out_evi, "evi_ghana_stack.tif")
  if (!file.exists(evi_out)) {
    terra::writeRaster(evi_stack, evi_out, overwrite = FALSE)
    message(sprintf("Saved: %s", evi_out))
  } else {
    message(sprintf("Skipping (already exists): %s", evi_out))
  }
}

# MODIS VI: each year file has two bands (ndvi_{yr}, evi_{yr}); load full stack
# and split by band prefix into separate NDVI and EVI stacks.
modis_vi_files <- sort(list.files(out_modis_vi,
                                  pattern    = "^modis_vi_ghana_\\d{4}\\.tif$",
                                  full.names = TRUE))
if (length(modis_vi_files) > 0) {
  modis_vi_raw   <- terra::rast(modis_vi_files)
  modis_ndvi_stk <- modis_vi_raw[[grep("^ndvi_", names(modis_vi_raw))]]
  modis_evi_stk  <- modis_vi_raw[[grep("^evi_",  names(modis_vi_raw))]]

  modis_ndvi_out <- file.path(out_modis_vi, "modis_ndvi_ghana_stack.tif")
  modis_evi_out  <- file.path(out_modis_vi, "modis_evi_ghana_stack.tif")
  if (!file.exists(modis_ndvi_out)) {
    terra::writeRaster(modis_ndvi_stk, modis_ndvi_out, overwrite = FALSE)
    message(sprintf("Saved: %s", modis_ndvi_out))
  } else {
    message(sprintf("Skipping (already exists): %s", modis_ndvi_out))
  }
  if (!file.exists(modis_evi_out)) {
    terra::writeRaster(modis_evi_stk, modis_evi_out, overwrite = FALSE)
    message(sprintf("Saved: %s", modis_evi_out))
  } else {
    message(sprintf("Skipping (already exists): %s", modis_evi_out))
  }
} else {
  message("No MODIS VI files found in ", out_modis_vi, " — run Section 7 first.")
}

# Land cover: single-band integer files (LC_Type1 = IGBP class, uint8).
lc_stack <- stack_from_dir(out_land_cover, "^land_cover_ghana_\\d{4}\\.tif$", "lc")
if (!is.null(lc_stack)) {
  lc_out <- file.path(out_land_cover, "land_cover_ghana_stack.tif")
  if (!file.exists(lc_out)) {
    terra::writeRaster(lc_stack, lc_out, datatype = "INT1U", overwrite = FALSE)
    message(sprintf("Saved: %s", lc_out))
  } else {
    message(sprintf("Skipping (already exists): %s", lc_out))
  }
}
