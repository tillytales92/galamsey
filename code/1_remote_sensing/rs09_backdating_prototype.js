// rs09_backdating_prototype.js  — GEE CODE EDITOR PROTOTYPE (JavaScript)
// =========================================================================
// Backdate the 2017–2025 embedding-classifier mine footprint to 2000–2016
// by dating each ever-mined pixel's conversion break in the Landsat archive
// with CCDC (Continuous Change Detection and Classification).
//
// Paste into code.earthengine.google.com (project: rgee-auth-tillam).
//
// LOGIC
//   1. ever-mined mask = max over mine_prob_ghana_{2017..2025} >= 50
//      (uint8 integer-percent assets written by rs05 Section 9)
//   2. Landsat 5/7/8 C2 L2 stack 1997–2018, cloud-masked, harmonised to
//      common band names (1997 start gives CCDC a stable pre-2000 baseline;
//      2018 end gives it enough post-break observations to confirm breaks
//      late in the 2000–2016 window)
//   3. CCDC on the masked stack -> first confirmed break in [2000, 2017)
//      -> onset year (int16). Pixels with no pre-2017 break are dated by
//      the embedding panel instead (they converted 2017+, or were already
//      mined before 2000 — see caveats).
//
// CAVEATS (state these in any output that uses the result)
//   - Only dates pixels still visible as mined in 2017+: mines that opened
//     AND fully revegetated before 2017 never enter the anchor mask.
//   - A break = spectral disturbance, not necessarily mining: within the
//     mask most breaks are the conversion event, but logging/clearing that
//     PRECEDED mining on the same pixel will date the clearing, not the pit.
//   - 30 m Landsat pixels vs the 10 m mask: the mask is aggregated with
//     .reduceResolution(mean) >= 0.5, i.e. majority mined per 30 m cell.
//   - Validate against Barenblitt MiningConversion_2007-2017Vec `classifica`
//     (2-digit conversion year) once uploaded as an asset — see Section 7.
//
// TUNING WORKFLOW
//   Keep TUNE = true (clips everything to the Awomaso AOI) while iterating
//   on the CCDC parameters in Section 5 — tiles render in seconds instead
//   of the Inspector timing out. Flip TUNE = false only to submit the
//   national export in Section 6.
// =========================================================================

// ---------- 0. Config ----------
var ASSET_HOME  = 'projects/rgee-auth-tillam/assets/ghana_mining';
var PROB_YEARS  = [2017, 2018, 2019, 2020, 2021, 2022, 2023, 2024, 2025];
var PROB_THRESH = 50;      // uint8 percent, mirrors rs05 downstream threshold
var ONSET_START = 2000.0;  // fractional-year window for accepted breaks
var ONSET_END   = 2017.0;

var TUNE     = true;       // true: clip to TUNE_AOI for fast iteration
var TUNE_AOI = ee.Geometry.Rectangle([-2.05, 5.98, -1.87, 6.15]);  // Awomaso

var ghana = ee.FeatureCollection(ASSET_HOME + '/rs05_ghana').geometry();
var aoi   = TUNE ? TUNE_AOI : ghana;

// ---------- 1. Ever-mined mask from the rs05 probability assets ----------
var probStack = ee.ImageCollection(
  PROB_YEARS.map(function (yr) {
    return ee.Image(ASSET_HOME + '/mine_prob_ghana_' + yr);
  })
);
// .max() makes a composite, which has NO valid default projection — grab the
// native 10 m grid from one of the source assets and re-stamp it.
var probProj    = ee.Image(ASSET_HOME + '/mine_prob_ghana_' + PROB_YEARS[0])
  .projection();
var everMined10 = probStack.max().gte(PROB_THRESH);  // 10 m, 0/1

// Aggregate to a 30 m Landsat-scale grid: majority-mined per 30 m cell.
// (Fixed UTM 30N grid rather than a specific scene's projection — scene IDs
// churn and CCDC output inherits the request projection anyway.)
var landsatProj = ee.Projection('EPSG:32630').atScale(30);
var everMined = everMined10
  .setDefaultProjection(probProj)
  .reduceResolution({reducer: ee.Reducer.mean(), maxPixels: 64})
  .reproject(landsatProj)
  .gte(0.5)
  .selfMask();

// Optional speckle cleanup (uncomment after checking the raw mask):
// everMined = everMined.updateMask(
//   everMined.connectedPixelCount(10, false).gte(4));   // >= ~0.36 ha

// ---------- 2. Landsat 5/7/8 C2 L2, cloud-masked, harmonised ----------
function maskL2(img) {
  var qa = img.select('QA_PIXEL');
  var clear = qa.bitwiseAnd(1 << 1).eq(0)   // dilated cloud
    .and(qa.bitwiseAnd(1 << 2).eq(0))       // cirrus (L8; unused bit on L5/7)
    .and(qa.bitwiseAnd(1 << 3).eq(0))       // cloud
    .and(qa.bitwiseAnd(1 << 4).eq(0));      // cloud shadow
  var sat = img.select('QA_RADSAT').eq(0);  // no saturated bands
  return img.updateMask(clear).updateMask(sat);
}
function scaleOptical(img, bands, names) {
  return img.select(bands).rename(names)
    .multiply(0.0000275).add(-0.2)
    .copyProperties(img, ['system:time_start']);
}
var NAMES = ['BLUE', 'GREEN', 'RED', 'NIR', 'SWIR1', 'SWIR2'];
var tm  = ['SR_B1', 'SR_B2', 'SR_B3', 'SR_B4', 'SR_B5', 'SR_B7'];  // L5/L7
var oli = ['SR_B2', 'SR_B3', 'SR_B4', 'SR_B5', 'SR_B6', 'SR_B7'];  // L8

function prepCol(id, bands) {
  return ee.ImageCollection(id)
    .filterBounds(aoi)
    .filterDate('1997-01-01', '2019-01-01')
    .map(maskL2)
    .map(function (img) { return scaleOptical(img, bands, NAMES); });
}
var landsat = prepCol('LANDSAT/LT05/C02/T1_L2', tm)
  .merge(prepCol('LANDSAT/LE07/C02/T1_L2', tm))
  .merge(prepCol('LANDSAT/LC08/C02/T1_L2', oli))
  .map(function (img) {
    return ee.Image(img).updateMask(everMined).clip(aoi);
  });

// Sanity layer: clear-observation density (SW Ghana clouds + L7 SLC-off
// make this the first thing to check — CCDC needs a usable time series)
var nObs = landsat.select('NIR').count();

// ---------- 3. CCDC ----------
// STARTING parameters — tune these (that is what this prototype is for):
//   breakpointBands  drive break detection; GREEN/RED/NIR/SWIR separates
//                    vegetation -> bare/water well for galamsey
//   chiSquareProbability  lower = more (earlier, noisier) breaks
//   minObservations       consecutive anomalies to confirm a break
//   lambda                LASSO regularisation of the harmonic fit
var ccdc = ee.Algorithms.TemporalSegmentation.Ccdc({
  collection:            landsat,
  breakpointBands:       ['GREEN', 'RED', 'NIR', 'SWIR1', 'SWIR2'],
  tmaskBands:            ['GREEN', 'SWIR2'],
  minObservations:       6,
  chiSquareProbability:  0.99,
  minNumOfYearsScaler:   1.33,
  dateFormat:            1,        // fractional years (matches ONSET_*)
  lambda:                0.002,
  maxIterations:         25000
});

// ---------- 4. First confirmed break in [ONSET_START, ONSET_END) ----------
var tBreak = ccdc.select('tBreak');       // 1D array image, one per segment
var prob   = ccdc.select('changeProb');   // 1 = confirmed break
var valid  = prob.eq(1)
  .and(tBreak.gte(ONSET_START))
  .and(tBreak.lt(ONSET_END));
var tValid   = tBreak.arrayMask(valid);
var hasBreak = tValid.arrayLength(0).gt(0);
var onsetYear = tValid
  .arrayPad([1])                          // avoid reducing an empty array
  .arrayReduce(ee.Reducer.min(), [0])
  .arrayFlatten([['onset']])
  .updateMask(hasBreak)
  .floor().int16()
  .rename('onset_year');

// Pixels in the mask WITHOUT a dated pre-2017 break -> handled by the
// embedding panel (converted 2017+), or mined before 2000 / undatable.
var undated = everMined.updateMask(hasBreak.unmask(0).not());

// ---------- 5. Visualise ----------
Map.centerObject(TUNE_AOI, 12);
var rgbVis = {bands: ['RED', 'GREEN', 'BLUE'], min: 0, max: 0.25};
Map.addLayer(landsat.filterDate('2002-01-01', '2003-01-01').median(),
             rgbVis, 'Landsat median 2002', false);
Map.addLayer(landsat.filterDate('2016-01-01', '2017-01-01').median(),
             rgbVis, 'Landsat median 2016', false);
Map.addLayer(nObs, {min: 0, max: 600, palette: ['red', 'yellow', 'green']},
             'clear obs count', false);
Map.addLayer(everMined, {palette: ['grey']}, 'ever mined 2017-2025', false);
Map.addLayer(onsetYear,
             {min: 2000, max: 2016,
              palette: ['#450457', '#8b5a9e', '#d94fd0', '#f9c5dd', '#FCFDBF']},
             'onset year 2000-2016');
Map.addLayer(undated, {palette: ['cyan']}, 'mined, no pre-2017 break', false);

// Click pixels with the Inspector to eyeball tBreak/changeProb segments.
print('CCDC bands', ccdc.bandNames());

// ---------- 6. Export (flip TUNE = false first) ----------
Export.image.toAsset({
  image:            onsetYear.unmask(0).updateMask(everMined),  // 0 = undated
  description:      'mine_onset_year_2000_2016',
  assetId:          ASSET_HOME + '/mine_onset_year_2000_2016',
  region:           ghana.bounds(),
  scale:            30,
  crs:              'EPSG:4326',
  maxPixels:        1e13,
  pyramidingPolicy: {'.default': 'mode'}   // categorical years: no averaging
});

// ---------- 7. Validation hook (needs one more asset) ----------
// Upload data/raw/barenblitt/MiningConversion_2007-2017Vec.shp as
// ghana_mining/barenblitt_conversion_0717 (rs09 R port will do this like
// rs05's upload_as_asset), then:
// var conv = ee.FeatureCollection(ASSET_HOME + '/barenblitt_conversion_0717');
// var sampled = onsetYear.sampleRegions({
//   collection: conv, properties: ['classifica'], scale: 30, tileScale: 8});
// Export.table.toDrive({collection: sampled, folder: 'ghana_mining_gee_exports',
//   description: 'rs09_onset_vs_barenblitt', fileFormat: 'CSV'});
// -> score onset_year against 2000 + classifica in R (rs09 port).
