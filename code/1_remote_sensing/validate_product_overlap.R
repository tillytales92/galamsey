# validate_product_overlap.R   (was validate_barenblitt_overlap.R -- renamed 2026-09-08)
# Benchmark our RS 2019 mine-probability layer against EVERY external mining product we have,
# year- and area-matched, to see where our classification sits relative to all existing datasets
# and how far off the absolute area is.
#
# All three references are ~2019 snapshots, so the only honest pairing is our 2019 layer:
#   Barenblitt et al. (2021)  FullConversiontoMiningExtent2019.shp   -- SW Ghana only, 75.6% PA,
#                             positive-labels-only, minetype 1=artisanal / 2=industrial
#   Maus et al. (2022) v2     global_mining_polygons_v2.gpkg          -- global manual delineation
#                             of mining LAND USE (~2019). Industrial/large-scale biased; misses
#                             most artisanal -> expect low recall of galamsey, large our_only.
#   Tang & Werner (2023)      74548 global polygons (EASE-Grid)       -- global, deep learning on
#                             high-res imagery (~2019). Better small-mine coverage than Maus, still
#                             conservative on the smallest pits. Ghana not individually validated.
#
# NONE is ground truth. Read every number as AGREEMENT / triangulation, not accuracy. Consistent
# under-coverage across ALL THREE where we flag mining is the interesting signal (either we over-
# predict, or we are catching artisanal activity the others miss -- the spatial pattern tells which).
#
# Two regions:
#   bar_hull : convex hull of Barenblitt 2019 (SW study-area proxy). Barenblitt is only compared
#              here -- outside its hull it is silent, not zero (CLAUDE.md).
#   ghana    : national admin0. Maus / Tang & Werner / any_product are compared here too (they are
#              national); Barenblitt rows are hull-only.
#
# For each region x product x cutoff, within the region, report km2 of:
#   both       (we and the product agree)
#   our_only   (we flag, product does not -- genuine FP + product omissions + growth since ~2019)
#   prod_only  (product flags, we do not -- our omissions, or revegetated/relict footprint)
# plus our_km2, prod_km2, recall_vs_prod = both/prod_km2, agree_frac = both/our_km2,
# our_over_prod = our_km2/prod_km2.
#
# Cutoff sweep uses the raw prob tiles mine_prob_ghana_c4_2019_t* + an urban knockout chosen by
# the MASK switch (ghsl / dw / ghsl_dw / none) so the year- and area-matched comparison reflects
# the build_03 config under consideration. It does NOT use the deployed mine_mask_ghana_c4_2019
# asset (baked at cutoff 45 + GHSL + industrial); a cutoff = "deployed" row reads that asset as-is
# for reference, so it differs from the sweep's cutoff-45 point by the MASK choice + industrial excl.
#
# Output: outputs/tables/product_overlap.csv + console tables (one per region).
# Run INTERACTIVELY. Prerequisite: build_02 Section 10 (prob tiles) + build_03 (masks) have run.

#### 1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, sf, here, tidyverse, janitor, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, here::here
)

UTM30N        <- 32630
EE_PROJECT    <- "rgee-auth-tillam"
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)

#### 2. Parameters ####
YEAR    <- 2019L
CUTOFFS <- c(45L, 55L, 60L, 70L, 80L)
SCALE   <- 100L                  # 30 m is Barenblitt-native; 100 m is ~10x faster, fine for area

GHSL_EPOCHS       <- c(1975, 1980, 1985, 1990, 1995, 2000, 2005, 2010, 2015, 2020, 2025)
URBAN_THRESH_100M <- 2000        # same as build_03

# Which urban knockout to apply to the cutoff-sweep prediction, so the year/area-matched
# comparison reflects the config being considered:
#   "ghsl"    GHSL built_surface > URBAN_THRESH_100M            (build_03's current mask)
#   "ghsl_dw" GHSL OR Dynamic World mean P(built) > DW_BUILT_MIN (the 2026-09-08 candidate)
#   "dw"      Dynamic World only
#   "none"    raw cutoff, no urban knockout
MASK        <- "ghsl_dw"
DW_BUILT_MIN <- 0.20            # only used when MASK involves DW (DW starts 2015 -> fine for 2019)

BAR_2019_SHP <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")
MAUS_GPKG    <- here("data", "raw", "mining_mausetal", "global_mining_polygons_v2.gpkg")
TW_SHP       <- here("data", "raw", "mining_tangwerner", "74548_projected polygons.shp")
GHA_ADMIN0   <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp")

out_csv <- here("outputs", "tables", "product_overlap.csv")
dir.create(dirname(out_csv), recursive = TRUE, showWarnings = FALSE)

#### 3. Authenticate ####
ee_Authenticate()
ee_Initialize(drive = TRUE, project = EE_PROJECT)
ee_check()

#### 4. Local geometry prep ####
# s2 OFF for the whole script -- raw Barenblitt and both global products have degenerate edges
# that trip s2's stricter validity checks; planar ops on ~country-extent data are fine here.
suppressMessages(sf_use_s2(FALSE))

geom_as_ee <- function(x) {                      # attribute-free sf (lon/lat) -> ee FC
  g <- st_zm(st_geometry(x), drop = TRUE)
  g <- g[!st_is_empty(g)]
  sfx <- st_sf(geometry = g)
  st_crs(sfx) <- st_crs(4326)
  sf_as_ee(sfx)
}

dissolve_4326 <- function(sfobj) {               # -> single simplified (multi)polygon, EPSG:4326
  g <- sfobj |> st_make_valid() |> st_transform(UTM30N) |> st_geometry() |> st_union()
  g <- st_simplify(g, dTolerance = 10)          # 10 m -- negligible vs 30 m Barenblitt native
  st_transform(st_sf(geometry = g), 4326)
}

ghana_sf <- st_read(GHA_ADMIN0, quiet = TRUE) |> st_make_valid() |>
  st_geometry() |> st_union() |> st_transform(4326)
ghana_sf <- st_sf(geometry = ghana_sf)
ghana_ee <- geom_as_ee(ghana_sf)$geometry()

clip_to_ghana <- function(x) {                   # global product -> Ghana-only sf (loose, pre-dissolve)
  x |> st_zm(drop = TRUE) |> st_transform(4326) |> st_make_valid() |>
    st_filter(ghana_sf, .predicate = st_intersects)
}

bar19 <- st_read(BAR_2019_SHP, quiet = TRUE) |> clean_names()

# convex hull of all Barenblitt 2019 features = SW study-area proxy
hull <- bar19 |> st_make_valid() |> st_geometry() |> st_combine() |> st_convex_hull() |>
  st_transform(4326) |> (\(g) st_sf(geometry = g))()
hull_ee <- geom_as_ee(hull)$geometry()

message("reading + clipping global products to Ghana ...")
maus_raw <- st_read(MAUS_GPKG, quiet = TRUE)
tw_raw   <- st_read(TW_SHP,    quiet = TRUE)
message(sprintf("  Maus: %d global polygons", nrow(maus_raw)))
message(sprintf("  Tang & Werner: %d global polygons", nrow(tw_raw)))
maus_gh <- clip_to_ghana(maus_raw)
tw_gh   <- clip_to_ghana(tw_raw)
message(sprintf("  Maus in Ghana: %d ; Tang & Werner in Ghana: %d", nrow(maus_gh), nrow(tw_gh)))

message("dissolving product geometries ...")
d_bar_all <- dissolve_4326(bar19)
d_bar_art <- dissolve_4326(filter(bar19, mine_type == 1))
d_maus    <- dissolve_4326(maus_gh)
d_tw      <- dissolve_4326(tw_gh)
d_any     <- do.call(rbind, list(d_bar_all, d_maus, d_tw)) |> st_union() |>
  (\(g) st_sf(geometry = st_geometry(g)))()

# product label -> (dissolved sf, regions it is meaningfully compared in)
PRODUCTS <- list(
  barenblitt_all       = list(sf = d_bar_all, regions = "bar_hull"),
  barenblitt_artisanal = list(sf = d_bar_art, regions = "bar_hull"),
  maus                 = list(sf = d_maus,    regions = c("bar_hull", "ghana")),
  tang_werner          = list(sf = d_tw,      regions = c("bar_hull", "ghana")),
  any_product          = list(sf = d_any,     regions = c("bar_hull", "ghana"))
)
REGION_GEOM <- list(bar_hull = hull_ee, ghana = ghana_ee)

prod_img <- function(geom_sf) {
  ee$Image()$byte()$paint(featureCollection = geom_as_ee(geom_sf), color = 1)$unmask(0)$gt(0)
}

#### 5. Our prediction layers (2019) ####
asset_ids <- {
  a <- ee$data$listAssets(EE_ASSET_HOME)$assets
  vapply(a, function(x) if (!is.null(x$id)) x$id else x$name, character(1))
}
prob_mosaic_2019 <- {
  ids <- asset_ids[grepl(sprintf("/mine_prob_ghana_c4_%d_t", YEAR), asset_ids)]
  if (!length(ids)) stop(sprintf("no mine_prob_ghana_c4_%d_t* tiles found", YEAR))
  message(sprintf("  %d: %d prob tiles", YEAR, length(ids)))
  ee$ImageCollection(lapply(ids, function(i) ee$Image(i)))$mosaic()$rename("mine_prob")
}
# urban knockout per MASK -- a 1 = "keep" image (0 where knocked out), so `our$updateMask(keep)`
keep_mask_2019 <- {
  epoch <- GHSL_EPOCHS[which.min(abs(YEAR - GHSL_EPOCHS))]
  ghsl <- ee$ImageCollection("JRC/GHSL/P2023A/GHS_BUILT_S")$
    filterDate(sprintf("%d-01-01", epoch), sprintf("%d-01-01", epoch + 1L))$first()$
    select("built_surface")$gt(URBAN_THRESH_100M)                 # 1 = GHSL urban
  dw <- ee$ImageCollection("GOOGLE/DYNAMICWORLD/V1")$
    filterDate(sprintf("%d-01-01", YEAR), sprintf("%d-01-01", YEAR + 1L))$
    select("built")$mean()$unmask(0)$gt(DW_BUILT_MIN)              # 1 = DW built
  knock <- switch(MASK,
    ghsl    = ghsl,
    dw      = dw,
    ghsl_dw = ghsl$Or(dw),
    none    = ee$Image(0),
    stop("MASK must be one of ghsl / dw / ghsl_dw / none"))
  knock$Not()                                                     # 1 = keep
}
message(sprintf("urban knockout: MASK = '%s'", MASK))

deployed_mask_2019 <- ee$Image(file.path(EE_ASSET_HOME, sprintf("mine_mask_ghana_c4_%d", YEAR)))$
  gt(0)$unmask(0)

#### 6. Confusion km2 in one grouped reduce ####
pxkm2 <- ee$Image$pixelArea()$divide(1e6)$rename("area")

confusion_km2 <- function(our_bin01, prod_bin01, region_geom) {
  combo <- our_bin01$multiply(2)$add(prod_bin01)$rename("combo")   # 0 none,1 prod-only,2 our-only,3 both
  grp <- pxkm2$addBands(combo)$reduceRegion(
    reducer = ee$Reducer$sum()$group(groupField = 1L, groupName = "combo"),
    geometry = region_geom, scale = SCALE, maxPixels = 1e13, bestEffort = FALSE, tileScale = 8
  )$getInfo()
  v <- c(`0` = 0, `1` = 0, `2` = 0, `3` = 0)
  for (g in grp$groups) v[as.character(g$combo)] <- g$sum
  tibble(both = v[["3"]], our_only = v[["2"]], prod_only = v[["1"]],
         our_km2 = v[["2"]] + v[["3"]], prod_km2 = v[["1"]] + v[["3"]])
}

#### 7. Loop: region x product x cutoff ####
rows <- list()
for (rlab in names(REGION_GEOM)) {
  rgeom <- REGION_GEOM[[rlab]]
  for (plab in names(PRODUCTS)) {
    if (!rlab %in% PRODUCTS[[plab]]$regions) next
    pimg <- prod_img(PRODUCTS[[plab]]$sf)

    rows[[length(rows) + 1]] <- confusion_km2(deployed_mask_2019, pimg, rgeom) |>
      mutate(region = rlab, product = plab, cutoff = "deployed", .before = 1)

    for (ct in CUTOFFS) {
      our <- prob_mosaic_2019$gte(ct)$updateMask(keep_mask_2019)$unmask(0)
      rows[[length(rows) + 1]] <- confusion_km2(our, pimg, rgeom) |>
        mutate(region = rlab, product = plab, cutoff = as.character(ct), .before = 1)
    }
  }
}

res <- bind_rows(rows) |>
  mutate(mask = MASK,
         recall_vs_prod = both / prod_km2,
         agree_frac     = both / our_km2,
         our_over_prod   = our_km2 / prod_km2) |>
  select(region, product, cutoff, mask, everything()) |>
  arrange(region, product, match(cutoff, c("deployed", as.character(CUTOFFS))))

write_csv(res, out_csv)

#### 8. Console report ####
for (rlab in names(REGION_GEOM)) {
  cat(sprintf("\n=== our 2019 layer vs external products, region = %s, at %d m ===\n", rlab, SCALE))
  res |>
    filter(region == rlab) |>
    select(-region) |>
    mutate(across(where(is.numeric), ~ round(.x, 2))) |>
    as.data.frame() |>
    print(row.names = FALSE)
}
cat(sprintf("\nWrote %s\n", out_csv))
cat("\nNone of these is ground truth. Barenblitt = SW artisanal benchmark (positive-only, 75.6% PA);\n",
    "Maus = industrial-biased, misses galamsey; Tang & Werner = better small-mine coverage, still\n",
    "conservative. our_only large vs ALL THREE, spread across farmland not hugging their polygons,\n",
    "=> over-prediction. our_only large but river-/pit-shaped near known belts => real artisanal\n",
    "activity the global products omit. Look for the cutoff where our_over_prod approaches ~1-2x\n",
    "Tang & Werner while recall_vs_prod stays high.\n", sep = "")
