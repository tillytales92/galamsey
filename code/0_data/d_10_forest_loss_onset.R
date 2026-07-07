# d_10_forest_loss_onset.R
# Hansen Global Forest Change -> candidate ONSET-YEAR proxy for each Maus et al. Ghana mining
# polygon, validated against Barenblitt's own per-parcel conversion years where they overlap.
#
# Motivation (from a_05/galamsey_tasklist.md discussion, 2026-07-07): Maus et al.'s global mining
# polygons (d_09_mining_mausetal.R) are a single static footprint -- unlike Barenblitt, they carry
# no year. Barenblitt got a per-year time series by training a separate classifier on Landsat for
# EACH year 2007-2017. This script asks the same "when did mining begin here" question a cheaper
# way: Hansen GFC already ships a per-pixel change-detection result (`lossyear`, its own
# break-detection algorithm run on the full Landsat archive, 2001-2025) -- so for a Maus polygon
# that was forested in 2000, the earliest/modal year of detected forest loss inside it is a
# candidate onset-year proxy, without training anything ourselves.
#
# IMPORTANT CAVEATS (do not over-read the output without these):
#   - Hansen detects FOREST LOSS, not mining specifically. A polygon that was already non-forest
#     (cropland, bare land, water-adjacent, or already mined) before 2000 will show LITTLE OR NO
#     loss signal even if mining started well before or during the Hansen record -- `forest_frac_2000`
#     / `has_baseline_forest` flag this; treat those polygons' onset years as missing, not "no
#     mining detected".
#   - Forest loss != mining onset in general (could be logging, fire, agricultural clearing). This
#     is a PROXY, validated below against Barenblitt only where the two datasets overlap
#     (SW Ghana, 2007-2017) -- outside that window/area it is unvalidated.
#   - Small polygons relative to the ~30 m Hansen grid (the Maus EDA found a 10.24 ha minimum, i.e.
#     ~3-4 pixels across) get few extracted pixels; `n_pixels`/`land_area_frac` flag this per row.
#
# Inputs:
#   data/raw/hansen/hansen_gfc_ghana_stack.tif        -- from d_01_download_gee.R Sec 6c/8/9
#     (bands: treecover2000, loss, lossyear, gain, datamask; NOT YET DOWNLOADED as of 2026-07-07 --
#     run d_01's Hansen export + Drive download first, this script will stop with a clear message
#     if the file is absent)
#   data/raw/mining_mausetal/global_mining_polygons_v2.gpkg -- Ghana subset, as in d_09
#   data/raw/barenblitt/MiningConversion_2007-2017Vec.shp   -- validation only (optional; each
#     feature's `classifica` field is a 2-digit year = the year THAT PARCEL was first classified as
#     mining, i.e. already a per-feature onset year -- no cumulative-union logic needed, just join
#     and take the min year among features intersecting a given Maus polygon)
#
# Outputs:
#   data/processed/mining_mausetal/gha_maus_onset_years.csv  -- one row per Maus polygon:
#     maus_id, ISO3_CODE, COUNTRY_NAME, AREA (Maus's own km^2 field), area_ha (geometry-based),
#     n_pixels, land_area_frac, forest_frac_2000, mean_treecover_2000, has_baseline_forest,
#     loss_frac_of_forest, onset_year_min, onset_year_modal, barenblitt_onset_year (if validation
#     data present)
#   outputs/figures/forest_loss_onset/*.png -- diagnostics (see Sec 4-5)
#
# Re-run when: the Hansen export is refreshed, TREECOVER_THRESHOLD changes, or the Maus gpkg updates.

pacman::p_load(sf, terra, here, janitor, tidyverse, scales, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff,
  here::here
)
UTM30N <- 32630

hansen_path         <- here("data", "raw", "hansen", "hansen_gfc_ghana_stack.tif")
maus_path           <- here("data", "raw", "mining_mausetal", "global_mining_polygons_v2.gpkg")
barenblitt_ts_path  <- here("data", "raw", "barenblitt", "MiningConversion_2007-2017Vec.shp")
admin0_path         <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp")

stopifnot(
  "Hansen GFC stack not found -- run d_01_download_gee.R Sec 6c (submit), Sec 8 (download), Sec 9 (stack) first." =
    file.exists(hansen_path),
  "Maus et al. gpkg not found" = file.exists(maus_path)
)

fig_dir  <- here("outputs", "figures", "forest_loss_onset")
proc_dir <- here("data", "processed", "mining_mausetal")
dir.create(fig_dir,  recursive = TRUE, showWarnings = FALSE)
dir.create(proc_dir, recursive = TRUE, showWarnings = FALSE)

# Canopy-cover threshold (%) for calling a pixel "forested" in 2000 -- 30% is the conventional
# default in most Hansen-based forest-loss studies (incl. Global Forest Watch); lower thresholds
# (e.g. 10%) count more baseline area as "forest" but dilute the signal with sparse/degraded cover.
TREECOVER_THRESHOLD <- 30
# A polygon needs at least this share of its land area forested in 2000 for the onset-year proxy
# to mean anything at all -- below this, "no loss detected" more likely means "wasn't forest to
# begin with" than "no clearing happened".
MIN_FOREST_SHARE <- 0.10

####1. Load ####

hansen <- terra::rast(hansen_path)
message(sprintf("Hansen GFC: %d band(s) [%s], %.0f m res",
                terra::nlyr(hansen), paste(names(hansen), collapse = ", "),
                mean(terra::res(hansen)) * 111320))
stopifnot("Expected bands treecover2000/loss/lossyear/gain/datamask not found in Hansen stack" =
            all(c("treecover2000", "loss", "lossyear", "gain", "datamask") %in% names(hansen)))

maus_gha <- st_read(
  maus_path,
  query = "SELECT * FROM mining_polygons WHERE ISO3_CODE = 'GHA'",
  quiet = TRUE
) |>
  st_make_valid() |>
  mutate(maus_id = row_number())

message(sprintf("Maus et al. Ghana polygons: %d", nrow(maus_gha)))

# Geometry-based area (repo convention), for context alongside Maus's own AREA (km^2) field.
maus_gha <- st_transform(maus_gha, UTM30N) |>
  mutate(area_ha = as.numeric(st_area(geom)) / 1e4) |>
  st_transform(4326)

####2. Zonal extraction -- per pixel, area-weighted (small polygons vs. 30 m grid) ####
# exact = TRUE returns a `fraction` column: the share of each intersecting raster cell covered by
# the polygon. Needed here because many Maus polygons are only a few pixels across (10.24 ha
# minimum found in d_09 ~= 3-4 pixels), so an unweighted per-pixel extract would be noisy.

maus_vect <- terra::vect(maus_gha)
ex <- terra::extract(hansen, maus_vect, exact = TRUE, ID = TRUE)
message(sprintf("Extracted %d raster-cell x polygon intersections across %d polygons.",
                nrow(ex), n_distinct(ex$ID)))

####3. Aggregate to one row per polygon ####

# Fraction-weighted mode: the lossyear value with the most covered-area weight, not just the most
# frequent pixel count -- consistent with the fraction-weighting used throughout this section.
weighted_mode <- function(x, w) {
  keep <- !is.na(x) & !is.na(w) & w > 0
  if (!any(keep)) return(NA_integer_)
  tab <- tapply(w[keep], x[keep], sum)
  as.integer(names(tab)[which.max(tab)])
}

onset <- ex |>
  dplyr::filter(!is.na(datamask), datamask == 1) |>   # land only -- loss/lossyear meaningless over water
  group_by(ID) |>
  summarise(
    n_pixels             = n(),
    land_area_frac       = sum(fraction, na.rm = TRUE),
    forest_frac_2000     = sum(fraction[treecover2000 >= TREECOVER_THRESHOLD], na.rm = TRUE) /
                            sum(fraction, na.rm = TRUE),
    mean_treecover_2000  = weighted.mean(treecover2000, fraction, na.rm = TRUE),
    loss_frac_of_forest  = {
      fw <- fraction[treecover2000 >= TREECOVER_THRESHOLD]
      lw <- loss[treecover2000 >= TREECOVER_THRESHOLD]
      if (length(fw) && sum(fw, na.rm = TRUE) > 0) sum(fw[lw == 1L], na.rm = TRUE) / sum(fw, na.rm = TRUE)
      else NA_real_
    },
    onset_year_min = {
      ly <- lossyear[treecover2000 >= TREECOVER_THRESHOLD & lossyear > 0L]
      if (length(ly)) 2000L + min(ly, na.rm = TRUE) else NA_integer_
    },
    onset_year_modal = {
      idx <- treecover2000 >= TREECOVER_THRESHOLD & lossyear > 0L & !is.na(lossyear)
      if (any(idx)) 2000L + weighted_mode(lossyear[idx], fraction[idx]) else NA_integer_
    },
    .groups = "drop"
  ) |>
  mutate(has_baseline_forest = forest_frac_2000 >= MIN_FOREST_SHARE)

maus_onset <- maus_gha |>
  st_drop_geometry() |>
  select(maus_id, ISO3_CODE, COUNTRY_NAME, AREA, area_ha) |>
  left_join(onset, by = c("maus_id" = "ID"))

cat("\n=== Hansen-derived onset-year coverage ===\n")
cat(sprintf("  %d of %d polygons (%.1f%%) have >= %.0f%% forested baseline (usable proxy).\n",
            sum(maus_onset$has_baseline_forest, na.rm = TRUE), nrow(maus_onset),
            100 * mean(maus_onset$has_baseline_forest, na.rm = TRUE), 100 * MIN_FOREST_SHARE))
cat(sprintf("  Of those, %d (%.1f%%) have a detected onset year (some/all forest loss by 2025).\n",
            sum(!is.na(maus_onset$onset_year_modal)),
            100 * mean(!is.na(maus_onset$onset_year_modal[maus_onset$has_baseline_forest]))))
cat("\nOnset-year distribution (modal, forested-baseline polygons only):\n")
print(maus_onset |> dplyr::filter(has_baseline_forest) |> count(onset_year_modal))

####4. Validation against Barenblitt (where they overlap) ####
# Barenblitt's MiningConversion_2007-2017Vec.shp is ALREADY a per-feature onset year (`classifica`,
# 2-digit -> 2000+N) -- each feature is a parcel first classified as mining that year, so the
# "ground truth" onset for a Maus polygon is just the MINIMUM year among Barenblitt features that
# spatially intersect it (no cumulative-union construction needed, unlike b_03a's no-mine mask).

mine_ts <- if (file.exists(barenblitt_ts_path)) {
  st_read(barenblitt_ts_path, quiet = TRUE) |>
    clean_names() |>
    st_make_valid() |>
    mutate(year = 2000L + as.integer(trimws(classifica))) |>
    select(year)
} else {
  message("Barenblitt time series not found -- skipping the validation section.")
  NULL
}

if (!is.null(mine_ts)) {
  bb_year <- st_join(maus_gha |> select(maus_id), mine_ts, join = st_intersects) |>
    st_drop_geometry() |>
    group_by(maus_id) |>
    summarise(barenblitt_onset_year = if (all(is.na(year))) NA_integer_ else min(year, na.rm = TRUE),
              .groups = "drop")

  maus_onset <- maus_onset |> left_join(bb_year, by = "maus_id")

  # Restrict the comparison to STRICTLY INTERIOR Barenblitt years (2008-2016): parcels dated 2007
  # or 2017 could really have converted earlier/later but be left/right-censored by Barenblitt's
  # own 2007-2017 window, which would bias the comparison against Hansen for no real reason.
  cmp <- maus_onset |>
    dplyr::filter(has_baseline_forest, !is.na(onset_year_modal), !is.na(barenblitt_onset_year),
                  barenblitt_onset_year > 2007, barenblitt_onset_year < 2017)

  if (nrow(cmp) > 0) {
    cmp <- cmp |> mutate(year_diff = onset_year_modal - barenblitt_onset_year)
    cat(sprintf("\n=== Validation vs. Barenblitt (n = %d polygons, interior years 2008-2016) ===\n",
                nrow(cmp)))
    cat(sprintf("  Correlation (Hansen modal onset vs. Barenblitt onset): %.2f\n",
                cor(cmp$onset_year_modal, cmp$barenblitt_onset_year, use = "complete.obs")))
    cat(sprintf("  Mean absolute year error: %.2f years\n", mean(abs(cmp$year_diff))))
    cat(sprintf("  Within +/-1 / +/-2 / +/-3 years: %.1f%% / %.1f%% / %.1f%%\n",
                100 * mean(abs(cmp$year_diff) <= 1), 100 * mean(abs(cmp$year_diff) <= 2),
                100 * mean(abs(cmp$year_diff) <= 3)))

    p_val <- ggplot(cmp, aes(barenblitt_onset_year, onset_year_modal)) +
      geom_abline(slope = 1, intercept = 0, linetype = "dashed", colour = "grey50") +
      geom_jitter(aes(size = area_ha), width = 0.15, height = 0.15, alpha = 0.5, colour = "#2171B5") +
      scale_size_continuous(name = "Polygon area (ha)", trans = "sqrt") +
      coord_equal() +
      labs(title = "Hansen forest-loss onset year vs. Barenblitt observed onset year",
           subtitle = sprintf("n = %d polygons (interior years 2008-2016 only, forested baseline >= %.0f%%); dashed = 1:1",
                              nrow(cmp), 100 * MIN_FOREST_SHARE),
           x = "Barenblitt onset year (ground truth)", y = "Hansen modal onset year (proxy)") +
      theme_bw(base_size = 11)
    p_val
    ggsave(file.path(fig_dir, "onset_validation_scatter.png"), p_val, width = 7, height = 6, dpi = 150)
  } else {
    message("No polygons met the validation-comparison criteria (interior Barenblitt years + forested baseline).")
  }
}

####5. Diagnostics ####

p_hist <- maus_onset |>
  dplyr::filter(has_baseline_forest) |>
  ggplot(aes(onset_year_modal)) +
  geom_histogram(binwidth = 1, fill = "#D94701", na.rm = TRUE) +
  labs(title = "Hansen-derived mining-polygon onset years (Ghana, Maus et al. footprint)",
       subtitle = sprintf("Forested-baseline polygons only (>= %.0f%% of area forested in 2000); NA = no loss detected by 2025",
                          100 * MIN_FOREST_SHARE),
       x = "Modal onset year (forest loss)", y = "Number of polygons") +
  theme_bw(base_size = 11)
p_hist
ggsave(file.path(fig_dir, "onset_year_hist.png"), p_hist, width = 8, height = 5, dpi = 150)

p_forest_share <- ggplot(maus_onset, aes(forest_frac_2000)) +
  geom_histogram(bins = 40, fill = "#238B45", na.rm = TRUE) +
  geom_vline(xintercept = MIN_FOREST_SHARE, linetype = "dashed", colour = "grey30") +
  scale_x_continuous(labels = label_percent()) +
  labs(title = "Share of each Maus polygon forested in 2000 (baseline for the onset-year proxy)",
       subtitle = sprintf("Dashed line = %.0f%% usability cutoff (MIN_FOREST_SHARE)", 100 * MIN_FOREST_SHARE),
       x = "Forested share of polygon area, year 2000", y = "Number of polygons") +
  theme_bw(base_size = 11)
p_forest_share
ggsave(file.path(fig_dir, "forest_baseline_share_hist.png"), p_forest_share, width = 7, height = 5, dpi = 150)

admin0 <- if (file.exists(admin0_path)) {
  st_read(admin0_path, quiet = TRUE) |> st_make_valid() |> select(any_of(c("adm0_name", "geometry")))
} else NULL

maus_onset_sf <- maus_gha |> select(maus_id) |> left_join(maus_onset, by = "maus_id")
bb <- st_bbox(maus_onset_sf)
p_map <- ggplot() +
  { if (!is.null(admin0)) geom_sf(data = admin0, fill = "grey96", colour = "grey60") } +
  geom_sf(data = dplyr::filter(maus_onset_sf, !has_baseline_forest | is.na(onset_year_modal)),
          fill = "grey70", colour = NA) +
  geom_sf(data = dplyr::filter(maus_onset_sf, has_baseline_forest, !is.na(onset_year_modal)),
          aes(fill = onset_year_modal), colour = NA) +
  coord_sf(xlim = c(bb["xmin"], bb["xmax"]), ylim = c(bb["ymin"], bb["ymax"])) +
  scale_fill_viridis_c(name = "Onset year", option = "viridis") +
  labs(title = "Hansen-derived onset year by Maus et al. mining polygon",
       subtitle = "Grey = no usable forested baseline in 2000, or no loss detected by 2025",
       caption  = "Hansen et al. GFC v1.13 (2000-2025); Maus et al. (2022) mining polygons. Till Meissner.") +
  theme_minimal(base_size = 10) +
  theme(plot.title = element_text(face = "bold"),
        axis.text = element_blank(), axis.title = element_blank(),
        panel.grid = element_blank(),
        plot.caption = element_text(colour = "grey50", size = 7))
p_map
ggsave(file.path(fig_dir, "onset_year_map.png"), p_map, width = 8, height = 8, dpi = 150)

####6. Write processed output ####

out_csv <- file.path(proc_dir, "gha_maus_onset_years.csv")
write_csv(maus_onset, out_csv)
message(sprintf("\nSaved: %s (%d rows)", out_csv, nrow(maus_onset)))

message("\n=== d_10_forest_loss_onset.R complete ===")
