# d_08_dhs_data.R
# Pulls Ghana DHS (Demographic and Health Survey) data via the `rdhs` package:
# economic/employment, household wealth, and maternal/newborn health, all from the IR
# (women's) recode, plus GE cluster coordinates for later spatial join onto the hex/
# district panel. Design + how to add a new domain: code/0_data/explainer.md.
#
# Setup required before first run (see https://docs.ropensci.org/rdhs/):
#   1. Register a DHS Program project at https://dhsprogram.com/data/new-user-registration.cfm
#      and get it approved for Ghana IR + GE data (GE approval can lag IR approval).
#   2. Set two environment variables (e.g. in .Renviron) rather than hardcoding
#      credentials in this script:
#        DHS_EMAIL   = the email your DHS project is registered under
#        DHS_PROJECT = the exact project name as registered on the DHS site
#   3. rdhs will prompt for your DHS password on first use and cache the config at
#      ~/.rdhs.json (not committed) + a local data cache under rdhs's cache dir.
#
# Outputs (data/raw/dhs/ -- raw, tidy extracts; per-hex/district aggregation is a
# 2_build/ job, not done here):
#   ghana_dhs_surveys.csv        survey metadata (round, year, DHS_CountryCode, ...)
#   dhs_clusters_ghana.csv       GE cluster lat/lon (where access is approved)
#   dhs_{domain}_ghana.csv       one file per Sec 2 domain, all survey rounds row-bound

####0. Setup ####
pacman::p_load(tidyverse, rdhs, here, janitor, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff
)

raw_dir <- here("data", "raw", "dhs")
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)

####1. Authenticate + discover available Ghana surveys ####
dhs_email   <- Sys.getenv("DHS_EMAIL")
dhs_project <- Sys.getenv("DHS_PROJECT")
if (!nzchar(dhs_email) || !nzchar(dhs_project)) {
  stop(
    "Set DHS_EMAIL and DHS_PROJECT environment variables before running this script ",
    "(e.g. in .Renviron) -- see the setup note at the top of this file."
  )
}

set_rdhs_config(
  email           = dhs_email,
  project         = dhs_project,
  config_path     = "~/.rdhs.json",
  global          = TRUE,
  verbose_download = TRUE
)
client <- client_dhs(get_rdhs_config())

ghana_surveys <- dhs_surveys(countryIds = "GH", surveyType = "DHS") |> as_tibble()
write_csv(ghana_surveys, file.path(raw_dir, "ghana_dhs_surveys.csv"))
message(nrow(ghana_surveys), " Ghana DHS survey rounds found: ",
        paste(ghana_surveys$SurveyYear, collapse = ", "))

####2. Domain definitions -- add new domains here ####
# `file_type` is the DHS Recode file type (IR = Individual/women's Recode, which carries
# v190/v191 wealth already merged onto each respondent). `variables` are candidate DHS
# variable codes; Sec 3 checks each against the actual recode before extracting.
DOMAINS <- list(
  economic = list(
    file_type = "IR",
    variables = c("v714", "v716", "v717", "v718", "v719", "v731", "v732", "v739", "v741")
    # v714 currently working; v716/v717 occupation (detailed/grouped); v718 employer type;
    # v719 continuity (seasonal vs all-year); v731 worked last 12mo; v732 earns cash;
    # v739 who decides use of earnings; v741 earnings vs husband's
  ),
  wealth = list(
    file_type = "IR",
    variables = c("v190", "v191")
    # v190 wealth index quintile; v191 wealth index factor score (combined, DHS-standard)
  ),
  maternal_newborn_health = list(
    file_type = "IR",
    variables = c("v212", "m14_1", "m15_1", "m3a_1", "m17_1", "m70_1", "b5_1")
    # v212 age at first birth; m14 ANC visit count; m15 place of delivery;
    # m3a assistance at delivery (doctor); m17 delivery by caesarean;
    # m70 timing of first postnatal checkup; b5 child alive -- all for most recent birth
  )
)
# ID/weighting variables carried alongside every domain extraction
ID_VARS <- c("caseid", "v000", "v007", "v008", "v001", "v002", "v005", "v021", "v023", "v024", "v025")

####3. Verify + extract one domain across all Ghana survey rounds ####
extract_domain <- function(domain_name, spec) {
  message("\n--- Domain: ", domain_name, " (", spec$file_type, ") ---")

  datasets <- dhs_datasets(
    fileFormat  = "Stata",
    surveyType  = "DHS",
    fileType    = list(spec$file_type),
    countryIds  = "GH",
    selectSurveys = TRUE
  ) |> as_tibble()

  if (nrow(datasets) == 0) {
    warning("No ", spec$file_type, " datasets found for Ghana -- skipping ", domain_name)
    return(invisible(NULL))
  }

  # Confirm which candidate codes actually exist before extracting (names can drift
  # across rounds); report anything missing rather than silently dropping it.
  # essential_variables= (tried first) silently made search_variables() report EVERY candidate as
  # "not found" even for variables confirmed present (v714 etc., verified interactively 2026-11-09)
  # -- folding ID_VARS directly into variables= instead is what actually works.
  found <- search_variables(datasets$FileName, variables = c(spec$variables, ID_VARS))
  missing_vars <- setdiff(spec$variables, unique(found$variable))
  if (length(missing_vars) > 0) {
    message("  Not found in any round (check spelling / survey-specific naming): ",
            paste(missing_vars, collapse = ", "))
  }
  if (nrow(found) == 0) {
    warning("  None of domain '", domain_name, "'s candidate variables exist in any Ghana ",
            spec$file_type, " round -- skipping. Use rdhs::search_variable_labels(datasets$FileName, ",
            "search_terms = ...) to find this round's actual variable names, then update DOMAINS ",
            "in this script.")
    return(invisible(NULL))
  }

  downloads <- get_datasets(datasets$FileName)
  extract   <- extract_dhs(found, add_geo = FALSE)
  # rbind_labelled() expects matching columns across rounds (it harmonizes LABELS within a shared
  # column, not differing column SETS) -- different Ghana DHS rounds don't all carry the same
  # subset of candidate variables, so per-round extracts differ in column count and rbind_labelled()
  # errors ("Anzahl der Spalten der Argumente unterschiedlich", hit 2026-11-09). bind_rows() unions
  # columns and fills NA where a round lacks one, which is what's actually needed here.
  bound <- bind_rows(extract) |> as_tibble() |> clean_names()

  out_path <- file.path(raw_dir, paste0("dhs_", domain_name, "_ghana.csv"))
  write_csv(bound, out_path)
  message("  Wrote ", nrow(bound), " rows -> ", out_path)
  invisible(bound)
}

for (domain_name in names(DOMAINS)) {
  extract_domain(domain_name, DOMAINS[[domain_name]])
}

####4. Geographic cluster coordinates (GE) -- for later spatial join onto the hex/district panel ####
# GE access is sometimes approved on a separate timeline from IR/PR -- this section is
# wrapped so the rest of the script still completes if GE isn't yet authorised.
ge_result <- try({
  ge_datasets <- dhs_datasets(
    surveyType = "DHS",
    fileType   = list("GE"),
    countryIds = "GH",
    selectSurveys = TRUE
  ) |> as_tibble()

  if (nrow(ge_datasets) > 0) {
    ge_downloads <- get_datasets(ge_datasets$FileName)
    ge_clusters <- map_dfr(ge_downloads, ~ readRDS(.x) |> as_tibble() |> clean_names())
    write_csv(ge_clusters, file.path(raw_dir, "dhs_clusters_ghana.csv"))
    message("\nWrote ", nrow(ge_clusters), " GE cluster rows -> ",
            file.path(raw_dir, "dhs_clusters_ghana.csv"))
  } else {
    message("\nNo GE datasets found/authorised for Ghana -- skipping cluster coordinates.")
  }
}, silent = TRUE)
if (inherits(ge_result, "try-error")) {
  message("\nGE cluster pull failed (likely not yet authorised for this DHS project): ",
          conditionMessage(attr(ge_result, "condition")))
}

message("\n=== d_08_dhs_data.R complete ===")
