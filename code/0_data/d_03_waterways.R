# d_03_waterways.R
# Three-part script:
#
# PART 1 — Download (Secs 0b–0c)
#   Fetches all waterway=* LINE features for Ghana from the Geofabrik OSM extract
#   via the osmextract package. Writes a timestamped raw file to:
#     data/raw/shapefiles/osm_extracts/waterways_ghana_YYYY-MM-DD.gpkg
#   Only downloads if no timestamped file exists — set FORCE_DOWNLOAD <- TRUE to
#   force a re-fetch. Then builds a processed natural-watercourses-only file at:
#     data/processed/waterways/waterways_natural.shp
#   This processed file is what the analysis pipeline reads — no inline filtering
#   of waterway types in b_01_cross_section.R, a_01, or a_02.
#
# PART 2 — EDA (Secs 1–8)
#   Inspects the "waterway" type field and assesses which types are relevant for
#   alluvial gold mining. (1) load + classify natural vs artificial; (2) tabulate
#   types (count + length, study area and Ghana-wide); (3) map by class; (4) does
#   the filter move per-hex distance-to-river?; (5) OSM vs MERIT-modeled rivers;
#   (6) does swapping river measure change first-stage fit?; (7) first-stage model
#   ladder by river measure (Ankobra subset); (8) main rivers + galamsey hex map.
#
# Outputs:
#   data/raw/shapefiles/osm_extracts/waterways_ghana_YYYY-MM-DD.gpkg — raw OSM extract
#   data/processed/waterways/waterways_natural.shp                    — natural only (pipeline input)
#   outputs/figures/waterways/waterway_type_counts.csv
#   outputs/figures/waterways/waterway_types_map.png
#   outputs/figures/waterways/dist_river_all_vs_natural.{csv,png}    (if d03 cache exists)
#   outputs/figures/waterways/dist_river_osm_vs_merit.{csv,png}      (if d03 cache + MERIT raster)
#   outputs/figures/waterways/firststage_fit_by_river_measure.csv     (Ankobra subset only)
#   outputs/figures/maps/waterways_galamsey_map.png                   (if b_01_cross_section cache exists)

####0. Setup ####
pacman::p_load(sf, terra, here, janitor, tidyverse, scales, patchwork, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff,
  here::here
)
UTM30N <- 32630

osm_dir      <- here("data", "raw", "shapefiles", "osm_extracts")
proc_ww_dir  <- here("data", "processed", "waterways")
natural_path <- here("data", "processed", "waterways", "waterways_natural.shp")
barenblitt_path <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")

fig_dir <- here("outputs", "figures", "waterways")
dir.create(osm_dir,     recursive = TRUE, showWarnings = FALSE)
dir.create(proc_ww_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(fig_dir,     recursive = TRUE, showWarnings = FALSE)

# Natural waterway types (alluvial-gold relevant); used for waterways_natural.shp
# and referenced here once — downstream scripts read the processed file directly.
NATURAL_WATERWAYS <- c("river", "stream", "brook", "wadi", "tidal_channel",
                       "stream_pool", "flowline")

####0b. Download OSM waterways for Ghana (once; timestamped raw file) ####
# Checks for any existing waterways_ghana_YYYY-MM-DD.gpkg; downloads only if absent
# OR if FORCE_DOWNLOAD is TRUE. The Geofabrik extract is cached by osmextract in its
# own temp dir — subsequent downloads of the same version are fast.
FORCE_DOWNLOAD <- FALSE   # set TRUE to force a fresh Geofabrik fetch

existing_dl <- list.files(osm_dir,
                          pattern  = "^waterways_ghana_\\d{4}-\\d{2}-\\d{2}\\.gpkg$",
                          full.names = TRUE)

if (FORCE_DOWNLOAD || length(existing_dl) == 0) {
  pacman::p_load(osmextract)
  today_tag <- format(Sys.Date(), "%Y-%m-%d")
  raw_path  <- file.path(osm_dir, sprintf("waterways_ghana_%s.gpkg", today_tag))

  message(sprintf("Downloading Ghana OSM waterways from Geofabrik (%s)...", today_tag))
  waterways_dl <- oe_get(
    place          = "Ghana",
    layer          = "lines",
    query          = "SELECT osm_id, name, waterway, geometry FROM lines WHERE waterway IS NOT NULL",
    quiet          = FALSE,
    force_download = FORCE_DOWNLOAD
  ) |> st_make_valid()

  st_write(waterways_dl, raw_path, delete_dsn = TRUE, quiet = TRUE)
  message(sprintf("Written: %s  (%d features)", basename(raw_path), nrow(waterways_dl)))
} else {
  raw_path <- sort(existing_dl)[length(existing_dl)]   # most recent
  message(sprintf("Using existing OSM extract: %s  (set FORCE_DOWNLOAD <- TRUE to refresh)",
                  basename(raw_path)))
}

waterways_raw <- st_read(raw_path, quiet = TRUE) |>
  clean_names() |> st_make_valid() |> st_transform(UTM30N)
message(sprintf("Loaded %d waterway features from raw extract.", nrow(waterways_raw)))

####0c. Build processed natural-waterways file ####
# Filter to natural watercourses only and write to data/processed/waterways/.
# This is the file all analysis scripts read — no inline type-filtering elsewhere.
waterways_natural <- waterways_raw |> filter(waterway %in% NATURAL_WATERWAYS)
st_write(waterways_natural, natural_path, delete_dsn = TRUE, quiet = TRUE)
message(sprintf("Written: %s  (%d natural-watercourse features of %d total)",
                basename(natural_path), nrow(waterways_natural), nrow(waterways_raw)))

####1. Load (for EDA) ####
# Use the full raw dataset for the EDA below so all types are visible.
waterways <- waterways_raw

mining_2019 <- st_read(barenblitt_path, quiet = TRUE) |>
  clean_names() |>
  st_make_valid() |>
  st_transform(UTM30N)

# Study area = Barenblitt convex hull (same definition d03 uses for its hex grid).
study_area <- st_convex_hull(st_union(mining_2019))

waterways_study <- st_filter(waterways, study_area)

####2. Relevance classification ####
# Natural flowing watercourses can host/expose alluvial gold; human-made channels do not.
# `other` = anything unmapped below — eyeball it and reassign before relying on the filter.
natural    <- c("river", "stream", "brook", "wadi", "tidal_channel", "stream_pool", "flowline")
artificial <- c("canal", "drain", "ditch", "lock_gate", "fish_pass", "weir", "dam",
                "sluice_gate", "pressurised", "penstock")

classify_waterway <- function(x) {
  dplyr::case_when(
    x %in% natural    ~ "natural watercourse",
    x %in% artificial ~ "artificial channel",
    TRUE              ~ "other / review"
  )
}

waterways       <- waterways       |> mutate(ww_class = classify_waterway(waterway))
waterways_study <- waterways_study |> mutate(ww_class = classify_waterway(waterway))

####3. Tabulate types (count + total length) ####
type_summary <- function(sf_obj, scope) {
  # Compute lengths before the pipe so we don't depend on the geometry column name.
  lens <- as.numeric(st_length(sf_obj)) / 1000
  sf_obj |>
    mutate(length_km = lens) |>
    st_drop_geometry() |>
    group_by(waterway, ww_class) |>
    summarise(n = n(), length_km = round(sum(length_km), 1), .groups = "drop") |>
    mutate(scope = scope) |>
    arrange(desc(length_km))
}

tab_ghana <- type_summary(waterways,       "ghana")
tab_study <- type_summary(waterways_study, "study_area")

cat("\n=== Waterway types — STUDY AREA (Barenblitt SW Ghana) ===\n")
print(tab_study, n = Inf)
cat("\n=== Waterway types — ALL GHANA ===\n")
print(tab_ghana, n = Inf)

# Class-level share of total length within the study area — the headline number:
# how much of the "river" network is actually artificial.
class_share <- tab_study |>
  group_by(ww_class) |>
  summarise(n = sum(n), length_km = sum(length_km), .groups = "drop") |>
  mutate(length_share = round(length_km / sum(length_km), 3)) |>
  arrange(desc(length_km))
cat("\n=== Study-area length share by class ===\n")
print(class_share)

write_csv(bind_rows(tab_study, tab_ghana),
          file.path(fig_dir, "waterway_type_counts.csv"))

####4. Map the network by class ####
class_cols <- c("natural watercourse" = "#1F78B4",
                "artificial channel"  = "#E31A1C",
                "other / review"      = "#999999")

p_map <- ggplot() +
  geom_sf(data = study_area, fill = "#F5F5F0", colour = "grey70", linewidth = 0.2) +
  geom_sf(data = mining_2019, fill = "#E67E22", colour = NA, alpha = 0.35) +
  geom_sf(data = waterways_study, aes(colour = ww_class), linewidth = 0.25, alpha = 0.8) +
  scale_colour_manual(values = class_cols, name = "Waterway class") +
  labs(
    title    = "OSM waterways by class — Barenblitt study area",
    subtitle = "Orange = 2019 mining extent. Are artificial channels (red) near mining, or off in towns/farmland?",
    caption  = "OpenStreetMap contributors; Barenblitt et al. (2021). Convex-hull study area."
  ) +
  theme_void(base_size = 10) +
  theme(plot.title = element_text(face = "bold"),
        plot.caption = element_text(colour = "grey50", size = 7),
        legend.position = "bottom")

ggsave(file.path(fig_dir, "waterway_types_map.png"), p_map,
       width = 9, height = 9, dpi = 150)

####5. Does the type filter move distance-to-river? ####
# Recompute per-hex distance to nearest waterway under (a) ALL types vs (b) NATURAL only,
# on the exact d03 hex grid, so we can see whether the filter materially changes the
# regressor before bothering to edit d03. Skipped if the d03 cache is absent.
cache_path <- here("data", "processed", "hex_5km_crosssection.rds")

if (file.exists(cache_path)) {
  hex_sf        <- readRDS(cache_path)$hex_sf
  hex_centroids <- st_centroid(hex_sf)

  ww_natural <- waterways |> filter(ww_class == "natural watercourse")

  dist_km <- function(targets) {
    idx <- st_nearest_feature(hex_centroids, targets)
    as.numeric(st_distance(hex_centroids, targets[idx, ], by_element = TRUE)) / 1000
  }

  dist_cmp <- tibble(
    hex_id       = hex_sf$hex_id,
    dist_all_km  = dist_km(waterways),
    dist_nat_km  = dist_km(ww_natural)
  ) |>
    mutate(diff_km = dist_nat_km - dist_all_km)   # >= 0: natural-only is farther

  cat("\n=== Distance to nearest river: ALL types vs NATURAL only (km) ===\n")
  cat(sprintf("  mean(all) = %.2f | mean(natural) = %.2f | mean shift = %.2f km\n",
              mean(dist_cmp$dist_all_km), mean(dist_cmp$dist_nat_km), mean(dist_cmp$diff_km)))
  cat(sprintf("  correlation(all, natural) = %.3f | hexes shifting >1 km: %d (%.1f%%)\n",
              cor(dist_cmp$dist_all_km, dist_cmp$dist_nat_km),
              sum(dist_cmp$diff_km > 1), 100 * mean(dist_cmp$diff_km > 1)))

  write_csv(dist_cmp, file.path(fig_dir, "dist_river_all_vs_natural.csv"))

  p_cmp <- ggplot(dist_cmp, aes(dist_all_km, dist_nat_km)) +
    geom_abline(slope = 1, intercept = 0, colour = "grey60", linetype = 2) +
    geom_point(alpha = 0.25, size = 0.6, colour = "#1F78B4") +
    coord_equal() +
    labs(
      title    = "Per-hex distance to nearest river: all waterways vs natural only",
      subtitle = "Points above the 1:1 line = hexes whose nearest 'river' was actually an artificial channel",
      x = "Distance to nearest waterway, ALL types (km)",
      y = "Distance to nearest NATURAL watercourse (km)",
      caption  = "d03 5 km hex grid. OpenStreetMap contributors."
    ) +
    theme_minimal(base_size = 10) +
    theme(plot.title = element_text(face = "bold"),
          plot.caption = element_text(colour = "grey50", size = 7))

  ggsave(file.path(fig_dir, "dist_river_all_vs_natural.png"), p_cmp,
         width = 7, height = 7, dpi = 150)
} else {
  message("d03 cache not found (", cache_path, ") — skipping the distance comparison.\n",
          "  Run a_02_spatial_clustering.R (saveRDS cache block) first to enable Section 5.")
}

####6. OSM vs MERIT-modeled rivers — does distance-to-nearest-river change? ####
# Before rewiring d03_firststage's `dist_river_km`, test on the d03 5 km hex grid how the
# regressor shifts across THREE river definitions:
#   (a) OSM  — observed, all waterway types (the d03 status quo, line ~144)
#   (b) MERIT upa > 50 km² — modeled channels, river threshold (matches d_04_merit Sec 7-10)
#   (c) MERIT upa > 10 km² — modeled channels, lower cut reaching small tributaries
# COVERAGE CAVEAT: the MERIT download (d_04_merit.R) currently spans the ANKOBRA basin only,
# not the full Barenblitt study area. So MERIT distances are valid only for d03 hexes inside
# the Ankobra raster extent — the comparison is restricted to those hexes, and OSM is
# recomputed on the SAME subset for an apples-to-apples contrast. Boundary hexes may have an
# upward-biased MERIT distance (a nearer channel can sit just outside the clip).
merit_path <- here("data", "raw", "merit", "merit_hydro_ankobra.tif")

if (file.exists(cache_path) && file.exists(merit_path)) {
  hex_sf        <- readRDS(cache_path)$hex_sf
  hex_centroids <- st_centroid(hex_sf)

  hydro <- rast(merit_path)
  names(hydro) <- c("dir", "upa", "wth", "elv")
  upa_r <- hydro[["upa"]]

  # MERIT coverage polygon (raster extent) in UTM30N; keep only hexes whose centroid is inside.
  merit_extent <- st_as_sf(as.polygons(ext(upa_r), crs = "EPSG:4326")) |> st_transform(UTM30N)
  inside <- lengths(st_intersects(hex_centroids, merit_extent)) > 0
  hex_in <- hex_centroids[inside, ]
  cat(sprintf("\n=== OSM vs MERIT rivers — %d of %d d03 hexes inside the Ankobra MERIT extent ===\n",
              sum(inside), nrow(hex_centroids)))

  # Polygonise the two MERIT channel masks (native 4326) → UTM30N.
  merit_channels <- function(thr) {
    ifel(upa_r > thr, 1L, NA) |> as.polygons() |> st_as_sf() |> st_make_valid() |> st_transform(UTM30N)
  }
  chan_50 <- merit_channels(50)
  chan_10 <- merit_channels(10)

  dist_km_to <- function(pts, targets) {
    idx <- st_nearest_feature(pts, targets)
    as.numeric(st_distance(pts, targets[idx, ], by_element = TRUE)) / 1000
  }

  dist3 <- tibble(
    hex_id          = hex_sf$hex_id[inside],
    dist_osm_km     = dist_km_to(hex_in, waterways),   # all OSM types = d03 status quo
    dist_merit50_km = dist_km_to(hex_in, chan_50),
    dist_merit10_km = dist_km_to(hex_in, chan_10)
  )

  summ <- function(v) sprintf("mean %.2f / median %.2f / max %.2f", mean(v), median(v), max(v))
  cat(sprintf("  OSM (all types) : %s km\n", summ(dist3$dist_osm_km)))
  cat(sprintf("  MERIT upa > 50  : %s km\n", summ(dist3$dist_merit50_km)))
  cat(sprintf("  MERIT upa > 10  : %s km\n", summ(dist3$dist_merit10_km)))
  cat("\n  Pearson correlations:\n")
  print(round(cor(as.matrix(dist3[, c("dist_osm_km", "dist_merit50_km", "dist_merit10_km")])), 3))
  cat(sprintf("\n  Spearman: OSM~MERIT50 = %.3f | OSM~MERIT10 = %.3f | MERIT10~MERIT50 = %.3f\n",
              cor(dist3$dist_osm_km,     dist3$dist_merit50_km, method = "spearman"),
              cor(dist3$dist_osm_km,     dist3$dist_merit10_km, method = "spearman"),
              cor(dist3$dist_merit10_km, dist3$dist_merit50_km, method = "spearman")))
  cat(sprintf("  Mean shift vs OSM: MERIT50 %+.2f km | MERIT10 %+.2f km  (negative = MERIT nearer)\n",
              mean(dist3$dist_merit50_km - dist3$dist_osm_km),
              mean(dist3$dist_merit10_km - dist3$dist_osm_km)))

  write_csv(dist3, file.path(fig_dir, "dist_river_osm_vs_merit.csv"))

  dist_long <- dist3 |>
    pivot_longer(c(dist_merit50_km, dist_merit10_km),
                 names_to = "merit_measure", values_to = "dist_merit_km") |>
    mutate(merit_measure = recode(merit_measure,
                                  dist_merit50_km = "MERIT upa > 50 km²",
                                  dist_merit10_km = "MERIT upa > 10 km²"))

  p3 <- ggplot(dist_long, aes(dist_osm_km, dist_merit_km)) +
    geom_abline(slope = 1, intercept = 0, colour = "grey60", linetype = 2) +
    geom_point(alpha = 0.3, size = 0.6, colour = "#1F78B4") +
    facet_wrap(~ merit_measure) +
    coord_equal() +
    labs(
      title    = "Distance to nearest river: OSM vs MERIT-modeled channels",
      subtitle = "d03 5 km hexes inside the Ankobra MERIT extent. Below 1:1 = MERIT finds a nearer channel than OSM.",
      x = "Distance to nearest OSM waterway, all types (km)",
      y = "Distance to nearest MERIT channel (km)",
      caption  = "MERIT Hydro upa threshold (Ankobra only); OpenStreetMap contributors; d03 5 km grid."
    ) +
    theme_minimal(base_size = 10) +
    theme(plot.title = element_text(face = "bold"),
          plot.caption = element_text(colour = "grey50", size = 7))

  ggsave(file.path(fig_dir, "dist_river_osm_vs_merit.png"), p3, width = 10, height = 5.5, dpi = 150)
} else {
  message("Section 6 skipped — need both the d03 cache (", cache_path, ") and the MERIT raster (",
          merit_path, ").")
}

####7. Does swapping OSM→MERIT river distance change the first-stage fit (M1-M4)? ####
# Quick check: refit the d03c model ladder (M1-M4 logistic, defs mirrored from
# 2_build/b_03_firststage_models.R) three times, changing ONLY the river-distance regressor —
#   (a) OSM all-types (status quo)   (b) MERIT upa>50   (c) MERIT upa>20
# — and compare McFadden R² + AUC. Question: does a MERIT distance lift fit over OSM?
#
# HARD CAVEAT — read before trusting the numbers:
#   * MERIT covers the ANKOBRA basin ONLY, so ALL THREE variants are refit on just the d03
#     hexes inside that extent (a small subset of the full study area). The ABSOLUTE AUC/R²
#     here will NOT match the published full-sample M1-M4 — only the RELATIVE gap between the
#     three river measures, on this common subset, is interpretable.
#   * Spatial lags (M2-M4) are rebuilt on the subset (queen poly2nb, as d03 line 218-219), so
#     they differ from the full-grid lw. This is a fit-only sanity check, NOT the D2bc null.
#   * Needs elev_mean/slope_mean in hex_5km_crosssection.rds (b_02_hex_frame.R) for M3-M4;
#     M1-M2 still run without it.
#   * Prevalence on the subset is printed — if few mine hexes, treat AUC/R² as indicative only.

if (file.exists(cache_path) && file.exists(merit_path)) {
  pacman::p_load(spdep, splines, pROC)

  cache  <- readRDS(cache_path)
  hex_sf <- cache$hex_sf
  hex_an <- cache$hex_analysis

  hydro <- rast(merit_path); names(hydro) <- c("dir", "upa", "wth", "elv")
  upa_r <- hydro[["upa"]]
  merit_extent <- st_as_sf(as.polygons(ext(upa_r), crs = "EPSG:4326")) |> st_transform(UTM30N)

  # Ankobra-subset hexes (centroid inside MERIT extent); keep sf order for the weights.
  cent    <- st_centroid(hex_sf)
  inside  <- lengths(st_intersects(cent, merit_extent)) > 0
  sub_sf  <- hex_sf[inside, ]
  cent_in <- cent[inside, ]

  merit_channels <- function(thr)
    ifel(upa_r > thr, 1L, NA) |> as.polygons() |> st_as_sf() |> st_make_valid() |> st_transform(UTM30N)
  dist_km_to <- function(pts, targets) {
    idx <- st_nearest_feature(pts, targets)
    as.numeric(st_distance(pts, targets[idx, ], by_element = TRUE)) / 1000
  }

  dist_tbl <- tibble(
    hex_id       = sub_sf$hex_id,
    dist_osm     = dist_km_to(cent_in, waterways),       # OSM all types = d03 status quo
    dist_merit50 = dist_km_to(cent_in, merit_channels(50)),
    dist_merit20 = dist_km_to(cent_in, merit_channels(20))
  )

  # Analysis frame built FROM sub_sf so it stays aligned to the weights row order.
  df <- tibble(hex_id = sub_sf$hex_id) |>
    left_join(select(hex_an, hex_id, gold_suit_share, any_art), by = "hex_id") |>
    left_join(dist_tbl, by = "hex_id")

  have_terrain <- all(c("elev_mean", "slope_mean") %in% names(hex_an))
  if (have_terrain) {
    df <- left_join(df,
                    select(hex_an, hex_id, elev_mean, slope_mean),
                    by = "hex_id")
  }

  # Subset spatial weights (queen contiguity, mirroring d03).
  nb <- poly2nb(sub_sf, queen = TRUE)
  lw <- nb2listw(nb, style = "W", zero.policy = TRUE)

  # Fit the ladder for one river-distance column; return McFadden R² + AUC per model.
  fit_ladder <- function(river_col) {
    d <- df
    d$dist_river_km  <- df[[river_col]]
    d$lag_gold_suit  <- lag.listw(lw, df$gold_suit_share, zero.policy = TRUE)
    d$lag_dist_river <- lag.listw(lw, d$dist_river_km,    zero.policy = TRUE)
    forms <- list(
      M1 = any_art ~ gold_suit_share + dist_river_km,
      M2 = any_art ~ ns(dist_river_km, 4) + gold_suit_share + lag_gold_suit + lag_dist_river
    )
    if (have_terrain) {
      forms$M3 <- any_art ~ ns(dist_river_km, 4) + gold_suit_share + lag_gold_suit +
                    lag_dist_river + elev_mean + slope_mean
      forms$M4 <- any_art ~ ns(dist_river_km, 4) + gold_suit_share + lag_gold_suit +
                    lag_dist_river + elev_mean + slope_mean +
                    gold_suit_share:dist_river_km + gold_suit_share:slope_mean +
                    gold_suit_share:elev_mean + dist_river_km:slope_mean
    }
    dd  <- if (have_terrain) filter(d, !is.na(elev_mean), !is.na(slope_mean)) else d
    ll0 <- as.numeric(logLik(glm(any_art ~ 1, data = dd, family = binomial())))
    imap_dfr(forms, \(f, nm) {
      m <- glm(f, data = dd, family = binomial())
      tibble(model    = nm,
             mcfadden = 1 - as.numeric(logLik(m)) / ll0,
             auc      = as.numeric(pROC::roc(dd$any_art, fitted(m), quiet = TRUE)$auc))
    })
  }

  river_fit <- bind_rows(
    fit_ladder("dist_osm")     |> mutate(river = "OSM (all types)"),
    fit_ladder("dist_merit50") |> mutate(river = "MERIT upa>50"),
    fit_ladder("dist_merit20") |> mutate(river = "MERIT upa>20")
  )

  cat(sprintf("\n=== First-stage fit by river measure — ANKOBRA SUBSET ONLY (%d hexes, prevalence %.3f) ===\n",
              nrow(df), mean(df$any_art, na.rm = TRUE)))
  cat("    absolute AUC/R² NOT comparable to full-sample M1-M4 — read the RELATIVE OSM-vs-MERIT gap\n")
  if (!have_terrain) cat("    (elev_mean/slope_mean absent from cache -> only M1-M2 fit; run d_02_elevation.R then b_02_hex_frame.R for M3-M4)\n")

  auc_wide <- river_fit |> select(model, river, auc) |>
    pivot_wider(names_from = river, values_from = auc) |> mutate(metric = "AUC", .before = 1)
  mcf_wide <- river_fit |> select(model, river, mcfadden) |>
    pivot_wider(names_from = river, values_from = mcfadden) |> mutate(metric = "McFadden R²", .before = 1)
  print(mutate(bind_rows(auc_wide, mcf_wide), across(where(is.numeric), \(x) round(x, 3))), n = Inf)

  write_csv(river_fit, file.path(fig_dir, "firststage_fit_by_river_measure.csv"))
} else {
  message("Section 7 skipped — need the d03 cache (", cache_path, ") + MERIT raster (",
          merit_path, "). Terrain CSV optional (M1-M2 only without it).")
}

####8. Main rivers + galamsey hexagons — study area map ####
# Named OSM river features (waterway == "river") across the Barenblitt study region,
# overlaid on 5 km hexagons coloured by 2019 artisanal mining extent. Rivers are drawn
# on top at full opacity so both layers are legible where they coincide.
# Requires hex_5km_crosssection.rds + mining_extent_by_hex5km_2019.csv from b_01_cross_section.R.

gha_adm0 <- st_read(
  here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp"),
  quiet = TRUE
) |> clean_names() |> st_transform(UTM30N)

# Merge named river segments per river name, drop short stubs (<5 km total length).
# "river" in OSM = main watercourses; streams/brooks excluded.
# do_union = FALSE: st_combine (collect segments into multilinestring, no topology fix).
rivers_main <- waterways_study |>
  filter(waterway == "river", !is.na(name)) |>
  group_by(name) |>
  summarise(do_union = FALSE, .groups = "drop") |>
  mutate(total_km = as.numeric(st_length(geometry)) / 1000) |>
  filter(total_km > 5) |>
  arrange(desc(total_km))

# Place one label per river; only rivers > 15 km inside the study area get labelled.
river_pts <- rivers_main |>
  filter(total_km > 15) |>
  st_point_on_surface()

mine5_path <- here("data", "processed", "mining_extent_by_hex5km_2019.csv")

if (file.exists(cache_path) && file.exists(mine5_path)) {

  hex_sf_8 <- readRDS(cache_path)$hex_sf
  mine5    <- read_csv(mine5_path, show_col_types = FALSE)

  hex_art <- hex_sf_8 |>
    left_join(select(mine5, hex_id, Artisanal), by = "hex_id") |>
    mutate(art_ha = replace_na(Artisanal, 0))

  plasma_pal <- c("#FCFDBF", "#FCA636", "#E05C5C", "#BF3984", "#7B1D7D", "#450457")
  bb <- st_bbox(study_area)

  p8 <- ggplot() +
    geom_sf(data = gha_adm0, fill = "#F5F5F0", colour = "grey75", linewidth = 0.25) +
    # Mining hexes: semi-transparent fill so river lines remain visible over them
    geom_sf(data = filter(hex_art, art_ha > 0),
            aes(fill = art_ha), colour = NA, alpha = 0.70) +
    scale_fill_gradientn(colours = plasma_pal, trans = "sqrt",
                         name = "Artisanal\nextent (ha)", labels = scales::comma) +
    # Rivers on top — bright blue, drawn after hexes so always visible
    geom_sf(data = rivers_main, colour = "#1C6EA4", linewidth = 0.65, alpha = 0.90) +
    geom_sf_text(data = river_pts, aes(label = name),
                 size = 2.4, colour = "#0D4F7A", fontface = "italic",
                 check_overlap = TRUE) +
    # Study area dashed outline + Ghana border on top
    geom_sf(data = study_area, fill = NA, colour = "grey45",
            linewidth = 0.35, linetype = "dashed") +
    geom_sf(data = gha_adm0, fill = NA, colour = "grey50", linewidth = 0.4) +
    coord_sf(xlim = c(bb["xmin"] - 15000, bb["xmax"] + 15000),
             ylim = c(bb["ymin"] - 15000, bb["ymax"] + 15000)) +
    labs(
      title    = "Main rivers and artisanal mining — SW Ghana",
      subtitle = "5 km hexagons: 2019 artisanal extent (ha, sqrt scale).  Blue: named OSM rivers (waterway = 'river').",
      caption  = "Barenblitt et al. (2021); OpenStreetMap contributors. Dashed outline: Barenblitt study area."
    ) +
    theme_void(base_size = 11) +
    theme(
      plot.title      = element_text(face = "bold"),
      plot.subtitle   = element_text(colour = "grey35", size = 8.5),
      plot.caption    = element_text(colour = "grey50", size = 7),
      legend.position = "right"
    )

  dir.create(here("outputs", "figures", "maps"), recursive = TRUE, showWarnings = FALSE)
  ggsave(here("outputs", "figures", "maps", "waterways_galamsey_map.png"),
         p8, width = 9, height = 10, dpi = 150)
  message("Saved: outputs/figures/maps/waterways_galamsey_map.png")

} else {
  missing_files <- c(
    if (!file.exists(cache_path)) basename(cache_path),
    if (!file.exists(mine5_path)) basename(mine5_path)
  )
  message("Section 8 skipped — missing: ", paste(missing_files, collapse = ", "),
          ". Run b_01_cross_section.R first.")
}

message("\n=== d_03_waterways.R complete — see ", fig_dir, " and outputs/figures/maps/ ===")
