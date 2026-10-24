import struct
import wave
from types import SimpleNamespace

import numpy as np
from faster_whisper.audio import decode_audio

from reelops_worker.config import Settings
from reelops_worker.transcribe import transcribe


def test_faster_whisper_can_decode_our_wav(tmp_path):
    """Regression guard for dependency drift: faster-whisper decodes audio with
    PyAV, and PyAV 19 broke the call it makes. Needs no model, so it stays a
    fast unit test.
    """
    wav = tmp_path / "tone.wav"
    rate = 16000
    samples = (8000 * np.sin(2 * np.pi * 440 * np.arange(rate) / rate)).astype(np.int16)
    with wave.open(str(wav), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack(f"<{len(samples)}h", *samples))

    audio = decode_audio(str(wav), sampling_rate=rate)
    assert audio.dtype == np.float32
    assert len(audio) == rate  # one second at 16 kHz


class FakeModel:
    """Records the transcribe() call; returns one segment and the info fields we log."""

    def __init__(self):
        self.kwargs = {}

    def transcribe(self, path, **kwargs):
        self.kwargs = kwargs
        info = SimpleNamespace(language="en", language_probability=1.0, duration_after_vad=1.0, duration=1.0)
        return iter([SimpleNamespace(start=0.0, end=1.0, text=" ReelOps captions this. ")]), info


def test_hotwords_reach_whisper(tmp_path):
    model = FakeModel()
    segments = transcribe(tmp_path / "a.wav", Settings(whisper_hotwords="ReelOps"), model)
    assert model.kwargs["hotwords"] == "ReelOps"
    assert [s.text for s in segments] == ["ReelOps captions this."]
    transcribe(tmp_path / "a.wav", Settings(), model)
    assert model.kwargs["hotwords"] is None  # default: no hint
