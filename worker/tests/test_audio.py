import shutil

import pytest

from reelops_worker import ffmpeg
from reelops_worker.audio import NoAudioStreamError, extract_audio

# Real ffmpeg on tiny generated clips: faking ffprobe would only test the fake.
pytestmark = pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="needs ffmpeg")


def _make_video(path, with_audio):
    args = ["-f", "lavfi", "-i", "testsrc=size=160x120:rate=10:duration=1"]
    if with_audio:
        args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "aac"]
    ffmpeg.run([*args, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-shortest", path])
    return path


def test_missing_audio_stream_raises_clear_error(tmp_path):
    video = _make_video(tmp_path / "silent.mp4", with_audio=False)
    with pytest.raises(NoAudioStreamError, match="has no audio stream"):
        extract_audio(video, tmp_path / "out.wav")
    assert not (tmp_path / "out.wav").exists()


def test_extracts_16khz_mono_wav(tmp_path):
    video = _make_video(tmp_path / "talk.mp4", with_audio=True)
    wav = extract_audio(video, tmp_path / "out.wav")
    stream = ffmpeg.probe(wav)["streams"][0]
    assert (stream["codec_name"], stream["sample_rate"], stream["channels"]) == ("pcm_s16le", "16000", 1)
