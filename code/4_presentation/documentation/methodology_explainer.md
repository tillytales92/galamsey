# Methodology — explainer

This document explains the **methods** behind the analysis, with an emphasis on what each method
*shows* and, just as importantly, what it *does not* show. It is the conceptual companion to the
figures in `galamsey_motivation.qmd`. Wherever a method is implemented, the script and section are
named so the code can be found.

Everything below operates on a **hexagonal grid** clipped to the Barenblitt SW-Ghana study area
(convex hull of the 2019 mining extent, clipped to Ghana). The **5 km grid is the headline**; 1 km
and 2 km are used for robustness. Spatial weights are **queen contiguity, row-standardised**, built
once per resolution in `b_01_cross_section.R` and cached in `hex_{N}km_crosssection.rds` as the
`spdep` objects `nb`/`lw`.

Two data caveats colour every result and are repeated on the relevant slides:
- **Barenblitt covers SW Ghana only** (~104,730 km²) — absence in northern districts means "not
  surveyed", not "no mining".
- **Producer accuracy is 75.6%** — ~1 in 4 real mines were missed, so Barenblitt is used as
  positive labels only, never as clean negatives.

---

## 1. Spatial clustering

The empirical question of Part 1 is: **is galamsey spatially clustered, and if so, why?** "Clustered"
means mine-heavy hexes sit next to other mine-heavy hexes more than chance would predict. The danger
is that clustering is trivially explained by clustered *geography* — gold-bearing rock and river
networks are themselves spatially autocorrelated, so mining that merely tracks geology would look
clustered without any social/economic spillover. The whole clustering section is built to separate
these two explanations.

The tools, in order of the argument:
1. **Global Moran's I** — is there clustering at all? (§2)
2. **LISA** — *where* are the hot/cold spots? (§3)
3. **Partialling-out + the geography-weighted null** — does clustering survive controlling for
   geography? (§4, the decomposition + simulation)
4. **The M1→M5 model ladder** — is that geography control strong and robust to grain and to omitted
   smooth geography? (§5–§7)
5. **The spatial lag model** — does mining beget neighbouring mining over time? (§8)

Implemented in `a_02_spatial_clustering.R` (sections D2*) and `a_03_firststage_diagnostics.Rmd` +
its compute script `b_02_firststage_models.R`.

---

## 2. Global Moran's I

**What it is.** Moran's I is the spatial analogue of a correlation coefficient: it measures whether a
variable's value at each hex co-varies with the (weight-averaged) value at its neighbours. Formally,
for a variable `x` with row-standardised weights `w_ij`:

```
      N     Σ_i Σ_j w_ij (x_i - x̄)(x_j - x̄)
I  = ---- · --------------------------------
      W            Σ_i (x_i - x̄)²
```

I ≈ +1 = strong positive clustering (high next to high, low next to low); I ≈ 0 = spatial randomness;
I < 0 = a checkerboard. Significance is assessed against the analytic null (`spdep::moran.test`).

**How it's used here** (`a_02` D2a):
- **By year** on annual *new* mining (ha), 2007–2017 — a time series of `moran_I` with a ±1.96 SD
  band, showing clustering is present and roughly stable through the sample
  (`d2a_morans_by_year`).
- **Full-series summary** on cumulative and 2019-extent measures, split artisanal / industrial /
  all-types (`d2a_morans_total`). Observed I on binary artisanal presence at 5 km is ≈ **0.49**.

**What it shows:** that galamsey is *significantly, positively clustered* — not randomly scattered.

**What it does NOT show:** *why*. A high Moran's I is equally consistent with (a) social/economic
spillover and (b) mining passively tracking spatially-autocorrelated geology. It is a description of
the pattern, not its cause. It is also a single global number — it says nothing about *where* the
clusters are (that is LISA) or whether clustering *grows over time* (that is the lag model).

---

## 3. LISA — Local Indicators of Spatial Association

**What it is.** LISA (local Moran's I, `spdep::localmoran`) decomposes the global statistic into a
per-hex contribution, so each hex can be classified by the sign of its own value and its neighbours'
average, when locally significant (p < 0.05):

- **HH** — high value surrounded by high (a mining **hotspot**)
- **LL** — low surrounded by low (a cold spot / empty region)
- **HL** / **LH** — spatial outliers (a mining hex amid empty neighbours, or vice versa)

**How it's used here** (`a_02` D2a, `d2a_lisa_2017`): a quadrant map of the 2019 artisanal extent,
`hex_z` vs its spatial lag, coloured by the four categories. (It uses the 2019 cross-section because
the 2007–2017 time series shapefile carries no mine-type field.)

**What it shows:** the *geography of the clusters* — which specific hexes form significant mining
hotspots and where the empty cold spots are.

**What it does NOT show:** causation (same caveat as global Moran's I), and it is a cross-sectional
snapshot — it does not track how a hotspot forms or spreads.

---

## 4. The decomposition and the geography-weighted null (the simulation exercise)

This is the heart of the "why clustered?" argument. It decomposes the observed clustering:

```
I_observed  =  I_geography  +  I_excess
```

`I_geography` = the clustering you'd expect if mines were located purely by geography;
`I_excess` = the part left over, which geography cannot explain. The claim is that `I_excess` is
large — evidence of a social/economic spillover process.

**Step 1 — partialling out (`a_02` D2b).** Regress artisanal mining share on geography
(`gold_suit_share`, then `+ dist_river_km`) with OLS, take the residuals, and recompute Moran's I on
them. If the residual Moran's I stays high, geography did not "soak up" the clustering. This is the
transparent, linear version of the decomposition.

**Step 2 — the geography-weighted null simulation (`a_02` D2bc; the "simulation exercise").** The
rigorous version. The logic:

1. Fit a **logistic first stage** of binary mine presence (`any_art`) on geography — *with no
   spatial term* (no circularity: we never tell the model about neighbours).
2. Take the fitted probabilities as **assignment weights**. Simulate a mine allocation by drawing
   `n_mine` hexes with probability ∝ their fitted geography propensity, place mines there, and
   compute Moran's I of that synthetic pattern.
3. Repeat 500 times → a **null distribution** of Moran's I values that arise *only* because geology
   and rivers are themselves spatially autocorrelated. There is no spillover in this data-generating
   process by construction.
4. Compare the **observed** Moran's I to that null. `p_excess` = share of null draws ≥ observed.

Four nulls are built with progressively richer weights — uniform, geology-only, river-only, and
joint — so you can see clustering survive each control. The headline result: the observed value
(≈0.49) lies **beyond every one of 500 draws** even under the joint geography null → `p_excess ≈ 0`.

**What it shows:** the observed clustering is **not** an artefact of spatially-autocorrelated
geography. Mines cluster *more* than geology + rivers can manufacture, which is the signature of a
spillover / agglomeration process.

**What it does NOT show:**
- It does not, by itself, prove *social/economic* spillover specifically. Any **omitted spatial
  driver** the first stage lacks (economic, institutional, historical) could in principle inflate
  `I_excess`. §5–§7 (the ladder, MAUP, and the spline) exist precisely to shrink this loophole.
- It is cross-sectional — it cannot separate genuine contagion from an omitted covariate that
  happens to cluster. Only the temporal dimension (does mining at *t* predict *new* mining nearby at
  *t+1*?) can do that (see §8, and the honest limitation noted in `a_03` Part C).
- `p_excess ≈ 0` means "beyond the null", not a point estimate of the spillover magnitude.

---

## 5. The M1 → M5 model ladder

The credibility of the geography-weighted null hinges on the first stage being a **strong, honest
geography control**. A near-useless first stage would collapse the geography null onto the uniform
null, making the gap meaningless. So the geography model is climbed as a **nested ladder** (each a
strict superset of the last), fit on the 1/2/5 km grids in `b_02_firststage_models.R` and presented
in `a_03_firststage_diagnostics.Rmd`.

| Model | Specification | What it adds |
|-------|--------------|--------------|
| **M1** | `any_art ~ gold_suit_share + dist_river_km` | Baseline (the original D2bc weight model) |
| **M2** | + `ns(dist_river_km, 4)` (replaces linear) + spatial lags of both covariates | Non-linear river distance + neighbourhood smoothing — no new data |
| **M3** | + `elev_mean + slope_mean` | Exogenous terrain (alluvial mining favours flat, low ground) |
| **M4** | + geology×river + geology×slope + geology×elev + river×slope | Mechanism conjunctions (gold source × depositional setting) |
| **M5** | M4 + `s(easting_km, northing_km)` thin-plate spline | Absorbs *all* smooth spatial structure — the most conservative null (§7) |

Each fitted glm produces a geography-weighted null (§4), so as the model strengthens the null gets a
*more* generous chance to explain the clustering. The finding is that **`p_excess` stays ≈ 0 at every
rung and every grain** — clustering survives even the richest measured-geography control.

**Fit metrics and how to read them** (`a_03` Part A): **AUC** is the cross-grid metric (rank-based,
prevalence-robust); **McFadden R² / Brier** are prevalence-sensitive so are compared only *within* a
grid; **AIC** only within a grid (nested, same n). Terrain (the M2→M3 step) is the biggest single AUC
jump — the weak baseline was an *information* problem (coarse Girard geology), not a functional-form
one.

**What the ladder shows:** the geography control is strong and its strength is not a grain artefact;
which *interaction* carries M4 changes with grain (Appendix A1) but the verdict does not.

**What it does NOT show:** an *unmeasured* geographic driver could still exist — which is exactly what
M5 (§7) is built to address, and even M5 has a residual limitation (§7).

---

## 6. MAUP robustness (why 1/2/5 km)

The **Modifiable Areal Unit Problem**: results computed on areal units can be an artefact of the
chosen zoning/grain. `a_03` re-runs the *entire* ladder + null on 1, 2, and 5 km hexagons.

**How to read it correctly** (spelled out in `a_03`): MAUP guarantees *levels* move with grain —
finer grids have lower mine prevalence and higher AUC. The raw Moran's I is *not* fixed in direction:
for galamsey it tends to **rise** at finer grain (5 km cells average mined valleys with unmined
hillslope, diluting the signal; 1 km hexes resolve tight mine clusters against empty neighbours,
sharpening local contrast). Meanwhile the null tightens (more observations → less simulation
variance). So the observed–null gap can *widen* at finer grain. The robust claim is therefore about
the **verdict** (`p_excess ≈ 0`, observed ≫ null-95), not the raw I level — and the verdict holds at
all three grains. If anything the excess-clustering result strengthens as grain refines.

**One caveat:** Girard gold-suitability geology is 1:10M scale — no meaningful signal below ~5 km. So
`gold_suit_share` is a valid covariate at 5 km but is dropped / down-weighted at 1–2 km.

---

## 7. How the spatial spline (M5) works

M1–M4 control for **measured** geography. The residual worry is an **omitted but spatially smooth**
driver (economic, institutional, historical) that could manufacture the excess clustering. M5
confronts this by adding a **thin-plate regression spline on the hex centroid coordinates** to the
richest measured model:

```
logit P(mine_i)  =  X_i β   +   f(easting_i, northing_i)
                    ‾‾‾‾‾‾       ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
                  M4 covariates   smooth 2-D spatial surface
```

`f(·)` is fit with `mgcv::gam` (`bs = "tp"`, basis size `k = 60`; result unchanged at `k = 100`). It
is a flexible surface that **absorbs any smooth spatial variation, measured or not** — it lets *pure
location* soak up whatever the named covariates miss. That makes the resulting geography-weighted
null the most conservative one available: it now *expects* far more clustering (the null distribution
shifts sharply right), yet the observed Moran's I still lies beyond it (`p_excess = 0` at both 5 km
and 2 km). Run at 5 km and 2 km only (the GAM + null simulation is costly at 1 km); kept out of the
cross-grid MAUP tables because it is a *different* robustness axis (omitted geography, not grain).

The fitted surface itself is mapped in `a_03` Part C — the mining propensity attributable to
**location alone**, net of geology/river/terrain (red = more mining than measured geography predicts).

**What M5 shows:** the excess clustering is **not attributable to any smooth confounder**, measured
or unmeasured. This is the strongest form of the "geography can't explain it" claim the
cross-section can deliver.

**What M5 does NOT show — the honest limitation** (stated explicitly in `a_03` Part C): a spline can
only represent *smooth* variation. The remaining observed–null gap is short-range clustering that is
finer-grained than any smooth surface, and **two explanations remain observationally equivalent**
in a cross-section:
1. **Genuine spatial contagion** — mining raises the chance of mining at an immediate neighbour
   (labour/equipment moving short distances, miners following a discovery, propagation along one
   channel). *This is the spillover reading.*
2. **A non-smooth sub-grid covariate** — a real driver that changes abruptly between adjacent hexes
   (an ore vein, a fault, one road, a concession boundary) that no smooth surface can absorb.

M5 **cannot separate (1) from (2)** — the classic true-vs-apparent-contagion problem. Doing so needs
the **temporal** dimension (neighbour mining at *t* → new conversion at *t+1*), which is what the
event study (§9) and the spatial lag model (§8) bring. (A further caveat: `gold_suit_share` is itself
smooth and collinear with the spline, so the split of smooth signal between covariate and surface is
not perfectly clean — read the surface qualitatively.)

---

## 8. The spatial lag model

**What it is** (`a_02` D2d). A panel regression that adds the *time* dimension the cross-sectional
clustering tools lack. For each hex × year it builds the **spatial lag of cumulative mining at t−1**
— the neighbour-weighted mining stock in surrounding hexes the year before — and regresses current
mining on it with two-way fixed effects:

```
mine_ha_it   =  ρ · (spatial lag of neighbour stock)_{i,t-1}  +  α_i + γ_t + ε_it
```

Two outcomes: annual new mining (ha) in levels, and an any-new-mining LPM. Hex FE (`α_i`) absorb all
time-invariant hex characteristics (including fixed geology and river position); year FE (`γ_t`)
absorb national shocks (e.g. the gold-price boom). SEs clustered on hex. A positive, significant `ρ`
says: *hexes whose neighbours had more accumulated mining last year get more new mining this year.*

**What it shows:** a **dynamic, directional** association consistent with diffusion — mining appears
to beget neighbouring mining over time, and the hex + year FE rule out the two most obvious
confounders (fixed geography, common time shocks). This is a genuine step beyond the cross-sectional
Moran's I because it conditions on the *past* and on fixed hex traits.

**What it does NOT show — and this is why the event study exists:**
- **It is not a clean causal effect.** Own and neighbour mining share time-*varying* unobservables
  that hex/year FE cannot remove — most importantly, a *local* gold-price or discovery shock that
  hits a hex and its neighbours together makes neighbour-stock and own-mining co-move mechanically
  (the reflection problem / common-suitability confound).
- **It is the contaminated continuous-treatment TWFE** design that the event-study literature warns
  against: with staggered, heterogeneous dynamics, TWFE with a continuous lagged regressor is subject
  to negative-weighting / "forbidden comparison" bias. The single coefficient `ρ` is a weighted
  average that need not be a valid ATT.
- **Adjacency is symmetric** — it cannot tell A→B from B→A.

For these reasons D2d is kept as the transparent **"before"** baseline that the event study
(§9) improves upon. The defence against the reflection problem is **pre-trends** (flat pre + jump
post = diffusion; co-trending = common fundamentals) and a **directed** (upstream) treatment, both of
which require the staggered event-study machinery.

---

## 9. The event-study designs

The event study (`a_05_event_study.Rmd`, specified in `../3_analysis/event_study_design.md`) tackles
two questions on one shared hex × year panel (`event_panel_{1,2,5}km.rds`):

| | **Q1 — Waterborne degradation** | **Q2 — Mining diffusion** |
|---|---|---|
| Outcome | downstream NDVI | own-hex mining |
| Treatment | **upstream** mining onset | **neighbour** mining onset |
| Right neighbour | directed upstream (MERIT D8 flow graph) | adjacency (queen) + directed upstream |
| Placebo | downstream onset | downstream onset |

**Neighbour definitions** come from the MERIT D8 flow graph (`d_04_merit.R`), not the old northing
proxy: for each focal hex the panel carries *upstream-all-reachable*, *upstream-1-hop*, *lateral*
(queen-adjacent but off the flow path — no water link), *downstream-1-hop*, and
*downstream-all-reachable* exposure columns. The directed upstream/downstream split is the identifying
device: downstream mining **cannot** contaminate an upstream hex through water, so the downstream arm
is a built-in **placebo**.

**Headline estimator: Callaway & Sant'Anna** (`did::att_gt` → `aggte`), doubly-robust,
**not-yet-treated** controls (preferred over never-treated because Barenblitt's coverage/accuracy
makes "never-treated" conflate "never surveyed"), universal base period, SEs clustered on a 25 km
spatial block (a sub-basin stand-in). C&S is chosen precisely because it is **robust to the staggered,
heterogeneous-timing bias** that sinks the TWFE spatial-lag model in §8.

The `run_cs()` helper wraps `att_gt` + dynamic (event-time) + group aggregation; `first_cross()`
builds the treatment clock as "first year a stock column crosses threshold `mbar`". Every figure and
table is exported to `outputs/figures/event_study/` for the deck.

### Q1 designs (upstream mining → downstream NDVI)

**V1 — continuous distributed lag (TWFE, robustness/dose-response).** `feols` regressions separating
the **stock** (long-run level) and **flow** (short-run growth) channels: 1a stock-only, 1b flow-lags-
only (on ΔNDVI, lags 0–3), 1c joint (flow lags + a stock polynomial, symmetric across the
upstream/downstream placebo). A collinearity caveat is carried because `stock_{t-1} = Σ flow_s`.
Transparent but TWFE-biased under heterogeneity — hence a *robustness companion*, not the headline.
**1d — dCDH:** the de Chaisemartin–D'Haultfœuille continuous-dose, heterogeneity-robust estimator
(`did_multiplegt_dyn`), run when the optional `DIDmultiplegtDYN` package is available.

**V2 — absorbing treatment at a stock threshold (headline).** Treatment = the first year the upstream
mining stock crosses `m̄`, swept over {0, 10, 25, 50} ha (m̄ = 0 ≡ "any onset"). C&S, NDVI in levels.
Run in parallel for five exposure dimensions in treatment → comparison → placebo order (upstream-all,
upstream-1-hop, lateral, downstream-1-hop, downstream-all). The m̄ sweep is the **stability check** — a
real effect should be stable across thresholds. Adjacency (queen) is *excluded* here because it mixes
upstream + lateral + downstream neighbours, confounding treatment and placebo.

**V2c — V2 censored to pre-own-entry (headline causal spec).** The **own-mining confounder** fix:
each hex is dropped from the moment it starts mining itself (`year < own_onset_year`), so any NDVI
drop cannot be its *own* land-clearing — identification comes purely from pre-own-entry variation.
Six exposure dimensions. *Interpretation:* upstream negative & significant while downstream is null =
cleanest evidence for the waterborne channel.

**V3 — upstream-onset clock, censored (mechanism).** Does NDVI fall when an **upstream** hex starts
mining, *before the focal hex itself mines*? Treatment clock = onset of the immediate 1-hop upstream
neighbour (headline), with all-reachable upstream as robustness and downstream onsets as directional
placebos. A **gap plot** (`T_own − T_up` distribution) is reported first — if the two clocks are
collinear, V3 is weakly identified and V2c is the only viable headline. (A critical implementation
detail: `nearest_*_onset_year` are time-invariant per hex but stored year-by-year, so they must be
resolved to hex-level scalars before the C&S join or `gname` becomes non-constant within a unit — the
permanent fix is in `b_03e_assemble_eventpanel.R`.)

**V3b — faithful two-clock TWFE.** Implements the paper's V3 equation literally: one two-way-FE
regression on the pre-own-entry sample with **two event-time clocks jointly** — the hex's own-entry
clock β_k (pre-period only) and the nearest-upstream clock δ_j — both normalised to event time −1.
β_k traces the common pre-entry NDVI decline of all eventual enterers; δ_j isolates the part that
follows the upstream neighbour's onset (the waterborne channel). Read jointly: β≈0, δ<0 = pure
waterborne; β<0, δ<0 = mixed; β<0, δ≈0 = common pre-entry decline unrelated to upstream status. It
reproduces the β-vs-δ decomposition at the cost of TWFE's heterogeneity bias — which is exactly why
V2/V3 headline with C&S.

### Q2 designs (neighbour mining → own mining)

Q2 is the §8 spatial-lag regression **upgraded** to a staggered event study (currently commented out
in the Rmd as of 2026-06-30):
- **D2d reproduction** — the naïve TWFE baseline (the "before"), explicitly *not* a clean causal
  effect.
- **Directed upstream onset → own mining (headline)** — treatment = upstream onset, placebo =
  downstream onset. Clean because downstream onset cannot cause upstream mining through channels;
  flat pre-trend + post jump = diffusion along the river corridor.
- **Adjacency benchmark (symmetric)** — magnitude comparison; interpret pre-trends with the reflection
  caveat (adjacent hexes share suitability fundamentals).
- **Extensive-margin onset hazard** — a transparent TWFE LPM among still-at-risk hex-years: does an
  already-active upstream/adjacent neighbour raise the probability the hex starts mining this year?
  (TWFE is appropriate here — binary outcome, absorbing regressor.)

### What the event study shows and does not show

**Shows:** with a directed treatment (upstream) and a genuine placebo (downstream), a C&S design with
flat pre-trends and a post-onset NDVI drop on the upstream arm — but not the downstream arm — is
strong evidence for the **waterborne-contamination** channel that survives (a) heterogeneous-timing
bias, (b) the own-land-clearing confounder (V2c), and (c) threshold choice (the m̄ sweep). The Q2
directed design likewise upgrades the §8 correlation into a pre-trend-tested diffusion test.

**Does NOT show / caveats (carried in the doc):**
- **Sub-basin clustering** is a 25 km block stand-in — replace with a real HydroBASINS / MERIT
  pour-point basin ID for the headline SEs.
- **Window** — Barenblitt is 2007–2017; the usable event window is its overlap with the NDVI stack;
  onsets before NDVI coverage have no pre-period and are dropped.
- **Coverage/accuracy** — 75.6% producer accuracy means onset is measured with error, and
  "never-treated" conflates "never surveyed" (hence not-yet-treated controls).
- **Off-network galamsey** (~5.5% of mined ha at `ROUTE_KM2 = 10`) is unattributed upstream; the
  `d_04` §11j threshold sweep documents the sensitivity.
- **NDVI is an all-pixel hex mean** — isolating the *agricultural* channel needs a cropland mask
  (`*_forestcrop` / `*_nominecrop` columns exist but are highly missing).
- The reflection/common-fundamentals concern is *mitigated* by pre-trends and the directed design,
  not eliminated — shared gold-geology + river fundamentals still make own and neighbour onset
  co-move to some degree.
