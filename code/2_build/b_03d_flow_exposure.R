# b_03c_flow_exposure.R
# Propagate galamsey upstream and downstream over the MERIT D8 hex flow graph.
# Part 3 of 4 in the modular event-panel build.
#
# Inputs:
#   hex_{N}km_own_mining.rds                       — own_new_ha per hex x year (from b_03b)
#   data/processed/merit/hex_flow_edges_{N}km.csv  — directed flow graph (from d_04_merit.R Sec 11)
#   hex_{N}km_crosssection.rds                     — hex_sf for queen-adjacency (lateral only)
#
# Outputs: data/processed/hex_{N}km_flow_exposure.rds
#   tibble(hex_id, year,
#          up_new_ha, down_new_ha,                       — full-catchment flow
#          nearest_up_new_ha, nearest_down_new_ha,       — 1-hop flow only
#          nearest_up_onset_year, nearest_down_onset_year,
#          lateral_new_ha)                               — queen-adj minus 1-hop up/down
#   covering flow-graph hexes x years 2007:2017 when flow edges present;
#   all hexes x years 2007:2017 with NA columns when flow edges absent (stub).
#
# Stock columns and lateral_onset_year are computed in b_03e_assemble_eventpanel.R.
#
# Re-run when: flow edges file is added or updated for a given resolution.

RESOLUTIONS <- c(1, 2, 5)

pacman::p_load(igraph, sf, spdep, tidyverse, conflicted, here)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)

# Propagate own_new_ha from all reachable sources in the given direction.
# Returns tibble(hex_id, year, new_agg) for graph vertices only.
propagate_new <- function(edges, own_wide, yrs, mode = c("in", "out")) {
  mode <- match.arg(mode)
  g   <- igraph::graph_from_data_frame(dplyr::select(edges, from_hex, to_hex), directed = TRUE)
  vn  <- igraph::V(g)$name
  M   <- as.matrix(dplyr::select(own_wide, -year))
  colnames(M) <- base::setdiff(names(own_wide), "year")
  sets <- setNames(
    lapply(vn, \(v)
      base::setdiff(igraph::V(g)$name[igraph::subcomponent(g, v, mode = mode)], v)),
    vn
  )
  map_dfr(vn, \(v) {
    s   <- sets[[v]]; s <- s[s %in% colnames(M)]
    agg <- if (length(s)) rowSums(M[, s, drop = FALSE]) else rep(0, length(yrs))
    tibble(hex_id = v, year = yrs, new_agg = agg)
  })
}

# Sum own_new_ha over a fixed per-hex neighbour set (1-hop; no recursion).
# `sets` is a named list: sets[[v]] = character vector of neighbour hex IDs.
aggregate_1hop <- function(sets, own_wide, yrs) {
  M  <- as.matrix(dplyr::select(own_wide, -year))
  colnames(M) <- base::setdiff(names(own_wide), "year")
  map_dfr(names(sets), \(v) {
    nb  <- sets[[v]]; nb <- nb[nb %in% colnames(M)]
    agg <- if (length(nb)) rowSums(M[, nb, drop = FALSE]) else rep(0, length(yrs))
    tibble(hex_id = v, year = yrs, new_agg = agg)
  })
}

for (res_km in RESOLUTIONS) {
  own_path  <- here("data", "processed", sprintf("hex_%dkm_own_mining.rds",  res_km))
  flow_path <- here("data", "processed", "merit",
                    sprintf("hex_flow_edges_%dkm.csv", res_km))
  out_path  <- here("data", "processed", sprintf("hex_%dkm_flow_exposure.rds", res_km))

  if (!file.exists(own_path)) {
    message(sprintf("Skipping %d km: hex_%dkm_own_mining.rds not found — run b_03b first.",
                    res_km, res_km))
    next
  }

  message(sprintf("\n%s\n=== Flow exposure: %d km ===\n%s",
                  strrep("=", 55), res_km, strrep("=", 55)))

  own_r        <- readRDS(own_path)
  all_hex_ids  <- unique(own_r$hex_id)
  mining_years <- sort(unique(own_r$year))

  # If flow edges absent, write NA stub so b_03d can always run
  if (!file.exists(flow_path)) {
    message(sprintf("  hex_flow_edges_%dkm.csv not found — writing NA stub.", res_km))
    stub <- expand_grid(hex_id = all_hex_ids, year = mining_years) |>
      mutate(up_new_ha = NA_real_, down_new_ha = NA_real_,
             nearest_up_onset_year = NA_real_, nearest_down_onset_year = NA_real_)
    saveRDS(stub, out_path)
    message(sprintf("Saved (stub): %s", out_path))
    next
  }

  edges_r <- read_csv(flow_path, show_col_types = FALSE)
  overlap  <- mean(unique(c(edges_r$from_hex, edges_r$to_hex)) %in% all_hex_ids)
  if (overlap < 0.5) {
    warning(sprintf("Flow edges overlap %d km grid only %.0f%% — writing NA stub.",
                    res_km, 100 * overlap))
    stub <- expand_grid(hex_id = all_hex_ids, year = mining_years) |>
      mutate(up_new_ha = NA_real_, down_new_ha = NA_real_,
             nearest_up_onset_year = NA_real_, nearest_down_onset_year = NA_real_)
    saveRDS(stub, out_path)
    message(sprintf("Saved (stub): %s", out_path))
    next
  }

  message(sprintf("  Flow graph: %d edges", nrow(edges_r)))

  own_wide_r <- own_r |>
    dplyr::select(hex_id, year, own_new_ha) |>
    pivot_wider(names_from = hex_id, values_from = own_new_ha, values_fill = 0)
  yrs_r <- own_wide_r$year

  message("  Propagating upstream mining (mode = in)...")
  up_r   <- propagate_new(edges_r, own_wide_r, yrs_r, "in")  |> rename(up_new_ha   = new_agg)
  message("  Propagating downstream mining (mode = out)...")
  down_r <- propagate_new(edges_r, own_wide_r, yrs_r, "out") |> rename(down_new_ha = new_agg)

  # nearest_up/down_onset_year: earliest own-onset among immediate 1-hop graph neighbours
  g_r  <- igraph::graph_from_data_frame(dplyr::select(edges_r, from_hex, to_hex), directed = TRUE)
  vn_r <- igraph::V(g_r)$name
  own_onset_r <- own_r |>
    dplyr::filter(own_new_ha > 0) |>
    group_by(hex_id) |>
    summarise(own_onset_year = min(year), .groups = "drop")
  nearest_r <- tibble(hex_id = vn_r) |>
    mutate(
      nearest_up_onset_year = map_dbl(hex_id, \(v) {
        nb <- names(igraph::neighbors(g_r, v, mode = "in"))
        oy <- own_onset_r$own_onset_year[match(nb, own_onset_r$hex_id)]
        if (all(is.na(oy))) NA_real_ else min(oy, na.rm = TRUE)
      }),
      nearest_down_onset_year = map_dbl(hex_id, \(v) {
        nb <- names(igraph::neighbors(g_r, v, mode = "out"))
        oy <- own_onset_r$own_onset_year[match(nb, own_onset_r$hex_id)]
        if (all(is.na(oy))) NA_real_ else min(oy, na.rm = TRUE)
      })
    )

  # nearest_up/down_new_ha: 1-hop aggregation of own_new_ha (no recursion)
  message("  Aggregating 1-hop upstream/downstream new_ha...")
  nearest_up_sets_r   <- setNames(lapply(vn_r, \(v) names(igraph::neighbors(g_r, v, mode = "in"))),  vn_r)
  nearest_down_sets_r <- setNames(lapply(vn_r, \(v) names(igraph::neighbors(g_r, v, mode = "out"))), vn_r)
  near_up_r   <- aggregate_1hop(nearest_up_sets_r,   own_wide_r, yrs_r) |> rename(nearest_up_new_ha   = new_agg)
  near_down_r <- aggregate_1hop(nearest_down_sets_r, own_wide_r, yrs_r) |> rename(nearest_down_new_ha = new_agg)

  # lateral_new_ha: queen-adjacent minus 1-hop upstream/downstream
  message("  Computing lateral (queen − 1-hop up/down) new_ha...")
  cross_path_r <- here("data", "processed", sprintf("hex_%dkm_crosssection.rds", res_km))
  if (file.exists(cross_path_r)) {
    hex_sf_tmp   <- readRDS(cross_path_r)$hex_sf
    nb_queen_r   <- spdep::poly2nb(hex_sf_tmp, queen = TRUE)
    all_vn_r     <- hex_sf_tmp$hex_id
    queen_sets_r <- setNames(
      lapply(seq_along(all_vn_r), \(i) {
        nb <- nb_queen_r[[i]]
        if (nb[1] == 0L) character(0) else all_vn_r[nb]
      }),
      all_vn_r
    )
    rm(hex_sf_tmp, nb_queen_r); gc()
    lateral_sets_r <- setNames(
      lapply(vn_r, \(v) base::setdiff(queen_sets_r[[v]],
                                       union(nearest_up_sets_r[[v]], nearest_down_sets_r[[v]]))),
      vn_r
    )
    rm(queen_sets_r); gc()
    lateral_r <- aggregate_1hop(lateral_sets_r, own_wide_r, yrs_r) |> rename(lateral_new_ha = new_agg)
    rm(lateral_sets_r); gc()
  } else {
    message(sprintf("  hex_%dkm_crosssection.rds not found — lateral will be NA.", res_km))
    lateral_r <- expand_grid(hex_id = vn_r, year = yrs_r) |> mutate(lateral_new_ha = NA_real_)
  }

  out_r <- full_join(up_r, down_r, by = c("hex_id", "year")) |>
    left_join(near_up_r,   by = c("hex_id", "year")) |>
    left_join(near_down_r, by = c("hex_id", "year")) |>
    left_join(lateral_r,   by = c("hex_id", "year")) |>
    left_join(nearest_r,   by = "hex_id") |>
    arrange(hex_id, year)

  n_up   <- n_distinct(out_r$hex_id[out_r$up_new_ha   > 0])
  n_down <- n_distinct(out_r$hex_id[out_r$down_new_ha > 0])
  n_lat  <- n_distinct(out_r$hex_id[!is.na(out_r$lateral_new_ha) & out_r$lateral_new_ha > 0])
  message(sprintf("  Graph hexes: %d | any upstream mining: %d | downstream: %d | lateral: %d",
                  n_distinct(out_r$hex_id), n_up, n_down, n_lat))

  saveRDS(out_r, out_path)
  message(sprintf("Saved: %s", out_path))

  rm(own_r, edges_r, own_wide_r, up_r, down_r, near_up_r, near_down_r, lateral_r,
     nearest_up_sets_r, nearest_down_sets_r,
     g_r, vn_r, own_onset_r, nearest_r, out_r)
  gc()
}

message("\n=== b_03c_flow_exposure.R complete ===")
