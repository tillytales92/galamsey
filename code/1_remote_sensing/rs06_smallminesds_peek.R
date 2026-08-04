# rs06_smallminesds_peek.R
# Quick look at SmallMinesDS (Ofori-Ampofo et al. 2025) — example image + mask, 2022, small subset.
# Each patch: 128x128, 10 m, georeferenced. Bands 1-10 = Sentinel-2 (blue->SWIR2), 11-12 = Sentinel-1
# VV/VH, 13 = Copernicus DEM. Masks are binary (1 = artisanal mining). RGB = S2 bands 3(red),2(grn),1(blu).
# Not part of the pipeline — a visual sanity check only.

pacman::p_load(terra, here, leaflet, leafem)

YEAR    <- 2022
N_SHOW  <- 4      # how many example patches to display
MIN_FRAC <- 0.02  # only show patches with >2% mining pixels (patch 0001 etc. are all-zero)
SCAN    <- 120    # how many masks to scan to find mining examples (keeps it a small subset)

dir_y <- here("data", "raw", "smallminesds", "SmallMinesDS", "SmallMinesDS", as.character(YEAR))
img_of <- function(mask_path) file.path(dir_y, "IMAGE", sub("MASK", "IMG", basename(mask_path)))

# --- find a small subset of patches that actually contain mining ---
mask_files <- head(list.files(file.path(dir_y, "MASK"), pattern = "\\.tif$", full.names = TRUE), SCAN)
frac <- vapply(mask_files, \(f) mean(terra::values(rast(f)), na.rm = TRUE), numeric(1))
pick <- mask_files[order(frac, decreasing = TRUE)][seq_len(N_SHOW)]   # the N most-mined patches

cat(sprintf("Scanned %d masks; %d have >%.0f%% mining. Showing the top %d.\n",
            length(mask_files), sum(frac > MIN_FRAC), 100 * MIN_FRAC, N_SHOW))

# --- true-colour array with a 2-98% per-band linear stretch (returns HxWx3 in [0,1]) ---
rgb_array <- function(img) {
  r <- img[[c(3, 2, 1)]]                                        # S2 red, green, blue
  q <- terra::global(r, \(x) quantile(x, c(0.02, 0.98), na.rm = TRUE))
  a <- terra::as.array(r)
  for (i in 1:3) a[, , i] <- (pmin(pmax(a[, , i], q[i, 1]), q[i, 2]) - q[i, 1]) / (q[i, 2] - q[i, 1])
  a
}
# base-graphics panel: draw an as.raster image into the current mfrow cell (avoids terra's
# internal layout() calls, which otherwise reset par(mfrow) and blank the grid).
show_ras <- function(ras, main) {
  plot.new(); plot.window(c(0, 1), c(0, 1), asp = 1)
  rasterImage(ras, 0, 0, 1, 1); title(main, cex.main = 0.85)
}

# --- plot: one row per patch — S2 true colour (with translucent mining overlay) | binary mask ---
par(mfrow = c(N_SHOW, 2), mar = c(1, 1, 2, 1))
for (mf in pick) {
  id   <- sub("MASK_(.*)\\.tif$", "\\1", basename(mf))
  m    <- terra::as.matrix(rast(mf), wide = TRUE)
  frac <- mean(m, na.rm = TRUE)

  show_ras(as.raster(rgb_array(rast(img_of(mf)))),
           sprintf("%s — S2 true colour (+ mining)", id))
  rasterImage(as.raster(matrix(ifelse(m == 1, "#FF2A2A80", "#00000000"), nrow(m))), 0, 0, 1, 1)

  show_ras(as.raster(matrix(ifelse(m == 1, "red", "grey90"), nrow(m))),
           sprintf("mask (%.1f%% mining)", 100 * frac))
}

# Optional: save a copy for the record —
# dev.copy(png, here("outputs", "figures", sprintf("smallminesds_peek_%d.png", YEAR)),
#          width = 900, height = 450 * N_SHOW, res = 120); dev.off()


# ============================================================
# Interactive leaflet — patch in its real SW-Ghana location, true colour + mask
# toggleable over an Esri satellite basemap. Shows WHERE the labelled sites sit.
# ============================================================
leaflet_patch <- function(mask_path) {
  id  <- sub("MASK_(.*)\\.tif$", "\\1", basename(mask_path))
  rgb <- terra::project(rast(img_of(mask_path))[[c(3, 2, 1)]], "EPSG:4326")   # S2 R,G,B
  msk <- terra::project(classify(rast(mask_path), cbind(0, NA)),              # 0 -> NA (transparent)
                        "EPSG:4326", method = "near")
  e   <- as.vector(ext(rgb))                                                  # xmin,xmax,ymin,ymax
  leaflet() |>
    addProviderTiles("Esri.WorldImagery", group = "Esri satellite") |>
    leafem::addRasterRGB(rgb, r = 1, g = 2, b = 3, quantiles = c(0.02, 0.98),
                         group = "S2 true colour") |>
    addRasterImage(msk, colors = "#ff2a2a", opacity = 0.6, group = "Mining mask") |>
    addLayersControl(baseGroups = "Esri satellite",
                     overlayGroups = c("S2 true colour", "Mining mask"),
                     options = layersControlOptions(collapsed = FALSE)) |>
    addScaleBar(position = "bottomleft") |>
    fitBounds(e[1], e[3], e[2], e[4]) |>
    addControl(sprintf("SmallMinesDS %s (%d)", id, YEAR), position = "topright")
}

# Build for the top-mined patch. Change pick[1] to any element of `pick`, or pass another MASK path.
map <- leaflet_patch(pick[1])

# NOTE: source() and Rscript do NOT auto-display an htmlwidget (only typing `map` at the console does),
# which is why the map "doesn't show" when the script is sourced. So print it explicitly for the
# RStudio Viewer AND always write a standalone HTML you can open in any browser.
if (interactive()) print(map)

html_out <- here("outputs", "figures", "smallminesds",
                 sprintf("smallminesds_leaflet_%s.html",
                         sub("MASK_(.*)\\.tif$", "\\1", basename(pick[1]))))   # id already has the year
dir.create(dirname(html_out), showWarnings = FALSE, recursive = TRUE)
tryCatch(                                                        # selfcontained needs pandoc (RStudio has it);
  htmlwidgets::saveWidget(map, html_out, selfcontained = TRUE), # fall back to a _files sidecar if absent
  error = function(e) htmlwidgets::saveWidget(map, html_out, selfcontained = FALSE))
message("Leaflet map written to: ", html_out,
        "\n(open it in a browser if the RStudio Viewer didn't show it)")
if (interactive()) utils::browseURL(html_out)
