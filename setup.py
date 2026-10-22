#!/usr/bin/env python3
"""Liga (ou desliga) os hooks e a statusLine do Claudinho no
~/.claude/settings.json. Faz backup antes de mexer e não apaga o que já existe.
Os scripts são copiados pra ~/.claudinho/hooks, então o repo pode ser apagado depois.

    python3 setup.py            # instala
    python3 setup.py remover    # desfaz

Adaptado do kindle-claude, de Guilherme Pessoa (MIT):
https://github.com/guithepc/kindle-claude
"""
import json
import os
import shutil
import sys
import time

BASE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.expanduser(os.environ.get("CLAUDINHO_DIR", "~/.claudinho"))
ORIG = os.path.join(DATA, "orig_statusline.txt")
SETTINGS = os.path.expanduser(os.environ.get("CLAUDINHO_SETTINGS", "~/.claude/settings.json"))
PY = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else (sys.executable or "python3")
HOOKS = os.path.join(DATA, "hooks")
HOOK_CMD = f'"{PY}" "{os.path.join(HOOKS, "hook.py")}"'
STATUS_CMD = f'"{PY}" "{os.path.join(HOOKS, "statusline.py")}"'
EVENTS = {"PreToolUse": "*", "PostToolUse": "*", "UserPromptSubmit": None,
          "Notification": None, "Stop": None, "SessionEnd": None}
# "claudinho-widget" reconhece instalações antigas, que apontavam pra pasta do repo.
MARKS = (HOOKS, "claudinho-widget")


def mine(cmd):
    return any(m in (cmd or "") for m in MARKS)


def ours(entry):
    return any(mine(h.get("command")) for h in entry.get("hooks", []))


def load():
    if not os.path.exists(SETTINGS):
        return {}
    with open(SETTINGS, encoding="utf-8") as f:
        return json.load(f)


def save(cfg):
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    if os.path.exists(SETTINGS):
        bak = f"{SETTINGS}.bak-claudinho-{int(time.time())}"
        shutil.copy2(SETTINGS, bak)
        print(f"Backup salvo em {bak}")
    with open(SETTINGS, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write("\n")


def install():
    os.makedirs(HOOKS, exist_ok=True)
    for name in ("hook.py", "statusline.py"):
        shutil.copy2(os.path.join(BASE, "hooks", name), os.path.join(HOOKS, name))
    cfg = load()
    hooks = cfg.setdefault("hooks", {})
    for event, matcher in EVENTS.items():
        lst = [e for e in hooks.get(event, []) if not ours(e)]
        entry = {"hooks": [{"type": "command", "command": HOOK_CMD}]}
        if matcher:
            entry["matcher"] = matcher
        lst.append(entry)
        hooks[event] = lst

    current = (cfg.get("statusLine") or {}).get("command", "")
    if current and not mine(current):
        os.makedirs(DATA, exist_ok=True)
        with open(ORIG, "w", encoding="utf-8") as f:
            f.write(current)
        print("Sua statusLine antiga foi guardada e continua aparecendo.")
    cfg["statusLine"] = {"type": "command", "command": STATUS_CMD}
    save(cfg)
    print("Pronto! Reinicie as sessões do Claude Code pra elas começarem a mandar eventos.")


def remove():
    cfg = load()
    hooks = cfg.get("hooks", {})
    for event in list(hooks):
        hooks[event] = [e for e in hooks[event] if not ours(e)]
        if not hooks[event]:
            del hooks[event]
    if not hooks:
        cfg.pop("hooks", None)
    if mine((cfg.get("statusLine") or {}).get("command", "")):
        old = open(ORIG, encoding="utf-8").read().strip() if os.path.exists(ORIG) else ""
        if old:
            cfg["statusLine"] = {"type": "command", "command": old}
        else:
            cfg.pop("statusLine", None)
    save(cfg)
    print("Hooks e statusLine do Claudinho removidos.")


if __name__ == "__main__":
    remove() if sys.argv[1:] == ["remover"] else install()
