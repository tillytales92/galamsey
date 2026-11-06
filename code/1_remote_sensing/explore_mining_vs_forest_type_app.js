// explore_mining_vs_forest_type_app.js -- App-ready variant of explore_mining_vs_forest_type.js
// ("for fun" exploratory, not part of the core pipeline). Paste into code.earthengine.google.com
// (project: rgee-auth-tillam); can also be published via Code Editor -> Apps -> Publish.
//
// Combines our own 2017-2025 gold-mining panel (mine_mask_ghana_c4_<yr>, see
// build_03_embedding_panel.R) with DeepMind/Google Research/WRI/IIASA's "Forest Typology" (ForTy)
// map (https://deepmind.google/blog/beyond-tree-cover-mapping-the-worlds-forest-types/) to show
// what forest TYPE cumulative mining expansion has actually replaced over time, at a user-chosen
// administrative unit (district only, see 2026-11-04 note below). Map + three charts (cumulative
// mining trend 2017-2025, land-type breakdown 2020-2025, "what did NEW mining growth displace") +
// two GIFs (forest-type palette over 2020-2025, and real satellite imagery over 2015-2025).
// (The left/right "swipe" year comparison and the "Try a district" example buttons described in
// the dated notes below were both removed 2026-11-05, user call -- not needed.)
//
// *** 2026-11-03 REWRITE (user request): region/district picker, dropdown-driven ***
// Replaced the preset-district-list + click-to-pick-a-point mechanism with a Region dropdown
// (scopes the list) -> District dropdown, over Ghana's own admin boundaries. "Generate stats"
// reduces over the selected district's own geometry (not a buffered box/circle like the old
// custom-point version). Dropdown chosen over click-to-select-a-polygon on the map: clicking would
// need an async server-side point-in-polygon lookup (filterBounds + evaluate) to resolve which
// admin unit was clicked -- the same class of thing that already failed silently once in this
// script's history (Map.drawingTools()'s onDraw() never firing, see git history / old comments),
// and a published App has no console to debug a silent failure like that. Dropdowns are
// synchronous and trivial by comparison.
//
// *** 2026-11-04 (user request): Region mode REMOVED, default view + forest toggle changed ***
// This file originally also let a whole Region (not just a District) be the analysis unit --
// removed: "Generate stats" over a full region (e.g. Ashanti, ~24,000 km2) was too computationally
// intensive for the published App. District-only now; the Region dropdown still exists but only to
// scope the District list, same as it always did in District mode. Also: the map now starts
// showing ONLY the gold mining layer (forestLayer added with shown=false, STEP 10) -- the
// forest-type layer is opt-in via a new "Show forest type" checkbox (STEP 9/forestCheckbox),
// rather than visible by default.
//
// *** 2026-11-03 FOLLOW-UP (user request), same day ***
// - Forest-type layer now clipped to Ghana only (GHANA_GEOM, STEP 1/2) -- the raw ForTy mosaic is
//   global, so without clipping the map painted neighbouring countries too.
// - Region/District dropdowns now restricted to admin units that actually contain some cumulative
//   mining (STEP 4) -- picking a region/district with zero galamsey wouldn't produce anything
//   interesting anyway.
// - Region<->district linkage switched from attribute matching (comparing a region-name field
//   between the independently-sourced admin1/admin2 assets) to a SPATIAL join (district centroid
//   inside a region polygon). This is also the fix for a reported crash -- "Cannot read properties
//   of null (reading 'coordinates')" at Map.centerObject() -- caused by the two assets' region-name
//   spellings not lining up, so the old attribute filter matched zero features and produced a null
//   geometry. See the STEP 4 comment for the full explanation.
// - "Generate stats"'s three charts no longer ALSO get print()'d to the console -- a GEE chart
//   widget can only have one parent, and print() + resultsPanel.add() on the same widget threw
//   "Widgets cannot be added to a panel if they have been printed in the console." Charts now go to
//   resultsPanel only (App-visible, which was the actual goal); plain string/debug messages still
//   print() as before.
// - Added a genuine left/right "swipe" comparison (STEP 8: two linked ui.Map widgets in a
//   ui.SplitPanel with wipe:true -- a draggable divider in the middle, left map showing one year,
//   right map showing another) -- this is what "slider" actually meant; it's a different thing
//   from the in-place year-slider on the main map (STEP 9/10), which still swaps the SAME map's
//   overlay in place and is kept as a separate, lighter-weight way to scrub years.
//
// *** 2026-11-03 FOLLOW-UP #2 (user request): real satellite imagery GIF ***
// Added true-colour composite helpers (STEP 3b, same technique as validate_change_gif.js: Sentinel-2
// from SENTINEL2_START_YEAR (2018) on, Landsat 5/7/8 before that -- that script confirmed ZERO
// Sentinel-2 scenes over this kind of AOI for the 2017 dry season). Used by "Generate satellite GIF"
// (STEP 7b) -- a second, District-mode-only GIF alongside the original forest-type one: real imagery
// as the background over SATELLITE_YEARS (2015-2025, widened from EMBED_YEARS 2026-11-04 -- the
// classifier only exists 2017+, but imagery doesn't need it), not DISPLAY_YEARS -- this GIF has no
// 2020-only-ForTy-baseline or 2017-classifier reason to start later, unlike everything else here. No
// solid mining-mask fill (user call), but the mining footprint's own boundary IS drawn as a gold/
// amber outline (user follow-up), plus the district outline + year/location label for orientation.
// Slower than the original GIF (real cloud-filtering + compositing per year, not an instant mask
// render); 2018 will also look visibly sparser/noisier than 2019 on (~5 Sentinel-2 scenes).
// (An earlier version of this follow-up also swapped the STEP 8 swipe-compare's base layer to real
// imagery -- reverted, user reported it didn't work; STEP 8 is back to the generic Satellite
// basemap + forest-type/mining layers, unchanged from the original swipe implementation.)
//
// *** ADMIN BOUNDARY FIELD NAMES -- UNVERIFIED ON THE EE ASSET, READ FIRST ***
// REGION_FIELD / DISTRICT_FIELD below assume the uploaded gha_admin1 / gha_admin2 assets carry the
// same field names the cleaned shapefiles do elsewhere in this project (see
// diag_02_external_references.R, d_06_gold_deposits.R: adm1_name = region name, adm2_name =
// district name). That's AFTER R's clean_names() runs on the raw shapefile though -- if these
// assets were exported straight from the shapefile without going through that step, the actual EE
// property names could differ in case/underscore (e.g. ADM1_NAME). The two print() calls right
// after ADMIN1/ADMIN2 below dump one feature's full property list to the console on load -- check
// that FIRST if the Region/District dropdowns come up empty on open, and fix the two field
// constants to match rather than guessing again.
//
// *** DATA SOURCE CAVEAT (unchanged from the original script) ***
// The ForTy asset ID/band names below were confirmed via EE Data Catalog documentation research,
// NOT by actually running this script. If GEE throws an "asset not found"/"band not found" error,
// that's the first thing to report back. Catalog page: https://developers.google.com/earth-engine/
// datasets/catalog/projects_nature-trace_assets_forest_typology_forest_typology_2020_v1_0_collection
//
// *** 2020-ONLY BASELINE, NOT AN ANNUAL SERIES ***
// The blog post mentions an annual 2017-2025 ForTy time series, but its EE asset ID could not be
// confirmed from available documentation -- this script uses ForTy's fixed 2020 baseline instead.
// The land-type-breakdown chart, the growth-composition chart, the GIF, and the map year slider are
// all trimmed to DISPLAY_YEARS (2020-2025) for this reason. The cumulative-
// mining TREND chart is the one exception -- it doesn't depend on ForTy at all, so it still runs the
// full EMBED_YEARS (2017-2025).
//
// *** CUMULATIVE mining, not the raw noisy per-year classification ***
// Uses the UNION of mine_mask_ghana_c4_{2017..Y} (monotonically non-decreasing) rather than each
// year's raw independent classification -- deliberately sidesteps the year-to-year volatility this
// whole exercise would otherwise run into (see [[project_temporal_consistency_investigation]] in
// memory), since this script is about a multi-year replacement STORY, not about that open question.
//
// Plain (non-App, non-admin-boundary) version with the original 5 preset districts + Southwest
// Ghana scope lives in explore_mining_vs_forest_type.js -- left exactly as it was, unaffected by
// this file.

var ASSET_HOME  = "projects/rgee-auth-tillam/assets/ghana_mining";
var EMBED_YEARS = [2017, 2018, 2019, 2020, 2021, 2022, 2023, 2024, 2025];
var FORTY_ASSET = "projects/nature-trace/assets/forest_typology/forest_typology_2020_v1_0_collection";

// Satellite GIF range, kept SEPARATE from EMBED_YEARS (2026-11-04, user request: show 2015-2025) --
// the classifier masks (mine_mask_ghana_c4_<yr>) only exist 2017+, but the satellite imagery itself
// (STEP 3b) has no such floor -- Landsat covers 2015 fine. Widening EMBED_YEARS itself would try to
// load a nonexistent mine_mask_ghana_c4_2015/2016 and error.
var SATELLITE_YEARS = [2015, 2016, 2017, 2018, 2019, 2020, 2021, 2022, 2023, 2024, 2025];

// DISPLAY year range: the ForTy forest-type basemap is a fixed 2020 snapshot, so showing 2017-2019
// against it implies the basemap was accurate for years it predates. EMBED_YEARS itself stays the
// FULL 2017-2025 classifier range on purpose -- cumMineByYear (STEP 3) must keep accumulating from
// 2017 so that e.g. cumMineByYear[2020] is the TRUE cumulative footprint through 2020, not just
// 2020's own mask; only the ForTy-dependent charts/GIF/slider are trimmed to DISPLAY_YEARS.
var DISPLAY_START_YEAR = 2020;
var DISPLAY_YEARS = EMBED_YEARS.filter(function (yr) { return yr >= DISPLAY_START_YEAR; });

// Palette: 3 greens for the forest-ORIGIN classes -- Primary dark, Planted pale, and Naturally
// Regenerating a vivid/bright green (not just "medium") so it reads clearly as its own distinct
// class rather than a muddy in-between step -- plus distinct non-green hues for the two classes
// that aren't really "forest" in the strict sense (Plantation = managed/commercial, teal; Tree
// Crops & Agroforestry = agriculture with tree cover, cocoa-brown), grey for Other Land, and
// gold/amber for mining (thematically apt -- gold mining).
var CLASS_NAMES  = ["Primary Forest", "Naturally Regenerating Forest", "Planted Forest",
                     "Plantation Forest", "Tree Crops & Agroforestry", "Other Land"];
var CLASS_COLORS = ["1b5e20", "00c853", "a5d6a7", "00897b", "795548", "bdbdbd"];
var MINING_COLOR = "ffc107";   // gold/amber

// *** 2026-11-03 blank-published-App fix: everything from here to the end of the file is wrapped in
// a try/catch (closed at the very bottom). Diagnosis: the script ran fine interactively in the Code
// Editor (signed in as the owner) but the published App showed a blank page -- the leading
// hypothesis is that SOMETHING in the synchronous setup below (most likely the STEP 4 blocking
// getInfo() district join, or the STEP 7 require() of a third-party community module -- now made
// lazy, see getTextModule()) throws under App/anonymous-viewer conditions in a way it doesn't when
// run interactively. Without this try/catch, an exception anywhere before ui.root.add(mainMap) at
// the very end means ui.root.clear()/.add() never run at all, leaving root at whatever the App
// template initialized it to -- blank, with the actual error visible only in a console no App
// viewer has access to. The catch below renders that error directly into ui.root instead, so it's
// visible on the page itself next time this happens -- report back whatever it says.
try {

// ====================================================================================================
// STEP 1 -- admin boundaries (region = admin1, district = admin2), already uploaded by the user as
// EE assets. See the field-name caveat at the top of this file -- the two print() calls are the
// first thing to check if the dropdowns below come up empty.
// ====================================================================================================
var REGION_FIELD   = "adm1_name";   // name field on the admin1 (region) asset
var DISTRICT_FIELD = "adm2_name";   // name field on the admin2 (district) asset

var ADMIN1 = ee.FeatureCollection(ASSET_HOME + "/gha_admin1");
var ADMIN2 = ee.FeatureCollection(ASSET_HOME + "/gha_admin2");
print("ADMIN1 (region) sample feature -- check property names here if the Region dropdown is empty:",
      ADMIN1.first());
print("ADMIN2 (district) sample feature -- check property names here if the District dropdown is empty:",
      ADMIN2.first());

var GHANA_GEOM = ADMIN1.geometry();   // union of all regions -- used to clip the forest-type layer

// Protected areas -- pulled directly from GEE's public WDPA/WDOECM catalog (confirmed working in
// the Code Editor 2026-11-05: WCMC/WDPA/current/polygons + WCMC/WDOECM/current/polygons), NOT our
// own upload -- no asset to maintain, always current. Ghana + Designated only (excludes "Proposed"
// sites, not yet legally protected). Used for protectedLayer only (STEP 10, outline, toggled via
// protectedCheckbox STEP 9) -- display is lazy-tiled so it's cheap. The per-district mining-in-PA
// STAT is deliberately NOT computed live here (see DISTRICT_PROTECTED_STATS below) -- an earlier
// version did reduce a painted protectedMask inside showStats() and it measurably slowed down
// every "Generate stats" click (painting the whole merged WDPA+WDOECM collection per click, not
// just the few sites near the selection). Precomputed lookup instead: this stat is cross-sectional
// anyway (not a time series), so there's no reason to ever recompute it per click.
var PROTECTED_AREAS = ee.FeatureCollection("WCMC/WDPA/current/polygons")
  .merge(ee.FeatureCollection("WCMC/WDOECM/current/polygons"))
  .filter(ee.Filter.and(
    ee.Filter.eq("ISO3", "GHA"),
    ee.Filter.eq("STATUS", "Designated")
  ));

// Populated 2026-11-05 from diag_05_mining_by_region.qmd Section 6c's output
// (outputs/figures/mining_protected_overlap_by_district.csv, converted to this literal object --
// not an EE asset, a plain JS object keeps the lookup a zero-cost client-side read, no round trip
// at all). Re-run Section 6c and regenerate (same conversion, see that session's scratch script)
// if the underlying mining/protected-area data ever changes.
var DISTRICT_PROTECTED_STATS = {
  "Ablekuma Central Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Ablekuma North Municipal": {miningInPaHa: 0, paTotalHa: 5.25},
  "Ablekuma West Municipal": {miningInPaHa: 0.02, paTotalHa: 155.13},
  "Abuakwa North": {miningInPaHa: 0, paTotalHa: 18.61},
  "Abuakwa South": {miningInPaHa: 0, paTotalHa: 436.22},
  "Abura-Asebu-Kwamankese": {miningInPaHa: 21.12, paTotalHa: 898.98},
  "Accra Metropolis": {miningInPaHa: 0, paTotalHa: 0},
  "Achiase": {miningInPaHa: 0.04, paTotalHa: 11738.53},
  "Ada East": {miningInPaHa: 73.48, paTotalHa: 26255.01},
  "Ada West": {miningInPaHa: 151.08, paTotalHa: 12907.96},
  "Adaklu": {miningInPaHa: 0, paTotalHa: 7726.29},
  "Adansi Akrofuom": {miningInPaHa: 296.36, paTotalHa: 12883.88},
  "Adansi Asokwa": {miningInPaHa: 2.92, paTotalHa: 10564.25},
  "Adansi North": {miningInPaHa: 2.67, paTotalHa: 1754.83},
  "Adansi South": {miningInPaHa: 4.02, paTotalHa: 16036.5},
  "Adenta Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Afadzato South": {miningInPaHa: 0, paTotalHa: 0},
  "Afigya Kwabre North": {miningInPaHa: 0, paTotalHa: 1232.37},
  "Afigya Kwabre South": {miningInPaHa: 0, paTotalHa: 0},
  "Agona East": {miningInPaHa: 0, paTotalHa: 0},
  "Agona West Municipal": {miningInPaHa: 0, paTotalHa: 10.14},
  "Agotime Ziope": {miningInPaHa: 0, paTotalHa: 0},
  "Ahafo Ano North": {miningInPaHa: 0.02, paTotalHa: 2060.1},
  "Ahafo Ano South East": {miningInPaHa: 0, paTotalHa: 3630.14},
  "Ahafo Ano South West": {miningInPaHa: 1.86, paTotalHa: 21451.06},
  "Ahanta West Municipal": {miningInPaHa: 9.62, paTotalHa: 5862.48},
  "Ajumako-Enyan-Essiam": {miningInPaHa: 0, paTotalHa: 0},
  "Akatsi North": {miningInPaHa: 0, paTotalHa: 0},
  "Akatsi South": {miningInPaHa: 10.36, paTotalHa: 18890.36},
  "Akwapem North": {miningInPaHa: 0, paTotalHa: 0},
  "Akwapem South": {miningInPaHa: 0, paTotalHa: 0},
  "Akyem Mansa": {miningInPaHa: 12.16, paTotalHa: 1443.53},
  "Amansie Central": {miningInPaHa: 2694.02, paTotalHa: 13655.5},
  "Amansie South": {miningInPaHa: 609.05, paTotalHa: 14587.87},
  "Amansie West": {miningInPaHa: 682.11, paTotalHa: 4279.92},
  "Anloga": {miningInPaHa: 230.66, paTotalHa: 23222.02},
  "Aowin": {miningInPaHa: 545.41, paTotalHa: 128756.21},
  "Asante Akim Central Municipal": {miningInPaHa: 0.02, paTotalHa: 14.51},
  "Asante Akim North": {miningInPaHa: 0.18, paTotalHa: 37145.23},
  "Asante Akim South": {miningInPaHa: 104.51, paTotalHa: 32192.67},
  "Asene Akroso Manso": {miningInPaHa: 3.71, paTotalHa: 6071.87},
  "Ashaiman Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Asikuma-Odoben-Brakwa": {miningInPaHa: 0.36, paTotalHa: 8742.29},
  "Asokore Mampong Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Asokwa Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Assin Fosu": {miningInPaHa: 0, paTotalHa: 5856.62},
  "Assin North": {miningInPaHa: 0, paTotalHa: 195.82},
  "Assin South": {miningInPaHa: 0, paTotalHa: 34586.38},
  "Asunafo North Municipal": {miningInPaHa: 0.53, paTotalHa: 51798.81},
  "Asunafo South": {miningInPaHa: 0.02, paTotalHa: 18489.15},
  "Asuogyaman": {miningInPaHa: 0, paTotalHa: 26.08},
  "Asutifi North": {miningInPaHa: 0, paTotalHa: 36308.06},
  "Asutifi South": {miningInPaHa: 84.54, paTotalHa: 10690.54},
  "Atebubu Amantin": {miningInPaHa: 0, paTotalHa: 0},
  "Atiwa East": {miningInPaHa: 0, paTotalHa: 17918.93},
  "Atiwa West": {miningInPaHa: 7.47, paTotalHa: 21536.33},
  "Atwima Kwanwoma": {miningInPaHa: 0, paTotalHa: 0},
  "Atwima Mponua": {miningInPaHa: 284.68, paTotalHa: 59125.88},
  "Atwima Nwabiagya North": {miningInPaHa: 0, paTotalHa: 0},
  "Atwima Nwabiagya South": {miningInPaHa: 42.76, paTotalHa: 1279.72},
  "Awutu Senya": {miningInPaHa: 3.47, paTotalHa: 446.66},
  "Awutu Senya East": {miningInPaHa: 0, paTotalHa: 0},
  "Ayawaso Central Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Ayawaso East Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Ayawaso North Municipal": {miningInPaHa: 0, paTotalHa: 5.36},
  "Ayawaso West": {miningInPaHa: 0.44, paTotalHa: 151.41},
  "Ayensuano": {miningInPaHa: 0.3, paTotalHa: 71.33},
  "Banda": {miningInPaHa: 8.34, paTotalHa: 108075.54},
  "Bawku Municipal": {miningInPaHa: 0, paTotalHa: 626.96},
  "Bawku West": {miningInPaHa: 9.41, paTotalHa: 20808.16},
  "Bekwai Municipal": {miningInPaHa: 0.45, paTotalHa: 26.9},
  "Berekum East Municipal": {miningInPaHa: 0.35, paTotalHa: 20305.92},
  "Berekum West": {miningInPaHa: 0, paTotalHa: 9307.77},
  "Bia East": {miningInPaHa: 0.62, paTotalHa: 33950.7},
  "Bia West": {miningInPaHa: 50.13, paTotalHa: 72251.64},
  "Biakoye": {miningInPaHa: 0, paTotalHa: 12148.98},
  "Bibiani-Anhwiaso-Bekwai Municipal": {miningInPaHa: 617.8, paTotalHa: 26231.14},
  "Binduri": {miningInPaHa: 0, paTotalHa: 836.14},
  "Birim Central Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Birim North": {miningInPaHa: 2.28, paTotalHa: 11168.54},
  "Birim South": {miningInPaHa: 10.85, paTotalHa: 7427.97},
  "Bodi": {miningInPaHa: 44.11, paTotalHa: 16902.71},
  "Bole": {miningInPaHa: 103.67, paTotalHa: 184777.36},
  "Bolga East": {miningInPaHa: 0, paTotalHa: 0},
  "Bolgatanga Municipal": {miningInPaHa: 0, paTotalHa: 11852.67},
  "Bongo": {miningInPaHa: 0.78, paTotalHa: 2535.06},
  "Bosome Freho": {miningInPaHa: 39.16, paTotalHa: 16050.39},
  "Bosomtwe": {miningInPaHa: 2.4, paTotalHa: 607.04},
  "Builsa North": {miningInPaHa: 0, paTotalHa: 13489.41},
  "Builsa South": {miningInPaHa: 0, paTotalHa: 17224.31},
  "Bunkpurugu Nakpanduri": {miningInPaHa: 0, paTotalHa: 9127},
  "Cape Coast Metropolitan": {miningInPaHa: 0.78, paTotalHa: 257.3},
  "Central Gonja": {miningInPaHa: 14.67, paTotalHa: 81016.85},
  "Central Tongu": {miningInPaHa: 0, paTotalHa: 9},
  "Chereponi": {miningInPaHa: 0, paTotalHa: 0},
  "Daffiama Bussie Issa": {miningInPaHa: 0, paTotalHa: 15500.75},
  "Denkyembour": {miningInPaHa: 0, paTotalHa: 30.03},
  "Dormaa East": {miningInPaHa: 0, paTotalHa: 72.93},
  "Dormaa Municipal": {miningInPaHa: 0, paTotalHa: 49254.21},
  "Dormaa West": {miningInPaHa: 0, paTotalHa: 360.99},
  "East Gonja Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "East Mamprusi": {miningInPaHa: 13.65, paTotalHa: 28523.96},
  "Effia Kwesimintsim Municipal": {miningInPaHa: 0.28, paTotalHa: 0.28},
  "Effutu Municipal": {miningInPaHa: 7.61, paTotalHa: 2900.09},
  "Ejisu Municipal": {miningInPaHa: 0, paTotalHa: 85.35},
  "Ejura-Sekyedumase": {miningInPaHa: 0.18, paTotalHa: 19954.35},
  "Ekumfi": {miningInPaHa: 0, paTotalHa: 0},
  "Ellembelle": {miningInPaHa: 0.18, paTotalHa: 10815.93},
  "Fanteakwa North": {miningInPaHa: 0, paTotalHa: 30328.25},
  "Fanteakwa South": {miningInPaHa: 0, paTotalHa: 2727.08},
  "Ga Central Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Ga East": {miningInPaHa: 0, paTotalHa: 1.94},
  "Ga North Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Ga South Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Ga West Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Garu": {miningInPaHa: 0.19, paTotalHa: 6251.9},
  "Gomoa Central": {miningInPaHa: 4.33, paTotalHa: 3259.7},
  "Gomoa East": {miningInPaHa: 14.41, paTotalHa: 4088.43},
  "Gomoa West": {miningInPaHa: 0, paTotalHa: 0},
  "Gushegu": {miningInPaHa: 0, paTotalHa: 8135.04},
  "Ho Municipal": {miningInPaHa: 0, paTotalHa: 963.67},
  "Ho West": {miningInPaHa: 0, paTotalHa: 1766.32},
  "Hohoe Municipal": {miningInPaHa: 0, paTotalHa: 6000.37},
  "Jaman North": {miningInPaHa: 0, paTotalHa: 48.68},
  "Jaman South Municipal": {miningInPaHa: 0, paTotalHa: 160.06},
  "Jasikan": {miningInPaHa: 0, paTotalHa: 2638.86},
  "Jirapa": {miningInPaHa: 0, paTotalHa: 0},
  "Jomoro": {miningInPaHa: 2.51, paTotalHa: 50683.86},
  "Juaben Municipal": {miningInPaHa: 0, paTotalHa: 2811.43},
  "Juaboso": {miningInPaHa: 177.92, paTotalHa: 91184.68},
  "Kadjebi": {miningInPaHa: 0, paTotalHa: 10937.53},
  "Karaga": {miningInPaHa: 0, paTotalHa: 23461.34},
  "Kasena Nankana East": {miningInPaHa: 0, paTotalHa: 16213.11},
  "Kasena Nankana West": {miningInPaHa: 0, paTotalHa: 18163.72},
  "Keta Municipal": {miningInPaHa: 129.18, paTotalHa: 51378.29},
  "Ketu North": {miningInPaHa: 0.09, paTotalHa: 238.58},
  "Ketu South": {miningInPaHa: 88.29, paTotalHa: 9973.41},
  "Kintampo North Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Kintampo South": {miningInPaHa: 0, paTotalHa: 16263.43},
  "Komenda-Edina-Eguafo-Abirem Municipal": {miningInPaHa: 8.91, paTotalHa: 471.79},
  "Korle Klottey Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Kpandai": {miningInPaHa: 0, paTotalHa: 0},
  "Kpando Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Kpone Katamanso": {miningInPaHa: 0, paTotalHa: 0},
  "Krachi East Municipal": {miningInPaHa: 0, paTotalHa: 15640.6},
  "Krachi Nchumuru": {miningInPaHa: 0, paTotalHa: 0},
  "Krachi West": {miningInPaHa: 0, paTotalHa: 0},
  "Krowor Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Kumasi Metropolitan": {miningInPaHa: 0, paTotalHa: 96.87},
  "Kumbungu": {miningInPaHa: 0, paTotalHa: 0},
  "Kwabre East": {miningInPaHa: 0, paTotalHa: 0},
  "Kwadaso Municipal": {miningInPaHa: 0, paTotalHa: 63.27},
  "Kwaebibirem": {miningInPaHa: 0, paTotalHa: 11090.77},
  "Kwahu Afram Plains North": {miningInPaHa: 0, paTotalHa: 0},
  "Kwahu Afram Plains South": {miningInPaHa: 0, paTotalHa: 0},
  "Kwahu East": {miningInPaHa: 0.09, paTotalHa: 13423.84},
  "Kwahu South": {miningInPaHa: 0.09, paTotalHa: 20737.58},
  "Kwahu West": {miningInPaHa: 0.09, paTotalHa: 5664.66},
  "La-Nkwantanang-Madina": {miningInPaHa: 0, paTotalHa: 0},
  "La Dade-Kotopon": {miningInPaHa: 0, paTotalHa: 0},
  "Lambussie-Karni": {miningInPaHa: 0, paTotalHa: 7737.94},
  "Lawra": {miningInPaHa: 0, paTotalHa: 0},
  "Ledzokuku Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Lower Manya": {miningInPaHa: 0, paTotalHa: 5004.88},
  "Mampong Municipal": {miningInPaHa: 0, paTotalHa: 14784.11},
  "Mamprugu Moagduri": {miningInPaHa: 0, paTotalHa: 196.43},
  "Mfantseman Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Mion": {miningInPaHa: 0, paTotalHa: 5779.21},
  "Mpohor": {miningInPaHa: 191.87, paTotalHa: 2924.37},
  "Nabdam": {miningInPaHa: 0.79, paTotalHa: 8121.56},
  "Nadowli-Kaleo": {miningInPaHa: 0, paTotalHa: 0},
  "Nandom": {miningInPaHa: 0, paTotalHa: 0},
  "Nanton": {miningInPaHa: 0, paTotalHa: 0},
  "Nanumba North": {miningInPaHa: 0, paTotalHa: 26987.24},
  "Nanumba South": {miningInPaHa: 0, paTotalHa: 1392.39},
  "New Juaben North Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "New Juaben South Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Ningo/Prampram": {miningInPaHa: 0, paTotalHa: 0},
  "Nkoranza North": {miningInPaHa: 0, paTotalHa: 11514.34},
  "Nkoranza South": {miningInPaHa: 0, paTotalHa: 2459.06},
  "Nkwanta North": {miningInPaHa: 0, paTotalHa: 0},
  "Nkwanta South Municipal": {miningInPaHa: 0, paTotalHa: 47981.31},
  "North Dayi": {miningInPaHa: 0, paTotalHa: 3098},
  "North East Gonja": {miningInPaHa: 0, paTotalHa: 0},
  "North Gonja": {miningInPaHa: 0, paTotalHa: 269918.87},
  "North Tongu": {miningInPaHa: 0, paTotalHa: 0},
  "Nsawam Adoagyiri": {miningInPaHa: 0, paTotalHa: 0},
  "Nzema East": {miningInPaHa: 14.57, paTotalHa: 21479.15},
  "Obuasi East": {miningInPaHa: 0.92, paTotalHa: 94.19},
  "Obuasi Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Offinso Municipal": {miningInPaHa: 0, paTotalHa: 11136.92},
  "Offinso North": {miningInPaHa: 8.25, paTotalHa: 42403.11},
  "Oforikrom Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Okaikwei North Municipal": {miningInPaHa: 3.56, paTotalHa: 359.92},
  "Okere": {miningInPaHa: 0, paTotalHa: 87.6},
  "Old Tafo Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Prestea/Huni Valley": {miningInPaHa: 555.83, paTotalHa: 29538.61},
  "Pru East": {miningInPaHa: 0, paTotalHa: 0},
  "Pru West": {miningInPaHa: 0, paTotalHa: 0},
  "Pusiga": {miningInPaHa: 0, paTotalHa: 448.9},
  "Saboba": {miningInPaHa: 0, paTotalHa: 0},
  "Sagnerigu": {miningInPaHa: 0, paTotalHa: 125.36},
  "Savelugu": {miningInPaHa: 0, paTotalHa: 13809.33},
  "Sawla-Tuna-Kalba": {miningInPaHa: 0, paTotalHa: 54295.44},
  "Sefwi-Wiawso": {miningInPaHa: 2.33, paTotalHa: 24708.08},
  "Sefwi Akontombra": {miningInPaHa: 23.92, paTotalHa: 60812.76},
  "Sekondi Takoradi Metropolis": {miningInPaHa: 0.22, paTotalHa: 60.44},
  "Sekyere Afram Plains North": {miningInPaHa: 0, paTotalHa: 2757.96},
  "Sekyere Central": {miningInPaHa: 0.18, paTotalHa: 47636.24},
  "Sekyere East": {miningInPaHa: 0.36, paTotalHa: 2680.38},
  "Sekyere Kumawu": {miningInPaHa: 0, paTotalHa: 28832.94},
  "Sekyere South": {miningInPaHa: 0, paTotalHa: 2201.63},
  "Sene East": {miningInPaHa: 0, paTotalHa: 208792.72},
  "Sene West": {miningInPaHa: 0, paTotalHa: 68266.76},
  "Shai Osudoku": {miningInPaHa: 0, paTotalHa: 5185.54},
  "Shama": {miningInPaHa: 3.96, paTotalHa: 200.69},
  "Sissala East": {miningInPaHa: 0, paTotalHa: 22191.97},
  "Sissala West": {miningInPaHa: 0, paTotalHa: 17940.06},
  "South Dayi": {miningInPaHa: 0, paTotalHa: 0},
  "South Tongu": {miningInPaHa: 100.95, paTotalHa: 42976.32},
  "Suaman": {miningInPaHa: 479.28, paTotalHa: 18444.28},
  "Suame Municipal": {miningInPaHa: 0.63, paTotalHa: 22.87},
  "Suhum Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Sunyani Municipal": {miningInPaHa: 0.18, paTotalHa: 9016.12},
  "Sunyani West": {miningInPaHa: 0.18, paTotalHa: 31246.72},
  "Tain": {miningInPaHa: 0, paTotalHa: 89.7},
  "Talensi": {miningInPaHa: 3.76, paTotalHa: 27607.29},
  "Tamale Metropolitan": {miningInPaHa: 0, paTotalHa: 106.93},
  "Tano North Municipal": {miningInPaHa: 0, paTotalHa: 16577.62},
  "Tano South Municipal": {miningInPaHa: 0, paTotalHa: 284.78},
  "Tarkwa Nsuaem": {miningInPaHa: 552.46, paTotalHa: 13765.15},
  "Tatale Sanguli": {miningInPaHa: 0, paTotalHa: 0},
  "Techiman Municipal": {miningInPaHa: 0, paTotalHa: 3235.49},
  "Techiman North": {miningInPaHa: 0, paTotalHa: 0},
  "Tema Metropolitan": {miningInPaHa: 5.79, paTotalHa: 688},
  "Tema West Municipal": {miningInPaHa: 12.52, paTotalHa: 671.35},
  "Tempane": {miningInPaHa: 0, paTotalHa: 763.68},
  "Tolon": {miningInPaHa: 0, paTotalHa: 0},
  "Twifo Atti-Morkwa": {miningInPaHa: 0, paTotalHa: 24972.6},
  "Twifo Hemang Lower Denkyira": {miningInPaHa: 0, paTotalHa: 6446.71},
  "Upper Denkyira East Municipal": {miningInPaHa: 1.63, paTotalHa: 1352.95},
  "Upper Denkyira West": {miningInPaHa: 1.25, paTotalHa: 86.32},
  "Upper Manya": {miningInPaHa: 0, paTotalHa: 459.46},
  "Upper West Akim": {miningInPaHa: 0, paTotalHa: 0},
  "Wa East": {miningInPaHa: 0, paTotalHa: 15265.71},
  "Wa Municipal": {miningInPaHa: 0, paTotalHa: 0},
  "Wa West": {miningInPaHa: 0, paTotalHa: 0},
  "Wassa Amenfi Central": {miningInPaHa: 866.5, paTotalHa: 50564},
  "Wassa Amenfi East": {miningInPaHa: 1511.79, paTotalHa: 40863.31},
  "Wassa Amenfi West": {miningInPaHa: 77.36, paTotalHa: 23800.09},
  "Wassa East": {miningInPaHa: 306.55, paTotalHa: 75219.01},
  "Weija Gbawe Municipal": {miningInPaHa: 183.94, paTotalHa: 5835.01},
  "Wenchi Municipal": {miningInPaHa: 15, paTotalHa: 9303.22},
  "West Akim": {miningInPaHa: 3.7, paTotalHa: 3803.31},
  "West Gonja": {miningInPaHa: 1.06, paTotalHa: 198817.35},
  "West Mamprusi Municipal": {miningInPaHa: 5.27, paTotalHa: 6302.49},
  "Yendi Municipal": {miningInPaHa: 0, paTotalHa: 244.19},
  "Yilo Krobo": {miningInPaHa: 0, paTotalHa: 3198.26},
  "Yunyoo-Nasuan": {miningInPaHa: 0, paTotalHa: 0},
  "Zabzugu": {miningInPaHa: 0, paTotalHa: 0}
};

// ====================================================================================================
// STEP 2 -- build the ForTy categorical forest-type map (argmax over 5 prob bands + derived "other")
// -- NATIONAL (clipped to Ghana), built once, independent of location (only reduced per-location
// later on, in showStats()/generateGif()).
// ====================================================================================================
var forty = ee.ImageCollection(FORTY_ASSET).mosaic();
var fortyBands = ["PrimaryForest", "NaturallyRegeneratingForest", "PlantedForest",
                   "PlantationForest", "TreeCropsAndAgroforestry"];
var probSum = forty.select(fortyBands).reduce(ee.Reducer.sum());
var otherLand = ee.Image(250).subtract(probSum).rename("OtherLand");
var allClassProbs = forty.select(fortyBands).addBands(otherLand);

// class 1-6: PrimaryForest, NaturallyRegeneratingForest, PlantedForest, PlantationForest,
// TreeCropsAndAgroforestry, OtherLand (argmax + 1, per the catalog page's own recommended pattern)
var forestClass = allClassProbs.toArray().arrayArgmax().arrayGet([0]).add(1).rename("forest_class")
  .clip(GHANA_GEOM);

// ====================================================================================================
// STEP 3 -- cumulative mining mask per year -- NATIONAL, built once, independent of location (same
// reasoning as forestClass; only clipped/reduced per-location later, in the button handlers).
// ====================================================================================================
var cumMineByYear = {};
var runningMine = ee.Image(0).rename("cum_mine");
EMBED_YEARS.forEach(function (yr) {
  var mineYr = ee.Image(ASSET_HOME + "/mine_mask_ghana_c4_" + yr).unmask(0);
  runningMine = runningMine.or(mineYr).rename("cum_mine_" + yr);
  cumMineByYear[yr] = runningMine;
});

// ====================================================================================================
// STEP 3b -- true-colour composite helpers, for the satellite GIF (STEP 7b). Same technique as
// validate_change_gif.js (dry-season window to dodge cloud-driven flicker, SCL/QA cloud masks),
// parametrized by geometry (not a fixed AOI) since this app renders over whichever district is
// currently selected, not one fixed site. Sentinel-2 from SENTINEL2_START_YEAR on; Landsat 5/7/8
// before that -- confirmed in validate_change_gif.js that COPERNICUS/S2_SR_HARMONIZED has ZERO
// scenes over this kind of AOI for the 2017 dry season (2018 itself stays on Sentinel-2 but will
// look visibly sparser/noisier than 2019 on, ~5 scenes). The GIF runs the full EMBED_YEARS
// (2017-2025, not DISPLAY_YEARS) BECAUSE of this Landsat fallback -- unlike the ForTy-dependent
// charts/GIF/slider, the satellite GIF has no 2020-only-baseline reason to start later.
// ====================================================================================================
var SENTINEL2_START_YEAR = 2018;
var S2_CLOUD_MAX = 20;   // tighter than the project default (40%) -- fewer clouds, less GIF flicker

function maskS2Clouds(img) {
  var scl = img.select("SCL");
  return img.updateMask(scl.neq(3).and(scl.neq(9))).divide(10000);   // 3=cloud shadow, 9=cloud (high prob)
}

function s2DrySeasonComposite(yr, geom) {
  // Nov(yr-1) -> Mar(yr): the composite labelled `yr` is that year's dry season, not calendar year.
  var start = ee.Date.fromYMD(yr - 1, 11, 1);
  var end   = ee.Date.fromYMD(yr, 3, 31);
  var base = ee.ImageCollection("COPERNICUS/S2_SR_HARMONIZED").filterBounds(geom).filterDate(start, end);
  var strict = base.filter(ee.Filter.lt("CLOUDY_PIXEL_PERCENTAGE", S2_CLOUD_MAX));
  // server-side fallback: widen to 80% if S2_CLOUD_MAX leaves nothing for an unusually cloudy year,
  // rather than silently handing median() an empty collection.
  var col = ee.ImageCollection(ee.Algorithms.If(strict.size().gt(0), strict,
    base.filter(ee.Filter.lt("CLOUDY_PIXEL_PERCENTAGE", 80))));
  return col.map(maskS2Clouds).median().select(["B4", "B3", "B2"]).clip(geom);
}

// ---- Landsat 5/7/8 true-colour fallback (pre-Sentinel-2-coverage years only) -- same QA_PIXEL
// cloud-mask bits + C2 L2 scale factors as build_04_backdating.R Section 5 / validate_change_gif.js.
var LANDSAT_CLOUD_MAX = 80;   // % scene cloud cover, loose on purpose -- Landsat's revisit is sparse

function maskLandsatQA(img) {
  var qa = img.select("QA_PIXEL");
  var clear = qa.bitwiseAnd(1 << 1).eq(0)
    .and(qa.bitwiseAnd(1 << 3).eq(0))
    .and(qa.bitwiseAnd(1 << 4).eq(0));
  var sat = img.select("QA_RADSAT").eq(0);
  return img.updateMask(clear).updateMask(sat);
}
// NOT filterBounds()'d here -- built once at load, before any unit is selected. filterBounds(geom)
// happens inside landsatDrySeasonComposite() below instead, re-reading whichever geom is passed at
// call time (ee objects are immutable -- baking a bounds filter in here would freeze it to nothing,
// since no geom exists yet at load time).
function prepLandsat(id, bands) {
  return ee.ImageCollection(id)
    .filter(ee.Filter.lt("CLOUD_COVER", LANDSAT_CLOUD_MAX))
    .map(maskLandsatQA)
    .map(function (img) {
      // .select(...).multiply(...).add(...) strips system:time_start -- copyProperties re-attaches
      // it. Without this, every later filterDate() silently matches nothing, for every image, every
      // year (validate_change_gif.js hit exactly this bug -- "FIX 2" in its own comments).
      return img.select(bands, ["RED", "GREEN", "BLUE"]).multiply(0.0000275).add(-0.2)
        .copyProperties(img, ["system:time_start"]);
    });
}
var LANDSAT_TM  = ["SR_B3", "SR_B2", "SR_B1"];   // L5/L7 true-colour: red, green, blue
var LANDSAT_OLI = ["SR_B4", "SR_B3", "SR_B2"];   // L8    true-colour: red, green, blue
var landsatCol = prepLandsat("LANDSAT/LT05/C02/T1_L2", LANDSAT_TM)
  .merge(prepLandsat("LANDSAT/LE07/C02/T1_L2", LANDSAT_TM))
  .merge(prepLandsat("LANDSAT/LC08/C02/T1_L2", LANDSAT_OLI));

function landsatDrySeasonComposite(yr, geom) {
  // Aug(yr-1) -> Apr(yr): wider than S2's window -- Landsat's 16-day/1-2-sensor revisit is much
  // sparser than Sentinel-2's 5-day/2-satellite cadence.
  var start = ee.Date.fromYMD(yr - 1, 8, 1);
  var end   = ee.Date.fromYMD(yr, 4, 30);
  return landsatCol.filterBounds(geom).filterDate(start, end).median().clip(geom);
}

// picks Landsat (pre-SENTINEL2_START_YEAR) vs Sentinel-2 (SENTINEL2_START_YEAR on) -- same
// visualize() stretch for both, since both are scaled surface reflectance in roughly 0-0.3.
function imageryVis(yr, geom) {
  var img = (yr < SENTINEL2_START_YEAR) ? landsatDrySeasonComposite(yr, geom) : s2DrySeasonComposite(yr, geom);
  return img.visualize({min: 0, max: 0.3});
}

// ====================================================================================================
// STEP 4 -- restrict the Region/District dropdowns to the regions that actually matter. The
// diag_05_mining_by_region.qmd region chart made it clear only 5 regions carry any real galamsey
// footprint -- ALLOWED_REGIONS hardcodes those (explicit user call, 2026-11-03), rather than relying
// on a km2 threshold to infer it. MIN_MINING_KM2 still does a second, finer job: dropping the
// near-zero-mining DISTRICTS *within* those 5 regions (every region has a few scattered noise
// districts). One combined reduceRegions() + one getInfo() builds {district, region, mining_first,
// mining_final} rows for ALL districts in a single round trip. Region membership is determined
// SPATIALLY (district centroid inside a region polygon), not by matching a region-name field between
// the two independently-sourced admin1/admin2 assets -- that attribute-matching approach is what
// caused a "Cannot read properties of null (reading 'coordinates')" crash in an earlier version of
// this script: the two assets' region-name spellings didn't line up, the attribute filter matched
// zero features, and Map.centerObject() got an empty/null geometry. The spatial join sidesteps that
// mismatch entirely, and also means REGION_NAMES/MINING_DISTRICTS_BY_REGION below need only ONE field
// name each (REGION_FIELD on ADMIN1, DISTRICT_FIELD on ADMIN2) rather than a field that has to agree
// across both assets.
// ====================================================================================================
var ALLOWED_REGIONS = ["Western", "Ashanti", "Central", "Eastern", "Western North"];
function isAllowedRegion(regionName) {
  if (!regionName) return false;
  var lower = regionName.toLowerCase();
  return ALLOWED_REGIONS.some(function (r) { return r.toLowerCase() === lower; });
}

// MIN_MINING_KM2: within the 5 allowed regions, drops districts with only scattered noise pixels.
// Provisional value pending diag_05_mining_by_region.qmd (companion R report, same folder), which
// plots the district-level mining-area distribution and units retained at several candidate cutoffs.
var MIN_MINING_KM2 = 1;
var areaKm2 = ee.Image.pixelArea().divide(1e6);
var MINING_FINAL = cumMineByYear[EMBED_YEARS[EMBED_YEARS.length - 1]];

var districtsWithRegion = ADMIN2.select([DISTRICT_FIELD]).map(function (f) {
  var regionName = ADMIN1.filterBounds(f.geometry().centroid()).first().get(REGION_FIELD);
  return f.set("region_name", regionName);
});
// Two bands (not just the final year) -- mining_first/mining_final feed both the dropdown filter
// AND the "try a district" examples (STEP 9), so this stays a single combined round trip.
var districtMiningImg = ee.Image.cat([
  cumMineByYear[DISPLAY_YEARS[0]].multiply(areaKm2).rename("mining_first"),
  MINING_FINAL.multiply(areaKm2).rename("mining_final")
]);
var districtMiningStats = districtMiningImg.reduceRegions({
  collection: districtsWithRegion, reducer: ee.Reducer.sum(), scale: 30, tileScale: 8
});
var districtRows = districtMiningStats.map(function (f) {
  return ee.Feature(null, {
    district: f.get(DISTRICT_FIELD), region: f.get("region_name"),
    mining_first: f.get("mining_first"), mining_final: f.get("mining_final")
  });
}).getInfo().features.map(function (f) { return f.properties; });   // single BLOCKING round trip

var MINING_DISTRICTS_BY_REGION = {};
districtRows.forEach(function (row) {
  if (isAllowedRegion(row.region) && row.mining_final > MIN_MINING_KM2) {
    if (!MINING_DISTRICTS_BY_REGION[row.region]) MINING_DISTRICTS_BY_REGION[row.region] = [];
    MINING_DISTRICTS_BY_REGION[row.region].push(row.district);
  }
});
var REGION_NAMES = Object.keys(MINING_DISTRICTS_BY_REGION).sort();
REGION_NAMES.forEach(function (r) { MINING_DISTRICTS_BY_REGION[r].sort(); });

// Speed-up (user call, 2026-11-03): now that REGION_NAMES is known, clip forestClass/cumMineByYear
// down to just the union of those regions -- everything downstream (main map tiles, GIFs,
// "Generate stats" reduceRegions) then renders/computes over a much smaller area than all
// of Ghana. Done AFTER the district join above, not before -- that join needs the NATIONAL
// forestClass/cumMineByYear to even determine which regions qualify in the first place.
var ALLOWED_REGIONS_GEOM = ADMIN1.filter(ee.Filter.inList(REGION_FIELD, REGION_NAMES)).geometry();
forestClass = forestClass.clip(ALLOWED_REGIONS_GEOM);
EMBED_YEARS.forEach(function (yr) { cumMineByYear[yr] = cumMineByYear[yr].clip(ALLOWED_REGIONS_GEOM); });

print(REGION_NAMES.length + " of " + ALLOWED_REGIONS.length + " allowed regions (" +
      ALLOWED_REGIONS.join(", ") + ") matched + have > " + MIN_MINING_KM2 + " km2 of cumulative " +
      "mining in some district (through " + EMBED_YEARS[EMBED_YEARS.length - 1] + "), across " +
      REGION_NAMES.reduce(function (n, r) { return n + MINING_DISTRICTS_BY_REGION[r].length; }, 0) +
      " districts -- the dropdowns below are restricted to these. If REGION_NAMES comes back shorter " +
      "than ALLOWED_REGIONS, check the ADMIN1 property printout above for a spelling mismatch.");

function districtNamesForRegion(regionName) {
  return MINING_DISTRICTS_BY_REGION[regionName] || [];
}

// Default region on first open: Ashanti if it cleared the mining threshold (it should -- it's the
// biggest galamsey region), falling back to whichever region ranks first alphabetically otherwise
// (e.g. if ADMIN1's spelling/casing differs from "Ashanti").
var DEFAULT_REGION = REGION_NAMES.filter(function (r) { return r.toLowerCase() === "ashanti"; })[0] ||
  REGION_NAMES[0];

// NOTE 2026-11-03: a national region-by-region overview chart (2020 level + growth to 2025, summed
// from districtRows above) used to live here and get appended to every "Generate stats" run. Pulled
// back out (user call) -- it's a static, selection-independent figure, better suited to a documented
// report than to a per-unit exploration tool. See diag_05_mining_by_region.qmd (same folder) instead.

// ====================================================================================================
// STEP 5 -- shared selection state. District-only (Region mode REMOVED 2026-11-04, user call -- a
// full region, e.g. Ashanti ~24,000 km2, was too computationally intensive for "Generate stats"/
// the published App). Set by onRegionChange/onDistrictChange (wired up in STEP 9), read at CALL time
// by showStats()/generateGif(), so whichever dropdown fired most recently wins.
//   currentGeom  -- ee.Geometry (the selected district's own polygon, used directly for the chart
//                   reduceRegion and the GIF crop)
//   currentLabel -- display string for chart titles / status label
// ----------------------------------------------------------------------------------------------------
var currentGeom, currentLabel;

function outlineImageForGeom(geom) {
  // Red boundary only (transparent fill) -- ee.FeatureCollection.style() is the simplest route to
  // an outline-only rendering, no paint()/mask fiddling needed.
  return ee.FeatureCollection([ee.Feature(geom)]).style({color: "ff0000", fillColor: "00000000", width: 3});
}

function setSelection(regionName, districtName, geom) {
  currentGeom = geom;
  currentLabel = districtName + " (" + regionName + ")";
  statusLabel.setValue("Selected: " + currentLabel);
  mainMap.centerObject(currentGeom);
  outlineLayer.setEeObject(outlineImageForGeom(currentGeom));
  outlineLayer.setName("Selected district outline");
}

function onRegionChange(regionName) {
  // The region dropdown just scopes which (mining) districts are offered -- it was never itself a
  // selectable analysis unit, so no mode check needed here any more.
  var names = districtNamesForRegion(regionName);
  districtSelect.items().reset(names);
  if (names.length === 0) {
    statusLabel.setValue("No mining districts found for region: " + regionName + ".");
    return;
  }
  districtSelect.setValue(names[0], true);   // true -> fires onDistrictChange
}

function onDistrictChange(districtName) {
  if (!districtName) return;
  var regionName = regionSelect.getValue();
  // District names are matched directly against ADMIN2 -- no dependence on a region-name field
  // agreeing between ADMIN1 and ADMIN2 (see STEP 4 for why that used to break).
  var geom = ADMIN2.filter(ee.Filter.eq(DISTRICT_FIELD, districtName)).geometry();
  setSelection(regionName, districtName, geom);
}

// ====================================================================================================
// STEP 6 -- "Generate stats" button: reduceRegion over the selected district's own polygon,
// producing all three charts' data from ONE combined image / ONE round trip.
// ====================================================================================================
function showStats() {
  var scale     = 10;
  var tileScale = 8;

  var bandsOut = [];
  EMBED_YEARS.forEach(function (yr) {   // full 2017-2025 range -- feeds the trend chart
    bandsOut.push(cumMineByYear[yr].multiply(areaKm2).rename("mining_" + yr));
  });
  DISPLAY_YEARS.forEach(function (yr) {   // ForTy-dependent -- feeds the land-type breakdown chart
    for (var c = 1; c <= 6; c++) {
      var classMask = forestClass.eq(c).and(cumMineByYear[yr].not());
      bandsOut.push(classMask.multiply(areaKm2).rename("class" + c + "_" + yr));
    }
  });
  // "growth composition" bands: of the forest in the 2020 ForTy baseline, how much of EACH class
  // got newly absorbed into mining during DISPLAY_YEARS -- isolates GROWTH, same framing as the
  // original manual finding this script generalizes (76.9% of 2020-2025 growth traced to forest in
  // the Nkotumso hotspot: cocoa/agroforestry -34, naturally regenerating -20, primary forest -6
  // km2; only 23.1% from already-non-forest "Other Land").
  var newlyMined = cumMineByYear[DISPLAY_YEARS[DISPLAY_YEARS.length - 1]].and(cumMineByYear[DISPLAY_YEARS[0]].not());
  for (var c2 = 1; c2 <= 6; c2++) {
    bandsOut.push(forestClass.eq(c2).and(newlyMined).multiply(areaKm2).rename("growth_class" + c2));
  }
  var combinedImg = ee.Image.cat(bandsOut);

  resultsPanel.clear();
  resultsPanel.add(ui.Label(currentLabel + " -- computing, please wait...", {fontWeight: "bold"}));
  print(currentLabel + " -- computing mining trend (" + EMBED_YEARS.length + " yrs) + 6-class " +
        "forest-type area (" + DISPLAY_YEARS.length + " yrs) + growth composition, scale=" + scale + ".");
  var stats = combinedImg.reduceRegion({
    reducer: ee.Reducer.sum(), geometry: currentGeom, scale: scale, maxPixels: 1e10, tileScale: tileScale
  }).getInfo();   // single BLOCKING round trip

  resultsPanel.clear();
  resultsPanel.add(ui.Label(currentLabel, {fontWeight: "bold", fontSize: "14px"}));

  // ---- chart 1: cumulative galamsey coverage trend, full 2017-2025 (doesn't depend on ForTy) -----
  // NOTE: chart widgets go to resultsPanel.add() ONLY -- a widget printed to the console can't also
  // be added to a panel ("Widgets cannot be added to a panel if they have been printed in the
  // console"), and resultsPanel (App-visible) is the one that actually matters here.
  var trendRows = EMBED_YEARS.map(function (yr) {
    return ee.Feature(null, {year: yr, "Gold mining area (km2)": stats["mining_" + yr]});
  });
  var trendChart = ui.Chart.feature.byFeature(ee.FeatureCollection(trendRows), "year", ["Gold mining area (km2)"])
    .setChartType("LineChart")
    .setOptions({
      title: currentLabel + " -- cumulative galamsey coverage, 2017-2025",
      colors: [MINING_COLOR], pointSize: 4,
      // explicit integer ticks -- a LineChart's numeric x-axis otherwise auto-picks "nice" fractional
      // gridlines (e.g. 2017.5, 2022.5) for a 9-point 2017-2025 domain, which reads badly for years.
      hAxis: {title: "Year", ticks: EMBED_YEARS, format: "####"},
      vAxis: {title: "Area (km2)"}, legend: {position: "none"}
    });
  resultsPanel.add(trendChart);

  // ---- one-line protected-area stat -- precomputed LOOKUP, not a live reduceRegion (see
  // DISTRICT_PROTECTED_STATS above for why: this is cross-sectional, no reason to ever recompute
  // it per click, and painting the WDPA/WDOECM collection live measurably slowed "Generate stats").
  var paEntry = DISTRICT_PROTECTED_STATS[districtSelect.getValue()];
  var paLine;
  if (!paEntry) {
    paLine = "Protected-area overlap not available yet for " + currentLabel +
      " (DISTRICT_PROTECTED_STATS not yet populated -- see TODO near its definition).";
  } else if (paEntry.paTotalHa === 0) {
    paLine = "No WDPA/WDOECM protected areas recorded in " + currentLabel + ".";
  } else {
    paLine = Math.round(paEntry.miningInPaHa) + " ha of " + currentLabel + "'s " +
      Math.round(paEntry.paTotalHa) + " ha of protected land (WDPA/WDOECM) show gold mining (" +
      (100 * paEntry.miningInPaHa / paEntry.paTotalHa).toFixed(1) + "%).";
  }
  resultsPanel.add(ui.Label(paLine, {fontStyle: "italic", margin: "4px 0 10px 0"}));

  // ---- chart 2: per-year stacked land-type breakdown (mining + remaining forest classes) ---------
  var chartRows = DISPLAY_YEARS.map(function (yr) {
    var props = {year: yr, "Gold Mining": stats["mining_" + yr]};
    for (var c = 1; c <= 6; c++) props[CLASS_NAMES[c - 1]] = stats["class" + c + "_" + yr];
    return ee.Feature(null, props);
  });
  var seriesNames = ["Gold Mining"].concat(CLASS_NAMES);
  var seriesColors = [MINING_COLOR].concat(CLASS_COLORS);
  var chart1 = ui.Chart.feature.byFeature(ee.FeatureCollection(chartRows), "year", seriesNames)
    .setChartType("ColumnChart")
    .setOptions({
      title: currentLabel + " -- cumulative gold mining vs. forest type, " +
             DISPLAY_YEARS[0] + "-" + DISPLAY_YEARS[DISPLAY_YEARS.length - 1] + " (km2)",
      isStacked: true, colors: seriesColors,
      hAxis: {title: "Year"}, vAxis: {title: "Area (km2)"}, legend: {position: "right"}
    });
  resultsPanel.add(chart1);

  // ---- chart 3: what did DISPLAY_YEARS' GROWTH in mining actually replace (one bar per class, each
  // bar colored to match its class on the map) -- classes with zero growth are filtered out rather
  // than rendered as empty bars. Per-bar color needs EE's generic ui.Chart(array, type, options)
  // constructor (ui.Chart.feature.byFeature's single-series ColumnChart can't color rows
  // individually) -- builds a plain Google-Charts-style 2D array directly from `stats` (already
  // client-side after .getInfo() above) with a {role: 'style'} column.
  // -------------------------------------------------------------------------------------------------
  var chart2Data = [["Class", "km2 newly mined", {role: "style"}]];
  CLASS_NAMES.forEach(function (name, i) {
    var km2 = stats["growth_class" + (i + 1)];
    if (km2 > 0) chart2Data.push([name, km2, "color: #" + CLASS_COLORS[i]]);
  });
  if (chart2Data.length === 1) {   // header row only -- nothing passed the km2 > 0 filter
    var noGrowthMsg = currentLabel + " -- no forest-type growth to show: no new mining in " +
      DISPLAY_YEARS[0] + "-" + DISPLAY_YEARS[DISPLAY_YEARS.length - 1] + ".";
    print(noGrowthMsg);
    resultsPanel.add(ui.Label(noGrowthMsg));
  } else {
    var chart2 = ui.Chart(chart2Data, "ColumnChart", {
      title: currentLabel + " -- composition of NEW mining area, " + DISPLAY_YEARS[0] + "-" +
             DISPLAY_YEARS[DISPLAY_YEARS.length - 1] + " (km2 of each forest type newly mined over)",
      legend: {position: "none"},
      hAxis: {title: null}, vAxis: {title: "km2 newly mined"}
    });
    resultsPanel.add(chart2);
  }
}

// ====================================================================================================
// STEP 7 -- "Generate GIF" button: animated cumulative-mining-vs-forest-type video for the CURRENT
// district, reusing
// the global forestClass/cumMineByYear (no recomputation) -- only the final .clip() + the title
// label are location-specific. Each frame is burned with "<year> -- <location>" (top-left) so the
// title survives even when the GIF is shared/downloaded standalone.
// ====================================================================================================
// Lazy-loaded (not a top-level require()) -- a third-party community module failing to resolve
// should break the "Generate GIF" buttons specifically, not the whole App's initial load (see
// 2026-11-03 blank-published-App investigation, header note near the top of this file).
var _textModule = null;
function getTextModule() {
  if (_textModule === null) _textModule = require("users/gena/packages:text");
  return _textModule;
}
var LABEL_SCALE = 30;
var LABEL_STYLE = {
  fontSize: 24, textColor: "ffffff", outlineColor: "000000", outlineWidth: 3,
  alignX: "left", alignY: "top"
};

function labelPointForGeom(geom) {
  // top-left corner of the geometry's own bounding box -- generalizes the old fixed-degree-offset
  // hack (which only worked for a point + known radius) to an arbitrary district polygon, entirely
  // server-side (no extra getInfo round trip).
  var ring = ee.List(geom.bounds().coordinates().get(0));
  return ee.Geometry.Point(ring.get(3));
}

function generateGif() {
  var hotspotAoi = currentGeom.bounds();
  var labelPoint = labelPointForGeom(currentGeom);
  var fortyVis = forestClass.visualize({min: 1, max: 6, palette: CLASS_COLORS});
  // Same red outline-only image used for the map's outlineLayer -- same every frame (district
  // doesn't change mid-GIF), so built once outside the per-year map rather than recomputed per frame.
  var outlineVis = outlineImageForGeom(currentGeom);
  var frames = ee.ImageCollection(DISPLAY_YEARS.map(function (yr) {
    var mineVis = cumMineByYear[yr].selfMask().visualize({palette: [MINING_COLOR]});
    var label = getTextModule().draw(yr + " -- " + currentLabel, labelPoint, LABEL_SCALE, LABEL_STYLE);
    return fortyVis.blend(mineVis).blend(outlineVis).blend(label).clip(hotspotAoi).set("year", yr);
  }));
  var gifParams = {region: hotspotAoi, dimensions: 500, framesPerSecond: 0.6, crs: "EPSG:3857"};

  resultsPanel.clear();
  resultsPanel.add(ui.Label(currentLabel + " -- generating GIF, please wait...", {fontWeight: "bold"}));

  print(currentLabel + " -- GIF frame order (0.6 frames/second): " + DISPLAY_YEARS.join(" -> ") +
        " -- gold/amber = cumulative mining footprint through that year, green/teal/brown/grey = " +
        "the 2020 ForTy forest-type basemap (static across all frames, only the mining overlay grows).");
  var url = frames.getVideoThumbURL(gifParams);   // single BLOCKING round trip
  print(currentLabel + " -- shareable link (opens the same animation in a browser tab):", url);

  resultsPanel.clear();
  resultsPanel.add(ui.Label(currentLabel, {fontWeight: "bold", fontSize: "14px"}));
  resultsPanel.add(ui.Thumbnail({image: frames, params: gifParams}));
  resultsPanel.add(ui.Label({value: "Open full-size / shareable link", targetUrl: url}));
  resultsPanel.add(ui.Label("Frame order: " + DISPLAY_YEARS.join(" -> "), {fontSize: "11px", color: "666666"}));
}

// ====================================================================================================
// STEP 7b -- "Generate satellite GIF" button: REAL imagery (STEP 3b) + the red district outline
// (re-added 2026-11-05, user request -- NOT the mining-extent outline, which stays off per the
// user's original 2026-11-03 revert of that combination). Plus the year/location label.
// Slower than STEP 7's GIF (real cloud-filtering + median compositing per year, vs. an instant
// selfMask/visualize) -- District mode only, same reasoning as the other GIF.
// ====================================================================================================
function satelliteFrameForYear(yr, geom, labelPoint, outlineVis) {
  var vis = imageryVis(yr, geom);
  var label = getTextModule().draw(yr + " -- " + currentLabel, labelPoint, LABEL_SCALE, LABEL_STYLE);
  return vis.blend(outlineVis).blend(label).set("year", yr);
}

function generateSatelliteGif() {
  var hotspotAoi = currentGeom.bounds();
  var labelPoint = labelPointForGeom(currentGeom);
  // Same red outline-only image used elsewhere (STEP 7's GIF, the main map's outlineLayer) -- built
  // once, not per frame, same reasoning as STEP 7.
  var outlineVis = outlineImageForGeom(currentGeom);
  // SATELLITE_YEARS (2015-2025), NOT EMBED_YEARS -- this GIF doesn't depend on the classifier or the
  // 2020-only ForTy baseline, so it isn't held back to 2017+/2020+ the way the other charts/GIF/slider
  // are; Landsat covers 2015-2017 fine (see SATELLITE_YEARS' own comment near EMBED_YEARS).
  var frames = ee.ImageCollection(SATELLITE_YEARS.map(function (yr) {
    return satelliteFrameForYear(yr, hotspotAoi, labelPoint, outlineVis);
  }));
  var gifParams = {region: hotspotAoi, dimensions: 500, framesPerSecond: 0.6, crs: "EPSG:3857"};

  resultsPanel.clear();
  resultsPanel.add(ui.Label(currentLabel + " -- generating satellite GIF, please wait (real imagery " +
    "compositing is slower than the forest-type GIF)...", {fontWeight: "bold"}));

  print(currentLabel + " -- satellite GIF frame order (0.6 frames/second): " + SATELLITE_YEARS.join(" -> ") +
        " -- Landsat true-colour through " + (SENTINEL2_START_YEAR - 1) + ", Sentinel-2 from " +
        SENTINEL2_START_YEAR + " on (2018 itself still sparse) -- imagery only, no overlay.");
  var satUrl = frames.getVideoThumbURL(gifParams);   // single BLOCKING round trip
  print(currentLabel + " -- shareable link (opens the same animation in a browser tab):", satUrl);

  resultsPanel.clear();
  resultsPanel.add(ui.Label(currentLabel + " (satellite imagery)", {fontWeight: "bold", fontSize: "14px"}));
  resultsPanel.add(ui.Thumbnail({image: frames, params: gifParams}));
  resultsPanel.add(ui.Label({value: "Open full-size / shareable link", targetUrl: satUrl}));
  resultsPanel.add(ui.Label("Frame order: " + SATELLITE_YEARS.join(" -> "), {fontSize: "11px", color: "666666"}));
}

// ====================================================================================================
// STEP 8 -- the app's one and only map (our own ui.Map instance, NOT the Code Editor's built-in
// global `Map`, which this script never uses). The left/right "swipe" year-comparison view that
// used to live in this slot (two linked ui.Map widgets in a ui.SplitPanel) was removed 2026-11-05,
// user call -- not needed. The control panel and resultsPanel are attached via mainMap.add()
// (STEP 9/10 below).
// ====================================================================================================
var mainMap = ui.Map();

// ====================================================================================================
// STEP 9 -- UI. Region -> District dropdowns top-right (Region just scopes the district list, see
// STEP 5), plus a year slider that swaps the main map's mining overlay in place (2020-2025,
// matching DISPLAY_YEARS/the ForTy baseline), a checkbox to toggle the forest-type layer (OFF by
// default, 2026-11-04 user call -- initial view shows only the gold mining layer). Results panel
// bottom-left, same as before (App-visible).
// ====================================================================================================
var regionSelect = ui.Select({
  items: REGION_NAMES, value: DEFAULT_REGION, onChange: onRegionChange, style: {width: "230px"}
});
var districtSelect = ui.Select({
  items: [], onChange: onDistrictChange, style: {width: "230px"}
});
var statusLabel = ui.Label("", {fontSize: "12px", color: "333333"});

// Full EMBED_YEARS (2017-2025), not DISPLAY_YEARS -- this slider only drives the gold MINING
// layer (cumMineByYear exists for the full classifier range), and the forest-type layer it used to
// be implicitly paired with is now opt-in (forestCheckbox) rather than always visible, so there's
// no reason to hold it back to the ForTy-snapshot years (2026-11-04, user call).
var yearSliderLabel = ui.Label("Scrub gold mining year: " + EMBED_YEARS[EMBED_YEARS.length - 1],
                                {fontSize: "12px"});
var yearSlider = ui.Slider({
  min: EMBED_YEARS[0], max: EMBED_YEARS[EMBED_YEARS.length - 1], step: 1,
  value: EMBED_YEARS[EMBED_YEARS.length - 1], style: {width: "230px"},
  onChange: function (yr) {
    yearSliderLabel.setValue("Scrub gold mining year: " + yr);
    miningLayer.setEeObject(cumMineByYear[yr].selfMask());
    miningLayer.setName("Cumulative gold mining extent (through " + yr + ")");
  }
});

// ON by default (miningLayer itself is added with its default shown=true in STEP 10) -- the gold
// mining layer IS the initial view; this just lets it be hidden too, same toggle mechanism as
// forestCheckbox below.
var miningCheckbox = ui.Checkbox({
  label: "Show gold mining", value: true,
  onChange: function (checked) { miningLayer.setShown(checked); }
});

// OFF by default (forestLayer itself is added with shown=false in STEP 10) -- initial view is just
// the gold mining layer; forest type is opt-in.
var forestCheckbox = ui.Checkbox({
  label: "Show forest type (2020 baseline)", value: false,
  onChange: function (checked) { forestLayer.setShown(checked); }
});

// OFF by default, same toggle mechanism -- protected-area outlines (WDPA/WDOECM, Designated only).
var protectedCheckbox = ui.Checkbox({
  label: "Show protected areas (WDPA/WDOECM)", value: false,
  onChange: function (checked) { protectedLayer.setShown(checked); }
});

var statsButton = ui.Button({label: "Generate stats", onClick: showStats});
var gifButton = ui.Button({
  label: "Generate Land Cover GIF (" + DISPLAY_YEARS[0] + "-" + DISPLAY_YEARS[DISPLAY_YEARS.length - 1] + ")",
  onClick: generateGif
});
var satelliteGifButton = ui.Button({
  label: "Generate Satellite GIF (" + SATELLITE_YEARS[0] + "-" + SATELLITE_YEARS[SATELLITE_YEARS.length - 1] + ")",
  onClick: generateSatelliteGif
});
// Reopens welcomePanel (data sources + how-to-use) -- shown automatically on first load, dismissed
// via its own "Got it" button; this is the only way back in afterwards.
var infoButton = ui.Button({
  label: "More info (data sources, how to use)",
  onClick: function () { welcomePanel.style().set("shown", true); }
});

// Click-to-select on the map -- a second way to pick a district, alongside the dropdowns above.
// The only genuinely new work is the point-in-polygon lookup (which district contains the click)
// -- region membership and the mining-data filter both reuse districtRows (STEP 4, already fetched
// client-side at startup), no second round trip needed. .evaluate() (async callback), NOT
// .getInfo() (blocking) -- a click handler shouldn't freeze the Code Editor UI while EE resolves
// the point-in-polygon query.
mainMap.onClick(function (coords) {
  statusLabel.setValue("Looking up district at (" + coords.lon.toFixed(4) + ", " + coords.lat.toFixed(4) + ")...");
  var pt = ee.Geometry.Point([coords.lon, coords.lat]);
  ADMIN2.filterBounds(pt).first().get(DISTRICT_FIELD).evaluate(function (districtName, err) {
    if (err || !districtName) {
      statusLabel.setValue("No district found there -- click inside Ghana.");
      return;
    }
    var row = districtRows.filter(function (r) { return r.district === districtName; })[0];
    if (!row || !isAllowedRegion(row.region) || row.mining_final <= MIN_MINING_KM2) {
      statusLabel.setValue(districtName + " has no significant mining data -- pick a highlighted district from the dropdown instead.");
      return;
    }
    regionSelect.setValue(row.region, true);
    districtSelect.setValue(districtName, true);
  });
});

mainMap.add(ui.Panel(
  [ui.Label("Region:", {fontWeight: "bold"}), regionSelect,
   ui.Label("Select district, or click location:", {fontWeight: "bold"}), districtSelect,
   statusLabel,
   yearSliderLabel, yearSlider,
   miningCheckbox, forestCheckbox, protectedCheckbox,
   statsButton, gifButton, satelliteGifButton, infoButton],
  ui.Panel.Layout.flow("vertical"),
  {position: "top-right", width: "250px"}
));

var resultsPanel = ui.Panel({
  style: {position: "bottom-left", width: "480px", maxHeight: "560px",
          backgroundColor: "rgba(255,255,255,0.92)", padding: "8px"}
});
mainMap.add(resultsPanel);

// ---- welcome box: centered, shown once on load, dismissed with "Got it" (user call, 2026-11-03:
// not tied to resultsPanel/first-click -- a real dismissible modal instead) -------------------------
// "middle-center" is not a valid ui.Map widget position (only top-left/top-center/top-right/
// bottom-left/bottom-center/bottom-right exist) -- top-center + a top margin is the closest
// approximation to "centered" the API actually allows.
var welcomePanel = ui.Panel({
  style: {position: "top-center", width: "420px", padding: "12px", margin: "60px 0 0 0",
          backgroundColor: "rgba(255,255,255,0.97)"}
});
welcomePanel.add(ui.Label("Galamsey vs. forest type explorer", {fontWeight: "bold", fontSize: "15px"}));
welcomePanel.add(ui.Label(
  "Tracks how much of Ghana's gold-mining expansion (2017-" + EMBED_YEARS[EMBED_YEARS.length - 1] +
  ") has come at the expense of forest, by district.", {fontSize: "12px"}
));

welcomePanel.add(ui.Label("Data sources", {fontWeight: "bold", fontSize: "12px", margin: "10px 0 2px 0"}));
welcomePanel.add(ui.Label(
  "- Mining extent: our own Random Forest classifier on Google's AlphaEarth embeddings " +
  "(mine_mask_ghana_c4_<year>, see build_03_embedding_panel.R), run annually " + EMBED_YEARS[0] +
  "-" + EMBED_YEARS[EMBED_YEARS.length - 1] + ". Shown as the UNION to date (only grows, never " +
  "shrinks), not each year's raw independent classification.", {fontSize: "11px"}
));
welcomePanel.add(ui.Label(
  "- Forest type: DeepMind/Google Research/WRI/IIASA's \"Forest Typology\" (ForTy) map -- a single " +
  DISPLAY_YEARS[0] + " snapshot (6 classes: Primary/Naturally Regenerating/Planted Forest, " +
  "Plantation, Tree Crops & Agroforestry, Other Land), not an annual series.", {fontSize: "11px"}
));
welcomePanel.add(ui.Label(
  "- Satellite GIF: real Sentinel-2 (" + SENTINEL2_START_YEAR + " on) / Landsat (before that) dry-" +
  "season true-colour composites, " + SATELLITE_YEARS[0] + "-" + SATELLITE_YEARS[SATELLITE_YEARS.length - 1] +
  ".", {fontSize: "11px"}
));
welcomePanel.add(ui.Label(
  "- Admin boundaries: Ghana regions/districts, restricted to the " + ALLOWED_REGIONS.length +
  " regions with real galamsey activity (" + ALLOWED_REGIONS.join(", ") + ").", {fontSize: "11px"}
));
welcomePanel.add(ui.Label(
  "- Protected areas: WDPA/WDOECM public catalog (UNEP-WCMC & IUCN), Designated status only -- " +
  "\"Proposed\" sites excluded, not yet legally protected. Mostly Forest Reserves.", {fontSize: "11px"}
));

welcomePanel.add(ui.Label("How to use", {fontWeight: "bold", fontSize: "12px", margin: "10px 0 2px 0"}));
welcomePanel.add(ui.Label(
  "1. Pick a Region (and District) above, or click any location on the map itself.", {fontSize: "11px"}
));
welcomePanel.add(ui.Label(
  "2. \"Generate stats\" for the mining trend, land-type breakdown, and growth-composition charts " +
  "(bottom-left panel), plus a one-line protected-area overlap stat (precomputed, not live -- see " +
  "DISTRICT_PROTECTED_STATS near the top of this file for its source).", {fontSize: "11px"}
));
welcomePanel.add(ui.Label(
  "3. \"Generate Land Cover GIF\" (forest-type palette) or \"Generate Satellite GIF\" (real " +
  "imagery + district outline) animate the selected district.", {fontSize: "11px"}
));
welcomePanel.add(ui.Label(
  "4. The year slider (above) scrubs the main map's gold mining overlay between " + EMBED_YEARS[0] +
  " and " + EMBED_YEARS[EMBED_YEARS.length - 1] + ". The map starts showing just the gold mining " +
  "layer -- use the \"Show gold mining\"/\"Show forest type\"/\"Show protected areas\" checkboxes " +
  "to toggle each layer (forest type is the ForTy basemap, a 2020 snapshot); see the legend " +
  "(top-left) for layer colours.", {fontSize: "11px"}
));
welcomePanel.add(ui.Button({
  label: "Got it",
  onClick: function () { welcomePanel.style().set("shown", false); },
  style: {margin: "10px 0 0 0"}
}));
mainMap.add(welcomePanel);   // still shown automatically on load, as before -- "More info" (STEP 9)
                              // just adds a way back in after "Got it" dismisses it, nothing about
                              // the first-load behavior changes.

// ====================================================================================================
// STEP 10 -- always-on map layers (forest-type basemap, static, + the year-slider-driven mining
// overlay) -- cheap, lazy-tiled, NOT clipped to any one location, so switching unit just recenters
// the map without needing to re-add layers. forestLayer starts OFF (shown=false, 2026-11-04 user
// call: initial view is just the gold mining layer) -- toggled via forestCheckbox (STEP 9).
// ====================================================================================================
mainMap.setOptions("SATELLITE");
var forestLayer = ui.Map.Layer(
  forestClass, {min: 1, max: 6, palette: CLASS_COLORS}, "ForTy forest type (Ghana, 2020 baseline)", false
);
mainMap.layers().add(forestLayer);
var miningLayer = ui.Map.Layer(
  cumMineByYear[EMBED_YEARS[EMBED_YEARS.length - 1]].selfMask(), {palette: [MINING_COLOR]},
  "Cumulative gold mining extent (through " + EMBED_YEARS[EMBED_YEARS.length - 1] + ")"
);
mainMap.layers().add(miningLayer);
// Outline only (not filled) -- an opaque fill would obscure the mining/forest layers underneath it.
// paint()'s width draws the boundary only; color here is a 1 (palette index), not a hex value.
var protectedOutline = ee.Image().byte().paint({featureCollection: PROTECTED_AREAS, color: 1, width: 2});
var protectedLayer = ui.Map.Layer(
  protectedOutline, {palette: ["00e676"]}, "Protected areas (WDPA/WDOECM, Designated)", false
);
mainMap.layers().add(protectedLayer);
// Placeholder (empty FeatureCollection) until the initial selection below sets the real outline --
// setSelection() always has a layer to call .setEeObject()/.setName() on, never needs to add/remove.
var outlineLayer = ui.Map.Layer(outlineImageForGeom(ee.Geometry.Point([0, 0])), {}, "Selected unit outline");
mainMap.layers().add(outlineLayer);

// ---- legend: what the layer colours mean (user call, 2026-11-03) ----------------------------------
function legendRow(color, label) {
  var colorBox = ui.Label("", {
    backgroundColor: color, padding: "8px", margin: "2px 6px 2px 0"
  });
  var description = ui.Label(label, {margin: "2px 0 2px 0", fontSize: "12px"});
  return ui.Panel([colorBox, description], ui.Panel.Layout.flow("horizontal"));
}
var legendPanel = ui.Panel({
  style: {position: "top-left", padding: "8px", backgroundColor: "rgba(255,255,255,0.92)"}
});
legendPanel.add(ui.Label("Legend", {fontWeight: "bold", margin: "2px 0 6px 0"}));
CLASS_NAMES.forEach(function (name, i) { legendPanel.add(legendRow("#" + CLASS_COLORS[i], name)); });
legendPanel.add(legendRow("#" + MINING_COLOR, "Cumulative mining extent"));
legendPanel.add(legendRow("#00e676", "Protected area boundary (WDPA/WDOECM)"));
legendPanel.add(legendRow("#ff0000", "Selected region/district outline"));
mainMap.add(legendPanel);

// ---- initial selection: District mode, Ashanti (DEFAULT_REGION) preset, Amansie West if it's
// present in the region's mining-district list (2026-11-04 user request), else fall back to
// onRegionChange's own default (first mining district alphabetically) ---------------------------------
var DEFAULT_DISTRICT = "Amansie West";
onRegionChange(DEFAULT_REGION);
if (districtNamesForRegion(DEFAULT_REGION).indexOf(DEFAULT_DISTRICT) > -1) {
  districtSelect.setValue(DEFAULT_DISTRICT, true);
} else {
  print("DEFAULT_DISTRICT '" + DEFAULT_DISTRICT + "' not found in " + DEFAULT_REGION +
        "'s mining-district list -- check DISTRICT_FIELD spelling on the ADMIN2 asset " +
        "(see the property printout near STEP 1). Falling back to the alphabetical default.");
}

// ---- install mainMap as the entire visible layout (our own ui.Map, not the Code Editor's built-in
// global `Map`, which this script never uses) --------------------------------------------------------
ui.root.clear();
ui.root.add(mainMap);

print("Tick 'Show forest type' to overlay the ForTy layer against the mining layer and see " +
      "spatially which forest types sit adjacent to / underneath the expanding mining footprint. " +
      "Use the year slider to scrub the gold mining overlay on this map between " + EMBED_YEARS[0] +
      " and " + EMBED_YEARS[EMBED_YEARS.length - 1] + ". Pick a Region (and District, restricted " +
      "to units with some mining), then 'Generate stats'.");

} catch (err) {
  // See the try{} note near STEP 1 -- renders whatever broke directly onto the page, since a
  // published App viewer has no console to see it in otherwise.
  print("APP FAILED TO LOAD:", err);
  ui.root.clear();
  ui.root.add(ui.Panel(
    [ui.Label("This app failed to load.", {fontWeight: "bold", fontSize: "16px", color: "b71c1c"}),
     ui.Label(String(err), {fontSize: "12px", color: "333333"})],
    ui.Panel.Layout.flow("vertical"),
    {margin: "40px", width: "500px"}
  ));
}
