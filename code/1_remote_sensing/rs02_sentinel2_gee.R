# rs02_sentinel2_gee.R
# Getting Sentinel-2 images for Ghanaian districts
# Mirrors the structure of rs01_landsat_gee.R; see that script for Landsat equivalents.
# Key differences vs Landsat:
#   - Single collection COPERNICUS/S2_SR_HARMONIZED (no L8/L9 merge)
#   - SCL-band cloud masking instead of QA_PIXEL bitwise flags
#   - 10 m native resolution (10/20 m bands; GEE reprojects on export/display)
#   - Reflectance scaling: DN / 10000 (vs Landsat × 0.0000275 − 0.2)
#   - Data available from June 2015; full 5-day revisit from mid-2017 (S2A + S2B)

####1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, googledrive, leaflet, tidyverse, here, sf, janitor, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)

####2. Authenticate ####
rgee::ee_Authenticate()
rgee::ee_Initialize(drive = TRUE)
ee_check()
googledrive::drive_auth()

####3. Ghana Shapefile ####

# Shapefiles already unzipped by rs01_landsat_gee.R — read directly.
gha_country   <- st_read(here("data", "raw", "shapefiles","hdx_gh_admin","gha_admin0.shp"))
gha_regions   <- st_read(here("data", "raw", "shapefiles","hdx_gh_admin", "gha_admin1.shp"))
gha_districts <- st_read(here("data", "raw", "shapefiles","hdx_gh_admin", "gha_admin2.shp"))

mining_2007_2017 <- st_read(here("data", "raw", "barenblitt",
                                 "MiningConversion_2007-2017Vec.shp")) |>
  clean_names()

mining_2019 <- st_read(here("data", "raw", "barenblitt",
                             "FullConversiontoMiningExtent2019.shp")) |>
  clean_names() |>
  mutate(
    mine_label = factor(mine_type,
                        levels = c(1, 2),
                        labels = c("Artisanal", "Industrial"))
  )

# Flag known galamsey-affected districts (same list as rs01_landsat_gee.R)
mining_pattern <- str_c(c(
  "Tarkwa", "Prestea", "Wassa Amenfi East", "Wassa Amenfi West",
  "Bibiani", "Wassa East",
  "Obuasi", "Amansie Central", "Adansi North", "Bosome Freho",
  "Abuakwa South", "Birim Central", "Fanteakwa", "Kwaebibirem",
  "Upper Denkyira",
  "Wa East", "Wa West", "Nadowli", "Bole"
), collapse = "|")

gha_districts <- gha_districts |>
  mutate(galamsey = str_detect(adm2_name, mining_pattern))

####4. Helper Functions ####

# SCL classes masked: 3 = cloud shadow, 8 = cloud medium prob,
# 9 = cloud high prob, 10 = thin cirrus, 11 = snow/ice.
# SCL is computed per-pixel — more accurate for tropical haze than QA60 flags.
mask_clouds_s2 <- function(image) {
  scl <- image$select("SCL")
  bad <- scl$eq(3L)$Or(scl$eq(8L))$Or(scl$eq(9L))$
    Or(scl$eq(10L))$Or(scl$eq(11L))
  image$updateMask(bad$Not())
}

# Builds a cloud-minimised median composite over a 2-year window.
# S2 has ~5-day revisit (both satellites), so one year is usually enough,
# but the 2-year window matches the Landsat compositing strategy and helps
# fill persistent cloud gaps in Ghana's wet-season months (Apr–Oct).
# Returns raw DN (0–10000 scale) for the display path.
make_composite_s2 <- function(start_year, bounds) {
  ee$ImageCollection("COPERNICUS/S2_SR_HARMONIZED")$
    filterBounds(bounds)$
    filterDate(paste0(start_year, "-01-01"), paste0(start_year + 1, "-12-31"))$
    filter(ee$Filter$lt("CLOUDY_PIXEL_PERCENTAGE", 70))$
    map(mask_clouds_s2)$
    select(
      c("B2",   "B3",    "B4",  "B8",  "B11",  "B12"),
      c("blue", "green", "red", "nir", "swir1", "swir2")
    )$
    median()$
    clip(bounds)
}

####5. District Comparison ####

# False colour SWIR1-NIR-Red (same interpretation as Landsat):
#   Bright green  -> dense vegetation (high NIR = B8)
#   Magenta / tan -> bare soil, mining disturbance (high SWIR1 = B11)
#   Dark blue     -> water, turbid mining ponds
# min/max tuned to S2 raw DN (0-10000 scale); gamma slightly higher than
# Landsat to compensate for S2's generally higher dynamic range.
vis_false_s2 <- list(
  bands = c("swir1", "nir", "red"),
  min   = 200,
  max   = 3500,
  gamma = 1.4
)

compare_district_s2 <- function(district_name, year1, year2) {
  district_sf <- gha_districts |> filter(adm2_name == district_name)
  if (nrow(district_sf) == 0) stop("District not found: ", district_name)

  bbox <- st_bbox(district_sf)
  bounds <- ee$Geometry$Rectangle(
    coords   = c(bbox[["xmin"]], bbox[["ymin"]], bbox[["xmax"]], bbox[["ymax"]]),
    proj     = "EPSG:4326",
    geodesic = FALSE
  )

  img1 <- make_composite_s2(year1, bounds)
  img2 <- make_composite_s2(year2, bounds)

  Map$setCenter(
    lon  = mean(c(bbox[["xmin"]], bbox[["xmax"]])),
    lat  = mean(c(bbox[["ymin"]], bbox[["ymax"]])),
    zoom = 11
  )

  district_ee <- sf_as_ee(select(district_sf, adm2_name))
  outline <- ee$Image()$byte()$paint(
    featureCollection = district_ee,
    color = 1,
    width = 2
  )
  outline_layer <- Map$addLayer(outline, list(palette = "FF0000"), "District boundary")

  label1 <- paste0(district_name, " S2 ", year1, "-", year1 + 1)
  label2 <- paste0(district_name, " S2 ", year2, "-", year2 + 1)

  map1 <- Map$addLayer(img1, vis_false_s2, label1) + outline_layer
  map2 <- Map$addLayer(img2, vis_false_s2, label2) + outline_layer

  map1 | map2
}

# -- Example ------------------------------------------------------------------
compare_district_s2("Atiwa West", 2017, 2024)

####6. Spectral Indices (Phase 1) ####
district_extent_s2 <- function(district_name) {
  district_sf <- gha_districts |> filter(adm2_name == district_name)
  if (nrow(district_sf) == 0) stop("District not found: ", district_name)

  bbox <- st_bbox(district_sf)
  list(
    bounds = ee$Geometry$Rectangle(
      coords   = c(bbox[["xmin"]], bbox[["ymin"]], bbox[["xmax"]], bbox[["ymax"]]),
      proj     = "EPSG:4326",
      geodesic = FALSE
    ),
    outline = ee$Image()$byte()$paint(
      featureCollection = sf_as_ee(select(district_sf, adm2_name)),
      color = 1,
      width = 2
    ),
    lon = mean(c(bbox[["xmin"]], bbox[["xmax"]])),
    lat = mean(c(bbox[["ymin"]], bbox[["ymax"]]))
  )
}

# Identical index formulas to rs01_landsat_gee.R — operates on 0-1 reflectance regardless
# of sensor. Galamsey fingerprint: low NDVI + high BSI + high MNDWI + high NDTI.
add_indices_s2 <- function(image) {
  ndvi  <- image$normalizedDifference(c("nir", "red"))$rename("ndvi")
  mndwi <- image$normalizedDifference(c("green", "swir1"))$rename("mndwi")
  ndti  <- image$normalizedDifference(c("red", "green"))$rename("ndti")

  sw_r <- image$select("swir1")$add(image$select("red"))
  n_b  <- image$select("nir")$add(image$select("blue"))
  bsi  <- sw_r$subtract(n_b)$divide(sw_r$add(n_b))$rename("bsi")

  image$addBands(ndvi)$addBands(mndwi)$addBands(ndti)$addBands(bsi)
}

# Analysis path: scale DN → reflectance first, then compute indices.
# S2 Level-2A DN = reflectance × 10000 (no additive offset unlike Landsat C2L2).
indexed_composite_s2 <- function(start_year, bounds) {
  sr <- make_composite_s2(start_year, bounds)$divide(10000)
  add_indices_s2(sr)
}

# Vis params are sensor-agnostic (reflectance range 0-1); identical to rs01_landsat_gee.R.
vis_ndvi  <- list(min = 0,    max = 0.8, palette = c("8c510a", "f6e8c3", "01665e"))
vis_bsi   <- list(min = -0.3, max = 0.4, palette = c("01665e", "f6e8c3", "8c510a"))
vis_mndwi <- list(min = -0.4, max = 0.4, palette = c("ffffff", "9ecae1", "08519c"))
vis_ndti  <- list(min = -0.2, max = 0.3, palette = c("2166ac", "f7f7f7", "b2182b"))

view_indices_s2 <- function(district_name, start_year) {
  ext <- district_extent_s2(district_name)
  img <- indexed_composite_s2(start_year, ext$bounds)

  Map$setCenter(lon = ext$lon, lat = ext$lat, zoom = 11)
  outline_layer <- Map$addLayer(ext$outline, list(palette = "FF0000"),
                                "District boundary")

  Map$addLayer(img$select("ndvi"),  vis_ndvi,  "NDVI") +
    Map$addLayer(img$select("bsi"),   vis_bsi,   "BSI") +
    Map$addLayer(img$select("mndwi"), vis_mndwi, "MNDWI") +
    Map$addLayer(img$select("ndti"),  vis_ndti,  "NDTI (turbidity)") +
    outline_layer
}

# -- Example ------------------------------------------------------------------
view_indices_s2("Atiwa West", 2024)

####7. Change Detection (Phase 2) ####

vis_dndvi_s2 <- list(min = -0.5, max = 0.5,
                     palette = c("b2182b", "f7f7f7", "1a9850"))

detect_mining_change_s2 <- function(district_name, year1, year2,
                                    ndvi_drop = -0.15, bsi_gain = 0.10) {
  ext  <- district_extent_s2(district_name)
  img1 <- indexed_composite_s2(year1, ext$bounds)
  img2 <- indexed_composite_s2(year2, ext$bounds)

  d_ndvi <- img2$select("ndvi")$subtract(img1$select("ndvi"))$rename("d_ndvi")
  d_bsi  <- img2$select("bsi")$subtract(img1$select("bsi"))$rename("d_bsi")

  candidate <- d_ndvi$lt(ndvi_drop)$And(d_bsi$gt(bsi_gain))

  Map$setCenter(lon = ext$lon, lat = ext$lat, zoom = 11)
  outline_layer <- Map$addLayer(ext$outline, list(palette = "FF0000"),
                                "District boundary")

  Map$addLayer(d_ndvi, vis_dndvi_s2, "Delta NDVI") +
    Map$addLayer(candidate$selfMask(),
                 list(palette = "ff00ff", min = 1, max = 1),
                 "Mining candidate") +
    outline_layer
}

# -- Example ------------------------------------------------------------------
# S2 starts June 2015; first complete calendar year is 2016.
detect_mining_change_s2("Atiwa West", 2017, 2024)

####8. Barenblitt et al. Data ####
pal <- colorFactor(
  palette = c("red", "blue"),
  domain  = mining_2019$mine_label
)

m <- leaflet(mining_2019) |>
  addProviderTiles(providers$OpenStreetMap,     group = "Street Map") |>
  addProviderTiles(providers$Esri.WorldImagery, group = "Satellite") |>
  addPolygons(
    fillColor  = ~pal(mine_label),
    color      = "black",
    weight     = 1,
    fillOpacity = 0.6,
    popup      = ~paste("<b>Mine type:</b>", mine_label),
    group      = "Mine Type"
  ) |>
  addLegend(
    position = "bottomright",
    pal      = pal,
    values   = ~mine_label,
    title    = "Mine Type"
  ) |>
  addLayersControl(
    baseGroups    = c("Street Map", "Satellite"),
    overlayGroups = "Mine Type",
    options       = layersControlOptions(collapsed = FALSE)
  )

m
