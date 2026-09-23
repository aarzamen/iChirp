#!/usr/bin/env python3
# QA-only stub for Jev (plan 021; UITests/M6aJevTourUITests.swift, docs/human-qa-guide.md "M6a"). It is NOT Jev and
# NOT a model: it answers TypeSafe's POST /v1/systemone shape with SYNTHETIC, deterministic choices so the app's Jev
# screens can be checked without a key or the internet. It stores nothing and logs nothing.
#
# For every choice question it picks the option whose id or description shares the most words with the state text
# (ties go to the first option id in sorted order), gives it the largest probability (0.60, plus 0.10 per shared word,
# at most 0.90), spreads the rest so the probabilities sum to 1, and sets confidence to the winner's probability. It
# echoes the request's model id.
#
# Usage:  python3 scripts/jev_stub_server.py                 # http://127.0.0.1:11998
#         JEV_STUB_PORT=11997 python3 scripts/jev_stub_server.py
#         JEV_STUB_MODE=401|429|500|garbage python3 scripts/jev_stub_server.py   # fail in that way
# Then:   scripts/run_sim.sh -ChirpJevBaseURL http://127.0.0.1:11998            (DEBUG builds only)
import json, os, re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("JEV_STUB_PORT", "11998"))
MODE = os.environ.get("JEV_STUB_MODE", "").strip().lower()
STOP = {"the", "and", "for", "that", "this", "with", "are", "was", "has", "have", "from", "you", "not", "but",
        "all", "any", "one", "its", "into", "out", "about", "who", "what", "which", "when", "does", "some", "other"}


def words(value):
    if isinstance(value, dict):
        return set().union(*(words(v) for v in value.values())) if value else set()
    if isinstance(value, list):
        return set().union(*(words(v) for v in value)) if value else set()
    if not isinstance(value, str):
        return set()
    return {w for w in re.findall(r"[a-z0-9]+", value.lower()) if len(w) >= 3 and w not in STOP}


def answer(question, state_words):
    options = sorted((question.get("criteria") or {}).keys())
    scores = {o: len(state_words & (words(o.replace("_", " ").replace("-", " ")) | words(question["criteria"][o])))
              for o in options}
    best = max(scores.values()) if scores else 0
    winner = next(o for o in options if scores[o] == best)
    # The winner gets 0.60 plus 0.10 per shared word (at most 0.90), so the app's gate shows all three verdicts;
    # the rest is split among the other options by their own overlap.
    top = min(0.60 + 0.10 * best, 0.90)
    others = [o for o in options if o != winner]
    weights = {o: 1.0 + scores[o] for o in others}
    total = sum(weights.values()) or 1.0
    probabilities = {o: round((1.0 - top) * w / total, 4) for o, w in weights.items()}
    probabilities[winner] = round(1.0 - sum(probabilities.values()), 4)
    return {"type": "choice", "choice": winner, "probabilities": probabilities,
            "confidence": probabilities[winner]}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send(404, {"detail": "Not found (synthetic Jev stub)"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        if self.path.rstrip("/") != "/v1/systemone":
            return self.send(404, {"detail": "Not found (synthetic Jev stub)"})
        if MODE == "401":
            return self.send(401, {"detail": "Invalid API key (synthetic Jev stub)"})
        if MODE == "429":
            return self.send(429, {"detail": "Rate limited (synthetic Jev stub)"})
        if MODE == "500":
            return self.send(500, {"detail": "Server error (synthetic Jev stub)"})
        if MODE == "garbage":
            return self.send(200, b"<html>not json</html>", "text/html")
        try:
            request = json.loads(raw or b"{}")
            state_words = words(request.get("state"))
            answers = {qid: answer(q, state_words) for qid, q in (request.get("questions") or {}).items()}
        except Exception:
            return self.send(422, {"detail": "Malformed request (synthetic Jev stub)"})
        self.send(200, {"model": request.get("model", "jev-1.13.0"), "answers": answers,
                        "usage": {"input_tokens": max(1, len(raw) // 4), "output_tokens": 5 * len(answers)}})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
