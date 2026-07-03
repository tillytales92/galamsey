# a_04_motivating_facts.R
# Section 2 — Motivating Facts
#
# Subsections follow the tasklist:
#   2.1  What Triggers Expansion of Galamsey?    (D3a–D3c)
#   2.2  Is There Reversion from Galamsey?       (D4a–D4b)
#   2.3  Does Galamsey Impact Ag Productivity?   (D5a–D5c)
#   2.4  Does Galamsey Shift Labor?              (D6a–D6c)
#
# mine_data swap point: replace barenblitt_ts / mine_data with RS panel
# (Part 1 output) once complete, without rewriting analysis code.
#
# Data availability is noted per section. Missing datasets are commented out
# with acquisition notes below.

####0. Setup ####

pacman::p_load(tidyverse, sf, here, janitor, scales, patchwork, fixest, quantmod,
               terra, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)
UTM30N <- 32630

# ---- Available data paths ----
barenblitt_ts_path   <- here("data", "raw", "barenblitt",
                              "MiningConversion_2007-2017Vec.shp")
barenblitt_2019_path <- here("data", "raw", "barenblitt",
                              "FullConversiontoMiningExtent2019.shp")
admin2_path          <- here("data", "raw", "shapefiles", "hdx_gh_admin",
                              "gha_admin2.shp")
ndvi_stack_path      <- here("data", "raw", "landsat_vi", "landsat_ndvi_ghana_stack.tif")
evi_stack_path       <- here("data", "raw", "landsat_vi", "landsat_evi_ghana_stack.tif")
# Landsat annual NDVI/EVI stacks (250 m, EPSG:4326, layers named ndvi_YYYY / evi_YYYY).
# Built by d_01_download_gee.R Sections 7–8. Source that script first if files are absent.

# Ghana Mining Repository 2025 — formal licence locations (KML).
# Available but path unknown — check data_inventory.md for exact location.
# NOTE: 2025 snapshot only; no establishment-year field. Cannot reconstruct
# the date a formal mine first appeared in an area without a historical series.
# formal_mines_path <- here("data", "raw", ...)

# ---- Missing data paths — not yet acquired ----

# CLIMATE / RAINFALL (needed for D3b)
# chirps_path <- here("data", "raw", "climate", "chirps_ghana_annual.tif")
#   Sources:
#     CHIRPS v2.0 (0.05° daily rainfall): https://www.chc.ucsb.edu/data/chirps
#     GEE: ee$ImageCollection("UCSB-CHG/CHIRPS/DAILY") — reduce to annual total per pixel
#     ERA5 monthly reanalysis: https://cds.climate.copernicus.eu (requires free account)
#   Format needed: annual total precipitation (mm) raster or district averages, 1995–2025.
#   For drought index: SPEI or SPI can be derived from CHIRPS using the SPEI R package.

# COCOA YIELDS (needed for D5c)
# cocobod_path <- here("data", "raw", "cocobod", "district_yields.csv")
#   Sources:
#     Ghana Cocoa Board (COCOBOD) — direct data request via https://www.cocobod.gh
#     IFPRI datasets: https://www.ifpri.org (some district-level Ghana cocoa data)
#     Bulk purchase data sometimes in academic supplements (Kolavalli & Vigneri 2011;
#     Zeitlin et al. series on Ghanaian cocoa farmers)
#   Format needed: annual cocoa purchases or yields (tonnes) by district, 2000–2020.

# CENSUS MICRODATA (needed for D6a–D6c)
# census_path <- here("data", "raw", "census")
#   Sources:
#     Ghana Statistical Service: https://www.statsghana.gov.gh (2000, 2010, 2021)
#     IPUMS International: https://international.ipums.org — Ghana 2000 and 2010 available;
#       2021 may not yet be released as microdata
#     Variables needed: employment sector (agriculture, mining, other), occupation code,
#       district identifier (adm2), possibly EA identifier for sub-district matching
#   Note: Ghana Living Standards Survey (GLSS 7, 2016/17) covers labor allocation in more
#     detail than the census and is available via GSS — useful complement for D6c.

out_dir <- here("outputs", "figures", "motivating_facts")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

####1. Load Available Data ####

districts_sf <- st_read(admin2_path) |> clean_names() |>
  select(adm2_name, geometry) |>
  st_transform(UTM30N) |> st_make_valid()

# mine_data — replace with RS panel once Part 1 complete
mine_data <- st_read(barenblitt_ts_path) |> clean_names() |>
  st_transform(UTM30N) |> st_make_valid() |>
  mutate(year = 2000L + as.integer(trimws(classifica)))

mine_2019 <- st_read(barenblitt_2019_path) |> clean_names() |>
  st_transform(UTM30N) |> st_make_valid()

# National annual totals
national_annual <- mine_data |>
  mutate(ha = as.numeric(st_area(geometry)) / 1e4) |>
  st_drop_geometry() |>
  group_by(year) |>
  summarise(new_ha = sum(ha), .groups = "drop") |>
  arrange(year) |>
  mutate(cumul_ha = cumsum(new_ha))

# Gold price — GC=F front-month futures via Yahoo Finance (requires internet)
# Global price only; no Ghana-specific series exists. Reasonable proxy because
# artisanal miners sell at prices closely tied to the world spot price.
gold_raw    <- getSymbols("GC=F", src = "yahoo",
                           from = "2007-01-01", to = "2017-12-31",
                           auto.assign = FALSE)
gold_annual <- Cl(gold_raw) |>
  as.data.frame() |>
  rownames_to_column("date") |>
  setNames(c("date", "price")) |>
  mutate(date = as.Date(date), year = as.integer(format(date, "%Y"))) |>
  filter(!is.na(price)) |>
  group_by(year) |>
  summarise(price_usd = mean(price), .groups = "drop") |>
  arrange(year) |>
  mutate(log_price  = log(price_usd),
         gold_shock = log_price - lag(log_price))

# District-level panel — read from d01 processed CSV (run d01 first)
# Adjust suffix if d01 was run with a different unit_type
district_panel_path <- here("data", "processed",
                             "mining_timeseries_by_districts_2007-2017.csv")
if (file.exists(district_panel_path)) {
  district_panel <- read_csv(district_panel_path, show_col_types = FALSE)
} else {
  message("District panel CSV not found — source 2_build/b_01_mining_by_unit.R first.")
  district_panel <- NULL
}

####2.1 What Triggers Expansion of Galamsey? ####

####D3a. Galamsey Expansion vs Gold Price Shocks ####

national_gold <- national_annual |>
  left_join(gold_annual, by = "year")

# 1. Dual-axis time series: new conversions vs gold price
coeff_d3a <- max(national_gold$new_ha, na.rm = TRUE) /
             max(national_gold$price_usd, na.rm = TRUE)

p_d3a_ts <- national_gold |>
  ggplot(aes(x = year)) +
  geom_area(aes(y = new_ha), fill = "#E67E22", alpha = 0.6) +
  geom_line(aes(y = new_ha), colour = "#922B21", linewidth = 0.8) +
  geom_point(aes(y = new_ha), colour = "#922B21", size = 2) +
  geom_line(aes(y = price_usd * coeff_d3a),
            colour = "#2C3E50", linewidth = 0.8, linetype = "dashed") +
  geom_point(aes(y = price_usd * coeff_d3a),
             colour = "#2C3E50", size = 2, shape = 21, fill = "white") +
  scale_x_continuous(breaks = 2007:2017) +
  scale_y_continuous(
    name     = "New mining area (ha/year)",
    labels   = label_comma(),
    expand   = expansion(mult = c(0, 0.05)),
    sec.axis = sec_axis(~ . / coeff_d3a,
                        name   = "Gold price (USD/oz)",
                        labels = label_comma())
  ) +
  labs(
    title    = "Annual new galamsey conversion and world gold price",
    subtitle = "Barenblitt et al. (2021); gold price: GC=F futures via Yahoo Finance",
    x        = NULL,
    caption  = "Gold price is global front-month futures — no Ghana-specific series available."
  ) +
  theme_minimal(base_size = 11) +
  theme(
    axis.text.x        = element_text(angle = 45, hjust = 1),
    axis.title.y.right = element_text(colour = "#2C3E50"),
    axis.text.y.right  = element_text(colour = "#2C3E50")
  )

ggsave(file.path(out_dir, "d3a_timeseries_gold.png"), p_d3a_ts,
       width = 8, height = 5, dpi = 150)
message("Saved: d3a_timeseries_gold.png")

# 2. Spearman correlation: annual new mining (ha) vs gold price with 2-year lag
# GC=F annual averages align closely with World Gold Council reported prices
# for the same period and are used here as the price series.
national_gold_lag2 <- national_gold |>
  arrange(year) |>
  mutate(price_lag2 = lag(price_usd, 2)) |>
  filter(!is.na(price_lag2))

cor_d3a <- cor.test(national_gold_lag2$new_ha, national_gold_lag2$price_lag2,
                    method = "spearman")
message(sprintf("D3a Spearman rho (new_ha ~ gold price, 2-yr lag): %.3f  p = %.3f  n = %d",
                cor_d3a$estimate, cor_d3a$p.value, nrow(national_gold_lag2)))

####D3b. Event-Study: Galamsey Expansion vs Climate Shocks ####

# BLOCKED — rainfall/climate data not yet acquired (see acquisition notes in Section 0).
#
# Intended approach:
#   1. Load CHIRPS annual rainfall raster; extract district-level annual totals
#      via exact_extract() or st_extract()
#   2. Compute rainfall anomaly relative to long-run district mean (z-score or
#      deviation in mm)
#   3. Panel regression at district × year level:
#        new_ha_i ~ rainfall_anomaly_t + rainfall_anomaly_{t-1} | district + year
#   4. Test both positive shocks (flood disruption) and negative shocks (drought
#      → pushed into mining as agriculture fails)
#   5. SPEI index as alternative drought measure (available via SPEI R package
#      given monthly CHIRPS input)

# TODO: uncomment and complete once chirps_path is available
# chirps <- terra::rast(chirps_path)
# district_rainfall <- exactextractr::exact_extract(chirps, districts_sf, "mean") |>
#   pivot_longer(...) |>
#   mutate(rainfall_anomaly = ...)

####D3c. Does Galamsey Accelerate After First Formal Mine Appears? ####

# PARTIALLY BLOCKED — Ghana Mining Repository KML is available as a 2025 snapshot
# but carries no establishment-year field. Cannot reconstruct first-appearance date
# from this source alone.
#
# What can be done with current data:
#   - Spatial join: which districts/hexes have a formal mine licence in the 2025 snapshot?
#   - Cross-sectional comparison: do areas with formal mine presence have more or less
#     artisanal mining? (Uses mine_2019 + formal_mines_path)
#
# What is needed for the full event-study:
#   - A historical series of formal mine licences with issue dates, OR
#   - The PMMC (Precious Minerals Marketing Company) or Ghana Minerals Commission
#     annual licence registers — available via direct request or Minerals Commission
#     publication archive: https://www.mincomgh.org
#
# Intended approach once historical licences available:
#   1. For each hex/district, identify year of first formal mine licence
#   2. Event-time panel: new_ha_i(t) ~ sum_k β_k × 1(t - first_licence_i == k)
#      with hex + year FE; plot β_k as event-time coefficients

# TODO: load formal mines KML and do cross-sectional comparison
# formal_mines <- st_read(formal_mines_path) |> st_transform(UTM30N)
# hex_formal <- ...

####2.2 Is There Reversion from Galamsey? ####

####D4a. Do Areas That Transition to Galamsey Eventually Revert? ####

# NOTE ON DATA LIMITATION: The Barenblitt time-series shapefile records new mining
# *conversions* each year (areas newly converted to mining). It does not track whether
# previously converted areas are still actively mined in subsequent years. As a result,
# true reversion (a mine closing and land reverting) cannot be measured within the
# Barenblitt data — the cumulative panel is monotonically non-decreasing by construction.
#
# What can be observed as a proxy:
#   - Slowdown in new conversions in a hex after peak activity (saturation vs reversion)
#   - Zero new conversions in late years in hexes that were active early
#     (consistent with reversion but not conclusive)
#
# For a true reversion analysis, the RS panel from Part 1 is needed: annual mine
# *presence* (not just onset) so that absence in year t+k after presence in year t
# can be identified as reversion.

if (!is.null(district_panel)) {

  # Proxy: proportion of "early onset" hexes with zero new conversions in final years
  # Requires hex-level panel — placeholder pending hex CSV from d01
  # district_reversion <- district_panel |>
  #   group_by(adm2_name) |>
  #   arrange(year) |>
  #   mutate(peak_year   = year[which.max(new_ha)],
  #          post_peak   = year > peak_year,
  #          new_ha_post = if_else(post_peak, new_ha, NA_real_)) |>
  #   summarise(pct_declining = mean(new_ha_post < new_ha[year == peak_year],
  #                                  na.rm = TRUE))
  message("D4a placeholder: full reversion analysis requires RS panel (Part 1)")
}

####2.3 Does Galamsey Impact Agricultural Productivity? ####

####D5a. NDVI/EVI Gradient Around Galamsey Sites ####

# D5a and D5b share setup: crop stacks to study area, project to UTM30N,
# build a raster distance-zone layer once, then use terra::zonal() for extraction.

if (!file.exists(ndvi_stack_path) || !file.exists(evi_stack_path)) {
  message("D5a/D5b: stacks not found — run d_01_download_gee.R Sections 7–8 first.")
} else {

  ndvi_stk_d5 <- terra::rast(ndvi_stack_path)
  evi_stk_d5  <- terra::rast(evi_stack_path)

  # Step 1: crop stacks to study area + 25 km margin (covers outermost ring)
  study_bbox_4326 <- mine_2019 |>
    st_union() |> st_convex_hull() |>
    st_buffer(25000) |>
    st_transform(4326) |>
    st_bbox() |>
    terra::ext()

  message("D5a/D5b: cropping stacks to study area...")
  ndvi_crop <- terra::crop(ndvi_stk_d5, study_bbox_4326)
  evi_crop  <- terra::crop(evi_stk_d5,  study_bbox_4326)

  # Step 2: project to UTM30N for metric distance computation
  message("D5a/D5b: reprojecting to UTM30N...")
  ndvi_utm <- terra::project(ndvi_crop, paste0("EPSG:", UTM30N),
                              method = "bilinear", res = 250)
  # Project EVI onto the NDVI grid as template so the two share an identical
  # extent/resolution — required for stacking them per-pixel in D5a.
  evi_utm  <- terra::project(evi_crop, ndvi_utm, method = "bilinear")

  # Step 3: distance-to-nearest-mine surface for D5a (2019 artisanal extent).
  # mine cells = 1 / non-mine = NA; distance() gives metres from nearest mine cell.
  # tmpl is reused by D5b for rasterizing the time-series onset layers.
  mine_art_vect <- mine_2019 |>
    filter(mine_type == 1) |>
    terra::vect()

  tmpl      <- ndvi_utm[[1]]
  mine_rast <- terra::rasterize(mine_art_vect, tmpl, background = NA)

  message("D5a: computing distance-to-mine raster...")
  dist_rast <- terra::distance(mine_rast)

  # D5a: 2019 binned scatter — NDVI/EVI vs continuous distance to nearest mine.
  # Matches the proposal ("binned scatter of ag productivity against distance to
  # nearest mining site"): distance is a continuous covariate, pixels are grouped
  # into equal-width distance bins, each point is a bin mean. Mine pixels have
  # distance 0 (left edge of the axis) — no separate "interior" category needed.
  if (!"ndvi_2019" %in% names(ndvi_utm) || !"evi_2019" %in% names(evi_utm)) {
    message("D5a: ndvi_2019 or evi_2019 layer missing from stack — skipping scatter.")
  } else {
    message("D5a: building binned scatter vs distance (2019)...")

    D5A_MAX_KM <- 20    # cap: beyond this is study-area edge, not informative
    D5A_BIN_KM <- 0.5   # bin width

    # Per-pixel distance (m) + index values; drop reprojection-edge NA cells
    pix_d5a <- c(dist_rast, ndvi_utm[["ndvi_2019"]], evi_utm[["evi_2019"]]) |>
      terra::as.data.frame(na.rm = FALSE) |>
      as_tibble() |>
      setNames(c("dist_m", "ndvi", "evi")) |>
      drop_na() |>
      mutate(dist_km = dist_m / 1000) |>
      filter(dist_km <= D5A_MAX_KM)

    # Equal-width distance bins: mean index + mean distance + pixel count per bin
    binned_d5a <- pix_d5a |>
      mutate(bin = floor(dist_km / D5A_BIN_KM)) |>
      group_by(bin) |>
      summarise(dist_km = mean(dist_km),
                ndvi    = mean(ndvi),
                evi     = mean(evi),
                n       = n(),
                .groups = "drop")

    make_binscatter <- function(data, y_col, y_label) {
      ggplot(data, aes(x = dist_km, y = .data[[y_col]])) +
        geom_smooth(aes(weight = n), method = "loess", span = 0.75, se = TRUE,
                    colour = "#C0392B", fill = "#C0392B", alpha = 0.15,
                    linewidth = 0.8) +
        geom_point(aes(size = n), colour = "#1A5276", alpha = 0.7) +
        scale_size_continuous(range = c(1, 4), guide = "none") +
        scale_x_continuous(breaks = scales::breaks_width(2)) +
        scale_y_continuous(labels = label_number(accuracy = 0.01)) +
        labs(x = "Distance to nearest mine (km)", y = y_label) +
        theme_minimal(base_size = 11)
    }

    p_d5a <- make_binscatter(binned_d5a, "ndvi", "Mean NDVI (2019)") /
             make_binscatter(binned_d5a, "evi",  "Mean EVI (2019)") +
      plot_annotation(
        title    = "NDVI and EVI vs distance to nearest artisanal galamsey mine",
        subtitle = sprintf("2019 cross-section; %g km bins, point size ∝ pixel count; Landsat 250 m",
                           D5A_BIN_KM),
        caption  = paste0("Binned scatter of pixel-level NDVI/EVI against distance to nearest mine ",
                          "(distance 0 = mine pixels).\nLOESS fit weighted by bin pixel count. ",
                          "SW Ghana only (Barenblitt coverage); 6.25 ha pixels.")
      )

    ggsave(file.path(out_dir, "d5a_ndvi_evi_distance_binscatter.png"), p_d5a,
           width = 8, height = 8, dpi = 150)
    message("Saved: d5a_ndvi_evi_distance_binscatter.png")
  }

  ####D5b. Event Study: NDVI/EVI Around Galamsey Mine Onset, by Distance ####
  # Aligns NDVI/EVI to each location's mine-onset year (Barenblitt time series,
  # 2007–2017) and tracks them in event time, split by distance band. Near bands
  # are "treated" (expect a drop at/after t = 0); far bands are "control" (should
  # stay flat — if they don't, that reveals a region-wide confounder). Each band is
  # normalised to its own pre-onset baseline at t = -1.

  ES_ONSET_YEARS <- 2007:2017
  ES_WINDOW      <- 5            # event-time half-window (years)
  ES_BASE        <- -1L          # normalisation reference (pre-onset year)

  # 1. Distance to the nearest mine of each onset year → one layer per year
  message("D5b: building per-onset-year distance stack...")
  dist_by_year <- terra::rast(map(ES_ONSET_YEARS, function(y) {
    mv <- mine_data |> filter(year == y) |> terra::vect()
    terra::distance(terra::rasterize(mv, tmpl, background = NA))
  }))
  names(dist_by_year) <- paste0("onset_", ES_ONSET_YEARS)

  # 2. Nearest-mine onset year (which.min over the stack) + distance to that mine
  nearest_idx   <- terra::which.min(dist_by_year)
  nearest_onset <- terra::subst(nearest_idx, seq_along(ES_ONSET_YEARS), ES_ONSET_YEARS)
  names(nearest_onset) <- "onset_year"
  dist_nearest  <- min(dist_by_year)

  # 3. Collapse distance into 4 bands: Mine (0) + three rings
  band_rast <- terra::classify(
    dist_nearest,
    rcl = matrix(c(   0,  1000, 1,
                   1000,  5000, 2,
                   5000, 20000, 3), ncol = 3, byrow = TRUE),
    include.lowest = TRUE, right = TRUE, others = NA
  )
  mine_any_rast <- terra::rasterize(terra::vect(mine_data), tmpl, background = NA)
  band_rast <- terra::ifel(!is.na(mine_any_rast), 0L, band_rast)
  names(band_rast) <- "band"

  BAND_LABELS <- c("Mine", "0–1 km", "1–5 km", "5–20 km")
  band_pal    <- setNames(c("#C0392B", "#E59866", "#5499C7", "#1A5276"), BAND_LABELS)

  # 4. Per-pixel panel over the calendar window → event time
  es_years   <- (min(ES_ONSET_YEARS) - ES_WINDOW):(max(ES_ONSET_YEARS) + ES_WINDOW)
  ndvi_es_ly <- intersect(paste0("ndvi_", es_years), names(ndvi_utm))
  evi_es_ly  <- intersect(paste0("evi_",  es_years), names(evi_utm))

  if (length(ndvi_es_ly) < 2) {
    message("D5b: insufficient NDVI layers in event window — skipping event study.")
  } else {
    message("D5b: extracting per-pixel event-time panel...")

    es_pix <- c(band_rast, nearest_onset,
                ndvi_utm[[ndvi_es_ly]], evi_utm[[evi_es_ly]]) |>
      terra::as.data.frame(na.rm = FALSE) |>
      as_tibble() |>
      filter(band %in% 0:3, !is.na(onset_year))

    es_long <- es_pix |>
      pivot_longer(cols = c(all_of(ndvi_es_ly), all_of(evi_es_ly)),
                   names_to = c("index", "year"),
                   names_pattern = "(ndvi|evi)_(\\d{4})",
                   values_to = "value") |>
      mutate(year = as.integer(year), event_time = year - onset_year) |>
      filter(!is.na(value), event_time >= -ES_WINDOW, event_time <= ES_WINDOW)

    # Mean per (index, band, event_time), then normalise each band to t = -1
    es_summary <- es_long |>
      group_by(index, band, event_time) |>
      summarise(mean_val = mean(value), n = n(), .groups = "drop") |>
      group_by(index, band) |>
      mutate(norm_val = mean_val - mean_val[event_time == ES_BASE]) |>
      ungroup() |>
      mutate(band_label = factor(BAND_LABELS[band + 1], levels = BAND_LABELS))

    make_event_plot <- function(data, index_key, y_label) {
      ggplot(filter(data, index == index_key),
             aes(x = event_time, y = norm_val,
                 colour = band_label, group = band_label)) +
        geom_hline(yintercept = 0, colour = "grey80", linewidth = 0.4) +
        geom_vline(xintercept = 0, linetype = "dashed", colour = "grey40") +
        geom_line(linewidth = 0.9) +
        geom_point(size = 2) +
        scale_colour_manual(values = band_pal, name = "Distance band") +
        scale_x_continuous(breaks = -ES_WINDOW:ES_WINDOW) +
        scale_y_continuous(labels = label_number(accuracy = 0.01)) +
        labs(x = "Years since mine onset", y = y_label) +
        theme_minimal(base_size = 11) +
        theme(legend.position = "right")
    }

    p_d5b <- make_event_plot(es_summary, "ndvi", "Δ NDVI vs t = -1") /
             make_event_plot(es_summary, "evi",  "Δ EVI vs t = -1") +
      plot_annotation(
        title    = "Event study: NDVI and EVI around galamsey mine onset, by distance",
        subtitle = "Onset = first Barenblitt conversion year (2007–2017); normalised to t = -1; Landsat 250 m",
        caption  = paste0("Each location aligned to its nearest mine's onset year. ",
                          "Near bands = treated, far bands = control.\n",
                          "SW Ghana only (Barenblitt coverage); 6.25 ha pixels.")
      )

    ggsave(file.path(out_dir, "d5b_ndvi_evi_event_study.png"), p_d5b,
           width = 9, height = 9, dpi = 150)
    message("Saved: d5b_ndvi_evi_event_study.png")
  }

}  # end stacks-exist block

####D5c. Cocoa Yields Around Galamsey Areas ####

# BLOCKED — COCOBOD district-level yield data not yet acquired
#           (see acquisition notes in Section 0).
#
# Intended approach once cocobod_path is available:
#   1. Load district × year cocoa purchase/yield data
#   2. Merge with district-level mining intensity from district_panel
#   3. Panel regression:
#        log(cocoa_yield_it) ~ mining_intensity_it + mining_intensity_{it-1}
#        | district_i + year_t
#      with district + year FE; cluster SEs by district
#   4. Robustness: IV approach using gold-suitable geology share as instrument
#      for mining intensity (mirrors first-stage in a_02_spatial_clustering.R D2c-FS)

# TODO: uncomment and complete once cocobod_path is available
# cocobod <- read_csv(cocobod_path) |> clean_names()
# cocoa_panel <- cocobod |>
#   left_join(district_panel |> group_by(adm2_name, year) |>
#               summarise(new_ha = sum(new_ha), .groups = "drop"),
#             by = c("district" = "adm2_name", "year"))
# fit_cocoa <- feols(log(yield) ~ new_ha | district + year,
#                   data = cocoa_panel, vcov = ~ district)

####2.4 Does Galamsey Shift Labor Away from Agriculture? ####

####D6a. Does Formal/Urban Employment Rise in High-Galamsey Districts? ####

# BLOCKED — Ghana census microdata not yet acquired (see acquisition notes in Section 0).
#
# Intended approach once census_path is available:
#   1. Load individual-level census records for 2000 and 2010 (IPUMS Ghana)
#   2. Aggregate to district × year: employment shares by sector
#      (agriculture, mining, services, construction, unemployed)
#   3. Merge with district mining intensity at corresponding census year from district_panel
#   4. Cross-sectional diff-in-diff (2000 vs 2010):
#        Δemployment_share_i = β × Δmining_intensity_i + controls
#   5. IV: instrument Δmining_intensity with geology share (Girard)

####D6b. Is There an Increase in People Reporting Formal Mining Employment? ####

# BLOCKED — same census data requirement as D6a.
#
# Intended approach:
#   1. Extract census occupation codes corresponding to mining (ISIC Rev. 4: B05–B09)
#   2. Compute district share reporting mining occupation in 2000 vs 2010
#   3. Regress change in mining employment share on change in galamsey intensity
#   Note: formal mining employment likely understates galamsey involvement;
#         GLSS 7 (2016/17) has a specific informal employment module that may be
#         more informative — request from Ghana Statistical Service

####D6c. Is Labor Moving into Informal Mining? ####

# BLOCKED — census/GLSS data not yet acquired (see acquisition notes in Section 0).
#
# Intended approach:
#   1. Use GLSS 7 (2016/17) informal employment module — ask respondents about
#      self-employment in mining / quarrying vs agriculture
#   2. Spatial merge to district level; compare to Barenblitt mining intensity
#   3. Potentially: diff-in-diff using GLSS 5 (2005/06) as baseline
#   Note: GLSS 7 available from Ghana Statistical Service upon request;
#         GLSS 5 microdata available via World Bank Microdata Catalog:
#         https://microdata.worldbank.org

message("\n=== a_04_motivating_facts.R complete ===")
