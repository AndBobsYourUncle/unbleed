#!/bin/zsh
# Developer install: copies the freshly built app to ~/Applications (the drivers need the .pkg or
# packaging/install_drivers.sh, since they go in /Library and need admin rights).
set -euo pipefail
cd "${0:A:h}"
[[ -d build/Unbleed.app ]] || ./build.sh
mkdir -p ~/Applications
pkill -INT -f "Unbleed.app/Contents/MacOS/unbleed" 2>/dev/null && sleep 1 || true
rm -rf ~/Applications/Unbleed.app
cp -R build/Unbleed.app ~/Applications/
echo "installed ~/Applications/Unbleed.app"
