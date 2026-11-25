# ring1_dominance_diagnostic.R
# Does ring 1 still set the cumulative within-3-hop treatment clock at higher stock thresholds?
# For each mbar, classify within-3-hop UPSTREAM-treated hexes by what trips the threshold:
#   (a) ring 1 alone sets the clock   (le3 onset year == 1-hop onset year)
#   (b) rings 2-3 advance the clock   (ring 1 crosses too, but the aggregate crosses earlier)
#   (c) rings 2-3 create the treatment (ring 1 never crosses mbar; 1-hop would call it never-treated)
# Motivation + result table: event_study_design.md, hop-ring caveat point 2. Standalone diagnostic;
# reads the assembled event panel only, writes nothing.
#
# Run: source(here::here("code", "3_analysis", "ring1_dominance_diagnostic.R"))

pacman::p_load(dplyr, tidyr, here)

RES  <- 5                       # resolution (km); 5 is the primary grid
MBAR <- c(0, 5, 10, 20)         # stock thresholds, matching a_05_event_study_2.Rmd's mbar_grid

p <- readRDS(here("data", "processed", sprintf("event_panel_%dkm.rds", RES)))$panel

# onset (first year stock strictly exceeds mbar), per hex, for an arbitrary stock column
onset_of <- function(df, stock_col, mbar) {
  df |>
    group_by(hex_id) |>
    summarise(g = { y <- year[!is.na(.data[[stock_col]]) & .data[[stock_col]] > mbar]
                    if (length(y)) min(y) else NA_integer_ }, .groups = "drop")
}

# cumulative within-3 upstream stock = sum of the three disjoint ring stocks
p <- p |>
  mutate(up_le3_stock_ha = rowSums(cbind(nearest_up_stock_ha, up_hop2_stock_ha, up_hop3_stock_ha),
                                   na.rm = TRUE),
         on_graph = !is.na(nearest_up_stock_ha))   # rowSums(na.rm) turns off-graph rows into 0; flag them

res <- lapply(MBAR, function(mb) {
  o_le3  <- onset_of(filter(p, on_graph), "up_le3_stock_ha",     mb) |> rename(g_le3  = g)
  o_1hop <- onset_of(filter(p, on_graph), "nearest_up_stock_ha", mb) |> rename(g_1hop = g)
  d <- full_join(o_le3, o_1hop, by = "hex_id") |> filter(!is.na(g_le3))   # within-3-treated only
  n_le3 <- nrow(d)
  d <- d |> mutate(cat = case_when(
    is.na(g_1hop)   ~ "rings2-3 create treatment",
    g_1hop == g_le3 ~ "ring1 sets clock",
    g_1hop >  g_le3 ~ "rings2-3 advance clock"))
  tab <- d |> count(cat) |> mutate(share = n / n_le3)
  tibble(mbar = mb, n_treated_le3 = n_le3, n_treated_1hop = sum(!is.na(d$g_1hop)),
         extra_hexes_vs1hop = n_le3 - sum(!is.na(d$g_1hop)),
         ring1_sets_clock  = tab$share[match("ring1 sets clock",           tab$cat)],
         r23_advance_clock = tab$share[match("rings2-3 advance clock",     tab$cat)],
         r23_create_treat  = tab$share[match("rings2-3 create treatment",  tab$cat)])
}) |> bind_rows() |>
  mutate(across(c(ring1_sets_clock, r23_advance_clock, r23_create_treat),
                ~round(replace_na(., 0), 3)))

cat(sprintf("\n=== Ring-1 dominance of the UPSTREAM clock, by stock threshold (%d km, ROUTE_KM2=10) ===\n\n", RES))
print(as.data.frame(res), row.names = FALSE)
cat("\n ring1_sets_clock  = within-3 onset year equals 1-hop onset year (ring 1 alone trips mbar)\n",
    "r23_advance_clock = ring 1 also crosses, but the aggregate crosses in an EARLIER year\n",
    "r23_create_treat  = ring 1 never crosses mbar; hex is treated only via rings 2-3\n",
    "extra_hexes_vs1hop= treated hexes present under le3 but not under the 1-hop definition\n")
