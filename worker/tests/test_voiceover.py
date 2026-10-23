import logging

import pytest

from reelops_worker import PipelineError
from reelops_worker.config import Settings
from reelops_worker.transcribe import Segment
from reelops_worker.voiceover import Fit, fit_to_slot, resolve_voice, slots

# --- slot and atempo math ----------------------------------------------------


def test_slots_run_to_next_start_and_video_end():
    segments = [Segment(0.5, 2.0, "a"), Segment(3.0, 4.0, "b"), Segment(6.0, 7.0, "c")]
    assert slots(segments, duration=10.0) == [2.5, 3.0, 4.0]


def test_slots_never_negative():
    # Last segment starting after the reported duration (rounding) -> 0, not negative.
    assert slots([Segment(10.2, 10.5, "a")], duration=10.0) == [0.0]


def test_clip_that_fits_is_unchanged():
    assert fit_to_slot(clip=2.0, slot=3.0, max_speedup=1.5) == Fit(1.0, 0.0)


def test_exact_fit_is_unchanged():
    assert fit_to_slot(clip=3.0, slot=3.0, max_speedup=1.5) == Fit(1.0, 0.0)


def test_clip_is_sped_up_to_fit_within_cap():
    fit = fit_to_slot(clip=3.0, slot=2.5, max_speedup=1.5)
    assert fit.tempo == pytest.approx(1.2)
    assert fit.overrun == pytest.approx(0.0)


def test_speedup_is_capped_and_overrun_reported():
    fit = fit_to_slot(clip=6.0, slot=2.0, max_speedup=1.5)
    assert fit.tempo == 1.5
    assert fit.overrun == pytest.approx(2.0)  # 6 / 1.5 = 4s in a 2s slot


def test_zero_slot_uses_max_speedup():
    fit = fit_to_slot(clip=3.0, slot=0.0, max_speedup=1.5)
    assert fit == Fit(1.5, 2.0)


# --- voice selection (fake Polly client, no AWS) -----------------------------


class FakePolly:
    """Stands in for boto3's Polly client; returns voices in pages of one."""

    def __init__(self, voices):
        self.voices = voices

    def describe_voices(self, Engine, NextToken=None):
        i = int(NextToken or 0)
        page = {"Voices": self.voices[i : i + 1]}
        if i + 1 < len(self.voices):
            page["NextToken"] = str(i + 1)
        return page


KAJAL = {"Id": "Kajal", "LanguageCode": "en-IN", "AdditionalLanguageCodes": ["hi-IN"]}
JOANNA = {"Id": "Joanna", "LanguageCode": "en-US"}


def test_prefers_configured_voice_with_language():
    # Kajal is on the second page, so this also checks pagination.
    polly = FakePolly([JOANNA, KAJAL])
    assert resolve_voice(polly, Settings()) == ("Kajal", "en-IN")


def test_falls_back_without_unsupported_language(caplog):
    polly = FakePolly([JOANNA])
    with caplog.at_level(logging.WARNING):
        assert resolve_voice(polly, Settings()) == ("Joanna", None)
    assert "falling back to Joanna" in caplog.text


def test_no_usable_voice_is_a_clear_error():
    with pytest.raises(PipelineError, match="neither Kajal nor Joanna"):
        resolve_voice(FakePolly([{"Id": "Matthew", "LanguageCode": "en-US"}]), Settings())
