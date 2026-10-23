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
from pathlib import Path
from urllib.parse import unquote_plus

import boto3
from botocore.exceptions import ClientError

from . import PipelineError
from .config import Settings
from .pipeline import run as run_pipeline
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
    def __init__(self, settings: Settings, *, sqs, s3, table, polly=None, model=None, worker_id=None, clock=time.time):
        settings.require_consumer()
        self.settings = settings
        self.sqs = sqs
        self.s3 = s3
        self.table = table
        self.polly = polly
        self.model = model
        self.clock = clock
        self.worker_id = worker_id or f"{socket.gethostname()}-{os.getpid()}-{uuid.uuid4().hex[:6]}"
        self.stopping = threading.Event()
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

        if not self._claim(job_id, obj.etag):
            return self._claim_failed(job_id, receipt)
        return self._process(job_id, obj, receipt, receives)

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

    def _process(self, job_id: str, obj: S3Object, receipt: str, receives: int) -> str:
        log.info("job %s: claimed by %s (receive %d)", job_id, self.worker_id, receives)
        self._busy = True
        try:
            with Heartbeat(self, job_id, receipt) as heartbeat, tempfile.TemporaryDirectory(prefix="job-") as tmp:
                src = Path(tmp) / Path(obj.key).name
                self.s3.download_file(obj.bucket, obj.key, str(src))
                out = run_pipeline(src, Path(tmp) / "output.mp4", self.settings, model=self.model, polly=self.polly)
                if heartbeat.lost.is_set():
                    log.warning("job %s: lease was lost mid-job; abandoning to the new owner", job_id)
                    return "lost_lease"
                self.s3.upload_file(str(out), obj.bucket, output_key(job_id), ExtraArgs={"ContentType": "video/mp4"})

            # Delete LAST: the message is the job's retry ticket. Deleting
            # before "done" is durable would turn a crash into a lost job.
            if not self._set_status(job_id, "done"):
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
            # Possibly transient (network, throttling, a bug): leave the message
            # so SQS retries; after max_receives it moves to the DLQ.
            if receives >= self.settings.max_receives:
                log.exception("job %s: failed on final attempt %d; message goes to the DLQ", job_id, receives)
                self._set_status(job_id, "failed", error=f"gave up after {receives} attempts: {exc}")
            else:
                log.exception("job %s: error on attempt %d; will retry", job_id, receives)
                # Release the claim so the retry can take it straight away.
                self._set_status(job_id, "pending", error=str(exc))
            return "retry"

        finally:
            self._busy = False
            if self._signals:
                signal.alarm(0)

    # ---- DynamoDB ----------------------------------------------------------

    def _get_job(self, job_id: str) -> dict | None:
        item = self.table.get_item(Key={"job_id": job_id}, ConsistentRead=True).get("Item")
        # TTL deletion is lazy: treat expired items as gone.
        if not item or int(item.get("expires_at", 0)) <= self.clock():
            return None
        return item

    def _claim(self, job_id: str, etag: str) -> bool:
        """Atomically take the job if it's pending or its lease has gone stale."""
        now = int(self.clock())
        try:
            self.table.update_item(
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
            )
            return True
        except ClientError as exc:
            if _condition_failed(exc):
                return False
            raise

    def _set_status(self, job_id: str, status: str, error: str | None = None) -> bool:
        """Update a job this worker owns. False if the lease was lost."""
        names = {"#s": "status"}
        values = {":status": status, ":now": int(self.clock()), ":me": self.worker_id, ":processing": "processing"}
        update = "SET #s = :status, updated_at = :now"
        if error is not None:
            update += ", #e = :error"
            names["#e"] = "error"
            values[":error"] = error[:1000]
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


def main() -> int:
    """Entry point for consumer mode: load the model once, then poll forever."""
    settings = Settings.from_env()
    settings.require_consumer()
    region = settings.aws_region

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
    )
    consumer.install_signal_handlers()
    consumer.run_forever()
    return 0
