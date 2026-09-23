"""The command line: the banner never repeats the pairing token, serving is offline for Hugging Face, and third-party
output (a phonemizer's warnings quote text) never reaches the terminal. Review round 1, L1 M1 and M9."""

from __future__ import annotations

import logging
import os
from pathlib import Path

import pytest

from parakeet_companion import __main__ as cli

TOKEN = "synthetic-banner-token-0000000000000000000000"


def banner(capsys, created: bool, show_token: bool, host: str = "0.0.0.0") -> str:
    cli._print_banner(host, 8765, "studio.local", TOKEN, Path("/tmp/token"), created, None, None, show_token)
    return capsys.readouterr().out


def test_the_token_is_printed_only_when_it_is_new(capsys) -> None:
    assert TOKEN in banner(capsys, created=True, show_token=False)
    unchanged = banner(capsys, created=False, show_token=False)
    assert TOKEN not in unchanged
    assert "unchanged" in unchanged and "--show-token" in unchanged and "/tmp/token" in unchanged


def test_show_token_prints_it_again(capsys) -> None:
    assert TOKEN in banner(capsys, created=False, show_token=True)


def test_show_token_is_an_option() -> None:
    args = cli.build_parser().parse_args(["--show-token"])
    assert args.show_token is True
    assert cli.build_parser().parse_args([]).show_token is False


def test_the_banner_says_it_listens_on_every_network(capsys) -> None:
    assert "every network" in banner(capsys, created=False, show_token=False)
    assert "every network" not in banner(capsys, created=False, show_token=False, host="192.168.1.20")


def test_serving_is_offline_for_hugging_face(monkeypatch) -> None:
    monkeypatch.delenv("HF_HUB_OFFLINE", raising=False)
    cli.enter_offline_mode()
    assert os.environ["HF_HUB_OFFLINE"] == "1"


@pytest.fixture
def restored_root_logger():
    root = logging.getLogger()
    handlers, level = list(root.handlers), root.level
    yield root
    root.handlers[:] = handlers
    root.setLevel(level)


def test_third_party_log_lines_never_reach_the_terminal(capsys, restored_root_logger) -> None:
    restored_root_logger.handlers[:] = []  # as in production: nothing but what the companion adds
    cli.silence_third_party_output()
    logging.getLogger("mlx_audio.tts.models.kokoro.pipeline").warning("SYNTHETIC-PHONEMES-4412")
    logging.warning("SYNTHETIC-PHONEMES-4413")
    captured = capsys.readouterr()
    assert "SYNTHETIC-PHONEMES" not in captured.err + captured.out
