// validate_ground_truth_comparison.js
// Paste into code.earthengine.google.com (project: rgee-auth-tillam).
//
// PURPOSE -- one map to compare, for 2022:
//   * a live Sentinel-2 true-colour composite (AOI)
//   * every reference mining product we have, as outlines: Barenblitt 2019, Maus 2022,
//     Tang & Werner 2023, SmallMinesDS
//   * build_03's DEPLOYED mask asset (mine_mask_ghana_c4_2022)
//   * OUR 2022 classifier at cutoffs {45, 60, 70}, each shown twice:
//        - raw   : prob >= cutoff, no urban knockout
//        - +GHSL : built_surface > GHSL_URBAN (500) knocked out   <- build_03's new config
//   * the industrial-exclusion candidate polygon, IF uploaded (see NOTE 2)
//
// AOI layers load on run; NATIONAL layers are added with visibility OFF -- tick them on in the
// Layers panel, the basemap switches to SATELLITE, use the top-of-map dropdown to fly around.
// Console prints national km2 @100 m for each (cutoff x filter) plus a Barenblitt-overlap recall
// proxy (km2 of the layer that falls inside a Barenblitt 2019 polygon).
//
// NOTE 1 -- the DEPLOYED layer reads the mine_mask_ghana_c4_2022 asset as-is, i.e. whatever config
// build_03 last exported. BEFORE the 2026-09-09 re-export that is the old config (cutoff 45 / GHSL
// 2000 / Barenblitt-only industrial); AFTER it, the new one (cutoff 70 / GHSL 500 / GSW + roads).
//
// NOTE 2 -- the industrial/artisanal split is DEFERRED (build_03 APPLY_INDUSTRIAL <- FALSE), so the
// re-exported mask does NOT subtract large-scale mines. The candidate polygon is shown here for QA
// only, and only once outputs/industrial_exclusion_candidate.shp (from scratchpad
// make_industrial_candidate.R) is uploaded to <ASSET_HOME>/industrial_exclusion_candidate.

var ASSET_HOME = "projects/rgee-auth-tillam/assets/ghana_mining";

// ---- parameters ------------------------------------------------------------
var YEAR       = 2022;            // vintage of the AOI assets + the S2 composite
var CUTOFFS    = [45, 60, 70];    // probability cutoffs to preview
var GHSL_URBAN = 500;             // build_03's new URBAN_THRESHOLD_100M (of 10000); knock out built_surface > this
var DEFAULT_CUTOFF = 60;          // which cutoff's layers are visible on load

var AOI_CENTER = ee.Geometry.Point([-1.942743, 6.060442]);
var AOI_HALFWIDTH_M = 20500.0;
var aoi = AOI_CENTER.buffer(AOI_HALFWIDTH_M * 1.4142).bounds();   // *sqrt(2) ~ circumscribes the R script's square AOI

// ---- sources -------------------------------------------------------------
var barenblitt = ee.FeatureCollection(ASSET_HOME + "/gt_compare_barenblitt_raw");
var maus       = ee.FeatureCollection(ASSET_HOME + "/gt_compare_maus_raw");
var tang       = ee.FeatureCollection(ASSET_HOME + "/gt_compare_tang_raw");
var smds       = ee.FeatureCollection(ASSET_HOME + "/gt_compare_smallminesds_aoi");
var GHANA      = ee.FeatureCollection(ASSET_HOME + "/rs05_ghana").geometry();

// 2022 c4 probability tiles (0-100 uint8). ghana_mining is a plain folder, not an ImageCollection,
// so enumerate it client-side and mosaic the tiles whose id contains '/mine_prob_ghana_c4_2022_t'.
var allAssetIds = ee.data.listAssets(ASSET_HOME).assets.map(function (a) { return a.id || a.name; });
var probIds = allAssetIds.filter(function (n) { return n.indexOf("/mine_prob_ghana_c4_" + YEAR + "_t") > -1; });
print(YEAR + " c4 prob tiles found (expect ~17):", probIds.length);
var probNat = ee.ImageCollection(probIds.map(function (id) { return ee.Image(id); })).mosaic();

// industrial-exclusion candidate (DEFERRED from build_03, APPLY_INDUSTRIAL <- FALSE). Shown here
// for QA only. Guarded -- silently absent until outputs/industrial_exclusion_candidate.shp is
// uploaded to this id. gate+confirm: leases INT (Maus>=1km2 U Barenblitt-ind) - Barenblitt-artisanal.
var IND_ASSET     = ASSET_HOME + "/industrial_exclusion_candidate";
var hasIndustrial = allAssetIds.indexOf(IND_ASSET) > -1;
if (!hasIndustrial) print("industrial_exclusion_candidate not uploaded yet -> " + IND_ASSET);

// build_03's deployed post-processed mask -- reflects whatever config build_03 last exported
var deployedNat = ee.Image(ASSET_HOME + "/mine_mask_ghana_c4_" + YEAR).selfMask();

// GHSL built surface, 2020 epoch ~ 2022
var ghslBuilt = ee.ImageCollection("JRC/GHSL/P2023A/GHS_BUILT_S")
  .filterDate("2020-01-01", "2021-01-01").first().select("built_surface");
var urbanKeep = ghslBuilt.gt(GHSL_URBAN).not();                   // 1 = keep, 0 = urban

// ---- live Sentinel-2 2022 composite (AOI only) --------------------------
function maskS2(img) {
  var scl = img.select("SCL");
  return img.updateMask(scl.neq(3).and(scl.neq(9))).divide(10000);
}
var s2 = ee.ImageCollection("COPERNICUS/S2_SR_HARMONIZED")
  .filterBounds(aoi).filterDate(YEAR + "-01-01", YEAR + "-12-31")
  .filter(ee.Filter.lt("CLOUDY_PIXEL_PERCENTAGE", 40))
  .map(maskS2).median().select(["B4", "B3", "B2"]).clip(aoi);

// palettes: raw = blues (deepen with cutoff), +GHSL = oranges
var RAW_PAL = {45: "9ecae1", 60: "4292c6", 70: "084594"};
var FLT_PAL = {45: "fdd0a2", 60: "fd8d3c", 70: "a63603"};
function ourRaw(ct) { return probNat.gte(ct).selfMask(); }
function ourFlt(ct) { return probNat.gte(ct).updateMask(urbanKeep).selfMask(); }

// ============================================================================
// AOI VIEW  (loads on run)
// ============================================================================
Map.centerObject(aoi, 12);
Map.addLayer(s2, {min: 0, max: 0.3}, "Sentinel-2 " + YEAR + " (true colour)", true);

Map.addLayer(barenblitt.style({color: "450457", fillColor: "00000000", width: 2}), {}, "Barenblitt 2019", true);
Map.addLayer(maus.style({color: "2171B5", fillColor: "00000000", width: 2}), {}, "Maus et al. 2022", false);
Map.addLayer(tang.style({color: "D94701", fillColor: "00000000", width: 2}), {}, "Tang & Werner 2023", false);
Map.addLayer(smds.style({color: "ff2a2a", fillColor: "00000000", width: 2}), {}, "SmallMinesDS (real outlines)", true);

if (hasIndustrial) {
  Map.addLayer(ee.FeatureCollection(IND_ASSET).style({color: "ff3300", fillColor: "ff33002e", width: 2}),
    {}, "industrial exclusion candidate (deferred, ~418 km2)", false);
}

Map.addLayer(deployedNat.clip(aoi), {palette: ["888888"]}, "build_03 DEPLOYED mask (last export)", false);

CUTOFFS.forEach(function (ct) {
  var vis = (ct === DEFAULT_CUTOFF);
  Map.addLayer(ourRaw(ct).clip(aoi), {palette: [RAW_PAL[ct]]}, "our " + YEAR + "  prob >= " + ct + "  (raw)", vis);
  Map.addLayer(ourFlt(ct).clip(aoi), {palette: [FLT_PAL[ct]]}, "our " + YEAR + "  prob >= " + ct + " + GHSL@" + GHSL_URBAN, vis);
});

print("SmallMinesDS patches:", smds.size(), " Barenblitt polys:", barenblitt.size(),
      " Maus polys:", maus.size(), " Tang polys:", tang.size());

// ============================================================================
// NATIONAL VIEW  (all visibility OFF -- tick on in the Layers panel)
// ============================================================================
Map.setOptions("SATELLITE");
Map.addLayer(deployedNat, {palette: ["888888"]}, "NAT  build_03 DEPLOYED mask (last export)", false);
if (hasIndustrial) {
  Map.addLayer(ee.FeatureCollection(IND_ASSET).style({color: "ff3300", fillColor: "ff33002e", width: 2}),
    {}, "NAT  industrial exclusion candidate (deferred, ~418 km2)", false);
}

CUTOFFS.forEach(function (ct) {
  Map.addLayer(ourRaw(ct), {palette: [RAW_PAL[ct]]}, "NAT  prob >= " + ct + "  (raw)", false);
  Map.addLayer(ourFlt(ct), {palette: [FLT_PAL[ct]]}, "NAT  prob >= " + ct + " + GHSL@" + GHSL_URBAN, false);
});

// ---- console: national area + Barenblitt-overlap recall proxy -------------
function areaKm2(img, label) {
  var a = img.gt(0).multiply(ee.Image.pixelArea()).reduceRegion({
    reducer: ee.Reducer.sum(), geometry: GHANA, scale: 100, maxPixels: 1e13, tileScale: 8
  });
  print(label + "  -- national km2 @100 m:", ee.Number(a.values().get(0)).divide(1e6));
}
var barImg = ee.Image().byte().paint(barenblitt, 1).selfMask();   // 1 inside a Barenblitt 2019 poly

CUTOFFS.forEach(function (ct) {
  areaKm2(ourRaw(ct),                  "prob >= " + ct + "  (raw)");
  areaKm2(ourFlt(ct),                  "prob >= " + ct + " + GHSL@" + GHSL_URBAN);
  areaKm2(ourRaw(ct).updateMask(barImg), "  ^ within Barenblitt (raw)");
  areaKm2(ourFlt(ct).updateMask(barImg), "  ^ within Barenblitt (+GHSL@" + GHSL_URBAN + ")");
});
areaKm2(deployedNat, "DEPLOYED mask asset (last export)");

// ---- jump-to dropdown ----------------------------------------------------
// "belt/River" = expect mining; "DARK" = expect little/none; "industrial" = large-scale leases,
// should be knocked out once build_03's gate+confirm industrial exclusion is re-exported.
var CHECK_SITES = {
  "belt - Obuasi":                 [-1.666, 6.202, 12],
  "belt - Dunkwa / Offin":         [-1.780, 5.972, 12],
  "belt - Tarkwa":                 [-1.995, 5.301, 12],
  "belt - Prestea":                [-2.143, 5.433, 12],
  "Eastern - Kibi / Atewa fringe": [-0.552, 6.163, 12],
  "Eastern - Anyinam":             [-0.545, 6.363, 13],
  "Ashanti - Amansie (AOI)":       [-1.943, 6.060, 12],
  "River - Pra corridor":          [-1.503, 5.720, 12],
  "River - Ankobra corridor":      [-2.230, 5.150, 12],
  "DARK: Kumasi metro":            [-1.616, 6.700, 12],
  "DARK: Accra / Tema":            [-0.100, 5.630, 11],
  "DARK: Sunyani":                 [-2.328, 7.339, 12],
  "DARK: Atewa forest core":       [-0.560, 6.230, 12],
  "DARK: Lake Volta":              [ 0.050, 6.900, 9],
  "DARK: Bui reservoir":           [-2.245, 8.280, 11],
  "industrial: Obuasi lease":      [-1.680, 6.150, 13],
  "industrial: Ahafo / Kenyasi":   [-2.360, 7.010, 12],
  "industrial: Tarkwa Gold":       [-1.995, 5.301, 13],
  "industrial: Damang":            [-1.820, 5.520, 13],
  "industrial: Chirano":           [-2.230, 6.230, 13],
  "industrial: Bibiani":           [-2.330, 6.460, 13],
  "industrial: Prestea / Bogoso":  [-2.143, 5.433, 13],
  "North: Wa (expect empty)":      [-2.500, 10.060, 10],
  "North: Tamale (expect empty)":  [-0.840, 9.400, 10]
};
Map.add(ui.Select({
  items: Object.keys(CHECK_SITES),
  placeholder: "jump to location...",
  onChange: function (key) { var s = CHECK_SITES[key]; Map.setCenter(s[0], s[1], s[2]); },
  style: {position: "top-center"}
}));
