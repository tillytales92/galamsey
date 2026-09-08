# d_11_protected_areas.R
# Unzip + load the WDPA/WDOECM Ghana protected-areas extract, then basic EDA.
#
# Source: data/raw/gh_protectedareas/WDPA_WDOECM_Jul2026_Public_GHA_shp/
#   *_0.zip, *_1.zip, *_2.zip -- three zips, NOT three different datasets. Per
#   Shapefile_splitting_README.txt, UNEP-WCMC splits large national extracts into equal
#   parts by feature count (not geography), each zip containing the SAME two layers
#   (a polygon shapefile and a point shapefile) with the SAME filenames. Confirmed here:
#   97+97+96 = 290 polygon features, 0 duplicate SITE_IDs across parts -- they're
#   disjoint thirds that must be row-bound back into one layer per geometry type.
#
# This is the newer merged WDPA+WDOECM schema (site-based: SITE_ID/SITE_PID, plus
# OECM_ASMT), not the older WDPAID-keyed schema -- no WDPAID/MARINE fields here.
#
# Outputs (all derived -- data/raw/ stays exactly as downloaded, i.e. just the 3 zips):
#   data/processed/protected_areas/unzipped/part_{0,1,2}/ (raw unzip of each part, kept for
#     replicability / re-inspection without re-unzipping)
#   data/processed/protected_areas/protected_areas_{poly,points}.shp (merged layers,
#     WGS84, one feature per SITE_ID -- the b_0N-stage covariate build reads these)
#   outputs/figures/protected_areas/*.png (diagnostic plots)

pacman::p_load(sf, here, janitor, tidyverse, scales, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff,
  here::here
)
UTM30N <- 32630

raw_dir  <- here("data", "raw", "gh_protectedareas", "WDPA_WDOECM_Jul2026_Public_GHA_shp")
proc_dir <- here("data", "processed", "protected_areas")
zip_ids  <- 0:2

fig_dir <- here("outputs", "figures", "protected_areas")
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(proc_dir, recursive = TRUE, showWarnings = FALSE)

####1. Unzip each part into data/processed/ -- data/raw/ stays untouched as-downloaded ####
# (each zip has identically-named files, so each part gets its own subfolder)

for (i in zip_ids) {
  zip_path <- file.path(raw_dir, sprintf("WDPA_WDOECM_Jul2026_Public_GHA_shp_%d.zip", i))
  out_dir  <- file.path(proc_dir, "unzipped", sprintf("part_%d", i))
  stopifnot("zip part not found" = file.exists(zip_path))
  if (!dir.exists(out_dir) || length(list.files(out_dir)) == 0) {
    dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
    unzip(zip_path, exdir = out_dir)
    message(sprintf("Unzipped part_%d -> %s", i, out_dir))
  } else {
    message(sprintf("part_%d already unzipped, skipping.", i))
  }
}

####2. Load each part SEPARATELY first -- inspect why/how the data is split into three ####
# Each zip contains the SAME two layer names ("-polygons"/"-points"), so this is not three
# different datasets -- it's the same national layer cut into three pieces. Loading each
# part on its own here (before any merging) lets us check: are the schemas identical? are
# the SITE_IDs disjoint (a clean row-wise split) or overlapping (a spatial tile split)?

read_part <- function(i, suffix) {
  path <- file.path(proc_dir, "unzipped", sprintf("part_%d", i),
                     sprintf("WDPA_WDOECM_Jul2026_Public_GHA_shp-%s.shp", suffix))
  st_read(path, quiet = TRUE) |> mutate(wdpa_part = i)
}

poly_parts   <- map(zip_ids, read_part, suffix = "polygons")
points_parts <- map(zip_ids, read_part, suffix = "points")

cat("\n=== Per-part inspection (polygons layer) ===\n")
for (i in seq_along(zip_ids)) {
  p <- poly_parts[[i]]
  cat(sprintf("part_%d: %d polygon features, %d point-only features, bbox = [%s]\n",
              zip_ids[i], nrow(p), nrow(points_parts[[i]]),
              paste(round(st_bbox(p), 2), collapse = ", ")))
}

schemas_identical <- length(unique(map(poly_parts, names))) == 1
cat(sprintf("\nSchema identical across all parts: %s\n", schemas_identical))
if (!schemas_identical) {
  cat("Field-name diffs vs part_0:\n")
  for (i in 2:length(poly_parts)) print(setdiff(names(poly_parts[[i]]), names(poly_parts[[1]])))
}

all_site_ids  <- map(poly_parts, "SITE_ID")
n_dupes_01    <- length(intersect(all_site_ids[[1]], all_site_ids[[2]]))
n_dupes_02    <- length(intersect(all_site_ids[[1]], all_site_ids[[3]]))
n_dupes_12    <- length(intersect(all_site_ids[[2]], all_site_ids[[3]]))
cat(sprintf("\nSITE_ID overlap across parts -- 0&1: %d, 0&2: %d, 1&2: %d\n",
            n_dupes_01, n_dupes_02, n_dupes_12))
cat(sprintf(paste0("Interpretation: %s -- WDPA splits large national extracts into equal\n",
                    "parts BY FEATURE COUNT (not by geography or a spatial tiling scheme; note\n",
                    "the overlapping bboxes above), purely to keep each downloadable zip under a\n",
                    "file-size limit. The three parts must be row-bound back into one layer.\n"),
            if (n_dupes_01 + n_dupes_02 + n_dupes_12 == 0) "disjoint, no spatial/ID structure to the split"
            else "NOT disjoint -- investigate before merging"))

####3. Merge the three parts back into one layer per geometry type ####

pa_poly   <- bind_rows(poly_parts) |> st_make_valid()
pa_points <- bind_rows(points_parts)

stopifnot("duplicate SITE_ID across parts -- parts are not disjoint as expected" =
            !anyDuplicated(pa_poly$SITE_ID))

message(sprintf("\nMerged: %d protected-area polygons (%d unique sites) and %d points across %d parts.",
                nrow(pa_poly), n_distinct(pa_poly$SITE_ID), nrow(pa_points), length(zip_ids)))

####4. Basic EDA ####

cat("\n=== Fields ===\n"); print(names(pa_poly))

cat("\n=== STATUS ===\n");     print(table(pa_poly$STATUS, useNA = "ifany"))
cat("\n=== DESIG_ENG ===\n");  print(table(pa_poly$DESIG_ENG, useNA = "ifany"))
cat("\n=== IUCN_CAT ===\n");   print(table(pa_poly$IUCN_CAT, useNA = "ifany"))
cat("\n=== GOV_TYPE ===\n");   print(table(pa_poly$GOV_TYPE, useNA = "ifany"))
cat("\n=== OECM_ASMT ===\n");  print(table(pa_poly$OECM_ASMT, useNA = "ifany"))

pa_utm <- st_transform(pa_poly, UTM30N) |>
  mutate(area_ha_geom = as.numeric(st_area(geometry)) / 1e4,
         area_ha_field = REP_AREA * 100)

cat("\n=== Area (ha) ===\n")
cat("-- from REP_AREA field (km^2 x 100) --\n"); print(summary(pa_utm$area_ha_field))
cat("-- from geometry (UTM30N) --\n");            print(summary(pa_utm$area_ha_geom))
cat(sprintf("\nTotal protected area (geometry-based): %.0f ha across %d sites.\n",
            sum(pa_utm$area_ha_geom), nrow(pa_utm)))

p_area <- ggplot(pa_utm, aes(area_ha_geom)) +
  geom_histogram(bins = 30, fill = "#238B45") +
  scale_x_log10(labels = label_number()) +
  labs(title = "Ghana WDPA/WDOECM protected-area size distribution",
       subtitle = "Log10 x-axis; area computed from geometry (UTM30N)",
       x = "Area (ha, log scale)", y = "Count") +
  theme_bw(base_size = 11)
p_area
ggsave(file.path(fig_dir, "protected_areas_area_hist.png"), p_area, width = 7, height = 5, dpi = 150)

####5. Spatial map ####

admin0_path <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp")
admin0 <- if (file.exists(admin0_path)) {
  st_read(admin0_path, quiet = TRUE) |> st_make_valid() |> select(any_of(c("adm0_name", "geometry")))
} else { message("admin0 shapefile not found -- map will omit the Ghana outline."); NULL }

p_map <- ggplot() +
  { if (!is.null(admin0)) geom_sf(data = admin0, fill = "grey96", colour = "grey60") } +
  geom_sf(data = pa_poly, aes(fill = DESIG_ENG), colour = NA, alpha = 0.85) +
  geom_sf(data = pa_points, colour = "black", size = 1.5, shape = 4) +
  labs(title = "Ghana protected areas (WDPA/WDOECM)",
       subtitle = sprintf("%d sites (%d polygons, %d point-only sites), %.0f ha total",
                           n_distinct(pa_poly$SITE_ID), nrow(pa_poly), nrow(pa_points),
                           sum(pa_utm$area_ha_geom)),
       fill = "Designation",
       caption = "UNEP-WCMC & IUCN, Protected Planet (WDPA/WDOECM), Jul 2026. Till Meissner.") +
  theme_minimal(base_size = 10) +
  theme(plot.title = element_text(face = "bold"),
        axis.text = element_blank(), axis.title = element_blank(),
        panel.grid = element_blank(),
        plot.caption = element_text(colour = "grey50", size = 7))
p_map
ggsave(file.path(fig_dir, "protected_areas_map.png"), p_map, width = 8, height = 8, dpi = 150)

####6. Save merged layers to data/processed/ ####

st_write(pa_poly, file.path(proc_dir, "protected_areas_poly.shp"),
          delete_layer = TRUE, quiet = TRUE)
st_write(pa_points, file.path(proc_dir, "protected_areas_points.shp"),
          delete_layer = TRUE, quiet = TRUE)

message(sprintf("\nWrote merged layers to %s", proc_dir))

message("\n=== d_11_protected_areas.R complete ===")
