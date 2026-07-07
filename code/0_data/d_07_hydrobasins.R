# d_07_hydrobasins.R
# HydroBASINS level-9 sub-basins → per-hex basin ID for event-study SE clustering.
#
# Offline script (no GEE / no auth): the raw layer is exported by d_01 Sec 6b to
#   data/raw/hydrobasins/hydrobasins_hybas9_studyarea.geojson
# (WWF/HydroSHEDS/v1/Basins/hybas_9, filtered to the study-area export_region).
# This script OWNS that dataset end-to-end, the way d_03 owns OSM and d_04 owns MERIT.
#
# PART 1 — Diagnostics / EDA (Secs 2–4)
#   How many level-9 basins actually cover the 5 km hex grid (= number of SE clusters),
#   the hexes-per-basin distribution, and a map of the basin partition over the study
#   area with the Barenblitt galamsey extent overlaid. This is the plot to eyeball
#   BEFORE swapping the 25 km centroid-block stand-in for real basin clustering.
#
# PART 2 — Build artifact (Sec 3)
#   Writes the per-hex lookup consumed by the build pipeline, per resolution:
#     data/processed/hydrobasins/hex_basin_{N}km.csv
#       hex_id, HYBAS_ID, PFAF_ID, MAIN_BAS, basin_num
#   Assignment is by hex CENTROID (matches the 25 km centroid-block convention in
#   a_05); centroids falling outside every basin polygon (coastal edge) are assigned
#   the nearest basin. `basin_num` is a compact 1..K integer factor of HYBAS_ID —
#   the `did`/polars backend cannot take the large-integer HYBAS_ID or a string
#   cluster column directly. `MAIN_BAS` is kept so SEs can optionally be clustered at
#   the coarser main-basin level as a robustness check.
#
# Loops over RESOLUTIONS like the sibling b_03c/b_03d scripts — only needs each
# resolution's hex_{N}km_crosssection.rds (from b_01), NOT the VI panel, so this can
# run for a resolution (e.g. 2 km) independently of whether its peak-EVI extraction
# (b_03a) has been run yet.
#
# Downstream wiring:
#   b_03e_assemble_eventpanel.R  merges hex_basin_{N}km.csv into event_panel_{N}km.rds
#   a_05_event_study.Rmd         replaces the block_id placeholder with basin_num
#
# Outputs (per resolution N):
#   data/processed/hydrobasins/hex_basin_{N}km.csv
#   outputs/figures/hydrobasins/basin_partition_map_{N}km.png
#   outputs/figures/hydrobasins/hexes_per_basin_hist_{N}km.png
#   outputs/figures/hydrobasins/basin_summary_{N}km.csv

RESOLUTIONS <- c(5, 2, 1)   # km

####0. Setup ####
pacman::p_load(sf, here, janitor, tidyverse, scales, patchwork, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff,
  here::here
)
UTM30N <- 32630

basins_path     <- here("data", "raw", "hydrobasins", "hydrobasins_hybas9_studyarea.geojson")
barenblitt_path <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")
admin0_path     <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp")
rivers_path     <- here("data", "processed", "waterways", "waterways_natural.shp")

proc_dir <- here("data", "processed", "hydrobasins")
fig_dir  <- here("outputs", "figures", "hydrobasins")
dir.create(proc_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(fig_dir,  recursive = TRUE, showWarnings = FALSE)

stopifnot("HydroBASINS geojson not found — run d_01 Sec 6b export + download_from_drive first." =
            file.exists(basins_path))

have_res <- RESOLUTIONS[file.exists(
  here("data", "processed", sprintf("hex_%dkm_crosssection.rds", RESOLUTIONS))
)]
if (!length(have_res)) stop("No crosssection caches found. Run b_01_cross_section.R first.")
message(sprintf("Resolutions with caches: %s km", paste(have_res, collapse = ", ")))

####1. Load shared assets (once for all resolutions) ####
# Basins: EPSG:4326 → UTM30N for metric overlay/area. Level-9 fields of interest:
#   HYBAS_ID (unique sub-basin id), MAIN_BAS (main-basin id, coarser), PFAF_ID
#   (Pfafstetter code), SUB_AREA (basin area, km²).
basins <- st_read(basins_path, quiet = TRUE) |>
  st_make_valid() |>
  st_transform(UTM30N)
message(sprintf("Loaded %d HydroBASINS level-9 polygons from the export region.", nrow(basins)))

# Galamsey extent (for the map overlay) — optional.
mining_2019 <- if (file.exists(barenblitt_path)) {
  st_read(barenblitt_path, quiet = TRUE) |> st_make_valid() |> st_transform(UTM30N)
} else { message("Barenblitt extent not found — map will omit the galamsey overlay."); NULL }

# Natural rivers (optional context overlay).
rivers <- if (file.exists(rivers_path)) {
  st_read(rivers_path, quiet = TRUE) |> st_transform(UTM30N)
} else NULL

# Ghana outline (optional context).
admin0 <- if (file.exists(admin0_path)) {
  st_read(admin0_path, quiet = TRUE) |> st_make_valid() |> st_transform(UTM30N)
} else NULL

####2. Per-resolution loop ####
for (res_km in have_res) {
message(sprintf("\n%s\n=== HydroBASINS assignment: %d km ===\n%s",
                strrep("=", 55), res_km, strrep("=", 55)))

hex_cache     <- here("data", "processed", sprintf("hex_%dkm_crosssection.rds", res_km))
hex_sf        <- readRDS(hex_cache)$hex_sf |> st_transform(UTM30N)   # already UTM30N; guard anyway
hex_centroids <- st_centroid(hex_sf)
message(sprintf("Loaded %d hexes from the %d km cross-section grid.", nrow(hex_sf), res_km))

####2a. Assign each hex to a basin (by centroid) ####
# st_within: centroid inside exactly one basin polygon. Any centroid outside every
# basin (study-area edge / coast) falls back to the nearest basin.
assigned <- st_join(
  hex_centroids,
  basins[, c("HYBAS_ID", "PFAF_ID", "MAIN_BAS")],
  join = st_within
) |>
  # a boundary-straddling centroid could match >1 polygon; keep the first per hex.
  distinct(hex_id, .keep_all = TRUE)

na_idx <- is.na(assigned$HYBAS_ID)
if (any(na_idx)) {
  nn <- st_nearest_feature(hex_centroids[na_idx, ], basins)
  assigned[na_idx, c("HYBAS_ID", "PFAF_ID", "MAIN_BAS")] <-
    st_drop_geometry(basins[nn, c("HYBAS_ID", "PFAF_ID", "MAIN_BAS")])
  message(sprintf("  %d hex(es) fell outside every basin polygon — assigned nearest basin.",
                  sum(na_idx)))
}

lookup <- assigned |>
  st_drop_geometry() |>
  select(hex_id, HYBAS_ID, PFAF_ID, MAIN_BAS) |>
  mutate(basin_num = as.integer(factor(HYBAS_ID)))   # compact 1..K for did/polars

####2b. Cluster-count diagnostics + write artifact ####
n_clusters <- n_distinct(lookup$HYBAS_ID)
n_main     <- n_distinct(lookup$MAIN_BAS)
per_basin  <- lookup |> count(HYBAS_ID, name = "n_hex")

cat(sprintf("\n=== HydroBASINS level-9 clustering diagnostics (%d km hex grid) ===\n", res_km))
cat(sprintf("  hexes                     : %d\n", nrow(lookup)))
cat(sprintf("  distinct level-9 basins   : %d   <- number of SE clusters\n", n_clusters))
cat(sprintf("  distinct MAIN_BAS (coarse): %d\n", n_main))
cat(sprintf("  hexes per basin           : min %d | median %.0f | mean %.1f | max %d\n",
            min(per_basin$n_hex), median(per_basin$n_hex),
            mean(per_basin$n_hex), max(per_basin$n_hex)))
cat(sprintf("  singleton basins (1 hex)  : %d (%.1f%% of basins)\n",
            sum(per_basin$n_hex == 1), 100 * mean(per_basin$n_hex == 1)))

# Rule-of-thumb sanity note for clustered inference.
if (n_clusters < 30)
  cat("  ** WARNING: <30 clusters — clustered/CS SEs may be unreliable; consider a coarser or block fallback.\n")

per_basin_summary <- basins |>
  st_drop_geometry() |>
  select(HYBAS_ID, MAIN_BAS, PFAF_ID, SUB_AREA) |>
  inner_join(per_basin, by = "HYBAS_ID") |>
  arrange(desc(n_hex))
write_csv(per_basin_summary, file.path(fig_dir, sprintf("basin_summary_%dkm.csv", res_km)))

out_csv <- file.path(proc_dir, sprintf("hex_basin_%dkm.csv", res_km))
write_csv(lookup, out_csv)
message(sprintf("Written: %s  (%d hexes → %d basins)", out_csv, nrow(lookup), n_clusters))

####2c. Map — basin partition over the study area ####
# Basins are categorical; a sequential palette would mislead. Fill with a small
# cycling qualitative set purely to separate neighbours (no legend — K is large).
basins_used <- basins |> filter(HYBAS_ID %in% lookup$HYBAS_ID) |>
  mutate(hue = factor(as.integer(factor(HYBAS_ID)) %% 8))

bb <- st_bbox(basins_used)

p_map <- ggplot() +
  { if (!is.null(admin0)) geom_sf(data = admin0, fill = "grey96", colour = NA) } +
  geom_sf(data = basins_used, aes(fill = hue), colour = "white",
          linewidth = 0.25, alpha = 0.85, show.legend = FALSE) +
  scale_fill_brewer(palette = "Set2") +
  { if (!is.null(rivers)) geom_sf(data = st_crop(rivers, bb),
                                  colour = "#2b6cb0", linewidth = 0.2, alpha = 0.5) } +
  { if (!is.null(mining_2019)) geom_sf(data = mining_2019,
                                       fill = "#1a1a1a", colour = NA) } +
  coord_sf(xlim = c(bb["xmin"], bb["xmax"]), ylim = c(bb["ymin"], bb["ymax"]),
           expand = FALSE) +
  labs(
    title    = "HydroBASINS level-9 sub-basins over the study area",
    subtitle = sprintf("%d basins cover the %d km hex grid (= SE clusters); black = Barenblitt 2019 galamsey extent",
                       n_clusters, res_km),
    caption  = "WWF/HydroSHEDS HydroBASINS (hybas_9). Barenblitt et al. (2021). Till Meissner."
  ) +
  theme_minimal(base_size = 10) +
  theme(plot.title = element_text(face = "bold"),
        axis.text = element_blank(), axis.title = element_blank(),
        panel.grid = element_blank(),
        plot.caption = element_text(colour = "grey50", size = 7))

ggsave(file.path(fig_dir, sprintf("basin_partition_map_%dkm.png", res_km)), p_map,
       width = 8, height = 8, dpi = 150)

####2d. Diagnostic — hexes-per-basin distribution ####
p_hist <- ggplot(per_basin, aes(n_hex)) +
  geom_histogram(binwidth = 1, fill = "#2c7fb8", colour = "white") +
  geom_vline(xintercept = median(per_basin$n_hex), linetype = 2, colour = "grey30") +
  labs(
    title    = "Hexes per level-9 basin",
    subtitle = sprintf("%d basins | median %.0f hex/basin | %d singleton basin(s)",
                       n_clusters, median(per_basin$n_hex), sum(per_basin$n_hex == 1)),
    x = "hexes assigned to the basin", y = "number of basins",
    caption  = "Dashed line = median. Singletons contribute a size-1 SE cluster."
  ) +
  theme_minimal(base_size = 10) +
  theme(plot.title = element_text(face = "bold"),
        plot.caption = element_text(colour = "grey50", size = 7))

ggsave(file.path(fig_dir, sprintf("hexes_per_basin_hist_%dkm.png", res_km)), p_hist,
       width = 7, height = 5, dpi = 150)

message(sprintf("  Artifact: %s", out_csv))
message(sprintf("  Figures : %s {basin_partition_map, hexes_per_basin_hist}_%dkm.png", fig_dir, res_km))

rm(hex_sf, hex_centroids, assigned, lookup, n_clusters, n_main, per_basin,
   per_basin_summary, out_csv, basins_used, bb, p_map, p_hist)
gc()
}   # end RESOLUTIONS loop

message("\n=== d_07_hydrobasins.R complete ===")
