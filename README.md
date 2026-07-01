# Ghana Galamsey Mapping

Research project mapping galamsey (illegal artisanal gold mining) in Ghana, combining
remote sensing classification with spatial and economic analysis of mining incidence.

> **Note:** This repository currently contains **code only**. Raw and processed data
> (~9GB) are kept out of version control and synced separately via Dropbox. Paths in the
> scripts assume a sibling `data/` directory populated from that Dropbox folder.

## Project Structure

The project has two sequential phases:

1. **Remote Sensing** (`code/1_remote_sensing/`) — classify mine presence from
   Landsat/Sentinel-2 imagery via Google Earth Engine, 1995–2025, across all of Ghana.
2. **Descriptives & Analysis** (`code/3_analysis/`) — spatial and economic analysis of
   mining incidence. Currently uses Barenblitt et al. (2021) as an interim data source;
   designed to swap in the remote-sensing panel once Part 1 is complete.

### Code layout

Scripts carry a folder-role prefix + sequence number and coordinate through data
artifacts (RDS/CSV) rather than sourcing one another — renaming a script never breaks
the pipeline.

```
code/
├── 0_data/            d_NN_*  — raw-data acquisition & covariate builders
│                               (elevation, waterways, MERIT hydrology, gold geology, GEE downloads)
├── 1_remote_sensing/  rs_NN_* — Landsat/Sentinel-2 GEE pipeline + embedding classifier
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

Primary inputs include Barenblitt et al. (2021) mining-extent shapefiles (SW Ghana),
Ghana administrative boundaries, Girard et al. gold-suitability geology layers, OSM
waterways, and MERIT Hydro terrain/flow data. See `CLAUDE.md` (not tracked here) for
full source paths and caveats.
