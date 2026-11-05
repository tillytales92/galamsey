// explore_mining_vs_forest_type.js -- "for fun" exploratory script, not part of the core pipeline.
// Paste into code.earthengine.google.com (project: rgee-auth-tillam).
//
// Combines our own 2017-2025 gold-mining panel (mine_mask_ghana_c4_<yr>, see
// build_03_embedding_panel.R) with DeepMind/Google Research/WRI/IIASA's "Forest Typology" (ForTy)
// map (https://deepmind.google/blog/beyond-tree-cover-mapping-the-worlds-forest-types/) to show
// what forest TYPE cumulative mining expansion has actually replaced over time, in a user-chosen
// district. Map + two bar charts (a per-year stacked trend, and a single "what did the 2017-2025
// GROWTH in mining actually displace" breakdown) + a GIF.
//
// MULTI-DISTRICT UI (2026-11-02, user request, "along the lines of validate_change_gif.js"): a
// dropdown (top-right) picks among DISTRICTS below -- reuses 4 of validate_change_gif.js's known
// artisanal-mining-corridor sites (Amansie/Obuasi/Dunkwa-Offin/Prestea) plus this script's own
// original Nkotumso/Upper Denkyira West hotspot as the default. Two buttons trigger the heavy work
// on whichever district is CURRENTLY selected: "Generate GIF" (the animated cumulative-mining-vs-
// forest-type video, a blocking getVideoThumbURL call) and "Show forest-type breakdown" (the two
// bar charts + a plain console table, a blocking reduceRegion call). Switching the dropdown alone
// is cheap (just recenters the map) and does NOT trigger either. The forest-type basemap + current
// cumulative-mining-extent MAP LAYERS, unlike those two, are shown automatically on load -- they're
// lazy-tiled EE layers, not a blocking call, same reasoning validate_finalproduct.js uses for its
// always-on mask layer.
//
// NOTE (2026-11-02): a separate App-ready variant with click-to-pick-location + a results panel
// (for publishing via Code Editor -> Apps -> Publish) lives in
// explore_mining_vs_forest_type_app.js -- this file is the plain Code-Editor-script version,
// deliberately left as-is so it keeps working exactly as before.
//
// *** DATA SOURCE CAVEAT -- READ FIRST ***
// The ForTy asset ID/band names below were confirmed via EE Data Catalog documentation research,
// NOT by actually running this script (no EE execution access in this session). If GEE throws an
// "asset not found"/"band not found" error, that's the first thing to report back, same as every
// other script this session. Catalog page: https://developers.google.com/earth-engine/datasets/
// catalog/projects_nature-trace_assets_forest_typology_forest_typology_2020_v1_0_collection
//
// *** 2020-ONLY BASELINE, NOT AN ANNUAL SERIES ***
// The blog post mentions an annual 2017-2025 ForTy time series, but its EE asset ID could not be
// confirmed from available documentation -- this script uses ForTy's fixed 2020 baseline instead.
// "Forest type share declining over the years" in the stacked bar chart below means pixels of that
// 2020 baseline type cumulatively converting to mining over time -- NOT the forest-type map itself
// being independently re-estimated each year. If the real annual series does turn out to be
// accessible, swap FORTY_ASSET per year and this caveat goes away.
//
// *** CUMULATIVE mining, not the raw noisy per-year classification ***
// Uses the UNION of mine_mask_ghana_c4_{2017..Y} (monotonically non-decreasing) rather than each
// year's raw independent classification -- deliberately sidesteps the year-to-year volatility this
// whole session was about (see [[project_temporal_consistency_investigation]] in memory), since
// this script is about a multi-year replacement STORY, not about that open question.

var ASSET_HOME  = "projects/rgee-auth-tillam/assets/ghana_mining";
var EMBED_YEARS = [2017, 2018, 2019, 2020, 2021, 2022, 2023, 2024, 2025];
var FORTY_ASSET = "projects/nature-trace/assets/forest_typology/forest_typology_2020_v1_0_collection";
var HOTSPOT_HALFWIDTH_M = 10000;   // 20km x 20km focus box, for every district

// DISPLAY year range (2026-11-02, user request -- originally GIF-only, now also the table/charts
// for consistency): the ForTy forest-type basemap is a fixed 2020 snapshot, so showing 2017-2019
// against it implies the basemap was accurate for years it predates. EMBED_YEARS itself stays the
// FULL 2017-2025 classifier range on purpose -- cumMineByYear (STEP 3) must keep accumulating from
// 2017 so that e.g. cumMineByYear[2020] is the TRUE cumulative footprint through 2020, not just
// 2020's own mask; only the GIF/table/chart OUTPUTS are trimmed to DISPLAY_YEARS, not the
// underlying accumulation.
var DISPLAY_START_YEAR = 2020;
var DISPLAY_YEARS = EMBED_YEARS.filter(function (yr) { return yr >= DISPLAY_START_YEAR; });

// 2026-11-02 palette (user request): 3 greens for the forest-ORIGIN classes -- Primary dark, Planted
// pale, and Naturally Regenerating a vivid/bright green (not just "medium") so it reads clearly as
// its own distinct class rather than a muddy in-between step -- plus distinct non-green hues for
// the two classes that aren't really "forest" in the strict sense (Plantation = managed/
// commercial, teal; Tree Crops & Agroforestry = agriculture with tree cover, cocoa-brown), grey for
// Other Land (unchanged), and gold/amber for mining -- was red, now thematically apt (gold mining)
// and reads clearly against the green/brown backdrop.
var CLASS_NAMES  = ["Primary Forest", "Naturally Regenerating Forest", "Planted Forest",
                     "Plantation Forest", "Tree Crops & Agroforestry", "Other Land"];
var CLASS_COLORS = ["1b5e20", "00c853", "a5d6a7", "00897b", "795548", "bdbdbd"];
var MINING_COLOR = "ffc107";   // gold/amber

// ====================================================================================================
// STEP 1 -- district setup. Centers are known mining corridors, not auto-detected (simpler, avoids
// EE geometry-precision fiddling) -- nudge the coordinates if a map view looks off-target.
// ====================================================================================================
var DISTRICTS = {
  "Upper Denkyira West (Nkotumso)":       [-1.92,  6.00],
  "Amansie":                              [-1.943, 6.060],
  "Obuasi":                               [-1.666, 6.202],
  "Dunkwa / Offin (Upper Denkyira East)": [-1.780, 5.972],
  "Prestea (Prestea-Huni Valley)":        [-2.143, 5.433]
};
var DEFAULT_DISTRICT = "Upper Denkyira West (Nkotumso)";

// ---- "Southwest Ghana" scope (2026-11-02, user request) -- the "Show forest-type breakdown"
// button can run over the district's 20km box (default) OR this much larger region instead. Reuses
// the SAME SW-Ghana study-area geometry validate_finalproduct.js's `barenblittHull` / validate_
// product_overlap.R's `bar_hull` already use (Barenblitt 2019's own convex hull) -- NOT a new
// boundary invented for this script. NOT wired into "Generate GIF" -- a 500px frame over ~104,730
// km2 would be far too low-resolution to show forest-type nuance meaningfully, so the GIF stays
// district-only regardless of this selector.
var barenblittHull = ee.FeatureCollection(ASSET_HOME + "/gt_compare_barenblitt_raw").geometry().convexHull();

// ---- "Region" scope (2026-11-02, user request) -- same idea as Southwest Ghana above, but at
// Ghana's admin1 (region) level, to see which REGION has had the most cocoa/agroforestry (Tree
// Crops & Agroforestry) converted to mining. Uses FAO GAUL admin1 -- a PUBLIC EE asset, no upload
// needed, same reasoning as reusing barenblittHull above rather than inventing a new boundary.
// CAVEAT: GAUL/2015 reflects Ghana's PRE-2019 10-region structure, not the current 16 regions --
// the 2019 split carved Ahafo/Bono/Bono East/Oti/North East/Savannah out of the old Brong Ahafo/
// Volta/Northern. The names below are GAUL's own ADM1_NAME spelling, UNVERIFIED live (no EE
// execution access this session) -- if a region's filter comes back empty, check the exact
// spelling against a live listing of the asset first, don't assume the geometry itself is empty.
var GAUL_ADMIN1 = ee.FeatureCollection("FAO/GAUL/2015/level1").filter(ee.Filter.eq("ADM0_NAME", "Ghana"));
var REGIONS = ["Ashanti", "Western", "Central", "Eastern", "Brong Ahafo",
               "Greater Accra", "Volta", "Northern", "Upper East", "Upper West"];
var DEFAULT_REGION = "Ashanti";   // core of the gold/cocoa belt overlap
var currentRegion = DEFAULT_REGION;   // mutated by the region dropdown below
function regionGeometry(name) {
  return GAUL_ADMIN1.filter(ee.Filter.eq("ADM1_NAME", name)).geometry();
}

var SCOPES = {"District (20km box)": "district", "Region": "region", "Southwest Ghana (full belt)": "sw_ghana"};
var currentScope = "district";   // mutated by the scope dropdown below

// set by showForestBreakdown() whenever a non-district scope is used -- lets the batch-export
// block at the bottom of this script (STEP 8) reuse whichever region/scope was looked at last,
// instead of needing one separate copy-pasted export block per scope.
var lastBigRegionGeom = null, lastBigRegionLabel = null;

// ---- GIF title label (2026-11-02, user request) -- reuses the EXACT recipe already fixed and
// confirmed working in validate_change_gif.js this session: fontSize 24 is the only font-size
// asset `gena/packages:text` actually has (`users/gena/fonts/Arial24`; other sizes 404); LABEL_SCALE
// 30 was the confirmed-good render scale for a similarly-sized (~20-28km) box there. Top-left,
// same as that script's final (reverted-back-to) setting.
var text = require("users/gena/packages:text");
var LABEL_SCALE = 30;
var LABEL_STYLE = {
  fontSize: 24, textColor: "ffffff", outlineColor: "000000", outlineWidth: 3,
  alignX: "left", alignY: "top"
};
var LABEL_POINT_OFFSET_DEG = 0.11;   // ~inside the box's top-left corner; box half-side is ~0.127 deg

// mutable, set by applyDistrict() below -- every function further down reads these at CALL time.
var currentDistrict, AOI_CENTER, HOTSPOT_AOI, LABEL_POINT;

function applyDistrict(key) {
  currentDistrict = key;
  AOI_CENTER = ee.Geometry.Point(DISTRICTS[key]);
  HOTSPOT_AOI = AOI_CENTER.buffer(HOTSPOT_HALFWIDTH_M * Math.SQRT2).bounds();
  LABEL_POINT = ee.Geometry.Point([DISTRICTS[key][0] - LABEL_POINT_OFFSET_DEG,
                                    DISTRICTS[key][1] + LABEL_POINT_OFFSET_DEG]);
  Map.centerObject(HOTSPOT_AOI, 12);
}

// ====================================================================================================
// STEP 2 -- build the ForTy categorical forest-type map (argmax over 5 prob bands + derived "other")
// -- NATIONAL, built once, independent of district (only clipped/reduced per-district later on).
// ====================================================================================================
var forty = ee.ImageCollection(FORTY_ASSET).mosaic();
var fortyBands = ["PrimaryForest", "NaturallyRegeneratingForest", "PlantedForest",
                   "PlantationForest", "TreeCropsAndAgroforestry"];
var probSum = forty.select(fortyBands).reduce(ee.Reducer.sum());
var otherLand = ee.Image(250).subtract(probSum).rename("OtherLand");
var allClassProbs = forty.select(fortyBands).addBands(otherLand);

// class 1-6: PrimaryForest, NaturallyRegeneratingForest, PlantedForest, PlantationForest,
// TreeCropsAndAgroforestry, OtherLand (argmax + 1, per the catalog page's own recommended pattern)
var forestClass = allClassProbs.toArray().arrayArgmax().arrayGet([0]).add(1).rename("forest_class");

// ====================================================================================================
// STEP 3 -- cumulative mining mask per year -- NATIONAL, built once, independent of district (same
// reasoning as forestClass; only clipped/reduced per-district later, in the two button handlers).
// ====================================================================================================
var cumMineByYear = {};
var runningMine = ee.Image(0).rename("cum_mine");
EMBED_YEARS.forEach(function (yr) {
  var mineYr = ee.Image(ASSET_HOME + "/mine_mask_ghana_c4_" + yr).unmask(0);
  runningMine = runningMine.or(mineYr).rename("cum_mine_" + yr);
  cumMineByYear[yr] = runningMine;
});

// ====================================================================================================
// STEP 4 -- "Show forest-type breakdown" button: reduceRegion (DISPLAY_YEARS.length years x 6
// classes + mining, plus 6 "growth composition" bands) over the DISTRICT's 20km box (native
// scale=10, cheap) OR a much bigger REGION or the SOUTHWEST GHANA belt instead (scale=100 for
// either -- a whole admin1 region or the ~104,730 km2 belt at native 10m would risk an interactive
// timeout, same reasoning every other national-scale script in this project uses; trades precision
// for feasibility -- see the batch-export alternative in STEP 8). Feeds a console table + two bar
// charts. Uses DISPLAY_YEARS (2020-2025), not the full EMBED_YEARS -- matches the GIF's own 2020
// start, for the same reason (ForTy's forest-type basemap is a fixed 2020 snapshot).
// ====================================================================================================
var areaKm2 = ee.Image.pixelArea().divide(1e6);

function showForestBreakdown() {
  var region, scale, label;
  if (currentScope === "sw_ghana") {
    region = barenblittHull; scale = 100; label = "Southwest Ghana (full belt)";
  } else if (currentScope === "region") {
    region = regionGeometry(currentRegion); scale = 100; label = currentRegion + " region";
  } else {
    region = HOTSPOT_AOI; scale = 10; label = currentDistrict;
  }
  var isNationalScale = currentScope !== "district";   // "region" and "sw_ghana" share the same caveats below

  var bandsOut = [];
  DISPLAY_YEARS.forEach(function (yr) {
    bandsOut.push(cumMineByYear[yr].multiply(areaKm2).rename("mining_" + yr));
    for (var c = 1; c <= 6; c++) {
      var classMask = forestClass.eq(c).and(cumMineByYear[yr].not());
      bandsOut.push(classMask.multiply(areaKm2).rename("class" + c + "_" + yr));
    }
  });
  // "growth composition" bands: of the forest that existed in the 2020 ForTy baseline, how much of
  // EACH class got newly absorbed into mining specifically during DISPLAY_YEARS (not already mined
  // at DISPLAY_YEARS[0] = 2020) -- isolates GROWTH, same framing as the original manual finding
  // this script generalizes (76.9% of 2020-2025 growth traced to forest in the Nkotumso hotspot:
  // cocoa/agroforestry -34, naturally regenerating -20, primary forest -6 km2; only 23.1% from
  // already-non-forest "Other Land"). Baseline is now 2020, matching that original finding's own
  // window exactly (this used to be anchored at 2017, before the table's range was trimmed to match
  // the GIF -- see DISPLAY_START_YEAR above).
  var newlyMined = cumMineByYear[DISPLAY_YEARS[DISPLAY_YEARS.length - 1]].and(cumMineByYear[DISPLAY_YEARS[0]].not());
  for (var c = 1; c <= 6; c++) {
    bandsOut.push(forestClass.eq(c).and(newlyMined).multiply(areaKm2).rename("growth_class" + c));
  }
  var combinedImg = ee.Image.cat(bandsOut);

  print(label + " -- computing mining + 6-class forest-type area for " + DISPLAY_YEARS.length +
        " years (" + DISPLAY_YEARS[0] + "-" + DISPLAY_YEARS[DISPLAY_YEARS.length - 1] + "), plus " +
        "the growth-composition breakdown, in ONE reduceRegion call, scale=" + scale +
        (isNationalScale ? " (" + label + " -- this one's bigger, give it a moment)" :
                            " (20km box)") + ".");
  if (isNationalScale) {
    lastBigRegionGeom = region;
    lastBigRegionLabel = label;
    print("CAVEAT: scale=100 is an APPROXIMATION, not a precise area -- two different, known " +
          "biases apply. (1) The mining bands come from mine_mask_ghana_c4_<yr>, exported with " +
          "pyramidingPolicy='mode' -- reading a mode-pyramided mask at 100m instead of its native " +
          "~10m is DOCUMENTED to read ~3-8% HIGH in this exact project (see validate_finalproduct." +
          "js's own 'Final product km2' caveat; root cause archived 2026-11-03 as " +
          "notes/archive/validate_scale_mismatch.js once its one question was answered). (2) The " +
          "forest-class bands come from forestClass, computed on the fly with no pyramid to pull " +
          "from -- at 100m this falls back to nearest-neighbor resampling (one point-sample per " +
          "100m cell, not a true area integral), which adds NOISE to the class composition rather " +
          "than a clean directional bias. For a number you'd actually cite, run the batch export " +
          "block at the bottom of this script instead (native scale, no interactive timeout risk).");
  }
  var stats = combinedImg.reduceRegion({
    reducer: ee.Reducer.sum(), geometry: region, scale: scale, maxPixels: 1e10, tileScale: 8
  }).getInfo();   // single BLOCKING round trip

  // ---- plain console table (the "table" half of "table with bar charts") -----------------------
  print(label + " -- cumulative mining + forest-type area by year (km2):");
  DISPLAY_YEARS.forEach(function (yr) {
    var row = "  " + yr + "  mining=" + stats["mining_" + yr].toFixed(1);
    for (var c = 1; c <= 6; c++) {
      row += "  " + CLASS_NAMES[c - 1] + "=" + stats["class" + c + "_" + yr].toFixed(1);
    }
    print(row);
  });

  // ---- bar chart 1: per-year stacked trend (mining + remaining forest classes) -------------------
  var chartRows = DISPLAY_YEARS.map(function (yr) {
    var props = {year: yr, "Gold Mining": stats["mining_" + yr]};
    for (var c = 1; c <= 6; c++) props[CLASS_NAMES[c - 1]] = stats["class" + c + "_" + yr];
    return ee.Feature(null, props);
  });
  var seriesNames = ["Gold Mining"].concat(CLASS_NAMES);
  var seriesColors = [MINING_COLOR].concat(CLASS_COLORS);
  print(ui.Chart.feature.byFeature(ee.FeatureCollection(chartRows), "year", seriesNames)
    .setChartType("ColumnChart")
    .setOptions({
      title: label + " -- cumulative gold mining vs. forest type, " +
             DISPLAY_YEARS[0] + "-" + DISPLAY_YEARS[DISPLAY_YEARS.length - 1] + " (km2)",
      isStacked: true, colors: seriesColors,
      hAxis: {title: "Year"}, vAxis: {title: "Area (km2)"}, legend: {position: "right"}
    }));

  // ---- bar chart 2: what did DISPLAY_YEARS' GROWTH in mining actually replace (one bar per class,
  // each bar colored to match its class on the map, not a single flat color) ----------------------
  // FIX 1 (2026-11-02, user reported a meaningless "0" on the x-axis): the previous version packed
  // all 6 classes as PROPERTIES of a single feature and called byFeature with xProperty=null --
  // with only one row and no real x-axis value to read, EE/Google Charts fell back to the row's
  // numeric index ("0") as the only tick. Rebuilt as ONE ROW PER CLASS instead, with the class
  // NAME as the x-axis category -- this is also what makes "only show bars with data" possible:
  // filtered out here, before the chart ever sees them, rather than rendered as empty/zero bars.
  // FIX 2 (2026-11-02, user asked for per-class colors matching the map, not one flat gold color):
  // ui.Chart.feature.byFeature's single-series ColumnChart can only take ONE color for the whole
  // series -- it has no per-row styling hook through that wrapper. Switched to EE's generic
  // ui.Chart(array, type, options) constructor instead, building a plain Google-Charts-style 2D
  // array directly from `stats` (already a client-side object after .getInfo() above, so no
  // ee.Feature/ee.FeatureCollection needed at all here) with a {role: 'style'} column -- the
  // standard Google Charts technique for coloring individual bars in a single-series chart.
  // -------------------------------------------------------------------------------------------------
  var chart2Data = [["Class", "km2 newly mined", {role: "style"}]];
  CLASS_NAMES.forEach(function (name, i) {
    var km2 = stats["growth_class" + (i + 1)];
    if (km2 > 0) chart2Data.push([name, km2, "color: #" + CLASS_COLORS[i]]);
  });
  if (chart2Data.length === 1) {   // header row only -- nothing passed the km2 > 0 filter
    print(label + " -- no forest-type growth to show: no new mining in " + DISPLAY_YEARS[0] +
          "-" + DISPLAY_YEARS[DISPLAY_YEARS.length - 1] + ".");
  } else {
    print(ui.Chart(chart2Data, "ColumnChart", {
      title: label + " -- composition of NEW mining area, " + DISPLAY_YEARS[0] + "-" +
             DISPLAY_YEARS[DISPLAY_YEARS.length - 1] + " (km2 of each forest type newly mined over)",
      legend: {position: "none"},
      hAxis: {title: null}, vAxis: {title: "km2 newly mined"}
    }));
  }
}

// ====================================================================================================
// STEP 5 -- "Generate GIF" button: animated cumulative-mining-vs-forest-type video for the CURRENT
// district, reusing the global forestClass/cumMineByYear (no recomputation) -- only the final
// .clip(HOTSPOT_AOI) + the title label are district-specific. Each frame is burned with "<year> --
// <district>" (top-left) so the title survives even when the GIF is shared/downloaded standalone,
// outside the Code Editor console's own frame-order printout below.
// ====================================================================================================
function generateGif() {
  var fortyVis = forestClass.visualize({min: 1, max: 6, palette: CLASS_COLORS});
  var frames = ee.ImageCollection(DISPLAY_YEARS.map(function (yr) {
    var mineVis = cumMineByYear[yr].selfMask().visualize({palette: [MINING_COLOR]});
    var label = text.draw(yr + " -- " + currentDistrict, LABEL_POINT, LABEL_SCALE, LABEL_STYLE);
    return fortyVis.blend(mineVis).blend(label).clip(HOTSPOT_AOI).set("year", yr);
  }));
  var gifParams = {region: HOTSPOT_AOI, dimensions: 500, framesPerSecond: 0.6, crs: "EPSG:3857"};   // was 1, slowed per user request

  print(currentDistrict + " -- GIF frame order (0.6 frames/second): " + DISPLAY_YEARS.join(" -> ") +
        " -- red = cumulative mining footprint through that year, green/yellow/orange/grey = the " +
        "2020 ForTy forest-type basemap (static across all frames, only the red overlay grows).");
  print(ui.Thumbnail({image: frames, params: gifParams}));
  print(currentDistrict + " -- shareable link (opens the same animation in a browser tab):",
        frames.getVideoThumbURL(gifParams));
}

// ====================================================================================================
// STEP 6 -- always-on map layers (forest-type basemap + current cumulative mining extent) -- cheap,
// lazy-tiled, NOT clipped to any one district, so switching the dropdown (which only recenters the
// map) naturally shows whichever district is now in view without needing to re-add layers.
// ====================================================================================================
Map.setOptions("SATELLITE");
Map.addLayer(forestClass, {min: 1, max: 6, palette: CLASS_COLORS}, "ForTy forest type (2020 baseline)", true);
Map.addLayer(cumMineByYear[EMBED_YEARS[EMBED_YEARS.length - 1]].selfMask(),
  {palette: [MINING_COLOR]}, "Cumulative mining extent (through " + EMBED_YEARS[EMBED_YEARS.length - 1] + ")", true);

// ====================================================================================================
// STEP 7 -- UI: district dropdown + scope dropdown + region dropdown + the two action buttons
// (top-right). The scope/region dropdowns only affect "Show forest-type breakdown" (see STEP 4) --
// "Generate GIF" always uses the district box regardless of scope, per the caveat in STEP 4's
// header comment (a region or the whole SW Ghana belt is far too big to animate meaningfully at
// 500px). The region dropdown itself is only read when scope = "Region".
// ====================================================================================================
applyDistrict(DEFAULT_DISTRICT);   // centers the map on load

var districtSelect = ui.Select({
  items: Object.keys(DISTRICTS),
  value: DEFAULT_DISTRICT,
  onChange: applyDistrict,
  style: {width: "230px"}
});
var scopeSelect = ui.Select({
  items: Object.keys(SCOPES),
  value: "District (20km box)",
  onChange: function (key) { currentScope = SCOPES[key]; },
  style: {width: "230px"}
});
var regionSelect = ui.Select({
  items: REGIONS,
  value: DEFAULT_REGION,
  onChange: function (key) { currentRegion = key; },
  style: {width: "230px"}
});
Map.add(ui.Panel(
  [ui.Label("District (used by both buttons):", {fontWeight: "bold"}), districtSelect,
   ui.Label("Breakdown scope (table/charts only):", {fontWeight: "bold"}), scopeSelect,
   ui.Label("Region (used when scope = Region):", {fontWeight: "bold"}), regionSelect,
   ui.Button({label: "Generate GIF", onClick: generateGif}),
   ui.Button({label: "Show forest-type breakdown", onClick: showForestBreakdown})],
  ui.Panel.Layout.flow("vertical"),
  {position: "top-right", width: "250px"}
));

print("Toggle the forest-type layer against the red cumulative-mining overlay on the map to see " +
      "spatially which forest types sit adjacent to / underneath the expanding mining footprint. " +
      "Pick a district above, then click a button -- neither runs automatically on load.");

// ====================================================================================================
// STEP 8 -- precise numbers for a REGION or the Southwest Ghana belt, as a BATCH export instead of
// the interactive scale=100 approximation in STEP 4. Reuses lastBigRegionGeom/lastBigRegionLabel,
// set automatically the last time "Show forest-type breakdown" ran with scope != "District" -- so
// run that first (region or SW Ghana, whichever you want precise numbers for), THEN this block.
// Native scale=10, no interactive timeout risk, no scale-induced bias -- but it's a background GEE
// Task, not instant: run this block, then check the Tasks tab, then download the CSV from Drive
// once COMPLETED. Uncomment to run (kept off by default so pasting/running the rest of the script
// doesn't accidentally submit a GEE task every time).
// ====================================================================================================
// if (lastBigRegionGeom === null) {
//   print("Run 'Show forest-type breakdown' with scope = Region or Southwest Ghana first -- " +
//         "nothing to export yet.");
// } else {
//   var bigBandsOut = [];
//   DISPLAY_YEARS.forEach(function (yr) {
//     bigBandsOut.push(cumMineByYear[yr].multiply(areaKm2).rename("mining_" + yr));
//     for (var c = 1; c <= 6; c++) {
//       bigBandsOut.push(forestClass.eq(c).and(cumMineByYear[yr].not()).multiply(areaKm2).rename("class" + c + "_" + yr));
//     }
//   });
//   var bigNewlyMined = cumMineByYear[DISPLAY_YEARS[DISPLAY_YEARS.length - 1]].and(cumMineByYear[DISPLAY_YEARS[0]].not());
//   for (var c2 = 1; c2 <= 6; c2++) {
//     bigBandsOut.push(forestClass.eq(c2).and(bigNewlyMined).multiply(areaKm2).rename("growth_class" + c2));
//   }
//   var bigCombinedImg = ee.Image.cat(bigBandsOut);
//   var bigStats = bigCombinedImg.reduceRegion({
//     reducer: ee.Reducer.sum(), geometry: lastBigRegionGeom, scale: 10, maxPixels: 1e13, tileScale: 8
//   });
//   Export.table.toDrive({
//     collection: ee.FeatureCollection([ee.Feature(null, bigStats)]),
//     description: "mining_vs_forest_type_" + lastBigRegionLabel.replace(/[^a-zA-Z0-9]/g, "_"),
//     folder: "ghana_mining_gee_exports",
//     fileFormat: "CSV"
//   });
//   print("Submitted for " + lastBigRegionLabel + " -- check the Tasks tab. Once COMPLETED, the " +
//         "CSV lands in Drive under ghana_mining_gee_exports/.");
// }
