# d_05_ndvi.R
#Look at NDVI/EVI data — missing value diagnostics
#NDVI data comes from two sources:
#1. Landsat
#   NDVI   — Landsat C02 T1 L2 Annual NDVI composite, 30 m, Ghana, 1995–2025
#            Collection: LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_NDVI
#            → data/raw/landsat_vi/landsat_ndvi_ghana_{year}.tif
#   EVI    — Landsat C02 T1 L2 Annual EVI composite, 30 m, Ghana, 1995–2025
#            Collection: LANDSAT/COMPOSITES/C02/T1_L2_ANNUAL_EVI
#            → data/raw/landsat_vi/landsat_evi_ghana_{year}.tif
#2. MODIS
#5c. MODIS VI — MOD13Q1.061 Terra Vegetation Indices 16-Day 250m
#
# Collection: MODIS/061/MOD13Q1
# Bands:      NDVI, EVI — raw integer * 0.0001 → range [-0.2, 1.0]
# QA:         SummaryQA: 0=good, 1=marginal, 2=snow/ice, 3=cloudy; keep ≤ 1.
# Compositing: d_01 exports the FULL QA-masked 16-day series (modis_{ndvi,evi}_16day_ghana_{yr}.tif,
#   ~23 bands/yr); d_01 Section 9 derives the annual-MEAN stacks read here
#   (modis_{ndvi,evi}_ghana_stack.tif). The 16-day files also feed the peak-EVI pipeline (ESA CCI
#   land-use mask applied per 16-day step → per-hex mean → annual MAX).
# Resolution: 250 m (native MOD13Q1) — finer sibling of MOD13A2 (1 km).

#the third data source is MODIS LandCover
#MODIS Land Cover — MCD12Q1.061 Land Cover Type Yearly 500m
# Collection: MODIS/061/MCD12Q1
# Band:       LC_Type1 — IGBP classification, 17 classes (uint8, no scale factor).
# Key classes for Ghana: 2=tropical forest, 8=woody savanna, 9=savanna,
# 10=grasslands, 12=croplands, 14=cropland/natural vegetation mosaic.
# Already annual — one image per calendar year; first() retrieves it.
# Primary use in d06: cropland mask for Q1 NDVI (restrict NDVI to agricultural
# pixels to isolate the agricultural-welfare channel of upstream mining).
# Resolution: 500 m (native MCD12Q1).

#HERE: we want to get a better understanding of the three data products before use
#we look at missingness patterns and then try to understand

#Load packages
pacman::p_load(here, elevatr, terra, sf, janitor, tidyverse, conflicted, patchwork, leaflet)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)

# Data --------------------------------------------------------------------
# ndvi_stack_path       <- here("data", "raw", "landsat_vi", "landsat_ndvi_ghana_stack.tif")
# evi_stack_path        <- here("data", "raw", "landsat_vi", "landsat_evi_ghana_stack.tif")
modis_ndvi_stack_path <- here("data", "raw", "modis_vi",   "modis_ndvi_ghana_stack.tif")
modis_evi_stack_path  <- here("data", "raw", "modis_vi",   "modis_evi_ghana_stack.tif")

# ndvi       <- terra::rast(ndvi_stack_path)
# evi        <- terra::rast(evi_stack_path)
modis_ndvi <- terra::rast(modis_ndvi_stack_path)
modis_evi  <- terra::rast(modis_evi_stack_path)

# Missing data diagnostics --------------------------------------------------

# terra::global() returns a data frame but column name varies across versions;
# [[1]] extracts the first (only) column safely in all cases.
na_by_year <- function(stk, label) {
  counts <- terra::global(is.na(stk), "sum")[[1]]
  years  <- as.integer(stringr::str_extract(names(stk), "\\d{4}"))
  tibble(
    year     = years,
    na_count = counts,
    total    = terra::ncell(stk),
    pct_na   = round(100 * counts / terra::ncell(stk), 1),
    product  = label
  )
}

na_all <- bind_rows(
  #na_by_year(ndvi,       "Landsat NDVI (250 m)"),
  #na_by_year(evi,        "Landsat EVI (250 m)"),
  na_by_year(modis_ndvi, "MODIS NDVI (250 m)"),
  na_by_year(modis_evi,  "MODIS EVI (250 m)")
)

print(na_all |> select(product, year, na_count, total, pct_na), n = Inf)

# Line chart: % missing by year, all four products
ggplot(na_all, aes(year, pct_na, colour = product)) +
  geom_line() +
  geom_point(size = 1.5) +
  scale_colour_manual(values = c(
    # "Landsat NDVI (250 m)" = "#1b7837",
    # "Landsat EVI (250 m)"  = "#762a83",
    "MODIS NDVI (250 m)"   = "#74c476",
    "MODIS EVI (250 m)"    = "#c994c7"
  )) +
  labs(title = "Missing pixels by year — Landsat & MODIS NDVI / EVI",
       x = NULL, y = "% NA cells", colour = NULL) +
  theme_minimal(base_size = 11) +
  theme(legend.position = "bottom")

# Spatial NA-frequency maps: how many years is each pixel missing?
#n_landsat <- terra::nlyr(ndvi)
n_modis   <- terra::nlyr(modis_ndvi)

# plot(terra::app(is.na(ndvi),       sum), main = sprintf("Landsat NDVI: years with NA (out of %d)", n_landsat))
# plot(terra::app(is.na(evi),        sum), main = sprintf("Landsat EVI: years with NA (out of %d)",  n_landsat))
plot(terra::app(is.na(modis_ndvi), sum), main = sprintf("MODIS NDVI: years with NA (out of %d)",   n_modis))
plot(terra::app(is.na(modis_evi),  sum), main = sprintf("MODIS EVI: years with NA (out of %d)",    n_modis))

# MODIS Land Cover (MCD12Q1) ------------------------------------------------

lc_stack_path <- here("data", "raw", "land_cover", "modis_lc_ghana_stack.tif")
lc_stack      <- terra::rast(lc_stack_path)
lc_years      <- as.integer(stringr::str_extract(names(lc_stack), "\\d{4}"))
message(sprintf("Land cover stack: %d layers (%d–%d)", terra::nlyr(lc_stack), min(lc_years), max(lc_years)))

# Full IGBP LC_Type1 class table with colours
igbp <- tribble(
  ~value, ~label,                         ~colour,
       1, "Evergreen Needleleaf Forest",  "#005a00",
       2, "Evergreen Broadleaf Forest",   "#1a8a1a",
       3, "Deciduous Needleleaf Forest",  "#4dae4d",
       4, "Deciduous Broadleaf Forest",   "#7fbf7b",
       5, "Mixed Forest",                 "#b8e0a8",
       6, "Closed Shrubland",             "#c8a96e",
       7, "Open Shrubland",               "#e0c882",
       8, "Woody Savanna",                "#a6761d",
       9, "Savanna",                      "#d9b365",
      10, "Grassland",                    "#f5f078",
      11, "Permanent Wetland",            "#80cdc1",
      12, "Cropland",                     "#d95f02",
      13, "Urban / Built-up",             "#e31a1c",
      14, "Cropland/Natural Mosaic",      "#fdae61",
      15, "Snow / Ice",                   "#f7f7f7",
      16, "Barren",                       "#bdbdbd",
      17, "Water",                        "#4575b4"
)

# Ghana admin boundary for map overlay
gha_boundary <- st_read(
  here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp"), quiet = TRUE
) |> st_transform(4326)

# Helper: classify → attach factor labels → plot with built-in terra legend.
# Setting levels() before plot(type="classes") lets terra draw the legend
# internally using the label column — more reliable than a manual legend() call.
plot_lc <- function(lc_yr, igbp_tbl, boundary_sf, title) {
  freq_yr  <- terra::freq(lc_yr) |> as_tibble()
  freq_yr  <- freq_yr[!is.na(freq_yr$value), ]
  igbp_sub <- igbp_tbl[igbp_tbl$value %in% freq_yr$value, ]
  igbp_sub <- igbp_sub[order(igbp_sub$value), ]
  lc_rc    <- terra::classify(lc_yr,
                               rcl = cbind(igbp_sub$value, seq_len(nrow(igbp_sub))))
  levels(lc_rc) <- data.frame(value = seq_len(nrow(igbp_sub)),
                               label = igbp_sub$label)
  plot(lc_rc, type = "classes", col = igbp_sub$colour, main = title,
       plg = list(cex = 0.6))
  plot(st_geometry(boundary_sf), add = TRUE, border = "grey20", lwd = 1)
}

# --- Categorical map: 2010 and most recent year (Ghana-wide) ---------------
for (yr in c(2010, max(lc_years))) {
  plot_lc(lc_stack[[which(lc_years == yr)]], igbp, gha_boundary,
          sprintf("MODIS Land Cover %d — Ghana (IGBP LC_Type1, 500 m)", yr))
}

# --- Bar chart: class composition 2019 ------------------------------------
freq_2020 <- terra::freq(lc_stack[[which(lc_years == 2020)]]) |>
  as_tibble() |>
  dplyr::filter(!is.na(value)) |>
  left_join(igbp, by = "value") |>
  mutate(label = fct_reorder(label, count))

ggplot(freq_2020, aes(count, label, fill = colour)) +
  geom_col() +
  scale_fill_identity() +
  labs(title = "Land cover composition — Ghana 2020 (IGBP LC_Type1)",
       x = "Pixel count (500 m pixels)", y = NULL) +
  theme_minimal(base_size = 11)

# --- Time trend: cropland (12) and evergreen broadleaf forest (2) ----------
# Uses base-R subsetting to avoid dplyr::filter / stats::filter conflict.
trend <- map_dfr(seq_along(lc_years), \(i) {
  f <- terra::freq(lc_stack[[i]]) |> as_tibble()
  f <- f[!is.na(f$value), ]
  tibble(
    year          = lc_years[i],
    crop_pixels   = sum(f$count[f$value == 12]),
    forest_pixels = sum(f$count[f$value == 2])
  )
})

trend |>
  pivot_longer(c(crop_pixels, forest_pixels), names_to = "class", values_to = "pixels") |>
  mutate(class = recode(class,
                        crop_pixels   = "Cropland (class 12)",
                        forest_pixels = "Evergreen Broadleaf (class 2)")) |>
  ggplot(aes(year, pixels, colour = class)) +
  geom_line() +
  geom_point(size = 1.5) +
  scale_colour_manual(values = c("Cropland (class 12)"            = "#d95f02",
                                  "Evergreen Broadleaf (class 2)" = "#1a8a1a")) +
  labs(title = "Cropland and forest cover over time — Ghana (MODIS MCD12Q1)",
       x = NULL, y = "Pixel count (500 m)", colour = NULL) +
  theme_minimal(base_size = 11) +
  theme(legend.position = "bottom")

# MODIS Land Cover — Ankobra basin ------------------------------------------
# Boundary: filter OSM waterways for features named "Ankobra", union the line
# segments, take the convex hull, then buffer 20 km to approximate catchment
# width. This gives a hydrologically meaningful polygon rather than the d03
# hex-grid bounding box.

waterways_path <- here("data", "raw", "shapefiles", "osm_waterways", "waterways_lines.shp")

waterways_4326 <- st_read(waterways_path, quiet = TRUE) |>
  clean_names() |>
  st_make_valid() |>
  st_transform(4326)

# Guard: name field might be absent in some OSM exports
if (!"name" %in% names(waterways_4326)) stop("No 'name' column in waterways shapefile.")

ankobra_river <- waterways_4326 |>
  dplyr::filter(stringr::str_detect(coalesce(name, ""), stringr::regex("ankobra", ignore_case = TRUE)))

message(sprintf("Ankobra river: %d OSM segments, %.0f km total",
                nrow(ankobra_river),
                sum(as.numeric(st_length(st_transform(ankobra_river, 32630)))) / 1000))

# Convex hull of river line(s) + 20 km buffer (in UTM30N for metric buffering)
ankobra_basin <- ankobra_river |>
  st_union() |>
  st_convex_hull() |>
  st_transform(32630) |>
  st_buffer(20000) |>
  st_transform(4326) |>
  st_as_sf()

# Crop LC stack to bbox, then mask to basin polygon
lc_anko <- terra::mask(
  terra::crop(lc_stack, terra::vect(ankobra_basin)),
  terra::vect(ankobra_basin)
)

# --- Maps: 2005 and 2020 side by side (ggplot2 + patchwork) ----------------
# Classes present in EITHER year → shared legend so both maps are comparable.
vals_union <- base::union(
  { f <- terra::freq(lc_anko[[which(lc_years == 2005)]]); f$value[!is.na(f$value)] },
  { f <- terra::freq(lc_anko[[which(lc_years == 2020)]]); f$value[!is.na(f$value)] }
)
igbp_sub <- igbp[igbp$value %in% vals_union, ]
igbp_sub <- igbp_sub[order(igbp_sub$value), ]
col_scale <- scale_fill_manual(
  values = setNames(igbp_sub$colour, igbp_sub$label), name = NULL
)

# ggplot2 LC map builder — raster as data frame, sf overlays via geom_sf()
map_lc_gg <- function(lc_yr, igbp_sub, river_sf, basin_sf, title) {
  df <- as.data.frame(lc_yr, xy = TRUE, na.rm = TRUE)
  colnames(df) <- c("x", "y", "value")
  df <- merge(df, igbp_sub[, c("value", "label")], by = "value", all.x = TRUE)

  ggplot() +
    geom_raster(data = df, aes(x, y, fill = label)) +
    col_scale +
    geom_sf(data = basin_sf, fill = NA, colour = "grey30", linewidth = 0.4,
            inherit.aes = FALSE) +
    geom_sf(data = river_sf, colour = "#4575b4", linewidth = 0.8,
            inherit.aes = FALSE) +
    coord_sf() +
    labs(title = title, x = NULL, y = NULL) +
    theme_void(base_size = 9) +
    theme(plot.title      = element_text(size = 9, face = "bold", hjust = 0.5),
          legend.text     = element_text(size = 7),
          legend.key.size = unit(0.4, "cm"))
}

p_2005 <- map_lc_gg(lc_anko[[which(lc_years == 2005)]], igbp_sub,
                     ankobra_river, ankobra_basin, "2005")
p_2020 <- map_lc_gg(lc_anko[[which(lc_years == 2020)]], igbp_sub,
                     ankobra_river, ankobra_basin, "2020")

(p_2005 + p_2020) +
  plot_layout(guides = "collect") +
  plot_annotation(
    title   = "MODIS Land Cover — Ankobra basin (IGBP LC_Type1, 500 m)",
    theme   = theme(plot.title = element_text(size = 11, face = "bold"))
  ) &
  theme(legend.position = "bottom")

# --- Bar chart: class composition 2019 -------------------------------------
freq_anko_2019 <- terra::freq(lc_anko[[which(lc_years == 2019)]]) |>
  as_tibble() |>
  dplyr::filter(!is.na(value)) |>
  left_join(igbp, by = "value") |>
  mutate(label = fct_reorder(label, count))

ggplot(freq_anko_2019, aes(count, label, fill = colour)) +
  geom_col() +
  scale_fill_identity() +
  labs(title = "Land cover composition — Ankobra basin 2019 (IGBP LC_Type1)",
       x = "Pixel count (500 m pixels)", y = NULL) +
  theme_minimal(base_size = 11)

# --- Time trend: four key classes within the basin -------------------------
trend_classes <- tibble(
  value  = c(2L, 8L, 9L, 12L),
  label  = c("Evergreen Broadleaf Forest", "Woody Savanna", "Savanna", "Cropland"),
  colour = c("#1a8a1a",                    "#a6761d",       "#d9b365", "#d95f02")
)

trend_anko <- map_dfr(seq_along(lc_years), \(i) {
  f <- terra::freq(lc_anko[[i]]) |> as_tibble()
  f <- f[!is.na(f$value), ]
  map_dfr(seq_len(nrow(trend_classes)), \(j) {
    tibble(year   = lc_years[i],
           value  = trend_classes$value[j],
           pixels = sum(f$count[f$value == trend_classes$value[j]]))
  })
}) |>
  merge(trend_classes, by = "value")

ggplot(trend_anko, aes(year, pixels, colour = label)) +
  geom_line() +
  geom_point(size = 1.5) +
  scale_colour_manual(
    values = setNames(trend_classes$colour, trend_classes$label), name = NULL
  ) +
  labs(title = "Land cover trends — Ankobra basin (MODIS MCD12Q1)",
       x = NULL, y = "Pixel count (500 m)") +
  theme_minimal(base_size = 11) +
  theme(legend.position = "bottom")

# Forestcrop missingness — why are the *_forestcrop VI columns mostly NA? --------
# The *_forestcrop columns of the event panel are built in 2_build/b_03a_vi_panel.R: each VI is masked
# to IGBP class 2 (Evergreen Broadleaf Forest) pixels only, then averaged per hex. They are ~80% NA at
# 5 km (and higher at 1/2 km). Two independent causes, quantified below:
#   CAUSE 1 — temporal coverage. forestcrop needs a land-cover layer for that year; years with no
#             layer are 100% NA regardless of geography.
#   CAUSE 2 — spatial rarity. Class 2 is a small, shrinking share of the study area, so most hexes
#             hold NO class-2 pixel in a given year -> the forest-masked hex mean is NaN -> NA.

fc_cache <- here("data", "processed", "hex_5km_crosssection.rds")
if (file.exists(fc_cache)) {

  hexv   <- terra::vect(st_transform(readRDS(fc_cache)$hex_sf, 4326))
  lc_st  <- terra::crop(lc_stack, terra::ext(hexv))       # bbox crop includes some sea (class 17 = water)
  mod_t  <- terra::crop(modis_ndvi[[1]], terra::ext(hexv))
  lc_res <- terra::resample(lc_st, mod_t, method = "near")  # onto the MODIS VI grid (matches *_modis_forestcrop)

  # --- CAUSE 1: coverage gap between the VI span and the land-cover span ---
  vi_span <- as.integer(stringr::str_extract(names(modis_ndvi), "\\d{4}"))
  gap_yrs <- base::setdiff(min(vi_span):max(vi_span), lc_years)
  message("\n=== Forestcrop CAUSE 1: temporal coverage ===")
  message(sprintf("  Land cover available: %d-%d (%d layers)",
                  min(lc_years), max(lc_years), length(lc_years)))
  message(sprintf("  MODIS VI span: %d-%d", min(vi_span), max(vi_span)))
  message(sprintf("  VI years with NO land-cover mask -> forestcrop 100%% NA: %s",
                  paste(gap_yrs, collapse = ", ")))
  message("  NOTE: the stack ends at ", max(lc_years),
          " although d_01_download_gee.R requests LCOVER_YEARS = 2001:2024 — the ",
          "2021-2024 land-cover layers appear to be missing from modis_lc_ghana_stack.tif ",
          "(re-download + re-stack in d_01 Sec 8 to recover those forestcrop years).")

  # --- CAUSE 2: class-2 share of land pixels + % of hexes holding any class-2 pixel, by year ---
  fc_diag <- purrr::map_dfr(seq_along(lc_years), function(i) {
    cl2  <- terra::ifel(lc_res[[i]] == 2L, 1L, NA)
    cnt  <- terra::extract(cl2, hexv, fun = sum, na.rm = TRUE, ID = FALSE)[[1]]  # NA for a hex with no class-2 pixel
    land <- terra::freq(lc_res[[i]]); land <- land[!is.na(land$value) & land$value != 17L, ]
    tibble(year                  = lc_years[i],
           class2_pct_land       = round(100 * sum(land$count[land$value == 2]) / sum(land$count), 1),
           hexes_with_forest_pct = round(100 * mean(!is.na(cnt) & cnt > 0), 1),
           forestcrop_na_pct     = round(100 * mean(is.na(cnt) | cnt == 0), 1))
  })
  message("\n=== Forestcrop CAUSE 2: Evergreen Broadleaf Forest rarity (MODIS grid, 5 km hexes) ===")
  print(as.data.frame(fc_diag), row.names = FALSE)
  message(sprintf(
    paste0("  Only ~%.0f%% of 5 km hexes contain any class-2 pixel (falling %.0f%% -> %.0f%% as forest ",
           "is lost),\n  so ~%.0f%% of hex-years are NA even within the covered years — on top of the ",
           "all-NA years above."),
    mean(fc_diag$hexes_with_forest_pct), fc_diag$hexes_with_forest_pct[1],
    fc_diag$hexes_with_forest_pct[nrow(fc_diag)], mean(fc_diag$forestcrop_na_pct)))

  p_fc <- ggplot(fc_diag, aes(year)) +
    geom_col(aes(y = hexes_with_forest_pct), fill = "#1a8a1a", alpha = 0.85) +
    geom_line(aes(y = class2_pct_land), colour = "#c0392b", linewidth = 0.9) +
    geom_point(aes(y = class2_pct_land), colour = "#c0392b", size = 1.6) +
    labs(title    = "Why *_forestcrop is mostly NA: Evergreen Broadleaf Forest is rare and shrinking",
         subtitle = sprintf(paste0("Green bars = %% of 5 km hexes with >=1 class-2 pixel (NA if none); ",
                                    "red = class-2 %% of land pixels.\nOutside %d-%d every hex is NA ",
                                    "(no land-cover mask)."), min(lc_years), max(lc_years)),
         x = NULL, y = "%") +
    theme_minimal(base_size = 11) +
    theme(plot.title = element_text(face = "bold"))
  print(p_fc)

  dir.create(here("outputs", "figures", "ndvi"), recursive = TRUE, showWarnings = FALSE)
  ggsave(here("outputs", "figures", "ndvi", "forestcrop_missingness.png"), p_fc,
         width = 8, height = 5, dpi = 150)
  message("Saved: outputs/figures/ndvi/forestcrop_missingness.png")

} else {
  message("Forestcrop diagnostics skipped — hex_5km_crosssection.rds not found (run b_01_cross_section.R).")
}

# Forestcrop mask-definition comparison — Ankobra basin only --------------------
# The event-panel *_forestcrop columns (b_03a_vi_panel.R) mask each VI layer to a SINGLE IGBP
# class — class 2, Evergreen Broadleaf Forest — before averaging per hex. A hex is NA in a year
# unless it holds >=1 pixel of the mask class, so the narrow class-2 definition drives most of the
# missingness (CAUSE 2 above). Here we test, for the Ankobra basin's 5 km hexes, how the hex-year
# NA rate would change under broader outcome-mask definitions we are considering:
#   forest      = IGBP 1-5   (all forest types, not just evergreen broadleaf)
#   cropland    = IGBP 12,14 (cropland + cropland/natural-vegetation mosaic)
#   forest+crop = union of the two
# each compared against the current class-2-only baseline. Same machinery as fc_diag: mask VI to
# the class set, a hex with no in-mask pixel -> forest-masked mean is NaN -> NA.

mask_defs <- list(
  "class2 (current)"        = 2L,
  "forest (1-5)"            = 1:5,
  "cropland (12,14)"        = c(12L, 14L),
  "forest+crop (1-5,12,14)" = c(1:5, 12L, 14L)
)

fc_hex_cache <- here("data", "processed", "hex_5km_crosssection.rds")
if (file.exists(fc_hex_cache) && exists("ankobra_basin")) {

  # 5 km hexes intersecting the Ankobra basin polygon
  hex_anko_sf <- st_transform(readRDS(fc_hex_cache)$hex_sf, 4326)
  hex_anko_sf <- hex_anko_sf[st_intersects(hex_anko_sf, ankobra_basin, sparse = FALSE)[, 1], ]
  hex_anko_v  <- terra::vect(hex_anko_sf)
  message(sprintf("\n=== Ankobra basin forestcrop mask comparison: %d of the 5 km hexes intersect the basin ===",
                  nrow(hex_anko_sf)))

  # LC resampled onto the MODIS VI grid over the basin (matches *_modis_forestcrop build)
  vi_tmpl_anko <- terra::crop(modis_ndvi[[1]], terra::ext(hex_anko_v))
  lc_anko_res  <- terra::resample(terra::crop(lc_stack, terra::ext(hex_anko_v)),
                                  vi_tmpl_anko, method = "near")

  # Per definition x year: % of basin hexes with NO in-mask pixel -> forestcrop VI is NA
  na_rate_hex <- function(classes) {
    purrr::map_dfr(seq_along(lc_years), function(i) {
      m   <- terra::ifel(lc_anko_res[[i]] %in% classes, 1L, NA)
      cnt <- terra::extract(m, hex_anko_v, fun = sum, na.rm = TRUE, ID = FALSE)[[1]]  # NA/0 = no in-mask pixel
      tibble(year = lc_years[i], na_pct = round(100 * mean(is.na(cnt) | cnt == 0), 1))
    })
  }

  fc_defs <- purrr::imap_dfr(mask_defs, \(cls, nm) na_rate_hex(cls) |> mutate(definition = nm)) |>
    mutate(definition = factor(definition, levels = names(mask_defs)))

  # Summary: mean / range of the hex-year NA rate across covered years, per definition
  fc_defs_summary <- fc_defs |>
    group_by(definition) |>
    summarise(mean_na_pct = round(mean(na_pct), 1),
              min_na_pct  = min(na_pct),
              max_na_pct  = max(na_pct), .groups = "drop")
  message("Hex-year NA rate by mask definition (covered LC years only; excludes 100%-NA gap years):")
  print(as.data.frame(fc_defs_summary), row.names = FALSE)

  p_fc_defs <- ggplot(fc_defs, aes(year, na_pct, colour = definition)) +
    geom_line(linewidth = 0.8) +
    geom_point(size = 1.4) +
    scale_colour_manual(values = c(
      "class2 (current)"        = "#c0392b",
      "forest (1-5)"            = "#1a8a1a",
      "cropland (12,14)"        = "#d95f02",
      "forest+crop (1-5,12,14)" = "#6a51a3")) +
    labs(title    = "Ankobra basin: forestcrop NA rate shrinks as the land-cover mask broadens",
         subtitle = "% of basin 5 km hexes with no in-mask pixel in that year (=> forestcrop VI is NA)",
         x = NULL, y = "% hex-years NA", colour = "mask definition") +
    theme_minimal(base_size = 11) +
    theme(legend.position = "bottom", plot.title = element_text(face = "bold"))
  print(p_fc_defs)

  dir.create(here("outputs", "figures", "ndvi"), recursive = TRUE, showWarnings = FALSE)
  ggsave(here("outputs", "figures", "ndvi", "forestcrop_maskdefs_ankobra.png"),
         p_fc_defs, width = 8, height = 5, dpi = 150)
  message("Saved: outputs/figures/ndvi/forestcrop_maskdefs_ankobra.png")

} else {
  message("Ankobra mask-definition diagnostics skipped — need hex_5km_crosssection.rds and the ankobra_basin object.")
}


# ESA CCI Land Cover (Defourny et al. 2024) — parallel to the MODI --------
# Fourth data product. ESA/C3S Climate Change Initiative annual land cover, 300 m, UN-LCCS legend
# (codes 10–220), 1995–2022. Downloaded from Digital Earth Africa (DE Africa STAC) via
# code/0_data/download_land_cover_ghana.ipynb and stacked in d_01 Sec 9 → cci_landcover_ghana_stack.tif.
# We reproduce the MODIS-LC diagnostics here (national maps, composition, trends, Ankobra basin) to
# understand the CCI classification before using it as the peak-EVI outcome mask in b_03a. Two things
# to learn vs MODIS: (a) the finer 300 m grid and (b) the more granular forest/cropland split — CCI
# separates evergreen (50) / deciduous (60/62) tree cover and rainfed cropland (10) from mosaics
# (30/40), which is exactly what the forestcrop / cropland outcome masks need.

cci_stack_path <- here("data", "raw", "land_cover", "esa", "cci_landcover_ghana_stack.tif")

if (file.exists(cci_stack_path)) {

  cci_stack <- terra::rast(cci_stack_path)
  cci_years <- as.integer(stringr::str_extract(names(cci_stack), "\\d{4}"))
  message(sprintf("\nESA CCI stack: %d layers (%d–%d), %.0f m res",
                  terra::nlyr(cci_stack), min(cci_years), max(cci_years),
                  mean(terra::res(cci_stack)) * 111320))

  # Full UN-LCCS class table with the official ESA CCI colours (only Ghana-relevant rows plotted).
  cci <- tribble(
    ~value, ~label,                                ~colour,
        10, "Cropland, rainfed",                   "#ffff64",
        11, "Cropland, rainfed, herbaceous",       "#ffff64",
        12, "Cropland, rainfed, tree/shrub",       "#ffff00",
        20, "Cropland, irrigated",                 "#aaf0f0",
        30, "Mosaic cropland >50% / nat. veg.",    "#dcf064",
        40, "Mosaic nat. veg. >50% / cropland",    "#c8c864",
        50, "Tree cover, broadleaf evergreen",     "#006400",
        60, "Tree cover, broadleaf deciduous",     "#00a000",
        61, "Tree cover, broadleaf decid. closed", "#00a000",
        62, "Tree cover, broadleaf decid. open",   "#aac800",
        70, "Tree cover, needleleaf evergreen",    "#003c00",
        90, "Tree cover, mixed leaf",              "#788200",
       100, "Mosaic tree & shrub >50% / herb.",    "#8ca000",
       110, "Mosaic herbaceous >50% / tree-shrub", "#be9600",
       120, "Shrubland",                           "#966400",
       121, "Shrubland, evergreen",                "#964b00",
       122, "Shrubland, deciduous",                "#966400",
       130, "Grassland",                           "#ffb432",
       140, "Lichens and mosses",                  "#ffdcd2",
       150, "Sparse vegetation",                   "#ffebaf",
       160, "Tree cover, flooded, fresh water",    "#00785a",
       170, "Tree cover, flooded, saline water",   "#009678",
       180, "Shrub / herbaceous, flooded",         "#00dc82",
       190, "Urban areas",                         "#c31400",
       200, "Bare areas",                          "#fff5d7",
       201, "Consolidated bare areas",             "#dcdcdc",
       202, "Unconsolidated bare areas",           "#fff5d7",
       210, "Water bodies",                        "#0046c8",
       220, "Permanent snow and ice",              "#ffffff"
  )

  # --- Categorical map: 2010 and most recent year (Ghana-wide) -----------------
  # Reuses the generic plot_lc() defined for MODIS (takes any value/label/colour table).
  for (yr in c(2010, max(cci_years))) {
    plot_lc(cci_stack[[which(cci_years == yr)]], cci, gha_boundary,
            sprintf("ESA CCI Land Cover %d — Ghana (UN-LCCS, 300 m)", yr))
  }

  # --- Bar chart: class composition 2020 --------------------------------------
  freq_cci_2020 <- terra::freq(cci_stack[[which(cci_years == 2020)]]) |>
    as_tibble() |>
    dplyr::filter(!is.na(value)) |>
    left_join(cci, by = "value") |>
    mutate(label = fct_reorder(label, count))

  print(
    ggplot(freq_cci_2020, aes(count, label, fill = colour)) +
      geom_col() +
      scale_fill_identity() +
      labs(title = "Land cover composition — Ghana 2020 (ESA CCI, UN-LCCS)",
           x = "Pixel count (300 m pixels)", y = NULL) +
      theme_minimal(base_size = 11)
  )

  # --- Time trend: aggregated CCI class groups (Ghana-wide) --------------------
  # CCI splits forest and cropland finely; aggregate to comparable groups so the trend is legible.
  cci_groups <- list(
    "Cropland (10,11,20)"      = c(10L, 11L, 20L),
    "Cropland mosaic (30,40)"  = c(30L, 40L),
    "Forest (50,60,61,62)"     = c(50L, 60L, 61L, 62L),
    "Shrubland (120,121,122)"  = c(120L, 121L, 122L)
  )
  cci_grp_cols <- c("Cropland (10,11,20)"     = "#d95f02",
                    "Cropland mosaic (30,40)" = "#dcb064",
                    "Forest (50,60,61,62)"    = "#1a8a1a",
                    "Shrubland (120,121,122)" = "#966400")

  trend_by_groups <- function(stk, yrs, groups) {
    map_dfr(seq_along(yrs), \(i) {
      f <- terra::freq(stk[[i]]) |> as_tibble(); f <- f[!is.na(f$value), ]
      map_dfr(names(groups), \(nm)
        tibble(year = yrs[i], group = nm,
               pixels = sum(f$count[f$value %in% groups[[nm]]])))
    })
  }

  cci_trend <- trend_by_groups(cci_stack, cci_years, cci_groups)
  print(
    ggplot(cci_trend, aes(year, pixels, colour = group)) +
      geom_line() + geom_point(size = 1.4) +
      scale_colour_manual(values = cci_grp_cols, name = NULL) +
      labs(title = "Land cover over time — Ghana (ESA CCI, UN-LCCS)",
           x = NULL, y = "Pixel count (300 m)") +
      theme_minimal(base_size = 11) +
      theme(legend.position = "bottom")
  )

  # --- ESA CCI — Ankobra basin ------------------------------------------------
  # Reuses ankobra_basin / ankobra_river built in the MODIS-LC section above.
  if (exists("ankobra_basin")) {
    cci_anko <- terra::mask(
      terra::crop(cci_stack, terra::vect(ankobra_basin)),
      terra::vect(ankobra_basin)
    )

    # Shared legend across 2005 & 2020 (classes present in either year)
    vals_union_cci <- base::union(
      { f <- terra::freq(cci_anko[[which(cci_years == 2005)]]); f$value[!is.na(f$value)] },
      { f <- terra::freq(cci_anko[[which(cci_years == 2020)]]); f$value[!is.na(f$value)] }
    )
    cci_sub <- cci[cci$value %in% vals_union_cci, ]
    cci_sub <- cci_sub[order(cci_sub$value), ]
    # map_lc_gg() (defined above) reads `col_scale` from the enclosing env — repoint it at the CCI legend.
    col_scale <- scale_fill_manual(values = setNames(cci_sub$colour, cci_sub$label), name = NULL)

    p_cci_2005 <- map_lc_gg(cci_anko[[which(cci_years == 2005)]], cci_sub,
                            ankobra_river, ankobra_basin, "2005")
    p_cci_2020 <- map_lc_gg(cci_anko[[which(cci_years == 2020)]], cci_sub,
                            ankobra_river, ankobra_basin, "2020")
    print(
      (p_cci_2005 + p_cci_2020) +
        plot_layout(guides = "collect") +
        plot_annotation(
          title = "ESA CCI Land Cover — Ankobra basin (UN-LCCS, 300 m)",
          theme = theme(plot.title = element_text(size = 11, face = "bold"))
        ) &
        theme(legend.position = "bottom")
    )

    # Basin composition 2019
    freq_cci_anko_2019 <- terra::freq(cci_anko[[which(cci_years == 2019)]]) |>
      as_tibble() |>
      dplyr::filter(!is.na(value)) |>
      left_join(cci, by = "value") |>
      mutate(label = fct_reorder(label, count))
    print(
      ggplot(freq_cci_anko_2019, aes(count, label, fill = colour)) +
        geom_col() + scale_fill_identity() +
        labs(title = "Land cover composition — Ankobra basin 2019 (ESA CCI)",
             x = "Pixel count (300 m pixels)", y = NULL) +
        theme_minimal(base_size = 11)
    )

    # Basin trend — same aggregated groups
    cci_trend_anko <- trend_by_groups(cci_anko, cci_years, cci_groups)
    print(
      ggplot(cci_trend_anko, aes(year, pixels, colour = group)) +
        geom_line() + geom_point(size = 1.4) +
        scale_colour_manual(values = cci_grp_cols, name = NULL) +
        labs(title = "Land cover trends — Ankobra basin (ESA CCI)",
             x = NULL, y = "Pixel count (300 m)") +
        theme_minimal(base_size = 11) +
        theme(legend.position = "bottom")
    )
  } else {
    message("ESA CCI Ankobra maps skipped — ankobra_basin not in scope (run the MODIS-LC section first).")
  }

  # --- Forest/cropland-mask coverage on the 5 km hex grid (CCI vs MODIS) -------
  # The peak-EVI outcome masks each 16-day VI composite to CCI forest / cropland classes before the
  # per-hex mean. As with MODIS *_forestcrop, a hex is NA in a year with no in-mask pixel. Quantify
  # the hex-year NA rate under the candidate CCI mask definitions so we can see how much the finer
  # 300 m CCI grid reduces the ~80% forestcrop missingness we get from MODIS class 2.
  cci_mask_defs <- list(
    "forest (50,60,61,62)"          = c(50L, 60L, 61L, 62L),
    "cropland (10,11,20)"           = c(10L, 11L, 20L),
    "cropland+mosaic (10,11,20,30)" = c(10L, 11L, 20L, 30L),
    "forest+crop"                   = c(50L, 60L, 61L, 62L, 10L, 11L, 20L)
  )
  cci_hex_cache <- here("data", "processed", "hex_5km_crosssection.rds")
  if (file.exists(cci_hex_cache)) {
    hexv_cci <- terra::vect(st_transform(readRDS(cci_hex_cache)$hex_sf, 4326))
    # CCI resampled onto the MODIS VI grid over the hex bbox (matches the b_03a mask build)
    mod_t_cci  <- terra::crop(modis_ndvi[[1]], terra::ext(hexv_cci))
    cci_res    <- terra::resample(terra::crop(cci_stack, terra::ext(hexv_cci)), mod_t_cci, method = "near")
    cci_res_yr <- as.integer(stringr::str_extract(names(cci_res), "\\d{4}"))

    na_rate_cci <- function(classes) {
      map_dfr(seq_along(cci_res_yr), \(i) {
        m   <- terra::ifel(cci_res[[i]] %in% classes, 1L, NA)
        cnt <- terra::extract(m, hexv_cci, fun = sum, na.rm = TRUE, ID = FALSE)[[1]]
        tibble(year = cci_res_yr[i], na_pct = round(100 * mean(is.na(cnt) | cnt == 0), 1))
      })
    }
    cci_defs <- purrr::imap_dfr(cci_mask_defs, \(cls, nm) na_rate_cci(cls) |> mutate(definition = nm)) |>
      mutate(definition = factor(definition, levels = names(cci_mask_defs)))
    cci_defs_summary <- cci_defs |>
      group_by(definition) |>
      summarise(mean_na_pct = round(mean(na_pct), 1),
                min_na_pct = min(na_pct), max_na_pct = max(na_pct), .groups = "drop")
    message("\n=== ESA CCI mask coverage: hex-year NA rate by definition (5 km hexes, all Ghana) ===")
    print(as.data.frame(cci_defs_summary), row.names = FALSE)

    p_cci_defs <- ggplot(cci_defs, aes(year, na_pct, colour = definition)) +
      geom_line(linewidth = 0.8) + geom_point(size = 1.3) +
      labs(title    = "ESA CCI outcome-mask coverage on the 5 km hex grid",
           subtitle = "% of 5 km hexes with no in-mask pixel that year (=> masked peak-VI would be NA)",
           x = NULL, y = "% hex-years NA", colour = "mask definition") +
      theme_minimal(base_size = 11) +
      theme(legend.position = "bottom", plot.title = element_text(face = "bold"))
    print(p_cci_defs)

    dir.create(here("outputs", "figures", "ndvi"), recursive = TRUE, showWarnings = FALSE)
    ggsave(here("outputs", "figures", "ndvi", "cci_maskdefs_hex5km.png"),
           p_cci_defs, width = 8, height = 5, dpi = 150)
    message("Saved: outputs/figures/ndvi/cci_maskdefs_hex5km.png")
  } else {
    message("ESA CCI mask-coverage diagnostic skipped — hex_5km_crosssection.rds not found.")
  }

} else {
  message("ESA CCI section skipped — cci_landcover_ghana_stack.tif not found. Run d_01 Sec 9 to build it.")
}


#Interactive leaflet map — ESA CCI land classes, Ankobra basin, 2
# Same content as the static patchwork maps above, but interactive: switch between a CartoDB and a
# satellite basemap (baseGroups radio), toggle the 2005 / 2020 CCI classification plus the Ankobra
# river & basin outline (overlay checkboxes), and CLICK any land-cover patch to read its class.
# Reuses cci_anko / cci_sub / cci_years / ankobra_river / ankobra_basin built in the ESA CCI section
# above (top-level `if` blocks don't create scope, so these persist when sourced).
if (all(sapply(c("cci_anko", "cci_sub", "cci_years", "ankobra_river", "ankobra_basin"), exists))) {

  r_2005 <- cci_anko[[which(cci_years == 2005)]]
  r_2020 <- cci_anko[[which(cci_years == 2020)]]

  # addRasterImage renders a flat PNG that carries no per-pixel data, so it can't report a class on
  # click. Instead vectorise each year (dissolve = TRUE merges contiguous same-class cells into one
  # multipolygon per class -> a handful of features, cheap to render) and draw those as polygons with
  # popups. Visually equivalent to the raster (filled class regions), but every patch is now clickable.
  cci_to_poly <- function(r) {
    p <- sf::st_as_sf(terra::as.polygons(r, dissolve = TRUE))
    names(p)[1] <- "value"                                   # first attribute = the CCI class code
    dplyr::left_join(p, cci_sub[, c("value", "label", "colour")], by = "value")
  }
  poly_2005 <- cci_to_poly(r_2005)
  poly_2020 <- cci_to_poly(r_2020)

  # Popup on click (class name + code) and a lightweight hover label.
  cci_popup  <- function(p) paste0("<b>", p$label, "</b><br>ESA CCI class code: ", p$value)
  cci_hover  <- function(p) lapply(p$label, htmltools::HTML)

  cci_leaflet <- leaflet::leaflet() |>
    leaflet::addProviderTiles(leaflet::providers$CartoDB.Positron,  group = "CartoDB") |>
    leaflet::addProviderTiles(leaflet::providers$Esri.WorldImagery, group = "Satellite") |>
    leaflet::addPolygons(data = poly_2005, fillColor = ~colour, fillOpacity = 0.8,
                         weight = 0, smoothFactor = 0.2, group = "2005 land cover",
                         label = cci_hover(poly_2005), popup = cci_popup(poly_2005),
                         highlightOptions = leaflet::highlightOptions(
                           weight = 2, color = "#000000", fillOpacity = 0.9, bringToFront = TRUE)) |>
    leaflet::addPolygons(data = poly_2020, fillColor = ~colour, fillOpacity = 0.8,
                         weight = 0, smoothFactor = 0.2, group = "2020 land cover",
                         label = cci_hover(poly_2020), popup = cci_popup(poly_2020),
                         highlightOptions = leaflet::highlightOptions(
                           weight = 2, color = "#000000", fillOpacity = 0.9, bringToFront = TRUE)) |>
    leaflet::addPolygons(data = ankobra_basin, fill = FALSE, color = "#444444",
                         weight = 1.5, group = "Basin outline") |>
    leaflet::addPolylines(data = ankobra_river, color = "#2b6cb0", weight = 2,
                          opacity = 0.9, group = "Ankobra river") |>
    leaflet::addLegend(colors = cci_sub$colour, labels = cci_sub$label,
                       title = "ESA CCI land cover", opacity = 0.9, position = "bottomright") |>
    leaflet::addLayersControl(
      baseGroups    = c("CartoDB", "Satellite"),
      overlayGroups = c("2005 land cover", "2020 land cover", "Ankobra river", "Basin outline"),
      options       = leaflet::layersControlOptions(collapsed = FALSE)
    ) |>
    # Show 2005 by default; user ticks 2020 to compare (avoids the two years overlapping at load).
    leaflet::hideGroup("2020 land cover")
  print(cci_leaflet)

  # Persist as a standalone HTML (interactive maps don't survive the RStudio viewer session).
  if (requireNamespace("htmlwidgets", quietly = TRUE)) {
    dir.create(here("outputs", "figures", "ndvi"), recursive = TRUE, showWarnings = FALSE)
    out_html <- here("outputs", "figures", "ndvi", "cci_ankobra_leaflet_2005_2020.html")
    htmlwidgets::saveWidget(cci_leaflet, out_html, selfcontained = TRUE)
    message("Saved: outputs/figures/ndvi/cci_ankobra_leaflet_2005_2020.html")
  }

} else {
  message("Leaflet CCI map skipped — run the ESA CCI Ankobra section above first ",
          "(needs cci_anko, cci_sub, cci_years, ankobra_river, ankobra_basin).")
}
