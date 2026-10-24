import logging
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


@pytest.mark.parametrize("kind", ["text named .mp4", "truncated mp4"])
def test_unreadable_upload_gets_a_friendly_error_without_internals(tmp_path, caplog, kind):
    upload = tmp_path / "input.mp4"
    if kind == "text named .mp4":
        upload.write_text("This is a text file pretending to be a video.\n" * 200)
    else:
        # No faststart: the moov index is at the end, so the cut removes it.
        real = _make_video(tmp_path / "real.mp4", with_audio=True)
        upload.write_bytes(real.read_bytes()[: real.stat().st_size // 3])
    with caplog.at_level(logging.WARNING), pytest.raises(PipelineError) as err:
        ffmpeg.has_stream(upload, "video", untrusted=True)
    assert str(err.value) == (
        "input.mp4 isn't an MP4, MOV or WebM video we can read. Export it as MP4 and upload it again."
    )
    # ffprobe's details (temp path, demuxer, memory address) stay in the logs.
    assert "ffprobe rejected upload input.mp4" in caplog.text
    assert "moov atom not found" in caplog.text or "Invalid data" in caplog.text


def test_trusted_probe_failure_keeps_the_details(tmp_path):
    # Our own intermediate files: a failure there is a bug, so keep stderr.
    broken = tmp_path / "voice.wav"
    broken.write_text("not audio")
    with pytest.raises(PipelineError, match=r"ffprobe \(voice.wav\) failed"):
        ffmpeg.probe(broken)
