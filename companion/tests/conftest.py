from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from parakeet_companion.app import create_app
from parakeet_companion.config import CompanionSettings

from .fakes import TOKEN, FakeSpeech, FakeYouTube


@pytest.fixture
def speech() -> FakeSpeech:
    return FakeSpeech()


@pytest.fixture
def youtube() -> FakeYouTube:
    return FakeYouTube()


@pytest.fixture
def client(speech: FakeSpeech, youtube: FakeYouTube) -> TestClient:
    app = create_app(CompanionSettings(token=TOKEN), speech=speech, youtube=youtube)
    return TestClient(app)


@pytest.fixture
def auth() -> dict[str, str]:
    return {"Authorization": f"Bearer {TOKEN}"}
