
// validate_min_patch_size_filter.js
// Paste into code.earthengine.google.com (project: rgee-auth-tillam). Tests the CHEAP post-hoc
// spatial-filtering option discussed 2026-08-18 (before investing in contextual RF input features):
// does removing small, spatially-isolated connected patches from the classified "mine" mask clean
// up the remaining false positives without a retrain? Targets the residual noise left over after
// cutoff + GHSL masking -- e.g. the ~4.6% of Kumasi still flagged at cutoff 25 + 100m mask, and the
// ~0.79% still flagged at cutoff 45 + 100m mask -- to see how much of that is scattered singleton/
// small-cluster noise (which this WOULD catch) vs. coherent multi-pixel patches that just happen to
// be the wrong land cover (which this WON'T catch -- that's the case contextual features would be
// for, if this doesn't close the gap).
//
// Uses connectedPixelCount() (patch size in PIXELS at 10m, capped at a generous maxSize so large
// real mine patches are never mistakenly treated as "small") rather than full connectedComponents()
// labelling -- cheaper, and all this needs is a size threshold, not per-patch IDs.
//
// Self-contained: retrains fresh from the persisted mc4_train_pts_tagged asset, same pattern as
// validate_low_cutoff_mask_comparison.js. Tests TWO base configurations side by side: cutoff 45
// (higher recall, more residual noise to clean up -- the OLD settled cutoff, now the noisier
// reference point) and cutoff 70 (build_03's current settled cutoff, decided 2026-09-09) -- both +
// the 100m epoch-matched mask at the new URBAN_THRESHOLD_100M (500, was 2000), since that
// combination is already decided.
//
// UPDATED 2026-09-14: cutoffs + urban threshold bumped from {25, 45} / 2000 to {45, 70} / 500 to
// match build_03's settled config. First run (old config, Kumasi) found a flat curve -- no
// singleton-noise knee at either cutoff, ~18-21% reduction only by 50px (0.5ha) -- meaning residual
// FP is coherent multi-pixel patches, not scattered noise. See
// notes/2026-09-07_build03_fp_postprocessing_plan.md "UPDATE 2026-09-14" for the full result table
// and interpretation. This re-run checks whether that conclusion still holds now that most
// urban/water FP is already gone upstream at cutoff 70.

var ASSET_HOME = "projects/rgee-auth-tillam/assets/ghana_mining";
var N_TREES = 200;
var EXPORT_SCALE = 10;

var CITY = "kumasi";  // "kumasi" | "accra"
var CITY_CENTERS = { kumasi: [-1.6244, 6.6885], accra: [-0.1870, 5.6037] };
var AOI_CENTER = ee.Geometry.Point(CITY_CENTERS[CITY]);
var AOI_HALFWIDTH_M = 20000;
var aoi = AOI_CENTER.buffer(AOI_HALFWIDTH_M).bounds();

var URBAN_THRESHOLD_100M = 500;   // build_03's settled value (was 2000)
var CLASSIFICATION_YEAR = 2022;
var GHSL_100M_EPOCHS = [1975, 1980, 1985, 1990, 1995, 2000, 2005, 2010, 2015, 2020, 2025];
function nearestEpochYear(year) {
  var best = GHSL_100M_EPOCHS[0], bestDiff = Math.abs(year - best);
  GHSL_100M_EPOCHS.forEach(function (e) {
    var diff = Math.abs(year - e);
    if (diff < bestDiff) { best = e; bestDiff = diff; }
  });
  return best;
}
var epoch100m = nearestEpochYear(CLASSIFICATION_YEAR);

// -- 1. Retrain, classify, mask (identical setup to validate_low_cutoff_mask_comparison.js) --
var trainPts = ee.FeatureCollection(ASSET_HOME + "/mc4_train_pts_tagged");
var bandNames = ee.ImageCollection("GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL").first().bandNames();
var classifier = ee.Classifier.smileRandomForest(N_TREES)
  .train({features: trainPts, classProperty: "cls4", inputProperties: bandNames})
  .setOutputMode("MULTIPROBABILITY");

var embedding = ee.ImageCollection("GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL")
  .filterBounds(aoi)
  .filterDate(CLASSIFICATION_YEAR + "-01-01", (CLASSIFICATION_YEAR + 1) + "-01-01")
  .mosaic();
var mineProb = embedding.classify(classifier).arrayGet(1).multiply(100).rename("mine_prob").clip(aoi);

var ghslBuilt100m = ee.ImageCollection("JRC/GHSL/P2023A/GHS_BUILT_S")
  .filterDate(epoch100m + "-01-01", (epoch100m + 1) + "-01-01").first().select("built_surface").clip(aoi);

// -- 2. Min-patch-size filter: connectedPixelCount() on the binary mask, threshold in PIXELS --
var MAX_PATCH_SCAN = 64;    // only needs to exceed the largest MIN_PATCH_SIZES value (50) -- 1024 was
                             // needlessly expensive (connectedPixelCount cost scales with this) and
                             // triggered "User memory limit exceeded" in the interactive Code Editor
var MIN_PATCH_SIZES = [0, 2, 3, 5, 10, 20, 50];  // 0 = no filter (baseline); pixel counts at 10m
                                                  // (1 px=100m^2, so e.g. 5 px=0.05ha, 50 px=0.5ha)

var pixelAreaKm2 = ee.Image.pixelArea().divide(1e6);
function areaFlagged(mask) {
  return pixelAreaKm2.updateMask(mask).reduceRegion({
    reducer: ee.Reducer.sum(), geometry: aoi, scale: EXPORT_SCALE, maxPixels: 1e10, tileScale: 4
  }).get("area");
}

function runConfig(cutoff, label) {
  var binary = mineProb.gte(cutoff).and(ghslBuilt100m.lte(URBAN_THRESHOLD_100M));
  var patchSizePx = binary.selfMask().connectedPixelCount({maxSize: MAX_PATCH_SCAN, eightConnected: true});
  print("=== " + label + " (cutoff " + cutoff + " + 100m mask) ===");
  MIN_PATCH_SIZES.forEach(function (minPx) {
    var filtered = minPx === 0 ? binary.selfMask() : binary.selfMask().updateMask(patchSizePx.gte(minPx));
    print("  min patch size " + minPx + " px (" + (minPx * 100) + " m^2), area flagged (km^2):",
          areaFlagged(filtered));
  });
}

runConfig(45, "Cutoff 45");
runConfig(70, "Cutoff 70");

// -- 3. Visual QA: cutoff 45 + mask, before/after a mid-range patch filter (10 px = 0.1 ha) --
// Uses cutoff 45 (not 70) for the visual layer since it's the noisier of the two configs -- more
// residual patches to actually see the before/after on.
function maskS2(img) {
  var scl = img.select("SCL");
  return img.updateMask(scl.neq(3).and(scl.neq(9))).divide(10000);
}
var s2 = ee.ImageCollection("COPERNICUS/S2_SR_HARMONIZED")
  .filterBounds(aoi).filterDate(CLASSIFICATION_YEAR + "-01-01", CLASSIFICATION_YEAR + "-12-31")
  .filter(ee.Filter.lt("CLOUDY_PIXEL_PERCENTAGE", 40)).map(maskS2).median()
  .select(["B4", "B3", "B2"]).clip(aoi);

var binary45 = mineProb.gte(45).and(ghslBuilt100m.lte(URBAN_THRESHOLD_100M));
var patchSizePx45 = binary45.selfMask().connectedPixelCount({maxSize: MAX_PATCH_SCAN, eightConnected: true});
var filtered45_10px = binary45.selfMask().updateMask(patchSizePx45.gte(10));

Map.centerObject(aoi, 11);
Map.addLayer(s2, {min: 0, max: 0.3}, "Sentinel-2 " + CLASSIFICATION_YEAR + " (true colour)", true);
Map.addLayer(binary45.selfMask(), {palette: ["ff0000"]}, "cutoff 45 + mask, UNFILTERED", true);
Map.addLayer(filtered45_10px, {palette: ["00c3ff"]}, "cutoff 45 + mask, min-patch 10px (0.1ha)", true);

print("Compare the min-patch-size=0 row (baseline) against larger thresholds: a big drop between");
print("0 and ~5-10px means most residual noise IS scattered singleton/small-cluster false positives");
print("(the filter is doing real work); a flat curve means the residual false positives are already");
print("coherent multi-pixel patches this filter can't touch -- that's the signal to try contextual");
print("RF input features instead.");
