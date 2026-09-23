#!/usr/bin/env python3
# QA-only stub for the M4 screen tour (UITests/M4ScreenTourUITests.swift, docs/human-qa-guide.md "M4"): answers
# Ollama's /api/tags and /api/chat on http://127.0.0.1:11999 with canned SYNTHETIC text. It is not a model, stores
# nothing and logs nothing. Usage: python3 scripts/llm_stub_server.py   (Ctrl-C to stop)
import json, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SOAP = ("S: Synthetic speaker reports the follow-up moved to Thursday.\n"
        "O: Not documented.\nA: Not documented.\nP: Confirm the Thursday follow-up [00:00].")
DOC = ("Summary\n\nThe synthetic conversation covers a short exchange between two voices. "
       "One voice proposes a plan and the other agrees [00:00].\n\n- Decision: proceed as proposed\n- Owner: speaker one")
ANSWER = "The speakers agreed to proceed with the plan [00:00]."

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.rstrip("/") == "/api/tags":
            body = json.dumps({"models": [{"name": "synthetic-stub:1b"}, {"name": "synthetic-stub:3b"}]}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        prompt = " ".join(m.get("content", "") for m in req.get("messages", []))
        text = SOAP if "SOAP" in prompt else (ANSWER if "Answer the question" in prompt else DOC)
        if not req.get("stream"):
            body = json.dumps({"model": "synthetic-stub:1b", "message": {"role": "assistant", "content": "Hi"}, "done": True}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        self.send_response(200); self.send_header("Content-Type", "application/x-ndjson"); self.end_headers()
        for word in text.split(" "):
            chunk = {"model": "synthetic-stub:1b", "message": {"role": "assistant", "content": word + " "}, "done": False}
            self.wfile.write((json.dumps(chunk) + "\n").encode()); self.wfile.flush(); time.sleep(0.08)
        done = {"model": "synthetic-stub:1b", "message": {"role": "assistant", "content": ""}, "done": True,
                "done_reason": "stop", "prompt_eval_count": 100, "eval_count": 40}
        self.wfile.write((json.dumps(done) + "\n").encode()); self.wfile.flush()

ThreadingHTTPServer(("127.0.0.1", 11999), H).serve_forever()
