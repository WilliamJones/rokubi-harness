#!/usr/bin/env python3
"""
Minimal mock of the OpenAI Responses API for end-to-end smoke tests.

Serves POST /responses as an SSE stream and GET /models. The scripted "agent"
looks at the incoming `input` and plays one of a few scenes against the
`demo-project/` cart (open a copy of it — the scene edits src/cart.js), so the
harness's tool loop, checkpoints, terminal, plan, changes and completion UI can
be exercised offline:

  turn 1 (no tool outputs yet)       → update_plan + run_command `npm test` + read_file src/cart.js
  turn 2 (outputs for those calls)   → update_plan + apply_patch src/cart.js + run_command `npm test`
  turn 3 (verify output present)     → report_completion + closing message
  turn 4+                            → plain closing message

Also serves POST /chat/completions (the OpenRouter/Chat Completions flavour) with the same scenes.

Usage:  scripts/mock-openai.py [port]
        RokubiHarness --project <copy of demo-project> --base-url http://127.0.0.1:8765 --api-key test --prompt "…"
OpenRouter mode: RokubiHarness --project … --openrouter-key test --base-url http://127.0.0.1:8765 --prompt "…"
See scripts/smoke.sh for the automated version.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
LOG = []

# ---- The scene: fix the per-line discount bug in demo-project/src/cart.js ----

CART_PATH = "src/cart.js"
BUGGY_TOTAL = """export function total(items, discount) {
  // Rounding happens at the boundary, never mid-calculation.
  return round(
    items.reduce((sum, item) => sum + applyDiscount(item.price * item.quantity, discount), 0)
  );
}"""
FIXED_TOTAL = """export function total(items, discount) {
  // Discount applies once to the order subtotal. Rounding happens at the boundary,
  // never mid-calculation.
  return round(applyDiscount(subtotal(items), discount));
}"""

PLAN_1 = [{"title": "Run the tests", "status": "in_progress"},
          {"title": "Fix the discount bug", "status": "pending"},
          {"title": "Verify", "status": "pending"}]
PLAN_2 = [{"title": "Run the tests", "status": "done"},
          {"title": "Fix the discount bug", "status": "in_progress"},
          {"title": "Verify", "status": "pending"}]
PLAN_3 = [{"title": "Run the tests", "status": "done"},
          {"title": "Fix the discount bug", "status": "done"},
          {"title": "Verify", "status": "done"}]

MSG_1 = "I'll run the tests to see what fails, then read the cart code."
MSG_DONE = "Done — `total()` now applies the discount once to the order subtotal. **All 5 tests pass.**"
REASON_1 = "Run the suite first so I fix the real failure, not a guess."
REASON_2 = "The fixed discount is subtracted per line. Apply it once to the subtotal instead."

COMPLETION = {
    "summary": "Fixed the cart total: the discount is now applied once to the order, not once per line.",
    "changed_files": [CART_PATH],
    "verifications": [
        {"name": "Tests", "status": "passed", "detail": "5/5 passed (npm test)"},
        {"name": "Lint", "status": "not_run", "detail": "no linter in this project"},
    ],
}

# (call_id suffix, tool name, arguments) — call ids are "call_<suffix>" in both API flavours.
TURN_1_CALLS = [
    ("fc_plan1", "update_plan", {"steps": PLAN_1}),
    ("fc_test1", "run_command", {"command": "npm test", "purpose": "Run tests"}),
    ("fc_read", "read_file", {"path": CART_PATH}),
]
TURN_2_CALLS = [
    ("fc_plan2", "update_plan", {"steps": PLAN_2}),
    ("fc_patch", "apply_patch", {"path": CART_PATH, "edits": [{"old": BUGGY_TOTAL, "new": FIXED_TOTAL}]}),
    ("fc_run", "run_command", {"command": "npm test", "purpose": "Verify tests"}),
]
TURN_3_CALLS = [
    ("fc_plan3", "update_plan", {"steps": PLAN_3}),
    ("fc_done", "report_completion", COMPLETION),
]


def pick_turn(call_names, done_call_ids):
    """Which scene to play, given the tool calls already in the transcript and the outputs present."""
    if "call_fc_done" in done_call_ids:
        return 4
    if "call_fc_run" in done_call_ids:
        return 3
    if "call_fc_read" in done_call_ids or "read_file" in call_names:
        return 2
    return 1


# ---- Responses API flavour ----

def sse(handler, event_type, payload):
    payload = {"type": event_type, **payload}
    handler.wfile.write(f"event: {event_type}\ndata: {json.dumps(payload)}\n\n".encode())
    handler.wfile.flush()


def text_item(handler, item_id, text):
    sse(handler, "response.output_item.added", {"output_index": 0, "item": {"type": "message", "id": item_id, "role": "assistant"}})
    for i in range(0, len(text), 12):
        sse(handler, "response.output_text.delta", {"item_id": item_id, "delta": text[i:i + 12]})
        time.sleep(0.02)
    sse(handler, "response.output_item.done", {"output_index": 0, "item": {
        "type": "message", "id": item_id, "role": "assistant", "status": "completed",
        "content": [{"type": "output_text", "text": text}]}})


def reasoning_item(handler, item_id, summary):
    sse(handler, "response.output_item.added", {"output_index": 0, "item": {"type": "reasoning", "id": item_id}})
    sse(handler, "response.reasoning_summary_text.delta", {"item_id": item_id, "delta": summary})
    sse(handler, "response.output_item.done", {"output_index": 0, "item": {
        "type": "reasoning", "id": item_id, "summary": [{"type": "summary_text", "text": summary}],
        "encrypted_content": "ENCRYPTED-" + item_id}})


def call_item(handler, item_id, name, args):
    sse(handler, "response.output_item.added", {"output_index": 1, "item": {
        "type": "function_call", "id": item_id, "call_id": "call_" + item_id, "name": name}})
    sse(handler, "response.function_call_arguments.done", {"item_id": item_id, "arguments": json.dumps(args)})
    sse(handler, "response.output_item.done", {"output_index": 1, "item": {
        "type": "function_call", "id": item_id, "call_id": "call_" + item_id, "name": name,
        "arguments": json.dumps(args), "status": "completed"}})


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("[mock] " + fmt % args + "\n")

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            body = json.dumps({"data": [
                {"id": "gpt-5.4", "name": "OpenAI: GPT-5.4", "context_length": 400000,
                 "pricing": {"prompt": "0.0000025", "completion": "0.00001"}},
                {"id": "anthropic/claude-sonnet-5", "name": "Anthropic: Claude Sonnet 5", "context_length": 200000,
                 "pricing": {"prompt": "0.000003", "completion": "0.000015"}},
                {"id": "meta-llama/llama-3.3-70b-instruct:free", "name": "Meta: Llama 3.3 70B (free)", "context_length": 131072,
                 "pricing": {"prompt": "0", "completion": "0"}},
            ]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        if self.path.rstrip("/").endswith("/chat/completions"):
            return self.chat_completions(req)
        LOG.append(req)
        with open("/tmp/mock-openai-last-request.json", "w") as f:
            json.dump(req, f, indent=2)

        assert req.get("store") is False, "store must be false"
        assert req.get("stream") is True
        inputs = req.get("input", [])
        outputs = [i for i in inputs if i.get("type") == "function_call_output"]
        calls = [i for i in inputs if i.get("type") == "function_call"]
        reasoning = [i for i in inputs if i.get("type") == "reasoning"]

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        sse(self, "response.created", {"response": {"id": f"resp_{len(LOG)}"}})

        turn = pick_turn([c.get("name") for c in calls], [o.get("call_id") for o in outputs])
        sys.stderr.write(f"[mock] turn {turn}; outputs: {[o.get('call_id') for o in outputs]}; reasoning resent: {len(reasoning)}\n")
        if turn == 4:
            text_item(self, f"msg_close_{len(LOG)}", "Anything else?")
        elif turn == 3:
            for cid, name, args in TURN_3_CALLS:
                call_item(self, cid, name, args)
            text_item(self, "msg_done", MSG_DONE)
        elif turn == 2:
            reasoning_item(self, "rs_2", REASON_2)
            for cid, name, args in TURN_2_CALLS:
                call_item(self, cid, name, args)
        else:
            reasoning_item(self, "rs_1", REASON_1)
            text_item(self, "msg_1", MSG_1)
            for cid, name, args in TURN_1_CALLS:
                call_item(self, cid, name, args)

        sse(self, "response.completed", {"response": {"id": f"resp_{len(LOG)}", "usage": {"input_tokens": 120, "output_tokens": 40}}})

    # ---- Chat Completions flavour (what OpenRouter speaks) ----
    def chat_chunk(self, delta, finish=None, usage=None):
        obj = {"id": "cc", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        if usage: obj["usage"] = usage
        self.wfile.write(f"data: {json.dumps(obj)}\n\n".encode()); self.wfile.flush()

    def chat_text(self, text):
        for i in range(0, len(text), 10):
            self.chat_chunk({"content": text[i:i + 10]}); time.sleep(0.02)

    def chat_call(self, index, call_id, name, args):
        a = json.dumps(args)
        self.chat_chunk({"tool_calls": [{"index": index, "id": call_id, "type": "function", "function": {"name": name, "arguments": ""}}]})
        for i in range(0, len(a), 8):  # arguments arrive in fragments
            self.chat_chunk({"tool_calls": [{"index": index, "function": {"arguments": a[i:i + 8]}}]})

    def chat_completions(self, req):
        LOG.append(req)
        with open("/tmp/mock-openai-last-request.json", "w") as f: json.dump(req, f, indent=2)
        msgs = req.get("messages", [])
        assert msgs and msgs[0]["role"] == "system", "system message first"
        tool_msgs = [m for m in msgs if m.get("role") == "tool"]
        assistant_calls = [c for m in msgs if m.get("tool_calls") for c in m["tool_calls"]]
        names = [c["function"]["name"] for c in assistant_calls]
        done_ids = [m["tool_call_id"] for m in tool_msgs]

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-cache"); self.end_headers()
        self.chat_chunk({"role": "assistant"})
        usage = {"prompt_tokens": 120, "completion_tokens": 40, "total_tokens": 160}
        turn = pick_turn(names, done_ids)
        sys.stderr.write(f"[mock/chat] turn {turn}; outputs: {done_ids}\n")
        if turn == 4:
            self.chat_text("Anything else?")
            self.chat_chunk({}, finish="stop", usage=usage)
        elif turn == 3:
            for i, (cid, name, args) in enumerate(TURN_3_CALLS):
                self.chat_call(i, "call_" + cid, name, args)
            self.chat_text(MSG_DONE)
            self.chat_chunk({}, finish="tool_calls", usage=usage)
        elif turn == 2:
            for i, (cid, name, args) in enumerate(TURN_2_CALLS):
                self.chat_call(i, "call_" + cid, name, args)
            self.chat_chunk({}, finish="tool_calls", usage=usage)
        else:
            self.chat_text(MSG_1)
            for i, (cid, name, args) in enumerate(TURN_1_CALLS):
                self.chat_call(i, "call_" + cid, name, args)
            self.chat_chunk({}, finish="tool_calls", usage=usage)
        self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()


if __name__ == "__main__":
    sys.stderr.write(f"[mock] listening on http://127.0.0.1:{PORT}\n")
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
