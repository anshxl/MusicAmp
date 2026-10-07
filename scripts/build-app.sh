#!/bin/zsh
# Builds .build/MusicAmp.app (release, ad-hoc signed).
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  build, copy to /Applications (or ~/Applications), and open it
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

if [[ "${1:-}" == "--install" ]]; then
    dest="${INSTALL_DIR:-/Applications}"
    [[ -w "$dest" ]] || dest="$HOME/Applications"
    mkdir -p "$dest"
    pkill -x MusicAmp && sleep 1 || true # replace a running copy
    rm -rf "$dest/MusicAmp.app"
    ditto $app "$dest/MusicAmp.app"
    echo "Installed $dest/MusicAmp.app"
    open "$dest/MusicAmp.app"
fi
