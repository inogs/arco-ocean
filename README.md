# The ARCO-OCEAN Dataset

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.17751608.svg)](https://doi.org/10.5281/zenodo.17751608)

[//]: # (TODO: Put a cover figure)

## Summary

The availability of standard datasets and benchmarks has been a key factor in the development of new machine learning methods and models, including those applied to weather forecasting and climate science ([Rasp et al., 2023](https://arxiv.org/abs/2308.15560), [Watson-Parris et al., 2022](https://doi.org/10.1029/2021MS002954)). The ARCO-OCEAN dataset is a new dataset that aims to provide a representative, and to some extent comprehensive, dataset for training machine learning models to forecast the ocean state.

This dataset is the first to include both the ocean state and its forcing, and has been designed having in mind coupled atmosphere-ocean models for Subseasonal-to-Seasonal (S2S) forecasts ([Campanella et al., 2025](https://www.climatechange.ai/papers/iclr2025/81)). However, future extensions could include variables related to climate, like biogeochemistry or a full-depth representation of the ocean.

## Data

ARCO-OCEAN is an analysis-ready cloud-optimized ([Abernathey et al., 2021](https://doi.org/10.1109/MCSE.2021.3059437)) dataset providing physical properties of the ocean, waves, and sea ice for a period of about 28 years between the 1st of January 1993 and the 30th of June 2021. The dataset includes also atmospheric and hydrological variables that would be needed as boundary conditions and used to drive a numerical simulation. The dataset is the result of collecting, processing, merging and optimizing for the cloud different data sources, all retrospective analyses (reanalyses) or hindcasts of different Earth system components.

The fields are discretized on a regular grid with a horizontal spatial resolution of 0.25°. The latter being the resolution of most state-of-the-art machine learning weather forecasting models trained on the retrospective analysis ERA5 ([Hersback et al., 2020](https://doi.org/10.1002/qj.3803)). Many of the variables in ARCO-OCEAN were originally defined on an Arakawa C grid and afterward interpolated on cell centers before being further postprocessed and ingested in the dataset. Please refer to the documentation of individual source datasets for more details. Also, see the section on regridding below.

The temporal resolution of ARCO-OCEAN is 1 day. The simulation timestep of numerical models is usually much less than that, and source datasets distribute either system state snapshots or time averages (or accumulations, e.g., for precipitation) at lower temporal resolutions. On top of that, the ARCO-OCEAN postprocessing further reduces the temporal resolution of some of these datasets. Individual sections of documentation provide more details.

ARCO-OCEAN is distributed as a Zarr dataset using the [Zarr Storage Specification Version 2](https://zarr-specs.readthedocs.io/en/latest/v2/v2.0.html) with consolidated metadata, but migration to version 3 is planned. The previous can be accessed directly from the cloud or downloaded to local storage. The dataset is chunked only along the time dimension, with a chunk size of 1 day, and uses LZ4 compression with compression level 1. This choice was motivated by speed-memory efficiency trade-offs and aimed at minimizing the time spent on IO when reading short segments of the dataset (2/3 days) from local storage. This chunking scheme might be suboptimal for some applications, such as computing the climatology, especially for small areas. Hence, dataset statistics (climatology, mean, and others) are provided.

Indeed, the dataset has been designed to train a machine learning forecasting model and takes inspiration from similar datasets, like ARCO-ERA5 ([Carver et al., 2023](https://ams.confex.com/ams/103ANNUAL/meetingapp.cgi/Paper/415842)). In light of this, design choices made are motivated in the following, and more precise information on how to reproduce the ARCO-OCEAN dataset is provided.

### Ocean and sea ice

The ocean circulation and sea ice variables are taken from the GLORYS12 reanalysis[^1], hence the dataset contains modified E.U. Copernicus Marine Service Information; [DOI: 10.48670/moi-00021](https://doi.org/10.48670/moi-00021).

GLORYS12 has an eddy-resolving resolution of 0.083°, which enables a high-fidelity representation of the dynamics of the ocean. Henceforth, by regridding a higher resolution product, the ARCO-OCEAN dataset retains accuracy although its lower resolution, as argued in [El Aouni et al., 2024](https://arxiv.org/abs/2412.05454). Notice that GLORYS12 has a domain including longitudes between -80° and 90°. During postprocessing steps this domain has been extended to lower latitudes by filling them with missing values (NaNs). From the viewpoint of the computation of the mask (see the related section below), it is as if the points at these latitudes were covered with land.

GLORYS12 is the only source dataset with a corresponding vertical dimension in ARCO-OCEAN. The number of vertical levels has been reduced from 50 to 10 by subsampling GLORYS12 at the following levels: 0, 4, 8, 12, 16, 20, 24, 28, 32, and 34. Hence, ARCO-OCEAN contains the surface level (at about 50 cm depth, not accounting for skin effects), which is the most important due to coupling with the atmosphere, and 9 levels below, at (about) geometrically increasing depths within the first kilometre.

| ARCO-OCEAN level | GLORYS12 level | Depth (m) |
|------------------|----------------|-----------|
| 0                | 0              | 0.494025  |
| 1                | 4              | 5.078224  |
| 2                | 8              | 11.405    |
| 3                | 12             | 21.59882  |
| 4                | 16             | 40.34405  |
| 5                | 20             | 77.85385  |
| 6                | 24             | 155.8507  |
| 7                | 28             | 318.1274  |
| 8                | 32             | 643.5668  |
| 9                | 34             | 902.3393  |

This is to reduce the memory footprint of the dataset while keeping a faithful representation of the dynamics at timescales of interest. Indeed, the selected depths will contain the mixed layer, the pycnocline and the thermocline for most latitudes and times, while deeper circulation would be less relevant for S2S timescales. Given that mesoscale vertical velocities are on the order of centimetres per day, but high-magnitude events can be on the order of meters per day ([Christensen et al., 2024](https://doi.org/10.1029/2023JC020003)), most of the dynamics can be captured within the first kilometre.

All dynamic variables, except the bottom temperature for the above reason, have been kept, and their names reflect those used in the source dataset.

| Variable name | Description                                   | Data type | Units   | Assimilated |
|---------------|-----------------------------------------------|-----------|---------|-------------|
| `thetao`      | Potential temperature                         | float32   | °C      | Yes         |
| `so`          | Salinity                                      | float32   | - (PSU) | Yes         |
| `uo`          | Eastward ocean current velocity               | float32   | m/s     | No          |
| `vo`          | Northward ocean current velocity              | float32   | m/s     | No          |
| `zos`         | Sea surface height above geoid                | float32   | m       | Yes         |
| `siconc`      | Sea ice concentration (over the sea part)     | float32   | -       | Yes         |
| `sivol`       | Sea ice volume per area (`siconc` × `sithick`) | float32  | m       | No          |
| `usic`        | `siconc` × eastward sea ice velocity          | float32   | m/s     | No          |
| `vsic`        | `siconc` × northward sea ice velocity         | float32   | m/s     | No          |

Values are averages over the sea part of each cell. GLORYS12's sea ice thickness and velocity (means over the ice-covered part) are `sivol / siconc`, `usic / siconc` and `vsic / siconc` where `siconc > 0`. The deepest GLORYS12 level (5728 m) is not published: the model never computes it.

| Variable name | Description                                            | Data type | Units |
|---------------|--------------------------------------------------------|-----------|-------|
| `seafrac`     | Share of the cell where GLORYS12 has a sea cell, per level | float32 | -   |
| `deptho`      | Mean sea-floor depth, land as 0 (the column's water)   | float32   | m     |
| `areacello`   | Cell area, on GLORYS12's sphere (radius 6,378,100 m)   | float32   | m²    |
| `volcello`    | Sea water volume of the cell: `seafrac` × layer thickness × `areacello` | float32 | m³ |
| `lat_bnds`, `lon_bnds`, `depth_bnds` | CF cell bounds (depth: GLORYS12's layer faces) | float32 | ° / m |

Ocean and sea ice values exist exactly where `seafrac > 0`. Volumes and heat contents are sums of value × `volcello`; areas and river totals use `areacello` (discharge in m³/s = `dis24_outlets` × `areacello` / 86400). The variables name these weights in `cell_measures`. How these fields are built, and why, is in the [notes on coarsening ocean datasets](https://github.com/stefanocampanella/arco-make/blob/master/docs/coarsen-ocean-datasets.md).

[^1]: Global Ocean Physics Reanalysis. E.U. Copernicus Marine Service Information (CMEMS). Marine Data Store (MDS). DOI: 10.48670/moi-00021 (Accessed on 10-Oct-2025)

### Waves

WAVERYS wave variables were part of earlier versions and are no longer included: their sea and ice masks differ from GLORYS12's (no sea north of about 81°N, waves missing where ERA5's ice cover exceeds about 0.3). The findings are kept in the notes on coarsening.

### Atmospheric

Dynamical atmospheric variables are derived from the ERA5 dataset available as a public dataset on Google Cloud Storage[^3], which redistributes the data available on Climate Data Store[^4]. As such, it requires attributing the original source.

> Hersbach et al, (2017) was downloaded from the Copernicus Climate Change Service (C3S) Climate Data Store. We thank C3S for allowing us to redistribute the data.
> Hersbach, H., Bell, B., Berrisford, P., Hirahara, S., Horányi, A., Muñoz‐Sabater, J., Nicolas, J., Peubey, C., Radu, R., Schepers, D., Simmons, A., Soci, C., Abdalla, S., Abellan, X., Balsamo, G., Bechtold, P., Biavati, G., Bidlot, J., Bonavita, M., De Chiara, G., Dahlgren, P., Dee, D., Diamantakis, M., Dragani, R., Flemming, J., Forbes, R., Fuentes, M., Geer, A., Haimberger, L., Healy, S., Hogan, R.J., Hólm, E., Janisková, M., Keeley, S., Laloyaux, P., Lopez, P., Lupu, C., Radnoti, G., de Rosnay, P., Rozum, I., Vamborg, F., Villaume, S., Thépaut, J-N. (2017): Complete ERA5: Fifth generation of ECMWF atmospheric reanalyses of the global climate. Copernicus Climate Change Service (C3S) Data Store (CDS). (Accessed on DD-MM-YYYY)
> The results contain modified Copernicus Climate Change Service information 2022. Neither the European Commission nor ECMWF is responsible for any use that may be made of the Copernicus information or data it contains.

The question regarding which atmospheric variables one should include in the training of a data-driven ocean circulation model is still an open research one. As an example, at the moment of writing, some competitive models use just the air temperature at 2 metres and the wind velocity at 10 metres above the surface ([El Aouni et al., 2024](https://arxiv.org/abs/2412.05454)), or even just the winds ([Wang et al., 2024](https://arxiv.org/abs/2402.02995)). Another obvious starting point is using the variables used by numerical models, as [NEMO](https://www.nemo-ocean.eu/doc/node27.html) or [MITgcm](https://mitgcm.readthedocs.io/en/latest/phys_pkgs/exf.html#ssub-phys-pkg-exf-inputs-units), an approach closer to that followed by [Cui et al., 2025](https://doi.org/10.1038/s41467-025-57389-2).

The wind stress, the evaporation, and the latent and sensible heat fluxes can be computed using bulk formulae (for a discussion of their parametrization in NEMO see [Bonino et al., 2022](https://doi.org/10.5194/gmd-15-6873-2022)), starting from the air density and pressure. In turn, the former can be computed from temperature and specific humidity. In particular, we included the dew point temperature at 2 metres above the surface, but not the lowest level of the 3D specific humidity, following the [ECMWF guidelines for computing the surface (2m) specific humidity](https://confluence.ecmwf.int/display/CKB/ERA5%3A+data+documentation#heading-Guidelines). Also, precipitations, wind gusts and variables relevant for radiative transfers were included.

The temporal resolution of the ARCO-ERA5 dataset is 1 hour; therefore, it had to be resampled at a daily resolution. This means that all variables should be intended as averages over the time interval of 24 hours, including, for example, the instantaneous wind gusts, apart from the time invariants `z` and `lsm` (below).

The total precipitation in the dataset comprises both rainfall and snowfall, and is obtained from the variable `total_precipitation` in the ARCO-ERA5 dataset, which contains the accumulated value in the last hour. After resampling its value has been rescaled to the total precipitation in the previous day (by multiplying by 24 hours, after averaging). Similar considerations apply to solar and terrestrial radiation variables, which contain accumulated values.

| Variable name | Description                                        | Data type | Units | Assimilated |
|---------------|----------------------------------------------------|-----------|-------|-------------|
| `2t`          | Temperature of air at 2m                           | float32   | K     | Yes         |
| `2d`          | Dew temperature of air at 2m                       | float32   | K     | Yes         |
| `sp`          | Pressure of the atmosphere at the surface          | float32   | Pa    | Yes         |
| `ssrd`        | Shortwave radiation at surface (positive downward) | float32   | J/m^2 | No          |
| `strd`        | Longwave radiation at surface (positive downward)  | float32   | J/m^2 | No          |
| `tp`          | Hourly total precipitation rate                    | float32   | m     | Yes         |
| `10u`         | Eastward wind velocity at 10m                      | float32   | m/s   | Yes         |
| `10v`         | Northward wind velocity at 10m                     | float32   | m/s   | Yes         |
| `i10fg`       | Maximum wind gust at 10m at specified time         | float32   | m/s   | No          |

Time invariants are read from the same ARCO-ERA5 store at one stamp, 2000-01-01 00:00, and stored once, without the time dimension. ERA5 stores them as hourly series of the same values (identical on 1993-01-01, 2000-01-01, 2010-07-01 and 2021-06-30), except `z` from 2022-10-01 on, which differs at the two polar rows. The climatology and the anomaly standard deviation leave them out, with the other static variables.

| Variable name | Description                                                      | Data type | Units   |
|---------------|------------------------------------------------------------------|-----------|---------|
| `z`           | Gravitational potential energy per unit mass at surface (static) | float32   | m^2/s^2 |
| `lsm`         | Fraction of land in a grid cell (static)                         | float32   | -       |

[^3]: Carver, Robert W, and Merose, Alex. (2023): ARCO-ERA5: An Analysis-Ready Cloud-Optimized Reanalysis Dataset.
22nd Conf. on AI for Env. Science, Denver, CO, Amer. Meteo. Soc, 4A.1, [https://ams.confex.com/ams/103ANNUAL/meetingapp.cgi/Paper/415842](https://ams.confex.com/ams/103ANNUAL/meetingapp.cgi/Paper/415842)

[^4]: Copernicus Climate Change Service, Climate Data Store, (2023): ERA5 hourly data on single levels from 1940 to present. Copernicus Climate Change Service (C3S) Climate Data Store (CDS). DOI: 10.24381/cds.adbb2d47 (Accessed on 10-Oct-2025)


### Hydrological

Hydrological variables and their auxiliary data are derived from historical GloFAS data[^6] and downloaded from EWDS[^7], hence the dataset contains modified Copernicus Emergency Management Service information 2025. The European Commission is not responsible for any use that may be made of the Copernicus information or data it contains.

River runoff is required to compute the freshwater budget of the ocean, along with the evaporation, sea ice, and precipitation. For this reason, ARCO-OCEAN contains the discharge of global rivers (including sediments, chemical and biological material) in the last 24 hours, taken from GloFAS. This value, although not assimilated, is computed by forcing a hydrological model with an atmospheric reanalysis (ERA5). Whether a machine learning model could make use of this information and, for example, remove the contribution of sediments to the volumetric flow rate is still an open research question.

| Variable name   | Description                                                     | Data type | Units | Assimilated |
|-----------------|-----------------------------------------------------------------|-----------|-------|-------------|
| `dis24_outlets` | River discharge into the ocean, metres per day over each cell   | float32   | m     | No          |

The discharge (GloFAS v5.0, mean of 24 h) is taken at the pits of GloFAS's drainage network (local drain direction 5, from the v4.0 auxiliary data), where rivers end, divided by the area of the cell and regridded conservatively: like a daily precipitation total, and the global total is kept (checked at every step). The discharge of a cell, in m^3/s, is the value × cell area / 86400. The ocean model links the outlets to its coast; pits of basins without an outlet to the sea (Caspian, Lake Chad) are included.

[^6]: Grimaldi, S., Salamon, P., Disperati, J., Zsoter, E., Russo, C., Ramos, A., Carton De Wiart, C., Barnard, C., Hansford, E., Gomes, G., Prudhomme, C. (2022): River discharge and related historical data from the Global Flood Awareness System, v4.0. European Commission, Joint Research Centre (JRC). DOI: 10.24381/cds.a4fdd6b9 (Accessed on 10-Oct-2025)

[^7]: Joint Research Center, Copernicus Emergency Management Service (2019): River discharge and related historical data from the Global Flood Awareness System. Early Warning Data Store (EWDS). DOI: 10.24381/cds.a4fdd6b9 (Accessed on 10-Oct-2025)


### Notes on regridding, null values, and masking

All fields are regridded conservatively with `xarray-regrid` ([Schilperoort et al., 2025](https://doi.org/10.5281/zenodo.15176942)), which averages the source cells under each target cell weighted by their overlap.

- Ocean fields: averages over the sea part of each cell. A cell is sea (has values) where `seafrac > 0`, i.e. where GLORYS12 has some sea cell: GLORYS12's 3D mask regridded is `seafrac`, so the domain is static and every regridded value has a cell. The few sea cells where GLORYS12 has no value (its gaps, the same every day) take the nearest value above in the same column, or 0 if none.
- Sea ice: averages over the sea part, no ice as 0 (section above).
- River discharge: a flux per unit area, regridded with missing values as 0.
- ERA5: the `land_sea_mask`, renamed `lsm`, is the fraction of land in each cell. `z` and `lsm` are constant in ERA5, which stores them as series: they are read at one stamp and stored once, without the time dimension.

The [notes on coarsening ocean datasets](https://github.com/stefanocampanella/arco-make/blob/master/docs/coarsen-ocean-datasets.md) explain these choices, with measurements at 0.25°, 0.5° and 1°: which coarse cells to call sea, how the water of each layer is kept, how gaps are filled, sea ice and river discharge.

## Data format

The dataset uses Zarr format version 2. The dataset has four dimensions. The longitude and latitude dimensions are named `lon` and `lat`, respectively. The time dimension is named `time`, and finally the vertical dimension is named `level`. All dimensions but `level` have a corresponding coordinate variable, the latter has also an auxiliary coordinate named `depth`. The latitudes are in the range [-90, 90], and the longitudes are in the range [0, 360], following the [convention used by the ECMWF](https://confluence.ecmwf.int/display/CKB/ERA5%3A+What+is+the+spatial+reference#ERA5:Whatisthespatialreference-Coordinatesystem). The level coordinate corresponds to the original vertical levels in GLORYS12, and similarly for depth. The time coordinate uses the proleptic Gregorian calendar and unit "days since 2000-01-01 00:00:00" (UTC). Notice that when loaded with XArray, it will have nanosecond resolution, but only the date part is relevant as the dataset has daily resolution.

All variables use single precision floating point numbers, except masks which use one byte integer values. They use C order (row-major) storage, with time as the leading (slowest varying) dimension, followed by level (when present), then latitude, and finally longitude. The dataset is chunked along the time dimension, with a chunk size of 1 day. At a resolution of 0.25°, the latter corresponds to 4MB chunks in memory, and a disk footprint of ocean variables chunks ranging from 500KB to 2.8MB depending on the content of the chunk and compression ratio. Indeed, masked values, about 70% of the domain, are NaNs, sea ice variables are 0.0 or NaN on most of the domain. The total size of the dataset at this resolution is about 1.3TB.

The statistics (climatology, anomaly standard deviation, mean) are computed over the reference period 1993-2018: later years are held out for evaluation and do not enter the normalization.

The climatology and the anomaly standard deviation have 365 bins along `time`, the days of a 365-day year (0 = Jan 1). Feb 29 values are pooled with Feb 28 (bin 58), and the later days of leap years use the bin of the same date: to index them, take the day of year minus 1, and minus 1 more after Feb 29 in leap years. Each bin is smoothed with a Gaussian window of 29 days (scale 7 days), counting only the values present.

## Data access

The available ARCO-OCEAN dataset versions and their statistics are available via [AWS S3](https://aws.amazon.com/s3/) at the `s3://ogs-arco-ocean` bucket. Once you have the S3 URI pointing to a version of the dataset, you can either download it locally using the AWS CLI or open the dataset remotely, for example, using XArray. Say you want to work with the dataset located at `s3://ogs-arco-ocean/dataset/tres=1d/res=0p25/levels=10`.

In the first case, you'll need to install the AWS CLI. See these instructions for [installing AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html). Once installed the AWS CLI, you can download the dataset using the following command:

```bash
aws s3 cp s3://ogs-arco-ocean/dataset/tres=1d/res=0p25/levels=10 /path/to/local/dataset --recursive --no-sign-request
```

In the second case, you'll need to have a Python environment with `xarray` and `zarr` installed, more information on how to install them can be found [here](https://docs.xarray.dev/en/stable/getting-started-guide/installing.html) and [here](https://zarr.readthedocs.io/en/stable/installation.html). You'll also need other dependencies and use a slightly different code depending on the version of Zarr-Python installed (Zarr-Python version 3 is currently still capable of reading a Zarr version 2 dataset, as ARCO-OCEAN).

If you're using `zarr==2`, then `fsspec` and `s3fs` will also be needed, and you'll be able to open the dataset using the `FSStore` from `zarr.storage` as follows:

```python
import zarr
import xarray as xr

# see https://zarr.readthedocs.io/en/support-v2/api/storage.html#zarr.storage.FSStore for more information
store = zarr.storage.FSStore(url='s3://ogs-arco-ocean/dataset/tres=1d/res=0p25/levels=10', mode='r', anon=True)

dataset = xr.open_dataset(store, engine='zarr')
```

If you're using `zarr==3`, then you'll need to install also `obstore`, and then use the `ObjectStore` from `zarr.storage` as follows:

```python
import xarray as xr
from zarr.storage import ObjectStore
from obstore.store import S3Store

# see https://zarr.readthedocs.io/en/stable/user-guide/storage.html#object-store for more information
s3_store = S3Store('ogs-arco-ocean/dataset/tres=1d/res=0p25/levels=10', skip_signature=True, region='eu-south-1')
store = ObjectStore(store=s3_store, read_only=True)
dataset = xr.open_dataset(store, engine='zarr')
```

The dataset can be accessed using the Hive partition format `s3://ogs-arco-ocean/dataset/<dataset_name>_tres-<time_resolution>_res-<horizontal_resolution_in_deg>_levels-<number_of_vertical_levels>`. At the moment, we distribute a single version with full path `s3://ogs-arco-ocean/dataset/tres=1d/res=0p25/levels=10`.

Along with the main dataset, statistics computed with respect to the time dimension are also provided. These are the climatology, the anomaly standard deviation, and the mean. These can be accessed using paths: `s3://ogs-arco-ocean/stats=<stats_name>/tres=<time_resolution>/res=<horizontal_resolution_in_deg>/levels=<number_of_vertical_levels>`, where `<stats_name>` is one of `climatology`, `anomaly_std`, or `mean`.

## Tutorials

1. [Computing the Oceanic El Nino Index (ONI) with Xarray and ARCO-OCEAN](tutorials/oni.ipynb)

## License

This dataset is released for use under the CC-BY license. Highlights and key features of the license are provided [here](https://creativecommons.org/licenses/by/4.0/). Full legal text is provided [here](https://creativecommons.org/licenses/by/4.0/legalcode).

## Suggested attribution

[//]: # (FIXME: Temporary. Come up with a better attribution)
```
Campanella, S., Salon S., Querin, S., Bortolussi, L., and Stock, J.: ARCO-OCEAN: A dataset of physical properties of the ocean, waves, and sea ice, with hydrological and atmospheric forcing, optimized for machine learning. https://doi.org/10.5281/zenodo.17751608
```
