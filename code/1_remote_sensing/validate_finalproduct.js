// validate_finalproduct.js
// Paste into code.earthengine.google.com (project: rgee-auth-tillam).
//
// SPLIT 2026-09-28 from the combined cutoff-tuning + final-product-QA script: this file is now
// ROUTINE QA ONLY -- does the deployed product look right, year by year, against every reference
// mining product we have. The cutoff/GHSL-urban-threshold sweep (raw prob>=cutoff, +GHSL layers,
// their sliders) moved to the companion script validate_cutoff_tuning.js, for revisiting that
// (already-settled, cutoff=70/GHSL@500) decision if it's ever reopened. Both scripts are
// standalone paste-ins (no shared require() module, matching every other validate_*.js here) so
// each duplicates the S2 composite / CHECK_SITES / reference-outline plumbing.
//
// PURPOSE -- one map, driven by a YEAR slider, to compare:
//   * a live Sentinel-2 true-colour composite -- follows whichever CHECK_SITES location is
//     selected, and scrubs with the year slider
//   * the Final product layer (build_03's deployed mine_mask_ghana_c4_<year> asset), per slider year
//   * every reference mining product we have, as outlines: Barenblitt 2019, Maus 2022,
//     Tang & Werner 2023, SmallMinesDS -- fixed-vintage snapshots (~2019-2022), so their geometry
//     doesn't move with the year slider, but their VISIBILITY does: only the outline(s) matching
//     the slider year are shown (see NOTE 6). NATIONAL (validate_finalproduct.R uploads all four
//     as national assets, chunked to dodge EE's inline payload limit).
//   * the named industrial-mine footprints (build_03 Section 7's gate+confirm exclusion set,
//     uploaded per-mine by upload_industrial_candidate_maus.R as industrial_final_selected_<date>)
//     -- off by default, toggle on to sanity-check that known large-scale mines are actually
//     knocked out of the Final product layer.
//
// Layers are full-extent (no AOI clip, including the reference-product outlines) except the S2
// composite, which is clipped to a small window around the selected site (full-country median
// composites are needlessly expensive). Pan the site dropdown (top-center) to jump around;
// comparison layers load OFF -- tick them on as needed.
//
// NOTE 1 -- YEARS is every year with a deployed mask asset, so a year stuck mid-export is skipped
// by the slider instead of the map erroring on a missing asset.
//
// NOTE 2 -- area-stat console prints (national km2 + Barenblitt agreement proxy) run once on load
// for the DEFAULT year only -- use the "Print area stats" button to rerun for whatever year the
// slider currently shows, so dragging never fires a burst of reduceRegion calls (this project has
// hit GEE quota/memory limits before -- see explainer.md).
//
// NOTE 3 -- Barenblitt/Maus/Tang & Werner/SmallMinesDS are fixed-vintage snapshots (2019/2022/
// 2023/2022), not an annual series. Comparing a slider year far from a source's own vintage year
// is misleading -- galamsey expands over time, so e.g. Final product 2025 vs Maus 2022 would show
// inflated "ours only" area for reasons that are just post-2022 mining growth, not classifier
// error. So the area-stat comparison is GATED: "Print area stats" only computes the chosen
// source's km2 + agreement proxy when the slider year equals that source's own vintage year, and
// picking a source in "Compare to:" auto-snaps the slider there.
//
// NOTE 4 -- the "Show area-over-time chart" button (bottom-right) plots Final product km2 by
// year (National or the selected site, picked via the adjoining dropdown) as a line, with each
// reference source's own km2 drawn as a bar AT ITS OWN VINTAGE YEAR ONLY (2019/2022/2023) --
// gated behind a button like "Print area stats", for the same reduceRegion-burst reason.
//
// NOTE 5 -- Barenblitt (SW Ghana only) and SmallMinesDS (~5-district gold belt) do NOT cover all
// of Ghana, unlike Maus/Tang & Werner which are genuinely national/global -- comparing either of
// them to the whole country, or to a site outside their own coverage, would read "no mining" when
// the honest answer is "not surveyed" (CLAUDE.md). So both the area stats and the trend chart use
// each source's own convex hull (OWN_REGION) as its comparison universe: the "National" row is
// relabelled/recomputed over that hull instead of all of Ghana, the Selected-site row/chart bar
// is simply omitted when the chosen site falls entirely outside it, and the National-scope chart
// never shows these two sources at all (the whole country is never inside their coverage).
//
// NOTE 6 -- each reference outline's VISIBILITY (not just the area stats/chart) is year-gated
// too: loadYear() calls REFERENCE_LAYER[label].setShown(VINTAGE_YEAR[label] === yr) for all four,
// so e.g. selecting year 2022 shows only Maus/SmallMinesDS and hides Barenblitt/Tang & Werner --
// a layer that's irrelevant at the current year no longer sits on the map implying otherwise.
// Still manually toggleable afterward via the layer list if you want to see it anyway.

var ASSET_HOME = "projects/rgee-auth-tillam/assets/ghana_mining";

// ---- AOI / site helpers ----------------------------------------------------
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
var smds       = ee.FeatureCollection(ASSET_HOME + "/gt_compare_smallminesds");
var GHANA      = ee.FeatureCollection(ASSET_HOME + "/rs05_ghana").geometry();
// named industrial mines -- update date after re-running upload_industrial_candidate_maus.R
var industrialMines = ee.FeatureCollection(ASSET_HOME + "/industrial_final_selected_2026-10-27");

// Barenblitt (SW Ghana only) and SmallMinesDS (~5-district Amansie-Bekwai-Obuasi gold belt) do
// NOT cover all of Ghana -- unlike Maus/Tang & Werner, which are genuinely national/global. Each
// source's own convex hull (same construction diag_03_product_overlap.R uses for "bar_hull") is
// its real study area -- comparing it to the whole country, or to a site outside that hull, reads
// "no mining" when the honest answer is "not surveyed" (CLAUDE.md caveat). Computed directly from
// the already-uploaded FeatureCollections -- no new EE asset/upload needed.
var barenblittHull = barenblitt.geometry().convexHull();
var smdsHull       = smds.geometry().convexHull();

// Each reference source is a FIXED-VINTAGE snapshot, not an annual series -- see NOTE 3 below.
// Defined this early (ahead of the MAP LAYERS section) because loadYear() uses it to auto show/
// hide each outline layer -- only the source(s) matching the slider year stay visible.
var VINTAGE_YEAR = {
  "Barenblitt 2019":    2019,
  "Maus et al. 2022":   2022,
  "Tang & Werner 2023": 2023,
  "SmallMinesDS 2022":  2022
};

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
var YEARS = yearsWithPattern(new RegExp("mine_mask_ghana_c4_(\\d{4})$")).sort();
if (YEARS.length === 0) YEARS = [2017, 2018, 2019, 2020, 2021, 2022, 2023, 2024, 2025];  // fallback
print("Years with a deployed mask asset (slider range):", YEARS);

var DEFAULT_YEAR = YEARS.indexOf(2022) > -1 ? 2022 : YEARS[YEARS.length - 1];

// ---- per-year / per-site data getters --------------------------------------
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

// live state -- reassigned by loadYear() / the site dropdown.
var deployedNat, s2;
var currentYear = DEFAULT_YEAR;

// ============================================================================
// MAP LAYERS -- built once as ui.Map.Layer objects so the year slider/dropdown can update them in
// place (setEeObject) instead of re-adding duplicate layers. Stacking order: S2 background,
// orientation/reference outlines, DEPLOYED mask last (drawn on top).
// ============================================================================
Map.setOptions("SATELLITE");
Map.centerObject(currentAoi, DEFAULT_SITE[2]);

var s2Layer = ui.Map.Layer(ee.Image(0), {min: 0, max: 0.3}, "Sentinel-2 (true colour, site AOI)", true);
Map.layers().add(s2Layer);

// Captured as ui.Map.Layer (not plain Map.addLayer) so loadYear() below can setShown() them --
// only the source(s) whose own VINTAGE_YEAR matches the slider year stay visible; the booleans
// here are overwritten by the loadYear(DEFAULT_YEAR) call a few lines down, before the map ever
// renders, so they don't matter beyond readability.
var barenblittLayer = ui.Map.Layer(barenblitt.style({color: "450457", fillColor: "00000000", width: 2}), {}, "Barenblitt 2019", true);
var mausLayer       = ui.Map.Layer(maus.style({color: "2171B5", fillColor: "00000000", width: 2}), {}, "Maus et al. 2022", false);
var tangLayer       = ui.Map.Layer(tang.style({color: "D94701", fillColor: "00000000", width: 2}), {}, "Tang & Werner 2023", false);
var smdsLayer       = ui.Map.Layer(smds.style({color: "ff2a2a", fillColor: "00000000", width: 2}), {}, "SmallMinesDS", true);
Map.layers().add(barenblittLayer);
Map.layers().add(mausLayer);
Map.layers().add(tangLayer);
Map.layers().add(smdsLayer);
var REFERENCE_LAYER = {   // keys match VINTAGE_YEAR/COMPARE_SOURCES exactly
  "Barenblitt 2019":    barenblittLayer,
  "Maus et al. 2022":   mausLayer,
  "Tang & Werner 2023": tangLayer,
  "SmallMinesDS 2022":  smdsLayer
};

Map.addLayer(industrialMines.style({color: "ffff00", fillColor: "00000000", width: 2}),
             {}, "Industrial mines (named, final selection)", false);

// Final product drawn last = on top; punchy magenta so it reads clearly over satellite
var deployedLayer = ui.Map.Layer(ee.Image(0), {palette: ["ff00ff"]}, "Final product", true);
Map.layers().add(deployedLayer);

// ---- refreshSite: recompute the S2 composite for the current year + AOI ----
function refreshSite() {
  s2 = s2ForYearAndSite(currentYear, currentAoi);
  s2Layer.setEeObject(s2);
  s2Layer.setName("Sentinel-2 " + currentYear + " (true colour, site AOI)");
}

// ---- loadYear: recompute deployedNat for a new year, then refresh everything downstream
function loadYear(yr) {
  currentYear = yr;
  deployedNat = deployedForYear(yr);
  refreshSite();
  deployedLayer.setEeObject(deployedNat);
  deployedLayer.setName("Final product " + yr);
  // only show a reference outline for the year(s) it's actually a vintage snapshot of --
  // Barenblitt 2019 has nothing to say about year 2022, so hide it rather than leave it on and
  // imply otherwise. Still manually toggleable afterward via the layer list if wanted.
  Object.keys(VINTAGE_YEAR).forEach(function (label) {
    REFERENCE_LAYER[label].setShown(VINTAGE_YEAR[label] === yr);
  });
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

// Snaps the YEAR slider to a given year (used by "Compare to:" below) -- sets the widget value
// directly rather than relying on its onChange to fire, so the jump is explicit either way.
function jumpToYear(yr) {
  if (YEARS.indexOf(yr) === -1) return false;
  yearSlider.setValue(YEARS.indexOf(yr));
  yearLabel.setValue("Year: " + yr);
  loadYear(yr);
  return true;
}

// Cheap sanity check (server-side .size(), no rendering needed) that all four reference assets
// actually loaded with plausible counts -- catches a broken/misnamed/stale asset (e.g. the
// gt_compare_smallminesds_aoi/gt_compare_smallminesds mixup, 2026-09-28) immediately on load,
// before it'd otherwise only surface as missing outlines somewhere on the map.
print("SmallMinesDS patches:", smds.size(), " Barenblitt polys:", barenblitt.size(),
      " Maus polys:", maus.size(), " Tang polys:", tang.size());

// ---- console: national area + Barenblitt-overlap agreement proxy ----------
// Fires once for the default year on load. Re-run for whatever year the slider currently shows
// via the button -- NOT auto-fired on every drag tick, so scrubbing never triggers a burst of
// reduceRegion calls.
function km2(img, geometry) {
  var a = img.gt(0).multiply(ee.Image.pixelArea()).reduceRegion({
    reducer: ee.Reducer.sum(), geometry: geometry, scale: 100, maxPixels: 1e13, tileScale: 8
  });
  return ee.Number(a.values().get(0)).divide(1e6);
}
// ---- "Compare to:" -- which reference source the area stats below are measured against --------
var COMPARE_SOURCES = {
  "Barenblitt 2019":    barenblitt,
  "Maus et al. 2022":   maus,
  "Tang & Werner 2023": tang,
  "SmallMinesDS 2022":  smds
};
var currentCompareLabel = "Barenblitt 2019";
var compareImg = ee.Image().byte().paint(COMPARE_SOURCES[currentCompareLabel], 1).selfMask();

// VINTAGE_YEAR is defined earlier (before MAP LAYERS) -- also used here to gate the area-stat
// comparison and as the x-position of each source's bar in the area-over-time chart further down.

// Each source's own comparison universe -- GHANA for the two genuinely national/global products,
// its own convex hull for the two that aren't. Drives (a) what region + label the first
// statsForRegion() row below uses instead of a blanket "National", and (b) the Selected-site
// coverage gate right after it.
var OWN_REGION = {
  "Barenblitt 2019":    {region: barenblittHull, label: "Barenblitt study area",    national: false},
  "Maus et al. 2022":   {region: GHANA,          label: "National",                national: true},
  "Tang & Werner 2023": {region: GHANA,          label: "National",                national: true},
  "SmallMinesDS 2022":  {region: smdsHull,       label: "SmallMinesDS study area", national: false}
};

// One-off blocking check -- same pattern as the ee.data.listAssets() call near the top of this
// file -- whether testRegion falls entirely outside a non-national source's own coverage hull.
// Only called from a button/dropdown click, never a slider drag, so the blocking getInfo() is fine.
function outsideCoverage(label, testRegion) {
  var own = OWN_REGION[label];
  return !own.national && !own.region.intersects(testRegion, 1).getInfo();
}

// Prints the same numbers twice -- once over the comparison source's own coverage region (see
// OWN_REGION), once over just the currently selected site (currentAoi) -- so you can see whether
// the deployed product behaves the same way locally as it does over the source's full extent.
//
// CAVEAT (2026-09-22, see notes/2026-09-21_open_items.md sections F-H): computed at scale:100 for
// speed -- coarser than deployedNat's true native 10m storage resolution. deployedNat is exported
// with pyramidingPolicy "mode", so summarising it at 100m rounds mixed/boundary 100m cells up to
// fully "mined" wherever mined pixels are the local majority -- inflating "Final product km2" by
// roughly +3-8% nationally. Confirmed a pure display-precision artifact, not a flaw in the
// deployed asset (validate_native_scale_agreement.js: 99.996% Jaccard against a native-10m,
// grid-pinned check). Treat every number below as good for a quick sanity check / year-to-year
// comparison, NOT as a precise area figure to quote anywhere.
//
// NOTE also: this "agreement proxy" is (Final product AND comparison source) / Final product --
// i.e. what share of OUR flagged area the chosen source corroborates. That's closer to
// precision/agreement-with-that-source than true recall (which would need the denominator to be
// the source's own total mapped area). The real Barenblitt recall number (85.8% at the deployed
// config) is in diag_03_product_overlap.R's output.
// Comparison is only MEANINGFUL when (a) testRegion actually falls inside the source's own
// coverage and (b) the slider year equals the source's own vintage year (see NOTE 3) -- rather
// than print a caveat on a bad comparison, just don't compute one; unavailableReason (if given)
// takes priority over the year check.
function statsForRegion(region, label, unavailableReason) {
  var finalKm2 = km2(deployedNat, region);
  print(label + " -- Final product km2 [APPROX, scale:100 -- see caveat above function, likely +3-8% high]:", finalKm2);
  if (unavailableReason) {
    print(label + " -- " + currentCompareLabel + " comparison unavailable: " + unavailableReason);
    return;
  }
  if (currentYear !== VINTAGE_YEAR[currentCompareLabel]) {
    print(label + " -- " + currentCompareLabel + " comparison unavailable at year " + currentYear +
          " -- it's a " + VINTAGE_YEAR[currentCompareLabel] + "-vintage snapshot, not an annual " +
          "series. Move the YEAR slider to " + VINTAGE_YEAR[currentCompareLabel] +
          " (or just re-pick it in \"Compare to:\", which snaps the slider there) to compare.");
    return;
  }
  var compareKm2 = km2(compareImg, region);
  print(label + " -- " + currentCompareLabel + " km2:", compareKm2);
  print(label + " -- % of Final product within a " + currentCompareLabel + " polygon (agreement proxy):",
        km2(deployedNat.updateMask(compareImg), region).divide(finalKm2).multiply(100));
}

function printAreaStats() {
  var own = OWN_REGION[currentCompareLabel];
  statsForRegion(own.region, own.label);
  var siteReason = outsideCoverage(currentCompareLabel, currentAoi)
    ? ("the selected site falls entirely outside " + currentCompareLabel + "'s own coverage (" + own.label + ").")
    : null;
  statsForRegion(currentAoi, "Selected site", siteReason);
}
printAreaStats();
Map.add(ui.Button({
  label: "Print area stats for current year",
  onClick: printAreaStats,
  style: {position: "bottom-left"}
}));

// ---- area-over-time chart: Final product km2 by year, reference sources as vintage-year bars ---
// Gated behind a button, same reduceRegion-burst reason as "Print area stats" -- this one does
// YEARS.length + 4 reduceRegion calls in a single batched FeatureCollection, so it's heavier than
// that button and should be used deliberately, not on every tick of a slider.
var SOURCE_COLOR = {   // matches each source's own outline colour above, for a consistent legend
  "Barenblitt 2019":    "450457",
  "Maus et al. 2022":   "2171B5",
  "Tang & Werner 2023": "D94701",
  "SmallMinesDS 2022":  "ff2a2a"
};
var trendScopeLabel = "National";
function trendRegion() { return trendScopeLabel === "National" ? GHANA : currentAoi; }

// ee.Feature property names reject "." and "&" (e.g. "Maus et al. 2022" -> "Invalid property
// name") -- chart-safe stand-ins for the COMPARE_SOURCES/VINTAGE_YEAR labels, used ONLY for
// Feature properties/chart column names below; every other UI (dropdowns, print labels) keeps
// the real label.
var CHART_COL = {
  "Barenblitt 2019":    "Barenblitt 2019",
  "Maus et al. 2022":   "Maus 2022",
  "Tang & Werner 2023": "Tang and Werner 2023",
  "SmallMinesDS 2022":  "SmallMinesDS 2022"
};

function showTrendChart() {
  var region = trendRegion();
  // Drop any source whose own coverage doesn't actually reach this chart's region -- a 0-height
  // bar at every year for a source that was never going to have mining data here (National scope
  // for Barenblitt/SmallMinesDS, or a Selected site outside either source's hull) would otherwise
  // look like "we checked, found nothing" rather than "not surveyed" (same OWN_REGION/
  // outsideCoverage logic as "Print area stats").
  var srcLabels = Object.keys(VINTAGE_YEAR).filter(function (l) {
    return trendScopeLabel === "National" ? OWN_REGION[l].national : !outsideCoverage(l, region);
  });
  var seriesCols = ["Final product"].concat(srcLabels.map(function (l) { return CHART_COL[l]; }), "Industrial mines");
  // Industrial mines are a STATIC named-mine footprint (not a time series, see NOTE 6-adjacent
  // comment at the top of this file) and build_03 excludes them from every year's Final product
  // mask identically -- one reduceRegion, replicated across all years as a flat reference line
  // (not stacked -- Final product and this are mutually exclusive by construction of the mask).
  var industrialKm2 = km2(ee.Image().byte().paint(industrialMines, 1).selfMask(), region);
  var feats = YEARS.map(function (yr) {
    var props = {year: yr, "Final product": km2(deployedForYear(yr), region), "Industrial mines": industrialKm2};
    srcLabels.forEach(function (srcLabel) {
      // 0, not null -- a mix of null/number values in one column makes Google Charts throw "All
      // series on a given axis must be of the same data type" (every feature needs a consistent
      // numeric type per column). A 0-height bar at a non-vintage year is visually a no-op anyway.
      props[CHART_COL[srcLabel]] = (VINTAGE_YEAR[srcLabel] === yr)
        ? km2(ee.Image().byte().paint(COMPARE_SOURCES[srcLabel], 1).selfMask(), region)
        : 0;
    });
    return ee.Feature(null, props);
  });
  var seriesStyle = {0: {type: "line", color: "ff00ff", lineWidth: 3, pointSize: 5}};
  srcLabels.forEach(function (srcLabel, i) {
    seriesStyle[i + 1] = {type: "bars", color: SOURCE_COLOR[srcLabel]};
  });
  seriesStyle[srcLabels.length + 1] = {type: "line", color: "ffff00", lineWidth: 2, lineDashStyle: [4, 4], pointSize: 0};
  var chart = ui.Chart.feature.byFeature(ee.FeatureCollection(feats), "year", seriesCols)
    .setChartType("ComboChart")
    .setOptions({
      title: trendScopeLabel + " mined area by year (km2) -- Final product vs. reference snapshots",
      hAxis: {title: "Year", format: "####"},
      vAxis: {title: "km2"},
      seriesType: "line",
      series: seriesStyle
    });
  print(chart);
  print("Area-over-time chart note: each reference source shown only has a bar at its own " +
        "vintage year (Barenblitt 2019, Maus/SmallMinesDS 2022, Tang & Werner 2023) -- see NOTE " +
        "3/4 at the top of this script. Barenblitt/SmallMinesDS are additionally dropped " +
        "entirely when they don't cover this chart's region (National scope, or a Selected site " +
        "outside their own study area) -- same coverage check as \"Print area stats\". The " +
        "yellow dashed \"Industrial mines\" line is flat by construction (same static footprint " +
        "every year) and is NOT part of Final product -- build_03 subtracts it from every " +
        "year's mask identically, so the two series are mutually exclusive, not stacked.");
}

var trendScopeSelect = ui.Select({
  items: ["National", "Selected site"],
  value: trendScopeLabel,
  onChange: function (key) { trendScopeLabel = key; },
  style: {width: "140px"}
});
Map.add(ui.Panel(
  [ui.Label("Area trend:", {fontWeight: "bold"}), trendScopeSelect,
   ui.Button({label: "Show area-over-time chart (Console)", onClick: showTrendChart})],
  ui.Panel.Layout.flow("vertical"),
  {position: "bottom-right", width: "260px"}
));

var compareLabel = ui.Label("Compare to:", {fontWeight: "bold"});
var compareSelect = ui.Select({
  items: Object.keys(COMPARE_SOURCES),
  value: currentCompareLabel,
  onChange: function (key) {
    currentCompareLabel = key;
    compareImg = ee.Image().byte().paint(COMPARE_SOURCES[key], 1).selfMask();
    jumpToYear(VINTAGE_YEAR[key]);   // comparison is only meaningful at this source's own vintage year
    printAreaStats();   // one-off dropdown pick, not a drag -- safe to auto-fire
  },
  style: {width: "220px"}
});
Map.add(ui.Panel([compareLabel, compareSelect], ui.Panel.Layout.flow("vertical"),
  {position: "top-right", width: "260px"}));

// ---- jump-to dropdown -- also moves the Sentinel-2 composite, not just the map viewport --------
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
  value: "Ashanti - Amansie (AOI)",   // matches DEFAULT_SITE -- dropdown now reflects the actual
                                      // default state instead of looking unselected
  onChange: function (key) {
    var s = CHECK_SITES[key];
    Map.setCenter(s[0], s[1], s[2]);
    currentAoi = siteAoi(s[0], s[1]);
    refreshSite();
  },
  style: {position: "top-center"}
}));

// ---- one-time info popup -- explains the map on launch, dismissible ---------------------------
var infoPanel = ui.Panel({
  widgets: [
    ui.Label("Final product QA", {fontWeight: "bold", fontSize: "16px"}),
    ui.Label("Deployed mining-detection output (magenta), by year -- drag the YEAR slider " +
             "(top-left) to scrub it. The reference outlines -- Barenblitt 2019, Maus 2022, " +
             "Tang & Werner 2023, SmallMinesDS -- auto show/hide to match: only the source(s) " +
             "whose own vintage year equals the slider year stay visible (toggle the layer list " +
             "to override). The named industrial mines layer is static, off by default."),
    ui.Label("Use \"Compare to:\" (top-right) to pick which reference source the area stats are " +
             "measured against -- prints our footprint, the source's own footprint, and the " +
             "overlap %, snapping the YEAR slider to that source's own vintage year (comparison " +
             "is only computed when the slider year matches it). \"Print area stats\" (bottom-" +
             "left) reruns it for the current year + site; Barenblitt/SmallMinesDS comparisons " +
             "use each source's own study-area hull (not \"National\") and go quiet if the " +
             "selected site falls outside it -- they don't cover all of Ghana."),
    ui.Label("\"Area trend\" (bottom-right) plots Final product km2 by year -- National or the " +
             "selected site -- as a chart in the Console, with each reference source's own km2 " +
             "shown as a bar at its own vintage year only (Barenblitt/SmallMinesDS dropped " +
             "entirely wherever they don't cover the chosen region)."),
    ui.Label("Jump to a specific site with the dropdown (top-center)."),
    ui.Label("For adjusting the detection cutoff / GHSL urban threshold instead of just viewing " +
             "the deployed product, use the companion script validate_cutoff_tuning.js.",
             {fontStyle: "italic", color: "666666"}),
    ui.Button({
      label: "Got it",
      onClick: function () { infoPanel.style().set("shown", false); }
    })
  ],
  style: {position: "bottom-center", width: "320px", padding: "10px", backgroundColor: "white"}
});
Map.add(infoPanel);
