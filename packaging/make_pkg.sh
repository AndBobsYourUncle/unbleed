#!/bin/zsh
# Builds the Unbleed installer: build/Unbleed-<version>.pkg
#   /Applications/Unbleed.app
#   /Library/Audio/Plug-Ins/HAL/Unbleed Mic.driver, Unbleed Desktop.driver  (+ Core Audio restart)
# The package itself is unsigned (that needs a "Developer ID Installer" certificate); its contents are
# signed with your Developer ID. Open it with right-click → Open if Gatekeeper complains.
set -euo pipefail
cd "${0:A:h}/.."

[[ -d build/Unbleed.app && -d "build/drivers/Unbleed Mic.driver" ]] || ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
WORK=build/pkg
rm -rf $WORK && mkdir -p $WORK/app-root $WORK/driver-root $WORK/resources

# Stage without extended attributes: macOS tags every built file with a protected com.apple.provenance
# attribute that pkgbuild can't archive (it would also leave ._ AppleDouble files in the payload).
export COPYFILE_DISABLE=1
stage() { ditto --noextattr --noqtn --noacl "$1" "$2"; }
stage build/Unbleed.app $WORK/app-root/Unbleed.app
stage "build/drivers/Unbleed Mic.driver" "$WORK/driver-root/Unbleed Mic.driver"
stage "build/drivers/Unbleed Desktop.driver" "$WORK/driver-root/Unbleed Desktop.driver"

# Never "relocate" to wherever a dev build with the same bundle ID happens to live.
nonrelocatable() {
    pkgbuild --analyze --root $1 $2 >/dev/null
    local count=$(/usr/libexec/PlistBuddy -c "Print" $2 | grep -c "RootRelativeBundlePath" || true)
    for ((i = 0; i < count; i++)); do
        /usr/libexec/PlistBuddy -c "Set :$i:BundleIsRelocatable false" $2 2>/dev/null ||
            /usr/libexec/PlistBuddy -c "Add :$i:BundleIsRelocatable bool false" $2
    done
}
nonrelocatable $WORK/app-root $WORK/app.plist
nonrelocatable $WORK/driver-root $WORK/drivers.plist

# Installer scripts. The app installs first, then the drivers, so "before" runs with the app package
# (quit Unbleed, remember devices + driver fingerprints) and "after" with the drivers package (restart
# Core Audio only if needed, restore the user's devices, relaunch). Both get the signed helper.
swiftc -O packaging/audiodefaults.swift -o $WORK/audiodefaults
SIGN_ID=$(security find-identity -v -p codesigning | grep -oE '"Developer ID Application[^"]*"' | head -1 | tr -d '"')
codesign --force --options runtime ${RELEASE:+--timestamp} --sign "${SIGN_ID:--}" $WORK/audiodefaults 2>/dev/null
mkdir -p $WORK/app-scripts $WORK/driver-scripts
cp packaging/scripts/preinstall $WORK/audiodefaults $WORK/app-scripts/
cp packaging/scripts/postinstall $WORK/audiodefaults $WORK/driver-scripts/

pkgbuild --root $WORK/app-root --component-plist $WORK/app.plist --install-location /Applications \
    --scripts $WORK/app-scripts --identifier dev.unbleed.app.pkg --version $VERSION $WORK/UnbleedApp.pkg >/dev/null 2>&1

pkgbuild --root $WORK/driver-root --component-plist $WORK/drivers.plist \
    --install-location /Library/Audio/Plug-Ins/HAL --scripts $WORK/driver-scripts \
    --identifier dev.unbleed.drivers.pkg --version $VERSION $WORK/UnbleedDrivers.pkg >/dev/null 2>&1

# pkgbuild archives that protected attribute as AppleDouble "._" entries no matter what, and those would
# land inside the bundles and break their code signatures. Rebuild each payload and bill of materials
# without them.
clean_component() {
    local pkg=$1 root=$2 x=$WORK/expand-${1:t:r}
    rm -rf $x && pkgutil --expand $pkg $x
    tar --format cpio --no-mac-metadata --uid 0 --gid 0 --uname root --gname wheel -cf - -C $root . | gzip -9 > $x/Payload
    lsbom $x/Bom | grep -v '/\._' > $x/files && mkbom -i $x/files $x/Bom && rm $x/files
    local count=$(lsbom $x/Bom | wc -l | tr -d ' ')
    sed -i '' -E "s/numberOfFiles=\"[0-9]+\"/numberOfFiles=\"$count\"/" $x/PackageInfo
    rm $pkg && pkgutil --flatten $x $pkg
    if pkgutil --payload-files $pkg | grep -q '\._'; then echo "AppleDouble entries left in $pkg" >&2; exit 1; fi
}
clean_component $WORK/UnbleedApp.pkg $WORK/app-root
clean_component $WORK/UnbleedDrivers.pkg $WORK/driver-root

cp packaging/resources/*.html build/branding/installer-background.png $WORK/resources/
cat > $WORK/Distribution.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Unbleed</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <background file="installer-background.png" alignment="bottomleft" scaling="none"/>
    <background-darkAqua file="installer-background.png" alignment="bottomleft" scaling="none"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <domains enable_localSystem="true"/>
    <allowed-os-versions><os-version min="14.2"/></allowed-os-versions>
    <choices-outline>
        <line choice="default"><line choice="app"/><line choice="drivers"/></line>
    </choices-outline>
    <choice id="default"/>
    <choice id="app" visible="false"><pkg-ref id="dev.unbleed.app.pkg"/></choice>
    <choice id="drivers" visible="false"><pkg-ref id="dev.unbleed.drivers.pkg"/></choice>
    <pkg-ref id="dev.unbleed.app.pkg" version="$VERSION" onConclusion="none">UnbleedApp.pkg</pkg-ref>
    <pkg-ref id="dev.unbleed.drivers.pkg" version="$VERSION" onConclusion="none">UnbleedDrivers.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild --distribution $WORK/Distribution.xml --resources $WORK/resources --package-path $WORK \
    build/Unbleed-$VERSION.pkg >/dev/null
echo "built build/Unbleed-$VERSION.pkg"
