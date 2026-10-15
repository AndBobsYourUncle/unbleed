#!/bin/zsh
# Builds Unbleed's two virtual audio devices from the BlackHole source (GPL-3.0, third_party/BlackHole):
#   "Unbleed Mic"     — Unbleed writes your cleaned voice here; OBS reads it as a mic
#   "Unbleed Desktop" — Unbleed writes the desktop mix (minus itself) here; OBS reads it as game audio
# Both are 2-channel, 48 kHz only, without a volume control, and can't become the system default
# input/output — so nothing else ends up routed through them by accident.
# BlackHole's name and artwork are not used (its license doesn't allow that for modified builds).
set -euo pipefail
cd "${0:A:h}/.."

SRC=third_party/BlackHole/BlackHole/BlackHole.c
OUT=build/drivers
ICON=build/branding/Unbleed.icns
mkdir -p $OUT
[[ -f $ICON ]] || { echo "run build.sh first (needs the icon)" >&2; exit 1 }

# Patch the user-visible branded strings (box name, model name, overload log) in a build copy.
sed -e 's/CFSTR("BlackHole Box")/CFSTR(kDriver_Name " Box")/' \
    -e 's/CFSTR("BlackHole")/CFSTR(kDriver_Name)/' \
    -e "s/implemented by the BlackHole driver/implemented by the \" kDriver_Name \" driver/" \
    -e 's/DebugMsg("BlackHole overload error/DebugMsg(kDriver_Name " overload error/' \
    $SRC > $OUT/UnbleedDevice.c
for marker in 'kDriver_Name " Box"' 'CFSTR(kDriver_Name)' 'kDriver_Name " overload'; do
    grep -qF "$marker" $OUT/UnbleedDevice.c || { echo "patch failed ($marker) — BlackHole source changed?" >&2; exit 1 }
done

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning |
    grep -oE '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"')}

# name | bundle id | plug-in factory UUID (must be unique per driver)
build_driver() {
    local name=$1 bundle=$2 factory=$3
    local exe=${name// /}
    local dir="$OUT/$name.driver"
    rm -rf "$dir"
    mkdir -p "$dir/Contents/MacOS" "$dir/Contents/Resources"

    clang -bundle -O2 -arch arm64 -mmacosx-version-min=12.0 -w \
        -DkDriver_Name="\"$name\"" -DkPlugIn_BundleID="\"$bundle\"" -DkPlugIn_Icon='"Unbleed.icns"' \
        -DkHas_Driver_Name_Format=false -DkDevice_Name="\"$name\"" -DkManufacturer_Name='"Unbleed"' \
        -DBlackHole_Create=Unbleed_Create -DkNumber_Of_Channels=2 -DkSampleRates=48000 -DkEnableVolumeControl=false \
        -DkCanBeDefaultDevice=false -DkCanBeDefaultSystemDevice=false \
        -framework CoreAudio -framework CoreFoundation -framework Accelerate \
        $OUT/UnbleedDevice.c -o "$dir/Contents/MacOS/$exe"

    cp $ICON "$dir/Contents/Resources/Unbleed.icns"
    cat > "$dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>English</string>
    <key>CFBundleExecutable</key><string>$exe</string>
    <key>CFBundleIconFile</key><string>Unbleed.icns</string>
    <key>CFBundleIdentifier</key><string>$bundle</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFPlugInFactories</key>
    <dict><key>$factory</key><string>Unbleed_Create</string></dict>
    <key>CFPlugInTypes</key>
    <dict><key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key><array><string>$factory</string></array></dict>
</dict>
</plist>
EOF
    codesign ${=UNBLEED_SIGN_FLAGS:---force} --sign "${IDENTITY:--}" "$dir"
    echo "built $dir"
}

build_driver "Unbleed Mic"     dev.unbleed.driver.mic     7C1F5B2E-3A4D-4E8B-9F21-6D0A8C3E5B71
build_driver "Unbleed Desktop" dev.unbleed.driver.desktop B4E2A913-58C6-4F07-A1D3-2E9F7C40D86A
