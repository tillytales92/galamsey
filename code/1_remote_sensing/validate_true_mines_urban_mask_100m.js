
// validate_true_mines_urban_mask_100m.js
// Paste into code.earthengine.google.com (project: rgee-auth-tillam). Re-runs
// validate_true_mines_urban_mask.js's check -- "how many SmallMinesDS-2022 true-mine validation
// points sit on GHSL-flagged urban land" -- but with the epoch-matched 100m GHSL product
// (JRC/GHSL/P2023A/GHS_BUILT_S) instead of the static single-epoch 10m product
// (JRC/GHSL/P2023A/GHS_BUILT_S_10m, frozen at 2018). 2026-08-18 conversation: the static 2018 mask
// under-covers post-2018 growth and over-covers pre-2018 land use for a 1995-2025 panel; this
// swaps in the correctly-dated epoch at the cost of 10m -> 100m spatial precision.
//
// validate_ghsl_100m_epochs.js (run earlier this session) confirmed: 12 epochs, 5-year steps,
// 1975-01-01 through 2030-01-01. 2030 is very likely a modelled/projected epoch, not an
// observation (GHSL's standard R2023A pattern) -- EXCLUDED from nearest-epoch matching here;
// treat any year that would nearest-match 2030 with suspicion and prefer 2025 instead. Also
// confirmed built_surface units scale with pixel area (m^2 built per pixel, ~9659/10000 max at
// 100m vs ~100/100 max at 10m) -- so URBAN_THRESHOLD must be RESCALED, not reused as-is: the 10m
// product used 20 (out of a 100 max, i.e. 20% built), so the equivalent 100m threshold for the
// same 20% definition is 2000 (out of a 10000 max).
//
// Reads rs05_val_pts_2022 directly (no new assets to upload) -- same asset used throughout
// build_02/trial_multiclass/trial_4class. All points are vintage 2022, so this script resolves a
// single nearest epoch (2020) for all of them; nearestEpochDate() is written to take an arbitrary
// year so it can be copied into a multi-vintage context (e.g. build_02's mixed-source training
// points, or build_03's per-year panel classification) without modification.

var ASSET_HOME = "projects/rgee-auth-tillam/assets/ghana_mining";
var URBAN_THRESHOLD_100M = 2000;  // rescaled from the 10m product's 20-out-of-100 (20% built-up)

// -- Nearest-epoch matching (client-side; epochs are a small fixed list, no need for a server call) --
var GHSL_100M_EPOCHS = [1975, 1980, 1985, 1990, 1995, 2000, 2005, 2010, 2015, 2020, 2025];  // 2030 excluded, likely projected
function nearestEpochYear(year) {
  var best = GHSL_100M_EPOCHS[0];
  var bestDiff = Math.abs(year - best);
  GHSL_100M_EPOCHS.forEach(function (e) {
    var diff = Math.abs(year - e);
    if (diff < bestDiff) { best = e; bestDiff = diff; }
  });
  return best;
}
function builtSurfaceForYear(year) {
  var epoch = nearestEpochYear(year);
  print("Requested year " + year + " -> nearest real GHSL 100m epoch: " + epoch);
  return ee.ImageCollection("JRC/GHSL/P2023A/GHS_BUILT_S")
    .filterDate(epoch + "-01-01", (epoch + 1) + "-01-01")
    .first()
    .select("built_surface");
}

// -- Apply to the 2022 validation points (nearest epoch resolves to 2020) --
var VAL_YEAR = 2022;
var ghslBuilt100m = builtSurfaceForYear(VAL_YEAR);

var valPts    = ee.FeatureCollection(ASSET_HOME + "/rs05_val_pts_2022");
var trueMines = valPts.filter(ee.Filter.eq("label", 1));

var trueMinesTagged = ghslBuilt100m.reduceRegions({
  collection: trueMines,
  reducer: ee.Reducer.first(),
  scale: 100
}).map(function (f) {
  var built = ee.Number(f.get("first"));
  return f.set("built_surface_100m", built)
          .set("on_urban_mask_100m", built.gt(URBAN_THRESHOLD_100M));
});

var onMask  = trueMinesTagged.filter(ee.Filter.eq("on_urban_mask_100m", 1));
var offMask = trueMinesTagged.filter(ee.Filter.eq("on_urban_mask_100m", 0));

print("=== True mines vs. epoch-matched 100m GHSL urban mask (2020 epoch, threshold " + URBAN_THRESHOLD_100M + ") ===");
print("True mines total:", trueMinesTagged.size());
print("True mines ON 100m urban mask:", onMask.size());
print("  -- inspect Features for per-point built_surface_100m value:", onMask);
print("True mines OFF 100m urban mask:", offMask.size());
print("Compare against the 10m/2018 static-mask result (17 points ON mask, from validate_true_mines_urban_mask.js) --");
print("a smaller ON-mask count here would mean the epoch-matched 100m mask strips FEWER real mines than the stale 2018 10m mask did.");

// -- Visual QA, same red/green convention as the 10m version --
function maskS2(img) {
  var scl = img.select("SCL");
  return img.updateMask(scl.neq(3).and(scl.neq(9))).divide(10000);
}
var s2_2022 = ee.ImageCollection("COPERNICUS/S2_SR_HARMONIZED")
  .filterBounds(trueMines.geometry().bounds())
  .filterDate("2022-01-01", "2022-12-31")
  .filter(ee.Filter.lt("CLOUDY_PIXEL_PERCENTAGE", 40))
  .map(maskS2)
  .median()
  .select(["B4", "B3", "B2"]);

Map.centerObject(trueMines, 7);
Map.addLayer(s2_2022, {min: 0, max: 0.3}, "Sentinel-2 2022 (true colour)", true);
Map.addLayer(ghslBuilt100m.gt(URBAN_THRESHOLD_100M).selfMask(),
             {palette: ["808080"]}, "GHSL 100m urban mask, 2020 epoch (built_surface > " + URBAN_THRESHOLD_100M + ")", true, 0.5);
Map.addLayer(offMask.style({color: "00FF00", pointSize: 5}), {}, "True mines OFF 100m urban mask", true);
Map.addLayer(onMask.style({color: "FF0000", pointSize: 6}), {}, "True mines ON 100m urban mask", true);

// Click red points in the Inspector to compare against the 10m version's onMask set -- same
// points staying red would say the confusion is genuine (settlement/camp overlap real mine
// infrastructure regardless of resolution); points flipping from red(10m) to green(100m) would be
// cases where the coarser 100m pixel averaged away a small isolated urban signal the 10m product
// caught, which cuts the other way (100m under-detecting small settlements near real mines).
