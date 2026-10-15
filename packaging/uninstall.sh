#!/bin/zsh
# Removes Unbleed: the app, both audio devices, and the installer receipts. Keeps your settings and
# learned state in ~/Library/Application Support/Unbleed (delete that folder too for a clean slate).
# Run with: sudo packaging/uninstall.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1 }
pkill -INT -f "Unbleed.app/Contents/MacOS/unbleed" 2>/dev/null || true
rm -rf /Applications/Unbleed.app
rm -rf "/Library/Audio/Plug-Ins/HAL/Unbleed Mic.driver" "/Library/Audio/Plug-Ins/HAL/Unbleed Desktop.driver"
pkgutil --forget dev.unbleed.app.pkg >/dev/null 2>&1 || true
pkgutil --forget dev.unbleed.drivers.pkg >/dev/null 2>&1 || true
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod
echo "Unbleed removed"
