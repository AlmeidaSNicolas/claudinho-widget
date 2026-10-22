#!/usr/bin/env python3
"""Hook do Claude Code: conta pro Claudinho o que cada sessão está fazendo.
Grava em ~/.claudinho/state.json, uma entrada por session_id.
Só usa a biblioteca padrão, nunca imprime nada e nunca falha.

  UserPromptSubmit -> trabalhando, pensando
  PreToolUse       -> trabalhando, com a ferramenta no fogo
  PostToolUse      -> trabalhando, ferramenta terminou
  Notification     -> pedindo permissão ou esperando você
  Stop             -> terminou
  SessionEnd       -> sessão fechada
"""
import fcntl
import json
import os
import sys
import time

DATA = os.path.expanduser(os.environ.get("CLAUDINHO_DIR", "~/.claudinho"))
STATE = os.path.join(DATA, "state.json")
LOCK = os.path.join(DATA, "state.lock")
FORGET_AFTER = 6 * 3600


def describe(tool, inp):
    if not isinstance(inp, dict):
        return ""
    if tool == "Bash":
        return inp.get("description") or (inp.get("command") or "").split("\n")[0]
    for key in ("file_path", "notebook_path", "path"):
        if inp.get(key):
            return os.path.basename(str(inp[key]).rstrip("/"))
    for key in ("pattern", "query", "url", "description", "prompt"):
        if inp.get(key):
            return str(inp[key]).split("\n")[0]
    return ""


def apply(state, ev, now):
    name = ev.get("hook_event_name", "")
    sessions = state.setdefault("sessions", {})
    s = sessions.setdefault(ev.get("session_id") or "sem-id", {})
    if ev.get("cwd"):
        s["project"] = os.path.basename(ev["cwd"].rstrip("/"))

    if name == "PreToolUse":
        tool = ev.get("tool_name", "?")
        s.update(status="working", tool_running=True, tool_name=tool,
                 tool_desc=describe(tool, ev.get("tool_input"))[:120])
    elif name in ("PostToolUse", "UserPromptSubmit"):
        s.update(status="working", tool_running=False)
    elif name == "Notification":
        asking = "permission" in (ev.get("message") or "").lower()
        s.update(status="asking" if asking else "waiting", tool_running=False)
    elif name == "Stop":
        s.update(status="done", tool_running=False)
    elif name == "SessionEnd":
        s.update(status="closed", tool_running=False)
    else:
        return False

    s["last_event"] = now
    for sid in [k for k, v in sessions.items() if now - v.get("last_event", 0) > FORGET_AFTER]:
        del sessions[sid]
    return True


def main():
    try:
        ev = json.load(sys.stdin)
    except Exception:
        return
    os.makedirs(DATA, exist_ok=True)
    # vários agentes podem chamar o hook ao mesmo tempo
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(STATE, encoding="utf-8") as f:
                state = json.load(f)
        except Exception:
            state = {}
        if not apply(state, ev, time.time()):
            return
        tmp = STATE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False)
        os.replace(tmp, STATE)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
