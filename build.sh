#!/bin/zsh
# Compila o Claudinho.app (só barra de menu, sem ícone no Dock).
#   ./build.sh             -> build/Claudinho.app
#   ./build.sh --preview   -> regenera as imagens do README em docs/img
#   ./build.sh --icon      -> regenera Resources/AppIcon.icns a partir do sprite
set -e
cd "$(dirname "$0")"
SWIFTC=(swiftc -O -swift-version 5 -target arm64-apple-macos14.0)

if [[ "$1" == "--preview" ]]; then
  mkdir -p build
  # sem -parse-as-library: o main.swift da ferramenta roda como script
  $SWIFTC -D PREVIEW Sources/*.swift tools/preview/main.swift -o build/preview
  ./build/preview docs/img
  exit 0
fi

if [[ "$1" == "--icon" ]]; then
  mkdir -p build Resources
  rm -rf build/AppIcon.iconset
  $SWIFTC Sources/Sprites.swift tools/icon/main.swift -o build/icon
  ./build/icon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
  echo "ok: Resources/AppIcon.icns"
  exit 0
fi

APP=build/Claudinho.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claudinho</string>
  <key>CFBundleIdentifier</key><string>local.claudinho.monitor</string>
  <key>CFBundleExecutable</key><string>Claudinho</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
$SWIFTC -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/Claudinho"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "ok: $APP"
