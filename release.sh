#!/bin/zsh
# Official release: build (timestamped signatures) → package → sign package → notarize → staple → verify.
# Result: build/Unbleed-<version>.pkg that opens cleanly on any Mac, even offline.
#
# One-time setup: a "Developer ID Installer" certificate in your login keychain, and notarization
# credentials stored as a keychain profile:  xcrun notarytool store-credentials unbleed ...
set -euo pipefail
cd "${0:A:h}"

PROFILE=${NOTARY_PROFILE:-unbleed}
INSTALLER_ID=$(security find-identity -v | grep -oE '"Developer ID Installer[^"]*"' | head -1 | tr -d '"')
[[ -n $INSTALLER_ID ]] || { echo "no Developer ID Installer certificate in the keychain" >&2; exit 1 }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
PKG=build/Unbleed-$VERSION.pkg

echo "▸ building (release signatures)"
RELEASE=1 ./build.sh | grep -E "^built|^bundled"

echo "▸ checking signatures"
codesign --verify --deep --strict build/Unbleed.app
for d in build/drivers/*.driver; do codesign --verify --strict "$d"; done
for f in build/Unbleed.app build/drivers/*.driver; do
    info=$(codesign -dv "$f" 2>&1)  # captured first: grep -q + pipefail would trip on SIGPIPE
    [[ $info == *"Timestamp="* ]] || { echo "$f has no secure timestamp" >&2; exit 1 }
done

echo "▸ packaging"
RELEASE=1 packaging/make_pkg.sh | grep "^built"
productsign --sign "$INSTALLER_ID" --timestamp $PKG $PKG.signed >/dev/null
mv $PKG.signed $PKG
[[ $(pkgutil --check-signature $PKG) == *"issued by Apple for distribution"* ]] || { echo "package signing failed" >&2; exit 1 }

echo "▸ notarizing (uploading to Apple; usually a few minutes)"
SUBMISSION=$(xcrun notarytool submit $PKG --keychain-profile $PROFILE --wait --output-format plist)
STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" /dev/stdin <<< "$SUBMISSION")
ID=$(/usr/libexec/PlistBuddy -c "Print :id" /dev/stdin <<< "$SUBMISSION")
if [[ $STATUS != Accepted ]]; then
    echo "notarization $STATUS — Apple's report:" >&2
    xcrun notarytool log $ID --keychain-profile $PROFILE >&2
    exit 1
fi

echo "▸ stapling"
xcrun stapler staple $PKG >/dev/null
xcrun stapler validate $PKG >/dev/null
[[ $(spctl --assess --type install --verbose $PKG 2>&1) == *accepted* ]] || { echo "Gatekeeper rejected $PKG" >&2; exit 1 }

echo "✅ $PKG is signed, notarized and stapled (submission $ID)"
