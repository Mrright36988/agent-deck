#!/usr/bin/python3
"""agent-deck hook: forwards a Claude Code or Codex hook event to the AgentDeck app.

Usage (from the hooks config): deck-hook <claude|codex> <EventName>

Reads the hook input on stdin and sends it over the app's unix socket. For PermissionRequest it
waits for the app's answer and prints it. Whenever the app is unreachable, or anything goes wrong,
it exits 0 without output, so the session carries on as if agent-deck were not installed.

Cursor also runs the hooks in ~/.claude/settings.json for its own agent. Those calls carry
`cursor_version` in their input and are ignored: they are not Claude Code sessions.
"""
import json
import os
import socket
import sys

SOCKET_PATH = os.environ.get("AGENT_DECK_SOCKET") or os.path.expanduser(
    "~/Library/Application Support/agent-deck/deck.sock")
WAIT_EVENTS = {"PermissionRequest"}
WAIT_SECONDS = 590  # below the 600 s hook timeout, so the hook always ends on its own terms


def forward(tool, event, payload):
    wait = event in WAIT_EVENTS
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        conn.settimeout(0.1)
        conn.connect(SOCKET_PATH)
        conn.settimeout(WAIT_SECONDS if wait else 1.0)
        message = {"v": 1, "tool": tool, "event": event, "wait": wait, "payload": payload}
        conn.sendall(json.dumps(message, ensure_ascii=False).encode() + b"\n")
        if not wait:
            return None
        reply = b""
        while not reply.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            reply += chunk
        return json.loads(reply or b"{}").get("output")
    finally:
        conn.close()


def main():
    tool, event = sys.argv[1], sys.argv[2]
    raw = sys.stdin.read()
    payload = json.loads(raw) if raw.strip() else {}
    if "cursor_version" in payload:
        return
    output = forward(tool, event, payload)
    if output:
        sys.stdout.write(json.dumps(output, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
