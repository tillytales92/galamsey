# rs07_labels.R
# Harmonise external mining-label sources into artifacts the embedding classifier
# (rs05) can consume. Offline script (no GEE / no auth).
#
# Sources (see literature/rs/remote_sensing_overview.md §2B for methodology + caveats):
#   1. Barenblitt 2019 extent  — data/raw/barenblitt/FullConversiontoMiningExtent2019.shp
#      (minetype 1 = artisanal, 2 = industrial; SW Ghana only; PA 75.6%)
#   2. Maus et al. 2022 v2     — data/raw/mining_mausetal/global_mining_polygons_v2.gpkg
#      (hand-drawn on the 2019 Sentinel-2 mosaic inside 10 km SNL buffers; broad
#      "mining lands" incl. non-mine islands; 54.5% of validation errors < 50 m
#      from polygon borders → erode hard before sampling positives; CC-BY-SA)
#   3. Tang & Werner 2023      — data/raw/mining_tangwerner/74548_projected polygons.shp
#      (hand-drawn feature contours on 0.15–10 m Google Earth imagery of MIXED
#      vintage ~2019–2022; positional RMSE 39.7 m → erode ~40 m; commodity in
#      `Name`, no country field → filtered spatially to Ghana here)
#   4. SmallMinesDS            — data/raw/smallminesds/.../{2016,2022}/MASK/*.tif
#      (independent expert masks; STRICTLY HELD OUT for validation — rs07 only
#      extracts patch footprints so training sampling can avoid them)
#
# Outputs → data/processed/labels/:
#   labels_positives_polygons.rds   eroded positive polygons (source, vintage_year,
#                                   commodity, area_ha_raw), UTM30N
#   labels_positives_points.rds     interior points of polygons that vanish under
#                                   erosion (small ASM sites — keep as point labels)
#   labels_exclusion_mask.rds       union of ALL raw mining footprints (all sources,
#                                   incl. industrial + SmallMinesDS patches), buffered
#                                   EXCLUSION_BUFFER_M — sample negatives OUTSIDE this
#   smallminesds_patch_footprints.rds  patch extents w/ epoch + share_mined (validation
#                                      bookkeeping; never train inside these)
#   labels_summary.csv              counts/areas by source
#   labels_qa.gpkg                  all layers, for visual QA in QGIS
# Plus QA maps → outputs/figures/labels/labels_overview_map.png (static)
#              → outputs/figures/labels/labels_overview_map.html (interactive leaflet)
#
# How rs05 should consume this (not done here):
#   - positives: rasterise labels_positives_polygons (+ points) instead of / alongside
#     the raw Barenblitt paint(); pair each source with its vintage embedding year
#     (Barenblitt & Maus → 2019; Tang → ~2021) rather than one TRAIN_YEAR.
#   - negatives: mask the label image with the exclusion mask before
#     stratifiedSample() so class-0 points can't fall on known-but-unlabelled mining.
#   - SmallMinesDS: validation only — 2022 masks test the embedding classifier,
#     2016 masks are reserved for the Phase-2 Landsat/CCDC historical stack.
#
# NOT included: Africa Mining Watch (d_08) — candidate for the exclusion union once
# its precision is assessed; licences: Maus + SmallMinesDS are CC-BY-SA (share-alike)
# — fine for internal training/validation, check before redistributing derived labels.

pacman::p_load(sf, terra, here, janitor, tidyverse, scales, leaflet, htmlwidgets, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff,
  here::here
)

UTM30N <- 32630

####1. Parameters ####

ERODE_M <- c(
  barenblitt = 0,    # Landsat-native 30 m labels, already used raw in rs05
  maus       = 50,   # 54.5% of their validation errors sit < 50 m from borders
  tang       = 40    # Google Earth positional RMSE 39.7 m (~4 Sentinel pixels)
)
EXCLUSION_BUFFER_M  <- 1000   # buffer around all known mining for negative sampling
VINTAGE <- c(barenblitt = 2019L, maus = 2019L, tang = 2021L)  # tang = mixed ~2019-22
COMPUTE_MASK_SHARES <- TRUE   # per-patch mined share (reads all 4,270 mask rasters)

barenblitt_path <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")
maus_path       <- here("data", "raw", "mining_mausetal", "global_mining_polygons_v2.gpkg")
tang_path       <- here("data", "raw", "mining_tangwerner", "74548_projected polygons.shp")
smds_root       <- here("data", "raw", "smallminesds", "SmallMinesDS", "SmallMinesDS")
admin0_path     <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp")

stopifnot(
  "Barenblitt shp not found"   = file.exists(barenblitt_path),
  "Maus gpkg not found"        = file.exists(maus_path),
  "Tang & Werner shp not found" = file.exists(tang_path),
  "SmallMinesDS dir not found" = dir.exists(smds_root),
  "admin0 shp not found"       = file.exists(admin0_path)
)

out_dir <- here("data", "processed", "labels")
fig_dir <- here("outputs", "figures", "labels")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

####2. Ghana outline (spatial filter for the global Tang layer) ####

admin0 <- st_read(admin0_path, quiet = TRUE) |>
  st_make_valid() |>
  select(geometry) |>
  st_transform(UTM30N)

####3. Barenblitt 2019 — artisanal positives; ALL types feed the exclusion mask ####

message("=== Loading Barenblitt 2019 extent ===")
barenblitt_all <- st_read(barenblitt_path, quiet = TRUE) |>
  clean_names() |>
  st_make_valid() |>
  st_transform(UTM30N)

barenblitt_pos <- barenblitt_all |>
  filter(mine_type == 1) |>          # artisanal only, as in rs05
  transmute(source       = "barenblitt",
            source_id    = as.character(row_number()),
            commodity    = "Au",
            vintage_year = VINTAGE[["barenblitt"]])
message(sprintf("  %d polygons total, %d artisanal (mine_type == 1)",
                nrow(barenblitt_all), nrow(barenblitt_pos)))

####4. Maus et al. — Ghana subset via server-side SQL filter (as in d_09) ####

message("=== Loading Maus et al. (Ghana) ===")
maus_lyr <- st_layers(maus_path)$name[1]
maus_gha <- st_read(
  maus_path,
  query = sprintf("SELECT * FROM %s WHERE ISO3_CODE = 'GHA'", maus_lyr),
  quiet = TRUE
) |>
  rename(geometry = geom) |>   # gpkg names the sfc "geom"; align with the shapefiles for bind_rows
  st_make_valid() |>
  st_transform(UTM30N) |>
  transmute(source       = "maus",
            source_id    = as.character(row_number()),
            commodity    = NA_character_,   # no commodity attribute in the dataset
            vintage_year = VINTAGE[["maus"]])
message(sprintf("  %d Ghana polygons", nrow(maus_gha)))

####5. Tang & Werner — Ghana subset via GDAL wkt_filter (global file, no country field) ####
# Layer is 3D (XYZ, z all zero) in EPSG:6933 (NSIDC EASE-Grid Global); the wkt_filter
# runs server-side so we never load all 74,548 global polygons. Buffer the outline
# 5 km first so border-straddling polygons aren't clipped out of the filter.

message("=== Loading Tang & Werner (Ghana) ===")
tang_crs   <- st_crs(st_read(tang_path, quiet = TRUE,
                             query = sprintf("SELECT * FROM \"%s\" LIMIT 0",
                                             "74548_projected polygons")))
ghana_wkt  <- admin0 |>
  st_buffer(5000) |>
  st_transform(tang_crs) |>
  st_geometry() |>
  st_union() |>
  st_as_text()

tang_gha <- st_read(tang_path, wkt_filter = ghana_wkt, quiet = TRUE) |>
  st_zm(drop = TRUE) |>
  st_make_valid() |>
  st_transform(UTM30N) |>
  transmute(source       = "tang",
            source_id    = as.character(OBJECTID),
            # `Name` holds commodity codes ("Au", "Fe") for parts of the global file,
            # but for Ghana it is Google Earth placemark junk ("多边形", "Placemark",
            # bare numbers) — checked 2026-07-14 — so no usable commodity attribute.
            commodity    = NA_character_,
            vintage_year = VINTAGE[["tang"]])
message(sprintf("  %d Ghana polygons (no usable commodity attribute in Ghana)",
                nrow(tang_gha)))

####6. SmallMinesDS patch footprints (validation hold-out bookkeeping) ####
# Extents only — the masks themselves stay untouched as the independent test set.

message("=== Extracting SmallMinesDS patch footprints ===")
smds_footprints <- map_dfr(c(2016, 2022), function(yr) {
  mask_files <- list.files(file.path(smds_root, yr, "MASK"),
                           pattern = "^MASK_.*\\.tif$", full.names = TRUE)
  message(sprintf("  %d: %d mask patches", yr, length(mask_files)))
  map_dfr(mask_files, function(f) {
    r <- terra::rast(f)
    stopifnot("SmallMinesDS patch not in EPSG:32630" =
                terra::crs(r, describe = TRUE)$code == "32630")
    tibble(
      patch_id    = str_remove(str_remove(basename(f), "^MASK_"), sprintf("_%d\\.tif$", yr)),
      epoch       = yr,
      share_mined = if (COMPUTE_MASK_SHARES)
        as.numeric(terra::global(r, "mean", na.rm = TRUE)) else NA_real_,
      geometry    = st_as_sfc(st_bbox(c(xmin = terra::xmin(r), ymin = terra::ymin(r),
                                        xmax = terra::xmax(r), ymax = terra::ymax(r)),
                                      crs = st_crs(UTM30N)))
    )
  })
}) |> st_as_sf()

message(sprintf("  %d footprints; mined share: median %.1f%%, %d patches all-zero",
                nrow(smds_footprints),
                100 * median(smds_footprints$share_mined, na.rm = TRUE),
                sum(smds_footprints$share_mined == 0, na.rm = TRUE)))

####7. Harmonised positives — erode, keep survivors as polygons, salvage the rest as points ####
# Erosion pulls sampling away from uncertain borders (Maus: errors concentrate
# < 50 m from edges; Tang: 39.7 m RMSE). Polygons that vanish under erosion are
# small riverine ASM sites — exactly galamsey-shaped — so keep an interior point.

positives_raw <- bind_rows(barenblitt_pos, maus_gha, tang_gha) |>
  mutate(area_ha_raw = as.numeric(st_area(geometry)) / 1e4)

# Row-aligned erosion (st_buffer takes a per-feature distance vector), so
# positives_raw and the eroded geometries never get out of order.
erode_by    <- ERODE_M[positives_raw$source]
geom_eroded <- st_geometry(positives_raw)
to_erode    <- erode_by > 0
geom_eroded[to_erode] <- st_make_valid(st_buffer(geom_eroded[to_erode], -erode_by[to_erode]))

survived <- !st_is_empty(geom_eroded)
labels_positives_polygons <- st_set_geometry(positives_raw, geom_eroded)[survived, ]
labels_positives_points   <- positives_raw[!survived, ] |> st_point_on_surface()

positives_raw |>
  st_drop_geometry() |>
  mutate(survived = survived) |>
  count(source, survived) |>
  pivot_wider(names_from = survived, values_from = n, values_fill = 0,
              names_prefix = "survived_") |>
  print()

####8. Exclusion mask — union of ALL raw mining footprints, buffered ####
# Raw (uneroded) geometries, all mine types, all sources, plus every SmallMinesDS
# patch footprint (mined or not — the whole patch is reserved for validation).
# Negatives must be sampled OUTSIDE this. NB: all sources have known omission
# (Maus PA 79%, ASM undersampled) — outside-the-mask is still not guaranteed clean.

message("=== Building exclusion mask (slow: buffering + unioning all footprints) ===")
exclusion_mask <- c(
  st_geometry(barenblitt_all),      # incl. industrial
  st_geometry(maus_gha),
  st_geometry(tang_gha),
  st_geometry(smds_footprints)
) |>
  st_buffer(EXCLUSION_BUFFER_M) |>
  st_union()
message(sprintf("  Exclusion mask: %.0f km2 (%.1f%% of Ghana)",
                as.numeric(st_area(exclusion_mask)) / 1e6,
                100 * as.numeric(st_area(exclusion_mask)) /
                  as.numeric(st_area(st_union(admin0)))))

####9. Write artifacts ####

saveRDS(labels_positives_polygons, file.path(out_dir, "labels_positives_polygons.rds"))
saveRDS(labels_positives_points,   file.path(out_dir, "labels_positives_points.rds"))
saveRDS(exclusion_mask,            file.path(out_dir, "labels_exclusion_mask.rds"))
saveRDS(smds_footprints,           file.path(out_dir, "smallminesds_patch_footprints.rds"))

labels_summary <- labels_positives_polygons |>
  st_drop_geometry() |>
  group_by(source) |>
  summarise(n_polygons  = n(),
            area_ha_raw = sum(area_ha_raw),
            vintage     = first(vintage_year), .groups = "drop") |>
  left_join(
    labels_positives_points |> st_drop_geometry() |> count(source, name = "n_points"),
    by = "source"
  ) |>
  mutate(n_points = replace_na(n_points, 0L))
write_csv(labels_summary, file.path(out_dir, "labels_summary.csv"))
print(labels_summary)

# QA GeoPackage (one file, four layers) for QGIS inspection
qa_gpkg <- file.path(out_dir, "labels_qa.gpkg")
if (file.exists(qa_gpkg)) file.remove(qa_gpkg)
st_write(labels_positives_polygons, qa_gpkg, layer = "positives_polygons", quiet = TRUE)
st_write(labels_positives_points,   qa_gpkg, layer = "positives_points",   quiet = TRUE)
st_write(st_sf(geometry = exclusion_mask), qa_gpkg, layer = "exclusion_mask", quiet = TRUE)
st_write(smds_footprints,           qa_gpkg, layer = "smallminesds_footprints", quiet = TRUE)

####10. QA map ####

p_qa <- ggplot() +
  geom_sf(data = admin0, fill = "grey96", colour = "grey60") +
  geom_sf(data = st_sf(geometry = exclusion_mask),
          fill = "grey80", colour = NA, alpha = 0.6) +
  geom_sf(data = labels_positives_polygons, aes(fill = source), colour = NA) +
  geom_sf(data = labels_positives_points, aes(colour = source), size = 0.3, show.legend = FALSE) +
  scale_fill_manual(values = c(barenblitt = "#450457", maus = "#2171B5", tang = "#D94701"),
                    name = "Positive labels") +
  scale_colour_manual(values = c(barenblitt = "#450457", maus = "#2171B5", tang = "#D94701")) +
  labs(title    = "Harmonised mining labels — positives by source + exclusion mask (grey)",
       subtitle = sprintf("%s polygons + %s salvage points; exclusion buffer %d m; SmallMinesDS held out",
                          comma(nrow(labels_positives_polygons)),
                          comma(nrow(labels_positives_points)), EXCLUSION_BUFFER_M),
       caption  = "Barenblitt et al. (2021); Maus et al. (2022); Tang & Werner (2023); Ofori-Ampofo et al. (2025). Till Meissner.") +
  theme_minimal(base_size = 10) +
  theme(plot.title = element_text(face = "bold"),
        axis.text = element_blank(), panel.grid = element_blank(),
        plot.caption = element_text(colour = "grey50", size = 7))
ggsave(file.path(fig_dir, "labels_overview_map.png"), p_qa, width = 8, height = 9, dpi = 150)

####11. Interactive leaflet QA map ####
# Same layers as the static map — positives by source, salvage points, exclusion
# mask, SmallMinesDS footprints — each toggleable over an Esri satellite basemap,
# so labels can be checked against actual imagery. Geometries are simplified in
# UTM (metres) before the 4326 transform to keep the HTML a manageable size.

message("=== Building interactive leaflet QA map ===")
pal_src <- c(barenblitt = "#450457", maus = "#2171B5", tang = "#D94701")

simplify_ll <- function(x, tol_m) x |> st_simplify(dTolerance = tol_m) |> st_transform(4326)

excl_ll <- st_sf(geometry = exclusion_mask) |> simplify_ll(tol_m = 100)
pos_ll  <- labels_positives_polygons |> simplify_ll(tol_m = 10)
pts_ll  <- labels_positives_points   |> st_transform(4326)
smds_ll <- smds_footprints           |> st_transform(4326)

m_qa <- leaflet() |>
  addProviderTiles("Esri.WorldImagery", group = "Esri satellite") |>
  addProviderTiles("CartoDB.Positron",  group = "Light basemap") |>
  addPolygons(data = excl_ll, group = "Exclusion mask (negatives sampled outside)",
              fillColor = "#808080", fillOpacity = 0.35,
              color = "#4d4d4d", weight = 1) |>
  addPolygons(data = smds_ll, group = "SmallMinesDS footprints (held out)",
              fill = FALSE, color = "#00B0B0", weight = 1.5,
              label = ~sprintf("SmallMinesDS %s (%d) — %.0f%% mined",
                               patch_id, epoch, 100 * share_mined))

for (s in names(pal_src)) {
  grp    <- paste0("Positives: ", s)
  pos_s  <- filter(pos_ll, source == s)
  pts_s  <- filter(pts_ll, source == s)
  if (nrow(pos_s) > 0)
    m_qa <- m_qa |>
      addPolygons(data = pos_s, group = grp,
                  fillColor = pal_src[[s]], fillOpacity = 0.6,
                  color = pal_src[[s]], weight = 1,
                  label = ~sprintf("%s #%s — %.1f ha (raw), vintage %d",
                                   source, source_id, area_ha_raw, vintage_year))
  if (nrow(pts_s) > 0)   # polygons that vanished under erosion, kept as points
    m_qa <- m_qa |>
      addCircleMarkers(data = pts_s, group = grp,
                       radius = 3, stroke = FALSE,
                       fillColor = pal_src[[s]], fillOpacity = 0.9,
                       label = ~sprintf("%s #%s — %.1f ha (raw), salvage point",
                                        source, source_id, area_ha_raw))
}

m_qa <- m_qa |>
  addLayersControl(
    baseGroups    = c("Esri satellite", "Light basemap"),
    overlayGroups = c(paste0("Positives: ", names(pal_src)),
                      "Exclusion mask (negatives sampled outside)",
                      "SmallMinesDS footprints (held out)"),
    options = layersControlOptions(collapsed = FALSE)) |>
  addLegend(position = "bottomright", colors = unname(pal_src),
            labels = names(pal_src), title = "Positive labels", opacity = 0.8) |>
  addScaleBar(position = "bottomleft")

# source()/Rscript don't auto-display htmlwidgets — print for the Viewer AND
# write a standalone HTML (selfcontained needs pandoc; fall back to a _files sidecar).
if (interactive()) print(m_qa)
html_out <- file.path(fig_dir, "labels_overview_map.html")
tryCatch(
  htmlwidgets::saveWidget(m_qa, html_out, selfcontained = TRUE),
  error = function(e) htmlwidgets::saveWidget(m_qa, html_out, selfcontained = FALSE))
message("  Leaflet QA map written to: ", html_out)

####12. SmallMinesDS validation POINTS (for the rs05 ablation scorer) ####
# Turns the held-out masks into point labels GEE can score against: per patch,
# sample up to K_POS core-mining and K_NEG core-non-mining pixel centres.
# "Core" = a 3x3 focal erosion on each class, so no point sits on a mask edge
# (mixed 10 m pixels). These are VALIDATION-ONLY points — rs05 uploads the 2022
# set, samples the 2022 embedding at them, and computes per-combo error matrices.
# 2016 points are written too, reserved for the Phase-2 Landsat/CCDC stack.

K_POS <- 5L   # max mining points per patch
K_NEG <- 2L   # max non-mining points per patch (patches are mostly non-mining)
set.seed(42)

message("=== Sampling SmallMinesDS validation points ===")
for (yr in c(2016, 2022)) {
  mask_files <- list.files(file.path(smds_root, yr, "MASK"),
                           pattern = "^MASK_.*\\.tif$", full.names = TRUE)
  val_pts <- map_dfr(mask_files, function(f) {
    r <- terra::rast(f)
    # class cores: mining pixels whose 3x3 neighbourhood is all mining, and
    # non-mining pixels whose neighbourhood contains no mining
    core_pos <- terra::focal(r, w = 3, fun = "min", fillvalue = 0)
    core_neg <- terra::focal(r, w = 3, fun = "max", fillvalue = 1)
    cells_pos <- which(terra::values(core_pos) == 1)
    cells_neg <- which(terra::values(core_neg) == 0)
    if (length(cells_pos) > K_POS) cells_pos <- sample(cells_pos, K_POS)
    if (length(cells_neg) > K_NEG) cells_neg <- sample(cells_neg, K_NEG)
    cells <- c(cells_pos, cells_neg)
    if (length(cells) == 0) return(NULL)
    xy <- terra::xyFromCell(r, cells)
    tibble(
      patch_id = str_remove(str_remove(basename(f), "^MASK_"), sprintf("_%d\\.tif$", yr)),
      epoch    = yr,
      label    = rep(c(1L, 0L), c(length(cells_pos), length(cells_neg))),
      geometry = st_as_sfc(map2(xy[, 1], xy[, 2], ~ st_point(c(.x, .y))),
                           crs = st_crs(UTM30N))
    )
  }) |> st_as_sf()

  message(sprintf("  %d: %d points (%d mining / %d non-mining)",
                  yr, nrow(val_pts), sum(val_pts$label == 1), sum(val_pts$label == 0)))
  saveRDS(val_pts,
          file.path(out_dir, sprintf("smallminesds_validation_points_%d.rds", yr)))
}

message("\n=== rs07_labels.R complete — artifacts in data/processed/labels/ ===")
