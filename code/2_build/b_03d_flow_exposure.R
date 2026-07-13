# b_03d_flow_exposure.R
# Propagate galamsey upstream and downstream over the MERIT D8 hex flow graph.
# Part 4 of 5 in the modular event-panel build.
#
# Runs once per ROUTE_KM2 threshold config (see b_03c_flow_graph.R): the PRIMARY (10 km²,
# unsuffixed files) and ALT (50 km², "_upa50" files) flow graphs each get their own exposure cache.
#
# EXPOSURE IS BUILT AS HOP RINGS (as of 2026-07-10). For each k in 1..K_HOPS, the ring-k set of a
# hex is the hexes at shortest-path distance EXACTLY k along the directed flow graph — upstream
# (mode = "in") or downstream (mode = "out"). Rings are disjoint, so they partition the within-K
# neighbourhood and the cumulative "within k hops" exposure is recovered downstream by summing:
#     up_le3_new_ha = nearest_up_new_ha + up_hop2_new_ha + up_hop3_new_ha
#     up_le3_stock_ha likewise (cumsum is linear); cumulative onset = pmin() over ring onsets.
# Rings are therefore a sufficient statistic for the nested sets, and additionally let hop-1/2/3
# enter one regression to trace attenuation with hydrological distance. A hex reachable at two
# different path lengths is assigned to its SHORTEST-path ring.
# The k = Inf case is already built separately: up_new_ha / down_new_ha (full reachable catchment,
# via igraph::subcomponent) are unchanged by this refactor.
#
# LATERAL IS DEFINED AGAINST THE FULL K-HOP NEIGHBOURHOOD, not against ring k:
#     lateral_ring_k = queen_ring_k \ (up_within_K  ∪  down_within_K)
# i.e. the max hop K — not k — drives the exclusion. This guarantees (a) no hex is ever both
# lateral and flow-treated at any radius, and (b) the lateral rings sum to the cumulative lateral
# set exactly as the flow rings do. NOTE this makes k = 1 STRICTER than the pre-2026-07-10
# definition (which subtracted only the 1-hop up/down sets), so `lateral_new_ha` values change:
# hexes that are queen-adjacent but 2-3 hops up/down along the channel now leave the lateral set.
#
# Hops are hydrological topology, not distance. Flow edges join geographically adjacent hexes, so
# k hops ≈ k hex-widths ALONG A MEANDERING CHANNEL: ~3 km at the 1 km grid but ~15 km at the 5 km
# grid. Hop-k coefficients are NOT comparable across resolutions.
#
# Inputs (per threshold suffix S in {"", "_upa50"}):
#   hex_{N}km_own_mining.rds                          — own_new_ha per hex x year (from b_03b)
#   data/processed/merit/hex_flow_edges_{N}km{S}.csv  — directed flow graph (from b_03c)
#   hex_{N}km_crosssection.rds                        — hex_sf for queen-adjacency rings (lateral only)
#
# Outputs: data/processed/hex_{N}km_flow_exposure{S}.rds
#   tibble(hex_id, year,
#          up_new_ha, down_new_ha,                        — full-catchment flow (k = Inf)
#          nearest_up_new_ha, nearest_down_new_ha,        — ring 1 (names kept for back-compat)
#          lateral_new_ha,                                — queen ring 1 minus within-K up/down
#          up_hop{k}_new_ha, down_hop{k}_new_ha,          — rings 2..K_HOPS
#          lateral_hop{k}_new_ha)
#   covering flow-graph hexes x years 2007:2017 when flow edges present;
#   all hexes x years 2007:2017 with NA columns when flow edges absent (stub).
#
# Stock columns and ALL onset years (including nearest_up_onset_year / nearest_down_onset_year,
# which this script used to compute directly) are now derived uniformly in
# b_03e_assemble_eventpanel.R from the *_new_ha columns. min{year : ring_new_ha > 0} equals the
# min own_onset_year over ring members because own_new_ha >= 0, so this is the same quantity by a
# single code path rather than two.
#
# Re-run when: flow edges file is added or updated for a given resolution, or K_HOPS changes.

# === USER PARAMETERS ===
RESOLUTIONS    <- c(1, 2, 5)
ROUTE_SUFFIXES <- c("", "_upa50")   # must match ROUTE_CONFIGS suffixes in b_03c_flow_graph.R
K_HOPS         <- 3L                # max hop ring to build (k = 1..K_HOPS); also the lateral-exclusion radius

pacman::p_load(igraph, sf, spdep, tidyverse, conflicted, here)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)

stopifnot(K_HOPS >= 1L)

# Column name for a given direction / ring / stem. Ring 1 keeps its historical names
# (nearest_up_*, nearest_down_*, lateral_*) so existing panels and analysis scripts still resolve.
hop_col <- function(dir, k, stem) {
  if (k == 1L) {
    if (identical(dir, "lateral")) paste0("lateral_", stem)
    else                           paste0("nearest_", dir, "_", stem)
  } else {
    paste0(dir, "_hop", k, "_", stem)
  }
}

# Every *_new_ha ring column this script emits, in build order (used for the NA stub).
ring_new_cols <- function(K) {
  unlist(lapply(seq_len(K), \(k)
    c(hop_col("up", k, "new_ha"), hop_col("down", k, "new_ha"), hop_col("lateral", k, "new_ha"))))
}

# Propagate own_new_ha from all reachable sources in the given direction (k = Inf).
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

# Sum own_new_ha over a fixed per-hex neighbour set (no recursion — the set is already resolved).
# `sets` is a named list: sets[[v]] = character vector of neighbour hex IDs.
aggregate_sets <- function(sets, own_wide, yrs) {
  M  <- as.matrix(dplyr::select(own_wide, -year))
  colnames(M) <- base::setdiff(names(own_wide), "year")
  map_dfr(names(sets), \(v) {
    nb  <- sets[[v]]; nb <- nb[nb %in% colnames(M)]
    agg <- if (length(nb)) rowSums(M[, nb, drop = FALSE]) else rep(0, length(yrs))
    tibble(hex_id = v, year = yrs, new_agg = agg)
  })
}

# Vertices at shortest-path distance EXACTLY k from each vertex (mindist = order = k).
graph_ring <- function(g, k, mode) {
  vn <- igraph::V(g)$name
  setNames(
    lapply(igraph::ego(g, order = k, nodes = igraph::V(g), mode = mode, mindist = k), names),
    vn
  )
}

# Queen-contiguity rings 1..K as named lists of hex_ids. spdep::nblag() rejects maxlag = 1,
# and encodes "no neighbours" as the single value 0L.
queen_rings <- function(hex_sf, K) {
  nb   <- spdep::poly2nb(hex_sf, queen = TRUE)
  lags <- if (K == 1L) list(nb) else suppressWarnings(spdep::nblag(nb, maxlag = K))
  ids  <- hex_sf$hex_id
  lapply(lags, \(nb_k) setNames(
    lapply(seq_along(ids), \(i) {
      j <- nb_k[[i]]
      if (length(j) == 0L || j[1] == 0L) character(0) else ids[j]
    }),
    ids
  ))
}

for (res_km in RESOLUTIONS) {
  own_path <- here("data", "processed", sprintf("hex_%dkm_own_mining.rds",  res_km))

  if (!file.exists(own_path)) {
    message(sprintf("Skipping %d km: hex_%dkm_own_mining.rds not found — run b_03b first.",
                    res_km, res_km))
    next
  }
  own_r_shared <- readRDS(own_path)

  # Queen rings depend only on the hex grid, not on the flow graph — build once per resolution
  # and reuse across ROUTE_SUFFIXES. NULL when the crosssection cache is absent (lateral -> NA).
  cross_path_r <- here("data", "processed", sprintf("hex_%dkm_crosssection.rds", res_km))
  queen_ring_sets <- if (file.exists(cross_path_r)) {
    hex_sf_tmp <- readRDS(cross_path_r)$hex_sf
    qr <- queen_rings(hex_sf_tmp, K_HOPS)
    rm(hex_sf_tmp); gc()
    qr
  } else {
    message(sprintf("  hex_%dkm_crosssection.rds not found — lateral columns will be NA.", res_km))
    NULL
  }

  for (suffix in ROUTE_SUFFIXES) {
  flow_path <- here("data", "processed", "merit",
                    sprintf("hex_flow_edges_%dkm%s.csv", res_km, suffix))
  out_path  <- here("data", "processed", sprintf("hex_%dkm_flow_exposure%s.rds", res_km, suffix))

  message(sprintf("\n%s\n=== Flow exposure: %d km%s (K_HOPS = %d) ===\n%s",
                  strrep("=", 55), res_km,
                  if (nzchar(suffix)) sprintf(" (%s)", suffix) else " (primary)",
                  K_HOPS, strrep("=", 55)))

  own_r        <- own_r_shared
  all_hex_ids  <- unique(own_r$hex_id)
  mining_years <- sort(unique(own_r$year))

  # If flow edges absent (or barely overlapping this grid), write NA stub so b_03e can always run.
  write_stub <- function(reason) {
    message(sprintf("  %s — writing NA stub.", reason))
    stub <- expand_grid(hex_id = all_hex_ids, year = mining_years) |>
      mutate(up_new_ha = NA_real_, down_new_ha = NA_real_)
    for (cn in ring_new_cols(K_HOPS)) stub[[cn]] <- NA_real_
    saveRDS(stub, out_path)
    message(sprintf("Saved (stub): %s", out_path))
  }

  if (!file.exists(flow_path)) {
    write_stub(sprintf("%s not found", basename(flow_path)))
    next
  }

  edges_r <- read_csv(flow_path, show_col_types = FALSE)
  overlap <- mean(unique(c(edges_r$from_hex, edges_r$to_hex)) %in% all_hex_ids)
  if (overlap < 0.5) {
    warning(sprintf("Flow edges overlap %d km grid only %.0f%% — writing NA stub.",
                    res_km, 100 * overlap))
    write_stub(sprintf("flow edges overlap only %.0f%%", 100 * overlap))
    next
  }

  message(sprintf("  Flow graph: %d edges", nrow(edges_r)))

  own_wide_r <- own_r |>
    dplyr::select(hex_id, year, own_new_ha) |>
    pivot_wider(names_from = hex_id, values_from = own_new_ha, values_fill = 0)
  yrs_r <- own_wide_r$year

  ####1. Full-catchment exposure (k = Inf) ####

  message("  Propagating upstream mining (mode = in)...")
  up_r   <- propagate_new(edges_r, own_wide_r, yrs_r, "in")  |> rename(up_new_ha   = new_agg)
  message("  Propagating downstream mining (mode = out)...")
  down_r <- propagate_new(edges_r, own_wide_r, yrs_r, "out") |> rename(down_new_ha = new_agg)

  ####2. Hop rings 1..K_HOPS on the flow graph ####

  g_r  <- igraph::graph_from_data_frame(dplyr::select(edges_r, from_hex, to_hex), directed = TRUE)
  vn_r <- igraph::V(g_r)$name

  message(sprintf("  Building upstream/downstream rings k = 1..%d...", K_HOPS))
  up_rings   <- lapply(seq_len(K_HOPS), \(k) graph_ring(g_r, k, "in"))
  down_rings <- lapply(seq_len(K_HOPS), \(k) graph_ring(g_r, k, "out"))

  ####3. Lateral rings — queen ring k minus the WITHIN-K flow neighbourhood ####
  # Union over all rings 1..K == ego(order = K, mindist = 1), by disjointness of the rings.

  flow_excl_r <- setNames(
    lapply(vn_r, \(v) unique(c(
      unlist(lapply(up_rings,   \(s) s[[v]]), use.names = FALSE),
      unlist(lapply(down_rings, \(s) s[[v]]), use.names = FALSE)
    ))),
    vn_r
  )

  lat_rings <- if (!is.null(queen_ring_sets)) {
    message("  Computing lateral rings (queen ring k − within-K up/down)...")
    lapply(seq_len(K_HOPS), \(k) setNames(
      lapply(vn_r, \(v) {
        q <- queen_ring_sets[[k]][[v]]
        if (is.null(q)) character(0) else base::setdiff(q, flow_excl_r[[v]])
      }),
      vn_r
    ))
  } else NULL

  ####4. Aggregate own_new_ha over every ring set ####

  message("  Aggregating new_ha over rings...")
  ring_tbls <- list()
  for (k in seq_len(K_HOPS)) {
    ring_tbls[[length(ring_tbls) + 1L]] <-
      aggregate_sets(up_rings[[k]], own_wide_r, yrs_r) |>
      rename(!!hop_col("up", k, "new_ha") := new_agg)
    ring_tbls[[length(ring_tbls) + 1L]] <-
      aggregate_sets(down_rings[[k]], own_wide_r, yrs_r) |>
      rename(!!hop_col("down", k, "new_ha") := new_agg)
    ring_tbls[[length(ring_tbls) + 1L]] <- if (!is.null(lat_rings)) {
      aggregate_sets(lat_rings[[k]], own_wide_r, yrs_r) |>
        rename(!!hop_col("lateral", k, "new_ha") := new_agg)
    } else {
      expand_grid(hex_id = vn_r, year = yrs_r) |>
        mutate(!!hop_col("lateral", k, "new_ha") := NA_real_)
    }
  }
  rings_r <- Reduce(\(a, b) full_join(a, b, by = c("hex_id", "year")), ring_tbls)

  ####5. Assemble and write ####

  out_r <- full_join(up_r, down_r, by = c("hex_id", "year")) |>
    left_join(rings_r, by = c("hex_id", "year")) |>
    arrange(hex_id, year)

  n_pos <- function(cn) if (all(is.na(out_r[[cn]]))) NA_integer_
                        else n_distinct(out_r$hex_id[!is.na(out_r[[cn]]) & out_r[[cn]] > 0])
  message(sprintf("  Graph hexes: %d | any upstream (catchment): %d | downstream: %d",
                  n_distinct(out_r$hex_id), n_pos("up_new_ha"), n_pos("down_new_ha")))
  for (k in seq_len(K_HOPS)) {
    message(sprintf("    ring %d — hexes with mining: up %s | down %s | lateral %s", k,
                    n_pos(hop_col("up", k, "new_ha")),
                    n_pos(hop_col("down", k, "new_ha")),
                    n_pos(hop_col("lateral", k, "new_ha"))))
  }

  saveRDS(out_r, out_path)
  message(sprintf("Saved: %s", out_path))

  rm(own_r, edges_r, own_wide_r, up_r, down_r, g_r, vn_r,
     up_rings, down_rings, lat_rings, flow_excl_r, ring_tbls, rings_r, out_r)
  gc()
  }   # end ROUTE_SUFFIXES loop

  rm(own_r_shared, queen_ring_sets)
  gc()
}

message("\n=== b_03d_flow_exposure.R complete ===")
message("  Next: run b_03e_assemble_eventpanel.R to add stock/onset columns and build the panel.")
