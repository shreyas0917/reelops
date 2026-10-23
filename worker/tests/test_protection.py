import logging
import socket

import pytest
from fake_ecs_agent import fake_agent

from reelops_worker.config import Settings
from reelops_worker.protection import TaskProtection


def test_disabled_without_agent_uri(monkeypatch):
    monkeypatch.delenv("ECS_AGENT_URI", raising=False)
    tp = TaskProtection()
    assert not tp.enabled
    assert tp.set(True) is False


def test_reads_agent_uri_from_environment(monkeypatch):
    monkeypatch.setenv("ECS_AGENT_URI", "http://169.254.170.2/v3/abc")
    assert TaskProtection().enabled


def test_request_shape_on_and_off():
    with fake_agent() as agent:
        tp = TaskProtection(agent.url, expires_minutes=60)
        assert tp.set(True) is True
        assert agent.protected is True
        assert tp.set(False) is True
        assert agent.protected is False
    (m1, p1, ct1, b1), (m2, p2, ct2, b2) = agent.requests
    assert (m1, p1, ct1) == ("PUT", "/task-protection/v1/state", "application/json")
    assert b1 == {"ProtectionEnabled": True, "ExpiresInMinutes": 60}
    assert (m2, p2, b2) == ("PUT", "/task-protection/v1/state", {"ProtectionEnabled": False})


@pytest.mark.parametrize("mode", ["http_error", "failure"])
def test_agent_errors_are_warnings_not_exceptions(mode, caplog):
    with fake_agent() as agent:
        agent.mode = mode
        with caplog.at_level(logging.WARNING):
            assert TaskProtection(agent.url).set(True) is False
    assert "task protection on failed" in caplog.text


def test_unreachable_agent_is_a_warning(caplog):
    with socket.socket() as s:  # find a free port, then leave it closed
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    with caplog.at_level(logging.WARNING):
        assert TaskProtection(f"http://127.0.0.1:{port}", timeout=1).set(True) is False
    assert "task protection on failed" in caplog.text


def test_context_manager_protects_then_clears():
    with fake_agent() as agent:
        with TaskProtection(agent.url).protected("job-1") as on:
            assert on is True
            assert agent.protected is True
        assert agent.protected is False
    assert [b["ProtectionEnabled"] for *_, b in agent.requests] == [True, False]


def test_context_manager_skips_clear_if_set_failed():
    with fake_agent() as agent:
        agent.mode = "http_error"
        with TaskProtection(agent.url).protected("job-1") as on:
            assert on is False
    assert len(agent.requests) == 1  # no pointless "off" call


@pytest.mark.parametrize("minutes", [0, 2881])
def test_protection_minutes_bounds(minutes):
    with pytest.raises(ValueError, match="task_protection_minutes"):
        Settings(task_protection_minutes=minutes)
