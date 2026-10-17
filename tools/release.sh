#!/bin/bash
# Builds a release the way users get it, from a FRESH CLONE of the public repository, and prepares everything to upload:
#   Feather-<version>-alpha.zip, its .sha256, update.json and update.json.sig (the signed manifest the updater checks).
#
#   tools/release.sh            -> artifacts in /tmp/feather-release-<timestamp>/out
#
# It publishes nothing. Needs: the signing key in your Keychain (tools/new-update-key.sh), UPDATE_PUBLIC_KEY set in project.yml,
# xcodegen, and `pip install cryptography`. The version comes from project.yml.
set -euo pipefail
REPO_URL="${FEATHER_REPO_URL:-https://github.com/lumenworksco/Feather.git}"
WORK="/tmp/feather-release-$(date +%s)"
mkdir -p "$WORK/out"
git clone -q "$REPO_URL" "$WORK/src"
cd "$WORK/src"
echo "building commit $(git rev-parse --short HEAD) from a fresh clone"

PUB=$(grep -E '^\s*UPDATE_PUBLIC_KEY:' project.yml | head -1 | sed -E 's/.*UPDATE_PUBLIC_KEY:\s*"?([^"]*)"?.*/\1/')
[ -n "$PUB" ] || { echo "UPDATE_PUBLIC_KEY is empty in project.yml: updates could never be verified. Run tools/new-update-key.sh and put the public key there (and push it)." >&2; exit 1; }

xcodegen generate >/dev/null
xcodebuild -project Feather.xcodeproj -scheme Feather -configuration Release -derivedDataPath build build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="$WORK/src/build/Build/Products/Release/Feather.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
ZIP="$WORK/out/Feather-$VERSION-alpha.zip"

# What the app contains must match what the updater and the entitlements promise.
codesign --verify --strict --deep "$APP"
codesign -d --entitlements - "$APP" 2>&1 | grep -q device.usb || { echo "USB entitlement missing" >&2; exit 1; }
[ -d "$APP/Contents/Library/FeatherUpdater.app" ] || { echo "installer helper missing" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :FeatherUpdatePublicKey' "$APP/Contents/Info.plist")" = "$PUB" ] || { echo "public key in the app differs from project.yml" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :FeatherUpdatePublicKey' "$APP/Contents/Library/FeatherUpdater.app/Contents/Info.plist")" = "$PUB" ] || { echo "public key in the helper differs" >&2; exit 1; }

ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP" "$ZIP"
( cd "$WORK/out" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )
python3 "$WORK/src/tools/make-update.py" "$ZIP" "$WORK/out" >/dev/null

# Check the signature the way the app will, with the public key from project.yml.
python3 - "$PUB" "$WORK/out" <<'PY'
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
pub = Ed25519PublicKey.from_public_bytes(base64.b64decode(sys.argv[1]))
body = open(sys.argv[2] + "/update.json", "rb").read()
sig = base64.b64decode(open(sys.argv[2] + "/update.json.sig").read().strip())
pub.verify(sig, body)
print("signature verifies against the public key in project.yml")
PY

echo
echo "version $VERSION (build $BUILD)"
echo "artifacts in $WORK/out:"; ls -la "$WORK/out" | awk 'NR>1 && $9 != "." && $9 != ".." {print "  " $5 " bytes  " $9}'
echo
echo "next: gh release create v$VERSION-alpha --target main --title \"Feather $VERSION-alpha\" --notes-file <notes> --latest $WORK/out/*"
