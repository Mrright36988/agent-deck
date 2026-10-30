"""Tests for deck_hook.py. Run: /usr/bin/python3 -m unittest discover -s hook"""
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import unittest

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "deck_hook.py")


def run_hook(socket_path, tool, event, stdin):
    env = dict(os.environ, AGENT_DECK_SOCKET=socket_path)
    started = time.monotonic()
    proc = subprocess.run(["/usr/bin/python3", HOOK, tool, event], input=stdin.encode(),
                          capture_output=True, env=env, timeout=10)
    return proc, time.monotonic() - started


class FakeDeck:
    """A one-connection stand-in for the app: records the envelope and optionally answers it."""

    def __init__(self, path, answer=None):
        self.path, self.answer, self.received = path, answer, None
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(1)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        conn, _ = self.server.accept()
        data = b""
        while not data.endswith(b"\n"):
            data += conn.recv(65536)
        self.received = json.loads(data)
        if self.received["wait"]:
            conn.sendall(json.dumps({"output": self.answer}).encode() + b"\n")
        conn.close()

    def close(self):
        self.thread.join(timeout=5)
        self.server.close()


class DeckHookTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.sock = os.path.join(self.dir, "deck.sock")

    def test_app_not_running_exits_fast_and_silent(self):
        proc, elapsed = run_hook(self.sock, "claude", "PermissionRequest", '{"session_id": "s1"}')
        self.assertEqual((proc.returncode, proc.stdout, proc.stderr), (0, b"", b""))
        self.assertLess(elapsed, 0.5)

    def test_bad_input_exits_silent(self):
        proc, _ = run_hook(self.sock, "claude", "Stop", "not json")
        self.assertEqual((proc.returncode, proc.stdout), (0, b""))

    def test_permission_request_prints_the_app_answer(self):
        answer = {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}
        deck = FakeDeck(self.sock, answer)
        proc, _ = run_hook(self.sock, "codex", "PermissionRequest", '{"session_id": "thr_1", "tool_name": "Bash"}')
        deck.close()
        self.assertEqual(json.loads(proc.stdout), answer)
        self.assertEqual(deck.received["tool"], "codex")
        self.assertTrue(deck.received["wait"])
        self.assertEqual(deck.received["payload"]["tool_name"], "Bash")

    def test_no_decision_prints_nothing(self):
        deck = FakeDeck(self.sock, None)
        proc, _ = run_hook(self.sock, "claude", "PermissionRequest", '{"session_id": "s1"}')
        deck.close()
        self.assertEqual((proc.returncode, proc.stdout), (0, b""))

    def test_other_events_are_fire_and_forget(self):
        deck = FakeDeck(self.sock)
        proc, _ = run_hook(self.sock, "claude", "Stop", '{"session_id": "s1", "last_assistant_message": "完成"}')
        deck.close()
        self.assertEqual(proc.stdout, b"")
        self.assertFalse(deck.received["wait"])
        self.assertEqual(deck.received["payload"]["last_assistant_message"], "完成")

    def test_cursor_agent_calls_are_ignored(self):
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(self.sock)
        server.listen(1)
        server.settimeout(0.3)
        proc, _ = run_hook(self.sock, "claude", "Stop", '{"session_id": "c1", "cursor_version": "3.27.14"}')
        with self.assertRaises(socket.timeout):
            server.accept()
        server.close()
        self.assertEqual((proc.returncode, proc.stdout), (0, b""))


if __name__ == "__main__":
    unittest.main()
