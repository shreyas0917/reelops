import pytest

from reelops_worker.config import Settings


def test_defaults():
    s = Settings.from_env({})
    assert s.whisper_model == "base"
    assert s.whisper_compute_type == "int8"
    assert s.polly_voice == "Kajal"
    assert s.polly_fallback_voice == "Joanna"
    assert s.max_speedup == 1.5
    assert s.aws_region == "ap-south-1"
    assert s.whisper_hotwords is None  # no transcription hint unless configured


def test_whisper_hotwords_from_env():
    assert Settings.from_env({"REELOPS_WHISPER_HOTWORDS": " ReelOps "}).whisper_hotwords == "ReelOps"


def test_env_overrides():
    s = Settings.from_env(
        {
            "REELOPS_WHISPER_MODEL": "small",
            "REELOPS_POLLY_VOICE": "Matthew",
            "REELOPS_MAX_SPEEDUP": "1.25",
            "REELOPS_CAPTION_MAX_CHARS": "32",
        }
    )
    assert s.whisper_model == "small"
    assert s.polly_voice == "Matthew"
    assert s.max_speedup == 1.25
    assert s.caption_max_chars == 32


def test_blank_values_fall_back_to_defaults():
    assert Settings.from_env({"REELOPS_POLLY_VOICE": "  "}).polly_voice == "Kajal"


def test_language_auto_means_detect():
    assert Settings.from_env({"REELOPS_LANGUAGE": "auto"}).language is None


def test_region_precedence():
    assert Settings.from_env({"AWS_DEFAULT_REGION": "us-east-1"}).aws_region == "us-east-1"
    env = {"AWS_REGION": "eu-west-1", "AWS_DEFAULT_REGION": "us-east-1"}
    assert Settings.from_env(env).aws_region == "eu-west-1"


@pytest.mark.parametrize("value", ["0.9", "2.5"])
def test_max_speedup_out_of_range(value):
    with pytest.raises(ValueError, match="REELOPS_MAX_SPEEDUP"):
        Settings.from_env({"REELOPS_MAX_SPEEDUP": value})


def test_non_numeric_is_a_clear_error():
    with pytest.raises(ValueError, match="REELOPS_MAX_SPEEDUP must be a float"):
        Settings.from_env({"REELOPS_MAX_SPEEDUP": "fast"})
