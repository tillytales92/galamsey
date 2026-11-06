# upload_protected_areas.R
# Uploads Ghana's WDPA/WDOECM protected areas (code/0_data/d_11_protected_areas.R's merged layer)
# to Earth Engine as a FeatureCollection asset, so explore_mining_vs_forest_type_app.js can show
# them as a toggleable layer and diag_05_mining_by_region.qmd can compute per-district mining-
# within-protected-area overlap.
#
# Source: data/processed/protected_areas/protected_areas_poly.shp (WDPA/WDOECM, UNEP-WCMC & IUCN,
# Jul 2026 Ghana extract). Filtered to STATUS == "Designated" only (drops 29 of 290 "Proposed"
# sites -- not yet legally protected, shouldn't read as "mining inside a protected area" the same
# way). 264 of the remaining 261 designated sites are "Forest Reserve" (DESIG_ENG) -- the
# dominant category by far, matching the "forests that should be under protection" framing this
# was requested for.
#
# Run INTERACTIVELY (rgee authentication). Not yet run -- check the asset in the Code Editor
# afterwards.

####1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, tidyverse, sf, here)

UTM30N        <- 32630
EE_PROJECT    <- "rgee-auth-tillam"   # ID, never the numeric project number
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
ASSET_ID      <- file.path(EE_ASSET_HOME, "protected_areas_designated")
PA_STATUS_KEEP <- c("Designated")   # excludes "Proposed" -- not yet legally protected

####2. Load and filter ####
pa_src <- st_read(here("data", "processed", "protected_areas", "protected_areas_poly.shp"), quiet = TRUE)
pa <- pa_src |>
  filter(STATUS %in% PA_STATUS_KEEP) |>
  st_zm(drop = TRUE) |>
  st_transform(UTM30N) |>
  select(SITE_ID, NAME, DESIG_ENG, IUCN_CAT, STATUS, STATUS_YR, REP_AREA, OECM_ASMT)
message(sprintf("Protected areas: %d of %d sites kept (STATUS %%in%% %s)",
                nrow(pa), nrow(pa_src), paste(PA_STATUS_KEEP, collapse = "/")))
print(table(pa$DESIG_ENG))

####3. Clean geometry for EE (same pattern as upload_gold_leases.R) ####
ee_ready <- function(g) {
  g <- st_set_precision(g, 1) |> st_make_valid()
  g <- suppressWarnings(st_collection_extract(g, "POLYGON"))
  g <- g[!st_is_empty(g), ]
  print(table(as.character(st_geometry_type(g))))
  st_transform(g, 4326)
}
pa_ee <- ee_ready(pa)
message(sprintf("Cleaned: %d features, %.0f km2 total", nrow(pa_ee),
                sum(as.numeric(st_area(st_transform(pa_ee, UTM30N)))) / 1e6))

####4. Local copy (fallback for a manual Code Editor upload) ####
dir.create(here("outputs"), showWarnings = FALSE)
local_shp <- here("outputs", "protected_areas_designated.shp")
st_write(pa_ee, local_shp, delete_dsn = TRUE, quiet = TRUE)
message("Wrote ", local_shp)

####5. Upload to Earth Engine ####
# sf_as_ee() inline (via="getInfo", fine at this size, ~261 features) + Export$table$toAsset --
# NOT sf_as_ee(..., assetId=...) directly, which routes through the legacy getInfo_to_asset path
# and silently lands under projects/earthengine-legacy/ instead of this Cloud Project (same bug
# documented in build_02_embedding_classifier.R / upload_gold_leases.R).
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

tryCatch({
  if (tryCatch({ ee$data$getAsset(ASSET_ID); TRUE }, error = function(e) FALSE)) {
    message("  deleting pre-existing asset: ", ASSET_ID)
    ee$data$deleteAsset(ASSET_ID)
  }
  fc   <- sf_as_ee(pa_ee)
  task <- ee$batch$Export$table$toAsset(collection = fc, description = "upload_protected_areas", assetId = ASSET_ID)
  task$start()
  message("  task submitted -- visible under code.earthengine.google.com -> Tasks")
  wait_until_asset_ready(ASSET_ID)
  message("Uploaded (confirmed queryable): ", ASSET_ID)
}, error = function(e) message(
  "Upload failed (", conditionMessage(e), ").\n",
  "  -> upload ", local_shp, " in the Code Editor (Assets > New > Shape files), named protected_areas_designated."))
