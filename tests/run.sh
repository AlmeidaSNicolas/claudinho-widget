#!/bin/zsh
# Roda todos os testes. Não mexe em ~/.claudinho, ~/.claude nem no app instalado.
#   ./tests/run.sh
set -e
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/data" "$TMP/projects" "$TMP/bin"

echo "== hooks e setup (python)"
/usr/bin/python3 tests/hooks_test.py

echo "\n== unidade (swift)"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -D PREVIEW Sources/*.swift Widget/ClaudinhoWidget.swift tests/unit/main.swift -o "$TMP/bin/unit" 2>&1 | grep -E "error" && exit 1
CLAUDINHO_DIR="$TMP/data" CLAUDINHO_PROJECTS="$TMP/projects" CLAUDINHO_FIXTURES="$PWD/tests/fixtures" "$TMP/bin/unit"

echo "\n== build do app"
./build.sh >/dev/null
plutil -lint -s build/Claudinho.app/Contents/Info.plist
codesign -v build/Claudinho.app
W=build/Claudinho.app/Contents/PlugIns/ClaudinhoWidget.appex
plutil -lint -s "$W/Contents/Info.plist"
[[ $(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$W/Contents/Info.plist") == com.apple.widgetkit-extension ]]
[[ $(plutil -extract CFBundleIdentifier raw "$W/Contents/Info.plist") == local.claudinho.monitor.widget ]]
codesign -d --entitlements - "$W" 2>/dev/null | grep -q app-sandbox
codesign -d --entitlements - "$W" 2>/dev/null | grep -q /.claudinho/
codesign -v "$W"
echo "app ok (com o widget embutido, em sandbox, lendo só ~/.claudinho)"
