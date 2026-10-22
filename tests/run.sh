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

echo "\n== certificado"
# `security` de mentira: o chaveiro de verdade não é tocado
mkdir -p "$TMP/fake"
cat > "$TMP/fake/security" <<'FAKE'
#!/bin/sh
cat <<OUT
  1) 1111111111111111111111111111111111111111 "Developer ID Application: Outro (ZZZ)"
  2) ABCDEF0123456789ABCDEF0123456789ABCDEF01 "Apple Development: Nicolas (ABCDE12345)"
     2 valid identities found
OUT
FAKE
printf '#!/bin/sh\necho "     0 valid identities found"\n' > "$TMP/fake/security-vazio"
chmod +x "$TMP/fake/security" "$TMP/fake/security-vazio"
[[ $(env -u CLAUDINHO_SIGN_IDENTITY PATH="$TMP/fake:$PATH" tools/identidade.sh) == ABCDEF0123456789ABCDEF0123456789ABCDEF01 ]] || { echo "  FALHOU  acha o Apple Development"; exit 1; }
mv "$TMP/fake/security-vazio" "$TMP/fake/security"
[[ $(env -u CLAUDINHO_SIGN_IDENTITY PATH="$TMP/fake:$PATH" tools/identidade.sh) == "-" ]] || { echo "  FALHOU  sem certificado = ad hoc"; exit 1; }
[[ $(CLAUDINHO_SIGN_IDENTITY="X (1)" PATH="$TMP/fake:$PATH" tools/identidade.sh) == "X (1)" ]] || { echo "  FALHOU  variável manda"; exit 1; }
echo "certificado ok (acha sozinho, cai pra ad hoc, a variável manda)"

echo "\n== build do app"
./build.sh >/dev/null
plutil -lint -s build/Claudinho.app/Contents/Info.plist
codesign -v build/Claudinho.app
W=build/Claudinho.app/Contents/PlugIns/ClaudinhoWidget.appex
if [[ $(tools/identidade.sh) != "-" ]]; then
  plutil -lint -s "$W/Contents/Info.plist"
  [[ $(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$W/Contents/Info.plist") == com.apple.widgetkit-extension ]]
  [[ $(plutil -extract CFBundleIdentifier raw "$W/Contents/Info.plist") == local.claudinho.monitor.widget ]]
  codesign -d --entitlements - "$W" 2>/dev/null | grep -q app-sandbox
  codesign -d --entitlements - "$W" 2>/dev/null | grep -q /.claudinho/
  codesign -v "$W"
  echo "app ok (com o widget nativo embutido, em sandbox, lendo só ~/.claudinho)"
else
  [[ ! -d "$W" ]]   # sem certificado, o widget que trava não pode ir junto
  # o widget ainda tem que compilar como extensão, pra não apodrecer até ter certificado
  swiftc -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library -application-extension \
    Sources/Sprites.swift Sources/Style.swift Sources/WidgetData.swift Widget/ClaudinhoWidget.swift -o "$TMP/bin/widget"
  echo "app ok (sem o widget nativo: falta certificado; o código dele compila e é testado)"
fi
