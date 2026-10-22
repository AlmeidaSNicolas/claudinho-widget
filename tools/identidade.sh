#!/bin/zsh
# Imprime a identidade de assinatura a usar: CLAUDINHO_SIGN_IDENTITY se estiver definida,
# senão o primeiro certificado "Apple Development" do chaveiro, senão "-" (ad hoc).
if [[ -n "$CLAUDINHO_SIGN_IDENTITY" ]]; then
  print -r -- "$CLAUDINHO_SIGN_IDENTITY"
  exit 0
fi
id=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: /{print $2; exit}')
print -r -- "${id:--}"
