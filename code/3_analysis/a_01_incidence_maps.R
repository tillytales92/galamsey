# a_01_incidence_maps.R
# Section 1.1 — Incidence of Galamsey
#
# Reads CSVs produced by 2_build/b_01_mining_by_unit.R — run b_01 first for
# districts and hex10km before running this script.
#
# Plots produced:
#   D1a  small-multiple maps — cumulative/annual mining extent by year
#          (hex10km + districts, all years, plasma palette)
#   D1b  artisanal vs industrial side-by-side maps (hex10km + districts, 2005-2019)
#   D1c  land-cover fraction time series (national + per unit)
#   D1d  summary statistics + bar chart + national series vs gold price

####0. Setup ####
pacman::p_load(tidyverse, sf, here, janitor, scales, patchwork, quantmod, gganimate, gifski, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)
UTM30N <- 32630

####1. Parameters ####

# Spatial file paths
district_sf_path     <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin2.shp")
barenblitt_2019_path <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")
waterways_path       <- here("data", "raw", "shapefiles", "osm_waterways", "waterways_lines.shp")
HEX_SIZE             <- 10000  # metres (flat-to-flat); run d01 with matching hex_size_km first
hex_label            <- paste0("hex", HEX_SIZE / 1000, "km")   # e.g. "hex5km", "hex10km"

# Unit identifier columns
district_id_col <- "adm2_name"
hex_id_col      <- "hex_id"

####2. Load Data ####

# Ghana boundary overlays
country_sf <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp")) |>
  clean_names() |> st_transform(UTM30N)
regions_sf <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin1.shp")) |>
  clean_names() |> st_transform(UTM30N)

# Districts
districts_sf <- st_read(district_sf_path) |>
  clean_names() |>
  select(all_of(district_id_col), geometry) |>
  st_transform(UTM30N)

# Survey area: convex hull of Barenblitt 2019 extent, clipped to Ghana boundary
# Clipping prevents the hull extending into the sea or across land borders
mining_2019_raw <- st_read(barenblitt_2019_path) |>
  clean_names() |> st_transform(UTM30N) |> st_make_valid()
survey_area_sf  <- mining_2019_raw |>
  st_union() |>
  st_convex_hull() |>
  st_intersection(st_union(country_sf)) |>
  st_make_valid() |>
  st_sf()
survey_bbox     <- st_bbox(survey_area_sf)

# Regions that overlap the survey area — used as the boundary overlay on all maps
study_regions_sf <- regions_sf[st_intersects(regions_sf, survey_area_sf, sparse = FALSE)[, 1], ]

# OSM waterways clipped to survey area (displayed on maps). Keep only natural
# watercourses (drop man-made canals/drains/ditches) so the rivers shown match those
# used for dist_river_km in a_02; classification lives in d_03_waterways.R.
NATURAL_WATERWAYS <- c("river", "stream", "brook", "wadi", "tidal_channel",
                       "stream_pool", "flowline")
waterways      <- st_read(waterways_path) |> clean_names() |> st_transform(UTM30N) |>
  filter(waterway %in% NATURAL_WATERWAYS)
waterways_clip <- st_filter(waterways, survey_area_sf)

# Hexagons — generated from district boundary union (all Ghana)
study_area <- districts_sf |> st_union()
hex_raw    <- st_sf(geometry = st_make_grid(study_area, cellsize = HEX_SIZE, square = FALSE)) |>
  mutate(hex_id = paste0("hex_", row_number()))
keep    <- st_intersects(hex_raw, study_area, sparse = FALSE)[, 1]
hex_sf  <- hex_raw[keep, ] |> st_make_valid()

# Survey-area-clipped units for display — organic boundary matching d03 approach.
# hex_sf and districts_sf (all Ghana) are kept for d01 data joins; these are map-only.
hex_survey_sf       <- hex_sf[st_intersects(hex_sf, survey_area_sf, sparse = FALSE)[, 1], ]
survey_districts_sf <- districts_sf[st_intersects(districts_sf, survey_area_sf, sparse = FALSE)[, 1], ]

survey_units <- setNames(
  list(hex_survey_sf, survey_districts_sf),
  c(hex_label, "districts")
)

# Save district count for the presentation (avoids heavy spatial ops in the qmd)
saveRDS(nrow(survey_districts_sf),
        here("data", "processed", "n_surveyed_districts.rds"))

# d01 processed outputs — time series and 2019 extent for each unit type
ts_long_hex       <- read_csv(here("data", "processed", paste0("mining_timeseries_by_", hex_label, "_2007_2017_long.csv")),   show_col_types = FALSE)
ts_long_districts <- read_csv(here("data", "processed", "mining_timeseries_by_districts_2007_2017_long.csv"), show_col_types = FALSE)

extent_hex        <- read_csv(here("data", "processed", paste0("mining_extent_by_", hex_label, "_2019.csv")),   show_col_types = FALSE)
extent_districts  <- read_csv(here("data", "processed", "mining_extent_by_districts_2019.csv"), show_col_types = FALSE)

# Ghana locator inset — built once, reused across all map outputs
p_inset_ghana <- ggplot() +
  geom_sf(data = country_sf,    fill = "grey92", colour = "grey50", linewidth = 0.3) +
  geom_sf(data = survey_area_sf, fill = "#C0392B", alpha = 0.45,
          colour = "#7B241C", linewidth = 0.6) +
  theme_void() +
  theme(panel.background = element_rect(fill = "white", colour = "grey40", linewidth = 0.5))

####3. Unit Areas (for normalisation) ####
unit_areas_hex <- hex_sf |>
  mutate(unit_ha = as.numeric(st_area(geometry)) / 1e4) |>
  st_drop_geometry() |>
  select(all_of(hex_id_col), unit_ha)

unit_areas_districts <- districts_sf |>
  mutate(unit_ha = as.numeric(st_area(geometry)) / 1e4) |>
  st_drop_geometry() |>
  select(all_of(district_id_col), unit_ha)

# Single consolidated config list used by all sections
unit_configs <- setNames(
  list(
  list(
    units_sf    = hex_sf,
    ts_long     = ts_long_hex,
    extent_data = extent_hex,
    unit_areas  = unit_areas_hex,
    id_col      = hex_id_col,
    unit_label  = "hex cell",
    out_subdir  = hex_label
  ),
  list(
    units_sf    = districts_sf,
    ts_long     = ts_long_districts,
    extent_data = extent_districts,
    unit_areas  = unit_areas_districts,
    id_col      = district_id_col,
    unit_label  = "district",
    out_subdir  = "districts"
  )
  ),
  c(hex_label, "districts")
)

####4. D1a — Small-Multiple Maps: Cumulative Mining Extent by Year ####

# accumulation : "cumulative" — cumsum since first year | "annual" — yearly additions
# Colour scale : plasma (sqrt transform), area in ha
# Map viewport : natural extent of survey-area-clipped units (organic shape, no rectangular crop)

plot_mining_map <- function(
  units_sf,
  ts_long,
  id_col,
  years_show   = seq(2007, 2017, by = 2),
  accumulation = c("cumulative", "annual"),
  unit_label   = "district",
  country_sf   = NULL,
  regions_sf   = NULL,
  waterways_sf = NULL
) {
  accumulation <- match.arg(accumulation)

  all_units <- units_sf |> st_drop_geometry() |> pull(!!sym(id_col))

  unit_areas_tbl <- units_sf |>
    mutate(unit_ha = as.numeric(st_area(geometry)) / 1e4) |>
    st_drop_geometry() |>
    select(all_of(id_col), unit_ha)

  ts_prep <- ts_long |>
    complete(!!sym(id_col) := all_units,
             year = min(ts_long$year):max(ts_long$year),
             fill = list(area_ha = 0)) |>
    arrange(!!sym(id_col), year) |>
    group_by(!!sym(id_col)) |>
    mutate(cumulative_ha = cumsum(area_ha)) |>
    ungroup() |>
    mutate(value = if (accumulation == "cumulative") cumulative_ha else area_ha) |>
    left_join(unit_areas_tbl, by = id_col) |>
    mutate(plot_value = if (accumulation == "cumulative") value / unit_ha * 100 else value) |>
    filter(year %in% years_show)

  p <- ggplot(units_sf |> left_join(ts_prep, by = id_col)) +
    geom_sf(aes(fill = plot_value), colour = "white", linewidth = 0.1)

  if (!is.null(regions_sf))
    p <- p + geom_sf(data = regions_sf, fill = NA, colour = "grey40", linewidth = 0.25)
  if (!is.null(country_sf))
    p <- p + geom_sf(data = country_sf, fill = NA, colour = "grey15", linewidth = 0.5)
  if (!is.null(waterways_sf))
    p <- p + geom_sf(data = waterways_sf, colour = "#3B8ED0", linewidth = 0.15, alpha = 0.6)

  p +
    facet_wrap(~year, nrow = 2) +
    scale_fill_gradientn(
      colours  = c("#FCFDBF", "#FEC287", "#FD9567", "#F1605D", "#CD4071", "#9E2F7F", "#721F81", "#450457"),
      trans    = "sqrt",
      labels   = if (accumulation == "cumulative") \(x) paste0(round(x, 2), "%") else label_comma(),
      name     = if (accumulation == "cumulative") "Mining\nshare (%)" else "Area added\n(ha)",
      na.value = "#F9F9F9",
      guide    = guide_colorbar(
        barwidth       = unit(12, "cm"),
        barheight      = unit(0.4, "cm"),
        title.position = "top",
        title.hjust    = 0.5
      )
    ) +
    labs(
      title    = if (accumulation == "cumulative")
        paste0("Cumulative mining share (% of ", unit_label, " area)")
      else
        paste0("Annual land conversion to mining (ha) by ", unit_label),
      subtitle = paste0(
        if (accumulation == "cumulative") "New conversions since 2007 — " else "Annual new conversions — ",
        "Barenblitt et al. (2021). Pre-2007 mining excluded."
      ),
      caption  = "Barenblitt SW Ghana survey area. OSM waterways in blue."
    ) +
    theme_void(base_size = 10) +
    theme(
      strip.text      = element_text(face = "bold", size = 9),
      legend.position = "bottom",
      plot.title      = element_text(face = "bold"),
      plot.caption    = element_text(colour = "grey50", size = 7)
    )
}

# 2 units × 2 accumulations = 4 maps
param_grid <- expand.grid(
  unit_name    = names(unit_configs),
  accumulation = c("cumulative", "annual"),
  stringsAsFactors = FALSE
)

for (i in seq_len(nrow(param_grid))) {
  row <- param_grid[i, ]
  cfg <- unit_configs[[row$unit_name]]

  p <- plot_mining_map(
    units_sf     = survey_units[[row$unit_name]],
    ts_long      = cfg$ts_long,
    id_col       = cfg$id_col,
    accumulation = row$accumulation,
    unit_label   = cfg$unit_label,
    regions_sf   = study_regions_sf,
    waterways_sf = waterways_clip
  )

  # Attach Ghana locator inset — top-right corner, overlapping the last facet
  p_final <- p + inset_element(p_inset_ghana,
                                left = 0.88, bottom = 0.05, right = 1.0, top = 0.92,
                                align_to = "plot")

  out_dir <- here("outputs", "figures", "maps", cfg$out_subdir)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  fname <- paste0("d1a_", row$unit_name, "_", row$accumulation, ".png")
  ggsave(file.path(out_dir, fname), p_final, width = 14, height = 10, dpi = 150)
  message("Saved: ", cfg$out_subdir, "/", fname)
}

####4b. D1a — Animated GIFs: Cumulative Mining Extent ####

for (nm in names(unit_configs)) {
  cfg       <- unit_configs[[nm]]
  id_col    <- cfg$id_col
  all_units <- cfg$units_sf |> st_drop_geometry() |> pull(!!sym(id_col))

  plot_data <- cfg$ts_long |>
    complete(!!sym(id_col) := all_units, year = 2007:2017,
             fill = list(area_ha = 0)) |>
    arrange(!!sym(id_col), year) |>
    group_by(!!sym(id_col)) |>
    mutate(cumulative_ha = cumsum(area_ha)) |>
    ungroup() |>
    right_join(survey_units[[nm]], by = id_col) |>
    st_as_sf()

  p_anim <- ggplot(plot_data) +
    geom_sf(aes(fill = cumulative_ha), colour = NA) +
    geom_sf(data = study_regions_sf, fill = NA, colour = "grey40", linewidth = 0.3) +
    geom_sf(data = waterways_clip, colour = "#3B8ED0", linewidth = 0.15, alpha = 0.6) +
    scale_fill_gradientn(
      colours  = c("#FCFDBF", "#FEC287", "#FD9567", "#F1605D", "#CD4071", "#9E2F7F", "#721F81", "#450457"),
      trans    = "sqrt",
      name     = "Area (ha)",
      labels   = label_comma(),
      na.value = "#F0F0F0",
      guide    = guide_colorbar(
        barwidth       = unit(8, "cm"),
        barheight      = unit(0.4, "cm"),
        title.position = "top",
        title.hjust    = 0.5
      )
    ) +
    labs(
      title    = "Cumulative land converted to mining — {closest_state}",
      subtitle = paste0(tools::toTitleCase(cfg$unit_label),
                        " level — Barenblitt et al. (2021). New conversions since 2007."),
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

  out_dir <- here("outputs", "figures", "maps", cfg$out_subdir)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  gif_file <- file.path(out_dir, paste0("d1a_", nm, "_cumulative_animation.gif"))

  animate(
    p_anim,
    nframes  = length(2007:2017) * 4,
    fps      = 4,
    width    = 700,
    height   = 850,
    renderer = gifski_renderer(gif_file)
  )
  message("Saved: maps/", cfg$out_subdir, "/d1a_", nm, "_cumulative_animation.gif")
}

####5. D1b — Artisanal vs Industrial Mining Maps ####

# Two-panel side-by-side choropleth: artisanal (warm palette) | industrial (blue palette)
plot_mining_types_map <- function(
  units_sf,
  extent_data,
  id_col,
  unit_label   = "district",
  country_sf   = NULL,
  regions_sf   = NULL,
  waterways_sf = NULL
) {
  map_data <- units_sf |>
    left_join(
      extent_data |> select(all_of(id_col), Artisanal, Industrial),
      by = id_col
    ) |>
    mutate(across(c(Artisanal, Industrial), \(x) replace_na(x, 0)))

  make_panel <- function(col, colours, title) {
    p <- ggplot(map_data) +
      geom_sf(aes(fill = .data[[col]]), colour = "white", linewidth = 0.1)
    if (!is.null(regions_sf))
      p <- p + geom_sf(data = regions_sf, fill = NA, colour = "grey40", linewidth = 0.25)
    if (!is.null(country_sf))
      p <- p + geom_sf(data = country_sf, fill = NA, colour = "grey15", linewidth = 0.5)
    if (!is.null(waterways_sf))
      p <- p + geom_sf(data = waterways_sf, colour = "#3B8ED0", linewidth = 0.15, alpha = 0.6)
    p +
      scale_fill_gradientn(
        colours  = colours,
        trans    = "sqrt",
        labels   = label_comma(),
        name     = "Area (ha)",
        na.value = "#F9F9F9",
        guide    = guide_colorbar(
          barwidth       = unit(7, "cm"),
          barheight      = unit(0.4, "cm"),
          title.position = "top",
          title.hjust    = 0.5
        )
      ) +
      labs(title = title) +
      theme_void(base_size = 11) +
      theme(
        plot.title      = element_text(face = "bold", size = 11, hjust = 0.5),
        legend.position = "bottom"
      )
  }

  p_art <- make_panel(
    "Artisanal",
    c("#FFFFD4", "#FED98E", "#FE9929", "#D95F0E", "#993404"),
    paste0("Artisanal (galamsey) by ", unit_label)
  )
  p_ind <- make_panel(
    "Industrial",
    c("#EFF3FF", "#BDD7E7", "#6BAED6", "#2171B5", "#084594"),
    paste0("Industrial mining by ", unit_label)
  )

  p_art + p_ind +
    plot_annotation(
      subtitle = "Barenblitt et al. (2021) — full extent 2005–2019",
      caption  = "Barenblitt SW Ghana survey area. OSM waterways in blue.",
      theme    = theme(
        plot.subtitle = element_text(colour = "grey40", size = 9),
        plot.caption  = element_text(colour = "grey50", size = 8)
      )
    )
}

for (nm in names(unit_configs)) {
  cfg <- unit_configs[[nm]]
  p   <- plot_mining_types_map(
    units_sf     = survey_units[[nm]],
    extent_data  = cfg$extent_data,
    id_col       = cfg$id_col,
    unit_label   = cfg$unit_label,
    regions_sf   = study_regions_sf,
    waterways_sf = waterways_clip
  )

  # Attach Ghana locator inset — bottom-right of the composite figure
  p_final <- p + inset_element(p_inset_ghana,
                                left = 0.88, bottom = 0.0, right = 1.0, top = 0.32,
                                align_to = "plot")

  out_dir <- here("outputs", "figures", "maps", cfg$out_subdir)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  fname   <- paste0("d1b_", nm, "_artisanal_vs_industrial.png")
  ggsave(file.path(out_dir, fname), p_final, width = 14, height = 9, dpi = 150)
  message("Saved: ", cfg$out_subdir, "/", fname)
}

####6. D1c — Land-Cover Fraction Time Series ####

# --- 6a. National cumulative fraction (unit-agnostic, produced once) ----------
ghana_total_ha <- sum(unit_areas_districts$unit_ha)

ts_national_frac <- ts_long_districts |>
  group_by(year) |>
  summarise(area_ha = sum(area_ha), .groups = "drop") |>
  arrange(year) |>
  mutate(
    cumulative_ha   = cumsum(area_ha),
    frac_cumulative = cumulative_ha / ghana_total_ha * 100
  )

p_frac_national <- ggplot(ts_national_frac, aes(x = year)) +
  geom_area(aes(y = frac_cumulative), fill = "#E67E22", alpha = 0.5) +
  geom_line(aes(y = frac_cumulative), colour = "#922B21", linewidth = 0.9) +
  geom_point(aes(y = frac_cumulative), colour = "#922B21", size = 2.5) +
  scale_x_continuous(breaks = 2007:2017) +
  scale_y_continuous(
    labels = \(x) paste0(round(x, 3), "%"),
    expand = expansion(mult = c(0, 0.05))
  ) +
  labs(
    title    = "Cumulative land converted to mining — share of Ghana land area",
    subtitle = "New conversions since 2007; district total area as denominator.",
    x = NULL, y = "% of Ghana land area",
    caption  = paste0(
      "Barenblitt et al. (2021). Coverage: SW Ghana — national share is a lower bound.\n",
      "Total district area used as denominator: ",
      format(round(ghana_total_ha), big.mark = ","), " ha."
    )
  ) +
  theme_minimal(base_size = 11) +
  theme(
    axis.text.x  = element_text(angle = 45, hjust = 1),
    plot.caption = element_text(colour = "grey50", size = 8)
  )

dir.create(here("outputs", "figures"), recursive = TRUE, showWarnings = FALSE)
ggsave(here("outputs", "figures", "d1c_national_frac.png"),
       p_frac_national, width = 8, height = 5, dpi = 150)
message("Saved: d1c_national_frac.png")

# --- 6b. District-level: land-share bar + annual flows (hex IDs not meaningful here) ---
for (nm in "districts") {
  cfg        <- unit_configs[[nm]]
  id_col     <- cfg$id_col
  ul         <- cfg$unit_label
  ul_t       <- tools::toTitleCase(ul)
  all_units  <- cfg$units_sf |> st_drop_geometry() |> pull(!!sym(id_col))

  ts_cumulative <- cfg$ts_long |>
    complete(!!sym(id_col) := all_units, year = 2007:2017,
             fill = list(area_ha = 0)) |>
    arrange(!!sym(id_col), year) |>
    group_by(!!sym(id_col)) |>
    mutate(cumulative_ha = cumsum(area_ha)) |>
    ungroup()

  frac_by_unit <- ts_cumulative |>
    filter(year == 2017) |>
    left_join(cfg$unit_areas, by = id_col) |>
    mutate(frac_unit = cumulative_ha / unit_ha * 100) |>
    filter(frac_unit > 0) |>
    slice_max(frac_unit, n = 15)

  p_frac_unit <- frac_by_unit |>
    mutate(!!sym(id_col) := fct_reorder(!!sym(id_col), frac_unit)) |>
    ggplot(aes(x = frac_unit, y = !!sym(id_col))) +
    geom_col(fill = "#E67E22", alpha = 0.85) +
    scale_x_continuous(
      labels = \(x) paste0(round(x, 1), "%"),
      expand = expansion(mult = c(0, 0.05))
    ) +
    labs(
      title    = paste0("Mining land share by ", ul, " (cumulative 2007–2017)"),
      subtitle = paste0("Top 15 ", ul, "s by share of ", ul, " land area converted to mining"),
      x        = paste0("% of ", ul, " land area"), y = NULL,
      caption  = "Barenblitt et al. (2021). New conversions since 2007 only."
    ) +
    theme_minimal(base_size = 11) +
    theme(plot.caption = element_text(colour = "grey50", size = 8))

  top_units <- cfg$ts_long |>
    group_by(!!sym(id_col)) |>
    summarise(total_ha = sum(area_ha), .groups = "drop") |>
    slice_max(total_ha, n = 12) |>
    pull(!!sym(id_col))

  p_ts <- cfg$ts_long |>
    filter(!!sym(id_col) %in% top_units) |>
    mutate(unit = factor(!!sym(id_col), levels = top_units)) |>
    ggplot(aes(x = year, y = area_ha, colour = unit)) +
    geom_line(linewidth = 0.7) +
    geom_point(size = 1.8) +
    scale_x_continuous(breaks = 2007:2017) +
    scale_y_continuous(labels = label_comma()) +
    scale_colour_brewer(palette = "Paired", name = ul_t) +
    labs(
      title    = paste0("Annual land conversion to mining by ", ul, " (2007–2017)"),
      subtitle = paste0("Top 12 ", ul, "s by total converted area — Barenblitt et al. (2021)"),
      x = NULL, y = "Area converted (ha)",
      caption  = "Southern Ghana survey area only."
    ) +
    theme_minimal(base_size = 11) +
    theme(
      legend.position = "right",
      axis.text.x     = element_text(angle = 45, hjust = 1),
      plot.caption    = element_text(colour = "grey50", size = 8)
    )

  out_dir <- here("outputs", "figures")
  ggsave(file.path(out_dir, paste0("d1c_", nm, "_frac_by_unit.png")),
         p_frac_unit, width = 8, height = 6, dpi = 150)
  ggsave(file.path(out_dir, paste0("d1c_", nm, "_ts_top12.png")),
         p_ts, width = 11, height = 6, dpi = 150)
  message("Saved: D1c plots for ", nm)
}

####7. D1d — Summary Statistics ####

# --- 7a. District-level: console summary + top-20 extent bar (hex IDs not meaningful here) ---
for (nm in "districts") {
  cfg    <- unit_configs[[nm]]
  id_col <- cfg$id_col
  ul     <- cfg$unit_label
  ul_t   <- tools::toTitleCase(ul)

  unit_summary <- cfg$units_sf |>
    st_drop_geometry() |>
    left_join(cfg$extent_data, by = id_col) |>
    mutate(across(c(Artisanal, Industrial, Total), \(x) replace_na(x, 0))) |>
    left_join(cfg$unit_areas, by = id_col) |>
    mutate(
      galamsey   = Artisanal > 0,
      any_mining = Total     > 0,
      frac_art   = Artisanal / unit_ha * 100,
      frac_total = Total     / unit_ha * 100
    )

  n_total    <- nrow(unit_summary)
  n_any      <- sum(unit_summary$any_mining)
  n_galamsey <- sum(unit_summary$galamsey)
  total_ha   <- sum(unit_summary$Total)
  art_ha     <- sum(unit_summary$Artisanal)
  ind_ha     <- sum(unit_summary$Industrial)

  cat(sprintf("\n=== Incidence of Galamsey — %s level (Barenblitt 2005–2019) ===\n\n", ul_t))
  cat(sprintf("Ghana %ss (total):                      %d\n",   ul_t, n_total))
  cat(sprintf("%ss with any mining:                    %d  (%.0f%%)\n",
              ul_t, n_any,      n_any      / n_total * 100))
  cat(sprintf("%ss with artisanal (galamsey) mining:   %d  (%.0f%%)\n",
              ul_t, n_galamsey, n_galamsey / n_total * 100))
  cat(sprintf("\nTotal mining extent (2005–2019):  %s ha\n",
              format(round(total_ha), big.mark = ",")))
  cat(sprintf("  Artisanal (galamsey):           %s ha  (%.0f%%)\n",
              format(round(art_ha), big.mark = ","), art_ha / total_ha * 100))
  cat(sprintf("  Industrial:                     %s ha  (%.0f%%)\n",
              format(round(ind_ha), big.mark = ","), ind_ha / total_ha * 100))
  cat(sprintf("\nAmong %ss with galamsey:\n", ul_t))
  cat(sprintf("  Median artisanal extent:  %.0f ha\n",
              median(unit_summary$Artisanal[unit_summary$galamsey])))
  cat(sprintf("  Mean artisanal extent:    %.0f ha\n",
              mean(unit_summary$Artisanal[unit_summary$galamsey])))
  cat(sprintf("  Max artisanal extent:     %.0f ha (%s)\n",
              max(unit_summary$Artisanal),
              unit_summary[[id_col]][which.max(unit_summary$Artisanal)]))

  p_extent <- cfg$extent_data |>
    slice_max(Total, n = 20) |>
    pivot_longer(c(Artisanal, Industrial), names_to = "type", values_to = "area_ha") |>
    mutate(unit = fct_reorder(!!sym(id_col), area_ha, sum)) |>
    ggplot(aes(x = area_ha, y = unit, fill = type)) +
    geom_col() +
    scale_fill_manual(values = c(Artisanal = "#FE9929", Industrial = "#2171B5"),
                      name = "Mine type") +
    scale_x_continuous(labels = label_comma(),
                       expand = expansion(mult = c(0, 0.05))) +
    labs(
      title    = paste0("Total mining extent by ", ul, " (2005–2019)"),
      subtitle = paste0("Top 20 ", ul, "s — Barenblitt et al. (2021)"),
      x = "Area (ha)", y = NULL,
      caption  = "Southern Ghana survey area only. Northern districts not surveyed."
    ) +
    theme_minimal(base_size = 11) +
    theme(
      legend.position = "bottom",
      plot.caption    = element_text(colour = "grey50", size = 8)
    )

  out_dir <- here("outputs", "figures")
  ggsave(file.path(out_dir, paste0("d1d_", nm, "_extent_top20.png")),
         p_extent, width = 9, height = 7, dpi = 150)

  write_csv(unit_summary,
            here("data", "processed",
                 paste0("unit_summary_galamsey_", nm, "_2019.csv")))
  message("Saved: D1d plots + summary CSV for ", nm)
}

# --- 7b. National annual conversions + gold price (produced once) -------------
ts_national <- ts_long_districts |>
  group_by(year) |>
  summarise(area_ha = sum(area_ha), .groups = "drop")

gold_raw <- getSymbols("GC=F", src = "yahoo",
                        from = "2007-01-01", to = "2017-12-31",
                        auto.assign = FALSE)

gold_annual <- Cl(gold_raw) |>
  as.data.frame() |>
  rownames_to_column("date") |>
  setNames(c("date", "price")) |>
  mutate(date = as.Date(date), year = as.integer(format(date, "%Y"))) |>
  filter(!is.na(price)) |>
  group_by(year) |>
  summarise(price = mean(price), .groups = "drop")

coeff <- max(ts_national$area_ha) / max(gold_annual$price)

p_national <- ts_national |>
  left_join(gold_annual, by = "year") |>
  ggplot(aes(x = year)) +
  geom_area(aes(y = area_ha), fill = "#E67E22", alpha = 0.6) +
  geom_line(aes(y = area_ha), colour = "#922B21", linewidth = 0.8) +
  geom_point(aes(y = area_ha), colour = "#922B21", size = 2) +
  geom_line(aes(y = price * coeff),
            colour = "#2C3E50", linewidth = 0.8, linetype = "dashed") +
  geom_point(aes(y = price * coeff),
             colour = "#2C3E50", size = 2, shape = 21, fill = "white") +
  scale_x_continuous(breaks = 2007:2017) +
  scale_y_continuous(
    name     = "Area converted (ha)",
    labels   = label_comma(),
    expand   = expansion(mult = c(0, 0.05)),
    sec.axis = sec_axis(~ . / coeff,
                        name   = "Gold price (USD/oz)",
                        labels = label_comma())
  ) +
  labs(
    title    = "Ghana-wide annual land conversion to mining and gold price",
    subtitle = "Barenblitt et al. (2021); gold price: GC=F futures via Yahoo Finance",
    x = NULL
  ) +
  theme_minimal(base_size = 11) +
  theme(
    axis.text.x        = element_text(angle = 45, hjust = 1),
    axis.title.y.right = element_text(colour = "#2C3E50"),
    axis.text.y.right  = element_text(colour = "#2C3E50")
  )

ggsave(here("outputs", "figures", "d1d_national_gold_price.png"),
       p_national, width = 8, height = 5, dpi = 150)
message("Saved: d1d_national_gold_price.png")

####D1e. Lorenz Curve — Concentration of Galamsey Across Districts ####

lorenz <- extent_districts |>
  arrange(Artisanal) |>
  mutate(
    cum_districts = row_number() / n(),
    cum_mining    = cumsum(Artisanal) / sum(Artisanal)
  )

pct50_n <- lorenz |> filter(cum_mining >= 0.5) |> slice(1) |> pull(cum_districts)
pct80_n <- lorenz |> filter(cum_mining >= 0.8) |> slice(1) |> pull(cum_districts)

p_lorenz <- ggplot(lorenz, aes(x = cum_districts, y = cum_mining)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed",
              colour = "grey60", linewidth = 0.6) +
  geom_line(colour = "#450457", linewidth = 1.1) +
  geom_area(fill = "#450457", alpha = 0.08) +
  annotate("segment",
           x = pct50_n, xend = pct50_n, y = 0,   yend = 0.5,
           linetype = "dotted", colour = "grey40") +
  annotate("segment",
           x = 0,       xend = pct50_n, y = 0.5, yend = 0.5,
           linetype = "dotted", colour = "grey40") +
  annotate("text",
           x = pct50_n + 0.02, y = 0.25,
           label = sprintf("%.0f%% of districts\naccount for 50%%\nof total galamsey",
                           pct50_n * 100),
           hjust = 0, size = 3, colour = "grey30") +
  scale_x_continuous(labels = label_percent(), breaks = breaks_width(0.2),
                     expand = expansion(mult = c(0, 0.01))) +
  scale_y_continuous(labels = label_percent(), breaks = breaks_width(0.2),
                     expand = expansion(mult = c(0, 0.01))) +
  labs(
    title    = "Concentration of galamsey across districts",
    subtitle = sprintf("%.0f%% of districts account for 80%% of total artisanal mining extent",
                       pct80_n * 100),
    x        = "Cumulative share of surveyed districts (sorted by mining extent)",
    y        = "Cumulative share of total artisanal mining (ha)",
    caption  = sprintf("%d surveyed districts, SW Ghana. Barenblitt 2019 artisanal extent.\nDashed line = perfect equality.",
                       nrow(extent_districts))
  ) +
  theme_minimal(base_size = 12) +
  theme(plot.subtitle = element_text(colour = "#450457", face = "bold"))

ggsave(here("outputs", "figures", "motivating_facts", "d_lorenz_district_concentration.png"),
       p_lorenz, width = 7, height = 6, dpi = 150)
message("Saved: d_lorenz_district_concentration.png")
