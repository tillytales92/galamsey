# explore_landsat_sentinel.R
# Interactive Landsat 8/9 + Sentinel-2 exploration of galamsey spectral signatures and
# district-level change detection. Merged 2026-08-04 from the former rs01_landsat_gee.R
# (Landsat) and rs02_sentinel2_gee.R (Sentinel-2) -- the two mirrored each other
# section-for-section (same district-comparison / index / change-detection logic, just
# different collections, cloud masks, and reflectance scaling), so one sensor-parameterized
# script replaces two near-duplicates. Pass sensor = "landsat" or sensor = "s2" to
# compare_district() / view_indices() / detect_mining_change().
#
# Not a panel-builder: toggleable Map$addLayer overlays + one leaflet map, for visual
# review only. See build_02_embedding_classifier.R for the production classifier.
#
# Sensor differences (handled via the SENSORS dispatch table in Section 4):
#   - Landsat: L8+L9 merge, QA_PIXEL bitwise cloud mask, reflectance = DN x 0.0000275 - 0.2
#   - Sentinel-2: single COPERNICUS/S2_SR_HARMONIZED collection, per-pixel SCL cloud mask
#     (more accurate for tropical haze than a bitwise QA flag), reflectance = DN / 10000,
#     10 m native resolution, data from June 2015 (first complete calendar year 2016)
# Index formulas and vis params (Section 6) are identical for both once on 0-1 reflectance.

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

####3. Ghana shapefile + Barenblitt data ####

# -- 3a. Unzip ----------------------------------------------------------------
unzip(here("data", "raw", "shapefiles", "gha_admin_boundaries.shp.zip"),
      exdir = here("data", "raw", "shapefiles"))
unzip(here("data", "raw", "barenblitt", "MiningConversion_2007-2017Vec.zip"),
      exdir = here("data", "raw", "barenblitt"))
unzip(here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.zip"),
      exdir = here("data", "raw", "barenblitt"))

# -- 3b. Read shapefiles -------------------------------------------------------
gha_country   <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp"))
gha_regions   <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin1.shp"))
gha_districts <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin2.shp"))

mining_2007_2017 <- st_read(here("data", "raw", "barenblitt",
                                 "MiningConversion_2007-2017Vec.shp")) |>
  clean_names()
# shows yearly changes in land conversion

mining_2019 <- st_read(here("data", "raw", "barenblitt",
                            "FullConversiontoMiningExtent2019.shp")) |>
  clean_names() |>
  mutate(mine_label = factor(mine_type, levels = c(1, 2),
                            labels = c("Artisanal", "Industrial")))
# shows total land converted to gold mining between 2005-2019 (each polygon is one mine)
# 1 = artisanal, 2 = industrial, aream2 and km2 show polygon area

# -- 3c. Flag galamsey-affected districts -------------------------------------
# Matches on adm2_name using key terms from known hotspot lists.
# Notes: Akwatia/New Abirem fall within Kwaebibirem; Manso Nkwanta is not a
# standalone district in this shapefile; Bibiani matches Bibiani-Anhwiaso-Bekwai.
mining_pattern <- str_c(c(
  # Western & Western North
  "Tarkwa", "Prestea", "Wassa Amenfi East", "Wassa Amenfi West",
  "Bibiani", "Wassa East",
  # Ashanti
  "Obuasi", "Amansie Central", "Adansi North", "Bosome Freho",
  # Eastern
  "Abuakwa South", "Birim Central", "Fanteakwa", "Kwaebibirem",
  # Central
  "Upper Denkyira",
  # Upper West & Savannah
  "Wa East", "Wa West", "Nadowli", "Bole"
), collapse = "|")

gha_districts <- gha_districts |>
  mutate(galamsey = str_detect(adm2_name, mining_pattern))

# test plot
gha_districts |> ggplot() + geom_sf(aes(fill = galamsey))

gha_districts |>
  st_drop_geometry() |>
  filter(galamsey == TRUE) |>
  distinct(adm2_name)

####4. Sensor-specific composite builders ####

# -- Landsat: L8+L9 merge, QA_PIXEL bitwise mask (bit 3 = cloud, bit 4 = cloud shadow) --
mask_clouds_landsat <- function(image) {
  qa <- image$select("QA_PIXEL")
  image$updateMask(
    qa$bitwiseAnd(8L)$eq(0L)$And(    # no cloud (bit 3)
      qa$bitwiseAnd(16L)$eq(0L))     # no cloud shadow (bit 4)
  )
}

# Merges L8 + L9 for maximum scene density. Composites a 2-year window
# (start_year .. start_year + 1) to fill cloud gaps common in Ghana's forest
# belt. The CLOUD_COVER < 70 filter only drops near-useless scenes; the
# per-pixel QA mask does the real cloud removal.
make_composite_landsat <- function(start_year, bounds) {
  l8 <- ee$ImageCollection("LANDSAT/LC08/C02/T1_L2")
  l9 <- ee$ImageCollection("LANDSAT/LC09/C02/T1_L2")

  l8$merge(l9)$
    filterBounds(bounds)$
    filterDate(paste0(start_year, "-01-01"), paste0(start_year + 1, "-12-31"))$
    filter(ee$Filter$lt("CLOUD_COVER", 70))$
    map(mask_clouds_landsat)$
    select(
      c("SR_B2", "SR_B3", "SR_B4", "SR_B5", "SR_B6", "SR_B7"),
      c("blue",  "green", "red",   "nir",   "swir1", "swir2")
    )$
    median()$
    clip(bounds)
}

# -- Sentinel-2: single collection, per-pixel SCL cloud mask --
# SCL classes masked: 3 = cloud shadow, 8 = cloud medium prob,
# 9 = cloud high prob, 10 = thin cirrus, 11 = snow/ice.
mask_clouds_s2 <- function(image) {
  scl <- image$select("SCL")
  bad <- scl$eq(3L)$Or(scl$eq(8L))$Or(scl$eq(9L))$
    Or(scl$eq(10L))$Or(scl$eq(11L))
  image$updateMask(bad$Not())
}

# Builds a cloud-minimised median composite over a 2-year window.
# S2 has ~5-day revisit (both satellites), so one year is usually enough,
# but the 2-year window matches the Landsat compositing strategy and helps
# fill persistent cloud gaps in Ghana's wet-season months (Apr-Oct).
# Returns raw DN (0-10000 scale) for the display path.
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

# Dispatch table: everything sensor-specific (composite builder, reflectance
# scaling, false-colour vis params tuned to each sensor's DN range) lives here,
# so Sections 5-7 below are written once and work for either sensor.
SENSORS <- list(
  landsat = list(
    composite      = make_composite_landsat,
    to_reflectance = function(img) img$multiply(0.0000275)$add(-0.2),
    vis_false      = list(bands = c("swir1", "nir", "red"), min = 7500, max = 22000, gamma = 1.2),
    label          = "Landsat"
  ),
  s2 = list(
    composite      = make_composite_s2,
    to_reflectance = function(img) img$divide(10000),
    vis_false      = list(bands = c("swir1", "nir", "red"), min = 200, max = 3500, gamma = 1.4),
    label          = "S2"
  )
)

####5. District comparison (false-colour, sensor-agnostic) ####

# False colour SWIR1-NIR-Red:
#   Bright green  -> dense vegetation  (high NIR)
#   Magenta / tan -> bare soil, mining disturbance (high SWIR1, low NIR)
#   Dark blue     -> water, turbid mining ponds
compare_district <- function(sensor, district_name, year1, year2) {
  cfg <- SENSORS[[sensor]]
  district_sf <- gha_districts |> filter(adm2_name == district_name)
  if (nrow(district_sf) == 0) stop("District not found: ", district_name)

  bbox <- st_bbox(district_sf)
  bounds <- ee$Geometry$Rectangle(
    coords   = c(bbox[["xmin"]], bbox[["ymin"]], bbox[["xmax"]], bbox[["ymax"]]),
    proj     = "EPSG:4326",
    geodesic = FALSE
  )

  img1 <- cfg$composite(year1, bounds)
  img2 <- cfg$composite(year2, bounds)

  # setCenter sets the viewport as a side effect; it returns nothing usable,
  # so call it as a statement before addLayer rather than combining with `+`.
  Map$setCenter(
    lon  = mean(c(bbox[["xmin"]], bbox[["xmax"]])),
    lat  = mean(c(bbox[["ymin"]], bbox[["ymax"]])),
    zoom = 11
  )

  # District boundary as a red outline. select() drops the NA date columns
  # that break the sf -> EE conversion. paint() onto an empty (masked) image
  # draws only the edges, so the interior stays transparent over the imagery.
  district_ee <- sf_as_ee(select(district_sf, adm2_name))
  outline <- ee$Image()$byte()$paint(featureCollection = district_ee, color = 1, width = 2)
  outline_layer <- Map$addLayer(outline, list(palette = "FF0000"), "District boundary")

  label1 <- paste0(district_name, " ", cfg$label, " ", year1, "-", year1 + 1)
  label2 <- paste0(district_name, " ", cfg$label, " ", year2, "-", year2 + 1)

  map1 <- Map$addLayer(img1, cfg$vis_false, label1) + outline_layer
  map2 <- Map$addLayer(img2, cfg$vis_false, label2) + outline_layer

  map1 | map2
}

# -- Examples -------------------------------------------------------------
compare_district("landsat", "Upper Denkyira West", 2015, 2024)
compare_district("s2",      "Atiwa West",          2017, 2024)

####6. Spectral indices (sensor-agnostic) ####

# Looks up a district by adm2_name and returns what the index/change functions
# need: an EE bbox geometry (filter/clip), a painted boundary image (red
# outline overlay) and centre coords (viewport). Purely geometric -- identical
# regardless of sensor.
district_extent <- function(district_name) {
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
      color = 1, width = 2
    ),
    lon = mean(c(bbox[["xmin"]], bbox[["xmax"]])),
    lat = mean(c(bbox[["ymin"]], bbox[["ymax"]]))
  )
}

# Appends index bands to a surface-reflectance image. Operates on 0-1
# reflectance, so this is identical for both sensors once to_reflectance() has
# run. Galamsey fingerprint:
#   NDVI  low                 -> vegetation cleared
#   BSI   high                -> exposed laterite / tailings
#   MNDWI high                -> standing water (mining pits / ponds)
#   NDTI  high *within water* -> sediment-laden, turbid ponds (galamsey-specific)
add_indices <- function(image) {
  ndvi  <- image$normalizedDifference(c("nir", "red"))$rename("ndvi")
  mndwi <- image$normalizedDifference(c("green", "swir1"))$rename("mndwi")
  ndti  <- image$normalizedDifference(c("red", "green"))$rename("ndti")

  # BSI = ((SWIR1 + Red) - (NIR + Blue)) / ((SWIR1 + Red) + (NIR + Blue))
  sw_r <- image$select("swir1")$add(image$select("red"))
  n_b  <- image$select("nir")$add(image$select("blue"))
  bsi  <- sw_r$subtract(n_b)$divide(sw_r$add(n_b))$rename("bsi")

  image$addBands(ndvi)$addBands(mndwi)$addBands(ndti)$addBands(bsi)
}

# Analysis-side composite: same compositing as the sensor's raw composite but
# scaled to true surface reflectance, with index bands appended. Kept separate
# from the display path so compare_district()/vis_false stay on raw DN.
indexed_composite <- function(sensor, start_year, bounds) {
  cfg <- SENSORS[[sensor]]
  add_indices(cfg$to_reflectance(cfg$composite(start_year, bounds)))
}

vis_ndvi  <- list(min = 0,    max = 0.8, palette = c("8c510a", "f6e8c3", "01665e"))
vis_bsi   <- list(min = -0.3, max = 0.4, palette = c("01665e", "f6e8c3", "8c510a"))
vis_mndwi <- list(min = -0.4, max = 0.4, palette = c("ffffff", "9ecae1", "08519c"))
vis_ndti  <- list(min = -0.2, max = 0.3, palette = c("2166ac", "f7f7f7", "b2182b"))

# One district, one period: every index as a toggleable layer for visual review.
view_indices <- function(sensor, district_name, start_year) {
  ext <- district_extent(district_name)
  img <- indexed_composite(sensor, start_year, ext$bounds)

  Map$setCenter(lon = ext$lon, lat = ext$lat, zoom = 11)
  outline_layer <- Map$addLayer(ext$outline, list(palette = "FF0000"), "District boundary")

  Map$addLayer(img$select("ndvi"),  vis_ndvi,  "NDVI") +
    Map$addLayer(img$select("bsi"),   vis_bsi,   "BSI") +
    Map$addLayer(img$select("mndwi"), vis_mndwi, "MNDWI") +
    Map$addLayer(img$select("ndti"),  vis_ndti,  "NDTI (turbidity)") +
    outline_layer
}

# -- Examples -------------------------------------------------------------
view_indices("landsat", "Atiwa West", 2024)
view_indices("s2",      "Atiwa West", 2024)

####7. Change detection (sensor-agnostic) ####

# Diverging palette for NDVI change: red = vegetation loss, green = gain.
vis_dndvi <- list(min = -0.5, max = 0.5, palette = c("b2182b", "f7f7f7", "1a9850"))

# Flags mining candidates: pixels that BOTH lost vegetation and gained
# bare-soil signal between the two periods. Defaults are conservative starting
# points -- calibrate ndvi_drop / bsi_gain against known sites (and the
# Barenblitt extent data) before trusting the candidate mask.
detect_mining_change <- function(sensor, district_name, year1, year2,
                                 ndvi_drop = -0.15, bsi_gain = 0.10) {
  ext  <- district_extent(district_name)
  img1 <- indexed_composite(sensor, year1, ext$bounds)
  img2 <- indexed_composite(sensor, year2, ext$bounds)

  d_ndvi <- img2$select("ndvi")$subtract(img1$select("ndvi"))$rename("d_ndvi")
  d_bsi  <- img2$select("bsi")$subtract(img1$select("bsi"))$rename("d_bsi")

  candidate <- d_ndvi$lt(ndvi_drop)$And(d_bsi$gt(bsi_gain))

  Map$setCenter(lon = ext$lon, lat = ext$lat, zoom = 11)
  outline_layer <- Map$addLayer(ext$outline, list(palette = "FF0000"), "District boundary")

  Map$addLayer(d_ndvi, vis_dndvi, "Delta NDVI") +
    Map$addLayer(candidate$selfMask(),
                list(palette = "ff00ff", min = 1, max = 1),
                "Mining candidate") +
    outline_layer
}

# -- Examples -------------------------------------------------------------
detect_mining_change("landsat", "Atiwa West", 2015, 2024)
# S2 starts June 2015; first complete calendar year is 2016.
detect_mining_change("s2",      "Atiwa West", 2017, 2024)

####8. Barenblitt et al. mine-type leaflet map ####
# Sensor-independent -- just the Barenblitt 2019 extent by artisanal/industrial type.
pal <- colorFactor(palette = c("red", "blue"), domain = mining_2019$mine_label)

m <- leaflet(mining_2019) |>
  addProviderTiles(providers$OpenStreetMap,     group = "Street Map") |>
  addProviderTiles(providers$Esri.WorldImagery, group = "Satellite") |>
  addPolygons(
    fillColor   = ~pal(mine_label),
    color       = "black",
    weight      = 1,
    fillOpacity = 0.6,
    popup       = ~paste("<b>Mine type:</b>", mine_label),
    group       = "Mine Type"
  ) |>
  addLegend(position = "bottomright", pal = pal, values = ~mine_label, title = "Mine Type") |>
  addLayersControl(
    baseGroups    = c("Street Map", "Satellite"),
    overlayGroups = "Mine Type",
    options       = layersControlOptions(collapsed = FALSE)
  )

m
