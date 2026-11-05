# diag_02_scoring.R  (renamed 2026-11-03 from validate_scoring.R -- diag_NN_* = decision-ready
# report tied to one build_NN stage, re-run on change; see code/1_remote_sensing's naming convention)
# All SmallMinesDS-2022 scoring of the embedding classifier in one place. Consolidates (2026-09-03)
# three older scripts that each answered a slice of "which model config / which cutoff":
#   - validate_ablation_sources.R    -> Part 1 (label-combo ablation)
#   - validate_threshold_comparison.R -> Part 2 (cross-scheme cutoff sweep)
#   - validate_probability_threshold.R -> Part 3 (cutoff sweep + PR/ROC for the DEPLOYED model)
# The old scripts read the stale binary-model files (rs05_val_probability_scores_2022.csv,
# mc_*, mine_prob_ghana_{yr}); this one reads the current c4 / class-scheme files written by
# build_02_embedding_classifier.R's rewrite. validate_probability_threshold.R's Section 6
# (an EE round-trip GHSL urban-mask sweep against the stale binary 2022 asset) is DROPPED --
# the urban-confusion question it explored is settled (see the project_4class_urban_confusion
# memory / notes/2026-08-18): c4 + GHSL-100m epoch mask + cutoff 45.
#
# Offline -- no GEE, no auth. Just reads CSVs already on disk:
#   outputs/tables/rs05_ablation_smallminesds2022.csv          (18 rows: 3 schemes x 6 combos)
#   outputs/tables/class_scheme_matched_precision_comparison.csv (build_02 Section 7c)
#   data/raw/embedding/c4_national_val_probability_scores_2022.csv   (DEPLOYED national model)
#   data/raw/embedding/{binary,c3,c4}_val_probability_scores_2022.csv (SW ablation-scope, per scheme)
#
# Outputs: outputs/figures/scoring/*.png, outputs/tables/class_scheme_threshold_sweep.csv
#
# REMEMBER: PA = producer's accuracy = recall (of true mines, how many found?).
#           UA = user's accuracy = precision (of pixels called mine, how many real?).

pacman::p_load(here, tidyverse, scales, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff, here::here
)

SETTLED_CUTOFF <- 45L   # decided 2026-08-18 (project_4class_urban_confusion) -- annotated on the
                        # curves below, NOT re-derived here; F1-max is reported for reference only.

fig_dir <- here("outputs", "figures", "scoring")
tab_dir <- here("outputs", "tables")
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

# One sweep helper, shared by Parts 2 and 3. Takes an explicit df (label, prob).
sweep_threshold <- function(df, thr) {
  pred <- as.integer(df$prob >= thr)
  tp <- sum(pred == 1 & df$label == 1); fp <- sum(pred == 1 & df$label == 0)
  fn <- sum(pred == 0 & df$label == 1); tn <- sum(pred == 0 & df$label == 0)
  pa <- tp / (tp + fn)
  ua <- if (tp + fp == 0) NA_real_ else tp / (tp + fp)
  tibble(threshold = thr,
         oa  = (tp + tn) / nrow(df),
         pa  = pa, ua = ua,
         f1  = ifelse(is.na(ua) || (pa + ua) == 0, NA_real_, 2 * pa * ua / (pa + ua)),
         fpr = fp / (fp + tn))
}

# ============================================================================================
# PART 1 -- label-source ablation (was validate_ablation_sources.R)
# Which training-label combo (barenblitt / maus / tang / human=maus+tang / no_maus=barenblitt+
# tang / all) generalises best to held-out SmallMinesDS-2022, now ALSO split by class scheme
# (binary / c3 / c4) since build_02's rewrite runs the full 3 x 6 grid.
# ============================================================================================

abl_path <- here("outputs", "tables", "rs05_ablation_smallminesds2022.csv")
stopifnot("Ablation CSV not found -- run build_02_embedding_classifier.R Section 7 first" =
            file.exists(abl_path))
ablation <- read_csv(abl_path, show_col_types = FALSE)

combo_lvl  <- c("barenblitt", "maus", "tang", "human", "no_maus", "all")
scheme_lvl <- c("binary", "c3", "c4")
ablation <- ablation |>
  mutate(combo        = factor(combo, levels = combo_lvl),
         class_scheme = factor(class_scheme, levels = scheme_lvl))

cat("\n=== PART 1: ablation grid (SmallMinesDS-2022, held out) ===\n")
print(ablation |> select(class_scheme, combo, oa, kappa, mine_pa, mine_ua, mine_f1) |>
        arrange(class_scheme, combo), n = Inf)

# 1a. OA / kappa by combo, faceted by scheme
p_acc <- ablation |>
  select(class_scheme, combo, oa, kappa) |>
  pivot_longer(c(oa, kappa), names_to = "metric", values_to = "value") |>
  ggplot(aes(combo, value, fill = metric)) +
  geom_col(position = "dodge") +
  facet_wrap(~ class_scheme) +
  scale_y_continuous(labels = label_percent()) +
  scale_fill_manual(values = c(oa = "#450457", kappa = "#D94701"),
                    labels = c(oa = "Overall accuracy", kappa = "Kappa")) +
  labs(title = "Ablation: OA & kappa by training-label combo x class scheme",
       subtitle = "Held-out SmallMinesDS-2022", x = NULL, y = NULL, fill = NULL) +
  theme_bw(base_size = 11) +
  theme(axis.text.x = element_text(angle = 30, hjust = 1))
ggsave(file.path(fig_dir, "ablation_oa_kappa.png"), p_acc, width = 10, height = 4.5, dpi = 150)

# 1b. Precision vs recall scatter (top-right = best on both)
p_pr <- ggplot(ablation, aes(mine_pa, mine_ua, colour = class_scheme)) +
  geom_point(size = 3.5) +
  geom_text(aes(label = combo), vjust = -1, size = 3, show.legend = FALSE) +
  scale_x_continuous(labels = label_percent()) +
  scale_y_continuous(labels = label_percent()) +
  labs(title = "Ablation: precision vs. recall", subtitle = "Top-right = best on both axes",
       x = "Mine PA (recall)", y = "Mine UA (precision)", colour = "Scheme") +
  theme_bw(base_size = 11)
ggsave(file.path(fig_dir, "ablation_precision_recall.png"), p_pr, width = 8, height = 6, dpi = 150)

# 1c. Decision-rule checks (per scheme): a combo that drops a source is only worth preferring
# if it wins BOTH PA and UA, not one at the other's expense.
check_drop <- function(df, kept, dropped, label) {
  if (!all(c(kept, dropped) %in% df$combo)) return(invisible(NULL))
  k <- df |> filter(combo == kept); d <- df |> filter(combo == dropped)
  cat(sprintf("  [%s] %-8s vs %-4s: PA %.3f/%.3f (%s), UA %.3f/%.3f (%s) -> %s\n",
              as.character(df$class_scheme[1]), kept, dropped,
              k$mine_pa, d$mine_pa, if (k$mine_pa >= d$mine_pa) "keep wins" else "drop wins",
              k$mine_ua, d$mine_ua, if (k$mine_ua >= d$mine_ua) "keep wins" else "drop wins",
              if (k$mine_pa >= d$mine_pa && k$mine_ua >= d$mine_ua)
                "dropping dominates -- safe to drop" else "mixed -- keep the source"))
}
cat("\n--- Part 1c: does dropping a label source dominate on BOTH PA and UA? ---\n")
for (s in scheme_lvl) {
  sub <- ablation |> filter(class_scheme == s)
  check_drop(sub, "human",   "all", "circularity: drop Barenblitt?")
  check_drop(sub, "no_maus", "all", "Maus's marginal contribution")
}

# 1d. Single-source precision -- is Maus's broad "mining lands" definition visible as low UA?
cat("\n--- Part 1d: single-source precision (UA), c4 scheme ---\n")
ss <- ablation |> filter(class_scheme == "c4", combo %in% c("barenblitt", "maus", "tang"))
if (nrow(ss) == 3) print(ss |> select(combo, mine_pa, mine_ua) |> arrange(mine_ua))

# 1e. build_02 Section 7c's matched-precision comparison (the permanent version of the by-hand
# table) -- just surfaced here, not recomputed.
mp_path <- here("outputs", "tables", "class_scheme_matched_precision_comparison.csv")
if (file.exists(mp_path)) {
  cat("\n--- Part 1e: matched-precision comparison (build_02 Section 7c) ---\n")
  print(read_csv(mp_path, show_col_types = FALSE), n = Inf)
}

# ============================================================================================
# PART 2 -- cross-scheme cutoff sweep (was validate_threshold_comparison.R)
# Full PA/UA/F1 sweep, every cutoff 0-100, for binary vs c3 vs c4 side by side. These three
# CSVs are all SW ablation-scope (build_02 Section 7b) -- apples-to-apples across schemes.
# ============================================================================================

scheme_files <- c(binary = "binary_val_probability_scores_2022.csv",
                  c3     = "c3_val_probability_scores_2022.csv",
                  c4     = "c4_val_probability_scores_2022.csv")
# here() drops names, so re-attach them -- imap_dfr() below keys the class_scheme column off them.
scheme_paths <- set_names(here("data", "raw", "embedding", scheme_files), names(scheme_files))
present      <- file.exists(scheme_paths)
if (!any(present)) stop("No per-scheme scored CSVs found -- run build_02 Section 7b first.")

cross <- imap_dfr(scheme_paths[present], function(p, s) {
  df <- read_csv(p, show_col_types = FALSE)
  map_dfr(0:100, ~ sweep_threshold(df, .x)) |> mutate(class_scheme = s, .before = 1)
})

cross_wide <- cross |>
  select(class_scheme, threshold, pa, ua, f1) |>
  pivot_wider(names_from = class_scheme, values_from = c(pa, ua, f1))
out_path <- file.path(tab_dir, "class_scheme_threshold_sweep.csv")
write_csv(cross_wide, out_path)
cat(sprintf("\n=== PART 2: wrote cross-scheme 0-100 sweep -> %s ===\n", out_path))
print(cross_wide |> filter(threshold %% 10 == 0), n = Inf)

p_cross <- cross |>
  select(class_scheme, threshold, pa, ua, f1) |>
  pivot_longer(c(pa, ua, f1), names_to = "metric", values_to = "value") |>
  ggplot(aes(threshold, value, colour = class_scheme)) +
  geom_line(linewidth = 0.9) +
  geom_vline(xintercept = SETTLED_CUTOFF, linetype = "dashed", colour = "grey40") +
  facet_wrap(~ factor(metric, c("pa", "ua", "f1"),
                      c("Recall (PA)", "Precision (UA)", "F1"))) +
  scale_y_continuous(labels = label_percent()) +
  labs(title = "Cutoff sweep by class scheme (SW ablation scope)",
       subtitle = sprintf("Dashed line = settled cutoff %d", SETTLED_CUTOFF),
       x = "Cutoff (mine_prob >= x)", y = NULL, colour = "Scheme") +
  theme_bw(base_size = 11)
ggsave(file.path(fig_dir, "cross_scheme_cutoff_sweep.png"), p_cross, width = 11, height = 4.5, dpi = 150)

# ============================================================================================
# PART 3 -- deployed model: PR curve + ROC + recommended cutoffs (was validate_probability_
# threshold.R). Uses the ACTUAL deployed national classifier's scores (c4 + no_maus + national
# negatives), which is a different, broader spatial frame than Part 2's SW ablation CSVs.
# ============================================================================================

dep_path <- here("data", "raw", "embedding", "c4_national_val_probability_scores_2022.csv")
stopifnot("Deployed-model scored CSV not found -- run build_02 Section 9 first" =
            file.exists(dep_path))
dep <- read_csv(dep_path, show_col_types = FALSE)
cat(sprintf("\n=== PART 3: deployed c4/no_maus national model, %d SmallMinesDS-2022 points ===\n",
            nrow(dep)))
cat(sprintf("  %d mining / %d non-mining\n", sum(dep$label == 1), sum(dep$label == 0)))

dep_sweep <- map_dfr(0:100, ~ sweep_threshold(dep, .x))

p_pr_curve <- ggplot(dep_sweep, aes(threshold)) +
  geom_line(aes(y = pa, colour = "Recall (PA)"), linewidth = 1) +
  geom_line(aes(y = ua, colour = "Precision (UA)"), linewidth = 1) +
  geom_line(aes(y = f1, colour = "F1"), linewidth = 1, linetype = "dashed") +
  geom_vline(xintercept = SETTLED_CUTOFF, linetype = "dashed", colour = "grey40") +
  scale_y_continuous(labels = label_percent()) +
  scale_colour_manual(values = c("Recall (PA)" = "#450457", "Precision (UA)" = "#D94701",
                                 "F1" = "grey30"), name = NULL) +
  labs(title = "Deployed model: precision / recall / F1 across cutoffs",
       subtitle = sprintf("Held-out SmallMinesDS-2022; dashed vertical = settled cutoff %d", SETTLED_CUTOFF),
       x = "Cutoff (mine_prob >= x)", y = NULL) +
  theme_bw(base_size = 11)
ggsave(file.path(fig_dir, "deployed_precision_recall_curve.png"), p_pr_curve, width = 8, height = 5, dpi = 150)

roc_ord <- dep_sweep |> arrange(fpr)
auc <- sum(diff(roc_ord$fpr) * (head(roc_ord$pa, -1) + tail(roc_ord$pa, -1)) / 2)
p_roc <- ggplot(roc_ord, aes(fpr, pa)) +
  geom_line(colour = "#450457", linewidth = 1) +
  geom_abline(slope = 1, intercept = 0, linetype = "dotted", colour = "grey60") +
  scale_x_continuous(labels = label_percent()) + scale_y_continuous(labels = label_percent()) +
  labs(title = sprintf("Deployed model ROC (AUC = %.3f)", auc),
       subtitle = "Dotted line = random guessing",
       x = "False-positive rate", y = "True-positive rate (recall)") +
  theme_bw(base_size = 11)
ggsave(file.path(fig_dir, "deployed_roc_curve.png"), p_roc, width = 6, height = 6, dpi = 150)

f1_best     <- dep_sweep |> filter(!is.na(f1)) |> slice_max(f1, n = 1, with_ties = FALSE)
youden_best <- dep_sweep |> mutate(youden = pa - fpr) |> slice_max(youden, n = 1, with_ties = FALSE)
at_settled  <- dep_sweep |> filter(threshold == SETTLED_CUTOFF)

cat("\n--- Part 3: cutoffs ---\n")
cat(sprintf("  Settled (deployed):  mine_prob >= %d   PA %.3f, UA %.3f, F1 %.3f\n",
            SETTLED_CUTOFF, at_settled$pa, at_settled$ua, at_settled$f1))
cat(sprintf("  F1-maximizing:       mine_prob >= %d   PA %.3f, UA %.3f, F1 %.3f  (reference only)\n",
            f1_best$threshold, f1_best$pa, f1_best$ua, f1_best$f1))
cat(sprintf("  Youden's J-max:      mine_prob >= %d   PA %.3f, 1-FPR %.3f\n",
            youden_best$threshold, youden_best$pa, 1 - youden_best$fpr))
cat(sprintf("  AUC: %.3f\n", auc))

message("\n=== diag_02_scoring.R complete ===")
