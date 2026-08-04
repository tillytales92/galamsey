# rs05_embedding_classifier.R
# Mine detection via Google AlphaEarth satellite embeddings (2017–2025)
#
# REWIRED 2026-07-14 to consume the rs07_labels.R artifacts (multi-source labels)
# and to run a source ablation scored against held-out SmallMinesDS 2022.
#
# Workflow:
#   1. Load harmonised labels from data/processed/labels/ (rs07_labels.R):
#      positives by source (barenblitt / maus / tang), exclusion mask,
#      SmallMinesDS 2022 validation points
#   2. Sample training-point LOCATIONS locally in R (positives area-weighted in
#      the label cores; negatives outside the exclusion mask), upload the
#      points + study area + validation points as EE ASSETS (browsable/
#      visualisable in the Code Editor, not just inline request literals — see
#      EE_ASSET_HOME), and read each vintage's embedding year at the training
#      points (barenblitt+maus → 2019, tang → 2021). Polygons never go to EE
#      directly — their GeoJSON embedded in every evaluating request is what
#      broke the 10 MB payload limit before this rewrite.
#   3. ABLATION: train an RF per source combo (barenblitt / maus / tang /
#      human = maus+tang / all) + a cosine-similarity baseline (the pond-script
#      method), score every one against the SmallMinesDS 2022 points →
#      outputs/tables/rs05_ablation_smallminesds2022.csv
#   4. Train the final NATIONAL classifier (all sources, incl. the northern
#      Maus/Tang positives + nationally sampled negatives) → annual probability
#      maps 2017–2025 over ALL of Ghana → EE assets (Drive behind a flag)
#
# SW/NATIONAL SPLIT (2026-07-16): the ablation (steps 2-3) stays inside the SW
# Barenblitt hull, where the dense labels and the SmallMinesDS validation set
# live — its numbers remain comparable across runs. The final model (step 4)
# is national: a key motivation for running our own classifier is to test
# whether it picks up NORTHERN mining that existing datasets miss. Northern
# predictions are UNVALIDATED (no reference data up there) — check high-prob
# northern patches against imagery / Africa Mining Watch (d_08) before use.
#
# Run INTERACTIVELY: ee_Authenticate() / ee_Initialize() below block on a
# browser login. Prerequisite: rs07_labels.R has been run (incl. Section 11).
#
# Design notes: code/1_remote_sensing/rs03_embedding_classifier_design.md
# Label design + erosion/vintage rationale: rs07_labels.R header +
# literature/rs/remote_sensing_overview.md §2B.
#
# Post-processing (NOT here — belongs to the panel step rs07_embedding_panel):
# threshold probability maps, then optionally corroborate with annual-MAX NDWI
# (S2 B3/B8, catches ephemeral ponds; unmask(1) under persistent cloud),
# min-patch-size via connectedPixelCount, vectorise with 4-connectivity —
# the working chain from the GEE pond-detection prototype script.

####1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, googledrive, tidyverse, sf, here, janitor, scales, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff,
  here::here
)

UTM30N <- 32630

# Cloud Project for Earth Engine asset operations — the alphanumeric PROJECT
# ID (e.g. "ee-tillmeissner"), NOT the numeric project number (853810444110).
# ROOT CAUSE of the 2026-07-15 asset failures: the earthengine-api client's
# ASSET_NAME_PATTERN regex (_cloud_api_utils.py) only recognises
# "projects/<id>/assets/..." when <id> starts with a lowercase LETTER. A
# numeric project number fails the regex, so every by-ID call (getAsset,
# createAsset, Export$table$toAsset) silently rewrites the path to
# "projects/earthengine-legacy/assets/projects/<number>/assets/..." — the
# doubled-path "does not exist" errors, and the "Cannot create a top level
# assets folder" error. The server accepts both forms; only the client-side
# regex is picky — which is why LISTING assets worked while everything by-ID
# failed. Find the ID: console.cloud.google.com project picker ("Project ID"
# column, next to number 853810444110), or the EE Code Editor Assets tab.
# NB this is the user's one shared EE Cloud Project (~16 unrelated assets:
# Ethiopia/Egypt/Cambodia work, night-lights, ...), not Ghana-specific —
# hence the dedicated ghana_mining subfolder below.
EE_PROJECT <- "rgee-auth-tillam"   # project number: 853810444110
if (!grepl("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", EE_PROJECT))
  stop("EE_PROJECT must be the alphanumeric Cloud project ID ",
       "(starts with a letter, e.g. 'ee-tillmeissner'), not the numeric ",
       "project number — see the comment above this line.")

####2. Authenticate ####
rgee::ee_Authenticate()
rgee::ee_Initialize(drive = TRUE, project = EE_PROJECT)
ee_check()
googledrive::drive_auth()

####3. Load rs07 label artifacts ####

lab_dir <- here("data", "processed", "labels")
stopifnot("rs07_labels.R artifacts not found — run it first" =
            file.exists(file.path(lab_dir, "labels_positives_polygons.rds")))

pos_poly  <- readRDS(file.path(lab_dir, "labels_positives_polygons.rds"))
pos_pts   <- readRDS(file.path(lab_dir, "labels_positives_points.rds")) |>
  st_buffer(15)   # salvage points → ~pixel-sized polygons so paint() rasterises them
exclusion <- readRDS(file.path(lab_dir, "labels_exclusion_mask.rds"))
val_2022  <- readRDS(file.path(lab_dir, "smallminesds_validation_points_2022.rds"))

positives <- bind_rows(pos_poly, pos_pts)   # UTM30N; source / vintage_year / geometry

# Two spatial frames (see the SW/NATIONAL SPLIT note in the header):
#   study_area_utm — convex hull of the Barenblitt-source positives (SW Ghana
#     belt) + buffer: the ABLATION frame (dense labels + SmallMinesDS live here).
#   ghana_utm — national outline: the FINAL-model frame (northern positives
#     retained, negatives sampled nationally) and the Section 9 export region.
STUDY_BUFFER_KM <- 10
study_area_utm <- positives |>
  filter(source == "barenblitt") |>
  st_union() |>
  st_convex_hull() |>
  st_buffer(STUDY_BUFFER_KM * 1000)

ghana_utm <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin",
                          "gha_admin0.shp"), quiet = TRUE) |>
  select(geometry) |>              # drop valid_on/valid_to (NAs crash sf_as_ee)
  st_make_valid() |>
  st_union() |>
  st_transform(st_crs(positives)) |>
  st_simplify(dTolerance = 100)    # keep the inline-FC upload small; only used
                                   # for neg sampling / clipping / export bounds

# Positives outside the SW hull (isolated northern Maus/Tang sites) are no
# longer dropped — they train the final national model (§5), just not the
# ablation.
in_sw <- st_intersects(positives, study_area_utm, sparse = FALSE)[, 1]
message(sprintf("Positives: %d in SW study area, %d outside — kept for the national model (by source: %s)",
                sum(in_sw), sum(!in_sw),
                positives |> st_drop_geometry() |> filter(!in_sw) |>
                  count(source) |> mutate(s = paste0(source, "=", n)) |> pull(s) |>
                  paste(collapse = ", ")))
positives_north <- positives[!in_sw, ]
positives       <- positives[in_sw, ]

# Balanced validation set: both classes downsampled to the minority-class count
# (2022: mining is the MAJORITY — 6,770 vs 4,270 — since K_POS > K_NEG in rs07 §11)
set.seed(42)
n_min <- min(table(val_2022$label))
val_bal <- val_2022 |>
  group_by(label) |>
  slice_sample(n = n_min) |>
  ungroup() |>
  st_as_sf()
message(sprintf("Validation points (balanced): %d mining / %d non-mining",
                sum(val_bal$label == 1), sum(val_bal$label == 0)))

####4. Parameters ####

DRIVE_FOLDER <- "ghana_mining_gee_exports"
EMBED_YEARS  <- 2017:2025  # 2025 layer released 2026-03, confirmed in-catalog for Ghana 2026-07-16
N_POS        <- c(barenblitt = 2000L, maus = 1000L, tang = 1000L)  # positive px per source (SW / ablation)
N_POS_NORTH  <- 500L    # cap on northern positives per source (final national model only;
                        # sample_in() warns + returns fewer if the sites are too small)
NEG_RATIO    <- 3L      # negatives sampled per positive, per vintage
N_TREES      <- 200L
EXPORT_SCALE <- 10L
SEED         <- 42L

# Ablation: which sources supervise the positives (negatives shared, subsampled
# per combo to NEG_RATIO × positives so only the positive supervision varies)
ABLATION <- list(
  barenblitt = "barenblitt",
  maus       = "maus",
  tang       = "tang",
  human      = c("maus", "tang"),
  all        = c("barenblitt", "maus", "tang")
)

out_embed <- here("data", "raw", "embedding")
tab_dir   <- here("outputs", "tables")
dir.create(out_embed, recursive = TRUE, showWarnings = FALSE)
dir.create(tab_dir,   recursive = TRUE, showWarnings = FALSE)

# EE Assets home for this run's uploads — makes train_pts/study_area/val_pts
# browsable + visualisable in the Code Editor (Assets tab), not just inline
# request literals.
# NB: ee$data$getAssetRoots() does NOT return genuine "root" objects for this
# account — it lists arbitrary existing top-level assets in EE_PROJECT
# (confirmed 2026-07-15: 16 unrelated assets from other analyses came back,
# no Folder-typed root among them), so it's useless for discovering a home
# folder. Use a dedicated, deterministic subfolder instead — keeps rs05's
# uploads out of the clutter of everything else already in this project —
# and create it once if it doesn't exist yet.
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
folder_exists <- tryCatch({ ee$data$getAsset(EE_ASSET_HOME); TRUE },
                          error = function(e) FALSE)
if (!folder_exists) {
  message(sprintf("Creating EE asset folder: %s", EE_ASSET_HOME))
  ee$data$createAsset(list(type = "FOLDER"), EE_ASSET_HOME)
}
message(sprintf("EE asset root: %s", EE_ASSET_HOME))

####5. Sample training POINTS locally, upload only points ####
# sf_as_ee embeds geometries as GeoJSON in the EE expression graph, so every
# request that later evaluates it re-sends them — the raw label polygons
# (7,391 barenblitt alone) blow EE's 10 MB request limit ("Request payload size
# exceeds the limit", first triggered when Section 7 forces evaluation).
# Fix: do ALL geometry work locally — sample pixel locations in R (area-weighted
# within the label cores; negatives rejection-sampled outside the exclusion
# mask, enforced exactly with sf) — and send EE only ~16k POINTS. EE's sole job
# is then reading embedding band values at those points (Section 6).

message("=== Step 5: Sampling training points locally ===")
set.seed(SEED)

# Vintage → sources trained on that embedding year (from the rs07 artifact)
vintages <- positives |>
  st_drop_geometry() |>
  distinct(source, vintage_year)
print(vintages)

# snap to the export grid so no two samples share a 10 m pixel (mirrors what
# stratifiedSample's one-point-per-pixel behaviour gave us)
dedupe_px <- function(pts) pts[!duplicated(round(st_coordinates(pts) / EXPORT_SCALE)), ]

sample_in <- function(geom, n, avoid = NULL) {
  out <- st_sfc(crs = st_crs(geom))
  for (i in 1:20) {
    if (length(out) >= n) break
    cand <- st_sample(geom, size = ceiling((n - length(out)) * 1.4), type = "random")
    if (!is.null(avoid)) cand <- cand[!st_intersects(cand, avoid, sparse = FALSE)[, 1]]
    out <- dedupe_px(c(out, cand))
  }
  if (length(out) < n) warning(sprintf("only %d of %d points sampled", length(out), n))
  out[seq_len(min(n, length(out)))]
}

# Positives per source: area-weighted over that source's (eroded) geometries.
# NB ground claimed by several sources is sampled per source (intended: an
# ablation subset must contain everything its sources label).
train_pos_pts <- map(names(N_POS), function(s) {   # NB pos_pts is taken (§3 salvage points)
  d  <- positives |> filter(source == s)
  yr <- unique(d$vintage_year)
  message(sprintf("  positives '%s': %d points from %d features (vintage %d)",
                  s, N_POS[[s]], nrow(d), yr))
  st_sf(cls = 1L, source = s, vintage = yr, region = "sw",
        geometry = sample_in(st_geometry(d), N_POS[[s]]))
}) |> bind_rows()

# SW negatives per vintage: study area OUTSIDE the exclusion mask (ablation pool)
train_neg_pts <- map(unique(vintages$vintage_year), function(yr) {
  n_neg <- NEG_RATIO * sum(N_POS[vintages$source[vintages$vintage_year == yr]])
  message(sprintf("  SW negatives: %d points for vintage %d (outside exclusion mask)",
                  n_neg, yr))
  st_sf(cls = 0L, source = "negative", vintage = yr, region = "sw",
        geometry = sample_in(study_area_utm, n_neg, avoid = exclusion))
}) |> bind_rows()

# --- National additions (final model only; sampled AFTER the SW blocks so the
# --- seeded RNG stream — and hence the SW/ablation points — is bit-identical
# --- to pre-split runs) ------------------------------------------------------

# Northern positives: area-weighted like the SW ones, capped at N_POS_NORTH
train_pos_north_pts <- map(unique(positives_north$source), function(s) {
  d  <- positives_north |> filter(source == s)
  yr <- unique(d$vintage_year)
  message(sprintf("  northern positives '%s': up to %d points from %d features (vintage %d)",
                  s, N_POS_NORTH, nrow(d), yr))
  st_sf(cls = 1L, source = s, vintage = yr, region = "north",
        geometry = sample_in(st_geometry(d), N_POS_NORTH))
}) |> bind_rows()

# National negatives: NEG_RATIO x (SW + northern) positives per vintage, drawn
# across ALL of Ghana outside the (national) exclusion mask — the final model
# must see northern savanna / bare soil / farmland as non-mine, or it will
# misfire on them. The SW pool above stays reserved for the ablation.
train_neg_nat_pts <- map(
  unique(c(vintages$vintage_year, train_pos_north_pts$vintage)),
  function(yr) {
    n_pos_yr <- sum(N_POS[vintages$source[vintages$vintage_year == yr]]) +
      sum(train_pos_north_pts$vintage == yr)
    n_neg <- NEG_RATIO * n_pos_yr
    message(sprintf("  national negatives: %d points for vintage %d (outside exclusion mask)",
                    n_neg, yr))
    st_sf(cls = 0L, source = "negative", vintage = yr, region = "national",
          geometry = sample_in(ghana_utm, n_neg, avoid = exclusion))
  }) |> bind_rows()

train_pts <- bind_rows(train_pos_pts, train_neg_pts,
                       train_pos_north_pts, train_neg_nat_pts)

message("=== Uploading training points, study area, validation points to EE assets ===")
message("  (each upload: build inline FeatureCollection, then Export$table$toAsset — ",
        "visible under code.earthengine.google.com -> Tasks)")

# rgee's sf_as_ee(via = "getInfo_to_asset") goes through an older, manifest-
# based asset-creation path that unconditionally prefixes the legacy
# "projects/earthengine-legacy/assets/" namespace — broken for Cloud-Project
# accounts. Instead: build the FeatureCollection inline as before (via =
# "getInfo", the default — fine at our ~3 MB size, this is what worked before
# any asset was involved), then persist it with EE's own modern export call,
# which resolves Cloud-Project asset paths correctly.
# Re-runs: the local sampling is seeded, so the points are identical every
# run — reuse the existing assets instead of re-uploading (the count check
# below still guards against stale assets). Set REUSE_ASSETS <- FALSE after
# changing N_POS / NEG_RATIO / SEED / the rs07 label artifacts.
REUSE_ASSETS <- TRUE  # 2026-07-16: OFF for the first SW/national-split run —
                       # rs05_train_pts gained northern + national points and a
                       # `region` property. Flip back to TRUE afterwards.

upload_as_asset <- function(sf_obj, name) {
  assetId <- file.path(EE_ASSET_HOME, name)
  exists  <- tryCatch({ ee$data$getAsset(assetId); TRUE }, error = function(e) FALSE)
  if (exists && REUSE_ASSETS) {
    message(sprintf("  reusing existing asset: %s", assetId))
    return(ee$FeatureCollection(assetId))
  }
  if (exists) {
    # Export$table$toAsset has no overwrite flag — delete first so re-running
    # the script doesn't error.
    message(sprintf("  deleting pre-existing asset: %s", assetId))
    ee$data$deleteAsset(assetId)
  }
  fc   <- sf_as_ee(sf_obj)   # via = "getInfo" (default): inline, no asset yet
  task <- ee$batch$Export$table$toAsset(
    collection  = fc,
    description = name,
    assetId     = assetId
  )
  task$start()
  message(sprintf("  submitted: %s -> %s", name, assetId))
  ee_monitoring(task)   # blocks until COMPLETED/FAILED, printing progress
  ee$FeatureCollection(assetId)   # return a handle to the now-persisted asset
}

train_pts_ee <- train_pts |>
  st_transform(4326) |>
  upload_as_asset("rs05_train_pts")

study_area_ee <- study_area_utm |>
  st_sf(geometry = _) |>
  st_transform(4326) |>
  upload_as_asset("rs05_study_area")

ghana_ee <- ghana_utm |>
  st_sf(geometry = _) |>
  st_transform(4326) |>
  upload_as_asset("rs05_ghana")

val_ee <- val_bal |>
  select(label) |>
  st_transform(4326) |>
  upload_as_asset("rs05_val_pts_2022")

# Verify each asset actually holds what we think it does: size()$getInfo()
# forces a real round-trip (would itself throw the old payload error if
# something were still too large) and confirms the feature count made it
# across; first()$getInfo() confirms the schema (properties + geometry).
check_upload <- function(fc, label, n_expected) {
  n_ee <- fc$size()$getInfo()
  status <- if (n_ee == n_expected) "OK" else "MISMATCH"
  message(sprintf("  [%s] %s: EE reports %d features (expected %d)",
                  status, label, n_ee, n_expected))
  print(fc$first()$getInfo()$properties)
  invisible(n_ee == n_expected)
}

message("=== Verifying uploads ===")
ok_train <- check_upload(train_pts_ee, "rs05_train_pts",    nrow(train_pts))
ok_study <- check_upload(study_area_ee, "rs05_study_area",   1L)
ok_ghana <- check_upload(ghana_ee,      "rs05_ghana",        1L)
ok_val   <- check_upload(val_ee,        "rs05_val_pts_2022", nrow(val_bal))
stopifnot("upload verification failed — see MISMATCH above (a stale reused asset? set REUSE_ASSETS <- FALSE and re-run Section 5)" =
            all(ok_train, ok_study, ok_ghana, ok_val))

####6. Extract embeddings at the training points ####
# One sampleRegions per vintage year: reads the 64 embedding bands at that
# vintage's points. Every sample carries: 64 bands + cls + source + vintage +
# region. (Points falling on masked embedding pixels are dropped by
# sampleRegions.)

message("=== Step 6: Sampling embeddings at the training points ===")

embedding_year <- function(yr) {
  ee$ImageCollection("GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL")$
    filterBounds(ghana_ee$geometry())$   # national — training points + Section 9 exports both fit
    filterDate(sprintf("%d-01-01", yr), sprintf("%d-01-01", yr + 1L))$
    mosaic()
}
band_names <- embedding_year(2019L)$bandNames()$getInfo()

vintage_years_all <- unique(train_pts$vintage)
sampled_yr <- map(vintage_years_all, function(yr) {
  embedding_year(yr)$sampleRegions(
    collection = train_pts_ee$filter(ee$Filter$eq("vintage", yr)),
    properties = list("cls", "source", "vintage", "region"),
    scale      = EXPORT_SCALE,
    geometries = TRUE,
    tileScale  = 8L
  )
}) |> set_names(as.character(vintage_years_all))

samples_all <- reduce(sampled_yr, function(a, b) a$merge(b))

# Ablation pools: SW only, so Section 7's numbers stay comparable to pre-split
# runs. The national additions feed only the final model (Section 8).
train_pos <- map(names(N_POS), function(s) {
  samples_all$
    filter(ee$Filter$eq("source", s))$
    filter(ee$Filter$eq("region", "sw"))
}) |> set_names(names(N_POS))

neg_all     <- samples_all$
  filter(ee$Filter$eq("source", "negative"))$
  filter(ee$Filter$eq("region", "sw"))
n_neg_total <- sum(NEG_RATIO * N_POS)

pos_north_all <- samples_all$filter(ee$Filter$eq("region", "north"))
neg_nat_all   <- samples_all$filter(ee$Filter$eq("region", "national"))

####7. Ablation — RF per source combo + similarity baseline, scored on SmallMinesDS 2022 ####

message("=== Step 7: Ablation (scored on held-out SmallMinesDS 2022) ===")

# Validation design matrix: sample the 2022 embedding once at the balanced points
val_fc <- embedding_year(2022L)$sampleRegions(
  collection = val_ee,
  properties = list("label"),
  scale      = EXPORT_SCALE,
  tileScale  = 8L
)

score_on_val <- function(classified, pred_col) {
  cm <- classified$errorMatrix("label", pred_col)
  # EE array shapes differ: producersAccuracy is a COLUMN vector (N x 1,
  # index [[class]][[1]]), consumersAccuracy a ROW vector (1 x N, index
  # [[1]][[class]]) — indexing both the same way is a subscript error.
  tibble(
    oa      = cm$accuracy()$getInfo(),
    kappa   = cm$kappa()$getInfo(),
    mine_pa = cm$producersAccuracy()$getInfo()[[2]][[1]],   # recall, class 1
    mine_ua = cm$consumersAccuracy()$getInfo()[[1]][[2]]    # precision, class 1
  )
}

ablation_results <- imap(ABLATION, function(srcs, combo) {
  message(sprintf("  combo '%s' (%s)", combo, paste(srcs, collapse = "+")))
  pos_fc <- reduce(train_pos[srcs], function(a, b) a$merge(b))
  n_pos  <- sum(N_POS[srcs])
  # fixed negative pool, thinned so every combo trains at 1:NEG_RATIO
  frac    <- min(1, (NEG_RATIO * n_pos) / n_neg_total)
  neg_sub <- neg_all$randomColumn("r", SEED)$filter(ee$Filter$lt("r", frac))
  clf <- ee$Classifier$smileRandomForest(N_TREES)$
    train(features = pos_fc$merge(neg_sub), classProperty = "cls",
          inputProperties = band_names)
  score_on_val(val_fc$classify(clf, "pred"), "pred") |>
    mutate(combo = combo, method = "rf", n_pos_target = n_pos, .before = 1)
}) |> list_rbind()

# --- Similarity baselines (the pond-script methods) — computed LOCALLY --------
# Two one-class baselines mirroring the GEE pond prototype:
#   v2 (sim_mean): cosine similarity to the unit-normalised MEAN positive embedding
#   v3 (sim_max):  MAX over per-prototype similarities (multi-prototype matching;
#                  handles heterogeneous galamsey types — ponds / tailings / spoil)
# Thresholds per baseline = p05/p25/p50 of its similarity at the positive
# training points (the pond script's tuning trick, which pins recall only) —
# precision comes from scoring on independent SmallMinesDS.
#
# WHY LOCAL (2026-07-15): the server-side v3 image (per-pixel max over ~100
# prototype-similarity images) blew EE's ~5-min interactive limit ("Computation
# timed out"). But the baselines only ever need embeddings AT POINTS — pure
# vector arithmetic — so: export the sampled embeddings once via BATCH Drive
# tasks (no timeout), then compute cosines, thresholds, and error matrices in
# R in milliseconds. Numerically identical: embedding pixels are unit-norm, so
# the dot product against unit-normalised references is a true cosine. The
# exported CSVs are kept in data/raw/embedding/ (reused on re-runs; also handy
# later for AUC/PR curves and local spatial CV).

# SW positives only (train_pos is region == "sw"): the baselines are scored on
# the SW SmallMinesDS points, and this keeps the cached
# rs05_pos_embeddings_trainpts.csv from pre-split runs valid.
pos_fc_all <- reduce(train_pos, function(a, b) a$merge(b))

export_embeddings_csv <- function(fc, name) {
  dsn <- file.path(out_embed, paste0(name, ".csv"))
  if (file.exists(dsn)) {
    message(sprintf("  reusing %s (delete the file to force re-export)", basename(dsn)))
    return(read_csv(dsn, show_col_types = FALSE))
  }
  task <- ee$batch$Export$table$toDrive(
    collection  = fc,
    description = name,
    folder      = DRIVE_FOLDER,
    fileFormat  = "CSV"
  )
  task$start()
  message(sprintf("  batch export '%s' submitted (batch = no interactive timeout) — waiting...",
                  name))
  ee_monitoring(task)
  ee_drive_to_local(task = task, dsn = dsn)
  read_csv(dsn, show_col_types = FALSE)
}

message("  exporting sampled embeddings for the local similarity baselines")
pos_emb_df <- export_embeddings_csv(pos_fc_all, "rs05_pos_embeddings_trainpts")
val_emb_df <- export_embeddings_csv(val_fc,     "rs05_val_embeddings_2022")

P         <- as.matrix(pos_emb_df[, band_names])   # positives x 64
V         <- as.matrix(val_emb_df[, band_names])   # validation x 64
val_label <- val_emb_df$label
unit_rows <- function(m) m / sqrt(rowSums(m * m))

score_sim_local <- function(sim_val, sim_calib, tag) {
  thresholds <- round(quantile(sim_calib, c(0.05, 0.25, 0.50)), 3)
  message(sprintf("    '%s' thresholds from positive-point sim quantiles: %s",
                  tag, paste(thresholds, collapse = " / ")))
  map(thresholds, function(thr) {
    pred <- as.integer(sim_val > thr)
    tab  <- table(actual = factor(val_label, levels = 0:1),
                  pred   = factor(pred,      levels = 0:1))
    po   <- sum(diag(tab)) / sum(tab)
    pe   <- sum(rowSums(tab) * colSums(tab)) / sum(tab)^2
    tibble(
      combo        = sprintf("%s_thr%.3f", tag, thr),
      method       = tag,
      n_pos_target = sum(N_POS),
      oa           = po,
      kappa        = (po - pe) / (1 - pe),
      mine_pa      = tab["1", "1"] / sum(tab["1", ]),   # recall, class 1
      mine_ua      = tab["1", "1"] / sum(tab[, "1"])    # precision, class 1
    )
  }) |> list_rbind()
}

# v2: cosine to the unit-normalised mean positive embedding; calibrated on ALL
# positives (matches the pond script's only honest tuning signal)
message("  similarity baseline v2 (cosine to mean positive embedding)")
mean_unit <- colMeans(P)
mean_unit <- mean_unit / sqrt(sum(mean_unit^2))

# v3: max over ~100 random positive prototypes (seeded). Prototypes must not
# calibrate their own threshold — max-similarity at a prototype is ~1.0 by
# construction (it matches itself) — so thresholds come from NON-prototype
# positives only. (The JS pond script can't avoid this: ALL its samples are
# prototypes.)
PROTO_FRAC <- 0.025
set.seed(SEED)
proto_idx  <- sample(nrow(P), size = max(1L, round(PROTO_FRAC * nrow(P))))
proto_unit <- unit_rows(P[proto_idx, , drop = FALSE])
sim_max_of <- function(M) apply(M %*% t(proto_unit), 1, max)
message(sprintf("  similarity baseline v3 (max over %d prototypes)", length(proto_idx)))

ablation_results <- bind_rows(
  ablation_results,
  score_sim_local(as.vector(V %*% mean_unit),
                  as.vector(P %*% mean_unit), "sim_mean"),
  score_sim_local(sim_max_of(V),
                  sim_max_of(P[-proto_idx, , drop = FALSE]), "sim_max")
)
print(ablation_results)
write_csv(ablation_results, file.path(tab_dir, "rs05_ablation_smallminesds2022.csv"))
message(sprintf("Ablation table written: %s",
                file.path(tab_dir, "rs05_ablation_smallminesds2022.csv")))

####8. Final classifier (all sources, NATIONAL) ####

message("=== Step 8: Training final classifiers (all sources, national) ===")

# FINAL MODEL = NATIONAL: all positives (SW + northern Maus/Tang) + the
# nationally sampled negative pool, trained at 1:NEG_RATIO. The SW ablation
# negatives are deliberately EXCLUDED — the national pool already covers the
# SW belt by area weight, and adding them would double-weight the SW and skew
# the class ratio (which shifts the RF probability calibration).
train_all <- reduce(train_pos, function(a, b) a$merge(b))$
  merge(pos_north_all)$
  merge(neg_nat_all)

# Quick random 80/20 in-sample check (spatially optimistic — the honest number
# is the SmallMinesDS row of the ablation table; spatial CV runs in R after
# the Section 9 training-CSV export)
split    <- train_all$randomColumn("rand", SEED)
train_fc <- split$filter(ee$Filter$lt("rand", 0.8))
test_fc  <- split$filter(ee$Filter$gte("rand", 0.8))

classifier_binary <- ee$Classifier$smileRandomForest(N_TREES)$
  train(features = train_fc, classProperty = "cls", inputProperties = band_names)
classifier_prob <- ee$Classifier$smileRandomForest(N_TREES)$
  setOutputMode("PROBABILITY")$
  train(features = train_fc, classProperty = "cls", inputProperties = band_names)

cm <- test_fc$classify(classifier_binary, "pred")$errorMatrix("cls", "pred")
message(sprintf("In-sample 80/20: OA %.3f, kappa %.3f (inflated; see ablation table)",
                cm$accuracy()$getInfo(), cm$kappa()$getInfo()))

####9. Export annual mine-probability maps (2017–2025) + training CSV ####
# Each year's map goes to TWO destinations, each behind a flag:
#   - EE ASSET (ghana_mining/mine_prob_ghana_{yr}): visualisable in the Code
#     Editor, and lets the panel step (rs07_embedding_panel) run its whole
#     threshold/NDWI/min-patch/vectorise chain server-side with no download.
#     NATIONAL since 2026-07-16 (~239k km², ~2.8x the SW hull): ~9 x 1.5-3 GB
#     incl. pyramids — still comfortable against the 250 GB asset quota.
#   - DRIVE GeoTIFF: for the local raster workflow (Sections 10-11).
# Both are batch tasks (async, no timeout) — submit and watch the Tasks tab.

PROB_TO_ASSET <- TRUE
PROB_TO_DRIVE <- FALSE  # 2026-07-15: asset-only for now — flip on when/if the
                        # local raster workflow (Sections 10-11) is needed

message("\n=== Step 9: Submitting export tasks ===")

embed_tasks <- map(EMBED_YEARS, function(yr) {
  # Probability stored as an INTEGER PERCENT (0-100, uint8), not float32:
  # 4x smaller before compression and integers compress far better — Ghana
  # (~239k km2) at 10 m is ~2.4B px/yr, i.e. ~9.6 GB/yr as float vs ~1-2 GB/yr
  # as uint8. Downstream thresholding reads mine_prob >= 50 instead of >= 0.5.
  prob_map <- embedding_year(yr)$classify(classifier_prob)$
    multiply(100)$round()$toUint8()$
    rename("mine_prob")$
    clip(ghana_ee)
  tasks <- list()

  if (PROB_TO_DRIVE) {
    tasks$drive <- ee$batch$Export$image$toDrive(
      image          = prob_map,
      description    = paste0("mine_prob_ghana_", yr, "_drive"),
      folder         = DRIVE_FOLDER,
      fileNamePrefix = paste0("mine_prob_ghana_", yr),
      scale          = EXPORT_SCALE,
      region         = ghana_ee$geometry()$bounds(),
      crs            = "EPSG:4326",
      maxPixels      = 1e13,
      fileFormat     = "GeoTIFF"
    )
    tasks$drive$start()
    message(sprintf("  Submitted to Drive: mine_prob_ghana_%d  (scale = %d m, uint8 percent)",
                    yr, EXPORT_SCALE))
  }

  if (PROB_TO_ASSET) {
    assetId <- file.path(EE_ASSET_HOME, paste0("mine_prob_ghana_", yr))
    if (tryCatch({ ee$data$getAsset(assetId); TRUE }, error = function(e) FALSE)) {
      message(sprintf("  deleting pre-existing asset: %s", assetId))
      ee$data$deleteAsset(assetId)
    }
    tasks$asset <- ee$batch$Export$image$toAsset(
      image            = prob_map,
      description      = paste0("mine_prob_ghana_", yr, "_asset"),
      assetId          = assetId,
      scale            = EXPORT_SCALE,
      region           = ghana_ee$geometry()$bounds(),
      crs              = "EPSG:4326",
      maxPixels        = 1e13,
      pyramidingPolicy = list(".default" = "mean")
    )
    tasks$asset$start()
    message(sprintf("  Submitted to EE asset: %s", assetId))
  }

  tasks
})

# Training samples (with source + vintage + region properties; NATIONAL set
# since 2026-07-16 — incl. northern positives + national negatives) for local
# spatial CV
training_export_task <- ee$batch$Export$table$toDrive(
  collection  = train_all,
  description = "mine_embedding_training_samples",
  folder      = DRIVE_FOLDER,
  fileFormat  = "CSV"
)
training_export_task$start()
message("  Submitted: mine_embedding_training_samples.csv")

message(sprintf(
  "\nSubmitted %d years x {%s} probability-map exports + 1 training CSV.",
  length(embed_tasks),
  paste(c("drive"[PROB_TO_DRIVE], "asset"[PROB_TO_ASSET]), collapse = "+")))
message("Monitor: code.earthengine.google.com → Tasks tab")

####10. Download from Google Drive ####
# Run AFTER all GEE tasks show "COMPLETED".
# NB 2026-07-15: probability maps are ASSET-ONLY for now (PROB_TO_DRIVE =
# FALSE in Section 9) — there are no mine_prob GeoTIFFs on Drive to download,
# so the first line stays commented until that flag is flipped. The training
# CSV still goes to Drive and IS worth downloading (feeds local spatial CV).
# Reuses download_from_drive() from d_01_download_gee.R — source that script
# first if running in a fresh session.

# -- Uncomment once GEE tasks complete ----------------------------------------
# if (PROB_TO_DRIVE) download_from_drive(DRIVE_FOLDER, "mine_prob_ghana_", out_embed)
# download_from_drive(DRIVE_FOLDER, "mine_embedding_training_",  out_embed)

####11. Load probability maps into a raster stack ####
# ONLY APPLIES when PROB_TO_DRIVE = TRUE (local GeoTIFF workflow); with
# asset-only exports the maps live in EE and the panel step reads them there.
# Run AFTER Section 10 has downloaded all files locally.
# Produces mine_prob_stack: one layer per year, named "mine_prob_{year}".
# Thresholding / NDWI pond corroboration / min-patch-size / vectorising belong
# to the panel step (rs07_embedding_panel) — see the header note.

pacman::p_load(terra)

prob_files <- sort(list.files(out_embed,
                               pattern = "^mine_prob_ghana_\\d{4}-.*\\.tif$",
                               full.names = TRUE))
if (length(prob_files) == 0) {
   message("No probability map files found — run Sections 9–10 first.")
 } else {
   mine_prob_stack <- terra::rast(prob_files)
   years_found     <- as.integer(stringr::str_extract(
                        basename(prob_files), "\\d{4}"))
   names(mine_prob_stack) <- paste0("mine_prob_", years_found)
   message(sprintf("Probability stack: %d layers (%d–%d)",
                   terra::nlyr(mine_prob_stack),
                   min(years_found), max(years_found)))
 }

message("\n=== rs05_embedding_classifier.R: done ===")
