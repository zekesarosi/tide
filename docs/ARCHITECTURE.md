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

## Widgets

The app and the widget extension share an App Group (`group.<bundle id>`) and
a Keychain access group (`<team>.<bundle id>.shared`):

* **App side.** After every forecast load, the app saves a `ForecastSnapshot` to
  the group container and reloads widget timelines. The snapshot is a compact copy
  of the forecast: 12 h back to 48 h ahead on a 30-minute grid, with σ, the
  predicted tide, the latest observation, events with flood probabilities, the
  thresholds and alert titles.
* **Station list and settings.** The app also writes the station catalog and the
  user's settings (units, datum, favorites) to the group, so the widget's station
  picker (an App Intents `EntityStringQuery`) works offline.
* **Widget timelines.** The `AppIntentTimelineProvider` makes entries
  15 minutes apart from one snapshot, so the "now" marker, level and trend move
  without network access.
* **When the widget fetches.** If the snapshot is older than 45 minutes, in a
  different datum, or the user pressed the widget's refresh button (an interactive
  App Intent), the widget runs TideKit's normal `ForecastService` pipeline itself,
  with a 48 h horizon and a 25 s timeout (cancellation reaches in-flight requests).
  It falls back to the saved snapshot on failure, backs off for 45 minutes before
  fetching again, and asks for a new timeline after 30 minutes (60 after a failure).
  Entries cover up to 12 hours, so the widget keeps moving if reloads are throttled.
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
  is keyed on the redacted URL.

## Known limitations

* Statistical surge models can't predict tropical-cyclone surge. The app shows NHC
  context and widens the uncertainty band, but it does not run a hydrodynamic model.
  NOAA's STOFS, ETSS and P-Surge products are distributed as NetCDF/GRIB2. A small
  server-side extractor that serves station time series as JSON would be the way to
  add them.
* Thirty days of training data seldom include an extreme event, so responses to rare
  storms are extrapolated linearly. Official guidance, when blended, mitigates this.
* Wave set-up and run-up aren't modelled; total water level here means still water.
