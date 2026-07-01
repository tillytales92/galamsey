# d_04_merit.R
# Hydro-geomorphic analysis from MERIT-DEM + MERIT Hydro for the FULL Barenblitt study area (SW
# Ghana): GEE export -> local reproject -> flow direction / streams (Sec 7), HAND / MRVBF / SPI-STI
# (Sec 8-10, DISABLED by default — heavy at study-area scale), and the D8 hex flow graph + upstream
# galamsey-exposure builder (Sec 11) on the canonical d03 5 km hex grid (full SW Ghana).
#
# Background and full conceptual framework: code/0_data/gold_deposits.md — read that first.
#
# Two MERIT products (do not confuse them):
#   MERIT-DEM   (Yamazaki et al. 2017) — error-reduced 90 m DEM. Band 'dem'. Use for elevation,
#               slope, MRVBF. NOT flow routing.
#   MERIT Hydro (Yamazaki et al. 2019) — pre-conditioned routing layers. Bands: 'dir' D8 flow
#               direction (ESRI: E=1 SE=2 S=4 SW=8 W=16 NW=32 N=64 NE=128); 'upa' upstream drainage
#               area (km²); 'wth' river width (m, 0=none); 'elv' hydrologically adjusted elevation.
#               Use for flow direction, streams, HAND. NOT morphometry (elv is altered).
#
# Workflow (run interactively — browser auth in Sec 2):
#   Sec 1-4   env + auth + study-area geometry + submit GEE exports to Drive.
#   Sec 5     fetch from Drive once the EE Tasks tab shows COMPLETED.
#   Sec 6     reproject to UTM30N (per-band resampling; multi-tile mosaic via read_merit).
#   Sec 7     flow direction + stream network (study-area-wide).
#   Sec 8-10  HAND / MRVBF / SPI-STI / Strahler — DISABLED (if(FALSE)); heavy at study-area scale.
#   Sec 11    D8 hex flow graph + upstream exposure on the d03 5 km hex grid (full SW Ghana).
#             Feeds 2_build/b_04_event_panel.R via data/processed/merit/hex_flow_edges_5km.csv.
#
# Region tag: REGION_TAG = "studyarea" (full Barenblitt extent + buffer).
#
# Outputs: data/raw/merit/ (exports) | data/processed/merit/ (UTM working + derived) |
#          outputs/figures/merit/ (plots).

####1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
# Load `here` AFTER tidyverse (lubridate::here masks here::here otherwise).
pacman::p_load(rgee, googledrive, sf, terra, janitor, tidyverse, whitebox, RSAGA, igraph,
               leaflet, htmlwidgets, patchwork, here, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)
UTM30N <- 32630

DRIVE_FOLDER <- "ghana_mining_gee_exports"
MERIT_SCALE  <- 90          # native MERIT resolution (~3 arc-sec)
REGION_TAG   <- "studyarea" # export-region tag
BUFFER_KM    <- 25          # buffer around the Barenblitt extent for the GEE export (km)
dem_prefix   <- paste0("merit_dem_",   REGION_TAG)
hydro_prefix <- paste0("merit_hydro_", REGION_TAG)

out_dir  <- here("data", "raw",       "merit")
proc_dir <- here("data", "processed", "merit")
fig_dir  <- here("outputs", "figures", "merit")
for (d in c(out_dir, proc_dir, fig_dir)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

HEX_KM_TEST <- 5   # Ankobra-demo hex size (km) for the Sec 11 flow graph + galamsey overlays

# Galamsey (Barenblitt artisanal mining, minetype == 1) loader — used to overlay mining-affected
# hexes on the Sec 10a SPI and Sec 11 flow-direction figures. Coverage caveat: Barenblitt is SW
# Ghana only, but the Ankobra falls inside it. Returns UTM30N sf, or NULL if the shapefile is absent.
load_galamsey <- function() {
  bp <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")
  if (!file.exists(bp)) { message("Barenblitt galamsey shapefile not found — skipping overlay."); return(NULL) }
  sf::st_read(bp, quiet = TRUE) |>
    janitor::clean_names() |>
    sf::st_make_valid() |>
    dplyr::filter(mine_type == 1) |>          # 1 = artisanal = galamsey
    sf::st_transform(UTM30N)
}

# Hexes intersecting galamsey, on a fresh grid over a raster's extent (Sec 10a uses this).
galamsey_hexes_over <- function(template_rast, gal, hex_km = HEX_KM_TEST) {
  if (is.null(gal)) return(NULL)
  hex_g <- sf::st_make_grid(
    sf::st_as_sf(terra::as.polygons(terra::ext(template_rast), crs = paste0("EPSG:", UTM30N))),
    cellsize = hex_km * 1000, square = FALSE) |> sf::st_sf()
  hex_g[lengths(sf::st_intersects(hex_g, gal)) > 0, ]
}

# Read a downloaded MERIT export. GEE may split a large region into several GeoTIFF tiles
# (prefix-0000000000-0000000000.tif ...); mosaic them via VRT into one SpatRaster.
read_merit <- function(prefix, dir = out_dir) {
  tiles <- list.files(dir, pattern = paste0("^", prefix, ".*\\.tif$"), full.names = TRUE)
  if (length(tiles) == 0) return(NULL)
  if (length(tiles) == 1) terra::rast(tiles) else terra::vrt(tiles, overwrite = TRUE)
}

####2. Authenticate ####
# Opens browser windows — run interactively; cannot run unattended.
rgee::ee_Authenticate()
rgee::ee_Initialize(drive = TRUE)
ee_check()
googledrive::drive_auth()

####3. Study area — full Barenblitt extent (SW Ghana) ####
# Bounding box of the Barenblitt 2019 mining extent + BUFFER_KM, in EPSG:4326 for GEE. A rectangle
# (not a dissolved polygon) avoids the sf_as_ee() date-column crash. MERIT 'upa' is a GLOBAL
# accumulation, so clipping to this box does not corrupt upstream-area values inside it.
# Fast path: bbox(union) == bbox(all features), so st_union() is skipped entirely; the buffer
# is applied directly to the numeric bbox values (no polygon dissolve needed).
barenblitt_path <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")
utm_bbox <- sf::st_read(barenblitt_path, quiet = TRUE) |>
  sf::st_transform(UTM30N) |>
  sf::st_bbox()
buf_m <- BUFFER_KM * 1000
utm_bbox["xmin"] <- utm_bbox["xmin"] - buf_m
utm_bbox["ymin"] <- utm_bbox["ymin"] - buf_m
utm_bbox["xmax"] <- utm_bbox["xmax"] + buf_m
utm_bbox["ymax"] <- utm_bbox["ymax"] + buf_m
study_bbox <- utm_bbox |>
  sf::st_as_sfc() |>
  sf::st_transform(4326) |>
  sf::st_bbox()
region_bounds <- ee$Geometry$Rectangle(
  coords = c(study_bbox[["xmin"]], study_bbox[["ymin"]], study_bbox[["xmax"]], study_bbox[["ymax"]]),
  proj = "EPSG:4326", geodesic = FALSE)
cat(sprintf("GEE export bbox (%s, +%g km): %.3f-%.3f degE, %.3f-%.3f degN\n", REGION_TAG, BUFFER_KM,
            study_bbox[["xmin"]], study_bbox[["xmax"]], study_bbox[["ymin"]], study_bbox[["ymax"]]))

####4. GEE: export MERIT products to Drive ####
# Native EPSG:4326 at 90 m — NOT a server-side UTM reproject (slow + corrupts categorical 'dir').
# Reproject locally in Section 6. Over the full study area the hydro export may TILE into several
# GeoTIFFs; read_merit() (Sec 1) mosaics them. Skip this block if the exports already exist on Drive.
merit_dem_img <- ee$Image("MERIT/DEM/v1_0_3")$select("dem")$clip(region_bounds)
ee$batch$Export$image$toDrive(
  image = merit_dem_img, description = dem_prefix, folder = DRIVE_FOLDER, fileNamePrefix = dem_prefix,
  scale = MERIT_SCALE, region = region_bounds, crs = "EPSG:4326", maxPixels = 1e10,
  fileFormat = "GeoTIFF")$start()
message("Submitted: ", dem_prefix)

# toFloat(): 'dir' is Byte while upa/wth/elv are Float32; a multi-band GeoTIFF needs one dtype.
# D8 codes (0-247) are exact in Float32, so the cast is lossless.
merit_hydro_img <- ee$Image("MERIT/Hydro/v1_0_1")$
  select(c("dir", "upa", "wth", "elv"))$toFloat()$clip(region_bounds)
ee$batch$Export$image$toDrive(
  image = merit_hydro_img, description = hydro_prefix, folder = DRIVE_FOLDER,
  fileNamePrefix = hydro_prefix, scale = MERIT_SCALE, region = region_bounds, crs = "EPSG:4326",
  maxPixels = 1e10, fileFormat = "GeoTIFF")$start()
message("Submitted: ", hydro_prefix, "  — monitor at code.earthengine.google.com (Tasks tab)")

####5. Fetch the GEE exports from Google Drive ####
# Run AFTER both Section 4 tasks show COMPLETED on the EE Tasks tab (auth done in Section 2).
# Files land in out_dir as merit_{dem,hydro}_<REGION_TAG>(-tile).tif.

download_gee <- function(drive_folder, prefix, local_dir) {
  message(sprintf("Looking for '%s*' in Drive folder '%s'...", prefix, drive_folder))
  folder_dribble <- tryCatch(
    googledrive::drive_ls(path = drive_folder, pattern = paste0("^", prefix)),
    error = function(e) { message("  Drive error: ", conditionMessage(e)); return(tibble()) }
  )
  if (nrow(folder_dribble) == 0) {
    message("  Not found — check GEE Tasks tab."); return(invisible(NULL))
  }
  walk(seq_len(nrow(folder_dribble)), \(i) {
    dest <- file.path(local_dir, folder_dribble$name[i])
    if (!file.exists(dest)) {
      googledrive::drive_download(file = folder_dribble[i, ], path = dest, overwrite = FALSE)
      message("  Downloaded: ", folder_dribble$name[i])
    } else {
      message("  Already exists: ", folder_dribble$name[i])
    }
  })
}

#download_gee(DRIVE_FOLDER, dem_prefix,   out_dir)
#download_gee(DRIVE_FOLDER, hydro_prefix, out_dir)

####6. Load locally + reproject to UTM30N ####
# Exports are native EPSG:4326 (Section 4) to keep the GEE task fast. Reproject to
# UTM30N here so downstream WhiteboxTools / SAGA steps run on a metric grid. Per-band resampling:
#   dir, upa, wth -> NEAREST: 'dir' is categorical D8 codes (bilinear invents fake directions);
#                    'upa'/'wth' define ~1-px channels that bilinear would smear below the
#                    stream threshold, dropping real channels.
#   elv           -> BILINEAR: a smooth elevation surface (used for HAND's vertical drop).
# The DEM is reprojected onto the SAME grid as the hydro stack (shared template) so Section 10's
# slope × upa algebra aligns cell-for-cell. read_merit() mosaics multi-tile exports. Run after Sec 5.

dem_utm_path   <- file.path(proc_dir, paste0(dem_prefix,   "_utm30n.tif"))  # working, UTM30N
hydro_utm_path <- file.path(proc_dir, paste0(hydro_prefix, "_utm30n.tif"))  # working, UTM30N

merit_hydro_ll <- read_merit(hydro_prefix)   # raw download, EPSG:4326 (NULL if not yet fetched)
merit_dem_ll   <- read_merit(dem_prefix)
files_ready    <- !is.null(merit_hydro_ll) && !is.null(merit_dem_ll)

if (files_ready) {

  names(merit_hydro_ll) <- c("dir", "upa", "wth", "elv")
  names(merit_dem_ll)   <- "dem"

  utm_crs <- paste0("EPSG:", UTM30N)

  # Hydro: dir/upa/wth nearest, elv bilinear, recombined in band order. Project the continuous
  # band onto the nearest-projected grid so all four bands share one grid.
  hydro_near <- terra::project(merit_hydro_ll[[c("dir", "upa", "wth")]], utm_crs,
                               method = "near", res = MERIT_SCALE)
  hydro_elv  <- terra::project(merit_hydro_ll[["elv"]], hydro_near, method = "bilinear")
  merit_hydro <- c(hydro_near, hydro_elv)
  names(merit_hydro) <- c("dir", "upa", "wth", "elv")

  # DEM onto the SAME grid as the hydro stack (template = merit_hydro) for Section 10 alignment.
  merit_dem <- terra::project(merit_dem_ll, merit_hydro[[1]], method = "bilinear")
  names(merit_dem) <- "dem"

  terra::writeRaster(merit_hydro, hydro_utm_path, overwrite = TRUE)
  terra::writeRaster(merit_dem,   dem_utm_path,   overwrite = TRUE)
  message("Reprojected to UTM30N + wrote working files to ", proc_dir)

  cat("\n=== MERIT-DEM (UTM30N) ===\n"); print(merit_dem)
  cat("\n=== MERIT Hydro (UTM30N) ===\n"); print(merit_hydro)

  cat("\n--- Hydro band summaries ---\n")
  for (b in names(merit_hydro)) {
    v <- terra::values(merit_hydro[[b]], na.rm = TRUE)
    cat(sprintf("  %-4s : min=%8.1f  median=%8.1f  max=%8.1f\n", b, min(v), median(v), max(v)))
  }

} else {
  message("MERIT files not found in ", out_dir, " — run Sections 2-5 first (submit + fetch).")
}

####7. Flow direction (D8) from MERIT Hydro ####
# The 'dir' band encodes the D8 steepest-descent direction using the ESRI standard:
#
#   32  64  128
#   16   *    1
#    8   4    2
#
#   E=1, SE=2, S=4, SW=8, W=16, NW=32, N=64, NE=128
#   0  = river mouth / endorheic outlet    (no downstream neighbour)
#   247= ocean / off-land mask
#
# Compatibility with WhiteboxTools: WBT's wbt_d8_pointer uses the SAME ESRI encoding,
# so MERIT Hydro's 'dir' can be passed directly to WBT functions that expect a D8 pointer
# raster (wbt_d8_flow_accumulation, wbt_strahler_stream_order, etc.) — no recoding needed.
# Verify: run wbt_d8_pointer on a patch of the elv band and compare with merit_hydro$dir;
# the values should match for all non-sink cells.
#
# The 'upa' band replaces flow accumulation: cells with large upa are the main channels.
# 'wth' is Yamazaki's pre-mapped river width from satellite + OSM fusion — a stricter,
# validated channel mask than a simple upa threshold.

if (files_ready) {

  merit_hydro <- terra::rast(hydro_utm_path)
  names(merit_hydro) <- c("dir", "upa", "wth", "elv")

  # -- 7a. Direction frequency table --
  dir_bearing <- c(`1`=90, `2`=135, `4`=180, `8`=225, `16`=270, `32`=315, `64`=0, `128`=45)
  dir_vals <- terra::values(merit_hydro[["dir"]], na.rm = TRUE)
  land_vals <- dir_vals[dir_vals %in% as.integer(names(dir_bearing))]

  dir_tbl <- table(land_vals) |>
    as_tibble() |>
    setNames(c("code", "count")) |>
    mutate(
      code    = as.integer(code),
      bearing = dir_bearing[as.character(code)],
      dir     = case_when(
        bearing ==   0 ~ "N",  bearing ==  45 ~ "NE", bearing ==  90 ~ "E",
        bearing == 135 ~ "SE", bearing == 180 ~ "S",  bearing == 225 ~ "SW",
        bearing == 270 ~ "W",  bearing == 315 ~ "NW"
      ),
      pct = round(100 * count / sum(count), 1)
    ) |>
    arrange(bearing)

  cat("\n=== D8 flow direction distribution (study area) ===\n")
  print(dir_tbl, n = Inf)

  cat(sprintf("\nSink/outlet cells (dir == 0):  %d\n", sum(dir_vals == 0, na.rm = TRUE)))
  cat(sprintf("Ocean mask cells  (dir == 247): %d\n", sum(dir_vals == 247, na.rm = TRUE)))

  # -- 7b. Stream network from upa --
  # Threshold the upstream area to define channels. 4th-order tributaries start around 50 km²;
  # calibrate against OSM natural watercourses (see d_03_waterways.R) — too low → every gully
  # is a "stream", HAND ≈ 0 everywhere.
  STREAM_KM2 <- 50

  n_stream <- sum(terra::values(merit_hydro[["upa"]], na.rm = TRUE) > STREAM_KM2)
  cat(sprintf("\nStream cells (upa > %g km²): %d  |  main channels (upa > 5000 km²): %d\n",
              STREAM_KM2,
              n_stream,
              sum(terra::values(merit_hydro[["upa"]], na.rm = TRUE) > 5000)))

  # -- 7c. Diagnostic plot: upa + wth-based channel mask --
  png(file.path(fig_dir, "studyarea_flow_network.png"), width = 1800, height = 900, res = 150)
  par(mfrow = c(1, 2), mar = c(1, 1, 3, 2))

  upa_plot <- log1p(merit_hydro[["upa"]])
  terra::plot(upa_plot, main = "log(1 + upstream area)  [km²]",
              col = hcl.colors(50, "Blues", rev = TRUE), axes = FALSE, legend = TRUE)

  wth_ch <- merit_hydro[["wth"]]
  wth_ch[wth_ch == 0] <- NA
  terra::plot(wth_ch, main = "River channel width (m)  — MERIT Hydro 'wth'",
              col = hcl.colors(30, "Blues", rev = TRUE), axes = FALSE, legend = TRUE)
  dev.off()
  message("Saved: studyarea_flow_network.png")

}

####8. HAND — Height Above Nearest Drainage ####
# MERIT Hydro replaces the DEM-conditioning chain (d_06_gold_deposits.R Sections A-C):
#   'elv' is already hydrologically adjusted — no breaching needed.
#   'upa' thresholded > STREAM_KM2 gives a stream mask — replaces extract_streams.
#   Pass these to wbt_elevation_above_stream → HAND.
#
# Alluvial-gold interpretation:
#   HAND  0 – 2 m   active floodplain  (modern alluvium, actively reworked — prime galamsey)
#   HAND  2 – 10 m  river terraces     (paleo-placers, classic galamsey targets)
#   HAND >10 m      upland             (not depositional)
#
# Requires WhiteboxTools: whitebox::install_whitebox()

STREAM_KM2 <- 50   # must match Section 7

if (FALSE) {   # Section 8 DISABLED — heavy at study-area scale; flip to files_ready to enable

  if (!isTRUE(try(whitebox::check_whitebox_binary(), silent = TRUE)))
    stop("WhiteboxTools not found — run whitebox::install_whitebox() then restart R.")

  merit_hydro <- terra::rast(hydro_utm_path)
  names(merit_hydro) <- c("dir", "upa", "wth", "elv")

  # Stage working rasters; WBT reads/writes files on disk.
  elv_path    <- file.path(proc_dir, "ankobra_elv.tif")
  stream_path <- file.path(proc_dir, "ankobra_streams.tif")
  hand_path   <- file.path(proc_dir, "ankobra_hand.tif")

  terra::writeRaster(merit_hydro[["elv"]], elv_path, overwrite = TRUE)

  # Stream mask: 1 = channel, 0 = non-channel (WBT expects integer, not logical/NA)
  stream_r <- terra::app(merit_hydro[["upa"]], fun = \(x) as.integer(x > STREAM_KM2))
  terra::writeRaster(stream_r, stream_path, overwrite = TRUE, datatype = "INT1U")

  if (!file.exists(hand_path)) {
    message("Computing HAND (WhiteboxTools ElevationAboveStream)...")
    whitebox::wbt_elevation_above_stream(dem = elv_path, streams = stream_path, output = hand_path)
  }

  hand      <- terra::rast(hand_path)
  hand_vals <- terra::values(hand, na.rm = TRUE)

  cat("\n=== HAND summary (Ankobra basin) ===\n")
  cat(sprintf("  Active floodplain (< 2 m):   %6d cells  (%4.1f%%)\n",
              sum(hand_vals <  2),                    100 * mean(hand_vals <  2)))
  cat(sprintf("  River terraces   (2 – 10 m): %6d cells  (%4.1f%%)\n",
              sum(hand_vals >= 2 & hand_vals < 10),   100 * mean(hand_vals >= 2 & hand_vals < 10)))
  cat(sprintf("  High terrace     (10 – 30 m):%6d cells  (%4.1f%%)\n",
              sum(hand_vals >= 10 & hand_vals < 30),  100 * mean(hand_vals >= 10 & hand_vals < 30)))
  cat(sprintf("  Upland           (> 30 m):   %6d cells  (%4.1f%%)\n",
              sum(hand_vals >= 30),                   100 * mean(hand_vals >= 30)))

  # Classify into geomorphic zones
  hand_class <- terra::classify(hand,
    rcl = matrix(c(0, 2, 1,  2, 10, 2,  10, 30, 3,  30, Inf, 4), ncol = 3, byrow = TRUE),
    include.lowest = TRUE
  )
  names(hand_class) <- "hand_zone"
  terra::writeRaster(hand_class,
                     file.path(proc_dir, "ankobra_hand_zones.tif"),
                     overwrite = TRUE, datatype = "INT1U")

  zone_cols <- c("1" = "#2166AC", "2" = "#74ADD1", "3" = "#D1E5F0", "4" = "#F7F7F7")

  png(file.path(fig_dir, "ankobra_hand_zones.png"), width = 1200, height = 1200, res = 150)
  par(mar = c(2, 2, 3, 5))
  terra::plot(hand_class, main = "HAND zones — Ankobra basin (MERIT Hydro)",
              col = zone_cols, type = "classes", axes = FALSE,
              levels = c("Floodplain (0-2m)", "Terrace (2-10m)",
                         "High terrace (10-30m)", "Upland (>30m)"))
  dev.off()
  message("Saved: ankobra_hand_zones.png")

}

####9. MRVBF — Multiresolution Index of Valley Bottom Flatness ####
# IMPORTANT: use MERIT-DEM ('dem' band), NOT MERIT Hydro's 'elv'. The 'elv' band has been
# nudged cell-by-cell to enforce downhill flow consistency — that distorts the flatness and
# local-lowness signals that MRVBF measures. MERIT-DEM is error-reduced but morphologically
# intact.
#
# MRVBF requires SAGA GIS (no WhiteboxTools equivalent). Install SAGA separately, then
# configure RSAGA::rsaga.env(path = "C:/path/to/saga"). Mirrors d_06_gold_deposits.R §E.
# Values ≥ 1 conventionally flag "valley bottom".

if (FALSE) {   # Section 9 DISABLED — heavy at study-area scale; flip to files_ready to enable

  merit_dem    <- terra::rast(dem_utm_path)
  names(merit_dem) <- "dem"
  dem_path_proc <- file.path(proc_dir, "ankobra_dem.tif")
  terra::writeRaster(merit_dem, dem_path_proc, overwrite = TRUE)

  mrvbf_path <- file.path(proc_dir, "ankobra_mrvbf.tif")

  if (!file.exists(mrvbf_path)) {
    saga_ok <- requireNamespace("RSAGA", quietly = TRUE) &&
               !inherits(try(saga_env <- RSAGA::rsaga.env(), silent = TRUE), "try-error") &&
               nzchar(saga_env$path)

    if (saga_ok) {
      message("Computing MRVBF (SAGA ta_morphometry)...")
      saga_tmp <- file.path(tempdir(), "saga_merit"); dir.create(saga_tmp, showWarnings = FALSE)
      saga_dem <- file.path(saga_tmp, "dem")
      RSAGA::rsaga.import.gdal(in.grid = dem_path_proc, out.grid = saga_dem, env = saga_env)
      RSAGA::rsaga.geoprocessor(
        lib    = "ta_morphometry",
        module = "Multiresolution Index of Valley Bottom Flatness (MRVBF)",
        param  = list(
          DEM   = paste0(saga_dem, ".sgrd"),
          MRVBF = file.path(saga_tmp, "mrvbf.sgrd"),
          MRRTF = file.path(saga_tmp, "mrrtf.sgrd")
        ),
        env = saga_env
      )
      terra::writeRaster(terra::rast(file.path(saga_tmp, "mrvbf.sdat")),
                         mrvbf_path, overwrite = TRUE)
      message("MRVBF written to: ", mrvbf_path)
    } else {
      message("SAGA not configured — install SAGA GIS + rsaga.env(path='...'). ",
              "See d_06_gold_deposits.R Section E.")
    }
  }

  if (file.exists(mrvbf_path)) {
    mrvbf      <- terra::rast(mrvbf_path)
    mrvbf_vals <- terra::values(mrvbf, na.rm = TRUE)
    cat(sprintf("\n=== MRVBF summary ===\n  Valley-bottom cells (MRVBF ≥ 1): %.1f%%\n",
                100 * mean(mrvbf_vals >= 1)))
    png(file.path(fig_dir, "ankobra_mrvbf.png"), width = 1200, height = 1200, res = 150)
    terra::plot(mrvbf, main = "MRVBF — valley bottom flatness (MERIT-DEM)",
                col = hcl.colors(50, "viridis"), axes = FALSE)
    dev.off()
    message("Saved: ankobra_mrvbf.png")
  }

}

####10. Derived indices ####
# Additional alluvial-gold indicators computable from the MERIT layers.

if (FALSE) {   # Section 10 DISABLED — heavy at study-area scale; flip to files_ready to enable

  merit_dem   <- terra::rast(dem_utm_path);   names(merit_dem)   <- "dem"
  merit_hydro <- terra::rast(hydro_utm_path); names(merit_hydro) <- c("dir", "upa", "wth", "elv")

  # -- 10a. Stream Power Index (SPI) + channel-conditional placer-trap layer --
  # SPI = ln(specific_catchment_area × tan(slope)).
  #   Specific catchment area (m²/m) = upa (km²) × 1e6 / cell_width (m).
  # Physics: SPI proxies the energy available to move sediment.
  #   High SPI = steep, high-discharge reach → gold is transported, not deposited (erosive).
  #   Low SPI on a channel = low-energy reach → heavy minerals (gold ≈ 19× water density)
  #                          drop out first → PLACER TRAP. This is the galamsey target.
  #
  # SUBTLETY (why raw SPI alone is ambiguous): SPI is LOW in two opposite places —
  #   (i) depositional channel reaches (low slope, high upa)  ← what we want, and
  #   (ii) dry uplands/ridges (slope present but upa → 0)      ← irrelevant.
  # It is HIGH in both erosive headwaters and the steep trunk. So the depositional signal
  # only reads correctly CONDITIONAL ON BEING ON A CHANNEL. We therefore export both:
  #   - spi            : continuous covariate (full grid)            → ankobra_spi.tif
  #   - placer_trap    : 1 = channel cell (upa > STREAM_KM2) in the
  #                      low-SPI tail (below the channel-SPI median)  → ankobra_placer_trap.tif
  # The placer_trap mask is the physically interpretable layer; raw spi is kept so the
  # downstream model can also use it as an interaction (gold_suit × spi), per gold_deposits.md.
  STREAM_KM2 <- 50   # must match Sections 7-8 (channel definition)

  slope_rad  <- terra::terrain(merit_dem, v = "slope", unit = "radians")
  sca        <- merit_hydro[["upa"]] * 1e6 / MERIT_SCALE   # specific catchment area (m²/m)
  spi        <- log(sca * tan(slope_rad + 1e-6))            # +epsilon guards against log(0)
  names(spi) <- "spi"
  terra::writeRaster(spi, file.path(proc_dir, "ankobra_spi.tif"), overwrite = TRUE)

  cat("\n=== SPI summary (full grid) ===\n")
  print(terra::global(spi, fun = c("mean", "sd", "min", "max"), na.rm = TRUE))

  # Channel-conditional placer trap: restrict to channel cells, then flag the low-SPI tail.
  channel_mask <- merit_hydro[["upa"]] > STREAM_KM2
  spi_channel  <- terra::mask(spi, channel_mask, maskvalues = c(FALSE, NA))
  chan_vals    <- terra::values(spi_channel, na.rm = TRUE)

  if (length(chan_vals) > 0) {
    spi_med     <- stats::median(chan_vals)
    placer_trap <- terra::ifel(spi_channel <= spi_med, 1L, 0L)
    names(placer_trap) <- "placer_trap"
    terra::writeRaster(placer_trap, file.path(proc_dir, "ankobra_placer_trap.tif"),
                       overwrite = TRUE, datatype = "INT1U")

    cat(sprintf("\n=== Channel SPI (upa > %g km²) ===\n", STREAM_KM2))
    cat(sprintf("  Channel cells: %d  |  median channel SPI: %.2f\n",
                length(chan_vals), spi_med))
    cat(sprintf("  Placer-trap cells (channel & SPI ≤ median): %d\n",
                sum(terra::values(placer_trap, na.rm = TRUE) == 1)))

    # Galamsey hexes (Barenblitt artisanal) for overlay — which hex-areas contain galamsey.
    gal_hex <- galamsey_hexes_over(spi, load_galamsey())

    # Diagnostic: full-grid SPI beside the channel-conditional placer-trap mask.
    png(file.path(fig_dir, "ankobra_spi.png"), width = 1800, height = 900, res = 150)
    par(mfrow = c(1, 2), mar = c(1, 1, 3, 4))
    terra::plot(spi, main = "Stream Power Index (ln)",
                col = hcl.colors(50, "viridis"), axes = FALSE, legend = TRUE)
    if (!is.null(gal_hex)) {
      terra::plot(terra::vect(gal_hex), add = TRUE, border = "#FF1493", lwd = 1.2)
      legend("topright", legend = "Galamsey hex", col = "#FF1493", lwd = 1.2, bty = "n", cex = 0.8)
    }
    pt_plot <- placer_trap; pt_plot[pt_plot == 0] <- NA
    terra::plot(pt_plot, main = "Placer traps — low-SPI channel reaches",
                col = "#B2182B", type = "classes", axes = FALSE, legend = FALSE)
    if (!is.null(gal_hex))
      terra::plot(terra::vect(gal_hex), add = TRUE, border = "#FF1493", lwd = 1.2)
    dev.off()
    message("Saved: ankobra_spi.png")
  } else {
    message("Section 10a: no channel cells (upa > ", STREAM_KM2,
            " km²) — skipping placer-trap layer.")
  }

  # -- 10b. Sediment Transport Index (STI) --
  # STI = (m+1) × (SCA / 22.13)^m × (sin(slope) / 0.0896)^n,  with m = 0.6, n = 1.3
  #   (Moore & Burch 1986; Moore et al. 1991). SCA = specific catchment area (m²/m).
  # STI is the sediment-transport-capacity analogue of SPI: derived from unit stream power, it
  # quantifies the flow's capacity to ENTRAIN and carry sediment (vs SPI's total energy). Same
  # placer logic:
  #   high STI = strong transport (erosive / pass-through) — gold keeps moving;
  #   low STI on a channel = transport capacity exhausted → deposition → placer-favourable.
  # Kept as a continuous covariate alongside SPI; the two encode the same physics from different
  # derivations, so the model can use whichever discriminates better (or their contrast). No
  # separate placer mask — SPI's channel-conditional mask (10a) already serves that role.
  # Reuses sca + slope_rad from 10a (same files_ready block).
  m_sti <- 0.6; n_sti <- 1.3
  sti        <- (m_sti + 1) * (sca / 22.13)^m_sti * (sin(slope_rad) / 0.0896)^n_sti
  names(sti) <- "sti"
  terra::writeRaster(sti, file.path(proc_dir, "ankobra_sti.tif"), overwrite = TRUE)

  cat("\n=== STI summary (full grid) ===\n")
  print(terra::global(sti, fun = c("mean", "sd", "min", "max"), na.rm = TRUE))

  # -- 10c. HAND terrace zone raster --
  # If HAND was computed in Section 8, write a 4-class terrace zone raster.
  # Reclassifies HAND into alluvial-gold geomorphic zones for use as a covariate.
  hand_zone_path <- file.path(proc_dir, "ankobra_hand_zones.tif")
  if (file.exists(hand_zone_path))
    cat("\nTerrace zone pixel counts:\n",
        capture.output(print(terra::freq(terra::rast(hand_zone_path)))), sep = "\n")

  # -- 10d. Strahler stream order + confluence proxy --
  # Strahler order flags position in the drainage hierarchy: placers favour intermediate
  # orders (3-5) — headwater reaches (order 1-2) are too erosive; trunk channels (6+) have
  # gold too dispersed. Confluences (where a lower order joins a higher) are classic traps.
  #
  # We pass MERIT Hydro's 'dir' band as the D8 pointer — same ESRI encoding as WBT output.
  # If values look wrong after the first run, verify with: wbt_d8_pointer on elv and compare.
  stream_path   <- file.path(proc_dir, "ankobra_streams.tif")
  dir_path      <- file.path(proc_dir, "ankobra_dir.tif")
  strahler_path <- file.path(proc_dir, "ankobra_strahler.tif")

  if (file.exists(stream_path)) {

    terra::writeRaster(merit_hydro[["dir"]], dir_path, overwrite = TRUE, datatype = "INT2U")

    if (!file.exists(strahler_path)) {
      if (!isTRUE(try(whitebox::check_whitebox_binary(), silent = TRUE)))
        stop("WhiteboxTools not found — run whitebox::install_whitebox() first.")
      message("Computing Strahler stream order (WhiteboxTools)...")
      whitebox::wbt_strahler_stream_order(
        d8_pntr = dir_path,
        streams  = stream_path,
        output   = strahler_path
      )
    }

    strahler <- terra::rast(strahler_path)
    cat("\n=== Strahler order distribution (stream cells only) ===\n")
    print(terra::freq(strahler))
    cat("Peak order (Ankobra trunk expected 5-7):",
        max(terra::values(strahler, na.rm = TRUE)), "\n")

    # Confluence proxy: flag cells where Strahler order increases relative to its upstream
    # neighbours — a step-up in order = a stream junction → energy drop → gold trap.
    # Full implementation via wbt_stream_link_identifier would give cleaner results;
    # the frequency table above is sufficient to assess whether the threshold and order
    # distribution look plausible before investing in the full junction detection.

  } else {
    message("Section 10d: stream mask not found — run Section 8 first.")
  }

}

####11. D8 hex flow graph — full SW Ghana on the d03 5 km grid ####
# Builds a directed hex-to-hex flow graph from MERIT Hydro's D8 'dir' band over the full
# Barenblitt study area (SW Ghana), keyed to the canonical d03 5 km hex grid. An edge
# hex_A -> hex_B means water flows from A into B (A upstream, B downstream).
#
# Replaces a_02_spatial_clustering.R's northing-as-downstream proxy; feeds 2_build/b_04_event_panel.R
# (FLOW_EDGES_PATH = data/processed/merit/hex_flow_edges_5km.csv). Design decisions confirmed
# during the Ankobra test run (earlier version of this script):
#   - CHANNEL-ONLY edges  : only cells with upa > ROUTE_KM2 source edges. ROUTE_KM2 = 10 km²
#                           is DECOUPLED from the 50 km² "river" label (Sec 7-10): off-network
#                           diagnostic showed 50 km² drops 23% of mined ha vs 5.5% at 10 km².
#   - IMMEDIATE neighbours: net directed edges between adjacent hexes only.
#   - NATIVE-GRID tracing  : route on the RAW 4326 dir/upa, NOT the UTM working file.
#                           Reprojecting a D8 pointer corrupts routing — confirmed.

STREAM_KM2 <- 50   # "river" label — must match Sections 7-10  (HEX_KM_TEST set in Sec 1 config)
ROUTE_KM2  <- 10   # flow-graph routing + exposure cut (11g diagnostic: 5.5% mined-ha off-network
                   # at 10 vs 23% at 50). Routing-derived overlays (11f/11h/11i) use ROUTE_KM2 too,
                   # so the red channels match the network that built the graph. NOT arbitrary: a
                   # threshold makes the graph a RIVER network (edges follow channels, which respect
                   # drainage divides); dropping it to 0 routes over ridges/hillslopes and leaks
                   # mining across basins. 11j sweeps ROUTE_KM2 in {2,5,10,20} + reports exposure
                   # robustness (hex_flow_threshold_sweep_5km.csv) — the question is the value, not
                   # whether to filter. Consider lowering toward ~5 km² if 11j shows the cut is immaterial.

if (files_ready) {

  # Read the RAW 4326 download (native MERIT grid) — NOT the UTM working file. Reprojecting 'dir'
  # corrupts routing (see header); routing is pure topology, so no metric CRS is needed.
  hydro_ll <- read_merit(hydro_prefix)
  names(hydro_ll) <- c("dir", "upa", "wth", "elv")

  # Load the canonical d03 5 km hex grid — all outputs must key to these hex_ids.
  d03_cache_path <- here("data", "processed", "hex_5km_crosssection.rds")
  if (!file.exists(d03_cache_path))
    stop("Sec 11: hex_5km_crosssection.rds not found — run a_02_spatial_clustering.R first.")
  hex_sf <- readRDS(d03_cache_path)$hex_sf |>
    dplyr::mutate(hex_num = as.integer(str_extract(hex_id, "\\d+")))
  message(sprintf("Sec 11: d03 hex grid loaded — %d hexes @ 5 km (SW Ghana)", nrow(hex_sf)))

  dir_r <- hydro_ll[["dir"]]
  upa_r <- hydro_ll[["upa"]]

  # -- 11.0 Leaflet preview of the upa-threshold channel network (visual QA + OSM comparison) --
  # Interactive check of the channel masks that source the flow graph, previewed at several upa
  # thresholds (lower = denser network reaching further up the tributaries galamsey targets), over
  # satellite + light basemaps with OSM waterways as a toggleable overlay. Motivation: the upa
  # network is gap-free and reaches small tributaries OSM misses, so it is the better basis for a
  # hex-to-river proximity predictor of galamsey (see 19_06 session log). 50 km² is the *river*
  # threshold (matches Sec 7-10); the 5-20 km² layers show how far the network must extend to catch
  # small alluvial channels. Native 4326 rasters → leaflet-ready, no reprojection.
  thr_km2 <- c(10,50)                               # upstream-area cuts to preview (km²)
  thr_col <- c("#FCBBA1", "#FB6A4A", "#CB181D", "#67000D")  # light→dark red per threshold

  ext_poly_ll <- sf::st_as_sf(terra::as.polygons(terra::ext(upa_r), crs = "EPSG:4326"))
  ww_ll <- sf::st_read(here("data", "raw", "shapefiles", "osm_waterways", "waterways_lines.shp"),
                       quiet = TRUE) |>
    janitor::clean_names() |>
    sf::st_make_valid() |>
    sf::st_transform(4326)
  ww_ll <- suppressWarnings(sf::st_crop(ww_ll, ext_poly_ll))

  chan_grps <- sprintf("MERIT channels (upa > %g km²)", thr_km2)
  m_chan <- leaflet::leaflet() |>
    leaflet::addProviderTiles("Esri.WorldImagery", group = "Satellite") |>
    leaflet::addProviderTiles("CartoDB.Positron",  group = "Light")
  for (i in seq_along(thr_km2)) {                            # nested masks, lighter = lower cut
    mask_i <- terra::ifel(upa_r > thr_km2[i], 1L, NA)
    pal_i  <- leaflet::colorNumeric(thr_col[i], domain = c(0, 1), na.color = "transparent")
    m_chan <- leaflet::addRasterImage(m_chan, mask_i, colors = pal_i, opacity = 0.9,
                                      project = TRUE, maxBytes = 1e7, group = chan_grps[i])
  }
  m_chan <- m_chan |>
    leaflet::addPolylines(data = ww_ll, color = "#1F78B4", weight = 1, opacity = 0.7,
                          group = "OSM waterways") |>
    leaflet::addLayersControl(
      baseGroups    = c("Satellite", "Light"),
      overlayGroups = c(chan_grps, "OSM waterways"),
      options = leaflet::layersControlOptions(collapsed = FALSE)) |>
    leaflet::hideGroup(chan_grps[-length(chan_grps)])        # start with only the 50 km² layer on
  print(m_chan)
  htmlwidgets::saveWidget(m_chan, file.path(fig_dir, "studyarea_channel_network_upa.html"),
                          selfcontained = TRUE)
  message("Saved: studyarea_channel_network_upa.html")

  # -- 11a. Rasterise the d03 hex grid onto the native 4326 MERIT grid --
  # Tag every native MERIT cell with the d03 hex that contains it.
  hex_ll   <- sf::st_transform(hex_sf, 4326)
  hex_id_r <- terra::rasterize(terra::vect(hex_ll), dir_r, field = "hex_num")

  # -- 11b. Per-cell downstream lookup via D8 offsets --
  # Pull to matrices (wide = row-major, row 1 = north; +row = south). ESRI D8 → (drow, dcol):
  #   E=1:(0,+1) SE=2:(+1,+1) S=4:(+1,0) SW=8:(+1,-1) W=16:(0,-1) NW=32:(-1,-1) N=64:(-1,0)
  #   NE=128:(-1,+1).  dir 0 (outlet) / 247 (ocean) have no offset → no downstream cell.
  dir_m <- terra::as.matrix(dir_r,    wide = TRUE)
  upa_m <- terra::as.matrix(upa_r,    wide = TRUE)
  hex_m <- terra::as.matrix(hex_id_r, wide = TRUE)
  nr <- nrow(dir_m); nc <- ncol(dir_m)

  off <- list(`1` = c(0, 1), `2` = c(1, 1), `4` = c(1, 0), `8` = c(1, -1),
              `16` = c(0, -1), `32` = c(-1, -1), `64` = c(-1, 0), `128` = c(-1, 1))

  # Channel cells (source set): upa > threshold and a defined direction.
  chan_idx <- which(upa_m > ROUTE_KM2 & !is.na(dir_m), arr.ind = TRUE)
  rr <- chan_idx[, 1]; cc <- chan_idx[, 2]
  codes <- dir_m[chan_idx]

  drv <- dcv <- rep(NA_integer_, length(codes))
  for (k in names(off)) {
    sel <- codes == as.integer(k)
    drv[sel] <- off[[k]][1]; dcv[sel] <- off[[k]][2]
  }
  r2 <- rr + drv; c2 <- cc + dcv
  in_bounds <- !is.na(drv) & r2 >= 1 & r2 <= nr & c2 >= 1 & c2 <= nc

  from_hex <- hex_m[cbind(rr, cc)]
  to_hex   <- rep(NA_integer_, length(rr))
  to_hex[in_bounds] <- hex_m[cbind(r2[in_bounds], c2[in_bounds])]
  flow_w   <- upa_m[cbind(rr, cc)]   # flow magnitude at the crossing (source-cell upa)

  # -- 11c. Cross-hex edges → aggregate → net dominant direction --
  edge_ok <- in_bounds & !is.na(from_hex) & !is.na(to_hex) & from_hex != to_hex
  edges_agg <- tibble::tibble(from = from_hex[edge_ok], to = to_hex[edge_ok],
                              flow = flow_w[edge_ok]) |>
    dplyr::group_by(from, to) |>
    dplyr::summarise(n_crossings = dplyr::n(), flow_weight = sum(flow), .groups = "drop")

  # Net out bidirectional pairs (D8 noise near boundaries / braids): keep dominant direction,
  # weight = |forward − reverse|.
  edges_net <- edges_agg |>
    dplyr::mutate(a = pmin(from, to), b = pmax(from, to)) |>
    dplyr::group_by(a, b) |>
    dplyr::summarise(
      fwd = sum(flow_weight[from == a]),
      rev = sum(flow_weight[from == b]),
      n_crossings = sum(n_crossings),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      from        = dplyr::if_else(fwd >= rev, a, b),
      to          = dplyr::if_else(fwd >= rev, b, a),
      flow_weight = abs(fwd - rev)
    ) |>
    dplyr::filter(flow_weight > 0) |>
    dplyr::transmute(from_hex = paste0("hex_", from), to_hex = paste0("hex_", to),
                     n_crossings, flow_weight)

  message(sprintf("Flow graph: %d directed hex edges among %d hexes touched by channels",
                  nrow(edges_net), dplyr::n_distinct(c(edges_net$from_hex, edges_net$to_hex))))
  readr::write_csv(edges_net, file.path(proc_dir, "hex_flow_edges_5km.csv"))

  # -- 11d. Downstreamness scalar (method A companion) — mean log(upa) over channel cells --
  downstreamness <- tibble::tibble(hex_num = hex_m[chan_idx], upa = upa_m[chan_idx]) |>
    dplyr::filter(!is.na(hex_num)) |>
    dplyr::group_by(hex_num) |>
    dplyr::summarise(mean_log_upa = mean(log(upa)), n_chan_cells = dplyr::n(), .groups = "drop") |>
    dplyr::mutate(hex_id = paste0("hex_", hex_num))
  readr::write_csv(downstreamness, file.path(proc_dir, "hex_downstreamness_5km.csv"))

  # -- 11e. Validation: cell-level root-cause check, then hex DAG + cycle handling --
  cat("\n=== Flow graph validation ===\n")

  ## Root-cause check. A valid D8 grid is acyclic at the CELL level by construction. Two cases:
  ##   - cell-level CYCLIC  → the Sec 6 reprojection corrupted the pointer grid (reprojecting
  ##                          categorical D8 codes relocates cells, so 'flow SE' no longer lands on
  ##                          the intended neighbour — the known reason not to reproject flow-dir
  ##                          rasters). FIX: trace on the native 4326 grid (raw download), not the
  ##                          UTM working file.
  ##   - cell-level ACYCLIC but hex-level cyclic → benign meander artifacts (a river leaves and
  ##                          re-enters a hex / loops across 3 hexes). FIX: break the few feedback
  ##                          edges below (they carry little flow) — the hex graph is still sound.
  in2  <- in_bounds
  lin  <- (cc - 1) * nr + rr
  lin2 <- rep(NA_integer_, length(lin))
  lin2[in2] <- (c2[in2] - 1) * nr + r2[in2]   # downstream of a channel cell is always a channel cell
  cell_g   <- igraph::graph_from_data_frame(
    data.frame(from = lin[in2], to = lin2[in2]), directed = TRUE)
  cell_dag <- igraph::is_dag(cell_g)
  cat(sprintf("  Cell-level routing acyclic: %s\n", cell_dag))
  if (!cell_dag) {
    kf <- paste(lin[in2], lin2[in2]); kr <- paste(lin2[in2], lin[in2])
    cat(sprintf("    -> reciprocal cell pairs (X<->Y, impossible in valid D8): %d\n",
                sum(kr %in% kf)))
    cat("    -> reprojection corrupted 'dir'; the proper fix is native-grid tracing (see notes).\n")
  } else {
    cat("    -> routing is sound; any hex cycles below are benign meander/aggregation artifacts.\n")
  }

  # Hex graph: break residual cycles (feedback arc set) so we obtain a usable DAG + rank.
  g <- igraph::graph_from_data_frame(
    dplyr::select(edges_net, from_hex, to_hex), directed = TRUE)
  is_dag <- igraph::is_dag(g)
  cat(sprintf("  Hex graph acyclic (raw): %s\n", is_dag))
  if (!is_dag) {
    fas  <- as.integer(igraph::feedback_arc_set(g, algo = "approx_eades"))
    frac <- sum(edges_net$flow_weight[fas]) / sum(edges_net$flow_weight)
    g         <- igraph::delete_edges(g, fas)
    edges_net <- edges_net[-fas, ]
    is_dag    <- igraph::is_dag(g)
    cat(sprintf("  Removed %d feedback edge(s) (%.1f%% of total flow) -> acyclic: %s\n",
                length(fas), 100 * frac, is_dag))
    readr::write_csv(edges_net, file.path(proc_dir, "hex_flow_edges_5km.csv"))  # cleaned
  }

  rank_tbl <- NULL
  if (is_dag) {
    ord_names <- igraph::V(g)$name[igraph::topo_sort(g, mode = "out")]  # upstream first
    rank_tbl  <- tibble::tibble(hex_id = ord_names,
                                downstream_rank = seq_along(ord_names))
    hex_north <- hex_sf |>
      dplyr::mutate(northing = sf::st_coordinates(sf::st_centroid(geometry))[, 2]) |>
      sf::st_drop_geometry() |>
      dplyr::select(hex_id, northing)
    # Validate against northing using the CARDINAL downstreamness scalar (mean log upa, 11d). The
    # topo rank is only a valid *ordering* — arbitrary among hexes not on a shared flow path — so it
    # is noise as a scalar and ~0 vs northing by construction (confirmed: rho≈0.05). mean_log_upa
    # rises monotonically downstream and is the meaningful measure; SW Ghana rivers drain broadly
    # S, so expect a NEGATIVE rho. The rank correlation is kept below only to document the contrast.
    cmp      <- dplyr::left_join(downstreamness, hex_north, by = "hex_id")
    rho      <- cor(cmp$mean_log_upa, cmp$northing, method = "spearman", use = "complete.obs")
    cmp_rank <- dplyr::left_join(rank_tbl, hex_north, by = "hex_id")
    rho_rank <- cor(cmp_rank$downstream_rank, cmp_rank$northing, method = "spearman", use = "complete.obs")
    cat(sprintf("  Spearman(mean_log_upa, northing):    %.3f   <- meaningful downstreamness check\n", rho))
    cat(sprintf("  Spearman(downstream_rank, northing): %.3f   (topo rank = arbitrary ordering, ~0 expected)\n", rho_rank))
    cat("    (negative mean_log_upa rho = more-downstream hexes sit further south, i.e. the northing\n")
    cat("     proxy is broadly right on average; |rho| < ~0.8 quantifies where it reorders.)\n")
  }

  # -- 11f. Diagnostic maps: topological downstream rank (left) vs mean log(upa) downstreamness
  #         (right), both with the MERIT channel (upa > ROUTE_KM2) overlay. The two panels make
  #         the 11e finding visual: the topo rank is patchy/arbitrary, mean_log_upa is a smooth
  #         downstream gradient. --
  if (!is.null(rank_tbl)) {
    hex_plot <- hex_sf |>
      dplyr::left_join(rank_tbl, by = "hex_id") |>
      dplyr::left_join(dplyr::select(downstreamness, hex_id, mean_log_upa), by = "hex_id")

    # MERIT upa-threshold channel network (the routing source) polygonised from the native 4326
    # raster, reprojected to UTM30N + clipped — overlaid in red as a visual check that each
    # downstreamness gradient tracks the channels actually used to build the flow graph.
    chan_v <- terra::ifel(upa_r > ROUTE_KM2, 1L, NA) |>
      terra::as.polygons() |>
      sf::st_as_sf() |>
      sf::st_make_valid() |>
      sf::st_transform(UTM30N)
    chan_v <- suppressWarnings(sf::st_crop(chan_v, sf::st_bbox(hex_sf)))

    make_map <- function(fill_col, legend_name, subtitle) {
      hp <- hex_plot
      hp$fill_val <- hex_plot[[fill_col]]
      ggplot2::ggplot(hp) +
        ggplot2::geom_sf(ggplot2::aes(fill = fill_val), colour = NA) +
        ggplot2::geom_sf(data = chan_v, fill = "red", colour = NA) +
        ggplot2::scale_fill_viridis_c(option = "mako", na.value = "grey92", name = legend_name) +
        ggplot2::labs(subtitle = subtitle) +
        ggplot2::theme_minimal(base_size = 9)
    }

    p_rank <- make_map("downstream_rank", "Downstream\nrank (topo)",
                       "Topological rank — arbitrary among unconnected hexes (~0 vs northing)")
    p_upa  <- make_map("mean_log_upa", "mean log(upa)\n(higher = downstream)",
                       "Mean log(upa) — cardinal downstreamness")
    p <- (p_rank | p_upa) +
      patchwork::plot_annotation(
        title   = "SW Ghana hex flow graph — downstreamness measures (d03 5 km grid)",
        caption = sprintf("D8 routing; grey = no channel; red = MERIT channels (upa > %g km²)",
                          ROUTE_KM2))
    ggplot2::ggsave(file.path(fig_dir, "studyarea_hex_flow_rank.png"), p,
                    width = 15, height = 8, dpi = 150)
    message("Saved: studyarea_hex_flow_rank.png  (2 panels: topo rank | mean_log_upa)")
  }

  # -- 11g. Upstream galamsey exposure per hex (event-study treatment builder) --
  # For each hex, sum the galamsey mining area in all hexes hydrologically UPSTREAM of it (whose
  # water drains through it), from the directed flow graph g. This is the per-hex treatment for
  # the "upstream mining -> downstream impact" event study — built from graph REACHABILITY, never
  # the (arbitrary) topological rank. Columns:
  #   up_mining_ha       : raw sum of upstream galamsey area (ha)
  #   up_mining_ha_decay : distance-decayed sum, weight = exp(-d / DECAY_HOPS) over network hops
  #                        (chemical attenuation / dilution downstream)
  #   own_mining_ha      : galamsey area IN the hex itself — lets the event study separate the
  #                        DIRECT land-clearing effect from the waterborne upstream channel.
  # Reachability/distances run on g (the cleaned DAG from 11e). Mining is attributed only among
  # hexes that are graph vertices (channel-connected) — mining in hexes with no channel edge has
  # no modelled downstream water path and is dropped.
  DECAY_HOPS <- 5   # network-hop decay scale for the weighted exposure (tune in the event study)

  if (is_dag) {
    gal <- load_galamsey()
    if (is.null(gal)) {
      message("11g skipped — galamsey shapefile absent, no mining to attribute.")
    } else {
      # Per-hex galamsey area (ha) on the test grid.
      gal_u <- sf::st_make_valid(sf::st_union(gal))
      mining_by_hex <- suppressWarnings(
        sf::st_intersection(dplyr::select(hex_sf, hex_id), gal_u)) |>
        dplyr::mutate(area_ha = as.numeric(sf::st_area(geometry)) / 1e4) |>
        sf::st_drop_geometry() |>
        dplyr::group_by(hex_id) |>
        dplyr::summarise(mining_ha = sum(area_ha), .groups = "drop")

      # Diagnostic: how much galamsey falls OFF the channel network, by upa threshold? Galamsey
      # sits on small tributaries, so at a high cut many mining hexes touch no channel cell and
      # their mining is dropped as a routing SOURCE (biases downstream exposure toward zero). This
      # sizes the loss at 50/20/10/5 km² to choose a routing cut — see 19_06 session log. Uses the
      # native-grid matrices upa_m/hex_m (11b); a hex is "on-network" if it holds >=1 channel cell.
      gal_ids    <- mining_by_hex$hex_id
      gal_ha_tot <- sum(mining_by_hex$mining_ha)
      cat("\n=== Galamsey off the channel network, by upa threshold (routing-source loss) ===\n")
      for (thr in sort(unique(c(50, 20, 10, 5, ROUTE_KM2)), decreasing = TRUE)) {
        sel        <- which(!is.na(upa_m) & upa_m > thr & !is.na(hex_m))
        on_net_ids <- paste0("hex_", unique(hex_m[sel]))
        off        <- dplyr::filter(mining_by_hex, !(hex_id %in% on_net_ids))
        cat(sprintf("  upa > %2g km²%s: %3d/%3d galamsey hexes OFF-network (%.1f%%) | %.0f/%.0f ha dropped (%.1f%%)\n",
                    thr, if (thr == ROUTE_KM2) " [ROUTE_KM2]" else "           ",
                    nrow(off), length(gal_ids), 100 * nrow(off) / length(gal_ids),
                    sum(off$mining_ha), gal_ha_tot, 100 * sum(off$mining_ha) / gal_ha_tot))
      }

      # Mining vector over graph vertices (0 where no galamsey / non-vertex).
      v_names <- igraph::V(g)$name
      mvec    <- stats::setNames(rep(0, length(v_names)), v_names)
      common  <- intersect(mining_by_hex$hex_id, v_names)
      mvec[common] <- mining_by_hex$mining_ha[match(common, mining_by_hex$hex_id)]

      # For each hex: upstream set via reachability, then raw + distance-decayed mining exposure.
      exposure <- purrr::map_dfr(v_names, function(v) {
        up_v   <- igraph::subcomponent(g, v, mode = "in")          # vertices that reach v (incl v)
        up_ids <- setdiff(igraph::V(g)$name[up_v], v)              # strictly upstream of v
        if (length(up_ids) == 0)
          return(tibble::tibble(hex_id = v, n_upstream = 0L,
                                up_mining_ha = 0, up_mining_ha_decay = 0))
        d <- as.numeric(igraph::distances(g, v = up_ids, to = v, mode = "out"))  # hops upstream->v
        tibble::tibble(
          hex_id             = v,
          n_upstream         = length(up_ids),
          up_mining_ha       = sum(mvec[up_ids]),
          up_mining_ha_decay = sum(mvec[up_ids] * exp(-d / DECAY_HOPS))
        )
      })

      # Attach own-hex mining + downstreamness scalars for the analysis frame.
      exposure <- exposure |>
        dplyr::left_join(dplyr::transmute(mining_by_hex, hex_id, own_mining_ha = mining_ha),
                         by = "hex_id") |>
        dplyr::mutate(own_mining_ha = tidyr::replace_na(own_mining_ha, 0)) |>
        dplyr::left_join(rank_tbl, by = "hex_id") |>
        dplyr::left_join(dplyr::select(downstreamness, hex_id, mean_log_upa), by = "hex_id")

      readr::write_csv(exposure, file.path(proc_dir, "hex_upstream_exposure_5km.csv"))
      cat(sprintf("\n=== Upstream exposure (11g) ===\n  %d graph hexes | %d with any upstream mining | total mined %.0f ha\n",
                  nrow(exposure), sum(exposure$up_mining_ha > 0), sum(mvec)))
      message("Saved: hex_upstream_exposure_5km.csv")

      # -- 11h. Map exposure: galamsey SOURCE vs accumulated UPSTREAM burden (raw + decayed). The
      #         3 panels make the propagation legible — exposure should light up DOWNSTREAM of the
      #         source hexes, along the channels, and be ~0 in disconnected/upstream hexes. --
      exp_sf <- dplyr::left_join(hex_sf, exposure, by = "hex_id")
      chan_v <- terra::ifel(upa_r > ROUTE_KM2, 1L, NA) |>
        terra::as.polygons() |> sf::st_as_sf() |> sf::st_make_valid() |> sf::st_transform(UTM30N)
      chan_v  <- suppressWarnings(sf::st_crop(chan_v, sf::st_bbox(exp_sf)))

      # Mining is extremely right-skewed (a few Ankobra-basin hexes dwarf the rest), so the house
      # sqrt scale still washes out the low-value hexes into the same colour as zero. Use a log10
      # scale over POSITIVE values and render no-mining hexes (0 / NA) as a distinct grey — so
      # "no mining" is visually separable from "a little mining". (Departs from the sqrt convention.)
      exp_map <- function(fill_col, subtitle) {
        hp <- exp_sf; hp$fill_val <- exp_sf[[fill_col]]
        hp$fill_val[!is.na(hp$fill_val) & hp$fill_val <= 0] <- NA   # 0 -> grey, distinct from low+
        ggplot2::ggplot(hp) +
          ggplot2::geom_sf(ggplot2::aes(fill = fill_val), colour = NA) +
          ggplot2::geom_sf(data = chan_v, fill = "white", colour = NA, alpha = 0.5) +
          ggplot2::scale_fill_viridis_c(option = "plasma", trans = "log10", na.value = "grey90",
                                        name = "ha\n(log10)") +
          ggplot2::labs(subtitle = subtitle) +
          ggplot2::theme_minimal(base_size = 9)
      }
      p_exp <- (exp_map("own_mining_ha",      "Galamsey source (own-hex mining)") |
                exp_map("up_mining_ha",       "Upstream exposure — raw (ha draining through)") |
                exp_map("up_mining_ha_decay", "Upstream exposure — distance-decayed")) +
        patchwork::plot_annotation(
          title   = "SW Ghana hexes — galamsey source vs accumulated upstream exposure (d03 5 km grid)",
          caption = sprintf("Mining area draining through each hex via the D8 flow graph; white = MERIT channels (upa > %g km²); log10 fill, grey = no mining.",
                            ROUTE_KM2))
      ggplot2::ggsave(file.path(fig_dir, "studyarea_hex_upstream_exposure.png"), p_exp,
                      width = 18, height = 7, dpi = 150)
      message("Saved: studyarea_hex_upstream_exposure.png  (3 panels: source | raw | decayed)")

      # -- 11i. Interactive leaflet: exposure hexes (full popups) + MERIT channels + directed flow
      #         edges, all toggleable over satellite/light basemaps. Quantile-binned plasma fill so
      #         the Ankobra outliers don't hide low-exposure hexes; no-mining hexes render grey. The
      #         channel network is a RASTER (native 4326); everything else in 4326 (leaflet CRS). --
      exp_ll <- sf::st_transform(exp_sf, 4326)

      # Per-hex popup (full exposure record) + short hover label.
      exp_ll$popup <- sprintf(
        paste0("<b>%s</b><br/>upstream hexes: %s<br/>upstream mining: %.1f ha",
               "<br/>upstream mining (decayed): %.1f ha<br/>own-hex mining: %.1f ha",
               "<br/>downstream rank: %s<br/>mean log(upa): %.2f"),
        exp_ll$hex_id, exp_ll$n_upstream, exp_ll$up_mining_ha, exp_ll$up_mining_ha_decay,
        exp_ll$own_mining_ha, exp_ll$downstream_rank, exp_ll$mean_log_upa)
      exp_ll$lab <- sprintf("%s — %.1f ha upstream", exp_ll$hex_id, exp_ll$up_mining_ha)

      # Quantile-binned plasma so the few very high Ankobra-basin hexes don't crush the rest into
      # one colour; 0 / NA (no upstream mining) are set NA -> grey, so "none" is separable from low.
      qbins <- function(x) {
        xp <- x[x > 0 & is.finite(x)]
        if (length(xp) < 2) return(c(0, 1))
        unique(stats::quantile(xp, probs = seq(0, 1, length.out = 8), na.rm = TRUE))
      }
      raw_v <- exp_ll$up_mining_ha;       raw_v[!is.na(raw_v) & raw_v <= 0] <- NA
      dec_v <- exp_ll$up_mining_ha_decay; dec_v[!is.na(dec_v) & dec_v <= 0] <- NA
      exp_ll$raw_v <- raw_v; exp_ll$dec_v <- dec_v
      pal_raw <- leaflet::colorBin("plasma", domain = raw_v, bins = qbins(exp_ll$up_mining_ha),
                                   na.color = "#BDBDBD")
      pal_dec <- leaflet::colorBin("plasma", domain = dec_v, bins = qbins(exp_ll$up_mining_ha_decay),
                                   na.color = "#BDBDBD")

      # Directed flow edges as upstream->downstream centroid segments (toggleable, hidden default).
      cent_xy <- sf::st_coordinates(
        suppressWarnings(sf::st_centroid(sf::st_transform(hex_sf, 4326)))) |>
        tibble::as_tibble() |> dplyr::mutate(hex_id = hex_sf$hex_id)
      edges_ll <- edges_net |>
        dplyr::left_join(dplyr::rename(cent_xy, x1 = X, y1 = Y), by = c("from_hex" = "hex_id")) |>
        dplyr::left_join(dplyr::rename(cent_xy, x2 = X, y2 = Y), by = c("to_hex"   = "hex_id")) |>
        dplyr::filter(!is.na(x1), !is.na(x2))
      flow_lines <- sf::st_sf(
        geometry = sf::st_sfc(lapply(seq_len(nrow(edges_ll)), function(i)
          sf::st_linestring(rbind(c(edges_ll$x1[i], edges_ll$y1[i]),
                                  c(edges_ll$x2[i], edges_ll$y2[i])))), crs = 4326))

      chan_pal <- leaflet::colorNumeric("#1F78B4", domain = c(0, 1), na.color = "#00000000")
      hl       <- leaflet::highlightOptions(weight = 2, color = "white", bringToFront = TRUE)
      m_exp <- leaflet::leaflet() |>
        leaflet::addProviderTiles("Esri.WorldImagery", group = "Satellite") |>
        leaflet::addProviderTiles("CartoDB.Positron",  group = "Light") |>
        leaflet::addRasterImage(terra::ifel(upa_r > ROUTE_KM2, 1L, NA), colors = chan_pal,
                                opacity = 0.9, project = TRUE, maxBytes = 1e7,
                                group = "MERIT channels") |>
        leaflet::addPolygons(data = exp_ll, fillColor = ~pal_raw(raw_v), fillOpacity = 0.7,
                             weight = 0.5, color = "grey40", popup = ~popup, label = ~lab,
                             highlightOptions = hl, group = "Exposure (raw)") |>
        leaflet::addPolygons(data = exp_ll, fillColor = ~pal_dec(dec_v),
                             fillOpacity = 0.7, weight = 0.5, color = "grey40", popup = ~popup,
                             label = ~lab, highlightOptions = hl, group = "Exposure (decayed)") |>
        leaflet::addPolylines(data = flow_lines, color = "#00E5FF", weight = 1, opacity = 0.6,
                             group = "Flow edges (down)") |>
        leaflet::addLegend(pal = pal_raw, values = raw_v, position = "bottomright",
                           title = "Upstream<br/>mining (ha)", na.label = "none") |>
        leaflet::addLayersControl(
          baseGroups    = c("Satellite", "Light"),
          overlayGroups = c("Exposure (raw)", "Exposure (decayed)", "MERIT channels",
                            "Flow edges (down)"),
          options = leaflet::layersControlOptions(collapsed = FALSE)) |>
        leaflet::hideGroup(c("Exposure (decayed)", "Flow edges (down)"))
      print(m_exp)
      htmlwidgets::saveWidget(m_exp, file.path(fig_dir, "studyarea_hex_exposure_leaflet.html"),
                              selfcontained = TRUE)
      message("Saved: studyarea_hex_exposure_leaflet.html")

      # -- 11j. ROUTE_KM2 sensitivity sweep — does the exposure measure depend on the channel cut? --
      # Rebuilds the flow graph + per-hex upstream exposure at a range of routing thresholds and
      # reports, per cut: edge count, feedback-arc share (DAG noise — rises as low cuts pull in
      # divide-straddling hillslope cells), galamsey mined-ha left OFF the routing network, and total
      # attributed area. Then the cross-threshold Spearman correlation of per-hex up_mining_ha: if the
      # exposure ranking is stable across ~5-20 km², the exact cut is immaterial and ROUTE_KM2 is just
      # a robustness dimension to report. Motivation: a threshold encodes "transport follows channels
      # (which respect drainage divides)", so dropping it to 0 routes over ridges/hillslopes and leaks
      # mining across basins — the question is the VALUE, not whether to filter (see 23_06 notes).
      # Self-contained: reuses the native-grid matrices (dir_m/upa_m/hex_m, off, nr, nc) from 11b and
      # mining_by_hex from 11g. dplyr::/tibble:: qualified throughout (RSAGA attaches plyr here).
      flow_exposure <- function(route_km2) {
        ci    <- which(upa_m > route_km2 & !is.na(dir_m), arr.ind = TRUE)
        r1    <- ci[, 1]; c1 <- ci[, 2]; codes <- dir_m[ci]
        dr <- dc <- rep(NA_integer_, length(codes))
        for (k in names(off)) { s <- codes == as.integer(k); dr[s] <- off[[k]][1]; dc[s] <- off[[k]][2] }
        r2 <- r1 + dr; c2 <- c1 + dc
        ib <- !is.na(dr) & r2 >= 1 & r2 <= nr & c2 >= 1 & c2 <= nc
        fh <- hex_m[cbind(r1, c1)]
        th <- rep(NA_integer_, length(r1)); th[ib] <- hex_m[cbind(r2[ib], c2[ib])]
        fw <- upa_m[cbind(r1, c1)]
        ok <- ib & !is.na(fh) & !is.na(th) & fh != th
        e_net <- tibble::tibble(from = fh[ok], to = th[ok], flow = fw[ok]) |>
          dplyr::group_by(from, to) |>
          dplyr::summarise(flow_weight = sum(flow), .groups = "drop") |>
          dplyr::mutate(a = pmin(from, to), b = pmax(from, to)) |>
          dplyr::group_by(a, b) |>
          dplyr::summarise(fwd = sum(flow_weight[from == a]),
                           rev = sum(flow_weight[from == b]), .groups = "drop") |>
          dplyr::mutate(from = dplyr::if_else(fwd >= rev, a, b),
                        to   = dplyr::if_else(fwd >= rev, b, a),
                        flow_weight = abs(fwd - rev)) |>
          dplyr::filter(flow_weight > 0) |>
          dplyr::transmute(from_hex = paste0("hex_", from), to_hex = paste0("hex_", to), flow_weight)
        gg <- igraph::graph_from_data_frame(dplyr::select(e_net, from_hex, to_hex), directed = TRUE)
        n_edge <- nrow(e_net); n_fas <- 0L; frac_fas <- 0
        if (!igraph::is_dag(gg)) {
          fas      <- as.integer(igraph::feedback_arc_set(gg, algo = "approx_eades"))
          frac_fas <- sum(e_net$flow_weight[fas]) / sum(e_net$flow_weight)
          n_fas    <- length(fas)
          gg       <- igraph::delete_edges(gg, fas)
        }
        vn      <- igraph::V(gg)$name
        mv      <- stats::setNames(rep(0, length(vn)), vn)
        cmn     <- intersect(mining_by_hex$hex_id, vn)
        mv[cmn] <- mining_by_hex$mining_ha[match(cmn, mining_by_hex$hex_id)]
        expo <- purrr::map_dfr(vn, function(v) {
          up <- setdiff(igraph::V(gg)$name[igraph::subcomponent(gg, v, mode = "in")], v)
          tibble::tibble(hex_id = v, up_mining_ha = if (length(up)) sum(mv[up]) else 0)
        })
        sel        <- which(!is.na(upa_m) & upa_m > route_km2 & !is.na(hex_m))
        on_net_ids <- paste0("hex_", unique(hex_m[sel]))
        off_ha     <- sum(mining_by_hex$mining_ha[!(mining_by_hex$hex_id %in% on_net_ids)])
        list(expo = expo, n_edge = n_edge, n_fas = n_fas, frac_fas = frac_fas,
             is_dag = igraph::is_dag(gg), off_ha = off_ha, attributed_ha = sum(mv))
      }

      ROUTE_KM2_SWEEP <- sort(unique(c(2, 5, 10, 20, ROUTE_KM2)))
      sweep_res  <- lapply(ROUTE_KM2_SWEEP, flow_exposure)
      gal_ha_tot <- sum(mining_by_hex$mining_ha)

      robust_tbl <- tibble::tibble(
        route_km2               = ROUTE_KM2_SWEEP,
        n_edges                 = vapply(sweep_res, `[[`, integer(1), "n_edge"),
        n_feedback_edges        = vapply(sweep_res, `[[`, integer(1), "n_fas"),
        pct_flow_in_feedback    = round(100 * vapply(sweep_res, `[[`, numeric(1), "frac_fas"), 2),
        pct_mined_ha_offnetwork = round(100 * vapply(sweep_res, `[[`, numeric(1), "off_ha") / gal_ha_tot, 1),
        total_attributed_ha     = round(vapply(sweep_res, `[[`, numeric(1), "attributed_ha"))
      )
      readr::write_csv(robust_tbl, file.path(proc_dir, "hex_flow_threshold_sweep_5km.csv"))
      cat("\n=== ROUTE_KM2 sensitivity sweep (11j) ===\n")
      print(robust_tbl, n = Inf)
      message("Saved: hex_flow_threshold_sweep_5km.csv")

      # Cross-threshold agreement of the per-hex treatment (up_mining_ha). Non-vertex hexes at a given
      # cut carry no upstream mining -> 0; Spearman is skew-robust. High off-diagonals = the exposure
      # ranking barely moves with the cut, so the headline ROUTE_KM2 choice is not driving results.
      exp_wide <- purrr::reduce(
        seq_along(ROUTE_KM2_SWEEP),
        function(acc, i) {
          col <- paste0("up_", ROUTE_KM2_SWEEP[i], "km")
          e   <- dplyr::transmute(sweep_res[[i]]$expo, hex_id, !!col := up_mining_ha)
          if (is.null(acc)) e else dplyr::full_join(acc, e, by = "hex_id")
        }, .init = NULL)
      exp_wide <- dplyr::mutate(exp_wide, dplyr::across(-hex_id, ~tidyr::replace_na(.x, 0)))
      cor_mat  <- cor(dplyr::select(exp_wide, -hex_id), method = "spearman")
      cat("\nSpearman correlation of per-hex up_mining_ha across ROUTE_KM2 cuts:\n")
      print(round(cor_mat, 3))
      cat(sprintf("  Headline cut = %g km². Stable off-diagonals across 5-20 => the cut is immaterial.\n",
                  ROUTE_KM2))
    }
  }

}

message("\n=== d_04_merit.R complete ===")
message("  Outputs:  ", proc_dir)
message("  Figures:  ", fig_dir)
message("  Next:     extend Sec 11 flow graph + 11g upstream-exposure to all-Ghana + swap into",
        " d03 make_dir_nb; feed hex_upstream_exposure_5km.csv into the up/down NDVI event study")
