#!/bin/zsh
# One-time setup for a fresh clone: Homebrew dependencies, third-party sources at the exact commits
# Unbleed was built against, and the WebRTC audio-processing library. Then: ./build.sh
#   --tools   also create .venv with the Python research/evaluation tools (tools/*.py)
set -euo pipefail
cd "${0:A:h}/.."

echo "▸ Homebrew dependencies"
brew install meson ninja pkg-config abseil onnxruntime

clone() {  # dir url commit
    if [[ ! -d third_party/$1/.git ]]; then
        git clone --quiet $2 third_party/$1
    fi
    git -C third_party/$1 fetch --quiet --depth 1 origin $3 2>/dev/null || true
    git -C third_party/$1 checkout --quiet $3
    echo "  third_party/$1 @ ${3:0:7}"
}
echo "▸ third-party sources"
mkdir -p third_party
clone webrtc-audio-processing https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git d0569cfa50c1858ee279d77b3fc8870be6902441
clone BlackHole https://github.com/ExistentialAudio/BlackHole.git 561d934c77a1fa64987e01ccabe890fed30e181f
clone DTLN-aec https://github.com/breizhn/DTLN-aec.git 9d24e128b4f409db18227b8babb343016625921f

echo "▸ building webrtc-audio-processing (static)"
(
    cd third_party/webrtc-audio-processing
    [[ -d build ]] || meson setup build --prefix=$PWD/../install --buildtype=release --default-library=static >/dev/null
    # the bundled example fails to link on macOS; only the library is needed
    ninja -C build webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a >/dev/null
    meson install -C build --no-rebuild >/dev/null
)

if [[ ${1:-} == --tools ]]; then
    echo "▸ Python tools (.venv)"
    brew install uv
    uv venv -p 3.12 .venv >/dev/null
    uv pip install --python .venv/bin/python -r tools/requirements.txt >/dev/null
fi

echo "✅ ready — now run ./build.sh"
