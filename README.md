# Tide & Surge — advanced tide and storm-surge forecasting for iPhone

An iPhone app (SwiftUI, iOS 18+) that forecasts **total water level** at
coastal and Great Lakes gauges:

```
total water level = astronomical tide + storm surge (+ mean sea level anomaly)
```

It does this from off-the-shelf public data:
- **NOAA**: harmonic constants, datums, observations and flood thresholds.
- **NWS**: alerts and official coastal forecasts.
- **Open-Meteo**: weather forcing.
- **Fisheries and Oceans Canada** and the **UK Hydrographic Office**: international stations.

Highlights:

* **On-device harmonic tide engine.** It reproduces NOAA's official predictions to
  **≈0.3 mm RMS** (NOAA's own rounding) at New York, Galveston and Seattle,
  and **≈1 mm RMS** at Anchorage. Anchorage has an 11 m range and 120
  constituents, 80+ of them compound shallow-water tides.
* **Station-calibrated storm-surge model.** It is trained on the last 30
  days of observations at each gauge, using:
  * pressure (inverse barometer) and quadratic wind stress, with fast and slow memory;
  * tide–surge interaction terms;
  * learned persistence of the current anomaly.
* **Skill-weighted blending.** The model is blended with naive persistence and
  with the **official NWS coastal forecast** (NWPS). The NWS forecast's datum is
  aligned automatically, and each source's weight comes from its own recent accuracy.
* **Probabilistic output.** You get an 80 % band on the water level curve, and
  each high tide gets a probability of reaching the NWS minor, moderate and major
  flood thresholds.
* **Widgets.** Home-screen widgets in small, medium and large, and lock-screen
  widgets in rectangular, circular and inline styles. They show the water level
  now and its trend, the anomaly vs. the tide table, the next tides, flood risk,
  and a mini forecast chart with its uncertainty band. Pick the station with
  Edit Widget; your first favorite is the default. Tapping a widget opens that
  station.
* **San Francisco Bay.** Zoom the Map tab in on the bay and its stations
  become live tide markers: play or scrub a tidal day to watch high water
  travel from the Golden Gate into the South Bay and up through Carquinez
  Strait, with a propagation strip in the Timing sheet. Each of 17 NOAA stations gets its
  high- and low-water lag and range ratio against the San Francisco radar gauge
  (9414290), averaged over 59 days of on-device predictions with the spread,
  plus the observed lag from two weeks of gauge data. Bay station screens
  and `tideforecast://bay` fly the map there.
* **Tide Globe.** The whole ocean's astronomical tide on a 3D Earth, rendered
  in Metal. Every pixel sums eight constituents from the NASA GOT4.10c atlas
  (0.5°) under the real Sun and Moon, with real sidereal time for the stars. High water sweeps around
  the amphidromes. Isolate M2, S2, N2, K1 or O1 to see each one's cotidal
  lines, and tap the sea to read the tide there, with a link to the nearest
  gauge. Open it from the Map tab or `tideforecast://globe`.
* **Context.** NWS coastal flood and storm surge alerts are shown. When a tropical
  cyclone is within 1,000 km, uncertainty is inflated and a warning appears.
  Statistical surge models are unreliable in hurricanes, so the app defers to NHC.

Measured out-of-sample 24 h surge error, live data, 2 Nov 2026:

| Station | Model | Naive persistence |
|---|---|---|
| The Battery, NY | 5.9 cm | 10.1 cm |
| Boston, MA | 5.5 cm | 10.0 cm |
| Sewells Point, VA | 6.3 cm | 10.2 cm |
| Galveston, TX | 7.5 cm | 9.1 cm |
| Buffalo, NY (Lake Erie) | 4.6 cm | 8.4 cm |
| San Francisco, CA | 5.8 cm | 6.7 cm |
| Seattle, WA | 8.2 cm | 9.6 cm |
| Anchorage, AK | 16.1 cm | 19.2 cm |
| Point Atkinson, BC (DFO) | 5.7 cm | 10.0 cm |

## Repository layout

```
TideKit/                 Swift package: all forecasting logic (no UI), runs on iOS, macOS, Linux
  Sources/TideKit/
    Harmonics/           Astronomy, constituent catalog, harmonic predictor
    Surge/               Surge model, statistics, total-water-level forecaster
    Providers/           NOAA CO-OPS, NWS alerts, NWPS, NHC, Open-Meteo, DFO IWLS, UK Admiralty
    Networking/          API client (auth, retries, pacing, caching), credential stores
    Services/            ForecastService: parallel fetch + graceful degradation
    Globe/               Sun/Moon ephemeris, global ocean tide atlas reader
  Sources/tide-cli/      Command-line harness that runs the live pipeline
  Sources/tide-analyze/  Retrospective analysis of a past week (hindcasts, attribution)
  Tests/TideKitTests/    68 tests incl. validation against NOAA fixtures and JPL Horizons
App/                     SwiftUI iPhone app
Widgets/                 WidgetKit extension (home + lock screen), App Intents station picker
Shared/                  App Group helpers + Slack Water theme, compiled into both app and widget
scripts/pack_globe_data.py  Packs the GOT4.10c atlas and Natural Earth land into App/Resources/Globe
Config/                  xcconfig (identity, keys) — Secrets.xcconfig is git-ignored
project.yml              XcodeGen spec (generates TideForecast.xcodeproj)
docs/ARCHITECTURE.md     Data sources, auth, and the forecasting method in detail
docs/DESIGN.md           Slack Water design system (tokens, type, components)
```

## Getting started

Requirements: Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # set TIDE_CONTACT, bundle id, team
xcodegen generate
open TideForecast.xcodeproj
```

**Set `TIDE_CONTACT`.** It's an e-mail address for whoever operates the app.
The National Weather Service requires every api.weather.gov request to carry a
`User-Agent` that identifies the application and a contact, and may block
requests that don't. The app builds it as `TideForecast/<version> (<contact>)`.

Run the forecasting engine without Xcode (macOS or Linux):

```sh
cd TideKit
swift test
TIDE_CONTACT=you@example.com swift run tide-cli 8518750          # The Battery, NY
TIDE_CONTACT=you@example.com swift run tide-cli "Point Atkinson"  # DFO Canada
TIDE_CONTACT=you@example.com swift run tide-cli 9063020 IGLD 72   # Buffalo, Lake Erie

# Retrospective analysis: observed vs predicted, surge attribution, replayed forecasts
TIDE_CONTACT=you@example.com swift run tide-analyze 2026-10-26T07:00:00Z 2026-11-02T08:00:00Z sfbay.json 9414290 9414750
```

## Data sources and authentication

| Source | Used for | Auth |
|---|---|---|
| NOAA CO-OPS Data + Metadata API | Stations, harmonic constants, datums, flood thresholds, 6-min observations | None; `application=` param identifies the app |
| NWS api.weather.gov | Active alerts at the station | No key; identifying `User-Agent` with contact is **mandatory** |
| NWS NWPS (api.water.noaa.gov) | Official coastal total-water-level forecast | None |
| NHC CurrentStorms.json | Active tropical cyclones | None |
| Open-Meteo | Sea-level pressure + 10 m wind (past 33 days + forecast) | None for non-commercial use; commercial `apikey` (query) via `customer-api` host |
| DFO IWLS (Canada) | Stations, predictions, observations, forecasts | None (rate-limited; requests are paced) |
| UK Admiralty Tidal API | UK stations + 7-day tidal events | `Ocp-Apim-Subscription-Key` header (required) |

How keys are handled:

* Keys are entered in **Settings › API keys** and stored in the **iOS Keychain**
  (`AfterFirstUnlockThisDeviceOnly`, never synced).
* `Config/Secrets.xcconfig` can inject development defaults through Info.plist.
  These end up in the app binary, so don't ship paid keys that way. For production
  use of a paid API, put a small proxy in front of it.
* Credentials are attached in one place (`APIClient.authorize`). They are redacted
  from cache keys and error messages. Required keys fail fast with a clear message
  instead of making an anonymous request.
* The client retries 429/5xx with exponential backoff and honours `Retry-After`.
  401/403 responses are not retried and are reported as credential or User-Agent problems.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full method.

## Status and next steps

* TideKit is built and tested on Linux (Swift 6.2) and validated against the live APIs.
* The SwiftUI app was written without access to Xcode. CI
  (`.github/workflows/ci.yml`) builds it on a macOS runner; that is its
  first real compile check.
* Ideas: background refresh and flood-risk notifications, a home/lock-screen
  widget, a STOFS/ETSS surge model feed through a small server-side proxy
  (those products are NetCDF/GRIB only), and wave set-up from NWS gridpoint wave
  forecasts.

*Not for navigation. Forecasts are guidance; always follow official warnings.*
