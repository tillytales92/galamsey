// validate_probability_timeseries.js
// Paste into code.earthengine.google.com (project: rgee-auth-tillam).
//
// Visualise mine_prob_ghana_c4_{yr}_t** NATIONALLY (mosaic of every tile) across 2017-2025 --
// year slider scrubs through the probability surface for the whole country, rather than one tile
// at a time. Standalone/lightweight -- no ground-truth overlays, no deployed-mask comparison; see
// validate_finalproduct.js for the full comparison map (which also has this slider,
// alongside Barenblitt/Maus/Tang/SmallMinesDS outlines and the deployed c4 mask).

var EE_ASSET_HOME = 'projects/rgee-auth-tillam/assets/ghana_mining';
var PREFIX        = 'mine_prob_ghana_c4_';

var VIS = {
  min: 0, max: 100,
  palette: ['fcfdbf', 'fc8961', 'e45a31', 'b73779', '812581', '51127c', '2c115f', '000004']
};

// ---- year discovery (client-side, one listAssets call) --------------------
// Only years with at least one prob tile go on the slider, so a year mid-export doesn't error.
var allAssetIds = ee.data.listAssets(EE_ASSET_HOME).assets.map(function (a) { return a.id || a.name; });
var yearRe = new RegExp(PREFIX + '(\\d{4})_t');
var yrsFound = {};
allAssetIds.forEach(function (id) {
  var m = id.match(yearRe);
  if (m) yrsFound[m[1]] = true;
});
var YEARS = Object.keys(yrsFound).map(Number).sort();
if (YEARS.length === 0) YEARS = [2017, 2018, 2019, 2020, 2021, 2022, 2023, 2024, 2025];  // fallback
print('Years with prob tiles found:', YEARS);

// ---- national mosaic per year ----------------------------------------------
function nationalImage(yr) {
  var ids = allAssetIds.filter(function (n) { return n.indexOf('/' + PREFIX + yr + '_t') > -1; });
  return ee.ImageCollection(ids.map(function (id) { return ee.Image(id); }))
    .mosaic().rename('mine_prob');
}

// ---- map ---------------------------------------------------------------
Map.setOptions('SATELLITE');
Map.setCenter(-1.5, 7.0, 7);   // whole-country view, instead of centering on a single tile

var active = ui.Map.Layer(nationalImage(YEARS[0]), VIS, 'mine_prob ' + YEARS[0]);
Map.layers().add(active);

var label = ui.Label('Year: ' + YEARS[0], {fontWeight: 'bold'});
var slider = ui.Slider({
  min: 0, max: YEARS.length - 1, value: 0, step: 1, style: {width: '300px'}
});
slider.onChange(function (i) {
  var yr = YEARS[i];
  active.setEeObject(nationalImage(yr));
  active.setName('mine_prob ' + yr);
  label.setValue('Year: ' + yr);
});
Map.add(ui.Panel([label, slider], ui.Panel.Layout.flow('vertical'),
  {position: 'top-left', width: '340px'}));
