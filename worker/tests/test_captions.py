import pytest

from reelops_worker.captions import format_timestamp, split_segment, wrap_lines, write_srt
from reelops_worker.transcribe import Segment


@pytest.mark.parametrize(
    ("seconds", "expected"),
    [
        (0, "00:00:00,000"),
        (1.5, "00:00:01,500"),
        (61.25, "00:01:01,250"),
        (3661.001, "01:01:01,001"),
        # Rounds before splitting: must not produce "00:00:59,1000".
        (59.9996, "00:01:00,000"),
        (-0.2, "00:00:00,000"),
    ],
)
def test_format_timestamp(seconds, expected):
    assert format_timestamp(seconds) == expected


def test_wrap_lines_respects_max_chars():
    text = "This sentence is deliberately long so that it has to wrap onto several lines"
    lines = wrap_lines(text, 20)
    assert all(len(line) <= 20 for line in lines)
    assert " ".join(lines) == text  # no words lost or split


def test_wrap_lines_keeps_overlong_word_whole():
    assert wrap_lines("see https://example.com/a/very/long/path ok", 10) == [
        "see",
        "https://example.com/a/very/long/path",
        "ok",
    ]


def test_wrap_lines_empty():
    assert wrap_lines("   ", 42) == []


def test_short_segment_is_one_caption():
    captions = split_segment(Segment(1.0, 3.0, "Welcome to ReelOps."), 42, 2)
    assert len(captions) == 1
    assert (captions[0].start, captions[0].end) == (1.0, 3.0)
    assert captions[0].lines == ("Welcome to ReelOps.",)


def test_long_segment_splits_within_limits():
    text = " ".join(["word"] * 60)  # ~300 chars
    seg = Segment(10.0, 30.0, text)
    captions = split_segment(seg, 42, 2)

    assert len(captions) > 1
    assert all(len(c.lines) <= 2 for c in captions)
    assert all(len(line) <= 42 for c in captions for line in c.lines)
    # Captions tile the segment exactly: no gaps, no overlaps.
    assert captions[0].start == seg.start
    assert captions[-1].end == pytest.approx(seg.end)
    for a, b in zip(captions, captions[1:]):
        assert a.end == pytest.approx(b.start)


def test_time_is_shared_by_character_count():
    # Two lines of 10 chars, max_lines=1: two captions with equal text -> equal time.
    captions = split_segment(Segment(0.0, 4.0, "aaaaaaaaaa bbbbbbbbbb"), 10, 1)
    assert [c.lines for c in captions] == [("aaaaaaaaaa",), ("bbbbbbbbbb",)]
    assert captions[0].end == pytest.approx(2.0)


def test_write_srt_format(tmp_path):
    segments = [Segment(0.0, 1.5, "Hello."), Segment(2.0, 3.25, "World.")]
    out = write_srt(segments, tmp_path / "c.srt", 42, 2)
    assert out.read_text(encoding="utf-8") == (
        "1\n00:00:00,000 --> 00:00:01,500\nHello.\n\n"
        "2\n00:00:02,000 --> 00:00:03,250\nWorld.\n"
    )
