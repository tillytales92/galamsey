# d_12_mining_repository.R
# Exploratory EDA on the Ghana Minerals Commission "Ghana Mining Repository" cadastre
# export (2025-11-09 snapshot) -- four files, understanding what each contains and how
# they connect before any of this becomes a covariate build.
#
# Offline script (no GEE / no auth).
#
# data/raw/GhanaMiningRepository_2025/ (four files):
#   1. Ghana_Mining_Repository_09112025.kml               -- 1,279 polygons: GRANTED
#      licenses with a mapped concession boundary. Fields live in each Placemark's
#      <ExtendedData>, which GDAL's default KML driver does NOT expose as sf columns here
#      (st_read() returns only Name/Description/geometry, Description blank) -- they must
#      be parsed from the raw XML (see extract_kml_attrs() below). Fields: code, owner,
#      type, country, status, start_date, expiry_date, assets.
#   2. Ghana_Mining_Repository_09112025_applications.kml   -- 6,894 polygons: PENDING
#      applications (status Approval/Pending/Validation -- not yet granted), same field
#      structure minus start_date/expiry_date, plus application_date instead. Codes are
#      "APL--N" placeholders, not real license codes yet.
#   3. report_license_09112025.xlsx  -- 1,786 rows, the full license register (Start Date,
#      License Code, Owner, Type, Status, Minerals, Regions). This is the SUPERSET of the
#      active KML: every one of the 1,279 active-KML codes appears here (License Code ==
#      KML code is the join key), plus 507 more rows for license types that have no
#      physical concession polygon at all (Export/Buying/Refinery licenses, Support
#      Service classes A/B/C) -- so the KML is a spatial subset of this table, not the
#      reverse. Has 41 duplicated License Codes (same code, different Owner/Type rows --
#      a data-quality quirk of the source, not a bug in this script).
#   4. report_owner_09112025.xlsx    -- 20,494 rows, the master company/individual
#      registry (Name, Type, TIN, Incorporation Date). Join key: report_license$Owner ==
#      report_owner$Name (confirmed 100% coverage for license-report owners; the KML's own
#      `owner` field also matches Name for ~99% of distinct owners, so the KML doesn't need
#      report_license as an intermediary for owner lookups).
#
# Connection summary (see Sec 4 for the checks establishing this):
#   report_owner (who)  <--Name/Owner--  report_license (what license, when, mineral, region)
#                                              |
#                                       License Code / code
#                                              |
#                        active KML (granted, mapped)   applications KML (pending, mapped;
#                        subset of report_license          NOT in report_license -- these
#                        codes; every code matches)         become real codes only once granted)
#
# Outputs:
#   outputs/figures/mining_repository/*.png (diagnostic plots)
#   data/processed/mining_repository/active_licenses_clean.gpkg (active_kml + assets_clean/
#     gold/type_simplified)
#   data/processed/mining_repository/applications_clean.gpkg (apps_kml + same 3 new cols)
#   data/processed/mining_repository/license_register_clean.csv (license_df + same 3 new
#     cols, minus geometry -- this table was never spatial)
#   (report_owner is unmutated -- no new columns added to it -- so it isn't re-saved here)

pacman::p_load(sf, here, xml2, purrr, janitor, tidyverse, readxl, scales, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff,
  here::here
)

data_dir <- here("data", "raw", "GhanaMiningRepository_2025")
fig_dir  <- here("outputs", "figures", "mining_repository")
proc_dir <- here("data", "processed", "mining_repository")
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(proc_dir, recursive = TRUE, showWarnings = FALSE)

active_kml_path <- file.path(data_dir, "Ghana_Mining_Repository_09112025.kml")
apps_kml_path   <- file.path(data_dir, "Ghana_Mining_Repository_09112025_applications.kml")
license_path    <- file.path(data_dir, "report_license_09112025.xlsx")
owner_path      <- file.path(data_dir, "report_owner_09112025.xlsx")
stopifnot(all(file.exists(active_kml_path, apps_kml_path, license_path, owner_path)))

####1. Parse the two KML files -- geometry via sf, attributes via raw XML ####
# GDAL's KML driver drops the per-Placemark <ExtendedData> here, so we parse it directly
# and bind it to the sf geometry read separately. Placemark order is preserved by both
# readers (verified: geometry's Name column == attrs' code column for every row), so a
# straight column-bind is safe and much faster than a per-placemark spatial join.

extract_kml_attrs <- function(path) {
  doc <- read_xml(path)
  ns  <- xml_ns_rename(xml_ns(doc), d1 = "k")
  pm  <- xml_find_all(doc, ".//k:Placemark", ns)
  map_dfr(pm, function(p) {
    dat  <- xml_find_all(p, ".//k:ExtendedData/k:Data", ns)
    vals <- set_names(xml_text(xml_find_first(dat, "k:value", ns)), xml_attr(dat, "name"))
    as_tibble(as.list(vals))
  })
}

read_kml_full <- function(path) {
  geom  <- st_read(path, quiet = TRUE) |> select(geometry)
  attrs <- extract_kml_attrs(path)
  stopifnot("Placemark order mismatch between geometry and attribute parse" = nrow(geom) == nrow(attrs))
  bind_cols(attrs, geom) |> st_as_sf()
}

active_kml <- read_kml_full(active_kml_path)
apps_kml   <- read_kml_full(apps_kml_path)

cat("\n=== 1. Active-license KML ===\n")
cat(sprintf("%d polygons. Fields: %s\n", nrow(active_kml), paste(setdiff(names(active_kml), "geometry"), collapse = ", ")))
cat("status:\n"); print(table(active_kml$status, useNA = "ifany"))
cat("type (top 10):\n"); print(sort(table(active_kml$type), decreasing = TRUE)[1:10])

cat("\n=== 2. Applications KML ===\n")
cat(sprintf("%d polygons. Fields: %s\n", nrow(apps_kml), paste(setdiff(names(apps_kml), "geometry"), collapse = ", ")))
cat("status:\n"); print(table(apps_kml$status, useNA = "ifany"))

####2. Load the two Excel reports ####

license_df <- read_excel(license_path) |> clean_names()
owner_df   <- read_excel(owner_path)   |> clean_names()

cat("\n=== 3. License register (xlsx) ===\n")
cat(sprintf("%d rows. Fields: %s\n", nrow(license_df), paste(names(license_df), collapse = ", ")))
cat("status:\n"); print(table(license_df$status, useNA = "ifany"))
cat(sprintf("duplicated License Codes: %d\n", sum(duplicated(license_df$license_code))))

cat("\n=== 4. Owner register (xlsx) ===\n")
cat(sprintf("%d rows. Fields: %s\n", nrow(owner_df), paste(names(owner_df), collapse = ", ")))
cat("owner Type:\n"); print(table(owner_df$type, useNA = "ifany"))

####3. How the four files connect -- join-key coverage checks ####

cat("\n=== 5. active KML code <-> license register License Code ===\n")
cat(sprintf("%d of %d active-KML codes found in license register (%.1f%%)\n",
            sum(active_kml$code %in% license_df$license_code), nrow(active_kml),
            100 * mean(active_kml$code %in% license_df$license_code)))
cat(sprintf("%d license-register rows have NO active-KML geometry (non-spatial license types):\n",
            sum(!license_df$license_code %in% active_kml$code)))
print(sort(table(license_df$type[!license_df$license_code %in% active_kml$code]), decreasing = TRUE))

cat("\n=== 6. applications KML code <-> license register License Code ===\n")
cat(sprintf("%d of %d application codes found in license register (expected ~0 -- these aren't granted yet)\n",
            sum(apps_kml$code %in% license_df$license_code), nrow(apps_kml)))

cat("\n=== 7. license register Owner <-> owner register Name ===\n")
cat(sprintf("%d of %d distinct license-register owners found in owner register (%.1f%%)\n",
            n_distinct(license_df$owner[license_df$owner %in% owner_df$name]), n_distinct(license_df$owner),
            100 * mean(unique(license_df$owner) %in% owner_df$name)))

cat("\n=== 8. KML owner field <-> owner register Name (direct, bypassing license register) ===\n")
cat(sprintf("%d of %d distinct active-KML owners found in owner register (%.1f%%)\n",
            n_distinct(active_kml$owner[active_kml$owner %in% owner_df$name]), n_distinct(active_kml$owner),
            100 * mean(unique(active_kml$owner) %in% owner_df$name)))

####4. Clean the commodity columns and build a `gold` dummy ####
# Both KML files' `assets` and the license register's `minerals` list commodities per
# license, with the same underlying data-quality quirks -- just different delimiters:
#   - assets (both KML files): comma-delimited, with a stray "/" in "Sand/ Gravel".
#   - minerals (license register): NEWLINE-delimited (e.g. "Gold\nDiamonds"), also with a
#     stray "/" in "Sand/ Gravel". Commas here are NOT a delimiter -- they occur only
#     inside natural-language Support Service descriptions (e.g. "Mine Consumables
#     (grinding media, activated carbon, caustic soda)"), so splitting minerals on ","
#     would shred those into meaningless fragments. Splitting on "/" still mildly affects a
#     couple of Support Service rows ("Civil works /engineering services" -> two tokens),
#     but neither fragment is ever "Gold", so it doesn't touch the gold dummy.
# All three get the same two-part cleanup: split on the field's delimiter(s), drop "."
# junk/placeholder tokens and blanks, trim whitespace, rejoin with "," for a consistent
# cleaned representation across all three tables. Rows with no real commodity left after
# cleaning are set to NA (not assumed non-gold -- "no data" != "confirmed not gold").
#
# `gold` is a dummy: 1 iff "Gold" or "Gold Ore" is one of the cleaned tokens (both count --
# a handful of rows have "Gold Ore" without plain "Gold" alongside, but it's the same
# underlying commodity for this project's purposes).

clean_commodity_list <- function(x, delims) {
  tokens <- str_split(x, delims)
  map_chr(tokens, function(t) {
    t <- str_trim(t)
    t <- t[t != "." & t != ""]
    if (length(t) == 0) return(NA_character_)
    paste(t, collapse = ",")
  })
}

is_gold <- function(x) {
  if (is.na(x)) return(NA_integer_)
  as.integer(any(c("Gold", "Gold Ore") %in% str_split(x, ",")[[1]]))
}

report_commodity_cleaning <- function(raw, clean, label) {
  cat(sprintf("\n=== %s cleaning ===\n", label))
  cat(sprintf("%d distinct raw values -> %d distinct cleaned values\n",
              n_distinct(raw), n_distinct(clean)))
  gold <- map_int(clean, is_gold)
  cat(sprintf("gold == 1 for %d of %d rows (%.1f%%); %d with no usable commodity data (NA)\n",
              sum(gold, na.rm = TRUE), length(clean),
              100 * mean(gold, na.rm = TRUE), sum(is.na(gold))))
  gold
}

active_kml <- active_kml |> mutate(assets_clean = clean_commodity_list(assets, "[,/]"))
active_kml$gold <- report_commodity_cleaning(active_kml$assets, active_kml$assets_clean, "Active-license KML assets")

apps_kml <- apps_kml |> mutate(assets_clean = clean_commodity_list(assets, "[,/]"))
apps_kml$gold <- report_commodity_cleaning(apps_kml$assets, apps_kml$assets_clean, "Applications KML assets")

license_df <- license_df |> mutate(minerals_clean = clean_commodity_list(minerals, "[/\n]"))
license_df$gold <- report_commodity_cleaning(license_df$minerals, license_df$minerals_clean, "License register minerals")

####5. Simplified license type -- `type_simplified` ####
# `type` has 41 distinct raw values across the three tables (Foreign/Ghanaian/National/
# International qualifiers, per-district Small Scale variants, typos like the double space
# in "Small Scale  Licence (Assin Fosu District)", "Licence" vs "License" spelling). Collapse
# to the 4 categories that matter for this project, everything else -> "Other". Matched by
# ANCHORED prefix (^) so "Restricted Mining Lease" is checked before plain "Mining Lease"
# (otherwise every restricted lease would also match the plain-lease pattern), and
# "Restricted Prospecting License (Foreign/Ghanaian)" and "Restricted Reconnaissance
# License (Ghanaian)" fall to Other rather than Prospecting Licence -- they start with
# "Restricted", not "Prospecting"/"Reconnaissance", and the project's 4 categories don't
# have a bucket for restricted-prospecting rights specifically (only 2-3 rows each anyway).
# "Small Scale Gold/ Diamond Permit" also falls to Other: it's a Permit, not a Licence, so
# it doesn't match the Small Scale rule's "Licen[cs]e" requirement.

simplify_type <- function(type) {
  case_when(
    str_starts(type, regex("^Restricted Mining Lease", ignore_case = TRUE)) ~ "Restricted Mining Lease",
    str_starts(type, regex("^Mining Lease", ignore_case = TRUE)) ~ "Mining Lease",
    str_starts(type, regex("^Prospecting Licen[cs]e", ignore_case = TRUE)) ~ "Prospecting Licence",
    str_starts(type, regex("^Small Scale", ignore_case = TRUE)) &
      str_detect(type, regex("Licen[cs]e", ignore_case = TRUE)) ~ "Small Scale Mining Licence",
    TRUE ~ "Other"
  )
}

active_kml <- active_kml |> mutate(type_simplified = simplify_type(type))
apps_kml   <- apps_kml   |> mutate(type_simplified = simplify_type(type))
license_df <- license_df |> mutate(type_simplified = simplify_type(type))

cat("\n=== 10. type_simplified counts ===\n")
cat("active-license KML:\n");   print(table(active_kml$type_simplified))
cat("applications KML:\n");     print(table(apps_kml$type_simplified))
cat("license register:\n");     print(table(license_df$type_simplified))
cat("\nraw types collapsed into 'Other' (license register):\n")
print(sort(table(license_df$type[license_df$type_simplified == "Other"]), decreasing = TRUE))

####6. Basic plots ####

p_status <- bind_rows(
  active_kml |> st_drop_geometry() |> count(status) |> mutate(source = "Active licenses (KML)"),
  apps_kml   |> st_drop_geometry() |> count(status) |> mutate(source = "Applications (KML)")
) |>
  ggplot(aes(x = fct_reorder(status, n), y = n, fill = source)) +
  geom_col(position = "dodge") +
  coord_flip() +
  labs(title = "Ghana Mining Repository -- status breakdown", x = NULL, y = "Count", fill = NULL) +
  theme_bw(base_size = 11)
p_status
ggsave(file.path(fig_dir, "mining_repository_status.png"), p_status, width = 7, height = 5, dpi = 150)

# Both KML layers contain a handful of placemarks with garbage coordinates (bbox blows out
# to the full globe, -180/-90/180/90) -- a digitising error in the source, not a parsing
# bug here (confirmed: st_bbox() on the raw layers returns the full extent). We don't drop
# those rows (unclear which specific placemark(s) are bad without a closer look), but we
# clip the plotted extent to Ghana's admin0 outline so the map is actually legible.

admin0_path <- here("data", "raw", "shapefiles", "hdx_gh_admin", "gha_admin0.shp")
admin0 <- if (file.exists(admin0_path)) {
  st_read(admin0_path, quiet = TRUE) |> st_make_valid() |> select(any_of(c("adm0_name", "geometry")))
} else { message("admin0 shapefile not found -- map will use the (garbage) full-data bbox."); NULL }
bb <- if (!is.null(admin0)) st_bbox(admin0) else st_bbox(active_kml)

p_map <- ggplot() +
  { if (!is.null(admin0)) geom_sf(data = admin0, fill = "grey96", colour = "grey60") } +
  geom_sf(data = apps_kml, fill = "#FDAE61", colour = NA, alpha = 0.5) +
  geom_sf(data = active_kml, fill = "#238B45", colour = NA, alpha = 0.7) +
  coord_sf(xlim = c(bb["xmin"], bb["xmax"]), ylim = c(bb["ymin"], bb["ymax"])) +
  labs(title = "Ghana Mining Repository -- granted (green) vs pending applications (orange)",
       subtitle = sprintf("%d granted, mapped licenses; %d pending applications",
                           nrow(active_kml), nrow(apps_kml)),
       caption = "Ghana Minerals Commission, Ghana Mining Repository (09-11-2025 snapshot). Till Meissner.") +
  theme_minimal(base_size = 10) +
  theme(plot.title = element_text(face = "bold"),
        axis.text = element_blank(), axis.title = element_blank(),
        panel.grid = element_blank(),
        plot.caption = element_text(colour = "grey50", size = 7))
p_map
ggsave(file.path(fig_dir, "mining_repository_map.png"), p_map, width = 8, height = 8, dpi = 150)

# Gold-only map, coloured by type_simplified -- filter to gold == 1 FIRST (drops the NA
# rows with no usable commodity data too, since NA == 1 is NA and filter() excludes it).
gold_active <- active_kml |> filter(gold == 1)

cat(sprintf("\n%d of %d active licenses are gold-bearing; type_simplified breakdown:\n",
            nrow(gold_active), nrow(active_kml)))
print(table(gold_active$type_simplified))

p_map_gold <- ggplot() +
  { if (!is.null(admin0)) geom_sf(data = admin0, fill = "grey96", colour = "grey60") } +
  geom_sf(data = gold_active, aes(fill = type_simplified), colour = NA, alpha = 0.85) +
  coord_sf(xlim = c(bb["xmin"], bb["xmax"]), ylim = c(bb["ymin"], bb["ymax"])) +
  scale_fill_brewer(palette = "Dark2", name = "License type") +
  labs(title = "Ghana gold licenses -- active, mapped concessions",
       subtitle = sprintf("%d of %d active licenses are gold-bearing", nrow(gold_active), nrow(active_kml)),
       caption = "Ghana Minerals Commission, Ghana Mining Repository (09-11-2025 snapshot). Till Meissner.") +
  theme_minimal(base_size = 10) +
  theme(plot.title = element_text(face = "bold"),
        axis.text = element_blank(), axis.title = element_blank(),
        panel.grid = element_blank(),
        plot.caption = element_text(colour = "grey50", size = 7))
p_map_gold
ggsave(file.path(fig_dir, "mining_repository_gold_type_map.png"), p_map_gold, width = 8, height = 8, dpi = 150)

p_owner_type <- ggplot(owner_df, aes(x = fct_infreq(type))) +
  geom_bar(fill = "#2171B5") +
  scale_y_continuous(labels = label_comma()) +
  labs(title = "Owner register -- entity type", x = NULL, y = "Count") +
  theme_bw(base_size = 11)
p_owner_type
ggsave(file.path(fig_dir, "mining_repository_owner_type.png"), p_owner_type, width = 6, height = 4, dpi = 150)

####7. Small Scale Mining Licence only -- gold, active, mapped ####

gold_small_scale <- gold_active |> filter(type_simplified == "Small Scale Mining Licence")

cat(sprintf("\n%d of %d gold-bearing active licenses are Small Scale Mining Licence.\n",
            nrow(gold_small_scale), nrow(gold_active)))

p_map_small_scale <- ggplot() +
  { if (!is.null(admin0)) geom_sf(data = admin0, fill = "grey96", colour = "grey60") } +
  geom_sf(data = gold_small_scale, fill = "#D95F02", colour = NA, alpha = 0.85) +
  coord_sf(xlim = c(bb["xmin"], bb["xmax"]), ylim = c(bb["ymin"], bb["ymax"])) +
  labs(title = "Ghana gold licenses -- Small Scale Mining Licence only",
       subtitle = sprintf("%d active, mapped small-scale gold licenses", nrow(gold_small_scale)),
       caption = "Ghana Minerals Commission, Ghana Mining Repository (09-11-2025 snapshot). Till Meissner.") +
  theme_minimal(base_size = 10) +
  theme(plot.title = element_text(face = "bold"),
        axis.text = element_blank(), axis.title = element_blank(),
        panel.grid = element_blank(),
        plot.caption = element_text(colour = "grey50", size = 7))
p_map_small_scale
ggsave(file.path(fig_dir, "mining_repository_gold_small_scale_map.png"), p_map_small_scale, width = 8, height = 8, dpi = 150)

####8. Save the mutated tables to data/processed/ ####
# Only the three tables that actually got new columns (assets_clean/minerals_clean, gold,
# type_simplified) -- report_owner was never mutated, so it isn't duplicated here.
# active_kml/apps_kml are saved as GeoPackage rather than Shapefile: Shapefile's DBF format
# truncates field names to 10 characters, which would silently mangle "type_simplified" and
# "assets_clean" into ambiguous/duplicate-looking names. GeoPackage has no such limit.

st_write(active_kml, file.path(proc_dir, "active_licenses_clean.gpkg"), delete_dsn = TRUE, quiet = TRUE)
st_write(apps_kml, file.path(proc_dir, "applications_clean.gpkg"), delete_dsn = TRUE, quiet = TRUE)
write_csv(license_df, file.path(proc_dir, "license_register_clean.csv"))

message(sprintf("\nWrote mutated tables to %s", proc_dir))

message("\n=== d_12_mining_repository.R complete ===")
