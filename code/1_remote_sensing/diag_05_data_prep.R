# diag_05_data_prep.R -- EE auth, downloads, and figure/table generation for
# diag_05_mining_by_region.qmd. Run this interactively in RStudio first (needs a live EE login);
# the .qmd only reads what this script writes to outputs/figures/diag_05/ and outputs/tables/diag_05/
# (plus the three canonical outputs/tables/*.csv also consumed elsewhere -- see explainer.md).

rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, sf, here, tidyverse, janitor, scales, googledrive, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, here::here
)

UTM30N        <- 32630
EE_PROJECT    <- "rgee-auth-tillam"
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
EMBED_YEARS   <- 2017:2025
OVERVIEW_FIRST_YEAR <- 2020

MINING_PALETTE <- c("#FCFDBF", "#FEC287", "#FD9567", "#F1605D", "#CD4071", "#9E2F7F", "#721F81", "#450457")

DRIVE_FOLDER <- "ghana_mining_gee_exports"
fig_dir <- here("outputs", "figures", "diag_05")
tbl_dir <- here("outputs", "tables", "diag_05")
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(tbl_dir, recursive = TRUE, showWarnings = FALSE)

ee_Authenticate()
ee_Initialize(drive = TRUE, project = EE_PROJECT)
# ee_Initialize(drive = TRUE) doesn't hand googledrive a working token on its own -- needs its own
# explicit auth call (same pattern as build_02_embedding_classifier.R / d_01_download_gee.R).
googledrive::drive_auth()

drive_download_export <- function(name_pattern, dest_path) {
  export_folder <- googledrive::drive_find(pattern = DRIVE_FOLDER, type = "folder", n_max = 1)
  if (nrow(export_folder) == 0)
    stop("Export folder '", DRIVE_FOLDER, "' not found -- check googledrive::drive_user().")
  contents <- googledrive::drive_ls(export_folder[1, ])
  hit <- contents[grepl(name_pattern, contents$name, fixed = TRUE), ]
  if (nrow(hit) == 0) return(invisible(FALSE))
  googledrive::drive_download(hit[1, ], path = dest_path, overwrite = TRUE)
  invisible(TRUE)
}

# ee_monitoring() reads destination_uris before a still-RUNNING task has populated that field
# (known rgee bug, same as build_04_backdating.R) -- only ever read `state`.
poll_task <- function(task, interval = 15) {
  repeat {
    state <- ee$batch$Task$status(task)[["state"]]
    message("  task state: ", state, " (", format(Sys.time(), "%H:%M:%S"), ")")
    if (state %in% c("COMPLETED", "FAILED", "CANCELLED")) break
    Sys.sleep(interval)
  }
  if (state != "COMPLETED")
    stop("EE task ended in state '", state, "' -- check the Code Editor Tasks tab (project ", EE_PROJECT, ").")
  invisible(state)
}

latest_col <- paste0("mining_", max(EMBED_YEARS))
first_col  <- paste0("mining_", min(EMBED_YEARS))
overview_first_col <- paste0("mining_", OVERVIEW_FIRST_YEAR)

## -- 1. Build the cumulative mining panel and pull it by district -----------------------------

cum_mine_by_year <- list()
running_mine <- ee$Image(0)$rename("cum_mine")
for (yr in EMBED_YEARS) {
  mine_yr <- ee$Image(paste0(EE_ASSET_HOME, "/mine_mask_ghana_c4_", yr))$unmask(0)
  running_mine <- running_mine$Or(mine_yr)$rename(paste0("cum_mine_", yr))
  cum_mine_by_year[[as.character(yr)]] <- running_mine
}

area_km2 <- ee$Image$pixelArea()$divide(1e6)
mining_bands <- ee$Image$cat(lapply(EMBED_YEARS, function(yr) {
  cum_mine_by_year[[as.character(yr)]]$multiply(area_km2)$rename(paste0("mining_", yr))
}))

# select(adm2_name, geometry) etc. BEFORE sf_as_ee -- the valid_on/valid_to NA columns crash
# sf_as_ee() otherwise (CLAUDE.md caveat).
districts_sf <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin2.shp"), quiet = TRUE) |>
  clean_names() |>
  select(adm2_name, adm1_name, geometry) |>
  st_make_valid()

districts_ee <- sf_as_ee(st_transform(districts_sf, 4326))

# NOT ee_extract() -- it calls ee$Image$reduceRegions(image=img, ...), a calling convention the
# installed earthengine-api no longer accepts. Direct instance-method call instead, joined back by
# adm2_name (reduceRegions() doesn't guarantee output order == input order).
#
# NOT a synchronous getInfo() either -- national scale, 9 bands, 260 districts hits EE's ~5min
# interactive ceiling. Batch export + poll + download, with skip-if-exists on re-run.
district_reduced <- mining_bands$reduceRegions(
  collection = districts_ee, reducer = ee$Reducer$sum(), scale = 30, tileScale = 8L
)
district_dsn <- here("outputs", "tables", "diag05_district_mining_panel_raw.csv")
dir.create(dirname(district_dsn), recursive = TRUE, showWarnings = FALSE)

if (drive_download_export("diag05_district_mining_panel", district_dsn)) {
  message("Found existing diag05_district_mining_panel export on Drive -- skipping resubmission.")
} else {
  district_task <- ee$batch$Export$table$toDrive(
    collection = district_reduced$select(c("adm2_name", paste0("mining_", EMBED_YEARS))),
    description = "diag05_district_mining_panel", folder = DRIVE_FOLDER, fileFormat = "CSV"
  )
  district_task$start()
  message("Submitted district panel export (national, 9 bands, 260 districts) -- BLOCKING until done.")
  poll_task(district_task)
  if (!drive_download_export("diag05_district_mining_panel", district_dsn))
    stop("Export completed but file not found in Drive folder '", DRIVE_FOLDER, "' -- check manually.")
}
district_stats <- read_csv(district_dsn, show_col_types = FALSE)

district_panel <- districts_sf |>
  st_drop_geometry() |>
  left_join(district_stats |> select(adm2_name, starts_with("mining_")), by = "adm2_name") |>
  as_tibble()

region_panel <- district_panel |>
  group_by(adm1_name) |>
  summarise(across(starts_with("mining_"), sum), n_districts = n(), .groups = "drop")

write_csv(district_panel, here("outputs", "tables", "mining_by_district.csv"))
write_csv(region_panel, here("outputs", "tables", "mining_by_region.csv"))

## -- 2. National total (sanity check) ----------------------------------------------------------

# Same ee_extract() bug as above -- direct reduceRegion() (singular) instead. scale=100 (not 30)
# deliberately -- rough sanity check only, and a whole-country 30m reduceRegion risks the same
# timeout the district pull hit above.
national_geom <- sf_as_ee(st_transform(st_union(districts_sf) |> st_as_sf(), 4326))$geometry()
national_direct <- mining_bands$select(latest_col)$reduceRegion(
  reducer = ee$Reducer$sum(), geometry = national_geom, scale = 100, maxPixels = 1e10, tileScale = 8L
)$getInfo()

national_check <- tibble(
  method = c("sum of districts", "direct national reduceRegion"),
  km2 = c(sum(district_panel[[latest_col]]), national_direct[[latest_col]])
)
write_csv(national_check, here(tbl_dir, "national_check.csv"))

## -- 3. Distribution of region-level mining area -----------------------------------------------

p_region_hist <- ggplot(region_panel, aes(x = .data[[latest_col]])) +
  geom_histogram(bins = 16, fill = "#721F81", colour = "white") +
  labs(x = "Cumulative mining area (km2)", y = "Number of regions",
       title = "Region-level cumulative mining area") +
  theme_minimal(base_size = 12)
ggsave(here(fig_dir, "fig_region_hist.png"), p_region_hist, width = 9, height = 5.5, dpi = 150)

## -- 4. Region ranking --------------------------------------------------------------------------

p_region_bar <- region_panel |>
  mutate(adm1_name = fct_reorder(adm1_name, .data[[latest_col]])) |>
  ggplot(aes(x = .data[[latest_col]], y = adm1_name, fill = .data[[latest_col]])) +
  geom_col() +
  scale_fill_gradientn(colours = MINING_PALETTE, trans = "sqrt", labels = label_comma(),
                        name = "Area (km2)") +
  labs(x = "Cumulative mining area (km2)", y = NULL,
       title = paste0("Cumulative galamsey coverage by region, through ", max(EMBED_YEARS))) +
  theme_minimal(base_size = 12)
ggsave(here(fig_dir, "fig_region_bar.png"), p_region_bar, width = 9, height = 6, dpi = 150)

## -- 5. Region overview: level + growth together ------------------------------------------------

region_overview <- region_panel |>
  transmute(
    adm1_name,
    level_first = .data[[overview_first_col]],
    growth      = .data[[latest_col]] - .data[[overview_first_col]],
    total       = .data[[latest_col]]
  )
region_order <- region_overview |> arrange(total) |> pull(adm1_name)

p_region_overview <- region_overview |>
  pivot_longer(cols = c(level_first, growth), names_to = "component", values_to = "km2") |>
  mutate(
    component = if_else(component == "level_first",
                         paste0("Mining, ", OVERVIEW_FIRST_YEAR),
                         paste0("Growth to ", max(EMBED_YEARS))),
    component = factor(component, levels = c(paste0("Growth to ", max(EMBED_YEARS)),
                                               paste0("Mining, ", OVERVIEW_FIRST_YEAR))),
    adm1_name = factor(adm1_name, levels = region_order)
  ) |>
  ggplot(aes(x = km2, y = adm1_name, fill = component)) +
  geom_col() +
  scale_fill_manual(
    values = setNames(c("#CD4071", "grey70"),
                       c(paste0("Growth to ", max(EMBED_YEARS)), paste0("Mining, ", OVERVIEW_FIRST_YEAR))),
    name = NULL
  ) +
  labs(x = "Area (km2)", y = NULL,
       title = paste0("Gold mining footprint by region -- ", OVERVIEW_FIRST_YEAR,
                       " level + growth to ", max(EMBED_YEARS))) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "top")
ggsave(here(fig_dir, "fig_region_overview_combined.png"), p_region_overview, width = 9, height = 6, dpi = 150)

## -- 6. Mining increase by region ----------------------------------------------------------------

region_increase <- region_panel |>
  transmute(
    adm1_name,
    mining_first = .data[[first_col]],
    mining_last  = .data[[latest_col]],
    increase_km2 = mining_last - mining_first,
    increase_pct = if_else(mining_first > 0, 100 * increase_km2 / mining_first, NA_real_)
  ) |>
  arrange(desc(increase_km2))
write_csv(region_increase, here(tbl_dir, "region_increase.csv"))

p_region_increase_bar <- region_increase |>
  mutate(adm1_name = fct_reorder(adm1_name, increase_km2)) |>
  ggplot(aes(x = increase_km2, y = adm1_name, fill = increase_km2)) +
  geom_col() +
  scale_fill_gradientn(colours = MINING_PALETTE, trans = "sqrt", labels = label_comma(),
                        name = "Increase (km2)") +
  labs(x = "Increase in cumulative mining area (km2)", y = NULL,
       title = paste0("Mining growth by region, ", min(EMBED_YEARS), "-", max(EMBED_YEARS))) +
  theme_minimal(base_size = 12)
ggsave(here(fig_dir, "fig_region_increase_bar.png"), p_region_increase_bar, width = 9, height = 6, dpi = 150)

## -- 7. Top 10 districts --------------------------------------------------------------------------

top10_districts <- district_panel |>
  transmute(
    adm2_name, adm1_name,
    mining_first = .data[[first_col]],
    mining_last  = .data[[latest_col]],
    increase_km2 = mining_last - mining_first
  ) |>
  arrange(desc(mining_last)) |>
  slice_head(n = 10)
write_csv(top10_districts, here(tbl_dir, "top10_districts.csv"))

p_top10_bar <- top10_districts |>
  mutate(district_label = paste0(adm2_name, " (", adm1_name, ")"),
         district_label = fct_reorder(district_label, mining_last)) |>
  ggplot(aes(x = mining_last, y = district_label, fill = mining_last)) +
  geom_col() +
  scale_fill_gradientn(colours = MINING_PALETTE, trans = "sqrt", labels = label_comma(),
                        name = "Area (km2)") +
  labs(x = "Cumulative mining area (km2)", y = NULL,
       title = paste0("Top 10 districts by cumulative galamsey coverage, through ", max(EMBED_YEARS))) +
  theme_minimal(base_size = 12)
ggsave(here(fig_dir, "fig_top10_districts_bar.png"), p_top10_bar, width = 9, height = 6, dpi = 150)

## -- 8. Mining encroachment on protected areas ------------------------------------------------------

protected_areas_ee <- ee$FeatureCollection("WCMC/WDPA/current/polygons")$
  merge(ee$FeatureCollection("WCMC/WDOECM/current/polygons"))$
  filter(ee$Filter$And(ee$Filter$eq("ISO3", "GHA"), ee$Filter$eq("STATUS", "Designated")))
# And(), NOT and() -- `and` is a reserved Python keyword, unlike JS.
protected_mask <- ee$Image()$byte()$paint(protected_areas_ee, 1)$unmask(0)

latest_cum_mine <- cum_mine_by_year[[as.character(max(EMBED_YEARS))]]
pa_bands <- ee$Image$cat(list(
  latest_cum_mine$multiply(area_km2)$multiply(protected_mask)$rename("mining_in_pa"),
  protected_mask$multiply(area_km2)$rename("pa_area")
))

pa_dsn <- here("outputs", "tables", "diag05_district_protected_overlap_raw.csv")
dir.create(dirname(pa_dsn), recursive = TRUE, showWarnings = FALSE)

if (drive_download_export("diag05_district_protected_overlap", pa_dsn)) {
  message("Found existing diag05_district_protected_overlap export on Drive -- skipping resubmission.")
} else {
  pa_reduced <- pa_bands$reduceRegions(
    collection = districts_ee, reducer = ee$Reducer$sum(), scale = 30, tileScale = 8L
  )
  pa_task <- ee$batch$Export$table$toDrive(
    collection = pa_reduced$select(c("adm2_name", "mining_in_pa", "pa_area")),
    description = "diag05_district_protected_overlap", folder = DRIVE_FOLDER, fileFormat = "CSV"
  )
  pa_task$start()
  message("Submitted district protected-overlap export -- BLOCKING until done.")
  poll_task(pa_task)
  if (!drive_download_export("diag05_district_protected_overlap", pa_dsn))
    stop("Export completed but file not found in Drive folder '", DRIVE_FOLDER, "' -- check manually.")
}

pa_stats <- read_csv(pa_dsn, show_col_types = FALSE)

protected_overlap <- district_panel |>
  transmute(adm2_name, adm1_name, mining_total = .data[[latest_col]]) |>
  left_join(pa_stats |> select(adm2_name, mining_in_pa, pa_area), by = "adm2_name") |>
  mutate(
    across(c(mining_in_pa, pa_area), ~ replace_na(.x, 0)),
    pct_mining_in_pa = if_else(mining_total > 0, 100 * mining_in_pa / mining_total, NA_real_)
  )
# Hardcoded path -- `out_dir`-style generic names have silently redirected this write before
# (a_01_incidence_maps_rs.R uses the same variable name for a different value in the same session).
write_csv(protected_overlap, here("outputs", "tables", "mining_protected_overlap_by_district.csv"))

protected_overlap_top15 <- protected_overlap |>
  filter(mining_in_pa > 0) |>
  arrange(desc(mining_in_pa)) |>
  slice_head(n = 15)
write_csv(protected_overlap_top15, here(tbl_dir, "protected_overlap_top15.csv"))

national_pa_summary <- tibble(
  year = max(EMBED_YEARS),
  nat_mining_in_pa = sum(protected_overlap$mining_in_pa),
  nat_mining_total = sum(protected_overlap$mining_total),
  pct_mining_in_pa = 100 * nat_mining_in_pa / nat_mining_total
)
write_csv(national_pa_summary, here(tbl_dir, "national_pa_summary.csv"))

p_protected_bar <- protected_overlap |>
  filter(mining_in_pa > 0) |>
  slice_max(mining_in_pa, n = 15) |>
  mutate(district_label = paste0(adm2_name, " (", adm1_name, ")"),
         district_label = fct_reorder(district_label, mining_in_pa)) |>
  ggplot(aes(x = mining_in_pa, y = district_label, fill = pct_mining_in_pa)) +
  geom_col() +
  scale_fill_gradientn(colours = MINING_PALETTE, trans = "sqrt", labels = \(x) paste0(round(x), "%"),
                        name = "% of district's\nmining in a PA") +
  labs(x = "Mining area inside a protected area (km2)", y = NULL,
       title = paste0("Gold mining encroachment on protected areas, top 15 districts, through ", max(EMBED_YEARS)),
       caption = "WDPA/WDOECM, Designated status only. Bar length = absolute area; fill = share of that district's own mining.") +
  theme_minimal(base_size = 12)
ggsave(here(fig_dir, "fig_protected_areas_bar.png"), p_protected_bar, width = 9, height = 6.5, dpi = 150)

## -- metadata for the .qmd (years etc., so it never has to touch EE) ----------------------------

saveRDS(
  list(embed_years = EMBED_YEARS, overview_first_year = OVERVIEW_FIRST_YEAR),
  here(tbl_dir, "diag05_meta.rds")
)

message("diag_05_data_prep.R done -- figures in ", fig_dir, ", tables in ", tbl_dir,
        ". Render diag_05_mining_by_region.qmd next.")
