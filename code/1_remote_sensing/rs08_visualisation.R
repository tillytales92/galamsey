pacman::p_load(sf, terra, here, tidyverse, tmap, conflicted)
conflicts_prefer(
  dplyr::filter, dplyr::select, dplyr::mutate, dplyr::summarise,
  dplyr::rename, dplyr::arrange, dplyr::lag,
  base::intersect, base::union, base::setdiff,
  here::here
)

# ---- Load ----
awomaso_dir <- here("data", "raw", "awomaso_figure")

basemap <- rast(file.path(awomaso_dir, "s2_2024_awomaso_rgb.tif"))  # basemap for panel A
m2017   <- rast(file.path(awomaso_dir, "mining_mask_2017_awomaso.tif"))
m2024   <- rast(file.path(awomaso_dir, "mining_mask_2024_awomaso.tif"))

# ---- Vectorize (sieve removes speckle < min_px pixels) ----
to_poly <- function(r, min_px = 10) {
  r |>
    sieve(threshold = min_px) |>
    as.polygons() |>
    st_as_sf() |>
    filter(.data[[names(r)[1]]] == 1) |>
    st_union() |>
    st_as_sf()
}

p2017 <- to_poly(m2017)
p2024 <- to_poly(m2024)

# ---- Panel A ----
# Draw 2024 first (bottom), 2017 last (top):
# visible color = year the area was first mined
cols <- c(`2017` = "#8b5a9e", `2024` = "#e6122e")

panelA <- tm_shape(basemap) +
  tm_rgb() +
  tm_shape(p2024) + tm_fill(fill = cols["2024"], fill_alpha = 0.8) +
  tm_shape(p2017) + tm_fill(fill = cols["2017"], fill_alpha = 0.9) +
  tm_graticules(lines = FALSE) +
  tm_compass(position = c("right", "top")) +
  tm_scalebar(position = c("right", "bottom")) +
  tm_add_legend(fill = unname(cols), labels = names(cols)) +
  tm_layout(legend.position = c("left", "bottom"))

# ---- Zoom box + panel B insets ----
# Pick coordinates of an interesting expansion front (UTM 30N metres);
# start from the AOI extent to orient yourself:
ext(basemap)   # 605090-625000 E, 660950-680850 N (~20 x 20 km)

zoom <- ext(612500, 621500, 667000, 673000)   # 9 x 6 km, same centre as before
zoom_box <- st_as_sfc(st_bbox(c(xmin = xmin(zoom), xmax = xmax(zoom),
                                ymin = ymin(zoom), ymax = ymax(zoom)),
                              crs = 32630))

panelA <- panelA +
  tm_shape(zoom_box) + tm_borders(lwd = 2, col = "black")

s17 <- crop(rast(file.path(awomaso_dir, "s2_2017_awomaso_rgb.tif")), zoom)
s24 <- crop(rast(file.path(awomaso_dir, "s2_2024_awomaso_rgb.tif")), zoom)

inset17 <- tm_shape(s17) + tm_rgb() + tm_title("2017")
inset24 <- tm_shape(s24) + tm_rgb() + tm_title("2024")

# ---- Compose + save ----
# tmap_arrange() objects can't be nested inside another tmap_arrange(), so the
# big-panel-left / stacked-insets-right layout is composed with grid viewports.
fig_path <- here("outputs", "figures", "awomaso_mining_change.png")
png(fig_path, width = 12, height = 8, units = "in", res = 300)
grid::grid.newpage()
grid::pushViewport(grid::viewport(
  layout = grid::grid.layout(2, 2, widths = grid::unit(c(0.65, 0.35), "npc"))))
print(panelA,  vp = grid::viewport(layout.pos.row = 1:2, layout.pos.col = 1))
print(inset17, vp = grid::viewport(layout.pos.row = 1,   layout.pos.col = 2))
print(inset24, vp = grid::viewport(layout.pos.row = 2,   layout.pos.col = 2))
dev.off()
message("Saved: ", fig_path)