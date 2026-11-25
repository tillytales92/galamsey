# diag_03_temporal_consistency.R  (renamed 2026-11-03, was validate_temporal_consistency_rules.R --
# see code/1_remote_sensing's diag_NN_* naming convention, decided the same session: a decision-
# ready comparison/report tied to one build_NN stage, meant to be RE-RUN whenever that stage's
# assets/parameters change, as opposed to validate_*'s one-off interactive Code-Editor scripts.)
#
# Systematic R/rgee comparison of the 3 candidate temporal-consistency rules discussed for
# build_03_embedding_panel.R's still-undecided APPLY_TEMPORAL_CONSISTENCY design question (see
# memory [[project_temporal_consistency_investigation]]). Consolidates what the three paste-into-
# Code-Editor pilots (validate_temporal_consistency_rule_pilot.js, _forward.js, _sticky_exit.js)
# each tested separately, into one script that reports the same numbers (2018->19 / 2021->22 dip
# behaviour, total year-to-year variation reduction, final-2025 cumulative level, and any NEW side
# effects a rule introduces) side by side, plus the raw (no-rule) trend as the baseline everything
# else is judged against. The three .js scripts are left in place for ad hoc interactive re-checks
# in the Code Editor (e.g. eyeballing a specific pixel) -- this script is the one to run for a
# decision-ready comparison table.
#
# RULES (all computed on the already-deployed mine_mask_ghana_c4_<year> binary assets, 2017-2025 --
# no probability tiles, no re-exporting, no changes to build_03):
#   A (centered majority vote):   smoothed[T] = >=2 of {raw[T-1], raw[T], raw[T+1]} say mine.
#                                  Edge years (2017, 2025) fall back to raw.
#   B (forward-only state machine): smoothed[T] = raw[T] AND raw[T+1] if they agree; else carries
#                                  forward the previous SMOOTHED state. 2017 = raw (no state yet);
#                                  2025 = raw (no T+1 to confirm).
#   C (sticky-exit, asymmetric):  no persistence to ENTER mine (adopts raw[T] immediately); once
#                                  mine, requires 2 CONSECUTIVE raw[T]==0 & raw[T+1]==0 to exit.
#                                  2017 = raw; 2025 can't exit (no T+1), so it's prevSmoothed OR raw.
#
# Run INTERACTIVELY -- ee_Authenticate() / ee_Initialize() block on a browser login.
# Prerequisite: all 9 mine_mask_ghana_c4_{2017..2025} assets must exist (they do as of this
# session -- see [[project_rs_pipeline_next_steps]]).

#### 1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, here, tidyverse, ggplot2, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, here::here
)

EE_PROJECT    <- "rgee-auth-tillam"                       # ID, never the numeric project number
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)

ee_Authenticate()
ee_Initialize(drive = TRUE, project = EE_PROJECT)

#### 2. Parameters ####
EMBED_YEARS <- 2017:2025   # build_03's EMBED_YEARS -- matches the 9 deployed mask assets

#### 3. Pull the 9 binary masks + build raw and all 3 rules' smoothed series, ONE reduceRegion ####
GHANA <- ee$FeatureCollection(paste0(EE_ASSET_HOME, "/rs05_ghana"))$geometry()
area_km2 <- ee$Image$pixelArea()$divide(1e6)

bin <- map(EMBED_YEARS, function(yr) {
  ee$Image(paste0(EE_ASSET_HOME, "/mine_mask_ghana_c4_", yr))$unmask(0)
}) |> set_names(as.character(EMBED_YEARS))
yr_chr <- function(yr) as.character(yr)

# ---- rule A: centered majority vote --------------------------------------------------------
ruleA <- list()
for (i in seq_along(EMBED_YEARS)) {
  yr <- EMBED_YEARS[i]
  if (i == 1 || i == length(EMBED_YEARS)) {
    ruleA[[yr_chr(yr)]] <- bin[[yr_chr(yr)]]
  } else {
    votes <- bin[[yr_chr(EMBED_YEARS[i - 1])]]$add(bin[[yr_chr(yr)]])$add(bin[[yr_chr(EMBED_YEARS[i + 1])]])
    ruleA[[yr_chr(yr)]] <- votes$gte(2)
  }
}

# ---- rule B: forward-only state machine -----------------------------------------------------
fwd <- list()
fwd[[yr_chr(EMBED_YEARS[1])]] <- bin[[yr_chr(EMBED_YEARS[1])]]
for (i in 2:length(EMBED_YEARS)) {
  yr <- EMBED_YEARS[i]; prev_yr <- EMBED_YEARS[i - 1]
  if (i == length(EMBED_YEARS)) {
    fwd[[yr_chr(yr)]] <- bin[[yr_chr(yr)]]
    next
  }
  raw_t <- bin[[yr_chr(yr)]]; raw_next <- bin[[yr_chr(EMBED_YEARS[i + 1])]]
  agree_mine <- raw_t$And(raw_next)
  ambiguous  <- raw_t$neq(raw_next)
  fwd[[yr_chr(yr)]] <- agree_mine$where(ambiguous, fwd[[yr_chr(prev_yr)]])
}

# ---- rule C: sticky-exit (asymmetric) --------------------------------------------------------
sticky <- list()
sticky[[yr_chr(EMBED_YEARS[1])]] <- bin[[yr_chr(EMBED_YEARS[1])]]
for (i in 2:length(EMBED_YEARS)) {
  yr <- EMBED_YEARS[i]; prev_yr <- EMBED_YEARS[i - 1]
  prev_smoothed <- sticky[[yr_chr(prev_yr)]]
  raw_t <- bin[[yr_chr(yr)]]
  if (i == length(EMBED_YEARS)) {
    sticky[[yr_chr(yr)]] <- prev_smoothed$Or(raw_t)   # can't exit in the final year, no T+1 to confirm
    next
  }
  raw_next <- bin[[yr_chr(EMBED_YEARS[i + 1])]]
  confirmed_exit <- raw_t$eq(0)$And(raw_next$eq(0))
  staying_mine   <- prev_smoothed$And(confirmed_exit$Not())
  entering_mine  <- prev_smoothed$Not()$And(raw_t)
  sticky[[yr_chr(yr)]] <- staying_mine$Or(entering_mine)
}

# ---- combine into one multi-band image, one reduceRegion call -------------------------------
rule_bands <- function(by_year, prefix) {
  map(EMBED_YEARS, ~ by_year[[yr_chr(.x)]]$multiply(area_km2)$rename(paste0(prefix, "_", .x)))
}
all_bands <- c(rule_bands(bin, "raw"), rule_bands(ruleA, "ruleA"),
               rule_bands(fwd, "fwd"), rule_bands(sticky, "sticky"))
combined <- ee$Image$cat(all_bands)

cat("Computing raw + 3 rules' national area for all 9 years in ONE reduceRegion call",
    "(36 bands) -- cheap, should return in well under a minute.\n")
stats <- combined$reduceRegion(
  reducer = ee$Reducer$sum(), geometry = GHANA, scale = 100, maxPixels = 1e13, tileScale = 8
)$getInfo()

area_df <- tibble(
  year   = EMBED_YEARS,
  raw    = map_dbl(EMBED_YEARS, ~ stats[[paste0("raw_", .x)]]),
  ruleA  = map_dbl(EMBED_YEARS, ~ stats[[paste0("ruleA_", .x)]]),
  fwd    = map_dbl(EMBED_YEARS, ~ stats[[paste0("fwd_", .x)]]),
  sticky = map_dbl(EMBED_YEARS, ~ stats[[paste0("sticky_", .x)]])
)

#### 4. Baseline: raw growth trend, NO temporal-consistency rule applied ####
cat("\n=== Raw national mined area by year, NO temporal-consistency rule applied ===\n")
print(area_df |> select(year, raw) |> mutate(raw = round(raw, 1)), row.names = FALSE)

p_raw <- ggplot(area_df, aes(year, raw)) +
  geom_line(color = "#9c179e", linewidth = 1) +
  geom_point(color = "#9c179e", size = 2.5) +
  scale_x_continuous(breaks = EMBED_YEARS) +
  labs(title = "Raw national mined area, 2017-2025 (no temporal-consistency rule)",
       subtitle = "mine_mask_ghana_c4_<year>, deployed cutoff -- no smoothing applied",
       x = NULL, y = "km2") +
  theme_minimal(base_size = 12)
print(p_raw)

#### 5. Per-rule comparison: dip behaviour, total variation, final-level shift, side effects ####
summarize_rule <- function(area_df, rule_col, rule_label) {
  raw_diff  <- diff(area_df$raw)
  rule_diff <- diff(area_df[[rule_col]])
  years <- area_df$year
  transitions <- paste0(years[-length(years)], " -> ", years[-1])

  diff_tbl <- tibble(
    transition = transitions,
    raw_km2    = round(raw_diff, 1),
    rule_km2   = round(rule_diff, 1)
  ) |>
    mutate(note = case_when(
      raw_km2 <  0 & rule_km2 >= 0 ~ "dip ERASED",
      raw_km2 <  0 & rule_km2 <  0 ~ "dip survives",
      raw_km2 >= 0 & rule_km2 <  0 ~ "NEW dip introduced",
      TRUE ~ ""
    ))

  total_var_raw  <- sum(abs(raw_diff))
  total_var_rule <- sum(abs(rule_diff))

  n <- nrow(area_df)
  list(
    label           = rule_label,
    diff_tbl        = diff_tbl,
    pct_reduction   = round(100 * (1 - total_var_rule / total_var_raw), 1),
    neg_count_raw   = sum(raw_diff < 0),
    # FIXED (2026-11-02): this used to be sum(rule_diff < 0) -- a raw count of ALL negative
    # transitions under the rule, which silently conflates "an original dip survived" with "a new
    # dip appeared somewhere raw was never negative." Split into the two non-overlapping categories
    # the diff_tbl's own `note` column already distinguishes, so the comparison table downstream
    # can't misrepresent one as the other again.
    dips_surviving  = sum(diff_tbl$note == "dip survives"),      # of the 2 real declines, how many still show up
    new_dips        = sum(diff_tbl$note == "NEW dip introduced"), # dips that WEREN'T in the raw data
    final_diff      = round(area_df[[rule_col]][n] - area_df$raw[n], 1),
    final_pct       = round(100 * (area_df[[rule_col]][n] - area_df$raw[n]) / area_df$raw[n], 1)
  )
}

rules <- list(
  list(col = "ruleA",  label = "A: centered majority vote"),
  list(col = "fwd",    label = "B: forward-only state machine"),
  list(col = "sticky", label = "C: sticky-exit (asymmetric)")
)
results <- map(rules, ~ summarize_rule(area_df, .x$col, .x$label))

for (r in results) {
  cat(sprintf("\n--- %s ---\n", r$label))
  print(r$diff_tbl, row.names = FALSE)
  cat(sprintf(
    "Total |year-to-year| variation reduction: %.1f%%  |  of the 2 real declines, still negative: %d/2  |  new dips introduced (raw was NOT negative there): %d  |  final-2025 diff: %+.1f km2 (%+.1f%%)\n",
    r$pct_reduction, r$dips_surviving, r$new_dips, r$final_diff, r$final_pct
  ))
}

#### 6. Consolidated comparison, one row per rule -- the decision-ready table ####
comparison <- tibble(
  rule                     = map_chr(rules, "label"),
  total_var_reduction_pct  = map_dbl(results, "pct_reduction"),
  real_dips_surviving      = map_int(results, "dips_surviving"),   # out of 2 (2018-19, 2021-22)
  new_dips_introduced      = map_int(results, "new_dips"),         # at transitions raw was NOT negative
  final_2025_diff_km2      = map_dbl(results, "final_diff"),
  final_2025_diff_pct      = map_dbl(results, "final_pct")
)
cat("\n=== Summary comparison across all 3 rules (raw baseline: real_dips_surviving=2, new_dips_introduced=0, final diff=0, by definition) ===\n")
print(comparison, row.names = FALSE)

cat(
  "\nREAD THIS: total_var_reduction_pct is how much smoother the series got (higher = more\n",
  "smoothing); real_dips_surviving is how many of the 2 real declines (2018->19, 2021->22) STILL\n",
  "show up as a decline under that rule (0 = both erased) -- this and new_dips_introduced are\n",
  "DISJOINT counts (a transition is either an original dip, a new one, or neither -- never both),\n",
  "so don't sum them expecting some other total. new_dips_introduced flags a rule fabricating a\n",
  "decline at a transition where raw was NOT negative (A's known 2017->18 artifact shows up here);\n",
  "final_2025_diff_pct is the cumulative bias the rule leaves in the LAST year's level vs raw --\n",
  "large and positive means the rule systematically inflates the panel over time.\n",
  sep = ""
)

#### 7. Combined trend chart: raw + all 3 rules, with major galamsey policy events annotated ####
# Policy/political events, 2017-2025 -- verified via web search 2026-11-02 (not from memory alone,
# given these end up on a research figure). Dates are approximate (month-level, placed at a single
# representative point within each window) purely for chart annotation -- the underlying series is
# annual anyway, so day-level precision doesn't matter here. Re-verify before reusing in anything
# publication-facing; this is an analyst annotation, not a sourced historical-events table artifact.
#   - 2017: nationwide small-scale mining ban announced ~Mar 2017 (initially 6 months, later
#     extended); Operation Vanguard (military-police joint task force) launched ~30 Jul 2017.
#     NOTE: per contemporary reporting, gold output reportedly INCREASED through the ban (1.5M oz
#     in 2017 -> ~2M oz, its highest level ever, in 2018) -- consistent with our own raw series
#     also rising 2017->2018 (650.3 -> 698.9 km2), not falling, during the ban.
#   - Dec 2018 (ban lifted, ~18 Dec 2018): ban lifted for newly registered/licensed miners after
#     ~20 months in force.
#   - 2019 (registration deadline 21 Jun 2019): Community Mining Scheme launched, formalizing
#     small-scale mining through district-level community structures.
#   - May 2021: Operation Vanguard formally dissolved.
#   - Sep 2024 (21-24 Sep, follow-on marches into early Oct): #StopGalamsey mass protests in Accra
#     (Democracy Hub-led), 50+ arrests, over worsening river pollution from illegal mining.
#   - 2025: Mahama administration takes office (7 Jan 2025) on an explicit anti-galamsey platform;
#     GOLDBOD Task Force (multi-agency, arrest/detention powers) inaugurated Jul 2025.
policy_events <- tibble(
  x     = c(2017.4, 2018.95, 2019.4, 2021.33, 2024.67, 2025.3),
  label = c(
    "2017: nationwide small-scale\nmining ban + Operation Vanguard",
    "Dec 2018: ban lifted\n(licensed miners)",
    "2019: Community Mining\nScheme launched",
    "May 2021: Operation\nVanguard dissolved",
    "Sep 2024: #StopGalamsey\nmass protests",
    "2025: Mahama admin crackdown;\nGOLDBOD Task Force"
  )
)
# stagger label heights (alternating) so adjacent events don't collide -- tweak if they still do
# once you actually see the rendered plot; can't preview-render ggplot output from this chat.
y_top <- max(area_df$raw, area_df$ruleA, area_df$fwd, area_df$sticky, na.rm = TRUE)
policy_events <- policy_events |>
  mutate(y = y_top * rep(c(1.18, 1.34), length.out = n()))

trend_long <- area_df |>
  pivot_longer(cols = c(raw, ruleA, fwd, sticky), names_to = "series", values_to = "km2") |>
  mutate(series = recode(series,
    raw    = "Raw (no rule)",
    ruleA  = "A: centered majority vote",
    fwd    = "B: forward-only state machine",
    sticky = "C: sticky-exit (asymmetric)"
  ))
SERIES_COLORS <- c(
  "Raw (no rule)"                 = "#444444",
  "A: centered majority vote"     = "#2171B5",
  "B: forward-only state machine" = "#1B9E77",
  "C: sticky-exit (asymmetric)"   = "#D94701"
)

#filter
trend_long_filter <- trend_long |>
  filter(series %in% c("Raw (no rule)",
                       "B: forward-only state machine"))

p_combined <- ggplot(trend_long, aes(year, km2, color = series)) +
  geom_vline(data = policy_events, aes(xintercept = x), color = "grey75", linetype = "dashed",
             inherit.aes = FALSE) +
  geom_text(data = policy_events, aes(x = x, y = y, label = label), inherit.aes = FALSE,
            size = 2.6, color = "grey35", lineheight = 0.85, hjust = 0.5) +
  geom_line(linewidth = 1) +
  geom_point(size = 2) +
  scale_color_manual(values = SERIES_COLORS) +
  scale_x_continuous(breaks = EMBED_YEARS) +
  scale_y_continuous(limits = c(0, y_top * 1.45), expand = expansion(mult = c(0.02, 0))) +
  labs(title = "National mined area, 2017-2025 -- raw vs all 3 temporal-consistency rules",
       subtitle = "Dashed lines: major galamsey-related policy/political events (approximate timing, see script comment for sources)",
       x = NULL, y = "km2", color = NULL) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom")
print(p_combined)
