# validate_site_timeseries.R
# Parameterized site inspector for build_02_embedding_classifier.R's c4 mine-probability
# output: pulls probability rasters directly from the EE assets for a chosen AOI and produces
# (1) a before/after map panel and (2) a probability TIME SERIES across all exported years --
# the temporal-consistency QA check flagged when we first discussed how to assess the
# classifier's quality (does a pixel/AOI's probability move the way real mining should -- rise
# on entry, stay high once established, not flicker noise year to year?).
#
# 2026-09-03: repointed to the TILED c4 export. build_02 Section 10 writes one asset per
# (year, tile) -- mine_prob_ghana_c4_{yr}_t{NN}, NOT a single per-year image -- so mine_prob_img()
# below mosaics each year's tiles. PROB_THRESHOLD 90 -> 45 (settled 2026-08-18).
#
# Replaces validate_awomaso_case_study.R (2026-08-05): that script read one-off, manually
# exported rasters for exactly 3 years (2017/2021/2024) from data/raw/awomaso_figure/; this
# reads all 9 years directly from EE for ANY site, so it generalizes beyond Awomaso and needs
# no manual export step. data/raw/awomaso_figure/ is left in place (untouched), just no longer
# read by anything -- delete it separately if it's confirmed redundant after this script is
# verified working.
#
# Run INTERACTIVELY: ee_Authenticate()/ee_Initialize() block on a browser login.
# Prerequisite: build_02_embedding_classifier.R Section 10 has exported mine_prob_ghana_c4_{yr}_t*
# tiles for the years in YEARS below (validate_gee_assets.R confirms completeness).
#
# NOTE: written 2026-08-05 without an interactive rgee session to test against -- the
# reduceRegion() band-name suffixes (Section 3) and ee_as_rast() calls (Section 4) follow
# standard EE/rgee conventions but have not been run end-to-end. Debug interactively before
# trusting the output; Section 3 (time series) is the higher-value, lower-risk half -- if
# Section 4 (map panel) breaks, the time series still stands alone.
#
# Outputs: outputs/figures/site_timeseries/{site}_probability_timeseries.png
#          outputs/figures/site_timeseries/{site}_map_panel.png

####1. Environment + auth ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, googledrive, sf, terra, here, tidyverse, scales, tmap, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff,
  here::here
)
UTM30N <- 32630
EE_PROJECT <- "rgee-auth-tillam"   # see build_02_embedding_classifier.R Section 1 for why this
                                   # must be the alphanumeric project ID, not the project number

rgee::ee_Authenticate()
rgee::ee_Initialize(drive = TRUE, project = EE_PROJECT)
ee_check()
googledrive::drive_auth()   # needed for ee_as_rast(..., via = "drive") in Section 4

EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)

# The c4 national probability map is exported TILED (build_02 Section 10): one asset per
# (year, tile), mine_prob_ghana_c4_{yr}_t{NN}. No single per-year image exists, so mosaic the
# year's tiles here (same pattern as build_03_embedding_panel.R's year_mosaic()).
PROB_PREFIX  <- "mine_prob_ghana_c4_"
TILE_IDS     <- sprintf("t%02d", 1:20)   # generous upper bound; only tiles that exist are used
asset_exists <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)

mine_prob_img <- function(yr) {
  ids <- file.path(EE_ASSET_HOME, sprintf("%s%d_%s", PROB_PREFIX, yr, TILE_IDS))
  ids <- Filter(asset_exists, ids)
  if (length(ids) == 0)
    stop(sprintf("no %s%d_t* tiles found -- has build_02 Section 10 run for %d?", PROB_PREFIX, yr, yr))
  ee$ImageCollection(lapply(ids, ee$Image))$mosaic()$rename("mine_prob")
}

####2. Parameters -- site presets + AOI builder ####
# Add new sites here as a centre (UTM30N metres) + half-width; anything inspected manually
# before (e.g. the old Awomaso figure) should get a preset so it stays reproducible. Awomaso's
# coordinates below match the old script's zoom-box centre (612500-621500 E, 667000-673000 N).
SITES <- list(
  awomaso = list(x = 617000, y = 670000, halfwidth_km = 4.5)
)
SITE           <- "awomaso"
YEARS          <- 2017:2025
PROB_THRESHOLD <- 45                       # uint8 percent; settled cutoff (2026-08-18,
                                            # project_4class_urban_confusion). See diag_02_scoring.R
                                            # for where it sits on the PR/ROC curve.
MAP_YEARS      <- c(min(YEARS), max(YEARS))   # which years get a map panel (each is a download -- keep small)

fig_dir <- here("outputs", "figures", "site_timeseries")
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

site    <- SITES[[SITE]]
aoi_utm <- st_sfc(st_point(c(site$x, site$y)), crs = UTM30N) |>
  st_buffer(site$halfwidth_km * 1000, endCapStyle = "SQUARE")
aoi_ee  <- aoi_utm |> st_transform(4326) |> sf_as_ee()

####3. Time series -- mean / max / %-area-above-threshold, all years ####
# The plausibility check: a flat/near-zero series before real onset, a rise, then a plateau is
# the expected shape for an established mine. A large single-year spike with no persistence the
# following year is the "flicker" pattern that would flag a temporal-consistency problem.

message(sprintf("=== Extracting probability time series for '%s' (%d-%d) ===", SITE, min(YEARS), max(YEARS)))

ts_df <- map_dfr(YEARS, function(yr) {
  img <- mine_prob_img(yr)$clip(aoi_ee)
  stats <- img$reduceRegion(
    reducer   = ee$Reducer$mean()$combine(ee$Reducer$max(), sharedInputs = TRUE),
    geometry  = aoi_ee,
    scale     = 10,
    maxPixels = 1e9
  )$getInfo()
  above <- img$gte(PROB_THRESHOLD)$reduceRegion(
    reducer   = ee$Reducer$mean(),
    geometry  = aoi_ee,
    scale     = 10,
    maxPixels = 1e9
  )$getInfo()
  tibble(year = yr,
         mean_prob   = stats$mine_prob_mean,
         max_prob    = stats$mine_prob_max,
         pct_area_ge = 100 * above$mine_prob)
})
print(ts_df)

p_ts <- ggplot(ts_df, aes(year)) +
  geom_col(aes(y = pct_area_ge), fill = "#D94701", alpha = 0.7) +
  geom_line(aes(y = mean_prob), colour = "#450457", linewidth = 1) +
  geom_point(aes(y = mean_prob), colour = "#450457", size = 2) +
  scale_x_continuous(breaks = YEARS) +
  labs(title = sprintf("Mine-probability time series — %s", SITE),
       subtitle = sprintf("Bars = %% of AOI pixels ≥ %d%% probability; line = mean AOI probability",
                          PROB_THRESHOLD),
       x = NULL, y = "Mean probability / % area above threshold") +
  theme_bw(base_size = 11)
ggsave(file.path(fig_dir, sprintf("%s_probability_timeseries.png", SITE)), p_ts, width = 8, height = 5, dpi = 150)

####4. Map panel -- footprint at MAP_YEARS, downloaded directly from the AOI clip ####

message(sprintf("=== Downloading probability rasters + S2 basemap for map panel (%s) ===",
                paste(MAP_YEARS, collapse = ", ")))

s2_composite <- function(yr) {
  ee$ImageCollection("COPERNICUS/S2_SR_HARMONIZED")$
    filterBounds(aoi_ee)$
    filterDate(sprintf("%d-01-01", yr), sprintf("%d-12-31", yr))$
    filter(ee$Filter$lt("CLOUDY_PIXEL_PERCENTAGE", 40))$
    map(function(img) img$updateMask(img$select("SCL")$neq(3)$And(img$select("SCL")$neq(9))))$
    median()$
    select(c("B4", "B3", "B2"))$
    clip(aoi_ee)
}

prob_masks <- map(MAP_YEARS, function(yr) {
  ee_as_rast(mine_prob_img(yr)$clip(aoi_ee), region = aoi_ee, scale = 10, via = "drive")
}) |> set_names(as.character(MAP_YEARS))

basemap <- ee_as_rast(s2_composite(max(MAP_YEARS)), region = aoi_ee, scale = 10, via = "drive")

to_poly <- function(prob_rast, thr = PROB_THRESHOLD, min_px = 10) {
  (prob_rast >= thr) |>
    terra::sieve(threshold = min_px) |>
    as.polygons() |>
    st_as_sf() |>
    filter(.data[[names(prob_rast)[1]]] == 1) |>
    st_union() |> st_as_sf()
}
footprints <- map(prob_masks, to_poly)

# draw MOST RECENT year first (bottom), OLDEST last (top): visible colour = first-mined year,
# generalising the 2-year Awomaso original to however many years are in MAP_YEARS
cols  <- setNames(colorRampPalette(c("#8b5a9e", "#e6122e"))(length(MAP_YEARS)), as.character(MAP_YEARS))
panel <- tm_shape(basemap) + tm_rgb()
for (yr in rev(as.character(MAP_YEARS))) {
  panel <- panel + tm_shape(footprints[[yr]]) + tm_fill(fill = cols[[yr]], fill_alpha = 0.85)
}
panel <- panel +
  tm_graticules(lines = FALSE) +
  tm_compass(position = c("right", "top")) +
  tm_scalebar(position = c("right", "bottom")) +
  tm_add_legend(fill = unname(cols), labels = names(cols)) +
  tm_layout(legend.position = c("left", "bottom"),
            title = sprintf("%s — mining footprint, %s vs %s (≥ %d%% probability)",
                            SITE, min(MAP_YEARS), max(MAP_YEARS), PROB_THRESHOLD))

tmap_save(panel, file.path(fig_dir, sprintf("%s_map_panel.png", SITE)), width = 10, height = 8, units = "in", dpi = 300)

message("\n=== validate_site_timeseries.R complete ===")
