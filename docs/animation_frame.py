# SPDX-FileCopyrightText: 2026 Stefano Campanella
# SPDX-License-Identifier: MIT
"""A prototype frame of the proposed ARCO-OCEAN animation: an orthographic globe, sea surface
temperature (thetao, level 0) and sea ice (siconc) over the sea fraction, land dark.
Usage: python docs/animation_frame.py REPO OUT.png [CENTRAL_LON] (REPO: a local historical repository)"""

import sys

import cartopy.crs as ccrs
import cartopy.feature as cfeature
import cmocean
import icechunk
import matplotlib.pyplot as plt
import numpy as np
import xarray as xr

repo = icechunk.Repository.open(icechunk.local_filesystem_storage(sys.argv[1]))
ds = xr.open_zarr(repo.readonly_session("main").store, consolidated=False)
day = ds.isel(time=0)
sst = day.thetao.isel(depth=0).load()
ice = day.siconc.load()
lon0 = float(sys.argv[3]) if len(sys.argv) > 3 else -150.0

background = "#0b1020"
fig = plt.figure(figsize=(6, 6), dpi=180, facecolor=background)
ax = fig.add_axes((0.02, 0.06, 0.96, 0.9), projection=ccrs.Orthographic(lon0, 12))
ax.set_facecolor(background)
ax.add_feature(cfeature.LAND, facecolor="#2b2f36", zorder=0)
mesh = ax.pcolormesh(
  sst.lon,
  sst.lat,
  sst,
  transform=ccrs.PlateCarree(),
  cmap=cmocean.cm.thermal,
  vmin=-2,
  vmax=31,
  shading="auto",
  zorder=1,
)
# Sea ice as white, its opacity the concentration (the colour map's lightest stays distinct).
ice_rgba = np.zeros((*ice.shape, 4))
ice_rgba[..., :3] = 0.96
ice_rgba[..., 3] = np.clip(np.nan_to_num(ice.values), 0, 1) * 0.95
ax.imshow(
  ice_rgba,
  origin="lower" if float(ice.lat[0]) < float(ice.lat[-1]) else "upper",
  extent=(float(ice.lon.min()), float(ice.lon.max()), float(ice.lat.min()), float(ice.lat.max())),
  transform=ccrs.PlateCarree(),
  zorder=2,
  interpolation="nearest",
)
ax.coastlines(linewidth=0.3, color="#9aa3ad", zorder=3)
ax.spines["geo"].set_edgecolor("#3a4252")
date = np.datetime_as_string(day.time.values, unit="D")
fig.text(
  0.04,
  0.025,
  f"ARCO-OCEAN  sea surface temperature and sea ice  {date}",
  color="#cfd6df",
  fontsize=8,
  family="DejaVu Sans",
)
cax = fig.add_axes((0.70, 0.03, 0.26, 0.012))
bar = fig.colorbar(mesh, cax=cax, orientation="horizontal")
bar.set_ticks([0, 10, 20, 30])
bar.ax.tick_params(labelsize=6, colors="#cfd6df", length=2)
bar.outline.set_edgecolor("#3a4252")
bar.ax.set_title("°C", color="#cfd6df", fontsize=6, pad=2)
fig.savefig(sys.argv[2], facecolor=background)
print("wrote", sys.argv[2], sst.shape)
