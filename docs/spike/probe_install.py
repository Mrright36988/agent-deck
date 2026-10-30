#!/usr/bin/python3
"""Install or remove the agent-deck spike probe hooks.

install    back up ~/.claude/settings.json and ~/.codex/hooks.json, then append probe hook groups
uninstall  drop every hook whose command runs probe_hook.py; if what remains equals the backup,
           copy the backup back so the file is byte-identical to before
status     show which probe hooks are installed
"""
import glob
import json
import os
import shutil
import sys
import time

PROBE = os.path.join(os.path.dirname(os.path.realpath(__file__)), "probe_hook.py")
MARK = "probe_hook.py"
CLAUDE = os.path.expanduser("~/.claude/settings.json")
CODEX = os.path.expanduser("~/.codex/hooks.json")


def group(tool, event, timeout, matcher=None):
    g = {"hooks": [{"type": "command", "command": "/usr/bin/python3 %s %s %s || true" % (PROBE, tool, event),
                    "timeout": timeout}]}
    if matcher:
        g["matcher"] = matcher
    return g


PLAN = {
    CLAUDE: {
        "SessionStart": [group("claude", "SessionStart", 10)],
        "UserPromptSubmit": [group("claude", "UserPromptSubmit", 10)],
        "PreToolUse": [group("claude", "PreToolUse", 90, matcher="AskUserQuestion")],
        "PermissionRequest": [group("claude", "PermissionRequest", 90)],
        "Notification": [group("claude", "Notification", 10)],
        "Stop": [group("claude", "Stop", 90)],
    },
    CODEX: {
        "SessionStart": [group("codex", "SessionStart", 10)],
        "UserPromptSubmit": [group("codex", "UserPromptSubmit", 10)],
        "PermissionRequest": [group("codex", "PermissionRequest", 90)],
        "Stop": [group("codex", "Stop", 90)],
    },
}


def load(path):
    with open(path) as f:
        return json.load(f)


def save(path, data):
    tmp = path + ".deck-probe.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def is_probe(hook):
    return MARK in (hook.get("command") or "")


def installed(data):
    return [ev for ev, groups in data.get("hooks", {}).items()
            for g in groups for h in g.get("hooks", []) if is_probe(h)]


def strip(data):
    hooks = data.get("hooks", {})
    for ev in list(hooks):
        kept = []
        for g in hooks[ev]:
            g = dict(g, hooks=[h for h in g.get("hooks", []) if not is_probe(h)])
            if g["hooks"]:
                kept.append(g)
        if kept:
            hooks[ev] = kept
        else:
            del hooks[ev]
    return data


def install():
    stamp = time.strftime("%Y%m%d%H%M%S")
    for path, events in PLAN.items():
        data = load(path)
        if installed(data):
            sys.exit("already installed in %s; run uninstall first" % path)
        shutil.copy2(path, "%s.bak.deck-probe-%s" % (path, stamp))
        hooks = data.setdefault("hooks", {})
        for ev, groups in events.items():
            hooks.setdefault(ev, []).extend(groups)
        save(path, data)
        print("installed %d events into %s (backup .bak.deck-probe-%s)" % (len(events), path, stamp))


def uninstall():
    for path in PLAN:
        data = load(path)
        if not installed(data):
            print("nothing to remove in %s" % path)
            continue
        data = strip(data)
        backups = sorted(glob.glob(path + ".bak.deck-probe-*"))
        if backups and load(backups[-1]) == data:
            shutil.copy2(backups[-1], path)
            print("restored %s byte-for-byte from %s" % (path, os.path.basename(backups[-1])))
        else:
            save(path, data)
            print("removed probe hooks from %s; other edits made since install were kept" % path)


def status():
    for path in PLAN:
        print(path, "->", installed(load(path)) or "none")


if __name__ == "__main__":
    {"install": install, "uninstall": uninstall, "status": status}[sys.argv[1]]()
