# b_01_cross_section.R
# Unified cross-sectional data builder. Replaces b_01_mining_by_unit.R (CSV writer)
# and b_02_hex_frame.R (hex-grid + first-stage covariate cache builder).
#
# One source() produces ALL downstream inputs required by:
#   a_01_incidence_maps.R     — reads mining_*_by_{unit}_*.csv
#   a_02_spatial_clustering.R — reads hex_5km_crosssection.rds + hex timeseries CSV
#   b_02_firststage_models.R  — reads hex_{1,2,5}km_crosssection.rds
#   b_03_event_panel.R        — reads hex_{N}km_crosssection.rds
#
# OUTPUTS PER UNIT
#   Districts:
#     data/processed/mining_extent_by_districts_2019.csv
#     data/processed/mining_timeseries_by_districts_2007_2017_wide.csv
#     data/processed/mining_timeseries_by_districts_2007_2017_long.csv
#   Each hex resolution N ∈ HEX_SIZES_KM:
#     data/processed/mining_extent_by_hex{N}km_2019.csv
#     data/processed/mining_timeseries_by_hex{N}km_2007_2017_wide.csv
#     data/processed/mining_timeseries_by_hex{N}km_2007_2017_long.csv
#     data/processed/hex_{N}km_crosssection.rds
#       list(hex_analysis, hex_sf, lw, nb, study_area)
#
# CSV COLUMN CONVENTION
#   Extent CSVs:  id_col | Artisanal | Industrial | Total   (read by a_01)
#   Long CSVs:    id_col | year | area_ha                   (a_01: area_ha; a_02 renames to mine_ha)
#
# PREREQUISITES
#   d_03_waterways.R must have run to produce data/processed/waterways/waterways_natural.shp.
#   d_02_elevation.R (optional) writes terrain rasters; elev/slope are NA in cache if absent.

####0. Parameters ####
HEX_SIZES_KM      <- c(5, 2, 1)   # resolutions to build; set c(5) for quick first run
TERRAIN_BUFFER_KM <- 10            # must match BUFFER_KM in d_02_elevation.R

####1. Setup ####
pacman::p_load(tidyverse, sf, here, janitor, units, spdep, terra, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)
UTM30N <- 32630

admin0_path          <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp")
admin2_path          <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin2.shp")
barenblitt_2019_path <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")
barenblitt_ts_path   <- here("data", "raw", "barenblitt", "MiningConversion_2007-2017Vec.shp")
gold_suit_path       <- here("data", "raw", "goldsuitability", "Gold_suitable_geology",
                              "gold_suitable_geology.shp")
waterways_path       <- here("data", "processed", "waterways", "waterways_natural.shp")
proc_dir             <- here("data", "processed")
elev_dir             <- here("data", "processed", "elevation")
dir.create(proc_dir, recursive = TRUE, showWarnings = FALSE)

####2. Load shared assets (once) ####
message("Loading shared assets...")

country_sf   <- st_read(admin0_path,  quiet = TRUE) |> clean_names() |>
  st_transform(UTM30N) |> st_make_valid()
districts_sf <- st_read(admin2_path,  quiet = TRUE) |> clean_names() |>
  select(adm2_name, geometry) |> st_transform(UTM30N) |> st_make_valid()

mining_2019 <- st_read(barenblitt_2019_path, quiet = TRUE) |> clean_names() |>
  st_transform(UTM30N) |> st_make_valid()

mining_ts <- st_read(barenblitt_ts_path, quiet = TRUE) |> clean_names() |>
  st_transform(UTM30N) |> st_make_valid() |>
  mutate(year = 2000L + as.integer(trimws(as.character(classifica))))

gold_suit <- st_read(gold_suit_path, quiet = TRUE) |> clean_names() |>
  st_transform(UTM30N) |> st_make_valid()

if (!file.exists(waterways_path))
  stop("waterways_natural.shp not found. Run d_03_waterways.R first.")
waterways <- st_read(waterways_path, quiet = TRUE) |> clean_names() |> st_transform(UTM30N)
message(sprintf("Natural waterways: %d features loaded from processed/.", nrow(waterways)))

# Study area: Barenblitt convex hull clipped to Ghana (canonical definition across all scripts)
ghana_poly      <- st_union(country_sf) |> st_make_valid()
study_area_hull <- st_union(mining_2019) |> st_convex_hull()
study_area      <- st_intersection(study_area_hull, ghana_poly) |> st_make_valid()
message(sprintf("Study area: %.0f km²", as.numeric(st_area(study_area)) / 1e6))

# Terrain rasters (loaded once; used in the hex loop)
elev_utm_path  <- file.path(elev_dir, sprintf("ghana_elevation_utm30n_buf%dkm.tif", TERRAIN_BUFFER_KM))
slope_utm_path <- file.path(elev_dir, sprintf("ghana_slope_utm30n_buf%dkm.tif",     TERRAIN_BUFFER_KM))
have_terrain   <- file.exists(elev_utm_path) && file.exists(slope_utm_path)
if (have_terrain) {
  dem_utm   <- terra::rast(elev_utm_path)
  slope_utm <- terra::rast(slope_utm_path)
  message("Terrain rasters found — elev_mean/slope_mean will be extracted per hex.")
} else {
  message("Terrain rasters absent — elev_mean/slope_mean will be NA in hex caches.",
          "\n  Run d_02_elevation.R first, then re-source this script.")
}

# Area-intersection helper — returns tibble with id_col + area_ha column.
intersect_area_ha <- function(mine_sf, unit_sf, id_col) {
  if (nrow(mine_sf) == 0)
    return(tibble(!!id_col := unit_sf[[id_col]], area_ha = 0))
  st_intersection(unit_sf |> select(all_of(id_col)), mine_sf) |>
    mutate(area_ha = as.numeric(st_area(geometry)) / 1e4) |>
    st_drop_geometry() |>
    group_by(!!sym(id_col)) |>
    summarise(area_ha = sum(area_ha, na.rm = TRUE), .groups = "drop") |>
    right_join(unit_sf |> st_drop_geometry() |> select(all_of(id_col)), by = id_col) |>
    mutate(area_ha = replace_na(area_ha, 0))
}

####3. Districts pass ####
message("\n=== DISTRICTS ===")

art_d  <- intersect_area_ha(mining_2019 |> filter(mine_type == 1), districts_sf, "adm2_name") |>
  rename(Artisanal = area_ha)
ind_d  <- intersect_area_ha(mining_2019 |> filter(mine_type == 2), districts_sf, "adm2_name") |>
  rename(Industrial = area_ha)

extent_districts <- art_d |>
  left_join(ind_d, by = "adm2_name") |>
  mutate(Total = Artisanal + Industrial) |>
  arrange(desc(Total))

message("  Computing annual district panel (2007-2017)...")
ts_dist_long <- map_dfr(2007:2017, function(yr) {
  intersect_area_ha(mining_ts |> filter(year == yr), districts_sf, "adm2_name") |>
    mutate(year = yr)
})
ts_dist_wide <- ts_dist_long |>
  pivot_wider(names_from = year, values_from = area_ha,
              values_fill = 0, names_prefix = "y") |>
  mutate(total_ha = rowSums(across(starts_with("y")))) |>
  arrange(desc(total_ha))

write_csv(extent_districts, here(proc_dir, "mining_extent_by_districts_2019.csv"))
write_csv(ts_dist_wide,     here(proc_dir, "mining_timeseries_by_districts_2007_2017_wide.csv"))
write_csv(ts_dist_long,     here(proc_dir, "mining_timeseries_by_districts_2007_2017_long.csv"))
message(sprintf("  Districts done: %d units — CSVs written.", nrow(districts_sf)))

####4. Hex loop ####
for (hex_km in HEX_SIZES_KM) {
  hex_m   <- hex_km * 1000
  res_tag <- paste0(hex_km, "km")
  message(sprintf("\n=== HEX %d km ===", hex_km))

  # --- 4a. Hex grid (Barenblitt convex hull clipped to Ghana) ---
  hex_raw <- st_sf(geometry = st_make_grid(study_area, cellsize = hex_m, square = FALSE)) |>
    mutate(hex_id = paste0("hex_", row_number()))
  keep    <- st_intersects(hex_raw, study_area, sparse = FALSE)[, 1]
  hex_sf  <- hex_raw[keep, ] |> st_make_valid()
  message(sprintf("  Hex grid: %d cells at %d m", nrow(hex_sf), hex_m))

  # --- 4b. Mining CSVs ---
  message("  Computing 2019 extent per hex...")
  art_raw <- intersect_area_ha(mining_2019 |> filter(mine_type == 1), hex_sf, "hex_id")
  ind_raw <- intersect_area_ha(mining_2019 |> filter(mine_type == 2), hex_sf, "hex_id")

  extent_hex <- art_raw |> rename(Artisanal = area_ha) |>
    left_join(ind_raw |> rename(Industrial = area_ha), by = "hex_id") |>
    mutate(Total = Artisanal + Industrial) |>
    arrange(desc(Total))

  message("  Computing annual hex panel (2007-2017)...")
  ts_hex_long <- map_dfr(2007:2017, function(yr) {
    message("    year ", yr)
    intersect_area_ha(mining_ts |> filter(year == yr), hex_sf, "hex_id") |>
      mutate(year = yr)
  })
  ts_hex_wide <- ts_hex_long |>
    pivot_wider(names_from = year, values_from = area_ha,
                values_fill = 0, names_prefix = "y") |>
    mutate(total_ha = rowSums(across(starts_with("y")))) |>
    arrange(desc(total_ha))

  write_csv(extent_hex,  here(proc_dir, sprintf("mining_extent_by_hex%s_2019.csv",               res_tag)))
  write_csv(ts_hex_wide, here(proc_dir, sprintf("mining_timeseries_by_hex%s_2007_2017_wide.csv", res_tag)))
  write_csv(ts_hex_long, here(proc_dir, sprintf("mining_timeseries_by_hex%s_2007_2017_long.csv", res_tag)))
  message(sprintf("  CSVs written: mining_*_by_hex%s_*.csv", res_tag))

  # --- 4c. First-stage covariates ---
  # art_ha / ind_ha for analysis frame (renaming from CSVs' area_ha)
  art_ha_xsec <- art_raw |> rename(art_ha = area_ha)
  ind_ha_xsec <- ind_raw |> rename(ind_ha = area_ha)

  message("  Computing gold suitability share per hex...")
  gold_hex <- st_intersection(hex_sf |> select(hex_id), gold_suit) |>
    mutate(ha = as.numeric(st_area(geometry)) / 1e4) |>
    st_drop_geometry() |>
    group_by(hex_id) |>
    summarise(gold_suit_ha = sum(ha), .groups = "drop")

  hex_centroids <- st_centroid(hex_sf)
  nearest_idx   <- st_nearest_feature(hex_centroids, waterways)
  dist_to_water <- st_distance(hex_centroids, waterways[nearest_idx, ], by_element = TRUE)

  hex_northing <- hex_centroids |>
    mutate(northing = st_coordinates(geometry)[, 2]) |>
    st_drop_geometry() |>
    select(hex_id, northing)

  hex_cs <- hex_sf |>
    mutate(unit_ha = as.numeric(st_area(geometry)) / 1e4) |>
    left_join(art_ha_xsec, by = "hex_id") |>
    left_join(ind_ha_xsec, by = "hex_id") |>
    left_join(gold_hex,    by = "hex_id") |>
    left_join(hex_northing, by = "hex_id") |>
    mutate(
      art_ha          = replace_na(art_ha, 0),
      ind_ha          = replace_na(ind_ha, 0),
      gold_suit_ha    = replace_na(gold_suit_ha, 0),
      art_share       = art_ha / unit_ha,
      gold_suit_share = gold_suit_ha / unit_ha,
      dist_river_km   = as.numeric(dist_to_water) / 1000,
      any_art         = art_ha > 0
    )

  # --- 4d. Terrain covariates ---
  if (have_terrain) {
    message("  Extracting elevation + slope per hex...")
    hex_vect  <- terra::vect(hex_sf)
    elev_hex  <- terra::extract(dem_utm,   hex_vect, fun = mean, na.rm = TRUE)
    slope_hex <- terra::extract(slope_utm, hex_vect, fun = mean, na.rm = TRUE)

    terrain_tbl <- tibble(
      hex_id     = hex_sf$hex_id,
      elev_mean  = elev_hex[[2]],
      slope_mean = slope_hex[[2]]
    )
    na_n <- sum(is.na(terrain_tbl$elev_mean))
    if (na_n > 0) {
      message(sprintf("    %d hex(es) lack DEM coverage — increase TERRAIN_BUFFER_KM in d_02_elevation.R.", na_n))
      write_csv(
        terrain_tbl |> filter(is.na(elev_mean)) |> select(hex_id),
        here(proc_dir, sprintf("hex_terrain_missing_%dkm.csv", hex_km))
      )
    }
    hex_cs <- hex_cs |> left_join(terrain_tbl, by = "hex_id")
    message(sprintf("  Terrain added: %d hexes, %d NA.", nrow(hex_sf), na_n))
  } else {
    hex_cs <- hex_cs |> mutate(elev_mean = NA_real_, slope_mean = NA_real_)
  }

  # --- 4e. Spatial weights ---
  message("  Building queen-contiguity weights...")
  nb <- poly2nb(hex_sf, queen = TRUE)
  lw <- nb2listw(nb, style = "W", zero.policy = TRUE)

  # --- 4f. Cache ---
  hex_analysis <- hex_cs |>
    st_drop_geometry() |>
    arrange(match(hex_id, hex_sf$hex_id))

  cache_path <- here(proc_dir, sprintf("hex_%s_crosssection.rds", res_tag))
  saveRDS(
    list(hex_analysis = hex_analysis, hex_sf = hex_sf,
         lw = lw, nb = nb, study_area = study_area),
    cache_path
  )
  prev <- mean(hex_analysis$any_art, na.rm = TRUE)
  message(sprintf("  Cache written: %s\n    %d hexes | prevalence = %.3f | %d mine hexes",
                  basename(cache_path), nrow(hex_sf), prev, sum(hex_analysis$any_art)))
}

message("\n=== b_01_cross_section.R complete ===")
message("Next: source b_02_firststage_models.R and b_03_event_panel.R")
