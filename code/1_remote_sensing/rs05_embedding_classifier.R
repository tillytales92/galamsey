# rs05_embedding_classifier.R
# Mine detection via Google AlphaEarth satellite embeddings (2017–2024)
#
# Workflow:
#   1. Load Barenblitt 2019 artisanal polygons as positive training labels
#   2. Rasterize labels + extract 2019 annual embeddings via stratifiedSample()
#   3. Train a Random Forest classifier (200 trees) on the 64-band embedding
#   4. Assess accuracy on a held-out 20% spatial split
#   5. Apply trained classifier to each year 2017–2024 → probability maps
#   6. Export annual GeoTIFFs to Google Drive
#
# Design notes: code/1_remote_sensing/rs03_embedding_classifier_design.md
# GEE setup: mirrors rs01_landsat_gee.R — run ee_Authenticate() /
# ee_Initialize() interactively before sourcing.

####1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, googledrive, tidyverse, sf, here, janitor, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)

####2. Authenticate ####
rgee::ee_Authenticate()
rgee::ee_Initialize(drive = TRUE)
ee_check()
googledrive::drive_auth()

####3. Study Area + Training Labels ####

gha_country <- st_read(
  here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp"),
  quiet = TRUE
) |> st_transform(4326)

# Barenblitt 2019 — artisanal mines only (minetype == 1)
# CLAUDE.md: always select() before sf_as_ee() to drop date columns that
# crash the upload; st_make_valid() before any spatial operations.
mining_2019 <- st_read(
  here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp"),
  quiet = TRUE
) |>
  clean_names() |>
  st_transform(4326) |>
  st_make_valid()

artisanal_sf <- mining_2019 |>
  filter(mine_type == 1) |>
  select(geometry)

message(sprintf("Artisanal mine polygons loaded: %d", nrow(artisanal_sf)))

# Study area = convex hull of all Barenblitt polygons (SW Ghana survey extent)
# This constrains both positive and negative sampling to the Barenblitt region,
# avoiding extrapolation to northern Ghana where there are no training negatives.
sf_use_s2(FALSE)

study_area_sf <- mining_2019 |>
  st_union() |>
  st_convex_hull() |>
  st_sf() |>
  mutate(id = 1L) |>
  rename("mining_2019" = "st_convex_hull.st_union.mining_2019..")

# Convert to EE objects
artisanal_ee  <- sf_as_ee(artisanal_sf)
study_area_ee <- sf_as_ee(study_area_sf)

# Ghana bounding box for embedding mosaics (wider than study area — mosaics
# are clipped to study_area_ee at export time)
bbox_ghana   <- st_bbox(gha_country)
ghana_bounds <- ee$Geometry$Rectangle(
  coords   = c(bbox_ghana[["xmin"]], bbox_ghana[["ymin"]],
               bbox_ghana[["xmax"]], bbox_ghana[["ymax"]]),
  proj     = "EPSG:4326",
  geodesic = FALSE
)

####4. Parameters ####
DRIVE_FOLDER   <- "ghana_mining_gee_exports"
EMBED_YEARS    <- 2017:2024
TRAIN_YEAR     <- 2019L    # embedding year aligned with Barenblitt 2019 extent
N_MINE_PX      <- 2000L    # positive training samples
N_NONMINE_PX   <- 6000L    # negative training samples (1:3 ratio)
N_TREES        <- 200L     # Random Forest trees
EXPORT_SCALE   <- 10L      # metres — use 30L for faster test exports
SEED           <- 42L

out_embed <- here("data", "raw", "embedding")
dir.create(out_embed, recursive = TRUE, showWarnings = FALSE)

####5. Build Training Dataset ####

message("=== Step 5: Building training dataset ===")

# Load the annual embedding mosaic for the training year
embedding_train <- ee$ImageCollection("GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL")$
  filterBounds(ghana_bounds)$
  filterDate(paste0(TRAIN_YEAR, "-01-01"), paste0(TRAIN_YEAR + 1L, "-01-01"))$
  mosaic()   # tiles are in local UTM; mosaic reprojects to a common CRS on export

message(sprintf("Embedding bands available: %d",
                length(embedding_train$bandNames()$getInfo())))

# Create a binary label raster within the study area:
#   1 = confirmed artisanal mine (Barenblitt 2019)
#   0 = non-mine land within the SW Ghana study area
#
# ee$Image$constant(0) covers the globe; clipping to study_area_ee constrains
# negative samples to the Barenblitt survey region. Pixels outside the study
# area are masked (not sampled), preventing northern-Ghana false negatives.
label_image <- ee$Image$constant(0L)$
  byte()$
  paint(featureCollection = artisanal_ee, color = 1L)$
  clip(study_area_ee)$
  rename("label")

# Stack embedding bands with the label band so stratifiedSample() returns
# both the label and all 64 embedding dimensions in one call.
stacked <- embedding_train$addBands(label_image)
band_names <- embedding_train$bandNames()$getInfo()

# Stratified sample: equal representation of mine vs non-mine per stratum.
# tileScale = 8 reduces memory pressure over the large export region.
# geometries = TRUE retains point coordinates (needed for spatial CV in R).
training_fc <- stacked$stratifiedSample(
  numPoints       = N_MINE_PX,      # ignored when classPoints is set
  classBand       = "label",
  region          = study_area_ee$geometry(),
  scale           = EXPORT_SCALE,
  seed            = SEED,
  classValues     = list(0L, 1L),
  classPoints     = list(N_NONMINE_PX, N_MINE_PX),
  geometries      = TRUE,
  tileScale       = 8L
)

message(sprintf("Training samples requested: %d mine + %d non-mine",
                N_MINE_PX, N_NONMINE_PX))

####6. Train Random Forest Classifier ####

message("=== Step 6: Training Random Forest ===")

# Split into 80% train / 20% test using a random column.
# NOTE: this is a random (non-spatial) split for a quick in-sample accuracy
# check. For spatial cross-validation by district, export training_fc to Drive
# (Section 8) and run spatial CV in R after downloading.
training_split <- training_fc$randomColumn("rand", seed = SEED)
train_fc <- training_split$filter(ee$Filter$lt("rand", 0.8))
test_fc  <- training_split$filter(ee$Filter$gte("rand", 0.8))

# Train two classifiers: one binary (for maps), one probability (for thresholding)
classifier_binary <- ee$Classifier$smileRandomForest(N_TREES)$
  train(
    features        = train_fc,
    classProperty   = "label",
    inputProperties = band_names
  )

classifier_prob <- ee$Classifier$smileRandomForest(N_TREES)$
  setOutputMode("PROBABILITY")$
  train(
    features        = train_fc,
    classProperty   = "label",
    inputProperties = band_names
  )

message("Classifiers trained.")

####7. Accuracy Assessment ####

message("=== Step 7: Accuracy assessment (random 80/20 split) ===")

# Classify the test set and compute a confusion matrix.
# getInfo() blocks R until GEE returns the result — takes ~30 sec.
test_classified <- test_fc$classify(classifier_binary, "predicted")

conf_matrix <- test_classified$errorMatrix(
  actual    = "label",
  predicted = "predicted"
)

overall_acc  <- conf_matrix$accuracy()$getInfo()
kappa        <- conf_matrix$kappa()$getInfo()
producers    <- conf_matrix$producersAccuracy()$getInfo()   # recall per class
consumers    <- conf_matrix$consumersAccuracy()$getInfo()   # precision per class

message(sprintf("Overall accuracy : %.3f", overall_acc))
message(sprintf("Kappa            : %.3f", kappa))
message(sprintf("Mine recall      : %.3f  (producer accuracy, class 1)", producers[[2]][[1]]))
message(sprintf("Mine precision   : %.3f  (consumer accuracy, class 1)", consumers[[2]][[1]]))
message("NOTE: random split overstates accuracy due to spatial autocorrelation.")
message("      Run spatial CV by district in R after exporting training samples.")

####8. Export Annual Mine Probability Maps (2017–2024) ####

message("\n=== Step 8: Submitting export tasks ===")

embed_tasks <- map(EMBED_YEARS, function(yr) {

  # Annual embedding mosaic for this year
  emb_yr <- ee$ImageCollection("GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL")$
    filterBounds(ghana_bounds)$
    filterDate(paste0(yr, "-01-01"), paste0(yr + 1L, "-01-01"))$
    mosaic()

  # Apply probability classifier → single band [0, 1] named "mine_prob"
  prob_map <- emb_yr$classify(classifier_prob)$
    rename("mine_prob")$
    clip(study_area_ee)   # clip to Barenblitt study area (SW Ghana)

  task <- ee$batch$Export$image$toDrive(
    image          = prob_map,
    description    = paste0("mine_prob_ghana_", yr),
    folder         = DRIVE_FOLDER,
    fileNamePrefix = paste0("mine_prob_ghana_", yr),
    scale          = EXPORT_SCALE,
    region         = study_area_ee$geometry()$bounds(),
    crs            = "EPSG:4326",
    maxPixels      = 1e13,
    fileFormat     = "GeoTIFF"
  )
  task$start()
  message(sprintf("  Submitted: mine_prob_ghana_%d  (scale = %d m)", yr, EXPORT_SCALE))
  task
})

# Export the training sample as a CSV for spatial CV in R
training_export_task <- ee$batch$Export$table$toDrive(
  collection  = training_fc,
  description = "mine_embedding_training_samples",
  folder      = DRIVE_FOLDER,
  fileFormat  = "CSV"
)
training_export_task$start()
message("  Submitted: mine_embedding_training_samples.csv")

message(sprintf("\nSubmitted %d probability map exports + 1 training CSV to '%s'.",
                length(embed_tasks), DRIVE_FOLDER))
message("Monitor: code.earthengine.google.com → Tasks tab")
message("Exports cover the Barenblitt study area (SW Ghana) at ", EXPORT_SCALE, " m resolution.")

####9. Download from Google Drive ####
# Run AFTER all GEE tasks show "COMPLETED".
# Reuses download_from_drive() from d_01_download_gee.R — source that script
# first if running in a fresh session.

# -- Uncomment once GEE tasks complete ----------------------------------------
# download_from_drive(DRIVE_FOLDER, "mine_prob_ghana_",          out_embed)
# download_from_drive(DRIVE_FOLDER, "mine_embedding_training_",  out_embed)

####10. Load Probability Maps into a Raster Stack ####
# Run AFTER Section 9 has downloaded all files locally.
# Produces mine_prob_stack: a terra SpatRaster with one layer per year,
# named "mine_prob_{year}". Used by rs06_embedding_panel.R to compute
# annual mine area per hex / district.

# pacman::p_load(terra)
#
# prob_files <- sort(list.files(out_embed,
#                               pattern = "^mine_prob_ghana_\\d{4}\\.tif$",
#                               full.names = TRUE))
# if (length(prob_files) == 0) {
#   message("No probability map files found — run Sections 8–9 first.")
# } else {
#   mine_prob_stack <- terra::rast(prob_files)
#   years_found     <- as.integer(stringr::str_extract(
#                        basename(prob_files), "\\d{4}"))
#   names(mine_prob_stack) <- paste0("mine_prob_", years_found)
#   message(sprintf("Probability stack: %d layers (%d–%d), %.0f m res",
#                   terra::nlyr(mine_prob_stack),
#                   min(years_found), max(years_found),
#                   mean(terra::res(mine_prob_stack)) * 111320))
# }

message("\n=== rs05_embedding_classifier.R: export tasks submitted ===")
