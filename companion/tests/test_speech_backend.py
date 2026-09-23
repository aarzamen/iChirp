"""`MLXSpeech` with injected fakes: catalog, availability, voice resolution, one resident model, errors."""

from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from parakeet_companion import audio
from parakeet_companion.backends import SpeechJob
from parakeet_companion.errors import (
    EncoderUnavailable,
    ModelUnavailable,
    SynthesisFailed,
    UnknownModel,
    UnknownVoice,
)
from parakeet_companion.speech import MODELS, MLXSpeech, is_complete_model_dir


class FakeModel:
    sample_rate = 24_000

    def __init__(self, directory: Path, fail: bool = False) -> None:
        self.directory = directory
        self.fail = fail
        self.calls: list[dict] = []

    def generate(self, **kwargs):
        self.calls.append(kwargs)
        if self.fail:
            raise ValueError("model exploded while reading: " + kwargs["text"])
        yield SimpleNamespace(audio=np.zeros(2_400, dtype=np.float32), sample_rate=24_000)
        yield SimpleNamespace(audio=np.full(2_400, 0.1, dtype=np.float32), sample_rate=24_000)


def make_model_dir(root: Path, voices: tuple[str, ...] = ()) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    (root / "config.json").write_text("{}")
    (root / "model.safetensors").write_bytes(b"x")
    if voices:
        (root / "voices").mkdir()
        for voice in voices:
            (root / "voices" / f"{voice}.safetensors").write_bytes(b"v")
    return root


@pytest.fixture
def dirs(tmp_path) -> dict[str, Path]:
    return {
        "qwen3-tts-1.7b": make_model_dir(tmp_path / "q17"),
        "qwen3-tts-0.6b": make_model_dir(tmp_path / "q06"),
        "kokoro-82m": make_model_dir(tmp_path / "kokoro", voices=("af_heart", "bm_george", "zz", "readme")),
    }


def backend(dirs: dict[str, Path], modules: set[str] | None = None, fail: bool = False) -> tuple[MLXSpeech, list]:
    loaded: list[FakeModel] = []
    released: list[bool] = []

    def load(directory: Path) -> FakeModel:
        model = FakeModel(directory, fail=fail)
        loaded.append(model)
        return model

    installed = {"mlx_audio", "misaki"} if modules is None else modules
    speech = MLXSpeech(
        locate=lambda spec: dirs.get(spec.id),
        has_module=lambda name: name in installed,
        load=load,
        release=lambda: released.append(True),
    )
    return speech, [loaded, released]


def test_catalog_has_the_three_contract_models() -> None:
    assert [spec.id for spec in MODELS] == ["qwen3-tts-1.7b", "qwen3-tts-0.6b", "kokoro-82m"]
    assert all("CustomVoice" in spec.repo for spec in MODELS if spec.family == "qwen3")


def test_status_reasons_name_the_fix(dirs) -> None:
    speech, _ = backend({"qwen3-tts-1.7b": dirs["qwen3-tts-1.7b"]}, modules={"mlx_audio"})
    status = {model.id: model for model in speech.models()}
    assert status["qwen3-tts-1.7b"].available
    assert "scripts/companion.sh --download qwen3-tts-0.6b" in status["qwen3-tts-0.6b"].reason
    assert "uv sync --project companion --extra kokoro" in status["kokoro-82m"].reason
    nothing, _ = backend(dirs, modules=set())
    assert all(not model.available and "uv sync" in model.reason for model in nothing.models())


def test_voices_list_only_available_models(dirs) -> None:
    speech, _ = backend({"qwen3-tts-1.7b": dirs["qwen3-tts-1.7b"], "kokoro-82m": dirs["kokoro-82m"]})
    voices = {voice.id: voice for voice in speech.voices()}
    ryan = voices["qwen3-tts-1.7b:Ryan"]
    assert (ryan.name, ryan.detail, ryan.languages, ryan.supports_style) == (
        "Ryan", "Dynamic male, strong rhythmic drive (US)", ["en"], True,
    )
    assert voices["qwen3-tts-1.7b:Uncle_Fu"].name == "Uncle Fu"
    assert not any(voice.startswith("qwen3-tts-0.6b") for voice in voices)
    heart = voices["kokoro-82m:af_heart"]
    assert (heart.name, heart.detail, heart.languages, heart.supports_style) == (
        "Heart", "American English female", ["en"], False,
    )
    assert "kokoro-82m:bm_george" in voices and "kokoro-82m:zz" not in voices and "kokoro-82m:readme" not in voices


def test_small_qwen_voices_do_not_support_style(dirs) -> None:
    speech, _ = backend(dirs)
    assert all(not v.supports_style for v in speech.voices() if v.model == "qwen3-tts-0.6b")


def test_resolve_accepts_full_ids_and_any_case(dirs) -> None:
    speech, _ = backend(dirs)
    assert speech.resolve("qwen3-tts-1.7b", "ryan")[1] == "Ryan"
    spec, name = speech.resolve(None, "qwen3-tts-0.6b:Aiden")
    assert (spec.id, name) == ("qwen3-tts-0.6b", "Aiden")
    assert speech.resolve(None, "Ryan")[0].id == "qwen3-tts-1.7b"
    with pytest.raises(UnknownVoice):
        speech.resolve("qwen3-tts-1.7b", "qwen3-tts-0.6b:Ryan")
    with pytest.raises(UnknownVoice):
        speech.resolve("qwen3-tts-1.7b", "af_heart")
    with pytest.raises(UnknownModel):
        speech.resolve("tts-1", "Ryan")
    missing, _ = backend({})
    with pytest.raises(ModelUnavailable):
        missing.resolve("qwen3-tts-1.7b", "Ryan")


def test_synthesis_maps_language_and_style(dirs) -> None:
    speech, (loaded, _) = backend(dirs)
    result = speech.synthesize(
        SpeechJob("qwen3-tts-1.7b", "Hello.", "Ryan", instructions="cheerful", language="en-GB", response_format="wav")
    )
    assert result.media_type == "audio/wav" and result.data[:4] == b"RIFF"
    call = loaded[0].calls[0]
    assert (call["voice"], call["instruct"], call["lang_code"], call["text"]) == ("Ryan", "cheerful", "english", "Hello.")
    speech.synthesize(SpeechJob("qwen3-tts-0.6b", "Hi.", "Aiden", instructions="cheerful", response_format="wav"))
    assert loaded[1].calls[0]["instruct"] is None
    assert loaded[1].calls[0]["lang_code"] == "auto"


class ChattyKokoro(FakeModel):
    """Like mlx-audio's Kokoro pipeline: prints and logs text-derived phonemes while it generates."""

    def generate(self, **kwargs):
        import logging
        import sys

        print("phonemes: " + kwargs["text"])
        sys.stderr.write("phonemes: " + kwargs["text"] + "\n")
        logging.warning("len(ps) == 999 > 510: " + kwargs["text"])
        yield from super().generate(**kwargs)


def test_kokoro_voices_come_from_the_local_folder_and_nothing_is_printed(dirs, capsys) -> None:
    # Review L1 M9: a request never downloads (the voice is the local file, not a Hugging Face lookup) and the
    # phonemizer's output, which quotes the text, never reaches the terminal.
    loaded: list[FakeModel] = []

    def load(directory: Path) -> FakeModel:
        model = ChattyKokoro(directory)
        loaded.append(model)
        return model

    speech = MLXSpeech(
        locate=lambda spec: dirs.get(spec.id), has_module=lambda name: True, load=load, release=lambda: None
    )
    speech.synthesize(SpeechJob("kokoro-82m", "SYNTHETIC-SECRET-TEXT", "af_heart", response_format="wav"))
    call = loaded[0].calls[0]
    assert call["voice"] == str(dirs["kokoro-82m"] / "voices" / "af_heart.safetensors")
    assert call["lang_code"] == "a"
    captured = capsys.readouterr()
    assert "SYNTHETIC-SECRET-TEXT" not in captured.out + captured.err


def test_one_model_stays_resident(dirs) -> None:
    speech, (loaded, released) = backend(dirs)
    job = SpeechJob("qwen3-tts-1.7b", "One.", "Ryan", response_format="wav")
    speech.synthesize(job)
    speech.synthesize(job)
    assert len(loaded) == 1 and released == []
    speech.synthesize(SpeechJob("kokoro-82m", "Two.", "af_heart", response_format="wav"))
    assert len(loaded) == 2 and released == [True]
    assert loaded[1].calls[0]["lang_code"] == "a"


def test_generation_failure_reports_the_type_only(dirs) -> None:
    speech, _ = backend(dirs, fail=True)
    with pytest.raises(SynthesisFailed) as raised:
        speech.synthesize(SpeechJob("qwen3-tts-1.7b", "Patient Jane Roe", "Ryan", response_format="wav"))
    assert "Jane" not in raised.value.message and "ValueError" in raised.value.message


def test_load_failure_is_503(dirs) -> None:
    def broken(_directory):
        raise OSError("disk")

    speech = MLXSpeech(locate=lambda spec: dirs.get(spec.id), has_module=lambda _: True, load=broken)
    with pytest.raises(ModelUnavailable):
        speech.synthesize(SpeechJob("qwen3-tts-1.7b", "Hi.", "Ryan", response_format="wav"))


def test_mp3_without_ffmpeg_is_refused_before_synthesis(dirs, monkeypatch) -> None:
    monkeypatch.setattr(audio, "ffmpeg_path", lambda: None)
    speech, (loaded, _) = backend(dirs)
    with pytest.raises(EncoderUnavailable):
        speech.synthesize(SpeechJob("qwen3-tts-1.7b", "Hi.", "Ryan", response_format="mp3"))
    assert loaded == []


def test_model_dir_completeness(tmp_path) -> None:
    directory = tmp_path / "m"
    directory.mkdir()
    assert not is_complete_model_dir(directory)
    (directory / "config.json").write_text("{}")
    assert not is_complete_model_dir(directory)
    (directory / "model.safetensors.index.json").write_text(
        json.dumps({"weight_map": {"a": "model-1.safetensors", "b": "model-2.safetensors"}})
    )
    (directory / "model-1.safetensors").write_bytes(b"x")
    assert not is_complete_model_dir(directory)
    (directory / "model-2.safetensors").write_bytes(b"x")
    assert is_complete_model_dir(directory)


def test_pytorch_kokoro_folder_is_not_an_mlx_model(tmp_path) -> None:
    folder = tmp_path / "Kokoro-82M"
    (folder / "voices").mkdir(parents=True)
    (folder / "config.json").write_text("{}")
    (folder / "kokoro-v1_0.pth").write_bytes(b"x")
    (folder / "voices" / "af_heart.pt").write_bytes(b"x")
    assert not is_complete_model_dir(folder)
