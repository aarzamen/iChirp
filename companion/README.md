# Parakeet companion (on your Mac)

A small service on your Mac that Parakeet on your iPhone reaches over your home Wi-Fi. It does two things the phone
cannot do well:

- **Speech in your local voices**: Qwen3-TTS (the model family ChoiceVoice uses, with its nine speakers such as Ryan
  and Aiden, and a style instruction) and Kokoro-82M, through mlx-audio on Apple silicon.
- **YouTube audio for videos without captions**, through yt-dlp.

API: [`spec/contracts/mac-companion-v1.md`](../spec/contracts/mac-companion-v1.md). Decision:
[ADR-014](../spec/adr/014-mac-companion.md).

## Start it

From the repo root (first run creates `companion/.venv` with Python 3.12 through `uv`):

```bash
cd ~/Documents/GitHub/iChirp
scripts/companion.sh --download qwen3-tts-1.7b   # once: about 3.1 GB into the Hugging Face cache
scripts/companion.sh                             # starts it; Control-C stops it
```

It prints something like:

```
  On your iPhone: Settings → Mac companion
    URL:           http://your-mac.local:8765
    Host:          your-mac.local
    Port:          8765
    Pairing token: <43 characters>
```

Other commands: `scripts/companion.sh --list-models` (which voices are ready), `--port 8766` (another port),
`--download qwen3-tts-0.6b` (smaller, about 2.0 GB, no style instructions), `--download kokoro-82m` (about 390 MB;
also run `uv sync --project companion --extra kokoro` for its phonemizer).

Needs: `uv` (`brew install uv`), `ffmpeg` for MP3 answers (`brew install ffmpeg`; WAV works without it), and a
JavaScript runtime for yt-dlp's YouTube support (`brew install deno`).

## Pair the iPhone

1. On the iPhone: **Settings → Mac companion**. Enter the host (`your-mac.local`, or the Mac's IP address), the port
   and the pairing token exactly as printed. The token goes into the iPhone's Keychain.
2. Tap **Test connection**: it shows the companion's version and what it can do.
3. **Trusted for clinical text** (off by default): turn it on only if this Mac is yours and stays on your home
   network. Only then may clinical text be spoken by this Mac's voices without asking each time.

The token is kept in `~/Library/Application Support/ParakeetCompanion/token` (readable only by you). To pair again
with a new token, stop the companion, delete that file, start it, and enter the new token on the phone.

## What it stores and logs

- **Stores nothing it receives.** Text to speak and links live in memory for one request. YouTube audio is written to
  a temporary folder that is deleted as soon as the phone has it (a folder a crash left behind is deleted at the next
  start).
- **Logs** one line per request: method, the endpoint (unknown paths show as `other`), status, bytes in and out,
  milliseconds. Model loads log the model id and time; speech logs the character count and audio length. Never the
  text, the voice input, a link, a title or the token. The log goes to the terminal only, not to a file.
- **Network**: it listens on the address you start it with (default `0.0.0.0`, your home network). It calls out only
  to YouTube (yt-dlp, when the phone asks for a video's audio) and to Hugging Face (only when you run `--download`).
  A speech request never downloads a model: if one is missing, the phone gets a message naming the command.

## Endpoints

| Endpoint | Token | What |
|---|---|---|
| `GET /v1/companion` | no | Name, version, API, `features.speech` / `features.youtubeAudio`, ready speech models |
| `GET /v1/voices` | yes | Voices of the ready models |
| `POST /v1/audio/speech` | yes | OpenAI speech shape; `input` ≤ 4 000 characters; MP3 (default) or WAV |
| `POST /v1/youtube/audio` | yes | `{"url": …}` for one youtube.com / youtu.be / m.youtube.com video; m4a back with `X-Companion-Title` and `X-Companion-Duration-Ms` |

Quick check from the Mac (replace the token):

```bash
curl -s localhost:8765/v1/companion
TOKEN='<pairing token>'
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-tts-1.7b","input":"Hello from Parakeet.","voice":"Ryan"}' \
  -o /tmp/parakeet-hello.mp3 localhost:8765/v1/audio/speech && afplay /tmp/parakeet-hello.mp3
```

## Stop it

Control-C in its terminal. Nothing keeps running and nothing is left behind except the token file and the models in
the Hugging Face cache (`~/.cache/huggingface/hub`).

## Develop

```bash
cd ~/Documents/GitHub/iChirp/companion
uv run pytest -q          # every endpoint with fakes: no models, no network
```

Layout: `parakeet_companion/app.py` (routes, the token guard and the content-free log), `auth.py` (the token),
`speech.py` (mlx-audio models and voices), `audio.py` (WAV/MP3), `youtube.py` (yt-dlp and the link allowlist),
`backends.py` (the protocols the tests fake), `__main__.py` (the command line).
