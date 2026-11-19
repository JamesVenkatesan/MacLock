#!/usr/bin/env bash
#
# make_release.sh — build, sign, notarize and package MacLock as a DMG.
#
# Produces build/release/MacLock-<version>.dmg: a Developer ID–signed,
# notarized and stapled disk image that opens on any Mac without Gatekeeper
# warnings. Optionally publishes it as a GitHub release.
#
# One-time setup (needs a paid Apple Developer Program membership):
#   1. Xcode → Settings → Accounts → Manage Certificates → + → "Developer ID Application".
#   2. Create an app-specific password at https://appleid.apple.com, then store it
#      in the keychain so this script never sees it:
#        xcrun notarytool store-credentials maclock-notary \
#          --apple-id <your Apple ID> --team-id <your team ID>
#
# Usage:
#   tools/make_release.sh                 # build + sign + notarize + DMG
#   tools/make_release.sh --publish       # ...then create GitHub release v<version>
#   tools/make_release.sh --no-notarize   # signed DMG only, for a quick local check
#
# Environment overrides:
#   NOTARY_PROFILE   keychain profile name from store-credentials (default: maclock-notary)
#   TEAM_ID          signing team (default: the project's DEVELOPMENT_TEAM)
#

set -euo pipefail

# MARK: - Config

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/glance.xcodeproj"
SCHEME="glance"
APP_NAME="MacLock"
NOTARY_PROFILE="${NOTARY_PROFILE:-maclock-notary}"
OUT_DIR="$REPO_ROOT/build/release"

PUBLISH=false
NOTARIZE=true
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=true ;;
        --no-notarize) NOTARIZE=false ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done
if $PUBLISH && ! $NOTARIZE; then
    echo "error: --publish requires notarization; drop --no-notarize." >&2
    exit 2
fi

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

build_setting() {
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
        | awk -F' = ' -v key="$1" '$1 ~ "^ *"key"$" { print $2; exit }'
}

# MARK: - Preflight

step "Checking prerequisites"

command -v xcodebuild >/dev/null || fail "xcodebuild not found — install Xcode."
xcode-select -p | grep -q "Xcode" || fail "Active developer dir is not Xcode. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

VERSION="$(build_setting MARKETING_VERSION)"
BUILD_NUMBER="$(build_setting CURRENT_PROJECT_VERSION)"
TEAM_ID="${TEAM_ID:-$(build_setting DEVELOPMENT_TEAM)}"
[[ -n "$VERSION" && -n "$TEAM_ID" ]] || fail "Couldn't read MARKETING_VERSION / DEVELOPMENT_TEAM from the project."

SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | grep "($TEAM_ID)" | head -1 \
    | sed -E 's/^ *[0-9]+\) ([0-9A-F]+) .*/\1/')" || true
[[ -n "$SIGN_IDENTITY" ]] || fail "No \"Developer ID Application\" certificate for team $TEAM_ID in your keychain.
       Create one in Xcode → Settings → Accounts → Manage Certificates (needs a paid Apple Developer Program membership)."

if $NOTARIZE; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "No notarytool credentials named \"$NOTARY_PROFILE\". Run:
       xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id $TEAM_ID"
fi

if $PUBLISH; then
    command -v gh >/dev/null || fail "--publish needs the GitHub CLI (brew install gh)."
    gh auth status >/dev/null 2>&1 || fail "--publish needs 'gh auth login' first."
    if gh release view "v$VERSION" >/dev/null 2>&1; then
        fail "GitHub release v$VERSION already exists — bump MARKETING_VERSION first."
    fi
fi

if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    echo "warning: working tree has uncommitted changes; they will be included in this build."
fi

echo "Version $VERSION ($BUILD_NUMBER), team $TEAM_ID"

# MARK: - Archive & export

WORK_DIR="$OUT_DIR/work"
ARCHIVE="$WORK_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$WORK_DIR/export"
DMG="$OUT_DIR/$APP_NAME-$VERSION.dmg"
rm -rf "$WORK_DIR" "$DMG"
mkdir -p "$WORK_DIR"

step "Archiving (Release)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" -destination "generic/platform=macOS" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID" \
    archive -quiet

step "Exporting with Developer ID signing"
cat > "$WORK_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$WORK_DIR/ExportOptions.plist" -allowProvisioningUpdates -quiet

APP="$EXPORT_DIR/$APP_NAME.app"
[[ -d "$APP" ]] || fail "Export didn't produce $APP_NAME.app."
codesign --verify --deep --strict "$APP" || fail "Exported app failed codesign verification."
codesign -dv "$APP" 2>&1 | grep -q "Developer ID Application" || fail "Exported app isn't Developer ID–signed."

# MARK: - DMG

step "Building DMG"
STAGING="$WORK_DIR/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO -fs HFS+ "$DMG" -quiet
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

# MARK: - Notarize

if $NOTARIZE; then
    step "Notarizing (usually a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
        | tee "$WORK_DIR/notary.log"
    grep -q "status: Accepted" "$WORK_DIR/notary.log" || {
        SUBMISSION_ID="$(awk '/^ *id:/ { print $2; exit }' "$WORK_DIR/notary.log")"
        [[ -n "$SUBMISSION_ID" ]] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" || true
        fail "Notarization was not accepted (log above)."
    }

    step "Stapling ticket"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG" \
        || fail "Gatekeeper rejected the stapled DMG."
else
    echo "Skipping notarization — this DMG will be blocked by Gatekeeper on other Macs."
fi

# MARK: - Publish

if $PUBLISH; then
    step "Publishing GitHub release v$VERSION"
    gh release create "v$VERSION" "$DMG" \
        --title "$APP_NAME $VERSION" \
        --notes "Download **$APP_NAME-$VERSION.dmg**, open it and drag $APP_NAME to Applications.

Signed with Developer ID and notarized by Apple. Requires macOS 15 or later."
fi

step "Done"
echo "$DMG"
shasum -a 256 "$DMG"
