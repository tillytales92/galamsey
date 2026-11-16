# diag_06_onset_2002_check.R -- first run 2026-11-16 (UTM grid); v2 samples on the asset grid + rules a1, a2, d
#
# Is the 2002 onset pile-up in the deployed asset (7.4% of all onsets vs 0.5% in 2001) real
# vegetation loss or an observation-density artefact? In the Barenblitt replica,
#   onset 2002  <=>  loss[2002] = (maxNDVI[2000] - maxNDVI[2003]) / 3 is the pixel's largest loss,
# and 2003 is the first Landsat 7 SLC-off year: fewer clear obs (mean 3.6 in 2002, 3.0 in 2003,
# 1.8 in 2004; scene_coverage_anchor2017.csv) -> a mechanically lower annual MAX.
#
# Sampled pixels only, no Drive export. Per pixel and year 1998-2018: clear-obs count + annual
# max / p85 / median NDVI (same masking/harmonisation as build_04). Then, in R:
#   1. recompute the deployed rule -- sanity check, must reproduce the asset's onset_year;
#   2. re-date under alternative rules -> where do the 2002 pixels move, and how many to >= 2005?
#        a   min-2-obs: years with < 2 clear obs = missing AND 3yr mean over >= 2 available years
#        a1  only the first half of a (drop 1-obs years, keep the strict 3-of-3 mean)
#        a2  only the second half of a (keep 1-obs years, 3yr mean over >= 2 available years)
#        b   p85 instead of max;  c  median instead of max
#        d   V-fix: a 1-obs year that sits >= V_DROP below BOTH neighbours is replaced by the
#            neighbours' mean; everything else as deployed (targets only the one-year-V artefact)
#        e   1-obs years replaced by linear interpolation between the nearest >= 2-obs years (no year
#            masked, so no candidate year lost -- unlike a/a1). Added 2026-11-16 after a1 failed the
#            by-true-year check in validate_backdating_method_fidelity.R.
#      plus the reweighted share of the footprint each rule dates before 2005.
#   3. the same rules on random points inside Barenblitt et al. polygons -> does agreement with
#      classifica + 1 (+-1 yr) hold? A rule that lowers it is not adopted;
#   4. dip shape under the deployed rule: does NDVI recover after the onset (transient dip, like
#      the 2002 example pixel in diag_04's figure) or stay down (persistent loss)? Is the trough a
#      single-observation year? For 2002 pixels: is there a separate loss >= 2005?
#
# Output: outputs/tables/backdating/diag_06_*.csv, outputs/figures/backdating/diag_06_onset_2002_check.png
# Re-runs reuse the sampled values from diag_06_samples_cache_assetgrid.rds (delete it to resample).

#### 1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, here, tidyverse, sf, patchwork, conflicted)
conflicts_prefer(dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise, dplyr::lag, here::here)

EE_PROJECT    <- "rgee-auth-tillam"
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)

ee_Authenticate()
ee_Initialize(project = EE_PROJECT)

#### 2. Parameters (window must match build_04_backdating.R) ####
ONSET_MIN <- 2000L; ONSET_MAX <- 2017L
IMG_START <- 1998L; IMG_END   <- 2018L
ONSET_ASSET <- file.path(EE_ASSET_HOME, sprintf("mine_onset_year_%d_%d_barenblitt", ONSET_MIN, ONSET_MAX))

N_2002    <- 500L    # sampled pixels with onset 2002
N_OTHER   <- 60L     # per other onset year (controls + dip shape by year)
N_VALID   <- 1500L   # random points inside Barenblitt et al. polygons (only some fall in the footprint)
MIN_OBS   <- 2L      # rules a, a1
V_DROP    <- 0.15    # rule d: NDVI gap below both neighbours that marks a one-year V
LATER_MIN <- 2005L   # "is there a separate loss from 2005 on?"
LATER_LOSS_MIN <- 0.05   # in 3yr-mean NDVI units, same scale as ndvi_deriv_x1000 / 1000
SEED  <- 16L
CHUNK <- 150L        # points per sampleRegions getInfo call

OUT_TAB <- here("outputs", "tables", "backdating")
OUT_FIG <- here("outputs", "figures", "backdating")
CACHE   <- file.path(OUT_TAB, "diag_06_samples_cache_assetgrid.rds")   # v2: sampled on the asset's grid

suppressMessages(sf_use_s2(FALSE))
conv <- st_read(here("data", "raw", "barenblitt", "MiningConversion_2007-2017Vec.shp"), quiet = TRUE) |>
  st_make_valid() |> st_zm(drop = TRUE) |> st_transform(32630) |>
  transmute(bar_year = 2000L + as.integer(classifica))

#### 3. Sample (EE) -- skipped if the cache exists ####
if (file.exists(CACHE)) {
  samp <- readRDS(CACHE)
  message("Loaded ", nrow(samp), " sampled pixels from cache")
} else {
  ghana <-ee$FeatureCollection(file.path(EE_ASSET_HOME, "rs05_ghana"))$geometry()
  asset <- ee$Image(ONSET_ASSET)

  # Landsat NDVI, as build_04 Section 5 (no ever_mined mask / clip -- irrelevant at sampled points)
  maskL2 <- function(img) {
    qa    <- img$select("QA_PIXEL")
    clear <- qa$bitwiseAnd(bitwShiftL(1L, 1L))$eq(0)$
      And(qa$bitwiseAnd(bitwShiftL(1L, 3L))$eq(0))$
      And(qa$bitwiseAnd(bitwShiftL(1L, 4L))$eq(0))
    img$updateMask(clear)$updateMask(img$select("QA_RADSAT")$eq(0))
  }
  ROY <- list(RED = list(s = 0.9047, i = 0.0061), NIR = list(s = 0.8462, i = 0.0412))
  ndvi_col <- function(id, bands, is_oli) {
    ee$ImageCollection(id)$filterBounds(ghana)$
      filterDate(sprintf("%d-01-01", IMG_START), sprintf("%d-01-01", IMG_END + 1L))$
      map(maskL2)$
      map(function(img) {
        sr <- img$select(bands, c("RED", "NIR"))$multiply(0.0000275)$add(-0.2)
        if (is_oli) sr <- sr$select("RED")$multiply(ROY$RED$s)$add(ROY$RED$i)$
          addBands(sr$select("NIR")$multiply(ROY$NIR$s)$add(ROY$NIR$i))
        sr$normalizedDifference(c("NIR", "RED"))$rename("NDVI")$copyProperties(img, list("system:time_start"))
      })
  }
  landsat <- ndvi_col("LANDSAT/LT05/C02/T1_L2", c("SR_B3", "SR_B4"), FALSE)$
    merge(ndvi_col("LANDSAT/LE07/C02/T1_L2", c("SR_B3", "SR_B4"), FALSE))$
    merge(ndvi_col("LANDSAT/LC08/C02/T1_L2", c("SR_B4", "SR_B5"), TRUE))

  # One band per stat x year. Every year 1998-2018 has scenes over Ghana, so no empty-year fallback.
  red <- ee$Reducer$max()$
    combine(ee$Reducer$count(), sharedInputs = TRUE)$
    combine(ee$Reducer$percentile(list(50L, 85L)), sharedInputs = TRUE)
  year_stats <- function(yr) {
    landsat$filter(ee$Filter$calendarRange(yr, yr, "year"))$reduce(red)$
      select(c("NDVI_max", "NDVI_count", "NDVI_p50", "NDVI_p85"), paste0(c("max_", "n_", "p50_", "p85_"), yr))
  }
  stats_img <- ee$Image$cat(lapply(IMG_START:IMG_END, year_stats))
  # Sentinels instead of masks: sampleRegions drops a point if a band is masked (no-obs years, undated).
  img_all <- asset$select(c("onset_year", "ndvi_deriv_x1000", "start_ndvi_x1000", "lt_agree"))$unmask(-1)$
    addBands(stats_img$unmask(-9))

  # (i) stratified by onset year, national
  yrs <- ONSET_MIN:ONSET_MAX
  strat <- asset$select("onset_year")$toInt()$
    stratifiedSample(numPoints = N_OTHER, classBand = "onset_year", region = ghana, scale = 30L,
                     classValues = as.list(yrs), classPoints = as.list(ifelse(yrs == 2002L, N_2002, N_OTHER)),
                     seed = SEED, geometries = TRUE, tileScale = 8L) |>
    ee_as_sf(via = "getInfo") |>
    transmute(set = "stratified", strat_onset = as.integer(onset_year), bar_year = NA_integer_)
  message(nrow(strat), " stratified points")

  # (ii) random points inside Barenblitt et al. polygons, area-weighted (drawn locally)
  set.seed(SEED)
  idx  <- sample(nrow(conv), N_VALID, replace = TRUE, prob = as.numeric(st_area(conv)))
  vpts <- st_sf(geometry = st_sample(conv[idx, ], size = rep(1L, N_VALID))) |> filter(!st_is_empty(geometry))
  vpts$bar_year <- map_int(st_intersects(vpts, conv), ~ min(conv$bar_year[.x]))   # overlaps: earliest
  vpts <- vpts |> st_transform(4326) |> mutate(set = "barenblitt_polygons", strat_onset = NA_integer_)

  pts <- bind_rows(strat, vpts) |> mutate(pid = row_number())
  get_chunk <- function(ix) {
    fc  <- sf_as_ee(pts[ix, "pid"])
    # On the ASSET's grid (EPSG:4326, 30 m), so the Landsat values are those build_04 dated. The first
    # run sampled on a UTM 30 m grid: often a neighbouring pixel, and only 68% matched the asset's year.
    res <- img_all$sampleRegions(collection = fc, properties = list("pid"),
                                 projection = asset$projection(), tileScale = 4L)$getInfo()
    map_dfr(res$features, ~ as_tibble(.x$properties))
  }
  chunks <- split(seq_len(nrow(pts)), ceiling(seq_len(nrow(pts)) / CHUNK))
  vals <- imap_dfr(chunks, function(ix, k) { message("  chunk ", k, "/", length(chunks)); get_chunk(ix) })

  samp <- pts |> st_drop_geometry() |>
    bind_cols(as_tibble(st_coordinates(pts))) |> rename(lon = X, lat = Y) |>
    inner_join(vals, by = "pid")
  saveRDS(samp, CACHE)
  message("Sampled ", nrow(samp), " of ", nrow(pts), " points -> cache")
}

#### 4. Long format + dating rules (R) ####
samp <- samp |> mutate(asset_onset = if_else(onset_year < 0, NA_integer_, as.integer(onset_year)))
long <- samp |>
  select(pid, matches("^(max|n|p50|p85)_\\d{4}$")) |>
  pivot_longer(-pid, names_to = c(".value", "year"), names_pattern = "(max|n|p50|p85)_(\\d{4})") |>
  mutate(year = as.integer(year),
         across(c(max, p50, p85), ~ if_else(.x <= -9, NA_real_, .x)),
         n = if_else(is.na(n) | n < 0, 0L, as.integer(n))) |>
  arrange(pid, year) |>
  group_by(pid) |>
  mutate(vdip  = n == 1L & !is.na(lag(max)) & !is.na(lead(max)) & pmin(lag(max), lead(max)) - max >= V_DROP,
         max_v = if_else(vdip, (lag(max) + lead(max)) / 2, max),     # rule d
         max_e = { ok <- n >= 2L & !is.na(max)                      # rule e
                   if (sum(ok) >= 2) { iv <- approx(year[ok], max[ok], xout = year, rule = 1)$y
                                       if_else(n == 1L & !is.na(iv), iv, max) } else max }) |>
  ungroup()

# Barenblitt replica on one annual value. Deployed: value = max, min_obs = 1, min_avail = 3
# (a missing year masks the 3yr mean, as in build_04 Section 7).
date_rule <- function(value, min_obs = 1L, min_avail = 3L, rule) {
  long |> group_by(pid) |>
    mutate(v    = if_else(n >= min_obs, .data[[value]], NA_real_),
           k    = (!is.na(lag(v))) + (!is.na(v)) + (!is.na(lead(v))),   # parens: `!` binds looser than `+`
           ma3  = if_else(k >= min_avail, (coalesce(lag(v), 0) + coalesce(v, 0) + coalesce(lead(v), 0)) / k, NA_real_),
           loss = lag(ma3) - ma3,
           cand = year >= max(IMG_START + 2L, ONSET_MIN) & year <= min(IMG_END - 1L, ONSET_MAX) & !is.na(loss),
           cand_later = cand & year >= LATER_MIN) |>
    summarise(onset      = if (any(cand)) year[cand][which.max(loss[cand])] else NA_integer_,
              loss_max   = if (any(cand)) max(loss[cand]) else NA_real_,
              later_year = if (any(cand_later)) year[cand_later][which.max(loss[cand_later])] else NA_integer_,
              later_loss = if (any(cand_later)) max(loss[cand_later]) else NA_real_,
              .groups = "drop") |>
    mutate(rule = rule)
}
RULES <- c("deployed", "a_min2obs", "a1_drop1obs", "a2_relaxavg", "b_p85", "c_median", "d_vfix", "e_interp1obs")
dated <- bind_rows(
  date_rule("max",   rule = "deployed"),
  date_rule("max",   min_obs = MIN_OBS, min_avail = 2L, rule = "a_min2obs"),
  date_rule("max",   min_obs = MIN_OBS, min_avail = 3L, rule = "a1_drop1obs"),
  date_rule("max",   min_obs = 1L,      min_avail = 2L, rule = "a2_relaxavg"),
  date_rule("p85",   rule = "b_p85"),
  date_rule("p50",   rule = "c_median"),
  date_rule("max_v", rule = "d_vfix"),
  date_rule("max_e", rule = "e_interp1obs")
) |> mutate(rule = factor(rule, RULES)) |>
  left_join(select(samp, pid, set, bar_year, asset_onset, lt_agree), by = "pid")
message(sprintf("Rule d: %d one-year V dips replaced in %d of %d pixels",
                sum(long$vdip), n_distinct(long$pid[long$vdip]), n_distinct(long$pid)))

#### 5. Results ####
dep <- filter(dated, rule == "deployed")

# 5.1 Sanity: does the recomputed deployed rule reproduce the asset?
san <- dep |> filter(!is.na(asset_onset)) |>
  summarise(n = n(), match = mean(onset == asset_onset, na.rm = TRUE), within1 = mean(abs(onset - asset_onset) <= 1, na.rm = TRUE))
message(sprintf("Recompute vs asset: %d px, %.1f%% exact, %.1f%% within 1 yr (mismatches = 4326-vs-UTM neighbour pixels)",
                san$n, 100 * san$match, 100 * san$within1))

# 5.2 Where do the 2002 pixels go? (2002 = recomputed deployed onset, so the rules are compared
#     on identical inputs)
px2002 <- dep |> filter(onset == 2002L) |> pull(pid)
moves <- dated |> filter(pid %in% px2002) |>
  mutate(dest = case_when(is.na(onset) ~ "undatable", onset == 2002 ~ "stays 2002", onset < 2002 ~ "2000-2001",
                          onset < LATER_MIN ~ sprintf("2003-%d", LATER_MIN - 1L), TRUE ~ sprintf("%d+", LATER_MIN))) |>
  count(rule, dest) |> group_by(rule) |> mutate(share = n / sum(n)) |> ungroup()
print(pivot_wider(select(moves, -n), names_from = rule, values_from = share, values_fill = 0))
write_csv(moves, file.path(OUT_TAB, "diag_06_2002_moves.csv"))

# 5.3 Dip shape under the deployed rule. pre = mean annual max in the 3 yrs before the onset,
#     trough = lowest annual max in onset..onset+1 (where loss[y] puts the drop), post = median
#     annual max in onset+2..onset+4. Recovery = share of the drop regained. Onsets >= 2015 have
#     a truncated post window (imagery ends 2018).
shape <- long |> inner_join(select(dep, pid, onset), by = "pid") |> filter(!is.na(onset)) |>
  group_by(pid, onset) |>
  summarise(pre      = mean(max[year %in% (onset[1] - 3L):(onset[1] - 1L)], na.rm = TRUE),
            trough   = suppressWarnings(min(max[year %in% onset[1]:(onset[1] + 1L)], na.rm = TRUE)),
            trough_n = { i <- which(year %in% onset[1]:(onset[1] + 1L) & !is.na(max)); if (length(i)) n[i][which.min(max[i])] else NA_integer_ },
            post     = median(max[year %in% (onset[1] + 2L):(onset[1] + 4L)], na.rm = TRUE),
            .groups = "drop") |>
  mutate(drop  = pre - trough,
         recov = (post - trough) / drop,
         shape = case_when(!is.finite(drop) | !is.finite(recov) | drop < 0.05 ~ "unclear (small drop / missing yrs)",
                           recov >= 0.75 ~ "transient dip (recovers)",
                           recov <= 0.25 ~ "persistent loss",
                           TRUE          ~ "partial recovery"),
         single_obs_trough = trough_n == 1L)

shape_strat <- shape |> inner_join(select(filter(samp, set == "stratified"), pid), by = "pid")
shape_by_year <- shape_strat |> count(onset, shape) |> group_by(onset) |> mutate(share = n / sum(n)) |> ungroup()
single_by_year <- shape_strat |> group_by(onset) |>
  summarise(n = n(), single_obs_trough = mean(single_obs_trough, na.rm = TRUE),
            transient_and_single = mean(shape == "transient dip (recovers)" & single_obs_trough, na.rm = TRUE), .groups = "drop")
print(single_by_year, n = Inf)

# National shares: reweight the stratified sample by the asset's onset-year counts
w <- read_csv(file.path(OUT_TAB, sprintf("onset_summary_%d_%d.csv", ONSET_MIN, ONSET_MAX)), show_col_types = FALSE) |>
  filter(onset_year > 0) |> group_by(onset = as.integer(onset_year)) |> summarise(n_asset = sum(n_pixels), .groups = "drop")
shape_national <- shape_by_year |> left_join(w, by = "onset") |>
  group_by(shape) |> summarise(share = sum(share * n_asset) / sum(w$n_asset), .groups = "drop")
message("Dip shape, whole footprint (reweighted):"); print(shape_national)
write_csv(left_join(shape_by_year, single_by_year, by = "onset", suffix = c("", "_year")),
          file.path(OUT_TAB, "diag_06_dip_shape_by_year.csv"))

# 5.4 2002 pixels: a separate loss from LATER_MIN on (what an ONSET_MIN = 2005 re-dating would pick)
later2002 <- dep |> filter(pid %in% px2002) |> left_join(select(shape, pid, shape), by = "pid") |>
  group_by(shape) |>
  summarise(n = n(), has_later_loss = mean(later_loss >= LATER_LOSS_MIN, na.rm = TRUE),
            median_later_year = median(later_year[later_loss >= LATER_LOSS_MIN], na.rm = TRUE), .groups = "drop")
print(later2002)
write_csv(later2002, file.path(OUT_TAB, "diag_06_2002_later_loss.csv"))

# 5.5 Guard: agreement with Barenblitt et al. (classifica + 1) under each rule
guard <- dated |> filter(set == "barenblitt_polygons", !is.na(asset_onset)) |>   # in the deployed footprint
  mutate(e = abs(onset - (bar_year + 1L))) |>
  group_by(rule) |>
  summarise(n = n(), coverage = mean(!is.na(onset)), exact = mean(e == 0, na.rm = TRUE),
            within1 = mean(e <= 1, na.rm = TRUE), within2 = mean(e <= 2, na.rm = TRUE), .groups = "drop")
print(guard)
write_csv(guard, file.path(OUT_TAB, "diag_06_rules_vs_barenblitt.csv"))

# 5.6 Share of the whole footprint dated before LATER_MIN under each rule (stratified sample
#     reweighted by the asset's onset-year counts) -- how much a "no mining before 2005" assumption
#     would have to override once the noise is removed.
wt <- samp |> filter(set == "stratified", !is.na(asset_onset)) |> count(onset = asset_onset, name = "n_samp") |>
  left_join(w, by = "onset") |> mutate(wt = n_asset / n_samp)
pre05 <- dated |> filter(set == "stratified", !is.na(asset_onset)) |>
  left_join(select(wt, asset_onset = onset, wt), by = "asset_onset") |>
  left_join(select(shape, pid, shape), by = "pid") |>
  group_by(rule) |>
  summarise(pre2005       = sum(wt * (onset < LATER_MIN), na.rm = TRUE) / sum(wt),
            pre2005_persistent_deployed = sum(wt * (onset < LATER_MIN & shape == "persistent loss"), na.rm = TRUE) / sum(wt),
            undatable     = sum(wt * is.na(onset)) / sum(wt), .groups = "drop")
print(pre05)
write_csv(pre05, file.path(OUT_TAB, "diag_06_pre2005_share.csv"))

#### 6. Figure ####
SHAPE_COL <- c("persistent loss" = "#2a78d6", "partial recovery" = "#1baf7a",
               "transient dip (recovers)" = "#eb6834", "unclear (small drop / missing yrs)" = "grey70")
DEST_LVL  <- c("2000-2001", "stays 2002", sprintf("2003-%d", LATER_MIN - 1L), sprintf("%d+", LATER_MIN), "undatable")
DEST_COL  <- setNames(c("grey55", "#eb6834", "#eda100", "#2a78d6", "grey80"), DEST_LVL)
th <- theme_minimal(base_size = 10) + theme(panel.grid.minor = element_blank(), panel.grid.major.x = element_blank())

p_shape <- ggplot(shape_by_year, aes(factor(onset), share, fill = factor(shape, names(SHAPE_COL)))) +
  geom_col(width = 0.8, colour = "white", linewidth = 0.3) +
  scale_fill_manual(values = SHAPE_COL, name = NULL) +
  scale_y_continuous(labels = scales::percent) +
  labs(x = "onset year (deployed rule)", y = "share of sampled pixels",
       title = "A. Does NDVI recover after the onset?") + th + theme(legend.position = "bottom")

p_moves <- ggplot(moves, aes(rule, share, fill = factor(dest, DEST_LVL))) +
  geom_col(width = 0.7, colour = "white", linewidth = 0.3) +
  scale_fill_manual(values = DEST_COL, name = NULL) +
  scale_y_continuous(labels = scales::percent) +
  labs(x = NULL, y = sprintf("share of the %d onset-2002 pixels", length(px2002)),
       title = "B. Where the 2002 pixels go under each rule") + th +
  theme(legend.position = "bottom", axis.text.x = element_text(angle = 30, hjust = 1))

set.seed(SEED)
spag_ids <- sample(px2002, min(150L, length(px2002)))
spag <- long |> filter(pid %in% spag_ids, year <= 2010L) |> left_join(select(shape, pid, shape), by = "pid") |>
  filter(shape != "unclear (small drop / missing yrs)")
p_spag <- ggplot(spag, aes(year, max)) +
  geom_line(aes(group = pid), colour = "grey75", linewidth = 0.3, na.rm = TRUE) +
  stat_summary(fun = median, geom = "line", colour = "#d7301f", linewidth = 1, na.rm = TRUE) +
  geom_vline(xintercept = 2003, linetype = "dotted") +
  facet_wrap(~ shape) +
  scale_x_continuous(breaks = c(2000, 2003, 2006, 2009)) +
  labs(x = NULL, y = "annual max NDVI", title = "C. Onset-2002 pixels, 1998-2010",
       subtitle = "grey = one pixel, red = median; dotted = 2003, first Landsat 7 SLC-off year") + th

fig <- (p_shape / (p_moves | p_spag)) + plot_layout(heights = c(1, 1.1))
print(fig)
ggsave(file.path(OUT_FIG, "diag_06_onset_2002_check.png"), fig, width = 13, height = 10, dpi = 200)

write_csv(left_join(dated, select(shape, pid, pre, trough, trough_n, post, recov, shape), by = "pid"),
          file.path(OUT_TAB, "diag_06_pixels.csv"))
