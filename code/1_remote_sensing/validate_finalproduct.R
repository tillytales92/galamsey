# validate_finalproduct.R
# Uploads NATIONAL (2026-09-17: was AOI-scoped -- see below) raw Barenblitt 2019, RAW
# (un-eroded) Maus et al. 2022 and Tang & Werner 2023 polygons, plus ALL of SmallMinesDS's
# real 2022 mask outlines, as EE assets -- so all four plus build_02_embedding_classifier.R's
# OWN c4 mine-probability output can be visually compared against a live Sentinel-2 composite,
# at ANY site, directly in the GEE Code Editor (validate_finalproduct.js, hand-maintained --
# see NOTE below).
#
# Why Barenblitt is included here too (added 2026-08-11): it's easy to assume Barenblitt is the
# "trusted" source since build_02 weights it 2x in training -- but per
# embedding_classifier_approach.md's source table, Barenblitt is itself a random-forest model
# output from Landsat (PA 75.6%), while Maus and Tang are BOTH hand-drawn (Maus on Sentinel-2,
# Tang on 0.15-10m Google Earth imagery) -- the reverse of what "trusted primary source" might
# suggest. The 2x training weight is for a different, structural reason (Barenblitt is the only
# source with a usable artisanal/industrial split -- build_01_labels.R filters it to mine_type==1
# -- not a claim that its boundaries are more accurate). Both mine_type values are uploaded here
# (not just artisanal) so the raw source can be judged as a whole, same treatment as Maus/Tang.
#
# Why Code Editor, not another R/leaflet map (2026-08-10 decision): the task here is open-ended
# visual judgment -- "which of these sources actually fits the imagery" -- not a fixed metric.
# Code Editor's native pan/zoom/layer-toggle is a better tool for that than rebuilding an R
# script per area, and it sidesteps every rgee/reticulate friction point hit earlier this session
# (5,000-element getInfo() cap, Drive search-index lag, reticulate int-overflow on task$status()).
#
# Why raw (not eroded) Maus/Tang: build_01_labels.R erodes Maus -50m / Tang -40m to their
# trustworthy CORES for training-sample placement -- that's a training-time decision, not the
# source's actual reported shape. Judging source QUALITY against imagery needs the real outline.
#
# Why SmallMinesDS gets share_mined > 0 (not build_01's balanced sample, not Part 2c's >10% in
# validate_external_references.R): Part 2c's >10% floor exists only to keep a browser-rendered
# leaflet HTML small -- EE assets have no such constraint, and the low-share/ambiguous patches
# are exactly the ones worth eyeballing for a data-quality judgment call. Only true empties
# (share_mined == 0) are dropped, since they render as literally nothing.
#
# NATIONAL, not AOI-scoped (2026-09-17): originally this script clipped all four sources to one
# ~41x41km Awomaso-centred box, matching validate_external_references.R Part 2c's AOI_SITE. That
# meant validate_finalproduct.js's CHECK_SITES dropdown could jump the Sentinel-2/probability
# layers to other sites but the ground-truth outlines stayed empty everywhere except Awomaso.
# Switched to national scope so the outlines actually follow the dropdown. Barenblitt/Maus/Tang
# at national scope are large enough to blow EE's ~10MB inline-upload payload limit (same
# failure build_02_embedding_classifier.R hit uploading ~7,391 Barenblitt polygons) -- Section 2's
# submit_chunks()/finalize_asset() (2026-09-17: split from one combined upload_as_asset(), ported
# from that script's chunked-and-persisted pattern) queue every source's chunks immediately
# (Sections 3-6) and only wait+merge+export at the very end (Section 7), so an interruption or
# quota timeout on one source's slow merge doesn't stop the others from ever being queued.
#
# NOTE on the .js file (2026-09-17): this script used to auto-generate
# validate_ground_truth_comparison.js from a template at the end (old Section 7). That .js has
# since been hand-built into something far more capable (year/cutoff/urban-threshold sliders, a
# multi-site dropdown) than anything this template ever produced, so the auto-generation step is
# REMOVED -- re-running this script only refreshes the 4 EE assets; validate_finalproduct.js
# already reads them by name and needs no regeneration. Both files were renamed together
# (validate_ground_truth_comparison.{R,js} -> validate_finalproduct.{R,js}) since "ground truth
# comparison" undersold what the .js now does (full deployed-product QA, not just source compare).
#
# Outputs -- 4 EE assets under ghana_mining/ (renamed gt_compare_smallminesds_aoi ->
# gt_compare_smallminesds since it's no longer AOI-scoped; the other three names are unchanged):
#   gt_compare_barenblitt_raw, gt_compare_maus_raw, gt_compare_tang_raw, gt_compare_smallminesds

pacman::p_load(sf, terra, here, tidyverse, janitor, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag, here::here
)
UTM30N <- 32630

rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)
library(reticulate)
pacman::p_load(rgee)

EE_PROJECT <- "rgee-auth-tillam"   # see build_02_embedding_classifier.R Section 1 for why this
                                   # must be the alphanumeric project ID, not the project number
#rgee::ee_Authenticate()
#rgee::ee_Initialize(project = EE_PROJECT)
ee_check()
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)

####1. Ghana boundary (Tang's wkt_filter needs it; Barenblitt/Maus need no spatial filter at all
####   now -- Barenblitt is inherently SW-hull-only and Maus's SQL query is already Ghana-wide) ###

admin0_path <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp")
admin0 <- st_read(admin0_path, quiet = TRUE) |>
  st_make_valid() |>
  select(geometry) |>
  st_transform(UTM30N)

####2. Upload helper -- CHUNKED + PERSISTED, ported from build_02_embedding_classifier.R's ####
####   upload_as_asset() (2026-08-11 v2 there; see that file's comment for the full "why" on ####
####   why chunks must be persisted as their own temp assets before merging, not just merged ####
####   inline) -- needed here now that these are national-scope uploads, not AOI-sized ones. ####

REUSE_ASSETS <- FALSE   # set TRUE on subsequent re-runs once this national upload is confirmed
                        # correct, to avoid re-uploading unchanged data every time.

wait_until_asset_ready <- function(id, max_wait_s = 600) {
  # 2026-09-17: first real (national-scope) run hit the 120s default while a chunk export
  # was still sitting in EE's READY (queued, not yet running) state -- same known
  # ee_monitoring()-unreliability build_02_embedding_classifier.R already documents on this
  # exact function, just a longer stall than seen there. Bumped to 600s; EE task-queue
  # latency, not a code bug, so a longer wait is the right fix, not a retry loop.
  waited <- 0
  repeat {
    ok <- tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)
    if (ok) return(invisible(TRUE))
    if (waited >= max_wait_s) stop("Asset never became queryable within ", max_wait_s, "s: ", id)
    Sys.sleep(3); waited <- waited + 3
  }
}

# Split into submit (Phase 1, fast, queues everything) and finalize (Phase 2, slow, waits +
# merges + exports the final asset) -- 2026-09-17. Previously ONE function did both per source,
# called sequentially for Barenblitt/Maus/Tang/SmallMinesDS -- so if Barenblitt's Phase 2 wait
# errored/timed out (expected under EECU quota throttling), the script halted right there and
# Maus/Tang/SmallMinesDS never even got their chunks SUBMITTED. Now every source's submit_chunks()
# runs first (Sections 3-6 below), and finalize_asset() for all of them only happens at the very
# end -- so "queue everything and walk away" actually queues everything, not just whichever
# source happened to be first.
submit_chunks <- function(sf_obj, name) {
  assetId <- file.path(EE_ASSET_HOME, name)
  exists  <- tryCatch({ ee$data$getAsset(assetId); TRUE }, error = function(e) FALSE)
  if (exists && REUSE_ASSETS) {
    message(sprintf("  reusing existing asset: %s", assetId))
    return(list(assetId = assetId, name = name, done = TRUE))
  }
  if (exists) {
    message(sprintf("  deleting pre-existing asset: %s", assetId))
    ee$data$deleteAsset(assetId)
  }

  chunk_size <- 2000L
  n_obj      <- nrow(sf_obj)
  chunk_idx  <- split(seq_len(n_obj), ceiling(seq_len(n_obj) / chunk_size))

  if (length(chunk_idx) == 1) {
    fc   <- sf_as_ee(sf_obj)
    task <- ee$batch$Export$table$toAsset(collection = fc, description = name, assetId = assetId)
    task$start()
    message(sprintf("  submitted (single, queued, not waiting) -> %s", assetId))
    return(list(assetId = assetId, name = name, done = FALSE, single = TRUE))
  }

  message(sprintf("  submitting %d chunk(s) of <=%d rows (queued, not waiting)", length(chunk_idx), chunk_size))
  temp_ids <- character(length(chunk_idx))
  for (i in seq_along(chunk_idx)) {
    temp_id <- sprintf("%s_tmpchunk%02d", assetId, i)
    temp_ids[i] <- temp_id
    # skip-if-exists: re-running after some chunks already completed only submits stragglers.
    already_ready <- tryCatch({ ee$data$getAsset(temp_id); TRUE }, error = function(e) FALSE)
    if (already_ready) {
      message(sprintf("    chunk %d/%d already persisted -- skipping -> %s", i, length(chunk_idx), temp_id))
    } else {
      chunk_fc   <- sf_as_ee(sf_obj[chunk_idx[[i]], ])
      chunk_task <- ee$batch$Export$table$toAsset(
        collection = chunk_fc, description = sprintf("%s_chunk%02d", name, i), assetId = temp_id
      )
      chunk_task$start()
      message(sprintf("    chunk %d/%d submitted (queued, not waiting) -> %s", i, length(chunk_idx), temp_id))
    }
  }
  list(assetId = assetId, name = name, done = FALSE, single = FALSE, temp_ids = temp_ids)
}

# Phase 2 -- wait for a source's chunks (or single upload) to persist, merge if needed, export
# the final asset, clean up temp chunks. Safe to let this error/timeout and re-run the whole
# script later: skip-if-exists in submit_chunks() and the already-COMPLETED final-asset check
# both mean no progress is lost, only stragglers get retried.
finalize_asset <- function(spec) {
  if (is.null(spec) || isTRUE(spec$done)) return(invisible(NULL))
  message(sprintf("=== Finalizing %s ===", spec$name))
  if (isTRUE(spec$single)) {
    wait_until_asset_ready(spec$assetId)
    message(sprintf("  %s ready.", spec$assetId))
    return(invisible(spec$assetId))
  }
  invisible(lapply(spec$temp_ids, wait_until_asset_ready))
  fc   <- Reduce(function(a, b) a$merge(b), lapply(spec$temp_ids, ee$FeatureCollection))
  task <- ee$batch$Export$table$toAsset(collection = fc, description = spec$name, assetId = spec$assetId)
  task$start()
  message(sprintf("  submitted final merge: %s -> %s", spec$name, spec$assetId))
  ee_monitoring(task)
  wait_until_asset_ready(spec$assetId)   # ee_monitoring() has been seen to return before COMPLETED
  message("  cleaning up temp chunk assets")
  for (tid in spec$temp_ids) tryCatch(ee$data$deleteAsset(tid), error = function(e) NULL)
  invisible(spec$assetId)
}
asset_specs <- list()   # collects each source's submit_chunks() result for the Section 7 finalize loop

####3. Barenblitt 2019 -- NATIONAL (inherently SW-hull-only), BOTH mine types kept ####
# Same load as build_01_labels.R Section 3, but keeping mine_type 1 AND 2 (build_01 filters to
# artisanal-only, mine_type==1, for training) -- this is a source-quality look, not a training
# extract, so the industrial polygons stay in (tagged) rather than being dropped.

message("=== Loading Barenblitt 2019 (national) ===")
barenblitt_path <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")
barenblitt_up <- st_read(barenblitt_path, quiet = TRUE) |>
  clean_names() |>
  st_make_valid() |>
  st_transform(UTM30N) |>
  transmute(source_id = as.character(row_number()), mine_type = mine_type) |>
  st_transform(4326)
message(sprintf("  %d Barenblitt polygons (%d artisanal / %d industrial)",
                nrow(barenblitt_up), sum(barenblitt_up$mine_type == 1), sum(barenblitt_up$mine_type == 2)))
if (nrow(barenblitt_up) > 0) asset_specs$barenblitt <- submit_chunks(barenblitt_up, "gt_compare_barenblitt_raw")

####4. Maus et al. 2022 v2 -- Ghana subset (already national via the SQL query), RAW (no erosion) ###

message("=== Loading raw Maus et al. (Ghana, national) ===")
maus_path <- here("data", "raw", "mining_mausetal", "global_mining_polygons_v2.gpkg")
maus_lyr  <- st_layers(maus_path)$name[1]
maus_up   <- st_read(maus_path, query = sprintf("SELECT * FROM %s WHERE ISO3_CODE = 'GHA'", maus_lyr),
                     quiet = TRUE) |>
  rename(geometry = geom) |>
  st_make_valid() |>
  st_transform(UTM30N) |>
  transmute(source_id = as.character(row_number())) |>
  st_transform(4326)
message(sprintf("  %d Maus polygons (Ghana, national)", nrow(maus_up)))
if (nrow(maus_up) > 0) asset_specs$maus <- submit_chunks(maus_up, "gt_compare_maus_raw")

####5. Tang & Werner 2023 -- wkt_filter scoped to Ghana (build_01_labels.R's approach, ported) ####

message("=== Loading raw Tang & Werner, wkt_filter scoped to Ghana ===")
tang_path <- here("data", "raw", "mining_tangwerner", "74548_projected polygons.shp")
tang_crs  <- st_crs(st_read(tang_path, quiet = TRUE,
                            query = sprintf("SELECT * FROM \"%s\" LIMIT 0", "74548_projected polygons")))
ghana_wkt <- admin0 |>
  st_buffer(5000) |>   # so border-straddling polygons aren't clipped out of the filter
  st_transform(tang_crs) |>
  st_geometry() |>
  st_union() |>
  st_as_text()

tang_up <- st_read(tang_path, wkt_filter = ghana_wkt, quiet = TRUE) |>
  st_zm(drop = TRUE) |>
  st_make_valid() |>
  st_transform(UTM30N) |>
  transmute(source_id = as.character(OBJECTID)) |>
  st_transform(4326)
message(sprintf("  %d Tang & Werner polygons (Ghana, national)", nrow(tang_up)))
if (nrow(tang_up) > 0) asset_specs$tang <- submit_chunks(tang_up, "gt_compare_tang_raw")

####6. SmallMinesDS -- ALL real outlines, share_mined > 0 (skip true empties only) ####
# Same vectorisation as before, just without the AOI pre-filter -- NB this now rasterises/
# polygonises every non-empty 2022 patch nationally (SmallMinesDS is itself geographically
# concentrated in ~5 Amansie/Bekwai/Obuasi-belt districts per explainer.md, so "national" here
# doesn't mean thousands of new areas suddenly appear, but it IS more patches than the old AOI
# subset and will take noticeably longer to run locally than before.

message("=== Vectorising ALL SmallMinesDS real outlines (2022, share_mined > 0) ===")
EPOCH <- 2022
patches_reg <- readRDS(here("data", "processed", "labels", "smallminesds_patch_footprints.rds"))
sel <- patches_reg |> filter(epoch == EPOCH, share_mined > 0)
message(sprintf("  %d patches selected (epoch %d, share > 0) out of %d total",
                nrow(sel), EPOCH, sum(patches_reg$epoch == EPOCH)))

smds_dir_epoch <- here("data", "raw", "smallminesds", "SmallMinesDS", "SmallMinesDS", as.character(EPOCH))
mask_paths <- file.path(smds_dir_epoch, "MASK", sprintf("MASK_%s_%d.tif", sel$patch_id, EPOCH))
stopifnot("Some SmallMinesDS mask files not found -- check smds_dir_epoch / patch_id format" =
            all(file.exists(mask_paths)))

outline_list <- lapply(seq_along(mask_paths), function(i) {
  if (i %% 500 == 0) message(sprintf("  ...vectorised %d/%d patches", i, length(mask_paths)))
  r     <- rast(mask_paths[i])
  r_bin <- (r == 1)
  p <- as.polygons(r_bin, dissolve = TRUE) |> st_as_sf()
  p <- p |> filter(.data[[names(r_bin)[1]]] == TRUE)
  if (nrow(p) == 0) return(NULL)
  p |> mutate(patch_id = sel$patch_id[i], share_mined = sel$share_mined[i]) |>
    select(patch_id, share_mined)
})
outlines <- do.call(rbind, Filter(Negate(is.null), outline_list)) |> st_transform(4326)
message(sprintf("  %d non-empty outlines vectorised", nrow(outlines)))
if (nrow(outlines) > 0) asset_specs$smallminesds <- submit_chunks(outlines, "gt_compare_smallminesds")

####7. Finalize -- wait + merge + export the final asset for each source ####
# All 4 sources' chunks are already queued in GEE by this point (Sections 3-6 above), regardless
# of how this loop goes. Safe to interrupt (Ctrl+C, close R, quota timeout) at any point in here --
# just re-run this whole script in a day or two; nothing submitted above gets lost, and this loop
# will skip everything already finished and only wait on genuine stragglers.
message(sprintf("\n=== All chunks queued for %d source(s) -- now waiting + merging (safe to interrupt) ===",
                length(asset_specs)))
for (nm in names(asset_specs)) finalize_asset(asset_specs[[nm]])

message("\n=== validate_finalproduct.R complete -- assets refreshed nationally.")
message("validate_finalproduct.js is hand-maintained (not auto-generated by this script) --")
message("no changes needed there beyond the gt_compare_smallminesds_aoi -> gt_compare_smallminesds")
message("asset rename already applied. Just re-run the .js in the Code Editor to pick up the")
message("refreshed assets.")
