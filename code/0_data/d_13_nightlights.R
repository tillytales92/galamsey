# d_13_nightlights.R -- harmonised nighttime lights per hex / district, annual 1992-2025.
#
# Source: Chiovelli, Michalopoulos, Papaioannou & Regan (2026), "Illuminating the Global South",
#   Economic Journal, doi:10.1093/ej/ueaf134. Data: Zenodo doi:10.5281/zenodo.20558766 (CC BY 4.0;
#   cite the paper). Variant `bloomtopcode_fix` (blooming + top-coding corrected), DMSP and VIIRS
#   harmonised onto one DMSP-style scale. Downloaded by hand to data/raw/nightlights/.
#   Files: bloomtopcode_fix/bloomtopcode_fix/DMSP{year}_bltcfix.tif, EPSG:4326, 30 arc-sec (~1 km),
#   integer, 0 = unlit.
#
# Units: b_01 hex grids (hex_{N}km_crosssection.rds) and the 260 districts (gha_admin2).
# Per unit x year, with exactextractr (cells weighted by the share of the cell inside the unit):
#   ntl_mean   mean light value
#   ntl_sum    sum of light (coverage-weighted) -- grows with unit size, use for totals
#   ntl_lit    share of the unit's area on lit cells (value > 0)
#   ntl_max    brightest cell touching the unit
#
# Output: data/processed/nightlights/nightlights_{unit}_1992_2025.{rds,csv}
# Runs locally (no GEE); a few minutes.

####0. Parameters ####
HEX_SIZES_KM <- c(5)
DO_DISTRICTS <- TRUE

pacman::p_load(tidyverse, sf, terra, exactextractr, here, conflicted)
conflicts_prefer(dplyr::filter, dplyr::select, dplyr::mutate, here::here)

NTL_DIR <- here("data", "raw", "nightlights", "bloomtopcode_fix", "bloomtopcode_fix")
OUT_DIR <- here("data", "processed", "nightlights")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

files <- list.files(NTL_DIR, "^DMSP\\d{4}_bltcfix\\.tif$", full.names = TRUE)
years <- as.integer(str_extract(basename(files), "\\d{4}"))
if (!length(files)) stop("No DMSP{year}_bltcfix.tif files in ", NTL_DIR)
message(length(files), " annual rasters, ", min(years), "-", max(years))

####1. Units (EPSG:4326, matching the rasters) ####
units <- list()
for (hex_km in HEX_SIZES_KM)
  units[[paste0("hex", hex_km, "km")]] <-
    readRDS(here("data", "processed", sprintf("hex_%dkm_crosssection.rds", hex_km)))$hex_sf |>
    select(unit_id = hex_id) |> st_transform(4326)
if (DO_DISTRICTS)
  units[["districts"]] <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin2.shp"), quiet = TRUE) |>
    st_make_valid() |> select(unit_id = adm2_name) |> st_transform(4326)

# Crop every year to the bounding box of all units once (the global rasters are ~650M cells)
bb <- ext(vect(do.call(rbind, lapply(units, \(u) st_as_sf(st_as_sfc(st_bbox(u))))))) + 0.05

####2. Extract ####
# Built-in (compiled) summaries only -- an R summary function per unit was far too slow (2026-11-17).
# All years in one multi-layer raster, plus a lit/unlit layer per year whose mean = ntl_lit.
stack <- rast(lapply(files, \(f) crop(rast(f), bb)))
names(stack) <- paste0("y", years)
lit <- stack > 0
names(lit) <- paste0("y", years)
res <- list()
for (u in names(units)) {
  s <- exact_extract(stack, units[[u]], fun = c("mean", "sum", "max"), progress = FALSE)
  l <- exact_extract(lit,   units[[u]], fun = "mean", progress = FALSE)
  names(l) <- paste0("lit.", names(lit))
  res[[u]] <- bind_cols(unit_id = units[[u]]$unit_id, s, l) |>
    pivot_longer(-unit_id, names_to = c("stat", "year"), names_pattern = "(mean|sum|max|lit)\\.y(\\d{4})") |>
    mutate(year = as.integer(year), stat = paste0("ntl_", stat)) |>
    pivot_wider(names_from = stat, values_from = value) |>
    select(unit_id, year, ntl_mean, ntl_sum, ntl_lit, ntl_max)
  message("  extracted ", u)
}

####3. Write + quick checks ####
for (u in names(units)) {
  d <- res[[u]] |> arrange(unit_id, year)
  base <- file.path(OUT_DIR, sprintf("nightlights_%s_%d_%d", u, min(years), max(years)))
  saveRDS(d, paste0(base, ".rds")); write_csv(d, paste0(base, ".csv"))
  tot <- d |> group_by(year) |> summarise(sum = round(sum(ntl_sum)), lit_pct = round(100 * mean(ntl_lit, na.rm = TRUE), 1),
                                          .groups = "drop")
  message("\n", u, ": ", n_distinct(d$unit_id), " units x ", n_distinct(d$year), " years -> ", base, ".{rds,csv}")
  print(as.data.frame(tot), row.names = FALSE)
}
message("\n=== d_13_nightlights.R: done ===")
