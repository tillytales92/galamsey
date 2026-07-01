# Alluvial Gold Potential from Hydro-Geomorphology — Plan

*Companion to `code/0_data/data_gold_deposits.R`. Working/planning document — this is where we
think through the approach before committing code. Status: exploratory.*

---

## 1. Purpose

Galamsey in Ghana is overwhelmingly **alluvial (placer) gold mining** — digging and sluicing
river sediments rather than hard-rock ore. So *where* it is feasible is governed by river
geomorphology: where eroded gold has been transported and concentrated by water. This document
plans how to turn a Digital Elevation Model (DEM) — optionally MERIT Hydro — plus WhiteboxTools
and SAGA into layers that flag those settings.

Three concrete uses in this project:

1. **A new exogenous first-stage covariate.** The d03 first stage (geology + river distance +
   elevation/slope → mine presence) is weak because Girard geology is coarse (1:10M). Terrain
   *interactions* (geology × low elevation, geology × river) already help (see
   `16_06_session.md` §8). Purpose-built valley-bottom / floodplain indices should encode "this
   is an alluvial depositional setting" in a single, mechanism-aligned variable — and unlike
   roads/settlements they are **exogenous** (terrain is not caused by mining).
2. **Fixing the D2e flow-direction proxy.** D2e currently uses UTM *northing* as a crude
   "downstream = closer to the Gulf" proxy. True D8 flow direction (here, or from MERIT Hydro)
   replaces that — see `project_d03_state` and `16_06_session.md` §9.
3. **A standalone targeting / validation layer** — where is alluvial gold *physically likely*,
   independent of where Barenblitt happened to detect mining.

---

## 2. Background — why geomorphology predicts placer gold

Gold weathers out of primary ("lode") deposits in bedrock, is washed into the drainage network,
and — because it is ~7× denser than quartz sand — drops out of the flow wherever water **loses
energy**. It therefore concentrates in predictable places: valley floors, floodplains, the
inside of meander bends, behind obstructions, at stream confluences, and in old river terraces
left behind as valleys incise. Hard-rock gold needs the bedrock; **alluvial** gold needs the
bedrock *upstream* **plus** a low-energy place downstream to settle. Two ingredients, both
mappable from topography + hydrology.

So the question "where is alluvial mining feasible?" becomes a set of terrain questions we can
answer from a DEM.

---

## 3. What we are looking for (and the "sinks/pits" ambiguity)

Concretely, the depositional/low-energy settings to flag:

| Feature | Why gold concentrates there | How we detect it |
|---|---|---|
| **Valley bottoms** | Flat, low — sediment accumulates | MRVBF (§6) |
| **Active floodplains** | Repeatedly reworked alluvium | Low HAND (§6) |
| **River terraces** | Abandoned floodplains = paleo-placers | Intermediate HAND bands (§6) |
| **Low-slope channel reaches** | Flow slows, heavy minerals drop | Slope + Stream Power Index (§6F) |
| **Confluences** | Energy drop / mixing at junctions | Stream-order/link analysis (§6F) |
| **Meander point bars** | Inside bends trap heavies | Channel sinuosity (§6F, harder) |
| **Downstream of gold-suitable rock** | Need an upstream lode source | Network distance from Girard geology (§6F) |

**On "sinks" / "pits" — an important clarification, since the term is overloaded:**

- **DEM sinks (depressions):** in hydrology a "sink" is a cell with no lower neighbour, so
  modelled flow gets trapped. **The vast majority are DEM artefacts** (noise, vegetation, dam
  cells) and they *break* flow routing — they must be removed (filled or breached) *before* you
  can compute flow direction at all. So in the standard pipeline, sinks are a nuisance to
  eliminate, **not** a target. That is Section A of the R script.
- **Real depressions** do exist (natural ponds, ox-bow lakes) and can be low-energy traps — but
  at DEM resolution they are hard to separate from artefacts.
- **The twist for us:** *galamsey itself digs pits and leaves water-filled ponds.* The
  Barenblitt polygons are largely these ponds. So a genuine depression on a recent DEM near a
  river could be an *existing mine*, not a prospective site. That makes raw "find the pits"
  risky as a *predictor* (it would partly detect current mining, i.e. leak the outcome) — but
  potentially useful as *validation* (do our predicted-suitable areas coincide with observed
  pits?). **Recommendation:** treat depressions as something to *remove* for routing (Section
  A), and keep "real depression detection" as a separate, clearly-labelled experiment — do not
  fold it into an exogenous first-stage covariate. Open question flagged in §9.

So to directly answer the original framing: the main signal is **not** pits/sinks themselves —
it is the valley-bottom / floodplain / low-energy-reach geometry around rivers. Sinks are mostly
a preprocessing step to get clean flow direction.

---

## 4. Data sources

Two separate things are needed and must not be confused: a **raw DEM** (for elevation, slope,
MRVBF) and **routing products** (flow direction, accumulation, stream network, for HAND and D2e).
Different datasets serve each role.

**Raw DEM — needed for: elevation, slope, MRVBF.** Options:

- **AWS Terrain Tiles** (what we already download via `elevatr` in `data_elevation.R`): ~150 m
  (z10) or ~76 m (z11). Pro: already on disk, tunable resolution. Con: raw, needs conditioning
  before routing.
- **SRTM 30 m** (via GEE): finer, but needs the same conditioning and has voids.
- **MERIT-DEM** (Yamazaki et al. 2017): error-reduced 90 m DEM — noise, vegetation bias, and
  voids corrected. The cleanest off-the-shelf DEM for terrain morphometry (slope, MRVBF).
  Hydrologically consistent without our own conditioning steps. Strong candidate to replace AWS
  tiles as the base layer.

**Routing products — needed for: HAND, D2e flow-direction proxy, stream network.**

- **MERIT Hydro** (Yamazaki et al. 2019): *derived* global hydrography at 3 arc-sec (~90 m).
  **Not a DEM** — it is built on top of MERIT-DEM and ships pre-computed routing outputs:
  `dir` (D8 flow direction), `upa` (upstream drainage area ≡ flow accumulation in km²), `wth`
  (river width mask), and `elv` (hydrologically adjusted elevation, nudged cell-by-cell to
  enforce consistent downhill flow). Because `elv` has been altered to fix drainage, **slope and
  MRVBF computed from it would be distorted** — do not use MERIT Hydro as a DEM substitute.
  Its value is that it **replaces our Sections A–C** (breach → D8 → stream extraction) with
  globally consistent, pre-conditioned equivalents. Available on GEE (`MERIT/Hydro/v1_0_1`) or
  by download. Also fixes the D2e northing proxy in one go. (Section G in the R script.)

**Engines.**
- **WhiteboxTools** (`whitebox` R pkg, `install_whitebox()`): self-contained binary; does
  breaching, D8/D-infinity, flow accumulation, stream extraction, Strahler order, HAND
  (`ElevationAboveStream`), and much more. Our Sections A–D.
- **SAGA GIS** (via `RSAGA`): needed for **MRVBF** (no native WhiteboxTools equivalent). Our
  Section E.

**Ancillary layers already in the project.**
- **OSM natural waterways** (`data_waterways.R`) — validate the DEM-derived stream network and
  optionally anchor HAND to mapped rivers.
- **Girard gold-suitable geology** — the upstream *source* layer for §6F network coupling.
- **Barenblitt mining extent** — validation target (not a predictor input).

---

## 5. Processing pipeline (DEM → layers)

Maps onto the R script sections:

1. **Condition the DEM** — breach depressions to remove spurious sinks (Section A). Breaching
   over filling: fewer altered cells, preserves valley-floor elevations (matters for HAND).
2. **Flow direction (D8 pointer)** + **flow accumulation** (Section B).
3. **Stream network** by thresholding accumulation, + **Strahler order** (Section C). The
   `STREAM_THRESHOLD` choice matters: too low → every gully is a "river" (HAND ≈ 0 everywhere);
   too high → only trunk rivers. Calibrate against OSM rivers. Placers favour **intermediate
   stream orders**, so the threshold also implicitly sets which channels we emphasise.
4. **HAND** from the conditioned DEM + streams (Section D).
5. **MRVBF** from the DEM (Section E, SAGA).
6. **Derived indicators** — SPI, confluences, terrace bands, network distance from gold-suitable
   geology (Section F, TODO).
7. **Combine + extract** to the hex grid as a covariate (Section H, TODO).

**MERIT Hydro shortcut (Section G):** replaces steps 1–3 with pre-computed routing layers
(`dir`, `upa`, river mask) — but the raw DEM (AWS tiles or MERIT-DEM) is still required for
steps 4–5 (HAND needs actual elevation to compute vertical drop; MRVBF needs unaltered terrain
morphology). The two datasets are complementary, not interchangeable.

---

## 6. The two headline indices — MRVBF and HAND (explained)

These were pulled out of `data_elevation.R` per request; here is what they are, why they matter
for alluvial gold, and what they need.

### MRVBF — Multiresolution Index of Valley Bottom Flatness

- **What it is.** A continuous index (Gallant & Dowling 2003) that flags **valley bottoms** —
  defined as places that are both *flat* (low slope) **and** *low* relative to their
  surroundings (low elevation percentile in a local window). Crucially it is **multiresolution**:
  it tests for flatness/lowness at the native DEM scale, then progressively coarsens the DEM and
  relaxes the slope threshold, so it captures both narrow headwater flats and broad lowland
  floodplains in one number. A companion index, **MRRTF**, does the same for ridge tops.
- **Output scale.** Roughly 0 to ~7+; higher = flatter, larger, lower valley bottom. Values ≳1
  are conventionally "valley bottom".
- **Why relevant to placer gold.** Valley bottoms are exactly where transported sediment — and
  with it heavy minerals like gold — accumulates. MRVBF is a direct, scale-aware proxy for "is
  this a sediment-accumulating valley floor," which is the core physical precondition for
  alluvial mining. It is purely topographic and therefore **exogenous** to mining.
- **How it is calculated / data needed.** **Input: a DEM only.** It combines, at each scale, a
  slope-based flatness measure with an elevation-percentile lowness measure via fuzzy thresholds,
  then merges across scales. Computed with **SAGA GIS** (`ta_morphometry` → "Multiresolution
  Index of Valley Bottom Flatness (MRVBF)") — Section E. No flow routing required.

### HAND — Height Above Nearest Drainage

- **What it is.** For every cell, the **vertical elevation difference between that cell and the
  stream cell it drains into**, following the flow path (Rennó et al. 2008; Nobre et al. 2011).
  It re-expresses elevation *relative to the local river* rather than to sea level.
- **Why relevant to placer gold.** HAND cleanly stratifies the valley into deposition zones:
  - **Low HAND (≈0–2 m):** the active floodplain — frequently inundated, modern alluvium being
    actively reworked. Prime alluvial-gold ground.
  - **Intermediate HAND (~2–10 m):** **river terraces** — abandoned floodplains left as the
    valley incised. These host *paleo-placers* and are classic galamsey targets.
  - **High HAND:** uplands — not depositional.
  So HAND turns "near a river" into "in the part of the valley where gold settles," which plain
  distance-to-river (our current `dist_river_km`) cannot do. Also exogenous.
- **How it is calculated / data needed.** **Inputs: DEM + flow direction + a stream network.**
  So HAND depends on the whole routing chain: condition DEM (A) → D8 (B) → streams (C) → HAND
  (D). The `STREAM_THRESHOLD` directly shapes it (denser streams → lower HAND everywhere), which
  is why §5 stresses calibrating it. Computed with **WhiteboxTools** (`ElevationAboveStream`).

### Why both, not one

MRVBF captures **valley morphology** (is this a broad flat sediment trap?); HAND captures
**hydrological/vertical position** (active floodplain vs terrace vs upland). They are
complementary — together they delineate the alluvial corridor *and* its sub-zones. Empirically
in this project, terrain mattered (it lifted the first-stage AUC; `16_06_session.md` §8), so
sharper terrain descriptors are the most promising no-new-survey improvement.

---

## 7. Combining into a suitability layer

Not yet decided — options to weigh in §9. Sketches:

- **Rule-based mask:** alluvial-suitable = (MRVBF ≥ t1) AND (HAND ≤ t2) AND (near a stream of
  intermediate order) AND (downstream of gold-suitable geology). Transparent, easy to validate.
- **Continuous score:** standardise and combine the indicators (optionally weight by
  agreement with Barenblitt in a calibration sample).
- **Supervised:** use the indicators as features in the existing first-stage logit / RF and let
  the data weight them — most consistent with the rest of the pipeline, but then "suitability" is
  just the fitted propensity.

Then extract per-hex (mean MRVBF, % low-HAND, etc.) onto the d03 grid → a covariate CSV (Section
H), mirroring `data_elevation.R`'s extraction.

---

## 8. Implementation status

- **`data_gold_deposits.R` Sections A–E are functional** (conditioning → D8 → streams/order →
  HAND → MRVBF), moved here from `data_elevation.R`.
- **Sections F–H are skeleton/TODO** pending the choices below.
- `data_elevation.R` is now the basic terrain layer (elevation + slope) only.

---

## 9. Open questions / decisions before going further

1. **DEM vs MERIT Hydro.** Route our own AWS-tile DEM (full control, finer at z11) or ingest
   MERIT Hydro (pre-conditioned, globally consistent, also fixes D2e)? Leaning MERIT Hydro for
   the flow layers, keeping our DEM for MRVBF/slope.
2. **Resolution.** Indices are most meaningful at ≤90 m; the hex grid is 5 km (or 1 km). Compute
   at native DEM resolution, then aggregate to hexes.
3. **STREAM_THRESHOLD calibration** against OSM rivers — pick before HAND is trusted.
4. **Depressions/pits:** confirm we only *remove* them for routing and keep any "detect real
   pits" work as separate validation, to avoid leaking the mining outcome into a predictor (§3).
5. **Endogeneity check:** all of MRVBF/HAND/SPI are terrain-derived and exogenous — good. But if
   galamsey reshapes micro-topography, a *recent* DEM near active sites could be mildly
   contaminated; prefer a pre-period or coarse DEM for the predictor if this is a concern.
6. **Suitability construction** (§7) — rule-based vs continuous vs supervised.

---

## References

- Gallant, J.C. & Dowling, T.I. (2003). A multiresolution index of valley bottom flatness for
  mapping depositional areas. *Water Resources Research* 39(12).
- Rennó, C.D. et al. (2008); Nobre, A.D. et al. (2011). HAND / Height Above Nearest Drainage.
- Yamazaki, D. et al. (2017). MERIT DEM. *GRL* 44.  ·  Yamazaki, D. et al. (2019). MERIT Hydro.
  *Water Resources Research* 55.
- WhiteboxTools — https://www.whiteboxgeo.com/  ·  SAGA GIS — https://saga-gis.sourceforge.io/
