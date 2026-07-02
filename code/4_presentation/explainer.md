# Presentation — explainer

This folder holds the **presentation deck** that assembles the project's figures and tables into a
narrative. It is pure presentation: it embeds pre-computed outputs from `outputs/figures/` and
pre-computed CSVs from `data/processed/` — **it runs no estimation itself**. Run the `a_NN_*`
analysis scripts (and knit `a_05_event_study.Rmd`) first so the figures/tables exist; the deck then
reads them via `include_graphics` (PNGs) and `cat(readLines(...))` (markdown tables).

For the statistics *behind* the slides — Global Moran's I, LISA, the geography-weighted null
decomposition, the M1→M5 model ladder, the simulation exercise, the spatial spline, the spatial lag
model, and the event-study designs — see the companion
[`methodology_explainer.md`](methodology_explainer.md) in this folder.

---

## galamsey_motivation.qmd

**Purpose:** The main deck — "Galamsey: Spatial Distribution, Clustering, and Evidence for Economic
Spillovers." A single Quarto source that renders to **two formats** from the same content:

- **reveal.js** HTML (`theme: simple`, self-contained) — the interactive web slides, output
  `galamsey_motivation.html`.
- **Beamer** PDF (`theme: Madrid`, galamsey-wine colour scheme, `aspectratio=169`) — the LaTeX/PDF
  deck.

All chunks are `echo: false` — no code shown, figures only. The `setup` chunk defines path shortcuts
into the `outputs/figures/` sub-directories (`spatial_clustering`, `maps`, `motivating_facts`,
`event_study`, `merit`, `waterways`) and reads a couple of small precomputed values (district
extent CSV, `n_surveyed_districts.rds` from `a_01`).

**Narrative arc:** Overview → "What's new" → **Part 1: Where does galamsey happen?** (Barenblitt
data, incidence maps, concentration) → **clustering** (Moran's I, LISA) → **why clustered?**
(geography-weighted null, M1–M5 robustness, spatial spline) → **spreading?** (spatial lag, MERIT
flow direction, event-study design). It embeds the D1/D2 figures from `a_01`/`a_02`, the MAUP/first-
stage figures behind `a_03`, the MERIT flow-graph figures from `d_04`, and the event-study
schematic/figures from `a_05`.

**Render:** `quarto render galamsey_motivation.qmd` (produces both formats). The `rsconnect/`
subfolder holds Posit Connect Cloud publishing metadata for the deployed HTML deck.

---

## galamsey_motivation_slides.tex

**Purpose:** A standalone **Beamer** LaTeX deck (`\documentclass[aspectratio=169,handout]{beamer}`) —
an earlier / hand-authored slide source kept alongside the Quarto-generated Beamer output. Compile
with `pdflatex` (or `latexmk`). Where the `.qmd` regenerates its Beamer PDF from the shared Quarto
content, this `.tex` is edited directly.

---

## methodology_explainer.md

The companion document (this folder) explaining the methods used across the analysis — spatial
clustering statistics, the model ladder and simulation exercises, the spatial spline, the spatial
lag model, and the event-study designs — and, for each, what it shows and what it does **not** show.
Read it alongside the deck to understand the inferential content behind each slide.
