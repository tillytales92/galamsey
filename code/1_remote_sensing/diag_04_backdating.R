# diag_04_backdating.R (was diag_06_backdating_results.R; replaced the old diag_04 grab-bag on 2026-11-13) -- SKETCH, NOT YET RUN (2026-11-13)
#
# Everything diag_04_backdating_report.Rmd needs from the deployed onset asset, in one run:
#   (a) Section 2b: a by-year summary of the whole asset (area per onset year, LandTrendr agreement,
#       start vegetation, loss size, computable years; inside vs outside the Barenblitt hull)
#       -> outputs/tables/backdating/onset_summary_2000_2017.csv, barenblitt_yearly_area.csv
#   (a2) Section 2c: classifier-era area 2017-2025 from build_03's masks (yearly stock + first-detected
#       new area), to join onto the backdated series -> classifier_era_area_2017_2025.csv
#   (b) Sections 3-7: the example-pixel figure below.
#
# (b) illustrates how the deployed Barenblitt-replica backdating works, on a handful of real pixels.
# Per pixel, 1998-2018: every clear Landsat NDVI observation, the annual max, its 3yr centred moving
# average, and the year-on-year loss in that average (the winning year = onset). LandTrendr's year
# and Barenblitt's classifica year (+1, our label convention) are marked for comparison.
#
# Pixels are picked from the deployed asset by category (2026-11-16: 5 categories, two figures, see
# Section 4): clean + gradual loss (method figure); one-year dip, bare at start, early vs Barenblitt
# et al. (weak-spots figure). Rule e is overlaid where it changes the series.
# The onset is recomputed here from the raw observations and checked against the asset's value
# ("recomputed_matches" in the CSV) -- a mismatch means this script and build_04 disagree, and the
# figure would then not show what the asset actually did.
#
# Interactive, except Section 2c, which submits one Drive table export and reads it on a later run.
# Output: outputs/figures/backdating/ndvi_timeseries_{method,weakspots}.png
#         outputs/tables/backdating/ndvi_timeseries_examples.csv (per pixel-year series)

#### 1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, here, tidyverse, sf, lubridate, patchwork, googledrive, conflicted)
conflicts_prefer(dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise, dplyr::lag, here::here)

EE_PROJECT    <- "rgee-auth-tillam"
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)

ee_Authenticate()
ee_Initialize(project = EE_PROJECT)

#### 2. Parameters (must match build_04_backdating.R) ####
ONSET_MIN <- 2000L; ONSET_MAX <- 2017L
IMG_START <- 1998L; IMG_END   <- 2018L
ONSET_ASSET <- file.path(EE_ASSET_HOME, sprintf("mine_onset_year_%d_%d_barenblitt", ONSET_MIN, ONSET_MAX))
N_PER_YEAR  <- 40L    # candidate pixels sampled per onset year
SEED        <- 7L

suppressMessages(sf_use_s2(FALSE))
conv <- st_read(here("data", "raw", "barenblitt", "MiningConversion_2007-2017Vec.shp"), quiet = TRUE) |>
  st_make_valid() |> st_zm(drop = TRUE) |> st_transform(4326) |>
  transmute(bar_year = 2000L + as.integer(classifica))
bar_hull_ee <- sf_as_ee(st_sf(geometry = st_convex_hull(st_combine(st_geometry(conv)))))$geometry()

#### 2b. By-year summary of the whole deployed asset (for the report's results section) ####
# One exact frequency histogram over the saved asset (cheap: no Landsat). Packed code per pixel:
#   in_hull*1e8 + onset_idx*1e6 + lt_agree*1e5 + start_class*1e4 + deriv_bin*100 + n_computable
#   onset_idx = onset_year - 1999 (0 = undatable); lt_agree 0/1/2, 9 -> 3 (undated);
#   start_class 0 = bare <0.4, 1 = 0.4-0.6, 2 = >=0.6, 3 = no data; deriv_bin = loss x1000 / 10, 0-49.
asset   <- ee$Image(ONSET_ASSET)
in_hull <- ee$Image$constant(0L)$paint(ee$FeatureCollection(list(ee$Feature(bar_hull_ee))), 1L)   # paint() needs a FeatureCollection
sn      <- asset$select("start_ndvi_x1000")
start_class <- ee$Image$constant(3L)$
  where(sn$neq(-9999)$And(sn$lt(400)), 0L)$
  where(sn$gte(400)$And(sn$lt(600)), 1L)$
  where(sn$gte(600), 2L)
onset   <- asset$select("onset_year")$toInt32()
code_s  <- in_hull$multiply(100000000L)$
  add(onset$subtract(1999L)$max(0L)$multiply(1000000L))$
  add(asset$select("lt_agree")$toInt32()$min(3L)$multiply(100000L))$
  add(start_class$multiply(10000L))$
  add(asset$select("ndvi_deriv_x1000")$max(0L)$min(499L)$divide(10L)$toInt32()$multiply(100L))$
  add(asset$select("n_computable_years")$toInt32())$
  updateMask(onset$mask())$rename("code")
ghana_bounds <- ee$FeatureCollection(file.path(EE_ASSET_HOME, "rs05_ghana"))$geometry()$bounds()
h <- code_s$reduceRegion(reducer = ee$Reducer$frequencyHistogram(), geometry = ghana_bounds, scale = 30L,
                         maxPixels = 1e11, tileScale = 8L)$getInfo()
summary_tbl <- tibble(code = as.numeric(names(h$code)), n_pixels = unlist(h$code)) |>
  mutate(region       = if_else(code %/% 1e8 == 1, "bar_hull", "outside"),
         onset_year   = if_else((code %/% 1e6) %% 100 == 0, 0, 1999 + (code %/% 1e6) %% 100),
         lt_agree     = c("agree", "disagree", "no_signal", "undated")[(code %/% 1e5) %% 10 + 1],
         start_class  = c("bare", "partly", "vegetated", "no_data")[(code %/% 1e4) %% 10 + 1],
         deriv_x1000  = ((code %/% 100) %% 100) * 10,
         n_computable = code %% 100) |>
  select(-code)
write_csv(summary_tbl, here("outputs", "tables", "backdating",
                            sprintf("onset_summary_%d_%d.csv", ONSET_MIN, ONSET_MAX)))
message("By-year summary written: ", round(sum(summary_tbl$n_pixels)), " pixels")

# Barenblitt's own new mining area per classifica year (for the report's expansion comparison)
conv |> st_transform(32630) |>
  mutate(area_km2 = as.numeric(st_area(geometry)) / 1e6) |>
  st_drop_geometry() |>
  group_by(bar_year) |> summarise(bar_km2 = sum(area_km2), .groups = "drop") |>
  write_csv(here("outputs", "tables", "backdating", "barenblitt_yearly_area.csv"))

#### 2c. Classifier era 2017-2025 from build_03's annual masks (to join onto the backdated series) ####
# Per 30 m pixel, a 9-bit flag: bit (yr - 2017) set if mined in mine_mask_ghana_c4_{yr}. One exact
# frequency histogram of in_hull*1000 + bits gives, for every year, both
#   stock_km2 = area flagged mined in that year's mask (not monotone: masks can flicker), and
#   new_km2   = area first flagged that year among pixels NOT mined in 2017 (same rule as the
#               ground-truth test), so backdated (to 2017) + new (2018+) is one continuous onset series.
# Same 10 m -> 30 m majority rule as build_04's anchor.
MASK_PREFIX <- "mine_mask_ghana_c4_"
CLS_YEARS   <- 2017:2025
mask30 <- function(yr) {
  id <- file.path(EE_ASSET_HOME, paste0(MASK_PREFIX, yr))
  ee$Image(id)$unmask(0)$setDefaultProjection(ee$Image(id)$projection())$
    reduceResolution(reducer = ee$Reducer$mean(), maxPixels = 64L)$
    reproject(ee$Projection("EPSG:32630")$atScale(30))$gte(0.5)$toInt32()
}
bits <- Reduce(function(acc, i) acc$add(mask30(CLS_YEARS[i])$multiply(as.integer(2^(i - 1)))),
               seq_along(CLS_YEARS)[-1], mask30(CLS_YEARS[1]))
code_c <- in_hull$toInt32()$multiply(1000L)$add(bits)$updateMask(bits$gt(0))$rename("code")
# Too heavy for an interactive getInfo (9 masks x reduceResolution over all Ghana: it hung for ~1 h on
# 2026-11-13). Runs as a Drive table export instead, one row per code. Re-run this section once the
# task shows COMPLETED: it then downloads and tabulates. Sections 3-7 do not depend on it.
CLS_EXPORT <- "diag_04_classifier_era_codes_2017_2025"
cls_raw    <- here("outputs", "tables", "backdating", paste0(CLS_EXPORT, ".csv"))
if (!file.exists(cls_raw)) {
  googledrive::drive_auth()
  fold <- googledrive::drive_find(pattern = "ghana_mining_gee_exports", type = "folder", n_max = 1)
  hit  <- if (nrow(fold)) googledrive::drive_ls(fold[1, ]) |> filter(name == paste0(CLS_EXPORT, ".csv")) else tibble()
  if (nrow(hit)) googledrive::drive_download(hit[1, ], path = cls_raw, overwrite = TRUE)
}
if (!file.exists(cls_raw)) {
  hist_d <- ee$Dictionary(code_c$reduceRegion(reducer = ee$Reducer$frequencyHistogram(), geometry = ghana_bounds,
                                              scale = 30L, crs = "EPSG:32630", maxPixels = 1e11,
                                              tileScale = 16L)$get("code"))
  hist_fc <- ee$FeatureCollection(hist_d$keys()$map(ee_utils_pyfunc(function(k)
    ee$Feature(NULL, list(code = k, n_pixels = hist_d$get(k))))))
  ee$batch$Export$table$toDrive(collection = hist_fc, description = CLS_EXPORT,
                                folder = "ghana_mining_gee_exports", fileFormat = "CSV",
                                selectors = list("code", "n_pixels"))$start()
  message("Section 2c: export '", CLS_EXPORT, "' submitted -- re-run this section when it shows COMPLETED.")
} else {
px <- read_csv(cls_raw, show_col_types = FALSE) |>
  transmute(code = as.numeric(code), n_pixels = as.numeric(n_pixels)) |>
  mutate(region = if_else(code %/% 1000 == 1, "bar_hull", "outside"), b = code %% 1000)
flag <- function(b, i) (b %/% 2^(i - 1)) %% 2 == 1
cls_tbl <- map_dfr(seq_along(CLS_YEARS), function(i) {
  earlier_none <- if (i == 1) rep(TRUE, nrow(px)) else
    Reduce(`&`, lapply(seq_len(i - 1), function(j) !flag(px$b, j)))
  px |> mutate(stock = flag(b, i), new = flag(b, i) & earlier_none) |>
    group_by(region) |>
    summarise(stock_km2 = sum(n_pixels[stock]) * 900 / 1e6, new_km2 = sum(n_pixels[new]) * 900 / 1e6, .groups = "drop") |>
    mutate(year = CLS_YEARS[i])
}) |> mutate(new_km2 = if_else(year == 2017L, NA_real_, new_km2))   # 2017 = the anchor, covered by backdating
write_csv(cls_tbl, here("outputs", "tables", "backdating", "classifier_era_area_2017_2025.csv"))
message("Classifier-era series written (2017 stock: ",
        round(sum(cls_tbl$stock_km2[cls_tbl$year == 2017])), " km2)")
}

#### 3. Candidate pixels: stratified by onset year, with every asset band ####
cand <- asset$stratifiedSample(numPoints = N_PER_YEAR, classBand = "onset_year", region = bar_hull_ee,
                               scale = 30L, seed = SEED, geometries = TRUE, tileScale = 4L) |>
  ee_as_sf(via = "getInfo")
hits <- st_intersects(cand, conv)
cand$bar_year <- map_int(hits, ~ if (length(.x)) min(conv$bar_year[.x]) else NA_integer_)
message(nrow(cand), " candidate pixels, ", sum(!is.na(cand$bar_year)), " with a Barenblitt et al. year")

#### 4. Pick one pixel per category (prefer pixels that also have a Barenblitt year) ####
# 2026-11-16: cut from 10 panels to 5, in two figures by purpose (FIG_GROUPS):
#   method (report 1.2): how the method works -- one clean and one gradual loss;
#   weak   (report 4):   the weak spots the text discusses -- one-year dip (the 2002 pile-up / rule e
#                        case, diag_06), bare at start (bare_pre2005 flag), dated early vs Barenblitt et al.
cats <- list(
  "Clean loss"    = quote(start_ndvi_x1000 >= 650 & ndvi_deriv_x1000 >= 200 & lt_agree == 0 & n_computable_years >= 12),
  "Gradual loss"  = quote(start_ndvi_x1000 >= 600 & between(ndvi_deriv_x1000, 60, 110) & lt_agree != 1),
  "One-year dip"  = quote(onset_year == 2002 & start_ndvi_x1000 >= 600),
  "Bare at start" = quote(start_ndvi_x1000 < 400 & onset_year > 0),
  # Fidelity test: 19% of points dated >= 4 yrs before Barenblitt et al. (+1). Onset >= 2008 keeps
  # the 2007 window-edge cases out.
  "Early vs Barenblitt et al." = quote(!is.na(bar_year) & onset_year >= 2008 & onset_year <= bar_year + 1L - 4L)
)
N_PICK <- c("One-year dip" = 4L)   # 4 candidates; Section 6 keeps the first with a real one-year V
FIG_GROUPS <- list(
  method = list(cats = c("Clean loss", "Gradual loss"), file = "ndvi_timeseries_method",
                title = "How the Barenblitt-replica method dates mining onset", show_e = FALSE),
  weak   = list(cats = c("One-year dip", "Bare at start", "Early vs Barenblitt et al."), file = "ndvi_timeseries_weakspots",
                title = "Weak spots of the Barenblitt-replica dating", show_e = TRUE)
)
set.seed(SEED)
picked <- imap_dfr(cats, function(cond, label) {
  pool <- cand |> filter(!!cond)
  if (nrow(pool) == 0) { message("no candidate for '", label, "' -- skipped"); return(NULL) }
  if (any(!is.na(pool$bar_year))) pool <- filter(pool, !is.na(bar_year))
  n <- min(nrow(pool), if (label %in% names(N_PICK)) N_PICK[[label]] else 1L)
  out <- slice_sample(pool, n = n)
  out |> mutate(category = if (n > 1) paste0(label, " #", seq_len(n)) else label)
})

#### 5. Raw clear NDVI observations per picked pixel (same masking/harmonisation as build_04) ####
maskL2 <- function(img) {
  qa    <- img$select("QA_PIXEL")
  clear <- qa$bitwiseAnd(bitwShiftL(1L, 1L))$eq(0)$
    And(qa$bitwiseAnd(bitwShiftL(1L, 3L))$eq(0))$
    And(qa$bitwiseAnd(bitwShiftL(1L, 4L))$eq(0))
  img$updateMask(clear)$updateMask(img$select("QA_RADSAT")$eq(0))
}
ROY <- list(RED = list(s = 0.9047, i = 0.0061), NIR = list(s = 0.8462, i = 0.0412))
ndvi_col <- function(id, bands, is_oli, geom) {
  ee$ImageCollection(id)$filterBounds(geom)$
    filterDate(sprintf("%d-01-01", IMG_START), sprintf("%d-01-01", IMG_END + 1L))$
    map(maskL2)$
    map(function(img) {
      sr <- img$select(bands, c("RED", "NIR"))$multiply(0.0000275)$add(-0.2)
      if (is_oli) sr <- sr$select("RED")$multiply(ROY$RED$s)$add(ROY$RED$i)$
        addBands(sr$select("NIR")$multiply(ROY$NIR$s)$add(ROY$NIR$i))
      # Decimal year as a band: getRegion's millisecond 'time' column overflows on its way into R on
      # Windows (32-bit long) and came back as 1969 for every observation (2026-11-13).
      d   <- ee$Date(img$get("system:time_start"))
      dec <- ee$Image$constant(ee$Number(d$get("year"))$add(d$getFraction("year")))$toDouble()$rename("dec")
      sr$normalizedDifference(c("NIR", "RED"))$rename("NDVI")$addBands(dec)$
        copyProperties(img, list("system:time_start"))
    })
}
get_obs <- function(lon, lat) {
  g  <- ee$Geometry$Point(c(lon, lat))
  ls <- ndvi_col("LANDSAT/LT05/C02/T1_L2", c("SR_B3", "SR_B4"), FALSE, g)$
    merge(ndvi_col("LANDSAT/LE07/C02/T1_L2", c("SR_B3", "SR_B4"), FALSE, g))$
    merge(ndvi_col("LANDSAT/LC08/C02/T1_L2", c("SR_B4", "SR_B5"), TRUE, g))
  r   <- ls$getRegion(g, 30L)$getInfo()
  hdr <- unlist(r[[1]])
  map_dfr(r[-1], function(row) {
    row <- setNames(lapply(row, function(v) if (is.null(v)) NA else v), hdr)
    tibble(dec = as.numeric(row$dec), ndvi = as.numeric(row$NDVI))
  }) |>
    filter(!is.na(ndvi), !is.na(dec)) |>
    transmute(date = date_decimal(dec), year = as.integer(floor(dec)), ndvi)
}
xy  <- st_coordinates(picked)
obs <- map_dfr(seq_len(nrow(picked)), function(i) {
  message("  fetching ", picked$category[i])
  get_obs(xy[i, 1], xy[i, 2]) |> mutate(category = picked$category[i])
})

#### 6. Recompute the method from the raw observations ####
# Also rule e (diag_06 / validate_backdating_method_fidelity.R): a 1-obs year's annual max replaced by
# linear interpolation between the nearest >= 2-obs years. Drawn in the figures where it differs.
win_year <- function(year, loss) {
  cand <- year >= max(IMG_START + 2L, ONSET_MIN) & year <= min(IMG_END - 1L, ONSET_MAX) & !is.na(loss)
  cand & loss == max(loss[cand], -Inf)
}
series <- obs |> group_by(category, year) |> summarise(ndvi_max = max(ndvi), n_obs = n(), .groups = "drop") |>
  complete(category, year = IMG_START:IMG_END, fill = list(n_obs = 0L)) |>
  arrange(category, year) |> group_by(category) |>
  mutate(ma3   = (lag(ndvi_max) + ndvi_max + lead(ndvi_max)) / 3,   # NA if any of the 3 years has no obs
         loss  = lag(ma3) - ma3,                                    # = NDVI_deriv: avg[y] - avg[y-1], negated series
         candidate = year >= max(IMG_START + 2L, ONSET_MIN) & year <= min(IMG_END - 1L, ONSET_MAX) & !is.na(loss),
         winner = win_year(year, loss),
         ndvi_e = { ok <- n_obs >= 2L & !is.na(ndvi_max)
                    if (sum(ok) >= 2) { iv <- approx(year[ok], ndvi_max[ok], xout = year, rule = 1)$y
                                        if_else(n_obs == 1L & !is.na(iv), iv, ndvi_max) } else ndvi_max },
         ma3_e    = (lag(ndvi_e) + ndvi_e + lead(ndvi_e)) / 3,
         winner_e = win_year(year, lag(ma3_e) - ma3_e)) |>
  ungroup()

# One-year dip: keep the first candidate whose lowest year in 2002-2003 rests on ONE observation and
# recovers by >= 0.2 within two years (the V diag_06 found in 53% of 2002 pixels); else the first.
dip_c <- sort(grep("^One-year dip #", unique(series$category), value = TRUE))
if (length(dip_c)) {
  is_v <- series |> filter(category %in% dip_c) |> group_by(category) |>
    summarise(v = { i <- which(year %in% 2002:2003 & !is.na(ndvi_max))
                    if (!length(i)) FALSE else {
                      t <- i[which.min(ndvi_max[i])]
                      n_obs[t] == 1L && isTRUE(max(ndvi_max[year %in% (year[t] + 1L):(year[t] + 2L)], -Inf, na.rm = TRUE) >= ndvi_max[t] + 0.2) } },
              .groups = "drop")
  keep <- c(is_v$category[is_v$v], dip_c)[1]
  message("One-year dip: kept ", keep, if (!any(is_v$v)) " (no candidate showed a clean V)" else "")
  ren <- function(x) x |> filter(!category %in% setdiff(dip_c, keep)) |>
    mutate(category = if_else(category == keep, "One-year dip", category))
  series <- ren(series); obs <- ren(obs); picked <- ren(picked)
}

check <- series |> group_by(category) |>
  summarise(recomputed = year[winner][1], recomputed_e = year[winner_e][1], .groups = "drop") |>
  right_join(st_drop_geometry(picked) |> select(category, onset_year, ndvi_deriv_x1000, start_ndvi_x1000,
                                                lt_agree, n_computable_years, bar_year), by = "category") |>
  mutate(recomputed_matches = !is.na(recomputed) & recomputed == onset_year)
print(check, width = Inf)
if (!all(check$recomputed_matches))
  message("NOTE: recomputed onset differs from the asset for some pixels -- the asset is at 30 m in ",
          "EPSG:4326, this is the UTM pixel under the point, so a neighbouring-pixel mismatch is possible.")

# LandTrendr's year isn't stored when it disagrees/doesn't fire; show it only via lt_agree in the label
labels <- check |> mutate(label = sprintf("%s | onset %s | LT %s | Barenblitt et al.+1 %s | start NDVI %.2f",
                                          category, onset_year,
                                          c("agrees", "disagrees", "no signal", "-")[match(lt_agree, c(0, 1, 2, 9))],
                                          if_else(is.na(bar_year), "-", as.character(bar_year + 1L)),
                                          start_ndvi_x1000 / 1000))
lab <- setNames(labels$label, labels$category)

#### 7. Figures: NDVI (left) and the year-on-year loss that picks the onset (right), one per FIG_GROUP ####
# Rule e is drawn (orange dashed 3-yr average + orange line at its onset) only in figures with show_e
# (weak spots), and there only in panels where it changes something; the method figure stays clean.
fig_dir <- here("outputs", "figures", "backdating"); dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
make_fig <- function(g) {
  cat_order <- intersect(g$cats, unique(series$category))
  if (!length(cat_order)) { message("no pixels for figure '", g$file, "' -- skipped"); return(invisible(NULL)) }
  s  <- series |> filter(category %in% cat_order) |> mutate(category = factor(category, cat_order))
  o  <- obs    |> filter(category %in% cat_order) |> mutate(category = factor(category, cat_order))
  mk <- labels |> filter(category %in% cat_order) |> mutate(category = factor(category, cat_order), bar_plus1 = bar_year + 1L)
  e_differs <- s |> group_by(category) |> summarise(d = any(abs(ndvi_e - ndvi_max) > 1e-9, na.rm = TRUE), .groups = "drop") |>
    filter(d, isTRUE(g$show_e)) |> pull(category)
  se  <- filter(s, category %in% e_differs)
  mke <- check |> filter(category %in% e_differs, !is.na(recomputed_e), recomputed_e != recomputed) |>
    mutate(category = factor(category, cat_order))

  p_ndvi <- ggplot(s, aes(year)) +
    geom_point(data = o, aes(decimal_date(date), ndvi), colour = "grey70", size = 0.7) +
    geom_line(aes(y = ndvi_max), colour = "#2C7FB8", linewidth = 0.5) +
    geom_line(aes(y = ma3), colour = "#253494", linewidth = 1.1) +
    geom_line(data = se, aes(y = ma3_e), colour = "#eb6834", linewidth = 0.9, linetype = "dashed") +
    geom_vline(data = mk, aes(xintercept = onset_year), colour = "#D7301F", linewidth = 0.8) +
    geom_vline(data = mke, aes(xintercept = recomputed_e), colour = "#eb6834", linewidth = 0.8, linetype = "dashed") +
    geom_vline(data = filter(mk, !is.na(bar_plus1)), aes(xintercept = bar_plus1),
               colour = "black", linetype = "dotted", linewidth = 0.8) +
    facet_wrap(~ category, ncol = 1, labeller = as_labeller(lab)) +
    coord_cartesian(ylim = c(-0.1, 1)) +
    labs(x = NULL, y = "NDVI",
         subtitle = paste0("grey = clear observations, thin = annual max, thick = 3-yr average; red = onset,\n",
                           "dotted = Barenblitt et al. year + 1",
                           if (length(e_differs)) "; orange dashed = rule e (1-obs years interpolated)" else "")) +
    theme_minimal(base_size = 10) + theme(strip.text = element_text(hjust = 0, size = 8))

  p_loss <- ggplot(filter(s, !is.na(loss)), aes(year, loss, fill = winner)) +
    geom_col(width = 0.8) +
    geom_hline(yintercept = 0, colour = "grey50") +
    scale_fill_manual(values = c(`FALSE` = "grey65", `TRUE` = "#D7301F"), guide = "none") +
    facet_wrap(~ category, ncol = 1, labeller = as_labeller(function(x) rep("", length(x)))) +
    labs(x = NULL, y = "loss in 3-yr average NDVI", subtitle = "the largest bar (red) is the onset year") +
    theme_minimal(base_size = 10)

  fig <- (p_ndvi | p_loss) + plot_layout(widths = c(3, 2)) + plot_annotation(title = g$title)
  print(fig)
  ggsave(file.path(fig_dir, paste0(g$file, ".png")), fig, width = 12, height = 2.3 * length(cat_order) + 1.4, dpi = 200)
}
walk(FIG_GROUPS, make_fig)

write_csv(left_join(series, select(check, category, onset_year, recomputed_e, recomputed_matches), by = "category"),
          here("outputs", "tables", "backdating", "ndvi_timeseries_examples.csv"))
