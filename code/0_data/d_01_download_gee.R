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
# Filenames are source-explicit ({source}_{product}_ghana_{year}) so that additional
# products (e.g. a second land-cover source) can be added without collisions.
#
# Downloads:
#   Landsat NDVI — LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_NDVI, 30 m, Ghana, 1995–2025
#                  → data/raw/landsat_vi/landsat_ndvi_ghana_{year}.tif + landsat_ndvi_ghana_stack.tif
#   Landsat EVI  — LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_EVI,  30 m, Ghana, 1995–2025
#                  → data/raw/landsat_vi/landsat_evi_ghana_{year}.tif  + landsat_evi_ghana_stack.tif
#   MODIS NDVI   — MOD13Q1 QA-filtered annual mean, 250 m, Ghana, 2000–2025
#                  → data/raw/modis_vi/modis_ndvi_ghana_{year}.tif + modis_ndvi_ghana_stack.tif
#   MODIS EVI    — MOD13Q1 QA-filtered annual mean, 250 m, Ghana, 2000–2025
#                  → data/raw/modis_vi/modis_evi_ghana_{year}.tif  + modis_evi_ghana_stack.tif
#   Land cover   — MCD12Q1 IGBP annual, 500 m, Ghana, 2001–2024
#                  → data/raw/land_cover/modis_lc_ghana_{year}.tif + modis_lc_ghana_stack.tif
#   CHIRPS       — Daily precipitation summed to annual totals (~5.5 km), Ghana, 1990–2025
#                  → data/raw/chirps/chirps_ghana_{year}.tif
#
# Drive layout: all products export to one Drive folder (ghana_mining_gee_exports);
# the source-explicit filenames keep them unambiguous within it.
#
# Workflow:
#   Secs 1–7  submit all GEE export tasks to Google Drive (5 VIs, 6 land cover, 7 CHIRPS).
#   Sec 7b    optional blocking monitor (uncomment to poll task completion).
#   Sec 8     download completed exports from Drive (uncomment once tasks show COMPLETED).
#   Sec 9     stack downloaded TIFs into multi-layer GeoTIFFs for fast loading.
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
# All products export to one Drive folder; filenames are source-explicit
# ({source}_{product}_ghana_{year}) so they never collide within it.
DRIVE_FOLDER <- "ghana_mining_gee_exports"  # top-level Google Drive folder

NDVI_YEARS   <- 1995:2025  # Landsat composite available from 1984; 1995 aligns with RS pipeline
CHIRPS_YEARS <- 1990:2025  # CHIRPS daily starts 1981-01-01

# Landsat NDVI + EVI share one local folder (distinguished by the landsat_ndvi_ / landsat_evi_ prefix)
out_landsat_vi <- here("data", "raw", "landsat_vi")
out_chirps     <- here("data", "raw", "chirps")
dir.create(out_landsat_vi, recursive = TRUE, showWarnings = FALSE)
dir.create(out_chirps,     recursive = TRUE, showWarnings = FALSE)

MODIS_VI_YEARS <- 2000:2025   # MOD13Q1 starts 2000-02-18; covers Barenblitt window + margin
LCOVER_YEARS   <- 2001:2024   # MCD12Q1 starts 2001; ~1 yr processing lag → 2024 is safe

out_modis_vi   <- here("data", "raw", "modis_vi")
out_land_cover <- here("data", "raw", "land_cover")
dir.create(out_modis_vi,   recursive = TRUE, showWarnings = FALSE)
dir.create(out_land_cover, recursive = TRUE, showWarnings = FALSE)

####5. Landsat NDVI — C02 T1 L2 Annual Composite (30 m) ####
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

message("=== Submitting Landsat NDVI export tasks ===")
ndvi_tasks <- map(NDVI_YEARS, \(yr) {
  annual_ndvi <- ee$ImageCollection("LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_NDVI")$
    filterBounds(ghana_bounds)$
    filterDate(paste0(yr, "-01-01"), paste0(yr + 1L, "-01-01"))$
    select("NDVI")$
    first()$                   # one composite image per year
    rename(paste0("ndvi_", yr))

  task <- ee$batch$Export$image$toDrive(
    image          = annual_ndvi,
    description    = paste0("landsat_ndvi_ghana_", yr),
    folder         = DRIVE_FOLDER,
    fileNamePrefix = paste0("landsat_ndvi_ghana_", yr),
    scale          = 30,
    region         = ghana_bounds,
    crs            = "EPSG:4326",
    maxPixels      = 1e10,
    fileFormat     = "GeoTIFF"
  )
  task$start()
  message(sprintf("  Submitted: landsat_ndvi_ghana_%d", yr))
  task
})

message(sprintf("Submitted %d NDVI tasks to Drive folder '%s'.",
                length(ndvi_tasks), DRIVE_FOLDER))

####5b. Landsat EVI — C02 T1 L2 Annual Composite (30 m) ####
#
# Collection: LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_EVI
# Band:       EVI, float, already scaled to [-1, 1].
# Same sensor coverage and quality filters as the NDVI composite:
#   - Landsat 7 excluded after 2017-01-01
#   - Landsat 8 excluded before 2013-05-01
#   - Daytime scenes only (WRS_ROW < 122)
# EVI adds a canopy background correction and uses the blue band to reduce
# aerosol influence — more informative than NDVI in densely vegetated areas.

# EVI shares the out_landsat_vi folder created in Section 4 (no separate dir needed).

message("\n=== Submitting Landsat EVI export tasks ===")
evi_tasks <- map(NDVI_YEARS, \(yr) {
  annual_evi <- ee$ImageCollection("LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_EVI")$
    filterBounds(ghana_bounds)$
    filterDate(paste0(yr, "-01-01"), paste0(yr + 1L, "-01-01"))$
    select("EVI")$
    first()$
    rename(paste0("evi_", yr))

  task <- ee$batch$Export$image$toDrive(
    image          = annual_evi,
    description    = paste0("landsat_evi_ghana_", yr),
    folder         = DRIVE_FOLDER,
    fileNamePrefix = paste0("landsat_evi_ghana_", yr),
    scale          = 30,
    region         = ghana_bounds,
    crs            = "EPSG:4326",
    maxPixels      = 1e10,
    fileFormat     = "GeoTIFF"
  )
  task$start()
  message(sprintf("  Submitted: landsat_evi_ghana_%d", yr))
  task
})

message(sprintf("Submitted %d EVI tasks to Drive folder '%s'.",
                length(evi_tasks), DRIVE_FOLDER))

####5c. MODIS VI — MOD13Q1.061 Terra Vegetation Indices 16-Day 250m ####
#
# Collection: MODIS/061/MOD13Q1
# Bands:      NDVI, EVI — raw integer * 0.0001 → range [-0.2, 1.0]
# QA:         SummaryQA: 0=good, 1=marginal, 2=snow/ice, 3=cloudy; keep ≤ 1.
# Compositing: annual mean of QA-masked 16-day composites (23 per year).
#   Mean preferred over max here: captures sustained greenness/degradation
#   rather than peak-season values; consistent with the event-study outcome.
# NDVI and EVI are exported as SEPARATE single-band files (modis_ndvi_ghana_ /
#   modis_evi_ghana_) — source-explicit names, uniform with the Landsat exports,
#   and simpler to stack (no band-splitting in Section 8). Two export tasks/year.
# Resolution: 250 m (native MOD13Q1) — finer sibling of MOD13A2 (1 km); same
#   band names, SummaryQA scheme, and 0.0001 scale factor.

message("\n=== Submitting MODIS VI (MOD13Q1) export tasks ===")
modis_vi_tasks <- map(MODIS_VI_YEARS, \(yr) {
  annual_vi <- ee$ImageCollection("MODIS/061/MOD13Q1")$
    filterBounds(ghana_bounds)$
    filterDate(paste0(yr, "-01-01"), paste0(yr + 1L, "-01-01"))$
    map(function(img) {
      qa <- img$select("SummaryQA")
      img$updateMask(qa$lte(1L))$select(list("NDVI", "EVI"))
    })$
    mean()$                        # annual mean of QA-filtered 16-day composites
    multiply(0.0001)$              # apply MODIS scale factor → [-0.2, 1.0]
    rename(list(paste0("ndvi_", yr), paste0("evi_", yr)))

  ndvi_task <- ee$batch$Export$image$toDrive(
    image          = annual_vi$select(paste0("ndvi_", yr)),
    description    = paste0("modis_ndvi_ghana_", yr),
    folder         = DRIVE_FOLDER,
    fileNamePrefix = paste0("modis_ndvi_ghana_", yr),
    scale          = 250,
    region         = ghana_bounds,
    crs            = "EPSG:4326",
    maxPixels      = 1e10,
    fileFormat     = "GeoTIFF"
  )
  evi_task <- ee$batch$Export$image$toDrive(
    image          = annual_vi$select(paste0("evi_", yr)),
    description    = paste0("modis_evi_ghana_", yr),
    folder         = DRIVE_FOLDER,
    fileNamePrefix = paste0("modis_evi_ghana_", yr),
    scale          = 250,
    region         = ghana_bounds,
    crs            = "EPSG:4326",
    maxPixels      = 1e10,
    fileFormat     = "GeoTIFF"
  )
  ndvi_task$start()
  evi_task$start()
  message(sprintf("  Submitted: modis_ndvi_ghana_%d + modis_evi_ghana_%d", yr, yr))
  list(ndvi = ndvi_task, evi = evi_task)
})

message(sprintf("Submitted %d MODIS VI tasks (%d years × 2 indices) to Drive folder '%s'.",
                2L * length(modis_vi_tasks), length(modis_vi_tasks), DRIVE_FOLDER))

####6. Land Cover — MODIS MCD12Q1.061 Land Cover Type Yearly 500m ####
# Kept in its own section (separate from the Section 5 vegetation indices); the
# modis_lc_ prefix leaves room for a second land-cover product (e.g. ESA CCI) later.
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
    description    = paste0("modis_lc_ghana_", yr),
    folder         = DRIVE_FOLDER,
    fileNamePrefix = paste0("modis_lc_ghana_", yr),
    scale          = 500,
    region         = ghana_bounds,
    crs            = "EPSG:4326",
    maxPixels      = 1e10,
    fileFormat     = "GeoTIFF"
  )
  task$start()
  message(sprintf("  Submitted: modis_lc_ghana_%d", yr))
  task
})

message(sprintf("Submitted %d MODIS Land Cover tasks to Drive folder '%s'.",
                length(lc_tasks), DRIVE_FOLDER))

####7. CHIRPS — Daily Precipitation → Annual Totals ####
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

####7b. Monitor tasks (optional — blocks R until all complete) ####
# Uncomment to poll GEE for task completion. Each task typically takes
# 5–20 min. With many tasks, check the Tasks tab rather than blocking R.
# NOTE: modis_vi_tasks is a list of per-year list(ndvi=, evi=) pairs, so flatten first.
#
# walk(ndvi_tasks,                      ee_monitoring)
# walk(evi_tasks,                       ee_monitoring)
# walk(purrr::flatten(modis_vi_tasks),  ee_monitoring)
# walk(lc_tasks,                        ee_monitoring)
# walk(chirps_tasks,                    ee_monitoring)

####8. Download from Google Drive ####
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
# download_from_drive(DRIVE_FOLDER, "landsat_ndvi_ghana_", out_landsat_vi)
# download_from_drive(DRIVE_FOLDER, "landsat_evi_ghana_",  out_landsat_vi)
# download_from_drive(DRIVE_FOLDER, "modis_ndvi_ghana_",   out_modis_vi)
# download_from_drive(DRIVE_FOLDER, "modis_evi_ghana_",    out_modis_vi)
# download_from_drive(DRIVE_FOLDER, "modis_lc_ghana_",     out_land_cover)
# download_from_drive(DRIVE_FOLDER, "chirps_ghana_",       out_chirps)

message("\n=== d_01_download.R: export tasks submitted ===")
message(sprintf(
  "  Landsat NDVI (30 m):  %d tasks (landsat_ndvi_ghana_1995 … 2025)", length(ndvi_tasks)
))
message(sprintf(
  "  Landsat EVI  (30 m):  %d tasks (landsat_evi_ghana_1995  … 2025)", length(evi_tasks)
))
message(sprintf(
  "  MODIS VI (250 m):     %d tasks (modis_{ndvi,evi}_ghana_2000 … 2025, %d yrs × 2)",
  2L * length(modis_vi_tasks), length(modis_vi_tasks)
))
message(sprintf(
  "  Land cover (500 m):   %d tasks (modis_lc_ghana_2001 … 2024, IGBP LC_Type1)", length(lc_tasks)
))
message(sprintf(
  "  CHIRPS:               %d tasks (chirps_ghana_1990 … 2025)", length(chirps_tasks)
))
message("  Monitor: code.earthengine.google.com → Tasks tab")
message("  Download: uncomment Section 8 once all tasks show COMPLETED")

####9. Load Downloaded TIFs into Raster Stacks ####
# Run AFTER Section 8 has downloaded all files locally.
# terra::rast() on a character vector reads and stacks all layers in one call.
# Layers are named by year for easy subsetting: ndvi_stack[["ndvi_2010"]]
# CRS is EPSG:4326 as exported; reproject to UTM30N (EPSG:32630) in analysis
# scripts when metric distances or area calculations are needed.

stack_from_dir <- function(dir, pattern, prefix) {
  files <- sort(list.files(dir, pattern = pattern, full.names = TRUE))
  if (length(files) == 0) {
    message(sprintf("No %s files found in %s — run Section 8 first.", prefix, dir))
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

# Small helper: write a stack to <dir>/<name>.tif, skipping NULL or existing files.
save_stack <- function(stk, dir, name, ...) {
  if (is.null(stk)) return(invisible(NULL))
  out <- file.path(dir, name)
  if (!file.exists(out)) {
    terra::writeRaster(stk, out, overwrite = FALSE, ...)
    message(sprintf("Saved: %s", out))
  } else {
    message(sprintf("Skipping (already exists): %s", out))
  }
}

# Landsat NDVI + EVI share out_landsat_vi; distinguished by the landsat_ndvi_ / landsat_evi_ prefix.
ndvi_stack <- stack_from_dir(out_landsat_vi, "^landsat_ndvi_ghana_\\d{4}\\.tif$", "ndvi")
evi_stack  <- stack_from_dir(out_landsat_vi, "^landsat_evi_ghana_\\d{4}\\.tif$",  "evi")
save_stack(ndvi_stack, out_landsat_vi, "landsat_ndvi_ghana_stack.tif")
save_stack(evi_stack,  out_landsat_vi, "landsat_evi_ghana_stack.tif")

# MODIS VI: NDVI and EVI are now separate single-band files — stack each directly.
modis_ndvi_stk <- stack_from_dir(out_modis_vi, "^modis_ndvi_ghana_\\d{4}\\.tif$", "ndvi")
modis_evi_stk  <- stack_from_dir(out_modis_vi, "^modis_evi_ghana_\\d{4}\\.tif$",  "evi")
save_stack(modis_ndvi_stk, out_modis_vi, "modis_ndvi_ghana_stack.tif")
save_stack(modis_evi_stk,  out_modis_vi, "modis_evi_ghana_stack.tif")

# Land cover: single-band integer files (LC_Type1 = IGBP class, uint8).
lc_stack <- stack_from_dir(out_land_cover, "^modis_lc_ghana_\\d{4}\\.tif$", "lc")
save_stack(lc_stack, out_land_cover, "modis_lc_ghana_stack.tif", datatype = "INT1U")
