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
# Compositing: annual mean of QA-masked 16-day composites (23 per year).
#   Mean preferred over max here: captures sustained greenness/degradation
#   rather than peak-season values; consistent with the event-study outcome.
# NDVI and EVI are exported as separate single-band files per year
# (modis_ndvi_ghana_ / modis_evi_ghana_), stacked independently in d_01 Section 9.
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
pacman::p_load(here, elevatr, terra, sf, janitor, tidyverse, conflicted, patchwork)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)

# Data --------------------------------------------------------------------
ndvi_stack_path       <- here("data", "raw", "landsat_vi", "landsat_ndvi_ghana_stack.tif")
evi_stack_path        <- here("data", "raw", "landsat_vi", "landsat_evi_ghana_stack.tif")
modis_ndvi_stack_path <- here("data", "raw", "modis_vi",   "modis_ndvi_ghana_stack.tif")
modis_evi_stack_path  <- here("data", "raw", "modis_vi",   "modis_evi_ghana_stack.tif")

ndvi       <- terra::rast(ndvi_stack_path)
evi        <- terra::rast(evi_stack_path)
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
  na_by_year(ndvi,       "Landsat NDVI (250 m)"),
  na_by_year(evi,        "Landsat EVI (250 m)"),
  na_by_year(modis_ndvi, "MODIS NDVI (250 m)"),
  na_by_year(modis_evi,  "MODIS EVI (250 m)")
)

print(na_all |> select(product, year, na_count, total, pct_na), n = Inf)

# Line chart: % missing by year, all four products
ggplot(na_all, aes(year, pct_na, colour = product)) +
  geom_line() +
  geom_point(size = 1.5) +
  scale_colour_manual(values = c(
    "Landsat NDVI (250 m)" = "#1b7837",
    "Landsat EVI (250 m)"  = "#762a83",
    "MODIS NDVI (250 m)"   = "#74c476",
    "MODIS EVI (250 m)"    = "#c994c7"
  )) +
  labs(title = "Missing pixels by year — Landsat & MODIS NDVI / EVI",
       x = NULL, y = "% NA cells", colour = NULL) +
  theme_minimal(base_size = 11) +
  theme(legend.position = "bottom")

# Spatial NA-frequency maps: how many years is each pixel missing?
n_landsat <- terra::nlyr(ndvi)
n_modis   <- terra::nlyr(modis_ndvi)

plot(terra::app(is.na(ndvi),       sum), main = sprintf("Landsat NDVI: years with NA (out of %d)", n_landsat))
plot(terra::app(is.na(evi),        sum), main = sprintf("Landsat EVI: years with NA (out of %d)",  n_landsat))
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
freq_2019 <- terra::freq(lc_stack[[which(lc_years == 2019)]]) |>
  as_tibble() |>
  dplyr::filter(!is.na(value)) |>
  left_join(igbp, by = "value") |>
  mutate(label = fct_reorder(label, count))

ggplot(freq_2019, aes(count, label, fill = colour)) +
  geom_col() +
  scale_fill_identity() +
  labs(title = "Land cover composition — Ghana 2019 (IGBP LC_Type1)",
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
