# b_03b_own_mining.R
# Compute per-hex annual new mining area (own-hex) and queen-adjacency neighbour mining
# from Barenblitt 2007-2017. Part 2 of 4 in the modular event-panel build.
#
# Outputs: data/processed/hex_{N}km_own_mining.rds
#   tibble(hex_id, year, own_new_ha, adj_new_ha)
#   All hexes x years 2007:2017; 0-filled (not sparse).
#   Stock columns and onset years are derived in b_03d_assemble.R.
#
# Re-run when: Barenblitt data updates, or adjacency definition changes.
# Prerequisites: hex_{N}km_crosssection.rds from b_01_cross_section.R

RESOLUTIONS <- c(1, 2, 5)

pacman::p_load(sf, spdep, janitor, tidyverse, conflicted, here)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)
UTM30N <- 32630

barenblitt_ts <- here("data", "raw", "barenblitt", "MiningConversion_2007-2017Vec.shp")
stopifnot(file.exists(barenblitt_ts))

have_res <- RESOLUTIONS[file.exists(
  here("data", "processed", sprintf("hex_%dkm_crosssection.rds", RESOLUTIONS))
)]
if (!length(have_res)) stop("No crosssection cache found. Run b_01_cross_section.R first.")
message(sprintf("Resolutions with caches: %s km", paste(have_res, collapse = ", ")))

####1. Load Barenblitt (shared) ####

message("Loading Barenblitt time series...")
mine_ts <- st_read(barenblitt_ts, quiet = TRUE) |>
  clean_names() |> st_make_valid() |> st_transform(UTM30N) |>
  mutate(year = 2000L + as.integer(trimws(classifica)))
mining_years <- sort(unique(mine_ts$year))
message(sprintf("  Mining years: %d-%d", min(mining_years), max(mining_years)))

####2. Per-resolution loop ####

for (res_km in have_res) {
  out_path <- here("data", "processed", sprintf("hex_%dkm_own_mining.rds", res_km))
  message(sprintf("\n%s\n=== Own mining + adjacency: %d km ===\n%s",
                  strrep("=", 55), res_km, strrep("=", 55)))

  hex_sf_r <- readRDS(
    here("data", "processed", sprintf("hex_%dkm_crosssection.rds", res_km))
  )$hex_sf
  message(sprintf("  Hex grid: %d hexes", nrow(hex_sf_r)))

  # Own-hex: annual new mining area via spatial intersection
  message(sprintf("  Computing own-hex new mining (%d hexes x %d years)...",
                  nrow(hex_sf_r), length(mining_years)))
  new_own_r <- map_dfr(mining_years, \(yr) {
    ym <- dplyr::filter(mine_ts, year == yr)
    if (nrow(ym) == 0) return(tibble())
    suppressWarnings(
      st_intersection(dplyr::select(hex_sf_r, hex_id), st_union(ym))
    ) |>
      mutate(own_new_ha = as.numeric(st_area(geometry)) / 1e4) |>
      st_drop_geometry() |>
      group_by(hex_id) |>
      summarise(own_new_ha = sum(own_new_ha), year = yr, .groups = "drop")
  })

  # Expand to full hex x year panel (0-fill non-mining hex-years)
  own_panel_r <- expand_grid(hex_id = hex_sf_r$hex_id, year = mining_years) |>
    left_join(new_own_r, by = c("hex_id", "year")) |>
    mutate(own_new_ha = replace_na(own_new_ha, 0))

  # Queen adjacency: for each hex, sum own_new_ha of its queen neighbours
  message(sprintf("  Building queen adjacency (%d hexes)...", nrow(hex_sf_r)))
  nb_r       <- spdep::poly2nb(hex_sf_r, queen = TRUE)
  adj_sets_r <- setNames(
    lapply(seq_along(nb_r), \(i) {
      idx <- nb_r[[i]]; hex_sf_r$hex_id[idx[idx > 0]]
    }),
    hex_sf_r$hex_id
  )

  own_wide_r <- own_panel_r |>
    pivot_wider(names_from = hex_id, values_from = own_new_ha, values_fill = 0)
  yrs_r  <- own_wide_r$year
  Mo_r   <- as.matrix(dplyr::select(own_wide_r, -year))
  colnames(Mo_r) <- base::setdiff(names(own_wide_r), "year")

  adj_new_r <- map_dfr(hex_sf_r$hex_id, \(v) {
    s   <- adj_sets_r[[v]]; s <- s[s %in% colnames(Mo_r)]
    agg <- if (length(s)) rowSums(Mo_r[, s, drop = FALSE]) else rep(0, length(yrs_r))
    tibble(hex_id = v, year = yrs_r, adj_new_ha = agg)
  })

  out_r <- own_panel_r |>
    left_join(adj_new_r, by = c("hex_id", "year")) |>
    mutate(adj_new_ha = replace_na(adj_new_ha, 0)) |>
    arrange(hex_id, year)

  n_own_treated <- n_distinct(out_r$hex_id[out_r$own_new_ha > 0])
  n_adj_treated <- n_distinct(out_r$hex_id[out_r$adj_new_ha > 0])
  message(sprintf("  Hexes with any own mining:       %d", n_own_treated))
  message(sprintf("  Hexes with any adjacent mining:  %d", n_adj_treated))

  saveRDS(out_r, out_path)
  message(sprintf("Saved: %s  (%d rows)", out_path, nrow(out_r)))

  rm(hex_sf_r, new_own_r, own_panel_r, adj_new_r, own_wide_r, Mo_r,
     nb_r, adj_sets_r, out_r)
  gc()
}

message("\n=== b_03b_own_mining.R complete ===")
