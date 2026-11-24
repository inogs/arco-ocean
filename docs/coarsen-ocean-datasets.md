# Coarsening ocean datasets

How [arco-make](https://github.com/stefanocampanella/arco-make)'s steps carry a z-level ocean
model (GLORYS12), its sea ice, and river discharge (GloFAS) to coarser regular grids, and what
the published fields mean. Written for ARCO-OCEAN (0.25°, 0.5° and 1° from GLORYS's 1/12°),
whose recipes are in `configs/download`; the steps are generic (arco-make's `docs/steps.md`).

Every statement with a number is backed by code, run with arco-make (the `notes` dependency
group, `uv sync --only-group notes`):

- the examples below (```` ```pycon ````) are doctests on synthetic data, run by
  `tests/test_coarsening_notes.py` (`uv run --only-group notes pytest tests`, and in CI);
- the examples marked ```` ```pycon live ```` read the real sources on small boxes, with
  Copernicus Marine credentials (`uv run --only-group notes pytest --live tests`);
- the global figures come from `docs/coarsen_analysis.py`, run at each resolution (section
  [Measurements](#measurements)); its numbers are those of the days it reads.

```pycon
>>> import numpy as np
>>> import xarray as xr
>>> from arcomake import processing_utils as pu

```

## 1. Setting

GLORYS12 is NEMO on a z-level grid: 50 levels of fixed thickness (`e3t`, 1 m at the surface,
458 m at the bottom), each native cell sea or land at each level. A coarse cell covers many native
cells (3 × 3 at 0.25°, 6 × 6 at 0.5°, 12 × 12 at 1°), whose sea floors lie at different depths.

`regrid` with `method = "conservative"` averages the native cells under each coarse cell,
weighted by their overlap and by latitude (cell areas on a sphere, xarray-regrid). Missing values:

- `skipna = false` counts them as 0 (land as depth 0, no ice as 0 concentration): the average
  is over the whole coarse cell;
- `skipna = true` averages the valid part only, and leaves NaN where the valid share is below
  `1 - nan_threshold`: `nan_threshold = 1` keeps a value wherever one native cell has one,
  `nan_threshold = 0` only where all have one.

```python
# xarray-regrid 0.4.2, methods/conservative.py (abridged)
if skipna:
  valid_frac = xr.dot(da.notnull(), *weight_arrays, dim=list(weights.keys()))
da_regrid = xr.dot(da.fillna(0), *weight_arrays, dim=list(weights.keys()))
if skipna:
  da_regrid /= valid_frac
  da_regrid = da_regrid.where(valid_frac >= get_valid_threshold(nan_threshold))
```

Two behaviours of xarray-regrid matter below: target cells whose centre lies outside the range
of the source's centres are NaN even where they overlap source cells (all methods); a source cell
straddling target cells is split by its overlap in degrees, not in area (1e-7 of a total for
0.05° cells on a 0.25° grid).

## 2. Layer faces

The static product gives `e3t`, one thickness per level (no partial cells): the faces are
`[0, cumsum(e3t)]`. `get_sea_mask` rebuilds them from the level centres instead, each centre
mid-layer; the two differ by up to 2 m at depth, enough to move a few thousand coarse cells
across a rule's cut (see [Measurements](#measurements)).

## 3. GLORYS's own sea cells

GLORYS's 3D `mask` marks a native cell sea where its depth `deptho` lies below the level's
centre: the cell is sea when water fills more than half of it. The model's bottom cell is
rounded to the nearest face. The relation holds everywhere but in a few tens of thousands of
cells (34,615), in one direction only (the rule says sea, the mask says land), and `mask` is exactly
"level below `deptho_lev`":

```pycon live
>>> import numpy as np
>>> import xarray as xr
>>> STATIC = "cm://cmems_mod_glo_phy_my_0.083deg_static"
>>> KW = {"engine": "copernicusmarine", "dataset_version": "202311", "service": "static-arco"}
>>> box = {"latitude": slice(-12, 12), "longitude": slice(95, 135)}  # Maritime Continent
>>> st = (
...   xr.open_dataset(STATIC, variables=["deptho", "deptho_lev", "mask"], dataset_part="bathy", **KW)
...   .sel(box)
...   .load()
... )
>>> mask = st["mask"].values.astype(bool)
>>> rule = np.nan_to_num(st.deptho.values)[None] > st.depth.values[:, None, None]
>>> bool((mask & ~rule).any())  # never sea for the mask and land for the rule
False
>>> k = np.arange(mask.shape[0])[:, None, None]
>>> bool((mask == (k < np.nan_to_num(st.deptho_lev.values)[None])).all())
True

```

The deepest level (49, centre 5,728 m) is sea in the mask but never has values: NEMO "has at most
jpk-1 t-points inside the ocean, the additional t-point at jk = jpk is below the sea floor and
is not used" (NEMO 3.6 manual, §4.3.2). Other cells marked sea without values (gaps) are few,
and the same every day (see [Measurements](#measurements)):

```pycon live
>>> DAILY = "cm://cmems_mod_glo_phy_my_0.083deg_P1D-m"
>>> day = xr.open_dataset(
...   DAILY,
...   engine="copernicusmarine",
...   variables=["thetao"],
...   start_datetime="2013-01-01",
...   end_datetime="2013-01-01",
... )
>>> t = day.thetao.isel(time=0).sel(box).load()
>>> int(mask[49].sum()) > 0, int(t.isel(depth=49).notnull().sum())
(True, 0)
>>> int((t.notnull().values & ~mask).sum())  # no value outside the mask
0

```

ARCO-OCEAN publishes 49 levels: level 49 is dropped.

## 4. Column water and mean depth

With land as depth 0, the conservative mean of `deptho` times the coarse cell's area is the water
volume of the column: the mean depth is the column's water, not a proxy for it. The water of each
native column, split by layer, adds up to its depth; averaging and summing over layers are both
linear, so the mean of the layers' water adds up to the mean depth. Only depths below the last
face (trenches below 5,958 m) break the identity.

## 5. Water per layer: a worked example

One coarse cell made of four native cells of equal area, four layers of 10 m; the native depths
are 0, 0, 8 and 40 m (two land cells, a shelf, a channel):

```pycon
>>> faces = np.array([0.0, 10.0, 20.0, 30.0, 40.0])
>>> top, h = faces[:-1], np.diff(faces)
>>> centres = (faces[:-1] + faces[1:]) / 2
>>> depths = np.array([0.0, 0.0, 8.0, 40.0])
>>> water = (np.clip(depths[:, None] - top, 0, h) / h).mean(axis=0)  # share of each layer
>>> water
array([0.45, 0.25, 0.25, 0.25])
>>> mean_depth = depths.mean()
>>> float(mean_depth), float((water * h).sum())  # the column identity
(12.0, 12.0)
>>> np.clip(mean_depth - top, 0, h) / h  # a flat column of 12 m
array([1. , 0.2, 0. , 0. ])
>>> fraction = (depths[:, None] > centres).mean(axis=0)  # GLORYS's mask, regridded
>>> fraction
array([0.5 , 0.25, 0.25, 0.25])
>>> float((fraction * h).sum())
12.5

```

| | Layer 0 | Layer 1 | Layer 2 | Layer 3 | Column |
|---|---|---|---|---|---|
| Water in the layer (share of the cell) | 0.45 | 0.25 | 0.25 | 0.25 | 12 m |
| Flat column of the mean depth | 1.00 | 0.20 | 0 | 0 | 12 m |
| GLORYS's mask regridded (`seafrac`) | 0.50 | 0.25 | 0.25 | 0.25 | 12.5 m |

- **The fraction** (`seafrac`) is GLORYS's 3D mask regridded conservatively: the share of the
  coarse cell's area where the model has a sea cell at that level. Times the layer's volume, it
  is the water GLORYS has there; summed over layers, the column's water (12.5 m against 12: the
  shelf's 8 m count as a full 10 m layer, below).
- **The flat column** spreads the mean depth evenly: it moves water from the layers that cross
  the sea floor inside the cell up to the layers above (layer 0 full, layers 2 and 3 empty though
  the channel fills them). What it adds above is what it removes below, so the column totals
  agree; the layers differ wherever a layer crosses the sea floor inside a coarse cell: coasts,
  slopes, ridges, seamounts, at any depth.

The fraction holds the column's water and its split by layer; the mean depth holds only the
total.

## 6. Rules: which coarse cells are sea

A rule turns the water of a cell and layer into sea or land:

```pycon
>>> mean_depth > centres  # current: the mean depth below the layer's centre
array([ True, False, False, False])
>>> fraction >= 0.5  # majority: at least half of the layer is sea
array([ True, False, False, False])
>>> fraction > 0  # any water
array([ True,  True,  True,  True])

```

- **Current** (the recipes until 2026: `get_sea_mask` on the regridded depth, `threshold = 0.5`)
  is GLORYS's own rule applied to a flat column. It guarantees "more than half water" only for a
  flat-bottomed cell; at 0.25° 8,869 surface cells it calls sea are less than half sea,
  and at depth cells more than half sea are called land (see [Measurements](#measurements)).
- **Majority** rounds each layer: it keeps each layer's water within half a percent down to
  4,800 m at 0.25°.
- **Any water** (ARCO-OCEAN's choice) keeps every cell where the model has some sea, so that
  every regridded value has a cell, and publishes `seafrac` with it: users weight by the
  fraction, or mask at another threshold (`seafrac >= 0.5` is the majority rule).

`fraction_mask` builds the mask: `threshold` (default 0) and `inclusive` choose the rule, and
`tolerance` (default 1e-6) clears round-off left by the regridding weights where a coarse cell
barely touches the source's cells:

```pycon
>>> ds = xr.Dataset({"seafrac": ("depth", np.array([0.5, 0.25, 1e-8, 0.0]))})
>>> out = pu.fraction_mask(ds, fraction="seafrac", mask_name="sea")
>>> out.seafrac.values, out.sea.values
(array([0.5 , 0.25, 0.  , 0.  ]), array([ True,  True, False, False]))
>>> pu.fraction_mask(ds, fraction="seafrac", mask_name="sea", threshold=0.5, inclusive=True).sea.values
array([ True, False, False, False])

```

No 0/1 mask conserves water: each rounds every cell and layer. The current rule rounds the
flat column to the nearest face (right in total, wrong by layer); majority rounds each layer;
any water rounds up. Only the fraction conserves water layer by layer.

**Inclusion.** If the mean depth lies below a layer's centre, some native column does too, and
is sea there: the current mask is inside the any-water mask, and its cells are empty only where
GLORYS itself has a gap.

**The footnote** (of the notebook these notes replace, `notebooks/regrid_glorys12.ipynb`). A
coarse value regridded with `nan_threshold = 0` lies inside the current mask, whatever its
threshold: every native cell under it has a value, hence is sea, hence lies deeper than the
threshold depth, and so does their weighted mean. Premises: native values
lie inside the native rule's mask; the weights of a coarse cell sum to 1; land counts as 0. On
random bathymetries:

```pycon
>>> rng = np.random.default_rng(0)
>>> fine = rng.choice([0.0, 3.0, 12.0, 27.0, 45.0], size=(1000, 4))  # 1000 coarse cells
>>> ok = True
>>> for threshold in (0.0, 0.25, 0.5, 0.75, 1.0):
...   cut = threshold * top + (1 - threshold) * faces[1:]  # the rule's depth per layer
...   all_sea = (fine[:, :, None] > cut).all(axis=1)  # a value with nan_threshold 0
...   current = fine.mean(axis=1)[:, None] > cut
...   ok &= bool((all_sea <= current).all())
>>> ok
True
>>> bool(((fine.mean(axis=1)[:, None] > centres) <= (fine[:, :, None] > centres).any(axis=1)).all())
True

```

The same holds on GLORYS (one day at 0.25°, see [Measurements](#measurements)): no native value
outside the native rule's mask, no regridded value outside the current mask.

## 7. `nan_threshold`

Natively, values exist exactly at GLORYS's sea cells, except its gaps. Regridded with
`nan_threshold = 1`, a coarse cell has a value wherever one native cell under it has one: exactly
the any-water cells, except where all their native sea cells are gaps. With 0, only where every
native cell has one: a coarse cell touching the coast or the sea floor has none. ARCO-OCEAN uses
1, with the any-water rule: values and sea cells coincide.

## 8. Volumes, partial cells, and Samudra

A mask counts a sea cell as a full layer. GLORYS's bottom cells are sea when more than half
full, so its mask rounds each column to the nearest face and the errors cancel (native mask
volume against `deptho`: -0.1 %). OM4, the model behind the Samudra emulator, counts partly
filled bottom cells as full, which overstates the volume (about 10 %, Samudra's notes). A
fraction computed from `deptho` with partial cells would put water where GLORYS has no cell and
no value; the fraction ARCO-OCEAN publishes is GLORYS's mask regridded, which describes where the
data are.

## 9. Gaps and filling

With level 49 dropped, a sea cell (any water) lacks a value only where all its native sea cells
are GLORYS gaps: a few thousand cells, the same every day. They are filled from the nearest value
above in the same column (`fill_from_above`), velocities included; cells with nothing above get
0 (`masked_fill`):

```pycon
>>> col = xr.Dataset(
...   {"t": ("depth", [4.0, np.nan, 2.0, np.nan]), "sea": ("depth", [True, True, True, True])}
... )
>>> pu.fill_from_above(col, variables=["t"], depth_dim="depth", mask_name="sea").t.values
array([4., 4., 2., 2.])

```

The recipes used to fill with the native bottom value of each column, regridded: under a coarse
cell this averages bottoms at different depths (a shelf edge and a plain), so a gap may get
water from far above it. Leaving one level out and refilling it, filling from above has
the lower error at every level tested (see [Measurements](#measurements)).

Elsewhere: horizontal extension from neighbouring sea cells (SOSIE's DROWN; CDO's `setmisstonn`,
`setmisstodis`; xESMF's `nearest_s2d`, `inverse_dist`, `creep_fill`), Laplace extension, or
leaving cells below the bottom missing (HYCOM's `layer2z`); remapping studies stress the boundary
treatment (White et al. 2009). A vertical fill always has a source for the gaps of GLORYS.

GLORYS was cut to latitudes -76.9167 to 89.9167 in earlier recipes: the rows south of it and the
row at 90° are sea in the static mask without any value. Without the cut, no coarse sea cell is
left empty by them (values come from the neighbouring rows, `nan_threshold = 1`), and the
round-off fractions that the cut caused near the equator disappear; the recipes read all rows.

## 10. Sea ice

GLORYS gives `siconc` (concentration) and `sithick` (thickness) NaN where there is no ice, and
`usi`, `vsi` (velocity) 0 there; all four have `cell_methods = "area: mean where sea_ice"`:
thickness and velocity are means over the ice-covered part, as in CMIP, where averages of
thickness are weighted by concentration (Notz et al. 2016).

ARCO-OCEAN publishes, over the sea part of each coarse cell:

- `siconc`: ice area / sea area;
- `sivol`: concentration × thickness, ice volume per unit sea area (m);
- `usic`, `vsic`: concentration × velocity.

Built with `products` on the native grid, `regrid` with `skipna = false` (missing as 0), and
`divide_by` the surface `seafrac`. GLORYS's quantities come back exactly: thickness is
`sivol / siconc` and velocity `usic / siconc` where `siconc > 0`, the means over the ice cover:

```pycon
>>> ice = xr.Dataset(
...   {  # three native cells: ice, open sea, land
...     "siconc": ("x", [0.8, np.nan, np.nan]),
...     "sithick": ("x", [2.0, np.nan, np.nan]),
...     "seafrac": ("x", [1.0, 1.0, 0.0]),
...   }
... )
>>> native = pu.products(ice, sivol=["siconc", "sithick"])
>>> coarse = native.fillna(0).mean("x")  # a conservative mean over one coarse cell
>>> coarse = pu.divide_by(coarse, variables=["siconc", "sivol"], by="seafrac")
>>> float(coarse.siconc), float(coarse.sivol), float(coarse.sivol / coarse.siconc)
(0.4, 0.8, 2.0)

```

Times `seafrac`, these fields are means over whole cells of native quantities (c, c h, c u), which
regrid linearly: coarsening them again (to 1°, say) gives what regridding the native fields gives.
They are 0 where there is no ice, continuous across the ice edge, and their area-weighted sums
(times `seafrac`) are the ice area and volume.

## 11. River discharge into the ocean

GloFAS gives the daily discharge (m³/s) of every land cell of its 0.05° grid. Discharge is not
additive across cells (a river's cell already holds its tributaries): averaging the cells of a
coarse cell mixes a main channel with hillslopes, a fifth of the main river at 0.25°, and less at
coarser grids. What the ocean receives is the discharge at the rivers' mouths.

GloFAS's local drain directions (LDD, the PCRaster convention: each cell points to its downstream
neighbour, 5 marks a pit, where the flow ends) give the mouths: the pits. ARCO-OCEAN publishes
`dis24_outlets`, the discharge at the pits as a flux per unit area of the coarse cell, in metres
per day like a daily precipitation total:

1. the LDD joins the discharge as a static part of the GloFAS dataset (`rename`,
   `coordinate_tolerance`: its coordinates differ from the discharge's by 4e-12);
2. `keep_where` keeps the discharge at the pits, 0 elsewhere;
3. `per_unit_area` divides by each native cell's area (times 86400: metres per day);
4. `regrid`, conservative, `skipna = false`, with `conservation_tolerance`: a pit straddling
   coarse cells is split by overlap, and the total must be kept.

```pycon
>>> lat, lon = np.arange(-0.875, 1.0, 0.25), np.arange(0.125, 2.0, 0.25)
>>> q = np.zeros((lat.size, lon.size))
>>> q[3, 4], q[6, 1] = 1000.0, 40.0  # two pits, m3/s
>>> pits = xr.Dataset({"q": (("latitude", "longitude"), q)}, coords={"latitude": lat, "longitude": lon})
>>> density = pu.per_unit_area(pits, variables=["q"])
>>> grid = {
...   "south": -0.75,
...   "north": 0.75,
...   "west": 0.25,
...   "east": 1.75,
...   "resolution_lat": 0.5,
...   "resolution_lon": 0.5,
... }
>>> coarse = pu.regrid(
...   density, grid=grid, method="conservative", kwargs={"skipna": False}, conservation_tolerance=1e-6
... )
>>> total = float((coarse.q * pu.cell_areas(coarse.latitude.values, coarse.longitude.values)).sum())
>>> round(total, 6)
1040.0

```

Checks: the upstream area at the pits equals the land area (every cell drains to one pit;
1.00006 for GloFAS v4.0's network); the total at the pits equals the total of the coarse field
(`conservation_tolerance`). GloFAS v5.0 publishes no LDD: the v4.0 one is used, on the same
6,221,926 cells as v5.0's discharge. Pits whose basin ends inland (the Caspian, Lake Chad, the
Okavango) stay in. The ocean model can link pits to its coast (Moby-Dick's
graph does): the dataset does not move them to sea cells.

The inland discharge (`dis24`), its mask and `uparea` are no longer published.

## 12. WAVERYS (not published)

WAVERYS (CMEMS's wave reanalysis, MFWAM on ERA5 winds and ice) was dropped from ARCO-OCEAN.
Findings, measured on 1 Mar and 15 Sep 2013 (`docs/coarsen_analysis.py`, section `waverys`):

- its sea (static depth, land NaN) differs from GLORYS's: none in the central Arctic (north of
  about 81°N), in a block of the Canadian Archipelago and in strips of the Antarctic coast (56,157
  GLORYS cells at 0.25°); sea in the Caspian, the Great Lakes, Ladoga and Onega (7,532 cells);
- waves are missing where ERA5's ice cover exceeds about 0.3 (half of the open-sea cells at
  0.28-0.32, nearly all above 0.4), a field the dataset does not contain;
- the recipes averaged the mean wave direction arithmetically, wrong across north (`sin_cos`
  fixes it), and filled waves under ice with 0, also the direction (meaning "from north") and
  the period.

## 13. What ARCO-OCEAN publishes

| Variable | Dimensions | Meaning |
|---|---|---|
| `seafrac` | depth, lat, lon (static) | share of the cell where GLORYS has a sea cell at that level |
| `deptho` | lat, lon (static) | mean sea-floor depth, land as 0 (the column's water) |
| `thetao`, `so`, `uo`, `vo` | time, depth, lat, lon | averages over the sea part; gaps filled from above |
| `zos` | time, lat, lon | average over the sea part |
| `siconc`, `sivol`, `usic`, `vsic` | time, lat, lon | over the sea part (section 10) |
| `dis24_outlets` | time, lat, lon | river input, metres per day over the cell (section 11) |
| `areacello` | lat, lon (static) | cell area (m²) on GLORYS12's sphere |
| `volcello` | depth, lat, lon (static) | sea water volume (m³): `seafrac` × layer thickness × `areacello` |
| `lat_bnds`, `lon_bnds`, `depth_bnds` | coordinate, bnds | CF cell bounds |

Values exist exactly where `seafrac > 0` (`ensure_no_nans` with `exact`). Volumes and heat
contents are sums of value × `volcello`, not of the mask; a model's loss is best weighted the
same way (water volume), so that cells barely touched by the sea weigh little. The ocean
variables name these weights in `cell_measures`, so CF tools find them.

The cells are those conservative regridding assumes: bounds midway between centres, the polar
rows half as tall. Areas are on a sphere of radius 6,378,100 m, the one GLORYS12's static cell
sizes (`e1t`, `e2t`) imply, so totals match the source's: at 1°, the total of `volcello` equals
GLORYS12's own (the sum of `e1t` × `e2t` × `e3t` × `mask` over levels 0-48, 1.330 × 10¹⁸ m³) to
2 × 10⁻⁷, at every level to 3 × 10⁻⁷. A sphere is not the Earth: against the WGS84 ellipsoid,
its cells are 0.45 % larger at the equator and 0.89 % smaller near the poles, whatever the
radius. Depth bounds are the faces `[0, cumsum(e3t)]` (section 2). River totals use the same
areas: discharge (m³/s) = `dis24_outlets` × `areacello` / 86400.

## Measurements

Generated by `docs/coarsen_analysis.py` (GLORYS 202311, GloFAS v5.0, 1 Jan 2013 for the ocean,
1 Mar 2013 for ice and rivers).

The same at every resolution (native GLORYS, section `glorys` and `data`):

| GLORYS12, native | |
|---|---|
| sea columns; deepest `deptho` | 6,151,166; 10,528 m (last face 5,958 m) |
| `mask` = level below `deptho_lev` | everywhere |
| `mask` = `deptho` below the centre | but 34,615 cells, all "rule sea, mask land" |
| bottom cell's water (share of its layer), quantiles 0, 1 %, 50 %, 99 % | 0.49, 0.51, 1.01, 1.56 |
| cells where a partial-cell fraction from `deptho` (> 0) differs from `mask` | 3,089,423 |
| faces rebuilt from centres against `cumsum(e3t)`, largest difference | 2.18 m |
| sea cells without value (levels 0-48), the same on 1993-01-01, 2013-01-01, 2021-06-30 | 224,223: 23,819 south of -76.9, 198,720 at 90°, 1,684 elsewhere |
| level 49: sea cells; with a value | 164,580; 0 |

Coarse grids (1 Jan 2013 for values):

| | 0.25° | 0.5° | 1° |
|---|---|---|---|
| column identity, largest gap (trenches) | 3,964 m | 2,707 m | 1,874 m |
| cells the current rule changes with `cumsum(e3t)` faces | 4,189 | 1,034 | 245 |
| level 0 (0.5 m): current / majority / any | 693,310 / 684,441 / 693,310 | 176,194 / 171,421 / 176,913 | 44,982 / 42,973 / 45,328 |
| level 0: current sea less than half sea | 8,869 | 4,773 | 2,009 |
| level 30 (454 m): current / majority / any | 600,081 / 599,197 / 608,646 | 150,793 / 150,030 / 155,772 | 38,071 / 37,647 / 40,045 |
| level 45 (3,992 m): current / majority / any | 322,447 / 324,494 / 359,731 | 80,231 / 81,579 / 98,869 | 20,002 / 20,500 / 26,852 |
| level 45: more than half sea, current land | 4,222 | 1,816 | 598 |
| level 48 (5,275 m): current / majority / any | 67,857 / 69,477 / 95,504 | 16,333 / 17,099 / 31,001 | 3,931 / 4,216 / 9,607 |
| volume / mean depth: `seafrac` | 0.9989 | 0.9989 | 0.9989 |
| volume / mean depth: current / majority / any mask | 0.9991 / 1.001 / 1.052 | 0.9993 / 1.003 / 1.107 | 0.9999 / 1.005 / 1.164 |
| flat column / `seafrac`, level 0 | 1.012 | 1.025 | 1.043 |
| flat column / `seafrac`, level 30 | 1.002 | 1.006 | 1.014 |
| flat column / `seafrac`, level 45 | 0.996 | 0.992 | 0.986 |
| flat column / `seafrac`, level 48 | 0.984 | 0.951 | 0.911 |
| regridded values outside any water | 0 | 0 | 0 |
| sea cells without value, levels 0-48 (filled from above) | 1,505 | 1,226 | 461 |
| sea columns without any value (filled with 0) | 0 | 0 | 0 |
| footnote: native values outside the native rule; values (`nan_threshold = 0`) outside the current mask | 0; 0 of 27,904,081 | 0; 0 of 6,693,626 | 0; 0 of 1,584,807 |

Filling (one level left out and refilled; RMSE, temperature °C / salinity):

| level left out | 0.25° above | 0.25° bottom | 0.5° above | 0.5° bottom | 1° above | 1° bottom |
|---|---|---|---|---|---|---|
| 10 (16 m) | 0.075 / 0.062 | 0.091 / 0.104 | 0.080 / 0.080 | 0.124 / 0.193 | 0.079 / 0.079 | 0.141 / 0.279 |
| 30 (454 m) | 1.21 / 0.119 | 1.41 / 0.131 | 1.21 / 0.118 | 1.75 / 0.164 | 1.20 / 0.117 | 2.03 / 0.211 |
| 40 (2,225 m) | 0.309 / 0.033 | 0.486 / 0.038 | 0.307 / 0.033 | 1.00 / 0.059 | 0.306 / 0.034 | 1.56 / 0.097 |
| 48 (5,275 m) | 0.043 / 0.0040 | 0.084 / 0.0050 | 0.042 / 0.0043 | 0.231 / 0.0124 | 0.041 / 0.0042 | 0.633 / 0.0261 |

Sea ice (1 Mar 2013) and rivers (GloFAS, 1 Mar 2013):

| | 0.25° | 0.5° | 1° |
|---|---|---|---|
| `siconc`: divided by `seafrac` against regridded over the sea part, largest difference | 0 | 0 | 0 |
| ice area; ice volume (coarse / native) | 1.000004; 1.000005 | 1.0000002; 1.0000002 | 1.0000002; 1.0000001 |
| thickness, velocity back from float32 `sivol`, `usic`: largest relative error | 1.5e-7 | 1.4e-7 | 1.5e-7 |
| pits; upstream area at pits / land area | 152,629; 1.00006 | 152,629; 1.00006 | 152,629; 1.00006 |
| discharge at the pits; coarse total | 1,079,448.7; 1,079,448.8 m³/s | 1,079,448.7; 1,079,448.7 | 1,079,448.7; 1,079,448.7 |
| cells with river input; pits on coarse edges | 29,892; 55,061 | 12,814; 0 | 5,597; 0 |
| river input in cells with GLORYS sea | 58 % | 68 % | 93 % |
| largest cell (the Amazon) | 244,040 m³/s | 244,030 m³/s | 245,130 m³/s |
| former `dis24` (mean) / main river, median | 0.22 | 0.11 | 0.058 |

GLORYS's sea ice natively: `siconc` missing on 5,027,535 of 6,151,166 sea cells (no ice), `usi`
0 on 5,125,114.

WAVERYS (section `waverys`): sea cells (any water) 644,685 against GLORYS's 693,310 at 0.25°
(7,532 only in WAVERYS, 56,157 only in GLORYS); share of open-sea cells without waves by ERA5's
ice cover, 1 Mar / 15 Sep 2013: 0.02 / 0.02 below 0.2, 0.15 / 0.17 at 0.2-0.28, 0.49 / 0.49 at
0.28-0.32, 0.81 / 0.83 at 0.32-0.4, 0.96 / 0.98 at 0.4-0.5, 1.00 / 1.00 above.

## References

- NEMO ocean engine, version 3.6 (Madec et al., 2016), §4.3.2-4.3.3 (z-coordinate, partial
  steps). <https://zenodo.org/records/1472492>
- Copernicus Marine, GLOBAL_MULTIYEAR_PHY_001_030 (GLORYS12V1), static and daily products.
- Copernicus Marine, GLOBAL_MULTIYEAR_WAV_001_032 (WAVERYS), product user manual, issue 1.6.
- ECMWF, IFS documentation Cy47r3, Part VII: ECMWF wave model, §5.5 (grids and land-sea mask).
- GloFAS v4.0 auxiliary data (LDD, upstream area):
  <https://confluence.ecmwf.int/display/CEMS/Auxiliary+Data>.
- Dai, A. and Trenberth, K. E. (2002): Estimates of freshwater discharge from continents,
  J. Hydrometeorology 3, 660-687.
- Notz, D. et al. (2016): The CMIP6 Sea-Ice Model Intercomparison Project (SIMIP), Geosci. Model
  Dev. 9, 3427-3446.
- White, L., Adcroft, A. and Hallberg, R. (2009): High-order regridding-remapping schemes for
  continuous isopycnal and generalized coordinates in ocean models, J. Comput. Phys. 228,
  8665-8692.
- Samudra: Dheeshjith, S. et al. (2025), an AI global ocean emulator trained on OM4.
- xESMF masking and extrapolation: <https://pangeo-xesmf.readthedocs.io/en/latest/notebooks/Masking.html>.
- SOSIE (DROWN): <https://brodeau.github.io/sosie>.
