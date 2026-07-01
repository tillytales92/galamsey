# d_02_elevation.R
# Download elevation (DEM) for Ghana and derive slope rasters. Pure terrain-layer builder
# only — per-hex extraction (elev_mean / slope_mean) is done in 2_build/b_02_hex_frame.R,
# which reads these rasters and writes the results into the cache RDS.
#
# NOTE: the valley-bottom / floodplain hydro-geomorphic indices (MRVBF, HAND, flow
# direction, sinks, etc.) have been moved to code/0_data/d_06_gold_deposits.R — see the plan
# in code/0_data/gold_deposits.md. This script is deliberately the *basic* terrain layer only.
#
# Source: elevatr -> AWS Terrain Tiles (Mapzen/Tilezen).
#   https://github.com/tilezen/joerd/blob/master/docs/data-sources.md
#
# Coverage note: the d03 hex grid is the convex hull of the Barenblitt SW-Ghana
# mining extent, so some hexes straddle the coastline / Cote d'Ivoire border and
# spill past the national outline. Clipping the DEM to the raw country polygon left
# those hexes with no cells underneath (NaN -> dropped downstream). We therefore
# download against a BUFFER_KM-buffered boundary so every hex sits fully inside DEM
# coverage. AWS terrain tiles include offshore bathymetry, so coastal buffer cells
# carry small negative "elevation" values (sea bed) — see the clamp note in Sec. 2.
#
# Outputs (filenames carry Z and the buffer so a changed buffer re-downloads cleanly):
#   data/raw/elevation/ghana_dem_z{Z}_buf{BUFFER_KM}km.tif               — raw DEM (EPSG:4326)
#   data/processed/elevation/ghana_elevation_utm30n_buf{BUFFER_KM}km.tif — DEM (EPSG:32630)
#   data/processed/elevation/ghana_slope_utm30n_buf{BUFFER_KM}km.tif     — slope deg (EPSG:32630)
#
# Per-hex extraction (elev_mean / slope_mean) happens in 2_build/b_02_hex_frame.R, which reads
# these rasters and stores terrain columns directly in hex_{N}km_crosssection.rds.
# Run this script first, then source b_02_hex_frame.R.

####0. Setup ####
pacman::p_load(here, elevatr, terra, sf, janitor, tidyverse, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)
UTM30N <- 32630

# Zoom level controls DEM resolution. At Ghana's latitude (~5-11 N):
#   z = 9 ~ 305 m | z = 10 ~ 152 m | z = 11 ~ 76 m
# Ghana is small enough that the finest tier (z11, ~76 m) is cheap (~270 MB raw), so we
# always use it — ample for 5 km and 1 km hex means alike, and reusable for the all-Ghana
# RS phase. Pinned here rather than derived from HEX_RES_KM to keep one DEM for everything.
Z <- 11L

# Buffer (km) added around the country outline before downloading, so 5 km hexes
# that straddle the coast/border get full DEM coverage. 10 km comfortably exceeds a
# hex half-width (2.5 km) plus typical convex-hull overshoot. Bump it if Section 4's
# completeness check still trips.
BUFFER_KM <- 10

admin0_path <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp")

raw_dir  <- here("data", "raw", "elevation")
proc_dir <- here("data", "processed", "elevation")
dir.create(raw_dir,  recursive = TRUE, showWarnings = FALSE)
dir.create(proc_dir, recursive = TRUE, showWarnings = FALSE)

####1. Study boundary (+ buffer) ####
# elevatr reprojects internally, but feed it an EPSG:4326 polygon. Buffer in the
# metric CRS (UTM30N) so BUFFER_KM is true kilometres, then transform back to 4326.
ghana_sf <- st_read(admin0_path) |>
  clean_names() |>
  st_make_valid() |>
  st_transform(4326)

ghana_buf <- ghana_sf |>
  st_transform(UTM30N) |>
  st_buffer(BUFFER_KM * 1000) |>
  st_transform(4326)

plot(st_geometry(ghana_buf), main = paste0("DEM download extent (Ghana +", BUFFER_KM, " km)"))
plot(st_geometry(ghana_sf), add = TRUE, border = "grey40")

####2. Download DEM (skip if already on disk) ####
# clip = "locations" masks the raster to the (buffered) outline; cells outside -> NA.
# The download is the slow step, so reuse the cached raw DEM for this Z + buffer if it
# exists. Changing Z or BUFFER_KM changes the filename, which forces a fresh download.
raster_dem_path <- file.path(raw_dir, sprintf("ghana_dem_z%d_buf%dkm.tif", Z, BUFFER_KM))

if (file.exists(raster_dem_path)) {
  message("Found cached DEM, skipping download: ", raster_dem_path)
  dem_ll <- terra::rast(raster_dem_path)
} else {
  message("Downloading DEM for Ghana +", BUFFER_KM, " km at z = ", Z,
          " (may take a few minutes)...")
  dem_ll <- get_elev_raster(
    locations          = ghana_buf,
    z                  = Z,
    clip               = "locations",
    override_size_check = TRUE,
    verbose            = TRUE
  ) |> terra::rast()            # RasterLayer -> SpatRaster
  terra::writeRaster(dem_ll, raster_dem_path, overwrite = TRUE)
  message("Saved: ", raster_dem_path)
}
names(dem_ll) <- "elevation"

# Offshore terrain tiles carry bathymetry (negative values). Clamp sub-sea cells to 0
# so a coastal hex's mean elevation reads as near-sea-level land rather than sea bed;
# slope is unaffected (a flat sea is ~0 deg either way). Comment this out if you want
# raw bathymetry preserved for another use.
dem_ll <- terra::clamp(dem_ll, lower = 0, values = TRUE)

####3. Reproject + derive slope (skip if already on disk) ####
# Slope must be computed on a metric grid so horizontal and vertical units agree,
# so project to UTM30N first (the project's standard metric CRS), then run terrain().
# Reuse the processed rasters if both already exist (cheap to re-load, costly to recompute).
elev_utm_path  <- file.path(proc_dir, sprintf("ghana_elevation_utm30n_buf%dkm.tif", BUFFER_KM))
slope_utm_path <- file.path(proc_dir, sprintf("ghana_slope_utm30n_buf%dkm.tif", BUFFER_KM))

if (file.exists(elev_utm_path) && file.exists(slope_utm_path)) {
  message("Found cached UTM30N elevation + slope, skipping reprojection.")
  dem_utm   <- terra::rast(elev_utm_path)
  slope_utm <- terra::rast(slope_utm_path)
} else {
  dem_utm   <- terra::project(dem_ll, paste0("EPSG:", UTM30N))
  slope_utm <- terra::terrain(dem_utm, v = "slope", unit = "degrees", neighbors = 8)
  names(slope_utm) <- "slope"

  terra::writeRaster(dem_utm,   elev_utm_path,  overwrite = TRUE)
  terra::writeRaster(slope_utm, slope_utm_path, overwrite = TRUE)
  message("Saved reprojected DEM + slope (EPSG:", UTM30N, ") to ", proc_dir)
}

####4. Visualise + save elevation and slope maps ####
# Objects are in memory if run top-to-bottom; load from disk for standalone execution.
if (!exists("dem_utm"))   dem_utm   <- terra::rast(elev_utm_path)
if (!exists("slope_utm")) slope_utm <- terra::rast(slope_utm_path)

dir.create(here("outputs", "figures", "maps"), recursive = TRUE, showWarnings = FALSE)

png(here("outputs", "figures", "maps", "elevation_utm30n.png"),
    width = 600, height = 800, res = 100)
terra::plot(dem_utm,   main = "Elevation (m) — UTM30N",
            col = hcl.colors(64, "Terrain2"))
dev.off()

png(here("outputs", "figures", "maps", "slope_utm30n.png"),
    width = 600, height = 800, res = 100)
terra::plot(slope_utm, main = "Slope (degrees) — UTM30N",
            col = hcl.colors(64, "YlOrRd"))
dev.off()

message("Elevation and slope maps saved to outputs/figures/maps/")

message("\n=== d_02_elevation.R complete ===")
message("Next: source 2_build/b_02_hex_frame.R to extract elev/slope per hex into the cache RDS.")
