# b_02_firststage_models.R
# Compute layer for the MAUP-robustness analysis presented in
# a_03_firststage_diagnostics.Rmd. Runs a nested model ladder (M1..M4) across the 1, 2 and
# 5 km hex grids and, for each model × resolution cell, computes (a) first-stage fit metrics
# and (b) the geography-weighted Moran's I null (the D2bc simulation). Results are cached so
# the Rmd only has to render tables/figures — mirroring the d03 / d03b heavy-compute split.
#
# The point: show that the first-stage / spillover conclusions are robust to the Modifiable
# Areal Unit Problem (MAUP) — i.e. they do not hinge on the 5 km grain.
#
# Model ladder (each a strict superset of the previous — simplest → most complex):
#   M1  baseline                 any_art ~ gold_suit_share + dist_river_km
#   M2  + form & smoothing       + ns(dist_river_km, 4) (replaces linear) + spatial lags
#                                  of both covariates                         (Fix 1 + Fix 2)
#   M3  + terrain                + elev_mean + slope_mean                     (Fix 3)
#   M4  + interactions (all 4)   + geology×river + geology×slope + geology×elev + river×slope
#                                                                             (Fix 5, common
#                                  spec across grids so M4 is one object for the MAUP read)
#
# Inputs (per resolution res ∈ {1,2,5}):
#   data/processed/hex_{res}km_crosssection.rds  — list(hex_analysis, lw, ...) from
#       b_01_cross_section.R (all resolutions)
#   data/processed/hex_terrain_{res}km.csv           — per-hex elev_mean/slope_mean from
#       d_02_elevation.R (run it at HEX_RES_KM = res first; z11 DEM)
#
# M5 (5 km + 2 km): M4 + a thin-plate spline on hex centroids that absorbs ALL smooth spatial
# structure (measured or not) — the most conservative geography null. This is a robustness axis
# orthogonal to MAUP (omitted-geography, not grain), run at the 5 km headline grain + a 2 km
# sensitivity (M5_RES; not 1 km — gam + null sim is costly there) and kept out of the cross-grid
# tables. Set M5_ONLY <- TRUE to reuse the cached M1-M4 ladder and recompute only M5 (cheap
# iteration on the spline / K_TPS / M5_RES, no ladder re-run).
#
# Output:
#   data/processed/d03_maup_results.rds  — list(fit_grid, sim_grid, int_grid, m5, meta)

####0. Setup ####
pacman::p_load(tidyverse, sf, spdep, pROC, splines, mgcv, broom, here)
conflicted::conflicts_prefer(dplyr::mutate)
conflicted::conflicts_prefer(dplyr::filter)

RES_LIST <- c(1, 2, 5)                       # hex resolutions (km) to compare
N_SIM    <- c(`1` = 100L, `2` = 250L, `5` = 500L)  # null draws scale with grid (1 km is slow)
SEED     <- 42
K_TPS    <- 60L   # M5 thin-plate spline basis; result robust to 100 (verified 18 Jun 2026)
M5_RES   <- c(5, 2)  # resolutions (km) to run M5 at: 5 km headline + 2 km sensitivity
M5_ONLY  <- FALSE # TRUE = skip the M1-M4 ladder; reuse the existing d03_maup_results.rds and
                  # recompute only the 5 km M5 block (cheap iteration on the spline / K_TPS).
                  # Requires a prior full run to have written the rds.

out_path <- here("data", "processed", "d03_maup_results.rds")

# Nested ladder as literal formulas (common spec across grids — see header).
LADDER <- list(
  M1 = any_art ~ gold_suit_share + dist_river_km,
  M2 = any_art ~ ns(dist_river_km, 4) + gold_suit_share + lag_gold_suit + lag_dist_river,
  M3 = any_art ~ ns(dist_river_km, 4) + gold_suit_share + lag_gold_suit + lag_dist_river +
                 elev_mean + slope_mean,
  M4 = any_art ~ ns(dist_river_km, 4) + gold_suit_share + lag_gold_suit + lag_dist_river +
                 elev_mean + slope_mean +
                 gold_suit_share:dist_river_km + gold_suit_share:slope_mean +
                 gold_suit_share:elev_mean + dist_river_km:slope_mean
)
LADDER_LABEL <- c(
  M1 = "Baseline (geology + river)",
  M2 = "+ river spline + spatial lags",
  M3 = "+ terrain (elev + slope)",
  M4 = "+ interactions (all 4)"
)

# Single interactions for the appendix breakdown (added on top of M3 = additive best-fit).
INT_TERMS <- c(
  "geology x river" = "gold_suit_share:dist_river_km",
  "geology x slope" = "gold_suit_share:slope_mean",
  "geology x elev"  = "gold_suit_share:elev_mean",
  "river x slope"   = "dist_river_km:slope_mean"
)

####1. Helpers ####
# Geography-weighted null: place n_mine mines with probability ∝ fitted values, recompute
# Moran's I; repeat. Identical to d03 D2bc / the Rmd helper.
sim_morans_null <- function(probs, lw, n_mine, n_sim) {
  replicate(n_sim, {
    idx <- sample(length(probs), n_mine, replace = FALSE, prob = probs)
    v   <- numeric(length(probs)); v[idx] <- 1
    moran.test(v, lw, zero.policy = TRUE)$estimate["Moran I statistic"]
  })
}

####2. Per-resolution driver ####
run_resolution <- function(res_km) {
  res_tag      <- paste0(res_km, "km")
  cache_path   <- here("data", "processed", paste0("hex_", res_tag, "_crosssection.rds"))
  terrain_path <- here("data", "processed", paste0("hex_terrain_", res_tag, ".csv"))

  if (!file.exists(cache_path) || !file.exists(terrain_path)) {
    message("  [skip ", res_tag, "] missing ",
            if (!file.exists(cache_path)) basename(cache_path) else basename(terrain_path))
    return(NULL)
  }
  message("  [", res_tag, "] loading cache + terrain...")
  cache        <- readRDS(cache_path)
  hex_analysis <- cache$hex_analysis
  lw           <- cache$lw

  # hex_analysis is in lw row order (d03 keys the weights to it), so fitted(model) on the
  # full data is already aligned to lw. Add the spatial lags used by M2-M4.
  hex_analysis <- hex_analysis |>
    mutate(
      lag_gold_suit  = lag.listw(lw, gold_suit_share, zero.policy = TRUE),
      lag_dist_river = lag.listw(lw, dist_river_km,   zero.policy = TRUE)
    )

  terr <- read_csv(terrain_path, show_col_types = FALSE) |>
    select(hex_id, elev_mean, slope_mean)
  hex_analysis <- hex_analysis |>
    select(-any_of(c("elev_mean", "slope_mean"))) |>
    left_join(terr, by = "hex_id")

  # Fit all models on the common complete-terrain subset so AIC/McFadden are comparable
  # within this resolution. After the Ghana clip this is usually the full grid.
  hex_fit  <- hex_analysis |> filter(!is.na(elev_mean), !is.na(slope_mean))
  prev_fit <- mean(hex_fit$any_art)
  prev_all <- mean(hex_analysis$any_art)
  n_mine   <- sum(hex_analysis$any_art)

  # Fit-metric closures keyed to hex_fit
  ll0 <- as.numeric(logLik(glm(any_art ~ 1, data = hex_fit, family = binomial())))
  mcf <- function(f) 1 - as.numeric(logLik(f)) / ll0
  auc <- function(f) as.numeric(roc(hex_fit$any_art, fitted(f), quiet = TRUE)$auc)
  bri <- function(f) mean((hex_fit$any_art - fitted(f))^2)

  fits <- map(LADDER, \(form) glm(form, data = hex_fit, family = binomial()))

  # --- (a) fit metrics ---
  fit_grid <- tibble(
    res_km      = res_km,
    model       = names(fits),
    model_label = LADDER_LABEL[names(fits)],
    n_fit       = nrow(hex_fit),
    prevalence  = round(prev_fit, 4),
    mcfadden    = map_dbl(fits, mcf),    # within-grid only (prevalence-sensitive)
    auc         = map_dbl(fits, auc),    # cross-grid comparable (rank-based)
    brier       = map_dbl(fits, bri),
    aic         = map_dbl(fits, AIC)
  )

  # --- (b) geography-weighted null per model ---
  # probs in hex_analysis (= lw) order; hexes outside the fit subset inherit prevalence.
  make_probs <- function(fit) {
    p <- rep(prev_all, nrow(hex_analysis))
    p[match(hex_fit$hex_id, hex_analysis$hex_id)] <- fitted(fit)
    p
  }
  obs_moran <- as.numeric(moran.test(as.numeric(hex_analysis$any_art), lw,
                                     zero.policy = TRUE)$estimate["Moran I statistic"])
  n_sim <- N_SIM[[as.character(res_km)]]

  message("  [", res_tag, "] simulating null (", n_sim, " draws × ", length(fits), " models)...")
  set.seed(SEED)
  sim_grid <- imap_dfr(fits, \(fit, nm) {
    null <- sim_morans_null(make_probs(fit), lw, n_mine, n_sim)
    tibble(
      res_km    = res_km,
      model     = nm,
      n_sim     = n_sim,
      obs_moran = obs_moran,
      null_mean = mean(null),
      null_p95  = as.numeric(quantile(null, 0.95)),
      p_excess  = mean(null >= obs_moran)
    )
  })

  # --- (c) per-interaction appendix breakdown (no simulation; cheap glm only) ---
  f_base <- glm(LADDER$M3, data = hex_fit, family = binomial())   # additive reference
  aic_base <- AIC(f_base)
  int_each <- imap_dfr(INT_TERMS, \(tm, nm) {
    f <- glm(update(LADDER$M3, paste("~ . +", tm)), data = hex_fit, family = binomial())
    tibble(
      res_km   = res_km, interaction = nm,
      aic = AIC(f), dAIC_vs_base = AIC(f) - aic_base,
      LR_p_vs_base = anova(f_base, f, test = "Chisq")$`Pr(>Chi)`[2]
    )
  })
  int_all <- {
    f <- fits$M4
    tibble(res_km = res_km, interaction = "all four",
           aic = AIC(f), dAIC_vs_base = AIC(f) - aic_base,
           LR_p_vs_base = anova(f_base, f, test = "Chisq")$`Pr(>Chi)`[2])
  }
  int_grid <- bind_rows(int_each, int_all)

  list(fit = fit_grid, sim = sim_grid, int = int_grid)
}

####2b. M5 — spatial-spline null (per resolution) ####
# M1-M4 control for MEASURED geography; M5 adds s(easting_km, northing_km), a thin-plate spline
# on hex centroids that absorbs ALL smooth spatial structure (measured or not) — the most
# conservative geography null. compute_m5() runs one resolution; compute_m5_all() loops M5_RES.
# Result robust to k = 100 (see d03d test script). Each returned tibble/sf carries res_km so the
# pieces combine across resolutions for the Rmd Part C.
compute_m5 <- function(res_km = 5, k_tps = K_TPS, n_sim = 500L) {
  res_tag      <- paste0(res_km, "km")
  cache_path   <- here("data", "processed", paste0("hex_", res_tag, "_crosssection.rds"))
  terrain_path <- here("data", "processed", paste0("hex_terrain_", res_tag, ".csv"))
  if (!file.exists(cache_path) || !file.exists(terrain_path)) {
    message("  [skip M5] missing ",
            if (!file.exists(cache_path)) basename(cache_path) else basename(terrain_path))
    return(NULL)
  }
  message("  [M5 @ ", res_tag, "] fitting spline + simulating null...")
  cache        <- readRDS(cache_path)
  hex_analysis <- cache$hex_analysis
  hex_sf       <- cache$hex_sf
  lw           <- cache$lw

  hex_analysis <- hex_analysis |>
    mutate(
      lag_gold_suit  = lag.listw(lw, gold_suit_share, zero.policy = TRUE),
      lag_dist_river = lag.listw(lw, dist_river_km,   zero.policy = TRUE)
    )
  terr <- read_csv(terrain_path, show_col_types = FALSE) |>
    select(hex_id, elev_mean, slope_mean)
  hex_analysis <- hex_analysis |>
    select(-any_of(c("elev_mean", "slope_mean"))) |>
    left_join(terr, by = "hex_id")

  # Centroid coordinates in km (UTM30N) — the spline inputs.
  # suppressWarnings: sf's "attributes are constant over geometries" note is benign here.
  coords <- suppressWarnings(st_centroid(hex_sf)) |>
    mutate(easting_km  = st_coordinates(geometry)[, 1] / 1000,
           northing_km = st_coordinates(geometry)[, 2] / 1000) |>
    st_drop_geometry() |>
    select(hex_id, easting_km, northing_km)
  hex_analysis <- left_join(hex_analysis, coords, by = "hex_id")

  hex_fit  <- hex_analysis |> filter(!is.na(elev_mean), !is.na(slope_mean), !is.na(easting_km))
  prev_all <- mean(hex_analysis$any_art)
  n_mine   <- sum(hex_analysis$any_art)

  # M4 (glm) and M5 (M4 + spline) share linear terms by construction. Inline k as a literal in
  # the formula string: a variable (k_tps) would be looked up in the formula's environment (the
  # global env of LADDER$M4, not this function) when mgcv parses the smooth term, and fail.
  f_m4 <- LADDER$M4
  spline_term <- sprintf("s(easting_km, northing_km, bs = 'tp', k = %d)", k_tps)
  f_m5 <- update(f_m4, paste(". ~ . +", spline_term))
  m4 <- glm(f_m4, data = hex_fit, family = binomial())
  m5 <- mgcv::gam(f_m5, data = hex_fit, family = binomial(), method = "REML")

  # --- test stats ---
  ll0 <- as.numeric(logLik(glm(any_art ~ 1, data = hex_fit, family = binomial())))
  auc <- function(f) as.numeric(roc(hex_fit$any_art, fitted(f), quiet = TRUE)$auc)
  stats <- tibble(
    res_km     = res_km,
    model      = c("M4 (measured geography)", "M5 (+ spatial spline)"),
    n          = nrow(hex_fit),
    prevalence = round(mean(hex_fit$any_art), 3),
    mcfadden   = round(c(1 - as.numeric(logLik(m4)) / ll0,
                         1 - as.numeric(logLik(m5)) / ll0), 4),
    auc        = round(c(auc(m4), auc(m5)), 3),
    brier      = round(c(mean((hex_fit$any_art - fitted(m4))^2),
                         mean((hex_fit$any_art - fitted(m5))^2)), 4),
    aic        = round(c(AIC(m4), AIC(m5)), 1),
    dev_expl   = round(c(1 - m4$deviance / m4$null.deviance, summary(m5)$dev.expl), 3),
    edf        = c(NA_real_, round(summary(m5)$s.table[1, "edf"], 1))
  )

  # --- residual Moran's I (deviance residuals, aligned to lw row order) ---
  resid_moran_one <- function(fit, label) {
    r <- residuals(fit, type = "deviance")
    v <- rep(0, nrow(hex_analysis))
    v[match(hex_fit$hex_id, hex_analysis$hex_id)] <- r
    mt <- moran.test(v, lw, zero.policy = TRUE)
    tibble(model = label,
           moran_i = as.numeric(mt$estimate["Moran I statistic"]),
           p_value = mt$p.value)
  }
  resid_moran <- bind_rows(
    resid_moran_one(m4, "M4 (measured geography)"),
    resid_moran_one(m5, "M5 (+ spatial spline)")
  ) |> mutate(res_km = res_km, .before = 1)

  # --- geography-weighted null draws (M4 & M5), shared seed ---
  make_probs <- function(fit) {
    p <- rep(prev_all, nrow(hex_analysis))
    p[match(hex_fit$hex_id, hex_analysis$hex_id)] <- fitted(fit)
    p
  }
  obs_moran <- as.numeric(moran.test(as.numeric(hex_analysis$any_art), lw,
                                     zero.policy = TRUE)$estimate["Moran I statistic"])
  set.seed(SEED); null_m4 <- sim_morans_null(make_probs(m4), lw, n_mine, n_sim)
  set.seed(SEED); null_m5 <- sim_morans_null(make_probs(m5), lw, n_mine, n_sim)
  null_draws <- bind_rows(
    tibble(model = "M4 (measured geography)", moran = null_m4),
    tibble(model = "M5 (+ spatial spline)",   moran = null_m5)
  ) |> mutate(res_km = res_km, .before = 1)
  stats$p_excess <- c(mean(null_m4 >= obs_moran), mean(null_m5 >= obs_moran))

  # --- spatial surface: s(easting,northing) term, net of the measured covariates ---
  pterms     <- predict(m5, type = "terms")
  sp_name    <- grep("easting_km", colnames(pterms), value = TRUE)
  surface_sf <- hex_sf |>
    select(hex_id) |>
    left_join(tibble(hex_id = hex_fit$hex_id, spatial_logit = pterms[, sp_name]),
              by = "hex_id") |>
    mutate(res_km = res_km)

  list(res_km = res_km, k_tps = k_tps, n_sim = n_sim,
       stats = stats, obs_moran = obs_moran, null_draws = null_draws,
       resid_moran = resid_moran, surface_sf = surface_sf)
}

# Run M5 across M5_RES and combine into one structure for the Rmd Part C (each piece carries
# res_km). Per-resolution n_sim follows N_SIM (2 km -> 250, 5 km -> 500).
compute_m5_all <- function() {
  m5_list <- M5_RES |>
    set_names(paste0(M5_RES, "km")) |>
    map(\(r) compute_m5(r, n_sim = N_SIM[[as.character(r)]])) |>
    compact()
  if (length(m5_list) == 0) return(NULL)
  list(
    stats       = map_dfr(m5_list, "stats"),
    null_draws  = map_dfr(m5_list, "null_draws"),
    resid_moran = map_dfr(m5_list, "resid_moran"),
    obs_moran   = map_dfr(m5_list, \(x) tibble(res_km = x$res_km, obs_moran = x$obs_moran)),
    surface_sf  = do.call(rbind, unname(map(m5_list, "surface_sf"))),
    k_tps       = K_TPS,
    res         = as.numeric(sub("km", "", names(m5_list)))
  )
}

####3. Run across resolutions + cache ####
if (M5_ONLY) {
  # Cheap path: reuse the cached M1-M4 ladder, recompute only the 5 km M5 block.
  if (!file.exists(out_path))
    stop("M5_ONLY = TRUE but ", basename(out_path),
         " not found — do a full run (M5_ONLY <- FALSE) first.")
  message("=== d03c M5_ONLY: reusing M1-M4 ladder from ", basename(out_path),
          "; recomputing M5 only ===")
  out               <- readRDS(out_path)
  out$m5            <- compute_m5_all()
  out$meta$k_tps    <- K_TPS
  out$meta$run_date <- Sys.Date()

} else {
  message("=== d03c MAUP robustness: ", paste(RES_LIST, collapse = "/"), " km ===")
  results <- map(RES_LIST, run_resolution)
  results <- purrr::compact(results)                  # drop skipped resolutions

  if (length(results) == 0)
    stop("No resolutions could be processed — build the caches + hex_terrain CSVs first.")

  # M5 spatial-spline null at M5_RES (NULL if those caches / terrain CSVs are missing)
  m5_out <- compute_m5_all()

  out <- list(
    fit_grid = map_dfr(results, "fit"),
    sim_grid = map_dfr(results, "sim"),
    int_grid = map_dfr(results, "int"),
    m5       = m5_out,
    meta     = list(
      seed       = SEED,
      n_sim      = N_SIM,
      k_tps      = K_TPS,
      res_run    = sort(unique(map_dfr(results, "fit")$res_km)),
      ladder     = LADDER_LABEL,
      int_terms  = INT_TERMS,
      run_date   = Sys.Date()
    )
  )
}

saveRDS(out, out_path)
message("\nSaved: ", out_path)

# Console preview
cat("\n=== Fit metrics (AUC is the cross-grid metric) ===\n")
out$fit_grid |>
  mutate(across(c(mcfadden, auc, brier), \(x) round(x, 4)), aic = round(aic, 1)) |>
  print(n = Inf)

cat("\n=== Geography-weighted null (p_excess ≈ 0 = clustering survives the control) ===\n")
out$sim_grid |>
  mutate(across(c(obs_moran, null_mean, null_p95, p_excess), \(x) round(x, 4))) |>
  print(n = Inf)

if (!is.null(out$m5)) {
  cat("\n=== M5 spatial-spline null (", paste0(out$m5$res, collapse = "/"), " km) ===\n", sep = "")
  print(out$m5$stats)
  cat("\nObserved Moran's I by resolution:\n"); print(out$m5$obs_moran)
  cat("\nResidual Moran's I:\n")
  out$m5$resid_moran |>
    mutate(moran_i = round(moran_i, 3), p_value = signif(p_value, 3)) |>
    print()
}

message("\n=== b_03_firststage_models.R complete — knit a_03_firststage_diagnostics.Rmd to present ===")
