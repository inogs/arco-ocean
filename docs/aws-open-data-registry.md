# The AWS Open Data Registry entry for the new version (draft)

Roadmap item 8. A draft of `datasets/ogs-arco-ocean.yaml` in
[awslabs/open-data-registry](https://github.com/awslabs/open-data-registry), to revise before the
pull request there. That pull request goes after the new version is published: the entry
describes the bucket's content, so it must not announce paths that are not there yet.

## What changes from the current entry

The current entry (read on 23 Nov 2026) describes the first version:
- 0.25° only, 10 levels, waves, 1993-01-01 to 2021-06-30, Zarr version 2;
- citation without a DOI;
- one tutorial, a Jupyter notebook.

The new version changes:
- **Products and paths.** There is one Icechunk repository per product and resolution:
  - `historical/res=<res>`: the historical dataset;
  - `statistics/res=<res>`: its climatology and anomaly standard deviation, as two groups;
  - `forecast/res=<res>`: daily forecast runs.

  Resolutions are `0p25`, `0p5` and `1p0`.
- **Content.**
  - 49 levels, no waves.
  - 1993-01-01 to 2026-06-30.
  - Statistics over 1993-2023.
  - Forecasts: daily runs, 10 lead days, the last five years of runs.
- **Format.** Icechunk (Zarr version 3, with versions). Reading needs the `icechunk` package; the
  plain Zarr path no longer works.
- **Update frequency.** The forecasts change every day. The historical dataset and its statistics
  are fixed.
- **Citation.** The new version's DOI, 10.5281/zenodo.24471954.
- **Licence.** CC BY 4.0 as before, but the sources' credits must go with the data (the dataset's
  `attribution` attribute).
- **Tutorial.** It is now a marimo notebook. The registry's `NotebookURL` must end in `.ipynb`, so
  the tutorial is given by `URL` only.

## Proposed entry

```yaml
Name: ARCO-OCEAN
Description: |
  ARCO-OCEAN is an analysis-ready cloud-optimized dataset of the physical properties of the
  ocean and sea ice, with the atmospheric and hydrological forcing that would drive a numerical
  simulation, designed for training machine learning models. Three products are given on
  regular latitude-longitude grids at 0.25, 0.5 and 1 degree, on 49 depth levels:
  the historical dataset, daily from 1 January 1993 to 30 June 2026, merged from retrospective
  analyses (GLORYS12 for the ocean and sea ice, ERA5 for the atmosphere, GloFAS for river
  discharge); its statistics (a daily climatology and the standard deviation of the anomalies
  over 1993-2023); and daily forecast runs on the same grids and variables (GLO12, ECMWF IFS
  open data and the GloFAS forecast; 10 lead days, the last five years of runs), updated every
  day. Each product is an Icechunk repository (Zarr version 3 with versions) per resolution:
  historical/res=<res>, statistics/res=<res> and forecast/res=<res>, res one of 0p25, 0p5, 1p0.
  Cells are conservatively averaged from the native grids, with the sea fraction, cell areas and
  volumes needed to weigh them. The first version (0.25 degree, 10 levels, with waves, to June
  2021, Zarr version 2) stays in the bucket until the new one replaces it.
Documentation: "[ARCO-OCEAN](https://github.com/inogs/arco-ocean)"
Contact: scampanella@ogs.it
ManagedBy: "[OGS](https://www.ogs.it/en/dynamics-ecosystems-and-computational-oceanography)"
UpdateFrequency: Daily for the forecasts; the historical dataset and its statistics are fixed.
Tags:
  - aws-pds
  - analysis ready data
  - atmosphere
  - climate
  - forecast
  - global
  - hydrology
  - ice
  - machine learning
  - oceans
  - physics
  - weather
  - zarr
License: "[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); the sources' credits (each repository's `attribution` attribute) must accompany the data."
Citation: "Campanella, S., Salon, S., Querin, S., Bortolussi, L., and Stock, J.: ARCO-OCEAN: A dataset of physical properties of the ocean and sea ice, with hydrological and atmospheric forcing, optimized for machine learning, https://doi.org/10.5281/zenodo.24471954, accessed on DD-MM-YYYY."
Resources:
  - Description: Icechunk repositories (Zarr version 3) of the historical dataset, its statistics and the forecasts, at three resolutions
    ARN: arn:aws:s3:::ogs-arco-ocean
    Region: eu-south-1
    Type: S3 Bucket
  - Description: Notifications for new ARCO-OCEAN data
    ARN: arn:aws:sns:eu-south-1:985149164500:ogs-arco-ocean-object_created
    Region: eu-south-1
    Type: SNS Topic
DataAtWork:
  Tutorials:
    - Title: Computing the Oceanic El Nino Index (ONI) with Xarray and ARCO-OCEAN
      URL: https://github.com/inogs/arco-ocean/blob/main/tutorials/oni.py
      AuthorName: OGS
      AuthorURL: https://github.com/inogs/
  Tools & Applications:
    - Title: arco-make, the tool that produces ARCO-OCEAN from its sources (recipes in the ARCO-OCEAN repository)
      URL: https://github.com/stefanocampanella/arco-make
      AuthorName: Stefano Campanella
      AuthorURL: https://github.com/stefanocampanella
ADXCategories:
  - Environmental Data
RegistryEntryAdded: "YYYY-MM-DD"  # the date of the current entry, kept
RegistryEntryLastModified: "YYYY-MM-DD"  # the date of the pull request
```

## Checked against the registry (23 Nov 2026)

- The fields and their types follow the registry's `schema.yaml`. `RegistryEntryAdded` and
  `RegistryEntryLastModified` are required there, but the current entry has neither: keep
  `RegistryEntryAdded` as the registry records it.
- Every tag is in the registry's `tags.yaml`, which has `forecast`, `global` and `weather`; it has
  no `reanalysis` or `icechunk` tag.
- `Explore` (links to browse the data) is optional. The Earthmover marketplace listing could go
  there once it exists (roadmap item 10).

## Open points

1. **The old paths.** The first version (`datasets/res=0p25`, `climatology/`, `anomaly_std/`)
   stays until replaced. Should the entry list it, with a deprecation date, or leave it out?
2. **The SNS topic.** It notifies every new object. With daily forecasts, that means a burst of
   objects every day: keep it, or describe it as forecast updates?
3. **The tutorial** still reads the first version. Update it to the new paths before the entry
   points to it.
4. **The suggested citation** drops "waves" here. The README's citation, marked FIXME, still has
   it (arco-ocean #17).
5. **The managing institution and the contact** are unchanged: confirm.
