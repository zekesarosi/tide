# San Francisco Bay tidal constants from SFBOFS

Offline pipeline for the on-device tide and current model of the core bay
(Golden Gate, Central Bay, Richardson Bay, the bar, the Bay Bridge and
Richmond), fitted to a year of NOAA's SFBOFS (FVCOM) nowcast. Public-domain
inputs only. The region, method and file format are fixed by
[docs/SFBAY.md](../../docs/SFBAY.md); the output is
`App/Resources/Bay/sfbay.tidemesh`.

| File | Role |
|---|---|
| `sfbaymesh.py` | Shared with the live residual job: mesh loading, the region cut, element→node averaging, OPeNDAP spans, meshID, `extract()` of one hour |
| `fetch.py` | Hourly nowcast fields from the NCEI archive, saved per region node |
| `analyze.py` | Least-squares fit against TideKit's basis, validation against NOAA |
| `pack.py` | Writes the `.tidemesh` and checks the round trip |
| `tidemesh.py` | Reader/verifier for `.tidemesh` files |

## Reproduce

Needs Python 3 with numpy and netCDF4, a Swift toolchain, and ~3 GB of
scratch space (keep `DATA` outside the repository).

```sh
python3 -m venv .venv && .venv/bin/pip install numpy netCDF4
DATA=/path/to/scratch/sfbay

# 0. One SFBOFS fields file for the mesh (any cycle; ~60 MB), e.g. from CO-OPS or NCEI
curl -o $DATA/mesh.nc https://www.ncei.noaa.gov/thredds/fileServer/model-sfbofs-files/2026/10/sfbofs.t03z.20261001.fields.n001.nc
.venv/bin/python scripts/sfbay/sfbaymesh.py $DATA/mesh.nc        # N, T, spans, meshID

# 1. A year of hourly fields (~8,700 OPeNDAP reads, ~2.5 h with 10 threads; reruns resume)
.venv/bin/python scripts/sfbay/fetch.py 2025-11-01 365 $DATA/year $DATA/mesh.nc 10

# 2. TideKit's own harmonic basis for the same hours
swift build --package-path TideKit --scratch-path build/spm-data --product tide-cli
build/spm-data/debug/tide-cli basis 2025-11-01T00:00:00Z 8760 3600 \
  M2,S2,N2,K2,K1,O1,P1,Q1,L2,NU2,MU2,2N2,T2,LAM2,J1,OO1,M1,M4,MS4,MN4,M6,MK3,2MK3,M3,S4,MSF,MF,MM,SA,SSA \
  $DATA/basis_year.csv

# 3. Fit and validate (NOAA harcon JSON in $DATA/truth, see below)
.venv/bin/python scripts/sfbay/analyze.py $DATA/year $DATA/basis_year.csv $DATA/mesh.nc $DATA/truth $DATA/out \
  --fit M2,S2,N2,K2,K1,O1,P1,Q1,MU2,L2,M4,MS4,MN4,M6,MK3,2MK3,MSF,MM,SA,SSA

# 4. Pack and verify
.venv/bin/python scripts/sfbay/pack.py $DATA/out/constants.npz $DATA/mesh.nc App/Resources/Bay/sfbay.tidemesh $DATA/basis_year.csv
.venv/bin/python scripts/sfbay/tidemesh.py App/Resources/Bay/sfbay.tidemesh $DATA/mesh.nc
```

Every name must
resolve in TideKit's `ConstituentCatalog.definition(named:)`; `tide-cli basis`
fails otherwise. Because the fit uses TideKit's basis, the constants are
(H cos G, H sin G) in exactly the convention `HarmonicPredictor`, the Tide Globe
and the Bay renderer use, node factors included.

NOAA reference data (`$DATA/truth`), from the CO-OPS metadata API:

* `wl_<id>.json`: `https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations/<id>/harcon.json?units=metric`
  for 9414290, 9414806, 9414863, 9414358, 9414750.
* `hc_<id>.json`: the same endpoint for the current stations in the box
  (`.../stations.json?type=currentpredictions` saved as `cp.json` lists them).

## Notes

* The region keeps every node in the box, including one that no kept triangle
  uses; the averaging uses every element of the full mesh that touches a kept
  node, so currents at the box edge are not biased by the cut.
* 43 wet nodes in enclosed marinas and basins (e.g. the SF Marina and some
  Embarcadero slips) have `zeta` identically zero in SFBOFS; their constants are zero.
* The NCEI archive has gaps (1–2 Nov 2025 and 27–28 Feb 2026, 94 hours);
  `fetch.py` reports and skips them and the fit tolerates them.

## Current file

`sfbay.tidemesh`: 2025-11-01 to 2026-10-31 (8,666 hourly nowcasts), K = 20,
N = 16,811 nodes, T = 32,059 triangles, 7.78 MB, meshID `0x265c52ee`.

The constituents are the 20 largest of 30 fitted (by mean square over the
region of water level and depth-mean current). SFBOFS's tides carry almost no
NU2, 2N2, J1, OO1 or T2 (amplitudes 5–30 % of NOAA's), presumably because its
open boundary is not forced with them, so fitting them adds nothing. SA, SSA
and MM are one year's seasonal and weather signal rather than tide (model SA is
about twice NOAA's long-term value); they are kept because they are large, and
the live residual corrects them.

Against NOAA's published constants (`analyze.py` output):

| | Year fit | July 2025 prototype (30 days, K2/P1/NU2 inferred) |
|---|---|---|
| Water level M2, 5 gauges: amplitude ratio / \|phase\| median | 1.05 / 1.2° | 1.06 / 1.2° |
| Water level S2, N2, K1, O1 | 1.03/0.6°, 0.96/1.6°, 1.02/1.8°, 1.06/0.5° | 1.05/2.0°, 1.16/6.4°, 1.01/2.1°, 1.05/0.8° |
| Currents M2, 23 stations × 2 bins | 0.99 / 3.6° (90th pct 12.5°) | 0.99 / 3.9° |
| Currents S2, N2, K1, O1 phase median | 5.8°, 8.7°, 3.1°, 4.7° | 11.3°, 14.5°, 3.9°, 5.6° |
| Currents K2 | 0.88 / 9.9° | 0.74 / 22.5° |
| Mean flood-axis current, median \|model − NOAA\| | 3.5 cm/s | 5.5 cm/s |

The worst currents are still around Yerba Buena Island and the Oakland
entrance (M2 10–26° late). Overtides (M4, M6, MS4) are weaker in the model
than at NOAA's few stations that report them. Residual RMS of the fit (the
part the live job supplies): water level 9 cm, depth-mean current 3–4 cm/s
median.

## Live layer (surge, wind, river flow)

`live_residual.py` turns NOAA's latest SFBOFS forecast into `sfbay.residual`
(docs/SFBAY.md): the model minus the tidemesh harmonic prediction, hourly at
every mesh node from cycle − 6 h to cycle + 48 h (55 frames: nowcast
n000–n006, forecast f001–f048; f000 repeats n006's hour and is skipped). It
picks the newest cycle whose 55 files are all listed in the CO-OPS THREDDS
catalog (else the previous one), reads only the core-bay index spans over
OPeNDAP, moves currents to nodes with `sfbaymesh`, checks the region's meshID
against the tidemesh and each file's valid time against the hourly grid, and
writes `sfbay.residual` plus `sfbay.residual.deflate` (raw deflate). Values are
rounded to 2⁻⁸ (~4 mm, ~4 mm/s) so the file deflates to ~4 MB.

```sh
.venv/bin/python scripts/sfbay/live_residual.py --out out     # ~45 s
```

`.github/workflows/sfbay-live.yml` runs it at 04:40, 10:40, 16:40 and 22:40 UTC
and uploads the result to the `sfbay-live` release. The app fetches it from
Info.plist `TideBayLiveURL` (set `TIDE_BAY_LIVE_URL` in Config/Secrets.xcconfig,
see the example file) via `BayLiveStore`, and shows the tide alone without it.
