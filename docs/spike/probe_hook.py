#!/usr/bin/python3
"""agent-deck spike probe.

Records hook events from sessions whose cwd is under probe-ws/ and answers the
blocking ones after DELAY seconds, standing in for a deck the user replies in.
Every other session gets an immediate exit 0 with no output.
"""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
TEST_ROOT = os.path.realpath(os.path.join(HERE, "probe-ws"))
RUNTIME = os.path.join(HERE, "runtime")
DELAY = float(os.environ.get("DECK_PROBE_DELAY", "20"))
STOP_KEYWORD = "STOPTEST"
STOP_REPLY = "[deck 回复测试] 这条是从 deck 发来的回复：请用一句话复述你上一条回复，并在开头加上 [DECK]。"


def in_test_root(cwd):
    if not cwd:
        return False
    real = os.path.realpath(cwd)
    return real == TEST_ROOT or real.startswith(TEST_ROOT + os.sep)


def log(record):
    os.makedirs(RUNTIME, exist_ok=True)
    record["ts"] = time.strftime("%H:%M:%S")
    with open(os.path.join(RUNTIME, "events.jsonl"), "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def arm_path(tool, session_id):
    return os.path.join(RUNTIME, "arm-stop-%s-%s" % (tool, session_id))


def respond(tool, event, data):
    session_id = str(data.get("session_id", ""))
    if event == "UserPromptSubmit":
        prompt = next((data[k] for k in ("prompt", "user_prompt", "input", "message")
                       if isinstance(data.get(k), str)), "")
        if STOP_KEYWORD in prompt:
            os.makedirs(RUNTIME, exist_ok=True)
            open(arm_path(tool, session_id), "w").close()
        return None
    if event == "PermissionRequest":
        # Round 2: AskUserQuestion is answered here instead of in PreToolUse, so the
        # plugin can show its own card while the hook waits (two entry points).
        time.sleep(DELAY)
        decision = {"behavior": "allow"}
        if data.get("tool_name") == "AskUserQuestion":
            questions = (data.get("tool_input") or {}).get("questions") or []
            answers = {q["question"]: q["options"][0]["label"] for q in questions if q.get("options")}
            decision["updatedInput"] = {"questions": questions, "answers": answers}
        return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}
    if event == "Stop":
        flag = arm_path(tool, session_id)
        if os.path.exists(flag) and not data.get("stop_hook_active"):
            os.remove(flag)
            time.sleep(DELAY)
            return {"decision": "block", "reason": STOP_REPLY}
    return None


def main():
    tool, event = sys.argv[1], sys.argv[2]
    data = json.loads(sys.stdin.read() or "{}")
    if not in_test_root(data.get("cwd")):
        return
    log({"tool": tool, "event": event, "session_id": data.get("session_id"),
         "keys": sorted(data.keys()), "tool_name": data.get("tool_name"),
         "notification_type": data.get("notification_type"), "message": data.get("message"),
         "permission_mode": data.get("permission_mode"), "source": data.get("source"),
         "turn_id": data.get("turn_id")})
    out = respond(tool, event, data)
    if out is not None:
        log({"tool": tool, "event": event, "session_id": data.get("session_id"), "responded": out})
        sys.stdout.write(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
