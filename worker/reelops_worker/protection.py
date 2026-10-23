"""ECS task scale-in protection, set through the ECS agent endpoint.

While a worker holds a job its task is protected, so a scale-in (e.g. desired
3 -> 1) stops idle tasks instead of busy ones. Best-effort: a failed call logs
a warning and the job carries on. Without $ECS_AGENT_URI (local runs, tests)
it does nothing. The agent calls ecs:UpdateTaskProtection with the task role.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request
from contextlib import contextmanager

log = logging.getLogger(__name__)


class TaskProtection:
    def __init__(self, agent_uri: str | None = None, expires_minutes: int = 60, timeout: float = 3.0):
        self.agent_uri = agent_uri if agent_uri is not None else os.environ.get("ECS_AGENT_URI")
        # Safety net: protection lapses on its own if a worker dies holding it.
        self.expires_minutes = expires_minutes
        self.timeout = timeout

    @property
    def enabled(self) -> bool:
        return bool(self.agent_uri)

    def set(self, protected: bool) -> bool:
        """Turn this task's scale-in protection on or off. True on success."""
        if not self.enabled:
            return False
        body = {"ProtectionEnabled": protected}
        if protected:
            body["ExpiresInMinutes"] = self.expires_minutes
        request = urllib.request.Request(
            f"{self.agent_uri}/task-protection/v1/state",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
            method="PUT",
        )
        state = "on" if protected else "off"
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as exc:
            log.warning("task protection %s failed: HTTP %s %s", state, exc.code, exc.read()[:300])
            return False
        except (urllib.error.URLError, OSError, ValueError) as exc:
            log.warning("task protection %s failed: %s", state, exc)
            return False
        # The agent reports ECS API failures in the body, sometimes with 200.
        if payload.get("failure") or payload.get("error"):
            log.warning("task protection %s failed: %s", state, payload.get("failure") or payload.get("error"))
            return False
        log.info("task protection %s", state)
        return True

    @contextmanager
    def protected(self, job_id: str):
        """Protect the task for the duration of a job; always clear afterwards."""
        on = self.set(True)
        try:
            yield on
        finally:
            if on:
                self.set(False)
