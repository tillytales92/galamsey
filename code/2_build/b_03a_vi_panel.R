# b_03a_vi_panel.R
# Peak-EVI / peak-NDVI zonal extraction per hex per year (Vashold et al. 2026 methodology).
# Part 1 of 4 in the modular event-panel build (see b_03b/c/d/e for the other components).
#
# PIPELINE (per index x mask x year):
#   1. Source: MODIS MOD13Q1 16-day composites, 250 m, QA-masked server-side
#      (data/raw/modis_vi/modis_{ndvi,evi}_16day_ghana_{yr}.tif, ~23 bands/yr).
#   2. Mask each 16-day composite with that year's ESA CCI land cover (300 m -> resampled to the
#      250 m VI grid) for the four vegetation masks; with the Barenblitt mine extent for nominecrop;
#      unmasked for overall.
#   3. Spatial reduction FIRST: per-hex zonal MEAN at each 16-day step (a ~23-value series per hex).
#   4. Temporal reduction SECOND: take BOTH the annual MEAN and the annual MAX ("peak") of that
#      per-hex 16-day series. Order matters — spatial mean per period, then annual max/mean.
#
# Outputs: data/processed/hex_{N}km_vi_panel.rds  — tibble(hex_id, year, <24 VI cols>, urban_share):
#   {index}_modis[_{mask}]_{stat}  for index in {ndvi, evi}, stat in {mean, max},
#   mask in {overall (no suffix), nominecrop, cropland, forest, veg_narrow, veg_broad}.
#   Values are in the native VI range [-0.2, 1.0] (16-day rasters are already GEE-scaled floats).
#   urban_share = fraction of a hex's classified ESA CCI pixels that are urban (class 190), per year.
#
# Re-run only when the 16-day rasters, the CCI stack, or the hex grids change. COMPUTE-HEAVY
# (~26 yr x ~23 periods x 2 indices x 6 masks x 3 resolutions of masked zonal extraction).
# Prerequisites: hex_{N}km_crosssection.rds (b_01_cross_section.R).

RESOLUTIONS <- c(5, 2, 1)   # smallest grid (fewest hexes) first — fails fast, cheapest to test

pacman::p_load(sf, terra, janitor, tidyverse, conflicted, here)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)
UTM30N <- 32630
# NOTE: the exported 16-day rasters are already scaled floats in the native VI range [-0.2, 1.0]
# (datatype FLT8S — the 0.0001 MOD13Q1 factor was applied at GEE-export time), so NO rescaling here.

# ---- Land-cover mask definitions (ESA CCI / UN-LCCS class codes) --------------------------------
# See the CCI legend in d_05_ndvi.R. The four masks nest: cropland U forest = veg_narrow c veg_broad.
#   cropland   : rainfed + irrigated cropland + cropland-dominant mosaic (30); excludes 40 (nature-dom.)
#   forest     : all tree-cover classes (broadleaf evergreen/deciduous, needleleaf evergreen, mixed)
#   veg_narrow : the "productive green" — dense cropland + tree cover only
#   veg_broad  : any vegetated land — adds veg mosaics, shrubland, grassland, sparse & flooded veg;
#                excludes urban (190), bare (200/201/202), water (210), snow (220), lichen/moss (140)
CCI_MASKS <- list(
  cropland   = c(10L, 11L, 12L, 20L, 30L),
  forest     = c(50L, 60L, 61L, 62L, 70L, 90L),
  veg_narrow = c(10L, 11L, 12L, 20L, 30L,  50L, 60L, 61L, 62L, 70L, 90L),
  veg_broad  = c(10L, 11L, 12L, 20L, 30L, 40L,
                 50L, 60L, 61L, 62L, 70L, 90L,
                 100L, 110L, 120L, 121L, 122L, 130L, 150L, 160L, 170L, 180L)
)
MASK_ORDER <- c("overall", "nominecrop", names(CCI_MASKS))   # order of VI columns in the output

# ---- Paths ---------------------------------------------------------------------------------------
modis_dir       <- here("data", "raw", "modis_vi")
cci_stack_path  <- here("data", "raw", "land_cover", "esa", "cci_landcover_ghana_stack.tif")
barenblitt_ts   <- here("data", "raw", "barenblitt", "MiningConversion_2007-2017Vec.shp")
barenblitt_2019 <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")

stopifnot(dir.exists(modis_dir), file.exists(cci_stack_path),
          file.exists(barenblitt_ts), file.exists(barenblitt_2019))

# 16-day file per year, for years present for BOTH indices
avail_years <- function(prefix) sort(as.integer(str_extract(
  list.files(modis_dir, pattern = sprintf("^%s_16day_ghana_\\d{4}\\.tif$", prefix)), "\\d{4}")))
VI_YEARS <- base::intersect(avail_years("modis_ndvi"), avail_years("modis_evi"))
if (!length(VI_YEARS)) stop("No modis_{ndvi,evi}_16day_ghana_{yr}.tif files found in ", modis_dir)
vi_file <- function(index, yr) file.path(modis_dir, sprintf("modis_%s_16day_ghana_%d.tif", index, yr))
message(sprintf("MODIS 16-day series: %d-%d (%d years), indices ndvi + evi",
                min(VI_YEARS), max(VI_YEARS), length(VI_YEARS)))

# Resolutions with a crosssection cache
have_res <- RESOLUTIONS[file.exists(
  here("data", "processed", sprintf("hex_%dkm_crosssection.rds", RESOLUTIONS)))]
if (!length(have_res)) stop("No crosssection cache found. Run b_01_cross_section.R first.")
message(sprintf("Resolutions with caches: %s km", paste(have_res, collapse = ", ")))

####1. Shared assets — study extent, MODIS template, CCI resampled, mine masks ####

# Study extent from the first available cache (identical across resolutions)
ref_cache    <- readRDS(here("data", "processed",
                             sprintf("hex_%dkm_crosssection.rds", have_res[1])))
ref_hex_4326 <- st_transform(ref_cache$hex_sf, 4326)
study_ext    <- terra::ext(terra::vect(ref_hex_4326))
rm(ref_cache, ref_hex_4326)

# MODIS 250 m grid template (both indices share the MOD13Q1 grid) cropped to the study area
modis_template <- terra::crop(terra::rast(vi_file("ndvi", VI_YEARS[1]))[[1]], study_ext)

# ESA CCI stack -> resampled once onto the MODIS VI grid (nearest, categorical)
message("Resampling ESA CCI land cover onto the MODIS VI grid...")
cci_raw   <- terra::crop(terra::rast(cci_stack_path), study_ext)
CCI_YEARS <- as.integer(str_extract(names(cci_raw), "\\d{4}"))
cci_res   <- terra::resample(cci_raw, modis_template, method = "near")
rm(cci_raw)
message(sprintf("  CCI: %d layers (%d-%d). VI years outside this span clamp to the nearest CCI year.",
                terra::nlyr(cci_res), min(CCI_YEARS), max(CCI_YEARS)))

# Barenblitt cumulative mining polygons for the nominecrop mask
message("Loading Barenblitt data for the no-mine mask...")
mine_ts <- st_read(barenblitt_ts, quiet = TRUE) |>
  clean_names() |> st_make_valid() |> st_transform(UTM30N) |>
  mutate(year = 2000L + as.integer(trimws(classifica)))
mine_2019_sf <- st_read(barenblitt_2019, quiet = TRUE) |>
  clean_names() |> st_make_valid() |> st_transform(UTM30N)
mine_vect_cum <- setNames(
  lapply(2007:2017, \(yr)
    terra::vect(st_transform(st_union(dplyr::filter(mine_ts, year <= yr)), 4326))),
  as.character(2007:2017))
mine_vect_2019 <- terra::vect(st_transform(st_union(mine_2019_sf), 4326))

get_mine_mask <- function(yr, template) {
  if (yr < 2007L) return(NULL)                                    # no mine data before 2007
  v <- if (yr <= 2017L) mine_vect_cum[[as.character(yr)]] else mine_vect_2019
  terra::rasterize(v, template)
}

####2. Masking + peak-reduction helpers ####

# Mask one year's 16-day VI stack to the pixels relevant for `mask_key`.
mask_vi_year <- function(vi_16, mask_key, yr) {
  if (mask_key == "overall") return(vi_16)
  if (mask_key == "nominecrop") {
    mm <- get_mine_mask(yr, vi_16[[1]])
    return(if (is.null(mm)) vi_16 else terra::mask(vi_16, mm, inverse = TRUE))
  }
  classes <- CCI_MASKS[[mask_key]]
  cci_yr  <- min(max(yr, min(CCI_YEARS)), max(CCI_YEARS))         # clamp to CCI coverage
  keep    <- terra::ifel(cci_res[[which(CCI_YEARS == cci_yr)]] %in% classes, 1L, NA)
  terra::mask(vi_16, keep)
}

# Spatial-then-temporal reduction: per-hex zonal mean at each 16-day step, then annual mean & max.
reduce_peak <- function(vi_16, hex_vect) {
  m <- as.matrix(terra::extract(vi_16, hex_vect, fun = mean, na.rm = TRUE, ID = FALSE))  # hex x periods
  m[is.nan(m)] <- NA
  ann_mean <- rowMeans(m, na.rm = TRUE); ann_mean[is.nan(ann_mean)] <- NA   # already in [-0.2, 1.0]
  ann_max  <- apply(m, 1, \(x) { x <- x[!is.na(x)]; if (length(x)) max(x) else NA_real_ })
  list(mean = ann_mean, max = ann_max)
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
  message(sprintf("  Hex grid: %d hexes | %d indices x %d masks x %d years",
                  nrow(hex_sf_r), 2L, length(MASK_ORDER), length(VI_YEARS)))
  rm(cache_r)

  long <- vector("list", 0L)
  for (index in c("ndvi", "evi")) {
    for (yr in VI_YEARS) {
      vi_16 <- terra::crop(terra::rast(vi_file(index, yr)), study_ext)   # ~23 bands, read once/year
      for (mask_key in MASK_ORDER) {
        red <- reduce_peak(mask_vi_year(vi_16, mask_key, yr), hex_vect_r)
        long[[length(long) + 1L]] <- tibble(
          hex_id = hex_ids_r, year = yr, index = index, mask = mask_key,
          mean = red$mean, max = red$max)
      }
      message(sprintf("    %s %d done", toupper(index), yr))
    }
  }

  # Long -> wide: column name {index}_modis[_{mask}]_{stat} (overall has no mask suffix)
  vi_r <- bind_rows(long) |>
    pivot_longer(c(mean, max), names_to = "stat", values_to = "val") |>
    mutate(col = if_else(mask == "overall",
                         paste0(index, "_modis_", stat),
                         paste0(index, "_modis_", mask, "_", stat))) |>
    dplyr::select(hex_id, year, col, val) |>
    pivot_wider(names_from = col, values_from = val) |>
    arrange(hex_id, year)

  # Urban land share per hex per year: fraction of classified CCI pixels that are urban (class 190).
  # Index-independent -> computed once from the resampled CCI grid. Genuine CCI years only (NA where
  # no CCI layer covers that VI year, i.e. beyond 2022 — not clamped, unlike the VI masks).
  urban_df <- as_tibble(terra::extract(cci_res == 190L, hex_vect_r,
                                       fun = mean, na.rm = TRUE, ID = FALSE)) |>
    mutate(hex_id = hex_ids_r) |>
    pivot_longer(-hex_id, names_to = "layer", values_to = "urban_share") |>
    mutate(year = as.integer(str_extract(layer, "\\d{4}"))) |>
    dplyr::filter(!is.na(year), year %in% VI_YEARS) |>
    dplyr::select(hex_id, year, urban_share)
  vi_r <- left_join(vi_r, urban_df, by = c("hex_id", "year"))

  vi_cols_r <- base::setdiff(names(vi_r), c("hex_id", "year"))
  message(sprintf("  VI years: %d-%d (%d years) | %d columns",
                  min(vi_r$year), max(vi_r$year), n_distinct(vi_r$year), length(vi_cols_r)))
  cat("  NA shares by VI column:\n"); print(round(sapply(vi_r[vi_cols_r], \(v) mean(is.na(v))), 3))

  saveRDS(vi_r, out_path)
  message(sprintf("Saved: %s", out_path))

  rm(hex_sf_r, hex_vect_r, hex_ids_r, vi_r, long)
  gc()
}

message("\n=== b_03a_vi_panel.R complete ===")
