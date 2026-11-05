# upload_industrial_candidate_maus.R
# QA upload for the ICMM-point-driven industrial-exclusion recipe in build_03_embedding_panel.R
# Section 7 (reworked 2026-10-27 -- see that script's header). That recipe dissolves its selection
# into one big polygon before export, which is fine for masking but useless for eyeballing WHICH
# individual polygon got pulled in for WHICH mine. This script instead uploads TWO versions of the
# same selection -- one from Maus et al. 2022 v2, one from Tang & Werner 2023 -- each kept as
# separate features, tagged with nearest ICMM mine + distance + area + how many ICMM mines' buffers
# it falls within, so validate_industrial_coverage.js can show and compare them (style/filter by
# mine, click a polygon and read its attributes in the Inspector) instead of eyeballing one
# undifferentiated blob per source. Added 2026-10-27 (user: Maus nails about half the mines but
# Edikan/Asanko Obotan/Bogoso-Prestea look wrong -- is Tang & Werner cleaner there?).
#
# Also uploads the 14 ICMM Ghana mine points themselves (name/commodity/confidence) as a small
# third asset, for a visual anchor -- they weren't previously on EE (ICMM is a point KMZ, not a
# dataset this project had uploaded before the 2026-10-27 industrial-exclusion rework).
#
# Source: data/raw/mining_icmm/global-mining-dataset-1-5.kmz (points, parsed via xml2 -- no usable
# OGR KML/LIBKML driver here, see build_03 Section 7a) + data/raw/mining_mausetal/
# global_mining_polygons_v2.gpkg (Ghana subset, via an attribute query) + data/raw/mining_tangwerner/
# "74548_projected polygons.shp" (GLOBAL, ~296 MB, EASE-Grid equal-area CRS, no country field --
# read via a spatial wkt_filter on a generous Ghana bbox reprojected into that CRS, NOT a full read;
# confirmed 2026-10-27 this takes <1s and returns ~1900 features rather than loading the whole file).
# Selection logic (ICMM confidence filter, buffer radius, source min-size filter) MIRRORS build_03
# Section 7 deliberately -- this project's scripts coordinate through data artifacts, not by
# sourcing each other, so it's duplicated rather than shared; if you change the radius/filters in
# build_03, update them here too for this QA layer to stay representative of what the pipeline does.
#
# A 4th asset, industrial_final_selected_<date>, applies IND_MINE_CONFIG (mirrors build_03 Section
# 7b-7d EXACTLY -- per-mine source + selection mode: "buffer" radius / "touching_only" / "contiguous"
# one-hop neighbors) to compute what build_03 actually keeps per mine, tagged mine/source/mode, kept
# as separate features (build_03's own export dissolves this into one blob). Added 2026-10-27 after
# a first visual QA round found 6 mines needing something other than the uniform uniform 4000 m
# buffer: Edikan/Asanko Obotan "looked odd" with scattered non-touching polygons (fixed by
# "contiguous"), Bogoso Prestea/Prestea needed just the touching polygon, Awaso/Obuasi needed a
# smaller (1000 m) buffer. This is the layer to actually trust; the raw Maus/Tang & Werner layers
# below are kept as "everything nearby" reference, to see what got excluded by the tighter modes.
#
# Output assets:
#   projects/rgee-auth-tillam/assets/ghana_mining/industrial_candidate_maus_<YYYY-MM-DD>        (polygons, raw)
#   projects/rgee-auth-tillam/assets/ghana_mining/industrial_candidate_tangwerner_<YYYY-MM-DD>  (polygons, raw)
#   projects/rgee-auth-tillam/assets/ghana_mining/industrial_final_selected_<YYYY-MM-DD>        (polygons, FINAL)
#   projects/rgee-auth-tillam/assets/ghana_mining/icmm_points_ghana_<YYYY-MM-DD>                (points)
# plus local copies in outputs/ to upload by hand if sf_as_ee() times out.
#
# Run INTERACTIVELY (rgee authentication). Not yet run -- check all four assets in the Code Editor after.

####1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, tidyverse, sf, here, xml2)

UTM30N     <- 32630
EE_PROJECT <- "rgee-auth-tillam"   # ID, never the numeric project number
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
SNAPSHOT   <- format(Sys.Date(), "%Y-%m-%d")
MAUS_ASSET_ID  <- file.path(EE_ASSET_HOME, paste0("industrial_candidate_maus_", SNAPSHOT))
TW_ASSET_ID    <- file.path(EE_ASSET_HOME, paste0("industrial_candidate_tangwerner_", SNAPSHOT))
FINAL_ASSET_ID <- file.path(EE_ASSET_HOME, paste0("industrial_final_selected_", SNAPSHOT))
ICMM_ASSET_ID  <- file.path(EE_ASSET_HOME, paste0("icmm_points_ghana_", SNAPSHOT))

# MUST mirror build_03_embedding_panel.R Section 3/7 -- see header note above.
IND_ICMM_KMZ            <- here("data", "raw", "mining_icmm", "global_mining_dataset_1.5_corrected.kmz")
                             # 2026-10-27: switched to the user-edited copy (Google Earth Pro) -- see
                             # the "_corrected" placemark handling below.
IND_CORRECTION_MODE     <- c("Obuasi" = "add")   # MUST mirror build_03 Section 3 -- see that file's
                             # comment for the "replace" vs "add" rationale.
IND_MAUS_GPKG           <- here("data", "raw", "mining_mausetal", "global_mining_polygons_v2.gpkg")
IND_TANGWERNER_SHP      <- here("data", "raw", "mining_tangwerner", "74548_projected polygons.shp")
IND_ICMM_MIN_CONFIDENCE <- c("High", "Moderate")
IND_ICMM_BUFFER_M       <- 4000
IND_MAUS_MIN_KM2        <- 0
GHANA_BBOX_4326         <- c(xmin = -3.5, ymin = 4.3, xmax = 1.5, ymax = 11.2)   # generous, Tang &
                                                                                  # Werner has no country field
IND_TOUCH_TOLERANCE_M   <- 50   # see build_03 Section 3 -- absorbs point-placement/digitization
                                 # imprecision for "touching_only"/"contiguous", not a real radius.
IND_MINE_CONFIG <- tibble::tribble(                 # MUST mirror build_03 Section 3 exactly
  ~mine,             ~source,       ~mode,            ~buffer_m,
  "Edikan",          "tangwerner",  "contiguous",     NA_real_,
  "Asanko Obotan",   "tangwerner",  "contiguous",     NA_real_,
  "Prestea",         "tangwerner",  "touching_only",  NA_real_,
  "Bogoso Prestea",  "maus",        "touching_only",  NA_real_,
  "Awaso",           "maus",        "buffer",         1000,
  "Obuasi",          "maus",        "buffer",         1000
)

####2. ICMM points (Ghana, named industrial mines) ####
icmm_tmp <- tempfile()
unzip(IND_ICMM_KMZ, exdir = icmm_tmp)
icmm_kml <- list.files(icmm_tmp, pattern = "[.]kml$", full.names = TRUE)[1]
icmm_doc <- read_xml(icmm_kml)
icmm_ns  <- xml_ns(icmm_doc)
parse_icmm_pm <- function(pm) {
  sd   <- xml_find_all(pm, ".//d1:SimpleData", icmm_ns)
  vals <- setNames(xml_text(sd), xml_attr(sd, "name"))
  xy   <- as.numeric(strsplit(trimws(xml_text(xml_find_first(pm, ".//d1:coordinates", icmm_ns))), ",")[[1]][1:2])
  # bind_rows() (not rbind()) -- a manually-added correction placemark (see below) carries NO
  # SimpleData at all, so its row has far fewer columns than a normal ICMM placemark; rbind() would
  # error on the mismatch, bind_rows() fills the missing ones with NA.
  as.data.frame(c(as.list(vals), list(
    placemark_name = xml_text(xml_find_first(pm, ".//d1:name", icmm_ns)),
    lon = xy[1], lat = xy[2])), stringsAsFactors = FALSE)
}
icmm_all <- bind_rows(lapply(xml_find_all(icmm_doc, ".//d1:Placemark", icmm_ns), parse_icmm_pm))

# --- manual correction handling (2026-10-27, mirrors build_03 Section 7a): a placemark named
# "<MineName>_corrected" either REPLACES that mine's coordinates (default -- the original location
# was simply wrong, e.g. Prestea) or is ADDED as a 2nd point alongside the original, per
# IND_CORRECTION_MODE (e.g. Obuasi -- both locations sit on real parts of that large complex). See
# build_03 Section 7a for the full rationale. select_near_icmm()/select_for_mine() below already
# union across however many points a mine has, so "add" needs no further changes downstream. --
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
    message(sprintf("  ICMM correction applied (replace): %s moved from (%.5f, %.5f) to (%.5f, %.5f)",
                    base_name, icmm_all$lon[match_idx], icmm_all$lat[match_idx],
                    corrections$lon[i], corrections$lat[i]))
    icmm_all$lon[match_idx] <- corrections$lon[i]
    icmm_all$lat[match_idx] <- corrections$lat[i]
  } else if (corr_mode == "add") {
    message(sprintf("  ICMM correction applied (add 2nd point): %s also has a point at (%.5f, %.5f)",
                    base_name, corrections$lon[i], corrections$lat[i]))
    new_row <- icmm_all[match_idx, ]
    new_row$lon <- corrections$lon[i]; new_row$lat <- corrections$lat[i]
    new_row$placemark_name <- corrections$placemark_name[i]
    add_rows[[length(add_rows) + 1]] <- new_row
  } else stop("IND_CORRECTION_MODE['", base_name, "'] must be \"replace\" or \"add\", got: ", corr_mode)
}
icmm_all <- icmm_all[!grepl("_corrected$", icmm_all$placemark_name), , drop = FALSE]
if (length(add_rows) > 0) icmm_all <- bind_rows(icmm_all, bind_rows(add_rows))

icmm_gh <- icmm_all |>
  filter(Country == "Ghana", Asset_Type == "Mine", Confidence_Factor %in% IND_ICMM_MIN_CONFIDENCE) |>
  select(ICMMID, Mine_Name, Asset_Type, Primary_Commodity, Confidence_Factor, lon, lat)
message(sprintf("ICMM Ghana mine points (confidence %s): %d -- %s",
                paste(IND_ICMM_MIN_CONFIDENCE, collapse = "/"), nrow(icmm_gh),
                paste(icmm_gh$Mine_Name, collapse = ", ")))

icmm_pts <- st_as_sf(icmm_gh, coords = c("lon", "lat"), crs = 4326, remove = FALSE)
icmm_pts_utm <- st_transform(icmm_pts, UTM30N)

# shared helper: select source polygons near an ICMM point, tag each with nearest mine, distance,
# area, and how many DIFFERENT ICMM mines' buffers it falls within (n_icmm_matches > 1 turned out
# 2026-10-27 to be a useful free tell for "this polygon is probably defective" -- 2 of 3 non-trivial
# dual claims in Maus were the oversized Edikan/Asanko and Bogoso-Prestea/Prestea polygons).
select_near_icmm <- function(src, id_col) {
  icmm_buf_each <- st_buffer(st_geometry(icmm_pts_utm), IND_ICMM_BUFFER_M)
  inter    <- st_intersects(src, icmm_buf_each)
  near_icmm <- lengths(inter) > 0
  sel      <- src[near_icmm, , drop = FALSE]
  sel_inter <- inter[near_icmm]

  dist_m      <- matrix(as.numeric(st_distance(sel, icmm_pts_utm)), nrow = nrow(sel))
  nearest_idx <- apply(dist_m, 1, which.min)
  sel$mine            <- icmm_gh$Mine_Name[nearest_idx]
  sel$dist_to_mine_m  <- round(apply(dist_m, 1, min))
  sel$area_km2        <- round(as.numeric(st_area(sel)) / 1e6, 3)
  sel$n_icmm_matches  <- lengths(sel_inter)
  sel$icmm_buffer_m   <- IND_ICMM_BUFFER_M       # recorded so the asset documents its own radius
  sel |> select(all_of(id_col), mine, dist_to_mine_m, area_km2, n_icmm_matches, icmm_buffer_m)
}

ee_ready <- function(g) {         # same pattern as upload_gold_leases.R -- no dissolve, keep features
  g <- st_set_precision(g, 1) |> st_make_valid()
  g <- suppressWarnings(st_collection_extract(g, "POLYGON"))
  g <- g[!st_is_empty(g), ]
  print(table(as.character(st_geometry_type(g))))   # should be POLYGON / MULTIPOLYGON only
  st_transform(g, 4326)
}

####3. Maus-GH polygons within IND_ICMM_BUFFER_M of an ICMM point, kept as separate features ####
maus_lyr <- sf::st_layers(IND_MAUS_GPKG)$name[1]
# "SELECT *" alone drops the gpkg's own fid -- OGR consumes it as the hidden feature ID rather than a
# regular column (confirmed 2026-10-27: st_read() on this file returns only ISO3_CODE/COUNTRY_NAME/
# AREA/geom). Aliasing it (fid AS maus_fid) makes OGR treat it as an ordinary attribute instead.
maus_gh  <- st_read(IND_MAUS_GPKG, quiet = TRUE,
                    query = sprintf("SELECT *, fid AS maus_fid FROM \"%s\" WHERE ISO3_CODE = 'GHA'", maus_lyr)) |>
  st_zm(drop = TRUE) |> st_transform(UTM30N)
maus_a  <- as.numeric(st_area(maus_gh)) / 1e6
maus_gh <- maus_gh[!is.na(maus_a) & maus_a >= IND_MAUS_MIN_KM2, , drop = FALSE]

maus_selected <- select_near_icmm(maus_gh, "maus_fid")
message(sprintf("Maus-GH polygons selected (>= %g km2, within %g m of an ICMM point): %d/%d",
                IND_MAUS_MIN_KM2, IND_ICMM_BUFFER_M, nrow(maus_selected), nrow(maus_gh)))
print(maus_selected |> st_drop_geometry() |> arrange(desc(area_km2)) |>
        mutate(across(where(is.numeric), ~round(., 2))))

####3b. Tang & Werner 2023 polygons within IND_ICMM_BUFFER_M of an ICMM point ####
# Global file, no country field -- st_read()'s wkt_filter spatially pre-filters via the shapefile's
# own .shx index (confirmed 2026-10-27: <1s, ~1900 features, NOT a full 296 MB read) to a generous
# Ghana bbox reprojected into the file's native EASE-Grid CRS.
tw_crs  <- st_crs(readLines(sub("[.]shp$", ".prj", IND_TANGWERNER_SHP)))
tw_bbox_wkt <- st_bbox(GHANA_BBOX_4326, crs = 4326) |> st_as_sfc() |> st_transform(tw_crs) |> st_as_text()
tw_gh   <- st_read(IND_TANGWERNER_SHP, wkt_filter = tw_bbox_wkt, quiet = TRUE) |>
  st_zm(drop = TRUE) |> st_transform(UTM30N) |>
  mutate(tw_id = OBJECTID) |> select(tw_id, geometry)
message(sprintf("Tang & Werner polygons in the Ghana bbox: %d", nrow(tw_gh)))

tw_selected <- select_near_icmm(tw_gh, "tw_id")
message(sprintf("Tang & Werner polygons selected (within %g m of an ICMM point): %d/%d",
                IND_ICMM_BUFFER_M, nrow(tw_selected), nrow(tw_gh)))
print(tw_selected |> st_drop_geometry() |> arrange(desc(area_km2)) |>
        mutate(across(where(is.numeric), ~round(., 2))))

####3c. FINAL per-mine selection -- mirrors build_03 Section 7b-7d EXACTLY ####
mine_config <- tibble(mine = unique(icmm_gh$Mine_Name)) |>   # unique() -- see build_03 Section 7b comment
  left_join(IND_MINE_CONFIG, by = "mine") |>
  mutate(
    source   = coalesce(source, "maus"),
    mode     = coalesce(mode, "buffer"),
    buffer_m = ifelse(mode == "buffer" & is.na(buffer_m), IND_ICMM_BUFFER_M, buffer_m)
  )

select_for_mine <- function(pt, src, mode, buffer_m) {
  if (mode == "buffer") return(src[lengths(st_intersects(src, st_buffer(pt, buffer_m))) > 0, , drop = FALSE])
  seed <- src[lengths(st_intersects(src, st_buffer(pt, IND_TOUCH_TOLERANCE_M))) > 0, , drop = FALSE]
  if (mode == "touching_only" || nrow(seed) == 0) return(seed)
  src[lengths(st_intersects(src, st_union(st_geometry(seed)))) > 0, , drop = FALSE]   # seed + 1-hop neighbors
}

mine_sel <- vector("list", nrow(mine_config))
for (i in seq_len(nrow(mine_config))) {
  cfg    <- mine_config[i, ]
  pt     <- st_geometry(icmm_pts_utm)[icmm_gh$Mine_Name == cfg$mine]
  src    <- if (cfg$source == "maus") maus_gh else tw_gh
  id_col <- if (cfg$source == "maus") "maus_fid" else "tw_id"
  sel    <- select_for_mine(pt, src, cfg$mode, cfg$buffer_m)
  if (nrow(sel) == 0) {
    warning(sprintf("'%s' (%s/%s): NO polygon selected", cfg$mine, cfg$source, cfg$mode))
  }
  mine_sel[[i]] <- list(mine = cfg$mine, source = cfg$source, mode = cfg$mode,
                        ids = sel[[id_col]], geom = st_geometry(sel), pt = pt)
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

final_rows <- list()
for (m in mine_sel) {
  if (length(m$geom) == 0) next
  final_rows[[m$mine]] <- st_sf(
    mine = m$mine, source = m$source, mode = m$mode,
    area_km2 = round(as.numeric(st_area(m$geom)) / 1e6, 3),   # per-feature area -- fine as-is, these
                                                                 # rows are kept separate, not summed here
    geometry = m$geom
  )
}
final_selected <- bind_rows(final_rows)
message(sprintf("FINAL per-mine selection: %d poly(s) across %d mines, %.1f km2 total (dissolved)",
                nrow(final_selected), length(unique(final_selected$mine)),
                as.numeric(st_area(st_union(st_geometry(final_selected)))) / 1e6))
# per-mine total: union EACH MINE'S OWN polygons first (fixes a real bug found 2026-10-27 -- Edikan's
# 3 "contiguous" Tang & Werner polygons genuinely overlap each other, so summing their individual
# area_km2 double-counted the overlap; a plain sum is only safe when a mine's own polygons don't
# overlap, which isn't guaranteed).
print(final_selected |> group_by(mine, source, mode) |>
        summarise(n = n(), km2 = round(as.numeric(st_area(st_union(st_geometry(geometry)))) / 1e6, 2),
                  .groups = "drop") |> st_drop_geometry() |> arrange(desc(km2)))

####4. Clean geometry for EE ####
maus_ee     <- ee_ready(maus_selected)
tw_ee       <- ee_ready(tw_selected)
final_ee    <- ee_ready(final_selected)
icmm_pts_ee <- st_transform(icmm_pts, 4326) |> select(-lon, -lat)

####5. Local copies (fallback for a manual Code Editor upload) ####
dir.create(here("outputs"), showWarnings = FALSE)
maus_shp  <- here("outputs", paste0("industrial_candidate_maus_", SNAPSHOT, ".shp"))
tw_shp    <- here("outputs", paste0("industrial_candidate_tangwerner_", SNAPSHOT, ".shp"))
final_shp <- here("outputs", paste0("industrial_final_selected_", SNAPSHOT, ".shp"))
icmm_shp  <- here("outputs", paste0("icmm_points_ghana_", SNAPSHOT, ".shp"))
st_write(maus_ee, maus_shp, delete_dsn = TRUE, quiet = TRUE)
st_write(tw_ee, tw_shp, delete_dsn = TRUE, quiet = TRUE)
st_write(final_ee, final_shp, delete_dsn = TRUE, quiet = TRUE)
st_write(icmm_pts_ee, icmm_shp, delete_dsn = TRUE, quiet = TRUE)
message("Wrote ", maus_shp, ", ", tw_shp, ", ", final_shp, " and ", icmm_shp)

####6. Upload to Earth Engine ####
# NOT sf_as_ee(x, assetId = ...) directly -- broken for this Cloud-Project account (legacy-namespace
# bug, same as upload_gold_leases.R / build_02 / validate_finalproduct.R). Build the FeatureCollection
# inline via sf_as_ee() with NO assetId (via = "getInfo", fine at this size), then persist with EE's
# own Export$table$toAsset, which resolves Cloud-Project asset paths correctly.
rgee::ee_Initialize(drive = TRUE, project = EE_PROJECT)

wait_until_asset_ready <- function(id, max_wait_s = 120) {
  waited <- 0
  repeat {
    ok <- tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)
    if (ok) return(invisible(TRUE))
    if (waited >= max_wait_s) stop("Asset never became queryable within ", max_wait_s, "s: ", id)
    Sys.sleep(3); waited <- waited + 3
  }
}

upload_fc <- function(x, asset_id, description, local_fallback) {
  tryCatch({
    if (tryCatch({ ee$data$getAsset(asset_id); TRUE }, error = function(e) FALSE)) {
      message("  deleting pre-existing asset: ", asset_id)
      ee$data$deleteAsset(asset_id)
    }
    fc   <- sf_as_ee(x)
    task <- ee$batch$Export$table$toAsset(collection = fc, description = description, assetId = asset_id)
    task$start()
    message("  task submitted -- visible under code.earthengine.google.com -> Tasks")
    wait_until_asset_ready(asset_id)
    message("Uploaded (confirmed queryable): ", asset_id)
  }, error = function(e) message(
    "Upload failed (", conditionMessage(e), ").\n",
    "  -> upload ", local_fallback, " in the Code Editor (Assets > New > Shape files), named ",
    basename(asset_id), "."))
}

upload_fc(maus_ee,     MAUS_ASSET_ID,  "upload_industrial_candidate_maus",       maus_shp)
upload_fc(tw_ee,       TW_ASSET_ID,    "upload_industrial_candidate_tangwerner", tw_shp)
upload_fc(final_ee,    FINAL_ASSET_ID, "upload_industrial_final_selected",      final_shp)
upload_fc(icmm_pts_ee, ICMM_ASSET_ID,  "upload_icmm_points_ghana",               icmm_shp)
