# build_03_embedding_panel.R  — SKETCH, NOT YET RUN
# Postprocessing for build_02_embedding_classifier.R's c4/no_maus probability maps: mosaic each
# year's export tiles, threshold, mask out urban confusion, (eventually) filter small/inconsistent
# patches, exclude industrial mining, and persist a clean annual MINE MASK per year, 2017-2025.
#
# SCOPE NOTE (2026-08-19): this script's output stops at the annual 2017-2025 mine mask. It does
# NOT aggregate to the hex x year panel -- that was the plan's original Step 8, but the user
# pointed out build_04_backdating_prototype.js (CCDC onset-year dating, 2000-2016) has to run
# BEFORE aggregation, not after: build_04 extends this same "ever mined" mask backward to
# 2000-2016 (mine_onset_year_2000_2016), and the hex x year panel needs to be built from the
# MERGED 2000-2025 surface, not just 2017-2025. So the pipeline is now:
#   build_02 (train/export c4 probability tiles)
#     -> build_03 (THIS script: threshold/mask/filter -> annual 2017-2025 mine mask)
#     -> build_04 (CCDC backdate the 2017-2025 mask -> onset years for 2000-2016; needs
#        reworking first -- it still reads the OLD pre-tiling binary asset names
#        mine_prob_ghana_{yr}, not this script's output or build_02's new tiled c4 assets)
#     -> [not yet named] merge 2000-2016 onset years + 2017-2025 direct annual masks into one
#        continuous surface, THEN aggregate to the hex x year panel (b_01_cross_section-style grid)
#
# STATUS: Sections 1-4 (setup, tile-grid rebuild, mosaic, threshold) and Section 5a (permanent-
# water + coast + road knockouts) are real, runnable logic. Section 5 (GHSL 100m mask) ports
# validate_true_mines_urban_mask_100m.js's tested nearestEpochYear()/builtSurfaceForYear() logic
# into R. Sections 6a (min-patch-size) and 6b (temporal-consistency) are DELIBERATELY OFF via their
# APPLY_* flags -- min-patch-size needs validate_min_patch_size_filter.js first, the temporal rule
# is undesigned. Section 7 (industrial exclusion) is now ON (APPLY_INDUSTRIAL <- TRUE, reworked
# 2026-10-27, see below). Nothing downstream depends on 6a/6b, so the script runs end-to-end today
# as a v1 (cutoff 70 + GHSL@500 urban mask + GSW permanent-water/coast + GRIP4 road buffer +
# ICMM/Maus industrial exclusion) and is upgradeable in place.
#
# CONFIG (settled 2026-09-09, see notes/2026-09-08_build03_config_decision.md + FP-overflagging
# notes): CUTOFF 45->70 (does ~95% of the FP reduction); URBAN_THRESHOLD_100M 2000->500 (GHSL-only,
# Dynamic World dropped); + APPLY_WATER_MASK (JRC GSW occurrence>=90, no river buffer) and
# APPLY_ROAD_BUFFER (GRIP4 Africa ~35 m).
#
# INDUSTRIAL EXCLUSION (reworked 2026-10-27): the old lease-gate + Maus/Barenblitt-industrial-
# confirm recipe was deferred since 2026-09-09 because the Minerals Commission lease gpkg (d_12)
# ships degenerate 2-point rings that crash sf/GEOS and sf_as_ee(). Replaced with: ICMM's global
# mining dataset (data/raw/mining_icmm/, 16 named Ghana points, points not polygons -- no geometry
# risk; one point has a user-made location correction applied, see Section 7a) LOCATES the known
# industrial mines; Maus et al. 2022 v2 (or, at 3 mines, Tang & Werner 2023 -- see IND_MINE_CONFIG)
# polygons near each point supply the actual exclusion SHAPE. The selection mechanism is now also
# per-mine (buffer radius / touching-only / touching+contiguous, see Section 7b-7d), not one uniform
# buffer for every mine -- a 2026-10-27 visual QA pass over all 14 mines found 8 fine on the uniform
# default but 6 needing a tighter, mode-specific selection. An earlier version of this rework also
# subtracted Barenblitt
# mine_type==1 (artisanal) from the candidate as a safeguard against erasing encroaching galamsey;
# DROPPED again the same day (IND_ERASE_BAR_ART <- FALSE) once the plan shifted to manually
# reviewing/correcting the candidate per mine -- that manual QA is a better safeguard than a blind
# automated erase, which risked punching spurious holes from Barenblitt's own digitization noise.
# See Section 7 for detail.
#
# Run INTERACTIVELY: ee_Authenticate()/ee_Initialize() block on a browser login. Prerequisite:
# build_02_embedding_classifier.R Section 10 has completed (or partially completed -- Section 3
# below warns about missing tiles per year rather than failing outright).

####1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, tidyverse, sf, here, conflicted, xml2, janitor)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  here::here
)

UTM30N <- 32630
EE_PROJECT <- "rgee-auth-tillam"   # see build_02 Section 1 -- ID, never the numeric project number

####2. Authenticate ####
rgee::ee_Authenticate()
rgee::ee_Initialize(drive = TRUE, project = EE_PROJECT)
ee_check()

####3. Parameters ####

EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
FINAL_SCHEME  <- "c4"
PROB_PREFIX   <- sprintf("mine_prob_ghana_%s_", FINAL_SCHEME)   # build_02 Section 10's export prefix
MASK_PREFIX   <- sprintf("mine_mask_ghana_%s_", FINAL_SCHEME)   # this script's output prefix
EMBED_YEARS   <- 2017:2025
EXPORT_SCALE  <- 10L

CUTOFF                    <- 70L     # 2026-09-09: 45 -> 70 for FP reduction (does ~95% of it). SW-hull
                                      # area at 70 ~= 680 km2 (< Tang & Werner 903), Barenblitt recall
                                      # 0.84. 45 was the 2026-08-18 setting; see FP-overflagging notes.
URBAN_THRESHOLD_100M      <- 500     # out of 10000. 2026-09-09: 2000 -> 500 (aggressive GHSL-only urban
                                      # knockout, DW dropped -- GHSL doesn't bite mapped mining the way
                                      # DW did). Revisit via validate_finalproduct.js's cutoff/urban sliders
                                      # sweep if recall within Barenblitt drops. Was 2000 (20%-built).
GHSL_100M_EPOCHS          <- c(1975, 1980, 1985, 1990, 1995, 2000, 2005, 2010, 2015, 2020, 2025)
                                      # 2030 excluded -- confirmed likely a projected, not observed, epoch

# TILE_KM MUST MATCH whatever build_02's Section 10a used for the run whose tiles you're reading --
# there's no persisted record of it anywhere else, so if build_02 was re-run with a different
# TILE_KM since, update this to match or the tile-ID reconstruction below won't find the assets.
TILE_KM <- 150

APPLY_MIN_PATCH_FILTER     <- FALSE   # TODO: flip on once validate_min_patch_size_filter.js has run
MIN_PATCH_SIZE             <- NA_real_  # TODO: fill in from that script's result (connectedPixelCount threshold)
APPLY_TEMPORAL_CONSISTENCY <- FALSE   # TODO: rule undesigned past ">=2 consecutive years" -- placeholder only

APPLY_INDUSTRIAL    <- TRUE  # REWORKED 2026-10-27 -- see the header comment. ICMM locates the
                             # known industrial mines (points, no geometry risk); Maus or Tang &
                             # Werner, per-mine selection mode (see IND_MINE_CONFIG), supplies the
                             # exclusion shape. Mining Leases (d_12) and Barenblitt mine_type==2 are no longer
                             # used as confirm sources (see header); d_12's degenerate-ring problem
                             # is now moot.
IND_ICMM_KMZ        <- here("data", "raw", "mining_icmm", "global_mining_dataset_1.5_corrected.kmz")
                             # 2026-10-27: switched from the original global-mining-dataset-1-5.kmz
                             # to this user-edited copy (Google Earth Pro) -- see the "_corrected"
                             # placemark handling in Section 7a. Re-point here again after any future
                             # manual correction round, keeping the "<MineName>_corrected" naming.
IND_CORRECTION_MODE <- c("Obuasi" = "add")   # default "replace" for any mine not listed -- see the
                             # "replace" vs "add" explanation in Section 7a. Obuasi: the original
                             # ICMM point and the corrected one (~4 km apart) both sit on real parts
                             # of that large, sprawling complex, so both are kept as seed points
                             # rather than the correction overwriting the original (unlike Prestea,
                             # where the original location was simply wrong).
IND_MAUS_GPKG       <- here("data", "raw", "mining_mausetal", "global_mining_polygons_v2.gpkg")
IND_TANGWERNER_SHP  <- here("data", "raw", "mining_tangwerner", "74548_projected polygons.shp")
IND_BARENBLITT_SHP  <- here("data", "raw", "barenblitt", "FullConversiontoMiningExtent2019.shp")
IND_ICMM_MIN_CONFIDENCE <- c("High", "Moderate")   # drop Low/Very Low ICMM points (Ghana: drops
                                      # only "Odumase"); flagged by name, not silently dropped
IND_ICMM_BUFFER_M   <- 4000  # DEFAULT radius for any mine not given its own row in IND_MINE_CONFIG
                             # below. Visually QA'd 2026-10-27 against all 14 mines -- fine as the
                             # default for the 8 that visually checked out clean (Ahafo, Akyem,
                             # Bibiani, Chirano, Damang, Iduapriem, Tarkwa, Wassa); the other 6 need
                             # a per-mine override (smaller radius, or a different selection mode
                             # entirely), see IND_MINE_CONFIG.
IND_MAUS_MIN_KM2   <- 0      # 2026-10-27: no longer the primary safeguard against sweeping in small
                             # ASM specks (proximity to a named ICMM mine does most of that work now)
                             # -- left as a secondary knob, default off. Was 1 km2 under the old
                             # national-lease-gate design.
GHANA_BBOX_4326     <- c(xmin = -3.5, ymin = 4.3, xmax = 1.5, ymax = 11.2)   # generous, Tang &
                             # Werner's global shapefile has no country field -- see Section 7c.
IND_TOUCH_TOLERANCE_M <- 50  # "touching_only"/"contiguous" modes below don't literally require the
                             # ICMM point to fall inside a polygon -- a manually-placed point (e.g.
                             # Google Earth Pro) can sit a few metres outside the digitized boundary
                             # by simple placement/digitization imprecision (confirmed 2026-10-27:
                             # corrected Prestea point sits 20-22 m outside its nearest polygon in
                             # BOTH sources). 50 m absorbs that without becoming a real selection
                             # radius -- it's ~2 Landsat/embedding pixels, nowhere near mine-footprint
                             # scale.
IND_MINE_CONFIG <- tibble::tribble(
  ~mine,             ~source,       ~mode,            ~buffer_m,
  "Edikan",          "tangwerner",  "contiguous",     NA_real_,
  "Asanko Obotan",   "tangwerner",  "contiguous",     NA_real_,
  "Prestea",         "tangwerner",  "touching_only",  NA_real_,
  "Bogoso Prestea",  "maus",        "touching_only",  NA_real_,
  "Awaso",           "maus",        "buffer",         1000,
  "Obuasi",          "maus",        "buffer",         1000
)
                             # Per-mine exceptions decided 2026-10-27 from a visual Code Editor QA
                             # pass over all 14 mines (8 others were fine on the IND_ICMM_BUFFER_M
                             # default, see above). Modes:
                             #   "buffer"        -- select polygons within buffer_m of the point
                             #                      (same mechanism as the old uniform design).
                             #   "touching_only" -- select ONLY the polygon(s) touching the point
                             #                      (within IND_TOUCH_TOLERANCE_M) -- no expansion.
                             #   "contiguous"    -- that touching polygon PLUS any polygon directly
                             #                      touching/overlapping IT (one hop, not a flood
                             #                      fill) -- fixes Edikan/Asanko Obotan looking "odd"
                             #                      with several scattered, non-touching polygons
                             #                      under the old buffer-only selection; this instead
                             #                      requires spatial contiguity with the core polygon,
                             #                      not just proximity to the point.
                             # Any mine not listed here uses source "maus", mode "buffer",
                             # buffer_m = IND_ICMM_BUFFER_M (the 8 mines that already checked out).
                             # Tang & Werner is used at Edikan/Asanko Obotan/Prestea because Maus's
                             # matched polygon is implausibly oversized there (Edikan 301.9 km2,
                             # Asanko Obotan 108.6 km2, Prestea 162.8 km2); Tang & Werner is NOT
                             # uniformly better, though -- it's larger than Maus at Iduapriem/Damang/
                             # Wassa, which is why those stay on the Maus default.
IND_ERASE_BAR_ART  <- FALSE  # DROPPED 2026-10-27 (was TRUE 2026-09-09-2026-10-27): originally a
                             # safeguard subtracting Barenblitt mine_type==1 (artisanal) from the
                             # candidate, to protect mapped galamsey encroaching inside/next to a
                             # known mine (e.g. Obuasi, Prestea). Decided unnecessary now that the
                             # candidate itself is being manually reviewed/corrected per mine
                             # (ICMM-point-driven selection + per-mine buffer/source overrides) --
                             # that manual QA is a better safeguard than this blind automated erase,
                             # which risked punching spurious holes from Barenblitt's own NDVI-
                             # anomaly digitization noise into an otherwise-clean curated shape. Only
                             # ever did anything inside the Barenblitt SW hull (mine_type==1 doesn't
                             # exist outside it), so this mainly affected Obuasi/Prestea/Bogoso-
                             # Prestea behavior. Mechanism left intact below, gated on this flag, in
                             # case it's revisited.
IND_CANDIDATE_ASSET <- ""    # if sf_as_ee(candidate) fails on geometry, upload the written .shp as
                             # an EE asset and put its id here to read it directly (skips sf_as_ee)

APPLY_WATER_MASK   <- TRUE    # 2026-09-09: knock out JRC GSW permanent water + a coast strip
GSW_OCCURRENCE_MIN <- 90      # % of months 1984-2021 with water; >=90 = permanent (ocean, lakes,
                             # perennial river CHANNELS). Channels only -- no river buffer, so
                             # banks/floodplain where riparian galamsey sits are kept.
COAST_BUFFER_M     <- 150     # strip buffered inland of WIDE water bodies only (ocean, big lakes);
                             # a morphological opening drops river-width features before buffering.
APPLY_ROAD_BUFFER  <- TRUE    # 2026-09-09: knock out a buffer around GRIP4 Africa roads
ROAD_BUFFER_M      <- 35      # half-width; GRIP4 ~2018, thin on rural tracks = lower bound
GRIP4_AFRICA_FC    <- "projects/sat-io/open-datasets/GRIP4/Africa"

out_ee_ok <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)

####4. Rebuild the export tile grid (must mirror build_02 Section 10a exactly) ####
# Duplicated rather than read from a saved grid, matching this project's convention that scripts
# coordinate through data ARTIFACTS, never by sourcing each other -- ghana_utm is cheap to rebuild
# and the tile grid is a pure function of it + TILE_KM.
ghana_utm <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin",
                          "gha_admin0.shp"), quiet = TRUE) |>
  select(geometry) |>
  st_make_valid() |>
  st_union() |>
  st_transform(UTM30N) |>
  st_simplify(dTolerance = 100)

tile_grid_utm <- st_make_grid(ghana_utm, cellsize = TILE_KM * 1000, square = TRUE)
tiles_utm     <- tile_grid_utm[lengths(st_intersects(tile_grid_utm, ghana_utm)) > 0]
tile_ids      <- sprintf("t%02d", seq_along(tiles_utm))
message(sprintf("Reconstructed %d tiles at TILE_KM=%d (must match the build_02 run being read)",
                length(tile_ids), TILE_KM))

ghana_ee <- ee$FeatureCollection(file.path(EE_ASSET_HOME, "rs05_ghana"))$geometry()

####5. Per-year: mosaic tiles -> threshold -> GHSL 100m mask ####

nearest_epoch_year <- function(yr) GHSL_100M_EPOCHS[which.min(abs(yr - GHSL_100M_EPOCHS))]

built_surface_for_year <- function(yr) {
  epoch <- nearest_epoch_year(yr)
  message(sprintf("  year %d -> nearest GHSL 100m epoch: %d", yr, epoch))
  ee$ImageCollection("JRC/GHSL/P2023A/GHS_BUILT_S")$
    filterDate(sprintf("%d-01-01", epoch), sprintf("%d-01-01", epoch + 1L))$
    first()$select("built_surface")
}

####5a. Year-invariant knockouts: permanent water (+ coast strip) and roads ####
# Both are static, so build once here and updateMask() them in every year's mask below. Each
# resolves to a "1 = keep" image (ee$Image(1) when its APPLY_* flag is off = no-op).
water_keep <- if (!APPLY_WATER_MASK) ee$Image(1) else {
  gsw  <- ee$Image("JRC/GSW1_4/GlobalSurfaceWater")$select("occurrence")
  perm <- gsw$gte(GSW_OCCURRENCE_MIN)$unmask(0)                 # 1 = permanent water (channels incl.)
  # morphological opening: drop features narrower than ~2*120 m (rivers) so only wide water bodies
  # (ocean, big lakes) get the coast buffer -- rivers keep their banks (no river buffer, per decision)
  wide  <- perm$focal_min(radius = 120, units = "meters")$focal_max(radius = 120, units = "meters")
  coast <- wide$focal_max(radius = COAST_BUFFER_M, units = "meters")
  perm$Or(coast)$Not()$rename("keep")                           # 1 = keep, 0 = water/coast
}
road_keep <- if (!APPLY_ROAD_BUFFER) ee$Image(1) else {
  # buffer the road LINES (vector) then paint -- resolution-independent, unlike focal_max on a
  # paint of a constant image (whose default 1-degree projection makes a metre-radius focal a no-op)
  roads_buf <- ee$FeatureCollection(GRIP4_AFRICA_FC)$filterBounds(ghana_ee)$
    map(function(f) f$buffer(ROAD_BUFFER_M))
  ee$Image()$byte()$paint(roads_buf, 1)$unmask(0)$Not()$rename("keep")   # 1 = keep, 0 = within buffer
}

year_mosaic <- function(yr) {
  assetIds <- file.path(EE_ASSET_HOME, sprintf("%s%d_%s", PROB_PREFIX, yr, tile_ids))
  present  <- keep(assetIds, out_ee_ok)
  if (length(present) == 0)
    stop(sprintf("no %s tiles found for %d -- has build_02 Section 10 finished for this year?", FINAL_SCHEME, yr))
  if (length(present) < length(assetIds))
    warning(sprintf("%d/%d tiles missing for %d -- mosaic will have gaps",
                    length(assetIds) - length(present), length(assetIds), yr))
  ee$ImageCollection(as.list(present))$mosaic()$rename("mine_prob")
}

# c4/no_maus's mine_prob band is already the array-extracted, 0-100 uint8 scalar band build_02
# Section 10 wrote (mine_prob_of() + arrayGet() happened at EXPORT time, not here) -- everything
# from here down operates on ordinary scalar images, not the expensive array type that caused the
# 2026-08-19 stuck export. Thresholding/masking a scalar mosaic at national scale should be cheap
# by comparison; if this section turns out slow too, apply build_02 Section 10a's tiling pattern
# here as well.
build_year_mask <- function(yr) {
  message(sprintf("=== %d ===", yr))
  prob_img <- year_mosaic(yr)

  mine_bin <- prob_img$gte(CUTOFF)

  built_100m  <- built_surface_for_year(yr)
  urban_mask  <- built_100m$gt(URBAN_THRESHOLD_100M)   # 1 = urban, mask OUT
  mine_masked <- mine_bin$updateMask(urban_mask$Not())   # $Not() -- 'not' is reserved in Python EE

  if (APPLY_WATER_MASK)  mine_masked <- mine_masked$updateMask(water_keep)   # GSW permanent + coast
  if (APPLY_ROAD_BUFFER) mine_masked <- mine_masked$updateMask(road_keep)    # GRIP4 road buffer

  # Hybrid rule (mine_prob > urban_prob) DELIBERATELY DROPPED -- confirmed redundant vs. the GHSL
  # mask alone at cutoff 45 (identical result in the Kumasi test, 2026-08-18). Do not reintroduce
  # without re-running that comparison; it would also require Section 10 to export an urban_prob
  # band it currently doesn't.

  if (APPLY_MIN_PATCH_FILTER) {
    stopifnot("MIN_PATCH_SIZE not set -- run validate_min_patch_size_filter.js first" = !is.na(MIN_PATCH_SIZE))
    mine_masked <- mine_masked$updateMask(
      mine_masked$connectedPixelCount(MIN_PATCH_SIZE + 1, FALSE)$gte(MIN_PATCH_SIZE)
    )
  }

  mine_masked
}

year_masks <- map(EMBED_YEARS, build_year_mask) |> set_names(as.character(EMBED_YEARS))

####6. Temporal-consistency rule (placeholder -- rule not yet designed) ####
if (APPLY_TEMPORAL_CONSISTENCY) {
  stop("APPLY_TEMPORAL_CONSISTENCY is on but the rule (>=2 consecutive years?) has never been ",
       "designed past that one sentence -- decide the exact logic (which 2 years? edge behaviour ",
       "at 2017/2025?) before implementing, don't guess it here.")
}
# When this gets designed: probably an ee$ImageCollection$toBands() or explicit pairwise $and()
# over year_masks, keeping a pixel only where it's masked-in in >=2 consecutive years. Left
# unimplemented deliberately.

####7. Industrial-mine exclusion -- Maus polygons selected by proximity to named ICMM mines ####
# Galamsey/artisanal mining is the research target; large-scale operations are subtracted from the
# final mask. REWORKED 2026-10-27 (was: Mining-Lease "gate" INT (Maus-GH U Barenblitt mine_type==2)
# "confirm", deferred since 2026-09-09 -- the Minerals Commission lease gpkg, d_12, ships degenerate
# 2-point rings that crash sf/GEOS and sf_as_ee()). New recipe:
#   locate = ICMM global mining dataset (data/raw/mining_icmm/, 16 named Ghana points, points not
#            polygons -- no geometry risk), Asset_Type == "Mine", confidence >= IND_ICMM_MIN_CONFIDENCE.
#            Covers all the major named operators (Ahafo, Obuasi, Tarkwa, Chirano, Bibiani, Damang,
#            Wassa, Edikan, Iduapriem, Akyem, Asanko, Bogoso Prestea, Prestea, Awaso). Self-reported
#            by ICMM member companies, so not necessarily exhaustive, but clean and geometry-free.
#   shape  = Maus et al. 2022 v2 polygons (Ghana subset; checked 2026-10-27 -- it has NO type/scale
#            field, only fid/geom/ISO3_CODE/COUNTRY_NAME/AREA, so it maps ALL mining disturbance,
#            industrial and artisanal alike), or Tang & Werner 2023 at 3 mines where Maus is
#            implausibly oversized (Edikan 301.9 km2, Asanko Obotan 108.6 km2, Prestea 162.8 km2 --
#            each a single simple POLYGON, not a multi-part dissolve artifact, confirmed by direct
#            inspection, just an implausible bounding box for one mine). Tang & Werner is NOT
#            uniformly better though -- it's larger than Maus at Iduapriem/Damang/Wassa -- so every
#            other mine stays on Maus. The SELECTION mechanism is also per-mine as of 2026-10-27
#            (visual QA over all 14 mines found 6 needing something other than the uniform
#            IND_ICMM_BUFFER_M default -- a smaller buffer, or a mode requiring the polygon to
#            actually touch the point, optionally plus its direct neighbors) -- see IND_MINE_CONFIG
#            and Section 7b-7d for the full per-mine table and the 3 selection modes.
# Dropped vs the old design: the Mining Leases gpkg (geometry problems, now redundant) and Barenblitt
# mine_type==2 as a confirm source (redundant with ICMM; it undercounted anyway -- missed
# Ahafo/Chirano/Bibiani, all three of which ICMM has). ALSO DROPPED (2026-10-27, same day as the
# rework above): IND_ERASE_BAR_ART, which subtracted Barenblitt mine_type==1 (artisanal) from the
# candidate as a safeguard against erasing galamsey encroaching inside/next to a known mine (e.g.
# Obuasi, Prestea). Decided unnecessary now that the candidate is manually reviewed/corrected per
# mine (see the per-mine distance/area diagnostic below) -- that manual QA judges each mine's actual
# imagery directly, which is a better safeguard than blindly subtracting Barenblitt's own artisanal
# layer, which has its own NDVI-anomaly digitization noise and could punch spurious holes into an
# otherwise-clean curated shape. Mechanism left intact below, gated on IND_ERASE_BAR_ART, in case
# it's revisited.
if (APPLY_INDUSTRIAL) {
  ind_old_s2 <- sf_use_s2(); suppressMessages(sf_use_s2(FALSE))   # Maus dissolve can leave slivers too

  # -> valid, polygon-only, sliver-free (EE's geometry parser rejects 2-point rings, which
  # st_simplify(preserveTopology = FALSE) would otherwise create from tiny slivers).
  clean_utm <- function(g, min_m2 = 100) {
    g <- st_make_valid(g)
    if (inherits(g, "sfc")) g <- st_sf(geometry = g)
    if (any(st_geometry_type(g) == "GEOMETRYCOLLECTION"))
      g <- suppressWarnings(st_collection_extract(g, "POLYGON"))
    g <- g[!st_is_empty(g), , drop = FALSE]
    a <- as.numeric(st_area(g)); g <- g[!is.na(a) & a >= min_m2, , drop = FALSE]
    st_make_valid(g)
  }
  diss <- function(g) st_union(st_geometry(clean_utm(g)))
  km2  <- function(g) {                                           # (multi)geom -> km2, POLYGON-only
    if (length(g) == 0) return(0)
    g <- suppressWarnings(st_collection_extract(st_make_valid(g), "POLYGON"))
    if (all(st_is_empty(g))) return(0)
    # st_union() FIRST, then area -- fixes a real bug found 2026-10-27: summing each feature's own
    # area independently double-counts any real overlap between them (confirmed: Edikan's 3
    # "contiguous" Tang & Werner polygons genuinely overlap each other by several km2, not just
    # touch at an edge -- the naive sum overstated every multi-polygon print in this section by the
    # overlap amount). A single already-dissolved feature is unaffected (union of one thing is a
    # no-op), so this is a strict correction, not a behavior change for the final candidate itself.
    as.numeric(st_area(st_union(st_geometry(st_transform(st_sf(geometry = g), UTM30N))))) / 1e6
  }

  # sf_as_ee()'s geometry parser rejects LinearRings with < 3 points; dissolves can leave 2-point
  # sliver rings. st_set_precision(1) snaps coords to a 1 m grid -> coincident points collapse ->
  # st_make_valid() then rebuilds/drops the degenerate rings. POLYGON-only, slivers < 500 m2
  # dropped, returned in 4326.
  ee_ready <- function(g) {
    if (inherits(g, "sfc")) g <- st_sf(geometry = g)
    g <- st_transform(g, UTM30N) |> st_set_precision(1) |> st_make_valid()
    g <- suppressWarnings(st_collection_extract(g, "POLYGON"))
    g <- st_simplify(g, dTolerance = 30, preserveTopology = TRUE) |> st_set_precision(1) |> st_make_valid()
    g <- suppressWarnings(st_collection_extract(g, "POLYGON"))
    g <- g[!st_is_empty(g), , drop = FALSE]
    a <- as.numeric(st_area(g)); g <- g[!is.na(a) & a >= 500, , drop = FALSE]
    st_transform(st_cast(g, "MULTIPOLYGON"), 4326)
  }

  ####7a. ICMM points -- named Ghana industrial mines ####
  # No usable OGR KML driver reports ExtendedData/SchemaData as fields here (tested 2026-10-27: the
  # "KML" driver only exposes Name/Description; "LIBKML" isn't in this GDAL build), so the KMZ is
  # parsed by hand via xml2 instead of sf::st_read().
  icmm_tmp <- tempfile()
  unzip(IND_ICMM_KMZ, exdir = icmm_tmp)
  icmm_kml <- list.files(icmm_tmp, pattern = "[.]kml$", full.names = TRUE)[1]
  icmm_doc <- read_xml(icmm_kml)
  icmm_ns  <- xml_ns(icmm_doc)
  parse_icmm_pm <- function(pm) {
    sd   <- xml_find_all(pm, ".//d1:SimpleData", icmm_ns)
    vals <- setNames(xml_text(sd), xml_attr(sd, "name"))
    xy   <- as.numeric(strsplit(trimws(xml_text(xml_find_first(pm, ".//d1:coordinates", icmm_ns))), ",")[[1]][1:2])
    # bind_rows() (not rbind()) -- a manually-added correction placemark (see below) carries NO
    # SimpleData at all, so its row has far fewer columns than a normal ICMM placemark; rbind()
    # would error on the mismatch, bind_rows() fills the missing ones with NA.
    as.data.frame(c(as.list(vals), list(
      placemark_name = xml_text(xml_find_first(pm, ".//d1:name", icmm_ns)),
      lon = xy[1], lat = xy[2])), stringsAsFactors = FALSE)
  }
  icmm_all <- bind_rows(lapply(xml_find_all(icmm_doc, ".//d1:Placemark", icmm_ns), parse_icmm_pm))

  # --- manual correction handling (2026-10-27): the user moves a mine's point in Google Earth Pro,
  # which saves the edit as a NEW, separate, metadata-less placemark named "<MineName>_corrected"
  # rather than an in-place edit -- the original entry (with all its ICMM metadata) is still in the
  # file, unmoved. Two distinct cases, per IND_CORRECTION_MODE below:
  #   "replace" (default) -- the original location was simply wrong (e.g. Prestea, moved ~7 km) --
  #     overwrite the base mine's lon/lat with the correction, keeping its own metadata.
  #   "add" -- BOTH locations genuinely sit on different parts of the same real industrial complex
  #     (e.g. Obuasi, moved ~4 km but the original point also captures real mine footprint -- it's a
  #     large sprawling operation, not a single mislocated point) -- keep the correction as a SECOND
  #     point for that mine (same Mine_Name, copied metadata) rather than overwriting the first. The
  #     selection functions in Section 7d already handle >1 point per mine correctly (buffer/
  #     touching/contiguous all just union across however many points a mine has), so this needs no
  #     changes there -- only mine_config (Section 7b) must dedupe on unique(Mine_Name) so a 2-point
  #     mine isn't processed twice.
  corrections <- icmm_all[grepl("_corrected$", icmm_all$placemark_name), , drop = FALSE]
  add_rows <- list()
  for (i in seq_len(nrow(corrections))) {
    base_name <- sub("_corrected$", "", corrections$placemark_name[i])
    match_idx <- which(icmm_all$Mine_Name == base_name)
    if (length(match_idx) != 1) {
      warning(sprintf("ICMM correction placemark '%s' found but '%s' doesn't match exactly 1 existing mine (%d matches) -- NOT applied",
                      corrections$placemark_name[i], base_name, length(match_idx)))
      next
    }
    corr_mode <- if (base_name %in% names(IND_CORRECTION_MODE)) IND_CORRECTION_MODE[[base_name]] else "replace"
    if (corr_mode == "replace") {
      message(sprintf("  ICMM correction applied (replace): %s moved from (%.5f, %.5f) to (%.5f, %.5f)",
                      base_name, icmm_all$lon[match_idx], icmm_all$lat[match_idx],
                      corrections$lon[i], corrections$lat[i]))
      icmm_all$lon[match_idx] <- corrections$lon[i]
      icmm_all$lat[match_idx] <- corrections$lat[i]
    } else if (corr_mode == "add") {
      message(sprintf("  ICMM correction applied (add 2nd point): %s also has a point at (%.5f, %.5f)",
                      base_name, corrections$lon[i], corrections$lat[i]))
      new_row <- icmm_all[match_idx, ]
      new_row$lon <- corrections$lon[i]; new_row$lat <- corrections$lat[i]
      new_row$placemark_name <- corrections$placemark_name[i]
      add_rows[[length(add_rows) + 1]] <- new_row
    } else stop("IND_CORRECTION_MODE['", base_name, "'] must be \"replace\" or \"add\", got: ", corr_mode)
  }
  icmm_all <- icmm_all[!grepl("_corrected$", icmm_all$placemark_name), , drop = FALSE]
  if (length(add_rows) > 0) icmm_all <- bind_rows(icmm_all, bind_rows(add_rows))

  icmm_gh <- icmm_all |> filter(Country == "Ghana", Asset_Type == "Mine")
  icmm_dropped <- icmm_gh |> filter(!Confidence_Factor %in% IND_ICMM_MIN_CONFIDENCE)
  if (nrow(icmm_dropped) > 0)
    message(sprintf("  ICMM: dropping %d Ghana mine(s) below confidence threshold (%s): %s",
                    nrow(icmm_dropped), paste(IND_ICMM_MIN_CONFIDENCE, collapse = "/"),
                    paste(icmm_dropped$Mine_Name, collapse = ", ")))
  icmm_gh <- icmm_gh |> filter(Confidence_Factor %in% IND_ICMM_MIN_CONFIDENCE)
  message(sprintf("Industrial: %d distinct ICMM Ghana mine(s), %d point(s) total (some mines have 2 via IND_CORRECTION_MODE \"add\"): %s",
                  length(unique(icmm_gh$Mine_Name)), nrow(icmm_gh), paste(icmm_gh$Mine_Name, collapse = ", ")))

  icmm_pts <- st_as_sf(icmm_gh, coords = c("lon", "lat"), crs = 4326) |> st_transform(UTM30N)

  ####7b. Resolve the full per-mine selection config (unlisted mines get the defaults) ####
  # unique() -- a mine on IND_CORRECTION_MODE "add" (e.g. Obuasi) now has 2 rows in icmm_gh/icmm_pts,
  # but still needs exactly ONE config row: Section 7d's select_for_mine() pulls ALL of that mine's
  # points at once (st_geometry(icmm_pts)[icmm_gh$Mine_Name == cfg$mine] naturally returns both) and
  # unions across them, so processing the mine twice would just waste a little time, not change the
  # result -- but unique() keeps the printed diagnostics from listing it twice too.
  mine_config <- tibble(mine = unique(icmm_gh$Mine_Name)) |>
    left_join(IND_MINE_CONFIG, by = "mine") |>
    mutate(
      source   = coalesce(source, "maus"),
      mode     = coalesce(mode, "buffer"),
      buffer_m = ifelse(mode == "buffer" & is.na(buffer_m), IND_ICMM_BUFFER_M, buffer_m)
    )
  message("  Per-mine selection config:")
  message(paste(sprintf("    %-20s source=%-11s mode=%-14s%s", mine_config$mine, mine_config$source,
                        mine_config$mode, ifelse(mine_config$mode == "buffer",
                                                  sprintf(" buffer=%gm", mine_config$buffer_m), "")),
                collapse = "\n"))

  ####7c. Load Maus-GH and Tang & Werner 2023 (Ghana subset each), each with a stable feature ID ####
  # The ID (maus_fid / tw_id) is needed by Section 7d's cross-mine dedup below -- without it there's
  # no way to tell "two mines independently selected this exact same polygon" from "two mines each
  # selected their own, different, polygon."
  maus_lyr <- sf::st_layers(IND_MAUS_GPKG)$name[1]
  # "SELECT *" alone drops the gpkg's own fid -- OGR consumes it as the hidden feature ID rather than
  # a regular column. Aliasing it (fid AS maus_fid) makes OGR treat it as an ordinary attribute.
  maus_gh  <- st_read(IND_MAUS_GPKG, quiet = TRUE,
                      query = sprintf("SELECT *, fid AS maus_fid FROM \"%s\" WHERE ISO3_CODE = 'GHA'", maus_lyr)) |>
    st_zm(drop = TRUE) |> st_transform(UTM30N)
  maus_a  <- as.numeric(st_area(maus_gh)) / 1e6
  maus_gh <- maus_gh[!is.na(maus_a) & maus_a >= IND_MAUS_MIN_KM2, , drop = FALSE]
  message(sprintf("  Maus-GH: %d polys (>= %g km2) loaded", nrow(maus_gh), IND_MAUS_MIN_KM2))

  # Global file, no country field -- st_read()'s wkt_filter spatially pre-filters via the shapefile's
  # own .shx index (confirmed 2026-10-27: <1s, ~1900 features, NOT a full ~296 MB read) to a generous
  # Ghana bbox reprojected into the file's native EASE-Grid CRS.
  tw_crs      <- st_crs(readLines(sub("[.]shp$", ".prj", IND_TANGWERNER_SHP)))
  tw_bbox_wkt <- st_bbox(GHANA_BBOX_4326, crs = 4326) |> st_as_sfc() |> st_transform(tw_crs) |> st_as_text()
  tw_gh <- st_read(IND_TANGWERNER_SHP, wkt_filter = tw_bbox_wkt, quiet = TRUE) |>
    st_zm(drop = TRUE) |> st_transform(UTM30N) |> mutate(tw_id = OBJECTID)
  message(sprintf("  Tang & Werner polygons in the Ghana bbox: %d", nrow(tw_gh)))

  ####7d. Per-mine selection -- buffer / touching_only / contiguous (see IND_MINE_CONFIG) ####
  select_for_mine <- function(pt, src, mode, buffer_m) {
    if (mode == "buffer") return(src[lengths(st_intersects(src, st_buffer(pt, buffer_m))) > 0, , drop = FALSE])
    # "touching_only"/"contiguous": seed = polygon(s) touching the point within IND_TOUCH_TOLERANCE_M
    # (a tolerance, not a real selection radius -- see that parameter's comment).
    seed <- src[lengths(st_intersects(src, st_buffer(pt, IND_TOUCH_TOLERANCE_M))) > 0, , drop = FALSE]
    if (mode == "touching_only" || nrow(seed) == 0) return(seed)
    src[lengths(st_intersects(src, st_union(st_geometry(seed)))) > 0, , drop = FALSE]   # seed + 1-hop neighbors
  }

  mine_sel <- vector("list", nrow(mine_config))
  for (i in seq_len(nrow(mine_config))) {
    cfg    <- mine_config[i, ]
    pt     <- st_geometry(icmm_pts)[icmm_gh$Mine_Name == cfg$mine]
    src    <- if (cfg$source == "maus") maus_gh else tw_gh
    id_col <- if (cfg$source == "maus") "maus_fid" else "tw_id"
    sel    <- select_for_mine(pt, src, cfg$mode, cfg$buffer_m)
    if (nrow(sel) == 0)
      warning(sprintf("'%s' (%s/%s): NO polygon selected -- check IND_MINE_CONFIG / source coverage there",
                      cfg$mine, cfg$source, cfg$mode))
    mine_sel[[i]] <- list(mine = cfg$mine, source = cfg$source, mode = cfg$mode,
                          ids = sel[[id_col]], geom = st_geometry(sel), pt = pt)
  }

  # --- cross-mine dedup (2026-10-27): a polygon independently selected by MORE THAN ONE mine (same
  # source, identical feature id) is kept by whichever mine's point(s) are nearest to it, dropped
  # from the rest. Fixes a real regression found 2026-10-27: Iduapriem Gold Mine's plain "buffer"
  # selection was independently pulling in the SAME Maus polygon (fid 44258, 61.5 km2) that Tarkwa's
  # buffer also reaches (it touches Tarkwa's point at 0 m) -- before the per-mine mode rework, a
  # "nearest mine" tie-break kept this exclusive to Tarkwa; the mode rework dropped that tie-break
  # for simplicity and silently reintroduced the duplication. This restores exclusivity WITHOUT
  # reintroducing the old design's downside (a polygon can still be a mine's OWN selection even if a
  # neighbor's buffer also happens to reach it -- it's just resolved to one owner, not blind nearest-
  # feature attribution across all of Ghana). ---
  for (src_name in c("maus", "tangwerner")) {
    idx <- which(sapply(mine_sel, `[[`, "source") == src_name)
    if (length(idx) < 2) next
    all_ids <- unlist(lapply(mine_sel[idx], `[[`, "ids"))
    dup_ids <- unique(all_ids[duplicated(all_ids)])
    for (did in dup_ids) {
      claimants <- idx[sapply(idx, function(j) did %in% mine_sel[[j]]$ids)]
      dists <- sapply(claimants, function(j) {
        g <- mine_sel[[j]]$geom[mine_sel[[j]]$ids == did]
        min(as.numeric(st_distance(g, mine_sel[[j]]$pt)))
      })
      keep <- claimants[which.min(dists)]
      message(sprintf("  dedup: %s polygon %s claimed by %s -- kept under %s only (nearest)",
                      src_name, did, paste(sapply(claimants, function(j) mine_sel[[j]]$mine), collapse = " & "),
                      mine_sel[[keep]]$mine))
      for (j in setdiff(claimants, keep)) {
        keep_mask <- mine_sel[[j]]$ids != did
        mine_sel[[j]]$ids  <- mine_sel[[j]]$ids[keep_mask]
        mine_sel[[j]]$geom <- mine_sel[[j]]$geom[keep_mask]
      }
    }
  }

  message("  Per-mine selection (source/mode, count, area; post-dedup):")
  selected <- vector("list", length(mine_sel))
  for (i in seq_along(mine_sel)) {
    m <- mine_sel[[i]]
    message(sprintf("    %-20s [%-11s/%-14s]: %d poly(s), %.2f km2",
                    m$mine, m$source, m$mode, length(m$geom), km2(m$geom)))
    selected[[i]] <- m$geom
  }

  candidate <- clean_utm(st_union(do.call(c, selected)))   # sf, UTM30N
  message(sprintf("  candidate (all 14 mines, per-mine source/mode): %.1f km2", km2(st_geometry(candidate))))

  # --- safeguard: erase Barenblitt artisanal so mapped galamsey near a known mine is protected ---
  if (IND_ERASE_BAR_ART) {
    bar_art <- st_read(IND_BARENBLITT_SHP, quiet = TRUE) |>
      janitor::clean_names() |> filter(mine_type == 1) |> st_zm(drop = TRUE) |> st_transform(UTM30N)
    d_barart    <- diss(bar_art)
    overlap_km2 <- km2(suppressWarnings(st_intersection(st_geometry(candidate), d_barart)))
    candidate   <- suppressWarnings(st_difference(st_geometry(candidate), d_barart)) |> clean_utm()
    message(sprintf("  Barenblitt-artisanal erase: -%.1f km2 -> candidate %.1f km2",
                    overlap_km2, km2(st_geometry(candidate))))
  }

  candidate <- ee_ready(candidate)                # topology-clean + 4326 for sf_as_ee() / st_write()
  message(sprintf("Industrial-exclusion polygon: %.1f km2",
                  as.numeric(sum(st_area(st_transform(candidate, UTM30N)))) / 1e6))

  # persist for QGIS + as an upload fallback if sf_as_ee() still chokes on the geometry
  dir.create(here("outputs"), showWarnings = FALSE)
  ind_shp <- here("outputs", "industrial_exclusion_candidate.shp")
  st_write(candidate, here("outputs", "industrial_exclusion_candidate.gpkg"), delete_dsn = TRUE, quiet = TRUE)
  st_write(candidate, ind_shp, delete_dsn = TRUE, quiet = TRUE)
  message("  wrote outputs/industrial_exclusion_candidate.{gpkg,shp}")

  suppressMessages(sf_use_s2(ind_old_s2))

  industrial_ee <- if (nzchar(IND_CANDIDATE_ASSET)) {
    message("  reading industrial candidate from EE asset: ", IND_CANDIDATE_ASSET)
    ee$FeatureCollection(IND_CANDIDATE_ASSET)
  } else tryCatch(sf_as_ee(candidate), error = function(e) stop(
    "sf_as_ee(candidate) failed (", conditionMessage(e), ").\n",
    "  -> upload ", ind_shp, " in the Code Editor (Assets > New > Shape files), then set\n",
    "     IND_CANDIDATE_ASSET <- \"<asset id>\" in Section 3 and re-run from Section 7.", call. = FALSE))

  industrial_mask <- ee$Image()$byte()$paint(industrial_ee, 1)$unmask(0)$Not()   # 1 = keep, 0 = industrial
  year_masks_final <- map(year_masks, ~ .x$updateMask(industrial_mask))
} else {
  message("APPLY_INDUSTRIAL is FALSE -- no large-scale-mine exclusion")
  year_masks_final <- year_masks
}

####8. Persist the annual mine mask per year (EE assets) ####
# National, single export per year (not tiled -- see the Section 5 comment on why this should be
# cheap now that the array-typed classification cost was already paid at build_02 export time).

FORCE_REEXPORT <- FALSE   # 2026-11-04: flipped back off -- the full re-export under the reworked
                          # ICMM/Maus industrial exclusion (2026-10-27 config) has landed; confirmed
                          # visually via validate_finalproduct.js (industrial mines excluded on the
                          # live assets). Flip back to TRUE only if build_03's config changes again
                          # and the deployed mine_mask_ghana_c4_{yr} assets need a fresh re-export.

export_year_mask <- function(yr) {
  asset_name <- paste0(MASK_PREFIX, yr)
  assetId    <- file.path(EE_ASSET_HOME, asset_name)
  if (out_ee_ok(assetId) && !FORCE_REEXPORT) {
    message(sprintf("  [skip] %s already exists (FORCE_REEXPORT <- TRUE to overwrite)", assetId))
    return(invisible(NULL))
  }
  if (out_ee_ok(assetId)) ee$data$deleteAsset(assetId)
  task <- ee$batch$Export$image$toAsset(
    image            = year_masks_final[[as.character(yr)]]$toUint8(),
    description      = paste0(asset_name, "_asset"),
    assetId          = assetId,
    scale            = EXPORT_SCALE,
    region           = ghana_ee$bounds(),
    crs              = "EPSG:4326",
    maxPixels        = 1e13,
    pyramidingPolicy = list(".default" = "mode")   # categorical 0/1 mask: no averaging
  )
  task$start()
  message(sprintf("  Submitted: %s", assetId))
  task
}

mask_tasks <- map(EMBED_YEARS, export_year_mask)
message(sprintf("\nSubmitted %d/%d annual mine-mask exports.",
                sum(!map_lgl(mask_tasks, is.null)), length(EMBED_YEARS)))
message("Monitor: code.earthengine.google.com -> Tasks tab")

# NEXT (not this script): rework build_04_backdating_prototype.js to read mine_mask_ghana_c4_{yr}
# (this script's output) instead of the stale mine_prob_ghana_{yr} binary-model names it currently
# hardcodes, port it from JS to R, run it to get mine_onset_year_2000_2016, THEN write the
# merge-plus-hex-aggregation script that was originally sketched as this script's Step 8.
