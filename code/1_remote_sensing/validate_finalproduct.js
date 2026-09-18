// validate_finalproduct.js
// Paste into code.earthengine.google.com (project: rgee-auth-tillam).
// Renamed 2026-09-17 from validate_ground_truth_comparison.js -- "ground truth comparison"
// undersold what this now does (full deployed-product QA: year/cutoff/urban-threshold tuning
// plus source comparison, not just a source-vs-source look). Companion R script renamed to
// validate_finalproduct.R alongside it.
//
// PURPOSE -- one map, driven by four interactive controls, to compare:
//   * a live Sentinel-2 true-colour composite -- follows whichever CHECK_SITES location is
//     selected (2026-09-16: previously fixed to one AOI; the site dropdown now also moves the S2
//     composite, not just the map viewport)
//   * a YEAR slider (top-left, 2026-09-16 merge of the standalone mine_prob_ghana_c4_{yr}_t0N
//     year-slider script) -- scrubs the S2 composite, Final product layer and probability layers together
//   * a CUTOFF slider and a GHSL URBAN-THRESHOLD slider (top-right, 2026-09-16) -- continuously
//     adjustable instead of the old fixed {45,60,70} comparison array
//   * every reference mining product we have, as outlines: Barenblitt 2019, Maus 2022,
//     Tang & Werner 2023, SmallMinesDS -- fixed-vintage snapshots (~2019-2022), so these don't
//     move with the year slider. NATIONAL as of 2026-09-17 (validate_finalproduct.R re-uploaded
//     all four as national assets, chunked to dodge EE's inline payload limit) -- previously
//     these were clipped to one ~41x41km Awomaso box, so the CHECK_SITES dropdown moved the S2
//     composite to other sites but these outlines just showed nothing there. Fixed now.
//   * the Final product layer (build_03's deployed mine_mask_ghana_c4_<year> asset), per slider year
//
// Layers are full-extent (no AOI clip, including the reference-product outlines now) except the
// S2 composite, which is clipped to a small window around the selected site (full-country median
// composites are needlessly expensive). Pan the site dropdown (top-center) to jump around;
// comparison layers load OFF -- tick them on as needed.
//
// CUT 2026-09-17 (were cluttering the map with layers the sliders already made redundant, or that
// were dormant/not-yet-real): the Ghana admin-1 GAUL-2015 region outlines (the site dropdown
// already tells you where you are by name); the industrial-exclusion-candidate layer (guarded on
// an asset that's never been uploaded -- re-add once build_03 actually ships that feature); and
// the 3 filter-cascade delta layers (dropped-by-GHSL / dropped-by-water+roads / scale-reproj-edge)
// -- those existed to support the one-time cutoff/GHSL threshold DECISION, already made and
// documented (notes/2026-09-08_build03_config_decision.md); with cutoff/urban-threshold now live
// sliders, toggling raw vs +GHSL vs Final product directly shows the same thing.
//
// NOTE 1 -- YEARS is auto-detected from which years have BOTH prob tiles and a deployed mask asset,
// so a year stuck mid-export (e.g. 2022 re-export queued behind a FORCE_REEXPORT run) is skipped
// by the slider instead of the map erroring on a missing asset.
//
// NOTE 2 -- area-stat console prints (national km2 + Barenblitt recall %) run once on load for the
// DEFAULT cutoff/year only -- use the "Print area stats" button to rerun for whatever the sliders
// currently show, so dragging never fires a burst of reduceRegion calls (this project has hit GEE
// quota/memory limits before -- see explainer.md).

var ASSET_HOME = "projects/rgee-auth-tillam/assets/ghana_mining";
var PREFIX     = "mine_prob_ghana_c4_";

// ---- parameters ------------------------------------------------------------
var DEFAULT_CUTOFF       = 70;     // build_03's deployed CUTOFF
var DEFAULT_URBAN_THRESH = 500;    // build_03's URBAN_THRESHOLD_100M (of 10000)
var RAW_COLOR = "084594";          // deep blue  -- prob >= cutoff, no urban knockout
var FLT_COLOR = "a63603";          // deep orange -- + GHSL urban knockout

var AOI_HALFWIDTH_M = 20500.0;     // half-width of the small window the S2 composite is clipped to
function siteAoi(lon, lat) {
  return ee.Geometry.Point([lon, lat]).buffer(AOI_HALFWIDTH_M * Math.SQRT2).bounds();
}
var DEFAULT_SITE = [-1.942743, 6.060442, 12];   // Ashanti - Amansie
var currentAoi  = siteAoi(DEFAULT_SITE[0], DEFAULT_SITE[1]);

// ---- sources (year-invariant vintage snapshots + orientation layers) -----
var barenblitt = ee.FeatureCollection(ASSET_HOME + "/gt_compare_barenblitt_raw");
var maus       = ee.FeatureCollection(ASSET_HOME + "/gt_compare_maus_raw");
var tang       = ee.FeatureCollection(ASSET_HOME + "/gt_compare_tang_raw");
var smds       = ee.FeatureCollection(ASSET_HOME + "/gt_compare_smallminesds");   // renamed 2026-09-17 (was _aoi, now national)
var GHANA      = ee.FeatureCollection(ASSET_HOME + "/rs05_ghana").geometry();

// ---- year discovery (client-side, reuses one listAssets call) -------------
var allAssetIds = ee.data.listAssets(ASSET_HOME).assets.map(function (a) { return a.id || a.name; });

function yearsWithPattern(re) {
  var yrs = {};
  allAssetIds.forEach(function (id) {
    var m = id.match(re);
    if (m) yrs[m[1]] = true;
  });
  return Object.keys(yrs).map(Number);
}
var probYears     = yearsWithPattern(new RegExp(PREFIX + "(\\d{4})_t"));
var deployedYears = yearsWithPattern(new RegExp("mine_mask_ghana_c4_(\\d{4})$"));
var YEARS = probYears.filter(function (y) { return deployedYears.indexOf(y) > -1; }).sort();
if (YEARS.length === 0) YEARS = [2017, 2018, 2019, 2020, 2021, 2022, 2023, 2024, 2025];  // fallback
print("Years with prob tiles + deployed mask (slider range):", YEARS);

var DEFAULT_YEAR = YEARS.indexOf(2022) > -1 ? 2022 : YEARS[YEARS.length - 1];

// GHSL built surface, 2020 epoch -- one fixed epoch used across the whole 2017-2025 slider range
var ghslBuilt = ee.ImageCollection("JRC/GHSL/P2023A/GHS_BUILT_S")
  .filterDate("2020-01-01", "2021-01-01").first().select("built_surface");

// ---- per-year / per-site data getters --------------------------------------
function probNatForYear(yr) {
  var ids = allAssetIds.filter(function (n) { return n.indexOf("/" + PREFIX + yr + "_t") > -1; });
  return ee.ImageCollection(ids.map(function (id) { return ee.Image(id); })).mosaic();
}
function deployedForYear(yr) {
  return ee.Image(ASSET_HOME + "/mine_mask_ghana_c4_" + yr).selfMask();
}
function maskS2(img) {
  var scl = img.select("SCL");
  return img.updateMask(scl.neq(3).and(scl.neq(9))).divide(10000);
}
function s2ForYearAndSite(yr, aoiGeom) {
  return ee.ImageCollection("COPERNICUS/S2_SR_HARMONIZED")
    .filterBounds(aoiGeom).filterDate(yr + "-01-01", yr + "-12-31")
    .filter(ee.Filter.lt("CLOUDY_PIXEL_PERCENTAGE", 40))
    .map(maskS2).median().select(["B4", "B3", "B2"]).clip(aoiGeom);
}

// live state -- reassigned by loadYear() / the site dropdown / the threshold sliders. ourRaw/ourFlt
// close over `probNat` and `urbanKeep` by reference, so reassigning those is picked up on the next
// call after any slider move.
var probNat, deployedNat, s2;
var currentYear         = DEFAULT_YEAR;
var currentCutoff       = DEFAULT_CUTOFF;
var currentUrbanThresh  = DEFAULT_URBAN_THRESH;
var urbanKeep           = ghslBuilt.gt(currentUrbanThresh).not();   // 1 = keep, 0 = urban

function ourRaw(ct) { return probNat.gte(ct).selfMask(); }
function ourFlt(ct) { return probNat.gte(ct).updateMask(urbanKeep).selfMask(); }

// ============================================================================
// MAP LAYERS -- built once as ui.Map.Layer objects so the sliders/dropdown can update them in place
// (setEeObject) instead of re-adding duplicate layers. Stacking order: S2 background,
// orientation/reference outlines, raw/flt, deltas, DEPLOYED mask last (drawn on top).
// ============================================================================
Map.setOptions("SATELLITE");
Map.centerObject(currentAoi, DEFAULT_SITE[2]);

var s2Layer = ui.Map.Layer(ee.Image(0), {min: 0, max: 0.3}, "Sentinel-2 (true colour, site AOI)", true);
Map.layers().add(s2Layer);

Map.addLayer(barenblitt.style({color: "450457", fillColor: "00000000", width: 2}), {}, "Barenblitt 2019", true);
Map.addLayer(maus.style({color: "2171B5", fillColor: "00000000", width: 2}), {}, "Maus et al. 2022", false);
Map.addLayer(tang.style({color: "D94701", fillColor: "00000000", width: 2}), {}, "Tang & Werner 2023", false);
Map.addLayer(smds.style({color: "ff2a2a", fillColor: "00000000", width: 2}), {}, "SmallMinesDS", true);

var rawLayer = ui.Map.Layer(ee.Image(0), {palette: [RAW_COLOR]}, "prob >= cutoff  (raw)", true);
var fltLayer = ui.Map.Layer(ee.Image(0), {palette: [FLT_COLOR]}, "prob >= cutoff + GHSL", true);
Map.layers().add(rawLayer);
Map.layers().add(fltLayer);

// Final product drawn last = on top; punchy magenta so it reads clearly over satellite
var deployedLayer = ui.Map.Layer(ee.Image(0), {palette: ["ff00ff"]}, "Final product", true);
Map.layers().add(deployedLayer);

// ---- refreshThresholds: recompute cutoff/urban-threshold-dependent layers ----
// Called after the cutoff slider, the urban-threshold slider, OR loadYear() (a new year needs the
// same recompute against the new probNat/deployedNat). Does NOT touch probNat/deployedNat/s2.
function refreshThresholds() {
  rawLayer.setEeObject(ourRaw(currentCutoff));
  rawLayer.setName("prob >= " + currentCutoff + "  (raw)");
  fltLayer.setEeObject(ourFlt(currentCutoff));
  fltLayer.setName("prob >= " + currentCutoff + " + GHSL@" + currentUrbanThresh);
}

// ---- refreshSite: recompute the S2 composite for the current year + AOI ----
function refreshSite() {
  s2 = s2ForYearAndSite(currentYear, currentAoi);
  s2Layer.setEeObject(s2);
  s2Layer.setName("Sentinel-2 " + currentYear + " (true colour, site AOI)");
}

// ---- loadYear: recompute probNat/deployedNat for a new year, then refresh everything downstream
function loadYear(yr) {
  currentYear = yr;
  probNat     = probNatForYear(yr);
  deployedNat = deployedForYear(yr);
  refreshSite();
  refreshThresholds();
  deployedLayer.setEeObject(deployedNat);
  deployedLayer.setName("Final product " + yr);
}
loadYear(DEFAULT_YEAR);

// ---- year slider ----------------------------------------------------------
var yearLabel  = ui.Label("Year: " + DEFAULT_YEAR, {fontWeight: "bold"});
var yearSlider = ui.Slider({
  min: 0, max: YEARS.length - 1, value: YEARS.indexOf(DEFAULT_YEAR), step: 1,
  style: {width: "300px"}
});
yearSlider.onChange(function (i) {
  var yr = YEARS[i];
  yearLabel.setValue("Year: " + yr);
  loadYear(yr);
});
Map.add(ui.Panel([yearLabel, yearSlider], ui.Panel.Layout.flow("vertical"),
  {position: "top-left", width: "340px"}));

// ---- cutoff + urban-threshold sliders --------------------------------------
var cutoffLabel = ui.Label("Cutoff: " + currentCutoff, {fontWeight: "bold"});
var cutoffSlider = ui.Slider({min: 0, max: 100, value: currentCutoff, step: 1, style: {width: "260px"}});
cutoffSlider.onChange(function (v) {
  currentCutoff = v;
  cutoffLabel.setValue("Cutoff: " + v);
  refreshThresholds();
});

var urbanLabel = ui.Label("GHSL urban threshold: " + currentUrbanThresh, {fontWeight: "bold"});
var urbanSlider = ui.Slider({min: 0, max: 10000, value: currentUrbanThresh, step: 100, style: {width: "260px"}});
urbanSlider.onChange(function (v) {
  currentUrbanThresh = v;
  urbanLabel.setValue("GHSL urban threshold: " + v);
  urbanKeep = ghslBuilt.gt(currentUrbanThresh).not();
  refreshThresholds();
});
Map.add(ui.Panel([cutoffLabel, cutoffSlider, urbanLabel, urbanSlider], ui.Panel.Layout.flow("vertical"),
  {position: "top-right", width: "300px"}));

print("SmallMinesDS patches:", smds.size(), " Barenblitt polys:", barenblitt.size(),
      " Maus polys:", maus.size(), " Tang polys:", tang.size());

// ---- console: national area + Barenblitt-overlap recall proxy -------------
// Fires once for the default cutoff/year on load. Re-run for whatever the sliders currently show
// via the button -- NOT auto-fired on every drag tick, so scrubbing never triggers a burst of
// reduceRegion calls.
function km2(img, geometry) {
  var a = img.gt(0).multiply(ee.Image.pixelArea()).reduceRegion({
    reducer: ee.Reducer.sum(), geometry: geometry, scale: 100, maxPixels: 1e13, tileScale: 8
  });
  return ee.Number(a.values().get(0)).divide(1e6);
}
var barImg = ee.Image().byte().paint(barenblitt, 1).selfMask();   // 1 inside a Barenblitt 2019 poly

// Prints the same 5 numbers twice -- once over all of Ghana, once over just the currently
// selected site (currentAoi) -- so you can see whether a slider change behaves the same way
// locally as it does nationally. NB Barenblitt only covers the SW hull, so the recall % at a
// site outside it (e.g. a "DARK: ..." or northern CHECK_SITES entry) will read ~0/undefined --
// that's real coverage information, not a bug.
function statsForRegion(region, label) {
  var rawKm2   = km2(ourRaw(currentCutoff), region);
  var fltKm2   = km2(ourFlt(currentCutoff), region);
  var finalKm2 = km2(deployedNat, region);
  print(label + " -- prob >= " + currentCutoff + "  (raw) km2:", rawKm2);
  print(label + " -- prob >= " + currentCutoff + " + GHSL@" + currentUrbanThresh + " km2:", fltKm2);
  print(label + " -- % of +GHSL within a Barenblitt 2019 polygon (recall proxy):",
        km2(ourFlt(currentCutoff).updateMask(barImg), region).divide(fltKm2).multiply(100));
  print(label + " -- Final product km2:", finalKm2);
  print(label + " -- % of Final product within a Barenblitt 2019 polygon (recall proxy):",
        km2(deployedNat.updateMask(barImg), region).divide(finalKm2).multiply(100));
}

function printAreaStats() {
  statsForRegion(GHANA, "National");
  statsForRegion(currentAoi, "Selected site");
}
printAreaStats();
Map.add(ui.Button({
  label: "Print area stats for current cutoff/year",
  onClick: printAreaStats,
  style: {position: "bottom-left"}
}));

// ---- jump-to dropdown -- now also moves the Sentinel-2 composite, not just the map viewport -----
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
  onChange: function (key) {
    var s = CHECK_SITES[key];
    Map.setCenter(s[0], s[1], s[2]);
    currentAoi = siteAoi(s[0], s[1]);
    refreshSite();
  },
  style: {position: "top-center"}
}));
