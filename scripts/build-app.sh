#!/bin/zsh
# Builds .build/MusicAmp.app (release). Run it with: open .build/MusicAmp.app
# As its own app, MusicAmp asks for Audio Recording and Automation (Music) on first launch.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product MusicAmp
app=.build/MusicAmp.app
rm -rf $app && mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp .build/release/MusicAmp $app/Contents/MacOS/
cp Support/MusicAmp-Info.plist $app/Contents/Info.plist
cp Support/base-2.91.wsz $app/Contents/Resources/
# ponytail: ad-hoc signature changes every build, so macOS may ask for permissions again after a rebuild.
codesign --force --sign - --identifier local.musicamp $app
echo "Built $app"
