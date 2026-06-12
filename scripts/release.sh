#!/usr/bin/env bash
# release.sh — produce a notarized, signed .app + .zip for direct
# download. Wraps the four standard steps Apple requires for a
# Gatekeeper-clean release:
#
#   1. archive   — xcodebuild builds + signs with Developer ID
#   2. export    — pulls the .app out of the .xcarchive
#   3. notarize  — uploads to Apple, waits for the ticket
#   4. staple    — embeds the ticket so launching needs no network
#
# Run from the repo root or any directory — the script resolves
# its own location.
#
# Prerequisites (one-time):
#   - "Developer ID Application: John Pettitt (7QWPRXJ3WW)"
#     in the login keychain with its private key.
#   - Notarization credentials stored under the keychain profile
#     `geoclock-notary`:
#         xcrun notarytool store-credentials geoclock-notary \
#           --apple-id <you>@example.com \
#           --team-id 7QWPRXJ3WW \
#           --password <app-specific-password>
#     Generate the app-specific password at
#     appleid.apple.com → Sign-In and Security → App-Specific Passwords.

set -euo pipefail

# --- Config ---------------------------------------------------

readonly TEAM_ID="7QWPRXJ3WW"
readonly SIGNING_IDENTITY="Developer ID Application: John Pettitt (${TEAM_ID})"
readonly NOTARY_PROFILE="geoclock-notary"
readonly SCHEME="GeoClockWallpaper"
readonly PROJECT="GeoClockWallpaper.xcodeproj"
readonly APP_NAME="GeoClockWallpaper.app"

# --- Locate repo root ----------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

readonly BUILD_DIR="$REPO_ROOT/build/release"
readonly ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
readonly EXPORT_PATH="$BUILD_DIR/export"

# --- Preflight checks ---------------------------------------

echo "==> Preflight"

# Cert + key paired in login keychain?
if ! security find-identity -p codesigning -v \
     | grep -q "$SIGNING_IDENTITY"; then
  echo "ERROR: '$SIGNING_IDENTITY' not found in your keychain." >&2
  echo "       Create it via Xcode → Settings → Accounts →" >&2
  echo "       Manage Certificates → + → Developer ID Application." >&2
  exit 1
fi

# Notarization credentials stored?
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
     >/dev/null 2>&1; then
  echo "ERROR: notary profile '$NOTARY_PROFILE' not set up." >&2
  echo "       Generate an app-specific password at appleid.apple.com" >&2
  echo "       then run:" >&2
  echo "         xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
  echo "           --apple-id <your-apple-id> \\" >&2
  echo "           --team-id $TEAM_ID \\" >&2
  echo "           --password <app-specific-password>" >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- Tests ----------------------------------------------------

# Refuse to ship a build whose unit tests fail. Tests run in
# Debug (fast, no signing requirements) before we pay for the
# Release archive.
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

echo "==> Archiving (Release, signed with $SIGNING_IDENTITY)"

# Full output goes to a log file; we surface the summary lines.
# Checking PIPESTATUS (not just the grep's exit code) means a
# failed build fails the script with its log available, instead
# of being masked by `grep || true` and only caught later by the
# missing-archive check with no diagnostics.
ARCHIVE_LOG="$BUILD_DIR/xcodebuild-archive.log"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
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

# --- Export ---------------------------------------------------

echo "==> Exporting .app"

EXPORT_OPTS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict></plist>
EOF

EXPORT_LOG="$BUILD_DIR/xcodebuild-export.log"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTS" > "$EXPORT_LOG" 2>&1 || {
    echo "ERROR: export failed — see $EXPORT_LOG" >&2
    grep -E "error:" "$EXPORT_LOG" | head -10 >&2
    exit 1
  }
grep -E "^\*\* " "$EXPORT_LOG" || true

readonly EXPORTED_APP="$EXPORT_PATH/$APP_NAME"
if [[ ! -d "$EXPORTED_APP" ]]; then
  echo "ERROR: exported .app missing (see $EXPORT_LOG)." >&2
  exit 1
fi

# --- Notarize -------------------------------------------------

# notarytool wants a single archive, not a directory tree.
# `ditto -c -k --keepParent` produces a zip Apple's service
# accepts (preserves resource forks + xattrs).
echo "==> Zipping for notarization"
readonly NOTARY_ZIP="$BUILD_DIR/$SCHEME.zip"
ditto -c -k --keepParent "$EXPORTED_APP" "$NOTARY_ZIP"

echo "==> Submitting to Apple notary service (this typically takes 1–5 min)"
NOTARY_LOG="$BUILD_DIR/notarytool.log"
xcrun notarytool submit "$NOTARY_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait | tee "$NOTARY_LOG"

# notarytool's exit status has historically been 0 even on an
# "Invalid" verdict — the stapler step below would then fail with
# a cryptic error and no notary log. Check the verdict explicitly
# and fetch the detailed log on rejection.
if ! grep -q "status: Accepted" "$NOTARY_LOG"; then
  echo "ERROR: notarization not accepted — fetching notary log" >&2
  SUBMISSION_ID="$(grep -m1 "id:" "$NOTARY_LOG" | awk '{print $2}')"
  if [[ -n "$SUBMISSION_ID" ]]; then
    xcrun notarytool log "$SUBMISSION_ID" \
      --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fi
  exit 1
fi

# --- Staple ---------------------------------------------------

# Embeds the notarization ticket into the .app so launching it
# doesn't require an outbound network check.
echo "==> Stapling notarization ticket"
xcrun stapler staple "$EXPORTED_APP"
xcrun stapler validate "$EXPORTED_APP"

# Re-zip after stapling so the ship-ready archive includes the
# ticket — the pre-notarize zip was just for the submit upload.
echo "==> Final zip"
rm "$NOTARY_ZIP"
ditto -c -k --keepParent "$EXPORTED_APP" "$NOTARY_ZIP"

echo
echo "==> Done"
echo "    App:  $EXPORTED_APP"
echo "    Zip:  $NOTARY_ZIP"
echo
echo "Verify the signature + notarization:"
echo "    codesign -dv --verbose=4 '$EXPORTED_APP'"
echo "    spctl --assess --type execute --verbose '$EXPORTED_APP'"
