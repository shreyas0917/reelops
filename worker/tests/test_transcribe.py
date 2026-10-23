import struct
import wave

import numpy as np
from faster_whisper.audio import decode_audio


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
