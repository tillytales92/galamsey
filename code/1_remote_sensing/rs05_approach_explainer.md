---
title: "Detecting galamsey with satellite embeddings: the rs05 approach"
subtitle: "How we build the labels, train the classifier, and prove it works — a plain-language companion to `rs07_labels.R` and `rs05_embedding_classifier.R`"
date: "2026-07-15"
author: "Ghana galamsey project · Till Meissner"
output:
  html_document:
    toc: true
    toc_float: true
    toc_depth: 2
    theme: readable
---

## 1. What we are trying to do

We want a **map of artisanal gold mining (galamsey) for every year 2017–2024**, covering the
south-west Ghana mining belt, built from satellite data. No such annual map exists: the best
available dataset (Barenblitt et al. 2021) stops in 2019, and every other mining inventory is a
one-off snapshot. The economic analysis in Part 2 of this project needs a *panel* — mining
presence by location by year — and rs05 is the machine that produces it.

The output of rs05 is one **probability raster per year** (each 10 m pixel gets a score
"how mine-like does this pixel look this year?"). A later step (`rs07_embedding_panel`)
thresholds those into binary mine/no-mine maps and aggregates them to the hex panel.

The whole approach stands on three legs, each covered below:

1. **Features** — what the classifier looks at (AlphaEarth satellite embeddings, §2)
2. **Labels** — how it learns what a mine looks like (`rs07_labels.R`, §4–5)
3. **Validation** — how we know whether to believe it (held-out SmallMinesDS + ablation, §7–8)

### Why not just use the existing mining shapefiles?

Global mining inventories already exist — Maus et al. (2022) and Tang & Werner (2023) both ship
Ghana polygons. Why build a classifier at all? The one-sentence answer: **they tell you *where*
mining ever was (as of ~2019–22); this pipeline tells you where it was *each year* — and the
economic analysis runs on the "each year".**

| | Maus / Tang & Werner shapefiles | This pipeline |
|---|---|---|
| **Time dimension** | One snapshot (Maus: 2019; Tang: undocumented mix ~2019–22) | Annual maps 2017–2024 → onset years, entry dynamics, stocks & flows |
| **Artisanal vs industrial** | No usable type attribute in Ghana (checked: Tang's commodity field is placemark junk there; Maus has no split) | Learns the *artisanal* class from Barenblitt's `minetype` flag |
| **ASM coverage** | Openly incomplete: Tang mapped ASM "case-study only"; Maus drew inside 10 km buffers of an industrial-mine registry | Generalises from the *signature* of mining — finds small riverine galamsey the inventories missed |
| **Accuracy** | Tang: no formal assessment at all; Maus: assessed, but not for ASM | Quantified against an independent expert test set (OA 84–88 %, PA/UA per model — §7–8) |
| **Consistency over time** | Splicing inventories confounds real change with differing mapping definitions | Same features, same model, every year — year-over-year change is meaningful |
| **Treatment intensity** | Polygon in/out only | Continuous probabilities → mined area per hex-year, dose–response designs |

The **time dimension is the decisive row**: event studies and Callaway–Sant'Anna cohorts need a
treatment *clock* — when did mining start here? — and a cross-sectional shapefile cannot supply
one at any price. Everything else is a real but secondary bonus.

And it isn't "our approach *versus* theirs": Maus and Tang are *inside* the pipeline as training
labels (§4). If the research question were merely "where has Ghana ever had mining, roughly as
of 2020?", the shapefiles would suffice and this pipeline would be over-engineering. It's the
panel dimension the analysis lives on that they cannot provide.

---

## 2. The features: AlphaEarth satellite embeddings

The classical remote-sensing route is to download raw imagery, fight through cloud masking
(SW Ghana averages ~83 % cloud cover), compute hand-picked spectral indices (NDVI, NDWI,
bare-soil…), and hope those indices capture what distinguishes a mine. We skip most of that by
using **Google's AlphaEarth embeddings** (Brown et al. 2025;
`GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL` in Earth Engine).

An embedding is a **64-number summary of everything the satellites saw at one 10 m pixel over
one calendar year** — Sentinel-2 optical, Sentinel-1 radar (which sees through cloud), thermal,
climate, terrain — compressed by a neural network that Google trained globally. Think of each
pixel getting a 64-dimensional "fingerprint" of its annual appearance and dynamics:

- pixels that look/behave alike (two mining ponds; two cocoa farms) get **similar
  fingerprints** — the vectors are unit-length, so similarity is simply a dot product
  (cosine similarity);
- the fingerprints are **consistent across years**, so a classifier trained on 2019 can be
  applied to any year 2017–2024;
- cloud robustness, multi-sensor fusion, and temporal aggregation are already baked in.

Our job reduces to something much smaller and more tractable: **teach a simple classifier which
fingerprints mean "galamsey"**. We use a random forest (200 trees) on the 64 bands — with
features this strong the choice of classifier is secondary (Brown et al.'s own benchmarks show
shallow models all perform similarly on these embeddings).

The catch: embeddings exist **only from 2017**. Anything earlier belongs to a separate
Landsat-based phase (see §9).

---

## 3. The pipeline at a glance

```
                        DATA (data/raw/)
   Barenblitt 2019   Maus 2022    Tang & Werner 2023    SmallMinesDS
   (RF map, SW      (global      (global polygons,      (expert masks,
    Ghana, has       polygons,    drawn on 0.15-10 m     Jan 2016 + Jan 2022)
    artisanal flag)  2019 mosaic) imagery ~2019-22)           |
        |               |               |                     | NEVER touches
        v               v               v                     | training
   +---------------------------------------------+           |
   | rs07_labels.R  (offline label harmonisation)|           |
   |  - erode polygons inward per source         |           |
   |  - salvage vanished small sites as points   |           |
   |  - union + 1 km buffer -> exclusion mask    |           |
   |  - extract validation points from the masks <-----------+
   +---------------------------------------------+
        |  data/processed/labels/*.rds
        v
   +---------------------------------------------+
   | rs05_embedding_classifier.R  (GEE, rgee)    |
   |  1 sample positives per source from its     |
   |    vintage-matched embedding year           |
   |  2 sample negatives outside exclusion mask  |
   |  3 ABLATION: RF per source combo + two      |
   |    similarity baselines, ALL scored on      |
   |    SmallMinesDS-2022  -> ablation table     |
   |  4 final RF (all sources) -> annual         |
   |    probability maps 2017-2024 -> Drive      |
   +---------------------------------------------+
        |  mine_prob_ghana_{2017..2024}.tif
        v
   rs07_embedding_panel (next step, not yet built):
   threshold -> optional NDWI pond corroboration ->
   min-patch filter -> vectorise -> hex x year panel
```

---

## 4. Getting to the labels (`rs07_labels.R`)

No single ground-truth dataset is good enough on its own, so we harmonise three **positive**
sources and hold a fourth back as the referee:

| Source | What it is | Coverage / vintage | Known weaknesses |
|---|---|---|---|
| **Barenblitt et al. 2021** | Random-forest mining map from Landsat, *the only source with an artisanal/industrial split* | SW Ghana, 2019 extent (+ 2007–17 series) | Producer accuracy 75.6 % → misses ~1 in 4 mines; itself a model output |
| **Maus et al. 2022 (v2)** | Hand-drawn "mining lands" polygons around known sites, global | Ghana subset (577 polygons), drawn on the **2019** Sentinel-2 mosaic | Broad definition (includes non-mine islands); 54.5 % of its validation errors sit < 50 m from polygon borders |
| **Tang & Werner 2023** | Hand-drawn mine-feature contours on 0.15–10 m Google Earth imagery, global | Ghana subset (1,907 polygons), **mixed vintage ≈ 2019–2022** | No formal accuracy assessment; positional RMSE 39.7 m; commodity attribute unusable in Ghana |
| **SmallMinesDS** (Ofori-Ampofo et al. 2025) | Dense expert ASGM masks, 10 m, two dated epochs | 5 SW districts, **Jan 2016 + Jan 2022** | Held out — used **only** for validation (§7) |

### The two geometric moves

Polygon *borders* are where all these datasets are least trustworthy (digitising slop,
positional error, mixed pixels). And *absence* of a polygon never means "no mining" — every
source has known omissions. rs07 turns both problems into geometry:

1. **Erode inward.** Training positives are sampled only from the polygon *core*: Maus shrunk
   by 50 m, Tang by 40 m (matching their measured error scales), Barenblitt kept as-is (its 30 m
   Landsat pixels are already coarse). Small sites that vanish under erosion — exactly the
   riverine galamsey shape we care about — are salvaged as a single interior **point** each
   (185 of them), rather than being lost.
2. **Buffer outward.** The union of **all raw footprints from all sources** (including
   industrial mines and every SmallMinesDS patch) plus a **1 km buffer** becomes the
   **exclusion mask** (~11,000 km², 4.6 % of Ghana). Negatives — examples of "not a mine" — are
   sampled only *outside* it. So a spot may only teach the model "this is what no-mining looks
   like" if *no dataset we have* places mining anywhere near it.

![](../../outputs/figures/rs05_explainer/fig1_erosion_exclusion_schematic.png)

The result: **9,690 positive polygons + 185 salvage points**, each carrying its source and
vintage. The full label set over Ghana (interactive version:
`outputs/figures/labels/labels_overview_map.html`):

![](../../outputs/figures/labels/labels_overview_map.png)

---

## 5. Vintage matching: labels must meet the right year

The label sources are snapshots from *different moments*, and galamsey moves fast — a 2019
polygon may be forest in 2017 and abandoned by 2022. Training a "2019 polygon" against a 2022
embedding would teach the model nonsense. So every source is paired with the embedding year
that matches when its imagery was actually taken:

- **Barenblitt & Maus → 2019 embeddings** (both are 2019 snapshots);
- **Tang & Werner → 2021 embeddings** (drawn on whatever Google Earth imagery was freshest,
  ≈ 2019–2022; 2021 is the midpoint);
- **SmallMinesDS Jan-2022 masks → score predictions made on 2022 embeddings**; the Jan-2016
  epoch predates the embeddings entirely and is reserved for the Landsat phase.

This is a point the SmallMinesDS paper makes explicitly: it criticises Maus and Tang & Werner
*by name* for lacking acquisition dates, "prohibiting their use as labels for machine
learning". Vintage-pairing is our answer to that critique.

![](../../outputs/figures/rs05_explainer/fig2_vintage_timeline.png)

---

## 6. Training (`rs05_embedding_classifier.R`)

With labels and features in place, training is deliberately simple:

| Ingredient | Choice | Why |
|---|---|---|
| Positive pixels | 2,000 Barenblitt + 1,000 Maus + 1,000 Tang | Barenblitt weighted up: it alone defines the *artisanal* target class |
| Negative pixels | 3 × positives, per vintage year, outside the exclusion mask | Class imbalance under control; negatives drawn from the same years as the positives they oppose |
| Sampling | Pixel locations drawn **locally in R** (area-weighted inside the label cores; negatives rejection-sampled outside the exclusion mask, max one point per 10 m pixel), then Earth Engine reads the embedding bands at those points | Keeps all geometry work where we control it exactly — and sending polygons to EE embeds their GeoJSON in every request, breaking the 10 MB payload limit. Study area = convex hull of Barenblitt positives + 10 km |
| Classifier | Random forest, 200 trees, on the 64 embedding bands | Strong-features/simple-model; probability output mode for the maps |
| Bookkeeping | Every training point keeps `source` + `vintage` properties | Enables the ablation (§8) and later spatial cross-validation |

The trained model is then applied to each year's embedding mosaic, 2017–2024, producing eight
probability maps.

---

## 7. Validation: how we know whether to believe it

### Why SmallMinesDS is the referee

Validating against your own training sources proves nothing (the pond-detection prototype had
exactly this circularity problem). SmallMinesDS is kept **strictly out of training** and makes
a good referee because its errors are plausibly *uncorrelated* with ours:

- different annotators and workflow (mean-shift segmentation + two cross-validating experts +
  per-block RF assist with human correction — independent of Barenblitt);
- different feature stack (Sentinel-2 + Sentinel-1 + DEM at patch level, not AlphaEarth);
- precisely dated (January 2022), so we know *which* embedding year it can judge.

### From masks to a test set

rs07 §12 converts the 2,135 held-out 2022 mask patches into point labels a GEE error matrix can
consume: per patch, up to 5 *core* mining pixels and up to 2 *core* non-mining pixels — "core"
meaning a 3×3 neighbourhood erosion per class, so no test point sits on a mask edge (mixed
10 m pixels). Both classes are then downsampled to the minority count, giving a **balanced test
set of 4,270 mining + 4,270 non-mining points**. Balance matters: on a wildly imbalanced test
set, overall accuracy rewards models that just say "no mine" everywhere.

### The numbers we report

For each model, the SmallMinesDS-2022 error matrix yields:

| Metric | Plain-language meaning |
|---|---|
| **OA** (overall accuracy) | share of all test points classified correctly |
| **kappa** | accuracy above what chance agreement would give |
| **mine PA** (producer's acc. / recall) | *of the true mines, how many did we find?* — misses = omission |
| **mine UA** (user's acc. / precision) | *of the pixels we call mine, how many really are?* — false alarms = commission |

PA and UA are the pair to watch: a model can trivially max one at the other's expense. The
script also prints an in-sample 80/20 split accuracy — ignore it except as a sanity check; a
random split leaks spatial structure and is always optimistic. The honest number is the
SmallMinesDS row.

---

## 8. The ablation: which labels actually help?

Because every training point is tagged with its source, we can train the same RF on different
label subsets and score each against the same held-out test set. One table answers several
standing questions at once (`outputs/tables/rs05_ablation_smallminesds2022.csv`):

| Row | Trains on | The question it answers |
|---|---|---|
| `barenblitt` | Barenblitt only | How far does the (model-derived) backbone alone go? |
| `maus` / `tang` | one hand-drawn source | Is either human inventory sufficient by itself? |
| `human` | Maus + Tang | Can we drop Barenblitt entirely — killing the circularity worry that we inherit its systematic errors? |
| `all` | all three | Does combining beat the best single source? (the default final model) |
| `sim_mean_*` | — (one-class) | Baseline: cosine similarity to the *mean* positive fingerprint — the original GEE "pond script" method, at three thresholds |
| `sim_max_*` | — (one-class) | Baseline: per-pixel *max* similarity over ~100 randomly chosen positive "prototypes" — the pond script's v3, effectively nearest-neighbour matching |

The similarity baselines matter for an honest comparison with the earlier prototype work: they
use **no negatives at all** — just "does this pixel resemble known mines?" If the RF can't
clearly beat them on SmallMinesDS, the extra machinery isn't earning its keep. (One subtlety:
`sim_max` thresholds are calibrated on positives that are *not* prototypes, because a prototype
matches itself with similarity ≈ 1.0 and would corrupt its own calibration.)

**Decision rule:** keep Barenblitt as training backbone *unless* the ablation shows
`human ≥ all` on mine PA/UA — i.e. the circularity concern is settled empirically, not by
argument.

---

## 9. Honest limitations

- **Circularity risk.** Barenblitt is itself a classifier output; training on it can inherit
  its systematic errors. Mitigations: the erosion step, the independent referee, and the
  ablation's `human` row as an explicit test.
- **The exclusion mask is not clean.** All sources have known omission (Maus PA ≈ 79 %, ASM
  under-sampled), so "outside the mask" still contains some unlabelled mining — some negatives
  are secretly positives. This biases the classifier towards *missing* mines, not inventing
  them.
- **SW Ghana only (for now).** The study area is the labelled belt; the north is unlabelled,
  not mine-free. Scaling up means widening `STUDY_BUFFER_KM` or swapping in the national
  boundary — and accepting that no validation data exists up there.
- **Nothing before 2017.** The embedding era starts 2017. The 1995/2000–2016 history is a
  separate planned phase (Landsat + CCDC/LandTrendr change detection), for which the
  SmallMinesDS Jan-2016 masks are being reserved as *its* validation set.
- **What a "mine" is differs by source.** Maus draws broad "mining lands", Tang draws tight
  feature contours, Barenblitt maps spectral conversion — the same site gets different
  footprints. Erosion narrows the gap but the definitions never fully align.
- **Licences.** Maus and SmallMinesDS are CC-BY-SA (share-alike): fine for internal
  training/validation; check before redistributing derived label datasets.
- **Not yet run.** As of 2026-07-15 the rewired rs05 script is written but awaits an
  interactive GEE run (`ee_Authenticate()` blocks on a browser login), so the ablation table
  and probability maps don't exist yet.

---

## 10. File map

| Piece | Path |
|---|---|
| Label harmonisation script | `code/1_remote_sensing/rs07_labels.R` |
| Classifier + ablation script | `code/1_remote_sensing/rs05_embedding_classifier.R` |
| Design notes (embedding classifier) | `code/1_remote_sensing/rs03_embedding_classifier_design.md` |
| Literature + feasibility review | `literature/rs/remote_sensing_overview.md` |
| Label artifacts | `data/processed/labels/labels_positives_{polygons,points}.rds`, `labels_exclusion_mask.rds`, `smallminesds_validation_points_{2016,2022}.rds`, `labels_qa.gpkg` |
| Label QA maps | `outputs/figures/labels/labels_overview_map.{png,html}` |
| Ablation table (after the GEE run) | `outputs/tables/rs05_ablation_smallminesds2022.csv` |
| Probability maps (after the GEE run) | `data/raw/embedding/mine_prob_ghana_{2017..2024}.tif` |

*Data sources: Barenblitt et al. (2021); Maus et al. (2022); Tang & Werner (2023);
Ofori-Ampofo et al. (2025); Brown et al. (2025). Document: Till Meissner.*
