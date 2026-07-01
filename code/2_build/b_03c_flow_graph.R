# b_03c_flow_graph.R
# Build directed D8 hex-to-hex flow graphs from MERIT Hydro native 4326 rasters.
# Part 3 of 5 in the modular event-panel build; prerequisite for b_03d_flow_exposure.R.
#
# An edge hex_A -> hex_B means water flows from A into B (A upstream, B downstream).
# Only channel cells (upa > ROUTE_KM2) source edges so the graph follows drainage divides
# rather than routing over ridges/hillslopes. ROUTE_KM2 = 10 km² is the validated choice
# from d_04_merit.R Sec 11j: 5.5% of mined ha off-network at 10 km² vs 23% at 50 km².
# Routing traces on the NATIVE 4326 dir/upa grids — reprojecting D8 pointer codes corrupts
# routing (confirmed cell-level cycles on the UTM grid; see d_04_merit.R header).
#
# Inputs:
#   data/raw/merit/merit_hydro_{REGION_TAG}*.tif  — native 4326 MERIT Hydro GeoTIFF(s),
#     bands: dir (D8 ESRI codes), upa (upstream area km²), wth, elv.
#     Downloaded + mosaiced by d_04_merit.R Secs 4-5.
#   hex_{N}km_crosssection.rds  — hex grid, from b_01_cross_section.R.
#
# Outputs (data/processed/merit/ per resolution N):
#   hex_flow_edges_{N}km.csv      — tibble(from_hex, to_hex, n_crossings, flow_weight)
#   hex_downstreamness_{N}km.csv  — tibble(hex_id, mean_log_upa, n_chan_cells)
#
# Re-run when: MERIT data updated, or hex resolution changes.
# For context on design decisions and validation: d_04_merit.R Sec 11 + session logs.

# === USER PARAMETERS ===
RESOLUTIONS <- c(1, 2, 5)   # km
ROUTE_KM2   <- 10            # channel routing threshold; see header for rationale
REGION_TAG  <- "studyarea"   # must match the tag used in d_04_merit.R

pacman::p_load(sf, terra, igraph, tidyverse, conflicted, here)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)

proc_dir <- here("data", "processed", "merit")
dir.create(proc_dir, recursive = TRUE, showWarnings = FALSE)

# Read MERIT export: mosaic multi-tile GeoTIFFs via VRT if needed.
# Uses the native 4326 RAW download, NOT the UTM working file.
read_merit_raw <- function(prefix, raw_dir = here("data", "raw", "merit")) {
  tiles <- list.files(raw_dir, pattern = paste0("^", prefix, ".*\\.tif$"), full.names = TRUE)
  if (!length(tiles)) return(NULL)
  if (length(tiles) == 1) terra::rast(tiles) else terra::vrt(tiles, overwrite = TRUE)
}

####1. Load MERIT Hydro rasters (shared across resolutions) ####

hydro_prefix <- paste0("merit_hydro_", REGION_TAG)
hydro_ll     <- read_merit_raw(hydro_prefix)

if (is.null(hydro_ll)) {
  stop(sprintf(
    "MERIT Hydro rasters not found (pattern: '%s*.tif' in data/raw/merit/).\n",
    hydro_prefix),
    "Run d_04_merit.R Secs 4-5 to download and fetch from Drive first.")
}

names(hydro_ll) <- c("dir", "upa", "wth", "elv")
dir_r <- hydro_ll[["dir"]]
upa_r <- hydro_ll[["upa"]]
message(sprintf("MERIT Hydro loaded (%d x %d cells, native 4326)", nrow(dir_r), ncol(dir_r)))
message(sprintf("  Channel cells at ROUTE_KM2 = %g km²: %d",
                ROUTE_KM2, sum(terra::values(upa_r) > ROUTE_KM2, na.rm = TRUE)))

# ESRI D8 direction codes -> (row offset, col offset). Row 1 = north; +row = south.
#   E=1:(0,+1)  SE=2:(+1,+1)  S=4:(+1,0)  SW=8:(+1,-1)
#   W=16:(0,-1) NW=32:(-1,-1) N=64:(-1,0) NE=128:(-1,+1)
d8_off <- list(`1`   = c( 0,  1), `2`   = c( 1,  1),
               `4`   = c( 1,  0), `8`   = c( 1, -1),
               `16`  = c( 0, -1), `32`  = c(-1, -1),
               `64`  = c(-1,  0), `128` = c(-1,  1))

# Pull to matrices once (wide = row-major; persistent across the resolution loop)
dir_m <- terra::as.matrix(dir_r, wide = TRUE)
upa_m <- terra::as.matrix(upa_r, wide = TRUE)
nr    <- nrow(dir_m)
nc    <- ncol(dir_m)

# Channel source cells: upa above threshold with a defined direction
chan_idx <- which(upa_m > ROUTE_KM2 & !is.na(dir_m), arr.ind = TRUE)
rr       <- chan_idx[, 1]
cc       <- chan_idx[, 2]
codes    <- dir_m[chan_idx]

# Resolve D8 offsets for every channel cell
drv <- dcv <- rep(NA_integer_, length(codes))
for (k in names(d8_off)) {
  sel        <- codes == as.integer(k)
  drv[sel]   <- d8_off[[k]][1]
  dcv[sel]   <- d8_off[[k]][2]
}
r2        <- rr + drv
c2        <- cc + dcv
in_bounds <- !is.na(drv) & r2 >= 1 & r2 <= nr & c2 >= 1 & c2 <= nc
flow_w    <- upa_m[cbind(rr, cc)]   # flow magnitude at the source cell

####2. Per-resolution loop ####

have_res <- RESOLUTIONS[file.exists(
  here("data", "processed", sprintf("hex_%dkm_crosssection.rds", RESOLUTIONS))
)]
if (!length(have_res)) stop("No crosssection caches found. Run b_01_cross_section.R first.")
message(sprintf("\nResolutions with caches: %s km", paste(have_res, collapse = ", ")))

for (res_km in have_res) {
  out_edges <- file.path(proc_dir, sprintf("hex_flow_edges_%dkm.csv",     res_km))
  out_down  <- file.path(proc_dir, sprintf("hex_downstreamness_%dkm.csv", res_km))

  message(sprintf("\n%s\n=== Flow graph: %d km ===\n%s",
                  strrep("=", 55), res_km, strrep("=", 55)))

  hex_sf_r <- readRDS(
    here("data", "processed", sprintf("hex_%dkm_crosssection.rds", res_km))
  )$hex_sf |>
    dplyr::mutate(hex_num = as.integer(str_extract(hex_id, "\\d+")))
  message(sprintf("  Hex grid: %d hexes", nrow(hex_sf_r)))

  ####2a. Rasterise hex IDs onto the native 4326 MERIT grid ####
  hex_ll   <- sf::st_transform(hex_sf_r, 4326)
  hex_id_r <- terra::rasterize(terra::vect(hex_ll), dir_r, field = "hex_num")
  hex_m    <- terra::as.matrix(hex_id_r, wide = TRUE)

  ####2b. Cross-hex edges from D8 cell pairs ####
  from_hex         <- hex_m[cbind(rr, cc)]
  to_hex           <- rep(NA_integer_, length(rr))
  to_hex[in_bounds] <- hex_m[cbind(r2[in_bounds], c2[in_bounds])]

  edge_ok   <- in_bounds & !is.na(from_hex) & !is.na(to_hex) & from_hex != to_hex
  edges_agg <- tibble(from = from_hex[edge_ok],
                      to   = to_hex[edge_ok],
                      flow = flow_w[edge_ok]) |>
    group_by(from, to) |>
    summarise(n_crossings = n(), flow_weight = sum(flow), .groups = "drop")

  ####2c. Net dominant direction (resolve bidirectional pairs) ####
  edges_net <- edges_agg |>
    mutate(a = pmin(from, to), b = pmax(from, to)) |>
    group_by(a, b) |>
    summarise(
      fwd         = sum(flow_weight[from == a]),
      rev         = sum(flow_weight[from == b]),
      n_crossings = sum(n_crossings),
      .groups     = "drop"
    ) |>
    mutate(
      from        = if_else(fwd >= rev, a, b),
      to          = if_else(fwd >= rev, b, a),
      flow_weight = abs(fwd - rev)
    ) |>
    dplyr::filter(flow_weight > 0) |>
    transmute(
      from_hex    = paste0("hex_", from),
      to_hex      = paste0("hex_", to),
      n_crossings,
      flow_weight
    )

  message(sprintf("  Raw graph: %d directed edges among %d hexes",
                  nrow(edges_net),
                  n_distinct(c(edges_net$from_hex, edges_net$to_hex))))

  ####2d. DAG validation + feedback-arc removal ####
  g_r    <- igraph::graph_from_data_frame(dplyr::select(edges_net, from_hex, to_hex),
                                           directed = TRUE)
  is_dag <- igraph::is_dag(g_r)
  cat(sprintf("  Acyclic (raw): %s\n", is_dag))

  if (!is_dag) {
    fas       <- as.integer(igraph::feedback_arc_set(g_r, algo = "approx_eades"))
    frac_flow <- sum(edges_net$flow_weight[fas]) / sum(edges_net$flow_weight)
    g_r       <- igraph::delete_edges(g_r, fas)
    edges_net <- edges_net[-fas, ]
    is_dag    <- igraph::is_dag(g_r)
    cat(sprintf("  Removed %d feedback edge(s) (%.2f%% of flow weight) -> acyclic: %s\n",
                length(fas), 100 * frac_flow, is_dag))
  }

  ####2e. Downstreamness scalar — mean log(upa) over channel cells per hex ####
  downstreamness_r <- tibble(hex_num = hex_m[chan_idx],
                              upa     = upa_m[chan_idx]) |>
    dplyr::filter(!is.na(hex_num)) |>
    group_by(hex_num) |>
    summarise(mean_log_upa  = mean(log(upa)),
              n_chan_cells  = n(),
              .groups       = "drop") |>
    mutate(hex_id = paste0("hex_", hex_num)) |>
    dplyr::select(hex_id, mean_log_upa, n_chan_cells)

  ####2f. Validation: Spearman(mean_log_upa, northing) ####
  # Negative expected: SW Ghana rivers drain broadly south, so downstream hexes sit further
  # south. |rho| well below 1 quantifies where the northing proxy reorders.
  hex_north_r <- hex_sf_r |>
    dplyr::mutate(northing = sf::st_coordinates(sf::st_centroid(geometry))[, 2]) |>
    sf::st_drop_geometry() |>
    dplyr::select(hex_id, northing)
  cmp_r <- left_join(downstreamness_r, hex_north_r, by = "hex_id")
  rho_r <- cor(cmp_r$mean_log_upa, cmp_r$northing, method = "spearman", use = "complete.obs")
  cat(sprintf("  Spearman(mean_log_upa, northing): %.3f  (negative = downstream is south)\n",
              rho_r))

  ####2g. Write outputs ####
  readr::write_csv(edges_net,       out_edges)
  readr::write_csv(downstreamness_r, out_down)
  message(sprintf("Saved: %s", out_edges))
  message(sprintf("Saved: %s", out_down))

  rm(hex_sf_r, hex_ll, hex_id_r, hex_m, edges_agg, edges_net, g_r,
     downstreamness_r, hex_north_r, cmp_r)
  gc()
}

message("\n=== b_03c_flow_graph.R complete ===")
message(sprintf("  Next: run b_03d_flow_exposure.R to propagate upstream/downstream mining."))
