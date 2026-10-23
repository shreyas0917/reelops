import json
import logging
import time
import uuid
from pathlib import Path
from urllib.parse import quote_plus

import boto3
import pytest
from moto import mock_aws

from reelops_worker import PipelineError, consumer
from reelops_worker.config import Settings
from reelops_worker.consumer import Consumer, Heartbeat, Shutdown, job_id_from_key, parse_event

REGION = "ap-south-1"
BUCKET = "reelops-media-test"
NOW = 1_800_000_000


class Clock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


@pytest.fixture
def aws():
    with mock_aws():
        sqs = boto3.client("sqs", region_name=REGION)
        queue_url = sqs.create_queue(QueueName="jobs", Attributes={"VisibilityTimeout": "300"})["QueueUrl"]
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket=BUCKET, CreateBucketConfiguration={"LocationConstraint": REGION})
        table = boto3.resource("dynamodb", region_name=REGION).create_table(
            TableName="jobs",
            KeySchema=[{"AttributeName": "job_id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "job_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        yield sqs, queue_url, s3, table


@pytest.fixture
def settings(aws):
    _, queue_url, _, _ = aws
    return Settings(jobs_queue_url=queue_url, media_bucket=BUCKET, jobs_table="jobs")


@pytest.fixture
def clock():
    return Clock(NOW)


@pytest.fixture
def worker(aws, settings, clock):
    sqs, _, s3, table = aws
    return Consumer(settings, sqs=sqs, s3=s3, table=table, worker_id="worker-me", clock=clock)


@pytest.fixture
def fake_pipeline(monkeypatch):
    """Replace the real pipeline (ffmpeg/Whisper/Polly) with a recorder."""
    calls = []

    def run(video, out_mp4, settings, *, model=None, polly=None):
        calls.append(Path(video).read_bytes())
        Path(out_mp4).write_bytes(b"fake rendered video")
        return Path(out_mp4)

    monkeypatch.setattr(consumer, "run_pipeline", run)
    return calls


# ---- helpers -----------------------------------------------------------------


def s3_event(key, size=1000, etag="etag-1", bucket=BUCKET):
    # S3 URL-encodes keys in event JSON, form style.
    obj = {"key": quote_plus(key, safe="/"), "size": size, "eTag": etag}
    return json.dumps({"Records": [{"eventName": "ObjectCreated:Put", "s3": {"bucket": {"name": bucket}, "object": obj}}]})


def deliver(aws, body):
    """Send a message through the moto queue and receive it, like the worker would."""
    sqs, queue_url, _, _ = aws
    sqs.send_message(QueueUrl=queue_url, MessageBody=body)
    msgs = sqs.receive_message(QueueUrl=queue_url, MessageSystemAttributeNames=["ApproximateReceiveCount"])
    return msgs["Messages"][0]


def queue_counts(aws):
    sqs, queue_url, _, _ = aws
    attrs = sqs.get_queue_attributes(
        QueueUrl=queue_url, AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"]
    )["Attributes"]
    return int(attrs["ApproximateNumberOfMessages"]), int(attrs["ApproximateNumberOfMessagesNotVisible"])


def make_job(aws, status="pending", filename="input.mp4", upload=True, **fields):
    _, _, s3, table = aws
    job_id = str(uuid.uuid4())
    key = f"raw/{job_id}/{filename}"
    item = {"job_id": job_id, "status": status, "s3_key": key, "attempts": 0,
            "created_at": NOW - 60, "updated_at": NOW - 60, "expires_at": NOW + 86400, **fields}  # fmt: skip
    table.put_item(Item=item)
    if upload:
        s3.put_object(Bucket=BUCKET, Key=key, Body=b"original upload")
    return job_id, key


def job(aws, job_id):
    return aws[3].get_item(Key={"job_id": job_id}, ConsistentRead=True)["Item"]


# ---- parsing -----------------------------------------------------------------


def test_url_encoded_key_is_decoded():
    obj = parse_event(s3_event("raw/abc/My Demo (final) é.mp4"))
    assert obj.key == "raw/abc/My Demo (final) é.mp4"


def test_test_event_parses_to_none():
    assert parse_event(json.dumps({"Service": "Amazon S3", "Event": "s3:TestEvent"})) is None


@pytest.mark.parametrize("body", ['{"hello": 1}', '{"Records": []}', "not json"])
def test_unexpected_messages_raise(body):
    with pytest.raises(ValueError):
        parse_event(body)


def test_job_id_from_key():
    job_id = str(uuid.uuid4())
    assert job_id_from_key(f"raw/{job_id}/input.mp4") == job_id
    assert job_id_from_key(f"output/{job_id}.mp4") is None
    assert job_id_from_key("raw/not-a-uuid/input.mp4") is None


# ---- message handling ----------------------------------------------------------


def test_test_event_is_deleted(aws, worker):
    msg = deliver(aws, json.dumps({"Service": "Amazon S3", "Event": "s3:TestEvent"}))
    assert worker.handle(msg) == "test_event"
    assert queue_counts(aws) == (0, 0)


def test_pending_job_is_processed(aws, worker, fake_pipeline):
    job_id, key = make_job(aws)
    assert worker.handle(deliver(aws, s3_event(key, etag="abc123"))) == "done"

    item = job(aws, job_id)
    assert item["status"] == "done"
    assert item["worker_id"] == "worker-me"
    assert item["etag"] == "abc123"
    assert item["attempts"] == 1
    assert fake_pipeline == [b"original upload"]
    out = aws[2].get_object(Bucket=BUCKET, Key=f"output/{job_id}.mp4")
    assert out["Body"].read() == b"fake rendered video"
    assert out["ContentType"] == "video/mp4"
    assert queue_counts(aws) == (0, 0)  # deleted after done


def test_url_encoded_key_end_to_end(aws, worker, fake_pipeline):
    job_id, key = make_job(aws, filename="My Demo (final).mp4")
    assert worker.handle(deliver(aws, s3_event(key))) == "done"
    assert job(aws, job_id)["status"] == "done"


def test_duplicate_of_done_job_is_skipped(aws, worker, fake_pipeline, caplog):
    job_id, key = make_job(aws, status="done", worker_id="worker-old")
    with caplog.at_level(logging.INFO):
        assert worker.handle(deliver(aws, s3_event(key))) == "duplicate_done"
    assert "duplicate skipped" in caplog.text
    assert fake_pipeline == []
    assert job(aws, job_id)["status"] == "done"
    assert queue_counts(aws) == (0, 0)


def test_fresh_lease_is_left_alone(aws, worker, fake_pipeline, caplog):
    job_id, key = make_job(aws, status="processing", worker_id="worker-other", claimed_at=NOW - 10)
    with caplog.at_level(logging.INFO):
        assert worker.handle(deliver(aws, s3_event(key))) == "lease_held"
    assert "lease held by worker-other" in caplog.text
    assert fake_pipeline == []
    item = job(aws, job_id)
    assert (item["status"], item["worker_id"], item["claimed_at"]) == ("processing", "worker-other", NOW - 10)
    assert queue_counts(aws) == (0, 0)


def test_stale_lease_is_taken_over(aws, worker, fake_pipeline):
    job_id, key = make_job(aws, status="processing", worker_id="worker-dead", claimed_at=NOW - 241, attempts=1)
    assert worker.handle(deliver(aws, s3_event(key))) == "done"
    item = job(aws, job_id)
    assert (item["status"], item["worker_id"], item["attempts"]) == ("done", "worker-me", 2)


def test_lease_exactly_at_threshold_is_still_fresh(aws, worker, fake_pipeline):
    _, key = make_job(aws, status="processing", worker_id="worker-other", claimed_at=NOW - 240)
    assert worker.handle(deliver(aws, s3_event(key))) == "lease_held"


def test_unknown_job_is_dropped(aws, worker):
    key = f"raw/{uuid.uuid4()}/input.mp4"
    assert worker.handle(deliver(aws, s3_event(key))) == "unknown_job"
    assert queue_counts(aws) == (0, 0)


def test_too_large_upload_marks_failed(aws, worker, fake_pipeline):
    job_id, key = make_job(aws)
    assert worker.handle(deliver(aws, s3_event(key, size=200 * 1024 * 1024 + 1))) == "too_large"
    item = job(aws, job_id)
    assert item["status"] == "failed"
    assert "too large" in item["error"]
    assert fake_pipeline == []
    assert queue_counts(aws) == (0, 0)


def test_pipeline_error_marks_failed_and_deletes(aws, worker, monkeypatch):
    def bad_input(*args, **kwargs):
        raise PipelineError("input.mp4 has no audio stream")

    monkeypatch.setattr(consumer, "run_pipeline", bad_input)
    job_id, key = make_job(aws)
    assert worker.handle(deliver(aws, s3_event(key))) == "failed"
    item = job(aws, job_id)
    assert (item["status"], item["error"]) == ("failed", "input.mp4 has no audio stream")
    assert queue_counts(aws) == (0, 0)


def test_unexpected_error_releases_claim_and_leaves_message(aws, worker, monkeypatch):
    def flaky(*args, **kwargs):
        raise RuntimeError("Polly throttled")

    monkeypatch.setattr(consumer, "run_pipeline", flaky)
    job_id, key = make_job(aws)
    assert worker.handle(deliver(aws, s3_event(key))) == "retry"
    item = job(aws, job_id)
    assert (item["status"], item["error"]) == ("pending", "Polly throttled")
    assert queue_counts(aws) == (0, 1)  # still in flight: SQS will redeliver


def test_final_attempt_marks_failed(aws, worker, monkeypatch):
    monkeypatch.setattr(consumer, "run_pipeline", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
    job_id, key = make_job(aws)
    msg = deliver(aws, s3_event(key))
    msg["Attributes"]["ApproximateReceiveCount"] = "3"
    assert worker.handle(msg) == "retry"
    item = job(aws, job_id)
    assert item["status"] == "failed"
    assert "gave up after 3 attempts: boom" in item["error"]
    assert queue_counts(aws) == (0, 1)  # left for the DLQ


def test_lost_lease_does_not_mark_done_or_delete(aws, worker, monkeypatch):
    _, _, _, table = aws

    def stolen(video, out_mp4, settings, **kwargs):
        # Another worker takes over while this one is still rendering.
        table.update_item(
            Key={"job_id": job_id},
            UpdateExpression="SET worker_id = :other",
            ExpressionAttributeValues={":other": "worker-other"},
        )
        Path(out_mp4).write_bytes(b"late")
        return Path(out_mp4)

    monkeypatch.setattr(consumer, "run_pipeline", stolen)
    job_id, key = make_job(aws)
    assert worker.handle(deliver(aws, s3_event(key))) == "lost_lease"
    item = job(aws, job_id)
    assert (item["status"], item["worker_id"]) == ("processing", "worker-other")
    assert queue_counts(aws) == (0, 1)  # not deleted


def test_shutdown_hands_job_back(aws, worker, monkeypatch):
    def interrupted(*args, **kwargs):
        raise Shutdown()

    monkeypatch.setattr(consumer, "run_pipeline", interrupted)
    job_id, key = make_job(aws)
    assert worker.handle(deliver(aws, s3_event(key))) == "abandoned"
    assert job(aws, job_id)["status"] == "pending"
    assert queue_counts(aws) == (1, 0)  # visible again right away


def test_heartbeat_refreshes_lease_and_detects_loss(aws):
    sqs, queue_url, s3, table = aws
    fast = Settings(jobs_queue_url=queue_url, media_bucket=BUCKET, jobs_table="jobs",
                    heartbeat_seconds=1, lease_seconds=2, visibility_timeout=3)  # fmt: skip
    worker = Consumer(fast, sqs=sqs, s3=s3, table=table, worker_id="worker-me")
    job_id, key = make_job(aws, status="processing", worker_id="worker-me", claimed_at=0)
    msg = deliver(aws, s3_event(key))

    with Heartbeat(worker, job_id, msg["ReceiptHandle"]) as hb:
        time.sleep(1.5)
        assert job(aws, job_id)["claimed_at"] > 0  # refreshed
        table.update_item(Key={"job_id": job_id}, UpdateExpression="SET worker_id = :o",
                          ExpressionAttributeValues={":o": "worker-other"})  # fmt: skip
        time.sleep(1.2)
        assert hb.lost.is_set()


# ---- task scale-in protection ---------------------------------------------------

from fake_ecs_agent import fake_agent  # noqa: E402

from reelops_worker.protection import TaskProtection  # noqa: E402


def protected_worker(aws, settings, clock, agent):
    sqs, _, s3, table = aws
    return Consumer(settings, sqs=sqs, s3=s3, table=table, worker_id="worker-me", clock=clock,
                    protection=TaskProtection(agent.url))  # fmt: skip


def test_task_is_protected_while_processing(aws, settings, clock, monkeypatch):
    seen = []

    def pipeline(video, out_mp4, settings, **kwargs):
        seen.append(agent.protected)  # state of the fake agent mid-job
        Path(out_mp4).write_bytes(b"out")
        return Path(out_mp4)

    monkeypatch.setattr(consumer, "run_pipeline", pipeline)
    with fake_agent() as agent:
        _, key = make_job(aws)
        assert protected_worker(aws, settings, clock, agent).handle(deliver(aws, s3_event(key))) == "done"
        assert seen == [True]
        assert agent.protected is False
        assert [b["ProtectionEnabled"] for *_, b in agent.requests] == [True, False]


@pytest.mark.parametrize(("error", "outcome"), [(PipelineError("no audio"), "failed"), (Shutdown(), "abandoned")])
def test_protection_cleared_on_failure_paths(aws, settings, clock, monkeypatch, error, outcome):
    def boom(*args, **kwargs):
        raise error

    monkeypatch.setattr(consumer, "run_pipeline", boom)
    with fake_agent() as agent:
        _, key = make_job(aws)
        assert protected_worker(aws, settings, clock, agent).handle(deliver(aws, s3_event(key))) == outcome
        assert agent.protected is False
        assert [b["ProtectionEnabled"] for *_, b in agent.requests] == [True, False]


def test_broken_agent_does_not_fail_the_job(aws, settings, clock, fake_pipeline):
    with fake_agent() as agent:
        agent.mode = "http_error"
        job_id, key = make_job(aws)
        assert protected_worker(aws, settings, clock, agent).handle(deliver(aws, s3_event(key))) == "done"
        assert job(aws, job_id)["status"] == "done"


def test_duplicates_do_not_touch_protection(aws, settings, clock, fake_pipeline):
    with fake_agent() as agent:
        _, key = make_job(aws, status="done")
        assert protected_worker(aws, settings, clock, agent).handle(deliver(aws, s3_event(key))) == "duplicate_done"
        assert agent.requests == []
