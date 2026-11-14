# Sailing and boating navigation: feature inventory, MVP and architecture

This document scopes the work to turn Tide & Surge into a sailing and boating navigation app.
It covers what to build, in what order, and where the code goes. Data sources are named but
not described here: for coverage, licensing, formats and costs, see
[DATA_SOURCES.md](DATA_SOURCES.md). The visual design work lives in `design/`.

**Our position.** The rest of the market treats tides and currents as a side table. We would
start from the strongest part of this codebase: a NOAA-grade harmonic engine (≈0.3 mm RMS),
a calibrated surge model, current predictions that match NOAA's to its own rounding (new, see
[Status](#status)), and an offline-first, cached data layer. The pitch: *the app that knows
what the water is doing*. That means routes and departure times that respect tidal gates,
anchor alarms that know the tide, and clearance under keels and bridges from total water
level rather than the tide table alone.

Sizes: **S** ≤ 1 engineer-week · **M** 1–3 weeks · **L** 1–2 months · **XL** a quarter or more.
Phases: **MVP** (first public sailing release) · **v1** (about 6 months after) · **v2+**.

---

## 1. Competitive benchmark

| App | What it does best | Where users complain |
|---|---|---|
| **Navionics** (Garmin) | The best-known chart coverage worldwide. SonarChart crowd-sourced bathymetry gives detailed contours in small harbours. Auto Guidance+ is easy, and the chart look is familiar. | Subscriptions and renewals: offline charts stop updating, and features go away, when one lapses. Auto Guidance has drawn routes through shallows and over land, and pushes all the checking back to the user. Instrument (NMEA) support is thin. Few sail-specific tools. |
| **Aqua Map** | Good value. Uses official US NOAA ENC and raster charts, and adds other regions as purchases. Integrates ActiveCaptain and Waterway Guide, plus USACE surveys on the ICW. Takes NMEA and AIS over WiFi. Popular with US cruisers and on the ICW. | A dated, dense UI. A steep learning curve. Some users see instability on large chart sets. Weather is basic. |
| **Orca** | A modern, polished UI and fast vector charts. The Orca Core hardware puts NMEA 2000 instruments onto the tablet. Smart routing accounts for weather and the boat. | The best features need their hardware. Regional coverage and chart detail can be thinner. Subscription pricing is another complaint. |
| **PredictWind** | The leader in weather routing: several models (including its own PWG/PWE), polars, departure planning across days, and comfort/safety limits. Works offshore through Iridium GO! and Starlink, and reads GRIBs offline. Strong tracking and blog features for passage-makers. | Price. A complex UI. Charting is secondary. Coastal and tidal detail is limited, so routes near shore and through tidal gates are generic. |
| **iNavX** | A veteran, instrument-friendly app: NMEA 0183 over TCP/UDP, AIS, and several chart vendors. Trusted by long-time cruisers. | The UI is dated and hasn't kept up with iOS. Charts are bought from several vendors. Stability on newer devices has been uneven. |
| **OpenCPN** | Free and open source. S-57/S-63/oeSENC charts. A rich plugin ecosystem (weather routing with polars, GRIB, AIS, dashboard, tactics) and deep configurability. The reference for what "complete" means. | The learning curve and the UI. Mostly desktop: mobile is Android-first and not native iOS. The setup burden (charts, plugins) falls on the user. |
| **Savvy Navvy** | "Google Maps for boats". Very simple auto-routing that takes tide, weather and draught into account, with clear departure-time suggestions. Quick for beginners. | Routing is simplified and opaque, so experienced sailors don't trust it. Few instrument and racing tools. Subscription-only. Charts are less detailed than official ENCs in places. |
| **SEAiq** | Professional pilot grade: official S-57/S-63 ENCs, pilot plugs, AIS, and route exchange (RTZ). Used by harbour pilots, which is strong evidence of reliability. | A utilitarian UI. The pro tiers are expensive. Little help with weather, routing or leisure use. |

**Gaps we can own.**
1. **Tidal intelligence everywhere.** Current gates, course-to-steer and slack windows built
   into planning. No competitor matches NOAA's own predictions to its rounding or uses
   surge-adjusted water levels for under-keel and air-draft clearance.
2. **Trustworthy automation.** An auto-route that shows its constraints and the safety
   margins it applied, and refuses rather than guessing, avoids Navionics's failure mode.
3. **Instruments without hardware lock-in.** NMEA 0183 and SignalK over WiFi work with
   whatever gateway the boat already has.
4. **A modern native iOS app** with real Watch, widget and Live Activity support, where the
   veteran apps are weakest.

---

## 2. Feature inventory

Each table row: **description · user value · size · dependencies · TideKit reuse · phase**.

### 2.1 Charts and offline

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| Base nautical chart | Official ENC-derived vector charts (US NOAA ENC first), shown in a familiar paper-chart style with depth shading and safety contour. | The one thing a nav app must have. | XL | NOAA ENC / S-57 sources; a vector-tile pipeline (server); a map renderer in the app | `Networking` (cache, pacing), `DiskResponseCache` | MVP |
| Offline chart packages | Region packs downloaded ahead of time, with versions, expiry and delta updates. Works with no signal. | Coverage offshore and in remote anchorages. | L | Package server; DATA_SOURCES §5 strategy | `DiskResponseCache`, `RefreshPolicy`, App Group storage | MVP |
| Safety-contour shading | Water shallower than a user's safety depth is shaded. The safety depth comes from the boat profile (draught + margin) and can follow live tide. | Instantly see where you can't go. | M | Charts; boat profile | `HarmonicPredictor`, `Nowcast` (tide-aware depth) | MVP |
| Tide-aware depths | Charted depth + predicted (or forecast total) water level at a time: now, at ETA, or scrubbed. | Answers "can I get over the bar at 15:00?" | M | Charts; tide stations | `HarmonicPredictor`, `TotalWaterLevelForecaster`, `Bay/TideMesh` | v1 |
| Raster charts (BSB/KAP, RNC) | Paper-chart look where vector data is poor; user-imported MBTiles/GeoTIFF. | Familiarity; obscure regions. | M | Import pipeline | — | v1 |
| International charts | Other hydrographic offices' ENCs (S-63 encryption, licensing) and commercial vendors. | Worldwide use. | XL | Licensing deals (see DATA_SOURCES §6) | — | v2+ |
| Crowd-sourced bathymetry | Logged depth + GPS from users' sounders, tide-corrected and gridded. | Detail in small harbours (Navionics SonarChart's niche). | XL | NMEA depth; server pipeline; opt-in | `HarmonicPredictor` (tide reduction to datum), `NMEA` | v2+ |
| Satellite / aerial overlay | Imagery blended over the chart for anchorage scouting. | Seeing reefs, beaches, moorings. | S | Imagery source | — | v1 |
| Chart object query | Tap a buoy, light or wreck for its attributes (characteristics, depth, sector). | Identifying lights at night. | M | ENC attributes | — | MVP |

### 2.2 Own ship and sensors

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| Phone GPS own-ship | Position, COG/SOG, heading from the compass, predictor vector, track trail. | Works on any phone. | S | Core Location | `Navigation` (geodesy) | MVP |
| Magnetic variation | WMM declination for any place and date; true↔magnetic everywhere a bearing is shown. | Correct compass courses. | S | WMM coefficients (embedded) | **`Navigation/MagneticModel` (built)** | MVP |
| NMEA 0183 over WiFi (TCP/UDP) | Connect to an existing gateway or multiplexer. Parse GPS, heading, wind, depth, speed, temperature and AIS. | Use the boat's own instruments and AIS receiver. | M | Network framework in the app | **`NMEA` (built)** | MVP |
| SignalK client | WebSocket delta stream from a SignalK server (often a Raspberry Pi), including NMEA 2000 data. | The open path to NMEA 2000 without proprietary hardware. | M | SignalK server on the boat | `NMEA` value types; `Navigation` | v1 |
| NMEA 2000 via gateways | Through SignalK or a gateway's 0183 conversion. A direct PGN decoder (via YDWG-02/Actisense-style gateways) comes later. | Modern instrument networks. | L | Gateways | `NMEA` | v2+ |
| Source arbitration and sensor fusion | Pick the best source per datum (external GPS over phone), detect stale data, damp noisy wind and heading. | Stable displays; graceful fallback. | M | NMEA, Core Location | `Statistics` (smoothing) | v1 |
| True wind and current from instruments | TWS/TWA/TWD from apparent wind, boat speed and heading; set and drift from STW/heading vs COG/SOG. | Core sailing numbers without a performance processor. | S | NMEA wind, log, heading | **`CurrentTriangle.setAndDrift` (built)** | MVP |
| Instrument dashboard | Configurable tiles: SOG, COG, depth, wind, VMG, XTE, ETA. Large type for the cockpit. | Replaces a chart-plotter repeater. | M | NMEA | `Navigation` | MVP |
| Depth alarm and logging | Shallow alarm with hysteresis; log depth against tide-corrected datum. | Safety; future crowd bathymetry. | S | NMEA depth | `HarmonicPredictor` | v1 |

### 2.3 Routing and passage planning

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| Manual routes | Tap waypoints; rhumb-line or great-circle legs; distances, bearings (T/M), leg times, ETA at a planned speed. GPX import/export. | Basic planning everyone needs. | M | Charts | **`Navigation` (`Route`, `RhumbLine`, `GreatCircle`, `Geodesy`) (built)** | MVP |
| Active navigation | Go-to waypoint and follow route: XTE, BTW/DTW, VMG to waypoint, ETA, arrival circle, auto-advance. Outputs RMB/XTE to an autopilot over NMEA. | On-the-water guidance; autopilot steering. | M | Own-ship; NMEA out | **`Route.progress`, `Passage` (built)**; `NMEA` (sentence builder) | MVP |
| Route hazard check | Flag legs crossing land, depth below the safety contour (tide-aware), or restricted areas. | Prevents the classic "route over a reef". | L | Charts (depth areas, land); safety depth | `Navigation`, `HarmonicPredictor` | v1 |
| Auto-routing over bathymetry | A grid/graph search (A* on a navigability mesh from ENC depth areas and land). It respects draught + margin, tide at ETA and keep-out areas, and explains its constraints. | Fast planning for coastal hops (Savvy Navvy's appeal), done in a way that can be trusted. | XL | Charts → navigability graph (server-built per region); boat profile | `Navigation`, `Currents`, `HarmonicPredictor` | v2+ |
| Departure planner (tidal) | For a route, sweep departure times. Score them by time, foul current, slack at gates and daylight. Show a departure heat strip. | "When should I leave?" answered with the tide. | M | Current stations; route | **`Currents/TidalGatePlanner` (built)** | MVP |
| Weather routing with polars | Isochrone routing over GRIB wind (later waves and currents) with the boat's polar. Comfort limits (max TWS, max wave, avoid upwind), motoring threshold, multi-model comparison. | Offshore passage planning (PredictWind's core). | XL | GRIB viewer; polars; currents; land mask | `Navigation`, `Currents`, Performance module | v2+ |
| Route sharing | Share a route or passage plan as a link or file; RTZ and GPX. | Crew briefings, buddy boats. | S | — | `Route` (Codable) | v1 |

### 2.4 Tidal-current gates

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| Current station predictions | Max flood, max ebb and slack times; velocity curves; set and drift for harmonic current stations. | Tidal stream tables, done right. | S | NOAA current harmonic constants | **`Currents/TidalCurrentPredictor` (built)**; `HarmonicPredictor`, `ConstituentCatalog` | MVP |
| Subordinate current stations | NOAA offset stations (time and speed ratios applied to a reference). | Most US current stations are subordinates. | S | NOAA offset metadata | `TidalCurrentPredictor`; pattern from `Bay/TidalOffsets` | MVP |
| Current arrows on the chart | Animated set/drift arrows at stations, plus the SF Bay mesh field; time scrubber shared with tides. | See the stream at a glance. | M | Map layer | `TidalCurrentPredictor`, `Bay/TideMesh.current` | MVP |
| Gate windows | Named gates (The Race, Hell Gate, Golden Gate, Deception Pass…) with the safe/slack windows for today and tomorrow, and a Live Activity countdown. | The one-glance answer cruisers ask for. | S | Gate catalog (curated) | **`TidalGatePlanner` gates (`maximumStream`, `minimumFairCurrent`, `window`) (built)** | MVP |
| Course-to-steer with current | Heading to steer to hold a leg's track with the predicted stream (and leeway). Shown live and in the plan. | Fewer miles, no set onto hazards. | S | Currents; route | **`CurrentTriangle.courseToSteer` (built)** | MVP |
| Wind-against-tide warning | Flag gates and legs where forecast wind opposes a strong stream (steep, dangerous seas). | A real safety call few apps make. | S | Wind forecast; currents | `OpenMeteo` provider; `TidalCurrentPredictor` | v1 |
| Model current fields | Gridded current from ocean or estuary models (e.g. NOAA OFS) for routing between stations. | Realistic currents along the whole route. | L | Model data (see DATA_SOURCES) | `CurrentField` protocol (built) | v2+ |

### 2.5 AIS and collision avoidance

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| AIS decoding | AIVDM/AIVDO with multi-part reassembly. Message types 1–5, 18, 19, 21, 24. | See other ships from the boat's receiver. | M | NMEA/WiFi source | **`AIS/AISMessage`, `AISDecoder` (built)** | MVP |
| Target table and display | Targets with name, type, size, nav status and a COG/SOG vector; stale/lost states; expiry. | Situational awareness. | M | AIS decoding; map layer | **`AISTargetTable` (built)** | MVP |
| CPA/TCPA and alarms | Closest point of approach and time to it for every target. Dangerous-target alarm with configurable thresholds and dead reckoning of stale reports. | Collision avoidance in fog and at night. | S | AIS, own-ship | **`CollisionAvoidance` (built)** | MVP |
| AIS-SART / MOB beacons | Detect 970/972/974 MMSIs, alarm, and show bearing and range. | Life-saving. | S | AIS | **`AISMessage.isEmergencyDevice` (built)** | MVP |
| Internet AIS | Server-fed AIS where there's no receiver (coverage view only, clearly labelled latency). | Planning; shore-side watch. | M | Commercial AIS feed (cost) | `Networking`, `AISTargetTable` | v2+ |
| Guard zones and COLREG hints | Sector/radius guard zone; give-way/stand-on hint from relative geometry (advisory only). | Less mental load. | M | AIS | `CollisionAvoidance` | v2+ |

### 2.6 Anchoring

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| Anchor alarm | Mark the drop point (offset from the antenna to the bow), set a radius, and watch. Drag alarm with GPS-noise filtering (median, spike rejection, dwell), creep warning, GPS-lost alarm. | Sleep at anchor. The most-requested cruiser feature. | M | Background location; notifications | **`Anchoring/AnchorWatch` (built)** | MVP |
| Tide-aware swing circle | Swing radius from rode, bow height and depth through the tide. Minimum scope at high water; under-keel clearance at low water; advisories. | Choose rode length and spot correctly. | S | Charted depth; tide station | **`Anchoring/SwingModel`, `AnchorPlan` (built)**; `HarmonicPredictor` | MVP |
| Catenary model | All-chain reach under wind load; warns when the chain lifts the anchor. | Understanding holding in a blow. | S | Wind forecast (optional) | **`SwingModel.catenaryReach` (built)** | v1 |
| Anchor position from swing | Fit a circle to the swing track to locate the anchor when it wasn't marked. | Correct a misplaced mark. | S | Track | **`AnchorWatch.estimateAnchor` (built)** | v1 |
| Remote anchor watch | Watch from shore or a second phone (iCloud/CloudKit relay or push). | Peace of mind ashore. | M | Backend relay | `AnchorWatch` status | v1 |
| Anchorage finder | Suggests shelter from forecast wind direction, using depth, bottom type and POIs. | Better nights. | L | Charts; wind forecast; POIs | `OpenMeteo` | v2+ |

### 2.7 Man overboard (MOB)

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| One-tap MOB | A large, always-reachable button (app, Watch, Action button, Lock Screen control). Marks the position, starts the elapsed-time clock and shows bearing/range back. | Seconds matter. | S | Own-ship | `Navigation` (bearing/range) | MVP |
| Drift-corrected MOB | Moves the datum with the predicted current, since a person in the water drifts with the stream. | Search where they are, not where they were. | S | Currents | `TidalCurrentPredictor`, `CurrentTriangle` | v1 |
| AIS MOB beacon tracking | Auto-trigger MOB on a 972 MMSI; navigate to the live beacon. | Hands-free. | S | AIS | `AISTargetTable` | MVP |
| DSC/VHF helper | Shows position formatted for a voice Mayday, and checklists. | Clear head in an emergency. | S | — | `Navigation` formatting | MVP |

### 2.8 Logbook and tracks

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| Track recording | Battery-aware background track with Douglas-Peucker simplification; GPX export. | Memory and evidence. | M | Background location | `Navigation` | MVP |
| Automatic logbook | Auto entries at departure and arrival, hourly position, and events (anchor, MOB, alarms) with wind, pressure, tide and current context. | Required on many passages; nice record. | M | Track; NMEA | `Briefing`, `OpenMeteo`, `HarmonicPredictor` | v1 |
| Trip statistics | Distance, moving time, max/avg SOG, time sailing vs motoring, tidal assist gained. | Insight; bragging. | S | Track | `Statistics` | v1 |
| Sharing and tracking page | A live or after-the-fact public track page. | Friends and family ashore. | M | Backend | — | v2+ |

### 2.9 Weather

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| Point marine forecast | Wind (gusts), waves, pressure, visibility for the boat, the route and anchorages. | Go/no-go. | S | Open-Meteo (already integrated), marine wave models | `OpenMeteo` provider, `ForecastService` | MVP |
| NWS marine zones and alerts | Coastal/offshore zone forecasts and Small Craft Advisory / Gale / Storm warnings. | The official word. | S | NWS API (already integrated for alerts) | `NWS` provider | MVP |
| GRIB viewer | Download GRIB2 subsets (wind, pressure, waves, precipitation, currents); animated barbs/particles; offline; point meteogram. | The offshore standard; works over sat links. | L | GRIB sources; GRIB2 decoder | `Networking`, `DiskResponseCache` | v1 |
| Multi-model comparison | Overlay or compare model runs along the route. | Gauge confidence. | M | GRIB | GRIB module | v2+ |
| Barometer trend | Phone barometer or NMEA pressure, with a falling-pressure alarm. | Classic storm warning. | S | Sensors | `Statistics` | v1 |
| Storm surge and water level | Existing total-water-level forecast at gauges, now used for clearance and depths. | Unique to us. | S | — | `TotalWaterLevelForecaster` | MVP |

### 2.10 Sail-specific tools

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| Polars | Import (ORC, CSV/POL, OpenCPN, Expedition formats) or pick a generic polar; bilinear interpolation; learn polars from logged data later. | Foundation for VMG, laylines and routing. | M | — | `Statistics` | v1 |
| VMG and target speeds | Upwind/downwind VMG, target boat speed and TWA, % of polar. | Sail faster. | S | Polars; true wind | `Passage.velocityMadeGood` (built) | v1 |
| Laylines | Tack and gybe laylines to the mark from TWD, target angles and current (set-corrected). | Fewer overstands. | M | Polars; wind; currents | `CurrentTriangle`, `Navigation` | v1 |
| Tack/gybe heading | Heading after the tack, current-corrected. | Quick tactics. | S | Wind; currents | `CurrentTriangle` | v1 |
| Start-line tools | Ping the ends; distance to line; time to line at current speed; time to burn; line bias vs wind; favoured end; countdown timer synced to the gun. | Racing starts. | M | Own-ship; wind | `GreatCircle.crossTrackDistance` (distance to line), `Navigation` | v2+ |
| Race courses and marks | Mark library, course setup, rounding alarms. | Club racing. | M | — | `Route` | v2+ |

### 2.11 POIs and community data

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| Marinas, anchorages, fuel, ramps | Searchable POIs with contacts, depth, amenities. | Trip planning. | M | POI sources (see DATA_SOURCES §4.7) | `Networking` | MVP (open data) |
| Community reviews and hazards | User reviews and local-knowledge hazard pins, with moderation. | Local knowledge (ActiveCaptain's moat). | L | Backend; moderation; licensing | — | v2+ |
| Bridges and air draft | Bridge clearances adjusted for the predicted or forecast water level vs the boat's air draft. | A real hazard on the ICW and in rivers; uniquely ours with surge. | M | Bridge data; datums | `TotalWaterLevelForecaster`, `DatumSet` | v1 |
| Tide and current station browser | Existing station screens, made reachable from the chart. | Already loved. | S | — | Existing app | MVP |

### 2.12 Notices and hazards

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| Local Notices to Mariners | USCG LNM / discrepancies / broadcast notices; geofenced to route and area. | Buoys off station, works, closures. | M | USCG/NGA sources | `Networking`, `NWS` patterns | v1 |
| Restricted and regulated areas | Security zones, MPAs, no-anchor zones, speed zones (manatee, whale). | Avoid fines and harm. | M | Regulatory sources | — | v1 |
| Chart update awareness | Which charts in offline packs are out of date. | Legal and safety. | S | Package server | `RefreshPolicy` | MVP |

### 2.13 Safety and legal posture

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| Not-for-navigation framing | First-run acknowledgement. Persistent "aid to navigation, not a substitute for official charts and prudent seamanship" wording. Disclaimer on auto-routes. Data-age indicators. | Protects users and us. | S | Legal review | Existing source-status / attribution model (`DataSourceInfo`) | MVP |
| Explainability | Every automated output shows its inputs and margins: route constraints, current source, alarm thresholds. | Trust; avoids silent wrongness. | S | — | `SourceStatus` pattern | MVP |
| Degradation, not failure | Stale GPS, stale AIS and missing data are shown plainly. Alarms prefer false positives for GPS loss. | Safety. | S | — | `ForecastService.capture` pattern | MVP |
| Attribution and licensing | Per-source attribution on the chart and in About. | Compliance. | S | DATA_SOURCES §6 | `DataSourceInfo.attribution` | MVP |

### 2.14 Apple Watch, CarPlay, widgets, Live Activities

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| Watch: MOB, anchor alarm, instruments | Haptic anchor and CPA alarms; MOB button; SOG/COG/depth/wind complications; tide and current complications. | Alarms on the wrist at night; hands free at the helm. | L | WatchConnectivity; watchOS target | Everything in TideKit (UI-free) | v1 |
| Live Activities | Passage (ETA, next waypoint, XTE), gate countdown, anchor watch status, race start countdown on the Lock Screen and Dynamic Island. | At-a-glance without unlocking. | M | ActivityKit | `Route`, `TidalGatePlanner`, `AnchorWatch` | MVP (anchor + gate) |
| Widgets | Existing tide widgets, plus current/gate and "next slack" widgets. | Already a strength. | S | — | `Widgets/` snapshots | MVP |
| CarPlay | CarPlay is built for driving, so it doesn't suit the helm. At most, ramp and tide info for trailer boaters on the drive. | Low. | — | — | — | Not planned |
| Lock Screen / Action button controls | MOB and "drop anchor" as Controls (iOS 18). | Fast emergency actions. | S | — | — | MVP |

### 2.15 Background location and battery

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| Background modes | Location updates in background for anchor watch, track and active route; audio-free alarms using critical alerts (entitlement request) or time-sensitive notifications. | Alarms that work with the screen off. | M | Apple entitlements (critical alerts) | `AnchorWatch` | MVP |
| Adaptive GPS duty cycle | Accuracy and rate tuned by mode: anchor (moderate, 1 Hz bursts), passage, idle. Use the external NMEA GPS when present so the phone's GPS can idle. | All-night anchor watch on one charge. | M | — | `AnchorWatch` (accepts sparse fixes) | MVP |
| Low-power chart mode | Lower frame rate, dark theme, no animations while under way. | Battery on long passages. | S | — | Globe's frame-rate controls are a precedent | v1 |

### 2.16 Accessibility, night mode, sunlight readability

| Feature | Description | User value | Size | Dependencies | Reuses | Phase |
|---|---|---|---|---|---|---|
| Night (red) mode | A true red-on-black palette for the chart and UI to preserve night vision; dims below system minimum. | Essential on night watches. | M | Design tokens (`docs/DESIGN.md`) | `Shared/Theme.swift` | MVP |
| Sunlight mode | High-contrast day palette and heavier strokes; large cockpit type. | Readable in glare. | S | Design | Theme | MVP |
| VoiceOver and Dynamic Type | All instruments and alarms announced; spoken CPA/anchor alerts; audio-only navigation prompts. | Inclusivity; hands-free. | M | — | — | MVP |
| Glove/wet-hands mode | Bigger targets, swipe-free critical actions. | Real-world use. | S | — | — | v1 |

### 2.17 Monetization tiers

| Tier | Includes | Rationale |
|---|---|---|
| **Free** | Tides and currents (today's app), current gates (view), phone-GPS own-ship on a basic chart, MOB, anchor alarm (foreground), 1 route. | Safety features are never paywalled. A big funnel from the existing tide audience. |
| **Coastal** (annual subscription) | Offline chart packs, unlimited routes, departure planner, course-to-steer, NMEA/SignalK instruments, AIS + CPA alarms, background anchor watch with remote watch, logbook, Watch app, Live Activities. | The core cruiser bundle. It competes with Aqua Map and Navionics on price, with better tides. |
| **Offshore** (higher annual) | GRIB viewer, weather routing with polars, multi-model, satellite-link-friendly downloads, sail performance tools, racing tools. | PredictWind's buyers. Server costs (routing, GRIB slicing) justify the price. |
| **Add-ons** | International chart regions (pass-through licensing), commercial internet AIS. | Costs that vary by region. |

Principles: offline charts keep working (frozen) when a subscription lapses, so there is no
"bricked at sea" failure, which is Navionics's top complaint. Data you created (routes,
tracks, logs) always exports.

---

## 3. Recommended MVP cut

**Theme: "Coastal cruiser who cares about tide."** It ships when a sailor can plan a day
passage, run it with instruments and AIS, and anchor overnight, all offline.

1. **Charts:** US NOAA ENC vector charts with offline packs, safety contour, object query.
2. **Own ship:** phone GPS + WMM variation; NMEA 0183 over WiFi (GPS, heading, wind, depth, log); instrument dashboard; true wind and set/drift.
3. **Routes:** manual routes (rhumb/GC), active navigation (XTE, ETA, VMG), GPX.
4. **Tidal edge:** current stations (harmonic + subordinate) on the chart, gate windows, departure planner, course-to-steer.
5. **AIS:** decoding, targets, CPA/TCPA alarms, AIS-SART/MOB.
6. **Anchoring:** tide-aware swing circle and advisories; background anchor alarm with drag/creep/GPS-lost.
7. **Safety:** MOB everywhere (app, Lock Screen control, Action button); disclaimers, explainability, data-age indicators; night and sunlight modes; VoiceOver.
8. **Surfaces:** Live Activities for anchor watch and gate countdown; current/slack widgets.
9. **Weather:** point marine forecast, NWS marine alerts, surge-aware water levels.

**Explicitly not in MVP:** auto-routing, weather routing, GRIB, polars and racing, SignalK and NMEA 2000,
Watch app, international charts, community data. Each is large or needs a server
component. Each MVP feature above rests either on TideKit logic that exists now or on a
contained app/UI build.

**The critical path is charts** (vector-tile pipeline + renderer + offline packs). It is the
only XL item in the MVP and should start immediately, in parallel with the TideKit work below.

---

## 4. Phased roadmap

| Phase | Horizon | Scope | Exit criteria |
|---|---|---|---|
| **0. Foundations** (now) | Weeks 0–4 | TideKit: Navigation/Geodesy + WMM, NMEA 0183, AIS + CPA, Anchoring, Currents + gate planner (**done**, see Status). Chart pipeline spike; renderer choice; offline package format. | Pure-logic modules tested against references; chart spike renders one ENC cell offline. |
| **1. MVP** | Months 1–4 | §3 list. App: chart screen, instruments, route editor, active nav, AIS layer, anchor watch, MOB, Live Activities. TideKit: subordinate current stations, track recorder + simplification, NMEA sentence output (RMB/XTE/APB), GPX. | TestFlight with ~50 cruisers; anchor-alarm false-alarm rate < 1 per 10 nights; gate predictions within 2 min of NOAA. |
| **2. v1** | Months 5–9 | SignalK, sensor fusion, tide-aware depths and bridge clearance, route hazard check, GRIB viewer, polars + VMG + laylines, logbook, remote anchor watch, Watch app, LNM and regulated areas, wind-against-tide. | Offshore tier launch; Watch alarms validated overnight. |
| **3. v2+** | Months 10+ | Auto-routing over bathymetry, isochrone weather routing, multi-model, racing/start-line, international charts, crowd bathymetry, community POIs, internet AIS, NMEA 2000 PGN decoding. | Routing passes a regression set of real passages with no hazard crossings. |

---

## 5. Proposed module architecture

### 5.1 Today

TideKit is one SwiftPM target (`Sources/TideKit`) organised by directory, layered bottom-up:

```
Core (models, TimeSeries, Nowcast)
  └─ Harmonics (astronomy, constituents, HarmonicPredictor)
       ├─ Surge (SurgeModel, TotalWaterLevelForecaster)
       ├─ Bay (TideMesh, TidalOffsets) · Globe (ephemeris, atlas)
       └─ Providers (NOAA, NWS, Open-Meteo, DFO, UKHO) ── Networking (APIClient, caches)
            └─ Services (ForecastService, BayService) · Briefing · Widgets (snapshots)
```

Rules the codebase already follows, which the new modules keep: no UI and no
CoreLocation/Network.framework (runs on Linux); value types and `Sendable` everywhere;
networking only through `APIClient`; decoding separated from fetching (`*Decoding` enums)
so fixtures test it; validation against an external reference wherever one exists.

### 5.2 Proposed

```
Core
 ├─ Navigation      geodesy (Vincenty, rhumb, great circle, XTE), local tangent plane,
 │                  current triangle, routes, WMM magnetic model              [built]
 ├─ Harmonics
 │    ├─ Currents   current-station predictor, events, NOAA decoding,
 │    │             CurrentField, TidalGatePlanner                            [built]
 │    └─ Anchoring  SwingModel, AnchorPlan, AnchorWatch                       [built]
 ├─ NMEA            0183 framing/checksum/tag blocks, typed sentences,
 │                  line splitter; later: sentence output, SignalK deltas     [built: input]
 │    └─ AIS        payload armour, reassembly, messages 1–5/18/19/21/24,
 │                  target table, CPA/TCPA + threat assessment                [built]
 ├─ Instruments     source arbitration, damping, true wind, depth alarm       [v1]
 ├─ Performance     polars, VMG/targets, laylines, start line                 [v1/v2]
 ├─ Tracks          recorder model, Douglas-Peucker, statistics, logbook      [MVP]
 ├─ Charts          chart catalog/package metadata, safety-depth sampler,
 │                  navigability grid (no rendering)                          [MVP/v1]
 ├─ Weather         GRIB2 decoder, gridded field sampling (wind, waves)       [v1]
 ├─ Routing         hazard check, A* over navigability grid, isochrones       [v1/v2]
 └─ Services        NavigationSession (actor: fuses GPS/NMEA, owns AnchorWatch,
                    AIS table, active route; emits alarms), plus today's services
```

Dependency rules:
* **Navigation depends only on Core.** It is the shared geometry for everything else. No
  other module rolls its own haversine. (`Station.distance` predates it and can migrate.)
* **NMEA depends on Navigation** (for `GeoCoordinate`). **AIS depends on NMEA + Navigation.**
* **Currents and Anchoring depend on Harmonics + Navigation.** They take a
  `HarmonicPredictor`/`TidalCurrentPredictor` as input and never fetch. Fetching stays in
  Providers. `NOAACoopsClient.currentHarmonics` is an extension that lives in `Currents/`.
* **Routing depends on Navigation, Currents, Charts and Weather** through protocols
  (`CurrentField`, a future `DepthField` and `WindField`), so tests can use synthetic
  fields, as `TidalGatePlannerTests` does.
* **Services/NavigationSession** is the only stateful orchestrator. The app feeds it fixes
  and NMEA lines and observes it. Platform I/O (CoreLocation, NWConnection sockets,
  notifications, ActivityKit) stays in the app layer, so TideKit still runs on Linux.

Package shape: keep one `TideKit` target for now. New directories under `Sources/TideKit`
need no `Package.swift` change, and the iOS app and widget already link the product. If
build times or API hygiene call for it later, split into `TideKitCore`, `TideKitNav` and
`TideKitForecast` targets along the lines above. The directory layering already matches.

---

## Status

*14 Nov 2026.* Phase 0 implementation of the four highest-value pure-logic items is done.
No Agent tool was available in this session, so the four items were not handed to parallel
subagents. They were built one after another, under the same rules the briefs would have
set: each item in its own directories, no changes to shared files (`Package.swift`
unchanged), the existing code style, tests against published reference values, and no git.

A Swift 6.4.2 toolchain (swift.org tarball for Ubuntu 24.04) was installed in the container.
**Everything was compiled and run** with `swift test --package-path TideKit`:
**152 tests, 0 failures** (84 that existed before + 68 new). The new files compile without warnings.

| Item | Sources | Tests | References | Result |
|---|---|---|---|---|
| (a) Geodesy / navigation core | `TideKit/Sources/TideKit/Navigation/`: `GeoCoordinate.swift` (coordinate, units, ENU vector, local tangent plane), `Geodesy.swift` (Vincenty inverse/direct on WGS 84 with spherical fallback, great-circle XTE/along-track/intermediate/densify, ellipsoidal rhumb lines), `CourseMath.swift` (course-to-steer, set & drift, leeway, VMG, ETA, `Route` legs and progress), `MagneticModel.swift` (WMM2025, embedded coefficients) | `Tests/TideKitTests/Navigation/` (21) | GeographicLib 2.1 geodesics (≤1 mm, ≤1e-6°); Vincenty's 1975 Flinders Peak example; Movable Type worked examples; **all 12 rows of NCEI's official WMM2025 test values** (0.1 nT, 0.01°, incl. grid variation) | Pass |
| (b) NMEA 0183 + AIS + CPA | `NMEA/`: `NMEASentence.swift` (framing, checksum, tag blocks, field helpers, line splitter), `NMEAMessages.swift` (RMC, GGA, GLL, VTG, HDG/HDT/HDM, MWV, DBT/DPT, VHW, MTW, XTE, RMB, ZDA, VDM/VDO). `AIS/`: `AISPayload.swift` (fragments, reassembly with timeout, 6-bit reader), `AISMessage.swift` (types 1/2/3, 4/11, 5, 18, 19, 21, 24A/B, emergency MMSIs), `CollisionAvoidance.swift` (CPA/TCPA with dead reckoning, threat levels, `AISTargetTable`) | `NMEA/` (8), `AIS/` (19) | Classic published NMEA sentences with their published checksums; real AIVDM samples (gpsd/pyais logs) checked field by field against pyais's decode; closed-form CPA geometry | Pass |
| (c) Anchor watch | `Anchoring/`: `SwingModel.swift` (taut reach, catenary, scope, `AnchorPlan` through the tide with advisories), `AnchorWatch.swift` (median filter, accuracy/speed spike rejection, dwell, creep warning, GPS-lost, anchor-from-bow offset, Kåsa circle fit) | `Anchoring/` (10) | Real tide at The Battery (existing NOAA fixtures) for depth, radius and scope extremes; closed-form catenary; seeded simulations: 2 h of swinging with correlated GPS noise and 1 % 60 m spikes → **0 alarms**; 0.5 kn drag → alarm < 2 min after leaving the circle | Pass |
| (d) Tidal currents + gate planner | `Currents/`: `TidalCurrent.swift` (major/minor-axis predictor on `HarmonicPredictor`, means, set/drift, slack/max events, NOAA current harcon + predictions decoding, `NOAACoopsClient.currentHarmonics`), `TidalGatePlanner.swift` (`CurrentField`, leg simulation with course-to-steer, gates: fair current / max stream / time window, departure sweep and refinement) | `Currents/` (10) | **NOAA's published predictions for the Golden Gate (SFB1203 bin 18), 1–7 Nov 2026**: velocity RMS 0.001 kn (NOAA's rounding); all 53 slack/max events within 37 s; set within 0.75° and speed within 0.004 kn of NOAA speed/direction. Analytic stream cases for the planner | Pass |

New test fixtures (downloaded from api.tidesandcurrents.noaa.gov on 14 Nov 2026), in
`TideKit/Tests/TideKitTests/Fixtures/`: `currents_pred_SFB1203_202611.json`,
`currents_maxslack_SFB1203_202611.json`, `currents_speeddir_SFB1203_202611.json`.

Findings worth knowing:
* NOAA current predictions include the published **major- and minor-axis mean currents**
  (`majorMeanSpeed`, `minorMeanSpeed` in `harcon.json`). Leaving out the major mean costs
  0.16 kn at the Golden Gate. The minor axis is **90° clockwise** of the flood axis.
* Vincenty's inverse doesn't converge for nearly antipodal points. `Geodesy.inverse` then
  falls back to the sphere (≤0.6 %). If ocean-crossing great circles ever need millimetres,
  port Karney's algorithm.
* `AGENTS.md` says the suite has 68 tests, but it had 84 before this work and has 152 now.
  It's a shared file, so it was left unchanged for the owner to update.

Not done (next TideKit steps, in MVP order): subordinate current stations; NMEA sentence
output (RMB/XTE/APB for autopilots); track recorder and simplification; `NavigationSession`
service; SignalK delta parsing.
