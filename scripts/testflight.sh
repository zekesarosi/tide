#!/bin/sh
# Archive a Release build and upload it to App Store Connect / TestFlight.
#
#   scripts/testflight.sh            # archive + upload
#   scripts/testflight.sh --no-upload  # archive + export an .ipa only
#
# Needs Config/Secrets.xcconfig (DEVELOPMENT_TEAM, TIDE_BUNDLE_ID) and the
# Apple ID signed in under Xcode › Settings › Accounts. The build number is a
# UTC timestamp, so every upload is unique without editing project.yml.
set -eu
cd "$(dirname "$0")/.."

DEST=upload
[ "${1:-}" = "--no-upload" ] && DEST=export

TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Config/Secrets.xcconfig | tail -1)
[ -n "$TEAM" ] || { echo "DEVELOPMENT_TEAM missing from Config/Secrets.xcconfig" >&2; exit 1; }
BUILD=$(date -u +%Y%m%d%H%M)
OUT=build/testflight/$BUILD
mkdir -p "$OUT"

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$DEST</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

xcodegen generate
xcodebuild archive \
  -project TideForecast.xcodeproj -scheme TideForecast -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/TideForecast.xcarchive" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD"
xcodebuild -exportArchive \
  -archivePath "$OUT/TideForecast.xcarchive" -exportPath "$OUT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates

echo "Build $BUILD: $DEST done ($OUT)"
