# diag_03_embedding_product.R -- everything diag_03_embedding_product_report.Rmd needs from GEE.
#
# Tied to build_03 (annual masks) + build_03b (Rule B -> Option 1 "ever mined" / Option 2
# "currently mined"). Two Drive table exports, non-blocking like b_04: each run submits whatever is
# missing and stops; re-run once the Tasks tab shows COMPLETED, and the CSVs are downloaded.
#
#   (A) diag03_areas.csv -- one row per region (ghana, bar_hull = Barenblitt et al. 2019 convex hull):
#       area (m2) per year of raw / cur (Opt 2) / ever (Opt 1); year-pair gains and losses for raw and
#       cur; area by number of on/off switches 2017-2025 (raw, cur); unconfirmed 2025 entries; and
#       overlap with each reference product (Barenblitt et al. artisanal + all, Maus, Tang & Werner),
#       references masked by the industrial footprint build_03 excludes, at each of COMPARE_YEARS.
#   (B) diag03_points_2022.csv -- the 11,040 SmallMinesDS 2022 validation points (build_01) sampled on
#       the 2022 raw / cur / ever masks: PA/UA of the FINAL product, not just the classifier
#       probability (diag_02_scoring.R).
#
# Run INTERACTIVELY (ee_Authenticate blocks on a browser login). Prereq: build_03b's asset exists.

####1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, here, tidyverse, sf, googledrive, conflicted)
conflicts_prefer(dplyr::filter, dplyr::select, dplyr::mutate, dplyr::lag, here::here)

EE_PROJECT    <- "rgee-auth-tillam"
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)

ee_Authenticate()
ee_Initialize(drive = TRUE, project = EE_PROJECT)
googledrive::drive_auth()

####2. Parameters ####
MASK_YEARS    <- 2017:2025
MASK_PREFIX   <- "mine_mask_ghana_c4_"
STATUS_ASSET  <- file.path(EE_ASSET_HOME, "mine_status_ghana_c4_ruleB_2017_2025")   # build_03b
IND_ASSET     <- file.path(EE_ASSET_HOME, "industrial_final_selected_2026-10-27")   # = validate_finalproduct.js
# Reference IMAGERY years (= build_01_labels.R's VINTAGE): Barenblitt et al. and Maus 2019, Tang & Werner
# mixed ~2019-22 -> 2021. Every reference is scored at both years; the report shows its own year + 2019.
COMPARE_YEARS <- c(2019L, 2021L)
SCALE         <- 10L          # native; 30 is ~9x cheaper if the export times out
OUT_DIR       <- here("outputs", "tables", "embedding_product")
DRIVE_FOLDER  <- "ghana_mining_gee_exports"
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

asset_exists <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)
if (!asset_exists(STATUS_ASSET)) stop(STATUS_ASSET, " not found -- run build_03b_temporal_rules.R first")

# Same task-check / Drive helpers as b_04 (duplicated, not sourced -- project convention).
reticulate::py_run_string(paste(
  "import ee",
  "def ee_task_running(desc):",
  "    try:",
  "        tasks = ee.data.getTaskList()",
  "    except Exception:",
  "        tasks = [t.status() for t in ee.batch.Task.list()]",
  "    return any(t.get('description') == desc and t.get('state') in ('READY', 'RUNNING') for t in tasks)",
  sep = "\n"))
task_running <- function(desc) isTRUE(reticulate::py$ee_task_running(desc))
drive_download_export <- function(export_name, dest_path) {
  folder <- googledrive::drive_find(pattern = DRIVE_FOLDER, type = "folder", n_max = 1)
  if (nrow(folder) == 0) stop("Drive folder '", DRIVE_FOLDER, "' not found")
  hit <- googledrive::drive_ls(folder[1, ]) |> filter(name == paste0(export_name, ".csv"))
  if (nrow(hit) == 0) return(FALSE)
  googledrive::drive_download(hit[1, ], path = dest_path, overwrite = TRUE)
  TRUE
}
fetch_or_submit <- function(name, make_task) {
  dest <- file.path(OUT_DIR, paste0(name, ".csv"))
  if (file.exists(dest)) return(TRUE)
  if (drive_download_export(name, dest)) return(TRUE)
  if (task_running(name)) { message("  '", name, "' still running"); return(FALSE) }
  make_task()$start(); message("  submitted '", name, "'"); FALSE
}

####3. Images ####
area   <- ee$Image$pixelArea()
status <- ee$Image(STATUS_ASSET)
entry  <- status$select("entry_year")$unmask(0)
k <- as.character(MASK_YEARS)
raw  <- setNames(lapply(MASK_YEARS, function(y) ee$Image(file.path(EE_ASSET_HOME, paste0(MASK_PREFIX, y)))$unmask(0)$gt(0)), k)
cur  <- setNames(lapply(MASK_YEARS, function(y) status$select(paste0("cur_", y))$unmask(0)), k)
ever <- setNames(lapply(MASK_YEARS, function(y) entry$gt(0)$And(entry$lte(y))), k)

bars <- ee$FeatureCollection(file.path(EE_ASSET_HOME, "gt_compare_barenblitt_raw"))
GHANA    <- ee$FeatureCollection(file.path(EE_ASSET_HOME, "rs05_ghana"))$geometry()
bar_hull <- bars$geometry()$convexHull()
regions  <- ee$FeatureCollection(list(ee$Feature(GHANA, list(region = "ghana")),
                                      ee$Feature(bar_hull, list(region = "bar_hull"))))

paint <- function(fc) ee$Image$constant(0L)$byte()$paint(fc, 1L)
not_ind <- paint(ee$FeatureCollection(IND_ASSET))$Not()
refs <- list(bar_art = bars$filter(ee$Filter$eq("mine_type", 1L)),
             bar_all = bars,
             maus    = ee$FeatureCollection(file.path(EE_ASSET_HOME, "gt_compare_maus_raw")),
             tang    = ee$FeatureCollection(file.path(EE_ASSET_HOME, "gt_compare_tang_raw")))

A <- function(img, name) img$multiply(area)$rename(name)
switches <- function(s) Reduce(function(a, b) a$add(b), lapply(2:length(k), function(i) s[[k[i]]]$neq(s[[k[i - 1]]])))
any_of_  <- function(s) Reduce(function(a, b) a$Or(b), s)

bands <- c(
  unlist(lapply(k, function(y) list(A(raw[[y]], paste0("raw_", y)), A(cur[[y]], paste0("cur_", y)),
                                    A(ever[[y]], paste0("ever_", y)))), recursive = FALSE),
  unlist(lapply(2:length(k), function(i) {
    y <- k[i]; p <- k[i - 1]
    list(A(raw[[y]]$And(raw[[p]]$Not()), paste0("rgain_", y)), A(raw[[p]]$And(raw[[y]]$Not()), paste0("rloss_", y)),
         A(cur[[y]]$And(cur[[p]]$Not()), paste0("cgain_", y)), A(cur[[p]]$And(cur[[y]]$Not()), paste0("closs_", y)))
  }), recursive = FALSE),
  { swr <- switches(raw); swc <- switches(cur); ar <- any_of_(raw); ac <- any_of_(cur)
    unlist(lapply(0:(length(k) - 1L), function(n)
      list(A(swr$eq(n)$And(ar), paste0("swraw_", n)), A(swc$eq(n)$And(ac), paste0("swcur_", n)))), recursive = FALSE) },
  list(A(entry$eq(max(MASK_YEARS)), "unconf")),
  unlist(lapply(names(refs), function(r) {
    rimg <- paint(refs[[r]]); rx <- rimg$And(not_ind)
    c(list(A(rimg, paste0("ref_", r)), A(rx, paste0("refx_", r))),
      unlist(lapply(as.character(COMPARE_YEARS), function(y)
        list(A(rx$And(raw[[y]]),  sprintf("both_raw_%s_%s", r, y)),
             A(rx$And(cur[[y]]),  sprintf("both_cur_%s_%s", r, y)),
             A(rx$And(ever[[y]]), sprintf("both_ever_%s_%s", r, y)))), recursive = FALSE))
  }), recursive = FALSE)
)
area_img <- ee$Image$cat(bands)

####4. Export A: areas per region ####
okA <- fetch_or_submit("diag03_areas", function()
  ee$batch$Export$table$toDrive(
    collection = area_img$reduceRegions(collection = regions, reducer = ee$Reducer$sum(), scale = SCALE,
                                        crs = "EPSG:32630", tileScale = 16L)$
      select(c("region", area_img$bandNames()$getInfo()), retainGeometry = FALSE),
    description = "diag03_areas", folder = DRIVE_FOLDER, fileFormat = "CSV"))

####5. Export B: SmallMinesDS 2022 points on the final masks ####
# Two stages (2026-11-25): sampling with the 11,040 points inlined in the task ran out of memory
# (EE error code 8), so the points are first stored as a table asset (cheap task, no image maths),
# and the sampling export reads that asset. Re-run the script after each stage completes.
PTS_ASSET <- file.path(EE_ASSET_HOME, "diag03_smallminesds_pts_2022")
asset_exists <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)
okB <- FALSE
if (!asset_exists(PTS_ASSET)) {
  if (task_running("diag03_pts_upload")) {
    message("  'diag03_pts_upload' still running")
  } else {
    pts <- readRDS(here("data", "processed", "labels", "smallminesds_validation_points_2022.rds")) |>
      mutate(pt_id = row_number()) |> select(pt_id, patch_id, label) |> st_transform(4326)
    chunks <- split(pts, ceiling(seq_len(nrow(pts)) / 2000))
    pts_inline <- Reduce(function(a, b) a$merge(b), lapply(chunks, function(x) sf_as_ee(x, via = "getInfo")))
    ee$batch$Export$table$toAsset(collection = pts_inline, description = "diag03_pts_upload",
                                  assetId = PTS_ASSET)$start()
    message("  submitted 'diag03_pts_upload' (points -> asset); re-run when it completes")
  }
} else {
  pts_ee <- ee$FeatureCollection(PTS_ASSET)
  pt_img <- ee$Image$cat(list(raw[["2022"]]$rename("raw"), cur[["2022"]]$rename("cur"), ever[["2022"]]$rename("ever")))
  okB <- fetch_or_submit("diag03_points_2022", function()
    ee$batch$Export$table$toDrive(
      collection = pt_img$sampleRegions(collection = pts_ee, properties = list("pt_id", "patch_id", "label"),
                                        scale = SCALE, geometries = FALSE, tileScale = 16L),
      description = "diag03_points_2022", folder = DRIVE_FOLDER, fileFormat = "CSV"))
}

if (okA && okB) message("Both CSVs in ", OUT_DIR, " -- render diag_03_embedding_product_report.Rmd") else
  message("Exports pending -- re-run once COMPLETED.")
