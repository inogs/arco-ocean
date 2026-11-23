# SPDX-FileCopyrightText: 2026 Stefano Campanella
# SPDX-License-Identifier: MIT
"""Measurements behind `docs/coarsen-ocean-datasets.md`, on real data, at one resolution.

Needs the network and the services' credentials (Copernicus Marine, EWDS; ERA5 is public), and
an ecCodes recent enough for GloFAS GRIB (arco-make's `live` extra, in the `notes` dependency
group). Memory: about 30 GB at 0.25 deg.

  uv run --only-group notes python docs/coarsen_analysis.py measure 0.25 out-0p25.json
  uv run --only-group notes python docs/coarsen_analysis.py tables out-0p25.json out-0p5.json out-1p0.json

`measure` writes the numbers of each section (`--sections`, default all) to a JSON file;
`tables` prints the notes' tables from such files. The sections:
- glorys: GLORYS's native mask against its depth, the layer faces, the coarse rules (current,
  majority, any water) with their volumes, per-layer water, the column identity;
- data: one day of temperature: GLORYS's gaps (on three days), level 49, regridded values
  against the rules, the footnote's premise and conclusion;
- fill: filling from above against regridded bottom values (a level left out and refilled);
- ice: sea ice over the sea part, volume per area, the round trip to GLORYS's quantities;
- rivers: GloFAS's discharge at the pits of its drainage network as a density, regridded
  conservatively; the checks; the regridded mean the recipes used to publish;
- waverys: WAVERYS's sea against GLORYS's, waves under sea ice (dropped from ARCO-OCEAN).
"""

import argparse
import datetime
import json
import pathlib
import sys
from collections.abc import Callable
from typing import Any

import numpy as np
import xarray as xr
from arcomake import processing_utils as pu
from arcomake import settings
from arcomake.temporary_utils import TempDirectoryRegistry

STATIC = "cm://cmems_mod_glo_phy_my_0.083deg_static"
DAILY = "cm://cmems_mod_glo_phy_my_0.083deg_P1D-m"
STATIC_KW = {"engine": "copernicusmarine", "dataset_version": "202311", "service": "static-arco"}
WAVES = "cm://cmems_mod_glo_wav_my_0.2deg_PT3H-i"
WAVES_STATIC = "cm://cmems_mod_glo_wav_my_0.2deg_static"
ERA5 = "gs://gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3"
GLOFAS_AUX = "https://confluence.ecmwf.int/download/attachments/242067380"
LEVELS = [0, 10, 20, 30, 40, 45, 47, 48, 49]
LEFT_OUT = [10, 20, 30, 40, 45, 47, 48]
DAY = "2013-01-01"
ICE_DAY = "2013-03-01"
GAP_DAYS = ["1993-01-01", "2013-01-01", "2021-06-30"]


def grid(res: float) -> dict[str, float]:
  return {
    "south": -90.0,
    "north": 90.0,
    "west": 0.0,
    "east": 360.0 - res,
    "resolution_lat": res,
    "resolution_lon": res,
  }


def regrid(ds: xr.Dataset, res: float, **kwargs: Any) -> xr.Dataset:
  return pu.regrid(ds, grid=grid(res), method="conservative", kwargs=kwargs).load()


def areas(ds: xr.Dataset | xr.DataArray, lat: str = "latitude", lon: str = "longitude"):
  return pu.cell_areas(ds[lat].values, ds[lon].values)


def quantiles(x: np.ndarray, qs=(0.01, 0.1, 0.5, 0.9, 0.99)) -> dict[str, float]:
  x = np.asarray(x, dtype="float64")
  x = x[np.isfinite(x)]
  if not x.size:
    return {}
  return {str(q): float(v) for q, v in zip(qs, np.quantile(x, qs), strict=True)}


def weighted(err: np.ndarray, w: np.ndarray) -> dict[str, float]:
  return {
    "bias": float((w * err).sum() / w.sum()),
    "rmse": float(np.sqrt((w * err**2).sum() / w.sum())),
  }


class Static:
  """GLORYS's static fields, read once: depth, its level, the 3D mask, the layer thicknesses."""

  def __init__(self) -> None:
    bathy = xr.open_dataset(
      STATIC, variables=["deptho", "deptho_lev", "mask"], dataset_part="bathy", **STATIC_KW
    )
    self.bathy = bathy.load()
    coords = xr.open_dataset(STATIC, variables=["e3t"], dataset_part="coords", **STATIC_KW)
    self.e3t = coords["e3t"].load().values.astype("float64")
    self.centres = self.bathy.depth.values.astype("float64")
    self.faces = np.concatenate([[0.0], np.cumsum(self.e3t)])
    self.mask = self.bathy["mask"].values.astype(bool)
    self.deptho = np.nan_to_num(self.bathy.deptho.values.astype("float64"))  # land: 0


def rebuilt_faces(centres: np.ndarray) -> np.ndarray:
  """Faces as `get_sea_mask` rebuilds them: each centre mid-layer, the first top at 0."""
  faces = [0.0]
  for c in centres:
    faces.append(faces[-1] + 2 * (c - faces[-1]))
  return np.array(faces)


def section_glorys(res: float, st: Static) -> dict[str, Any]:
  out: dict[str, Any] = {}
  rebuilt = rebuilt_faces(st.centres)
  out["faces"] = {
    "cumsum_e3t_last": st.faces[-4:].round(2).tolist(),
    "rebuilt_last": rebuilt[-4:].round(2).tolist(),
    "max_abs_difference_m": float(np.abs(rebuilt - st.faces).max()),
  }
  D, mask = st.deptho, st.mask
  k = np.arange(mask.shape[0])[:, None, None]
  wet = D > 0
  rule = D[None] > st.centres[:, None, None]
  lev = np.nan_to_num(st.bathy.deptho_lev.values)
  top, h = st.faces[:-1], np.diff(st.faces)
  wl = lev[wet].astype(int)
  fill = (D[wet] - st.faces[wl - 1]) / (st.faces[wl] - st.faces[wl - 1])
  w = np.clip(D[None] - top[:, None, None], 0, h[:, None, None]) / h[:, None, None]
  out["native"] = {
    "wet_columns": int(wet.sum()),
    "deptho_max_m": float(D.max()),
    "mask_equals_level_below_deptho_lev": bool((mask == ((k < lev[None]) & wet[None])).all()),
    "mask_but_not_centre_rule": int((mask & ~rule).sum()),
    "centre_rule_but_not_mask": int((rule & ~mask).sum()),
    "bottom_cell_fill_quantiles": quantiles(fill, (0.0, 0.01, 0.5, 0.99, 1.0)),
    "partial_cell_fraction_positive_differs_from_mask": int(((w > 0) != mask).sum()),
  }
  native = xr.Dataset(
    {
      "deptho": (("latitude", "longitude"), D),
      "w": (("depth", "latitude", "longitude"), w.astype("float32")),
      "binary": (("depth", "latitude", "longitude"), mask.astype("float32")),
    },
    coords={
      "depth": st.bathy.depth,
      "latitude": st.bathy.latitude,
      "longitude": st.bathy.longitude,
    },
  )
  del w
  raw = regrid(native, res, skipna=False)
  round_off = int(((raw.binary > 0) & (raw.binary < 1e-6)).sum())
  coarse = pu.fraction_mask(raw, fraction="binary").fillna(0.0)
  del raw
  Dbar = coarse.deptho.values
  f, fb = coarse.w.values.astype("float64"), coarse.binary.values.astype("float64")
  a = areas(coarse)
  bathy = coarse[["deptho"]].assign_coords(depth=st.bathy.depth)
  current = pu.get_sea_mask(bathy, bathymetry="deptho", depth_dim="depth", mask_name="m")[
    "m"
  ].values
  with_e3t = np.stack([Dbar > m for m in (st.faces[:-1] + st.faces[1:]) / 2])
  rules = {"current": current, "majority": fb >= 0.5, "any": fb > 0}
  out["coarse"] = {
    "identity_max_abs_m": float(np.abs((f * h[:, None, None]).sum(0) - Dbar).max()),
    "current_rule_e3t_vs_rebuilt_faces_cells": int((with_e3t != current).sum()),
    "cells_below_round_off_tolerance": round_off,
  }
  per_level = {}
  for lv in LEVELS:
    c, m, an = rules["current"][lv], rules["majority"][lv], rules["any"][lv]
    per_level[lv] = {
      "depth_m": float(st.centres[lv]),
      "current": int(c.sum()),
      "majority": int(m.sum()),
      "any": int(an.sum()),
      "current_only_vs_majority": int((c & ~m).sum()),
      "majority_only_vs_current": int((m & ~c).sum()),
      "current_sea_fraction_below_half": int((c & (fb[lv] < 0.5)).sum()),
      "current_sea_fraction_below_quarter": int((c & (fb[lv] < 0.25)).sum()),
      "smallest_fraction_in_current": float(fb[lv][c].min()) if c.any() else None,
    }
  out["rules_per_level"] = per_level
  V = float((a * Dbar).sum())
  flat = np.clip(Dbar[None] - top[:, None, None], 0, h[:, None, None])
  out["volumes_relative_to_mean_depth"] = {
    "fraction": float((a * (fb * h[:, None, None]).sum(0)).sum() / V),
    **{f"{n} mask": float((a * (r * h[:, None, None]).sum(0)).sum() / V) for n, r in rules.items()},
    "native mask over native depth": float(
      (areas(st.bathy) * (mask * h[:, None, None]).sum(0)).sum() / (areas(st.bathy) * D).sum()
    ),
  }
  out["layer_water_relative_to_fraction"] = {
    lv: {
      "flat_column": float((a * flat[lv]).sum() / (a * h[lv] * fb[lv]).sum()),
      **{
        n: float((a * h[lv] * r[lv]).sum() / (a * h[lv] * fb[lv]).sum()) for n, r in rules.items()
      },
    }
    for lv in LEVELS
  }
  return out


def section_data(res: float, st: Static, day: xr.Dataset) -> dict[str, Any]:
  out: dict[str, Any] = {}
  mask = st.mask
  lat = st.bathy.latitude.values
  gaps = {}
  for d in GAP_DAYS:
    t = xr.open_dataset(
      DAILY, engine="copernicusmarine", variables=["thetao"], start_datetime=d, end_datetime=d
    )
    gaps[d] = mask & t["thetao"].isel(time=0).isnull().load().values
  first = gaps[GAP_DAYS[0]]
  out["gaps"] = {
    "same_on_all_days": all(bool((g == first).all()) for g in gaps.values()),
    "levels_0_48": int(first[:49].sum()),
    "level_49": int(first[49].sum()),
    "level_49_sea_cells": int(mask[49].sum()),
    "rows_south_of_minus_76_9": int(first[:49, lat < -76.9].sum()),
    "row_90": int(first[:49, lat > 89.95].sum()),
    "scattered": int(first[:49, (lat >= -76.9) & (lat <= 89.95)].sum()),
    "values_outside_mask": int((day.thetao.notnull().values & ~mask).sum()),
  }
  coarse = regrid(day[["thetao"]], res, skipna=True, nan_threshold=1.0)
  frac = regrid(xr.Dataset({"b": st.bathy["mask"].astype("float32")}), res, skipna=False)
  sea = pu.fraction_mask(frac, fraction="b", mask_name="sea")["sea"].values
  valid = coarse.thetao.notnull().values
  empty = sea & ~valid
  out["regridded"] = {
    "values_outside_any_water": int((valid & ~sea).sum()),
    "sea_without_value_level_49": int(empty[49].sum()),
    "sea_without_value_levels_0_48": int(empty[:49].sum()),
    "columns_without_any_value": int((sea[0] & ~valid[:49].any(0)).sum()),
  }
  # The footnote: values with nan_threshold 0 lie inside the current mask.
  native_rule = pu.get_sea_mask(st.bathy, bathymetry="deptho", depth_dim="depth", mask_name="m")[
    "m"
  ].values
  bathy = regrid(st.bathy[["deptho"]].fillna(0.0), res, skipna=False).assign_coords(
    depth=st.bathy.depth
  )
  current = pu.get_sea_mask(bathy, bathymetry="deptho", depth_dim="depth", mask_name="m")[
    "m"
  ].values
  strict = np.isfinite(regrid(day[["thetao"]], res, skipna=True, nan_threshold=0.0).thetao.values)
  out["footnote"] = {
    "premise_exceptions": int((day.thetao.notnull().values & ~native_rule).sum()),
    "conclusion_exceptions": int((strict & ~current).sum()),
    "values_nan_threshold_0": int(strict.sum()),
  }
  return out


def section_fill(res: float, day: xr.Dataset, st: Static) -> dict[str, Any]:
  out: dict[str, Any] = {}
  variables = ["thetao", "so"]
  coarse = regrid(day[variables], res, skipna=True, nan_threshold=1.0)
  w = np.broadcast_to(areas(coarse), coarse.thetao.shape[1:])
  for K in LEFT_OUT:
    bottom = regrid(
      pu.get_bottom(day[variables].isel(depth=slice(0, K)), depth_dim="depth"),
      res,
      skipna=True,
      nan_threshold=1.0,
    )
    sub = coarse.isel(depth=slice(0, K + 1))
    above = pu.fill_from_above(
      sub.where(sub.depth < sub.depth[K]),  # level K left out
      variables=variables,
      depth_dim="depth",
    )
    res_k = {}
    for v in variables:
      truth, up, bot = coarse[v].values[K], above[v].values[K], bottom[v].values
      ok = np.isfinite(truth) & np.isfinite(up) & np.isfinite(bot)
      res_k[v] = {
        "cells": int(ok.sum()),
        "above": weighted((up - truth)[ok], w[ok]),
        "bottom": weighted((bot - truth)[ok], w[ok]),
      }
    out[K] = res_k
  return out


def section_ice(res: float, st: Static) -> dict[str, Any]:
  ice = (
    xr.open_dataset(
      DAILY,
      engine="copernicusmarine",
      variables=["siconc", "sithick", "usi", "vsi"],
      start_datetime=ICE_DAY,
      end_datetime=ICE_DAY,
    )
    .isel(time=0)
    .load()
  )
  sea = st.mask[0]
  native = pu.products(
    ice, sivol=["siconc", "sithick"], usic=["siconc", "usi"], vsic=["siconc", "vsi"]
  )
  frac = xr.Dataset(
    {"seafrac": (("latitude", "longitude"), sea.astype("float64"))},
    coords={k: ice[k] for k in ("latitude", "longitude")},
  )
  coarse = regrid(xr.merge([native[["siconc", "sivol", "usic", "vsic"]], frac]), res, skipna=False)
  coarse = pu.fraction_mask(coarse, fraction="seafrac")
  coarse = pu.divide_by(coarse, variables=["siconc", "sivol", "usic", "vsic"], by="seafrac")
  c0 = ice.siconc.fillna(0).where(sea)
  ref = regrid(
    xr.Dataset(
      {
        "c": c0,
        "ch": (c0 * ice.sithick.fillna(0)).where(sea),
        "cu": (c0 * ice.usi.fillna(0)).where(sea),
      }
    ),
    res,
    skipna=True,
    nan_threshold=1.0,
  )
  a_n, a_c = areas(ice), areas(coarse)
  f = np.nan_to_num(coarse.seafrac.values)  # NaN beyond the source's latitudes
  cz = np.nan_to_num(c0.values)
  out: dict[str, Any] = {
    "native_sea_cells": int(sea.sum()),
    "siconc_missing_on_sea": int((ice.siconc.isnull().values & sea).sum()),
    "usi_zero_on_sea": int((ice.usi.values == 0).sum()),
    "identity_max_abs": float(np.nanmax(np.abs(coarse.siconc.values - ref.c.values))),
    "area_ratio": float((a_c * f * np.nan_to_num(coarse.siconc.values)).sum() / (a_n * cz).sum()),
    "volume_ratio": float(
      (a_c * f * np.nan_to_num(coarse.sivol.values)).sum()
      / (a_n * cz * np.nan_to_num(ice.sithick.values)).sum()
    ),
  }
  c32 = np.nan_to_num(coarse.siconc.values).astype("float32")
  icy = c32 > 0
  for v, ref_name in [("sivol", "ch"), ("usic", "cu")]:
    reference = ref[ref_name].values / ref.c.values
    back = np.asarray(
      np.nan_to_num(coarse[v].values).astype("float32") / np.where(icy, c32, 1), dtype="float64"
    )
    rel = np.abs(back - reference)[icy] / np.maximum(np.abs(reference[icy]), 1e-12)
    out[f"round_trip_{v}_max_relative"] = float(np.nanmax(rel))
  thickness = np.where(icy, np.nan_to_num(coarse.sivol.values) / np.where(icy, c32, 1), np.nan)
  speed = np.where(icy, np.abs(np.nan_to_num(coarse.usic.values)) / np.where(icy, c32, 1), np.nan)
  bins = {}
  for lo, hi in [(0, 0.05), (0.05, 0.15), (0.15, 0.5), (0.5, 0.9), (0.9, 1.01)]:
    s = icy & (c32 > lo) & (c32 <= hi)
    bins[f"{lo}-{min(hi, 1.0)}"] = {
      "cells": int(s.sum()),
      "thickness_median": float(np.median(thickness[s])),
      "sivol_median": float(np.median(np.nan_to_num(coarse.sivol.values)[s])),
      "speed_median": float(np.median(speed[s])),
      "usic_abs_median": float(np.median(np.abs(np.nan_to_num(coarse.usic.values))[s])),
    }
  out["bins"] = bins
  return out


def section_rivers(res: float, st: Static) -> dict[str, Any]:
  with TempDirectoryRegistry():
    dis = xr.open_dataset(
      "ewds://cems-glofas-historical",
      engine="earlywarningdatastore",
      system_version="version_5_0",
      hydrological_model="lisflood",
      product_type="consolidated",
      timespan="time_mean",
      variable="average_river_discharge_in_the_last_24_hours",
      start_datetime=datetime.datetime(2013, 3, 1),
      end_datetime=datetime.datetime(2013, 3, 2),
    ).squeeze("time", drop=True)
    # Read the values while the downloaded files exist (`load` leaves the backend's arrays lazy).
    dis = xr.Dataset(
      {"avg_dis": (("latitude", "longitude"), np.asarray(dis["avg_dis"].values))},
      coords={"latitude": dis.latitude.values, "longitude": dis.longitude.values},
    )
    aux = (
      xr.merge(
        [
          xr.open_dataset(f"{GLOFAS_AUX}/ldd_glofas_v4_0.nc", engine="netcdfoverhttp")[["ldd"]],
          xr.open_dataset(f"{GLOFAS_AUX}/uparea_glofas_v4_0.nc", engine="netcdfoverhttp")[
            ["uparea"]
          ].rename(latitude="lat", longitude="lon"),
        ]
      )
      .rename(lat="latitude", lon="longitude")
      .load()
    )
  for name in ("latitude", "longitude"):  # the files' coordinates differ by about 4e-12
    assert np.allclose(aux[name].values, dis[name].values, rtol=0, atol=1e-9)
  aux = aux.assign_coords(latitude=dis.latitude, longitude=dis.longitude)
  ds = xr.merge([dis.rename(avg_dis="dis24"), aux])
  q = ds.dis24.values.astype("float64")
  pits = ds.ldd.values == 5
  a = areas(ds)
  out: dict[str, Any] = {
    "cells_with_discharge": int(np.isfinite(q).sum()),
    "pits": int(pits.sum()),
    "upstream_area_at_pits_over_land_area": float(
      np.nansum(ds.uparea.values[pits]) / (a * np.isfinite(q)).sum()
    ),
    "discharge_at_pits_m3s": float(np.nansum(q[pits])),
  }
  kept = pu.keep_where(ds, variables=["dis24"], condition="ldd", equals=5)
  density = pu.per_unit_area(kept[["dis24"]], variables=["dis24"], factor=86400.0)
  coarse = pu.regrid(
    density,
    grid=grid(res),
    method="conservative",
    kwargs={"skipna": False},
    conservation_tolerance=1e-6,
  ).load()
  per_cell = coarse.dis24.values * areas(coarse) / 86400.0
  frac = (
    regrid(xr.Dataset({"b": st.bathy["mask"].isel(depth=0).astype("float64")}), res, skipna=False)
    .b.fillna(0)
    .values
  )
  lat_p = ds.latitude.values[np.nonzero(pits)[0]]
  lon_p = (ds.longitude.values[np.nonzero(pits)[1]] + 360) % 360
  edge = np.isclose(((lat_p + 90) / res + 0.5) % 1, 0) | np.isclose((lon_p / res + 0.5) % 1, 0)
  out.update(
    {
      "coarse_total_m3s": float(np.nansum(per_cell)),
      "coarse_cells_with_input": int((np.nan_to_num(per_cell) > 0).sum()),
      "pits_on_coarse_edges": int(edge.sum()),
      "input_in_cells_with_sea": float(
        np.nansum(np.where(frac > 0, per_cell, 0)) / np.nansum(per_cell)
      ),
      "largest_cell_m3s": float(np.nanmax(per_cell)),
      "density_m_per_day_quantiles": quantiles(
        coarse.dis24.values[coarse.dis24.values > 0], (0.5, 0.9, 0.99, 1.0)
      ),
    }
  )
  mean = regrid(ds[["dis24"]], res, skipna=True, nan_threshold=0.0).dis24.values
  iy = np.floor((ds.latitude.values + 90) / res + 0.5).astype(int)
  ix = np.floor(((ds.longitude.values + 360) % 360) / res + 0.5).astype(int) % mean.shape[1]
  mx = np.full(mean.shape, -np.inf)
  Y, X = np.meshgrid(iy, ix, indexing="ij")
  ok = np.isfinite(q)
  np.maximum.at(mx, (Y[ok], X[ok]), q[ok])
  both = np.isfinite(mean) & (mx > 1)
  out["published_mean_over_main_river_median"] = float(np.median(mean[both] / mx[both]))
  return out


def section_waverys(res: float, st: Static) -> dict[str, Any]:
  ws = xr.open_dataset(
    WAVES_STATIC,
    engine="copernicusmarine",
    variables=["deptho"],
    dataset_version="202311",
    dataset_part="bathy",
    service="static-arco",
  ).load()
  wsea = np.isfinite(ws.deptho.values) & (ws.deptho.values > 0)
  fw = (
    regrid(
      ws.assign(sea=(("latitude", "longitude"), wsea.astype("float32")))[["sea"]], res, skipna=False
    )
    .sea.fillna(0)
    .values
  )
  fg = (
    regrid(xr.Dataset({"b": st.bathy["mask"].isel(depth=0).astype("float32")}), res, skipna=False)
    .b.fillna(0)
    .values
  )
  out: dict[str, Any] = {
    "waverys_any": int((fw > 0).sum()),
    "glorys_any": int((fg > 0).sum()),
    "waverys_only": int(((fw > 0) & (fg == 0)).sum()),
    "glorys_only": int(((fg > 0) & (fw == 0)).sum()),
  }
  era = xr.open_zarr(ERA5, consolidated=True, storage_options={"token": "anon"})["sea_ice_cover"]
  threshold = {}
  for stamp in ["2013-03-01T00:00", "2013-09-15T00:00"]:
    w = (
      xr.open_dataset(
        WAVES,
        engine="copernicusmarine",
        variables=["VHM0"],
        start_datetime=stamp,
        end_datetime=stamp,
      )
      .isel(time=0)
      .load()
    )
    sic = era.sel(time=stamp).load().sortby("latitude")
    valid = xr.Dataset(
      {
        "s": (("latitude", "longitude"), wsea.astype("float32")),
        "v": (("latitude", "longitude"), (w.VHM0.notnull().values & wsea).astype("float32")),
      },
      coords={"latitude": w.latitude, "longitude": w.longitude},
    )
    g = {
      "south": -90.0,
      "north": 90.0,
      "west": 0.0,
      "east": 359.75,
      "resolution_lat": 0.25,
      "resolution_lon": 0.25,
    }
    r = (
      pu.regrid(valid, grid=g, method="conservative", kwargs={"skipna": False})
      .load()
      .sortby("latitude")
    )
    open_sea = r.s.values > 0.99
    missing = 1 - r.v.values / np.where(r.s.values > 0, r.s.values, 1)
    rows = {}
    for lo, hi in [
      (0, 1e-6),
      (1e-6, 0.2),
      (0.2, 0.28),
      (0.28, 0.32),
      (0.32, 0.4),
      (0.4, 0.5),
      (0.5, 1.01),
    ]:
      s = open_sea & (sic.values >= lo) & (sic.values < hi)
      rows[f"{lo}-{hi}"] = float(missing[s].mean()) if s.any() else None
    threshold[stamp] = rows
  out["missing_share_by_era5_ice_cover"] = threshold
  return out


def measure(res: float, sections: list[str], path: pathlib.Path) -> None:
  settings.load()
  # Sections already measured in `path` are kept (rerun some with `--sections`).
  results: dict[str, Any] = json.loads(path.read_text()) if path.exists() else {}
  if results.get("resolution", res) != res:
    raise SystemExit(f"{path} holds measurements at another resolution")
  results["resolution"] = res
  st = Static()
  day = None
  if {"data", "fill"} & set(sections):
    day = (
      xr.open_dataset(
        DAILY,
        engine="copernicusmarine",
        variables=["thetao", "so"],
        start_datetime=DAY,
        end_datetime=DAY,
      )
      .isel(time=0)
      .load()
    )
  runners: dict[str, Callable[[], dict[str, Any]]] = {
    "glorys": lambda: section_glorys(res, st),
    "data": lambda: section_data(res, st, day),
    "fill": lambda: section_fill(res, day, st),
    "ice": lambda: section_ice(res, st),
    "rivers": lambda: section_rivers(res, st),
    "waverys": lambda: section_waverys(res, st),
  }
  for name in sections:
    print(f"section {name}...", file=sys.stderr, flush=True)
    results[name] = runners[name]()
    path.write_text(json.dumps(results, indent=1, default=float))
  print(f"wrote {path}", file=sys.stderr)


def main() -> None:
  parser = argparse.ArgumentParser(
    description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
  )
  sub = parser.add_subparsers(dest="command", required=True)
  m = sub.add_parser("measure")
  m.add_argument("resolution", type=float)
  m.add_argument("output", type=pathlib.Path)
  m.add_argument("--sections", default="glorys,data,fill,ice,rivers,waverys")
  t = sub.add_parser("tables")
  t.add_argument("inputs", type=pathlib.Path, nargs="+")
  args = parser.parse_args()
  if args.command == "measure":
    measure(args.resolution, args.sections.split(","), args.output)
  else:
    tables([json.loads(p.read_text()) for p in args.inputs])


def tables(results: list[dict[str, Any]]) -> None:
  """The notes' tables, one column per resolution."""

  def row(label: str, get: Callable[[dict[str, Any]], Any]) -> str:
    cells = []
    for r in results:
      try:
        value = get(r)
      except (KeyError, TypeError):
        value = None
      cells.append(
        "" if value is None else (f"{value:,}" if isinstance(value, int) else f"{value:.4g}")
      )
    return f"| {label} | " + " | ".join(cells) + " |"

  header = "| | " + " | ".join(f"{r['resolution']} deg" for r in results) + " |"
  rule = "|---|" + "---|" * len(results)
  print(header)
  print(rule)
  for lv in map(str, LEVELS):
    for key in [
      "current",
      "majority",
      "any",
      "current_only_vs_majority",
      "majority_only_vs_current",
    ]:
      print(
        row(f"level {lv}: {key}", lambda r, lv=lv, key=key: r["glorys"]["rules_per_level"][lv][key])
      )
  for key in ["fraction", "current mask", "majority mask", "any mask"]:
    print(
      row(
        f"volume / mean depth: {key}",
        lambda r, key=key: r["glorys"]["volumes_relative_to_mean_depth"][key],
      )
    )
  for lv in map(str, LEVELS):
    print(
      row(
        f"level {lv}: flat column / fraction",
        lambda r, lv=lv: r["glorys"]["layer_water_relative_to_fraction"][lv]["flat_column"],
      )
    )
  for key in [
    "values_outside_any_water",
    "sea_without_value_level_49",
    "sea_without_value_levels_0_48",
    "columns_without_any_value",
  ]:
    print(row(key, lambda r, key=key: r["data"]["regridded"][key]))
  for K in map(str, LEFT_OUT):
    for v in ["thetao", "so"]:
      for how in ["above", "bottom"]:
        print(
          row(
            f"left out {K}, {v}, {how}: RMSE",
            lambda r, K=K, v=v, how=how: r["fill"][K][v][how]["rmse"],
          )
        )
  for key in [
    "identity_max_abs",
    "area_ratio",
    "volume_ratio",
    "round_trip_sivol_max_relative",
    "round_trip_usic_max_relative",
  ]:
    print(row(f"ice: {key}", lambda r, key=key: r["ice"][key]))
  for key in [
    "coarse_total_m3s",
    "coarse_cells_with_input",
    "pits_on_coarse_edges",
    "input_in_cells_with_sea",
    "largest_cell_m3s",
    "published_mean_over_main_river_median",
  ]:
    print(row(f"rivers: {key}", lambda r, key=key: r["rivers"][key]))


if __name__ == "__main__":
  main()
