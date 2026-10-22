#!/usr/bin/env python3
"""statusLine do Claude Code: guarda o % exato da sessão (5h) e da semana em
~/.claudinho/statusline.json pro Claudinho, e imprime a linha de status.
Se você já tinha uma statusLine, ela continua aparecendo no lugar desta.

Adaptado do kindle-claude, de Guilherme Pessoa (MIT):
https://github.com/guithepc/kindle-claude
"""
import json
import os
import subprocess
import sys
import time

DATA = os.path.expanduser(os.environ.get("CLAUDINHO_DIR", "~/.claudinho"))
STATUS = os.path.join(DATA, "statusline.json")
ORIG = os.path.join(DATA, "orig_statusline.txt")


def save(data):
    rl = data.get("rate_limits")
    if not rl:  # só aparece depois da primeira resposta da sessão
        return
    os.makedirs(DATA, exist_ok=True)
    tmp = STATUS + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"rate_limits": rl, "saved_at": time.time()}, f)
    os.replace(tmp, STATUS)


def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except Exception:
        data = {}
    try:
        save(data)
    except Exception:
        pass

    if os.path.exists(ORIG):
        cmd = open(ORIG, encoding="utf-8").read().strip()
        if cmd:
            try:
                out = subprocess.run(cmd, shell=True, input=raw, text=True,
                                     capture_output=True, timeout=5).stdout
                sys.stdout.write(out)
                return
            except Exception:
                pass

    rl = data.get("rate_limits") or {}
    parts = [(data.get("model") or {}).get("display_name", "Claude")]
    for key, label in (("five_hour", "sessão"), ("seven_day", "semana")):
        pct = (rl.get(key) or {}).get("used_percentage")
        if pct is not None:
            parts.append(f"{label} {pct:.0f}%")
    print(" · ".join(parts))


if __name__ == "__main__":
    main()
