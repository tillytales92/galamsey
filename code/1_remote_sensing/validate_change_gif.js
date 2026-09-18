// validate_change_gif.js
// Paste into code.earthengine.google.com (project: rgee-auth-tillam).
//
// Animates mining expansion over a SMALL subregion (AOI below, currently Amansie), 2018-2025
// (2017 excluded -- see YEARS below): one frame per year, each frame = a Sentinel-2 dry-season
// true-colour composite with the classifier's mine mask (mine_prob_ghana_c4_{yr}_t**, mosaicked,
// cutoff CUTOFF) painted on top as a SEMI-TRANSPARENT fill + solid outline (2026-09-17 -- was a
// fully opaque fill, which hid the underlying imagery entirely inside mined areas) plus a real
// YEAR + LOCATION text label (2026-09-17 -- was a progress-bar stand-in; now uses the `gena/
// packages:text` community module, since GEE has no built-in text-on-image otherwise). NB that
// module's exact call signature is recalled from general familiarity, not verified against its
// current docs -- if `text.draw(...)` errors, check code.earthengine.google.com's Script Manager
// (search "text" under Examples/Community) for the current API and adjust the call below.
//
// This AOI is Amansie -- if you later find (per the district-level mining-increase analysis) a
// different district with a bigger 2018-2025 increase worth animating, just change AOI_RECT and
// LOCATION_LABEL below; nothing else in the script is Amansie-specific.
//
// OUTPUT: run this, then check the Console -- it prints a clickable GIF URL (getVideoThumbURL).
// Opens directly in the browser; right-click -> save to keep it. Section 2 (commented out) is the
// Export.video.toDrive alternative if you want a permanent file instead of a URL that expires --
// note that path exports .mp4, not .gif.
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
// 2017 EXCLUDED (2026-09-17, confirmed via diagnostic): COPERNICUS/S2_SR_HARMONIZED has ZERO
// scenes at all over this AOI for the 2017 dry-season window -- not a cloud-filtering issue,
// Sentinel-2's systematic acquisition over this part of Africa hadn't started yet (2018 itself is
// still sparse, only 5 total scenes, before jumping to 40-60+/year from 2019 on). No date-window
// widening fixes a year with genuinely zero source imagery, so it's dropped rather than special-
// cased. NB 2018's frame will still look visibly noisier than 2019+ (built from ~4-5 scenes).
var YEARS      = [2018, 2019, 2020, 2021, 2022, 2023, 2024, 2025];
var CUTOFF     = 70;             // match build_03's deployed CUTOFF
var MASK_COLOR = "ff00ff";       // solid magenta -- matches validate_finalproduct.js
var CLOUD_MAX  = 20;             // tighter than the 40% used elsewhere -- fewer clouds = less flicker

var DIMENSIONS = 500;            // px, longest side -- keep small (GIF size/time budget)
var FRAMES_PER_SECOND = 1.2;
var FILL_ALPHA = 0.45;           // mine-mask fill opacity, 0 (invisible) - 1 (fully opaque, old behaviour)

// same Amansie corridor used as the AOI in validate_finalproduct.js / the tile scripts,
// as an explicit rectangle (not a point+buffer) so the label-position arithmetic below is plain
// client-side math instead of a server round-trip.
var AOI_RECT       = [-2.10, 5.93, -1.79, 6.20];   // [xmin, ymin, xmax, ymax], degrees
var LOCATION_LABEL = "Amansie";
var aoi = ee.Geometry.Rectangle(AOI_RECT);

// ---- year/location text label (community module -- see header NOTE on API uncertainty) -------
var text = require("users/gena/packages:text");
var LABEL_POINT = ee.Geometry.Point([AOI_RECT[0] + 0.015, AOI_RECT[3] - 0.015]);   // near top-left
var LABEL_SCALE = 30;   // rendering scale, metres -- roughly matches the AOI's Landsat-ish detail
var LABEL_STYLE = {
  fontSize: 24, textColor: "ffffff", outlineColor: "000000", outlineWidth: 3,
  alignX: "left", alignY: "top"
};

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

function hexToRgb(hex) {
  return [parseInt(hex.substr(0, 2), 16), parseInt(hex.substr(2, 2), 16), parseInt(hex.substr(4, 2), 16)];
}

// Semi-transparent fill (so the underlying imagery still shows through mined areas) + a solid
// outline (a crisp boundary even where the fill alone would be hard to see against similarly
// bright ground). Outline = simple morphological boundary: pixels where a 1-pixel neighbourhood
// contains BOTH mask and non-mask values.
function frameForYear(yr) {
  var s2vis = s2DrySeason(yr).visualize({min: 0, max: 0.3});   // 3-band 0-255, names vis-red/green/blue
  var maskBin = probForYear(yr).gte(CUTOFF).clip(aoi);          // 0/1
  var edge    = maskBin.focal_max(1).subtract(maskBin.focal_min(1)).selfMask();

  var colorImg = ee.Image.constant(hexToRgb(MASK_COLOR)).rename(["vis-red", "vis-green", "vis-blue"]).toFloat();
  var mixed    = s2vis.toFloat().multiply(1 - FILL_ALPHA).add(colorImg.multiply(FILL_ALPHA));
  var filled   = s2vis.toFloat().where(maskBin, mixed).byte();
  var outlined = filled.blend(edge.visualize({palette: [MASK_COLOR]}));

  var label = text.draw(yr + " -- " + LOCATION_LABEL, LABEL_POINT, LABEL_SCALE, LABEL_STYLE);
  return outlined.blend(label).set("year", yr);
}

var frames = ee.ImageCollection(YEARS.map(frameForYear));

// ============================================================================
// Section 1 -- quick preview: prints a clickable GIF URL (expires; re-run to regenerate)
// ============================================================================
var gifParams = {
  region: aoi, dimensions: DIMENSIONS, crs: "EPSG:4326", framesPerSecond: FRAMES_PER_SECOND
};
print("GIF (year + location labelled top-left, " + YEARS[0] + "-" + YEARS[YEARS.length - 1] + "):",
      frames.getVideoThumbURL(gifParams));

// preview the last frame as a static image too, so you can sanity-check the AOI/mask/bar
// before waiting on the animation to render
Map.centerObject(aoi, 11);
Map.setOptions("SATELLITE");
Map.addLayer(frames.filter(ee.Filter.eq("year", YEARS[YEARS.length - 1])).first(), {}, "last frame preview");

// ============================================================================
// Section 2 -- permanent file instead of an expiring URL (OFF by default). Produces an .mp4, not a
// .gif -- convert afterward (e.g. ffmpeg, or any online mp4->gif tool) if you need the .gif file
// itself for a slide deck etc.
// ============================================================================
// Export.video.toDrive({
//   collection: frames, description: "galamsey_change_gif_amansie",
//   folder: "ghana_mining_gee_exports", dimensions: DIMENSIONS, framesPerSecond: FRAMES_PER_SECOND,
//   region: aoi, crs: "EPSG:4326"
// });
