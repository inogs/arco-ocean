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

| Variable name | Description                      | Data type | Units   | Assimilated |
|---------------|----------------------------------|-----------|---------|-------------|
| `thetao`      | Potential temperature            | float32   | °C      | Yes         |
| `so`          | Salinity                         | float32   | - (PSU) | Yes         |
| `uo`          | Eastward ocean current velocity  | float32   | m/s     | No          |
| `vo`          | Northward ocean current velocity | float32   | m/s     | No          |
| `zos`         | Sea surface height above geoid   | float32   | m       | Yes         |
| `mlostst`     | Mixed layer thickness            | float32   | m       | No          |
| `siconc`      | Sea ice concentration            | float32   | -       | Yes         |
| `sithick`     | Sea ice thickness                | float32   | m       | No          |
| `usi`         | Eastward sea ice velocity        | float32   | m/s     | No          |
| `vsi`         | Northward sea ice velocity       | float32   | m/s     | No          |

The only time invariant taken from GLORYS12 is the depth of the ocean below the geoid, while the mask has been recomputed as explained below.

| Variable name | Description                        | Data type      | Units |
|---------------|------------------------------------|----------------|-------|
| `deptho`      | Depth of the ocean below the geoid | float32 (bool) | m     |
| `glorys_mask` | GLORYS12 sea/land mask             | int8 (bool)    | -     |

[^1]: Global Ocean Physics Reanalysis. E.U. Copernicus Marine Service Information (CMEMS). Marine Data Store (MDS). DOI: 10.48670/moi-00021 (Accessed on 10-Oct-2025)

### Waves

The wave variables are derived from the WAVERYS reanalysis[^2], hence the dataset contains modified E.U. Copernicus Marine Service Information; [DOI: 10.48670/moi-00022](https://doi.org/10.48670/moi-00022).

Ocean waves form the boundary between the ocean and the atmosphere. Accurately describing the physical processes at this ocean–atmosphere boundary allows determining the air–sea fluxes of momentum, sensible and latent heat, among others. Since the wave field plays a key role in these exchange processes, wave models are necessary not only to represent the wave spectrum but also to simulate the interface processes that regulate fluxes across it. Information about the sea state provided by wave models can therefore be explicitly used in studies of air–sea interactions.

For these reasons, as well as other potential uses of the dataset, a core number of physical variables from WAVERYS have been selected. Among them, one can reasonably expect that significant wave height contributes the most to driving ocean circulation, by changing the sea surface roughness length, hence wind stresses. Notice that, to the best knowledge of the authors, there are no publicly available S2S forecasts for wave data. Hence, the inclusion of these variables in the training of an autoregressive model is not advised if working on operational systems targeting those timescales.

| Variable name | Description                                   | Data type | Units | Assimilated |
|---------------|-----------------------------------------------|-----------|-------|-------------|
| `swh`         | Spectral significant wave height (`VHM0`)     | float32   | m     | Yes         |
| `swp`         | Spectral moments (0, 2) wave period (`VTM02`) | float32   | s     | Yes         |
| `mwd`         | Mean wave direction from (`VMDR`)             | float32   | deg   | Yes         |
| `usd`         | Stokes drift eastward velocity  (`VSDX`)      | float32   | m/s   | Yes         |
| `vsd`         | Stokes drift northward velocity (`VSDY`)      | float32   | m/s   | Yes         |

Finally, notice that the bathymetry differs from the one in GLORYS12.

| Variable name    | Description                        | Data type   | Units |
|------------------|------------------------------------|-------------|-------|
| `waverys_deptho` | Depth of the ocean below the geoid | float32     | m     |
| `waverys_mask`   | WAVERYS sea/land mask              | int8 (bool) | -     |

[^2]: Global Ocean Waves Reanalysis. E.U. Copernicus Marine Service Information (CMEMS). Marine Data Store (MDS). DOI: 10.48670/moi-00021 (Accessed on 10-Oct-2025)

### Atmospheric

Dynamical atmospheric variables are derived from the ERA5 dataset available as a public dataset on Google Cloud Storage[^3], which redistributes the data available on Climate Data Store[^4]. As such, it requires attributing the original source.

> Hersbach et al, (2017) was downloaded from the Copernicus Climate Change Service (C3S) Climate Data Store. We thank C3S for allowing us to redistribute the data.
> Hersbach, H., Bell, B., Berrisford, P., Hirahara, S., Horányi, A., Muñoz‐Sabater, J., Nicolas, J., Peubey, C., Radu, R., Schepers, D., Simmons, A., Soci, C., Abdalla, S., Abellan, X., Balsamo, G., Bechtold, P., Biavati, G., Bidlot, J., Bonavita, M., De Chiara, G., Dahlgren, P., Dee, D., Diamantakis, M., Dragani, R., Flemming, J., Forbes, R., Fuentes, M., Geer, A., Haimberger, L., Healy, S., Hogan, R.J., Hólm, E., Janisková, M., Keeley, S., Laloyaux, P., Lopez, P., Lupu, C., Radnoti, G., de Rosnay, P., Rozum, I., Vamborg, F., Villaume, S., Thépaut, J-N. (2017): Complete ERA5: Fifth generation of ECMWF atmospheric reanalyses of the global climate. Copernicus Climate Change Service (C3S) Data Store (CDS). (Accessed on DD-MM-YYYY)
> The results contain modified Copernicus Climate Change Service information 2022. Neither the European Commission nor ECMWF is responsible for any use that may be made of the Copernicus information or data it contains.

The question regarding which atmospheric variables one should include in the training of a data-driven ocean circulation model is still an open research one. As an example, at the moment of writing, some competitive models use just the air temperature at 2 metres and the wind velocity at 10 metres above the surface ([El Aouni et al., 2024](https://arxiv.org/abs/2412.05454)), or even just the winds ([Wang et al., 2024](https://arxiv.org/abs/2402.02995)). Another obvious starting point is using the variables used by numerical models, as [NEMO](https://www.nemo-ocean.eu/doc/node27.html) or [MITgcm](https://mitgcm.readthedocs.io/en/latest/phys_pkgs/exf.html#ssub-phys-pkg-exf-inputs-units), an approach closer to that followed by [Cui et al., 2025](https://doi.org/10.1038/s41467-025-57389-2).

The wind stress, the evaporation, and the latent and sensible heat fluxes can be computed using bulk formulae (for a discussion of their parametrization in NEMO see [Bonino et al., 2022](https://doi.org/10.5194/gmd-15-6873-2022)), starting from the air density and pressure. In turn, the former can be computed from temperature and specific humidity. In particular, we included the dew point temperature at 2 metres above the surface, but not the lowest level of the 3D specific humidity, following the [ECMWF guidelines for computing the surface (2m) specific humidity](https://confluence.ecmwf.int/display/CKB/ERA5%3A+data+documentation#heading-Guidelines). Also, precipitations, wind gusts and variables relevant for radiative transfers were included.

The temporal resolution of the ARCO-ERA5 dataset is 1 hour; therefore, it had to be resampled at a daily resolution. This means that all variables should be intended as averages over the time interval of 24 hours, including, for example, the instantaneous wind gusts.

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

Time invariants are taken from one of the publicly available datasets at this Google Cloud bucket: [gs://weatherbench2/datasets](https://console.cloud.google.com/storage/browser/weatherbench2/datasets) and part of WeatherBench2 [^5]

| Variable name | Description                                             | Data type | Units   |
|---------------|---------------------------------------------------------|-----------|---------|
| `z`           | Gravitational potential energy per unit mass at surface | float32   | m^2/s^2 |
| `lsm`         | Fraction of land in a grid cell                         | float32   | -       |

[^3]: Carver, Robert W, and Merose, Alex. (2023): ARCO-ERA5: An Analysis-Ready Cloud-Optimized Reanalysis Dataset.
22nd Conf. on AI for Env. Science, Denver, CO, Amer. Meteo. Soc, 4A.1, [https://ams.confex.com/ams/103ANNUAL/meetingapp.cgi/Paper/415842](https://ams.confex.com/ams/103ANNUAL/meetingapp.cgi/Paper/415842)

[^4]: Copernicus Climate Change Service, Climate Data Store, (2023): ERA5 hourly data on single levels from 1940 to present. Copernicus Climate Change Service (C3S) Climate Data Store (CDS). DOI: 10.24381/cds.adbb2d47 (Accessed on 10-Oct-2025)

[^5]: Rasp, S. et al. WeatherBench 2: A benchmark for the next generation of data-driven global weather models. Preprint at https://doi.org/10.48550/arXiv.2308.15560 (2024).

### Hydrological

Hydrological variables and their auxiliary data are derived from historical GloFAS data[^6] and downloaded from EWDS[^7], hence the dataset contains modified Copernicus Emergency Management Service information 2025. The European Commission is not responsible for any use that may be made of the Copernicus information or data it contains.

River runoff is required to compute the freshwater budget of the ocean, along with the evaporation, sea ice, and precipitation. For this reason, ARCO-OCEAN contains the discharge of global rivers (including sediments, chemical and biological material) in the last 24 hours, taken from GloFAS. This value, although not assimilated, is computed by forcing a hydrological model with an atmospheric reanalysis (ERA5). Whether a machine learning model could make use of this information and, for example, remove the contribution of sediments to the volumetric flow rate is still an open research question.

| Variable name | Description                    | Data type | Units | Assimilated |
|---------------|--------------------------------|-----------|-------|-------------|
| `dis24`       | Mean discharge in the last 24h | float32   | m^3/s | No          |

| Variable name | Description                       | Data type   | Units |
|---------------|-----------------------------------|-------------|-------|
| `uparea`      | Upstream area of each river pixel | float32     | m^2   |
| `glofas_mask` | GloFAS land/sea mask              | int8 (bool) | -     |

[^6]: Grimaldi, S., Salamon, P., Disperati, J., Zsoter, E., Russo, C., Ramos, A., Carton De Wiart, C., Barnard, C., Hansford, E., Gomes, G., Prudhomme, C. (2022): River discharge and related historical data from the Global Flood Awareness System, v4.0. European Commission, Joint Research Centre (JRC). DOI: 10.24381/cds.a4fdd6b9 (Accessed on 10-Oct-2025)

[^7]: Joint Research Center, Copernicus Emergency Management Service (2019): River discharge and related historical data from the Global Flood Awareness System. Early Warning Data Store (EWDS). DOI: 10.24381/cds.a4fdd6b9 (Accessed on 10-Oct-2025)


### Notes on regridding, null values, and masking

One of the post-processing steps of the ARCO-OCEAN dataset is regridding, which requires special care. In particular, problems arising from dealing consistently with missing values (NaNs) and invalid points (e.g., land points) when regridding are peculiar of ocean data, as they have no analogue in weather datasets, and having control over them is crucial.

On the one hand, they contain important information (i.e., about the domain geometry), on the other, uncaught NaNs would propagate and lead to NaN pollution in most machine learning models. Indeed, accelerated tensor manipulation libraries used to implement these models can't usually skip NaNs in calculations as Numpy does.

In most applications, conservative regridding (i.e., preserving the integral of the source field between grids) is the go-to choice for continuous scalar fields. Notice that WeatherBench datasets use first order conservative regridding also for vector fields, and so has been done in ARCO-OCEAN. The regridding routine is implemented using the `xarray-regrid` Python package ([Schilperoort et al., 2025](https://doi.org/10.5281/zenodo.15176942)), which is based on the `conservative_normed` method provided by `xESMF` ([Zhuang et al., 2025](https://doi.org/10.5281/zenodo.15304267)) plus [minor modifications suggested by Stephan Hoyer](https://github.com/xarray-contrib/xarray-regrid/blob/eef312a2ee0fa5cae94814d72f17438f77ec9e5b/src/xarray_regrid/methods/conservative.py#L49-L54).

The `conservative_normed` algorithm relies on computing overlapping areas between cells of the source and destination grid, then normalizing the target grid values by the fraction of source grid cells actually containing a value. This allows handling missing values (NaNs) without adding excessive overhead. However, it can happen that the destination grid cell does not overlap with any valid source grid cell. These divisions by zero are usually not a problem, as in that case the target grid would contain a NaN anyway.

Nearest-neighbor interpolation is usually the right choice for categorical variables, as is the case for land/sea masking, where using other interpolation algorithms would imply the choice of some arbitrary threshold value. This, together with previous considerations on the `conservative_normed` algorithm imply that in general there will be land points in the target grid with assigned not-null values, which is not a problem as they can be masked out later. However, it also means that sea grid cells might contain null values.

The situation described relates to a single source dataset and a 2D mask. When working with multiple datasets, the situation is even more complex, as they might use a different definition of coastline, or exclude smaller islands, for example. For such reasons, the following approach was used in producing the ARCO-OCEAN dataset:

1. Each dataset includes his own land mask. In the case of ERA5, the associated variable is called `land_sea_mask` keeping the name used in the WeatherBench dataset. For all the other datasets, the mask is computed from auxiliary data and the variables is named `<name of the dataset>_mask`.
2. Masks related to atmospheric or hydrological variables use the convention of assigning `True` to land and `False` to sea, ocean and wave variables do the other way around.
3. The ERA5 `land_sea_mask` is taken as-is from the original dataset, just renamed to `lsm`. Technically, it is not a mask as its values vary continuously between 0 and 1. The other masks are computed from auxiliary data (which are also included in ARCO-OCEAN). In particular, the `glofas_mask` is true where the `uparea` variable is not null, the `waverys_mask` where the `deptho` variable (from the WAVERYS dataset) is not null. The `glorys_mask` derivation is more involved, and is the subject of the following paragraph.

For `glorys12_mask`, we avoid the problem of regridding the original mask, and compute a new mask from a given discretization of the vertical dimension and suitable bathymetry, which is a continuous field and can be eventually regridded. A cell is considered valid, hence a sea point, if half of its volume is filled with water, i.e., if the bathymetry at that point is below the cell center. The bathymetry has been taken from the `deptho` variable defined in GLORYS12, and has been regridded using a conservative algorithm to 0.25°. The depth coordinate has been subsampled to 10 levels, as described in the paragraph on ocean and sea ice variables.

The illustrated procedure does not solve the problem of valid cells containing missing values, though. To solve it, we used a filling routine averaging the values of surrounding cells. This is reminiscent of the approach followed by GraphCast ([Lam et al., 2023](https://doi.org/10.1126/science.adi2336)) to deal with random cases of NaNs in ERA5. To speed up the computation in Python, we computed such averages by means of Gauss blurring, corrected to take missing values into account in the same way as in the `conservative_normed` algorithm. The implementation makes use of `scipy.ndimage.gaussian_filter` (see [documentation](https://docs.scipy.org/doc/scipy/reference/generated/scipy.ndimage.gaussian_filter.html) for more details), with parameters `mode=mirror`, `radius=4` and `sigma=1.0`. This approach was used for the variables `so`, `thetao`, `vo`, `mlotst`, and `zos` in GLORYS12, and for `dis24` in GloFAS.

Finally, it is worth noting that in GLORYS12 sea ice variables are null on most of the domain, as they are represented using NaNs where the sea ice is absent. Henceforth, variables `usi`, `vsi`, `sithick`, and `siconc` are simply set to zero within `glorys_mask` and leaved to their original values elsewhere.

## Data format

The dataset uses Zarr format version 2. The dataset has four dimensions. The longitude and latitude dimensions are named `lon` and `lat`, respectively. The time dimension is named `time`, and finally the vertical dimension is named `level`. All dimensions but `level` have a corresponding coordinate variable, the latter has also an auxiliary coordinate named `depth`. The latitudes are in the range [-90, 90], and the longitudes are in the range [0, 360], following the [convention used by the ECMWF](https://confluence.ecmwf.int/display/CKB/ERA5%3A+What+is+the+spatial+reference#ERA5:Whatisthespatialreference-Coordinatesystem). The level coordinate corresponds to the original vertical levels in GLORYS12, and similarly for depth. The time coordinate uses the proleptic Gregorian calendar and unit "days since 2000-01-01 00:00:00" (UTC). Notice that when loaded with XArray, it will have nanosecond resolution, but only the date part is relevant as the dataset has daily resolution.

All variables use single precision floating point numbers, except masks which use one byte integer values. They use C order (row-major) storage, with time as the leading (slowest varying) dimension, followed by level (when present), then latitude, and finally longitude. The dataset is chunked along the time dimension, with a chunk size of 1 day. At a resolution of 0.25°, the latter corresponds to 4MB chunks in memory, and a disk footprint of ocean variables chunks ranging from 500KB to 2.8MB depending on the content of the chunk and compression ratio. Indeed, masked values, about 70% of the domain, are NaNs, sea ice variables are 0.0 or NaN on most of the domain. The total size of the dataset at this resolution is about 1.3TB.

The climatology is referred to the whole period of the time series, which is slightly shorter than the WMO definition of climatological normal (i.e. [30 years](https://community.wmo.int/en/activity-areas/climate-services/climate-products-and-initiatives/wmo-climatological-normals)), and does not coincide with a standard climatological normal (the closest would be 1990–2020). However, for practical purposes, it is a good approximation. The mean and standard deviation, which are rarely used in climate applications, can be used to compute the standard score of the input features in machine learning models. Some autoregressive forecasting models predict future states by means of increments or residual (as GraphCast). For such models it is useful to standardize the output features, which can have wildly different magnitudes and would otherwise make it harder to train the underlying neural networks. For this reason, the standard deviation of increments is provided.

The climatology is computed by converting the calendar from `gregorian_proleptic` to `365_day` with XArray beforehand, effectively dropping the 29th of February of leap years.  It has a `dayofyear` dimension containing the progressive number of days since the beginning of the year, in a non-leap year, and uses a chunk size of 1 along that dimension (all the others are unchunked). The other stats are computed using the full timeseries. The `<dataset_name>_diff_std` dataset is computed assuming the average increment is zero. This is reasonable, as the series of increments is a telescopic series and its average is equal to the difference between the last element and the first one over the number of elements, which converges to zero for a sufficiently long series.

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

Along with the main dataset, statistics computed with respect to the time dimension are also provided. These are the climatology, the mean, the standard deviation, and the standard deviation of the increments between consecutive time steps. These can be accessed using paths: `s3://ogs-arco-ocean/stats=<stats_name>/tres=<time_resolution>/res=<horizontal_resolution_in_deg>/levels=<number_of_vertical_levels>`, where `<stats_name>` is one of `climatology`, `mean`, `std`, or `diff_std`.

## Tutorials

1. [Computing the Oceanic El Nino Index (ONI) with Xarray and ARCO-OCEAN](tutorials/oni.ipynb)

## License

This dataset is released for use under the CC-BY license. Highlights and key features of the license are provided [here](https://creativecommons.org/licenses/by/4.0/). Full legal text is provided [here](https://creativecommons.org/licenses/by/4.0/legalcode).

## Suggested attribution

[//]: # (FIXME: Temporary. Come up with a better attribution)
```
Campanella, S., Salon S., Querin, S., Bortolussi, L., and Stock, J.: ARCO-OCEAN: A dataset of physical properties of the ocean, waves, and sea ice, with hydrological and atmospheric forcing, optimized for machine learning. https://doi.org/10.5281/zenodo.17751608
```
