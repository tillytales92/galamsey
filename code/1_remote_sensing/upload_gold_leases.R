# upload_gold_leases.R
# Uploads the gold-bearing Minerals Commission Mining Leases (the same set build_03 Section 7 uses as
# its exclusion gate) to Earth Engine as a dated FeatureCollection asset, so the validate_*.js
# scripts can show lease boundaries, owners and codes directly.
#
# Source: data/processed/mining_repository/active_licenses_clean.gpkg (d_12). Filter: type_simplified ==
# "Mining Lease" AND gold == 1 (NA = no commodity data, dropped). Geometry is cleaned the same way as
# build_03 (per-feature GEOS check, precision snap, POLYGON-only, MULTIPOLYGON, 4326) so no degenerate
# rings reach EE. Output asset: projects/rgee-auth-tillam/assets/ghana_mining/mining_leases_gold_<YYYY-MM-DD>
# plus a local copy in outputs/ to upload by hand if sf_as_ee() times out.
#
# Run INTERACTIVELY (rgee authentication). Not yet run -- check the asset in the Code Editor afterwards.

####1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, tidyverse, sf, here)

UTM30N     <- 32630
EE_PROJECT <- "rgee-auth-tillam"   # ID, never the numeric project number
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
SNAPSHOT   <- format(Sys.Date(), "%Y-%m-%d")
ASSET_ID   <- file.path(EE_ASSET_HOME, paste0("mining_leases_gold_", SNAPSHOT))

####2. Load and filter ####
leases_src <- st_read(here("data", "processed", "mining_repository", "active_licenses_clean.gpkg"),
                      quiet = TRUE)
leases <- leases_src |>
  filter(type_simplified == "Mining Lease", gold == 1) |>
  st_zm(drop = TRUE) |>
  st_transform(UTM30N) |>
  select(code, owner, type, status, start_date, expiry_date, gold) |>
  mutate(across(c(start_date, expiry_date), as.character))
message(sprintf("Gold Mining Leases: %d of %d active licences", nrow(leases), nrow(leases_src)))

####3. Per-feature geometry check (same test as build_03 Section 7) ####
lease_ok <- vapply(seq_len(nrow(leases)), function(i)
  tryCatch({ suppressWarnings(st_make_valid(st_geometry(leases)[i])); TRUE }, error = function(e) FALSE),
  logical(1))
if (any(!lease_ok)) {
  message(sprintf("  dropping %d feature(s) GEOS cannot repair: code %s", sum(!lease_ok),
                  paste(leases$code[!lease_ok], collapse = ", ")))
  leases <- leases[lease_ok, ]
}
# make_valid() can also collapse a degenerate ring to a LINESTRING without erroring; such a lease has
# no area and breaks the polygon extraction below, so drop it here and print its code.
polygonal <- as.character(st_geometry_type(st_make_valid(st_set_precision(leases, 1)))) %in%
  c("POLYGON", "MULTIPOLYGON")
if (any(!polygonal)) {
  message(sprintf("  dropping %d lease(s) that collapse to a non-polygon: code %s", sum(!polygonal),
                  paste(leases$code[!polygonal], collapse = ", ")))
  leases <- leases[polygonal, ]
}

####4. Clean geometry for EE ####
ee_ready <- function(g) {
  g <- st_set_precision(g, 1) |> st_make_valid()
  g <- suppressWarnings(st_collection_extract(g, "POLYGON"))
  g <- g[!st_is_empty(g), ]
  # diagnostic: should list only POLYGON / MULTIPOLYGON; anything else is a leftover collection
  print(table(as.character(st_geometry_type(g))))
  st_transform(g, 4326)   # no st_cast(): sf_as_ee() accepts POLYGON and MULTIPOLYGON together
}
leases_ee <- ee_ready(leases)
message(sprintf("Cleaned: %d features, %.0f km2 total", nrow(leases_ee),
                sum(as.numeric(st_area(st_transform(leases_ee, UTM30N)))) / 1e6))

####5. Local copy (fallback for a manual Code Editor upload) ####
dir.create(here("outputs"), showWarnings = FALSE)
local_shp <- here("outputs", paste0("mining_leases_gold_", SNAPSHOT, ".shp"))
st_write(leases_ee, local_shp, delete_dsn = TRUE, quiet = TRUE)
message("Wrote ", local_shp)

####6. Upload to Earth Engine ####
# NOT sf_as_ee(leases_ee, assetId = ...) directly -- that routes through rgee's
# via = "getInfo_to_asset" path, a legacy manifest-based asset-creation route that
# unconditionally prefixes "projects/earthengine-legacy/assets/" -- broken for this
# Cloud-Project account (same bug documented in build_02_embedding_classifier.R's
# upload_as_asset()). It fails SILENTLY from R's perspective (no error, "Uploaded: ..."
# prints) but the asset either lands under the legacy namespace or never becomes
# queryable, so Collection.loadTable in the Code Editor reports "not found" at the
# Cloud-Project path. Proven fix (same pattern as build_02/validate_finalproduct.R):
# build the FeatureCollection inline via sf_as_ee() with NO assetId (via = "getInfo",
# fine at this size), then persist it with EE's own Export$table$toAsset, which
# resolves Cloud-Project asset paths correctly.
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
  fc   <- sf_as_ee(leases_ee)   # inline, via = "getInfo" default -- small enough at this size
  task <- ee$batch$Export$table$toAsset(collection = fc, description = "upload_gold_leases", assetId = ASSET_ID)
  task$start()
  message("  task submitted -- visible under code.earthengine.google.com -> Tasks")
  wait_until_asset_ready(ASSET_ID)
  message("Uploaded (confirmed queryable): ", ASSET_ID)
}, error = function(e) message(
  "Upload failed (", conditionMessage(e), ").\n",
  "  -> upload ", local_shp, " in the Code Editor (Assets > New > Shape files), named mining_leases_gold_", SNAPSHOT, "."))
