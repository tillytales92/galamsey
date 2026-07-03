# b_03a_vi_panel.R
# Extract annual NDVI / EVI zonal means per hex per year from Landsat and MODIS rasters.
# Part 1 of 4 in the modular event-panel build (see b_03b/c/d for other components).
#
# Outputs: data/processed/hex_{N}km_vi_panel.rds
#   tibble(hex_id, year, ndvi_landsat, evi_landsat, ndvi_modis, evi_modis,
#          ndvi_landsat_forestcrop, evi_landsat_forestcrop,
#          ndvi_modis_forestcrop,   evi_modis_forestcrop,
#          ndvi_landsat_nominecrop, evi_landsat_nominecrop,
#          ndvi_modis_nominecrop,   evi_modis_nominecrop)
#
# Re-run only when raster stacks change (new GEE download) or resolution changes.
# Prerequisites: hex_{N}km_crosssection.rds from b_01_cross_section.R

RESOLUTIONS <- c(1, 2, 5)

pacman::p_load(sf, terra, janitor, tidyverse, conflicted, here)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)
UTM30N <- 32630

ndvi_stack_path       <- here("data", "raw", "landsat_vi", "landsat_ndvi_ghana_stack.tif")
evi_stack_path        <- here("data", "raw", "landsat_vi", "landsat_evi_ghana_stack.tif")
modis_ndvi_stack_path <- here("data", "raw", "modis_vi",   "modis_ndvi_ghana_stack.tif")
modis_evi_stack_path  <- here("data", "raw", "modis_vi",   "modis_evi_ghana_stack.tif")
lc_stack_path         <- here("data", "raw", "land_cover", "modis_lc_ghana_stack.tif")
barenblitt_ts         <- here("data", "raw", "barenblitt", "MiningConversion_2007-2017Vec.shp")
barenblitt_2019       <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")

stopifnot(file.exists(ndvi_stack_path), file.exists(barenblitt_ts), file.exists(barenblitt_2019))

# Check which resolution caches exist
have_res <- RESOLUTIONS[file.exists(
  here("data", "processed", sprintf("hex_%dkm_crosssection.rds", RESOLUTIONS))
)]
if (!length(have_res)) stop("No crosssection cache found. Run b_01_cross_section.R first.")
message(sprintf("Resolutions with caches: %s km", paste(have_res, collapse = ", ")))

####1. Load shared assets (once for all resolutions) ####

message("\nLoading Barenblitt data for no-mine mask...")
mine_ts <- st_read(barenblitt_ts, quiet = TRUE) |>
  clean_names() |> st_make_valid() |> st_transform(UTM30N) |>
  mutate(year = 2000L + as.integer(trimws(classifica)))
mine_2019_sf <- st_read(barenblitt_2019, quiet = TRUE) |>
  clean_names() |> st_make_valid() |> st_transform(UTM30N)

message("Pre-computing cumulative mining polygons (2007-2017)...")
mine_vect_cum <- setNames(
  lapply(2007:2017, \(yr)
    terra::vect(st_transform(st_union(dplyr::filter(mine_ts, year <= yr)), 4326))),
  as.character(2007:2017)
)
mine_vect_2019 <- terra::vect(st_transform(st_union(mine_2019_sf), 4326))

get_mine_mask <- function(yr, template) {
  if (yr < 2007L) return(NULL)
  v <- if (yr <= 2017L) mine_vect_cum[[as.character(yr)]] else mine_vect_2019
  terra::rasterize(v, template)
}

# Study extent from first available cache (same for all resolutions)
ref_cache    <- readRDS(here("data", "processed",
                             sprintf("hex_%dkm_crosssection.rds", have_res[1])))
ref_hex_4326 <- st_transform(ref_cache$hex_sf, 4326)
study_ext    <- terra::ext(terra::vect(ref_hex_4326))
rm(ref_cache, ref_hex_4326)

message("\nLoading and cropping raster stacks...")
ndvi_r <- terra::crop(terra::rast(ndvi_stack_path), study_ext)
message(sprintf("  Landsat NDVI: %d layers (%s)", terra::nlyr(ndvi_r),
                paste(range(as.integer(str_extract(names(ndvi_r), "\\d{4}"))), collapse = "-")))

evi_r <- if (file.exists(evi_stack_path)) {
  message("  Loading Landsat EVI...")
  terra::crop(terra::rast(evi_stack_path), study_ext)
} else { message("  Landsat EVI absent — skipped."); NULL }

modis_ndvi_r <- if (file.exists(modis_ndvi_stack_path)) {
  message("  Loading MODIS NDVI...")
  terra::crop(terra::rast(modis_ndvi_stack_path), study_ext)
} else NULL

modis_evi_r <- if (file.exists(modis_evi_stack_path)) {
  message("  Loading MODIS EVI...")
  terra::crop(terra::rast(modis_evi_stack_path), study_ext)
} else NULL

lc_landsat_r <- NULL; lc_modis_r <- NULL
if (file.exists(lc_stack_path)) {
  lc_raw  <- terra::crop(terra::rast(lc_stack_path), study_ext)
  lc_yrs  <- as.integer(str_extract(names(lc_raw), "\\d{4}"))
  message(sprintf("  Land cover: %d layers (%d-%d). Resampling to VI grids...",
                  terra::nlyr(lc_raw), min(lc_yrs), max(lc_yrs)))
  lc_landsat_r <- terra::resample(lc_raw, ndvi_r[[1]], method = "near")
  if (!is.null(modis_ndvi_r) || !is.null(modis_evi_r)) {
    lc_modis_r <- terra::resample(lc_raw, (if (!is.null(modis_ndvi_r)) modis_ndvi_r else modis_evi_r)[[1]],
                                  method = "near")
  }
  rm(lc_raw)
} else {
  message("  modis_lc_ghana_stack.tif absent — forestcrop columns omitted.")
}

####2. Helper functions ####

extract_annual_r <- function(r_crop, var, hex_vect, hex_ids) {
  terra::extract(r_crop, hex_vect, fun = mean, na.rm = TRUE, ID = FALSE) |>
    mutate(hex_id = hex_ids) |>
    pivot_longer(-hex_id, names_to = "layer", values_to = var) |>
    mutate(year = as.integer(str_extract(layer, "\\d{4}"))) |>
    dplyr::filter(!is.na(year)) |>
    dplyr::select(hex_id, year, all_of(var))
}

extract_forestcrop_r <- function(r_crop, lc_res, var, hex_vect, hex_ids, lc_class = 2L) {
  vi_years <- as.integer(str_extract(names(r_crop), "\\d{4}"))
  lc_years <- as.integer(str_extract(names(lc_res), "\\d{4}"))
  common   <- sort(base::intersect(vi_years, lc_years))
  if (!length(common)) { message(sprintf("  No year overlap for %s — skipped.", var)); return(NULL) }
  message(sprintf("  Extracting %s (IGBP class %d) for %d years (%d-%d)...",
                  var, lc_class, length(common), min(common), max(common)))
  map_dfr(common, \(yr) {
    vi_masked <- terra::mask(r_crop[[which(vi_years == yr)]],
                             terra::ifel(lc_res[[which(lc_years == yr)]] == lc_class, 1, NA))
    tibble(hex_id = hex_ids, year = yr,
           !!var := terra::extract(vi_masked, hex_vect, fun = mean, na.rm = TRUE, ID = FALSE)[[1]])
  })
}

extract_nominecrop_r <- function(r_crop, var, hex_vect, hex_ids) {
  vi_years <- as.integer(str_extract(names(r_crop), "\\d{4}"))
  message(sprintf("  Extracting %s (no-mine mask) for %d years (%d-%d)...",
                  var, length(vi_years), min(vi_years), max(vi_years)))
  map_dfr(vi_years, \(yr) {
    vi_lyr    <- r_crop[[which(vi_years == yr)]]
    mine_mask <- get_mine_mask(yr, vi_lyr)
    vi_masked <- if (is.null(mine_mask)) vi_lyr else terra::mask(vi_lyr, mine_mask, inverse = TRUE)
    tibble(hex_id = hex_ids, year = yr,
           !!var := terra::extract(vi_masked, hex_vect, fun = mean, na.rm = TRUE, ID = FALSE)[[1]])
  })
}

####3. Per-resolution loop ####

for (res_km in have_res) {
  out_path <- here("data", "processed", sprintf("hex_%dkm_vi_panel.rds", res_km))
  message(sprintf("\n%s\n=== VI extraction: %d km ===\n%s",
                  strrep("=", 55), res_km, strrep("=", 55)))

  cache_r    <- readRDS(here("data", "processed", sprintf("hex_%dkm_crosssection.rds", res_km)))
  hex_sf_r   <- cache_r$hex_sf
  hex_vect_r <- terra::vect(st_transform(hex_sf_r, 4326))
  hex_ids_r  <- hex_sf_r$hex_id
  message(sprintf("  Hex grid: %d hexes", nrow(hex_sf_r)))
  rm(cache_r)

  # Overall VI
  message("  Extracting Landsat NDVI (overall)...")
  vi_r <- extract_annual_r(ndvi_r, "ndvi_landsat", hex_vect_r, hex_ids_r)

  for (cfg in list(
    list(r = evi_r,        var = "evi_landsat", msg = "Landsat EVI (overall)"),
    list(r = modis_ndvi_r, var = "ndvi_modis",  msg = "MODIS NDVI (overall)"),
    list(r = modis_evi_r,  var = "evi_modis",   msg = "MODIS EVI (overall)")
  )) {
    if (is.null(cfg$r)) next
    message(sprintf("  Extracting %s...", cfg$msg))
    vi_r <- full_join(vi_r, extract_annual_r(cfg$r, cfg$var, hex_vect_r, hex_ids_r),
                      by = c("hex_id", "year"))
  }

  # Forest-crop VI
  if (!is.null(lc_landsat_r)) {
    for (cfg in list(
      list(r = ndvi_r,       lc = lc_landsat_r, var = "ndvi_landsat_forestcrop"),
      list(r = evi_r,        lc = lc_landsat_r, var = "evi_landsat_forestcrop"),
      list(r = modis_ndvi_r, lc = lc_modis_r,   var = "ndvi_modis_forestcrop"),
      list(r = modis_evi_r,  lc = lc_modis_r,   var = "evi_modis_forestcrop")
    )) {
      if (is.null(cfg$r) || is.null(cfg$lc)) next
      tmp <- extract_forestcrop_r(cfg$r, cfg$lc, cfg$var, hex_vect_r, hex_ids_r)
      if (!is.null(tmp)) vi_r <- left_join(vi_r, tmp, by = c("hex_id", "year"))
    }
  }

  # No-mine VI
  for (cfg in list(
    list(r = ndvi_r,       var = "ndvi_landsat_nominecrop"),
    list(r = evi_r,        var = "evi_landsat_nominecrop"),
    list(r = modis_ndvi_r, var = "ndvi_modis_nominecrop"),
    list(r = modis_evi_r,  var = "evi_modis_nominecrop")
  )) {
    if (is.null(cfg$r)) next
    tmp <- extract_nominecrop_r(cfg$r, cfg$var, hex_vect_r, hex_ids_r)
    vi_r <- left_join(vi_r, tmp, by = c("hex_id", "year"))
  }

  vi_cols_r <- base::setdiff(names(vi_r), c("hex_id", "year"))
  message(sprintf("  VI years: %d-%d (%d years) | %d columns",
                  min(vi_r$year), max(vi_r$year), n_distinct(vi_r$year), length(vi_cols_r)))

  saveRDS(vi_r, out_path)
  message(sprintf("Saved: %s", out_path))

  rm(cache_r, hex_sf_r, hex_vect_r, hex_ids_r, vi_r)
  suppressWarnings(rm(cfg, tmp))
  gc()
}

message("\n=== b_03a_vi_panel.R complete ===")
