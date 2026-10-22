#!/bin/zsh
# Instala o Claudinho em ~/Applications e faz ele abrir sozinho no login
# (e voltar se fechar com erro). "Sair" no menu fecha de verdade até o próximo login.
# Desinstalar: ./install.sh --uninstall
set -e
cd "$(dirname "$0")"
LABEL=local.claudinho.monitor
DEST="$HOME/Applications/Claudinho.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -x Claudinho 2>/dev/null || true

if [[ "$1" == "--uninstall" ]]; then
  pluginkit -r "$DEST/Contents/PlugIns/ClaudinhoWidget.appex" 2>/dev/null || true
  rm -f "$AGENT"; rm -rf "$DEST"
  echo "Claudinho removido (config em ~/.claudinho mantida)."
  exit 0
fi

./build.sh
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/.claudinho"
[[ -d "$DEST/Contents/PlugIns/ClaudinhoWidget.appex" ]] && pluginkit -r "$DEST/Contents/PlugIns/ClaudinhoWidget.appex" 2>/dev/null || true
rm -rf "$DEST"
cp -R build/Claudinho.app "$DEST"
# Registra o app e o widget no macOS (o widget aparece na galeria de widgets).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSREGISTER -f "$DEST" 2>/dev/null || true
[[ -d "$DEST/Contents/PlugIns/ClaudinhoWidget.appex" ]] && pluginkit -a "$DEST/Contents/PlugIns/ClaudinhoWidget.appex" 2>/dev/null || true

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/Claudinho</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ThrottleInterval</key><integer>30</integer>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$UID" "$AGENT"
echo "ok: Claudinho instalado em $DEST e abrindo no login."
