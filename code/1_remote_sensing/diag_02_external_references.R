# diag_02_external_references.R  (renamed 2026-11-03 from validate_external_references.R -- see
# code/1_remote_sensing's diag_NN_* naming convention)
# The two genuinely independent (never-trained-on) mining references available for Ghana:
# Africa Mining Watch (AMW) early ML detections, and SmallMinesDS (Ofori-Ampofo et al. 2025)
# expert masks. Merged into one script 2026-08-05 (was validate_africa_mining_watch.R +
# validate_smallminesds_peek.R) because they play the same structural role -- unlike
# Barenblitt/Maus/Tang (all training-label sources, see build_01_labels.R), neither of these
# ever enters build_02_embedding_classifier.R's training data, so they're the only sources
# that can meaningfully validate the classifier rather than just cross-check one training
# input against another. (That was validate_mausetal.R's problem -- retired 2026-08-05, since
# Maus is itself a training source: comparing it to Barenblitt was training-input-vs-training-
# input, not validation. Its content is superseded by build_01_labels.R's own QA
# (labels_summary.csv, labels_overview_map) plus the build_02 Section 7 ablation, which is the
# actual empirical test of whether Maus/Tang help.)
#
# SmallMinesDS is additionally build_02's held-out ablation TEST set (build_01_labels.R
# Section 12); Part 2 below is pure visual sanity-checking of the raw masks, not a restatement
# of that ablation.
#
# Structure:
#   Part 1 (offline, no GEE) -- AMW: confidence distributions, spatial coverage, footprint
#     size. Ported from the former validate_africa_mining_watch.R.
#   Part 2 (offline, no GEE) -- SmallMinesDS: visual patch peek (S2 true colour + mask) and a
#     "where do the labelled sites actually sit" leaflet map. Ported from the former
#     validate_smallminesds_peek.R.
#   Part 2b (offline, no GEE) -- NEW (2026-08-10): SmallMinesDS district coverage -- which
#     districts the full patch registry (all 4,270 patches, both epochs) actually falls in.
#     91% of patches sit in just 5 districts (Amansie Central/West/South, Bekwai Municipal,
#     Upper Denkyira West) -- the Amansie-Bekwai-Obuasi gold belt, not a national sample. Matters
#     because this is the ONLY footprint validate_ablation_sources.R and
#     validate_probability_threshold.R's accuracy numbers are actually measured against.
#     Also writes an interactive overview leaflet (2026-08-10) -- ALL 4,270 patches as toggleable
#     coloured points over an Esri satellite basemap, vs. leaflet_patch()'s one-patch zoomed view.
#   Part 2c (offline, no GEE) -- NEW (2026-08-10): REAL (not box) mining outlines for a chosen
#     AOI -- vectorises each patch's actual raster MASK rather than showing a share-coloured box.
#     Trades national scale (Part 2b) for exact shape at district scale; default AOI is a
#     41x41km Awomaso-centred box, epoch 2022, share_mined > 10% (203 patches).
#   Part 3 (needs rgee/EE, off by default) -- NEW: SmallMinesDS patches (a handful of Part 2's
#     high-mining-share picks) compared VISUALLY against build_02's OWN mine_prob_ghana_2022
#     output -- not against Barenblitt, which is a training source and therefore not
#     independent. For each patch: S2 image, then the classifier's footprint at each of
#     PROB_THRESHOLDS_SHOWN with the SmallMinesDS ground-truth boundary drawn on top, so cutoff
#     choices can be checked by eye, not just by the aggregate PA/UA numbers
#     (validate_probability_threshold.R). AMW dropped from this part for now -- kept in Parts
#     1-2 only; see Part 3's own header for why.
#
# Run Parts 1-2 standalone (no auth needed). Part 3 requires ee_Authenticate()/ee_Initialize()
# as in build_02_embedding_classifier.R, and build_02 must have already exported the
# mine_prob_ghana_{yr} assets it reads -- set RUN_PART3 <- TRUE below to enable it.
#
# Outputs: outputs/figures/external_references/*.png (+ one leaflet .html)

pacman::p_load(sf, terra, here, janitor, tidyverse, scales, patchwork, leaflet, leafem,
               htmlwidgets, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff,
  here::here
)
UTM30N <- 32630

fig_dir <- here("outputs", "figures", "external_references")
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

####################################################################
## PART 1 -- Africa Mining Watch: EDA (offline) ####################
####################################################################

amw_dir <- here("data", "raw", "africa_mining_watch_early_data", "africa_mining_watch_early_data")
boxes_path     <- file.path(amw_dir, "ghana_detection_boxes_Thresh0.99MLP64-16_2025-09-18T19_46.joblib.geojson")
rectpolys_path <- file.path(amw_dir, "ghana_rectpolys_Thresh0.99MLP64-16_2025-09-18T19_46.joblib.geojson")
admin0_path    <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp")

stopifnot("AMW detection_boxes geojson not found" = file.exists(boxes_path),
          "AMW rectpolys geojson not found"       = file.exists(rectpolys_path))

####1. Load ####
boxes <- st_read(boxes_path, quiet = TRUE) |> st_make_valid()
rects <- st_read(rectpolys_path, quiet = TRUE) |> st_make_valid()
message(sprintf("AMW detection_boxes: %d features | rectpolys: %d features", nrow(boxes), nrow(rects)))
message("Both share the same bounding box -- SW Ghana only ('early_data' = a pilot run, not national;")
message("Part 3's AMW comparison year below is therefore a best-guess vintage, not a confirmed match.)")

admin0 <- if (file.exists(admin0_path)) {
  st_read(admin0_path, quiet = TRUE) |> st_make_valid() |> select(any_of(c("adm0_name", "geometry")))
} else { message("admin0 shapefile not found -- map will omit the Ghana outline."); NULL }

####2. Confidence-score distributions ####
# Both files are already thresholded at 0.99 (per the filename), so this just shows HOW far
# above threshold detections sit.
conf_df <- bind_rows(
  boxes |> st_drop_geometry() |> mutate(source = "detection_boxes (raw, per-tile)"),
  rects |> st_drop_geometry() |> mutate(source = "rectpolys (merged site footprints)")
)
cat("\n=== AMW confidence score summary ===\n")
conf_df |> group_by(source) |> summarise(
  n = n(), min = min(confidence), p10 = quantile(confidence, .1),
  median = median(confidence), mean = mean(confidence), max = max(confidence)
) |> print()

p_conf <- ggplot(conf_df, aes(confidence)) +
  geom_histogram(bins = 60, fill = "#721F81") +
  facet_wrap(~source, scales = "free_y", ncol = 1) +
  scale_x_continuous(labels = label_number(accuracy = 0.001)) +
  labs(title = "AMW detection confidence scores",
       subtitle = "Both files are pre-filtered at confidence > 0.99 (see filename)",
       x = "Model confidence", y = "Count") +
  theme_bw(base_size = 11)
ggsave(file.path(fig_dir, "amw_confidence_hist.png"), p_conf, width = 8, height = 6, dpi = 150)

####3. Spatial coverage -- where are the detections? ####
bb <- st_bbox(rects)
p_amw_map <- ggplot() +
  { if (!is.null(admin0)) geom_sf(data = admin0, fill = "grey96", colour = "grey60") } +
  geom_sf(data = boxes, fill = "#2b6cb0", colour = NA, alpha = 0.15) +
  geom_sf(data = rects, fill = "#D94701", colour = NA, alpha = 0.6) +
  coord_sf(xlim = c(bb["xmin"], bb["xmax"]), ylim = c(bb["ymin"], bb["ymax"])) +
  labs(title = "Africa Mining Watch detections — Ghana (early/pilot run)",
       subtitle = sprintf("Blue = raw per-tile detection boxes (n = %s); orange = merged site footprints (n = %s)",
                          comma(nrow(boxes)), comma(nrow(rects))),
       caption  = "Africa Mining Watch, early ML detections (MLP64-16, thresh 0.99, 2025-09-18). Till Meissner.") +
  theme_minimal(base_size = 10) +
  theme(plot.title = element_text(face = "bold"), axis.text = element_blank(),
        axis.title = element_blank(), panel.grid = element_blank(),
        plot.caption = element_text(colour = "grey50", size = 7))
ggsave(file.path(fig_dir, "amw_detections_map.png"), p_amw_map, width = 8, height = 8, dpi = 150)

####4. Rectpolys site-footprint size distribution ####
rects_utm <- st_transform(rects, UTM30N) |> mutate(area_ha = as.numeric(st_area(geometry)) / 1e4)
cat("\n=== AMW rectpoly (merged site footprint) area, hectares ===\n")
print(summary(rects_utm$area_ha))
cat(sprintf("Total AMW footprint area: %.0f ha across %d sites\n",
            sum(rects_utm$area_ha), nrow(rects_utm)))

p_amw_area <- ggplot(rects_utm, aes(area_ha)) +
  geom_histogram(bins = 50, fill = "#D94701") +
  scale_x_log10(labels = label_number()) +
  labs(title = "AMW merged site-footprint size distribution",
       subtitle = "Log10 x-axis -- most footprints are small, a long tail of large sites",
       x = "Site area (ha, log scale)", y = "Count") +
  theme_bw(base_size = 11)
ggsave(file.path(fig_dir, "amw_rectpoly_area_hist.png"), p_amw_area, width = 7, height = 5, dpi = 150)

####################################################################
## PART 2 -- SmallMinesDS: visual sanity check (offline) ###########
####################################################################
# Bands 1-10 = Sentinel-2 (blue->SWIR2), 11-12 = Sentinel-1 VV/VH, 13 = Copernicus DEM. Masks
# are binary (1 = artisanal mining). RGB = S2 bands 3(red),2(grn),1(blu).

SMDS_YEAR  <- 2022
N_SHOW     <- 4      # how many example patches to display PER GROUP (high-share + low-share)
MIN_FRAC   <- 0.02   # "low-share" group still excludes near-empty patches (patch 0001 etc. are all-zero)
LOW_TARGET <- 0.10   # "low mining share" group targets patches nearest this fraction
SCAN       <- 120    # how many masks to scan to find examples (keeps it a small subset)

smds_dir_y <- here("data", "raw", "smallminesds", "SmallMinesDS", "SmallMinesDS", as.character(SMDS_YEAR))
img_of <- function(mask_path) file.path(smds_dir_y, "IMAGE", sub("MASK", "IMG", basename(mask_path)))

mask_files <- head(list.files(file.path(smds_dir_y, "MASK"), pattern = "\\.tif$", full.names = TRUE), SCAN)
smds_frac  <- vapply(mask_files, \(f) mean(terra::values(rast(f)), na.rm = TRUE), numeric(1))

pick_high <- mask_files[order(smds_frac, decreasing = TRUE)][seq_len(N_SHOW)]   # the N most-mined patches
eligible  <- mask_files[smds_frac > MIN_FRAC]                                  # exclude near-empty patches
elig_frac <- smds_frac[smds_frac > MIN_FRAC]
pick_low  <- eligible[order(abs(elig_frac - LOW_TARGET))][seq_len(min(N_SHOW, length(eligible)))]  # nearest LOW_TARGET
pick      <- c(pick_high, pick_low)

cat(sprintf("\nSmallMinesDS %d: scanned %d masks; %d have >%.0f%% mining.\n",
            SMDS_YEAR, length(mask_files), sum(smds_frac > MIN_FRAC), 100 * MIN_FRAC))
cat(sprintf("  Showing %d highest-mining-share patches + %d patches nearest %.0f%% mining share.\n",
            length(pick_high), length(pick_low), 100 * LOW_TARGET))

# true-colour array with a 2-98% per-band linear stretch (returns HxWx3 in [0,1])
rgb_array <- function(img) {
  r <- img[[c(3, 2, 1)]]
  q <- terra::global(r, \(x) quantile(x, c(0.02, 0.98), na.rm = TRUE))
  a <- terra::as.array(r)
  for (i in 1:3) a[, , i] <- (pmin(pmax(a[, , i], q[i, 1]), q[i, 2]) - q[i, 1]) / (q[i, 2] - q[i, 1])
  a
}
# base-graphics panel: draw an as.raster image into the current mfrow cell (avoids terra's
# internal layout() calls, which otherwise reset par(mfrow) and blank the grid).
show_ras <- function(ras, main) {
  plot.new(); plot.window(c(0, 1), c(0, 1), asp = 1)
  rasterImage(ras, 0, 0, 1, 1); title(main, cex.main = 0.85)
}

# one row per patch -- S2 true colour (with translucent mining overlay) | binary mask.
# First length(pick_high) rows = highest mining share; remaining rows = nearest LOW_TARGET
# (each row's title states its own %, so the two groups are self-labeling).
par(mfrow = c(length(pick), 2), mar = c(1, 1, 2, 1))
for (mf in pick) {
  id <- sub("MASK_(.*)\\.tif$", "\\1", basename(mf))
  m  <- terra::as.matrix(rast(mf), wide = TRUE)
  show_ras(as.raster(rgb_array(rast(img_of(mf)))), sprintf("%s — S2 true colour (+ mining)", id))
  rasterImage(as.raster(matrix(ifelse(m == 1, "#FF2A2A80", "#00000000"), nrow(m))), 0, 0, 1, 1)
  show_ras(as.raster(matrix(ifelse(m == 1, "red", "grey90"), nrow(m))),
           sprintf("mask (%.1f%% mining)", 100 * mean(m, na.rm = TRUE)))
}
dev.copy(png, file.path(fig_dir, sprintf("smallminesds_peek_%d.png", SMDS_YEAR)),
         width = 900, height = 450 * length(pick), res = 150)
dev.off()

# interactive leaflet -- patch in its real SW-Ghana location, true colour + mask toggleable
# over an Esri satellite basemap. Shows WHERE the labelled sites sit.
leaflet_patch <- function(mask_path) {
  id  <- sub("MASK_(.*)\\.tif$", "\\1", basename(mask_path))
  rgb <- terra::project(rast(img_of(mask_path))[[c(3, 2, 1)]], "EPSG:4326")
  msk <- terra::project(classify(rast(mask_path), cbind(0, NA)), "EPSG:4326", method = "near")
  e   <- as.vector(ext(rgb))
  leaflet() |>
    addProviderTiles("Esri.WorldImagery", group = "Esri satellite") |>
    leafem::addRasterRGB(rgb, r = 1, g = 2, b = 3, quantiles = c(0.02, 0.98), group = "S2 true colour") |>
    addRasterImage(msk, colors = "#ff2a2a", opacity = 0.6, group = "Mining mask") |>
    addLayersControl(baseGroups = "Esri satellite",
                     overlayGroups = c("S2 true colour", "Mining mask"),
                     options = layersControlOptions(collapsed = FALSE)) |>
    addScaleBar(position = "bottomleft") |>
    fitBounds(e[1], e[3], e[2], e[4]) |>
    addControl(sprintf("SmallMinesDS %s (%d)", id, SMDS_YEAR), position = "topright")
}

smds_map <- leaflet_patch(pick[1])   # change pick[1] to any element of `pick`, or another MASK path
if (interactive()) print(smds_map)
html_out <- file.path(fig_dir, sprintf("smallminesds_leaflet_%s.html",
                                       sub("MASK_(.*)\\.tif$", "\\1", basename(pick[1]))))
tryCatch(htmlwidgets::saveWidget(smds_map, html_out, selfcontained = TRUE),
         error = function(e) htmlwidgets::saveWidget(smds_map, html_out, selfcontained = FALSE))
message("SmallMinesDS leaflet map written to: ", html_out)

####################################################################
## PART 2b -- SmallMinesDS: district coverage (offline) ############
####################################################################
# Which districts do the labelled patches actually sit in? Uses the FULL patch registry from
# build_01_labels.R (all 4,270 patches, both epochs) -- not the SCAN-limited subset peeked
# above -- since this is a coverage question, not a visual spot-check.
#
# Matters because validate_ablation_sources.R and validate_probability_threshold.R score
# EVERYTHING against SmallMinesDS -- so whatever geographic footprint SmallMinesDS covers is
# the only footprint those accuracy numbers (OA .84-.88, PROB_THRESHOLD 55, AUC .94) are
# actually validated against. National predictions outside it -- especially northern Ghana --
# rest entirely on the classifier generalising, with no measured accuracy to back that up.

admin2_path  <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin2.shp")
patches_path <- here("data", "processed", "labels", "smallminesds_patch_footprints.rds")

if (file.exists(admin2_path) && file.exists(patches_path)) {

admin2 <- st_read(admin2_path, quiet = TRUE) |>
  select(adm1_name, adm2_name, adm2_pcode, geometry) |>
  st_make_valid()

patches_reg <- readRDS(patches_path)
patch_cent  <- patches_reg |> st_transform(st_crs(admin2)) |> st_centroid()

district_join <- st_join(patch_cent, admin2, join = st_within) |> st_drop_geometry()

district_tab <- district_join |>
  count(adm1_name, adm2_name, adm2_pcode, name = "n_patches", sort = TRUE)

top5_pct <- 100 * sum(head(district_tab$n_patches, 5)) / sum(district_tab$n_patches)

cat("\n=== SmallMinesDS patches by district (all epochs) ===\n")
print(district_tab, n = Inf)
cat(sprintf("\nTop 5 districts hold %.1f%% of all %d patches; %d districts touched in total.\n",
            top5_pct, sum(district_tab$n_patches), nrow(district_tab)))

p_smds_districts <- ggplot(district_tab, aes(fct_reorder(adm2_name, n_patches), n_patches)) +
  geom_col(fill = "#721F81") +
  coord_flip() +
  scale_y_continuous(labels = comma) +
  labs(title = "SmallMinesDS patches by district",
       subtitle = sprintf("%d districts touched, but %.0f%% of patches sit in the top 5 (Amansie/Bekwai/Upper Denkyira belt)",
                          nrow(district_tab), top5_pct),
       x = NULL, y = "# patches") +
  theme_bw(base_size = 11)
ggsave(file.path(fig_dir, "smallminesds_district_coverage.png"), p_smds_districts, width = 8, height = 6, dpi = 150)

# choropleth: where does the validation footprint sit relative to all of Ghana? -- same plasma
# gradient family used for mining-extent choropleths elsewhere (a_01_incidence_maps.R), applied
# here to patch counts rather than hectares, so the visual language of "this is a mining-
# intensity-style map" carries over even though the underlying quantity differs.
admin2_counts <- admin2 |>
  left_join(district_tab |> select(adm2_pcode, n_patches), by = "adm2_pcode") |>
  mutate(n_patches = replace_na(n_patches, 0))

p_smds_map <- ggplot(admin2_counts) +
  geom_sf(aes(fill = n_patches), colour = "grey70", linewidth = 0.1) +
  scale_fill_gradientn(
    colours = c("grey96", "#FCFDBF", "#FEC287", "#FD9567", "#F1605D", "#CD4071", "#9E2F7F", "#721F81", "#450457"),
    trans = "sqrt", na.value = "grey96", name = "# patches"
  ) +
  labs(title = "SmallMinesDS validation coverage across Ghana",
       subtitle = "Concentrated in one SW gold-belt cluster -- national predictions elsewhere are unvalidated",
       caption  = "SmallMinesDS (Ofori-Ampofo et al. 2025) patch registry, both epochs. Till Meissner.") +
  theme_minimal(base_size = 10) +
  theme(plot.title = element_text(face = "bold"), axis.text = element_blank(),
        axis.title = element_blank(), panel.grid = element_blank(),
        plot.caption = element_text(colour = "grey50", size = 7))
ggsave(file.path(fig_dir, "smallminesds_district_coverage_map.png"), p_smds_map, width = 8, height = 8, dpi = 150)

# interactive overview -- ALL 4,270 patches' REAL FOOTPRINTS (each ~1.28x1.28km, both epochs) as
# toggleable polygon layers over a real Esri satellite basemap, not just an admin-boundary
# choropleth. Complements the single-patch leaflet_patch() above (one patch, zoomed in, S2 +
# mask) with the reverse view: every patch's exact boundary at once, coloured by mining share, so
# you can see the whole validation footprint against actual imagery and click any patch for its
# id/epoch/share. Real footprints (not centroids) -- worth the larger file since the boundary
# itself is visible once zoomed into any single patch, not just its location.
pal_share <- colorNumeric(
  palette = c("#FCFDBF", "#FEC287", "#FD9567", "#F1605D", "#CD4071", "#9E2F7F", "#721F81", "#450457"),
  domain  = patches_reg$share_mined
)
patches_ll <- patches_reg |> st_transform(4326)

smds_overview <- leaflet(patches_ll) |>
  addProviderTiles("Esri.WorldImagery", group = "Esri satellite") |>
  addPolygons(
    weight = 1, color = "white", opacity = 0.6, fillOpacity = 0.6,
    fillColor = ~pal_share(share_mined), group = ~paste(epoch),
    popup = ~sprintf("<b>%s</b> (%d)<br>Mining share: %.1f%%", patch_id, epoch, 100 * share_mined)
  ) |>
  addLegend(pal = pal_share, values = patches_reg$share_mined, title = "Mining share",
            labFormat = labelFormat(suffix = "%", transform = \(x) 100 * x), position = "bottomleft") |>
  addLayersControl(baseGroups = "Esri satellite",
                   overlayGroups = as.character(sort(unique(patches_reg$epoch))),
                   options = layersControlOptions(collapsed = FALSE)) |>
  addScaleBar(position = "bottomright") |>
  addControl(sprintf("SmallMinesDS -- all %d patches, both epochs", nrow(patches_reg)), position = "topright")

if (interactive()) print(smds_overview)
overview_html <- file.path(fig_dir, "smallminesds_overview_leaflet.html")
tryCatch(htmlwidgets::saveWidget(smds_overview, overview_html, selfcontained = TRUE),
         error = function(e) htmlwidgets::saveWidget(smds_overview, overview_html, selfcontained = FALSE))
message("SmallMinesDS overview leaflet (all patches, satellite basemap) written to: ", overview_html)

####################################################################
## PART 2c -- SmallMinesDS: REAL outlines for a chosen AOI (offline) ###
####################################################################
# The overview above trades exact shape for scale (4,270 boxes coloured by an aggregate share
# statistic). This does the opposite for ONE chosen area: vectorises each patch's ACTUAL raster
# MASK (data/raw/smallminesds/.../MASK/MASK_{patch_id}_{epoch}.tif) into a real mining-boundary
# polygon, not a box. Doing this for all 4,270 patches nationally would mean opening 4,270
# separate GeoTIFFs -- fine for one AOI (a district-ish area), too slow/heavy at full scale.
#
# AOI_SITE follows the same {x, y, halfwidth_km} (UTM30N) convention as validate_site_timeseries.R
# SITES, for consistency. SHARE_MIN filters out near-empty patches (median share in a full AOI
# scan is often only ~2%) so the map only shows patches with real visible mining, not speckle.
AOI_SITE      <- list(x = 617000, y = 670000, halfwidth_km = 5)   # Awomaso-centred, ~41x41km
AOI_EPOCH     <- 2022                                                 # matches mine_prob_ghana_2022
SHARE_MIN     <- 0.01   # keep only patches with >10% mining share (203 of 1,428 in this AOI)

aoi_poly <- st_sfc(st_point(c(AOI_SITE$x, AOI_SITE$y)), crs = UTM30N) |>
  st_buffer(AOI_SITE$halfwidth_km * 1000, endCapStyle = "SQUARE")
aoi_hit  <- st_intersects(aoi_poly, st_transform(patches_reg, UTM30N), sparse = FALSE)[1, ]
aoi_sel  <- patches_reg[aoi_hit, ] |> filter(epoch == AOI_EPOCH, share_mined > SHARE_MIN)

message(sprintf("Part 2c AOI: %d patches selected (epoch %d, share > %.0f%%) out of %d in the box",
                nrow(aoi_sel), AOI_EPOCH, 100 * SHARE_MIN, sum(aoi_hit)))

smds_dir_epoch <- here("data", "raw", "smallminesds", "SmallMinesDS", "SmallMinesDS", as.character(AOI_EPOCH))
aoi_mask_paths <- file.path(smds_dir_epoch, "MASK", sprintf("MASK_%s_%d.tif", aoi_sel$patch_id, AOI_EPOCH))

if (nrow(aoi_sel) > 0 && all(file.exists(aoi_mask_paths))) {

  # vectorise each patch's binary mask (mining==1 cells) into a real polygon -- one raster read
  # + as.polygons() per patch, not a bulk operation, since each patch is its own small GeoTIFF
  aoi_outline_list <- lapply(seq_along(aoi_mask_paths), function(i) {
    r     <- rast(aoi_mask_paths[i])
    r_bin <- (r == 1)
    p <- as.polygons(r_bin, dissolve = TRUE) |> st_as_sf()
    p <- p |> filter(.data[[names(r_bin)[1]]] == TRUE)
    if (nrow(p) == 0) return(NULL)
    p |> mutate(patch_id = aoi_sel$patch_id[i], share_mined = aoi_sel$share_mined[i]) |>
      select(patch_id, share_mined)
  })
  aoi_outlines <- do.call(rbind, Filter(Negate(is.null), aoi_outline_list)) |> st_transform(4326)

  aoi_map <- leaflet(aoi_outlines) |>
    addProviderTiles("Esri.WorldImagery", group = "Esri satellite") |>
    addPolygons(color = "#ff2a2a", weight = 1, fillColor = "#ff2a2a", fillOpacity = 0.65,
                popup = ~sprintf("<b>%s</b><br>Mining share: %.1f%%", patch_id, 100 * share_mined)) |>
    addScaleBar(position = "bottomright") |>
    addControl(sprintf("SmallMinesDS real outlines -- %d patches, epoch %d, share > %.0f%%",
                       nrow(aoi_outlines), AOI_EPOCH, 100 * SHARE_MIN), position = "topright")

  if (interactive()) print(aoi_map)
  aoi_html <- file.path(fig_dir, "smallminesds_aoi_real_outlines.html")
  tryCatch(htmlwidgets::saveWidget(aoi_map, aoi_html, selfcontained = TRUE),
           error = function(e) htmlwidgets::saveWidget(aoi_map, aoi_html, selfcontained = FALSE))
  message("SmallMinesDS AOI real-outline leaflet written to: ", aoi_html)

} else {
  message("Skipping Part 2c -- no patches matched the AOI/epoch/share filter, or a mask file was missing.")
}

} else {
  message("Skipping SmallMinesDS district-coverage check -- admin2 shapefile or patch registry not found.")
}

####################################################################
## PART 3 -- classifier output vs. SmallMinesDS, visually (needs rgee/EE) ###
####################################################################
# Limited to SmallMinesDS for now (AMW dropped from this part, 2026-08-05) -- SmallMinesDS is
# precisely dated (Jan 2022, matches mine_prob_ghana_2022 exactly) and pixel-resolution, which
# is what a per-pixel visual overlay needs; AMW's site-level polygons and unconfirmed imagery
# vintage don't lend themselves to the same check.
#
# For each of PART3_PATCHES (defaults to Part 2's full `pick` -- 4 high-mining-share + 4
# nearest-10%-share patches), pulls the classifier's mine_prob_2022 raster for that exact patch
# extent and shows 4 panels per patch: S2 true colour + SmallMinesDS mining overlay, the
# SmallMinesDS mask alone in red (titled with its mining %), then one panel PER threshold in
# PROB_THRESHOLDS_SHOWN -- the classifier's OWN predicted mask at that cutoff, standalone, in
# blue (titled with its own predicted %) -- same solid-fill style as the SmallMinesDS panel but
# a different colour, so shapes get compared ACROSS panels (does the blue shape at 55 vs. 90
# look like the red reference shape?) rather than stacked as an overlay within one panel. Also
# lets you compare whether that differs between the obvious high-share patches and the more
# ambiguous low-share ones.

RUN_PART3             <- TRUE   # flip to TRUE once ee_Authenticate()/ee_Initialize() below is set up
PART3_PATCHES         <- pick    # both groups from Part 2: pick_high (4) + pick_low (4) = 8 patches
PROB_THRESHOLDS_SHOWN <- c(55, 90)    # uint8 percent cutoffs to compare side by side

if (RUN_PART3) {

rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)
library(reticulate)
pacman::p_load(rgee)

EE_PROJECT <- "rgee-auth-tillam"   # see build_02_embedding_classifier.R Section 1 for why this
                                   # must be the alphanumeric project ID, not the project number
rgee::ee_Authenticate()
rgee::ee_Initialize(project = EE_PROJECT)
ee_check()

EE_ASSET_HOME  <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
mine_prob_2022 <- ee$Image(file.path(EE_ASSET_HOME, "mine_prob_ghana_2022"))

message(sprintf("=== Part 3: pulling classifier output for %d patches ===", length(PART3_PATCHES)))

par(mfrow = c(length(PART3_PATCHES), 2 + length(PROB_THRESHOLDS_SHOWN)), mar = c(1, 1, 2, 1))

for (mf in PART3_PATCHES) {
  id     <- sub("MASK_(.*)\\.tif$", "\\1", basename(mf))
  mask_r <- rast(mf)
  m      <- terra::as.matrix(mask_r, wide = TRUE)

  # patch extent -> EE geometry (patch is EPSG:32630 per build_01_labels.R's own check).
  # NB 2026-08-05 (v1): sf::st_bbox(c(xmin = ext(mask_r)[1], ...)) silently returns an all-NA
  # bbox -- ext()[i] already carries its own name ("xmin"), so wrapping it in c(xmin = ...)
  # produces a compound name ("xmin.xmin") that st_bbox() can't match. Fixed via
  # terra::as.polygons(ext(...)) -- verified NA-free.
  # NB 2026-08-05 (v2): that polygon, routed through sf_as_ee() -> FeatureCollection ->
  # $geometry(), downloaded as 16384/16384 NA cells (total, not partial -- not a coverage gap).
  # Switched to ee$Geometry$Rectangle() built directly from the (already-verified-correct) sf
  # polygon's bounds -- bypasses the FeatureCollection/$geometry() indirection entirely, which
  # is the most likely source of the all-NA download. st_bbox() here is EXTRACTING bounds from
  # a valid sf object (its normal, documented use), not constructing one from a hand-named
  # vector -- not the same bug as v1.
  aoi_sf   <- terra::as.polygons(terra::ext(mask_r), crs = "EPSG:32630") |>
    sf::st_as_sf() |> sf::st_transform(4326)
  aoi_bb   <- sf::st_bbox(aoi_sf)
  aoi_geom <- ee$Geometry$Rectangle(
    c(aoi_bb[["xmin"]], aoi_bb[["ymin"]], aoi_bb[["xmax"]], aoi_bb[["ymax"]]),
    proj = "EPSG:4326", geodesic = FALSE
  )

  # tiny AOI (128x128 px @ 10m) -- well within the interactive pixel-fetch limit, so via =
  # "getDownloadURL" (rgee's direct small-raster download path -- confirmed against the
  # installed rgee 1.1.8's ee_as_rast() source; "getInfo" is NOT a valid via value, that was
  # wrong) avoids a batch Drive round-trip per patch (unlike the ~8.5k-point FeatureCollection
  # queries elsewhere in this pipeline, this is a raster pixel fetch, a different EE limit)
  prob_r <- ee_as_rast(mine_prob_2022$clip(aoi_geom), region = aoi_geom,
                       scale = 10, via = "getDownloadURL")
  prob_r <- terra::resample(prob_r, mask_r, method = "bilinear")   # align to the mask's exact grid

  # Diagnostic: an NA-heavy/all-NA prob_r (download/resample gap, or genuinely no classifier
  # coverage there) renders as an invisible/"empty" panel below rather than an error, since
  # ifelse(NA >= thr, ...) propagates NA straight into the colour matrix and NA cells draw as
  # fully transparent. Surface it instead of letting it silently disappear.
  n_na <- sum(is.na(terra::values(prob_r)))
  if (n_na > 0)
    message(sprintf("  [%s] prob_r has %d/%d NA cells after resample -- panels below will show",
                    id, n_na, terra::ncell(prob_r)),
            " those as 'not predicted' (grey), not invisible.")

  # Panel 1: S2 true colour + SmallMinesDS mining overlay (same rendering as Part 2)
  show_ras(as.raster(rgb_array(rast(img_of(mf)))), sprintf("%s — S2 true colour (+ mining)", id))
  rasterImage(as.raster(matrix(ifelse(m == 1, "#FF2A2A80", "#00000000"), nrow(m))), 0, 0, 1, 1)

  # Panel 2: SmallMinesDS mask alone (red), with mining share in the title -- the reference
  # shape everything else in this row gets compared against.
  show_ras(as.raster(matrix(ifelse(m == 1, "red", "grey90"), nrow(m))),
           sprintf("SmallMinesDS mask (%.1f%% mining)", 100 * mean(m, na.rm = TRUE)))

  # Panels 3+: classifier's OWN predicted mask at each threshold, standalone -- same solid-fill
  # style as panel 2 but in blue, not overlaid on the ground truth, so shapes are compared
  # ACROSS panels (panel 2 vs. panel 3 vs. panel 4) rather than stacked within one.
  for (thr in PROB_THRESHOLDS_SHOWN) {
    p    <- terra::as.matrix(prob_r, wide = TRUE)
    pred <- p >= thr
    pred[is.na(pred)] <- FALSE   # NA -> "not predicted" (grey) so the panel always renders
                                 # something visible instead of drawing invisible/transparent
                                 # cells (see the NA diagnostic above) -- % is still computed
                                 # over non-NA cells only via na.rm
    show_ras(as.raster(matrix(ifelse(pred, "#2b6cb0", "grey90"), nrow(p))),
             sprintf("classifier >= %d (%.1f%% predicted mining)", thr, 100 * mean(p >= thr, na.rm = TRUE)))
  }
}

dev.copy(png, file.path(fig_dir, "smallminesds_vs_classifier_2022.png"),
         width = 300 * (2 + length(PROB_THRESHOLDS_SHOWN)),
         height = 300 * length(PART3_PATCHES), res = 150)
dev.off()
message(sprintf("Wrote: %s", file.path(fig_dir, "smallminesds_vs_classifier_2022.png")))

}  # RUN_PART3

message("\n=== diag_02_external_references.R complete ===")
