# d_08_africa_mining_watch.R
# Exploratory EDA on the Africa Mining Watch (AMW) early ML detections for Ghana.
#
# Offline script (no GEE / no auth) — pure EDA, no processed outputs. Reads the two
# geojson exports AMW shared directly (not downloaded by any d_0N script in this repo):
#   data/raw/africa_mining_watch_early_data/africa_mining_watch_early_data/
#     ghana_detection_boxes_Thresh0.99MLP64-16_2025-09-18T19_46.joblib.geojson
#     ghana_rectpolys_Thresh0.99MLP64-16_2025-09-18T19_46.joblib.geojson
#
# Filename decoded: "Thresh0.99" = confidence threshold already applied upstream (every
# feature in both files has confidence > 0.99); "MLP64-16" = the classifier architecture
# (2-layer MLP, 64/16 units) scoring candidate mine sites; "detection_boxes" = raw
# per-tile model detections (69,095 boxes); "rectpolys" = detection boxes merged into
# 2,488 site-level rectangular footprints (the actual mine-site candidate set). Both are
# single-snapshot (one detection date implied by the run timestamp) — UNLIKE Barenblitt,
# there is no per-year time series here, and neither file carries any date/id/type field
# beyond `confidence`.
#
# Goal here is just descriptive EDA (distributions, spatial coverage, size, and a first
# look at agreement with Barenblitt 2019) to inform the tasklist item "review AMW data as
# a validation/ensemble source against Barenblitt and the rs05 AlphaEarth classifier" —
# this script does NOT attempt that full validation (no district-level accuracy stats,
# no ensembling); it is the first-look EDA that should precede it.
#
# Outputs: outputs/figures/africa_mining_watch/*.png (diagnostic plots only)

pacman::p_load(sf, here, janitor, tidyverse, scales, patchwork, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff,
  here::here
)
UTM30N <- 32630

amw_dir <- here("data", "raw", "africa_mining_watch_early_data", "africa_mining_watch_early_data")
boxes_path    <- file.path(amw_dir, "ghana_detection_boxes_Thresh0.99MLP64-16_2025-09-18T19_46.joblib.geojson")
rectpolys_path <- file.path(amw_dir, "ghana_rectpolys_Thresh0.99MLP64-16_2025-09-18T19_46.joblib.geojson")
barenblitt_path <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")
admin0_path     <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp")

stopifnot("AMW detection_boxes geojson not found" = file.exists(boxes_path),
          "AMW rectpolys geojson not found"       = file.exists(rectpolys_path))

fig_dir <- here("outputs", "figures", "africa_mining_watch")
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

####1. Load ####

boxes <- st_read(boxes_path, quiet = TRUE) |> st_make_valid()
rects <- st_read(rectpolys_path, quiet = TRUE) |> st_make_valid()

message(sprintf("detection_boxes: %d features | rectpolys: %d features",
                nrow(boxes), nrow(rects)))
message(sprintf("Both share the same bounding box: %s",
                paste(round(st_bbox(rects), 3), collapse = ", ")))
# NOTE: bbox is roughly lon -2.85 to -1.03, lat 4.93 to 6.94 -- SW Ghana only, NOT all of
# Ghana (which spans lon -3.5 to 1.3, lat 4.5 to 11.5). "early_data" in the folder name
# is consistent with this being a partial/pilot run, not a national product yet.

admin0 <- if (file.exists(admin0_path)) {
  st_read(admin0_path, quiet = TRUE) |> st_make_valid() |> select(any_of(c("adm0_name", "geometry")))
} else { message("admin0 shapefile not found -- maps will omit the Ghana outline."); NULL }

mining_2019 <- if (file.exists(barenblitt_path)) {
  st_read(barenblitt_path, quiet = TRUE) |> clean_names() |> st_make_valid()
} else { message("Barenblitt 2019 extent not found -- skipping the AMW/Barenblitt comparison section."); NULL }

####2. Confidence-score distributions ####
# Both files are already thresholded at 0.99 (per the filename), so this just shows HOW
# far above threshold detections sit -- a right-skewed pile-up near 1.0 would mean the
# threshold isn't very binding; a lot of mass near 0.99 would mean many detections are
# borderline.

conf_df <- bind_rows(
  boxes |> st_drop_geometry() |> mutate(source = "detection_boxes (raw, per-tile)"),
  rects |> st_drop_geometry() |> mutate(source = "rectpolys (merged site footprints)")
)

cat("\n=== Confidence score summary ===\n")
conf_df |> group_by(source) |> summarise(
  n = n(), min = min(confidence), p10 = quantile(confidence, .1),
  median = median(confidence), mean = mean(confidence), max = max(confidence)
) |> print()

p_conf <- ggplot(conf_df, aes(confidence)) +
  geom_histogram(bins = 60, fill = "#721F81") +
  facet_wrap(~source, scales = "free_y", ncol = 1) +
  scale_x_continuous(labels = label_number(accuracy = 0.001)) +
  labs(title = "AMW detection confidence scores",
       subtitle = "Both files are pre-filtered at confidence > 0.99 (see filename)",
       x = "Model confidence", y = "Count") +
  theme_bw(base_size = 11)
p_conf
ggsave(file.path(fig_dir, "amw_confidence_hist.png"), p_conf, width = 8, height = 6, dpi = 150)

####3. Spatial coverage — where are the detections? ####

bb <- st_bbox(rects)
p_map <- ggplot() +
  { if (!is.null(admin0)) geom_sf(data = admin0, fill = "grey96", colour = "grey60") } +
  geom_sf(data = boxes, fill = "#2b6cb0", colour = NA, alpha = 0.15) +
  geom_sf(data = rects, fill = "#D94701", colour = NA, alpha = 0.6) +
  coord_sf(xlim = c(bb["xmin"], bb["xmax"]), ylim = c(bb["ymin"], bb["ymax"])) +
  labs(title = "Africa Mining Watch detections — Ghana (early/pilot run)",
       subtitle = "Blue = raw per-tile detection boxes (n = 69,095); orange = merged site footprints (n = 2,488)",
       caption  = "Africa Mining Watch, early ML detections (MLP64-16, thresh 0.99, 2025-09-18). Till Meissner.") +
  theme_minimal(base_size = 10) +
  theme(plot.title = element_text(face = "bold"),
        axis.text = element_blank(), axis.title = element_blank(),
        panel.grid = element_blank(),
        plot.caption = element_text(colour = "grey50", size = 7))
p_map
ggsave(file.path(fig_dir, "amw_detections_map.png"), p_map, width = 8, height = 8, dpi = 150)

####4. Rectpolys site-footprint size distribution ####
# Area in hectares, UTM30N (repo convention: as.numeric(st_area(geometry)) / 1e4).

rects_utm <- st_transform(rects, UTM30N) |>
  mutate(area_ha = as.numeric(st_area(geometry)) / 1e4)

cat("\n=== Rectpoly (merged site footprint) area, hectares ===\n")
print(summary(rects_utm$area_ha))
cat(sprintf("Total AMW footprint area: %.0f ha across %d sites\n",
            sum(rects_utm$area_ha), nrow(rects_utm)))

p_area <- ggplot(rects_utm, aes(area_ha)) +
  geom_histogram(bins = 50, fill = "#D94701") +
  scale_x_log10(labels = label_number()) +
  labs(title = "AMW merged site-footprint size distribution",
       subtitle = "Log10 x-axis -- most footprints are small, a long tail of large sites",
       x = "Site area (ha, log scale)", y = "Count") +
  theme_bw(base_size = 11)
p_area
ggsave(file.path(fig_dir, "amw_rectpoly_area_hist.png"), p_area, width = 7, height = 5, dpi = 150)

####5. First look — agreement with Barenblitt 2019 ####
# NOT a full validation (no accuracy/recall stats) -- just: how many AMW site footprints
# spatially intersect the Barenblitt 2019 artisanal+industrial extent, as a first sanity
# check that the two sources are pointing at the same places. Both reprojected to UTM30N
# for a metric overlay; Barenblitt's known SW-Ghana-only coverage (~104,730 km^2, see
# CLAUDE.md caveats) means this can only speak to the area where Barenblitt has data --
# AMW detections outside that footprint are neither confirmed nor refuted by this check.

if (!is.null(mining_2019)) {
  mining_utm <- st_transform(mining_2019, UTM30N)
  mining_union <- st_union(mining_utm)

  overlap_idx <- st_intersects(rects_utm, mining_union, sparse = FALSE)[, 1]
  n_overlap   <- sum(overlap_idx)
  cat(sprintf("\n=== AMW rectpolys vs. Barenblitt 2019 extent ===\n"))
  cat(sprintf("  %d of %d AMW site footprints (%.1f%%) intersect the Barenblitt 2019 extent.\n",
              n_overlap, nrow(rects_utm), 100 * n_overlap / nrow(rects_utm)))
  cat(sprintf(paste0("  %d of %d (%.1f%%) fall OUTSIDE Barenblitt's SW-Ghana study area -- neither\n",
                     "  confirmed nor refuted, since Barenblitt was never surveyed there.\n"),
              nrow(rects_utm) - n_overlap, nrow(rects_utm),
              100 * (1 - n_overlap / nrow(rects_utm))))

  rects_utm <- rects_utm |> mutate(overlaps_barenblitt = overlap_idx)

  bb_bar <- st_bbox(mining_utm)
  p_overlap <- ggplot() +
    geom_sf(data = st_transform(mining_2019, st_crs(rects_utm)), fill = "grey30", colour = NA, alpha = 0.5) +
    geom_sf(data = rects_utm, aes(colour = overlaps_barenblitt), fill = NA, linewidth = 0.4) +
    coord_sf(xlim = c(bb_bar["xmin"], bb_bar["xmax"]), ylim = c(bb_bar["ymin"], bb_bar["ymax"])) +
    scale_colour_manual(values = c(`TRUE` = "#238B45", `FALSE` = "#D94701"),
                        labels = c(`TRUE` = "Intersects Barenblitt", `FALSE` = "No Barenblitt overlap"),
                        name = NULL) +
    labs(title = "AMW site footprints vs. Barenblitt 2019 extent (grey)",
         subtitle = "First-look agreement check only -- not a validated accuracy assessment",
         caption  = "Barenblitt et al. (2021); Africa Mining Watch early detections. Till Meissner.") +
    theme_minimal(base_size = 10) +
    theme(plot.title = element_text(face = "bold"),
          axis.text = element_blank(), axis.title = element_blank(),
          panel.grid = element_blank(),
          plot.caption = element_text(colour = "grey50", size = 7))
  p_overlap
  ggsave(file.path(fig_dir, "amw_barenblitt_overlap_map.png"), p_overlap, width = 8, height = 8, dpi = 150)
}

message("\n=== d_08_africa_mining_watch.R complete ===")
