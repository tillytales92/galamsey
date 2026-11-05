// validate_industrial_coverage.js
// Paste into code.earthengine.google.com (project: rgee-auth-tillam).
//
// PURPOSE -- visual QA for the ICMM-point-driven industrial-mine exclusion recipe in
// build_03_embedding_panel.R Section 7 (reworked 2026-10-27, see that script's header), including
// the per-mine source + selection-mode table (IND_MINE_CONFIG) added the same day. Loads the four
// assets uploaded by upload_industrial_candidate_maus.R:
//   * industrial_final_selected_<date> -- the FINAL per-mine selection, i.e. exactly what build_03
//     actually keeps (before its own dissolve), each feature tagged mine/source/mode/area_km2. This
//     is the layer to trust.
//   * industrial_candidate_maus_<date> / industrial_candidate_tangwerner_<date> -- the RAW "anything
//     within IND_ICMM_BUFFER_M of an ICMM point" selection per source, kept as reference-only
//     (off by default) so you can see what the tighter per-mine modes (touching_only/contiguous/a
//     smaller buffer) excluded, mine by mine.
//   * icmm_points_ghana_<date> -- the 14 named Ghana mine points (reflects any manual location
//     correction, e.g. Prestea moved ~7 km 2026-10-27).
//
// Per-mine config as of 2026-10-27 (MUST mirror build_03 Section 3's IND_MINE_CONFIG -- edit both
// together, not just one):
//   Edikan, Asanko Obotan       -- Tang & Werner, "contiguous" (the touching polygon + its direct
//                                  neighbors only -- fixes these two "looking odd" with several
//                                  scattered, non-touching polygons under a plain buffer selection).
//   Prestea, Bogoso Prestea     -- "touching_only" (just the one polygon touching the point, Tang &
//                                  Werner / Maus respectively) -- NOTHING else, no buffer expansion.
//   Awaso, Obuasi               -- Maus, "buffer" but 1000 m instead of the 4000 m default.
//   everyone else (8 mines)     -- Maus, "buffer", 4000 m default -- visually confirmed fine.
// Why Maus vs Tang & Werner at all: Maus's matched polygon is implausibly oversized at Edikan/Asanko
// Obotan/Prestea (one single simple POLYGON each, not a multi-part dissolve artifact, confirmed by
// direct inspection -- an implausible bounding box for one mine, e.g. ~40x48 km at Edikan). Tang &
// Werner is NOT uniformly better though -- it's larger than Maus at Iduapriem/Damang/Wassa, which
// is why those stay on Maus.
//
// Also loads, as OPTIONAL off-by-default reference layers (no new upload needed):
//   * Gold mining leases (mining_leases_gold_<date>, upload_gold_leases.R) -- not part of the
//     exclusion recipe itself.
//   * Barenblitt mine_type==1 (gt_compare_barenblitt_raw) -- NOT subtracted from the candidate
//     (IND_ERASE_BAR_ART dropped to FALSE 2026-10-27) -- reference-only context.
//
// Pure geometry/coverage comparison, no S2/year machinery -- see validate_finalproduct.js /
// validate_cutoff_tuning.js for imagery-based QA. NOT YET RUN in the Code Editor -- rewritten
// 2026-10-27 for the per-mine mode table; paste in and check after the R upload script's assets land.

var ASSET_HOME   = "projects/rgee-auth-tillam/assets/ghana_mining";
var FINAL_ASSET  = ASSET_HOME + "/industrial_final_selected_2026-10-27";       // update date after re-running upload_industrial_candidate_maus.R
var MAUS_ASSET   = ASSET_HOME + "/industrial_candidate_maus_2026-10-27";       // "
var TW_ASSET     = ASSET_HOME + "/industrial_candidate_tangwerner_2026-10-27"; // "
var ICMM_ASSET   = ASSET_HOME + "/icmm_points_ghana_2026-10-27";               // "
var LEASES_ASSET = ASSET_HOME + "/mining_leases_gold_2026-10-23";              // update date after re-running upload_gold_leases.R

var finalSelected = ee.FeatureCollection(FINAL_ASSET);
var mausRaw       = ee.FeatureCollection(MAUS_ASSET);
var twRaw         = ee.FeatureCollection(TW_ASSET);
var icmmPoints    = ee.FeatureCollection(ICMM_ASSET);
var leasesGold    = ee.FeatureCollection(LEASES_ASSET);
var barArt        = ee.FeatureCollection(ASSET_HOME + "/gt_compare_barenblitt_raw")
                       .filter(ee.Filter.eq("mine_type", 1));
var GHANA         = ee.FeatureCollection(ASSET_HOME + "/rs05_ghana").geometry();

Map.setOptions("SATELLITE");
Map.centerObject(GHANA, 7);

Map.addLayer(leasesGold.style({color: "ffff00", fillColor: "00000000", width: 1}),
             {}, "Gold mining leases (reference only, not used in the exclusion)", false);
Map.addLayer(barArt.style({color: "33cc33", fillColor: "00000000", width: 1}),
             {}, "Barenblitt artisanal (mine_type==1, reference only -- no longer erased)", false);
Map.addLayer(mausRaw.style({color: "888888", fillColor: "88888855", width: 1}),
             {}, "Maus RAW (everything within the buffer, before the per-mine mode narrows it)", false);
Map.addLayer(twRaw.style({color: "9966cc", fillColor: "9966cc55", width: 1}),
             {}, "Tang & Werner RAW (everything within the buffer)", false);
Map.addLayer(finalSelected.style({color: "ff3300", fillColor: "ff330066", width: 2}),
             {}, "FINAL selection (what build_03 actually keeps)", true);
Map.addLayer(icmmPoints.style({color: "00ffff", pointSize: 6}),
             {}, "ICMM industrial-mine points", true);

// ---- stats: per-mine source/mode/count/area, straight from the FINAL layer's own properties. -----
var rows = finalSelected.getInfo().features.map(function (f) { return f.properties; });
var byMine = {};
rows.forEach(function (p) {
  byMine[p.mine] = byMine[p.mine] || {n: 0, km2: 0, source: p.source, mode: p.mode};
  byMine[p.mine].n += 1;
  byMine[p.mine].km2 += p.area_km2;
});
var mineNames = Object.keys(byMine).sort(function (a, b) { return byMine[b].km2 - byMine[a].km2; });
print("Per-mine FINAL selection (source/mode, n polys, total km2) -- dissolved national total will " +
      "be a bit less than the sum below if any two mines' buffers legitimately overlap:");
mineNames.forEach(function (m) {
  var b = byMine[m];
  print("  " + m + " [" + b.source + "/" + b.mode + "]: " + b.n + " poly(s), " + b.km2.toFixed(1) + " km2");
});
print("Sum of per-mine totals: " +
      rows.reduce(function (s, p) { return s + p.area_km2; }, 0).toFixed(1) + " km2 (not dissolved -- " +
      "see header; Iduapriem/Tarkwa's buffers overlap so their shared polygon is double-counted here)");

// ---- mine navigator -- filter the FINAL layer to ONE mine + zoom to its ICMM point --------------
var mineFeatures = icmmPoints.getInfo().features;   // 14 points, safe to pull client-side
var MINE_COORDS = {};
mineFeatures.forEach(function (f) {
  MINE_COORDS[f.properties.Mine_Name] = f.geometry.coordinates;
});

var highlightLayer = null;
var mineSelect = ui.Select({
  items: Object.keys(MINE_COORDS).sort(),
  placeholder: "jump to mine...",
  onChange: function (mine) {
    if (highlightLayer !== null) Map.layers().remove(highlightLayer);
    var subset = finalSelected.filter(ee.Filter.eq("mine", mine));
    highlightLayer = ui.Map.Layer(subset.style({color: "ffffff", fillColor: "ffffff88", width: 3}),
                                   {}, mine + " (highlighted)");
    Map.layers().add(highlightLayer);
    var xy = MINE_COORDS[mine];
    Map.setCenter(xy[0], xy[1], 13);
  },
  style: {position: "top-center"}
});
Map.add(mineSelect);

// ---- one-time info popup -- explains the map on launch, dismissible ---------------------------
var infoPanel = ui.Panel({
  widgets: [
    ui.Label("Industrial-mine exclusion QA (per-mine source + selection mode)", {fontWeight: "bold", fontSize: "16px"}),
    ui.Label("Red = the FINAL selection -- what build_03 actually keeps per mine (cyan points = the " +
             "14 ICMM mines driving it). Click a polygon -- the Inspector shows its mine, source " +
             "(maus/tangwerner), mode, and area."),
    ui.Label("Toggle the grey/purple RAW layers (layer list) to see everything that WASN'T kept at " +
             "the 6 mines using a tighter mode than the plain 4000 m buffer -- Edikan/Asanko Obotan " +
             "(contiguous), Bogoso Prestea/Prestea (touching-only), Awaso/Obuasi (1000 m buffer)."),
    ui.Label("Jump to a specific mine with the dropdown (top-center) -- highlights just that " +
             "mine's final polygon(s) in white and zooms in."),
    ui.Label("Toggle \"Gold mining leases\" / \"Barenblitt artisanal\" for context -- neither is " +
             "part of the exclusion logic itself.", {fontStyle: "italic", color: "666666"}),
    ui.Button({
      label: "Got it",
      onClick: function () { infoPanel.style().set("shown", false); }
    })
  ],
  style: {position: "bottom-center", width: "340px", padding: "10px", backgroundColor: "white"}
});
Map.add(infoPanel);
