#!/usr/bin/env bash
# release-mas.sh — produce a Mac App Store .pkg ready for upload.
#
# The MAS pipeline differs from release.sh (Developer ID) in every
# step that matters:
#   - configuration Release-MAS (entitlements without the
#     /Users/Shared temporary-exception — review rejects those)
#   - signed with "Apple Distribution", not Developer ID
#   - exported with method app-store-connect as an installer .pkg
#   - NO notarization/stapling — App Store review replaces it
#
# Output: build/release-mas/export/GeoClockWallpaper.pkg
# Upload it with the Transporter app (Mac App Store, free) or from
# Xcode's Organizer. Uploading requires the app record to exist in
# App Store Connect first.
#
# Prerequisites (one-time):
#   - "Apple Distribution: John Pettitt (7QWPRXJ3WW)" and
#     "3rd Party Mac Developer Installer" (aka Mac Installer
#     Distribution) certificates in the login keychain: Xcode →
#     Settings → Accounts → Manage Certificates → +.
#   - Xcode signed into the account, so -allowProvisioningUpdates
#     can create/fetch the Mac App Store provisioning profile.

set -euo pipefail

# --- Config ---------------------------------------------------

readonly TEAM_ID="7QWPRXJ3WW"
readonly SIGNING_IDENTITY="Apple Distribution: John Pettitt (${TEAM_ID})"
readonly SCHEME="GeoClockWallpaper"
readonly PROJECT="GeoClockWallpaper.xcodeproj"

# --- Locate repo root ----------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

readonly BUILD_DIR="$REPO_ROOT/build/release-mas"
readonly ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
readonly EXPORT_PATH="$BUILD_DIR/export"

# --- Preflight checks ---------------------------------------

echo "==> Preflight"

if ! security find-identity -p codesigning -v \
     | grep -q "$SIGNING_IDENTITY"; then
  echo "ERROR: '$SIGNING_IDENTITY' not found in your keychain." >&2
  echo "       Create it via Xcode → Settings → Accounts →" >&2
  echo "       Manage Certificates → + → Apple Distribution," >&2
  echo "       and add a Mac Installer Distribution cert there too." >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- Tests ----------------------------------------------------

echo "==> Running unit tests"
TEST_LOG="$BUILD_DIR/xcodebuild-test.log"
if ! xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  test > "$TEST_LOG" 2>&1; then
  echo "ERROR: tests failed — see $TEST_LOG" >&2
  tail -30 "$TEST_LOG" >&2
  exit 1
fi
grep -E "Executed .* tests" "$TEST_LOG" | tail -1

# --- Archive --------------------------------------------------

# Automatic signing here (unlike release.sh's manual Developer ID):
# MAS archives need a Mac App Store provisioning profile, and
# letting Xcode manage it via -allowProvisioningUpdates beats
# maintaining profiles by hand for a bundle ID that changes never.
echo "==> Archiving (Release-MAS, Apple Distribution)"
ARCHIVE_LOG="$BUILD_DIR/xcodebuild-archive.log"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release-MAS \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  archive > "$ARCHIVE_LOG" 2>&1 || {
    echo "ERROR: archive failed — see $ARCHIVE_LOG" >&2
    grep -E "error:" "$ARCHIVE_LOG" | head -10 >&2
    exit 1
  }
grep -E "^\*\* " "$ARCHIVE_LOG" || true

if [[ ! -d "$ARCHIVE_PATH" ]]; then
  echo "ERROR: archive missing — xcodebuild failed (see $ARCHIVE_LOG)." >&2
  exit 1
fi

# --- Sanity: no forbidden entitlement ------------------------

# The whole point of Release-MAS is dropping the temporary-
# exception; shipping it anyway means an automatic rejection.
# Catch a project.yml/config regression here, not in review.
APP_IN_ARCHIVE="$ARCHIVE_PATH/Products/Applications/GeoClockWallpaper.app"
if codesign -d --entitlements - "$APP_IN_ARCHIVE" 2>/dev/null \
     | grep -q "temporary-exception"; then
  echo "ERROR: archive still carries a temporary-exception" >&2
  echo "       entitlement — Release-MAS config is not applying" >&2
  echo "       GeoClockWallpaper-MAS.entitlements." >&2
  exit 1
fi

# --- Export ---------------------------------------------------

echo "==> Exporting .pkg for App Store Connect"

EXPORT_OPTS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict></plist>
EOF

EXPORT_LOG="$BUILD_DIR/xcodebuild-export.log"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -allowProvisioningUpdates > "$EXPORT_LOG" 2>&1 || {
    echo "ERROR: export failed — see $EXPORT_LOG" >&2
    grep -E "error:" "$EXPORT_LOG" | head -10 >&2
    exit 1
  }
grep -E "^\*\* " "$EXPORT_LOG" || true

readonly PKG="$EXPORT_PATH/GeoClockWallpaper.pkg"
if [[ ! -f "$PKG" ]]; then
  echo "ERROR: exported .pkg missing (see $EXPORT_LOG)." >&2
  exit 1
fi

echo
echo "==> Done"
echo "    Pkg: $PKG"
echo
echo "Next: upload with Transporter (drag the .pkg in) or Xcode →"
echo "Organizer. The App Store Connect app record for"
echo "world.geoclock.wallpaper must exist before uploading."
