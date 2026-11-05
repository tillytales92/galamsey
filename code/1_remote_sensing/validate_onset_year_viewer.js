// validate_onset_year_viewer.js
// Paste into code.earthengine.google.com (project: rgee-auth-tillam).
//
// PURPOSE: visual inspector for the DEPLOYED backdating asset, build_04_backdating.R's
// mine_onset_year_2005_2016_barenblitt -- answers "what does this data actually look like"
// before trusting it downstream (b_04_rs_mining_panel.R). Loads the already-exported asset
// directly (does NOT recompute onset years -- that's build_04_backdating.R's job, or
// build_04_backdating_prototype.js for the side-by-side method comparison).
//
// WHAT THE ASSET IS (see build_04_backdating.R Section 12 for the authoritative version):
//   Anchor footprint = pixels classified mined in build_03's 2017 annual mask ONLY (not the
//   2017-2025 union -- a pixel first mined 2018+ is already dated by its own classification
//   year), reprojected 10m -> 30m Landsat grid by majority rule. For each anchor pixel, the
//   onset year is the single year in 2005-2016 with the steepest decline in a 3-yr-smoothed
//   annual max-NDVI series (Barenblitt et al.'s own "NDVI Anomaly Timeline" method, no
//   magnitude gate -- every anchor pixel gets SOME year unless its steepest drop fell at the
//   2017 boundary itself).
// 4 bands, each with its OWN undated sentinel:
//   onset_year        -- 2005-2016, or 0 = anchor pixel but undated.
//   ndvi_deriv_x1000   -- magnitude of the winning derivative, x1000 (toInt16 precision), or
//                         -9999 = undated. Continuous confidence score, no fixed cutoff.
//   reference_tier     -- 0 = no_reference (onset 2005-2006, Barenblitt's classifica field
//                         can't even in principle cover these), 1 = classifica_comparable
//                         (onset >= 2007), 9 = undated.
//   lt_agree           -- cross-check against LandTrendr (independent method, not deployed):
//                         0 = agree (LandTrendr cleared its own gate, within +-2yr),
//                         1 = disagree (LandTrendr cleared its gate, >2yr off),
//                         2 = no_lt_signal (LandTrendr found no confident break at all),
//                         9 = undated.
// NONE of this is ground-truth validation -- reference_tier/lt_agree flag uncertainty, they
// don't resolve it. See build_04_backdating.R's own header for the full caveat list.

// ---------- 0. Config ----------
var ASSET_HOME = 'projects/rgee-auth-tillam/assets/ghana_mining';
var ONSET_ID   = ASSET_HOME + '/mine_onset_year_2005_2016_barenblitt';
var ONSET_MIN  = 2005, ONSET_MAX = 2016;

var onset = ee.Image(ONSET_ID);

// dated = has a real onset_year (sentinel 0 excluded) -- gates every display layer below so
// sentinels never get misread as a real category/value.
var dated = onset.select('onset_year').gt(0);

var onsetYear = onset.select('onset_year').updateMask(dated);
var ndviDeriv = onset.select('ndvi_deriv_x1000').updateMask(dated).divide(1000).rename('ndvi_deriv');
var refTier   = onset.select('reference_tier').updateMask(dated);
var ltAgree   = onset.select('lt_agree').updateMask(dated);

// "anchor but undated" -- the pixels build_03 flagged as mined-as-of-2017 that this method
// never assigned a year to at all (steepest drop fell at the 2017 boundary itself; see header).
var undated = onset.select('onset_year').eq(0).selfMask();

// ---------- 1. Visualization params ----------
// Same gradient family as build_04_backdating_prototype.js's onsetVis, rescaled to the
// DEPLOYED window (2005-2016, not that script's 2000/2007-2016 options).
var onsetVis = {min: ONSET_MIN, max: ONSET_MAX,
                palette: ['#450457', '#8b5a9e', '#d94fd0', '#f9c5dd', '#FCFDBF']};
var derivVis = {min: 0, max: 0.3, palette: ['#FCFDBF', '#FD9567', '#CD4071', '#450457']};
var refTierVis = {min: 0, max: 1, palette: ['#d94fd0', '#450457']};         // 0 / 1
var ltAgreeVis = {min: 0, max: 2, palette: ['#2171B5', '#D94701', '#999999']}; // 0 / 1 / 2

// ---------- 2. Map ----------
Map.setOptions('SATELLITE');
Map.setCenter(-1.95, 6.05, 11);   // Amansie West area -- same default site as the companion app

Map.addLayer(onsetYear, onsetVis, 'onset year (2005-2016)', true);
Map.addLayer(ndviDeriv, derivVis, 'ndvi_deriv (confidence, no fixed cutoff)', false);
Map.addLayer(refTier, refTierVis, 'reference_tier (0=no_reference, 1=classifica_comparable)', false);
Map.addLayer(ltAgree, ltAgreeVis, 'lt_agree (0=agree, 1=disagree, 2=no_lt_signal)', false);
Map.addLayer(undated, {palette: ['ff0000']}, 'anchor pixel, UNDATED (steepest drop at 2017 boundary)', false);

// ---------- 3. Legends ----------
// Continuous gradient legend (onset year / ndvi_deriv), ported from
// build_04_backdating_prototype.js's makeOnsetLegend -- built from the SAME visParams
// Map.addLayer uses, so colors always match what's on the map.
function makeGradientLegend(visParams, title, decimals) {
  var lon = ee.Image.pixelLonLat().select('longitude');
  var gradient = lon.multiply((visParams.max - visParams.min) / 100.0).add(visParams.min);
  var legendImage = gradient.visualize(visParams);
  var fmt = function (v) { return decimals ? v.toFixed(decimals) : String(Math.round(v)); };

  var thumb = ui.Thumbnail({
    image: legendImage, params: {bbox: [0, 0, 100, 10], dimensions: '200x12'},
    style: {stretch: 'horizontal', margin: '0px 8px', maxHeight: '12px'}
  });
  var labels = ui.Panel({
    widgets: [
      ui.Label(fmt(visParams.min), {margin: '2px 8px'}),
      ui.Label(fmt((visParams.min + visParams.max) / 2),
               {margin: '2px 8px', textAlign: 'center', stretch: 'horizontal'}),
      ui.Label(fmt(visParams.max), {margin: '2px 8px'})
    ],
    layout: ui.Panel.Layout.flow('horizontal')
  });
  return ui.Panel({
    widgets: [ui.Label(title, {fontWeight: 'bold', margin: '4px 8px 0px 8px'}), thumb, labels],
    style: {padding: '6px'}
  });
}

// Discrete swatch legend (reference_tier / lt_agree categories).
function makeCategoryLegend(visParams, title, labelMap) {
  var rows = Object.keys(labelMap).map(function (key) {
    var frac = visParams.max > visParams.min ? (Number(key) - visParams.min) / (visParams.max - visParams.min) : 0;
    var idx = Math.round(frac * (visParams.palette.length - 1));
    var color = visParams.palette[idx];
    return ui.Panel({
      widgets: [
        ui.Label('', {backgroundColor: color, padding: '7px', margin: '2px 6px 2px 0px'}),
        ui.Label(labelMap[key], {margin: '2px 0px'})
      ],
      layout: ui.Panel.Layout.flow('horizontal')
    });
  });
  return ui.Panel({
    widgets: [ui.Label(title, {fontWeight: 'bold', margin: '4px 8px 4px 8px'})].concat(rows),
    style: {padding: '6px'}
  });
}

var legendPanel = ui.Panel({style: {position: 'bottom-right'}});
legendPanel.add(makeGradientLegend(onsetVis, 'Onset year', 0));
legendPanel.add(makeCategoryLegend(refTierVis, 'reference_tier',
  {0: 'no_reference (2005-06)', 1: 'classifica_comparable (>=2007)'}));
legendPanel.add(makeCategoryLegend(ltAgreeVis, 'lt_agree',
  {0: 'agree (<=2yr)', 1: 'disagree (>2yr)', 2: 'no_lt_signal'}));
Map.add(legendPanel);

// ---------- 4. Click-to-inspect: print every band's value at a point ----------
// The fastest way to actually see "what does this data look like" pixel-by-pixel, rather
// than just eyeballing colors -- click any point on the map.
var REF_TIER_LABELS = {0: 'no_reference', 1: 'classifica_comparable', 9: 'undated'};
var LT_AGREE_LABELS = {0: 'agree', 1: 'disagree', 2: 'no_lt_signal', 9: 'undated'};

Map.onClick(function (coords) {
  var pt = ee.Geometry.Point([coords.lon, coords.lat]);
  var vals = onset.reduceRegion({reducer: ee.Reducer.first(), geometry: pt, scale: 30}).getInfo();
  print('--- (' + coords.lon.toFixed(5) + ', ' + coords.lat.toFixed(5) + ') ---');
  if (vals.onset_year === null || vals.onset_year === 0) {
    print('Not an anchor pixel, or anchor but undated (onset_year = ' + vals.onset_year + ')');
  } else {
    print('onset_year:', vals.onset_year);
    print('ndvi_deriv:', vals.ndvi_deriv_x1000 === -9999 ? 'undated' : vals.ndvi_deriv_x1000 / 1000);
    print('reference_tier:', REF_TIER_LABELS[vals.reference_tier]);
    print('lt_agree:', LT_AGREE_LABELS[vals.lt_agree]);
  }
});

print('Click anywhere on the map to print that pixel\'s full band values. ' +
      'Toggle layers in the Layers panel (top-right) -- only onset_year is on by default.');
