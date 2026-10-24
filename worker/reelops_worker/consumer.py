"""Queue consumer: S3 upload events (via SQS) -> pipeline -> output/<job_id>.mp4.

Run with: python -m reelops_worker consume

Delivery is at-least-once (S3 and SQS can both duplicate), so a job is
claimed with a conditional DynamoDB write and the SQS message is deleted only
after the result is durable. A crash anywhere therefore means a retry, never a
lost job.
"""

from __future__ import annotations

import json
import logging
import os
import re
import signal
import socket
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from urllib.parse import unquote_plus

import boto3
from botocore.exceptions import ClientError

from . import PipelineError
from .captions import Caption
from .config import Settings
from .pipeline import run as run_pipeline
from .protection import TaskProtection
from .transcribe import load_model

log = logging.getLogger(__name__)

# Keys the API hands out: raw/<uuid4>/input.<ext>
JOB_KEY = re.compile(r"^raw/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/[^/]+$")


class Shutdown(Exception):
    """Raised by SIGALRM when the shutdown grace period runs out mid-job."""


@dataclass(frozen=True)
class S3Object:
    bucket: str
    key: str
    size: int
    etag: str


def parse_event(body: str) -> S3Object | None:
    """Return the uploaded object from an S3 event message, or None for the
    s3:TestEvent that S3 sends when the notification is configured.

    Raises ValueError for anything else; the message is then left for retry
    and ends up in the DLQ, where the alarm makes a human look at it.
    """
    event = json.loads(body)
    if event.get("Event") == "s3:TestEvent":
        return None
    try:
        records = event["Records"]
        # S3 sends one record per message; anything else is unexpected.
        if len(records) != 1:
            raise ValueError(f"expected 1 record, got {len(records)}")
        obj = records[0]["s3"]
        return S3Object(
            bucket=obj["bucket"]["name"],
            # Keys in S3 events are URL-encoded, form style ("my video.mp4"
            # arrives as "my+video.mp4"); the API needs the real key.
            key=unquote_plus(obj["object"]["key"]),
            size=int(obj["object"].get("size", 0)),
            etag=obj["object"].get("eTag", ""),
        )
    except (KeyError, TypeError, IndexError) as exc:
        raise ValueError(f"not an S3 event message: {exc!r}") from exc


def job_id_from_key(key: str) -> str | None:
    match = JOB_KEY.match(key)
    return match.group(1) if match else None


def output_key(job_id: str) -> str:
    return f"output/{job_id}.mp4"


# A DynamoDB item is at most 400 KB. A caption is ~100-150 bytes stored, so
# this keeps the job well under it (and is ~1.5 hours of continuous speech).
MAX_STORED_CAPTIONS = 2000


def segments_item(captions: list[Caption]) -> list[dict]:
    """Captions as stored on the job for the web UI's caption track.

    DynamoDB has no float type (boto3 rejects Python floats), so times are
    Decimals, rounded to milliseconds like the SRT file.
    """
    if len(captions) > MAX_STORED_CAPTIONS:
        log.warning("%d captions; storing the first %d on the job", len(captions), MAX_STORED_CAPTIONS)
    return [
        {"start": Decimal(f"{c.start:.3f}"), "end": Decimal(f"{c.end:.3f}"), "text": " ".join(c.lines)}
        for c in captions[:MAX_STORED_CAPTIONS]
    ]


def _condition_failed(exc: ClientError) -> bool:
    return exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException"


class Heartbeat:
    """While a job runs: every heartbeat_seconds, push the message's visibility
    out again and refresh the lease (only while this worker still owns it).
    """

    def __init__(self, consumer: Consumer, job_id: str, receipt_handle: str):
        self.consumer = consumer
        self.job_id = job_id
        self.receipt_handle = receipt_handle
        self.lost = threading.Event()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name=f"heartbeat-{job_id[:8]}", daemon=True)

    def __enter__(self) -> Heartbeat:
        self._thread.start()
        return self

    def __exit__(self, *exc_info) -> None:
        self._stop.set()
        self._thread.join()

    def _run(self) -> None:
        c = self.consumer
        while not self._stop.wait(c.settings.heartbeat_seconds):
            try:
                c.sqs.change_message_visibility(
                    QueueUrl=c.settings.jobs_queue_url,
                    ReceiptHandle=self.receipt_handle,
                    VisibilityTimeout=c.settings.visibility_timeout,
                )
                now = int(c.clock())
                c.table.update_item(
                    Key={"job_id": self.job_id},
                    UpdateExpression="SET claimed_at = :now, updated_at = :now",
                    ConditionExpression="worker_id = :me AND #s = :processing",
                    ExpressionAttributeNames={"#s": "status"},
                    ExpressionAttributeValues={":now": now, ":me": c.worker_id, ":processing": "processing"},
                )
                log.debug("job %s: heartbeat", self.job_id)
            except ClientError as exc:
                if _condition_failed(exc):
                    log.warning("job %s: lease lost to another worker", self.job_id)
                    self.lost.set()
                    return
                log.warning("job %s: heartbeat failed, will retry: %s", self.job_id, exc)


class Consumer:
    def __init__(
        self, settings: Settings, *, sqs, s3, table, polly=None, model=None, worker_id=None, clock=time.time,
        stopping: threading.Event | None = None, protection: TaskProtection | None = None,
    ):  # fmt: skip
        settings.require_consumer()
        self.settings = settings
        self.sqs = sqs
        self.s3 = s3
        self.table = table
        self.polly = polly
        self.model = model
        self.clock = clock
        self.worker_id = worker_id or f"{socket.gethostname()}-{os.getpid()}-{uuid.uuid4().hex[:6]}"
        # May already be set: a stop requested during startup is not lost.
        self.stopping = stopping or threading.Event()
        # Disabled unless $ECS_AGENT_URI is set (i.e. running on ECS).
        self.protection = protection or TaskProtection(expires_minutes=settings.task_protection_minutes)
        self._busy = False
        self._signals = False

    # ---- lifecycle -------------------------------------------------------

    def install_signal_handlers(self) -> None:
        """SIGTERM (ECS stop) / SIGINT (Ctrl-C): stop taking work. SIGALRM:
        grace period over mid-job, unwind it.
        """
        signal.signal(signal.SIGTERM, self.request_stop)
        signal.signal(signal.SIGINT, self.request_stop)
        signal.signal(signal.SIGALRM, self._grace_expired)
        self._signals = True

    def request_stop(self, signum=None, frame=None) -> None:
        if self.stopping.is_set():
            return
        self.stopping.set()
        if self._busy and self._signals:
            log.info("stop requested: finishing current job (up to %ss), taking no new messages",
                     self.settings.shutdown_grace_seconds)  # fmt: skip
            signal.alarm(self.settings.shutdown_grace_seconds)
        else:
            log.info("stop requested: exiting after the current poll")

    def _grace_expired(self, signum, frame) -> None:
        raise Shutdown()

    def run_forever(self) -> None:
        if self.stopping.is_set():
            log.info("stop requested during startup; not polling")
            return
        log.info("worker %s polling %s", self.worker_id, self.settings.jobs_queue_url)
        while not self.stopping.is_set():
            try:
                response = self.sqs.receive_message(
                    QueueUrl=self.settings.jobs_queue_url,
                    MaxNumberOfMessages=1,
                    WaitTimeSeconds=20,  # long polling
                    MessageSystemAttributeNames=["ApproximateReceiveCount"],
                )
            except ClientError as exc:
                log.warning("receive failed, retrying in 5 s: %s", exc)
                self.stopping.wait(5)
                continue
            for message in response.get("Messages", []):
                if self.stopping.is_set():
                    # Arrived during shutdown: hand it straight back.
                    self._release_message(message["ReceiptHandle"])
                    continue
                try:
                    self.handle(message)
                except Exception:
                    # Unexpected: leave the message; SQS retries, then the DLQ.
                    log.exception("unhandled error; message left for retry")
        log.info("worker %s stopped", self.worker_id)

    # ---- one message -----------------------------------------------------

    def handle(self, message: dict) -> str:
        """Process one SQS message. Returns an outcome name (for logs/tests)."""
        receipt = message["ReceiptHandle"]
        receives = int(message.get("Attributes", {}).get("ApproximateReceiveCount", 1))

        obj = parse_event(message["Body"])
        if obj is None:
            log.info("ignoring s3:TestEvent")
            self._delete(receipt)
            return "test_event"

        job_id = job_id_from_key(obj.key) if obj.bucket == self.settings.media_bucket else None
        job = self._get_job(job_id) if job_id else None
        if job is None or job.get("s3_key") != obj.key:
            log.warning("no job for s3://%s/%s; dropping message", obj.bucket, obj.key)
            self._delete(receipt)
            return "unknown_job"

        if obj.size > self.settings.max_input_bytes:
            error = f"upload too large: {obj.size} bytes (max {self.settings.max_input_bytes})"
            log.warning("job %s: %s", job_id, error)
            self._fail_unclaimed(job_id, error)
            self._delete(receipt)
            return "too_large"

        # A job whose earlier attempts all died mid-job (crash, OOM) never
        # reached the "give up" below: stop it here instead of crash-looping.
        attempts = int(job.get("attempts", 0))
        if attempts >= self.settings.max_attempts and self._give_up_unclaimed(job_id, attempts):
            log.warning("job %s: gave up after %d attempts that never finished", job_id, attempts)
            self._delete(receipt)
            return "gave_up"

        attempt = self._claim(job_id, obj.etag)
        if attempt is None:
            return self._claim_failed(job_id, receipt)
        return self._process(job_id, obj, receipt, receives, attempt)

    def _claim_failed(self, job_id: str, receipt: str) -> str:
        job = self._get_job(job_id) or {}
        status = job.get("status")
        if status == "done":
            # At-least-once delivery: the same upload event arrived again.
            log.info("job %s: duplicate skipped (already done)", job_id)
            self._delete(receipt)
            return "duplicate_done"
        if status == "failed":
            log.info("job %s: already failed; dropping message", job_id)
            self._delete(receipt)
            return "already_failed"
        if status == "processing":
            # Another live worker owns it and holds its own message; if that
            # worker dies, its message returns after the lease has expired.
            log.info("job %s: duplicate skipped (lease held by %s)", job_id, job.get("worker_id"))
            self._delete(receipt)
            return "lease_held"
        # E.g. it went back to pending between our claim and this read: retry.
        log.warning("job %s: claim failed with status=%s; leaving message for retry", job_id, status)
        return "retry"

    def _process(self, job_id: str, obj: S3Object, receipt: str, receives: int, attempt: int) -> str:
        log.info("job %s: claimed by %s (attempt %d, receive %d)", job_id, self.worker_id, attempt, receives)
        self._busy = True
        try:
            # Scale-in protection for the whole job, including the final
            # "done" write and the delete; cleared on every exit path.
            with self.protection.protected(job_id):
                return self._run_job(job_id, obj, receipt, attempt)
        finally:
            self._busy = False
            if self._signals:
                signal.alarm(0)

    def _run_job(self, job_id: str, obj: S3Object, receipt: str, attempt: int) -> str:
        try:
            with Heartbeat(self, job_id, receipt) as heartbeat, tempfile.TemporaryDirectory(prefix="job-") as tmp:
                src = Path(tmp) / Path(obj.key).name
                self.s3.download_file(obj.bucket, obj.key, str(src))
                result = run_pipeline(
                    src, Path(tmp) / "output.mp4", self.settings, model=self.model, polly=self.polly
                )
                if heartbeat.lost.is_set():
                    log.warning("job %s: lease was lost mid-job; abandoning to the new owner", job_id)
                    return "lost_lease"
                self.s3.upload_file(
                    str(result.output), obj.bucket, output_key(job_id), ExtraArgs={"ContentType": "video/mp4"}
                )

            # Segments and voice go in the same conditional write as "done":
            # a reader never sees done without them, and a worker that lost
            # its lease can't write them.
            # Delete LAST: the message is the job's retry ticket. Deleting
            # before "done" is durable would turn a crash into a lost job.
            details = {"segments": segments_item(result.captions), "voice": result.voice}
            if not self._set_status(job_id, "done", fields=details):
                log.warning("job %s: lease lost before completion; leaving message to the new owner", job_id)
                return "lost_lease"
            self._delete(receipt)
            log.info("job %s: done -> s3://%s/%s", job_id, obj.bucket, output_key(job_id))
            return "done"

        except PipelineError as exc:
            # Bad input (no audio, no speech, ...): retrying won't help.
            log.warning("job %s: failed: %s", job_id, exc)
            self._set_status(job_id, "failed", error=str(exc))
            self._delete(receipt)
            return "failed"

        except Shutdown:
            # Grace period over: hand the job back so another worker starts now.
            log.warning("job %s: shutdown grace period over; handing job back", job_id)
            self._set_status(job_id, "pending")
            self._release_message(receipt)
            return "abandoned"

        except Exception as exc:
            # Possibly transient (network, throttling, a bug): retry until the
            # job's own attempt count runs out, then fail it for good. The
            # user sees "failed", so the message has nothing left to do.
            if attempt >= self.settings.max_attempts:
                log.exception("job %s: failed on final attempt %d; giving up", job_id, attempt)
                if self._set_status(job_id, "failed", error=f"gave up after {attempt} attempts: {exc}"):
                    self._delete(receipt)
            else:
                log.exception("job %s: error on attempt %d; will retry", job_id, attempt)
                # Release the claim so the retry can take it straight away.
                self._set_status(job_id, "pending", error=str(exc))
            return "retry"

    # ---- DynamoDB ----------------------------------------------------------

    def _get_job(self, job_id: str) -> dict | None:
        item = self.table.get_item(Key={"job_id": job_id}, ConsistentRead=True).get("Item")
        # TTL deletion is lazy: treat expired items as gone.
        if not item or int(item.get("expires_at", 0)) <= self.clock():
            return None
        return item

    def _claim(self, job_id: str, etag: str) -> int | None:
        """Atomically take the job if it's pending or its lease has gone stale.
        Returns the job's attempt number (this claim included), or None.
        """
        now = int(self.clock())
        try:
            response = self.table.update_item(
                Key={"job_id": job_id},
                UpdateExpression=(
                    "SET #s = :processing, claimed_at = :now, updated_at = :now, worker_id = :me, etag = :etag "
                    "REMOVE #e ADD attempts :one"
                ),
                ConditionExpression="#s = :pending OR (#s = :processing AND claimed_at < :stale)",
                ExpressionAttributeNames={"#s": "status", "#e": "error"},
                ExpressionAttributeValues={
                    ":processing": "processing",
                    ":pending": "pending",
                    ":now": now,
                    ":stale": now - self.settings.lease_seconds,
                    ":me": self.worker_id,
                    ":etag": etag,  # recorded as an identifier only
                    ":one": 1,
                },
                ReturnValues="UPDATED_NEW",
            )
            return int(response["Attributes"]["attempts"])
        except ClientError as exc:
            if _condition_failed(exc):
                return None
            raise

    def _set_status(self, job_id: str, status: str, error: str | None = None, fields: dict | None = None) -> bool:
        """Update a job this worker owns, optionally setting extra attributes.
        False if the lease was lost.
        """
        names = {"#s": "status"}
        values = {":status": status, ":now": int(self.clock()), ":me": self.worker_id, ":processing": "processing"}
        update = "SET #s = :status, updated_at = :now"
        if error is not None:
            update += ", #e = :error"
            names["#e"] = "error"
            values[":error"] = error[:1000]
        for i, (name, value) in enumerate((fields or {}).items()):
            update += f", #f{i} = :f{i}"
            names[f"#f{i}"] = name
            values[f":f{i}"] = value
        try:
            self.table.update_item(
                Key={"job_id": job_id},
                UpdateExpression=update,
                ConditionExpression="worker_id = :me AND #s = :processing",
                ExpressionAttributeNames=names,
                ExpressionAttributeValues=values,
            )
            return True
        except ClientError as exc:
            if _condition_failed(exc):
                return False
            raise

    def _give_up_unclaimed(self, job_id: str, attempts: int) -> bool:
        """Fail a claimable job (pending, or a stale lease) that has used up
        its attempts. False if it isn't claimable (e.g. a live worker holds it).
        """
        now = int(self.clock())
        try:
            self.table.update_item(
                Key={"job_id": job_id},
                UpdateExpression="SET #s = :failed, #e = :error, updated_at = :now",
                ConditionExpression=(
                    "attempts >= :max AND (#s = :pending OR (#s = :processing AND claimed_at < :stale))"
                ),
                ExpressionAttributeNames={"#s": "status", "#e": "error"},
                ExpressionAttributeValues={
                    ":failed": "failed",
                    ":pending": "pending",
                    ":processing": "processing",
                    ":max": self.settings.max_attempts,
                    ":stale": now - self.settings.lease_seconds,
                    ":error": f"gave up after {attempts} attempts: the worker stopped during each one",
                    ":now": now,
                },
            )
            return True
        except ClientError as exc:
            if _condition_failed(exc):
                return False
            raise

    def _fail_unclaimed(self, job_id: str, error: str) -> None:
        """Mark a still-pending job failed (e.g. the upload is too large)."""
        try:
            self.table.update_item(
                Key={"job_id": job_id},
                UpdateExpression="SET #s = :failed, #e = :error, updated_at = :now",
                ConditionExpression="#s = :pending",
                ExpressionAttributeNames={"#s": "status", "#e": "error"},
                ExpressionAttributeValues={
                    ":failed": "failed",
                    ":pending": "pending",
                    ":error": error,
                    ":now": int(self.clock()),
                },
            )
        except ClientError as exc:
            if not _condition_failed(exc):
                raise

    # ---- SQS ---------------------------------------------------------------

    def _delete(self, receipt: str) -> None:
        self.sqs.delete_message(QueueUrl=self.settings.jobs_queue_url, ReceiptHandle=receipt)

    def _release_message(self, receipt: str) -> None:
        """Make a message visible again immediately."""
        self.sqs.change_message_visibility(
            QueueUrl=self.settings.jobs_queue_url, ReceiptHandle=receipt, VisibilityTimeout=0
        )


def main(stop: threading.Event | None = None) -> int:
    """Entry point for consumer mode: load the model once, then poll forever.

    `stop` is set by the early SIGTERM handler in __main__, so a stop requested
    during startup is honoured instead of lost.
    """
    stop = stop or threading.Event()
    settings = Settings.from_env()
    settings.require_consumer()
    region = settings.aws_region

    if stop.is_set():
        log.info("stop requested during startup; exiting before loading the model")
        return 0
    started = time.perf_counter()
    model = load_model(settings)
    log.info("Whisper model %s loaded in %.1fs", settings.whisper_model, time.perf_counter() - started)

    consumer = Consumer(
        settings,
        sqs=boto3.client("sqs", region_name=region),
        s3=boto3.client("s3", region_name=region),
        table=boto3.resource("dynamodb", region_name=region).Table(settings.jobs_table),
        polly=boto3.client("polly", region_name=region),
        model=model,
        stopping=stop,
        protection=TaskProtection(expires_minutes=settings.task_protection_minutes),
    )
    protection = "enabled" if consumer.protection.enabled else "disabled (no ECS_AGENT_URI)"
    log.info("task scale-in protection: %s", protection)
    consumer.install_signal_handlers()
    consumer.run_forever()
    return 0
