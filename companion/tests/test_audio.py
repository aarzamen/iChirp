from __future__ import annotations

import io
import wave

import numpy as np
import pytest

from parakeet_companion import audio


def test_wav_is_mono_16_bit_at_the_model_rate() -> None:
    data = audio.encode_wav(np.linspace(-2, 2, 2_400, dtype=np.float32), 24_000)
    with wave.open(io.BytesIO(data)) as handle:
        assert (handle.getnchannels(), handle.getsampwidth(), handle.getframerate(), handle.getnframes()) == (
            1, 2, 24_000, 2_400,
        )


@pytest.mark.skipif(audio.ffmpeg_path() is None, reason="ffmpeg is not installed on this Mac")
def test_mp3_through_ffmpeg() -> None:
    data, media_type = audio.encode(np.zeros(24_000, dtype=np.float32), 24_000, "mp3")
    assert media_type == "audio/mpeg"
    assert data[:3] == b"ID3" or data[0] == 0xFF
