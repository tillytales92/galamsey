# make_industrial_mines_dataset.R
# Builds a standalone, reusable dataset of Ghana's named industrial (large-scale) gold mines --
# ICMM's own metadata (name, commodity, confidence) joined to a real digitized footprint per mine
# (Maus et al. 2022 v2 or Tang & Werner 2023, per mine, per IND_MINE_CONFIG). Until now this
# information only existed as an EE QA layer (industrial_final_selected_<date>, uploaded by
# upload_industrial_candidate_maus.R) and inside build_03_embedding_panel.R Section 7's in-memory
# logic -- this script persists it locally as its own artifact, ONE dissolved polygon per mine, for
# reuse beyond the exclusion-mask pipeline (maps, citation, a covariate in other analyses).
#
# Selection logic (ICMM confidence filter, the "replace"/"add" location-correction handling,
# IND_MINE_CONFIG's per-mine source + selection mode) MIRRORS build_03_embedding_panel.R Section 7a-
# 7d EXACTLY -- this project's scripts coordinate through data artifacts, not by sourcing each
# other, so it's duplicated rather than shared. If you change the config in build_03 (a new mine
# correction, a different buffer/mode), update it here too so this dataset stays representative.
#
# Unlike upload_industrial_candidate_maus.R's QA layer (which keeps every raw polygon fragment
# separate, for inspecting WHICH one got picked), this script DISSOLVES each mine's selection into
# ONE row -- this is a clean reference dataset, not a debugging tool.
#
# Output: data/processed/ghana_industrial_mines.{gpkg,shp} -- one feature per mine (14 rows), fields:
#   mine, icmm_id, commodity, confidence, source (maus/tangwerner), mode (buffer/touching_only/
#   contiguous), buffer_m (NA unless mode=="buffer"), n_icmm_points (1, or 2 for an IND_CORRECTION_
#   MODE "add" mine), n_src_polys (how many raw source polygons were dissolved into this one row),
#   area_km2.
#
# Run INTERACTIVELY (no EE/rgee needed -- this is pure sf, local files only).

####1. Environment ####
pacman::p_load(tidyverse, sf, here, xml2, tibble)

UTM30N <- 32630

IND_ICMM_KMZ            <- here("data", "raw", "mining_icmm", "global_mining_dataset_1.5_corrected.kmz")
IND_CORRECTION_MODE     <- c("Obuasi" = "add")   # MUST mirror build_03 Section 3
IND_MAUS_GPKG           <- here("data", "raw", "mining_mausetal", "global_mining_polygons_v2.gpkg")
IND_TANGWERNER_SHP      <- here("data", "raw", "mining_tangwerner", "74548_projected polygons.shp")
IND_ICMM_MIN_CONFIDENCE <- c("High", "Moderate")
IND_ICMM_BUFFER_M       <- 4000
IND_MAUS_MIN_KM2        <- 0
GHANA_BBOX_4326         <- c(xmin = -3.5, ymin = 4.3, xmax = 1.5, ymax = 11.2)
IND_TOUCH_TOLERANCE_M   <- 50
IND_MINE_CONFIG <- tibble::tribble(                 # MUST mirror build_03 Section 3 exactly
  ~mine,             ~source,       ~mode,            ~buffer_m,
  "Edikan",          "tangwerner",  "contiguous",     NA_real_,
  "Asanko Obotan",   "tangwerner",  "contiguous",     NA_real_,
  "Prestea",         "tangwerner",  "touching_only",  NA_real_,
  "Bogoso Prestea",  "maus",        "touching_only",  NA_real_,
  "Awaso",           "maus",        "buffer",         1000,
  "Obuasi",          "maus",        "buffer",         1000
)

####2. ICMM points -- named Ghana industrial mines, with location corrections applied ####
icmm_tmp <- tempfile()
unzip(IND_ICMM_KMZ, exdir = icmm_tmp)
icmm_kml <- list.files(icmm_tmp, pattern = "[.]kml$", full.names = TRUE)[1]
icmm_doc <- read_xml(icmm_kml)
icmm_ns  <- xml_ns(icmm_doc)
parse_icmm_pm <- function(pm) {
  sd   <- xml_find_all(pm, ".//d1:SimpleData", icmm_ns)
  vals <- setNames(xml_text(sd), xml_attr(sd, "name"))
  xy   <- as.numeric(strsplit(trimws(xml_text(xml_find_first(pm, ".//d1:coordinates", icmm_ns))), ",")[[1]][1:2])
  as.data.frame(c(as.list(vals), list(
    placemark_name = xml_text(xml_find_first(pm, ".//d1:name", icmm_ns)),
    lon = xy[1], lat = xy[2])), stringsAsFactors = FALSE)
}
icmm_all <- bind_rows(lapply(xml_find_all(icmm_doc, ".//d1:Placemark", icmm_ns), parse_icmm_pm))

# "replace" (default) overwrites the mine's coordinates; "add" (per IND_CORRECTION_MODE) keeps the
# correction as a 2nd point alongside the original -- see build_03 Section 7a for the full rationale.
corrections <- icmm_all[grepl("_corrected$", icmm_all$placemark_name), , drop = FALSE]
add_rows <- list()
for (i in seq_len(nrow(corrections))) {
  base_name <- sub("_corrected$", "", corrections$placemark_name[i])
  match_idx <- which(icmm_all$Mine_Name == base_name)
  if (length(match_idx) != 1) {
    warning(sprintf("ICMM correction placemark '%s' found but '%s' doesn't match exactly 1 existing mine (%d matches) -- NOT applied",
                    corrections$placemark_name[i], base_name, length(match_idx)))
    next
  }
  corr_mode <- if (base_name %in% names(IND_CORRECTION_MODE)) IND_CORRECTION_MODE[[base_name]] else "replace"
  if (corr_mode == "replace") {
    icmm_all$lon[match_idx] <- corrections$lon[i]
    icmm_all$lat[match_idx] <- corrections$lat[i]
  } else if (corr_mode == "add") {
    new_row <- icmm_all[match_idx, ]
    new_row$lon <- corrections$lon[i]; new_row$lat <- corrections$lat[i]
    new_row$placemark_name <- corrections$placemark_name[i]
    add_rows[[length(add_rows) + 1]] <- new_row
  } else stop("IND_CORRECTION_MODE['", base_name, "'] must be \"replace\" or \"add\", got: ", corr_mode)
}
icmm_all <- icmm_all[!grepl("_corrected$", icmm_all$placemark_name), , drop = FALSE]
if (length(add_rows) > 0) icmm_all <- bind_rows(icmm_all, bind_rows(add_rows))

icmm_gh <- icmm_all |>
  filter(Country == "Ghana", Asset_Type == "Mine", Confidence_Factor %in% IND_ICMM_MIN_CONFIDENCE)
message(sprintf("ICMM: %d distinct mines, %d point(s) total: %s",
                length(unique(icmm_gh$Mine_Name)), nrow(icmm_gh), paste(icmm_gh$Mine_Name, collapse = ", ")))

icmm_pts <- st_as_sf(icmm_gh, coords = c("lon", "lat"), crs = 4326) |> st_transform(UTM30N)

####3. Load Maus-GH and Tang & Werner 2023 (Ghana subset each) ####
maus_lyr <- sf::st_layers(IND_MAUS_GPKG)$name[1]
# "SELECT *" alone drops the gpkg's own fid -- OGR consumes it as the hidden feature ID. Aliasing it
# (fid AS maus_fid) makes it an ordinary attribute -- needed below for the cross-mine dedup.
maus_gh  <- st_read(IND_MAUS_GPKG, quiet = TRUE,
                    query = sprintf("SELECT *, fid AS maus_fid FROM \"%s\" WHERE ISO3_CODE = 'GHA'", maus_lyr)) |>
  st_zm(drop = TRUE) |> st_transform(UTM30N)
maus_a  <- as.numeric(st_area(maus_gh)) / 1e6
maus_gh <- maus_gh[!is.na(maus_a) & maus_a >= IND_MAUS_MIN_KM2, , drop = FALSE]

tw_crs      <- st_crs(readLines(sub("[.]shp$", ".prj", IND_TANGWERNER_SHP)))
tw_bbox_wkt <- st_bbox(GHANA_BBOX_4326, crs = 4326) |> st_as_sfc() |> st_transform(tw_crs) |> st_as_text()
tw_gh <- st_read(IND_TANGWERNER_SHP, wkt_filter = tw_bbox_wkt, quiet = TRUE) |>
  st_zm(drop = TRUE) |> st_transform(UTM30N) |> mutate(tw_id = OBJECTID)
message(sprintf("Maus-GH: %d polys; Tang & Werner (Ghana bbox): %d polys", nrow(maus_gh), nrow(tw_gh)))

####4. Per-mine selection (buffer / touching_only / contiguous) -- MIRRORS build_03 Section 7d ####
select_for_mine <- function(pt, src, mode, buffer_m) {
  if (mode == "buffer") return(src[lengths(st_intersects(src, st_buffer(pt, buffer_m))) > 0, , drop = FALSE])
  seed <- src[lengths(st_intersects(src, st_buffer(pt, IND_TOUCH_TOLERANCE_M))) > 0, , drop = FALSE]
  if (mode == "touching_only" || nrow(seed) == 0) return(seed)
  src[lengths(st_intersects(src, st_union(st_geometry(seed)))) > 0, , drop = FALSE]
}

mine_config <- tibble(mine = unique(icmm_gh$Mine_Name)) |>
  left_join(IND_MINE_CONFIG, by = "mine") |>
  mutate(
    source   = coalesce(source, "maus"),
    mode     = coalesce(mode, "buffer"),
    buffer_m = ifelse(mode == "buffer" & is.na(buffer_m), IND_ICMM_BUFFER_M, buffer_m)
  )

mine_sel <- vector("list", nrow(mine_config))
for (i in seq_len(nrow(mine_config))) {
  cfg    <- mine_config[i, ]
  pt     <- st_geometry(icmm_pts)[icmm_gh$Mine_Name == cfg$mine]
  src    <- if (cfg$source == "maus") maus_gh else tw_gh
  id_col <- if (cfg$source == "maus") "maus_fid" else "tw_id"
  sel    <- select_for_mine(pt, src, cfg$mode, cfg$buffer_m)
  mine_sel[[i]] <- list(mine = cfg$mine, source = cfg$source, ids = sel[[id_col]],
                        geom = st_geometry(sel), pt = pt)
}

# --- cross-mine dedup (2026-10-27, mirrors build_03 Section 7d EXACTLY): a polygon independently
# selected by MORE THAN ONE mine (same source, identical feature id) is kept by whichever mine's
# point(s) are nearest to it, dropped from the rest. See build_03 for the full rationale (fixes
# Iduapriem Gold Mine vs Tarkwa sharing a Maus polygon under the plain "buffer" mode). ---
for (src_name in c("maus", "tangwerner")) {
  idx <- which(sapply(mine_sel, `[[`, "source") == src_name)
  if (length(idx) < 2) next
  all_ids <- unlist(lapply(mine_sel[idx], `[[`, "ids"))
  dup_ids <- unique(all_ids[duplicated(all_ids)])
  for (did in dup_ids) {
    claimants <- idx[sapply(idx, function(j) did %in% mine_sel[[j]]$ids)]
    dists <- sapply(claimants, function(j) {
      g <- mine_sel[[j]]$geom[mine_sel[[j]]$ids == did]
      min(as.numeric(st_distance(g, mine_sel[[j]]$pt)))
    })
    keep <- claimants[which.min(dists)]
    message(sprintf("  dedup: %s polygon %s claimed by %s -- kept under %s only (nearest)",
                    src_name, did, paste(sapply(claimants, function(j) mine_sel[[j]]$mine), collapse = " & "),
                    mine_sel[[keep]]$mine))
    for (j in setdiff(claimants, keep)) {
      keep_mask <- mine_sel[[j]]$ids != did
      mine_sel[[j]]$ids  <- mine_sel[[j]]$ids[keep_mask]
      mine_sel[[j]]$geom <- mine_sel[[j]]$geom[keep_mask]
    }
  }
}

mine_rows <- vector("list", length(mine_sel))
for (i in seq_along(mine_sel)) {
  cfg <- mine_config[i, ]
  m   <- mine_sel[[i]]
  sel <- st_sf(geometry = m$geom)   # geometry only -- dropped id columns no longer needed past this point
  if (nrow(sel) == 0) {
    warning(sprintf("'%s' (%s/%s): NO polygon selected -- excluded from the dataset", cfg$mine, cfg$source, cfg$mode))
    next
  }
  meta <- icmm_gh[icmm_gh$Mine_Name == cfg$mine, ][1, ]   # identical metadata across a mine's point(s) -- take one
  mine_rows[[i]] <- st_sf(
    mine         = cfg$mine,
    icmm_id      = meta$ICMMID,
    commodity    = meta$Primary_Commodity,
    confidence   = meta$Confidence_Factor,
    source       = cfg$source,
    mode         = cfg$mode,
    buffer_m     = cfg$buffer_m,
    n_icmm_points = sum(icmm_gh$Mine_Name == cfg$mine),
    n_src_polys  = nrow(sel),
    area_km2     = round(as.numeric(sum(st_area(st_union(st_geometry(sel))))) / 1e6, 3),
    geometry     = st_sfc(st_union(st_geometry(sel)), crs = UTM30N)
  )
}
ghana_industrial_mines <- bind_rows(mine_rows) |> st_transform(4326)
message(sprintf("Built: %d mines, %.1f km2 total (not dissolved across mines -- see area_km2 per row)",
                nrow(ghana_industrial_mines), sum(ghana_industrial_mines$area_km2)))
print(ghana_industrial_mines |> st_drop_geometry() |> arrange(desc(area_km2)))

####5. Write to data/processed/ ####
out_gpkg <- here("data", "processed", "ghana_industrial_mines.gpkg")
out_shp  <- here("data", "processed", "ghana_industrial_mines.shp")
st_write(ghana_industrial_mines, out_gpkg, delete_dsn = TRUE, quiet = TRUE)
st_write(ghana_industrial_mines, out_shp, delete_dsn = TRUE, quiet = TRUE)
message("Wrote ", out_gpkg, " and ", out_shp)
