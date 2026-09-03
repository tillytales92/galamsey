# validate_spatial_leakage.R
# Stage 1 of the RS6 backlog item (galamsey_tasklist.md: "Spatial CV + accuracy assessment for
# embedding classifier -- todo") -- a cheap diagnostic, not the full spatial-CV implementation.
#
# THE CONCERN (raised 2026-08-11): SmallMinesDS validation is concentrated in the same SW-Ghana
# gold belt (Amansie/Bekwai/Upper Denkyira -- see validate_external_references.R Part 2b) that
# Barenblitt/Maus/Tang training positives are drawn from. No single point is reused between
# training and validation (build_01_labels.R's exclusion mask keeps training NEGATIVES off every
# known footprint incl. SmallMinesDS, and the positives are independent digitizations) -- but
# AlphaEarth embeddings are spatially autocorrelated, so a validation point sitting near a
# training point may be "easy" even though it was never literally trained on. If so, the accuracy
# numbers this whole project has been leaning on (ablation OA/kappa, the 55% cutoff, the GHSL
# masking sweep) could be optimistic specifically where it matters least to know that -- i.e. they
# may not say much about genuinely new geography (the northern predictions, the actual reason
# this classifier runs nationally).
#
# WHAT THIS SCRIPT DOES: for each of the 8,540 SmallMinesDS-2022 validation points, computes the
# distance to the NEAREST training-positive point (Barenblitt/Maus/Tang, eroded, the actual
# geometries build_02 trains on), then checks whether accuracy at the deployed 55% cutoff
# degrades as that distance grows. Flat accuracy across distance = reassuring, no evidence of
# proximity-driven inflation. Accuracy dropping with distance = real evidence the reported
# accuracy doesn't travel to genuinely new areas, i.e. exactly the north.
#
# NOT full spatial CV (Stage 2, not built): that would mean re-training the classifier holding
# out spatial blocks -- a much bigger lift. This script answers a narrower, cheaper question
# first: does the CURRENT validation already show a distance-accuracy relationship, using data
# and assets that already exist (no retraining).
#
# Caches its one EE round-trip to data/processed/labels/spatial_leakage_scored_points.rds so it
# only needs auth once. DELETE that file to force a refresh (e.g. after re-running build_02 with
# different training data).
#
# Outputs: outputs/figures/spatial_leakage/*.png

pacman::p_load(sf, here, tidyverse, scales, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag, here::here
)
UTM30N <- 32630
PROB_THRESHOLD <- 55   # the deployed default established in validate_probability_threshold.R

fig_dir <- here("outputs", "figures", "spatial_leakage")
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
cache_path <- here("data", "processed", "labels", "spatial_leakage_scored_points.rds")

####1. Validation points + classifier probability, WITH real geometry (needs rgee/EE) ####

if (file.exists(cache_path)) {
  message("Reading cached scored+geometry validation points: ", cache_path)
  scored_geom <- readRDS(cache_path)
} else {

  rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
  Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
  Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)
  library(reticulate)
  pacman::p_load(rgee, googledrive)

  EE_PROJECT <- "rgee-auth-tillam"   # see build_02_embedding_classifier.R Section 1 for why this
                                     # must be the alphanumeric project ID, not the project number
  #rgee::ee_Authenticate()
  #rgee::ee_Initialize(project = EE_PROJECT)
  ee_check()
  #googledrive::drive_auth()   # ee_as_sf(via = "drive") needs this

  EE_ASSET_HOME  <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
  val_pts        <- ee$FeatureCollection(file.path(EE_ASSET_HOME, "rs05_val_pts_2022"))
  mine_prob_2022 <- ee$Image(file.path(EE_ASSET_HOME, "mine_prob_ghana_2022"))

  message("=== Sampling mine_prob_ghana_2022 at SmallMinesDS-2022 validation points, KEEPING geometry ===")
  # geometries = TRUE this time (Section 6 of validate_probability_threshold.R deliberately used
  # FALSE to keep that request light) -- distance-to-training-point is the whole point here, so
  # geometry has to travel with each result row. ee_as_sf(via = "drive") is rgee's own utility for
  # downloading a FeatureCollection to local sf, handling the >5,000-element interactive cap by
  # paginating through Drive internally -- simpler and more robust than manually parsing the .geo
  # GeoJSON column out of a CSV export (which is what Section 6's approach would have required).
  sampled_fc <- mine_prob_2022$sampleRegions(
    collection = val_pts, properties = list("label"), scale = 10, geometries = TRUE
  )
  scored_geom <- ee_as_sf(sampled_fc, via = "drive") |>
    rename(prob = mine_prob) |>
    select(label, prob, geometry) |>
    st_transform(UTM30N)

  saveRDS(scored_geom, cache_path)
  message("Wrote: ", cache_path)
}

message(sprintf("Loaded %d scored validation points with geometry", nrow(scored_geom)))

####2. Training-positive geometries (local, no EE needed) ####

lab_dir   <- here("data", "processed", "labels")
pos_poly  <- readRDS(file.path(lab_dir, "labels_positives_polygons.rds"))
pos_pts   <- readRDS(file.path(lab_dir, "labels_positives_points.rds"))
train_pos <- bind_rows(
  pos_poly |> st_geometry() |> st_as_sf(),
  pos_pts  |> st_geometry() |> st_as_sf()
) |> st_transform(UTM30N)
message(sprintf("Loaded %d training-positive geometries (Barenblitt+Maus+Tang, eroded)", nrow(train_pos)))

####3. Distance from each validation point to the nearest training positive ####

nearest_idx <- st_nearest_feature(scored_geom, train_pos)
scored_geom$dist_to_train_m <- st_distance(scored_geom, train_pos[nearest_idx, ], by_element = TRUE) |>
  as.numeric()

cat("\n=== Distance from SmallMinesDS-2022 validation points to nearest training positive ===\n")
print(summary(scored_geom$dist_to_train_m))

####4. Accuracy (at the deployed 55% cutoff) by distance bin ####

DIST_BREAKS_M <- c(0, 250, 500, 1000, 2000, 5000, 10000, Inf)
scored_geom <- scored_geom |>
  mutate(dist_bin = cut(dist_to_train_m, DIST_BREAKS_M, include.lowest = TRUE,
                        labels = c("0-250m", "250-500m", "500m-1km", "1-2km",
                                   "2-5km", "5-10km", "10km+")))

acc_by_dist <- scored_geom |> st_drop_geometry() |>
  group_by(dist_bin) |>
  summarise(
    n     = n(),
    n_pos = sum(label == 1),
    pa    = sum(prob >= PROB_THRESHOLD & label == 1) / pmax(sum(label == 1), 1),
    ua    = { tp <- sum(prob >= PROB_THRESHOLD & label == 1)
              fp <- sum(prob >= PROB_THRESHOLD & label == 0)
              if (tp + fp == 0) NA_real_ else tp / (tp + fp) },
    oa    = (sum(prob >= PROB_THRESHOLD & label == 1) + sum(prob < PROB_THRESHOLD & label == 0)) / n(),
    .groups = "drop"
  )

cat(sprintf("\n=== Accuracy at mine_prob >= %d, by distance-to-nearest-training-point ===\n", PROB_THRESHOLD))
print(acc_by_dist, n = Inf)

# simple trend check: correlate distance (continuous) with a per-point correctness indicator,
# not just eyeball the binned table -- Spearman since the relationship need not be linear
correct <- with(scored_geom, (prob >= PROB_THRESHOLD) == (label == 1))
rho <- suppressWarnings(cor(scored_geom$dist_to_train_m, as.numeric(correct), method = "spearman"))
cat(sprintf("\nSpearman correlation (distance vs. correctness): rho = %.3f\n", rho))
if (abs(rho) < 0.05) {
  cat("Negligible relationship -- no evidence current validation accuracy is inflated by\n")
  cat("proximity to training data. Reassuring for the SW-Ghana numbers, but note this still\n")
  cat("says nothing about the north, since NO validation point is far enough away to represent it.\n")
} else if (rho < 0) {
  cat("Accuracy DECLINES with distance from training data -- evidence the reported accuracy is\n")
  cat("partly a proximity artifact, and likely optimistic for genuinely new geography (the north).\n")
} else {
  cat("Accuracy INCREASES with distance -- unexpected; worth checking for a confound (e.g. distance\n")
  cat("correlating with mining density or label source) before concluding anything from this alone.\n")
}
cat(sprintf("Max distance in this validation set: %.1f km -- interpret the trend (or lack of one)\n",
            max(scored_geom$dist_to_train_m) / 1000))
cat("only up to that range; it cannot speak to distances beyond it (e.g. northern Ghana).\n")

####5. Plots ####

p_bar <- ggplot(acc_by_dist, aes(dist_bin)) +
  geom_col(aes(y = pa, fill = "Recall (PA)"), position = position_nudge(x = -0.2), width = 0.35) +
  geom_col(aes(y = ua, fill = "Precision (UA)"), position = position_nudge(x = 0.2), width = 0.35) +
  geom_text(aes(y = 0.02, label = paste0("n=", n)), size = 3, colour = "grey40") +
  scale_y_continuous(labels = label_percent(), limits = c(0, 1)) +
  scale_fill_manual(values = c("Recall (PA)" = "#450457", "Precision (UA)" = "#D94701"), name = NULL) +
  labs(title = "Validation accuracy by distance to nearest training-positive point",
       subtitle = sprintf("At the deployed cutoff (mine_prob >= %d) -- flat bars = no proximity effect", PROB_THRESHOLD),
       x = "Distance to nearest training positive", y = NULL) +
  theme_bw(base_size = 11)
ggsave(file.path(fig_dir, "spatial_leakage_accuracy_by_distance.png"), p_bar, width = 9, height = 5, dpi = 150)

p_scatter <- ggplot(scored_geom, aes(dist_to_train_m / 1000, as.numeric(prob >= PROB_THRESHOLD) - 0.5)) +
  geom_jitter(aes(colour = factor(label)), height = 0.15, alpha = 0.15, size = 0.6) +
  geom_smooth(aes(y = as.numeric(prob >= PROB_THRESHOLD)), method = "loess", colour = "black", se = TRUE) +
  scale_colour_manual(values = c("0" = "#2b6cb0", "1" = "#D94701"),
                      labels = c("0" = "True non-mine", "1" = "True mine"), name = NULL) +
  scale_x_continuous(labels = label_number(suffix = "km")) +
  labs(title = "Classifier positive-prediction rate vs. distance from training data",
       subtitle = "Black line = smoothed share predicted positive; flat = no distance effect",
       x = "Distance to nearest training positive", y = "Predicted positive (jittered)") +
  theme_bw(base_size = 11) + theme(legend.position = "bottom")
ggsave(file.path(fig_dir, "spatial_leakage_scatter.png"), p_scatter, width = 8, height = 6, dpi = 150)

message("\n=== validate_spatial_leakage.R complete ===")
