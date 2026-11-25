# mask_missingness_e2_diagnostic.R
# Standalone diagnostic (not part of the a_NN_* pipeline, not sourced by anything) -- follow-up to
# cluster_se_diagnostic.R (which confirmed the main_basin -> block_num clustering fix resolved a
# severe cluster-concentration problem for Q0a's event_time == 2 estimate, using the panel's
# original cropland-mask headline). run_cs()'s clustervars default is now `block_num` everywhere
# (real HydroBASINS basin_num where present, 280+ clusters -- see a_05_event_study_1/2/3.Rmd and
# event_study_design.md's SE-clustering section).
#
# Motivation for THIS script: the user reports event_time == 2 is STILL noisy for the current
# `evi_modis_veg_narrow_max` / `evi_modis_cropland_max` outcomes, even under block_num clustering,
# while asking whether re-downloading HydroBASINS at level 10/11 (finer sub-basins, in
# d_01_download_gee.R Sec 6b) would fix it. Two distinct mechanisms could produce a noisy e=+2 SE,
# and they call for opposite remedies:
#   (A) CONCENTRATION -- same failure mode as before: the hexes/basins that happen to inform e=+2
#       are dominated by 1-2 mega-basins (low effective cluster count despite many nominal
#       clusters). Finer HydroBASINS levels (10/11) could plausibly help this, IF it doesn't just
#       fragment those same basins into many hex-sized singletons instead (level 9 already has 18
#       singleton basins at 5km -- see 2026-07-06 CHANGELOG entry -- so finer levels risk making
#       this WORSE, not better, by degenerating cluster-robust inference toward no clustering).
#   (B) MASK-DRIVEN SMALL-N -- `cropland` (~3.6-9.5% NA) and `veg_narrow` (~1.3-2.2% NA) have much
#       higher missingness than `nominecrop` (~0.1% NA); run_cs() drops non-finite outcome rows
#       before fitting, so a higher-NA mask can shrink the *usable* e=+2 sample even where the
#       *eligible* (cohort-based) sample is fine. If missingness isn't spread evenly across event
#       time, this alone can reproduce "one noisy lag" without any cluster-concentration problem at
#       all -- and no amount of re-basinning fixes a small-N problem.
# This script separates the two: for each of the three headline EVI masks, on the SAME
# first_treat_own (Q0a) treatment definition, it reports (i) the ELIGIBLE hex count at e=+2
# (cohort reaches that lag within sample, regardless of outcome NA -- mask-independent), (ii) the
# USABLE hex count (also non-NA on that specific outcome column -- mask-dependent), (iii) the
# distinct block_num clusters and effective cluster count (inverse-Herfindahl, as in
# cluster_se_diagnostic.R) among the USABLE hexes only, and (iv) the actual fitted SE at e=+2 (and
# the full event-time SE profile, for context on whether e=+2 is uniquely bad).
#
# Reading the output:
#   - If USABLE << ELIGIBLE for cropland/veg_narrow but USABLE ~= ELIGIBLE for nominecrop, AND the
#     effective cluster counts among USABLE hexes are all still reasonably high (not dominated by
#     1-2 basins) -> mechanism (B), mask-driven small-N. Re-basinning would NOT help; the fix is
#     mask-specific (accept the noisier estimate on cropland/veg_narrow at that lag, or flag it).
#   - If effective cluster count among USABLE hexes is low (a handful of basins hold most of the
#     mass) for cropland/veg_narrow specifically, even though USABLE ~= ELIGIBLE -> mechanism (A),
#     concentration, structurally similar to the original main_basin problem just recurring at a
#     smaller scale. Worth testing whether an intermediate HydroBASINS level helps, WITHOUT jumping
#     straight to level 10/11 and risking singleton-basin fragmentation.
#   - Both can be true simultaneously; the table below reports both diagnostics side by side.
#
# Not run automatically -- execute manually (Rscript or source()). Fits att_gt(bstrap = TRUE) once
# per mask (3 fits); expect a few minutes runtime.

pacman::p_load(tidyverse, sf, did, here)

RES <- 2   # match a_05_event_study_1.Rmd's params$resolution_km default; change to 5 to check the
           # primary grid instead (event_study_design.md recommends 5km as primary).
EVENT_TIME_OF_INTEREST <- 2L

es <- readRDS(here("data", "processed", sprintf("event_panel_%dkm.rds", RES)))
panel  <- es$panel
hex_sf <- es$hex_sf

# --- block_num, exactly as in the load-panel chunk (real HydroBASINS basin_num where present,
# 25km centroid-block fallback otherwise) -------------------------------------------------------
has_basin <- all(c("basin_id", "basin_num") %in% names(panel)) && !all(is.na(panel$basin_num))
if (has_basin) {
  panel <- panel |> mutate(block_id = as.character(basin_id), block_num = basin_num)
} else {
  cent <- sf::st_coordinates(suppressWarnings(sf::st_centroid(sf::st_geometry(hex_sf))))
  blocks <- tibble(hex_id = hex_sf$hex_id,
                    block_id = paste0("b_", round(cent[, 1] / 25000), "_", round(cent[, 2] / 25000)))
  panel <- left_join(panel, blocks, by = "hex_id") |> mutate(block_num = as.integer(factor(block_id)))
}
cat(sprintf("Resolution: %dkm | block_num source: %s | n clusters: %d\n",
            RES, if (has_basin) "real HydroBASINS basin_num" else "25km centroid-block fallback",
            n_distinct(panel$block_num)))

xf <- if (all(c("elev_mean", "slope_mean") %in% names(panel)) && !all(is.na(panel$elev_mean)))
  ~ elev_mean + slope_mean else ~ 1

# --- Masks to compare -- the three current EVI-peak headline outcomes from a_05_event_study_1.Rmd's
# OUTCOMES (NDVI counterparts would show the same pattern if it's mask- rather than index-driven;
# add them here if you want to check that too). ---------------------------------------------------
masks <- c(
  evi_modis_nominecrop_max  = "no-mine-crop (~0.1% NA)",
  evi_modis_veg_narrow_max  = "veg-narrow (~1.3-2.2% NA)",
  evi_modis_cropland_max    = "cropland (~3.6-9.5% NA)"
)
masks <- masks[names(masks) %in% names(panel)]

# --- (i)/(ii): eligible vs usable hex counts at the event time of interest, under first_treat_own
# (Q0a's onset design) -- mask-independent "eligible" pool computed once, then intersected with
# each mask's own non-NA hexes at that lag for the "usable" pool. -------------------------------
max_year <- max(panel$year, na.rm = TRUE)

eligible <- panel |>
  filter(!is.na(first_treat_own), first_treat_own > 0) |>
  distinct(hex_id, first_treat_own, block_num) |>
  filter((max_year - first_treat_own) >= EVENT_TIME_OF_INTEREST)

cat(sprintf("\nELIGIBLE hexes at event_time == %d (cohort reaches this lag within sample, mask-independent): %d\n",
            EVENT_TIME_OF_INTEREST, nrow(eligible)))
cat(sprintf("  -> spans %d distinct block_num clusters (of %d total)\n",
            n_distinct(eligible$block_num), n_distinct(panel$block_num)))

effective_n_clusters <- function(ids) {
  # Inverse-Herfindahl effective cluster count: 1 / sum(p_i^2), p_i = share of hexes in cluster i.
  p <- as.numeric(table(ids)) / length(ids)
  1 / sum(p^2)
}

usable_summary <- imap_dfr(masks, function(mask_label, yname) {
  obs_at_e2 <- panel |>
    semi_join(eligible |> select(hex_id, first_treat_own), by = c("hex_id", "first_treat_own" = "first_treat_own")) |>
    filter(year - first_treat_own == EVENT_TIME_OF_INTEREST, !is.na(.data[[yname]]))
  tibble(
    outcome           = yname,
    mask              = mask_label,
    n_usable          = n_distinct(obs_at_e2$hex_id),
    n_clusters_usable = n_distinct(obs_at_e2$block_num),
    eff_clusters      = if (nrow(obs_at_e2) > 0) round(effective_n_clusters(obs_at_e2$block_num), 1) else NA_real_
  )
})

usable_summary <- usable_summary |>
  mutate(n_eligible  = nrow(eligible),
         pct_usable  = round(100 * n_usable / n_eligible, 1))

cat(sprintf("\n=== USABLE (non-NA) hexes at event_time == %d, by mask ===\n", EVENT_TIME_OF_INTEREST))
print(usable_summary |> select(mask, n_eligible, n_usable, pct_usable, n_clusters_usable, eff_clusters))

# --- (iv): actual fitted SE at the event time of interest, plus the full event-time profile, per
# mask -- ties the eligible/usable/concentration diagnostics above back to the real bootstrap SE. --
fit_one <- function(yname) {
  d <- panel |> filter(is.finite(.data[[yname]]))
  att <- did::att_gt(
    yname = yname, tname = "year", idname = "hex_num", gname = "first_treat_own",
    control_group = "notyettreated", xformla = xf, clustervars = "block_num",
    data = as.data.frame(d), est_method = "dr",
    base_period = "universal", allow_unbalanced_panel = TRUE, bstrap = TRUE
  )
  did::aggte(att, type = "dynamic", min_e = -5, max_e = 5, na.rm = TRUE)
}

cat("\n--- Fitting att_gt (clustervars = 'block_num') for each mask -- a few minutes ---\n")
se_profiles <- imap_dfr(masks, function(mask_label, yname) {
  cat(sprintf("  fitting %s (%s)...\n", yname, mask_label))
  dyn <- fit_one(yname)
  tibble(outcome = yname, mask = mask_label, event_time = dyn$egt, att = dyn$att.egt, se = dyn$se.egt)
})

cat(sprintf("\n=== SE at event_time == %d specifically, by mask ===\n", EVENT_TIME_OF_INTEREST))
print(se_profiles |> filter(event_time == EVENT_TIME_OF_INTEREST) |>
        mutate(across(c(att, se), \(x) round(x, 4))))

cat("\n=== Full event-time SE profile, by mask (context: is e==2 uniquely bad, or a general pattern?) ===\n")
print(se_profiles |> mutate(across(c(att, se), \(x) round(x, 4))), n = 100)

cat("\n=== Combined read: usable-sample diagnostics + fitted SE at event_time ==", EVENT_TIME_OF_INTEREST, "===\n")
usable_summary |>
  left_join(se_profiles |> filter(event_time == EVENT_TIME_OF_INTEREST) |> select(outcome, se),
            by = "outcome") |>
  mutate(se = round(se, 4)) |>
  select(mask, n_eligible, n_usable, pct_usable, n_clusters_usable, eff_clusters, se) |>
  print()
