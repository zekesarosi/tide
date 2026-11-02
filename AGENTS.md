# AGENTS.md

Directions for coding agents working on this repo. See README.md for the project overview.

- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.

## Build & test

```sh
swift test --package-path TideKit          # 50 unit tests, ~5 s, no network
xcodegen generate                          # after adding/removing files or editing project.yml
xcodebuildmcp simulator build-and-run \
  --project-path TideForecast.xcodeproj --scheme TideForecast \
  --simulator-name "iPhone 17" --derived-data-path build/DerivedData
```

- `TideForecast.xcodeproj` and `build/` are generated and git-ignored; never edit the project by hand, edit `project.yml`.
- Pipe raw `xcodebuild` through `xcbeautify` if you use it directly.
- No secrets are needed for the simulator. Without `Config/Secrets.xcconfig`, Settings shows a "Developer contact is not configured" warning (expected).

## Driving the simulator (Xcode 27 gotchas)

- Xcode 27 has no standalone Simulator.app; simulators run headless. Screenshots via
  `xcrun simctl io <udid> screenshot` or `xcodebuildmcp ui-automation screenshot` are accurate.
- **Taps are silently dropped on Xcode 27** (AXe 1.8.0 bug, cameroncooke/AXe#71: the tool prints
  success but the first gesture never reaches the app). Workarounds:
  - XcodeBuildMCP `tap`: always pass `postDelay: 0.5` (`--post-delay 0.5` on the CLI).
  - Raw AXe (`/opt/homebrew/Cellar/xcodebuildmcp/<ver>/libexec/bundled/axe`): use `--tap-style physical`.
  - XcodeBuildMCP `type_text` focuses the field with an affected tap; tap the field first (with the
    workaround), then type.
  - Always verify a tap with a fresh snapshot/screenshot; never trust the success message.
- Don't drive a simulator the user is interacting with; boot a second device instead.
- Grant location without the prompt: `xcrun simctl privacy <udid> grant location com.example.tideforecast`,
  then `xcrun simctl location <udid> set 40.7006,-74.0142` (The Battery, NY).

## App facts useful for testing

- Bundle id (default config): `com.example.tideforecast`.
- Deep link: `tideforecast://station/<source>:<code>`, e.g. `tideforecast://station/noaa-coops:8518750`.
  San Francisco Bay (Map tab, zoomed to the bay): `tideforecast://bay` or `tideforecast://bay/<NOAA code>` (selects that station).
  `swift run --package-path TideKit tide-cli bay` prints the bay offsets table against NOAA's own hi/lo tables.
  A bare code (`.../station/8518750`) is ignored. `simctl openurl` shows an "Open in Tide & Surge?" dialog.
- Good smoke-test stations: The Battery NY (`noaa-coops:8518750`, tidal + NWS blend + flood levels),
  Buffalo NY (`noaa-coops:9063020`, Great Lakes, no flood levels), Point Atkinson (DFO Canada, search "Atkinson").
- Station times display in the station's zone. `America/Vancouver` is on permanent UTC−7 in current tzdata,
  so BC stations read one hour ahead of Pacific time. That's correct, not a bug.
