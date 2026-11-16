# util_fetch_drive_exports.R -- download finished Earth Engine CSV exports from Google Drive
#
# EE table exports (toDrive) land in the Drive folder DRIVE_FOLDER. This copies every CSV there
# whose name matches PATTERN into outputs/tables/backdating/, skipping files already present locally
# (set OVERWRITE <- TRUE to refresh them). If Drive holds several files with the same name (a re-run
# export), the most recently modified one is taken.
# Needs only a Google Drive login, no Earth Engine session. Use the same Google account as for EE.

pacman::p_load(here, googledrive, tidyverse, conflicted)
conflicts_prefer(dplyr::filter, here::here)

DRIVE_FOLDER <- "ghana_mining_gee_exports"
# Current exports only. Older window experiments (2005-2016, 2000-2016, 2007-2016) and the
# single-method fidelity run were deleted locally on 2026-11-13 and are still on Drive -- a broader
# pattern would download them again.
PATTERN      <- "^build_04_.*_min2000_max2017|^validate_backdating_fidelity_(3methods|a1|e)"
OUT_DIR      <- here("outputs", "tables", "backdating")
OVERWRITE    <- FALSE

googledrive::drive_auth()
folder <- googledrive::drive_find(pattern = DRIVE_FOLDER, type = "folder", n_max = 1)
if (nrow(folder) == 0) stop("Drive folder '", DRIVE_FOLDER, "' not found -- check googledrive::drive_user().")

files <- googledrive::drive_ls(folder[1, ]) |>
  filter(str_detect(name, PATTERN), str_detect(name, "\\.csv$")) |>
  mutate(modified = map_chr(drive_resource, "modifiedTime")) |>
  arrange(desc(modified)) |>
  distinct(name, .keep_all = TRUE)

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
fetched <- character()
for (i in seq_len(nrow(files))) {
  dest <- file.path(OUT_DIR, files$name[i])
  if (file.exists(dest) && !OVERWRITE) next
  googledrive::drive_download(files[i, ], path = dest, overwrite = TRUE)
  fetched <- c(fetched, files$name[i])
}
message(if (length(fetched)) paste0("Downloaded ", length(fetched), " file(s):\n  ", paste(fetched, collapse = "\n  "))
        else "Nothing new -- every matching Drive export is already in outputs/tables/backdating/.")
