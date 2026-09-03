# build_02_embedding_classifier.R
# Mine detection via Google AlphaEarth satellite embeddings (2017–2025)
#
# Renamed from rs05_embedding_classifier.R (2026-08-04) to sort correctly AFTER the
# labels script it depends on (build_01_labels.R) — the old rs07/rs05 numbering ran the
# pipeline's dependency order backwards. NOTE: the actual EE asset names and cached local
# CSV filenames this script reads/writes (rs05_train_pts, rs05_study_area, rs05_ghana,
# rs05_val_pts_2022, rs05_pos_embeddings_trainpts.csv, rs05_val_embeddings_2022.csv,
# rs05_ablation_smallminesds2022.csv) were deliberately left unchanged — renaming them
# would make REUSE_ASSETS / the CSV-cache checks think nothing exists yet and force a
# wasteful re-upload/re-export of assets and CSVs that already exist from prior runs.
#
# REWIRED 2026-07-14 to consume the build_01_labels.R artifacts (multi-source labels)
# and to run a source ablation scored against held-out SmallMinesDS 2022.
#
# Workflow:
#   1. Load harmonised labels from data/processed/labels/ (build_01_labels.R):
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
#      maps 2017–2025 over ALL of Ghana → EE assets (Drive behind a flag).
#      Section 10's export loop skips years whose asset already exists, so
#      re-running after a partial run (e.g. only some years succeeded) just
#      fills the gaps — see FORCE_REEXPORT there. Section 8 does NOT depend on
#      Section 7's ablation output, so if the ablation is broken or you just
#      want the classifier, Sections 1-6 then straight to 8, 10 works fine
#      (Section 9 is an optional threshold-selection check on SmallMinesDS).
#
# SW/NATIONAL SPLIT (2026-07-16): the ablation (steps 2-3) stays inside the SW
# Barenblitt hull, where the dense labels and the SmallMinesDS validation set
# live — its numbers remain comparable across runs. The final model (step 4)
# is national: a key motivation for running our own classifier is to test
# whether it picks up NORTHERN mining that existing datasets miss. Northern
# predictions are UNVALIDATED (no reference data up there) — check high-prob
# northern patches against imagery / Africa Mining Watch (validate_africa_mining_watch.R) before use.
# (An SW-only probability classifier/export was added and then removed again
# 2026-08-04 — same population as the ablation's "all" combo — since the
# national model is the actual deliverable; revisit if a same-frame SW vs.
# national comparison is ever needed.)
#
# Run INTERACTIVELY: ee_Authenticate() / ee_Initialize() below block on a
# browser login. Prerequisite: build_01_labels.R has been run (incl. Section 11).
#
# Design notes: notes/archive/rs03_embedding_classifier_design.md (archived — superseded
# by rs05_approach_explainer.md as the readable summary of this approach).
# Label design + erosion/vintage rationale: build_01_labels.R header +
# literature/rs/remote_sensing_overview.md §2B.
#
# Post-processing (NOT here — belongs to the panel step build_03_embedding_panel):
# threshold probability maps, then optionally corroborate with annual-MAX NDWI
# (S2 B3/B8, catches ephemeral ponds; unmask(1) under persistent cloud),
# min-patch-size via connectedPixelCount, vectorise with 4-connectivity —
# the working chain from the GEE pond-detection prototype script. Cutoff/GHSL-mask/hybrid-rule
# deployment logic ALSO belongs there, not here — this script's job ends at "train, ablate,
# compare, pick and persist the winning classifier."
#
# CONSOLIDATED (2026-08-18): this script now trains and compares THREE class schemes (binary
# mine/other, 3-class +urban, 4-class +urban+water — see CLASS_SCHEMES in Section 4), folding in
# what used to live in two separate TRIAL scripts (notes/archive/trial_multiclass_classifier.R for
# 3-class, trial_4class_classifier.R for 4-class). Section 7's ablation grid runs per scheme (18
# runs). Section 7b/c retrains each scheme's winning combo (no_maus, user's explicit choice) at
# continuous probability and builds a matched-precision comparison table -- confirmed c4 beats both
# 3-class and binary at every tested precision level. Section 8 onward now trains/exports the
# FINAL_SCHEME/FINAL_COMBO winner (c4/no_maus), not the old hardcoded binary/all.
#
# COMPATIBILITY NOTE: Section 9 writes to a NEW filename (c4_national_val_probability_scores_2022.csv),
# not the old rs05_val_probability_scores_2022.csv -- that file (and the old mine_prob_ghana_{yr}
# EE assets) are left untouched/stale, still representing the PREVIOUS binary deployment.
# validate_probability_threshold.R and validate_threshold_comparison.R still point at the old
# binary files and have NOT been updated to read the new c4 ones yet -- follow-up work, not done in
# this pass. Do not archive trial_4class_classifier.R until this script's rewrite is verified to
# reproduce/exceed its results.

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

####3. Load build_01 label artifacts ####

lab_dir <- here("data", "processed", "labels")
stopifnot("build_01_labels.R artifacts not found — run it first" =
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
# (2022: mining is the MAJORITY — 6,770 vs 4,270 — since K_POS > K_NEG in build_01 §11)
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
N_POS        <- c(barenblitt = 2000L, maus = 1000L, tang = 2000L)  # positive px per source (SW / ablation)
                    # tang bumped 1000->2000L 2026-08-11: raw Tang outlines looked visually clean
                    # against Sentinel-2 in the Code Editor ground-truth comparison -- testing
                    # whether tang-only ablation performance improves with more training mass,
                    # now that it's sampled at parity with Barenblitt instead of half its count.
N_POS_NORTH  <- 500L    # cap on northern positives per source (final national model only;
                        # sample_in() warns + returns fewer if the sites are too small)
NEG_RATIO    <- 3L      # negatives sampled per positive, per vintage
N_TREES      <- 100L    # lowered from 200 (2026-08-19) -- validate_ntrees_ablation.R confirmed
                        # 100/150/200 are indistinguishable on c4/no_maus (national final-model
                        # pool) against SmallMinesDS-2022: OA within 0.03pt, mine_pa within 0.2pt,
                        # mine_ua within 0.3pt of each other, all inside normal run-to-run noise;
                        # 25/50 trees measurably underperform. Halves per-pixel RF inference cost
                        # (roughly linear in tree count) for both training and the Section 10
                        # export, on top of the tiled-export fix -- see outputs/tables/
                        # ntrees_ablation_c4_no_maus.csv for the full sweep.
EXPORT_SCALE <- 10L
SEED         <- 42L

# RERUN_MISSING_ONLY (2026-08-31): when a prior full run left only a handful of Section 10
# export tiles unfinished (e.g. c4 2022/t06 cancelled after ~3 days, and every t17 killed with
# "task too old"), flip this to TRUE and source the whole file. It short-circuits the three
# diagnostic blocks that would otherwise re-run for 20-40 min for nothing -- Section 7 (the
# 18-run ablation grid), Section 7b's continuous-probability scoring, Section 7c's matched-
# precision table, and Section 9's SmallMinesDS scoring -- while still building `classifier_prob`
# (Section 8) and reaching Section 10, whose per-tile skip-if-exists then resubmits ONLY the
# absent {year}_{tile} assets. Leave FALSE for a normal / first run. Independent of
# FORCE_REEXPORT (which forces a *full* re-export and is still respected in Section 10).
RERUN_MISSING_ONLY <- TRUE

# Ablation: which sources supervise the positives (negatives shared, subsampled
# per combo to NEG_RATIO × positives so only the positive supervision varies)
ABLATION <- list(
  barenblitt = "barenblitt",
  maus       = "maus",
  tang       = "tang",
  human      = c("maus", "tang"),
  all        = c("barenblitt", "maus", "tang"),
  no_maus    = c("barenblitt", "tang")   # added 2026-08-12: isolates Maus's marginal contribution
                                         # to "all" -- the existing human-vs-all check isolates
                                         # Barenblitt's contribution instead, never Maus's. Compare
                                         # no_maus against all the same way human is compared to
                                         # all: if no_maus >= all on BOTH PA and UA, Maus is doing
                                         # more diluting than helping and could be dropped; if it's
                                         # a mixed result (like human vs all was), keep it in.
)

# CLASS SCHEMES (2026-08-18): the ablation grid above now runs once per scheme, not just for
# binary -- consolidates what used to be three separate scripts (build_02=binary,
# notes/archive/trial_multiclass_classifier.R=3-class, trial_4class_classifier.R=4-class) into one.
# Class VALUES are shared across schemes (mine is always 1) so downstream scoring code that reads
# "class 1 = mine" (score_on_val() below) needs no scheme-specific branching.
CLASS_SCHEMES <- list(
  binary = c(other = 0L, mine = 1L),
  c3     = c(other = 0L, mine = 1L, urban = 2L),
  c4     = c(other = 0L, mine = 1L, urban = 2L, water = 3L)
)
# Priority when assigning a class: mine > water > urban > other (matches
# trial_4class_classifier.R's documented reasoning -- permanent water is a more physically
# unambiguous signal than GHSL built-surface density, so it takes precedence over "urban" if a
# pixel could plausibly qualify for both). Same threshold values/units/sources as the trial
# scripts: GHSL built_surface in m^2 per 10m pixel; JRC GSW occurrence in percent.
URBAN_THRESHOLD <- 20
WATER_THRESHOLD <- 50

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

# Vintage → sources trained on that embedding year (from the build_01 artifact)
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
# changing N_POS / NEG_RATIO / SEED / the build_01 label artifacts.
REUSE_ASSETS <- TRUE  # 2026-08-11: OFF again -- N_POS[["tang"]] changed 1000->2000, so
                        # rs05_train_pts must be resampled/reuploaded to reflect it. Flip back
                        # to TRUE once this run's asset is confirmed correct.

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
  # CHUNKED + PERSISTED upload (2026-08-11 v2 -- v1 chunked-then-merged-then-exported still
  # failed: merging still-inline (un-persisted) FeatureCollections just builds one bigger
  # expression that re-embeds ALL chunks' literal data when the merged result is finally
  # submitted in the one Export$table$toAsset call, hitting the same 10 MB limit again despite
  # each chunk being small on its own). The actual fix: persist EACH CHUNK as its own temp asset
  # first (a real batch export + wait, per chunk) -- once persisted, referencing it via
  # ee$FeatureCollection(tempId) is a lightweight pointer, not embedded data, so merging THOSE
  # stays small regardless of how much data the chunks actually hold. via="drive"/"gcs" are NOT
  # valid sf_as_ee() options in the installed rgee ("Invalid via argument" -- only for the
  # download-direction functions like ee_as_rast()), and via="getInfo_to_asset" is broken for
  # this Cloud-Project account (see note above) -- so this is the reliable path.
  # ee_monitoring() is known-unreliable in this codebase (see the Section 9 NB elsewhere in this
  # file: "seen to return before the task actually reaches COMPLETED") -- confirmed 2026-08-11 to
  # also affect toAsset chunk uploads: chunk 19/20 showed in the Assets tab but wasn't yet
  # queryable via Collection.loadTable when the merge step ran right after. Poll actual asset
  # existence explicitly rather than trusting ee_monitoring()'s return as the readiness signal.
  wait_until_asset_ready <- function(id, max_wait_s = 120) {
    waited <- 0
    repeat {
      ok <- tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)
      if (ok) return(invisible(TRUE))
      if (waited >= max_wait_s) stop("Asset never became queryable within ", max_wait_s, "s: ", id)
      Sys.sleep(3); waited <- waited + 3
    }
  }

  chunk_size <- 2000L
  n_obj      <- nrow(sf_obj)
  chunk_idx  <- split(seq_len(n_obj), ceiling(seq_len(n_obj) / chunk_size))

  if (length(chunk_idx) == 1) {
    fc <- sf_as_ee(sf_obj)
  } else {
    message(sprintf("  building FeatureCollection in %d chunk(s) of <=%d rows, each PERSISTED as its own temp asset first",
                    length(chunk_idx), chunk_size))
    temp_ids <- character(length(chunk_idx))
    for (i in seq_along(chunk_idx)) {
      temp_id <- sprintf("%s_tmpchunk%02d", assetId, i)
      if (tryCatch({ ee$data$getAsset(temp_id); TRUE }, error = function(e) FALSE))
        ee$data$deleteAsset(temp_id)
      chunk_fc   <- sf_as_ee(sf_obj[chunk_idx[[i]], ])
      chunk_task <- ee$batch$Export$table$toAsset(
        collection = chunk_fc, description = sprintf("%s_chunk%02d", name, i), assetId = temp_id
      )
      chunk_task$start()
      message(sprintf("    chunk %d/%d submitted -> %s", i, length(chunk_idx), temp_id))
      ee_monitoring(chunk_task)
      wait_until_asset_ready(temp_id)
      temp_ids[i] <- temp_id
    }
    message("  all chunks persisted -- re-confirming each is queryable before merging (belt and suspenders)")
    invisible(lapply(temp_ids, wait_until_asset_ready))
    fc <- Reduce(function(a, b) a$merge(b), lapply(temp_ids, ee$FeatureCollection))
  }

  task <- ee$batch$Export$table$toAsset(
    collection  = fc,
    description = name,
    assetId     = assetId
  )
  task$start()
  message(sprintf("  submitted: %s -> %s", name, assetId))
  ee_monitoring(task)   # blocks until COMPLETED/FAILED, printing progress
  # BUGFIX (2026-08-18): ee_monitoring() has already been observed elsewhere in this file (see
  # Section 9's NB) returning before a task actually reaches COMPLETED. Each CHUNK sub-upload above
  # already guards against this with wait_until_asset_ready() -- this FINAL merged export was
  # missing the same guard, so check_upload() downstream could hit "Collection asset ... not found"
  # on a task that's still genuinely RUNNING server-side. Same fix, applied here too.
  wait_until_asset_ready(assetId)

  if (length(chunk_idx) > 1) {
    message("  cleaning up temp chunk assets")
    for (tid in temp_ids) tryCatch(ee$data$deleteAsset(tid), error = function(e) NULL)
  }
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

####6b. Persist embedded samples, then tag with GHSL/water confounders ####
# PERSIST FIRST: chaining a second sampleRegions() directly onto the still-lazy `samples_all`
# expression would force EE to re-evaluate the ENTIRE embedding-sampling chain (Section 6, all
# vintage years) as a sub-computation of the confounder-tagging step below. This exact pattern
# timed out once in the 3-class trial (notes/archive/trial_multiclass_classifier.R Section 2b) at
# ~725,791 EECU-seconds ("Computation timed out", 21 min). Persisting `samples_all` as a real asset
# first means confounder tagging reads a cheap materialised table instead of recomputing everything.

persist_as_asset <- function(fc, name, wait_max_s = 2400, reuse = REUSE_ASSETS) {
  asset_id <- file.path(EE_ASSET_HOME, name)
  exists   <- tryCatch({ ee$data$getAsset(asset_id); TRUE }, error = function(e) FALSE)
  if (exists && reuse) {
    message(sprintf("  reusing existing asset: %s", asset_id))
    return(ee$FeatureCollection(asset_id))
  }
  if (exists) {
    message(sprintf("  deleting pre-existing asset: %s", asset_id))
    ee$data$deleteAsset(asset_id)
  }
  task <- ee$batch$Export$table$toAsset(collection = fc, description = name, assetId = asset_id)
  task$start()
  message(sprintf("  submitted: %s -> %s", name, asset_id))
  ee_monitoring(task)
  waited <- 0
  repeat {
    ok <- tryCatch({ ee$data$getAsset(asset_id); TRUE }, error = function(e) FALSE)
    if (ok) break
    if (waited >= wait_max_s) stop("Asset never became queryable within ", wait_max_s, "s: ", asset_id)
    Sys.sleep(10); waited <- waited + 10
  }
  ee$FeatureCollection(asset_id)
}

message("=== Step 6b: Persisting embedded training samples before confounder tagging ===")
samples_all_ee <- persist_as_asset(samples_all, "rs05_samples_all_embedded")
message(sprintf("  persisted: %d features", samples_all_ee$size()$getInfo()))

message("=== Step 6c: Tagging with GHSL built_surface + JRC water occurrence ===")
ghsl_built <- ee$ImageCollection("JRC/GHSL/P2023A/GHS_BUILT_S_10m")$
  filterDate("2018-01-01", "2019-01-01")$first()$select("built_surface")
water_occ  <- ee$Image("JRC/GSW1_4/GlobalSurfaceWater")$select("occurrence")$rename("water_occurrence")$
  unmask(0)   # BUGFIX (from trial_4class_classifier.R, 2026-08-17): occurrence is masked, not 0,
              # over any pixel never observed as water -- sampleRegions() silently DROPS a feature
              # if any requested band is masked at its location, so without this ~93% of training
              # points (anything on ordinary dry land) would be discarded, not merely tagged 0%.
confounders <- ghsl_built$addBands(water_occ)

samples_all_tagged <- confounders$sampleRegions(
  collection = samples_all_ee,
  properties = c(band_names, "cls", "source", "vintage", "region"),
  scale      = EXPORT_SCALE, geometries = TRUE, tileScale = 8L
)

# Priority-cascade class assignment, generalized over CLASS_SCHEMES (Section 4) so binary/3-class/
# 4-class all derive from ONE function instead of three scripts each hand-rolling their own
# ee$Algorithms$If cascade. Branches for classes absent from a given scheme are simply omitted --
# binary gets no urban/water branches at all, c3 gets urban but not water.
assign_class <- function(fc, scheme_name) {
  classes <- CLASS_SCHEMES[[scheme_name]]
  fc$map(function(f) {
    cls   <- ee$Number(f$get("cls"))
    built <- ee$Number(f$get("built_surface"))
    water <- ee$Number(f$get("water_occurrence"))
    out <- ee$Number(classes[["other"]])
    if ("urban" %in% names(classes))
      out <- ee$Algorithms$If(built$gt(URBAN_THRESHOLD), classes[["urban"]], out)
    if ("water" %in% names(classes))
      out <- ee$Algorithms$If(water$gte(WATER_THRESHOLD), classes[["water"]], out)
    out <- ee$Algorithms$If(cls$eq(1), classes[["mine"]], out)   # mine always wins, checked last
    f$set("class_label", out)
  })
}

# Ablation pools: SW only, so Section 7's numbers stay comparable to pre-split
# runs. The national additions feed only the final model (Section 8). Now built
# from samples_all_tagged (carries built_surface/water_occurrence) rather than
# samples_all, so assign_class() has what it needs regardless of scheme.
train_pos <- map(names(N_POS), function(s) {
  samples_all_tagged$
    filter(ee$Filter$eq("source", s))$
    filter(ee$Filter$eq("region", "sw"))
}) |> set_names(names(N_POS))

neg_all     <- samples_all_tagged$
  filter(ee$Filter$eq("source", "negative"))$
  filter(ee$Filter$eq("region", "sw"))
n_neg_total <- sum(NEG_RATIO * N_POS)

pos_north_all <- samples_all_tagged$filter(ee$Filter$eq("region", "north"))
neg_nat_all   <- samples_all_tagged$filter(ee$Filter$eq("region", "national"))

####7. Ablation — RF per (class scheme × source combo), scored on SmallMinesDS 2022 ####
# 18 runs (3 schemes x 6 combos) instead of the original 6 (binary only) -- verifies the "which
# combo wins" question independently for 3-class/4-class rather than assuming it carries over from
# binary (2026-08-18: this is exactly what let no_maus become 4-class's combo, in
# trial_4class_classifier.R, WITHOUT ever being independently tested at 4-class).

message("=== Step 7: Ablation across class schemes x source combos ===")

# Validation design matrix: sample the 2022 embedding once at the balanced points. Stays BINARY
# (label 0/1) regardless of scheme -- SmallMinesDS only ever labels mine-vs-not, so score_on_val()
# always compares "predicted class == 1 (mine)" against "label", whatever else the classifier was
# trained to distinguish.
val_fc <- embedding_year(2022L)$sampleRegions(
  collection = val_ee,
  properties = list("label"),
  scale      = EXPORT_SCALE,
  tileScale  = 8L
)

score_on_val <- function(classified, pred_col, tag = "combo") {
  cm <- classified$errorMatrix("label", pred_col)
  # EE array shapes differ: producersAccuracy is a COLUMN vector (N x 1,
  # index [[class]][[1]]), consumersAccuracy a ROW vector (1 x N, index
  # [[1]][[class]]) — indexing both the same way is a subscript error.
  # Generalizes unchanged across schemes: "mine" is always class value 1, so [[2]][[1]] / [[1]][[2]]
  # always target it regardless of how many other classes exist. producersAccuracy() only looks at
  # the class-1 ROW (of the true labels, which are always binary here) and consumersAccuracy() only
  # looks at the class-1 COLUMN (of predictions) -- predicting urban/water/other are all equally
  # "not mine" for this one-vs-rest scoring, exactly the desired behaviour.
  #
  # BUGFIX (2026-08-18): the original version called $getInfo() FOUR separate times (oa, kappa, pa,
  # ua). Since train()/classify() are lazy, EACH call independently re-triggered the ENTIRE upstream
  # graph -- retraining the RF and reclassifying all ~8,500 validation points from scratch, four
  # times per combo. Hit "User memory limit exceeded" on the largest combo ('all', 5,000 positives).
  # Fix: bundle all four into ONE ee$Dictionary and getInfo() ONCE, so the graph is computed a
  # single time. If even that single evaluation is still too large, fall back to a batch export +
  # local computation (same tryCatch-then-batch pattern used elsewhere in this file, e.g. Section
  # 7b/9), computing the confusion matrix locally from downloaded (label, pred) pairs instead.
  info <- tryCatch({
    ee$Dictionary(list(
      oa = cm$accuracy(), kappa = cm$kappa(),
      pa = cm$producersAccuracy(), ua = cm$consumersAccuracy()
    ))$getInfo()
  }, error = function(e) NULL)

  if (!is.null(info)) {
    return(tibble(
      oa      = info$oa,
      kappa   = info$kappa,
      mine_pa = info$pa[[2]][[1]],
      mine_ua = info$ua[[1]][[2]]
    ))
  }

  message(sprintf("  [%s] single-call scoring failed (likely memory limit) -- falling back to batch export + local confusion matrix", tag))
  tmp  <- tempfile(fileext = ".csv")
  export_name <- paste0("score_on_val_", gsub("[^A-Za-z0-9]", "_", tag), "_",
                        format(Sys.time(), "%Y%m%dT%H%M%OS0"))
  task <- ee$batch$Export$table$toDrive(
    collection  = classified$select(c("label", pred_col)),
    description = export_name, folder = DRIVE_FOLDER, fileFormat = "CSV"
  )
  task$start()
  export_folder <- googledrive::drive_find(pattern = DRIVE_FOLDER, type = "folder", n_max = 1)
  if (nrow(export_folder) == 0)
    stop("Export folder '", DRIVE_FOLDER, "' not found -- check googledrive::drive_user().")
  max_wait_s <- 20 * 60; waited_s <- 0
  repeat {
    contents <- googledrive::drive_ls(export_folder[1, ])
    hit <- contents[grepl(export_name, contents$name, fixed = TRUE), ]
    if (nrow(hit) > 0) { f <- hit[1, ]; break }
    if (waited_s >= max_wait_s) stop("Export not found after ", max_wait_s / 60, " min")
    Sys.sleep(10); waited_s <- waited_s + 10
  }
  googledrive::drive_download(f, path = tmp, overwrite = TRUE)
  scored <- read_csv(tmp, show_col_types = FALSE)
  # local one-vs-rest confusion matrix: "mine" is always class value 1, everything else (0/2/3) is
  # "not mine" -- same semantics as EE's producersAccuracy/consumersAccuracy indexed at class 1.
  pred_mine  <- as.integer(scored[[pred_col]] == 1)
  label_mine <- as.integer(scored$label == 1)
  tp <- sum(pred_mine == 1 & label_mine == 1); fp <- sum(pred_mine == 1 & label_mine == 0)
  fn <- sum(pred_mine == 0 & label_mine == 1); tn <- sum(pred_mine == 0 & label_mine == 0)
  n  <- tp + fp + fn + tn
  po <- (tp + tn) / n
  pe <- ((tp + fp) * (tp + fn) + (fn + tn) * (fp + tn)) / n^2
  tibble(
    oa      = po,
    kappa   = (po - pe) / (1 - pe),
    mine_pa = tp / (tp + fn),
    mine_ua = tp / (tp + fp)
  )
}

ablation_results <- if (RERUN_MISSING_ONLY) {
  message("[RERUN_MISSING_ONLY] skipping Section 7 ablation grid")
  NULL
} else { map(names(CLASS_SCHEMES), function(scheme_name) {
  message(sprintf(" -- class scheme '%s' --", scheme_name))
  train_pos_scheme <- map(names(N_POS), ~ assign_class(train_pos[[.x]], scheme_name)) |>
    set_names(names(N_POS))
  neg_all_scheme <- assign_class(neg_all, scheme_name)

  imap(ABLATION, function(srcs, combo) {
    message(sprintf("  combo '%s' (%s)", combo, paste(srcs, collapse = "+")))
    pos_fc <- reduce(train_pos_scheme[srcs], function(a, b) a$merge(b))
    n_pos  <- sum(N_POS[srcs])
    # fixed negative pool, thinned so every combo trains at 1:NEG_RATIO
    frac    <- min(1, (NEG_RATIO * n_pos) / n_neg_total)
    neg_sub <- neg_all_scheme$randomColumn("r", SEED)$filter(ee$Filter$lt("r", frac))
    clf <- ee$Classifier$smileRandomForest(N_TREES)$
      train(features = pos_fc$merge(neg_sub), classProperty = "class_label",
            inputProperties = band_names)
    scored <- score_on_val(val_fc$classify(clf, "pred"), "pred", tag = paste(scheme_name, combo, sep = "_"))
    scored |>
      mutate(mine_f1 = ifelse(is.na(mine_ua) || (mine_pa + mine_ua) == 0, NA_real_,
                               2 * mine_pa * mine_ua / (mine_pa + mine_ua)),
             class_scheme = scheme_name, combo = combo, method = "rf", n_pos_target = n_pos,
             .before = 1)
  }) |> list_rbind()
}) |> list_rbind() }

# --- Similarity baselines (the pond-script methods) — DISABLED 2026-08-05 ----
# Not needed to compare source combos (Part A above already does that); skipped
# here to avoid the two batch Drive export round-trips (no cached CSVs found in
# data/raw/embedding/). Re-enable by uncommenting if the RF-vs-baseline
# comparison is needed again (e.g. for the approach.md writeup).
#
# pos_fc_all <- reduce(train_pos, function(a, b) a$merge(b))
#
# export_embeddings_csv <- function(fc, name) {
#   dsn <- file.path(out_embed, paste0(name, ".csv"))
#   if (file.exists(dsn)) {
#     message(sprintf("  reusing %s (delete the file to force re-export)", basename(dsn)))
#     return(read_csv(dsn, show_col_types = FALSE))
#   }
#   task <- ee$batch$Export$table$toDrive(
#     collection  = fc,
#     description = name,
#     folder      = DRIVE_FOLDER,
#     fileFormat  = "CSV"
#   )
#   task$start()
#   message(sprintf("  batch export '%s' submitted (batch = no interactive timeout) — waiting...",
#                   name))
#   ee_monitoring(task)
#   ee_drive_to_local(task = task, dsn = dsn)
#   read_csv(dsn, show_col_types = FALSE)
# }
#
# message("  exporting sampled embeddings for the local similarity baselines")
# pos_emb_df <- export_embeddings_csv(pos_fc_all, "rs05_pos_embeddings_trainpts")
# val_emb_df <- export_embeddings_csv(val_fc,     "rs05_val_embeddings_2022")
#
# P         <- as.matrix(pos_emb_df[, band_names])   # positives x 64
# V         <- as.matrix(val_emb_df[, band_names])   # validation x 64
# val_label <- val_emb_df$label
# unit_rows <- function(m) m / sqrt(rowSums(m * m))
#
# score_sim_local <- function(sim_val, sim_calib, tag) {
#   thresholds <- round(quantile(sim_calib, c(0.05, 0.25, 0.50)), 3)
#   message(sprintf("    '%s' thresholds from positive-point sim quantiles: %s",
#                   tag, paste(thresholds, collapse = " / ")))
#   map(thresholds, function(thr) {
#     pred <- as.integer(sim_val > thr)
#     tab  <- table(actual = factor(val_label, levels = 0:1),
#                   pred   = factor(pred,      levels = 0:1))
#     po   <- sum(diag(tab)) / sum(tab)
#     pe   <- sum(rowSums(tab) * colSums(tab)) / sum(tab)^2
#     tibble(
#       combo        = sprintf("%s_thr%.3f", tag, thr),
#       method       = tag,
#       n_pos_target = sum(N_POS),
#       oa           = po,
#       kappa        = (po - pe) / (1 - pe),
#       mine_pa      = tab["1", "1"] / sum(tab["1", ]),   # recall, class 1
#       mine_ua      = tab["1", "1"] / sum(tab[, "1"])    # precision, class 1
#     )
#   }) |> list_rbind()
# }
#
# # v2: cosine to the unit-normalised mean positive embedding; calibrated on ALL
# # positives (matches the pond script's only honest tuning signal)
# message("  similarity baseline v2 (cosine to mean positive embedding)")
# mean_unit <- colMeans(P)
# mean_unit <- mean_unit / sqrt(sum(mean_unit^2))
#
# # v3: max over ~100 random positive prototypes (seeded). Prototypes must not
# # calibrate their own threshold — max-similarity at a prototype is ~1.0 by
# # construction (it matches itself) — so thresholds come from NON-prototype
# # positives only. (The JS pond script can't avoid this: ALL its samples are
# # prototypes.)
# PROTO_FRAC <- 0.025
# set.seed(SEED)
# proto_idx  <- sample(nrow(P), size = max(1L, round(PROTO_FRAC * nrow(P))))
# proto_unit <- unit_rows(P[proto_idx, , drop = FALSE])
# sim_max_of <- function(M) apply(M %*% t(proto_unit), 1, max)
# message(sprintf("  similarity baseline v3 (max over %d prototypes)", length(proto_idx)))
#
# ablation_results <- bind_rows(
#   ablation_results,
#   score_sim_local(as.vector(V %*% mean_unit),
#                   as.vector(P %*% mean_unit), "sim_mean"),
#   score_sim_local(sim_max_of(V),
#                   sim_max_of(P[-proto_idx, , drop = FALSE]), "sim_max")
# )

if (!is.null(ablation_results)) {
  print(ablation_results)
  write_csv(ablation_results, file.path(tab_dir, "rs05_ablation_smallminesds2022.csv"))
  message(sprintf("Ablation table written: %s",
                  file.path(tab_dir, "rs05_ablation_smallminesds2022.csv")))
}

####7b. Each scheme's winning combo (no_maus) at CONTINUOUS probability, for full threshold sweeps ####
# Winning combo: no_maus for ALL THREE schemes (user's explicit call, 2026-08-18) -- Section 7's
# ablation table shows no_maus trades some recall (PA) for meaningfully better precision (UA) in
# every scheme (it does NOT dominate "all" on both metrics simultaneously), and the decision was
# made on the strength of the UA gain, consistent with the precision-favouring preference already
# established for this project (see the no_maus rationale on ABLATION above, decided the same way
# for binary alone on 2026-08-12).
WINNING_COMBO <- c(binary = "no_maus", c3 = "no_maus", c4 = "no_maus")

message("=== Step 7b: each scheme's winning combo at continuous probability ===")

# Image-based mine_prob extraction (NOT FeatureCollection-based) -- deliberately mirrors
# trial_4class_classifier.R's PROVEN mine_prob_of() pattern (classify an IMAGE, arrayGet() the mine
# band) rather than inventing untested FeatureCollection-array-property extraction for
# MULTIPROBABILITY mode. For binary (PROBABILITY mode), classify() already returns a scalar band.
mine_prob_of <- function(img, classifier, scheme_name) {
  classes <- CLASS_SCHEMES[[scheme_name]]
  if (length(classes) == 2) {
    img$classify(classifier, "mine_prob")
  } else {
    img$classify(classifier)$arrayGet(as.integer(classes[["mine"]]))$rename("mine_prob")
  }
}

prob_scores <- if (RERUN_MISSING_ONLY) {
  message("[RERUN_MISSING_ONLY] skipping Section 7b continuous-probability scoring")
  NULL
} else { map(names(CLASS_SCHEMES), function(scheme_name) {
  scheme_scored_path <- file.path(out_embed, sprintf("%s_val_probability_scores_2022.csv", scheme_name))
  if (file.exists(scheme_scored_path)) {
    message(sprintf("  [%s] reusing %s (delete the file to force re-score)",
                    scheme_name, basename(scheme_scored_path)))
    return(read_csv(scheme_scored_path, show_col_types = FALSE))
  }

  combo <- WINNING_COMBO[[scheme_name]]
  message(sprintf("  [%s] training winning combo '%s' at continuous probability", scheme_name, combo))
  classes <- CLASS_SCHEMES[[scheme_name]]
  srcs    <- ABLATION[[combo]]
  train_pos_scheme <- map(srcs, ~ assign_class(train_pos[[.x]], scheme_name)) |> set_names(srcs)
  neg_all_scheme   <- assign_class(neg_all, scheme_name)
  pos_fc  <- reduce(train_pos_scheme, function(a, b) a$merge(b))
  n_pos   <- sum(N_POS[srcs])
  frac    <- min(1, (NEG_RATIO * n_pos) / n_neg_total)
  neg_sub <- neg_all_scheme$randomColumn("r", SEED)$filter(ee$Filter$lt("r", frac))

  clf_prob <- ee$Classifier$smileRandomForest(N_TREES)$
    setOutputMode(if (length(classes) == 2) "PROBABILITY" else "MULTIPROBABILITY")$
    train(features = pos_fc$merge(neg_sub), classProperty = "class_label", inputProperties = band_names)

  sampled <- mine_prob_of(embedding_year(2022L), clf_prob, scheme_name)$multiply(100)$sampleRegions(
    collection = val_ee, properties = list("label"), scale = EXPORT_SCALE, tileScale = 8L
  )

  df <- tryCatch({
    scored_ee <- sampled$getInfo()
    tibble(
      label = map_dbl(scored_ee$features, ~ .x$properties$label),
      prob  = map_dbl(scored_ee$features, ~ .x$properties$mine_prob)
    )
  }, error = function(e) {
    message(sprintf("  [%s] interactive getInfo() failed -- falling back to batch export: %s",
                    scheme_name, conditionMessage(e)))
    tmp <- tempfile(fileext = ".csv")
    export_name <- paste0(scheme_name, "_val_probability_scores_2022_", format(Sys.time(), "%Y%m%dT%H%M%OS0"))
    task <- ee$batch$Export$table$toDrive(
      collection  = sampled$select(c("label", "mine_prob")),
      description = export_name, folder = DRIVE_FOLDER, fileFormat = "CSV"
    )
    task$start()
    export_folder <- googledrive::drive_find(pattern = DRIVE_FOLDER, type = "folder", n_max = 1)
    if (nrow(export_folder) == 0)
      stop("Export folder '", DRIVE_FOLDER, "' not found -- check googledrive::drive_user().")
    max_wait_s <- 20 * 60; waited_s <- 0
    repeat {
      contents <- googledrive::drive_ls(export_folder[1, ])
      hit <- contents[grepl(export_name, contents$name, fixed = TRUE), ]
      if (nrow(hit) > 0) { f <- hit[1, ]; break }
      if (waited_s >= max_wait_s) stop("Export not found after ", max_wait_s / 60, " min")
      message(sprintf("  still waiting (%ds elapsed)...", waited_s))
      Sys.sleep(10); waited_s <- waited_s + 10
    }
    googledrive::drive_download(f, path = tmp, overwrite = TRUE)
    read_csv(tmp, show_col_types = FALSE) |> rename(prob = mine_prob) |> select(label, prob)
  })

  write_csv(df, scheme_scored_path)
  message(sprintf("  [%s] wrote %d scored validation points to: %s", scheme_name, nrow(df), scheme_scored_path))
  df
}) |> set_names(names(CLASS_SCHEMES)) }

####7c. Matched-precision comparison table across schemes ####
# Comparing at a SHARED raw cutoff, or at each scheme's own F1-optimum, is misleading -- multi-
# class probability dilution shifts the cutoff scale (a 4-class model's mine_prob competes against
# 3 other classes, so its values run systematically lower than binary's for the same underlying
# confidence, discovered earlier this session). Matched precision (same UA, compare PA) is the fair
# comparison -- this is the permanent, rerunnable version of the table built by hand in conversation.

message("=== Step 7c: matched-precision comparison across schemes ===")

sweep_threshold <- function(df, thr) {
  pred <- as.integer(df$prob >= thr)
  tp <- sum(pred == 1 & df$label == 1); fp <- sum(pred == 1 & df$label == 0)
  fn <- sum(pred == 0 & df$label == 1)
  pa <- tp / (tp + fn)
  ua <- if (tp + fp == 0) NA_real_ else tp / (tp + fp)
  tibble(threshold = thr, pa = pa, ua = ua,
         f1 = ifelse(is.na(ua) || (pa + ua) == 0, NA_real_, 2 * pa * ua / (pa + ua)))
}

TARGET_UA_LEVELS <- c(0.90, 0.92, 0.93, 0.94)   # matches the ad hoc analysis already done in conversation

matched_precision <- if (RERUN_MISSING_ONLY) {
  message("[RERUN_MISSING_ONLY] skipping Section 7c matched-precision comparison")
  NULL
} else { map(names(CLASS_SCHEMES), function(scheme_name) {
  sweep <- map_dfr(0:100, ~ sweep_threshold(prob_scores[[scheme_name]], .x))
  valid <- sweep |> filter(!is.na(ua))
  map_dfr(TARGET_UA_LEVELS, function(target) {
    valid |>
      slice_min(abs(ua - target), n = 1, with_ties = FALSE) |>
      mutate(target_ua = target, class_scheme = scheme_name,
             combo = WINNING_COMBO[[scheme_name]], .before = 1)
  })
}) |> list_rbind() }

if (!is.null(matched_precision)) {
  print(matched_precision)
  write_csv(matched_precision, file.path(tab_dir, "class_scheme_matched_precision_comparison.csv"))
  message(sprintf("Matched-precision comparison written: %s",
                  file.path(tab_dir, "class_scheme_matched_precision_comparison.csv")))
}

####8. Final classifier (winning scheme x combo, NATIONAL) ####
# FINAL_SCHEME/FINAL_COMBO (2026-08-18): parametrized on the winner confirmed via Section 7c's
# matched-precision comparison -- c4 (4-class) beat both 3-class and binary at every tested
# precision level, with no_maus as the combo (user's explicit choice, precision-favouring). This
# REPLACES the old hardcoded binary/all final model. If re-run with a different scheme ever wins,
# just change these two lines -- everything below derives from them.
FINAL_SCHEME <- "c4"
FINAL_COMBO  <- WINNING_COMBO[[FINAL_SCHEME]]

message(sprintf("=== Step 8: Training final classifier (scheme '%s', combo '%s', national) ===",
                FINAL_SCHEME, FINAL_COMBO))

# NOTE: this section does not depend on Section 7's ablation_results — only on
# train_pos / pos_north_all / neg_nat_all / band_names (all built in Sections
# 5-6). If Section 7 is broken or you just want to skip it, you can run
# Sections 1-6 then jump straight here.

final_classes <- CLASS_SCHEMES[[FINAL_SCHEME]]
final_srcs    <- ABLATION[[FINAL_COMBO]]

# Tag with the winning scheme's class_label. National additions (northern positives + national
# negatives) need it too, not just the SW ablation pools -- the final model trains on all of them.
train_pos_final     <- map(final_srcs, ~ assign_class(train_pos[[.x]], FINAL_SCHEME)) |> set_names(final_srcs)
pos_north_all_final <- assign_class(pos_north_all$filter(ee$Filter$inList("source", final_srcs)), FINAL_SCHEME)
neg_nat_all_final   <- assign_class(neg_nat_all, FINAL_SCHEME)

# FINAL MODEL = NATIONAL: winning-combo positives (SW + northern) + the
# nationally sampled negative pool, trained at 1:NEG_RATIO. The SW ablation
# negatives are deliberately EXCLUDED — the national pool already covers the
# SW belt by area weight, and adding them would double-weight the SW and skew
# the class ratio (which shifts the RF probability calibration).
train_all <- reduce(train_pos_final, function(a, b) a$merge(b))$
  merge(pos_north_all_final)$
  merge(neg_nat_all_final)

# Quick random 80/20 in-sample check (spatially optimistic — the honest number
# is the SmallMinesDS row of the ablation table; spatial CV runs in R after
# the Section 9 training-CSV export)
split    <- train_all$randomColumn("rand", SEED)
train_fc <- split$filter(ee$Filter$lt("rand", 0.8))
test_fc  <- split$filter(ee$Filter$gte("rand", 0.8))

classifier_hard <- ee$Classifier$smileRandomForest(N_TREES)$
  train(features = train_fc, classProperty = "class_label", inputProperties = band_names)
classifier_prob <- ee$Classifier$smileRandomForest(N_TREES)$
  setOutputMode(if (length(final_classes) == 2) "PROBABILITY" else "MULTIPROBABILITY")$
  train(features = train_fc, classProperty = "class_label", inputProperties = band_names)

# This is a synchronous/interactive .getInfo() call, unlike the batch Export$... tasks
# used elsewhere in this script (no timeout there) -- the national test_fc can be large
# enough (all of Ghana's negatives) to exceed EE's ~5 min interactive compute budget, the
# same class of timeout the Section 7 similarity baselines hit and were moved to batch
# CSV export + local computation for. This check is diagnostic-only (the honest number is
# the SmallMinesDS ablation row) and classifier_prob above does NOT depend on it, so on a
# timeout we just skip it rather than block Section 10.
tryCatch({
  cm <- test_fc$classify(classifier_hard, "pred")$errorMatrix("class_label", "pred")
  message(sprintf("In-sample 80/20: OA %.3f, kappa %.3f (inflated; see ablation table)",
                  cm$accuracy()$getInfo(), cm$kappa()$getInfo()))
}, error = function(e) {
  message("In-sample 80/20 check timed out/failed (diagnostic only, skipping): ", conditionMessage(e))
})

####9. Score the final classifier on SmallMinesDS-2022 — threshold-selection support ####
# classifier_prob (above, the model that actually produced the exported probability maps) has
# never been validated directly -- Section 7's ablation table scores a DIFFERENT model (trained
# on SW-only positives/negatives, hard-classified via EE's default majority vote, not continuous
# probability), and Section 7b/c's matched-precision table scores yet another (SW-only, ablation-
# scope). This section scores the actual NATIONAL deployed model (SW + northern positives, national
# negatives) against the same held-out SmallMinesDS-2022 points at CONTINUOUS probability.
#
# FILENAME (2026-08-18): deliberately NOT "rs05_val_probability_scores_2022.csv" anymore -- that
# name is still read by validate_probability_threshold.R and validate_threshold_comparison.R,
# which both expect it to mean "the deployed BINARY national model". Silently repointing it at c4
# would leave those scripts running without error but producing quietly wrong output. Using a new
# name instead; validate_probability_threshold.R/validate_threshold_comparison.R still point at the
# OLD binary file (now stale, not regenerated by this run) until they're updated separately to read
# this one.

message(sprintf("=== Step 9: Scoring the final classifier (%s/%s, national) on SmallMinesDS-2022 ===",
                FINAL_SCHEME, FINAL_COMBO))

val_scored_path <- file.path(out_embed, sprintf("%s_national_val_probability_scores_2022.csv", FINAL_SCHEME))

if (RERUN_MISSING_ONLY) {
  message("[RERUN_MISSING_ONLY] skipping Section 9 (SmallMinesDS-2022 scoring of the final model)")
} else if (file.exists(val_scored_path)) {
  message(sprintf("  reusing %s (delete the file to force re-score)", basename(val_scored_path)))
} else {
  sampled_final <- mine_prob_of(embedding_year(2022L), classifier_prob, FINAL_SCHEME)$multiply(100)$sampleRegions(
    collection = val_ee, properties = list("label"), scale = EXPORT_SCALE, tileScale = 8L
  )
  val_df <- tryCatch({
    # interactive first -- ~8.5k balanced points, small enough to usually clear EE's ~5 min
    # interactive compute budget (same class of call as the diagnostic check above)
    scored <- sampled_final$getInfo()
    tibble(
      label = map_dbl(scored$features, ~ .x$properties$label),
      prob  = map_dbl(scored$features, ~ .x$properties$mine_prob)
    )
  }, error = function(e) {
    message("  interactive getInfo() timed out/failed -- falling back to batch export: ",
            conditionMessage(e))
    tmp  <- tempfile(fileext = ".csv")
    export_name <- paste0(FINAL_SCHEME, "_national_val_probability_scores_2022_",
                          format(Sys.time(), "%Y%m%dT%H%M%OS0"))
    task <- ee$batch$Export$table$toDrive(
      collection  = sampled_final$select(c("label", "mine_prob")),
      description = export_name,
      folder      = DRIVE_FOLDER,
      fileFormat  = "CSV"
    )
    task$start()
    message("  batch export submitted (batch = no interactive timeout) — waiting...")
    export_folder <- googledrive::drive_find(pattern = DRIVE_FOLDER, type = "folder", n_max = 1)
    if (nrow(export_folder) == 0)
      stop("Export folder '", DRIVE_FOLDER, "' not found -- check googledrive::drive_user().")
    max_wait_s <- 20 * 60; waited_s <- 0
    repeat {
      contents <- googledrive::drive_ls(export_folder[1, ])
      hit <- contents[grepl(export_name, contents$name, fixed = TRUE), ]
      if (nrow(hit) > 0) { f <- hit[1, ]; break }
      if (waited_s >= max_wait_s) stop("Export not found after ", max_wait_s / 60, " min")
      message(sprintf("  still waiting (%ds elapsed)...", waited_s))
      Sys.sleep(10); waited_s <- waited_s + 10
    }
    googledrive::drive_download(f, path = tmp, overwrite = TRUE)
    read_csv(tmp, show_col_types = FALSE) |> rename(prob = mine_prob) |> select(label, prob)
  })

  write_csv(val_df, val_scored_path)
  message(sprintf("  Wrote %d scored validation points to: %s", nrow(val_df), val_scored_path))
}

####10. Export annual mine-probability maps (national, 2017–2025) + training CSV ####
# TILED (2026-08-19): previously one Export.image.toAsset task per YEAR, covering all of Ghana in
# a single call. c4's MULTIPROBABILITY output mode (mine_prob_of() classify()+arrayGet()s an
# array-typed band -- see Section 7b) is far more expensive per pixel than the old binary model's
# scalar classify(), and array-typed computation doesn't parallelize across EE's worker pool as
# cleanly at national extent/10m scale as scalar classify() did: the 2017 export alone ran 12h,
# retried once (Attempt #2), burned ~325k EECU-seconds, and was cancelled without finishing.
# Splitting each year's export into smaller regional tiles -- one task per (year, tile) instead of
# one per year -- lets more of the country classify concurrently and keeps a single stuck/retried
# task from blocking an entire year's map. This does NOT reduce total EECU-seconds (the per-pixel
# cost is unchanged) -- only wall-clock time and the blast radius of any one task's failure. A
# tree-count reduction (see validate_ntrees_ablation.R) DOES cut EECU-seconds and stacks with this.
#
# Each (year, tile) goes to TWO destinations, each behind a flag:
#   - EE ASSET (ghana_mining/mine_prob_ghana_c4_{yr}_{tile}): visualisable in the
#     Code Editor. The panel step (build_03_embedding_panel) will need to mosaic each year's
#     tiles (ee$ImageCollection of that year's assets -> $mosaic()) before running its
#     threshold/NDWI/min-patch/vectorise chain -- not yet written, note for that script.
#   - DRIVE GeoTIFF: for the local raster workflow (Sections 11-12).
# Both are batch tasks (async, no timeout) — submit and watch the Tasks tab.
#
# SKIP-IF-EXISTS (added when re-running to fill in specific missing years,
# e.g. the national asset collection was missing 2018/2024/2025): each
# tile/year combo checks its asset first and only submits if absent, so
# re-running this section after a partial run just fills the gaps instead of
# re-deleting + re-submitting tiles that already succeeded (wastes quota/time
# for no reason). Set FORCE_REEXPORT <- TRUE to force a full re-run (e.g.
# after changing the classifier).

PROB_TO_ASSET  <- TRUE
PROB_TO_DRIVE  <- FALSE  # 2026-07-15: asset-only for now — flip on when/if the
                         # local raster workflow (Sections 11-12) is needed
FORCE_REEXPORT <- FALSE

# Oversized-tile split (2026-08-31): a few (year, tile) cells are too heavy to export as one
# 150 km task -- c4 2022/t06 ran ~3 days and was cancelled. Those go out as an N x N sub-grid of
# smaller tasks (asset suffix _t06s01, _t06s02, ...) instead, and are DROPPED from the main
# tile_year_combos loop below. Section 10b then mosaics the finished sub-tiles back into the
# single mine_prob_ghana_c4_<yr>_t06 asset build_03_embedding_panel expects. Add rows to
# SPLIT_COMBOS (yr, tile_i) if other cells turn out just as heavy.
#   2026-09-01: 2022/t06 finished + recombined (mine_prob_ghana_c4_2022_t06 present, 99.99% covered)
#   and its sub-tiles were cleaned up, so it's DROPPED from SPLIT_COMBOS -- the main loop now skips
#   it as already-existing. 2023/t06 was the one tile that never completed as a single task, so it
#   takes the split slot. Leave 2022/t06 out: re-adding it would re-submit 9 sub-tiles for an asset
#   that's already whole.
SPLIT_COMBOS  <- tibble::tibble(yr = 2023L, tile_i = 6L)
SPLIT_SUBGRID <- 3L   # 3 x 3 = 9 sub-tasks per split cell (bump to 4 if a sub-tile still drags)

TILE_KM        <- 150   # edge length of each export tile, in km. Smaller -> more tiles -> more
                         # concurrent tasks but more per-task overhead and a longer Tasks-tab list;
                         # larger -> fewer, bigger tiles, closer to the old single-task-per-year
                         # behaviour this is meant to move away from. Retune and re-run Section 10a
                         # to see the resulting tile count before submitting.

message("\n=== Step 10: Submitting export tasks ===")

####10a. Build the export tile grid (square tiles over Ghana, in UTM meters) ####
# Square (not the hexagons used for Part 2's analysis grids -- see CLAUDE.md) because a plain
# bounding box is what Export.image's `region` argument wants; empty tiles (grid cells that don't
# touch Ghana at all, inevitable from squaring off an irregular coastline/border) are dropped.
tile_grid_utm <- st_make_grid(ghana_utm, cellsize = TILE_KM * 1000, square = TRUE)
tile_keep     <- lengths(st_intersects(tile_grid_utm, ghana_utm)) > 0
tiles_utm     <- tile_grid_utm[tile_keep]
message(sprintf("  export grid: %d km tiles, %d intersect Ghana (%d empty dropped)",
                TILE_KM, length(tiles_utm), sum(!tile_keep)))

# Tile bounds sent to EE as an inline Rectangle (four numbers) -- no upload/asset needed, unlike
# the polygon labels earlier in this script which had to avoid embedding GeoJSON in requests.
tile_rects <- imap(tiles_utm, function(g, i) {
  bb <- as.numeric(st_bbox(st_transform(st_sfc(g, crs = st_crs(ghana_utm)), 4326)))
  list(id   = sprintf("t%02d", i),
       rect = ee$Geometry$Rectangle(bb, proj = "EPSG:4326", geodesic = FALSE))
})

# Probability stored as an INTEGER PERCENT (0-100, uint8), not float32: 4x
# smaller before compression and integers compress far better. Downstream
# thresholding reads mine_prob >= 50 instead of >= 0.5.
# scheme_name added (2026-08-18): classifier is now MULTIPROBABILITY-mode for c4 (an array-typed
# band), not a plain scalar -- mine_prob_of() (Section 7b) handles extracting the right band for
# either case, replacing the old direct classify()$multiply(100) call which only worked for a
# scalar (binary/PROBABILITY-mode) classifier.
export_prob_tile <- function(yr, tile, classifier, scheme_name, ghana_geom_ee, prefix) {
  asset_name <- sprintf("%s%d_%s", prefix, yr, tile$id)
  assetId    <- file.path(EE_ASSET_HOME, asset_name)
  exists     <- tryCatch({ ee$data$getAsset(assetId); TRUE }, error = function(e) FALSE)

  if (PROB_TO_ASSET && exists && !FORCE_REEXPORT) {
    message(sprintf("  [skip] %s already exists (FORCE_REEXPORT <- TRUE to overwrite)", assetId))
    return(invisible(NULL))
  }

  # clip to the actual country boundary intersected with this tile, not just the tile's bounding
  # box, so border tiles don't export predictions bleeding into neighbouring countries.
  region_ee <- ghana_geom_ee$intersection(tile$rect, 1)
  prob_map  <- mine_prob_of(embedding_year(yr), classifier, scheme_name)$
    multiply(100)$round()$toUint8()$
    clip(region_ee)
  tasks <- list()

  if (PROB_TO_DRIVE) {
    tasks$drive <- ee$batch$Export$image$toDrive(
      image          = prob_map,
      description    = paste0(asset_name, "_drive"),
      folder         = DRIVE_FOLDER,
      fileNamePrefix = asset_name,
      scale          = EXPORT_SCALE,
      region         = tile$rect,
      crs            = "EPSG:4326",
      maxPixels      = 1e13,
      fileFormat     = "GeoTIFF"
    )
    tasks$drive$start()
    message(sprintf("  Submitted to Drive: %s  (scale = %d m, uint8 percent)",
                    asset_name, EXPORT_SCALE))
  }

  if (PROB_TO_ASSET) {
    if (exists) {   # only reached when FORCE_REEXPORT is TRUE
      message(sprintf("  deleting pre-existing asset: %s", assetId))
      ee$data$deleteAsset(assetId)
    }
    tasks$asset <- ee$batch$Export$image$toAsset(
      image            = prob_map,
      description      = paste0(asset_name, "_asset"),
      assetId          = assetId,
      scale            = EXPORT_SCALE,
      region           = tile$rect,
      crs              = "EPSG:4326",
      maxPixels        = 1e13,
      pyramidingPolicy = list(".default" = "mean")
    )
    tasks$asset$start()
    message(sprintf("  Submitted to EE asset: %s", assetId))
  }

  tasks
}

# DISTINCT asset prefix (2026-08-18): "mine_prob_ghana_{yr}" already exists as the OLD binary
# model's export -- exporting c4's maps under the same name would silently overwrite it. New
# prefix keeps both available side by side until the old one is confirmed no longer needed.
tile_year_combos <- expand.grid(yr = EMBED_YEARS, tile_i = seq_along(tile_rects), KEEP.OUT.ATTRS = FALSE)
# Oversized cells are handled by the sub-grid block below, not the whole-tile loop.
tile_year_combos <- dplyr::anti_join(tile_year_combos, SPLIT_COMBOS, by = c("yr", "tile_i"))
if (nrow(SPLIT_COMBOS) > 0)
  message(sprintf("  %d (year,tile) cell(s) routed to the sub-grid split: %s",
                  nrow(SPLIT_COMBOS),
                  paste(sprintf("%d/t%02d", SPLIT_COMBOS$yr, SPLIT_COMBOS$tile_i), collapse = ", ")))
national_tasks <- map2(tile_year_combos$yr, tile_year_combos$tile_i, function(yr, tile_i) {
  export_prob_tile(yr, tile_rects[[tile_i]], classifier = classifier_prob, scheme_name = FINAL_SCHEME,
                    ghana_geom_ee = ghana_ee$geometry(), prefix = sprintf("mine_prob_ghana_%s_", FINAL_SCHEME))
})

####10-split. Oversized (year, tile) cells -> N x N sub-grid of smaller export tasks ####
# Same probability image and asset namespace as export_prob_tile() above -- only the region is one
# sub-cell of the parent tile. Per-sub-cell skip-if-exists, same as the main loop. Run Section 10b
# (below, in a LATER session once these COMPLETE) to stitch them back into the parent-tile asset.
split_subtile_tasks <- purrr::pmap(SPLIT_COMBOS, function(yr, tile_i) {
  parent   <- st_sfc(tiles_utm[[tile_i]], crs = st_crs(ghana_utm))   # [[ ]] drops the CRS; restore it
  sub_grid <- st_make_grid(parent, n = c(SPLIT_SUBGRID, SPLIT_SUBGRID), square = TRUE)
  sub_grid <- sub_grid[lengths(st_intersects(sub_grid, ghana_utm)) > 0]
  message(sprintf("  %d/t%02d -> %d sub-tiles intersecting Ghana", yr, tile_i, length(sub_grid)))
  imap(sub_grid, function(g, j) {
    bb   <- as.numeric(st_bbox(st_transform(st_sfc(g, crs = st_crs(ghana_utm)), 4326)))
    rect <- ee$Geometry$Rectangle(bb, proj = "EPSG:4326", geodesic = FALSE)
    asset_name <- sprintf("mine_prob_ghana_%s_%d_t%02ds%02d", FINAL_SCHEME, yr, tile_i, j)
    assetId    <- file.path(EE_ASSET_HOME, asset_name)
    exists     <- tryCatch({ ee$data$getAsset(assetId); TRUE }, error = function(e) FALSE)
    if (exists && !FORCE_REEXPORT) {
      message(sprintf("    [skip] %s already exists", assetId)); return(invisible(NULL))
    }
    if (exists) ee$data$deleteAsset(assetId)
    region_ee <- ghana_ee$geometry()$intersection(rect, 1)
    prob_map  <- mine_prob_of(embedding_year(yr), classifier_prob, FINAL_SCHEME)$
      multiply(100)$round()$toUint8()$clip(region_ee)
    task <- ee$batch$Export$image$toAsset(
      image = prob_map, description = paste0(asset_name, "_asset"), assetId = assetId,
      scale = EXPORT_SCALE, region = rect, crs = "EPSG:4326",
      maxPixels = 1e13, pyramidingPolicy = list(".default" = "mean"))
    task$start(); message(sprintf("    Submitted: %s", assetId)); task
  })
})

# Training samples (with source + vintage + region properties; NATIONAL set
# since 2026-07-16 — incl. northern positives + national negatives) for local
# spatial CV
if (RERUN_MISSING_ONLY) {
  message("[RERUN_MISSING_ONLY] skipping the training-CSV re-export (unchanged since the full run)")
} else {
  training_export_task <- ee$batch$Export$table$toDrive(
    collection  = train_all,
    description = "mine_embedding_training_samples",
    folder      = DRIVE_FOLDER,
    fileFormat  = "CSV"
  )
  training_export_task$start()
  message("  Submitted: mine_embedding_training_samples.csv")
}

n_nat_submitted <- sum(!map_lgl(national_tasks, is.null))
message(sprintf(
  "\nSubmitted %d/%d national probability-map tile exports (%d years x %d tiles, to %s) + 1 training CSV.",
  n_nat_submitted, nrow(tile_year_combos), length(EMBED_YEARS), length(tile_rects),
  paste(c("drive"[PROB_TO_DRIVE], "asset"[PROB_TO_ASSET]), collapse = "+")))
message("(tiles not submitted already had an asset — see the [skip] messages above; ",
        "set FORCE_REEXPORT <- TRUE to overwrite them)")
message("Monitor: code.earthengine.google.com → Tasks tab")

####10b. Stitch finished sub-tiles back into the parent-tile asset (RUN LATER) ####
# Run this ONLY after every _t<NN>s<MM> sub-tile from the split block above shows COMPLETED in the
# Tasks tab. It mosaics them into mine_prob_ghana_<scheme>_<yr>_t<NN> so build_03_embedding_panel
# finds a normal parent tile (its year_mosaic() only looks for t01..t17, not sub-tiles).
recombine_split_tiles <- function() {
  purrr::pmap(SPLIT_COMBOS, function(yr, tile_i) {
    parent_name <- sprintf("mine_prob_ghana_%s_%d_t%02d", FINAL_SCHEME, yr, tile_i)
    parent_id   <- file.path(EE_ASSET_HOME, parent_name)
    exists      <- tryCatch({ ee$data$getAsset(parent_id); TRUE }, error = function(e) FALSE)
    if (exists && !FORCE_REEXPORT) {
      message(sprintf("  [skip] %s already exists", parent_id)); return(invisible(NULL))
    }
    sub_ids <- file.path(EE_ASSET_HOME,
                         sprintf("mine_prob_ghana_%s_%d_t%02ds%02d", FINAL_SCHEME, yr, tile_i,
                                 seq_len(SPLIT_SUBGRID^2)))
    sub_ids <- keep(sub_ids, ~ tryCatch({ ee$data$getAsset(.x); TRUE }, error = function(e) FALSE))
    if (length(sub_ids) == 0) stop("no sub-tiles found for ", parent_name, " -- have they completed?")
    message(sprintf("  %s <- mosaic of %d sub-tiles", parent_name, length(sub_ids)))
    if (exists) ee$data$deleteAsset(parent_id)
    merged <- ee$ImageCollection(as.list(sub_ids))$mosaic()$toUint8()
    task <- ee$batch$Export$image$toAsset(
      image = merged, description = paste0(parent_name, "_asset"), assetId = parent_id,
      scale = EXPORT_SCALE, region = tile_rects[[tile_i]]$rect, crs = "EPSG:4326",
      maxPixels = 1e13, pyramidingPolicy = list(".default" = "mean"))
    task$start(); message(sprintf("  Submitted: %s", parent_id)); task
  })
}
#recombine_split_tiles()   # <- uncomment + run once the sub-tiles above show COMPLETED

####11. Download from Google Drive ####
# Run AFTER all GEE tasks show "COMPLETED".
# NB 2026-07-15: probability maps are ASSET-ONLY for now (PROB_TO_DRIVE =
# FALSE in Section 10) — there are no mine_prob GeoTIFFs on Drive to download,
# so the first line stays commented until that flag is flipped. The training
# CSV still goes to Drive and IS worth downloading (feeds local spatial CV).
# Reuses download_from_drive() from d_01_download_gee.R — source that script
# first if running in a fresh session.

# -- Uncomment once GEE tasks complete ----------------------------------------
# if (PROB_TO_DRIVE) download_from_drive(DRIVE_FOLDER, "mine_prob_ghana_", out_embed)
# download_from_drive(DRIVE_FOLDER, "mine_embedding_training_",  out_embed)

####12. Load probability maps into a raster stack ####
# ONLY APPLIES when PROB_TO_DRIVE = TRUE (local GeoTIFF workflow); with
# asset-only exports the maps live in EE and the panel step reads them there.
# Run AFTER Section 11 has downloaded all files locally.
# Produces mine_prob_stack: one layer per year, named "mine_prob_{year}".
# Thresholding / NDWI pond corroboration / min-patch-size / vectorising belong
# to the panel step (build_03_embedding_panel) — see the header note.

# pacman::p_load(terra)
#
# prob_files <- sort(list.files(out_embed,
#                                pattern = "^mine_prob_ghana_\\d{4}-.*\\.tif$",
#                                full.names = TRUE))
# if (length(prob_files) == 0) {
#    message("No probability map files found — run Sections 10–11 first.")
#  } else {
#    mine_prob_stack <- terra::rast(prob_files)
#    years_found     <- as.integer(stringr::str_extract(
#                         basename(prob_files), "\\d{4}"))
#    names(mine_prob_stack) <- paste0("mine_prob_", years_found)
#    message(sprintf("Probability stack: %d layers (%d–%d)",
#                    terra::nlyr(mine_prob_stack),
#                    min(years_found), max(years_found)))
#  }
#
# message("\n=== build_02_embedding_classifier.R: done ===")
