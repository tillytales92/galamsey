# b_03d_assemble.R
# Assemble the final event-study panel from the four component caches.
# Part 4 of 4 in the modular event-panel build.
#
# Inputs (all per resolution N):
#   hex_{N}km_vi_panel.rds             — 25 VI/urban columns, hex x year  (from b_03a)
#   hex_{N}km_own_mining.rds           — own_new_ha, adj_new_ha, hex x 2007:2017  (from b_03b)
#   hex_{N}km_flow_exposure.rds        — up/down/near/lateral flow at ROUTE_KM2=10 (PRIMARY, from b_03d)
#   hex_{N}km_flow_exposure_upa50.rds  — same, at ROUTE_KM2=50 (ALT robustness, from b_03d) — optional
#   hex_{N}km_crosssection.rds         — hex_sf + covariates  (from b_01_cross_section.R)
#   hydrobasins/hex_basin_{N}km.csv    — per-hex HydroBASINS level-9 sub-basin id (from d_07) — optional;
#                                        the SE-clustering key (replaces the 25 km centroid-block stand-in)
#
# Outputs: data/processed/event_panel_{N}km.{csv,rds}
#   Full hex x year panel with all VI, mining, exposure, and C&S event-time columns.
#
# This script runs in seconds. Re-run freely whenever any upstream cache changes
# or when the panel specification (column order, C&S bookkeeping) changes.
#
# Column inventory:
#   hex_id, hex_num, year
#   [25 VI/urban cols from b_03a]
#   own_new_ha, own_stock_ha, own_onset_year, event_time_own, ever_mined, first_treat_own
#   adj_new_ha, adj_stock_ha, adj_onset_year, first_treat_adj
#   up_new_ha,   up_stock_ha,   up_onset_year,   nearest_up_onset_year          [ROUTE_KM2=10, headline]
#   nearest_up_new_ha,   nearest_up_stock_ha                           [if flow graph present]
#   down_new_ha, down_stock_ha, down_onset_year, nearest_down_onset_year
#   nearest_down_new_ha, nearest_down_stock_ha                         [if flow graph present]
#   lateral_new_ha, lateral_stock_ha, lateral_onset_year               [if flow graph present]
#   <all of the above 15 up/down/lateral cols again with an "_upa50" suffix>  [ROUTE_KM2=50, robustness;
#     present only when hex_{N}km_flow_exposure_upa50.rds exists]
#   elev_mean, slope_mean, gold_suit_share, dist_river_km
#   basin_id, main_basin, pfaf_id, basin_num   [SE-clustering keys; present only when
#     hydrobasins/hex_basin_{N}km.csv exists. basin_num = compact 1..K factor of the level-9 HYBAS_ID
#     for the did/polars backend; main_basin = coarser HydroBASINS main-basin id for a robustness cut]

RESOLUTIONS <- c(1, 2, 5)

pacman::p_load(tidyverse, conflicted, here)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)

# Peak-VI columns from b_03a: {index}_modis[_{mask}]_{stat}, index in {ndvi,evi}, stat in {mean,max},
# mask in {overall (no suffix), nominecrop, cropland, forest, veg_narrow, veg_broad}. 24 columns.
all_vi_cols <- as.vector(t(outer(
  c("ndvi", "evi"),
  c("modis_mean",            "modis_max",
    "modis_nominecrop_mean", "modis_nominecrop_max",
    "modis_cropland_mean",   "modis_cropland_max",
    "modis_forest_mean",     "modis_forest_max",
    "modis_veg_narrow_mean", "modis_veg_narrow_max",
    "modis_veg_broad_mean",  "modis_veg_broad_max"),
  paste, sep = "_")))
# urban_share (fraction of hex CCI pixels that are urban, class 190) also travels in the VI panel.
all_vi_cols <- c(all_vi_cols, "urban_share")

# Flow-exposure columns produced by b_03d for ONE threshold's flow_r: expand to the full hex x year
# spine, compute stocks (cumulative new_ha) and onset years. Shared by the ROUTE_KM2=10 (primary)
# and ROUTE_KM2=50 (alt) exposure caches — called once per threshold, then the alt call's columns
# get an "_upa50" suffix before joining so both live in the same panel without colliding.
compute_flow_cols <- function(flow_r, hex_ids, panel_years) {
  has_flow        <- !all(is.na(flow_r$up_new_ha))
  has_near_flow   <- has_flow && all(c("nearest_up_new_ha", "nearest_down_new_ha") %in% names(flow_r))
  has_lateral_col <- has_flow && "lateral_new_ha" %in% names(flow_r)

  flow_exp <- expand_grid(hex_id = hex_ids, year = panel_years) |>
    left_join(
      dplyr::select(flow_r, hex_id, year, up_new_ha, down_new_ha,
                    any_of(c("nearest_up_new_ha", "nearest_down_new_ha", "lateral_new_ha"))),
      by = c("hex_id", "year")
    ) |>
    arrange(hex_id, year) |>
    group_by(hex_id) |>
    mutate(
      up_stock_ha           = if (has_flow)        cumsum(replace_na(up_new_ha,          0)) else NA_real_,
      down_stock_ha         = if (has_flow)        cumsum(replace_na(down_new_ha,         0)) else NA_real_,
      nearest_up_stock_ha   = if (has_near_flow)   cumsum(replace_na(nearest_up_new_ha,   0)) else NA_real_,
      nearest_down_stock_ha = if (has_near_flow)   cumsum(replace_na(nearest_down_new_ha, 0)) else NA_real_,
      lateral_stock_ha      = if (has_lateral_col) cumsum(replace_na(lateral_new_ha,      0)) else NA_real_
    ) |>
    ungroup()

  up_onset_r <- if (has_flow)
    flow_r |> dplyr::filter(up_new_ha   > 0) |>
      group_by(hex_id) |> summarise(up_onset_year   = min(year), .groups = "drop")
  else tibble(hex_id = character(0), up_onset_year = integer(0))

  down_onset_r <- if (has_flow)
    flow_r |> dplyr::filter(down_new_ha > 0) |>
      group_by(hex_id) |> summarise(down_onset_year = min(year), .groups = "drop")
  else tibble(hex_id = character(0), down_onset_year = integer(0))

  lateral_onset_r <- if (has_lateral_col)
    flow_r |> dplyr::filter(lateral_new_ha > 0) |>
      group_by(hex_id) |> summarise(lateral_onset_year = min(year), .groups = "drop")
  else tibble(hex_id = character(0), lateral_onset_year = integer(0))

  nearest_up_r <- if (has_flow)
    flow_r |> dplyr::filter(!is.na(nearest_up_onset_year)) |>
      distinct(hex_id, nearest_up_onset_year)
  else tibble(hex_id = character(0), nearest_up_onset_year = numeric(0))

  nearest_down_r <- if (has_flow && "nearest_down_onset_year" %in% names(flow_r))
    flow_r |> dplyr::filter(!is.na(nearest_down_onset_year)) |>
      distinct(hex_id, nearest_down_onset_year)
  else tibble(hex_id = character(0), nearest_down_onset_year = numeric(0))

  year_cols_r <- flow_exp |>
    dplyr::select(hex_id, year, up_new_ha, up_stock_ha, down_new_ha, down_stock_ha,
                  any_of(c("nearest_up_new_ha",   "nearest_up_stock_ha",
                           "nearest_down_new_ha", "nearest_down_stock_ha",
                           "lateral_new_ha",      "lateral_stock_ha")))

  onset_cols_r <- Reduce(\(a, b) full_join(a, b, by = "hex_id"),
                         list(up_onset_r, down_onset_r, lateral_onset_r, nearest_up_r, nearest_down_r))
  if (!has_flow) onset_cols_r <- onset_cols_r |>
    mutate(up_onset_year = NA_real_, down_onset_year = NA_real_, lateral_onset_year = NA_real_)

  list(has_flow = has_flow, year_cols = year_cols_r, onset_cols = onset_cols_r)
}

for (res_km in RESOLUTIONS) {
  vi_path       <- here("data", "processed", sprintf("hex_%dkm_vi_panel.rds",            res_km))
  own_path      <- here("data", "processed", sprintf("hex_%dkm_own_mining.rds",          res_km))
  flow_path     <- here("data", "processed", sprintf("hex_%dkm_flow_exposure.rds",       res_km))
  flow_path_50  <- here("data", "processed", sprintf("hex_%dkm_flow_exposure_upa50.rds", res_km))
  cross_path    <- here("data", "processed", sprintf("hex_%dkm_crosssection.rds",        res_km))
  basin_path    <- here("data", "processed", "hydrobasins",
                        sprintf("hex_basin_%dkm.csv", res_km))
  out_csv       <- here("data", "processed", sprintf("event_panel_%dkm.csv",             res_km))
  out_rds       <- here("data", "processed", sprintf("event_panel_%dkm.rds",             res_km))

  missing <- c(vi_path, own_path, flow_path, cross_path)[
    !file.exists(c(vi_path, own_path, flow_path, cross_path))
  ]
  if (length(missing)) {
    message(sprintf("Skipping %d km — missing inputs: %s",
                    res_km, paste(basename(missing), collapse = ", ")))
    next
  }

  message(sprintf("\n%s\n=== Assembling event panel: %d km ===\n%s",
                  strrep("=", 55), res_km, strrep("=", 55)))

  vi_r    <- readRDS(vi_path)
  own_r   <- readRDS(own_path)
  flow_r  <- readRDS(flow_path)
  cross_r <- readRDS(cross_path)

  hex_sf_r  <- cross_r$hex_sf
  covars_r  <- cross_r$hex_analysis |>
    dplyr::select(hex_id, any_of(c("gold_suit_share", "dist_river_km",
                                    "elev_mean", "slope_mean")))

  # Sub-basin clustering keys (optional, per resolution — d_07_hydrobasins.R currently builds 5 km
  # only). Time-invariant per hex, so joined by hex_id. NULL when absent so the panel still builds.
  basin_r <- if (file.exists(basin_path)) {
    read_csv(basin_path, show_col_types = FALSE) |>
      mutate(hex_id = as.character(hex_id)) |>
      dplyr::select(hex_id,
                    basin_id   = HYBAS_ID,
                    main_basin = MAIN_BAS,
                    pfaf_id    = PFAF_ID,
                    basin_num)
  } else NULL

  mining_years <- sort(unique(own_r$year))
  vi_years     <- sort(unique(vi_r$year))
  panel_years  <- sort(base::union(vi_years, mining_years))
  has_flow     <- !all(is.na(flow_r$up_new_ha))

  message(sprintf("  Panel years: %d-%d (%d years) | has flow graph: %s",
                  min(panel_years), max(panel_years), length(panel_years),
                  if (has_flow) "YES" else "NO (stub)"))

  ####1. Own + adjacency — expand to full spine, compute stocks and onsets ####

  panel_r <- expand_grid(hex_id = hex_sf_r$hex_id, year = panel_years) |>
    left_join(own_r, by = c("hex_id", "year")) |>
    mutate(own_new_ha = replace_na(own_new_ha, 0),
           adj_new_ha = replace_na(adj_new_ha, 0)) |>
    arrange(hex_id, year) |>
    group_by(hex_id) |>
    mutate(own_stock_ha = cumsum(own_new_ha),
           adj_stock_ha = cumsum(adj_new_ha)) |>
    ungroup()

  own_onset_r <- panel_r |>
    dplyr::filter(own_new_ha > 0) |>
    group_by(hex_id) |>
    summarise(own_onset_year = min(year), .groups = "drop")

  adj_onset_r <- panel_r |>
    dplyr::filter(adj_new_ha > 0) |>
    group_by(hex_id) |>
    summarise(adj_onset_year = min(year), .groups = "drop")

  ####2. Flow exposure — expand to full spine, compute stocks and onsets ####
  # For years outside the mining period (no match in flow_r), new_ha is NA -> treated as 0
  # for cumsum so stock freezes correctly at the 2017 level and is 0 before 2007.
  # ROUTE_KM2 = 10 (primary, unsuffixed columns below) via compute_flow_cols(flow_r, ...).

  flow_primary <- compute_flow_cols(flow_r, hex_sf_r$hex_id, panel_years)

  # ROUTE_KM2 = 50 (alt) — optional robustness set, joined with an "_upa50" suffix on every
  # column below except hex_id/year, so it lives alongside the primary set without colliding.
  # NULL (not just a flag) so a missing file at THIS resolution can't inherit stale objects
  # left over from a previous resolution's loop iteration.
  year_cols_50 <- onset_cols_50 <- NULL
  if (file.exists(flow_path_50)) {
    flow_r_50     <- readRDS(flow_path_50)
    flow_alt      <- compute_flow_cols(flow_r_50, hex_sf_r$hex_id, panel_years)
    year_cols_50  <- flow_alt$year_cols  |> rename_with(~paste0(., "_upa50"), -c(hex_id, year))
    onset_cols_50 <- flow_alt$onset_cols |> rename_with(~paste0(., "_upa50"), -hex_id)
    message(sprintf("  ROUTE_KM2=50 flow exposure: %s", if (flow_alt$has_flow) "populated" else "NA (stub)"))
  } else {
    message(sprintf("  %s not found — _upa50 columns omitted.", basename(flow_path_50)))
  }

  ####3. Join everything and add C&S bookkeeping columns ####

  panel_r <- panel_r |>
    left_join(vi_r, by = c("hex_id", "year")) |>
    left_join(flow_primary$year_cols,  by = c("hex_id", "year")) |>
    left_join(own_onset_r,             by = "hex_id") |>
    left_join(adj_onset_r,             by = "hex_id") |>
    left_join(flow_primary$onset_cols, by = "hex_id") |>
    left_join(covars_r,                by = "hex_id") |>
    mutate(
      hex_num         = as.integer(str_extract(hex_id, "\\d+")),
      ever_mined      = !is.na(own_onset_year),
      event_time_own  = if_else(ever_mined, year - own_onset_year, NA_real_),
      first_treat_own = replace_na(own_onset_year, 0L),
      first_treat_adj = replace_na(adj_onset_year, 0L)
    )

  if (!is.null(year_cols_50)) {
    panel_r <- panel_r |>
      left_join(year_cols_50,  by = c("hex_id", "year")) |>
      left_join(onset_cols_50, by = "hex_id")
  }

  if (!is.null(basin_r)) {
    panel_r <- panel_r |> left_join(basin_r, by = "hex_id")
  }

  ####4. Final column order ####

  # The upa50 (ROUTE_KM2=50) robustness set mirrors the 15 primary up/down/lateral columns,
  # each with an "_upa50" suffix — build that name list once rather than typing it twice.
  upa50_cols <- paste0(
    c("up_new_ha", "up_stock_ha", "up_onset_year", "nearest_up_onset_year",
      "nearest_up_new_ha", "nearest_up_stock_ha",
      "down_new_ha", "down_stock_ha", "down_onset_year", "nearest_down_onset_year",
      "nearest_down_new_ha", "nearest_down_stock_ha",
      "lateral_new_ha", "lateral_stock_ha", "lateral_onset_year"),
    "_upa50")

  panel_r <- panel_r |>
    arrange(hex_id, year) |>
    dplyr::select(
      hex_id, hex_num, year,
      any_of(all_vi_cols),
      own_new_ha, own_stock_ha, own_onset_year, event_time_own, ever_mined, first_treat_own,
      adj_new_ha, adj_stock_ha, adj_onset_year, first_treat_adj,
      up_new_ha,   up_stock_ha,   up_onset_year,   nearest_up_onset_year,
        any_of(c("nearest_up_new_ha",   "nearest_up_stock_ha")),
      down_new_ha, down_stock_ha, down_onset_year, any_of("nearest_down_onset_year"),
        any_of(c("nearest_down_new_ha", "nearest_down_stock_ha")),
      any_of(c("lateral_new_ha", "lateral_stock_ha", "lateral_onset_year")),
      any_of(upa50_cols),
      any_of(c("elev_mean", "slope_mean", "gold_suit_share", "dist_river_km")),
      any_of(c("basin_id", "main_basin", "pfaf_id", "basin_num"))
    )

  ####5. Diagnostics ####

  vi_cols_r <- base::intersect(names(panel_r), all_vi_cols)
  n_total   <- n_distinct(panel_r$hex_id)
  n_treat   <- n_distinct(panel_r$hex_id[panel_r$ever_mined])

  cat(sprintf("\n=== Event panel (%d km grid) ===\n", res_km))
  cat(sprintf("  %d hexes x %d years = %d rows | panel years %d-%d\n",
              n_total, n_distinct(panel_r$year), nrow(panel_r),
              min(panel_r$year), max(panel_r$year)))
  cat(sprintf("  VI columns (%d): %s\n", length(vi_cols_r), paste(vi_cols_r, collapse = ", ")))
  cat("  NA shares by VI column:\n")
  print(sapply(vi_cols_r, \(v) round(mean(is.na(panel_r[[v]])), 3)))
  cat(sprintf("  Treated (ever-mined) = %d | never-mined = %d\n", n_treat, n_total - n_treat))
  cat(sprintf("  Hexes with adj mining: %d\n",
              n_distinct(panel_r$hex_id[!is.na(panel_r$adj_onset_year)])))
  cat(sprintf("  Upstream/downstream (ROUTE_KM2=10): %s\n",
              if (flow_primary$has_flow) "populated" else "NA (flow edges absent)"))
  cat(sprintf("  Upstream/downstream (ROUTE_KM2=50): %s\n",
              if (!is.null(year_cols_50)) "populated" else "absent — upa50 file not found"))
  cat(sprintf("  Sub-basin SE clusters (HydroBASINS L9): %s\n",
              if (!is.null(basin_r))
                sprintf("%d basins / %d main-basins", n_distinct(basin_r$basin_id),
                        n_distinct(basin_r$main_basin))
              else "absent — hex_basin file not found (run d_07_hydrobasins.R)"))
  cat("  Onset-year distribution (own):\n")
  print(own_onset_r |> count(own_onset_year, name = "n_hexes"))

  ####6. Write outputs ####

  write_csv(panel_r, out_csv)
  saveRDS(list(panel        = panel_r,
               hex_sf       = hex_sf_r,
               vi_cols      = vi_cols_r,
               ndvi_years   = vi_years,
               mining_years = mining_years),
          out_rds)
  message(sprintf("\nSaved: %s", out_csv))
  message(sprintf("Saved: %s",  out_rds))

  rm(vi_r, own_r, flow_r, cross_r, hex_sf_r, covars_r, basin_r, panel_r,
     own_onset_r, adj_onset_r, flow_primary, year_cols_50, onset_cols_50)
  suppressWarnings(rm(flow_r_50, flow_alt))
  gc()
}

message("\n=== b_03d_assemble.R complete ===")
