// validate_trainingdata.js
// Paste into code.earthengine.google.com (project: rgee-auth-tillam).
//
// Validation points (rs05_val_pts_2022, label 1/0) + training points
// (rs05_train_pts: positives by source cls=1, negatives source="negative" cls=0),
// over a live Sentinel-2 2022 composite.
//
// Both asset names are current -- build_02_embedding_classifier.R still uploads to
// rs05_train_pts / rs05_val_pts_2022 today (the "rs05" prefix is a leftover data-artifact
// name from before that script was renamed, not a sign these are stale).
//
// IMPORTANT (fixed 2026-09-17, was misleading before): rs05_train_pts is a SUPERSET
// containing barenblitt/maus/tang positives, because it feeds build_02's 18-way ablation
// (3 class schemes x 6 source combos) -- that part is intentional. But the DEPLOYED final
// classifier (FINAL_SCHEME "c4", FINAL_COMBO "no_maus") trains on ONLY barenblitt + tang
// (build_02_embedding_classifier.R lines ~1005/1009: final_srcs <- ABLATION[["no_maus"]]) --
// Maus positives exist in this asset for the ablation but are NOT used by the model that's
// actually running. The old version of this script drew all three sources as equal-looking
// layers, which visually implied Maus trains the deployed model -- it doesn't. Maus is now
// labelled accordingly and off by default; Barenblitt/Tang (the deployed model's real
// sources) are on by default.

var ASSET_HOME = "projects/rgee-auth-tillam/assets/ghana_mining";
var AOI_CENTER = ee.Geometry.Point([-1.942743, 6.060442]);
var AOI_HALFWIDTH_M = 20500.0;
var aoi = AOI_CENTER.buffer(AOI_HALFWIDTH_M * 1.4142).bounds();

// -- Validation points --
var valpts     = ee.FeatureCollection(ASSET_HOME + "/rs05_val_pts_2022");
var valMine    = valpts.filter(ee.Filter.eq("label", 1));
var valNonMine = valpts.filter(ee.Filter.eq("label", 0));

// -- Training points --
var trainpts = ee.FeatureCollection(ASSET_HOME + "/rs05_train_pts");

// color + "is this source actually in the deployed model" (no_maus = barenblitt + tang)
var POS_SOURCES = {
  barenblitt: {color: "e31a1c", inDeployed: true},   // red   -- deployed model source
  tang:       {color: "ff7f00", inDeployed: true},   // orange -- deployed model source
  maus:       {color: "1f78b4", inDeployed: false}   // blue  -- ABLATION ONLY, see header note
};

// -- Live Sentinel-2 2022 composite --
function maskS2(img) {
  var scl = img.select("SCL");
  return img.updateMask(scl.neq(3).and(scl.neq(9))).divide(10000);
}
var s2_2022 = ee.ImageCollection("COPERNICUS/S2_SR_HARMONIZED")
  .filterBounds(aoi)
  .filterDate("2022-01-01", "2022-12-31")
  .filter(ee.Filter.lt("CLOUDY_PIXEL_PERCENTAGE", 40))
  .map(maskS2)
  .median()
  .select(["B4", "B3", "B2"])
  .clip(aoi);

// -- Display --
Map.centerObject(aoi, 12);
Map.addLayer(s2_2022, {min: 0, max: 0.3}, "Sentinel-2 2022 (true colour)", true);

// Training positives by source -- Barenblitt/Tang on by default (they're what the deployed
// c4/no_maus model actually trains on); Maus off by default and labelled as ablation-only.
Object.keys(POS_SOURCES).forEach(function (src) {
  var cfg   = POS_SOURCES[src];
  var pts   = trainpts.filter(ee.Filter.eq("source", src));   // all cls=1
  var label = "Train +ve -- " + src + (cfg.inDeployed ? " (deployed model)" : " (ABLATION ONLY -- excluded from deployed no_maus model)");
  Map.addLayer(pts.style({color: cfg.color, fillColor: "00000000", pointSize: 5, width: 2}),
               {}, label, cfg.inDeployed);
  print("Train +ve " + src + (cfg.inDeployed ? "" : "  [ablation-only, not in deployed model]") + ":", pts.size());
});

// Training negatives
var trainNeg = trainpts.filter(ee.Filter.eq("source", "negative"));
Map.addLayer(trainNeg.style({color: "cccccc", fillColor: "00000000", pointSize: 3, width: 1}),
             {}, "Train -ve (negative)", false);
print("Train -ve:", trainNeg.size());

// Validation points on top
Map.addLayer(valMine.style({color: "ffff00", fillColor: "00000000", pointSize: 6, width: 2}),
             {}, "Val -- mine (label=1)", true);
Map.addLayer(valNonMine.style({color: "ffffff", fillColor: "00000000", pointSize: 6, width: 2}),
             {}, "Val -- non-mine (label=0)", true);
print("Validation points:", valpts.size(), " mine:", valMine.size(), " non-mine:", valNonMine.size());
