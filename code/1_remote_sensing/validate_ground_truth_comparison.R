# validate_ground_truth_comparison.R
# Uploads AOI-scoped subsets of Barenblitt 2019, RAW (un-eroded) Maus et al. 2022 and Tang &
# Werner 2023 polygons, plus SmallMinesDS's real mask outlines, as small EE assets -- so all
# four plus build_02_embedding_classifier.R's OWN c4 mine-probability output for 2022 can be
# visually compared against a real Sentinel-2 2022 composite directly in the GEE Code Editor.
# (2026-09-03: repointed to the tiled c4 export mine_prob_ghana_c4_2022_t{NN}, cutoff 45.)
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
# AOI matches validate_external_references.R Part 2c's AOI_SITE (Awomaso-centred, ~41x41km) for
# consistency -- same area already inspected there, just now with the OTHER two label sources
# and a live Sentinel-2 backdrop added via Code Editor instead of a static leaflet.
#
# Outputs:
#   - 4 EE assets under ghana_mining/: gt_compare_barenblitt_raw, gt_compare_maus_raw,
#     gt_compare_tang_raw, gt_compare_smallminesds_aoi
#   - code/1_remote_sensing/validate_ground_truth_comparison.js -- ready-to-paste Code Editor
#     script that loads all four + a mosaic of the c4 2022 probability tiles + a live S2 2022
#     composite, pre-centred and pre-zoomed on the AOI.

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

####1. AOI -- same as validate_external_references.R Part 2c ####

AOI_SITE <- list(x = 617000, y = 670000, halfwidth_km = 20.5)
aoi_utm  <- st_sfc(st_point(c(AOI_SITE$x, AOI_SITE$y)), crs = UTM30N) |>
  st_buffer(AOI_SITE$halfwidth_km * 1000, endCapStyle = "SQUARE")
aoi_ll_centroid <- aoi_utm |> st_transform(4326) |> st_centroid() |> st_coordinates()

####2. Upload helper -- identical pattern to build_02_embedding_classifier.R's upload_as_asset ####

upload_as_asset <- function(sf_obj, name) {
  assetId <- file.path(EE_ASSET_HOME, name)
  exists  <- tryCatch({ ee$data$getAsset(assetId); TRUE }, error = function(e) FALSE)
  if (exists) {
    message(sprintf("  deleting pre-existing asset: %s", assetId))
    ee$data$deleteAsset(assetId)
  }
  fc   <- sf_as_ee(sf_obj)   # via = "getInfo" (default): inline -- fine at this AOI-scoped size
  task <- ee$batch$Export$table$toAsset(collection = fc, description = name, assetId = assetId)
  task$start()
  message(sprintf("  submitted: %s -> %s", name, assetId))
  ee_monitoring(task)
  invisible(assetId)
}

####3. Barenblitt 2019 -- clipped to the AOI, BOTH mine types kept ####
# Same load as build_01_labels.R Section 3, but keeping mine_type 1 AND 2 (build_01 filters to
# artisanal-only, mine_type==1, for training) -- this is a source-quality look, not a training
# extract, so the industrial polygons stay in (tagged) rather than being dropped.

message("=== Loading Barenblitt 2019, clipping to AOI ===")
barenblitt_path <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")
barenblitt_all  <- st_read(barenblitt_path, quiet = TRUE) |>
  clean_names() |>
  st_make_valid() |>
  st_transform(UTM30N)
barenblitt_aoi <- barenblitt_all[st_intersects(barenblitt_all, aoi_utm, sparse = FALSE)[, 1], ] |>
  transmute(source_id = as.character(row_number()), mine_type = mine_type) |>
  st_transform(4326)
message(sprintf("  %d Barenblitt polygons in AOI (%d artisanal / %d industrial) of %d Ghana-wide",
                nrow(barenblitt_aoi), sum(barenblitt_aoi$mine_type == 1),
                sum(barenblitt_aoi$mine_type == 2), nrow(barenblitt_all)))
if (nrow(barenblitt_aoi) > 0) upload_as_asset(barenblitt_aoi, "gt_compare_barenblitt_raw")

####4. Maus et al. 2022 v2 -- Ghana subset, then clipped to the AOI ####
# Same load as build_01_labels.R Section 4, but RAW (no erosion) and clipped to the small AOI
# instead of kept national.

message("=== Loading raw Maus et al. (Ghana), clipping to AOI ===")
maus_path <- here("data", "raw", "mining_mausetal", "global_mining_polygons_v2.gpkg")
maus_lyr  <- st_layers(maus_path)$name[1]
maus_gha  <- st_read(maus_path, query = sprintf("SELECT * FROM %s WHERE ISO3_CODE = 'GHA'", maus_lyr),
                     quiet = TRUE) |>
  rename(geometry = geom) |>
  st_make_valid() |>
  st_transform(UTM30N)
maus_aoi <- maus_gha[st_intersects(maus_gha, aoi_utm, sparse = FALSE)[, 1], ] |>
  transmute(source_id = as.character(row_number())) |>
  st_transform(4326)
message(sprintf("  %d Maus polygons in AOI (of %d Ghana-wide)", nrow(maus_aoi), nrow(maus_gha)))
if (nrow(maus_aoi) > 0) upload_as_asset(maus_aoi, "gt_compare_maus_raw")

####5. Tang & Werner 2023 -- wkt_filter scoped to the AOI directly (not all of Ghana) ####
# build_01_labels.R filters this global 74,548-polygon file down to Ghana via a wkt_filter on
# the national boundary; here the filter is the (much smaller) AOI directly, since that's all
# that's needed for this comparison -- avoids loading Ghana-wide Tang just to re-filter locally.

message("=== Loading raw Tang & Werner, wkt_filter scoped to AOI ===")
tang_path <- here("data", "raw", "mining_tangwerner", "74548_projected polygons.shp")
tang_crs  <- st_crs(st_read(tang_path, quiet = TRUE,
                            query = sprintf("SELECT * FROM \"%s\" LIMIT 0", "74548_projected polygons")))
aoi_wkt   <- aoi_utm |> st_buffer(2000) |> st_transform(tang_crs) |> st_as_text()   # +2km so
                                                                                    # border-straddling
                                                                                    # polygons aren't clipped out
tang_aoi <- st_read(tang_path, wkt_filter = aoi_wkt, quiet = TRUE) |>
  st_zm(drop = TRUE) |>
  st_make_valid() |>
  st_transform(UTM30N) |>
  transmute(source_id = as.character(OBJECTID)) |>
  st_transform(4326)
message(sprintf("  %d Tang & Werner polygons in AOI", nrow(tang_aoi)))
if (nrow(tang_aoi) > 0) upload_as_asset(tang_aoi, "gt_compare_tang_raw")

####6. SmallMinesDS -- real outlines in the AOI, share_mined > 0 (skip true empties only) ####
# Same vectorisation as validate_external_references.R Part 2c, but NO >10% floor -- see header
# note on why that floor doesn't apply here.

message("=== Vectorising SmallMinesDS real outlines in AOI (share_mined > 0) ===")
AOI_EPOCH   <- 2022
patches_reg <- readRDS(here("data", "processed", "labels", "smallminesds_patch_footprints.rds"))
aoi_hit     <- st_intersects(aoi_utm, st_transform(patches_reg, UTM30N), sparse = FALSE)[1, ]
aoi_sel     <- patches_reg[aoi_hit, ] |> filter(epoch == AOI_EPOCH, share_mined > 0)
message(sprintf("  %d patches selected (epoch %d, share > 0) out of %d in the box",
                nrow(aoi_sel), AOI_EPOCH, sum(aoi_hit)))

smds_dir_epoch <- here("data", "raw", "smallminesds", "SmallMinesDS", "SmallMinesDS", as.character(AOI_EPOCH))
aoi_mask_paths <- file.path(smds_dir_epoch, "MASK", sprintf("MASK_%s_%d.tif", aoi_sel$patch_id, AOI_EPOCH))
stopifnot("Some SmallMinesDS mask files not found -- check smds_dir_epoch / patch_id format" =
            all(file.exists(aoi_mask_paths)))

aoi_outline_list <- lapply(seq_along(aoi_mask_paths), function(i) {
  r     <- rast(aoi_mask_paths[i])
  r_bin <- (r == 1)
  p <- as.polygons(r_bin, dissolve = TRUE) |> st_as_sf()
  p <- p |> filter(.data[[names(r_bin)[1]]] == TRUE)
  if (nrow(p) == 0) return(NULL)
  p |> mutate(patch_id = aoi_sel$patch_id[i], share_mined = aoi_sel$share_mined[i]) |>
    select(patch_id, share_mined)
})
aoi_outlines <- do.call(rbind, Filter(Negate(is.null), aoi_outline_list)) |> st_transform(4326)
message(sprintf("  %d non-empty outlines vectorised", nrow(aoi_outlines)))
if (nrow(aoi_outlines) > 0) upload_as_asset(aoi_outlines, "gt_compare_smallminesds_aoi")

####7. Write the ready-to-paste Code Editor JS ####

js_path <- here("code", "1_remote_sensing", "validate_ground_truth_comparison.js")
js <- sprintf('
// validate_ground_truth_comparison.js
// Paste into code.earthengine.google.com (project: %1$s). Compares raw Barenblitt, raw Maus,
// raw Tang & Werner, SmallMinesDS real outlines, and build_02_embedding_classifier.R\'s OWN
// c4 mine-probability output for 2022 against a live Sentinel-2 2022 composite -- generated by
// validate_ground_truth_comparison.R, which uploaded the four small AOI-scoped assets this
// script reads.
//
// 2026-09-03: repointed from the old single-image binary asset (mine_prob_ghana_2022) to the
// current TILED c4 export (mine_prob_ghana_c4_2022_t{NN}, build_02 Section 10) -- mosaic the
// year\'s tiles since there is no single per-year c4 image. Cutoff 45 (settled 2026-08-18).

var ASSET_HOME = "%2$s";
var AOI_CENTER = ee.Geometry.Point([%3$f, %4$f]);
var AOI_HALFWIDTH_M = %5$f;
var aoi = AOI_CENTER.buffer(AOI_HALFWIDTH_M * 1.4142).bounds();  // *sqrt(2) ~ circumscribes the R script\'s square AOI

// -- Sources --
var barenblitt = ee.FeatureCollection(ASSET_HOME + "/gt_compare_barenblitt_raw");
var maus  = ee.FeatureCollection(ASSET_HOME + "/gt_compare_maus_raw");
var tang  = ee.FeatureCollection(ASSET_HOME + "/gt_compare_tang_raw");
var smds  = ee.FeatureCollection(ASSET_HOME + "/gt_compare_smallminesds_aoi");
// Mosaic the 2022 c4 probability tiles (0-100 uint8). stringStartsWith "..._2022_t" also matches
// any lingering split sub-tiles (_t06s01 etc.) -- harmless for a mosaic (same values on overlap).
var prob  = ee.ImageCollection(ASSET_HOME)
  .filter(ee.Filter.stringStartsWith("system:index", "mine_prob_ghana_c4_2022_t"))
  .mosaic()
  .clip(aoi);

// -- Live Sentinel-2 2022 composite (cloud-masked median, matches SmallMinesDS/classifier vintage) --
function maskS2(img) {
  var scl = img.select("SCL");
  return img.updateMask(scl.neq(3).and(scl.neq(9))).divide(10000);
}
var s2_2022 = ee.ImageCollection("COPERNICUS/S2_SR_HARMONIZED")
  .filterBounds(aoi)
  .filterDate("2022-01-01", "2022-12-31")
  .filter(ee.Filter.lt("CLOUDY_PIXEL_PERCENTAGE", 40))
  .map(maskS2)
  .median()
  .select(["B4", "B3", "B2"])
  .clip(aoi);

// -- Display --
Map.centerObject(aoi, 12);
Map.addLayer(s2_2022, {min: 0, max: 0.3}, "Sentinel-2 2022 (true colour)", true);
Map.addLayer(prob.gte(45).selfMask(), {palette: ["00c3ff"]}, "Classifier c4 >= 45%% (2022)", true);
Map.addLayer(smds.style({color: "ff2a2a", fillColor: "00000000", width: 2}), {}, "SmallMinesDS (real outlines)", true);
Map.addLayer(barenblitt.style({color: "450457", fillColor: "00000000", width: 2}), {}, "Barenblitt 2019 (raw, both types)", true);
Map.addLayer(maus.style({color: "2171B5", fillColor: "00000000", width: 2}), {}, "Maus et al. 2022 (raw)", true);
Map.addLayer(tang.style({color: "D94701", fillColor: "00000000", width: 2}), {}, "Tang & Werner 2023 (raw)", true);

print("SmallMinesDS patches:", smds.size(), " Barenblitt polygons:", barenblitt.size(),
      " Maus polygons:", maus.size(), " Tang polygons:", tang.size());
', EE_PROJECT, EE_ASSET_HOME, aoi_ll_centroid[1, "X"], aoi_ll_centroid[1, "Y"],
   AOI_SITE$halfwidth_km * 1000)

writeLines(js, js_path)
message("Wrote Code Editor script: ", js_path)
message("\n=== validate_ground_truth_comparison.R complete -- paste the .js file into code.earthengine.google.com ===")
