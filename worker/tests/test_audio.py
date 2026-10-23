import shutil

import pytest

from reelops_worker import PipelineError, ffmpeg
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


DASH_MANIFEST = """<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT1S"
     minBufferTime="PT1S" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011">
  <Period><AdaptationSet mimeType="video/mp4"><Representation id="1" bandwidth="1000">
    <BaseURL>x.mp4</BaseURL></Representation></AdaptationSet></Period>
</MPD>
"""


def test_disguised_non_video_upload_is_rejected_before_parsing(tmp_path):
    # A DASH manifest named .mp4 would otherwise be opened by ffmpeg's DASH
    # demuxer (and libxml2); the upload format whitelist blocks it.
    evil = tmp_path / "input.mp4"
    evil.write_text(DASH_MANIFEST)
    with pytest.raises(PipelineError, match="isn't an MP4, MOV or WebM video"):
        extract_audio(evil, tmp_path / "out.wav")


def test_upload_input_uses_the_whitelist(tmp_path):
    args = ffmpeg.upload_input(tmp_path / "a.mp4")
    assert args[:2] == ["-format_whitelist", ffmpeg.UPLOAD_FORMATS]
    assert "dash" not in ffmpeg.UPLOAD_FORMATS.split(",")
