# validate_gee_assets.R
# Inventory + completeness check for every EE asset the RS pipeline depends on, so "are all the
# assets on GEE yet?" has a definitive answer before build_03_embedding_panel.R is run.
#
# Checks three groups under projects/rgee-auth-tillam/assets/ghana_mining/:
#   A. Support assets that build_02 Section 5 uploads (point/polygon FeatureCollections).
#   B. build_02 Section 10 output: the c4 national probability TILES,
#      mine_prob_ghana_c4_{yr}_t{NN} for yr 2017-2025 x tile t01..tNN. This is the group the
#      "all assets should now be on GEE" claim is really about -- build_03 mosaics these.
#   C. build_03_embedding_panel.R output: mine_mask_ghana_c4_{yr}. Expected ABSENT until
#      build_03 has been run -- listed so the check also confirms when that step is done.
#
# The tile grid is rebuilt with the SAME logic as build_02 Section 10a / build_03 Section 4
# (150 km squares over gha_admin0, dropping cells that don't touch Ghana) so the expected tile
# IDs are authoritative, not hardcoded. If build_02's TILE_KM changed, change TILE_KM here too.
#
# Run INTERACTIVELY: ee_Authenticate()/ee_Initialize() block on a browser login. Read-only --
# only getAsset()/listAssets(), no exports, no writes.

####1. Environment ####
rgee_env_dir <- "C:\\Users\\ADMIN\\AppData\\Local\\r-miniconda\\envs\\rgee_py\\"
Sys.setenv(RETICULATE_PYTHON  = rgee_env_dir)
Sys.setenv(EARTHENGINE_PYTHON = rgee_env_dir)

library(reticulate)
pacman::p_load(rgee, tidyverse, sf, here, conflicted)
conflicts_prefer(dplyr::filter, dplyr::select, dplyr::mutate, here::here)

UTM30N     <- 32630
EE_PROJECT <- "rgee-auth-tillam"                 # ID, never the numeric project number

####2. Authenticate ####
rgee::ee_Authenticate()
rgee::ee_Initialize(drive = TRUE, project = EE_PROJECT)

####3. Parameters ####
EE_ASSET_HOME <- sprintf("projects/%s/assets/ghana_mining", EE_PROJECT)
FINAL_SCHEME  <- "c4"
PROB_PREFIX   <- sprintf("mine_prob_ghana_%s_", FINAL_SCHEME)   # build_02 Section 10
MASK_PREFIX   <- sprintf("mine_mask_ghana_%s_", FINAL_SCHEME)   # build_03 output
EMBED_YEARS   <- 2017:2025
TILE_KM       <- 150

SUPPORT_ASSETS <- c("rs05_train_pts", "rs05_study_area", "rs05_ghana", "rs05_val_pts_2022",
                    "mc4_train_pts_tagged")   # persisted 4-class training pts (trial_4class / validate JS)

asset_exists <- function(id) tryCatch({ ee$data$getAsset(id); TRUE }, error = function(e) FALSE)

####4. Rebuild the export tile grid (mirror build_02 Section 10a) ####
ghana_utm <- st_read(here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp"),
                     quiet = TRUE) |>
  select(geometry) |> st_make_valid() |> st_union() |>
  st_transform(UTM30N) |> st_simplify(dTolerance = 100)

tile_grid_utm <- st_make_grid(ghana_utm, cellsize = TILE_KM * 1000, square = TRUE)
tiles_utm     <- tile_grid_utm[lengths(st_intersects(tile_grid_utm, ghana_utm)) > 0]
tile_ids      <- sprintf("t%02d", seq_along(tiles_utm))
message(sprintf("Expected tile grid: %d tiles at TILE_KM=%d (%s..%s)",
                length(tile_ids), TILE_KM, tile_ids[1], tail(tile_ids, 1)))

####5. Group A -- support assets ####
support_tbl <- tibble(asset = SUPPORT_ASSETS) |>
  mutate(id = file.path(EE_ASSET_HOME, asset),
         present = map_lgl(id, asset_exists))

cat("\n===== A. Support assets (build_02 Section 5) =====\n")
support_tbl |> mutate(status = if_else(present, "OK", "MISSING")) |>
  select(asset, status) |> as.data.frame() |> print(row.names = FALSE)

####6. Group B -- c4 national probability tiles (build_02 Section 10) ####
prob_grid <- expand_grid(year = EMBED_YEARS, tile = tile_ids) |>
  mutate(id = file.path(EE_ASSET_HOME, sprintf("%s%d_%s", PROB_PREFIX, year, tile)),
         present = map_lgl(id, asset_exists))

# year x tile presence matrix (Y = present, . = missing)
prob_matrix <- prob_grid |>
  mutate(cell = if_else(present, "Y", ".")) |>
  select(year, tile, cell) |>
  pivot_wider(names_from = tile, values_from = cell)

cat(sprintf("\n===== B. %s{yr}_{tile} probability tiles (build_02 Section 10) =====\n", PROB_PREFIX))
cat(sprintf("Expected %d tiles x %d years = %d assets\n",
            length(tile_ids), length(EMBED_YEARS), nrow(prob_grid)))
print(as.data.frame(prob_matrix), row.names = FALSE)

prob_by_year <- prob_grid |> group_by(year) |>
  summarise(present = sum(present), expected = n(), .groups = "drop") |>
  mutate(complete = present == expected)
cat("\nPer-year completeness:\n")
print(as.data.frame(prob_by_year), row.names = FALSE)

missing_tiles <- prob_grid |> filter(!present) |> mutate(tag = sprintf("%d/%s", year, tile))
if (nrow(missing_tiles) == 0) {
  cat(sprintf("\n>>> GROUP B COMPLETE: all %d c4 probability tiles are on GEE.\n", nrow(prob_grid)))
} else {
  cat(sprintf("\n>>> GROUP B INCOMPLETE: %d/%d tiles missing:\n    %s\n",
              nrow(missing_tiles), nrow(prob_grid),
              paste(missing_tiles$tag, collapse = ", ")))
  cat("    (re-run build_02 Section 10 -- its skip-if-exists loop fills only the gaps.)\n")
}

# Leftover split sub-tiles: mine_prob_ghana_c4_{yr}_t{NN}s{MM}. Their existence alongside a
# present parent tile just means Section 10b's recombine ran but the sub-tiles weren't cleaned
# up -- harmless, but listed so the folder inventory isn't surprising.
subtile_hits <- expand_grid(year = EMBED_YEARS, tile = tile_ids, sub = sprintf("s%02d", 1:16)) |>
  mutate(id = file.path(EE_ASSET_HOME, sprintf("%s%d_%s%s", PROB_PREFIX, year, tile, sub)),
         present = map_lgl(id, asset_exists)) |>
  filter(present)
if (nrow(subtile_hits) > 0) {
  cat(sprintf("\nNote: %d leftover split sub-tiles present (e.g. %s) -- cosmetic, safe to delete.\n",
              nrow(subtile_hits),
              paste(sprintf("%d/%s%s", subtile_hits$year[1], subtile_hits$tile[1], subtile_hits$sub[1]))))
}

####7. Group C -- build_03 output masks (expected absent until build_03 runs) ####
mask_tbl <- tibble(year = EMBED_YEARS) |>
  mutate(id = file.path(EE_ASSET_HOME, sprintf("%s%d", MASK_PREFIX, year)),
         present = map_lgl(id, asset_exists))
cat(sprintf("\n===== C. %s{yr} annual mine masks (build_03 output) =====\n", MASK_PREFIX))
mask_tbl |> mutate(status = if_else(present, "OK", "not yet")) |>
  select(year, status) |> as.data.frame() |> print(row.names = FALSE)
if (all(mask_tbl$present)) cat(">>> build_03 has been run for all years.\n")
if (!any(mask_tbl$present)) cat(">>> build_03 not run yet (expected at this stage).\n")

####8. Full folder inventory (ground truth, independent of the expected-name logic above) ####
cat(sprintf("\n===== Full listing of %s =====\n", EE_ASSET_HOME))
inv <- tryCatch(
  ee$data$listAssets(list(parent = EE_ASSET_HOME)),
  error = function(e) { message("listAssets failed: ", conditionMessage(e)); NULL })
if (!is.null(inv) && length(inv$assets) > 0) {
  inv_tbl <- map_dfr(inv$assets, ~ tibble(name = sub(".*/", "", .x$name), type = .x$type))
  cat(sprintf("%d assets in folder. By family:\n", nrow(inv_tbl)))
  inv_tbl |>
    mutate(family = case_when(
      grepl("^mine_prob_ghana_c4_\\d{4}_t\\d+s\\d+$", name) ~ "c4 prob sub-tile (split leftover)",
      grepl("^mine_prob_ghana_c4_\\d{4}_t\\d+$",       name) ~ "c4 prob tile (build_02 s10)",
      grepl("^mine_prob_ghana_\\d{4}$",                name) ~ "OLD binary prob map (stale, kept)",
      grepl("^mine_mask_ghana_c4_\\d{4}$",             name) ~ "c4 annual mask (build_03)",
      grepl("^gt_compare_",                            name) ~ "ground-truth-compare AOI asset",
      grepl("^rs05_|^mc4_",                            name) ~ "support / training asset",
      TRUE ~ "other")) |>
    count(family, name = "n") |> as.data.frame() |> print(row.names = FALSE)
  cat("\nFull name list:\n")
  print(sort(inv_tbl$name))
}

cat("\n=== validate_gee_assets.R: done ===\n")
