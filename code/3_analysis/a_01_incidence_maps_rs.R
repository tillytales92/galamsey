# a_01_incidence_maps_rs.R
# RS-panel counterpart to a_01_incidence_maps.R's D1a/D1b -- same palette/layout conventions,
# driven by code/2_build/b_04_rs_mining_panel.R's hex panel instead of Barenblitt. Kept as a
# SEPARATE script/output set, not a replacement (2026-11-05 decision: keep both sources available
# for comparison, see code/2_build/explainer.md once b_04 gets its own entry there).
#
# Scope note: b_04 currently only has a 5km hex CSV, bar_hull-scoped (not national) -- see that
# script's own header. This script inherits both limits; extending either is a b_04-level decision,
# not something to silently work around here.

####0. Setup ####
pacman::p_load(tidyverse, sf, here, scales, patchwork, gganimate, gifski, conflicted)
conflicts_prefer(dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise, here::here)
UTM30N <- 32630

PLASMA <- c("#FCFDBF", "#FEC287", "#FD9567", "#F1605D", "#CD4071", "#9E2F7F", "#721F81", "#450457")
YEARS  <- 2005:2025

out_dir <- here("outputs", "figures", "maps", "hex5km_rs")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

####1. Load data ####
cache     <- readRDS(here("data", "processed", "hex_5km_crosssection.rds"))
hex_sf    <- cache$hex_sf           # bar_hull-scoped, SAME grid b_04 reused -- hex_id lines up
study_area <- cache$study_area

panel_raw <- read_csv(here("outputs", "tables", "backdating", "b_04_rs_mining_panel_5km.csv"),
                       show_col_types = FALSE)

industrial_sf <- st_read(here("data", "processed", "ghana_industrial_mines.gpkg"), quiet = TRUE) |>
  st_transform(UTM30N)

country_sf <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp"), quiet = TRUE) |>
  st_transform(UTM30N)
regions_sf <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin1.shp"), quiet = TRUE) |>
  st_transform(UTM30N)
study_regions_sf <- regions_sf[st_intersects(regions_sf, study_area, sparse = FALSE)[, 1], ]

p_inset_ghana <- ggplot() +
  geom_sf(data = country_sf,  fill = "grey92", colour = "grey50", linewidth = 0.3) +
  geom_sf(data = study_area,  fill = "#450457", alpha = 0.45, colour = "#2d032f", linewidth = 0.6) +
  theme_void() +
  theme(panel.background = element_rect(fill = "white", colour = "grey40", linewidth = 0.5))

####2. Reshape: wide (y2005..y2025, m2) -> long (year, area_ha), join to hex_sf ####
panel_long <- panel_raw |>
  select(hex_id, starts_with("y20")) |>
  pivot_longer(starts_with("y20"), names_to = "year", values_to = "area_m2") |>
  mutate(year = as.integer(str_remove(year, "^y")), area_ha = area_m2 / 1e4) |>
  select(hex_id, year, area_ha)

####3. D1a-RS -- small-multiple maps: cumulative mining extent by year ####
years_show <- seq(min(YEARS), max(YEARS), by = 4)   # 2005, 2009, ..., 2025 -- 6 panels

map_data_small <- hex_sf |>
  left_join(panel_long |> filter(year %in% years_show), by = "hex_id")

p_small <- ggplot(map_data_small) +
  geom_sf(aes(fill = area_ha), colour = "white", linewidth = 0.1) +
  geom_sf(data = study_regions_sf, fill = NA, colour = "grey40", linewidth = 0.25) +
  geom_sf(data = country_sf, fill = NA, colour = "grey15", linewidth = 0.5) +
  facet_wrap(~year, nrow = 2) +
  scale_fill_gradientn(
    colours = PLASMA, trans = "sqrt", labels = label_comma(), na.value = "#F9F9F9",
    name = "Area (ha)",
    guide = guide_colorbar(barwidth = unit(12, "cm"), barheight = unit(0.4, "cm"),
                            title.position = "top", title.hjust = 0.5)
  ) +
  labs(
    title    = "Cumulative mined area by 5km hex -- RS-derived panel",
    subtitle = "2005-2016 backdated (Barenblitt method) + 2017-2025 embedding classifier, no magnitude gate",
    caption  = "Barenblitt study-area hull only (not national -- see b_04_rs_mining_panel.R header)."
  ) +
  theme_void(base_size = 10) +
  theme(
    strip.text      = element_text(face = "bold", size = 9),
    legend.position = "bottom",
    plot.title      = element_text(face = "bold"),
    plot.caption    = element_text(colour = "grey50", size = 7)
  )

p_small_final <- p_small + inset_element(p_inset_ghana,
                                          left = 0.88, bottom = 0.05, right = 1.0, top = 0.92,
                                          align_to = "plot")
ggsave(file.path(out_dir, "d1a_hex5km_rs_cumulative.png"), p_small_final, width = 14, height = 10, dpi = 150)
message("Saved: maps/hex5km_rs/d1a_hex5km_rs_cumulative.png")

####4. D1a-RS -- animated GIF: cumulative mining extent, 2005-2025 ####
plot_data_anim <- panel_long |>
  right_join(hex_sf, by = "hex_id") |>
  st_as_sf()

p_anim <- ggplot(plot_data_anim) +
  geom_sf(aes(fill = area_ha), colour = NA) +
  geom_sf(data = study_regions_sf, fill = NA, colour = "grey40", linewidth = 0.3) +
  scale_fill_gradientn(
    colours = PLASMA, trans = "sqrt", name = "Area (ha)", labels = label_comma(), na.value = "#F0F0F0",
    guide = guide_colorbar(barwidth = unit(8, "cm"), barheight = unit(0.4, "cm"),
                            title.position = "top", title.hjust = 0.5)
  ) +
  labs(
    title    = "Cumulative mined area -- RS-derived panel -- {closest_state}",
    subtitle = "5km hex, Barenblitt study-area hull. Backdated 2005-2016 + classifier 2017-2025.",
    caption  = "Dashed outline: Barenblitt SW Ghana survey area."
  ) +
  theme_void(base_size = 12) +
  theme(
    plot.title      = element_text(face = "bold", size = 13),
    plot.subtitle   = element_text(size = 10, colour = "grey40"),
    plot.caption    = element_text(colour = "grey50", size = 8),
    legend.position = "bottom"
  ) +
  transition_states(year, transition_length = 1, state_length = 3) +
  ease_aes("linear")

gif_file <- file.path(out_dir, "d1a_hex5km_rs_cumulative_animation.gif")
animate(p_anim, nframes = length(YEARS) * 4, fps = 4, width = 700, height = 850,
        renderer = gifski_renderer(gif_file))
message("Saved: maps/hex5km_rs/d1a_hex5km_rs_cumulative_animation.gif")

####5. D1b-RS -- artisanal (RS, industrial already excluded) vs industrial (reference layer) ####
# NOT a subtraction -- build_03's APPLY_INDUSTRIAL (reworked 2026-10-27) already excludes named
# industrial mines from the deployed mine_mask_ghana_c4_{yr} assets, so the RS panel IS the
# artisanal-proxy layer already. The industrial panel is a separate static reference (14 named
# mines, ghana_industrial_mines.gpkg), not a derived difference -- it has no time dimension, unlike
# Barenblitt's own D1b (which has a real annual industrial series).
latest_year <- max(YEARS)
art_data <- hex_sf |> left_join(panel_long |> filter(year == latest_year), by = "hex_id")

p_art <- ggplot(art_data) +
  geom_sf(aes(fill = area_ha), colour = "white", linewidth = 0.1) +
  geom_sf(data = study_regions_sf, fill = NA, colour = "grey40", linewidth = 0.25) +
  geom_sf(data = country_sf, fill = NA, colour = "grey15", linewidth = 0.5) +
  scale_fill_gradientn(
    colours = c("#FFFFD4", "#FED98E", "#FE9929", "#D95F0E", "#993404"),
    trans = "sqrt", labels = label_comma(), name = "Area (ha)", na.value = "#F9F9F9",
    guide = guide_colorbar(barwidth = unit(7, "cm"), barheight = unit(0.4, "cm"),
                            title.position = "top", title.hjust = 0.5)
  ) +
  labs(title = paste0("Artisanal (RS, industrial excluded) -- ", latest_year)) +
  theme_void(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 11, hjust = 0.5), legend.position = "bottom")

p_ind <- ggplot() +
  geom_sf(data = study_area, fill = "grey95", colour = "grey70", linewidth = 0.2) +
  geom_sf(data = study_regions_sf, fill = NA, colour = "grey40", linewidth = 0.25) +
  geom_sf(data = country_sf, fill = NA, colour = "grey15", linewidth = 0.5) +
  geom_sf(data = industrial_sf, aes(fill = area_km2), colour = "#084594", linewidth = 0.3) +
  scale_fill_gradientn(
    colours = c("#EFF3FF", "#BDD7E7", "#6BAED6", "#2171B5", "#084594"),
    trans = "sqrt", labels = label_comma(), name = "Area (km2)", na.value = "#F9F9F9",
    guide = guide_colorbar(barwidth = unit(7, "cm"), barheight = unit(0.4, "cm"),
                            title.position = "top", title.hjust = 0.5)
  ) +
  labs(title = paste0("Industrial (named mines, static reference, n=", nrow(industrial_sf), ")")) +
  theme_void(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 11, hjust = 0.5), legend.position = "bottom")

p_types <- p_art + p_ind +
  plot_annotation(
    subtitle = "RS-derived (build_02/03/04) artisanal proxy vs ICMM/Maus/Tang&Werner industrial reference",
    caption  = "Barenblitt study-area hull. Industrial panel is a static reference layer, not a time series.",
    theme    = theme(plot.subtitle = element_text(colour = "grey40", size = 9),
                      plot.caption  = element_text(colour = "grey50", size = 8))
  )
p_types_final <- p_types + inset_element(p_inset_ghana,
                                          left = 0.88, bottom = 0.0, right = 1.0, top = 0.32,
                                          align_to = "plot")
ggsave(file.path(out_dir, "d1b_hex5km_rs_artisanal_vs_industrial.png"), p_types_final,
       width = 14, height = 9, dpi = 150)
message("Saved: maps/hex5km_rs/d1b_hex5km_rs_artisanal_vs_industrial.png")

message("\n=== a_01_incidence_maps_rs.R: done ===")
