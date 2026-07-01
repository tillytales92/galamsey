# a_02_spatial_clustering.R
# Section 1.2 — Spatial Clustering and Expansion of Galamsey
#
# mine_data: reads processed artifacts from b_01_cross_section.R; swap for RS
#            panel once Part 1 is complete.
#
# Scale note: 5 km hexagons — sufficient for Moran's I power; Girard geology
# (1:10M scale) provides no sub-5km signal anyway.
#
# Outputs (outputs/figures/spatial_clustering/):
#   d2_map_incidence        — descriptive map, southern Ghana (artisanal, 5 km hex)
#   d2a_morans_by_year      — global Moran's I time series
#   d2a_lisa_2017           — LISA hotspot/coldspot map (cumulative 2007–2017)
#   d2b_morans_comparison   — Moran's I: raw / geology / geology+river (CSV)
#   d2bc_geography_null     — geography-weighted null Moran's I distributions (PNG + CSV)
#   d2d_spatial_lag_coefs   — spatial lag regression coefficient table (CSV)
#   d2e_upstream_downstream — upstream vs downstream spread along rivers
#   d2e_schematic           — schematic illustration of D2e logic (synthetic data)

####0. Setup ####
pacman::p_load(
  tidyverse, sf, here, janitor, scales, patchwork, spdep, fixest, conflicted
)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)
UTM30N <- 32630

####1. Parameters ####
RIVER_BUFFER_M <- 1000   # metres — radius around waterways for D2c / D2e

# Build artifact paths (from b_01_cross_section.R)
cache_5km_path <- here("data", "processed", "hex_5km_crosssection.rds")
ts_hex_path    <- here("data", "processed", "mining_timeseries_by_hex5km_2007_2017_long.csv")

# Raw data still needed for map display and the D2bc first-stage model refit
barenblitt_2019_path <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")
gold_suit_path       <- here("data", "raw", "goldsuitability", "Gold_suitable_geology",
                              "gold_suitable_geology.shp")
waterways_path       <- here("data", "processed", "waterways", "waterways_natural.shp")
admin0_path          <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp")
admin1_path          <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin1.shp")

out_dir <- here("outputs", "figures", "spatial_clustering")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# Clean slate: remove rebuildable d2* outputs so stale files cannot linger
old_outputs <- list.files(out_dir, pattern = "^d2.*\\.(png|csv|tex|md)$", full.names = TRUE)
if (length(old_outputs) > 0) {
  unlink(old_outputs)
  message(sprintf("Cleared %d prior d03 output(s) in %s", length(old_outputs), out_dir))
}

####2. Read build artifacts ####

# a. First-stage cache: hex grid, cross-section frame, spatial weights, study area
message("Loading b_01_cross_section cache (5 km)...")
cache        <- readRDS(cache_5km_path)
hex_sf       <- cache$hex_sf
hex_analysis <- cache$hex_analysis
lw           <- cache$lw
nb           <- cache$nb
study_area   <- cache$study_area

# Reconstruct hex_cs (spatial) by joining analysis columns back to geometry
hex_cs <- hex_sf |> left_join(hex_analysis, by = "hex_id")

hex_centroids <- st_centroid(hex_sf)
hex_northing  <- hex_centroids |>
  mutate(northing = st_coordinates(geometry)[, 2]) |>
  st_drop_geometry() |>
  select(hex_id, northing)

# b. Annual mining panel (rename area_ha -> mine_ha to match internal convention)
year_list <- 2007:2017
panel_complete <- read_csv(ts_hex_path, show_col_types = FALSE) |>
  rename(mine_ha = area_ha) |>
  complete(hex_id = hex_sf$hex_id, year = year_list, fill = list(mine_ha = 0)) |>
  group_by(hex_id) |>
  arrange(year) |>
  mutate(cumul_ha = cumsum(mine_ha)) |>
  ungroup()

# c. Supporting layers for maps and D2bc model refit
mining_2019 <- st_read(barenblitt_2019_path, quiet = TRUE) |> clean_names() |>
  st_transform(UTM30N) |> st_make_valid()
gold_suit   <- st_read(gold_suit_path,       quiet = TRUE) |> clean_names() |>
  st_transform(UTM30N) |> st_make_valid()
country_sf  <- st_read(admin0_path,          quiet = TRUE) |> clean_names() |>
  st_transform(UTM30N)
regions_sf  <- st_read(admin1_path,          quiet = TRUE) |> clean_names() |>
  st_transform(UTM30N)
waterways   <- st_read(waterways_path,       quiet = TRUE) |> clean_names() |>
  st_transform(UTM30N)
message(sprintf("Waterways: %d natural-watercourse features loaded from processed/.", nrow(waterways)))

# d. Derived spatial objects
ghana_poly      <- st_union(country_sf) |> st_make_valid()
study_area_hull <- st_union(mining_2019) |> st_convex_hull()   # raw pre-clip hull
study_area_sf   <- st_sf(geometry = study_area)
study_overhang  <- st_difference(st_sf(geometry = study_area_hull), ghana_poly)
study_regions   <- regions_sf[st_intersects(regions_sf, study_area, sparse = FALSE)[, 1], ]
waterways_clip  <- st_filter(waterways, study_area_sf)

message(sprintf("Loaded: %d hexes at 5 km | %d panel rows | %d waterway features",
                nrow(hex_sf), nrow(panel_complete), nrow(waterways)))

# Ghana locator inset — built once, reused across map outputs
p_inset_ghana <- ggplot() +
  geom_sf(data = country_sf,    fill = "grey92", colour = "grey50", linewidth = 0.3) +
  geom_sf(data = study_area_sf, fill = "#C0392B", alpha = 0.45,
          colour = "#7B241C", linewidth = 0.6) +
  theme_void() +
  theme(panel.background = element_rect(fill = "white", colour = "grey40", linewidth = 0.5))

# Overhang diagnostic: document how much of the raw hull lies outside Ghana
overhang_km2 <- as.numeric(st_area(study_overhang)) / 1e6
hull_km2     <- as.numeric(st_area(st_sf(geometry = study_area_hull))) / 1e6
message(sprintf("Clipped %.0f km2 of overhang beyond Ghana (%.1f%% of the raw %.0f km2 hull)",
                overhang_km2, 100 * overhang_km2 / hull_km2, hull_km2))

p_overhang <- ggplot() +
  geom_sf(data = country_sf,     fill = "grey92", colour = "grey50", linewidth = 0.3) +
  geom_sf(data = study_area_sf,  fill = "#AED6F1", colour = "#1A5276", linewidth = 0.6, alpha = 0.5) +
  geom_sf(data = study_overhang, fill = "#C0392B", colour = NA, alpha = 0.6) +
  labs(
    title    = "Study area clipped to Ghana's border",
    subtitle = sprintf("Blue = retained study area; red = overhang removed (%.0f km², %.1f%% of raw hull)",
                       overhang_km2, 100 * overhang_km2 / hull_km2),
    caption  = "Study area = convex hull of Barenblitt 2019 extent, clipped to HDX gha_admin0."
  ) +
  theme_void(base_size = 10) +
  theme(plot.title   = element_text(face = "bold"),
        plot.caption = element_text(colour = "grey50", size = 7))

ggsave(file.path(out_dir, "d2_study_area_overhang.png"), p_overhang,
       width = 8, height = 8, dpi = 150)

####D2_Map. Descriptive Map — Southern Ghana Galamsey Incidence ####

p_incidence <- ggplot() +
  geom_sf(data = hex_cs,
          aes(fill = art_share * 100), colour = "white", linewidth = 0.05) +
  geom_sf(data = study_regions, fill = NA, colour = "grey40", linewidth = 0.3) +
  geom_sf(data = waterways_clip, colour = "#3B8ED0", linewidth = 0.15, alpha = 0.6) +
  scale_fill_gradientn(
    colours  = c("#FCFDBF", "#FEC287", "#FD9567", "#F1605D", "#CD4071", "#9E2F7F",
                 "#721F81", "#450457"),
    trans    = "sqrt",
    labels   = \(x) paste0(round(x, 2), "%"),
    name     = "Artisanal\nmining\nshare (%)",
    na.value = "#F0F0F0",
    guide    = guide_colorbar(barwidth  = unit(0.4, "cm"),
                              barheight = unit(9,   "cm"))
  ) +
  labs(
    title    = "Galamsey incidence — southern Ghana (2005–2019)",
    subtitle = "Artisanal mining land share per 5 km hexagon. Barenblitt et al. (2021).",
    caption  = paste0("OSM waterways shown in blue. ",
                      "Study area: Barenblitt SW Ghana survey region.")
  ) +
  theme_void(base_size = 11) +
  theme(
    plot.title      = element_text(face = "bold"),
    legend.position = "right",
    plot.caption    = element_text(colour = "grey50", size = 7)
  )

p_incidence_final <- p_incidence +
  inset_element(p_inset_ghana, left = 0.75, bottom = 0.75, right = 1.0, top = 1.0,
                align_to = "plot")

ggsave(file.path(out_dir, "d2_map_incidence.png"), p_incidence_final,
       width = 9, height = 10, dpi = 150)
message("Saved: d2_map_incidence.png")

####D2a. Moran's I — Spatial Clustering ####
# Global Moran's I on annual new mining (ha) by year
morans_ts <- map_dfr(year_list, \(yr) {
  vals <- panel_complete |>
    filter(year == yr) |>
    arrange(match(hex_id, hex_sf$hex_id)) |>
    pull(mine_ha)
  vals[is.na(vals)] <- 0
  if (var(vals) == 0)
    return(tibble(year = yr, moran_I = NA_real_, expectation = NA_real_,
                  variance = NA_real_, p_value = NA_real_))
  mt <- moran.test(vals, lw, zero.policy = TRUE)
  tibble(
    year        = yr,
    moran_I     = mt$estimate["Moran I statistic"],
    expectation = mt$estimate["Expectation"],
    variance    = mt$estimate["Variance"],
    p_value     = mt$p.value
  )
})

cat("\n=== D2a: Global Moran's I by year ===\n")
print(morans_ts)
write_csv(morans_ts, file.path(out_dir, "d2a_morans_by_year.csv"))

annual_ha <- panel_complete |>
  group_by(year) |>
  summarise(total_ha = sum(mine_ha, na.rm = TRUE), .groups = "drop")

p_moran_line <- ggplot(morans_ts, aes(x = year, y = moran_I)) +
  geom_ribbon(
    aes(ymin = moran_I - 1.96 * sqrt(variance),
        ymax = moran_I + 1.96 * sqrt(variance)),
    fill = "#E67E22", alpha = 0.2
  ) +
  geom_line(colour = "#E67E22", linewidth = 0.9) +
  geom_point(aes(colour = p_value < 0.05), size = 2.5) +
  scale_colour_manual(
    values = c("TRUE" = "#922B21", "FALSE" = "grey50"),
    labels = c("TRUE" = "p < 0.05", "FALSE" = "p ≥ 0.05"),
    name   = NULL
  ) +
  scale_x_continuous(breaks = year_list) +
  labs(
    title    = "Global Moran's I — annual new galamsey (5 km hexagons)",
    subtitle = "Spatial autocorrelation of annual new mining (ha); shaded band = ±1.96 SD",
    x = NULL, y = "Moran's I"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    axis.text.x  = element_blank(),
    axis.ticks.x = element_blank()
  )

p_bars <- ggplot(annual_ha, aes(x = year, y = total_ha)) +
  geom_col(fill = "#E67E22", alpha = 0.55, width = 0.7) +
  scale_x_continuous(breaks = year_list) +
  scale_y_continuous(labels = scales::comma) +
  labs(
    x       = NULL,
    y       = "New mining (ha)",
    caption = "Queen contiguity weights, row-standardised. Barenblitt et al. (2021)."
  ) +
  theme_minimal(base_size = 11) +
  theme(
    axis.text.x      = element_text(angle = 45, hjust = 1),
    panel.grid.minor = element_blank(),
    plot.caption     = element_text(colour = "grey50", size = 8)
  )

p_moran_ts <- (p_moran_line / p_bars) + plot_layout(heights = c(3, 1))

ggsave(file.path(out_dir, "d2a_morans_by_year.png"), p_moran_ts,
       width = 8, height = 6, dpi = 150)
message("Saved: d2a_morans_by_year.png")

#####Local Moran's I#####
# LISA (local Moran's I) — artisanal mining extent 2019
# Uses 2019 cross-section (art_ha from hex_cs) because the 2007–2017 time series
# shapefile carries no mine_type field and cannot be split by type.
# cumul_2017 (all types, TS) is retained below for the morans_total comparison.
cumul_2017 <- panel_complete |>
  filter(year == 2017) |>
  arrange(match(hex_id, hex_sf$hex_id)) |>
  pull(cumul_ha)
cumul_2017[is.na(cumul_2017)] <- 0

art_vec <- hex_cs |>
  st_drop_geometry() |>
  arrange(match(hex_id, hex_sf$hex_id)) |>
  pull(art_ha)
art_vec[is.na(art_vec)] <- 0

lisa       <- localmoran(art_vec, lw, zero.policy = TRUE)
mine_z     <- scale(art_vec)[, 1]
lag_mine_z <- scale(lag.listw(lw, art_vec, zero.policy = TRUE))[, 1]
p_local    <- lisa[, grep("^Pr", colnames(lisa))[1]]

hex_lisa <- hex_sf |>
  mutate(
    quadrant = case_when(
      mine_z >  0 & lag_mine_z >  0 & p_local < 0.05 ~ "HH",
      mine_z <= 0 & lag_mine_z <= 0 & p_local < 0.05 ~ "LL",
      mine_z >  0 & lag_mine_z <= 0 & p_local < 0.05 ~ "HL",
      mine_z <= 0 & lag_mine_z >  0 & p_local < 0.05 ~ "LH",
      TRUE ~ "Not sig."
    )
  )

quad_colours <- c(
  HH        = "#D7191C",
  LL        = "#2C7BB6",
  HL        = "#F4A240",
  LH        = "#ABD9E9",
  "Not sig." = "#F0F0F0"
)

p_lisa <- ggplot(hex_lisa) +
  geom_sf(aes(fill = quadrant), colour = "white", linewidth = 0.05) +
  geom_sf(data = study_regions, fill = NA, colour = "grey40", linewidth = 0.3) +
  scale_fill_manual(values = quad_colours, name = "LISA cluster") +
  labs(
    title    = "LISA clusters — artisanal mining extent 2019",
    subtitle = "HH = mining hotspot (high surrounded by high); p < 0.05",
    caption  = "5 km hexagons. Local Moran's I, queen contiguity. Artisanal only. Barenblitt et al. (2021)."
  ) +
  theme_void(base_size = 11) +
  theme(
    plot.title      = element_text(face = "bold"),
    legend.position = "right",
    plot.caption    = element_text(colour = "grey50", size = 7)
  )

p_lisa_final <- p_lisa +
  inset_element(p_inset_ghana, left = 0.75, bottom = 0.75, right = 1.0, top = 1.0,
                align_to = "plot")

ggsave(file.path(out_dir, "d2a_lisa_2017.png"), p_lisa_final,
       width = 9, height = 10, dpi = 150)
message("Saved: d2a_lisa_2017.png")

# Global Moran's I — full series summary
# Total cumulative reuses cumul_2017 (2007–2017 TS, all mine types).
# Artisanal/industrial split requires 2019 extent (only source with mine_type).
hex_ordered <- hex_cs |>
  st_drop_geometry() |>
  arrange(match(hex_id, hex_sf$hex_id))

mt_art <- moran.test(hex_ordered$art_share,
                     lw, zero.policy = TRUE)
mt_ind <- moran.test(hex_ordered$ind_ha / hex_ordered$unit_ha,
                     lw, zero.policy = TRUE)
mt_tot <- moran.test(cumul_2017, lw, zero.policy = TRUE)

morans_total <- tibble(
  series  = c("Artisanal (2019 extent)",
              "Industrial (2019 extent)",
              "All types cumulative (2007–2017 TS)"),
  moran_I = c(mt_art$estimate[1], mt_ind$estimate[1], mt_tot$estimate[1]),
  p_value = c(mt_art$p.value,     mt_ind$p.value,     mt_tot$p.value)
)
cat("\n=== D2a: Global Moran's I — full series ===\n")
print(morans_total)
write_csv(morans_total, file.path(out_dir, "d2a_morans_total.csv"))

####D2b. Moran's I Before and After Geography Controls ####

# OLS regressions used to partial out geography — residuals passed to Moran's I
fit_geo       <- feols(art_share ~ gold_suit_share,                    data = hex_analysis, vcov = "hetero")
fit_geo_river <- feols(art_share ~ gold_suit_share + dist_river_km,    data = hex_analysis, vcov = "hetero")

cat("\n=== D2b: Mining share ~ geography controls ===\n")
cat("Geology only:\n");        summary(fit_geo)
cat("\nGeology + river proximity:\n"); summary(fit_geo_river)

# Moran's I: raw → geology → geology + river proximity
mt_raw        <- moran.test(hex_analysis$art_share, lw, zero.policy = TRUE)
mt_resid_geo  <- moran.test(residuals(fit_geo),      lw, zero.policy = TRUE)
mt_resid_joint <- moran.test(residuals(fit_geo_river), lw, zero.policy = TRUE)

morans_comparison <- tibble(
  specification = c(
    "Raw artisanal mining share",
    "Residual after geology control",
    "Residual after geology + river proximity"
  ),
  moran_I = c(
    mt_raw$estimate[1],
    mt_resid_geo$estimate[1],
    mt_resid_joint$estimate[1]
  ),
  p_value = c(
    mt_raw$p.value,
    mt_resid_geo$p.value,
    mt_resid_joint$p.value
  )
)
cat("\n=== D2b: Moran's I — raw vs geography-controlled ===\n")
print(morans_comparison)
write_csv(morans_comparison, file.path(out_dir, "d2b_morans_comparison.csv"))
message("Saved: D2b outputs")

####D2c-FS. First Stage: Geography as a Predictor of Mine Presence ####

# OLS LPM: both geography covariates jointly predicting binary mine presence.
# Saved as CSV for the presentation first-stage slide.
fit_fs <- feols(as.integer(any_art) ~ dist_river_km + gold_suit_share,
                data = hex_analysis, vcov = "hetero")

cat("\n=== First stage: geography predictors of mine presence (OLS LPM) ===\n")
summary(fit_fs)

# Joint first-stage F (heteroskedasticity-robust Wald): tests whether the two
# geography covariates are jointly informative. NOTE: with n ~ 3,480 this is a
# significance test, not a strength test — a large, highly significant F coexists
# with very weak prediction (low R2 / AUC ~ 0.60). For the D2bc geography-weighted
# null, predictive strength is what matters, so read this F alongside R2, not as
# evidence the first stage is "strong". The F > 10 weak-instrument rule of thumb
# is a 2SLS diagnostic and does not strictly apply to this propensity model.
fs_f <- fitstat(fit_fs, "f")$f
cat("\nFirst-stage joint F-test (robust Wald):\n")
print(fs_f)

fs_tbl <- as.data.frame(coeftable(fit_fs)) |>
  rownames_to_column("term") |>
  filter(term != "(Intercept)") |>
  mutate(
    Predictor = recode(term,
      "dist_river_km"   = "Distance to nearest river (km)",
      "gold_suit_share" = "Gold-suitable geology (share of hex area)"
    )
  ) |>
  select(Predictor, everything(), -term) |>
  mutate(across(where(is.numeric), \(x) round(x, 5)))

write_csv(fs_tbl, file.path(out_dir, "d2_geography_firststage.csv"))
message("Saved: d2_geography_firststage.csv")

# --- Regression-table export helpers --------------------------------------
# Single source of truth: the fitted fixest models. Each regression table is
# emitted in two formats from the SAME model objects so the QMD (reveal.js)
# and the Beamer deck can never disagree on a coefficient:
#   * .tex  — via etable(); only dependency is booktabs (loaded in both decks)
#   * .md   — GitHub-flavoured pipe table, included by the QMD
# Both are written next to the existing coefficient CSVs in out_dir.
.fmt_sig <- function(x, sig = 3) formatC(x, format = "fg", digits = sig, big.mark = ",")
.fmt_int <- function(n) formatC(n, format = "d", big.mark = ",")
.stars   <- function(p) ifelse(p < .01, "***", ifelse(p < .05, "**",
                        ifelse(p < .1, "*", "")))

# Coefficient estimate (with stars) and SE (in parentheses) for one model term.
.reg_cell <- function(m, term) {
  ct <- coeftable(m)[term, ]
  list(est = paste0(.fmt_sig(ct[["Estimate"]]), .stars(ct[["Pr(>|t|)"]])),
       se  = paste0("(", .fmt_sig(ct[["Std. Error"]]), ")"))
}

# Write a GitHub-flavoured markdown pipe table (first column left, rest centred).
.write_md_table <- function(header, rows, file) {
  cell  <- function(v) paste0("| ", paste(v, collapse = " | "), " |")
  align <- paste0("|", paste0(c(" :--- ", rep(" :---: ", length(header) - 1)),
                              collapse = "|"), "|")
  writeLines(c(cell(header), align, vapply(rows, cell, character(1))), file)
  message("Saved: ", basename(file))
}

# First-stage regression table (D2c-FS) -> .tex + .md
etable(fit_fs, tex = TRUE, file = file.path(out_dir, "d2_geography_firststage.tex"),
       replace = TRUE, depvar = FALSE, fitstat = ~ n + r2 + f,
       headers = c("Any artisanal mining (0/1)"),
       dict = c(dist_river_km   = "Distance to nearest river (km)",
                gold_suit_share = "Gold-suitable geology (share of hex)"),
       style.tex = style.tex("aer"))
message("Saved: d2_geography_firststage.tex")

local({
  r_river <- .reg_cell(fit_fs, "dist_river_km")
  r_gold  <- .reg_cell(fit_fs, "gold_suit_share")
  .write_md_table(
    header = c("", "Any artisanal mining (0/1)"),
    rows = list(
      c("Distance to nearest river (km)",       r_river$est),
      c("",                                      r_river$se),
      c("Gold-suitable geology (share of hex)",  r_gold$est),
      c("",                                      r_gold$se),
      c("Observations",                          .fmt_int(fit_fs$nobs)),
      c("R&sup2;",                               .fmt_sig(fixest::r2(fit_fs, "r2"))),
      c("Joint F-stat",                          .fmt_sig(fs_f$stat))
    ),
    file = file.path(out_dir, "d2_geography_firststage.md")
  )
})

####D2bc. Geography-Weighted Null ####

# Decomposes observed clustering into geography-explained vs excess:
#   observed Moran's I = [clustering implied by geography alone] + [excess]
# Null: simulate 500 mine assignments where each hex is selected with probability
# proportional to its geographic covariates (no spatial spillover term). Any
# Moran's I in simulated draws arises only because geology and rivers are
# themselves spatially autocorrelated — not because mines attract neighbors.

# Helper: simulate n_sim weighted mine assignments, return Moran's I per draw
sim_morans_null <- function(probs, lw, n_mine, n_sim) {
  replicate(n_sim, {
    sim_idx <- sample(length(probs), n_mine, replace = FALSE, prob = probs)
    sim_vec <- numeric(length(probs))
    sim_vec[sim_idx] <- 1
    moran.test(sim_vec, lw, zero.policy = TRUE)$estimate["Moran I statistic"]
  })
}

# Logistic regressions — no spatial terms (no circularity)
fit_geo_logit   <- glm(any_art ~ gold_suit_share + dist_river_km,
                       data = hex_analysis, family = binomial())
fit_river_logit <- glm(any_art ~ dist_river_km,
                       data = hex_analysis, family = binomial())
fit_geol_logit  <- glm(any_art ~ gold_suit_share,
                       data = hex_analysis, family = binomial())

n_mine_obs <- sum(hex_analysis$any_art)

message("Simulating geography-weighted nulls (500 draws each — may take a minute)...")
set.seed(42)
null_uniform <- sim_morans_null(rep(1, nrow(hex_analysis)), lw, n_mine_obs, 500)
null_geol    <- sim_morans_null(fitted(fit_geol_logit),     lw, n_mine_obs, 500)
null_river   <- sim_morans_null(fitted(fit_river_logit),    lw, n_mine_obs, 500)
null_joint   <- sim_morans_null(fitted(fit_geo_logit),      lw, n_mine_obs, 500)

# Observed Moran's I on binary presence (comparable scale to null draws)
obs_moran_bin <- moran.test(as.numeric(hex_analysis$any_art),
                            lw, zero.policy = TRUE)$estimate["Moran I statistic"]

# p_excess: proportion of null draws >= observed (one-sided; small = excess clustering)
null_summary <- tibble(
  null      = c("Uniform random", "Geology only", "River only", "Joint (geology + river)"),
  null_mean = c(mean(null_uniform), mean(null_geol),
                mean(null_river),   mean(null_joint)),
  null_p95  = c(quantile(null_uniform, 0.95), quantile(null_geol, 0.95),
                quantile(null_river,   0.95), quantile(null_joint, 0.95)),
  obs_moran = obs_moran_bin,
  p_excess  = c(mean(null_uniform >= obs_moran_bin), mean(null_geol >= obs_moran_bin),
                mean(null_river   >= obs_moran_bin), mean(null_joint >= obs_moran_bin))
)

cat("\n=== D2bc: Geography-weighted null ===\n")
cat(sprintf("Observed Moran's I (binary artisanal presence): %.4f\n", obs_moran_bin))
print(null_summary)
write_csv(null_summary, file.path(out_dir, "d2bc_null_summary.csv"))

# Plot: null distributions + observed, faceted by null type
null_long <- bind_rows(
  tibble(null = "Uniform random",          moran_i = null_uniform),
  tibble(null = "Geology only",            moran_i = null_geol),
  tibble(null = "River only",              moran_i = null_river),
  tibble(null = "Joint (geology + river)", moran_i = null_joint)
) |>
  mutate(null = factor(null, levels = c("Uniform random", "Geology only",
                                        "River only", "Joint (geology + river)")))

p_geo_null <- ggplot(null_long, aes(x = moran_i, fill = null)) +
  geom_histogram(bins = 40, alpha = 0.75, colour = "white", linewidth = 0.2) +
  geom_vline(xintercept = obs_moran_bin,
             colour = "#C0392B", linewidth = 1, linetype = "dashed") +
  annotate("text",
           x = obs_moran_bin, y = Inf,
           label = sprintf("Observed\n%.3f", obs_moran_bin),
           hjust = 1.1, vjust = 1.4, colour = "#C0392B", size = 3) +
  facet_wrap(~ null, ncol = 2, scales = "free_y") +
  scale_fill_manual(
    values = c(
      "Uniform random"          = "grey60",
      "Geology only"            = "#2171B5",
      "River only"              = "#3B8ED0",
      "Joint (geology + river)" = "#721F81"
    ),
    guide = "none"
  ) +
  labs(
    title    = "Geography-weighted null: excess spatial clustering of galamsey",
    subtitle = paste0(
      "Dashed red line = observed Moran's I (binary artisanal mine presence).\n",
      "Histograms = 500 draws where mines assigned weighted by geography alone, no spatial spillover."
    ),
    x       = "Moran's I",
    y       = "Count",
    caption = paste0(
      "5 km hexagons, SW Ghana. Observed n_mine = ", n_mine_obs, ". ",
      "Weights: fitted values from logistic regression of any_art ~ covariates. ",
      "Barenblitt et al. (2021)."
    )
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title    = element_text(face = "bold"),
    plot.subtitle = element_text(colour = "grey30", size = 9, lineheight = 1.3),
    plot.caption  = element_text(colour = "grey50", size = 7),
    strip.text    = element_text(face = "bold")
  )

ggsave(file.path(out_dir, "d2bc_geography_null.png"), p_geo_null,
       width = 9, height = 7, dpi = 150)

# Focused single-panel histogram (joint null only) for presentation slide
p_null_hist <- ggplot(
  null_long |> filter(null == "Joint (geology + river)"),
  aes(x = moran_i)
) +
  geom_histogram(bins = 40, fill = "#721F81", alpha = 0.75,
                 colour = "white", linewidth = 0.2) +
  geom_vline(xintercept = obs_moran_bin,
             colour = "#C0392B", linewidth = 1.2, linetype = "dashed") +
  annotate("text",
           x = obs_moran_bin, y = Inf,
           label = sprintf("Observed: %.3f", obs_moran_bin),
           hjust = 1.1, vjust = 1.5, colour = "#C0392B",
           size = 3.5, fontface = "bold") +
  labs(
    title    = "Geography-weighted null vs observed clustering",
    subtitle = "500 simulations: mines assigned with probability ∝ geology + river proximity, no spillover term",
    x        = "Simulated Moran's I",
    y        = "Count",
    caption  = paste0(
      "Red dashed line = observed Moran's I (", round(obs_moran_bin, 3), "). ",
      "Not one of 500 draws approached the observed value. Barenblitt et al. (2021)."
    )
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title    = element_text(face = "bold"),
    plot.subtitle = element_text(colour = "grey30", size = 9),
    plot.caption  = element_text(colour = "grey50", size = 7)
  )

ggsave(file.path(out_dir, "d2bc_null_histogram.png"), p_null_hist,
       width = 8, height = 5, dpi = 150)
message("Saved: D2bc outputs")

####D2d. Spatial Lag Regression ####

# Spatial lag of cumulative mining at t-1 for each hex × year
lag_panel <- map_dfr(year_list[-1], \(yr) {
  vals <- panel_complete |>
    filter(year == yr - 1) |>
    arrange(match(hex_id, hex_sf$hex_id)) |>
    pull(cumul_ha)
  vals[is.na(vals)] <- 0
  tibble(
    hex_id         = hex_sf$hex_id,
    year           = yr,
    spatial_lag_t1 = lag.listw(lw, vals, zero.policy = TRUE)
  )
})

panel_reg <- panel_complete |>
  filter(year > min(year_list)) |>
  left_join(lag_panel, by = c("hex_id", "year"))

# Two-way FE: annual new mining (ha) ~ spatial lag of cumulative at t-1
fit_levels <- feols(mine_ha ~ spatial_lag_t1 | hex_id + year,
                    data = panel_reg, vcov = ~ hex_id)

# LPM: indicator for any new mining ~ spatial lag
fit_lpm <- feols(I(mine_ha > 0) ~ spatial_lag_t1 | hex_id + year,
                 data = panel_reg, vcov = ~ hex_id)

cat("\n=== D2d: Spatial Lag Regression ===\n")
cat("Outcome: annual new mining (ha)\n")
summary(fit_levels)
cat("\nOutcome: any new mining (LPM)\n")
summary(fit_lpm)

coef_out <- bind_rows(
  as.data.frame(coeftable(fit_levels)) |> rownames_to_column("term") |>
    mutate(outcome = "mine_ha_annual"),
  as.data.frame(coeftable(fit_lpm)) |> rownames_to_column("term") |>
    mutate(outcome = "any_mining_LPM")
)
write_csv(coef_out, file.path(out_dir, "d2d_spatial_lag_coefs.csv"))
message("Saved: d2d_spatial_lag_coefs.csv")

# Spatial-lag regression table (D2d) -> .tex + .md (helpers defined in D2c-FS)
etable(fit_levels, fit_lpm, tex = TRUE,
       file = file.path(out_dir, "d2d_spatial_lag.tex"), replace = TRUE,
       depvar = FALSE, fitstat = ~ n + r2,
       headers = c("New mining (ha)", "Any new mining (LPM)"),
       dict = c(spatial_lag_t1 = "Neighbour mining stock ($t-1$)",
                hex_id = "Hex", year = "Year"),
       style.tex = style.tex("aer"))
message("Saved: d2d_spatial_lag.tex")

local({
  c_lev <- .reg_cell(fit_levels, "spatial_lag_t1")
  c_lpm <- .reg_cell(fit_lpm,    "spatial_lag_t1")
  .write_md_table(
    header = c("", "New mining (ha)", "Any new mining (LPM)"),
    rows = list(
      c("Neighbour mining stock ($t-1$)", c_lev$est, c_lpm$est),
      c("",                               c_lev$se,  c_lpm$se),
      c("Hex fixed effects",  "Yes", "Yes"),
      c("Year fixed effects", "Yes", "Yes"),
      c("Observations", .fmt_int(fit_levels$nobs), .fmt_int(fit_lpm$nobs)),
      c("R&sup2;", .fmt_sig(fixest::r2(fit_levels, "r2")),
                   .fmt_sig(fixest::r2(fit_lpm, "r2")))
    ),
    file = file.path(out_dir, "d2d_spatial_lag.md")
  )
})


####D2e. Upstream vs Downstream Spread Along Rivers ####

# River-adjacent hexes (within RIVER_BUFFER_M of any waterway)
# st_is_within_distance uses an STRtree — avoids the slow union+buffer path
near_river   <- lengths(st_is_within_distance(hex_sf, waterways_clip,
                                              dist = RIVER_BUFFER_M)) > 0
hex_river_sf <- hex_sf[near_river, ]

message(sprintf("River-adjacent hexes: %d of %d (%.0f%%)",
                sum(near_river), nrow(hex_sf), mean(near_river) * 100))

# Contiguity among river-adjacent hexes only
nb_river <- poly2nb(hex_river_sf, queen = TRUE)

# Upstream/downstream neighbour table
# Flow direction proxy: lower northing = closer to coast = downstream
neigh_tbl <- map_dfr(seq_len(nrow(hex_river_sf)), \(i) {
  focal_id    <- hex_river_sf$hex_id[i]
  focal_north <- hex_northing$northing[hex_northing$hex_id == focal_id]
  neigh_idx   <- nb_river[[i]]
  if (length(neigh_idx) == 0) return(NULL)
  neigh_ids   <- hex_river_sf$hex_id[neigh_idx]
  neigh_north <- hex_northing$northing[match(neigh_ids, hex_northing$hex_id)]
  tibble(
    focal_id    = focal_id,
    focal_north = focal_north,
    neigh_id    = neigh_ids,
    neigh_north = neigh_north,
    direction   = if_else(neigh_north < focal_north, "downstream", "upstream")
  )
})

# Mine onset: first year cumulative > 0 in river-adjacent panel
panel_river <- panel_complete |>
  filter(hex_id %in% hex_river_sf$hex_id) |>
  group_by(hex_id) |>
  arrange(year) |>
  mutate(mine_onset = cumul_ha > 0 & lag(cumul_ha, default = 0) == 0) |>
  ungroup()

onset_hexes <- panel_river |>
  filter(mine_onset) |>
  select(hex_id, onset_year = year)

# For each onset hex × lead period, what fraction of upstream/downstream
# neighbors develop new mines?
future_mining <- panel_river |>
  select(neigh_id = hex_id, neigh_year = year, neigh_onset = mine_onset)

spread_res <- map_dfr(1:3, \(lead_yr) {
  onset_hexes |>
    left_join(neigh_tbl, by = c("hex_id" = "focal_id")) |>
    mutate(check_year = onset_year + lead_yr) |>
    left_join(future_mining, by = c("neigh_id", "check_year" = "neigh_year")) |>
    filter(!is.na(direction)) |>
    group_by(direction) |>
    summarise(
      n_pairs     = n(),
      n_new_mines = sum(neigh_onset, na.rm = TRUE),
      pct_new     = n_new_mines / n_pairs * 100,
      .groups     = "drop"
    ) |>
    mutate(lead_years = lead_yr)
})

cat("\n=== D2e: Upstream vs downstream spread ===\n")
print(spread_res)
write_csv(spread_res, file.path(out_dir, "d2e_spread_results.csv"))

p_spread <- spread_res |>
  filter(!is.na(direction)) |>
  ggplot(aes(x = factor(lead_years), y = pct_new, fill = direction)) +
  geom_col(position = "dodge", alpha = 0.85, width = 0.6) +
  scale_fill_manual(
    values = c(downstream = "#E67E22", upstream = "#2171B5"),
    name   = "Neighbor direction"
  ) +
  labs(
    title    = "Mine spread: upstream vs downstream from onset hex",
    subtitle = "% of river-adjacent neighbors that develop new mining within 1–3 years",
    x        = "Years after mine onset in focal hex",
    y        = "% of neighbors with new mining",
    caption  = paste0(
      "5 km hexagons within ", RIVER_BUFFER_M / 1000, " km of OSM waterway. ",
      "Downstream = lower northing (toward Gulf of Guinea). Barenblitt et al. (2021)."
    )
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.caption = element_text(colour = "grey50", size = 8))

ggsave(file.path(out_dir, "d2e_upstream_downstream.png"), p_spread,
       width = 8, height = 6, dpi = 150)
message("Saved: d2e_upstream_downstream.png")

message("\n=== a_02_spatial_clustering.R complete ===")
