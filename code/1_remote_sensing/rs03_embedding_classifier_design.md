# rs03 — Galamsey Detection via Satellite Embeddings: Design Notes

**Status:** planning  
**Last updated:** 2026-06-09

---

## 1. Motivation

Barzin, Arezki & van der Ploeg (2026) show that ~84% of globally detected mines are absent from conventional datasets, with missing mines averaging 1.9 km² (vs 9.1 km² for recorded mines) — consistent with ASM being the bulk of undetected activity. Their workflow uses Google/DeepMind's AlphaEarth embeddings as the backbone. This script applies the same embedding approach to Ghana, using Barenblitt as ground truth to train a binary mine/no-mine classifier, then extrapolating annually across 2017–2024.

The output is a pixel-level annual mine presence panel for all Ghana at 10 m resolution — the primary input for Part 2 analysis once Part 1 is complete.

---

## 2. Data

### 2.1 Embedding source

**Google Satellite Embedding V1 Annual** (`GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL`)

- 64-band unit-length vectors (A00–A63), 10 m resolution
- Annual mosaics 2017–2024 (calendar year)
- Based on AlphaEarth Foundations v2.1 (Brown et al. 2025): fuses Landsat, Sentinel-1, Sentinel-2, and additional sensors via self-supervised learning
- Cloud-robust: trained across multi-temporal, multi-sensor observations
- Embedding properties: distributed on unit sphere → dot product = cosine similarity; suitable for kNN and tree-based classifiers without normalisation

### 2.2 Training labels

**Barenblitt 2019 extent** (`FullConversiontoMiningExtent2019.shp`)

- Artisanal (`minetype = 1`) and industrial (`minetype = 2`) polygons, SW Ghana
- Coverage ~104,730 km²; 75.6% producer accuracy (≈1 in 4 real mines missed)
- Aligns temporally with 2019 embedding year (best available year within dataset)

**Barenblitt 2007–2017 time series** (`MiningConversion_2007-2017Vec.shp`)

- Useful for validation at the 2017 embedding year (only year of overlap)

### 2.3 Coverage and temporal overlap

| Source | Spatial extent | Years |
|--------|---------------|-------|
| AlphaEarth embeddings | Global (10 m) | 2017–2024 |
| Barenblitt 2019 extent | SW Ghana only | 2019 (cross-section) |
| Barenblitt TS | SW Ghana only | 2007–2017 |

**Critical constraint:** Barenblitt TS and the embedding dataset share only 2017. The primary training alignment is 2019 embeddings × Barenblitt 2019 extent. We then apply the trained classifier to all years 2017–2024.

---

## 3. Proposed Workflow

### Step 1 — Construct training samples in GEE

**Positive class (mine):**
- Load Barenblitt 2019 artisanal polygons (`minetype = 1`) — industrial mines have very different spectral/structural signatures and may confuse the classifier; train on artisanal only, then inspect industrial hits as a sanity check
- Sample points within each polygon: use `ee$FeatureCollection$randomPoints()` inside each polygon, minimum 10 points per polygon or 1 point per 0.5 ha (whichever is larger), eroding polygon boundaries by ~20 m to avoid edge contamination
- Target ~2,000–4,000 positive pixels total

**Negative class (non-mine):**
- Primary negatives: random points within SW Ghana (Barenblitt convex hull study area) with a 200 m exclusion buffer around all Barenblitt polygons
- Supplementary hard negatives: points within the gold suitability polygon (`gold_suitable_geology.shp`) but outside Barenblitt coverage — these are geologically similar to mine areas but unlabelled, providing harder negatives that reduce false positives in suitable terrain
- Avoid using northern Ghana as negatives: geologically and optically different from SW Ghana, would give an artificially easy classifier
- Target a 1:3 positive:negative ratio (class imbalance manageable for RF)

**Caveat:** Barenblitt's 75.6% producer accuracy means ~25% of true mine pixels in SW Ghana are mislabelled as non-mining in our negative sample. This noise floor limits recall — we cannot train our way past Barenblitt's own detection ceiling without additional ground truth.

### Step 2 — Extract embeddings at training points

```javascript
// GEE pseudocode
var embedding = ee.ImageCollection("GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL")
  .filterDate("2019-01-01", "2020-01-01")
  .first();  // single annual mosaic

var training_samples = positives.merge(negatives);

var training_data = embedding.sampleRegions({
  collection: training_samples,
  properties: ["label"],   // 1 = mine, 0 = non-mine
  scale: 10,
  tileScale: 8             // reduce memory pressure over large areas
});
```

### Step 3 — Train classifier

**Recommended: Random Forest** (`ee.Classifier.smileRandomForest`)

- Handles class imbalance better than kNN via `bagFraction` tuning
- Returns probability scores (not just binary labels) via `.setOutputMode("PROBABILITY")`
- More robust than kNN to irrelevant embedding dimensions
- Consistent with Barzin et al.'s shallow neural network approach in spirit (non-linear, handles high-dimensional inputs)

**Alternative: kNN** as a cross-check (as per GEE tutorial); should give similar results given that embeddings are designed for kNN-compatible geometry on the unit sphere.

Suggested starting parameters: `numberOfTrees = 200`, `minLeafPopulation = 5`, `bagFraction = 0.7`.

### Step 4 — Generate annual probability maps

Apply trained classifier to each annual embedding mosaic 2017–2024:

```javascript
var years = ee.List.sequence(2017, 2024);
var annual_maps = years.map(function(yr) {
  var emb = ee.ImageCollection("GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL")
    .filterDate(ee.Date.fromYMD(yr, 1, 1),
                ee.Date.fromYMD(ee.Number(yr).add(1), 1, 1))
    .first();
  return emb.classify(classifier)
    .rename("mine_prob")
    .set("year", yr);
});
```

Export each year as a GeoTIFF at 10 m to Google Drive (same pattern as rs01/rs02).

### Step 5 — Threshold to binary + compute area

- Convert probability map to binary with a threshold (suggest starting at 0.5; tune via precision-recall on held-out Barenblitt polygons)
- For each hex/district/year: sum mine pixels × (10 m)² / 10,000 = mine area in ha
- This becomes the RS panel that replaces Barenblitt in Part 2 analysis scripts

---

## 4. Validation Strategy

**Spatial cross-validation** (critical — spatial autocorrelation inflates standard split accuracy):

- Divide the Barenblitt 2019 coverage into 5 spatial folds by district cluster
- Train on 4 folds, validate on 1; report average precision, recall, F1 across folds
- Do not use random 80/20 splits — nearby polygons share embedding context and produce overly optimistic metrics

**Temporal validation at 2017:**
- Apply 2019-trained classifier to the 2017 embedding
- Compare predicted mine presence against Barenblitt TS cumulative mining by 2017
- Measures temporal transferability (one step removed from training year)

**Metrics to report:**
- Precision and recall separately (recall matters more for our use case — we prefer catching more mines over false-positive minimisation)
- Area under precision-recall curve (AUPRC) — more informative than AUC-ROC under class imbalance
- Commission/omission rates by mine size class (small < 1 ha; medium 1–10 ha; large > 10 ha) — following Barzin et al.'s finding that small mines are hardest to detect

---

## 5. Key Risks and Open Questions

### 5.1 Temporal mismatch
Embeddings begin 2017; Barenblitt TS ends 2017. We are training primarily on 2019 cross-section data and projecting backwards to 2017. Sites that began mining 2018–2019 would be labelled as mines in training but correctly absent in 2017 predictions — this is not a bug but should be documented.

**Decision needed:** Should we restrict the training polygons to Barenblitt TS sites active by 2017 (using `classifica` year field), to maximise consistency with the 2017 validation year?

### 5.2 Artisanal vs industrial training labels
Including industrial mines (`minetype = 2`) in training will pull the classifier toward the distinctive visual signature of large open-pit operations (different spectral profile, tailings ponds, access roads). Recommend training on artisanal-only and treating industrial mine recovery as a secondary validation check.

### 5.3 Scale of galamsey sites
Many galamsey sites are small — Barzin et al. report missing mines average 1.9 km². At 10 m resolution a 1 ha site = ~100 pixels; a 0.1 ha site = ~10 pixels. The 64-band embedding encodes neighbourhood context as well as the focal pixel, which helps — but very small sites near dense forest will be challenging.

### 5.4 Spatial extrapolation beyond SW Ghana
Barenblitt covers SW Ghana only. Applying the classifier to all Ghana extrapolates to northern regions with different vegetation, geology, and land use. The classifier has no examples of northern-Ghana non-mining land and may generate false positives in areas with exposed laterite or bare soil (visually similar to mine surfaces). Consider masking predictions outside the Barenblitt study area or generating a separate confidence layer.

### 5.5 Embedding availability vs Barenblitt TS window
The 2007–2017 Barenblitt TS period predates AlphaEarth embeddings entirely. The RS panel from this approach will only cover 2017–2024. For the pre-2017 period the existing Barenblitt TS (or Landsat spectral indices from rs01) remains the primary source.

---

## 6. Implementation Plan

| Step | Script | Status |
|------|--------|--------|
| Construct training samples | `rs03_embedding_classifier.js` (GEE) | TODO |
| Extract embeddings + train RF | `rs03_embedding_classifier.js` | TODO |
| Export annual probability maps 2017–2024 | `rs03_embedding_classifier.js` | TODO |
| Download GeoTIFFs from Drive | `code/0_data/data_download.R` Section 7 | TODO |
| Threshold + compute area panel | `rs03_embedding_panel.R` | TODO |
| Validation / accuracy assessment | `rs03_embedding_classifier.js` + `rs03_embedding_panel.R` | TODO |

Note: GEE training/classification is done in JavaScript (`.js`); post-processing and panel construction in R.

---

## 7. Relationship to Existing Scripts

- `rs01_landsat_gee.R` — Landsat spectral index pipeline; independent but provides temporal context pre-2017
- `rs02_sentinel2_gee.R` — Sentinel-2 pipeline; independent
- `d01_barenblitt_districts.R` — The `mine_data` swap point: once `rs03_embedding_panel.R` produces a panel in the same format as Barenblitt TS, it replaces `barenblitt_ts_path` without rewriting downstream analysis
- `d04_motivating_facts.R` — Will benefit from the extended 2017–2024 panel for D3a (gold price correlation) and D4b (event-time trajectories)

---

## 8. References

- Brown et al. (2025). AlphaEarth Foundations. arXiv:2507.22291
- Barzin, Arezki & van der Ploeg (2026). Detecting Critical Mines: A Perspective from the Sky. FERDI WP372
- Barenblitt et al. (2021). [Barenblitt data source — see CLAUDE.md]
- GEE tutorial: Supervised classification with satellite embeddings (community tutorial 03)
