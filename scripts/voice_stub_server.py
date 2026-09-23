#!/usr/bin/env python3
# QA-only stub of the Mac companion's speech API (spec/contracts/mac-companion-v1.md) for simulator checks of Listen and
# Settings → Voices (plan 020, docs/human-qa-guide.md "Voice"). It is not a voice: every answer is a short synthetic
# tone WAV whose length follows the text length. It stores nothing and never logs text, only method, path and status.
#
# Usage: python3 scripts/voice_stub_server.py [--port 8799] [--delay 0.4]   (Ctrl-C to stop)
# The app (DEBUG builds) finds it with the launch arguments
#   -ChirpQACompanionHost 127.0.0.1 -ChirpQACompanionPort 8799 -ChirpQACompanionToken synthetic-qa-token
import argparse, io, json, math, struct, sys, time, wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "synthetic-qa-token"  # synthetic, QA only
VOICES = [
    {"id": "stub:low", "name": "Stub tone (low)", "detail": "QA stub: a synthetic tone, not a voice",
     "languages": ["en"], "model": "stub", "supportsStyle": True},
    {"id": "stub:high", "name": "Stub tone (high)", "detail": "QA stub: a synthetic tone, not a voice",
     "languages": ["en"], "model": "stub", "supportsStyle": False},
]


def tone_wav(characters, pitch):
    """16-bit mono 24 kHz: ~45 ms per character (0.4–6 s), faded in and out."""
    rate = 24_000
    seconds = min(6.0, max(0.4, characters * 0.045))
    frames = int(rate * seconds)
    fade = int(rate * 0.03)
    samples = bytearray()
    for i in range(frames):
        envelope = min(1.0, i / fade, (frames - i) / fade)
        samples += struct.pack("<h", int(6000 * envelope * math.sin(2 * math.pi * pitch * i / rate)))
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(bytes(samples))
    return out.getvalue()


class Handler(BaseHTTPRequestHandler):
    delay = 0.4

    def log_message(self, *args):
        pass

    def reply(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        print(f"{self.command} {self.path} {status} {len(body)}B", file=sys.stderr, flush=True)

    def error(self, status, code, message):
        self.reply(status, json.dumps({"error": {"code": code, "message": message}}).encode())

    def authorized(self):
        if self.headers.get("Authorization") == f"Bearer {TOKEN}":
            return True
        self.error(401, "unauthorized", "Wrong or missing pairing token.")
        return False

    def do_GET(self):
        if self.path == "/v1/companion":
            self.reply(200, json.dumps({
                "name": "Parakeet companion", "version": "0.0.0-stub", "api": "mac-companion-v1",
                "features": {"speech": True, "youtubeAudio": False},
                "speech": {"models": ["stub"], "defaultModel": "stub"}}).encode())
        elif self.path == "/v1/voices":
            if self.authorized():
                self.reply(200, json.dumps({"voices": VOICES}).encode())
        else:
            self.error(404, "not_found", "No such endpoint.")

    def do_POST(self):
        if self.path != "/v1/audio/speech":
            return self.error(404, "not_found", "No such endpoint.")
        if not self.authorized():
            return
        length = int(self.headers.get("Content-Length", 0))
        request = json.loads(self.rfile.read(length) or b"{}")
        text = request.get("input", "")
        voice = request.get("voice", "")
        if len(text) > 4000:
            return self.error(413, "too_long", "input is over 4000 characters")
        if voice not in ("low", "high"):
            return self.error(400, "unknown_voice", "Unknown voice.")
        time.sleep(self.delay)
        self.reply(200, tone_wav(len(text), 220 if voice == "low" else 440), "audio/wav")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8799)
    parser.add_argument("--delay", type=float, default=0.4, help="seconds each synthesis takes")
    options = parser.parse_args()
    Handler.delay = options.delay
    print(f"Voice stub on http://127.0.0.1:{options.port} (token {TOKEN})", file=sys.stderr, flush=True)
    ThreadingHTTPServer(("127.0.0.1", options.port), Handler).serve_forever()
