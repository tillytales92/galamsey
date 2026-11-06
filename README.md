# Ghana Galamsey Mapping

Research project mapping galamsey (illegal artisanal gold mining) in Ghana, combining
remote sensing classification with spatial and economic analysis of mining incidence.

> **Note:** This repository currently contains **code only**. Raw and processed data
> (~9GB) are kept out of version control and synced separately via Dropbox. Paths in the
> scripts assume a sibling `data/` directory populated from that Dropbox folder.

## Project Structure

The project has two sequential phases:

1. **Remote Sensing** (`code/1_remote_sensing/`) — classify mine presence across all of
   Ghana via Google Earth Engine. Currently deployed: a Random Forest on Google
   AlphaEarth satellite embeddings, directly classifying 2017–2025, extended back to
   2005–2016 by replicating Barenblitt et al.'s own NDVI-decline dating method on the
   classifier's own footprint. Earlier years are not yet covered.
2. **Descriptives & Analysis** (`code/3_analysis/`) — spatial and economic analysis of
   mining incidence. Currently uses Barenblitt et al. (2021) as an interim data source;
   designed to swap in the remote-sensing panel once Part 1 is validated as a replacement.

### Code layout

Scripts carry a folder-role prefix + sequence number and coordinate through data
artifacts (RDS/CSV) rather than sourcing one another — renaming a script never breaks
the pipeline.

```
code/
├── 0_data/            d_NN_*  — raw-data acquisition & covariate builders
│                               (elevation, waterways, MERIT hydrology, gold geology, GEE downloads)
├── 1_remote_sensing/          — AlphaEarth-embeddings classifier + backdating pipeline:
│                               explore_* (exploration) / build_* (the sequential pipeline:
│                               labels → classifier → panel → backdating) / validate_*
│                               (one-off checks) / diag_* (re-run-on-change diagnostics).
│                               See code/1_remote_sensing/explainer.md for current status.
├── 2_build/           b_NN_*  — writes data/processed/ artifacts
│                               (hex/district cross-sections, first-stage models, event panel)
├── 3_analysis/        a_NN_*  — produces figures, tables, and reports
└── 4_presentation/            — Quarto/LaTeX slides summarizing motivation & findings
```

### Execution order

1. `0_data/d_03_waterways.R` — prerequisite: writes `waterways_natural.shp`.
2. `2_build/b_01_cross_section.R` — district + hex cross-sections; all downstream
   scripts read its outputs.
3. `2_build/b_02_firststage_models.R` — MAUP-robustness model ladder.
4. `2_build/b_03a`–`b_03e_*.R` — assembles the hex × year event panel (VI extraction,
   own-mining, flow graph, flow exposure, final assembly).
5. `3_analysis/a_NN_*` scripts/Rmds are then independent of each other.

## Conventions

- CRS: UTM30N (EPSG:32630) for all metric area calculations.
- Package loading via `pacman::p_load(...)`.
- Paths via `here::here(...)`.

## Data Sources

See [`data_inventory.md`](data_inventory.md) for the full, maintained list of datasets —
what's acquired, what's wired into the analysis, and source links/citations for each.
Primary inputs include Barenblitt et al. (2021) mining-extent shapefiles (SW Ghana),
Ghana administrative boundaries, Girard et al. gold-suitability geology layers, OSM
waterways, and MERIT Hydro terrain/flow data. `CLAUDE.md` (not tracked here) has
additional implementation-level source paths and caveats.

## Current Status

See [`galamsey_tasklist.md`](galamsey_tasklist.md) for what's done/in-progress/blocked
(updated on request, not automatically — may lag recent work).
