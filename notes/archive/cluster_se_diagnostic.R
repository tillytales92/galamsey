# cluster_se_diagnostic.R
# Standalone diagnostic (not part of the a_NN_* pipeline, not sourced by anything) -- compares
# Callaway & Sant'Anna dynamic-ATT standard errors for Q0a (own-hex mining onset -> own-hex
# vegetation, see a_05_event_study_1.Rmd) under three clustering specifications:
#   1. main_basin   -- current run_cs() default (coarse HydroBASINS MAIN_BAS grouping, 42 clusters
#                       at 5km; this is what "the main_basin specification" refers to).
#   2. basin_num    -- fine-grained HydroBASINS level-9 sub-basins (280 clusters at 5km; what the
#                       load-panel chunk's block_id/block_num aliasing would use if wired into
#                       run_cs() instead of the hardcoded "main_basin" default).
#   3. old_block_num -- the pre-2026-07-06 25km centroid-block stand-in ("the old way").
#
# Motivation: user observed abnormally large SEs specifically at event_time == 2 after moving to
# main_basin clustering, otherwise-normal SEs elsewhere. Likely cause: main_basin has only 42
# clusters; if the specific set of hexes/cohorts that reach event time +2 within the sample window
# happens to be concentrated in only a handful of those 42 basins, the *effective* number of
# clusters informing that one event-time estimate can be much smaller than 42 -- and did::att_gt's
# multiplier bootstrap (bstrap = TRUE) is known to get noisy/erratic with few effective clusters,
# producing an outsized SE at just that one lag rather than a general precision problem. This
# script (a) reproduces the ATT/SE table under all three cluster specs side by side so you can see
# whether basin_num / old_block_num show the same event_time==2 spike, and (b) reports how many
# distinct clusters actually contain a hex reaching event time +2, under each scheme, to check that
# hypothesis directly.
#
# Not run automatically -- execute manually (Rscript or source()). Uses att_gt(bstrap = TRUE) three
# times on the 5km panel; expect a few minutes runtime.

pacman::p_load(tidyverse, sf, did, here)

RES <- 5
es <- readRDS(here("data", "processed", sprintf("event_panel_%dkm.rds", RES)))
panel  <- es$panel
hex_sf <- es$hex_sf

# --- Reconstruct the old 25km centroid-block stand-in (superseded 2026-07-06 by basin_num, but
# kept here so it can be compared against) ----------------------------------------------------
cent <- sf::st_coordinates(suppressWarnings(sf::st_centroid(sf::st_geometry(hex_sf))))
blocks <- tibble(hex_id = hex_sf$hex_id,
                  old_block_id = paste0("b_", round(cent[, 1] / 25000), "_", round(cent[, 2] / 25000)))
panel <- left_join(panel, blocks, by = "hex_id") |>
  mutate(old_block_num = as.integer(factor(old_block_id)))

xf <- if (all(c("elev_mean", "slope_mean") %in% names(panel)) && !all(is.na(panel$elev_mean)))
  ~ elev_mean + slope_mean else ~ 1

cat(sprintf("main_basin clusters: %d | basin_num clusters: %d | old 25km-block clusters: %d\n",
            n_distinct(panel$main_basin), n_distinct(panel$basin_num), n_distinct(panel$old_block_num)))

# --- Quick map of the three cluster variables, side by side -----------------------------------
# Purely visual sanity check: does basin_num look like a genuine fine-grained refinement of
# main_basin (spatially nested, coherent blobs), or does old_block_num (the pre-2026-07-06 25km
# centroid stand-in) look qualitatively different (regular grid vs. hydrology-following shapes)?
# Colour = discrete cluster id; no legend (too many levels at basin_num=280) -- compare shapes only.
clust_ids <- panel |> distinct(hex_id, main_basin, basin_num, old_block_num)
clust_map_sf <- hex_sf |>
  dplyr::select(hex_id) |>
  left_join(clust_ids, by = "hex_id") |>
  pivot_longer(c(main_basin, basin_num, old_block_num),
               names_to = "cluster_spec", values_to = "cluster_id") |>
  mutate(cluster_spec = factor(cluster_spec,
                                levels = c("main_basin", "basin_num", "old_block_num"),
                                labels = c("main_basin (coarse)", "basin_num (fine)", "old_block_num (25km grid)")))

p_clust_map <- ggplot(clust_map_sf) +
  geom_sf(aes(fill = factor(cluster_id)), colour = NA) +
  facet_wrap(~cluster_spec) +
  scale_fill_viridis_d(option = "turbo", guide = "none") +
  labs(title = "Cluster assignment by specification (Q0a SE-clustering diagnostic)",
       subtitle = "Colour = distinct cluster id; compare spatial coherence across specs") +
  theme_void(base_size = 11) +
  theme(strip.text = element_text(face = "bold"))
print(p_clust_map)

map_out <- here("outputs", "figures", "event_study", "cluster_se_diagnostic_map.png")
dir.create(dirname(map_out), recursive = TRUE, showWarnings = FALSE)
ggsave(map_out, p_clust_map, width = 12, height = 5, dpi = 150)
cat("Saved cluster map:", map_out, "\n")

# Headline outcome (matches Q0a's headline in a_05_event_study_1.Rmd), with a fallback in case
# this resolution's panel doesn't carry the cropland_max column.
yname <- "ndvi_modis_cropland_max"
if (!yname %in% names(panel) || all(is.na(panel[[yname]]))) {
  cand <- grep("^ndvi_modis.*max$|^evi_modis.*max$", names(panel), value = TRUE)
  cand <- cand[vapply(cand, \(c) !all(is.na(panel[[c]])), logical(1))]
  yname <- cand[1]
}
cat("Outcome used:", yname, "\n")

fit_one <- function(cluster_col) {
  d <- panel |> filter(is.finite(.data[[yname]]))
  att <- did::att_gt(
    yname = yname, tname = "year", idname = "hex_num", gname = "first_treat_own",
    control_group = "notyettreated", xformla = xf, clustervars = cluster_col,
    data = as.data.frame(d), est_method = "dr",
    base_period = "universal", allow_unbalanced_panel = TRUE, bstrap = TRUE
  )
  did::aggte(att, type = "dynamic", min_e = -5, max_e = 5, na.rm = TRUE)
}

cat("\n--- Fitting with clustervars = 'main_basin' (current run_cs() default) ---\n")
dyn_main <- fit_one("main_basin")
cat("\n--- Fitting with clustervars = 'basin_num' (level-9, 280 clusters) ---\n")
dyn_fine <- fit_one("basin_num")
cat("\n--- Fitting with clustervars = 'old_block_num' (pre-2026-07-06 25km stand-in) ---\n")
dyn_old  <- fit_one("old_block_num")

tidy_one <- function(dyn, label)
  tibble(cluster_spec = label, event_time = dyn$egt, att = dyn$att.egt, se = dyn$se.egt)

cmp <- bind_rows(
  tidy_one(dyn_main, "main_basin (42)"),
  tidy_one(dyn_fine, "basin_num (280)"),
  tidy_one(dyn_old,  "old 25km block")
) |> arrange(event_time, cluster_spec)

cat("\n=== Dynamic ATT / SE by event time and clustering spec ===\n")
print(cmp |> mutate(across(c(att, se), \(x) round(x, 4))), n = 100)

cat("\n=== SE at event_time == 2 specifically ===\n")
print(cmp |> filter(event_time == 2))

# --- Diagnose WHY e=+2 might be noisy: how many distinct clusters actually contain a hex whose
# treatment cohort reaches event time +2 within the observed sample, under each scheme? A small
# effective-cluster count here (relative to the nominal 42/280/N) would support the "few clusters
# inform this one lag" explanation over a general model-misspecification story. ---
reach_e2 <- panel |>
  filter(!is.na(first_treat_own), first_treat_own > 0) |>
  distinct(hex_id, first_treat_own, main_basin, basin_num, old_block_num) |>
  mutate(max_year = max(panel$year, na.rm = TRUE),
         reaches_e2 = (max_year - first_treat_own) >= 2) |>
  filter(reaches_e2)

cat(sprintf("\nHexes whose treatment cohort can reach event time +2 within sample: %d\n", nrow(reach_e2)))
cat(sprintf("  -> spans %d distinct main_basin clusters (of %d total)\n",
            n_distinct(reach_e2$main_basin), n_distinct(panel$main_basin)))
cat(sprintf("  -> spans %d distinct basin_num clusters (of %d total)\n",
            n_distinct(reach_e2$basin_num), n_distinct(panel$basin_num)))
cat(sprintf("  -> spans %d distinct old_block_num clusters (of %d total)\n",
            n_distinct(reach_e2$old_block_num), n_distinct(panel$old_block_num)))

cat("\nHexes-per-main_basin among the e=+2-eligible set (top 10 -- a handful of dominant basins\n")
cat("here would mean the bootstrap variance at e=+2 is effectively driven by very few clusters):\n")
print(reach_e2 |> count(main_basin, sort = TRUE) |> head(10))
