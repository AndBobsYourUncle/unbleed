#!/bin/zsh
# Builds Unbleed.app (the WebRTC AEC bridge, the neural pipeline and the Swift app), its artwork, and the
# Unbleed Mic / Unbleed Desktop drivers. Packaging: packaging/make_pkg.sh. Dev install: ./install.sh.
# First time on a fresh clone: scripts/bootstrap.sh (Homebrew deps, third-party sources, WebRTC build).
# RELEASE=1 adds secure timestamps to signatures (release.sh does this).
set -euo pipefail
cd "${0:A:h}"

BUILD=build
APP=$BUILD/Unbleed.app
WEBRTC_SRC=third_party/webrtc-audio-processing/webrtc
export PKG_CONFIG_PATH=$PWD/third_party/install/lib/pkgconfig

rm -rf $BUILD/StreamAudio.app  # pre-rename build
mkdir -p $BUILD $APP/Contents/MacOS $APP/Contents/Resources

# artwork: icon set, menu bar icon, installer background — drawn in code
swiftc -O branding/make_branding.swift -o $BUILD/make_branding
$BUILD/make_branding $BUILD/branding >/dev/null
iconutil -c icns $BUILD/branding/Unbleed.iconset -o $BUILD/branding/Unbleed.icns

clang++ -std=c++17 -O2 -w -c Sources/AEC/aec_bridge.cpp -o $BUILD/aec_bridge.o \
    -I $WEBRTC_SRC $(pkg-config --cflags webrtc-audio-processing-2) \
    -DWEBRTC_MAC -DWEBRTC_APM_DEBUG_DUMP=0

ORT=$(brew --prefix onnxruntime)
clang++ -std=c++17 -O2 -c Sources/Neural/neural_aec.cpp -o $BUILD/neural_aec.o -I $ORT/include/onnxruntime

# offline runners used by tools/evaluate.py
clang++ -std=c++17 -O2 -w tools/aec3_offline.cpp $BUILD/aec_bridge.o \
    $(pkg-config --libs webrtc-audio-processing-2) -o $BUILD/aec3_offline
clang++ -std=c++17 -O2 tools/naec_offline.cpp $BUILD/neural_aec.o \
    -L $ORT/lib -lonnxruntime -Wl,-rpath,$ORT/lib -framework Accelerate -o $BUILD/naec_offline

swiftc -O -swift-version 5 Sources/Unbleed/*.swift \
    -import-objc-header Sources/Bridging.h \
    $BUILD/aec_bridge.o $BUILD/neural_aec.o \
    $(pkg-config --libs webrtc-audio-processing-2) -lc++ \
    -L $ORT/lib -lonnxruntime -framework Accelerate \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Resources/Info.plist \
    -o $APP/Contents/MacOS/unbleed

cp Resources/Info.plist $APP/Contents/Info.plist
mkdir -p $APP/Contents/Resources/models
cp models/*.onnx $APP/Contents/Resources/models/
cp $BUILD/branding/Unbleed.icns $BUILD/branding/MenuBarIcon.png $BUILD/branding/MenuBarIcon@2x.png $APP/Contents/Resources/
rm -rf $APP/Contents/Resources/Licenses && mkdir -p $APP/Contents/Resources/Licenses
cp LICENSE $APP/Contents/Resources/Licenses/Unbleed-GPL-3.0.txt
cp licenses/DTLN-aec-MIT.txt $APP/Contents/Resources/Licenses/
cp licenses/webrtc-audio-processing-BSD.txt $APP/Contents/Resources/Licenses/
cp licenses/BlackHole-GPL-3.0.txt $APP/Contents/Resources/Licenses/

# Self-contained: copy ONNX Runtime and its Homebrew dependencies into Contents/Frameworks.
rm -rf $APP/Contents/Frameworks
python3 packaging/bundle_libs.py $APP

# macOS remembers mic/system-audio permission per signing identity. Ad-hoc signatures change on every
# build (so it would re-prompt each time); a real certificate keeps the permission across rebuilds.
# Hardened runtime always (so dev builds behave like releases); secure timestamps only with RELEASE=1.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning |
    grep -oE '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"')}
export UNBLEED_SIGN_FLAGS="--force --options runtime ${RELEASE:+--timestamp}"
[[ -n ${RELEASE:-} ]] || UNBLEED_SIGN_FLAGS+=" --timestamp=none"
for lib in $APP/Contents/Frameworks/*.dylib; do
    codesign ${=UNBLEED_SIGN_FLAGS} --sign "${IDENTITY:--}" $lib 2>/dev/null
done
codesign ${=UNBLEED_SIGN_FLAGS} --entitlements Resources/Unbleed.entitlements --sign "${IDENTITY:--}" $APP
echo "built $APP (signed: ${IDENTITY:-ad-hoc}${RELEASE:+, timestamped})"

drivers/build_drivers.sh >/dev/null && echo "built build/drivers/Unbleed Mic.driver, Unbleed Desktop.driver"

# small helpers: record any input device to a WAV; pull the audio tracks out of an OBS recording
swiftc -O tools/probe.swift -o $BUILD/probe 2>/dev/null
swiftc -O -swift-version 5 tools/extract_tracks.swift -o $BUILD/extract_tracks 2>/dev/null
