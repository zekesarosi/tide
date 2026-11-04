# Architecture and forecasting method

## Pipeline

```
                ┌───────────────────────── ForecastService (parallel, failure-tolerant) ─────────────────────────┐
                │                                                                                                 │
 NOAA mdapi ──► harmonic constants ─► HarmonicPredictor ─► astronomical tide η(t) ──────────────┐                  │
 NOAA mdapi ──► datums, flood levels ─► datum conversion ──────────────────────────────────────┐│                  │
 NOAA data  ──► 6-min observations ─► hourly means ─► residual r(t) = obs − η ─┐               ││                  │
 Open-Meteo ──► pressure + wind (−33 d … +N d) ─────────────────────────────────┼► SurgeModel.fit ─► forecast ─┐   │
 NWS NWPS   ──► official total water level ─► datum alignment ─► official surge ─────────────────────► blend ─┤   │
 NWS alerts, NHC storms ─────────────────────────────────────────────────────────────────────────► context ──┤   │
                │                                                                       TotalWaterLevelForecaster │
                └─────────────────────────────────────────────────────────────────────────────────────────────────┘
                                         ▼
     WaterLevelForecast: curves (tide, observed, total ± 80 %), hourly surge with components,
     high/low events with flood-category probabilities, diagnostics, notes, source statuses
```

Every fetch is wrapped by `ForecastService.capture`, which turns a failure into a
`SourceStatus` instead of throwing. The forecast degrades in steps:

1. **Calibrated.** Regression and learned persistence, plus the official blend when available.
2. **Uncalibrated.** There are no observations, so the model is inverse barometer only, with wide uncertainty.
3. **Persistence-only.** There is no weather data, so the current anomaly is carried forward and decayed.

Only missing astronomical data (no harmonic constants, predictions or datum) is fatal.

## Astronomical tide

`HarmonicPredictor` implements the method NOAA uses:

```
h(t) = Z0 + Σ fᵢ Hᵢ cos(Vᵢ(t) + uᵢ − κᵢ)
```

The terms:
* H and κ (Greenwich phase) come from the CO-OPS `harcon.json`.
* V comes from the astronomical arguments: Meeus polynomials for s, h, p, N and p′, plus Schureman's T.
* f and u are Schureman's nodal corrections.
* Z0 is MSL above the requested datum, taken from `datums.json`.

Several details reproduce NOAA's predictions exactly. Each was found by fitting
NOAA's own output, and the regression tests now pin them:

* Node factors are evaluated once per **calendar year, at mid-year**.
* **M1** uses u = ξ − ν + Q, with the perigee term frozen at 1 January.
* **σ1** uses O1² modulation (≡ 2O1 − P1). **RP1**, **KP1** and **TK1** are
  ψ1, φ1 and π1 rather than literal compounds. **3KM5** = K2 + K1 + M2.
* Compound names are parsed generically (`2MS2K2` → 2M2 + S2 − 2K2) and
  disambiguated by NOAA's published speed. Names that omit repeated multipliers
  are handled, e.g. `2MS8` = 2M2 + 2S2 and `M2KS2` = M2 + 2K2 − 2S2.

Validation (fixtures in `Tests/TideKitTests/Fixtures`, hourly, one month each in 2026 and 2035):

| Station | RMS vs NOAA | Max |
|---|---|---|
| The Battery | 0.3 mm | 0.7 mm |
| Galveston | 0.3 mm | 0.7 mm |
| Seattle | 0.5–0.7 mm | 1.6 mm |
| Anchorage (120 constituents) | 0.7–1.0 mm | 2.5 mm |

High and low waters are found by bisection on the analytic derivative and match
NOAA's published times to within NOAA's 1-minute rounding.

## Storm surge model (`SurgeModel`)

Target: the hourly non-tidal residual `r(t) = observed − astronomical`.
Training uses the last 30 days. Forcing comes from Open-Meteo `past_days`
over the same window, so the training and forecast forcing have the same
biases. `cell_selection=sea` avoids land grid cells whose winds are too weak.

Regression, using ridge regularisation with λ chosen by blocked 4-fold time-series CV:

| Feature | Physics |
|---|---|
| ΔP̃ = P − 1013.25 hPa, 3 h exponential memory | Inverse barometer (theory −0.99 cm/hPa) |
| \|U\|u, \|U\|v with 3 h memory | Local wind set-up / set-down |
| \|U\|u, \|U\|v with 18 h memory | Shelf/basin-scale and Ekman response |
| η(t), η̇(t) | Tide–surge interaction, harmonic drift (large in shallow estuaries) |
| intercept | Mean sea-level anomaly vs. datum epoch (season, sea-level rise) |

Using both wind components means the model learns each coastline's orientation.
The diagnostics report the wind direction that raises water most. For example,
Boston and New York set up under NE–ENE winds, and Buffalo under SW winds along
Lake Erie's axis.

**Learned persistence.** The model's error is anchored on the mean of the last
`w` hours and decays as φᵏ. The pair (φ, w) is chosen to minimise forecast error
at 6–48 h leads on the training data. This works better than the lag-1 AR
estimate when the residual mixes slow anomalies (river flow, remote surge)
with tidal-band noise.

**Persistence blend.** The model is fitted on the first 70 % of the window and
hindcast on the last 30 %. The blend weight between "regression plus learned
persistence" and naive persistence is chosen to minimise pooled 12–48 h error.
Semi-enclosed basins (Puget Sound, Cook Inlet) end up leaning partly on persistence.

**Uncertainty.** σ at lead k combines:
* the empirical RMS error at that lead, monotone in lead;
* forcing-forecast error, which grows linearly to the size of the meteorological
  signal over 5 days.

The result is inflated ×2 when a tropical cyclone is within 1,000 km.

## Official guidance blend (NWPS)

NWPS publishes stage in each gauge's own datum, and there is no
machine-readable datum field. The offset is estimated as the **median of
(CO-OPS observed − NWPS observed)** over the last 3 days. It is accepted only
if the spread is small, since a pure datum shift is constant. The NWS forecast
is then:
* converted to surge;
* bias-corrected using the error between its issue time and now, decaying with φᵏ;
* given σ = max(4 cm, recent RMS) + 1 cm per 6 h.

The two forecasts are combined with inverse-variance weights. The combined
variance assumes the errors are correlated (ρ = 0.5) rather than independent,
so the band isn't overconfident.

## Flood risk

Flood thresholds come from CO-OPS `floodlevels.json`. NWS minor, moderate and
major are preferred, with NOS as the fallback. They are published relative to
station datum and converted to the display datum using `datums.json`. For each
high tide:

```
P(reach category) = 1 − Φ((threshold − total) / σ)
```

## Keeping the app and widgets in step

A forecast is computed once and then evaluated at whatever time a surface needs.
The tide itself is local math (harmonic constants → `HarmonicPredictor`); what
goes stale is the inputs: gauge readings every 6 minutes, the weather model about
hourly, the reference data (harmonic constants, datums, flood levels) almost never.

* **One rule for "now".** `Nowcast.level(at:)` (TideKit) is the water level at any
  time: the forecast, anchored to the latest gauge reading and easing back onto the
  forecast over about an hour. `WaterLevelForecast` (station screen) and
  `ForecastSnapshot` (favorites cards, widgets) both use it, so they agree whenever
  they show the same moment. The station screen runs on a minute-by-minute
  `TimelineView` and passes that time down (`\.forecastNow`); nothing uses the
  forecast's issue time as "now".
* **One freshness rule.** `RefreshPolicy` says how long a forecast stays current:
  6 minutes in the app and 20 in the widget for stations with live readings, an hour
  for stations without. Between refreshes nothing is recalculated.
* **One way to fetch, in the app.** `ForecastRepository` returns the cached forecast
  while it's current, shares one fetch between concurrent callers (station screen,
  favorites, morning summary), and puts every fresh forecast in the cache and the
  shared store.
* **One shared store.** Both processes publish through `ForecastPublisher`: a
  `ForecastSnapshot` per station in the App Group (12 h back to 48 h ahead on a
  30-minute grid), saved only if it's newer than what's there (coordinated across
  processes), then a Darwin notification. The app's favorites and an open station
  screen pick up the widget's newer data from that signal. Snapshots record the datum
  and blend setting; a reader refetches one built with other settings.
* **Shared download caches.** Both processes build their `ForecastService` with
  `AppGroup.makeService()`: a `DiskResponseCache` keeps responses valid for 15 minutes
  or more (reference data, tide-table predictions, the weather run, storms), and an
  `ObservationArchive` keeps the month of gauge readings the surge model trains on,
  so a refresh downloads only the readings since the last one (with a 2-hour overlap
  for late and revised readings). Requests are shaped to repeat: the weather request
  always covers the full 16-day model range, and DFO tide-table requests cover whole
  UTC days. Pull to refresh drops the short-lived entries and keeps the reference data.
* **Widget timelines.** Entries 15 minutes apart from one snapshot, covering up to
  12 hours, so the widget keeps moving if reloads are throttled. The next reload is
  when the snapshot stops being current. The widget fetches (48 h horizon, the app's
  datum and blend setting, 25 s timeout) when its snapshot isn't current or was built
  with other settings, or when the refresh button is pressed; it backs off for 30
  minutes after a failure.
* **Station list and settings.** The app writes the station catalog and the user's
  settings to the group, so the widget's station picker works offline.
* **Deep links.** Tapping a widget opens `tideforecast://station/<id>`.

## Networking and auth (`APIClient`)

* **Identity.** Every request carries `User-Agent: <App>/<version> (<contact>)`,
  which api.weather.gov requires. CO-OPS requests carry `application=<App>`.
* **Credentials.** Keys come from a `CredentialStore`: Keychain first, then build-time
  Info.plist defaults. They are attached per source as a header (UK Admiralty) or a
  query parameter (Open-Meteo), and are never written into URLs the caller builds.
* **Retries.** 429 and 5xx responses are retried with exponential backoff and jitter,
  honouring `Retry-After`. 401 and 403 are not retried.
* **Pacing.** Requests to the same host are spaced out for providers with published limits.
* **Caching and redaction.** Identical concurrent requests are coalesced, and a TTL cache
  is keyed on the redacted URL: in memory, and on disk in the App Group for entries
  valid 15 minutes or more (see above).

## Known limitations

* Statistical surge models can't predict tropical-cyclone surge. The app shows NHC
  context and widens the uncertainty band, but it does not run a hydrodynamic model.
  NOAA's STOFS, ETSS and P-Surge products are distributed as NetCDF/GRIB2. A small
  server-side extractor that serves station time series as JSON would be the way to
  add them.
* Thirty days of training data seldom include an extreme event, so responses to rare
  storms are extrapolated linearly. Official guidance, when blended, mitigates this.
* Wave set-up and run-up aren't modelled; total water level here means still water.
