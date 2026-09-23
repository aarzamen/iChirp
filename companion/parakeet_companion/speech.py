"""Speech in the owner's local voices through mlx-audio: Qwen3-TTS CustomVoice (ChoiceVoice's model family and
speakers) and Kokoro-82M.

- Models load lazily on the first request that needs them; one model stays resident (switching unloads the other).
- Synthesis is serialized with one lock (one Apple-silicon GPU, one model at a time).
- A request never downloads a model: a missing one is a 503 naming `scripts/companion.sh --download <model>`.
- Nothing is stored or logged but model ids, character counts and timings.
"""

from __future__ import annotations

import gc
import importlib.util
import json
import logging
import threading
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from . import audio
from .backends import ModelStatus, SpeechAudio, SpeechJob, VoiceInfo
from .errors import ModelUnavailable, SynthesisFailed, UnknownModel, UnknownVoice

logger = logging.getLogger("parakeet_companion")

#: ChoiceVoice's speakers (`~/Projects/ChoiceVoice/ui-vite/src/App.jsx`, `SPEAKERS`): the Qwen3-TTS CustomVoice
#: preset speakers, with ChoiceVoice's descriptions, native language and flag.
QWEN_SPEAKERS: tuple[tuple[str, str, str, str], ...] = (
    ("Vivian", "Bright, slightly edgy young female", "zh", "CN"),
    ("Serena", "Warm, gentle young female", "zh", "CN"),
    ("Uncle_Fu", "Seasoned male, low mellow timbre", "zh", "CN"),
    ("Dylan", "Youthful Beijing male, clear timbre", "zh", "CN"),
    ("Eric", "Lively Chengdu male, husky brightness", "zh", "CN"),
    ("Ryan", "Dynamic male, strong rhythmic drive", "en", "US"),
    ("Aiden", "Sunny American male, clear midrange", "en", "US"),
    ("Ono_Anna", "Playful Japanese female, light timbre", "ja", "JP"),
    ("Sohee", "Warm Korean female, rich emotion", "ko", "KR"),
)

#: ISO 639-1 → the language names Qwen3-TTS takes; anything else is "auto".
QWEN_LANGUAGES = {
    "en": "english", "zh": "chinese", "ja": "japanese", "ko": "korean", "de": "german",
    "fr": "french", "ru": "russian", "pt": "portuguese", "es": "spanish", "it": "italian",
}  # fmt: skip

#: Kokoro voice prefixes (`af_heart` = American English, female).
KOKORO_LANGUAGES = {
    "a": ("en", "American English"), "b": ("en", "British English"), "e": ("es", "Spanish"),
    "f": ("fr", "French"), "h": ("hi", "Hindi"), "i": ("it", "Italian"), "j": ("ja", "Japanese"),
    "p": ("pt", "Brazilian Portuguese"), "z": ("zh", "Mandarin Chinese"),
}  # fmt: skip


@dataclass(frozen=True)
class ModelSpec:
    id: str
    repo: str
    family: str  # "qwen3" or "kokoro"
    supports_style: bool
    approximate_size: str
    local_dirs: tuple[Path, ...] = ()
    #: Python modules the model needs besides mlx-audio, with the command that installs them.
    needs: tuple[tuple[str, str], ...] = ()


MODELS: tuple[ModelSpec, ...] = (
    ModelSpec("qwen3-tts-1.7b", "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit", "qwen3", True, "3.1 GB"),
    # The 0.6B CustomVoice model ignores style instructions (mlx-audio drops them), so its voices say so.
    ModelSpec("qwen3-tts-0.6b", "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit", "qwen3", False, "2.0 GB"),
    ModelSpec(
        "kokoro-82m",
        "mlx-community/Kokoro-82M-bf16",
        "kokoro",
        False,
        "390 MB",
        local_dirs=(Path.home() / "Kokoro-82M",),
        needs=(("misaki", "uv sync --project companion --extra kokoro"),),
    ),
)
DEFAULT_MODEL = "qwen3-tts-1.7b"


def is_complete_model_dir(directory: Path) -> bool:
    """An MLX model folder: `config.json` plus every safetensors shard its index names (or at least one)."""
    if not (directory / "config.json").is_file():
        return False
    index = directory / "model.safetensors.index.json"
    if index.is_file():
        try:
            shards = set(json.loads(index.read_text())["weight_map"].values())
        except (OSError, ValueError, KeyError):
            return False
        return bool(shards) and all((directory / shard).is_file() for shard in shards)
    return any(directory.glob("*.safetensors"))


def locate_in_hf_cache(spec: ModelSpec) -> Path | None:
    """The model's folder: an MLX copy in one of `spec.local_dirs`, else the Hugging Face cache. No network."""
    for directory in spec.local_dirs:
        if is_complete_model_dir(directory):
            return directory
    try:
        from huggingface_hub import try_to_load_from_cache
    except ImportError:
        return None
    found = try_to_load_from_cache(spec.repo, "config.json")
    if not isinstance(found, str):
        return None
    directory = Path(found).parent
    return directory if is_complete_model_dir(directory) else None


def module_installed(name: str) -> bool:
    return importlib.util.find_spec(name) is not None


def load_with_mlx_audio(directory: Path) -> Any:
    from mlx_audio.tts.utils import load_model

    return load_model(directory)


def release_mlx_memory() -> None:
    gc.collect()
    try:
        import mlx.core as mx

        mx.clear_cache()
    except Exception:  # noqa: BLE001 — best effort
        pass


@dataclass
class MLXSpeech:
    """`SpeechBackend` on mlx-audio. The collaborators are injectable so tests run without models or MLX."""

    specs: tuple[ModelSpec, ...] = MODELS
    locate: Callable[[ModelSpec], Path | None] = locate_in_hf_cache
    has_module: Callable[[str], bool] = module_installed
    load: Callable[[Path], Any] = load_with_mlx_audio
    release: Callable[[], None] = release_mlx_memory
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)
    _loaded_id: str | None = field(default=None, repr=False)
    _model: Any = field(default=None, repr=False)

    # MARK: Catalog

    def models(self) -> list[ModelStatus]:
        return [self._status(spec) for spec in self.specs]

    def voices(self) -> list[VoiceInfo]:
        voices: list[VoiceInfo] = []
        for spec in self.specs:
            status = self._status(spec)
            if status.available:
                voices.extend(self._voices(spec))
        return voices

    def _status(self, spec: ModelSpec) -> ModelStatus:
        if not self.has_module("mlx_audio"):
            return ModelStatus(spec.id, False, "mlx-audio is not installed. Run: uv sync --project companion")
        for module, command in spec.needs:
            if not self.has_module(module):
                return ModelStatus(spec.id, False, f"{spec.id} needs the {module} package. Run: {command}")
        if self.locate(spec) is None:
            return ModelStatus(
                spec.id,
                False,
                f"{spec.id} is not downloaded. Run: scripts/companion.sh --download {spec.id} "
                f"(about {spec.approximate_size}, once)",
            )
        return ModelStatus(spec.id, True)

    def _voices(self, spec: ModelSpec) -> list[VoiceInfo]:
        if spec.family == "qwen3":
            return [
                VoiceInfo(
                    id=f"{spec.id}:{name}",
                    name=name.replace("_", " "),
                    detail=f"{detail} ({flag})",
                    languages=[language],
                    model=spec.id,
                    supports_style=spec.supports_style,
                )
                for name, detail, language, flag in QWEN_SPEAKERS
            ]
        return [self._kokoro_voice(spec, name) for name in self._kokoro_voice_names(spec)]

    def _kokoro_voice_names(self, spec: ModelSpec) -> list[str]:
        directory = self.locate(spec)
        if directory is None:
            return []
        names = {path.stem for path in (directory / "voices").glob("*.safetensors")}
        return sorted(name for name in names if len(name) > 3 and name[2] == "_" and name[0] in KOKORO_LANGUAGES)

    @staticmethod
    def _kokoro_voice(spec: ModelSpec, name: str) -> VoiceInfo:
        language, language_name = KOKORO_LANGUAGES[name[0]]
        gender = {"f": "female", "m": "male"}.get(name[1], "voice")
        return VoiceInfo(
            id=f"{spec.id}:{name}",
            name=name[3:].replace("_", " ").title(),
            detail=f"{language_name} {gender}",
            languages=[language],
            model=spec.id,
            supports_style=False,
        )

    # MARK: Synthesis

    def resolve(self, model_id: str | None, voice: str) -> tuple[ModelSpec, str]:
        """The model and the speaker name for a request (`voice` may be "Ryan" or "qwen3-tts-1.7b:Ryan")."""
        prefix, separator, bare = voice.partition(":")
        if separator:
            if model_id and prefix != model_id:
                raise UnknownVoice("That voice belongs to another model.")
            model_id = model_id or prefix
            voice = bare
        spec = next((spec for spec in self.specs if spec.id == (model_id or DEFAULT_MODEL)), None)
        if spec is None:
            raise UnknownModel(f"Unknown model. This companion has: {', '.join(s.id for s in self.specs)}.")
        status = self._status(spec)
        if not status.available:
            raise ModelUnavailable(status.reason or f"{spec.id} is not ready.")
        names = (
            [name for name, *_ in QWEN_SPEAKERS] if spec.family == "qwen3" else self._kokoro_voice_names(spec)
        )
        match = next((name for name in names if name.lower() == voice.strip().lower()), None)
        if match is None:
            raise UnknownVoice(f"Unknown voice for {spec.id}. GET /v1/voices lists them.")
        return spec, match

    def synthesize(self, job: SpeechJob) -> SpeechAudio:
        spec, speaker = self.resolve(job.model or None, job.voice)
        audio.require_encoder(job.response_format)
        started = time.perf_counter()
        with self._lock:
            model = self._ensure_loaded(spec)
            try:
                samples, sample_rate = self._generate(spec, model, speaker, job)
            except Exception as error:  # noqa: BLE001 — type only; a message could quote the text
                logger.error("speech_failed model=%s error_type=%s", spec.id, type(error).__name__)
                raise SynthesisFailed(f"Speech synthesis failed on the Mac ({type(error).__name__}).") from None
        data, media_type = audio.encode(samples, sample_rate, job.response_format)
        logger.info(
            "speech_done model=%s chars=%d audio_ms=%d ms=%d",
            spec.id,
            len(job.text),
            int(len(samples) * 1000 / max(sample_rate, 1)),
            int((time.perf_counter() - started) * 1000),
        )
        return SpeechAudio(data=data, media_type=media_type)

    def _ensure_loaded(self, spec: ModelSpec) -> Any:
        if self._loaded_id == spec.id and self._model is not None:
            return self._model
        if self._model is not None:
            logger.info("model_unloaded model=%s", self._loaded_id)
            self._model = None
            self._loaded_id = None
            self.release()
        directory = self.locate(spec)
        if directory is None:
            raise ModelUnavailable(f"{spec.id} is not downloaded. Run: scripts/companion.sh --download {spec.id}")
        started = time.perf_counter()
        try:
            model = self.load(directory)
        except Exception as error:  # noqa: BLE001
            logger.error("model_load_failed model=%s error_type=%s", spec.id, type(error).__name__)
            raise ModelUnavailable(
                f"{spec.id} could not be loaded ({type(error).__name__}). Download it again: "
                f"scripts/companion.sh --download {spec.id}"
            ) from None
        logger.info("model_loaded model=%s ms=%d", spec.id, int((time.perf_counter() - started) * 1000))
        self._model = model
        self._loaded_id = spec.id
        return model

    @staticmethod
    def _generate(spec: ModelSpec, model: Any, speaker: str, job: SpeechJob) -> tuple[np.ndarray, int]:
        if spec.family == "qwen3":
            base = (job.language or "").lower().replace("_", "-").split("-")[0]
            results: Iterable[Any] = model.generate(
                text=job.text,
                voice=speaker,
                instruct=job.instructions if spec.supports_style and job.instructions else None,
                lang_code=QWEN_LANGUAGES.get(base, "auto"),
                verbose=False,
            )
        else:
            results = model.generate(text=job.text, voice=speaker, speed=1.0, lang_code=speaker[0], verbose=False)
        arrays: list[np.ndarray] = []
        sample_rate = int(getattr(model, "sample_rate", 0) or 0)
        for result in results:
            arrays.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
            sample_rate = int(getattr(result, "sample_rate", 0) or sample_rate)
        if not arrays:
            raise RuntimeError("no audio")
        return (np.concatenate(arrays) if len(arrays) > 1 else arrays[0]), (sample_rate or 24_000)

    # MARK: Download (CLI only; never from a request)

    def download(self, model_id: str) -> Path:
        spec = next((spec for spec in self.specs if spec.id == model_id), None)
        if spec is None:
            raise UnknownModel(f"Unknown model. Choose one of: {', '.join(s.id for s in self.specs)}.")
        from huggingface_hub import snapshot_download

        print(f"Downloading {spec.id} ({spec.repo}, about {spec.approximate_size}) into the Hugging Face cache…")
        path = Path(snapshot_download(spec.repo))
        for module, command in spec.needs:
            if not self.has_module(module):
                print(f"Note: {spec.id} also needs the {module} package. Run: {command}")
        return path
