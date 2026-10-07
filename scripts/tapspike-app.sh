#!/bin/zsh
# Wraps TapSpike in a minimal .app so TCC attributes the audio-capture prompt to
# TapSpike itself (a bare CLI is attributed to the terminal that launched it).
# Usage: scripts/tapspike-app.sh   (Ctrl+C stops it and cleans up the tap)
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product TapSpike
app=.build/TapSpike.app
rm -rf $app && mkdir -p $app/Contents/MacOS
cp .build/release/TapSpike $app/Contents/MacOS/
cp Support/TapSpike-Info.plist $app/Contents/Info.plist
# ponytail: ad-hoc signature changes every build, so macOS may ask again after a rebuild.
codesign --force --sign - --identifier local.musicamp.tapspike $app

# `open` makes LaunchServices the parent, so the app is its own responsible process.
trap 'pkill -TERM -f "$app/Contents/MacOS/TapSpike" || true' INT TERM
open -W -n --stdout "$(tty)" --stderr "$(tty)" $app &
wait $! || true
