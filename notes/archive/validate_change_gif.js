// validate_change_gif.js
// Paste into code.earthengine.google.com (project: rgee-auth-tillam).
//
// Animates mining expansion over a SMALL subregion, one frame per year, each frame = a dry-season
// true-colour composite (Landsat for 2017, Sentinel-2 2018 on -- see YEARS_OVERLAY/
// SENTINEL2_START_YEAR below), with the classifier's mine mask (mine_prob_ghana_c4_{yr}_t**,
// mosaicked, cutoff CUTOFF) painted on top as a SEMI-TRANSPARENT fill + solid outline (2026-09-17
// -- was a fully opaque fill, which hid the underlying imagery entirely inside mined areas) plus a
// real YEAR + LOCATION text label (2026-09-17 -- was a progress-bar stand-in; now uses the `gena/
// packages:text` community module, since GEE has no built-in text-on-image otherwise). NB that
// module's exact call signature is recalled from general familiarity, not verified against its
// current docs -- if `text.draw(...)` errors, check code.earthengine.google.com's Script Manager
// (search "text" under Examples/Community) for the current API and adjust the call below.
//
// MULTI-SITE UI (2026-11-02, user request): a dropdown (top-right) picks among SITES below --
// coordinates reused from validate_finalproduct.js's CHECK_SITES "belt" entries, i.e. known
// artisanal-mining corridors, not the "industrial"-labelled ones there (Obuasi and Prestea DO also
// host named large-scale leases nearby -- see the industrial-exclusion caveat in that file and in
// SITES' own comment below; this script's mask may still include some of that footprint until
// build_03's industrial exclusion is actually re-exported). Changing the dropdown immediately
// recenters the map (cheap); the two buttons trigger the actual heavy work on the CURRENTLY
// selected site: "Generate GIFs" runs the two getVideoThumbURL calls below, "Show area-over-time
// chart" sums the classifier mask's hectares per year (2017-2025) over the selected site's AOI and
// plots it as a ui.Chart in the Console. Neither runs automatically on load -- only the map view
// does -- same reasoning as validate_finalproduct.js gating its heavier stats behind buttons.
//
// TWO GIFs are produced from the same per-year imagery (2026-11-02, user request): `framesOverlay`
// (imagery + mine-mask fill/outline, as before) and `framesImagery` (the Sentinel-2 composite +
// year/location label alone, no mask) -- so the raw-imagery story can be shown without the overlay
// pre-empting "can you spot it yourself" viewing.
//
// `framesImagery` additionally runs back to LANDSAT_START_YEAR (2026-11-02, user request: start
// the series earlier than 2018) via Landsat 5/7/8 true-colour composites, same collections/cloud-
// mask approach as build_04_backdating.R Section 5 -- NOT the Roy et al. cross-sensor correction
// from that script (that's for NDVI/NBR precision; a true-colour GIF doesn't need it, just expect
// a faint tonal shift at sensor handovers ~2003/2013). `framesOverlay` CANNOT go earlier than 2017
// (CLASSIFIER_START_YEAR): the mine-mask classifier (`mine_prob_ghana_c4_*`) only exists 2017-2025,
// so there's no mask at all to overlay before that, regardless of background imagery availability.
// 2017 itself is now INCLUDED in framesOverlay (2026-11-02, was dropped entirely before) using
// Landsat as its background, since Sentinel-2 has no usable scenes over this AOI for 2017's window.
//
// OUTPUT: click "Generate GIFs" and check the Console -- it prints two clickable GIF URLs
// (getVideoThumbURL). Opens directly in the browser; right-click -> save to keep it. Section 2
// (commented out) is the Export.video.toDrive alternative if you want a permanent file instead of
// a URL that expires -- note that path exports .mp4, not .gif.
//
// WHY DRY-SEASON COMPOSITES (not calendar-year): SW Ghana is cloudy (see build_04's caveats on
// L5/L7 clear-obs scarcity) -- a straight Jan-Dec median lets cloud cover vary year to year and
// the GIF flickers on cloudiness, not on mining. Nov(yr-1)-Mar(yr) is the regional dry season, so
// each frame is labelled by the March it ends in and stays visually consistent across years.
//
// TUNE while checking output: keep DIMENSIONS small (few hundred px) and AOI small -- video/GIF
// thumbnails have tight pixel-count budgets and will silently fail or truncate frames if you push
// a national-scale region through this.

var ASSET_HOME = "projects/rgee-auth-tillam/assets/ghana_mining";
var PREFIX     = "mine_prob_ghana_c4_";

// ---- parameters -------------------------------------------------------------
// 2017's background imagery is LANDSAT, not Sentinel-2 (2026-11-02): COPERNICUS/S2_SR_HARMONIZED
// has ZERO scenes at all over this AOI for the 2017 dry-season window (confirmed via diagnostic,
// 2026-09-17) -- Sentinel-2's systematic acquisition over this part of Africa hadn't started yet
// (2018 itself is still sparse, only 5 total scenes, before jumping to 40-60+/year from 2019 on).
// The mine-mask classifier (mine_prob_ghana_c4_*) DOES exist for 2017 (build_03's EMBED_YEARS <-
// 2017:2025) -- it was only ever the background imagery that was missing, so 2017 used to be
// dropped from the overlay GIF entirely rather than special-cased. Now that the imagery-only GIF's
// Landsat path exists, 2017 is folded back into framesOverlay using Landsat as its background
// (SENTINEL2_START_YEAR below is the S2/Landsat switch; CLASSIFIER_START_YEAR is just where the
// mask itself starts existing -- keep these two concepts separate, conflating them is what caused
// 2017 to be dropped from the overlay in the first place).
var SENTINEL2_START_YEAR  = 2018;
var CLASSIFIER_START_YEAR = 2017;
var CLASSIFIER_END_YEAR   = 2025;
var YEARS_S2      = [];
for (var _ys = SENTINEL2_START_YEAR; _ys <= CLASSIFIER_END_YEAR; _ys++) { YEARS_S2.push(_ys); }
var YEARS_OVERLAY = [];
for (var _yo = CLASSIFIER_START_YEAR; _yo <= CLASSIFIER_END_YEAR; _yo++) { YEARS_OVERLAY.push(_yo); }
// NB 2018's frame will still look visibly noisier than 2019+ (built from ~4-5 S2 scenes); 2017's
// frame will look different again (Landsat true-colour, not S2 -- different sensor resolution/tone).
var CUTOFF     = 70;             // match build_03's deployed CUTOFF
var MASK_COLOR = "ff00ff";       // solid magenta -- matches validate_finalproduct.js
var CLOUD_MAX  = 20;             // tighter than the 40% used elsewhere -- fewer clouds = less flicker

// 2026-11-02: imagery-only GIF (no mine mask) runs back to LANDSAT_START_YEAR via Landsat 5/7/8.
// See landsatDrySeason() below for the band/cloud-mask setup.
var LANDSAT_START_YEAR = 2010;   // user call (2026-11-02) -- was 2000 (build_04's full backdating
                                  // window); 2010 chosen as a nearer, still-pre-classifier start
var YEARS_LANDSAT = [];
for (var _y = LANDSAT_START_YEAR; _y < SENTINEL2_START_YEAR; _y++) { YEARS_LANDSAT.push(_y); }
var YEARS_IMAGERY = YEARS_LANDSAT.concat(YEARS_S2);

var DIMENSIONS = 500;            // px, longest side -- keep small (GIF size/time budget)
var FRAMES_PER_SECOND = 0.6;     // 2026-11-02: slowed from 1.2 (~0.83s/frame) to 0.6 (~1.67s/frame)
                                  // per user request ("show each image longer"); tune further here.
var FILL_ALPHA = 0.45;           // mine-mask fill opacity, 0 (invisible) - 1 (fully opaque, old behaviour)

// ---- multi-site setup (2026-11-02) ---------------------------------------------------------
// Each site is an explicit rectangle (not a point+buffer) so the label-position arithmetic below
// stays plain client-side math instead of a server round-trip. All 4 share Amansie's original
// half-width/half-height (~0.115 deg lon x 0.105 deg lat, tightened ~25% from the very first
// version per an earlier "zoom in a little more" request) so every site gets the same framing.
// Center points for Obuasi/Dunkwa-Offin/Prestea are reused from validate_finalproduct.js's
// CHECK_SITES "belt" entries (known artisanal-mining corridors) -- NOT its "industrial" entries.
// CAVEAT: Obuasi and Prestea also sit near named large-scale leases (see CHECK_SITES' "industrial:
// Obuasi lease" / "industrial: Prestea / Bogoso" there) -- build_03's industrial-mine exclusion was
// flipped on 2026-10-27 but the masks haven't been re-exported since, so this script's mask may
// still include some of that footprint for those two sites specifically. Dunkwa/Offin and Amansie
// don't have that concern.
var HALF_LON = 0.115, HALF_LAT = 0.105;
function rectAround(lon, lat) { return [lon - HALF_LON, lat - HALF_LAT, lon + HALF_LON, lat + HALF_LAT]; }
var SITES = {
  "Amansie":          {rect: [-2.06, 5.96, -1.83, 6.17], zoom: 12},   // kept exact, pre-dates rectAround()
  "Obuasi":           {rect: rectAround(-1.666, 6.202),  zoom: 12},
  "Dunkwa / Offin":   {rect: rectAround(-1.780, 5.972),  zoom: 12},
  "Prestea":          {rect: rectAround(-2.143, 5.433),  zoom: 12}
};
var DEFAULT_SITE_KEY = "Amansie";

// mutable, set by applySite() below -- every function further down reads these at CALL time, not
// at definition time, so reassigning them here is enough to re-point the whole script at a new site.
var currentSiteKey, AOI_RECT, aoi, LABEL_POINT;

// ---- year/location text label (community module -- see header NOTE on API uncertainty) -------
var text = require("users/gena/packages:text");
// 2026-11-02: tried top-center + bigger font/scale per user request, but it came out "way too big
// and still weird" -- reverted to the original top-left / scale-30 / fontSize-24 settings below.
// (Also hit a real error along the way: fontSize is not a free parameter -- `gena/packages:text`
// loads a pre-rasterised font bitmap per size as a literal EE asset, e.g. `users/gena/fonts/
// Arial24`; 40 doesn't exist as an asset and threw `Image.load: ... not found`. 24 is the one
// confirmed to exist.)
var LABEL_SCALE = 30;   // rendering scale, metres -- roughly matches the AOI's Landsat-ish detail
var LABEL_STYLE = {
  fontSize: 24, textColor: "ffffff", outlineColor: "000000", outlineWidth: 3,
  alignX: "left", alignY: "top"
};

// recomputes AOI_RECT/aoi/LABEL_POINT for the given SITES key and recenters the map -- the cheap
// part of switching sites; does NOT regenerate GIFs or the chart (those are explicit button
// clicks, since they're the expensive part).
function applySite(key) {
  currentSiteKey = key;
  AOI_RECT = SITES[key].rect;
  aoi = ee.Geometry.Rectangle(AOI_RECT);
  LABEL_POINT = ee.Geometry.Point([AOI_RECT[0] + 0.015, AOI_RECT[3] - 0.015]);   // near top-left
  Map.centerObject(aoi, SITES[key].zoom);
}

var allAssetIds = ee.data.listAssets(ASSET_HOME).assets.map(function (a) { return a.id || a.name; });

// ---- per-year layers ----------------------------------------------------------
function probForYear(yr) {
  var ids = allAssetIds.filter(function (n) { return n.indexOf("/" + PREFIX + yr + "_t") > -1; });
  return ee.ImageCollection(ids.map(function (id) { return ee.Image(id); })).mosaic();
}
function maskS2(img) {
  var scl = img.select("SCL");
  return img.updateMask(scl.neq(3).and(scl.neq(9))).divide(10000);
}
function s2DrySeason(yr) {
  // Nov(yr-1) -> Mar(yr): the frame labelled `yr` is that year's dry season, not calendar year.
  var start = ee.Date.fromYMD(yr - 1, 11, 1);
  var end   = ee.Date.fromYMD(yr, 3, 31);

  var base   = ee.ImageCollection("COPERNICUS/S2_SR_HARMONIZED").filterBounds(aoi).filterDate(start, end);
  var strict = base.filter(ee.Filter.lt("CLOUDY_PIXEL_PERCENTAGE", CLOUD_MAX));
  // server-side fallback: if CLOUD_MAX is too strict for this window (e.g. an unusually cloudy
  // year), widen to 80% rather than silently handing median() an empty collection again.
  var col = ee.ImageCollection(ee.Algorithms.If(strict.size().gt(0), strict,
    base.filter(ee.Filter.lt("CLOUDY_PIXEL_PERCENTAGE", 80))));

  return col.map(maskS2).median().select(["B4", "B3", "B2"]).clip(aoi);
}

// ---- Landsat 5/7/8 true-colour, for YEARS_LANDSAT only (2026-11-02) ------------
// Same QA_PIXEL cloud-mask bits + C2 L2 scale factors as build_04_backdating.R Section 5. NOT the
// Roy et al. OLI->ETM+ harmonisation from that script -- that's calibrated for NDVI/NBR precision,
// not needed for a true-colour GIF; expect a faint tonal shift at the ~2003 (SLC-off) and ~2013
// (L5->L8 handover) boundaries.
//
// FIX 1 (2026-11-02, user reported solid-black pre-2018 frames): widened the window to 8 months
// (Aug(yr-1)-Apr(yr), vs S2's 5) and added a loose LANDSAT_CLOUD_MAX scene-level prefilter (mirrors
// s2DrySeason's CLOUDY_PIXEL_PERCENTAGE use, via Landsat's equivalent "CLOUD_COVER" property),
// since Landsat's 16-day/1-2-sensor revisit is much sparser than S2's 5-day/2-satellite cadence.
//
// FIX 2 (2026-11-02, diagnostics showed EVERY year at 0, root cause found): raw per-sensor counts
// (bounds + cloud filter + 2010 window, on the UNPROCESSED collection) were non-zero -- e.g. LE07
// had 7 -- yet landsatCol.filterDate(...) still returned 0 for every year. The `.select(bands,
// [...]).multiply(...).add(...)` chain below strips the image's `system:time_start` property, so
// every later `.filterDate()` call matches nothing, for every image, every year -- not a sparsity
// problem, a dropped-metadata problem. build_04_backdating.R's own near-identical Landsat prep
// (`prep_col`) hit this exact issue and explicitly re-attaches it via `copyProperties(img, list(
// "system:time_start"))` -- copied over here but originally missed. Fixed below.
//
// SEPARATE, GENUINE caveat (not a bug): LT05 (Landsat 5) returned only 5 scenes bounds-only, ALL
// TIME (vs LE07's 254, LC08's 185) -- consistent with Landsat 5's well-documented thin direct-
// downlink archive over much of Sub-Saharan Africa for most of its operational life. Expect 2010-
// 2011 composites to lean almost entirely on LE07 alone.
var LANDSAT_CLOUD_MAX = 80;   // % scene cloud cover, loose on purpose -- see note above
function maskLandsatQA(img) {
  var qa    = img.select("QA_PIXEL");
  var clear = qa.bitwiseAnd(1 << 1).eq(0)
    .and(qa.bitwiseAnd(1 << 3).eq(0))
    .and(qa.bitwiseAnd(1 << 4).eq(0));
  var sat = img.select("QA_RADSAT").eq(0);
  return img.updateMask(clear).updateMask(sat);
}
// NOTE (2026-11-02, multi-site fix): deliberately NOT filterBounds(aoi) here -- this collection is
// built ONCE at load, before any site is picked, so baking in a bounds filter here would freeze it
// to whatever `aoi` happened to be at that moment and never update when the dropdown changes (ee
// objects are immutable; reassigning the JS `aoi` variable later doesn't retroactively change an
// already-built ee.ImageCollection). filterBounds(aoi) instead happens inside landsatDrySeason()
// below, which re-reads the CURRENT `aoi` fresh on every call, same as s2DrySeason() already does.
function prepLandsat(id, bands) {
  return ee.ImageCollection(id)
    .filter(ee.Filter.lt("CLOUD_COVER", LANDSAT_CLOUD_MAX))
    .map(maskLandsatQA)
    .map(function (img) {
      return img.select(bands, ["RED", "GREEN", "BLUE"]).multiply(0.0000275).add(-0.2)
        .copyProperties(img, ["system:time_start"]);
    });
}
var LANDSAT_TM  = ["SR_B3", "SR_B2", "SR_B1"];   // L5/L7 true-colour: red, green, blue
var LANDSAT_OLI = ["SR_B4", "SR_B3", "SR_B2"];   // L8    true-colour: red, green, blue
var landsatCol = prepLandsat("LANDSAT/LT05/C02/T1_L2", LANDSAT_TM)
  .merge(prepLandsat("LANDSAT/LE07/C02/T1_L2", LANDSAT_TM))
  .merge(prepLandsat("LANDSAT/LC08/C02/T1_L2", LANDSAT_OLI));

function landsatWindow(yr) {
  return [ee.Date.fromYMD(yr - 1, 8, 1), ee.Date.fromYMD(yr, 4, 30)];
}
function landsatDrySeason(yr) {
  var w = landsatWindow(yr);
  return landsatCol.filterBounds(aoi).filterDate(w[0], w[1]).median().clip(aoi);
}

// picks Landsat (pre-SENTINEL2_START_YEAR) vs Sentinel-2 (SENTINEL2_START_YEAR on) -- same
// visualize() stretch for both, since both are scaled surface reflectance in roughly 0-0.3.
function imageryForYear(yr) {
  var img = (yr < SENTINEL2_START_YEAR) ? landsatDrySeason(yr) : s2DrySeason(yr);
  return img.visualize({min: 0, max: 0.3});
}

// diagnostic: per-year Landsat scene counts actually feeding each composite (post bounds+cloud
// filter, pre pixel-mask). CONFIRMED FIXED 2026-11-02 (counts came back non-zero after the
// copyProperties fix) -- left here, off by default; flip back to true if black frames recur.
var DIAG_PRINT_LANDSAT_COUNTS = false;
if (DIAG_PRINT_LANDSAT_COUNTS) {
  YEARS_LANDSAT.forEach(function (yr) {
    var w = landsatWindow(yr);
    print("Landsat scenes feeding " + yr + " composite:",
          landsatCol.filterBounds(aoi).filterDate(w[0], w[1]).size());
  });

  // 2026-11-02: the above came back 0 for EVERY year -- that points at one of the SHARED filter
  // steps (filterBounds, the CLOUD_COVER filter) failing identically for all three sensors, not
  // genuine data sparsity (sparsity would hit some years, not literally all of them). This isolates
  // which stage actually drops to zero, per sensor, for one representative year (2010).
  ["LANDSAT/LT05/C02/T1_L2", "LANDSAT/LE07/C02/T1_L2", "LANDSAT/LC08/C02/T1_L2"].forEach(function (id) {
    var boundsOnly = ee.ImageCollection(id).filterBounds(aoi);
    print(id + " -- filterBounds only, ALL TIME:", boundsOnly.size());
    var plusCloud = boundsOnly.filter(ee.Filter.lt("CLOUD_COVER", LANDSAT_CLOUD_MAX));
    print(id + " -- + CLOUD_COVER<" + LANDSAT_CLOUD_MAX + ", ALL TIME:", plusCloud.size());
    var w2010 = landsatWindow(2010);
    print(id + " -- + 2010 window:", plusCloud.filterDate(w2010[0], w2010[1]).size());
  });
}

function hexToRgb(hex) {
  return [parseInt(hex.substr(0, 2), 16), parseInt(hex.substr(2, 2), 16), parseInt(hex.substr(4, 2), 16)];
}

// Semi-transparent fill (so the underlying imagery still shows through mined areas) + a solid
// outline (a crisp boundary even where the fill alone would be hard to see against similarly
// bright ground). Outline = simple morphological boundary: pixels where a 1-pixel neighbourhood
// contains BOTH mask and non-mask values.
//
// `showMask` (2026-11-02) switches between the two GIF variants: TRUE = imagery + mine-mask fill/
// outline (runs YEARS_OVERLAY, 2017 on -- 2017's background is Landsat, see imageryForYear());
// FALSE = plain imagery, year/location label only (runs YEARS_IMAGERY, back to LANDSAT_START_YEAR).
function frameForYear(yr, showMask) {
  var vis   = imageryForYear(yr);   // 3-band 0-255, names vis-red/green/blue
  var label = text.draw(yr + " -- " + currentSiteKey, LABEL_POINT, LABEL_SCALE, LABEL_STYLE);

  if (!showMask) {
    return vis.toFloat().byte().blend(label).set("year", yr);
  }

  var maskBin = probForYear(yr).gte(CUTOFF).clip(aoi);          // 0/1
  var edge    = maskBin.focal_max(1).subtract(maskBin.focal_min(1)).selfMask();

  var colorImg = ee.Image.constant(hexToRgb(MASK_COLOR)).rename(["vis-red", "vis-green", "vis-blue"]).toFloat();
  var mixed    = vis.toFloat().multiply(1 - FILL_ALPHA).add(colorImg.multiply(FILL_ALPHA));
  var filled   = vis.toFloat().where(maskBin, mixed).byte();
  var outlined = filled.blend(edge.visualize({palette: [MASK_COLOR]}));

  return outlined.blend(label).set("year", yr);
}

// ============================================================================
// Section 1 -- "Generate GIFs" button: builds both frame collections for the CURRENTLY selected
// site and prints two clickable GIF URLs (getVideoThumbURL, expire -- click the button again to
// regenerate). Module-level so Section 2 below (commented out) can still reference them.
// ============================================================================
var framesOverlay, framesImagery;

function generateGifs() {
  framesOverlay = ee.ImageCollection(YEARS_OVERLAY.map(function (yr) { return frameForYear(yr, true); }));
  framesImagery = ee.ImageCollection(YEARS_IMAGERY.map(function (yr) { return frameForYear(yr, false); }));

  var gifParams = {
    region: aoi, dimensions: DIMENSIONS, crs: "EPSG:4326", framesPerSecond: FRAMES_PER_SECOND
  };
  print(currentSiteKey + " -- GIF with mine-mask overlay (" + YEARS_OVERLAY[0] + "-" +
        YEARS_OVERLAY[YEARS_OVERLAY.length - 1] + "):", framesOverlay.getVideoThumbURL(gifParams));
  print(currentSiteKey + " -- GIF, imagery only, no overlay (" + YEARS_IMAGERY[0] + "-" +
        YEARS_IMAGERY[YEARS_IMAGERY.length - 1] + "):", framesImagery.getVideoThumbURL(gifParams));

  // preview the last frame as a static image too, so you can sanity-check the AOI/mask/label
  // before waiting on either animation to render
  Map.layers().reset();   // drop any previous site's preview layer first
  Map.addLayer(framesOverlay.filter(ee.Filter.eq("year", YEARS_OVERLAY[YEARS_OVERLAY.length - 1])).first(),
    {}, currentSiteKey + " -- last frame preview (overlay)");
}

// ============================================================================
// Section 1b -- "Show area-over-time chart" button: sums the classifier mask's hectares per year
// (CLASSIFIER_START_YEAR-CLASSIFIER_END_YEAR) over the CURRENTLY selected site's small AOI, one
// multi-band reduceRegion call (cheap -- same single-call-over-many-bands pattern as the temporal-
// consistency rule pilots), plotted as a ui.Chart line in the Console. Uses the DEPLOYED
// mine_mask_ghana_c4_<yr> asset per year where it exists, else falls back to a live cutoff-CUTOFF
// threshold on the probability tiles (no postprocessing knockouts -- will read slightly high vs the
// deployed product for whichever years fall back). See the industrial-exclusion caveat in the
// SITES comment above for Obuasi/Prestea specifically.
// ============================================================================
var CLASSIFIER_YEARS = [];
for (var _yc = CLASSIFIER_START_YEAR; _yc <= CLASSIFIER_END_YEAR; _yc++) { CLASSIFIER_YEARS.push(_yc); }

function maskForChartYear(yr) {
  var maskId = ASSET_HOME + "/mine_mask_ghana_c4_" + yr;
  var exists = allAssetIds.indexOf(maskId) > -1;
  return exists ? ee.Image(maskId).selfMask() : probForYear(yr).gte(CUTOFF).selfMask();
}

function showAreaChart() {
  var bands = CLASSIFIER_YEARS.map(function (yr) {
    return ee.Image.pixelArea().updateMask(maskForChartYear(yr)).divide(1e4).rename("ha_" + yr);  // hectares
  });
  var combined = ee.Image.cat(bands);
  var stats = combined.reduceRegion({
    reducer: ee.Reducer.sum(), geometry: aoi, scale: 10, maxPixels: 1e10, tileScale: 4
  });
  var feats = CLASSIFIER_YEARS.map(function (yr) {
    return ee.Feature(null, {year: yr, hectares: stats.get("ha_" + yr)});
  });
  var chart = ui.Chart.feature.byFeature(ee.FeatureCollection(feats), "year", ["hectares"])
    .setChartType("LineChart")
    .setOptions({
      title: currentSiteKey + " -- artisanal mining area by year (ha), " +
             CLASSIFIER_START_YEAR + "-" + CLASSIFIER_END_YEAR,
      hAxis: {title: "Year", format: "####"},
      vAxis: {title: "Hectares"},
      pointSize: 5, lineWidth: 2, colors: ["ff00ff"], legend: {position: "none"}
    });
  print(chart);
}

// ============================================================================
// UI -- site dropdown + the two action buttons (top-right). Dropdown switch is cheap (just
// recenters the map); the buttons do the actual EE work, on whichever site is currently selected.
// ============================================================================
Map.setOptions("SATELLITE");
applySite(DEFAULT_SITE_KEY);   // sets AOI_RECT/aoi/LABEL_POINT and centers the map on load

var siteSelect = ui.Select({
  items: Object.keys(SITES),
  value: DEFAULT_SITE_KEY,
  onChange: applySite,
  style: {width: "200px"}
});
Map.add(ui.Panel(
  [ui.Label("Site:", {fontWeight: "bold"}), siteSelect,
   ui.Button({label: "Generate GIFs", onClick: generateGifs}),
   ui.Button({label: "Show area-over-time chart", onClick: showAreaChart})],
  ui.Panel.Layout.flow("vertical"),
  {position: "top-right", width: "220px"}
));

// ============================================================================
// Section 2 -- permanent file instead of an expiring URL (OFF by default). Produces an .mp4, not a
// .gif -- convert afterward (e.g. ffmpeg, or any online mp4->gif tool) if you need the .gif file
// itself for a slide deck etc. Run "Generate GIFs" at least once first (framesOverlay/framesImagery
// are populated there); swap `framesOverlay` for `framesImagery` to export the other variant.
// ============================================================================
// Export.video.toDrive({
//   collection: framesOverlay, description: "galamsey_change_gif_" + currentSiteKey + "_overlay",
//   folder: "ghana_mining_gee_exports", dimensions: DIMENSIONS, framesPerSecond: FRAMES_PER_SECOND,
//   region: aoi, crs: "EPSG:4326"
// });
