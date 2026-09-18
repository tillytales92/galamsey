// build_04_backdating_prototype.js
// Paste into code.earthengine.google.com (project: rgee-auth-tillam).
//
// Side-by-side prototype of two onset-dating methods for backdating the 2017-2025
// embedding-classifier mine footprint to 2000-2016, since build_04_backdating.R's own
// Section 7 (RStudio Viewer inspect) isn't rendering (2026-09-17) -- moved the whole
// eyeball-and-tune loop to the Code Editor instead, which is also just a better fit for
// open-ended visual comparison (see validate_finalproduct.R's header for the
// same Code-Editor-over-R-Viewer reasoning).
//
//   "landtrendr" (build_04's v1/deploy method, ported from Sections 5-6) -- LandTrendr
//                 segmentation of an annual -NBR series; onset = year of the largest
//                 drop in the FITTED (denoised) trajectory.
//   "ccdc"       (this file's own prototype -- not in build_04) -- CCDC (Continuous
//                 Change Detection & Classification) on a full 6-band harmonised
//                 Landsat stack; onset = fractional year of the first confirmed break.
//
// Both share ONE ever-mined anchor mask (Section 1) built from build_03's DEPLOYED
// mine_mask_ghana_c4_{yr} assets -- not a probability re-threshold -- so any difference
// between the two onset layers is a difference in DATING METHOD, not in which pixels
// got dated at all. Both also share the same cloud mask (Section 2) -- see NOTE 1 below
// for a bug that fix carries over from build_04's own debugging.
//
// NOTE 1 -- the original CCDC draft this was built from checked the cirrus QA_PIXEL bit
// on every sensor. build_04_backdating.R's own comment already flags that as wrong: that
// bit isn't cirrus on L5/L7 and can blank scenes incorrectly there. Dropped here so both
// branches share the same (correct) cloud mask.
//
// Deliberately simple (2026-09-17): no site dropdown, no CSV/asset export -- this is a
// look-and-eyeball prototype for ONE AOI at a time (edit TUNE_AOI's coordinates + re-run
// to check a different site). If/when a method here graduates into an actual pipeline
// step, that belongs in build_04_backdating.R (which already has its own national export +
// Barenblitt-validation-CSV machinery), not bolted onto this file.
//
// TUNING WORKFLOW -- keep TUNE = true (clips to the Awomaso AOI, or whatever you've edited
// TUNE_AOI to) while iterating on either method's parameters; tiles render in seconds.

// ---------- 0. Config ----------
var ASSET_HOME  = 'projects/rgee-auth-tillam/assets/ghana_mining';
var MASK_PREFIX = 'mine_mask_ghana_c4_';
var MASK_YEARS  = [2017, 2018, 2019, 2020, 2021, 2022, 2023, 2024, 2025];  // build_03 deployed years

var ONSET_START = 2000.0;   // fractional-year window for accepted breaks (both methods)
var ONSET_END   = 2017.0;   // 2017+ conversions are the embeddings' job

var TUNE     = true;        // true: clip to TUNE_AOI for fast iteration
var TUNE_AOI = ee.Geometry.Rectangle([-2.05, 5.98, -1.87, 6.15]);  // Awomaso

var ghana = ee.FeatureCollection(ASSET_HOME + '/rs05_ghana').geometry();
var aoi   = TUNE ? TUNE_AOI : ghana;

// ---------- 1. Shared ever-mined anchor mask (build_04 Section 4, ported) ----------
var allAssetIds = ee.data.listAssets(ASSET_HOME).assets.map(function (a) { return a.id || a.name; });
var maskIds = MASK_YEARS.map(function (yr) { return ASSET_HOME + '/' + MASK_PREFIX + yr; })
  .filter(function (id) { return allAssetIds.indexOf(id) > -1; });
print('Anchor mask years found:', maskIds.length, 'of', MASK_YEARS.length);
if (maskIds.length === 0) throw new Error('no mine_mask_ghana_c4_{yr} assets found');

var everMined10 = ee.ImageCollection(maskIds.map(function (id) { return ee.Image(id); }))
  .map(function (im) { return im.unmask(0); }).max().gt(0);          // 10 m, 0/1

var maskProj    = ee.Image(maskIds[0]).projection();                 // native 10 m grid
var landsatProj = ee.Projection('EPSG:32630').atScale(30);
var everMined = everMined10
  .setDefaultProjection(maskProj)
  .reduceResolution({reducer: ee.Reducer.mean(), maxPixels: 64})
  .reproject(landsatProj)
  .gte(0.5)
  .selfMask();

// ---------- 2. Landsat cloud mask (shared, both branches) ----------
// QA_PIXEL bits (Collection 2): 1 dilated cloud, 3 cloud, 4 cloud shadow. Bit 2 (cirrus)
// deliberately OMITTED -- see NOTE 1 above.
function maskL2(img) {
  var qa = img.select('QA_PIXEL');
  var clear = qa.bitwiseAnd(1 << 1).eq(0)
    .and(qa.bitwiseAnd(1 << 3).eq(0))
    .and(qa.bitwiseAnd(1 << 4).eq(0));
  var sat = img.select('QA_RADSAT').eq(0);
  return img.updateMask(clear).updateMask(sat);
}

// =========================================================================
// ---------- 3. CCDC branch ----------
// =========================================================================
function scaleOptical(img, bands, names) {
  return img.select(bands).rename(names)
    .multiply(0.0000275).add(-0.2)
    .copyProperties(img, ['system:time_start']);
}
var CCDC_NAMES   = ['BLUE', 'GREEN', 'RED', 'NIR', 'SWIR1', 'SWIR2'];
var tmBandsCcdc  = ['SR_B1', 'SR_B2', 'SR_B3', 'SR_B4', 'SR_B5', 'SR_B7'];  // L5/L7
var oliBandsCcdc = ['SR_B2', 'SR_B3', 'SR_B4', 'SR_B5', 'SR_B6', 'SR_B7'];  // L8
// NOTE: unlike the LandTrendr branch below, this does NOT apply Roy et al. OLI->ETM+
// harmonisation -- CCDC's multi-band harmonic fit tends to absorb a small per-band
// sensor offset into its own regression better than a single-index method does. If
// CCDC's breaks cluster suspiciously at the L7->L8 handover (~2013), check this first.
function prepCcdc(id, bands) {
  return ee.ImageCollection(id)
    .filterBounds(aoi)
    .filterDate('1997-01-01', '2019-01-01')
    .map(maskL2)
    .map(function (img) { return scaleOptical(img, bands, CCDC_NAMES); });
}
// Cloud-masked, full AOI -- NOT yet restricted to everMined. Kept separate from
// landsatCcdc below so the visual context composites (Section 5) can show the WHOLE box
// (surrounding forest/roads/rivers, not just mine pixels), while the everMined
// restriction is still applied before anything gets fed to the actual CCDC algorithm --
// that restriction is a real cost control (CCDC is expensive; no reason to run it over
// non-mined land), not just a display choice, so it stays on the collection below.
var landsatCcdcRaw = prepCcdc('LANDSAT/LT05/C02/T1_L2', tmBandsCcdc)
  .merge(prepCcdc('LANDSAT/LE07/C02/T1_L2', tmBandsCcdc))
  .merge(prepCcdc('LANDSAT/LC08/C02/T1_L2', oliBandsCcdc));

var landsatCcdc = landsatCcdcRaw
  .map(function (img) { return ee.Image(img).updateMask(everMined).clip(aoi); });

var nObs = landsatCcdc.select('NIR').count();   // shared sanity layer (cloud-obs density)

// STARTING parameters -- tune these (that is what this prototype is for)
var ccdc = ee.Algorithms.TemporalSegmentation.Ccdc({
  collection:           landsatCcdc,
  breakpointBands:      ['GREEN', 'RED', 'NIR', 'SWIR1', 'SWIR2'],
  tmaskBands:           ['GREEN', 'SWIR2'],
  minObservations:      6,
  chiSquareProbability: 0.99,
  minNumOfYearsScaler:  1.33,
  dateFormat:           1,        // fractional years (matches ONSET_*)
  lambda:               0.002,
  maxIterations:        25000
});

var tBreak    = ccdc.select('tBreak');
var changeP   = ccdc.select('changeProb');
var validCcdc = changeP.eq(1).and(tBreak.gte(ONSET_START)).and(tBreak.lt(ONSET_END));
var tValidCcdc   = tBreak.arrayMask(validCcdc);
var hasBreakCcdc = tValidCcdc.arrayLength(0).gt(0);
var onsetYearCcdc = tValidCcdc
  .arrayPad([1])                          // avoid reducing an empty array
  .arrayReduce(ee.Reducer.min(), [0])
  .arrayFlatten([['onset']])
  .updateMask(hasBreakCcdc)
  .floor().int16()
  .rename('onset_ccdc');

// =========================================================================
// ---------- 4. LandTrendr branch (build_04_backdating.R Sections 5-6, ported) ----------
// =========================================================================
// Roy et al. (2016) OLS coefficients, OLI -> ETM+ (Table 2) -- applied here because
// LandTrendr is fed a SINGLE index (-NBR), where a sensor offset directly biases the
// segmentation (see the CCDC branch's NOTE above for why it skips this).
var ROY = {
  RED:   {s: 0.9047, i: 0.0061},
  NIR:   {s: 0.8462, i: 0.0412},
  SWIR2: {s: 0.9071, i: 0.0172}
};
function prepLt(id, bands, isOli) {
  return ee.ImageCollection(id)
    .filterBounds(aoi)
    .filterDate('1999-01-01', '2019-01-01')
    .map(maskL2)
    .map(function (img) {
      var sr = img.select(bands, ['RED', 'NIR', 'SWIR2']).multiply(0.0000275).add(-0.2);
      if (isOli) {
        sr = sr.select('RED').multiply(ROY.RED.s).add(ROY.RED.i)
          .addBands(sr.select('NIR').multiply(ROY.NIR.s).add(ROY.NIR.i))
          .addBands(sr.select('SWIR2').multiply(ROY.SWIR2.s).add(ROY.SWIR2.i));
      }
      return sr.addBands(sr.normalizedDifference(['NIR', 'SWIR2']).rename('NBR'))
        .updateMask(everMined).clip(aoi)
        .copyProperties(img, ['system:time_start']);
    });
}
var tmBandsLt  = ['SR_B3', 'SR_B4', 'SR_B7'];   // L5/L7: red, nir, swir2
var oliBandsLt = ['SR_B4', 'SR_B5', 'SR_B7'];   // L8
var landsatLt = prepLt('LANDSAT/LT05/C02/T1_L2', tmBandsLt, false)
  .merge(prepLt('LANDSAT/LE07/C02/T1_L2', tmBandsLt, false))
  .merge(prepLt('LANDSAT/LC08/C02/T1_L2', oliBandsLt, true));

var LT_YEARS = [];
for (var y = 1999; y <= 2018; y++) LT_YEARS.push(y);   // padded window, matches build_04 IMG_START/END

var ltSeries = ee.ImageCollection(LT_YEARS.map(function (yr) {
  return ee.Image(landsatLt.filter(ee.Filter.calendarRange(yr, yr, 'year'))
    .select('NBR').reduce(ee.Reducer.median()))
    .multiply(-1000).toInt().rename('LOSS')
    .set('system:time_start', ee.Date.fromYMD(yr, 7, 1).millis());
}));

var lt = ee.Algorithms.TemporalSegmentation.LandTrendr({
  timeSeries:             ltSeries,
  maxSegments:            6,
  spikeThreshold:         0.9,
  vertexCountOvershoot:   3,
  preventOneYearRecovery: true,
  recoveryThreshold:      0.25,
  pvalThreshold:          0.05,
  bestModelProportion:    0.75,
  minObservationsNeeded:  6
});
var LT_MIN_MAGNITUDE = 100;   // min drop in inverted-NBR*1000 units to accept a disturbance

// row 0 = year, row 1 = source, row 2 = FITTED, row 3 = isVertex -- see build_04's own
// comment on why arrayProject([1]) is needed before arrayArgmax()/arrayFlatten() below.
var arrLt    = lt.select('LandTrendr');
var yearsLt  = arrLt.arraySlice(0, 0, 1).arrayProject([1]);
var fittedLt = arrLt.arraySlice(0, 2, 3).arrayProject([1]);
var fitLo = fittedLt.arraySlice(0, 0, -1);
var fitHi = fittedLt.arraySlice(0, 1);
var deltaLt = fitHi.subtract(fitLo);         // loss between t-1 and t (+ = loss)
var dYearLt = yearsLt.arraySlice(0, 1);      // the later year t

var inWinLt  = dYearLt.gte(ONSET_START + 1).and(dYearLt.lte(ONSET_END - 1));
var deltaWLt = deltaLt.arrayMask(inWinLt);
var yearWLt  = dYearLt.arrayMask(inWinLt);
var amaxLt   = deltaWLt.arrayArgmax().arrayFlatten([['i']]);
var maxMagLt = deltaWLt.arrayReduce(ee.Reducer.max(), [0]).arrayFlatten([['m']]);
var onsetYearLt = yearWLt.arrayGet(amaxLt).rename('onset_lt')
  .updateMask(maxMagLt.gte(LT_MIN_MAGNITUDE))
  .updateMask(everMined)
  .round().int16();

// =========================================================================
// ---------- 5. Compare + visualise ----------
// =========================================================================
// .clip(aoi) is load-bearing here, not cosmetic: hasBreakCcdc/onsetYearLt are only ever
// COMPUTED inside aoi (landsatCcdc/landsatLt are filterBounds(aoi)'d), so outside aoi
// they're undefined, not "confirmed no break". .unmask(0).not() (CCDC) and .mask().not()
// (LandTrendr) both turn "undefined" into "true" -- without the clip, these two layers
// would paint every ever-mined pixel in ALL OF GHANA as "no break", not just this AOI's.
var undatedCcdc = everMined.updateMask(hasBreakCcdc.unmask(0).not()).clip(aoi);
var undatedLt   = everMined.updateMask(onsetYearLt.mask().not()).clip(aoi);
var bothDated   = onsetYearCcdc.mask().and(onsetYearLt.mask());
var agreeDiff   = onsetYearCcdc.subtract(onsetYearLt).abs().updateMask(bothDated).rename('abs_diff');

Map.setOptions('SATELLITE');
Map.centerObject(TUNE_AOI, 12);
var rgbVis   = {bands: ['RED', 'GREEN', 'BLUE'], min: 0, max: 0.25};
var onsetVis = {min: 2000, max: 2016,
                palette: ['#450457', '#8b5a9e', '#d94fd0', '#f9c5dd', '#FCFDBF']};

// full-box context (NOT everMined-masked) -- cloud-masked only, clipped to aoi, so
// mined pixels are visible alongside their surrounding forest/roads/rivers for a real
// before/after visual check, not just isolated mine-footprint pixels.
Map.addLayer(landsatCcdcRaw.filterDate('2002-01-01', '2003-01-01').median().clip(aoi),
             rgbVis, 'Landsat median 2002 (full box)', false);
Map.addLayer(landsatCcdcRaw.filterDate('2007-01-01', '2008-01-01').median().clip(aoi),
             rgbVis, 'Landsat median 2007 (full box)', false);
Map.addLayer(landsatCcdcRaw.filterDate('2012-01-01', '2013-01-01').median().clip(aoi),
             rgbVis, 'Landsat median 2012 (full box)', false);
Map.addLayer(landsatCcdcRaw.filterDate('2016-01-01', '2017-01-01').median().clip(aoi),
             rgbVis, 'Landsat median 2016 (full box)', false);

// landsatCcdcRaw is capped at 2019-01-01 (prepCcdc's own filterDate, matching the
// CCDC/LandTrendr computation window) -- any year >= 2019 against it is an EMPTY
// collection, same "Image with no bands" failure as the GIF script's 2017 bug, just a
// different cause. This is a separate, uncapped OLI-only pull just for recent-year
// display composites (Landsat 5/7 are defunct by 2024 anyway, so OLI alone is fine).
function displayCompositeRecent(startDate, endDate) {
  return ee.ImageCollection('LANDSAT/LC08/C02/T1_L2')
    .filterBounds(aoi).filterDate(startDate, endDate)
    .map(maskL2)
    .map(function (img) { return scaleOptical(img, oliBandsCcdc, CCDC_NAMES); })
    .median().clip(aoi);
}
Map.addLayer(displayCompositeRecent('2024-01-01', '2025-01-01'), rgbVis, 'Landsat median 2024 (full box)', false);

Map.addLayer(ee.FeatureCollection([ee.Feature(aoi)]).style({color: 'ff0000', fillColor: '00000000', width: 2}),
             {}, 'AOI boundary', true);
// max was 600 (the theoretical ceiling if every possible L5+L7+L8 acquisition 1997-2018
// were cloud-free) -- real values in cloudy SW Ghana run ~50-150, so on a 0-600 scale
// everything rendered as the same near-zero red. Lowered so real variation is visible;
// nudge further once you've inspected a few more points.
Map.addLayer(nObs, {min: 0, max: 150, palette: ['red', 'yellow', 'green']}, 'clear obs count (lifetime total)', false);
// clip() here is cosmetic, not load-bearing like it was for undatedCcdc/undatedLt --
// everMined itself is fine to leave national (it's correctly combined with aoi-clipped
// collections wherever it actually gates a computation, Sections 3-4). This just keeps
// the DISPLAY consistent with every other layer being visibly confined to the AOI box.
Map.addLayer(everMined.clip(aoi), {palette: ['grey']}, 'ever mined (build_03 deployed, ' + maskIds.length + ' yrs)', false);

Map.addLayer(onsetYearCcdc, onsetVis, 'onset year -- CCDC', true);
Map.addLayer(onsetYearLt,   onsetVis, 'onset year -- LandTrendr', true);
Map.addLayer(undatedCcdc, {palette: ['00bcd4']}, 'mined, no CCDC break', false);
Map.addLayer(undatedLt,   {palette: ['ff9800']}, 'mined, no LandTrendr break', false);
Map.addLayer(agreeDiff, {min: 0, max: 8, palette: ['00ff00', 'ffff00', 'ff0000']},
             '|CCDC - LandTrendr| onset year (both dated)', false);

print('CCDC bands:', ccdc.bandNames());

// ---------- per-year clear-obs chart (click a point to check for gap years) ----------
// A lifetime TOTAL (the nObs layer above) can't tell "60 observations spread evenly" from
// "60 bunched in 3 good years, 18 near-blank ones" -- those look identical on that layer
// but explain very differently why a pixel might have no confirmed break. Click any point
// on the map to print a per-year clear-obs-count chart for that exact pixel.
// Extended to 2024 (was capped at 2018, same landsatCcdc date-cap issue as the display
// composites) -- 2019+ years pull from landsatRecentRaw (L8/L9 only; L5/L7 are defunct by
// then). Built from the RAW (not everMined-restricted) collections, matching the full-box
// composites above, so you can click anywhere in the box, not just inside mine pixels.
var landsatRecentRaw = ee.ImageCollection('LANDSAT/LC08/C02/T1_L2')
  .merge(ee.ImageCollection('LANDSAT/LC09/C02/T1_L2'))
  .filterBounds(aoi).filterDate('2019-01-01', '2025-01-01')
  .map(maskL2)
  .map(function (img) { return scaleOptical(img, oliBandsCcdc, CCDC_NAMES); });

var YEARS_ALL = [];
for (var yAll = 1997; yAll <= 2024; yAll++) YEARS_ALL.push(yAll);

var annualObsCcdc = ee.ImageCollection(YEARS_ALL.map(function (yr) {
  var src = yr <= 2018 ? landsatCcdcRaw : landsatRecentRaw;
  return src.filter(ee.Filter.calendarRange(yr, yr, 'year')).select('NIR').count()
    .rename('n_obs')
    .set('year', yr)
    .set('system:time_start', ee.Date.fromYMD(yr, 7, 1).millis());
}));

Map.onClick(function (coords) {
  var pt = ee.Geometry.Point([coords.lon, coords.lat]);
  var chart = ui.Chart.image.series({
    imageCollection: annualObsCcdc, region: pt, reducer: ee.Reducer.first(),
    scale: 30, xProperty: 'year'
  }).setOptions({
    title: 'Clear Landsat obs/year at (' + coords.lon.toFixed(4) + ', ' + coords.lat.toFixed(4) + ')',
    hAxis: {title: 'Year', format: '####'}, vAxis: {title: '# clear obs', minValue: 0},
    legend: {position: 'none'}
  });
  print(chart);   // accumulates in the Console across clicks -- clear the Console to reset
});

// Coverage stats behind a button, not auto-run -- Code Editor re-executes the WHOLE
// script on every Run click while you're tuning parameters above, so an automatic
// reduceRegion here would fire on every single parameter tweak.
function printCoverageStats() {
  var region = TUNE ? TUNE_AOI : ghana;
  // one multi-band reduceRegion instead of four separate calls -- count() respects each
  // band's own mask independently, so total/ccdc/lt/both can all be counted in one pass.
  var combined = ee.Image.cat([
    everMined.rename('total'),
    everMined.updateMask(hasBreakCcdc).rename('ccdc'),
    everMined.updateMask(onsetYearLt.mask()).rename('lt'),
    everMined.updateMask(bothDated).rename('both')
  ]);
  var counts = combined.reduceRegion({
    reducer: ee.Reducer.count(), geometry: region, scale: 30, maxPixels: 1e10, tileScale: 4
  }).getInfo();   // synchronous -- fine here, this only runs on a button click, not on load
  var pct = function (n) { return (100 * n / counts.total).toFixed(1) + '%'; };
  print('Ever-mined pixels in ' + (TUNE ? 'AOI box' : 'Ghana') + ':', counts.total);
  print('CCDC dated:', counts.ccdc + ' (' + pct(counts.ccdc) + ' of ever-mined)');
  print('LandTrendr dated:', counts.lt + ' (' + pct(counts.lt) + ' of ever-mined)');
  print('Both dated (overlap):', counts.both + ' (' + pct(counts.both) + ' of ever-mined)');
  print('Both dated, mean |diff| (years):', agreeDiff
    .reduceRegion({reducer: ee.Reducer.mean(), geometry: region, scale: 30, maxPixels: 1e10, tileScale: 4}));
}
Map.add(ui.Button({label: 'Print coverage stats', onClick: printCoverageStats, style: {position: 'bottom-left'}}));
