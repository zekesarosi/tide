# Navigation data sources catalog

Research for the sailing and boating navigation app built on Tide & Surge. Researched
and checked on **14 Nov 2026**. Licences, endpoints and programmes change often, so
re-verify anything marked `DOC`, `2ND` or `UNVERIFIED` before relying on it in a
shipping build. This document is not legal advice: get counsel to review the licensing
risk register (section 6) before launch.

**How to read the tags**

| Tag | Meaning |
|---|---|
| `LIVE` | We called the endpoint from our sandbox on 14 Nov 2026 and got real data back. |
| `DOC` | Confirmed from the provider's own page or documentation during this research, but not called. |
| `2ND` | Only secondary sources (forums, vendor blogs, third-party catalogues) were found. |
| `UNVERIFIED` | From prior knowledge, or the sources conflicted. Treat it as a lead, not a fact. |
| **BEST** | Best-in-class for its job. Build on it. |
| **TRAP** | Dead, rate-limited, ToS-hostile or licence-incompatible with a commercial iOS app. |
| **P0 / P1 / P2** | P0: MVP must-have. P1: first releases after the MVP. P2: later or niche. |

"Commercial OK" means the terms allow use inside a paid or ad-supported app. "Offline"
means the terms allow caching on the device for use without a connection.
"Redistribute" means we may serve the data (or tiles derived from it) from our own servers.

---

## 1. Summary table

### 1.1 Already integrated in TideKit (reuse, don't rebuild)

| Source | Used for today | Reuse in the navigation app |
|---|---|---|
| NOAA CO-OPS Data + Metadata API | Tides, datums, flood levels, 6-min water levels | Add **current predictions**, PORTS current meters, **air gap** (21 bridge clearance sensors, `LIVE`) and **visibility** (23 sensors, `LIVE`) through the same client. |
| NWS api.weather.gov | Alerts at a point | Marine zone forecasts, Special Marine Warnings, marine alerts by zone (section 4.4). |
| NWS NWPS | Coastal water level forecasts | River gauge forecasts for inland boating (section 4.9). |
| NHC CurrentStorms.json | Tropical cyclones | Add NHC GIS cone and track products for route planning. |
| Open-Meteo | Pressure and wind forcing | Point marine forecast (waves, swell, currents, SST). **A commercial subscription is required for a paid app.** |
| DFO IWLS, UK Admiralty Tidal API | International tides | Unchanged. |
| NASA GOT4.10c | Tide Globe | Unchanged. Never use it for coastal navigation. |

### 1.2 Catalog

| Source | Category | Coverage | Access | Licence / commercial | Offline / redistribute | Tier | Flag |
|---|---|---|---|---|---|---|---|
| **NOAA ENC (S-57)** | Vector charts | US, PR, USVI, Pacific territories | Zip by state/region/district + rolling 1/2/7/10-day zips, no auth (`DOC`) | Free; "download, use, and redistribute without restriction" except as noted; copies we redistribute are not "official" | Yes / Yes (not official, "NOAA ENC®" trademark can't be used) | P0 | **BEST** |
| NOAA S-101 ENC | Vector charts (next gen) | US | Dual S-57/S-101 production planned from 2026; no NOAA S-101 download found | Expected same as ENC | — | P2 | Watch |
| NOAA S-102 / S-104 / S-111 test buckets | Bathymetry / water level / currents (S-100 HDF5) | US (OFS + RTOFS + STOFS) | AWS `noaa-s102-pds`, `noaa-s104-pds`, `noaa-s111-pds` (`LIVE`) | Public domain (S-104 record says CC0) | Yes / Yes | P1 | **BEST** (currents) |
| **NOAA Chart Display Service (NCDS)** | Raster chart tiles, paper-chart symbology | US | WMTS / WMS / Esri REST (`LIVE`); weekly MBTiles by region (`DOC`) | US gov; no tile terms published | Yes (MBTiles meant for offline) / Probably yes (`UNVERIFIED`) | P0 | **BEST** fallback |
| NOAA ECDIS Display Service (S-52) | Raster tiles, ECDIS symbology | US | WMS / Esri REST (`DOC`) | As NCDS | As NCDS | P1 | |
| NOAA ENC Direct to GIS | ENC layers as GIS services | US | ArcGIS REST, by usage band (`LIVE`) | US gov; not for carriage | Yes | P2 | |
| NOAA RNC / paper charts | Raster charts | US | Cancelled; RNC Tile Service shut down 1 Oct 2021 | — | — | — | **TRAP** (dead) |
| CHS ENC (Canada) | Vector charts | Canada | Distributors only, S-63; VAR agreement for derived products | Crown copyright; the EULA bars derived products without a licence | Only under licence | P1 (licence) | **TRAP** if used unlicensed |
| UKHO ADMIRALTY AVCS | Vector charts | UK + global portfolio | Distributors / TSPs, S-63 | Commercial licence; leisure category exists | Under licence | P2 | |
| UKHO S-100 trial datasets | S-101/S-102/S-104/S-111 test data | Sample areas | Free download, for testing (`2ND`) | Test only | No | P2 | |
| AHO AusENC | Vector charts | Australia | Distributors, S-63, paid; S-101 for select areas from 2026 | Commercial licence | Under licence | P2 | |
| LINZ NZ ENC Service | Vector charts | New Zealand | Free subscription for mariners; S-57 reuse is royalty-based | Licence (fees) for reuse | Mariner use only | P2 | |
| LINZ Data Service chart data | Chart vector data, GeoTIFFs, bathymetry index | New Zealand | LDS download (`DOC`) | Per dataset (often CC BY 4.0, `UNVERIFIED`) | Per dataset | P2 | |
| Traficom open chart data (Finland) | Vector chart data, depths | Finland | Download service, WMS/WFS (`DOC`) | CC BY 4.0, commercial OK; **not for navigation**, not QA'd | Yes / Yes | P2 | |
| Kartverket sjøkart (Norway) | Raster chart WMS, depth WMS | Norway, Svalbard | Geonorge WMS (`2ND`) | CC BY 4.0 per catalogue (confirm on production Geonorge) | Yes / Yes | P2 | |
| Brazil CHM raster charts | Raster (BSB) | Brazil | Free download (`DOC`) | **No commercial reproduction or derivation**; not for navigation | No | — | **TRAP** |
| **OpenSeaMap seamarks** | Seamark overlay tiles + OSM seamark data | Global (crowd-sourced, uneven) | `tiles.openseamap.org/seamark/{z}/{x}/{y}.png` (`LIVE`) | Data ODbL; tiles CC BY-SA 2.0 | Self-host for offline; volunteer server has no SLA | P0 (outside US) | Useful, not authoritative |
| Navionics Mobile SDK (Garmin) | Charts, SonarChart, tides, POI | Global | iOS/Android SDK, developer token, request form (`DOC`) | Commercial "in-app purchase" plan; terms by request | SDK-managed | P1 | **BEST** paid global option |
| C-MAP (Navico / Brunswick) | Charts | Global | Developer WMTS announced 2020 (`2ND`); current status unknown | Commercial | Per contract | P1 (evaluate) | |
| Esri ArcGIS Maps SDK for Swift (ENCLayer) | S-57/S-63 renderer | — (bring your own data) | SPM package; paid licence for production (`DOC`) | Paid runtime licence | Yes | P2 | |
| **GEBCO_2025** | Global bathymetry grid | Global, 15″ (~450 m) | NetCDF / GeoTIFF, 7.5 GB global (`DOC`) | Public domain, attribution requested | Yes / Yes | P0 | **BEST** global |
| **NOAA BlueTopo / NBS** | High-res compiled bathymetry | US navigational waters | AWS `noaa-ocs-nationalbathymetry-pds` (`LIVE`) | NOAA OCS data are CC0 | Yes / Yes | P1 | **BEST** US |
| NCEI BAGs / multibeam / DEMs | Survey bathymetry | US + global archive | NCEI viewers and archive (`DOC`) | Public domain | Yes / Yes | P2 | |
| EMODnet DTM 2024 | Bathymetry ~115 m, LAT datum | European seas | WMS/WFS/WCS/WMTS + tiles (`DOC`) | CC BY 4.0 (some originator restrictions) | Yes / Yes | P1 (EU) | **BEST** EU |
| CHS NONNA-10/100 | Bathymetry 10/100 m | Canada | NONNA portal, GeoTIFF/BAG (`DOC`) | OGL-Canada + NONNA licence; **non-navigational** use | Yes, labelled | P2 | |
| IHO DCDB crowdsourced bathymetry (CSB) | Crowd soundings | Global (sparse) | NCEI CSB Data Extract API, CSV/GeoJSON (`DOC`) | CC0 intended | Yes / Yes | P2 | |
| **USCG NAVCEN MSI GeoJSON** | Light List, LNM (discrepancies, hazards, safety zones, bridges, marine events) | US | `navcen.uscg.gov/sites/default/files/msi/*.geojson` (`LIVE`) | US gov | Yes / Yes | P0 | **BEST** |
| USCG legacy weekly LNM/Light List PDF+XML | Notices | US | Retired after 31 Oct 2024 | — | — | — | **TRAP** (dead) |
| NGA MSI (NAVAREA IV/XII, HYDROLANT/PAC/ARC) | Navigational warnings | Global high seas | `msi.nga.mil/api/publications/...` JSON (`2ND`; returned **503 to our sandbox**) | US gov | Yes | P0 | Fragile |
| USCG Broadcast Notices to Mariners | Urgent notices | US | navcen.uscg.gov web pages; no feed found | US gov | — | P1 | Gap |
| Canada NOTMAR / CCG NAVWARN | Notices and warnings | Canada | Web pages and PDFs; no machine feed found | Crown | — | P2 | Gap |
| **NWS marine forecasts** | CWF, OFF, NSH, HSF text + zone geometry | US waters + high seas | api.weather.gov zones/products and tgftp text (`LIVE`) | US gov; User-Agent required | Yes / Yes | P0 | **BEST** |
| NWS alerts (marine) | SMW, Small Craft Advisory, Gale, Dense Fog | US | `alerts/active?zone=` (`LIVE`) | US gov | Yes | P0 | |
| **NDBC** | Buoy and C-MAN observations | US + partners (1,357 stations) | realtime2 text, latest_obs, activestations.xml (`LIVE`) | US gov | Yes / Yes | P0 | **BEST** |
| CDIP | Wave spectra, buoys | US coasts, Pacific | THREDDS (`LIVE`) | Public (`UNVERIFIED` terms) | Yes | P1 | |
| **GFS + GFS-Wave** | Global NWP GRIB2 | Global 0.25° (wave 0.16°/0.25° + regional) | AWS `noaa-gfs-bdp-pds` (`LIVE`), NOMADS | US gov | Yes / Yes | P0 | **BEST** |
| NOMADS GRIB filter | Subset GRIB | Global | HTTP; ~120 hits/min/IP limit, escalating blocks (`2ND`) | US gov | — | P1 | **TRAP** for client apps |
| **ECMWF open data (IFS, AIFS, WAM)** | Global NWP + waves GRIB2 | Global 0.25° (0.1° IFS from 20 Oct 2026 per ECMWF) | data.ecmwf.int + AWS/Azure/GCP mirrors (`LIVE`) | CC BY 4.0, commercial OK | Yes / Yes; only last ~12 runs kept | P0 | **BEST** |
| HRRR | 3 km CONUS NWP | CONUS | AWS `noaa-hrrr-bdp-pds` (`LIVE`) | US gov | Yes / Yes | P1 | |
| NBM | Blended forecast incl. visibility | US | AWS `noaa-nbm-grib2-pds` (`LIVE`) | US gov | Yes / Yes | P1 | |
| NAM | Regional NWP | North America | NOMADS | US gov; legacy (RRFS replacement, `UNVERIFIED`) | Yes | P2 | Legacy |
| DWD ICON (global/EU/D2) + EWAM/GWAM | NWP + waves | Global / Europe / Germany | opendata.dwd.de GRIB2 (`DOC`) | CC BY 4.0 with DWD attribution | Yes / Yes | P1 | |
| Météo-France AROME / ARPEGE | NWP | France+ / global | data.gouv.fr, AWS registry (`2ND`) | Licence Ouverte 2.0 | Yes / Yes | P2 | |
| ECCC MSC Datamart (HRDPS, GDPS, marine text) | NWP + marine forecasts | Canada / global | dd.weather.gc.ca (`LIVE`) | ECCC end-use licence: commercial OK with attribution | Yes / Yes | P1 (Canada) | |
| BOM Australia text and feeds | Marine forecasts | Australia | FTP/web | **Free text products "not for commercial use"** | No | — | **TRAP** |
| **NOAA OFS (CBOFS, SFBOFS, …)** | 3D currents, water level, temperature | 13 US estuaries / Great Lakes | AWS `noaa-nos-ofs-pds` (`LIVE`), THREDDS | US gov | Yes / Yes | P1 | **BEST** US harbours |
| NOAA RTOFS | Global ocean currents 1/12° | Global | AWS `noaa-nws-rtofs-pds` (`LIVE`) | US gov | Yes / Yes | P1 | |
| STOFS-3D-Atlantic / -Pacific | Total water level | US coasts | AWS `noaa-nos-stofs3d-pds` (`LIVE`) | US gov | Yes | P2 | |
| HYCOM / Navy ESPC | Global ocean | Global | hycom.org THREDDS; GOFS 3.1 retired 4 Sep 2024 (`2ND`) | US gov | Yes | P2 | Academic server, no SLA |
| **Copernicus Marine** | Currents, waves, SST, sea ice, regional seas | Global + EU regional | copernicusmarine toolbox / ARCO, registration (`DOC`) | Free incl. commercial, attribution | Yes / Yes with credit | P1 | **BEST** global ocean |
| IOOS HF radar (HFRNet) | Surface currents nowcast | US coasts | THREDDS (unreachable from sandbox) | US gov | Yes | P2 | |
| Open-Meteo Marine | Point waves, swell, currents, SST | Global | `marine-api.open-meteo.com` (got **429** from shared IP) | Data CC BY 4.0; **API free tier non-commercial** | Yes / Yes (CC BY) | P0 (paid plan) | |
| Stormglass | Point marine weather | Global | REST, key | Free 10 req/day non-commercial; €49+/mo commercial | Unclear | P2 | |
| Windy Point Forecast API | Point forecast | Global | REST, key | €990/yr, 10k req/day, **ECMWF excluded**, trial returns altered data | Unclear | P2 | **TRAP** for ECMWF |
| PredictWind | Proprietary models | Global | **No public API** | — | — | — | Gap |
| Saildocs | GRIB and text by e-mail | Global | `query@saildocs.com` (`2ND`) | Free (SailMail) | — | P2 | |
| NOAA CoastWatch ERDDAP (MUR SST etc.) | SST, chlorophyll | Global | ERDDAP griddap (`LIVE`) | US gov / NASA | Yes / Yes | P1 | |
| aviationweather.gov METAR API | Coastal visibility, ceiling, wind | Global airports | `/api/data/metar` JSON (`LIVE`) | US gov | Yes | P1 | |
| GOES-19/18 GLM | Total lightning | Americas, ~±50° lat | AWS `noaa-goes19` (20 s files, `LIVE`) | US gov, public | Yes / Yes | P1 | **BEST** free lightning |
| nowCOAST lightning density WMS | Ground-strike density | US / OPC area | GeoServer WMS (`2ND`) | US gov | Display | P2 | |
| Blitzortung | Ground lightning | Global | No public API | **Commercial use prohibited** | No | — | **TRAP** |
| Xweather (Vaisala) lightning | Ground lightning | Global | REST, paid | Commercial | Per contract | P2 | Paid |
| NEXRAD L2 / MRMS | Radar | US | AWS `unidata-nexrad-level2`, `noaa-mrms-pds` (`LIVE`) | US gov | Yes | P1 | |
| **On-boat AIS (NMEA 0183/2000 gateways)** | Live targets, own ship, instruments | Line of sight from the boat | TCP/UDP NMEA over Wi-Fi | No data licence | Local | P0 | **BEST** |
| **Signal K** | Boat data hub | On board | REST + WebSocket, mDNS (`DOC`) | Open source (Apache-2.0, `UNVERIFIED`) | Local | P0 | **BEST** |
| aisstream.io | Internet AIS stream | Global terrestrial (patchy) | `wss://stream.aisstream.io/v0/stream`, key (`DOC`) | Free; no SLA; **no direct client connections** | Relay through our server | P1 | |
| AISHub | Pooled AIS | Global (volunteer) | REST, 1 req/min (`DOC`) | Must contribute a station; commercial OK with credit; **no raw redistribution** | Limited | P2 | |
| Digitraffic Marine (Finland) | AIS + AtoN faults | Baltic / Finland | REST + MQTT (`LIVE`) | Open (CC BY 4.0, `UNVERIFIED`) | Yes | P2 | |
| Kystverket AIS (Norway) | AIS | Norway | TCP `153.44.253.27:5631` + download (`DOC`) | NLOD (open, attribution) | Yes | P2 | |
| MarineCadastre AIS | Historical US AIS | US | GeoParquet (2024–25), CSV (`DOC`) | CC0 | Yes / Yes | P2 | |
| MarineTraffic / Kpler | Global AIS incl. satellite | Global | Enterprise API, credits | Commercial, expensive, no public pricing | Per contract | P2 | Expensive |
| Global Fishing Watch API | Vessel activity | Global | REST | **CC BY-NC 4.0, no commercial** | — | — | **TRAP** |
| **OSM seamarks + harbours (Overpass / planet extracts)** | Marinas, harbours, anchorages, fuel, AtoN | Global (uneven) | Planet/Geofabrik extracts; Overpass for small queries | ODbL (share-alike on derived databases) | Yes (self-host) | P0 | |
| **Garmin ActiveCaptain Community API** | Marinas, anchorages, hazards, reviews | Global, strongest in North America | Free API, application and approval (`DOC`) | Free; detailed terms after approval | Unknown until approved | P0 (apply now) | **BEST** community POI |
| Waterway Guide API v2 | Marinas, anchorages, bridges, locks, fuel prices | US, Canada, Bahamas, Caribbean+ | REST, secret token (`DOC`) | Commercial licence, pricing not public | Per contract | P1 | **BEST** curated US POI |
| Marinas.com API | Marinas | — | **Deprecated, removed 1 Sep 2024** | — | — | — | **TRAP** (dead) |
| Navily | Anchorages / marinas (Med) | Europe | No API | — | — | — | Gap |
| Noforeignland | Cruising places, tracking | Global | Boat tracking key (write only) | — | — | — | Gap |
| NOAA Coast Pilot | Sailing directions | US | PDF chapters (`DOC`) | US gov | Yes | P1 | |
| FWC manatee zones (Florida) | Speed / no-wake zones | Florida | ArcGIS REST `gis.myfwc.com` (`DOC`) | State open data | Yes | P1 | |
| NOAA right whale SMAs (50 CFR 224.105) | Seasonal speed zones | US East Coast | Regulation text (static polygons) | US gov | Yes | P1 | |
| MarineCadastre Danger Zones & Restricted Areas | 33 CFR 334 polygons | US | Zip + feature service (`DOC`) | US gov; accuracy "untested" | Yes | P1 | |
| NOAA MPA Inventory | Marine protected areas | US | Download (`DOC`) | Public domain; not for navigation | Yes | P1 | |
| Protected Planet WDPA | Global protected areas | Global | Download / API | **No commercial use, no redistribution** | No | — | **TRAP** |
| NOAA Wrecks & Obstructions (AWOIS + ENC) | Wrecks | US | KML/XLS + ArcGIS (`DOC`); AWOIS frozen since 2016 | US gov; not for navigation | Yes | P1 | Prefer ENC WRECKS |
| US National Ice Center | Ice charts (SIGRID-3) | Arctic, Antarctic, Great Lakes (`UNVERIFIED`) | usicecenter.gov; NSIDC archive | US gov | Yes | P2 | |
| Canadian Ice Service | Ice charts (SIGRID-3) | Canadian waters incl. Great Lakes | `ice-glaces.ec.gc.ca/prods/sigrids/` (`DOC`) | ECCC open licence (`UNVERIFIED`) | Yes | P2 | |
| USGS Water Data OGC API | River gauges | US | `api.waterdata.usgs.gov/ogcapi/` (`LIVE`) | US gov | Yes | P1 | |
| USGS waterservices (legacy) | River gauges | US | Decommissioned Feb 2027, degradation from Nov 2026 | — | — | — | **TRAP** (dying) |
| USACE CWMS Data API | Stages, reservoirs, lock data | US Corps projects | `cwms-data.usace.army.mil/cwms-data/` (`LIVE`) | US gov | Yes | P1 | |
| USACE Corps Locks / LPMS | Lock status and queues | US inland | Web + XML services (unreachable from sandbox) | US gov | Yes | P1 | |
| USACE IENC | Inland ENCs (S-57) | US inland waterways | ienccloud.us (`LIVE`) | US gov | Yes | P1 | |
| EuRIS | Fairway info, locks, bridges, notices | EU inland | Portal + open APIs (`DOC`) | Free open data (GDPR data excluded) | Yes | P2 | |
| PEGELONLINE (WSV) | Water levels | German waterways | REST JSON (`LIVE`) | Open (`UNVERIFIED` exact licence) | Yes | P2 | |
| Rijkswaterstaat waterwebservices | Water levels, currents | Netherlands | New DDAPI20 host responds (`LIVE`); old docs discontinued | Free (`DOC`) | Yes | P2 | |
| **WMM2025 / WMMHR2025** | Magnetic declination | Global, valid 2025–2030 | Coefficient files (`DOC`) | Public domain | Bundle in app | P0 | **BEST** |
| NOAA geomag web calculator | Declination API | Global | Needs a free key (`LIVE`) | US gov | — | — | Not needed |
| **USNO Astronomical Applications API** | Sun/Moon, celestial navigation | Global | `aa.usno.navy.mil/api/...` v4.0.1 (`LIVE`) | US gov | Yes | P1 (validation) | |
| JPL DE440 / NOVAS / ERFA | Ephemerides for on-device almanac | Global | Files / libraries | Public domain / BSD | Bundle | P1 | |
| Swiss Ephemeris | Ephemeris | — | Library | **AGPL or paid licence** | — | — | **TRAP** |
| Apple MapKit satellite | Imagery | Global | MapKit (already in app) | Free in-app; no offline (`UNVERIFIED` exact terms) | No | P0 (online) | |
| **Sentinel-2 L2A (Copernicus)** | 10 m imagery, ~5-day revisit | Global | AWS `sentinel-cogs` + Earth Search STAC (`LIVE`) | Free incl. commercial, attribution | Yes / Yes | P1 | **BEST** free imagery |
| USGS NAIP Plus / Imagery Only | 0.6–1 m aerial imagery | US | ArcGIS Image/Map services (`LIVE`) | US gov, public domain | Yes / Yes | P1 | **BEST** US anchorage scouting |
| Landsat | 30 m imagery | Global | AWS / USGS | Public domain | Yes | P2 | |
| EOX Sentinel-2 cloudless | Cloud-free mosaic | Global | WMTS | 2016 CC BY; **2018+ CC BY-NC-SA** | — | — | **TRAP** |
| Esri World Imagery | High-res imagery | Global | ArcGIS | ArcGIS licence; export restricted (Gaia GPS lost offline in Jan 2025) | No (except ArcGIS apps) | — | **TRAP** |
| Mapbox Satellite | High-res imagery | Global | Mapbox SDK | Paid; offline only through the SDK from Mapbox servers | SDK only, no bundling | P2 | |
| Google Maps tiles | Imagery | Global | — | No offline caching | No | — | **TRAP** |

---

## 2. Recommended MVP data stack

The MVP should launch **US-first** (plus the Great Lakes), because US government data is
the only complete, free, commercially redistributable chart + notice + weather stack in
the world. Elsewhere the MVP is "planning grade" until a commercial chart licence is signed.

### 2.1 P0 stack

| Function | Primary | Fallback / complement | Why |
|---|---|---|---|
| Base chart (US) | **NOAA ENC S-57 → our own vector tiles** (section 4.1.7) | NCDS WMTS online, NCDS MBTiles offline | ENC is free to redistribute and vector, so it styles day/dusk/night and stays small offline. NCDS gives a familiar paper-chart look with zero pipeline work. |
| Base chart (rest of world) | OSM base + **OpenSeaMap seamarks** + GEBCO depth shading, clearly labelled "not an official chart" | Navionics SDK as a paid upgrade (decide by P1) | No free official vector charts exist outside the US (section 7). |
| Depth | ENC DEPARE/SOUNDG (US) | GEBCO_2025 (global shading) | — |
| Aids to navigation | ENC (US) + **NAVCEN Light List GeoJSON** for characteristics and LLNR | OSM seamarks | The Light List carries the authoritative light characteristic and private-aid status. |
| Notices | **NAVCEN LNM GeoJSON**: discrepancies, hazards, safety zones, bridges, marine events | NGA MSI NAVAREA IV/XII for offshore | LNM refreshes every ~15 min and is geolocated. |
| Marine forecast | **NWS zone forecasts** (CWF/NSH/OFF) via api.weather.gov + **marine alerts** | Open-Meteo (commercial plan) for points outside NWS zones | Official, free, verified live. |
| Observations | **NDBC** buoys + CO-OPS met/air gap/visibility | METAR | Free, verified live. |
| Gridded wind and waves | **GFS + GFS-Wave** and **ECMWF IFS/WAM open data**, sliced on our server into compact tiles | Open-Meteo point API | Both are free for commercial use. ECMWF is the most skilful global model. |
| Tides and tidal currents | Existing TideKit + **CO-OPS current predictions** | Open-Meteo / Copernicus currents offshore | Already built. Add the current-predictions product. |
| AIS | **On-board NMEA 0183 (TCP/UDP) and Signal K** | — | Costs nothing, works offshore, and is the feature cruisers expect. |
| POI | **OSM** (marinas, fuel, harbours) + ENC (anchorage areas, bridges with VERCLR) | **ActiveCaptain API: apply now**, it gates the best community data | — |
| Hazards / regulation | ENC restricted areas, wrecks, cables + NAVCEN safety zones | MarineCadastre danger zones (P1) | — |
| Magnetic variation | **WMM2025** computed on the device | — | Public domain, 5 KB of coefficients. |
| Sun, Moon, twilight | Existing `Ephemeris` (TideKit) | USNO API for test fixtures | Already built and pinned to JPL Horizons. |
| Imagery | Apple MapKit satellite (online) | USGS NAIP / Sentinel-2 (P1, offline) | — |

### 2.2 Server components the stack needs

The app's architecture already recommends a small proxy for paid keys (README). The
navigation app needs a little more on the server side:

1. **Chart tile builder** (weekly, plus daily deltas): pull NOAA's `OneDay_ENCs.zip` (or `OneWeek`) and build MBTiles/PMTiles per region with GDAL and tippecanoe. Serve the result from object storage behind a CDN.
2. **GRIB slicer**: pull GFS/GFS-Wave (AWS), ECMWF open data and later RTOFS/OFS, then cut regional, quantised wind/wave/current tiles (for example 16-bit u/v). This avoids NOMADS rate limits and keeps phones off 100 MB GRIB files.
3. **AIS relay** (P1): aisstream.io forbids direct client connections and limits each account to 3 connections, so one relay fans out bounding-box subsets.
4. **Key proxy** for Open-Meteo commercial, ActiveCaptain, Waterway Guide and any paid APIs. Keys must never ship in the binary.
5. **Notice cache**: mirror NAVCEN GeoJSON and NGA MSI every 15 minutes. NGA MSI returned 503 to our sandbox, so the app must not depend on it directly.

### 2.3 P1 additions

Copernicus Marine and RTOFS currents offshore; OFS and S-111 currents in US harbours;
BlueTopo high-resolution depth; HRRR/NBM for visibility and gusts; GOES GLM lightning;
NEXRAD/MRMS radar; Waterway Guide POI; aisstream.io internet AIS; USACE locks and USGS
river gauges; Canada (CHS licence via a distributor, ECCC forecasts); EMODnet depth for
Europe; Sentinel-2/NAIP offline imagery; manatee and right-whale speed zones.

---

## 3. What's already integrated

TideKit's providers (`TideKit/Sources/TideKit/Providers/`) give the navigation app a head
start. Notes for reuse:

* **NOAA CO-OPS** (`NOAACoops.swift`) uses `api.tidesandcurrents.noaa.gov/api/prod/datagetter` and `mdapi/prod/webapi`. The same client can fetch:
  * `product=currents_predictions` for tidal current stations;
  * PORTS current meters;
  * `air_gap`: 21 stations such as Verrazano-Narrows and the Bayonne Bridge (`LIVE`, `mdapi .../stations.json?type=airgap`);
  * `visibility`: 23 stations, mostly in Narragansett Bay and Chesapeake Bay (`LIVE`).
* **NWS** (`NWS.swift`) already sends the mandatory `User-Agent`. Marine zone IDs (`ANZ338` and similar) work with the same `alerts/active?zone=` and `zones/forecast/{id}/forecast` calls (section 4.4).
* **Open-Meteo** (`OpenMeteo.swift`) already switches to `customer-api` with a key. The marine endpoint is a different host (`marine-api.open-meteo.com`). **Our free-tier request from the shared sandbox IP got `429 Daily API request limit exceeded`.** Limits are per IP, so a server-side proxy on the free tier fails quickly. Budget for a commercial plan.
* **APIClient** pacing, coalescing and `DiskResponseCache` suit every REST source here. The cache TTLs in section 5 can plug straight into `RefreshPolicy`.

---

## 4. Detailed sources by category

### 4.1 Nautical charts

#### 4.1.1 NOAA ENC (S-57). P0, BEST

* **Provides:** official US vector charts in all usage bands, US1 (overview) to US6 (berthing). NOAA is moving to a regular gridded cell scheme ("rescheming"; status page at `distribution.charts.noaa.gov/ENC/rescheme/`), so the pipeline must cope with old and new cell names.
* **Access (`DOC`, page fetched 14 Nov 2026):** `https://charts.noaa.gov/ENCs/ENCs.shtml`.
  * `All_ENCs.zip`: 778 MB, all zips regenerated daily at about 05:50 UTC.
  * Per-state zips (`[ST]_ENCs.zip`, e.g. AK 204 MB, FL 62 MB), per-region and per-Coast-Guard-district zips, each with an ISO 19115 catalogue `*_ENCProdCat_19115.xml`.
  * Rolling deltas: `OneDay_ENCs.zip` (4 MB), `TwoDays` (6 MB), `OneWeek` (20 MB), `TenDays` (24 MB). **Use these for incremental tile rebuilds.**
  * No auth.
* **Format:** S-57 Edition 3.1, base cells (`.000`) plus updates (`.001`…). GDAL's S57 driver (MIT-licensed) reads it.
* **Cadence:** cells change with Notices to Mariners. Data.gov metadata says files are updated at least monthly; in practice NOAA posts daily.
* **Licence (`DOC`, `charts.noaa.gov/ENCs/Agreement.shtml`):**
  * "You may download, use, and redistribute them without restriction, and without payment to NOAA, except as noted herein."
  * "Redistributed NOAA ENCs are NOT considered official NOAA ENCs."
  * A product that incorporates ENC data in another form makes its producer "assume full liability".
  * "NOAA ENC®" and "NOAA®" are registered trademarks.
  * 15 CFR 995 sets up certified distributors. Only those copies count for carriage on regulated vessels. Recreational boats have no such requirement.
* **Implication:** we may convert to vector tiles and serve them commercially. We must:
  * label the charts as derived from NOAA ENC data and not official;
  * show each cell's edition, update number and issue date;
  * not market them as "NOAA ENC®";
  * carry our own liability disclaimer.
* **Reliability:** high. The files are static on a government CDN.

#### 4.1.2 S-100 / S-101 and the NOAA S-10x test buckets. P1 to P2

* **Status:**
  * S-100 product specifications and S-100 ECDIS became legal for use in January 2026. ECDIS installed from 1 January 2029 must be S-100 capable.
  * NOAA's transition plan targets dual S-57/S-101 production from 2026, built out region by region (`DOC`, NOAA plan via IHO).
  * We found **no NOAA S-101 download** on charts.noaa.gov (the ENC page says only "available in S-57 format").
  * UKHO says there is no planned withdrawal date for S-57.
  * Elsewhere: Greece issued 99 S-101 cells via IC-ENC in January 2026, Australia plans S-101 for select areas from 2026, and Finland's Traficom is rolling launches through 2026–27.
* **NOAA S-100 test data on AWS (`LIVE`):**
  * `noaa-s102-pds` (ed3.0.0): bathymetric surface.
  * `noaa-s104-pds` (ed2.0.0): water level from STOFS-2D-Global, CC0.
  * `noaa-s111-pds` (ed1.0.1): surface currents at 4.5 m depth from 12 NOS OFS (CBOFS, DBOFS, GoMOFS, LEOFS, LMHOFS, LOOFS, LSOFS, NGOFS2, NYOFS, SFBOFS, TBOFS, WCOFS) and RTOFS east/west. HDF5, regular grid (DCF-2) or native grid (DCF-3). Most models run 4×/day with 36–48 h horizons; two Great Lakes systems run to 120 h. An SNS topic announces new files. NOAA calls it "preliminary … for manufacturers to test".
* **Recommendation:**
  * Keep the internal chart model S-57-shaped now, but design the feature schema so that S-101 feature catalogue classes can map onto it.
  * **S-111 is the easiest way to get gridded harbour currents**: one HDF5 per run, already tiled to the Coast Survey scheme. Consider it for P1.
  * Revisit S-101 when NOAA publishes production cells.

#### 4.1.3 NOAA chart tile services. P0 fallback

| Service | Endpoint | Notes |
|---|---|---|
| NOAA Chart Display Service (NCDS, paper-chart symbology) | WMTS template `https://gis.charttools.noaa.gov/arcgis/rest/services/MarineChart_Services/NOAACharts/MapServer/WMTS/tile/1.0.0/MarineChart_Services_NOAACharts/{Style}/{TileMatrixSet}/{TileMatrix}/{TileRow}/{TileCol}.png` (`LIVE`, capabilities fetched) | Rendered from ENC weekly. Replaced the RNC Tile Service. |
| NCDS WMS / Esri REST | `.../MCS/NOAAChartDisplay/MapServer/exts/MaritimeChartService/{WMSServer,MapServer}` (`DOC`) | |
| ECDIS Display Service (S-52) | `.../MCS/ENCOnline/MapServer/exts/MaritimeChartService/{WMSServer,MapServer}` (`DOC`) | IMO/IHO-style ECDIS look. |
| NCDS MBTiles | `https://distribution.charts.noaa.gov/ncds/index.html`; pick a region, then "MBTiles" (`DOC`) | "Baseline MBTiles packages are updated weekly." Downloads take minutes. Made for offline use. |

* **Licence:** no tile-specific terms are published. They are US government works, and the ENC agreement applies to the data.
* **Reliability:** a user reported HTTP 503s from WMTS/WMS with no status page (`2ND`). **Don't hotlink from every client.** Mirror the MBTiles or proxy and cache the tiles.
* **Tier:** P0 as fallback, offline packs and a "paper chart" mode. The primary vector chart is our own (4.1.7).
* **Dead (TRAP):** the RNC Tile Service and RNC Viewer (shut down 1 Oct 2021), the Seamless RNC service (1 Jan 2022) and the paper/RNC product line (cancellation began January 2025). Ignore any code or tutorial that uses `tileservice.charts.noaa.gov`.

#### 4.1.4 Other national hydrographic offices

| Office | What's available | Commercial app route | Verdict |
|---|---|---|---|
| **CHS (Canada)** | ENCs and rasters through dealers; S-63 encrypted ENCs | Value-Added Reseller (VAR) agreement (May 2024 template) or an IP licence application. The EULA forbids using a product "to develop or derive any other product for distribution, navigation or commercial purposes" without a separate licence, and the VAR may not distribute official ENCs in SENC form (`DOC`). **NONNA bathymetry** is free for non-navigational use. | P1 via licence. **TRAP** if anyone suggests scraping a CHS WMS. |
| **UKHO / ADMIRALTY** | AVCS (S-63) through distributors and TSPs; a leisure licensing category; S-100 trial datasets; the ADMIRALTY Tidal API (already used); weekly Notices to Mariners | Become, or partner with, an ADMIRALTY distributor. C-MAP is one. Contact customerservices@ukho.gov.uk. | P2. Usually cheaper to go through C-MAP or Navionics. |
| **AHO (Australia)** | AusENC (S-63, paid) through agents; free evaluation cell (not for navigation); S-101 for select areas from 2026 | Distributor or licensing manager | P2 |
| **LINZ (New Zealand)** | NZ ENC Service: free subscription for mariners. LINZ Data Service: chart vector data and GeoTIFFs. NZMariner RNCs being withdrawn. | S-57 reuse "under a licence agreement … royalty-based" (hydro@linz.govt.nz). Check the LDS licence on each dataset (`UNVERIFIED` whether CC BY 4.0 covers chart layers). | P2 |
| **Traficom (Finland)** | Open vector chart data + depths, CC BY 4.0, commercial OK, through the download service and WMS/WFS. Official S-57 only through authenticated services under contract. | Open data is fine for planning layers, labelled "not suitable for navigation". Navigation use needs a contract. | P2. The best open data in the Baltic. |
| **Kartverket (Norway)** | Raster sea chart WMS (whole paper portfolio, updated twice a month); depth WMS; CC BY 4.0 per catalogue records (`2ND`, one record was on a test catalogue) | WMS for planning; confirm the licence on production Geonorge | P2 |
| **Germany (WSV)** | Inland ENCs free via ELWIS (ATOM feed) | Free | P2 (inland) |
| **Netherlands** | The Netherlands Hydrographic Service notes that "nautical charts are in most countries not regarded as open data"; source data partly open via INSPIRE/EMODnet | — | P2 |
| **Brazil (CHM)** | Free BSB raster charts, but "may not be reproduced, compiled, or derived for commercial purposes", and not for navigation. ENCs only via IC-ENC / EMGEPRON. | Licence ENCs via IC-ENC | **TRAP** for the rasters |
| **Peru (DIHIDRONAV)** | Free raster downloads (`2ND`) | Check the terms | P2 |
| IC-ENC / PRIMAR (RENCs) | Wholesale S-63 ENCs from many HOs | B2B distributors (ChartWorld, Navtor, …) | Only if we become an ECS vendor |

**Bottom line:** outside the US, official charts in a commercial leisure app go through
one of three routes: (a) a white-label commercial cartography SDK (Navionics, C-MAP), (b)
a distributor contract per hydrographic office, or (c) labelled, non-navigational open
layers (OpenSeaMap, Traficom, Kartverket, EMODnet).

#### 4.1.5 OpenSeaMap. P0 outside the US

* **Provides:** a seamark overlay (buoys, lights, harbours, anchorages, restricted areas) rendered from OSM `seamark:*` tags, plus a crowd-sourced depth project.
* **Access:**
  * Tiles: `https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png` (`LIVE`, transparent PNG overlay).
  * Raw data: OSM itself, via planet or Geofabrik extracts, or Overpass for small queries.
* **Licence:** data ODbL. Tiles "are available under CC-BY-SA" (2.0), per the OSM wiki (`DOC`).
* **Implications:**
  * Attribution is required.
  * **ODbL share-alike applies to any derived database** we publish. Keep OSM-derived POI in a separate layer and don't merge it into proprietary data we want to keep closed.
  * The tile server is volunteer-run with no published app policy or SLA, so for offline packs **render our own seamark tiles from OSM** rather than bulk-downloading theirs.
* **Quality:** good in Northern Europe, patchy elsewhere, not authoritative. Always label it "not an official chart".

#### 4.1.6 Commercial chart options

| Option | What you get | Terms (as found) | Fit |
|---|---|---|---|
| **Navionics Mobile SDK (Garmin)** | Charts, SonarChart HD bathymetry, tides/currents, map options, daily updates, object info; iOS and Android; developer token | One plan: "Mobile SDK in-app purchase". The developer buys rights to Navionics content for its users and handles delivery and monetisation (`DOC`, developer.garmin.com/marine-charts/mobile). Pricing and offline rules come after the request form. | **Best paid route to global coverage.** Request access early, since lead times are unknown. It ties our UX to Garmin's SDK. |
| **C-MAP (Navico / Brunswick)** | Global charts; announced a developer WMTS in 2020 via developer.navico.com, then with free registration (`2ND`); also an ADMIRALTY distributor | Current status and terms unknown | Evaluate alongside Navionics. |
| **Esri ArcGIS Maps SDK for Swift: ENCLayer** | Renders S-57 and S-63 with S-52 presentation | Paid production licence; other Esri SDKs gate ENC at Standard level (`DOC` for .NET/Kotlin/Flutter). **Brings no chart data.** | Only if we want a certified S-52 renderer. Heavy dependency. |
| ChartWorld / SevenCs, Teledyne CARIS | S-63/S-100 kernels and hosting | B2B | Not for the MVP. |
| o-charts | Official charts for OpenCPN only | OpenCPN ecosystem | Not usable in an iOS app. |

#### 4.1.7 S-57 to vector tiles pipeline. P0 build item

Recommended pipeline (server side, weekly full build plus daily delta):

```
charts.noaa.gov  ──►  S-57 cells (.000 + updates)
   OneDay/OneWeek zips      │
                            ▼
              GDAL/OGR S57 driver (ogr2ogr)
              options: RETURN_PRIMITIVES=OFF, SPLIT_MULTIPOINT=ON, ADD_SOUNDG_DEPTH=ON,
                       LNAM_REFS=ON, UPDATES=APPLY
                            │  one GeoJSONSeq per object class (DEPARE, DEPCNT, SOUNDG, LIGHTS,
                            │  BOYLAT, BCNCAR, RESARE, WRECKS, OBSTRN, BRIDGE, ACHARE, …),
                            │  tagged with cell name, usage band (US1–US6), edition/update, SCAMIN
                            ▼
              usage-band → zoom mapping (US1 z0–6 … US5 z13–16, US6 z16+), coverage
              clipping so larger-scale cells mask smaller-scale ones (M_COVR)
                            │
                            ▼
              tippecanoe (≥ 2.17 writes PMTiles directly) → MBTiles / PMTiles per region
                            │
                            ▼
              CDN (byte-range PMTiles) ──► app: MapLibre Native iOS + our S-52-inspired style + sprites
```

* **Reference implementations:**
  * **pelorus-nav** (MIT, active, App Store build): NOAA S-57 to vector tiles with GDAL, tippecanoe and PMTiles, rendered in MapLibre GL JS, claiming "proper S-52 symbology". **This is the closest blueprint.**
  * `Greenroom-Robotics/enc-mapbox-converter`: ogr2ogr to GeoJSON to tippecanoe, Dockerised. Licence not checked.
  * `manimaul/s57tiler` (Rust): a proof of concept "will not be developed further"; its successor is openenc.com.
* **Renderer:** MapLibre Native (BSD-2-Clause) is the natural choice for styled vector charts. MapKit can't style vector tiles. The app uses MapKit today (`BayMapView.swift`, `StationMapView.swift`), so plan a MapLibre chart view alongside it.
* **Symbology licensing (TRAP):**
  * OpenCPN's `s57data` (chartsymbols.xml, rastersymbols, colour tables) is **GPL-2.0+**. That is incompatible with App Store distribution of a closed-source app. Do not bundle it.
  * Draw our own sprite set from the IHO S-52 Presentation Library specification. The IHO publishes S-52 as a free download, but check its terms before copying symbol artwork.
  * Third-party symbol repos (e.g. erkswede/colors_and_symbols) need a licence check.
* **Correctness traps:**
  * SCAMIN handling.
  * Sounding precision and units (metres in NOAA ENCs).
  * Safety-contour selection (the S-52 conditional symbology procedures DEPARE/DEPCNT).
  * Lights sectors.
  * Overlapping cells of the same band.
  * Datum is WGS84; soundings are relative to chart datum (MLLW in US ENCs). TideKit can turn depth below datum into depth now, which is a differentiator.
* **Size:** the US S-57 set is 778 MB zipped. Vector tiles for the whole US to z16 are likely low single-digit GB (estimate, `UNVERIFIED`; measure on the first build). Region packs (state or district) keep downloads in the tens to low hundreds of MB.

### 4.2 Bathymetry

| Source | Resolution / coverage | Access | Licence | Use | Tier |
|---|---|---|---|---|---|
| **GEBCO_2025 Grid** | 15 arc-seconds (~450 m), global ocean + land; ice-surface and sub-ice versions + Type Identifier (TID) grid; annual release | gebco.net download: NetCDF, GeoTIFF, Esri ASCII; global file 7.5 GB (`DOC`) | **Public domain**, free; acknowledge the source and don't imply endorsement (`DOC`) | Global depth shading and planning contours. Pre-render a hillshade + depth-tint raster or quantised DEM tiles. | P0, **BEST** global |
| **NOAA BlueTopo / National Bathymetric Source** | Best available compiled bathymetry under US navigational waters; tile resolution varies by area (`UNVERIFIED` per-tile figures; see the BlueTopo spec) | AWS `s3://noaa-ocs-nationalbathymetry-pds/BlueTopo/` (`LIVE`, tile folders like `BC24C27G/`); download utility on GitHub; viewable in nowCOAST | NOAA OCS data dedicated to the public domain under **CC0** (`DOC`, data-licensing page) | High-res US depth layer and 3D/relief anchorage views. Updated weekly to monthly. | P1, **BEST** US |
| NOAA S-102 | S-100 bathymetric surface (HDF5) | AWS `noaa-s102-pds/ed3.0.0/` (`LIVE`) | Public domain | Future S-100 path. Same lineage as BlueTopo. | P2 |
| NCEI hydrographic surveys (BAG), multibeam archive, DEMs (CUDEM, Coastal Relief Model) | Survey resolution (sub-metre to ~100 m) | NCEI Bathymetric Data Viewer and archive (`DOC`) | Public domain | Source data. BlueTopo already compiles most of it. | P2 |
| **EMODnet Bathymetry DTM 2024** | 1/16 arc-minute (~115 m), all European seas; depths referenced to **LAT**; integrates GEBCO 2024, IBCAO 5, GMRT | WMS/WFS/WCS/WMTS + downloadable tiles (`DOC`) | **CC BY 4.0** by default; some originator data carry their own restrictions (`DOC`) | European depth layer | P1 (EU), **BEST** EU |
| CHS NONNA-10 / NONNA-100 | 10 m and 100 m, Canadian waters | CHS NONNA Data Portal: GeoTIFF, XYZ, CSAR, BAG (`DOC`) | OGL-Canada + NONNA licence; **free for non-navigational use** | Canadian depth shading, labelled non-navigational | P2 |
| Kartverket depth WMS, Traficom depth data | Norway, Finland | WMS / download | CC BY 4.0; "not a navigation product" | Planning layers | P2 |
| AusSeabed | Australia | Marine data portal | Bathymetry in the portal is openly licensed (`2ND`, likely CC BY 4.0) | Planning | P2 |
| **IHO DCDB crowdsourced bathymetry (CSB)** | Sparse soundings from volunteer vessels (100M+ points by IHO count, likely dated) | NCEI CSB Data Extract API (seamless collection); CSV/GeoJSON via the IHO DCDB Viewer (`DOC`) | DCDB intends release under **CC0** (`DOC`, stated as intent) | Read: gap-filling overlay. **Write:** the app could become a CSB contributor through an IHO "Trusted Node" (bathydata@iho.int), a strong community feature. | P2 |
| OpenSeaMap depth | Crowd-sourced shallow-water depths | depth.openseamap.org | Licence unclear (`UNVERIFIED`) | Avoid until the licence is clear. | — |
| Navionics SonarChart | Crowd-sourced HD bathymetry | Navionics SDK | Commercial | Comes with the Navionics route | P1 (paid) |

### 4.3 Aids to navigation and notices

#### 4.3.1 USCG NAVCEN MSI GeoJSON. P0, BEST

In late 2024 NAVCEN replaced the weekly LNM and Light List PDF/XML files with a geospatial
system. Legacy products stopped after 31 October 2024. The weekly XML and weekly Light
List correction files are gone. **This is a TRAP for any code built on the old XML.**

* **Base URL (`LIVE`):** `https://navcen.uscg.gov/sites/default/files/msi/<layer>.geojson`. `www.` redirects there.
* **Light List:** `lightListD01_1.geojson` … `lightListD17_2.geojson`, split by district and part. District 01 part 1 is 1.9 MB. Each aid has:
  * `LIGHT_LIST_NUMBER`, `NAME`, `AID_TYPE`, `LIGHT_CHAR` (e.g. "Fl R 4s"), `COLOR`, `STRUCTURE_REMARK`;
  * private/federal status, `MARKING_SYSTEM` (IALA B), `MODIFIED_DATE`, and an IALA MRN waterway identifier.
* **LNM layers** (each as point, line and polygon files):
  * `discFedAid_*`, `discPriAid_*` (discrepant federal and private aids, plus corrected variants);
  * `tmpChange_*`, `hazNav_*` (hazards, e.g. shoaling reports with depths), `safeZone*`, `bridge*`, `marEvent*`;
  * `navalAct*`, `marCon*` (marine construction), `msib*`, `autoVessel*`, `spaceOpsPoly_1`, `tessAdv*`;
  * `change_1`, `changeAdvNot_1`, `changeProp_1`;
  * `buoys_1…12` (Western Rivers).
* **Cadence:** NAVCEN's FAQ plans LNM every 15 minutes and Light List every 24 hours (`DOC`, stated as a plan). Use `MODIFIED_DATE` and HTTP ETags to diff.
* **API:** NAVCEN lists a REST API as "coming soon" (`DOC`). Not launched as of this research.
* **Caveats:**
  * Only notices with geometry appear.
  * A third party reports that the `safeZoneLine_1` layer isn't served (`2ND`).
  * Notices are now organised by waterway name rather than chart number.
* **Licence:** US government work, no restrictions. **Commercial OK, offline OK.**

#### 4.3.2 NGA Maritime Safety Information. P0, fragile

* **Provides:** NAVAREA IV and XII warnings (US-coordinated areas), HYDROLANT, HYDROPAC and HYDROARC, plus publications (Pub 117 radio aids, Sailing Directions, World Port Index, ASAM piracy reports).
* **Endpoints (`2ND`, from open-source clients):**
  * `https://msi.nga.mil/api/publications/broadcast-warn?output=json&status=active&navArea=4`
  * `.../api/publications/smaps?navArea=4&status=active&output=json`
* **Our probe:** both returned **HTTP 503 with an NGA "apology" page** from the sandbox. Expect bot, geo or cloud-IP filtering. Fetch from a US-hosted server, cache aggressively, and degrade gracefully.
* **Licence:** US government work.
* **Also useful:** the World Port Index (ports, facilities, depths) is good global POI seed data (`UNVERIFIED` current API).

#### 4.3.3 Other notices

* **USCG Broadcast Notices to Mariners (BNM):** HTML pages at `/broadcast-notice-to-mariners`. We found no feed. Many are mirrored as MSIBs, which do have GeoJSON. **P1 gap.**
* **NWS marine alerts:** the alerts API by marine zone (see 4.4) covers Special Marine Warnings, Small Craft Advisory, Gale and Storm warnings, and Dense Fog Advisory. P0.
* **Canada:** Notices to Mariners are published monthly as PDFs at notmar.gc.ca (East and West editions). CCG NAVWARNs are on regional web pages. **No machine-readable feed was found.** P2 gap. The scraping legality is untested, so ask DFO.
* **UK:** ADMIRALTY weekly Notices to Mariners (`UNVERIFIED` free PDF access). NAVTEX and NAVAREA I come through UKHO.
* **Finland (Digitraffic):** `https://meri.digitraffic.fi/api/aton/v1/faults` returns AtoN faults as GeoJSON (`LIVE`). It's a model of how this should work.
* **NAVTEX in general:** there's no single global feed. NAVTEX receivers on board can be read via NMEA 0183 (`$CRNRM` / `$CRNRX` sentences) through the AIS/NMEA integration (`UNVERIFIED` gateway support).

### 4.4 Marine weather

#### 4.4.1 NWS marine forecasts and zones. P0, BEST

| Product | Endpoint (all `LIVE` unless noted) | Notes |
|---|---|---|
| Zone forecast as JSON periods | `https://api.weather.gov/zones/forecast/ANZ338/forecast` returns `properties.periods[]` with `name` and `detailedForecast` ("W winds 10 to 15 kt … Waves around 2 ft. Wave Detail: W 1 ft at 2 seconds.") | Easiest integration. Marine zone IDs work on the forecast endpoint. |
| Zone geometry | `https://api.weather.gov/zones/marine/ANZ338` (GeoJSON polygon) | Point-in-polygon lookup. Bulk marine zone shapefiles come from NWS GIS (`DOC`). |
| Raw text products | `https://api.weather.gov/products/types/CWF/locations/OKX/latest`; also `OFF`, `NSH` (Great Lakes nearshore), `HSF`, `MWS`, `SMW` | Includes the full issuance, headlines and WMO header. |
| Flat files | `https://tgftp.nws.noaa.gov/data/forecasts/marine/coastal/an/anz338.txt`, `.../offshore/an/anz800.txt` (OPC offshore) | Tiny (1–2 KB) with an `Expires:` line. **Ideal for offline and low-bandwidth refresh.** |
| Alerts by zone | `https://api.weather.gov/alerts/active?zone=ANZ338` | Already used for points. |
| Gridded marine elements | `https://api.weather.gov/gridpoints/{wfo}/{x},{y}` includes `waveHeight`, `wavePeriod`, `waveDirection`, swell and wind-wave fields on coastal grid points (`DOC`, not probed) | NDFD coastal grids only. |
| OPC graphics and radiofax | `tgftp.nws.noaa.gov/fax/` and ocean.weather.gov | For offshore passage planning (P2). |

* **Auth:** none, but the **`User-Agent` with contact is mandatory**. TideKit already sends it.
* **Licence:** US government work. Commercial OK, redistribution OK.
* **Reliability:** generally high. Occasional 5xx on api.weather.gov, which is why the tgftp flat files make a good fallback.

#### 4.4.2 Observations. P0

* **NDBC (`LIVE`):**
  * `https://www.ndbc.noaa.gov/data/realtime2/{station}.txt`: 45 days of 10–60 min met and wave data (WDIR, WSPD, GST, WVHT, DPD, APD, MWD, PRES, ATMP, WTMP, DEWP, VIS, TIDE).
  * `https://www.ndbc.noaa.gov/data/latest_obs/latest_obs.txt`: all stations in about 100 KB. **One request for the whole map.**
  * `https://www.ndbc.noaa.gov/activestations.xml`: 1,357 stations with flags for met, currents, water quality and DART.
  * There's also `.spec` (wave spectral summary) and `.ocean` per station.
  * US government, unrestricted. **BEST**.
* **CDIP** (Scripps): directional wave spectra and nearshore wave models. THREDDS `https://thredds.cdip.ucsd.edu/thredds/` (`LIVE`). Licence terms not checked (`UNVERIFIED`). P1.
* **CO-OPS met:** wind, pressure and air/water temperature at tide stations, plus **air gap** and **visibility** (section 3). P0 via the existing client.
* **METAR:** `https://aviationweather.gov/api/data/metar?ids=KJFK&format=json` (`LIVE`) gives visibility, ceiling, wind and gusts at coastal airports. US government. P1 (fog).
* **IOOS ERDDAP** (`https://erddap.ioos.us/erddap/`, `LIVE`) aggregates regional association buoys that aren't in NDBC. P2.

#### 4.4.3 GRIB / numerical weather prediction sources

| Model | Resolution / range | Access | Licence | Notes | Tier |
|---|---|---|---|---|---|
| **GFS** | 0.25°, 16 days, 4 runs a day | AWS `noaa-gfs-bdp-pds` (`LIVE`); NOMADS | US gov | Baseline global wind and pressure. | P0 |
| **GFS-Wave** (WAVEWATCH III) | Global 0.25° and 0.16°, plus regional grids (e.g. `gfswave.t12z.arctic.9km`) | Same AWS bucket under `gfs.YYYYMMDD/HH/wave/gridded/` (`LIVE`) | US gov | Replaced the standalone WW3 multi-grid products. | P0 |
| **ECMWF IFS HRES/ENS, AIFS, WAM** | IFS 0.25° (0.1° added from 20 Oct 2026 per ECMWF). 00/12z to 360 h (3-hourly to 144 h); 06/18z to 144 h; AIFS 4×/day, 6-hourly to 360 h. Wave streams `wave`/`waef`. | `https://data.ecmwf.int/forecasts/` (`LIVE`) + AWS/Azure/GCP mirrors; `ecmwf-opendata` Python client | **CC BY 4.0, commercial use and redistribution allowed** with attribution (`DOC`); the whole real-time catalogue moved to CC BY 4.0 with no information cost in Oct 2025, but the free feed is still a subset | 500–2,000 simultaneous connections; rolling archive of the **last 12 runs only**, so archive what we need ourselves. | P0, **BEST** |
| HRRR | 3 km CONUS, hourly, 18–48 h | AWS `noaa-hrrr-bdp-pds` (`LIVE`) | US gov | Gusts, visibility and squalls near the coast. | P1 |
| NBM (National Blend of Models) | 2.5 km CONUS + OCONUS | AWS `noaa-nbm-grib2-pds` (`LIVE`) | US gov | Calibrated wind, gust, visibility and probabilities. | P1 |
| NAM | 12 km / 3 km nests | NOMADS | US gov | Legacy. NCEP is moving regional modelling to RRFS (`UNVERIFIED` status). | P2 |
| DWD ICON (global ~13 km, ICON-EU ~6.5 km, ICON-D2 ~2.2 km; resolutions approximate) + EWAM (0.05° Europe) / GWAM (0.25°) | `opendata.dwd.de` GRIB2, no registration (`DOC`) | **CC BY 4.0** with DWD acknowledgement (`DOC`, DWD legal notice). The ICON *model software* licence is non-commercial, but that covers the code, not DWD's published open data. | Best free European short-range model. | P1 |
| Météo-France AROME (0.01°/0.025°) / ARPEGE (0.1°/0.25°) | data.gouv.fr packages; AWS registry; portail-api.meteofrance.fr (`2ND`) | Licence Ouverte / Open Licence 2.0 | Mediterranean and Channel sailing. | P2 |
| ECCC HRDPS / GDPS / RDPS | `https://dd.weather.gc.ca/` (`LIVE`) | ECCC Data Server End-use Licence v2.1: worldwide, royalty-free, **commercial OK** with attribution ("Contains information licenced under the Data Server End-use Licence of Environment and Climate Change Canada.") | Canada | P1 (Canada) |
| UK Met Office | Weather DataHub | Free and paid tiers (`UNVERIFIED`) | UK waters | P2 |
| NOMADS GRIB filter | Server-side subsetting | `nomads.ncep.noaa.gov` | US gov | **TRAP for clients:** about 120 hits/min per IP, summed across NOMADS sites, with escalating firewall blocks (20 s → 1 min → 8 min → a day → "forever"); spreading load across IPs is explicitly discouraged (`2ND`, 2021 notice). Use AWS from our server instead. | P1 (server only) |

**Strategy:** the GRIB slicer (section 2.2) produces compact regional tiles. Users who want raw
GRIB for routing software can export the same subsets.

#### 4.4.4 Ocean currents

| Source | Coverage / resolution | Access | Licence | Tier |
|---|---|---|---|---|
| **CO-OPS current predictions** | Harmonic current stations in US estuaries | Existing CO-OPS client (`currents_predictions`) | US gov | P0 |
| **NOAA OFS** (CBOFS, CIOFS, DBOFS, GoMOFS, LEOFS, LMHOFS, LOOFS, LSOFS, NGOFS2, SFBOFS, SSCOFS, TBOFS, WCOFS) | Model native grids (tens of metres to km), 4 runs a day, 48–120 h | AWS `noaa-nos-ofs-pds`; actual layout `sfbofs/netcdf/2026/11/14/` (`LIVE`), which differs from the README's `OFS/netcdf/YYYYMM/`; `noaa-ofs-pds` has the last 30 days of NOMADS copies; THREDDS for 31 days | US gov | P1, **BEST** US harbours |
| **S-111 surface currents** | Same OFS + RTOFS, 4.5 m depth, regular-grid tiles | AWS `noaa-s111-pds` (`LIVE`) | US gov | P1. Easier to consume than raw OFS NetCDF. |
| NOAA RTOFS (global HYCOM-based) | 1/12°, 41 levels, to 192 h | AWS `noaa-nws-rtofs-pds` (`LIVE`, retention back to Jan 2024); NOMADS | US gov | P1 |
| **Copernicus Marine** global physics / waves / regional seas | Global 1/12°, 10-day; regional down to ~1.5 km | `copernicusmarine` toolbox (ARCO Zarr / subset), free registration | Free to use for research **and commercial** applications; cite "E.U. Copernicus Marine Service Information" + product DOI; when redistributing, credit "European Union, Copernicus Marine Service Information or Data (year), ©Mercator Ocean" (`DOC`, help centre) | P1, **BEST** global |
| HYCOM / Navy ESPC | 1/12° (ESPC-D deterministic, served on the 1/12° grid) | hycom.org THREDDS. **GOFS 3.1 analysis decommissioned 4 Sep 2024** (`2ND`). | US gov | P2. Research server with no SLA. Prefer RTOFS or Copernicus. |
| IOOS HF radar (HFRNet) | Hourly surface currents, 1–6 km, US coasts | THREDDS (`hfrnet-tds.ucsd.edu`, connection reset from our sandbox) | US gov | P2 |
| Open-Meteo (MeteoFrance SMOC currents) | 0.08° | Marine API | CC BY 4.0 data, paid API for commercial use | P0 (point, via the existing client) |

#### 4.4.5 Commercial marine forecast APIs

| Provider | Offer | Price / limits (as found) | Licence notes | Verdict |
|---|---|---|---|---|
| **Open-Meteo** | Forecast + **Marine API**: wave height, direction and period; wind-wave and swell (up to tertiary on GFS); ocean current velocity; SST; sea level incl. tides (MSL datum). Models: MeteoFrance MFWAM 0.08°, ECMWF WAM 9 km, GFS-Wave 0.25°/0.16°, DWD EWAM/GWAM, ERA5-Ocean (`DOC`). | Free: non-commercial only, 10,000 calls/day, 5,000/h, 600/min, 300k/month. Commercial: Standard 1M calls/month, Professional 5M, Enterprise 50M+; prices not on the page. Server code is open source (**AGPLv3**) for self-hosting. | Data **CC BY 4.0**. The docs warn the marine data are "not suitable for coastal navigation and does not replace your nautical almanac". | P0 with a commercial plan. Self-hosting is an option at scale (AGPL applies to the server, not to our app). |
| Stormglass | Point weather/marine | Free 10 req/day (non-commercial); Small €19/mo (500/day); Medium €49 (5,000/day, commercial); Large €129 (25,000/day) (`DOC`) | Caching terms not stated | P2 |
| **Windy API** | Point Forecast, Map Forecast, Webcams | Point Forecast Professional **€990/yr, 10,000 req/day**; the free trial key returns "shuffled and slightly modified" data, dev only; **Professional excludes the ECMWF model**; 3-hourly steps (`2ND`, Windy pricing page and staff forum posts) | — | **TRAP** if you expect ECMWF. Map Forecast API (embedded map) is a separate product. |
| PredictWind | PWG/PWE proprietary models, routing | **No public API**; "on the development list" (`DOC`, help centre). DataHub is on-board hardware, not a developer API. | — | Gap |
| Xweather (Vaisala) | Weather API incl. lightning | Pay-as-you-go (US/Canada) or custom | Commercial | P2 for lightning |
| MetService / MetOcean (NZ) | Point Forecast API incl. marine | Paid (`2ND`) | Commercial | P2 (NZ/Pacific) |
| Tomorrow.io, Meteomatics, Spire Weather | Point / gridded APIs | Not researched in depth (`UNVERIFIED`) | — | P2 |
| **Saildocs** | GRIB and NWS text by e-mail (`query@saildocs.com`), GFS (+ others), designed for satellite and HF links | Free; funded by SailMail (`2ND`, current status not confirmed) | Personal use | P2: have the app compose Saildocs requests for offshore users on Iridium/Starlink-limited plans. |

### 4.5 Waves, SST, visibility/fog, lightning

**Waves:**
* P0: NDBC (observations), GFS-Wave and ECMWF WAM (gridded), Open-Meteo Marine (point), NWS gridpoint wave fields (US coastal).
* P1: Copernicus Marine global waves (MFWAM) and CDIP spectra.
* No new licensing issues beyond those above.

**Sea-surface temperature:**
* NOAA CoastWatch ERDDAP serves MUR SST (JPL, 0.01°, daily) at `https://coastwatch.pfeg.noaa.gov/erddap/griddap/jplMURSST41` (`LIVE`). Use griddap subsetting to PNG or NetCDF.
* Alternatives: NOAA OISST (0.25°), Copernicus Marine SST, and Open-Meteo `sea_surface_temperature`.
* All free for commercial use (US gov / Copernicus). P1.

**Visibility and fog** (no single good source; see gaps):

| Source | What it gives | Tier |
|---|---|---|
| CO-OPS visibility sensors (23, `LIVE`) | Measured visibility in Narragansett Bay, Chesapeake Bay and similar ports | P1 |
| METAR (`LIVE`) | Airport visibility, often coastal | P1 |
| NWS "Dense Fog Advisory" (marine) via alerts | Official warning | P0 |
| HRRR / NBM visibility fields (AWS) | Gridded forecast visibility | P1 |
| Open-Meteo `visibility` (hourly variable on the forecast API) | Point forecast | P1 |
| NDBC `VIS` column | Rarely populated | — |
| GOES fog / low-stratus satellite products | Satellite fog detection (`UNVERIFIED` distribution) | P2 |

**Lightning:**

| Source | Coverage | Latency | Access | Licence | Tier |
|---|---|---|---|---|---|
| **GOES-19 (East) / GOES-18 (West) GLM** | Total lightning (in-cloud + ground) over the Americas and adjacent oceans (~±50° lat) | Files every 20 s; third party claims 30–60 s to S3 (`2ND`) | AWS `noaa-goes19/GLM-L2-LCFA/YYYY/DDD/HH/*.nc` (`LIVE`) | US gov, public | P1, **BEST** free |
| nowCOAST lightning strike density (OPC, 15 min, ground-based) | US / OPC areas | 15 min | WMS `observations/lightning_detection` (`2ND`, restored in 2024) | US gov | P2 (display only) |
| EUMETSAT MTG Lightning Imager | Europe, Africa, Atlantic | Near real time | EUMETSAT Data Store | EUMETSAT data policy (`UNVERIFIED`) | P2 (fills the GLM gap for Europe) |
| Blitzortung.org | Global ground strikes (volunteer) | Seconds | **No public API**; raw data only for participants | Licence says CC BY-SA 4.0, but the project prohibits commercial use and safety-of-life use | **TRAP** |
| Xweather (Vaisala GLD360) / AEM Earth Networks ENTLN | Global ground lightning | Seconds | Paid API | Commercial | P2 (paid) |

**Radar** (squall awareness near US coasts): NEXRAD Level II, `s3://unidata-nexrad-level2/YYYY/MM/DD/KOKX/` (`LIVE`), and MRMS mosaics in `noaa-mrms-pds` (`LIVE`). Both US government. Render on the server; don't decode Level II on the phone. P1.

### 4.6 AIS

#### 4.6.1 On-board AIS and instruments. P0, BEST

This is the most valuable AIS source. It needs no licence, costs nothing per user and works offshore.

* **NMEA 0183 over Wi-Fi:** most AIS transponders and multiplexers stream `!AIVDM` / `!AIVDO` plus GPS, depth, wind and heading sentences over TCP or UDP. Port 10110 is common, 2000 on some devices (`UNVERIFIED` per device). Examples: Digital Yacht iAIS/WLN, Vesper Cortex, em-trak, Quark-elec. AIS message decoding follows ITU-R M.1371, which is freely published.
* **NMEA 2000 gateways:**
  * Yacht Devices YDWG-02 (RAW and NMEA 0183 conversion over TCP/UDP);
  * Actisense W2K-1 (N2K ASCII/RAW and 0183);
  * Digital Yacht, Raymarine and other vendor gateways.
  * **Licensing:** the NMEA 2000 standard is copyrighted and only NMEA members get it. The open PGN database **canboat is GPL-3.0**, so it can't be linked into an App Store app; use it only as a reference, or rely on gateways' 0183 conversion. The "NMEA 2000®" trademark is reserved for certified products. Get legal review before shipping native PGN decoding.
* **Signal K:**
  * Default server port 3000.
  * REST under `/signalk/v1/api`; v2 REST APIs under `/signalk/v2/api`; streaming WebSocket at `/signalk/v1/stream?subscribe=self&format=delta`.
  * mDNS discovery `_signalk-ws._tcp` and `_signalk-http._tcp` (`DOC`).
  * Already common on Raspberry Pi / OpenPlotter boats; Victron Cerbo GX also ships it (`UNVERIFIED`).
  * Supporting Signal K gives one integration that covers dozens of instrument brands.
* **iOS specifics:**
  * Needs `NSLocalNetworkUsageDescription` plus `NSBonjourServices` (`_signalk-ws._tcp`, `_signalk-http._tcp`) for the Local Network permission.
  * Background socket reading is limited. An anchor alarm needs a background-location design rather than a background socket.

#### 4.6.2 Internet AIS

| Source | Coverage | Access | Terms | Tier |
|---|---|---|---|---|
| **aisstream.io** | Global terrestrial (volunteer receivers; coverage not documented) | `wss://stream.aisstream.io/v0/stream`. Send `{APIKey, BoundingBoxes, FiltersShipMMSI?, FilterMessageTypes?}` within 3 s. 25 message types incl. AtoN reports (`DOC`). | Free. **3 connections per account and 3 per IP**; at most one subscription update per second; **no SLA, no replay**; "Direct browser connections are not permitted", so connect from your own server; per-user bandwidth limits on uncompressed connections from Sep 2026. No explicit commercial-use clause found. | P1 via relay |
| AISHub | Global volunteer pool | REST, **1 request per minute** | You must feed your own station (≥ 10 vessels, ≥ 90 % uptime over 7 days). Commercial products allowed with "Data: AISHub contributors" credit; **you may not pass raw data on**; not for navigation (`DOC`). | P2 |
| Digitraffic Marine (Finland) | Finland / Baltic | `https://meri.digitraffic.fi/api/ais/v1/locations` GeoJSON (`LIVE`), plus MQTT; send a `Digitraffic-User` header | Open data (CC BY 4.0, `UNVERIFIED`) | P2 |
| Kystverket (Norway) | Norwegian coast | Raw IEC 62320-1 / NMEA over TCP `153.44.253.27:5631` (`DOC`; our sandbox couldn't open raw TCP); download service at ais-public.kystverket.no | NLOD, free, no registration | P2 |
| MarineCadastre (US historical) | US waters | Daily broadcast points 2024 and monthly tracks 2024–2025 as **GeoParquet** (Azure), older CSV/GDB (`DOC`) | **CC0**; "not for navigation" | P2 (traffic heatmaps) |
| MarineTraffic / Kpler | Global incl. satellite | Credit-metered APIs, sales-quoted; Kpler packaging (`2ND`) | Commercial, expensive | P2 (only for a premium tier) |
| Spire Maritime (reportedly now part of Kpler), VesselFinder, Datalastic | Global | Paid APIs (`UNVERIFIED` pricing) | Commercial | P2 |
| Global Fishing Watch | Fishing activity | REST | **CC BY-NC 4.0, no commercial licence offered** | **TRAP** |

**Satellite AIS** (essential mid-ocean) is **paid only**. See gaps.

### 4.7 Points of interest

| Source | Content | Coverage | Access | Licence | Tier |
|---|---|---|---|---|---|
| **ENC features** | ACHARE (anchorage areas), HRBFAC/SMCFAC (harbour/small-craft facilities, `UNVERIFIED` attribute completeness), BRIDGE (with **VERCLR/HORCLR** clearances), LOKBSN (locks), PILBOP, fuel (rare) | US | From our ENC pipeline | Public | P0 |
| **OSM** (`leisure=marina`, `seamark:type=harbour/anchorage/...`, `amenity=fuel` + `boat=yes`, `waterway=fuel`, `amenity=sanitary_dump_station`) | Marinas, fuel, pump-outs (sparse), slipways | Global, uneven | Geofabrik extracts (preferred); the public Overpass instance only for light use, with per-IP limits and 429s; the wiki's rule of thumb is under ~100 queries/day and 10 MB for regular use | ODbL | P0 |
| **Garmin ActiveCaptain Community API** | Marinas, anchorages, hazards, reviews, photos; users can contribute back | Global, densest in North America | Request access via developer.garmin.com/active-captain; docs, test environment and toolkit after approval (`DOC`) | APIs "are free"; caching, attribution and competitor terms only visible after approval | **P0: apply immediately**, **BEST** |
| **Waterway Guide** (with Waggoner for the Pacific Northwest) | Marinas, anchorages, bridges, locks, **fuel prices**, services, reviews | US East/Gulf coasts, ICW, Great Loop, Bahamas; expanding globally | REST API v2 with a secret token (`DOC`); partners include AquaMap, Savvy Navvy, Raymarine LightHouse, iNavX; BoatUS towing ports added Mar 2026 | Commercial licence, pricing not public | P1, **BEST** curated US |
| NOAA Coast Pilot | Sailing directions, anchorages, bridge and cable clearances | US | PDF chapters (`DOC`) | US gov | P1 (searchable text) |
| NGA World Port Index | Port facilities and depths | Global | NGA MSI (`UNVERIFIED` API) | US gov | P2 |
| NAVCEN LNM bridge layer | Bridge openings, closures, works | US | `bridge_1/bridgeLine_1/bridgePoly_1.geojson` (`LIVE` base URL) | US gov | P0 |
| CO-OPS air gap | **Live** clearance under 21 major bridges | US | CO-OPS API (`LIVE`) | US gov | P1 |
| FHWA National Bridge Inventory | Navigation vertical/horizontal clearance items for bridges over navigable water | US | Annual download (`UNVERIFIED` field coverage) | US gov | P2 |
| USACE / EuRIS locks | Lock locations, status, operating times | US inland / EU | See 4.9 | Public | P1 |
| Marinas.com | Marinas | — | **API deprecated, removed 1 Sep 2024.** Old terms forbade commercial use without an enterprise licence and capped caching at 30 days. | — | **TRAP** (dead) |
| Navily | Mediterranean anchorages and marinas, reviews | Europe | **No API or licensing programme found** | — | Gap |
| Noforeignland | Cruiser-curated places, boat tracking | Global | Only a boat-tracking API key (write); no read API documented | — | Gap; a partnership is possible |
| Dockwa, Snag-A-Slip (marina booking) | Reservations | US | Partner programmes (`UNVERIFIED`) | Commercial | P2 |
| Pump-outs | Clean Vessel Act pump-out stations | US | **No national open dataset found.** State GIS layers (e.g. FWC) and apps compile them separately. | Varies | Gap |
| Fuel prices | Marine fuel prices | — | Only Waterway Guide / ActiveCaptain user reports | Commercial | Gap |

### 4.8 Regulatory and hazard data

| Source | Content | Coverage | Access | Licence | Tier |
|---|---|---|---|---|---|
| **ENC regulatory features** | RESARE (restricted areas), MIPARE (military practice), CTNARE (caution), TSSLPT/TSEZNE (traffic separation), CBLARE/PIPARE (cables, pipelines), MARCUL, DMPGRD, WRECKS/OBSTRN/UWTROC | US | Our ENC pipeline | Public | P0 |
| NAVCEN safety zones, naval activity, marine events | Temporary regulated areas | US | GeoJSON (`LIVE` base) | US gov | P0 |
| MarineCadastre "Danger Zones and Restricted Areas" (33 CFR 334) | Military danger zones and restricted areas | US | `https://marinecadastre.gov/downloads/data/mc/DangerZoneRestrictedArea.zip` + feature service at coast.noaa.gov (`DOC`); updated May 2025; accuracy "untested". Also "Regulated Navigation Areas". | US gov | P1 |
| NOAA MPA Inventory | US marine protected areas incl. sanctuaries and fishing closures | US | MPA Center download (`DOC`) | Public domain; not for navigation | P1 |
| National Marine Sanctuaries boundaries | Sanctuary rules (e.g. Florida Keys no-anchor zones) | US | NOAA ONMS GIS (`UNVERIFIED` URL) | US gov | P1 |
| **Right whale speed rule** | Seasonal Management Areas, 10-knot limit for vessels ≥ 65 ft | US East Coast | **50 CFR 224.105 (2008 rule) remains in effect.** The 2022 expansion proposal was withdrawn (Jan 2025 Federal Register). An ANPRM on 4 Mar 2026 is considering replacing seasonal limits with detection technology. Litigation is pending. Dynamic Management Areas / Slow Zones are voluntary and published ad hoc by NOAA Fisheries. | US gov | P1: encode the SMA polygons from the CFR and show advisory DMAs; **watch rulemaking**. |
| **Florida manatee protection zones** | Idle, slow-speed and no-entry zones (FAC 68C-22); boating restricted areas (68D-24) are a separate layer | Florida | ArcGIS REST `gis.myfwc.com/hosting/rest/services/Open_Data/State_Manatee_Protection_Zones_in_Florida/MapServer` (`DOC`) | State open data; "the descriptions in the FAC shall prevail"; county and federal zones differ | P1 |
| Canada: whale speed restrictions (Gulf of St Lawrence, Salish Sea) | Seasonal and dynamic slowdowns | Canada | Transport Canada notices (`UNVERIFIED` data format) | Crown | P2 |
| Protected Planet WDPA | Global protected areas | Global | Download / API | **No commercial use, no redistribution**; commercial users must go through IBAT | **TRAP** |
| Marine Regions (VLIZ) | EEZs, territorial seas | Global | Download/WFS | Open (CC BY 4.0, `UNVERIFIED`) | P2 (borders and clearance-in prompts) |
| **Wrecks** | NOAA Wrecks & Obstructions database (≈13,000 wrecks, 6,000 obstructions), merging AWOIS (**frozen since 2016**) and ENC wrecks | US | KML/XLS + ArcGIS REST at `wrecks.nauticalcharts.noaa.gov` (TLS certificate mismatch from our sandbox) (`DOC`) | US gov; not for navigation, not comprehensive | P1. Use ENC WRECKS for navigation and AWOIS for dive and fishing context. |
| **US National Ice Center** | Sea ice charts (SIGRID-3 shapefiles), Arctic/Antarctic; Great Lakes products (`UNVERIFIED`) | Polar, Great Lakes | usicecenter.gov; archive at NSIDC G10013 (2003–present) | US gov | P2 |
| **Canadian Ice Service** | Regional ice charts, SIGRID-3, weekly in summer (more often operationally) | Canadian Arctic, Hudson Bay, East Coast, **Great Lakes** | Operational: `ice-glaces.ec.gc.ca/prods/sigrids/`; archive NSIDC G02171 | ECCC open (`UNVERIFIED` exact licence) | P2 |
| Copernicus Marine sea ice | Concentration, thickness | Global | Toolbox | As Copernicus | P2 |

### 4.9 Inland waterways

| Source | Content | Coverage | Access | Licence | Tier |
|---|---|---|---|---|---|
| **USACE Inland ENCs (IENC)** | S-57 inland charts: channels, locks, bridges, river miles | Mississippi, Ohio, Tennessee, Illinois, GIWW, … | `ienccloud.us` (`LIVE`) | US gov | P1 (same pipeline as NOAA ENC) |
| **USACE CWMS Data API** | River stages, flows, reservoir pools, **lock data**, ratings | Corps districts | `https://cwms-data.usace.army.mil/cwms-data/` (e.g. `/offices`, `LIVE`); Swagger UI; public reads need no key | US gov | P1 |
| USACE Corps Locks / LPMS | Lock status, queue (past 24 h), tonnage, traffic; half-hourly snapshots | US inland | corpslocks.usace.army.mil (proxy 502 from our sandbox); XML web services (`2ND`) | US gov | P1 |
| **USGS Water Data APIs (OGC)** | Instantaneous and daily gauge values | US | `https://api.waterdata.usgs.gov/ogcapi/v0/collections` (`LIVE`; collections include `latest-continuous`) | US gov | P1 |
| USGS waterservices.usgs.gov | Legacy NWIS IV/DV | US | **Decommissioning 22 Feb 2027, degradation from Nov 2026, outages Jan 2027** (`DOC`, USGS bulletin and blog) | — | **TRAP**: don't build on it |
| NWS NWPS river forecasts | Forecast stages, flood categories | US | `api.water.noaa.gov/nwps/v1/gauges` (already integrated for coastal gauges) | US gov | P1 |
| **EuRIS** | European inland fairway information: notices, locks and bridges, operating times, water levels, IENC viewing; new portal version 9 Dec 2025 | EU inland network | Portal + APIs; "All provided API's of EuRIS are treated free of charge as Open Data (except for GDPR protected data)", and commercial parties may retrieve data (`DOC`) | Open data | P2, **BEST** EU inland |
| German IENCs (WSV/ELWIS) | Inland ENCs | German federal waterways | ELWIS download / ATOM feed (`DOC`) | Free | P2 |
| **PEGELONLINE** (WSV) | Water levels on German federal waterways | Germany | `https://www.pegelonline.wsv.de/webservices/rest-api/v2/stations.json` (`LIVE`) | Open (`UNVERIFIED` exact licence, believed DL-DE Zero) | P2 |
| Rijkswaterstaat water data | Water levels, discharge, currents | Netherlands | Old docs say "maintenance of this page is discontinued"; the new host `ddapi20-waterwebservices.rijkswaterstaat.nl` answers (POST API, `LIVE`); legacy `waterwebservices.rijkswaterstaat.nl` | Free (`DOC`) | P2 |
| ECCC Water Office (hydrometric) | Real-time gauges | Canada | MSC Datamart / GeoMet OGC API (`UNVERIFIED` paths) | ECCC licence | P2 |
| France Vigicrues / VNF | Water levels, fairway notices | France | `UNVERIFIED` | — | P2 |

### 4.10 Celestial, astronomical and magnetic data

| Need | Recommendation | Licence | Tier |
|---|---|---|---|
| Sunrise, sunset, civil/nautical twilight, moonrise, moon phase | **On-device**: TideKit `Ephemeris` (truncated Meeus, Sun good, Moon ~0.1°), already pinned to JPL Horizons. Accurate enough for rise/set times. | Own code | P0 |
| Celestial navigation (GHA/Dec of Sun, Moon, planets, 57 stars; Hc/Zn sight reduction) | **0.1′ accuracy needed, ~60× better than the current Moon model.** Use JPL DE440 (public domain) or NOVAS (USNO, public domain) or ERFA (BSD) on the device. Star positions from Hipparcos / Yale Bright Star Catalogue. Don't copy *The Nautical Almanac* tables (UKHO/HMNAO copyright); compute them. | Public domain / BSD | P1 |
| Online cross-check | **USNO Astronomical Applications API v4.0.1** (`LIVE`): `https://aa.usno.navy.mil/api/rstt/oneday?date=2026-11-14&coords=40.70,-74.01&tz=-5` and `https://aa.usno.navy.mil/api/celnav?date=...&time=12:00&coords=...` return GHA, Dec, Hc, Zn and altitude corrections. Use it for **test fixtures**, not runtime. | US gov | P1 (tests) |
| Swiss Ephemeris | Don't use: AGPL or a paid commercial licence. | **TRAP** | — |
| **Magnetic declination** | **WMM2025** (released 17 Dec 2024, valid 2025–2030; 336 coefficients, ~5 KB; ~3,300 km resolution at the equator). Optionally **WMMHR2025** (degree 133, ~18,210 coefficients, ~534 KB, ~300 km), which better captures crustal anomalies near coasts. Compute on the device; the format is simple. Plan a 2030 update; NCEI issues out-of-cycle updates if the field drifts. | **Public domain** (NOAA/NGA/BGS) | P0, **BEST** |
| NOAA geomag web calculator | Requires a free API key (`LIVE` error message). Unneeded given on-device WMM. | US gov | — |

### 4.11 Satellite imagery for anchorage scouting

| Source | Resolution / revisit | Access | Licence | Offline | Tier |
|---|---|---|---|---|---|
| Apple MapKit satellite | High-res, global | Already in the app | Free within MapKit | **No**: no prefetching or caching (`UNVERIFIED` exact clause) | P0 (online) |
| **USGS NAIP Plus / USGS Imagery Only** | ~0.6–1 m aerial (NAIP plus higher-res orthoimagery), US, refreshed on a 2–3 year cycle | `https://imagery.nationalmap.gov/arcgis/rest/services/USGSNAIPPlus/ImageServer` and `https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer` (tile cache to ~1:9,028) (`LIVE`) | US gov, **public domain** | **Yes**: pre-render anchorage packs | P1, **BEST** US |
| **Sentinel-2 L2A** | 10 m, ~5-day revisit, global coast | AWS `sentinel-cogs` COGs + Element84 Earth Search STAC (`https://earth-search.aws.element84.com/v1`, `LIVE`) | Copernicus open licence: free incl. commercial; attribution "Contains modified Copernicus Sentinel data [year]" | **Yes** | P1, **BEST** global free. Recent imagery shows new shoals, moorings and reef colour; pick the least-cloudy recent scene per anchorage on the server. |
| Landsat 8/9 | 30 m | AWS / USGS | Public domain | Yes | P2 |
| NOAA Emergency Response Imagery | ~0.3–0.5 m post-storm | NOAA NGS (`UNVERIFIED` endpoint) | US gov | Yes | P2 (post-hurricane harbour checks) |
| EOX Sentinel-2 cloudless | 10 m annual mosaic | maps.eox.at | 2016 layer CC BY 4.0; **2018–2025 layers CC BY-NC-SA 4.0**; commercial use needs an EOX "Commercial Attribution-RestrictedUse 1.2" licence | — | **TRAP** (unless licensed) |
| Esri World Imagery | Sub-metre | ArcGIS | Requires an ArcGIS licence. The standard layer isn't for export; "World Imagery (for Export)" is limited to ArcGIS apps/SDKs and blocks exports over 100k tiles. Gaia GPS disabled offline Esri imagery on 1 Jan 2025 after an Esri policy change (`2ND`). | Effectively no | **TRAP** |
| Mapbox Satellite | Sub-metre | Mapbox Maps SDK | Paid (raster tile requests); offline only through the SDK, downloaded from Mapbox servers; **no preloading or bundling**; v11 caps 750 tile packs | SDK-managed | P2 (if we adopt Mapbox) |
| Google Maps tiles | — | — | No offline caching | No | **TRAP** |
| Maxar/Vantor, Planet, Airbus | 0.3–3 m, tasking | Commercial | Paid | Per contract | P2 (premium) |

---

## 5. Offline and caching strategy

A navigation app must work with no connection, and boats lose signal a few miles out.
Licensing decides what we may pre-package.

### 5.1 What may be cached or redistributed

| Class | Sources | May we pre-package and serve it from our CDN? | Device cache |
|---|---|---|---|
| **US federal data** | NOAA ENC, NCDS, BlueTopo, S-10x, NAVCEN, NWS, NDBC, CO-OPS, GFS/HRRR/NBM/RTOFS/OFS, GLM, NEXRAD, USGS, USACE, WMM, NAIP | **Yes.** ENC copies we redistribute are "not official", so label them and show the cell edition. | Unlimited |
| **Open licences with attribution** | ECMWF (CC BY 4.0), DWD (CC BY 4.0), EMODnet (CC BY 4.0), Copernicus Marine and Sentinel (Copernicus licences), Open-Meteo *data* (CC BY 4.0), ECCC, Traficom, Kartverket, GEBCO (public domain), Météo-France (Licence Ouverte) | **Yes, with attribution** shown in-app (an attributions screen plus on-map credit where a layer is visible) | Unlimited |
| **Share-alike** | OSM / OpenSeaMap (ODbL data; CC BY-SA tiles) | Yes. Derived databases we *publish* must stay ODbL, so keep OSM POI in their own store. | Unlimited |
| **API-terms governed** | Open-Meteo *API*, ActiveCaptain, Waterway Guide, aisstream.io, AISHub, Stormglass, Windy, Navionics SDK, Mapbox | **Only as each contract allows.** Assume no bulk pre-packaging until the terms say so. Marinas.com (now dead) capped caching at 30 days; expect similar clauses. | Per terms |
| **Non-commercial / prohibited** | WDPA, Global Fishing Watch, Blitzortung, EOX cloudless 2018+, Brazil raster charts, BOM free text, Esri imagery offline, Google tiles | **No** | No |

### 5.2 Package design

Offline content comes as **region packs** (e.g. "Chesapeake Bay", "Florida Keys",
"Puget Sound"). One pack holds:

1. **Chart vector tiles**: MBTiles/PMTiles built from ENC, z0–16 inside the pack bounds, with lower zooms for context. Store the ENC cell list with edition and update numbers inside the pack. The app shows "Charts current to <date>, cells US5MD1AM ed.12 upd.3 …". Daily delta packs come from NOAA's `OneDay_ENCs.zip`, so updates are small. The ENC agreement makes keeping charts current the user's responsibility, so surface staleness prominently (warn at >7 days, alarm at >30).
2. **Raster fallback**: NCDS MBTiles for the same region (optional download, made for offline by NOAA).
3. **Depth**: GEBCO for overview zooms; BlueTopo or EMODnet as quantised DEM tiles inside the pack.
4. **Seamarks and POI**: OSM-derived vector layer (ODbL attribution) plus ActiveCaptain and Waterway Guide snapshots **only if their terms allow it**.
5. **Notices**: the NAVCEN layers clipped to the pack, refreshed whenever online (15-min TTL). Offline, show the age next to every notice. **Never present stale notices as current.**
6. **Weather**: last-downloaded GRIB tiles (GFS/ECMWF wind, waves, currents) for the pack region and passage corridor, 5–10 days at 3-hourly steps, with the model run time. NWS text forecasts from tgftp (1–2 KB each) with their `Expires:` line respected.
7. **Tides and currents**: TideKit's harmonic constants for the pack's stations, which never expire within a year (the node factors are annual). Tide and current predictions work fully offline, a key advantage over competitors that fetch tide tables online.
8. **Imagery** (optional): Sentinel-2 / NAIP tiles around chosen anchorages only. They're too big for whole regions at high zoom.
9. **Astro and magnetic data**: computed on the device (WMM coefficients and ephemeris in the app bundle).

### 5.3 Freshness rules (extending `RefreshPolicy`)

| Data | TTL online | Offline behaviour |
|---|---|---|
| NAVCEN LNM / safety zones / NGA warnings | 15 min | Show age; flag safety zones as "may have changed" after 24 h |
| NWS marine forecast text | Until `Expires:` (usually ≤ 12 h) | Show issuance time; grey out after expiry |
| NWS alerts | 5 min (current setting: 300 s) | Show "alerts unavailable offline" rather than "no alerts" |
| NDBC latest_obs | 10 min | Hide observations older than 2 h |
| GRIB tiles | New run every 6 h (GFS/ECMWF) | Use until the end of the forecast range; show run age |
| Light List | 24 h | Days-old data is fine for characteristics |
| ENC tiles | Daily delta check | Staleness warning > 7 days |
| BlueTopo / GEBCO | Monthly / yearly | Static |
| AIS internet | Streaming | Hide targets older than 3 min (Class A) / 10 min (Class B) |

### 5.4 Storage, bandwidth and infrastructure

* **Measure** the US vector tile build size before committing to "download all US". All NOAA ENCs are 778 MB zipped as S-57. Region packs should target ≤ 200 MB each.
* Serve PMTiles from object storage. Byte-range requests let the phone fetch only the tiles inside a pack's bounds, with no tile server to run.
* The GRIB slicer should quantise to 8–16 bits and use regional bounds. A 5-day, 3-hourly wind + wave + current corridor should fit in single-digit MB (estimate).
* Keep all third-party fetches on the server where terms require it (aisstream.io), where rate limits are per IP (NOMADS, Open-Meteo free, Overpass), or where hosts block cloud and bot traffic (NGA MSI). The phone talks to our CDN plus a few US government endpoints that tolerate direct use (api.weather.gov with a User-Agent, CO-OPS, NDBC).
* Attribution: build one attributions registry. Each layer declares its credit line, and the map shows the credits for visible layers. CC BY 4.0, ODbL, Copernicus and ECCC all require this.

---

## 6. Licensing risk register

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| 1 | **No free official charts outside the US.** CHS, UKHO, AHO and Brazil require licences; LINZ S-57 reuse is royalty-based. | High (product scope) | Launch US-first. Pick Navionics SDK or C-MAP for global coverage by P1. Label OpenSeaMap/OSM layers "not an official chart". |
| 2 | **NOAA ENC derived charts:** not "official"; producer liability; trademark | Medium | Disclaimers, edition/date display, no "NOAA ENC®" branding, liability terms in the EULA. |
| 3 | **GPL symbology** (OpenCPN s57data) and **GPL canboat** in an App Store app | High if done | Draw our own S-52-style sprites; use canboat only as documentation; get legal review on N2K PGN decoding. |
| 4 | **Open-Meteo free API is non-commercial** (ads or subscriptions count as commercial); free limits are per IP | High (the existing app may already rely on it) | Buy a commercial plan before monetising; consider self-hosting (AGPL server) at scale. |
| 5 | **ODbL share-alike** on OSM-derived POI | Medium | Keep OSM data in a separate layer; publish derived OSM data under ODbL; never merge it into the proprietary POI store. |
| 6 | **Community POI APIs** (ActiveCaptain, Waterway Guide): terms unseen until approved; possible caching limits and competitor clauses | Medium | Apply now; design the POI layer so each provider can be switched off. |
| 7 | **AIS aggregators:** aisstream.io forbids client connections and has no SLA; AISHub forbids raw redistribution; MarineTraffic is costly | Medium | Server relay; treat internet AIS as "awareness only"; on-boat AIS stays primary. |
| 8 | **Non-commercial datasets** (WDPA, Global Fishing Watch, Blitzortung, EOX cloudless 2018+, BOM free text, TPXO tide model) | High if used | Excluded. Substitutes: NOAA MPA, GLM, Sentinel-2 L2A, GOT4.10c/FES2022 heights. |
| 9 | **Imagery offline restrictions** (Esri, Google, Apple, Mapbox) | Medium | Use public-domain NAIP and Copernicus Sentinel-2 for offline anchorage packs. |
| 10 | **Windy Point Forecast excludes ECMWF**, and its trial data are altered | Low | Get ECMWF from ECMWF open data directly. |
| 11 | **FES2022 tidal currents** are scientific-only (heights are free for any use); TPXO is OSU-copyrighted with no published commercial terms | Low | Keep GOT4.10c / FES2022 heights; don't use TPXO or FES currents. |
| 12 | **NMEA 2000 trademark/standard** | Low to medium | Don't claim NMEA 2000 certification; integrate via gateways and Signal K. |

---

## 7. Gaps: where no good free source exists

1. **Official vector charts outside the US.** Paid licences only, apart from New Zealand (free for mariners, not for redistribution) and Finland (open but non-navigational).
2. **Global POI** (marinas, anchorages, fuel, pump-outs, services). There's no open authoritative dataset. OSM is sparse; ActiveCaptain and Waterway Guide are North-America-centred; Navily (Mediterranean) and Noforeignland have no read API. **Pump-out locations and marine fuel prices** have no national or free source at all.
3. **Satellite AIS** for mid-ocean traffic. Paid only (Kpler/MarineTraffic/Spire and others).
4. **Real-time lightning outside the Americas** under a commercial licence. GLM covers the Americas; Europe and Africa need EUMETSAT MTG-LI (licence to verify) or a paid network.
5. **Machine-readable notices outside the US.** Canada NOTMAR/NAVWARN, most NAVAREAs and many national warnings exist only as web pages or PDFs. NGA MSI is the best global feed and it blocked our probe.
6. **Sea fog forecasting.** There's no dedicated free marine fog product. We have to combine model visibility (HRRR/NBM/ECMWF), METAR, CO-OPS sensors and NWS advisories.
7. **High-resolution tidal currents outside US OFS coverage.** Copernicus regional seas help in Europe. Elsewhere there's only harmonic current stations (where they exist) or coarse global models.
8. **PredictWind-grade proprietary forecasts and routing.** No API at all.
9. **Bridge opening schedules and live lock queues outside the USACE and EuRIS systems.**
10. **Broadcast Notices to Mariners (US) as a feed.** HTML only until NAVCEN's announced API ships.
11. **Whale and manatee speed zones as a single dataset.** They're scattered across NOAA Fisheries, FWC and Transport Canada, and US rules are in flux in 2026.

---

## 8. Verification log (14 Nov 2026)

Calls made from our sandbox. A failure here can mean our egress proxy, not the provider.

| Endpoint | Result |
|---|---|
| `navcen.uscg.gov/.../msi/hazNav_1.geojson`, `lightListD01_1.geojson` | 200, GeoJSON (188 KB / 1.9 MB) |
| `msi.nga.mil/api/publications/broadcast-warn`, `/smaps` | **503** NGA apology page |
| `api.weather.gov/zones/forecast/ANZ338/forecast`, `/zones/marine/ANZ338`, `/products/types/CWF/locations/OKX/latest`, `/alerts/active?zone=ANZ338` | 200 |
| `tgftp.nws.noaa.gov/data/forecasts/marine/coastal/an/anz338.txt`, `.../offshore/an/anz800.txt` | 200 |
| NDBC `realtime2/44025.txt`, `latest_obs.txt`, `activestations.xml` (1,357 stations) | 200 |
| NCDS WMTS capabilities | 200 |
| `encdirect.noaa.gov/arcgis/rest/services/encdirect` | 200 |
| `charts.noaa.gov/ENCs/ENCs.shtml` (zips stamped 12 Nov 2026) | 200 |
| AWS: `noaa-gfs-bdp-pds` (wave), `noaa-hrrr-bdp-pds`, `noaa-nbm-grib2-pds`, `noaa-nws-rtofs-pds`, `noaa-nos-ofs-pds` (sfbofs), `noaa-nos-stofs3d-pds`, `noaa-s102-pds`, `noaa-s104-pds`, `noaa-s111-pds`, `noaa-ocs-nationalbathymetry-pds` (BlueTopo), `noaa-goes19` (GLM), `unidata-nexrad-level2`, `noaa-mrms-pds`, `sentinel-cogs` | 200 listings |
| `data.ecmwf.int/forecasts/`, `dd.weather.gc.ca/`, `nomads.ncep.noaa.gov` | 200 |
| `marine-api.open-meteo.com/v1/marine` | **429** daily limit (shared IP) |
| CoastWatch ERDDAP `jplMURSST41.das`, CDIP THREDDS, IOOS ERDDAP | 200 |
| HFRNet THREDDS | Connection reset |
| `aviationweather.gov/api/data/metar` | 200 JSON |
| CO-OPS mdapi `type=airgap` (21), `type=visibility` (23) | 200 |
| `tiles.openseamap.org/seamark/12/1206/1539.png` | 200 PNG |
| `meri.digitraffic.fi/api/ais/v1/locations`, `/api/aton/v1/faults` | 200 GeoJSON |
| Kystverket TCP `153.44.253.27:5631` | Refused (sandbox blocks raw TCP) |
| `aa.usno.navy.mil/api/rstt/oneday`, `/api/celnav` | 200, API v4.0.1 |
| `ngdc.noaa.gov/geomag-web/calculators/calculateDeclination` | 400: API key required |
| `pegelonline.wsv.de/.../stations.json`, `cwms-data.usace.army.mil/cwms-data/offices`, `api.waterdata.usgs.gov/ogcapi/v0/collections`, `eurisportal.eu`, `ienccloud.us` | 200 |
| `corpslocks.usace.army.mil` | Proxy 502 |
| `ddapi20-waterwebservices.rijkswaterstaat.nl` | 405 on GET (POST API exists) |
| `wrecks.nauticalcharts.noaa.gov` | TLS hostname mismatch |
| USGS NAIP Plus ImageServer, USGS Imagery Only MapServer, Earth Search STAC | 200 |

---

## 9. Key references

Charts and S-100
* NOAA ENC downloads: https://charts.noaa.gov/ENCs/ENCs.shtml · user agreement: https://charts.noaa.gov/ENCs/Agreement.shtml · 15 CFR 995: https://www.ecfr.gov/current/title-15/subtitle-B/chapter-IX/subchapter-F/part-995
* Coast Survey GIS data and services: https://nauticalcharts.noaa.gov/data/gis-data-and-services.html · data licensing: https://nauticalcharts.noaa.gov/data/data-licensing.html · NCDS MBTiles: https://distribution.charts.noaa.gov/ncds/index.html
* RNC shutdown notice: https://nauticalcharts.noaa.gov/updates/coast-survey-to-shut-down-the-raster-navigational-chart-tile-service-and-other-related-services/
* NOAA S-57 to S-101 transition plan: https://iho.int/uploads/user/Inter-Regional%20Coordination/WEND-WG/WENDWG14/WENDWG14_2024_05.1Ac_EN_NOAA%20US%20Transition%20Plan%20S-101%2021%20November%202023.pdf · UKHO S-100 timelines: https://www.admiralty.co.uk/news/s-100-timelines-explained · S-111 README: https://noaa-s111-pds.s3.amazonaws.com/README.html · S-104 README: https://noaa-s104-pds.s3.amazonaws.com/README.html
* CHS EULA: https://charts.gc.ca/copyright-droitdauteur/eula-aluf-eng.html · CHS VAR agreement: https://cartes-charts.gc.ca/documents/copyright-droitdauteur/3006-01-F06_VAR_Agreement_(Digital)_EN.pdf
* AHO AusENC: https://hydro.gov.au/prodserv/digital/ausENC/enc.htm · LINZ charts: https://www.linz.govt.nz/products-services/charts/where-find-charts · Traficom open data: https://traficom.fi/en/hydrography/finnish-nautical-charts/distribution-channels-nautical-charts-and-hydrographic-data · Kartverket raster WMS record: https://data.norge.no/en/datasets/fddedf5f-3068-44ab-8424-882f5c776c70/sjokart-raster-havnekart · Brazil CHM FAQ: https://www.marinha.mil.br/chm/bndo/duvidas-frequentes
* OpenSeaMap: https://wiki.openstreetmap.org/wiki/OpenSeaMap · Navionics SDK: https://developer.garmin.com/marine-charts/mobile · C-MAP WMTS (2020): https://www.marinebusinessworld.com/news/225500/C-MAP-launches-Web-Map-Tiling-Service-(WMTS) · Esri ENC layers: https://developers.arcgis.com/swift/v200/layers/display-electronic-navigational-charts/
* Pipelines: https://github.com/garyo/pelorus-nav · https://github.com/Greenroom-Robotics/enc-mapbox-converter · https://github.com/manimaul/s57tiler · OpenCPN copyright: https://sources.debian.org/src/opencpn/5.2.4%2Bdfsg-1/data/copyright

Bathymetry
* GEBCO_2025: https://www.gebco.net/data-products-gridded-bathymetry-data/gebco2025-grid · terms: https://www.gebco.net/data-products/gridded-bathymetry/terms-of-use
* BlueTopo: https://nauticalcharts.noaa.gov/data/bluetopo.html · EMODnet DTM 2024: https://emodnet.ec.europa.eu/en/emodnet-bathymetry-dtm-2024-release · EMODnet terms: https://emodnet.ec.europa.eu/en/terms-use-emodnet-online-services-data-and-data-products
* CHS NONNA: https://open.canada.ca/data/dataset/d3881c4c-650d-4070-bf9b-1e00aabf0a1d · IHO DCDB: https://www.ncei.noaa.gov/iho-data-centre-digital-bathymetry

AtoN and notices
* NAVCEN MSI: https://navcen.uscg.gov/msi · LNM/LL FAQ: https://www.navcen.uscg.gov/LNM-and-LL-app-frequently-asked-questions · legacy change notice: https://content.govdelivery.com/accounts/USDHSCG/bulletins/3bca11b
* NGA MSI client example: https://github.com/captv89/seaRoute/blob/master/navwarn.go · Canada NOTMAR: https://notmar.gc.ca

Weather and ocean
* ECMWF open data: https://www.ecmwf.int/en/forecasts/datasets/open-data · DWD legal notice (CC BY 4.0): https://www.dwd.de/EN/service/legal_notice/legal_notice_node.html · ECCC licence: https://eccc-msc.github.io/open-data/licence/readme_en · Météo-France AROME: https://data.gouv.fr/es/datasets/paquets-arome-resolution-0-01deg
* NOMADS throttling: https://luckgrib.com/blog/2021/04/19/throttling.html · RTOFS on AWS: https://registry.opendata.aws/noaa-rtofs/ · OFS on AWS: https://registry.opendata.aws/noaa-ofs/ · GOFS 3.1 retirement: https://groups.google.com/a/hycom.org/g/forum/c/vT2LJyDisCY
* Copernicus Marine citation and licence: https://help.marine.copernicus.eu/en/articles/4444611-how-to-cite-or-reference-copernicus-marine-products-and-services · https://marine.copernicus.eu/user-corner/service-commitments-and-licence
* Open-Meteo marine: https://open-meteo.com/en/docs/marine-weather-api · terms: https://open-meteo.com/en/terms · pricing: https://open-meteo.com/en/pricing · Stormglass: https://stormglass.io/pricing/ · Windy Point Forecast: https://api.windy.com/point-forecast/pricing · PredictWind API FAQ: https://help.predictwind.com/en/articles/9749094-faq-predictwind-api · Saildocs: https://weather.mailasail.com/Franks-Weather/Saildocs-Free-Grib-Files
* BOM data feeds: https://www.bom.gov.au/catalogue/data-feeds.shtml · Blitzortung compendium: https://www.blitzortung.org/en/compendium.php · GOES GLM: https://catalog.data.gov/dataset/noaa-goes-r-series-geostationary-lightning-mapper-glm-level-2-lightning-detection-events-g · nowCOAST: https://nauticalcharts.noaa.gov/learn/nowcoast.html

AIS
* aisstream.io docs: https://aisstream.io/documentation · AISHub: https://www.aishub.net/join-us · Kystverket: https://kystverket.no/en/navigation-and-monitoring/ais/access-to-ais-data · MarineCadastre AIS: https://github.com/ocm-marinecadastre/ais-vessel-traffic · Global Fishing Watch licence: https://globalfishingwatch.org/our-apis/documentation/docs/license-rate-limits
* Signal K connection spec: https://signalk.org/specification/1.7.0/doc/connection.html · canboat (GPL): https://github.com/canboat/canboat · FSF interview on NMEA 2000 copyright: https://www.fsf.org/blogs/licensing/the-licensing-and-compliance-lab-interviews-kees-verruijt-of-canboat

POI, regulatory, inland
* ActiveCaptain APIs: https://developer.garmin.com/active-captain/overview · Waterway Guide API: https://www.waterwayguide.com/api-reference/anchorages/v2 · Marinas.com API terms (deprecated): https://marinas.com/developers/terms
* Right whale rule (FR 2025-00718): https://www.federalregister.gov/documents/2025/01/16/2025-00718/north-atlantic-right-whale-vessel-strike-reduction-rule · NOAA amendments page: https://www.fisheries.noaa.gov/action/amendments-north-atlantic-right-whale-vessel-strike-reduction-rule · FWC manatee zones: https://gis.myfwc.com/hosting/rest/services/Open_Data/State_Manatee_Protection_Zones_in_Florida/MapServer
* Danger zones: https://catalog.data.gov/dataset/danger-zones-and-restricted-areas · NOAA MPA Inventory: https://www.fisheries.noaa.gov/inport/item/69506 · WDPA terms: https://www.protectedplanet.net/c/terms-and-conditions · Wrecks: https://nauticalcharts.noaa.gov/data/wrecks-and-obstructions.html
* CIS SIGRID-3 (NSIDC): https://nsidc.org/data/G02171 · USNIC SIGRID-3: https://nsidc.org/data/G10013
* USGS WaterServices decommission: https://waterdata.usgs.gov/blog/api-waterservices-decom · CWMS Data API: https://github.com/USACE/cwms-data-api · LPMS: https://www.cisa.gov/mts-resilience-resources/lock-performance-monitoring-system-lpms · EuRIS: https://www.doris.bmimi.gv.at/en/fairway-information/euris-portal

Astro, magnetic, imagery
* WMM2025: https://www.ncei.noaa.gov/products/world-magnetic-model · WMM2025/WMMHR2025: https://geomag.colorado.edu/wmm2025-and-wmmhr2025 · USNO API: https://aa.usno.navy.mil/data/api
* EOX cloudless licence: https://cloudless.eox.at/documentation/license · Esri World Imagery export: https://support.esri.com/en/technical-article/000014855 · Gaia GPS Esri change: https://blog.gaiagps.com/esriupdate · Mapbox offline: https://docs.mapbox.com/ios/maps/guides/offline/concepts/ · FES2022: https://www.aviso.altimetry.fr/en/data/products/auxiliary-products/global-tide-fes.html

*Not for navigation. This catalog records research findings, not a warranty of any
provider's availability or terms.*
