#!/usr/bin/env python3
"""Testes dos hooks, da statusLine e do setup.py, em pastas temporárias."""
import json
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY = sys.executable
fails = 0


def check(cond, what):
    global fails
    if not cond:
        fails += 1
        print(f"  FALHOU  {what}")


def run(script, payload, env, args=()):
    return subprocess.run([PY, os.path.join(REPO, script), *args], input=payload, text=True,
                          capture_output=True, env=env)


with tempfile.TemporaryDirectory() as tmp:
    env = dict(os.environ, CLAUDINHO_DIR=os.path.join(tmp, "data"), CLAUDINHO_SETTINGS=os.path.join(tmp, "settings.json"))
    state = os.path.join(tmp, "data", "state.json")

    print("• hook.py")
    ev = lambda **k: json.dumps(dict(session_id="s1", cwd="/x/proj", **k))
    r = run("hooks/hook.py", ev(hook_event_name="PreToolUse", tool_name="Bash",
                                tool_input={"command": "ls -la", "description": "Lista"}), env)
    check(r.returncode == 0 and r.stdout == "", "hook não imprime nada e sai com 0")
    s = json.load(open(state))["sessions"]["s1"]
    check(s["status"] == "working" and s["tool_running"] and s["tool_name"] == "Bash" and s["tool_desc"] == "Lista", "PreToolUse grava a ferramenta")
    check(s["project"] == "proj", "projeto vem do cwd")
    run("hooks/hook.py", ev(hook_event_name="Notification", message="Claude needs your permission to use Bash"), env)
    check(json.load(open(state))["sessions"]["s1"]["status"] == "asking", "Notification de permissão = asking")
    run("hooks/hook.py", ev(hook_event_name="Notification", message="Claude is waiting for your input"), env)
    check(json.load(open(state))["sessions"]["s1"]["status"] == "waiting", "outra Notification = waiting")
    run("hooks/hook.py", ev(hook_event_name="Stop"), env)
    check(json.load(open(state))["sessions"]["s1"]["status"] == "done", "Stop = done")
    r = run("hooks/hook.py", "isso não é json", env)
    check(r.returncode == 0, "entrada quebrada não derruba o hook")

    print("• statusline.py")
    payload = json.dumps({"model": {"display_name": "Opus"}, "rate_limits": {
        "five_hour": {"used_percentage": 23.5, "resets_at": 1793000000},
        "seven_day": {"used_percentage": 12, "resets_at": 1793500000}}})
    r = run("hooks/statusline.py", payload, env)
    check("sessão 24%" in r.stdout and "semana 12%" in r.stdout, f"imprime a linha de status ({r.stdout.strip()})")
    saved = json.load(open(os.path.join(tmp, "data", "statusline.json")))
    check(saved["rate_limits"]["five_hour"]["used_percentage"] == 23.5 and "saved_at" in saved, "guarda o % exato")
    run("hooks/statusline.py", json.dumps({"model": {}}), env)
    check(json.load(open(os.path.join(tmp, "data", "statusline.json")))["rate_limits"], "sem rate_limits não apaga o anterior")

    print("• setup.py")
    original = {"theme": "dark", "statusLine": {"type": "command", "command": "echo minha"},
                "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say oi"}]}]}}
    json.dump(original, open(env["CLAUDINHO_SETTINGS"], "w"))
    for _ in range(2):  # rodar duas vezes não duplica
        r = run("setup.py", "", env)
        check(r.returncode == 0, f"setup instala ({r.stderr.strip()[:80]})")
    cfg = json.load(open(env["CLAUDINHO_SETTINGS"]))
    check(sorted(cfg["hooks"]) == ["Notification", "PostToolUse", "PreToolUse", "SessionEnd", "Stop", "UserPromptSubmit"], "seis eventos ligados")
    check(len(cfg["hooks"]["Stop"]) == 2 and len(cfg["hooks"]["PreToolUse"]) == 1, "não duplica e mantém o hook que já existia")
    check(os.path.join(tmp, "data", "hooks") in cfg["statusLine"]["command"], "statusLine aponta pra cópia fora do repo")
    check(os.path.exists(os.path.join(tmp, "data", "hooks", "hook.py")), "hooks copiados pra ~/.claudinho/hooks")
    check(REPO not in json.dumps(cfg), "nada aponta pra pasta do repo")
    r = run(os.path.join(tmp, "data", "hooks", "statusline.py"), payload, env)
    check("minha" in r.stdout, "statusLine antiga continua aparecendo")
    run("setup.py", "", env, ["remover"])
    check(json.load(open(env["CLAUDINHO_SETTINGS"])) == original, "remover devolve o settings.json original")

print(f"\nhooks: {'ok' if fails == 0 else f'{fails} falha(s)'}")
sys.exit(1 if fails else 0)
