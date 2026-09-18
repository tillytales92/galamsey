---
title: "Detecting galamsey with satellite embeddings: the build_02 approach"
subtitle: "How we build the labels, train the classifier, and prove it works — a plain-language companion to `build_01_labels.R` and `build_02_embedding_classifier.R` (with a short look at what happens after training, in `build_03`/`build_04`)"
date: "2026-09-15"
author: "Ghana galamsey project · Till Meissner"
output:
  html_document:
    toc: true
    toc_float: true
    toc_depth: 2
    theme: readable
---

## 1. What we are trying to do

We want a **map of artisanal gold mining (galamsey) across Ghana covering as many years as
possible — ideally the full 2000–2025 window**, not a single snapshot. No such map exists:
Barenblitt et al. (2021), the best available dataset, stops in 2019 and only covers the south-west;
every other inventory is a one-off. The economic analysis needs a *panel* — mining presence by
location by year — so getting the treatment clock right matters as much as spatial accuracy.

Two phases get us there. **2017–2025** is covered directly: Google's AlphaEarth satellite
embeddings only exist from 2017, so `build_02_embedding_classifier.R` trains a classifier on them
— one mine-probability raster per year. That's this document's main subject (§2–8). **2000–2016**
has no embeddings to classify, so `build_04_backdating.R` instead *dates* each already-known mine
pixel's vegetation-loss break in the older Landsat archive (§9). Earlier than 2000 is likely out of
reach (Landsat's cloud-free record thins out) and not yet decided.

### Why not just use the existing mining shapefiles?

Maus et al. (2022) and Tang & Werner (2023) already ship Ghana mining polygons. Why classify at
all? Because **they tell you *where* mining ever was, as a snapshot; this pipeline tells you where
it was *each year*** — and the economic analysis runs on the "each year".

| | Maus / Tang & Werner shapefiles | This pipeline |
|---|---|---|
| **Time dimension** | One snapshot (Maus 2019; Tang undocumented mix ~2019–22) | Annual, 2000–2025 (direct 2017–25, backdated 2000–16) |
| **Artisanal vs industrial** | No usable split for Ghana | Learns the artisanal class from Barenblitt's `minetype` flag |
| **ASM coverage** | Openly incomplete (Tang: case-study only; Maus: drawn around known industrial sites) | Generalises from the *signature* of mining — finds riverine galamsey the inventories missed |
| **Accuracy** | Tang: none assessed; Maus: assessed, not for ASM | Quantified against an independent expert test set (§7–8) |
| **Treatment intensity** | Polygon in/out only | Continuous probability → dose–response designs |

The **time dimension is decisive**: event studies need a treatment clock a cross-sectional
shapefile can't supply at any price. Everything else is a real but secondary bonus — and it isn't
"our approach *vs.* theirs": Maus and Tang are training labels *inside* this pipeline (§4).

---

## 2. The features: AlphaEarth satellite embeddings

Instead of raw imagery, cloud masking (SW Ghana averages ~83% cloud cover), and hand-picked
spectral indices, we use **Google's AlphaEarth embeddings** (Brown et al. 2025;
`GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL`). Each 10 m pixel gets a **64-number summary of everything
the satellites saw that year** — Sentinel-2 optical, Sentinel-1 radar (sees through cloud),
thermal, climate, terrain — compressed by a globally-trained neural network. Similar-looking
pixels get similar 64-dimensional fingerprints (unit-length vectors, so similarity = cosine
similarity), fingerprints are consistent across years, and cloud robustness / multi-sensor fusion
are already baked in.

Our job shrinks to something tractable: **teach a classifier which fingerprints mean "galamsey."**
We use a random forest (100 trees, §6) on the 64 bands — with features this strong, the classifier
choice is secondary (confirmed by our own tree-count sweep, §6, and Brown et al.'s benchmarks).

The catch: embeddings only exist from 2017 — hence the separate backdating phase (§9) for 2000–2016.

---

## 3. The pipeline at a glance

```
   Barenblitt 2019   Maus 2022    Tang & Werner 2023    SmallMinesDS
        |               |               |               (held out, never
        v               v               v                trains anything)
   +-----------------------------------------------------+   |
   | build_01_labels.R -- erode, salvage, exclusion mask, |   |
   |   extract validation points from the masks <--------------+
   +-----------------------------------------------------+
        v  data/processed/labels/*.rds
   +-----------------------------------------------------+
   | build_02_embedding_classifier.R (GEE, rgee)          |
   |  sample + tag positives/negatives -> ABLATE 3 class   |
   |  schemes x 6 source combos (18 runs) on SmallMinesDS  |
   |  -> c4/no_maus wins -> final national RF -> annual    |
   |  probability tiles, 2017-2025                         |
   +-----------------------------------------------------+
        v  mine_prob_ghana_c4_{2017..2025}_t{NN}
   +-----------------------------------------------------+
   | build_03_embedding_panel.R -- threshold (cutoff 70)   |
   | + urban/water/road knockouts -> annual BINARY mask    |
   +-----------------------------------------------------+
        v  mine_mask_ghana_c4_{2017..2025}
   +-----------------------------------------------------+
   | build_04_backdating.R -- Landsat 1999-2018 ->         |
   | LandTrendr -> per-pixel ONSET YEAR, 2000-2016          |
   +-----------------------------------------------------+
        v  mine_onset_year_2000_2016_{method}
   [not yet built] merge into one 2000-2025 surface -> hex x year panel
```

§9 covers the last two boxes in plain language. `code/1_remote_sensing/explainer.md` has current
status/config for every script — check there for what's actually run vs. pending.

---

## 4. Getting to the labels (`build_01_labels.R`)

No single source is good enough alone, so we harmonise three **positive** sources and hold a
fourth back as referee:

| Source | What it is | Coverage / vintage | Known weaknesses |
|---|---|---|---|
| **Barenblitt et al. 2021** | RF mining map from Landsat; only source with artisanal/industrial split | SW Ghana, 2019 (+2007–17 series) | Producer accuracy 75.6% → misses ~1 in 4 mines; itself a model output |
| **Maus et al. 2022 (v2)** | Hand-drawn "mining lands" polygons, global | Ghana (577 polys), 2019 mosaic | Broad definition; 54.5% of errors sit <50m from borders |
| **Tang & Werner 2023** | Hand-drawn contours on 0.15–10m imagery, global | Ghana (1,907 polys), mixed ~2019–22 | No accuracy assessment; positional RMSE 39.7m |
| **SmallMinesDS** (Ofori-Ampofo et al. 2025) | Dense expert masks, 10m, two epochs | 5 SW districts, Jan 2016 + Jan 2022 | Held out — validation only (§7) |

Polygon *borders* are the least trustworthy part of every source, and *absence* never means "no
mining." Two geometric fixes:

1. **Erode inward** — positives sampled only from polygon cores (Maus −50m, Tang −40m, matching
   their error scales; Barenblitt kept as-is). Small sites that vanish under erosion are salvaged
   as interior points (185 of them) instead of lost.
2. **Buffer outward** — the union of *all* raw footprints (incl. industrial + SmallMinesDS) + 1 km
   becomes an **exclusion mask** (~11,000 km², 4.6% of Ghana); negatives are sampled only outside
   it, so a spot only teaches "not a mine" if no source places mining anywhere near it.

![](../../outputs/figures/embedding_classifier_explainer/fig1_erosion_exclusion_schematic.png)

Result: **9,690 positive polygons + 185 salvage points**, each tagged with source + vintage
(interactive map: `outputs/figures/labels/labels_overview_map.html`).

![](../../outputs/figures/labels/labels_overview_map.png)

---

## 5. Vintage matching

Sources are snapshots from different moments, and galamsey moves fast — a 2019 polygon may be
forest in 2017. Training a "2019 polygon" against a 2022 embedding teaches nonsense, so each
source is paired with the embedding year matching its imagery: **Barenblitt & Maus → 2019**,
**Tang → 2021** (midpoint of its ~2019–22 mixed vintage), **SmallMinesDS Jan-2022 → scored against
2022 predictions** (its Jan-2016 epoch predates embeddings and is reserved for backdating, §9).
SmallMinesDS itself criticises Maus/Tang by name for lacking acquisition dates; vintage-pairing is
our answer to that.

![](../../outputs/figures/embedding_classifier_explainer/fig2_vintage_timeline.png)

---

## 6. Training (`build_02_embedding_classifier.R`)

The classifier learns **four classes** (`other`/`mine`/`urban`/`water`), not just mine-or-not —
splitting off the two most common confusable land covers measurably improved mine-probability
calibration (tested, not assumed — see §8). Every training pixel is tagged with two confounder
layers (GHSL 10m `built_surface`, JRC water `occurrence`) and assigned a class by priority: **mine
always wins** (a labelled positive stays a positive even on built-up/wet ground), then water beats
urban (a more unambiguous signal), then urban, then other. *These 10m training-time thresholds are
a different device from `build_03`'s 100m deployment-time urban mask (§9) — don't conflate them.*

| Ingredient | Choice | Why |
|---|---|---|
| Positives | 2,000 Barenblitt + 1,000 Maus + 2,000 Tang (per vintage year) | Barenblitt anchors the artisanal class; Tang matched to Barenblitt's count |
| Negatives | 3× positives, per vintage year, outside the exclusion mask | Controls class imbalance; same-year as the positives they oppose |
| Sampling | Locations drawn locally in R, embeddings read via EE | Avoids the 10 MB payload limit polygon uploads hit |
| Classifier | Random forest, 100 trees, 64 embedding bands | A tree-count sweep found 100–200 indistinguishable (OA within 0.03pt); 100 halves inference cost |

The deployed **national** model adds northern positives (capped at 500/source — testing whether the
classifier catches mining the existing datasets miss up there) and swaps in nationally-sampled
negatives (not added to the SW ones, to avoid double-weighting the SW belt). Northern predictions
are consequently **unvalidated** — no reference data exists there (§10).

---

## 7. Validation: SmallMinesDS as referee

Validating against your own training sources proves nothing. SmallMinesDS stays **strictly out of
training** and makes a good referee: different annotators/workflow, a different feature stack
(Sentinel-2/1 + DEM, not AlphaEarth), and it's precisely dated (Jan 2022).

`build_01` converts its 2,135 held-out mask patches into point labels — up to 5 *core* mining +
2 *core* non-mining pixels per patch (eroded 3×3, so no point sits on a mixed edge pixel) —
downsampled to a **balanced 4,270 + 4,270 test set** (an imbalanced set would reward models that
just say "no mine" everywhere). All four schemes (§8) are scored against this same binary mask, so
predicting urban/water/other all count equally as "not mine."

We report **OA** (overall accuracy), **kappa** (above-chance accuracy), **mine PA**
(producer's/recall — of true mines, how many found?), **mine UA** (user's/precision — of flagged
pixels, how many are real?). PA and UA trade off against each other (§8) — the script's in-sample
80/20 split accuracy is a sanity check only, always optimistic; the SmallMinesDS row is the honest
number.

---

## 8. The ablation: which scheme, which labels, and which cutoff?

Every training point is tagged with its source, and the pipeline trains three class schemes, so the
ablation is **18 runs** (3 schemes × 6 source combos), not 6 — verifying the winning combo per
scheme rather than assuming binary's answer carries over (`outputs/tables/rs05_ablation_smallminesds2022.csv`).

**Scheme comparison is not a raw-cutoff comparison.** A 4-class model's mine-probability competes
against three other classes, so its values run systematically lower than binary's for the same
underlying confidence. `build_02` §7c instead sweeps each scheme's winning combo across 0–100 and
compares at **matched precision** (same UA, compare PA):

| Target UA | binary PA | c3 PA | **c4 PA** | (c4's threshold) |
|---|---|---|---|---|
| 0.90 | 0.890 | 0.877 | **0.894** | 36 |
| 0.92 | 0.817 | 0.808 | **0.819** | 47 |
| 0.93 | 0.780 | 0.758 | **0.771** | 54 |
| 0.94 | 0.687 | 0.683 | **0.689** | 64 |

**c4 wins at every precision level** (c3 is even worse than binary — plausibly urban-only dilutes
probability without water's extra separating power). Within c4, **`no_maus`** (Barenblitt + Tang)
is the deployed combo: OA 0.891, mine PA 0.870, mine UA 0.907. It doesn't *dominate* `all` on both
metrics — it trades some recall for precision — but the project has an established
precision-favouring preference, so `no_maus` was chosen on the UA gain.

### The PA/UA trade-off is a real choice, not a detail

The table above **is** the deployment decision, not just a scheme comparison: its `threshold`
column is literally the probability cutoff you'd pick to hit a given UA. Higher cutoff → fewer
false alarms, more missed mines; lower cutoff → the reverse. There is no single "correct" cutoff —
it depends on what the map is for (a coarse hex-level "was this cell ever mined" indicator can
tolerate more false positives than a precise treatment-intensity measure).

The table only sweeps up to UA 0.94 (cutoff 64) on the *balanced* SmallMinesDS test set.
`build_03`'s actual deployed cutoff is **70** — higher than anything tested here — because
national-scale QA (comparing flagged area against Barenblitt across all of Ghana, not a balanced
5-district test set) found even cutoff 64 still let through too much diffuse false-positive area.
At cutoff 70, recall within the Barenblitt hull is 0.84. So the cutoff actually used reflects a
second, deployment-scale check beyond this table, not just a read-off from it — see `build_03` in
§9 and `explainer.md` for the full reasoning.

*(A similarity-baseline comparison — the earlier pond-detection prototype's no-negatives
cosine-similarity method — was planned as a sanity check but never run; see §10.)*

---

## 9. After training: from probability maps to a mine panel

Full technical detail lives in `code/1_remote_sensing/explainer.md`; here's the shape of it.

**`build_03_embedding_panel.R`** turns annual probabilities into a binary mine mask. A probability
alone isn't a map — some cutoff has to separate "mine" from "not" (§8), and raw imagery still
confuses cities, water, and roads with mining at the margin. So build_03: mosaics each year's
tiles, thresholds at **70**, then subtracts three more confusions a single threshold can't
separate — built-up land (a 100m time-matched layer, distinct from §6's 10m training-time tags),
permanent water, and a road buffer. Industrial-mine exclusion is designed but temporarily deferred
(a data-quality issue in the lease-boundary source).

**`build_04_backdating.R`** dates each already-known mine pixel's vegetation-loss break in the
older Landsat archive, using LandTrendr segmentation (not a classifier — there's no
embedding-equivalent feature set that far back) to assign onset years 2000–2016. It also validates
against Barenblitt's own separately-estimated conversion years for the overlapping period.

Together, an annual mask (2017–2025) plus onset years (2000–2016) is what should eventually become
the RS mine panel replacing Barenblitt as this project's `mine_data` source. The merge-and-panel
step itself is not yet built.

---

## 10. Honest limitations

- **Circularity risk**: Barenblitt is itself a model output; training on it can inherit its
  errors. Mitigated by erosion, the independent referee, and the `human`/`no_maus` ablation rows.
- **Exclusion mask isn't clean**: every source has known omissions, so some "negatives" outside
  the mask are secretly positives — biases the classifier toward *missing* mines, not inventing them.
- **SW validated, north is not**: the final model is extended nationally specifically to test for
  northern mining the existing datasets miss, but no reference data exists there to check it.
- **Nothing before 2000 (probably)**: 2000–2016 comes from LandTrendr change-detection, not
  classification (§9); CCDC was considered and rejected (too few clear Landsat observations/year
  pre-2017). Only pixels still visibly mined in 2017+ ever get backdated — a mine that opened and
  fully revegetated before 2017 is invisible to this whole pipeline.
- **Definitions differ by source**: Maus draws broad "mining lands", Tang tight contours,
  Barenblitt spectral conversion — erosion narrows but doesn't erase the gap.
- **Licences**: Maus and SmallMinesDS are CC-BY-SA — fine internally, check before redistributing.
- **Status as of 2026-09-15**: ablation (§8) settled and deployed; all 153 probability tiles
  (2017–2025 × 17 tiles) complete. `build_03` masks exported 2017–2024, 2025 queued (EE
  noncommercial compute quota exhausted, resets 2026-10-01). `build_04`'s two methods are
  implemented and bug-fixed (2026-09-14) but not yet validated end-to-end — its
  Barenblitt-conversion-year cross-check needs 6 uploaded point-asset chunks, 2 landed so far, rest
  queued behind the same quota limit. Not yet run: the similarity-baseline ablation rows, spatial
  cross-validation.

---

## 11. File map

| Piece | Path |
|---|---|
| Label harmonisation | `code/1_remote_sensing/build_01_labels.R` |
| Classifier + ablation | `code/1_remote_sensing/build_02_embedding_classifier.R` |
| Panel post-processing (cutoff/masks) | `code/1_remote_sensing/build_03_embedding_panel.R` |
| Backdating (2000–2016) | `code/1_remote_sensing/build_04_backdating.R` |
| Design notes (archived) | `notes/archive/rs03_embedding_classifier_design.md` |
| Literature review | `literature/rs/remote_sensing_overview.md` |
| Label artifacts | `data/processed/labels/labels_positives_{polygons,points}.rds`, `labels_exclusion_mask.rds`, `smallminesds_validation_points_{2016,2022}.rds` |
| Label QA maps | `outputs/figures/labels/labels_overview_map.{png,html}` |
| Ablation table (18 rows) | `outputs/tables/rs05_ablation_smallminesds2022.csv` |
| Matched-precision comparison | `outputs/tables/class_scheme_matched_precision_comparison.csv` |
| Tree-count sweep | `outputs/tables/ntrees_ablation_c4_no_maus.csv` |
| Probability tiles (deployed) | EE assets `mine_prob_ghana_c4_{2017..2025}_t{01..17}` |
| Annual binary masks | EE assets `mine_mask_ghana_c4_{2017..2024}` (2025 pending) |
| Backdated onset years | EE asset `mine_onset_year_2000_2016_{landtrendr,barenblitt}` (pending validation) |
| Full script-by-script status | `code/1_remote_sensing/explainer.md` |

*Data sources: Barenblitt et al. (2021); Maus et al. (2022); Tang & Werner (2023);
Ofori-Ampofo et al. (2025); Brown et al. (2025). Document: Till Meissner.*
