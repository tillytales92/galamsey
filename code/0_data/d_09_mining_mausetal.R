# d_09_mining_mausetal.R
# Exploratory EDA on the Maus et al. global mining-polygon dataset, filtered to Ghana.
#
# Offline script (no GEE / no auth) — pure EDA, no processed outputs. Reads the single
# GeoPackage layer shared directly (not downloaded by any d_0N script in this repo):
#   data/raw/mining_mausetal/global_mining_polygons_v2.gpkg  (layer "mining_polygons")
#
# This is Maus et al.'s GLOBAL mining-footprint dataset (44,929 polygons worldwide,
# fields ISO3_CODE / COUNTRY_NAME / AREA) — a Sentinel-2-based classification of ALL
# mining land use (not just artisanal gold, no artisanal/industrial split, and a single
# static snapshot — no per-year time series, unlike Barenblitt). We only want Ghana here,
# so the read below filters server-side via a GDAL SQL WHERE clause rather than loading
# all 44,929 global polygons into memory.
#
# Goal is descriptive EDA only (distributions, spatial coverage, size, and a first look
# at agreement with Barenblitt 2019) — analogous to d_08_africa_mining_watch.R's
# treatment of the AMW data, and useful as another candidate validation/ensemble source
# alongside AMW and the rs05 AlphaEarth classifier (see galamsey_tasklist.md).
#
# Outputs: outputs/figures/mining_mausetal/*.png (diagnostic plots only)

pacman::p_load(sf, here, janitor, tidyverse, scales, patchwork, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff,
  here::here
)
UTM30N <- 32630

maus_path       <- here("data", "raw", "mining_mausetal", "global_mining_polygons_v2.gpkg")
barenblitt_path <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")
admin0_path     <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp")
admin1_path     <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin1.shp")

stopifnot("Maus et al. gpkg not found" = file.exists(maus_path))

fig_dir <- here("outputs", "figures", "mining_mausetal")
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

####1. Load — global layer info, then Ghana only via server-side SQL filter ####

lyrs   <- st_layers(maus_path)
fields <- names(st_read(maus_path, quiet = TRUE, query = sprintf("SELECT * FROM %s LIMIT 0", lyrs$name[1])))
message(sprintf("Layer '%s': %d features worldwide, fields: %s",
                lyrs$name[1], lyrs$features[1], paste(fields, collapse = ", ")))

maus_gha <- st_read(
  maus_path,
  query = sprintf("SELECT * FROM %s WHERE ISO3_CODE = 'GHA'", lyrs$name[1]),
  quiet = TRUE
) |> st_make_valid()

message(sprintf("Ghana: %d of %d global mining polygons (%.2f%%).",
                nrow(maus_gha), lyrs$features[1], 100 * nrow(maus_gha) / lyrs$features[1]))

####2. Area distribution ####
# `AREA` is Maus et al.'s own field, in km^2 (confirmed against geom-computed UTM30N
# hectares below: AREA_field * 100 == area_ha to within rounding). We compute our own
# geometry-based hectares too, per repo convention (as.numeric(st_area(geometry))/1e4),
# so this is comparable to the Barenblitt/AMW EDA scripts and catches any AREA/geometry
# mismatch (e.g. clipped or re-simplified polygons).

maus_utm <- st_transform(maus_gha, UTM30N) |>
  mutate(area_ha_geom = as.numeric(st_area(geom)) / 1e4,
         area_ha_field = AREA * 100)

cat("\n=== Maus et al. Ghana polygons: area (ha) ===\n")
cat("-- from AREA field (km^2 x 100) --\n"); print(summary(maus_utm$area_ha_field))
cat("-- from geometry (UTM30N) --\n");        print(summary(maus_utm$area_ha_geom))
cat(sprintf("\nTotal mapped mining area (geometry-based): %.0f ha across %d polygons.\n",
            sum(maus_utm$area_ha_geom), nrow(maus_utm)))
cat(sprintf("Max |field - geometry| discrepancy: %.2f ha\n",
            max(abs(maus_utm$area_ha_field - maus_utm$area_ha_geom))))

p_area <- ggplot(maus_utm, aes(area_ha_geom)) +
  geom_histogram(bins = 50, fill = "#2171B5") +
  scale_x_log10(labels = label_number()) +
  labs(title = "Maus et al. Ghana mining-polygon size distribution",
       subtitle = "Log10 x-axis; area computed from geometry (UTM30N)",
       x = "Polygon area (ha, log scale)", y = "Count") +
  theme_bw(base_size = 11)
p_area
ggsave(file.path(fig_dir, "maus_gha_area_hist.png"), p_area, width = 7, height = 5, dpi = 150)

####3. Spatial map — where are the Ghana polygons? ####

admin0 <- if (file.exists(admin0_path)) {
  st_read(admin0_path, quiet = TRUE) |> st_make_valid() |> select(any_of(c("adm0_name", "geometry")))
  } else { message("admin0 shapefile not found -- map will omit the Ghana outline."); NULL }

  admin1 <- if (file.exists(admin1_path)) {
    st_read(admin1_path, quiet = TRUE) |> st_make_valid() |> select(any_of(c("adm1_name", "geometry")))
    } else NULL

    bb <- st_bbox(maus_gha)
    p_map <- ggplot() +
      { if (!is.null(admin0)) geom_sf(data = admin0, fill = "grey96", colour = "grey60") } +
        { if (!is.null(admin1)) geom_sf(data = admin1, fill = NA, colour = "grey80", linewidth = 0.2) } +
          geom_sf(data = maus_gha, fill = "#2171B5", colour = NA, alpha = 0.75) +
            coord_sf(xlim = c(bb["xmin"], bb["xmax"]), ylim = c(bb["ymin"], bb["ymax"])) +
              labs(title = "Maus et al. global mining polygons — Ghana subset",
                     subtitle = sprintf("%d polygons, %.0f ha total (all mining land use -- not gold-specific, no artisanal/industrial split)",
                                               nrow(maus_gha), sum(maus_utm$area_ha_geom)),
                                                      caption  = "Maus et al. (2022), global mining-area polygons v2. Till Meissner.") +
                                                        theme_minimal(base_size = 10) +
                                                          theme(plot.title = element_text(face = "bold"),
                                                                  axis.text = element_blank(), axis.title = element_blank(),
                                                                          panel.grid = element_blank(),
                                                                                  plot.caption = element_text(colour = "grey50", size = 7))
                                                                                  p_map
ggsave(file.path(fig_dir, "maus_gha_map.png"), p_map, width = 8, height = 8, dpi = 150)

####4. First look — agreement with Barenblitt 2019 ####
# NOT a full validation -- just: how much of Maus et al.'s Ghana footprint spatially
# intersects the Barenblitt 2019 artisanal+industrial extent. Maus et al. is ALL mining
# land use (industrial concessions, quarries, etc., not just artisanal gold) and is a
# single static snapshot, so disagreement is expected and doesn't imply either source is
# wrong -- this is a first sanity check on spatial agreement, not an accuracy assessment.
# Barenblitt's known SW-Ghana-only coverage (~104,730 km^2, see CLAUDE.md caveats) means
# this can only speak to the area where Barenblitt has data.

mining_2019 <- if (file.exists(barenblitt_path)) {
  st_read(barenblitt_path, quiet = TRUE) |> clean_names() |> st_make_valid()
} else { message("Barenblitt 2019 extent not found -- skipping the Maus/Barenblitt comparison section."); NULL }

if (!is.null(mining_2019)) {
  mining_utm   <- st_transform(mining_2019, UTM30N)
  mining_union <- st_union(mining_utm)

  overlap_idx <- st_intersects(maus_utm, mining_union, sparse = FALSE)[, 1]
  n_overlap   <- sum(overlap_idx)
  cat(sprintf("\n=== Maus et al. Ghana polygons vs. Barenblitt 2019 extent ===\n"))
  cat(sprintf("  %d of %d Maus polygons (%.1f%%) intersect the Barenblitt 2019 extent.\n",
              n_overlap, nrow(maus_utm), 100 * n_overlap / nrow(maus_utm)))
  cat(sprintf(paste0("  %d of %d (%.1f%%) fall OUTSIDE Barenblitt's SW-Ghana study area -- neither\n",
                     "  confirmed nor refuted, since Barenblitt was never surveyed there (and Maus\n",
                     "  et al. includes non-gold mining land use Barenblitt was never trying to map).\n"),
              nrow(maus_utm) - n_overlap, nrow(maus_utm),
              100 * (1 - n_overlap / nrow(maus_utm))))

  # Area-weighted overlap is a more informative number than a polygon count here, since
  # a handful of huge industrial concessions could dominate the hectare total.
  ha_overlap <- sum(maus_utm$area_ha_geom[overlap_idx])
  ha_total   <- sum(maus_utm$area_ha_geom)
  cat(sprintf("  Area-weighted: %.0f of %.0f ha (%.1f%%) of Maus et al.'s Ghana footprint overlaps Barenblitt.\n",
              ha_overlap, ha_total, 100 * ha_overlap / ha_total))

  maus_utm <- maus_utm |> mutate(overlaps_barenblitt = overlap_idx)

  bb_bar <- st_bbox(mining_utm)
  p_overlap <- ggplot() +
    geom_sf(data = st_transform(mining_2019, st_crs(maus_utm)), fill = "grey30", colour = NA, alpha = 0.5) +
    geom_sf(data = maus_utm, aes(colour = overlaps_barenblitt), fill = NA, linewidth = 0.4) +
    coord_sf(xlim = c(bb_bar["xmin"], bb_bar["xmax"]), ylim = c(bb_bar["ymin"], bb_bar["ymax"])) +
    scale_colour_manual(values = c(`TRUE` = "#238B45", `FALSE` = "#D94701"),
                        labels = c(`TRUE` = "Intersects Barenblitt", `FALSE` = "No Barenblitt overlap"),
                        name = NULL) +
    labs(title = "Maus et al. Ghana polygons vs. Barenblitt 2019 extent (grey)",
         subtitle = "First-look agreement check only -- not a validated accuracy assessment; Maus et al. is not gold-specific",
         caption  = "Barenblitt et al. (2021); Maus et al. (2022) global mining polygons. Till Meissner.") +
    theme_minimal(base_size = 10) +
    theme(plot.title = element_text(face = "bold"),
          axis.text = element_blank(), axis.title = element_blank(),
          panel.grid = element_blank(),
          plot.caption = element_text(colour = "grey50", size = 7))
  p_overlap
  ggsave(file.path(fig_dir, "maus_barenblitt_overlap_map.png"), p_overlap, width = 8, height = 8, dpi = 150)
}

message("\n=== d_09_mining_mausetal.R complete ===")
