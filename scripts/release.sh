#!/usr/bin/env bash
#
# Package an exported MacCove.app into a signed, notarized DMG and publish it
# as a GitHub release.
#
# Before running:
#   1. In Xcode: Product → Archive, then Distribute App → Direct Distribution,
#      and export the notarized MacCove.app.
#   2. Once per machine, save notary credentials to the keychain:
#        xcrun notarytool store-credentials MacCove \
#          --apple-id <apple id> --team-id 9MZKF3V7G9
#   3. Sign in to GitHub CLI: gh auth login
#
# Usage:
#   scripts/release.sh <path/to/MacCove.app> [options]
#
# Options:
#   --draft          Create the GitHub release as a draft
#   --no-upload      Stop after the DMG is notarized; don't touch GitHub
#   --target <ref>   Branch or commit to tag (default: current branch)
#   --yes            Don't ask before publishing
#
# Environment overrides:
#   SIGN_IDENTITY    Code signing identity (default: your Developer ID Application cert)
#   NOTARY_PROFILE   notarytool keychain profile (default: MacCove)
#   OUT_DIR          Where the DMG goes (default: <repo>/dist)

set -euo pipefail

TEAM_ID="9MZKF3V7G9"
BUNDLE_ID="com.ducling.MacCove"
APP_NAME="MacCove"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"
NOTARY_PROFILE="${NOTARY_PROFILE:-MacCove}"

bold() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Arguments ---------------------------------------------------------------

APP_PATH=""
DRAFT=0
UPLOAD=1
ASSUME_YES=0
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --draft)     DRAFT=1 ;;
    --no-upload) UPLOAD=0 ;;
    --yes|-y)    ASSUME_YES=1 ;;
    --target)    shift; TARGET="${1:-}"; [[ -n "$TARGET" ]] || die "--target needs a value" ;;
    -h|--help)   sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          die "Unknown option: $1" ;;
    *)           [[ -z "$APP_PATH" ]] || die "Only one app path, please"; APP_PATH="$1" ;;
  esac
  shift
done

[[ -n "$APP_PATH" ]] || die "Pass the exported app, e.g. scripts/release.sh ~/Desktop/MacCove.app"
APP_PATH="${APP_PATH%/}"
[[ -d "$APP_PATH" ]] || die "No app at $APP_PATH"

# --- Check the app -----------------------------------------------------------

bold "Checking $APP_PATH"

PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$PLIST" ]] || die "$APP_PATH has no Info.plist; is it an app bundle?"

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }

ACTUAL_BUNDLE_ID="$(plist_value CFBundleIdentifier)"
VERSION="$(plist_value CFBundleShortVersionString)"
BUILD="$(plist_value CFBundleVersion)"
MIN_OS="$(plist_value LSMinimumSystemVersion)"

[[ "$ACTUAL_BUNDLE_ID" == "$BUNDLE_ID" ]] || die "Bundle ID is '$ACTUAL_BUNDLE_ID', expected '$BUNDLE_ID'"
[[ -n "$VERSION" ]] || die "App has no CFBundleShortVersionString"
echo "Version $VERSION (build $BUILD), requires macOS ${MIN_OS:-?}"

codesign --verify --deep --strict "$APP_PATH" || die "The app's code signature is invalid"

SIGN_INFO="$(codesign -dvv "$APP_PATH" 2>&1)"
grep -q "Authority=Developer ID Application" <<<"$SIGN_INFO" \
  || die "The app isn't signed with a Developer ID certificate. Export it with Distribute App → Direct Distribution."
grep -q "TeamIdentifier=$TEAM_ID" <<<"$SIGN_INFO" \
  || die "The app is signed by a different team than $TEAM_ID"
grep -q "(runtime)" <<<"$SIGN_INFO" \
  || die "Hardened runtime is off; notarization will be rejected"

if spctl -a -t exec -vv "$APP_PATH" 2>&1 | grep -q "Notarized Developer ID"; then
  echo "App is notarized"
else
  warn "The app itself isn't notarized. Notarizing the DMG will still cover it, but exporting from Direct Distribution is better."
fi

# --- Signing identity --------------------------------------------------------

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | grep "($TEAM_ID)" | head -1 | awk '{print $2}')"
  [[ -n "$SIGN_IDENTITY" ]] || die "No Developer ID Application certificate for team $TEAM_ID in your keychain"
fi

# --- Build the DMG -----------------------------------------------------------

DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$OUT_DIR/$DMG_NAME"
mkdir -p "$OUT_DIR"

WORK_DIR="$(mktemp -d -t maccove-release)"
trap 'rm -rf "$WORK_DIR"' EXIT

bold "Building $DMG_NAME"

STAGING="$WORK_DIR/staging"
mkdir -p "$STAGING"
ditto "$APP_PATH" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null

bold "Signing the DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

# --- Notarize ----------------------------------------------------------------

bold "Notarizing (this usually takes a few minutes)"

NOTARY_JSON="$WORK_DIR/notary.json"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" --wait --output-format json >"$NOTARY_JSON" || true

STATUS="$(plutil -extract status raw "$NOTARY_JSON" 2>/dev/null || echo "unknown")"
SUBMISSION_ID="$(plutil -extract id raw "$NOTARY_JSON" 2>/dev/null || true)"

if [[ "$STATUS" != "Accepted" ]]; then
  cat "$NOTARY_JSON" >&2 || true
  if [[ -n "$SUBMISSION_ID" ]]; then
    echo >&2
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fi
  die "Notarization status: $STATUS"
fi
echo "Accepted ($SUBMISSION_ID)"

bold "Stapling"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH"

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
bold "DMG ready"
echo "$DMG_PATH"
echo "SHA-256: $SHA256"

[[ "$UPLOAD" -eq 1 ]] || exit 0

# --- GitHub release ----------------------------------------------------------

command -v gh >/dev/null || die "GitHub CLI not found. Install it with: brew install gh"
gh auth status >/dev/null 2>&1 || die "GitHub CLI isn't signed in. Run: gh auth login"

TAG="v$VERSION"
cd "$REPO_ROOT"

if gh release view "$TAG" >/dev/null 2>&1; then
  die "Release $TAG already exists. Bump the version, or upload to it with: gh release upload $TAG \"$DMG_PATH\" --clobber"
fi

TARGET="${TARGET:-$(git rev-parse --abbrev-ref HEAD)}"
if [[ "$TARGET" == "$(git rev-parse --abbrev-ref HEAD)" ]]; then
  git fetch --quiet origin "$TARGET" 2>/dev/null || warn "Couldn't fetch origin/$TARGET; is the branch pushed?"
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$TARGET" 2>/dev/null || true)" ]]; then
    warn "Your local $TARGET doesn't match origin/$TARGET. The tag is created on GitHub, so it will point at origin's commit."
  fi
fi

NOTES="Requires macOS ${MIN_OS:-26.0} or later.

Download **$DMG_NAME**, open it, and drag $APP_NAME to Applications.

SHA-256: \`$SHA256\`"

echo
echo "About to publish:"
echo "  Tag:     $TAG (on $TARGET)"
echo "  Asset:   $DMG_NAME"
echo "  Draft:   $([[ $DRAFT -eq 1 ]] && echo yes || echo no)"
if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "Publish to GitHub? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Skipped. The DMG is at $DMG_PATH"; exit 0; }
fi

GH_ARGS=(release create "$TAG" "$DMG_PATH"
  --title "$APP_NAME $VERSION"
  --target "$TARGET"
  --notes "$NOTES"
  --generate-notes)
[[ "$DRAFT" -eq 1 ]] && GH_ARGS+=(--draft)

bold "Creating GitHub release $TAG"
gh "${GH_ARGS[@]}"
