#!/bin/zsh
# Builds and signs build/SD Import.app.  `./build.sh install` also copies it to /Applications and opens it.
set -euo pipefail
cd "${0:A:h}"

APP="build/SD Import.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  -o "$APP/Contents/MacOS/SDImport" Sources/*.swift

# First valid Apple Development identity, unless SIGN_ID is set. A stable signature keeps the Photos grant across rebuilds.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --timestamp=none --sign "${SIGN_ID:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [[ "${1:-}" == install ]]; then
  pkill -x SDImport 2>/dev/null || true
  rm -rf "/Applications/SD Import.app"
  cp -R "$APP" /Applications/
  open "/Applications/SD Import.app"
  echo "Installed to /Applications and launched"
fi
