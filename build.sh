#!/bin/zsh
# Compila o Claudinho.app (só barra de menu, sem ícone no Dock).
#   ./build.sh             -> build/Claudinho.app
#   ./build.sh --preview   -> regenera as imagens do README em docs/img
#   ./build.sh --icon      -> regenera Resources/AppIcon.icns a partir do sprite
#
# O widget nativo (WidgetKit) só entra com um certificado de desenvolvedor: o macOS derruba
# widgets assinados ad hoc. Veja docs/problemas.md. O certificado "Apple Development" do
# chaveiro é achado sozinho; pra escolher outro:
#   CLAUDINHO_SIGN_IDENTITY="Apple Development: Fulano (ABCDE12345)" ./build.sh
set -e
cd "$(dirname "$0")"
SWIFTC=(swiftc -O -swift-version 5 -target arm64-apple-macos14.0)

if [[ "$1" == "--preview" ]]; then
  mkdir -p build
  # sem -parse-as-library: o main.swift da ferramenta roda como script
  $SWIFTC -D PREVIEW Sources/*.swift Widget/ClaudinhoWidget.swift tools/preview/main.swift -o build/preview
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

VERSION=0.3
BUILD=$(date +%s)   # build novo a cada compilação, pro macOS recarregar o widget
APP=build/Claudinho.app
WIDGET="$APP/Contents/PlugIns/ClaudinhoWidget.appex"
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
  <key>CFBundleShortVersionString</key><string>VERSION</string>
  <key>CFBundleVersion</key><string>BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
sed -i '' -e "s/VERSION/$VERSION/" -e "s/BUILD/$BUILD/" "$APP/Contents/Info.plist"
$SWIFTC -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/Claudinho"

SIGN=$(tools/identidade.sh)
if [[ "$SIGN" != "-" ]]; then
  # Widget: extensão embutida no app, com só as peças de desenho e o arquivo de dados.
  mkdir -p "$WIDGET/Contents/MacOS"
  sed -e "s/VERSION/$VERSION/" -e "s/BUILD/$BUILD/" Widget/Info.plist > "$WIDGET/Contents/Info.plist"
  $SWIFTC -parse-as-library -application-extension \
    Sources/Sprites.swift Sources/Style.swift Sources/WidgetData.swift Widget/ClaudinhoWidget.swift \
    -o "$WIDGET/Contents/MacOS/ClaudinhoWidget"
  # primeiro o widget (com o sandbox), depois o app por fora
  codesign --force --sign "$SIGN" --entitlements Widget/Widget.entitlements "$WIDGET" >/dev/null 2>&1
fi
codesign --force --sign "$SIGN" "$APP" >/dev/null 2>&1
if [[ "$SIGN" == "-" ]]; then
  echo "(widget nativo fora: nenhum certificado Apple Development no chaveiro)"
else
  echo "(widget nativo dentro, assinado com $SIGN)"
fi
echo "ok: $APP"
