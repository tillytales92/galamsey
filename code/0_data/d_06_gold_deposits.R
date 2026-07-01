# d_06_gold_deposits.R
# Two-part gold-potential characterisation:
#
# PART 1 — Hydro-geomorphic analysis for ALLUVIAL (placer) gold potential (Secs A–E, J–L)
#   Plan + conceptual background: code/0_data/gold_deposits.md. Explains what we are looking
#   for (valley bottoms, floodplains, terraces, confluences, depressions), why each matters
#   for alluvial gold, and how MERIT Hydro / a DEM / WhiteboxTools / SAGA produce the layers.
#   This script was split out of d_02_elevation.R, which is now the basic terrain layer only.
#   Status: Secs A–E functional. Secs J–L are TODO (placer indicators, MERIT Hydro, per-hex).
#
# PART 2 — Girard et al. (2022a) gold-suitability instrument EDA (Secs F–I)
#   Merged from 3_other/gold_suitability.R (2026-06-25). Compares Layer 1 (binary geology
#   polygon) and Layer 2 (PRIO-Grid share), overlays Barenblitt 2019 artisanal mining for
#   instrument validation, and produces district-level gold-suit share aggregates.
#   Outputs: gold_suitability_by_district.csv + three validation PNGs.
#
# Engines (install once):
#   WhiteboxTools — whitebox::install_whitebox()   (self-contained binary, R-driven)
#   SAGA GIS      — separate install, then RSAGA::rsaga.env(path = "C:/path/to/saga")
#
# Inputs (built by d_02_elevation.R — run it first):
#   data/processed/elevation/ghana_elevation_utm30n_buf{BUFFER_KM}km.tif
#
# Outputs (data/processed/hydro/, filenames carry the buffer):
#   ghana_breached_*  conditioned DEM        ghana_d8pointer_* flow direction (D8)
#   ghana_d8accum_*   flow accumulation      ghana_streams_*   extracted channel network
#   ghana_strahler_*  Strahler stream order  ghana_hand_*      height above nearest drainage
#   ghana_mrvbf_*     valley-bottom flatness

####0. Setup ####
pacman::p_load(terra, sf, here, janitor, tidyverse, whitebox, RSAGA, patchwork, scales, units, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)
UTM30N <- 32630

BUFFER_KM <- 10          # must match the DEM built by d_02_elevation.R

# Channel-definition threshold: minimum upslope cells for a cell to count as a stream.
# At z10 (~150 m) a cell is ~0.023 km^2, so 1000 cells ~= 23 km^2 contributing area. Lower
# it for a denser network (more headwater streams, smaller HAND), raise it for trunk rivers.
# See gold_deposits.md S5 for how this interacts with where placers actually form.
STREAM_THRESHOLD <- 1000

proc_dir  <- here("data", "processed", "elevation")
hydro_dir <- here("data", "processed", "hydro")
dir.create(hydro_dir, recursive = TRUE, showWarnings = FALSE)

elev_utm_path <- file.path(proc_dir, sprintf("ghana_elevation_utm30n_buf%dkm.tif", BUFFER_KM))
if (!file.exists(elev_utm_path)) {
  stop("DEM not found: ", elev_utm_path,
       "\n  Run code/0_data/d_02_elevation.R first to build the reprojected DEM.")
}

# WhiteboxTools writes to disk and reads GeoTIFFs; stage the DEM once.
if (!isTRUE(try(whitebox::check_whitebox_binary(), silent = TRUE)))
  stop("WhiteboxTools binary not found — run whitebox::install_whitebox() once, then re-run.")

dem_path     <- file.path(hydro_dir, sprintf("ghana_dem_in_buf%dkm.tif",      BUFFER_KM))
breached     <- file.path(hydro_dir, sprintf("ghana_breached_buf%dkm.tif",    BUFFER_KM))
d8pointer    <- file.path(hydro_dir, sprintf("ghana_d8pointer_buf%dkm.tif",   BUFFER_KM))
d8accum      <- file.path(hydro_dir, sprintf("ghana_d8accum_buf%dkm.tif",     BUFFER_KM))
streams      <- file.path(hydro_dir, sprintf("ghana_streams_buf%dkm.tif",     BUFFER_KM))
strahler     <- file.path(hydro_dir, sprintf("ghana_strahler_buf%dkm.tif",    BUFFER_KM))
hand_path    <- file.path(hydro_dir, sprintf("ghana_hand_buf%dkm.tif",        BUFFER_KM))
mrvbf_path   <- file.path(hydro_dir, sprintf("ghana_mrvbf_buf%dkm.tif",       BUFFER_KM))

terra::writeRaster(terra::rast(elev_utm_path), dem_path, overwrite = TRUE)

####A. Hydrological conditioning (remove spurious sinks) ####
# A "sink" / "pit" is a cell (or group) with no lower neighbour, so flow routing stalls
# there. Most are DEM noise and MUST be removed before flow direction can be computed --
# otherwise drainage is broken. We BREACH (carve a channel through the lip) rather than
# FILL (raise the pit to its lip): breaching alters far fewer cells and preserves valley
# floor elevations, which we care about for HAND. NB: some sinks are *real* (ponds, and
# notably galamsey pits themselves) -- see gold_deposits.md S3 on telling these apart.
if (!file.exists(breached)) {
  message("A. Breaching depressions...")
  whitebox::wbt_breach_depressions_least_cost(dem = dem_path, output = breached, dist = 100)
}

####B. Flow direction (D8) + flow accumulation ####
# D8 sends each cell's flow to its single steepest downslope neighbour -> a "pointer" grid
# encoding direction. Flow accumulation sums how many cells drain through each cell; high
# accumulation = channels. (D-infinity / MFD spread flow over multiple neighbours and model
# hillslope dispersal better, but D8 is the standard, cheapest basis for streams + HAND.)
if (!file.exists(d8pointer)) {
  message("B. D8 flow pointer + accumulation...")
  whitebox::wbt_d8_pointer(dem = breached, output = d8pointer)
  whitebox::wbt_d8_flow_accumulation(input = breached, output = d8accum, out_type = "cells")
}

####C. Stream network + Strahler order ####
# Threshold the accumulation grid to define channels, then order them. Strahler order is a
# proxy for position in the drainage network: placers tend to favour intermediate orders --
# not steep headwaters (too erosive) nor the largest rivers (gold too dispersed). See S5.
if (!file.exists(streams)) {
  message("C. Extracting streams (threshold = ", STREAM_THRESHOLD, " cells) + Strahler order...")
  whitebox::wbt_extract_streams(flow_accum = d8accum, output = streams, threshold = STREAM_THRESHOLD)
  whitebox::wbt_strahler_stream_order(d8_pntr = d8pointer, streams = streams, output = strahler)
}

####D. HAND — Height Above Nearest Drainage ####
# Vertical drop from each cell to the stream cell it drains into. Low HAND = active
# floodplain (modern alluvium); intermediate HAND = terraces (paleo-placers); high = upland.
# See gold_deposits.md S6 for the full explanation + why it matters.
if (!file.exists(hand_path)) {
  message("D. Computing HAND...")
  whitebox::wbt_elevation_above_stream(dem = breached, streams = streams, output = hand_path)
}

####E. MRVBF — Multiresolution Index of Valley Bottom Flatness ####
# Flags low + flat valley floors at multiple scales (sediment-accumulating settings). SAGA
# only -- no native WhiteboxTools equivalent. See gold_deposits.md S6.
if (!file.exists(mrvbf_path)) {
  if (requireNamespace("RSAGA", quietly = TRUE) &&
      !inherits(try(saga_env <- RSAGA::rsaga.env(), silent = TRUE), "try-error") &&
      nzchar(saga_env$path)) {
    message("E. Computing MRVBF (SAGA)...")
    saga_tmp <- file.path(tempdir(), "saga_mrvbf"); dir.create(saga_tmp, showWarnings = FALSE)
    saga_dem <- file.path(saga_tmp, "dem")          # base name; SAGA appends .sgrd/.sdat
    RSAGA::rsaga.import.gdal(in.grid = elev_utm_path, out.grid = saga_dem, env = saga_env)
    RSAGA::rsaga.geoprocessor(
      lib    = "ta_morphometry",
      module = "Multiresolution Index of Valley Bottom Flatness (MRVBF)",
      param  = list(DEM   = paste0(saga_dem, ".sgrd"),
                    MRVBF = file.path(saga_tmp, "mrvbf.sgrd"),
                    MRRTF = file.path(saga_tmp, "mrrtf.sgrd")),
      env = saga_env
    )
    terra::writeRaster(terra::rast(file.path(saga_tmp, "mrvbf.sdat")), mrvbf_path, overwrite = TRUE)
  } else {
    warning("SAGA/RSAGA not configured — skipping MRVBF. ",
            "Install SAGA GIS + RSAGA::rsaga.env(path='...'), then re-run Section E.")
  }
}

message("Hydro layers written to ", hydro_dir)

# PART 2 — Girard gold-suitability instrument EDA (Secs F–I)
# Merged from 3_other/gold_suitability.R on 2026-06-25.

####F. Girard layers — load and clip to Ghana ####
gha_country   <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin",
                               "gha_admin0.shp")) |> clean_names()
gha_districts <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin",
                               "gha_admin2.shp")) |>
  clean_names() |> select(adm2_name, adm1_name, geometry)

geology_raw <- st_read(
  here("data", "raw", "goldsuitability", "Gold_suitable_geology",
       "gold_suitable_geology.shp")) |> clean_names()

geology_rast <- rast(here("data", "raw", "goldsuitability", "gold_suitable_geology.tif"))

priogrid_raw <- read_csv(
  here("data", "raw", "goldsuitability", "Gold_suitable_PRIOgrid",
       "gold_suit_X_priogrid.csv"),
  col_types = cols(gid = col_integer(), xcoord = col_double(),
                   ycoord = col_double(), share_gold_suitable = col_double()))

mining_2019_gs <- st_read(
  here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")) |>
  clean_names() |>
  mutate(mine_label = factor(mine_type, 1:2, c("Artisanal", "Industrial")))

# Layer 1: geology polygon clipped to Ghana
geology_gha <- st_intersection(st_make_valid(geology_raw), st_union(gha_country))

# Layer 1 raster cropped + masked
gha_vect         <- vect(gha_country)
geology_rast_gha <- geology_rast |> crop(gha_vect) |> mask(gha_vect)

# Layer 2: build PRIO-Grid cell polygons (0.5° × 0.5°) for Ghana bbox, clip to outline
make_cell <- function(x, y, half = 0.25) {
  st_polygon(list(matrix(
    c(x-half,y-half, x+half,y-half, x+half,y+half, x-half,y+half, x-half,y-half),
    ncol = 2, byrow = TRUE)))
}
priogrid_gha <- priogrid_raw |>
  filter(!is.na(xcoord), xcoord >= -3.75, xcoord <= 1.75,
         ycoord >= 4.25, ycoord <= 11.75) |>
  mutate(share_gold_suitable = replace_na(share_gold_suitable, 0)) |>
  rowwise() |>
  mutate(geometry = st_sfc(make_cell(xcoord, ycoord), crs = 4326)) |>
  ungroup() |>
  st_as_sf() |>
  st_intersection(st_union(gha_country))

####G. Maps — Layer 1 vs Layer 2 + Barenblitt validation overlay ####
theme_map <- theme_void(base_size = 11) +
  theme(plot.title    = element_text(face = "bold", size = 11),
        plot.subtitle = element_text(colour = "grey40", size = 9),
        legend.position = "right",
        plot.caption  = element_text(colour = "grey50", size = 7))

# Load existing 5 km hex grid + 2019 artisanal mining extent
cs5       <- readRDS(here("data", "processed", "hex_5km_crosssection.rds"))
mine5     <- read_csv(here("data", "processed", "mining_extent_by_hex5km_2019.csv"),
                      show_col_types = FALSE)
hex5_plot <- cs5$hex_sf |>
  left_join(select(mine5, hex_id, Artisanal), by = "hex_id") |>
  mutate(has_mining = replace_na(Artisanal, 0) > 0) |>
  st_transform(4326)

p_geology <- ggplot() +
  geom_sf(data = gha_country,                    fill = "#F5F5F0", colour = "grey70", linewidth = 0.3) +
  geom_sf(data = geology_gha,                    fill = "#D4A853", colour = NA,       alpha = 0.75) +
  geom_sf(data = filter(hex5_plot, has_mining),  fill = "#B2182B", colour = "white",  linewidth = 0.08, alpha = 0.70) +
  geom_sf(data = gha_country,                    fill = NA,        colour = "grey40", linewidth = 0.4) +
  labs(title    = "Layer 1 — Gold-suitable geology",
       subtitle = "Amber: gold-suitable bedrock   |   Red hexagons: 5 km cells with artisanal mining",
       caption  = "Girard et al. (2022a) geology; Barenblitt et al. (2021) artisanal mining extent") +
  theme_map

p_priogrid <- ggplot() +
  geom_sf(data = gha_country,  fill = "#F5F5F0", colour = "grey70", linewidth = 0.3) +
  geom_sf(data = priogrid_gha, aes(fill = share_gold_suitable),
          colour = "white", linewidth = 0.25, alpha = 0.85) +
  geom_sf(data = gha_country,  fill = NA, colour = "grey40", linewidth = 0.4) +
  scale_fill_gradientn(colours = c("#F5F5F0", "#F0C97A", "#D4A853", "#8B5E0A"),
                       name = "Share\ngold-suitable",
                       labels = percent_format(accuracy = 1), limits = c(0, 1)) +
  labs(title    = "Layer 2 — Gold suitability (PRIO-Grid)",
       subtitle = "Share of 0.5° cell covered by gold-suitable geology\n(~55 × 55 km cells)",
       caption  = "Girard et al. (2022a); PRIO-GRID: Tollefsen et al. (2012)") + theme_map

p_compare <- p_geology + p_priogrid +
  plot_annotation(
    title   = "Gold-suitable geology in Ghana — two representations",
    caption = "Left: raw geological polygon. Right: coarse PRIO-Grid aggregation (0.5°).",
    theme   = theme(plot.title = element_text(face = "bold", size = 13)))
p_compare

p_validation <- ggplot() +
  geom_sf(data = gha_country,                                    fill = "#F5F5F0", colour = "grey70", linewidth = 0.3) +
  geom_sf(data = geology_gha,                                    fill = "#D4A853", colour = NA, alpha = 0.5) +
  geom_sf(data = filter(mining_2019_gs, mine_label == "Artisanal"), fill = "#C0392B", colour = NA, alpha = 0.7) +
  geom_sf(data = gha_districts,                                  fill = NA, colour = "white", linewidth = 0.1) +
  geom_sf(data = gha_country,                                    fill = NA, colour = "grey40", linewidth = 0.4) +
  labs(title    = "Gold-suitable geology vs actual artisanal mining (2005–2019)",
       subtitle = "Gold = gold-suitable bedrock (Layer 1)   |   Red = artisanal mining (Barenblitt 2021)",
       caption  = "Almost all artisanal mining falls within gold-suitable bedrock, validating the instrument.") +
  theme_map
p_validation

####H. District-level aggregation (Layer 1 × districts) ####
geology_utm   <- st_transform(geology_gha,   UTM30N) |> st_make_valid()
districts_utm <- st_transform(gha_districts, UTM30N) |> st_make_valid() |>
  mutate(district_area_ha = as.numeric(st_area(geometry)) / 1e4)

gold_by_district <- st_intersection(geology_utm, districts_utm) |>
  mutate(gold_area_ha = as.numeric(st_area(geometry)) / 1e4) |>
  st_drop_geometry() |>
  group_by(adm2_name, adm1_name) |>
  summarise(gold_area_ha = sum(gold_area_ha), .groups = "drop") |>
  left_join(districts_utm |> st_drop_geometry() |> select(adm2_name, district_area_ha),
            by = "adm2_name") |>
  mutate(gold_share = gold_area_ha / district_area_ha) |>
  arrange(desc(gold_share))

gold_by_district_full <- bind_rows(
  gold_by_district,
  gha_districts |> st_drop_geometry() |>
    anti_join(gold_by_district, by = "adm2_name") |>
    mutate(gold_area_ha = 0, gold_share = 0))

districts_gold_map <- gha_districts |>
  left_join(select(gold_by_district_full, adm2_name, gold_share), by = "adm2_name") |>
  mutate(gold_share = replace_na(gold_share, 0))

p_district_map <- ggplot(districts_gold_map) +
  geom_sf(aes(fill = gold_share), colour = "white", linewidth = 0.15) +
  scale_fill_gradientn(colours = c("#F5F5F0", "#F0C97A", "#D4A853", "#8B5E0A"),
                       name = "Share\ngold-suitable",
                       labels = percent_format(accuracy = 1), limits = c(0, 1)) +
  labs(title    = "Gold-suitable geology by district",
       subtitle = "Share of district area on gold-suitable bedrock (Layer 1)",
       caption  = "Girard et al. (2022a)") + theme_map

p_district_bar <- gold_by_district |>
  slice_max(gold_share, n = 25) |>
  mutate(adm2_name = fct_reorder(adm2_name, gold_share)) |>
  ggplot(aes(x = gold_share, y = adm2_name)) +
  geom_col(fill = "#D4A853") +
  scale_x_continuous(labels = percent_format(accuracy = 1),
                     expand = expansion(mult = c(0, 0.05))) +
  labs(title    = "Top 25 districts by gold-suitable geology coverage",
       subtitle = "Share of district area on gold-suitable bedrock",
       x = "Share of district area", y = NULL,
       caption  = "Girard et al. (2022a) Layer 1 — gold_suitable_geology shapefile") +
  theme_minimal(base_size = 11) +
  theme(plot.caption = element_text(colour = "grey50", size = 8))

p_district_map + p_district_bar + plot_layout(widths = c(1, 1.4))

####I. Save Girard outputs ####
dir.create(here("outputs", "figures", "maps"), recursive = TRUE, showWarnings = FALSE)
write_csv(gold_by_district_full,
          here("data", "processed", "gold_suitability_by_district.csv"))
ggsave(here("outputs", "figures","maps", "gold_suitability_comparison.png"),
       p_compare, width = 12, height = 7, dpi = 150)
ggsave(here("outputs", "figures","maps", "gold_suitability_vs_mining.png"),
       p_validation, width = 8, height = 9, dpi = 150)
ggsave(here("outputs", "figures","maps", "gold_suitability_districts.png"),
       p_district_map + p_district_bar + plot_layout(widths = c(1, 1.4)),
       width = 14, height = 8, dpi = 150)
ggsave(here("outputs", "figures","maps","gold_geology_with_mining_hexes.png"),
       p_geology, width = 7, height = 9, dpi = 150)

# PART 1 continued — SKELETON / TODO (design choices in gold_deposits.md)

####J. Derived placer indicators (TODO — see gold_deposits.md S6-S7) ####
# Candidate exogenous indicators of where eroded gold settles:
#   - SPI = ln(flow_accum * tan(slope_radians)); low SPI on a channel = low-energy reach.
#   - Confluences: junctions where lower-order meets higher-order stream -> placer trap.
#   - Terraces: reclassify HAND into bands (0-2 m floodplain / 2-10 m terrace / >10 m upland).
#   - Meander/point-bar proxies: sinuosity along the network.
#   - Source coupling: distance along network downstream of Girard gold-suitable bedrock.

####K. MERIT Hydro alternative (TODO — see gold_deposits.md S4) ####
# Ingest MERIT Hydro (Yamazaki et al. 2019, ~90 m) instead of routing the AWS-tile DEM.
# Pull via GEE ("MERIT/Hydro/v1_0_1") or direct download, clip to Ghana + buffer, reproject.

####L. Combine + per-hex extraction (TODO — see gold_deposits.md S7) ####
# Per-hex extraction of HAND / MRVBF / SPI should happen in 2_build/b_02_hex_frame.R
# (reads these rasters, stores columns in the cache RDS alongside elev_mean / slope_mean).

message("\n=== d_06_gold_deposits.R complete (A-E hydro + F-I Girard EDA functional; J-L TODO) ===")
