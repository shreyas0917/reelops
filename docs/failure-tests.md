# Failure tests

Failure drills run against the live stack (ECS Fargate, SQS, DynamoDB, S3,
ap-south-1) on 2026-10-24. Each drill is a script in `scripts/chaos/` that is
safe to re-run and ends with a `PASS`/`FAIL` line. Drills only touch jobs they
create (recorded in `samples/output/chaos/jobs.txt`); `scripts/chaos/cleanup.sh`
deletes exactly those afterwards. Account IDs are shown as `<account-id>`.

## Summary

| Test | Result | Recovery time |
| --- | --- | --- |
| 0. Pre-flight: who consumes the live queue? | Finding: a dev-box worker did | n/a (stopped) |
| 1. Worker stopped mid-job (SIGTERM) | PASS | re-claimed 54 s, done 167 s after the stop |
| 1b. Worker crashes mid-job (SIGKILL) | PASS; finding fixed (give-up now counts attempts, not receives) | re-claimed 300 s after the claim, done 388 s after the kill |
| 2. Duplicate delivery of a finished job's event | PASS | skipped < 1 s after delivery; nothing to recover |
| 3. Poison input (text named .mp4; video without audio) | FAIL -> **PASS after the fix** (clear error for unreadable files) | failed on the 1st attempt, < 1 s; not retried |
| 4. Unprocessable message -> DLQ -> alarm | PASS before and after the fix (both runs' ALARM and OK emails received) | before: DLQ after 3 receives (18.5 min); after: 10 receives (54.6 min); ALARM ~3 min later; OK ~3 min after the purge |
| 5. API task stopped | PASS (single task: 20 s outage); UI finding (transient 503 shown as a failed job) fixed in PR #9 | 503 for 20 s; 200 again 33 s after the stop |
| 6. Scale-in protection (run 1: manual scale-in) | INCONCLUSIVE; finding: step scaling reverts manual desired-count changes | n/a |
| 6. Scale-in protection (run 2: autoscaling scale-in) | PASS (drill script, clean re-run) | idle task stopped 3 s after the scale-in decision; protected 40-min job finished, attempts=1; workers at 0 by autoscaling |
| 7. Give-up alarm (one injected give-up line) | PASS (ALARM and OK notifications sent; email receipt to confirm) | ALARM 46 s after the line was written; OK 6 min after the ALARM |

Relevant settings: SQS visibility timeout 300 s, `maxReceiveCount` 3 before
PR #9 and 10 after (then the DLQ), job lease 240 s, heartbeat every 60 s, worker shutdown grace 20 s,
ECS `stopTimeout` 30 s, worker autoscaling 0-3 on queue backlog.

## 0. Pre-flight finding: a dev-box worker on the live queue

**Goal:** Test 1's first run was meant to stop the ECS worker processing a job.

**What happened:** The job was claimed 6 s after submission while ECS had
**0** worker tasks, and no claim appeared in the ECS worker logs. The job's
`worker_id` (`5eadd1478ae5-7-96cb90`) was the hostname of the local
`docker compose` worker container on the dev box, which had been running for
about an hour against the same live queue. It finished the job
(`status=done attempts=1`) before ECS scaled out.

**Why it matters:** Any worker with the queue URL and credentials is a
consumer. While one runs outside ECS, live jobs can be processed by whatever
code that local image was built from, ECS autoscaling sees less backlog than
there is, and every drill measures the wrong worker.

**Action:** The local stack was stopped (`docker compose down`). The drills
now refuse to run while a local `reelops-worker` container exists
(`require_only_ecs_workers` in `scripts/chaos/lib.sh`). Longer term: local
development should use its own queue, or a dev box role without
`sqs:ReceiveMessage` on the live queue.

## 1. Worker stopped mid-job (SIGTERM)

**Goal:** A worker that is told to stop (deployment, scale-in, `stop-task`)
must not lose or duplicate the job it is processing.

**How it was run:** `scripts/chaos/test1_worker_killed.sh`. It submits an
8.3-minute narrated recording (the screenshot walkthrough looped 16 times; the
worker processes ~7.6x faster than real time, so a 2-minute input finished in
16 s before the stop could land), waits for the claim, finds the owning task
from its log stream, and 5 s later runs `aws ecs stop-task` on it.

**Expected:** `stop-task` sends SIGTERM (SIGKILL after `stopTimeout` = 30 s).
The worker stops polling, gives the job its 20 s grace period, then hands it
back: job `pending`, message visible again immediately (not after the 300 s
visibility timeout). The ECS service replaces the task; the new worker claims
the job (attempts 1 -> 2) and finishes it; exactly one output object.

**Actual:** As expected.

```
12:52:23 submitted job ce02fd0c-6061-4ef5-9489-3914327f5a75
12:52:31 claimed after 6s: status=processing attempts=1
12:52:39 stop-task sent to 48e09a99 (SIGTERM)
12:53:03 handed back after 24s: status=pending attempts=1
12:53:34 re-claimed after 54s from the stop: status=processing attempts=2
12:55:27 done after 167s from the stop: status=done attempts=2
worker log:
12:52:24 48e09a99 job ce02fd0c-...: claimed by ip-10-20-1-19...-7-a7bcfc (receive 1)
12:53:00 48e09a99 job ce02fd0c-...: shutdown grace period over; handing job back
12:53:30 25a45f32 job ce02fd0c-...: claimed by ip-10-20-1-25...-7-fc6ffe (receive 2)
attempts=2 outputs=1 first-owner=48e09a99 final-owner=25a45f32
PASS test1-worker-killed: handed back 24s after SIGTERM, re-claimed by a new
task after 54s, done 167s after the stop; attempts=2, 1 output
```

In an earlier run of the same drill the replacement task was created 5 s
after the stop and started 27 s later (Fargate image pull and boot), which is
most of the stop-to-reclaim time; the job itself was waiting in the queue.

**What it proves:** A stopped worker hands its job back within the grace
period instead of abandoning it, so recovery takes the time a replacement
task needs to start (~30-55 s), not the 300 s visibility timeout. The
conditional claim and the "done" write still give exactly one output.

## 1b. Worker crashes mid-job (SIGKILL)

**Goal:** A worker that dies without warning (OOM kill, host failure) runs no
shutdown code. Recovery must then come from the two timers alone: the lease
(240 s) and the SQS visibility timeout (300 s).

**How it was run:** `scripts/chaos/test1b_worker_crash.sh`. ECS can't SIGKILL a
task, so the drill runs **one** deliberate worker on the dev box from the
deployed ECR image (`reelops-worker:f73d233`), waits for ECS workers to scale
in to zero (so the drill worker gets the job), submits the 8-minute input,
and 20 s after the claim runs `docker kill -s KILL`. The container is removed
on exit whatever happens.

**Expected:** Nothing happens until the lease is stale (claim + 240 s) and the
message reappears (receive + 300 s; no heartbeat had extended it yet). Then
an ECS worker (started by autoscaling on the in-flight backlog) receives it,
takes over the stale lease (attempts 1 -> 2) and finishes; one output.

**Actual:** As expected, ~300 s after the claim.

```
13:08:03 drill worker reelops-drill-worker started (hostname fad0aa570021)
13:08:03 submitted job 7175b3d1-11d8-4138-89ae-9909ac00cfdb
13:08:14 claimed by the drill worker: attempts=1 worker_id=fad0aa570021-7-3e813a
13:08:36 drill worker SIGKILLed 25s after the claim; its last log lines:
    faster_whisper: Processing audio with duration 08:16.939
13:13:13 re-claimed 300s after the first claim: attempts=2 worker_id=ip-10-20-1-178...-7-4a22e6
13:15:06 done 389s after the kill: status=done attempts=2
ECS worker log:
13:13:05 2d252812 job 7175b3d1-...: claimed by ip-10-20-1-178...-7-4a22e6 (receive 3)
13:15:00 2d252812 job 7175b3d1-...: done -> s3://reelops-media-<account-id>/output/7175b3d1-....mp4
attempts=2 outputs=1
PASS test1b-worker-crash: SIGKILLed worker's job taken over by ECS 300s after
the claim (lease 240 s, visibility 300 s), done 389s after the kill;
attempts=2, 1 output, no local worker left
```

`docker ps -a` afterwards: no containers.

**Finding: harmless events use up SQS receives.** The take-over was
"receive **3**" although the job had one real attempt. SQS metrics showed one
message sent and **two receives in the 13:08 minute**. The worker log explains
it: autoscaling was scaling in drill 1's idle worker at that moment.

```
13:08:02 25a45f32 stop requested: exiting after the current poll
13:08:04 25a45f32 worker ...-7-fc6ffe stopped
```

Its in-flight long poll returned the new message during shutdown, and it
released it (visibility 0) as designed: receive 1. The drill worker's claim
was receive 2, the ECS take-over receive 3. (The drill's "0 ECS workers" check
used `list-tasks --desired-status RUNNING`, which drops a task as soon as it is
told to stop; it now waits for the service's `runningCount` to reach 0.)

Why it matters: the queue's `maxReceiveCount` is 3, and the worker decides to
give up from the same SQS count (`receives >= max_receives` marks the job
`failed`, "gave up after 3 attempts"). Releases during scale-in and hand-backs
on SIGTERM are not failures, but they count. This job reached its last
receive after **one** real attempt: a single transient error on that attempt
(e.g. Polly throttling) would have failed it as "gave up after 3 attempts" and
moved the message to the DLQ. Not fixed here (no code changes during the
drills); see the options in the PR discussion.

**What it proves:** The crash path works: with no shutdown code at all, the
job is recovered by the lease and the visibility timeout, after ~300 s, with
no duplicate output. It also shows the retry budget is spent by non-failures.

## 2. Duplicate delivery

**Goal:** S3 event notifications and SQS are both at-least-once, so the same
upload event can arrive twice. A duplicate of a finished job must not
reprocess it, change its record or rewrite its output.

**How it was run:** `scripts/chaos/test2_duplicate_delivery.sh`. It runs a
short job to `done`, snapshots the whole job item and the output object's
`LastModified`, rebuilds the S3 event body for that upload (bucket,
URL-encoded key, size and ETag from `head-object`), sends it to the queue, and
compares afterwards.

**Expected:** The worker's conditional claim fails on `status = done`; it
logs `duplicate skipped (already done)` and deletes the message. Job item
identical, output untouched, queue empty.

**Actual:** As expected.

```
13:20:37 submitted job 97850140-7a14-4320-984d-35a515444a1b (31 s recording)
13:20:50 done: status=done attempts=1
13:20:53 re-sent the S3 event for raw/97850140-.../input.mp4
worker log:
13:20:53 2d252812 job 97850140-...: duplicate skipped (already done)
13:21:05 item unchanged: True (status=done attempts=1 updated_at=1792848047)
13:21:05 output LastModified before=2026-10-24T13:20:47 after=2026-10-24T13:20:47; outputs=1
PASS test2-duplicate-delivery: duplicate event skipped 6s after the re-send;
message deleted; job item and output unchanged
```

The worker skipped it in the same second it was sent; the 6 s in the PASS
line is the drill's 5 s polling interval.

**What it proves:** Processing is idempotent per upload: the claim is a
conditional write on the job's status, so a duplicate event costs one
DynamoDB read and one SQS delete, and the user's job and video are never
touched.

## 3. Poison input

**Goal:** Input that can never succeed must fail once, with an error the user
can act on, and must not be retried (three wasted attempts, then the DLQ).

**How it was run:** `scripts/chaos/test3_poison_input.sh` submits, through the
normal API, `not-a-video.mp4` (9 KB of text with an .mp4 name) and
`silent-video.mp4` (a real 10 s H.264 video with no audio track). Both pass
the API's checks (extension, size) and reach the worker.

**Expected:** Both jobs `failed` with `attempts=1`, one claim each, messages
deleted, DLQ unchanged, no output. Errors: "...isn't an MP4, MOV or WebM
video..." for the text file and "...has no audio stream..." for the silent
video.

**Actual:** Retry handling as expected; the text file's error is not.

```
13:24:32 submitted 8da1e15e-... (text) and 83bbd74e-... (no audio)
worker log:
13:24:32 2d252812 job 8da1e15e-...: claimed by ...-7-4a22e6 (receive 1)
13:24:33 2d252812 job 8da1e15e-...: failed: ffprobe (input.mp4) failed (exit 1):
         [mov,mp4,m4a,3gp,3g2,mj2 @ 0x563ed0112fc0] moov atom not found
13:24:33 2d252812 job 83bbd74e-...: claimed by ...-7-4a22e6 (receive 1)
13:24:33 2d252812 job 83bbd74e-...: failed: input.mp4 has no audio stream. ReelOps
         needs a narrated recording to transcribe; record with your microphone on.
job items: both status=failed attempts=1; queue empty; DLQ 0 -> 0; no outputs
FAIL test3-poison-input: 8da1e15e-...: error doesn't mention "isn't an MP4, MOV or WebM video"
```

**Bug:** `ffmpeg.probe()` turns a probe failure into the friendly "isn't an
MP4, MOV or WebM video" message only when ffprobe reports the detected format
as "not on whitelist" (the crafted-DASH case it was written for). A file no
demuxer recognises makes ffprobe fall back to the extension's demuxer
(`mov,mp4`), which fails with "moov atom not found", and the generic error
path stores the last lines of ffprobe's stderr as the job's error. The web UI
has no mapping for it, so the user sees `Processing failed: ffprobe (input.mp4)
failed (exit 1): [mov,... @ 0x563ed0112fc0] moov atom not found
/tmp/job-u4m74srg/input.mp4: Invalid data...`: unclear, and it exposes a
worker temp path and a memory address through the job API. Truncated or
corrupt real MP4s would take the same path. Fix pending approval.

**What it proves:** Permanent input errors are classified correctly (one
attempt, message deleted, no DLQ, no output, failed within a second). The
error text for unreadable files is not yet user-facing.

## 4. DLQ and alerting

**Goal:** A message the worker can't handle must not loop forever or vanish:
it should be retried a bounded number of times, land in the dead-letter
queue, and page a human.

**How it was run:** `scripts/chaos/test4_dlq_alarm.sh` sends a JSON message
that isn't an S3 event (with a unique marker) to the jobs queue and waits.
Safety: it refuses to run unless the DLQ is empty, and purges the DLQ only
after reading back its single message and matching the marker.

**Expected:** `parse_event()` raises, the worker logs "unhandled error; message
left for retry" and doesn't delete it. SQS redelivers after each 300 s
visibility timeout; after 3 receives (`maxReceiveCount`) the next receive
attempt moves it to the DLQ. `reelops-dev-jobs-dlq-not-empty`
(ApproximateNumberOfMessagesVisible > 0, 60 s, 1 period) goes to ALARM and
emails via SNS; after the purge it returns to OK.

**Actual:** As expected.

```
13:28:03 DLQ empty; alarm reelops-dev-jobs-dlq-not-empty is OK
13:28:03 sent malformed message (marker chaos-drill-55b0d9ac-...)
worker log (one line per receive):
13:31:19 d1513db3 ValueError: not an S3 event message: KeyError('Records')
13:36:19 d1513db3 ValueError: not an S3 event message: KeyError('Records')
13:41:19 d1513db3 ValueError: not an S3 event message: KeyError('Records')
13:46:30 message in the DLQ 1107s after sending
13:49:40 alarm ALARM 190s after the move (email sent via SNS)
13:49:42 DLQ message is the drill's (receive count 4, incl. this check)
13:49:49 DLQ purged
13:52:42 alarm OK 173s after the purge
alarm history:
2026-10-24T13:49:38 Alarm updated from OK to ALARM
2026-10-24T13:52:38 Alarm updated from ALARM to OK
PASS test4-dlq-alarm: 3 receives, in the DLQ 1107s after sending, alarm ALARM
190s later; purged, alarm OK 173s after the purge
```

Both SNS emails arrived (confirmed by the recipient): ALARM at ~19:19 IST
(13:49 UTC) and OK at ~19:22 IST (13:52 UTC), matching the alarm history.

Timeline: the first receive came 196 s after sending (no worker was running:
autoscaling started one on the backlog), then exactly every 300 s; the move
to the DLQ happened on the receive attempt after the third timeout. The alarm
lagged the move by ~3 minutes: SQS publishes queue metrics to CloudWatch with
a delay, so 1 x 60 s periods don't mean a 60 s reaction.

Observations:
- The traceback reaches CloudWatch as one log event per line, so a Logs
  Insights query sees fragments. A multiline pattern on the awslogs driver
  (or JSON logs) would keep each error in one event.
- The "unhandled error" log line doesn't include the SQS message id, so a DLQ
  message can't be matched to its worker logs except by time.
- Today's retry budget (3 receives) is shared with harmless releases (drill
  1b's finding); see the before/after below once the fix is deployed.

**What it proves:** An unprocessable message is retried exactly 3 times at the
visibility interval, parked in the DLQ instead of blocking the queue, and
alerts within ~3 minutes of reaching it (~22 minutes after it was first sent).

## 5. API task stopped

**Goal:** Measure what a user sees when the API task dies, and confirm ECS
replaces it without help.

**How it was run:** `scripts/chaos/test5_api_killed.sh` probes `/healthz`
through the ALB every 2 s in the background (time, status, latency), stops
the only API task with `aws ecs stop-task`, and records target states and
ECS service events until the client has seen 30 s of 200s again.

**Expected:** ECS deregisters the task's target first (state `draining`,
deregistration delay 30 s), so the ALB has no target and answers 503; the
service starts a replacement at once; 200s return once it is registered and
healthy (health check every 15 s, 2 successes). With one task there is
downtime; estimate 1-2 minutes.

**Actual:** 20 s of 503s, shorter than estimated.

```
14:00:27 baseline: 5 probes, all 200; targets: <old-task-ip>:healthy
14:00:28 stop-task sent to API task 0adcbdee...
14:00:40 targets: <old-task-ip>:draining
14:01:02 targets: <new-task-ip>:healthy <old-task-ip>:draining
14:01:13 targets: <new-task-ip>:healthy
probes:
14:00:38 200   14:00:40 503 ... 14:00:59 503 (10 x 503, ~2 ms each)   14:01:01 200
ECS service events:
14:00:38 deregistered 1 targets in (target-group .../reelops-dev-api/...)
14:00:38 has begun draining connections on 1 tasks.
14:00:39 has started 1 tasks: (task 5503a15d...)
14:00:58 registered 1 targets in (target-group .../reelops-dev-api/...)
14:01:27 has reached a steady state.
failures from 13s to 31s after the stop (503x10); back to 200 33s after the stop
PASS test5-api-killed: API stopped and replaced; downtime 20s (503x10), back to
200 33s after the stop, stable 30 s
```

Timeline: the old task kept answering for ~10 s after `stop-task` while ECS
processed the stop; the outage started when its target was deregistered.
The replacement was started 1 s later, registered 19 s after that (Fargate
start + app boot), and served 3 s after registration. The 503s came from the
ALB itself (~2 ms), so clients failed fast rather than hanging.

**Finding:** With `desired_count = 1`, any API task replacement (a crash, a
host retirement, and also every deployment's final switch) is a short
outage. Two tasks in two AZs would make this drill a zero-downtime event for
~2x the API's Fargate cost; for a dev stack a ~20 s gap is an accepted
trade-off, now measured rather than assumed. Background jobs are unaffected:
uploads go straight to S3, and workers don't use the API.

**Finding (web UI, from this drill's outage window):** reviewing how the
frontend would have behaved during those 20 s of 503s:
- While a job runs, the UI polls `GET /jobs/{id}` every 2 s and swallows every
  error (`App.tsx`, poll effect), so a short outage is invisible (good), but
  so is a long one: nothing ever tells the user the service is unreachable.
- Opening a job (page reload, a shared `?job=` link, clicking a video) calls
  `open()`, which turns a **single** 503 or network error into the failed
  state: the red "This video didn't finish" panel for a job that is fine, and
  polling stops, so it never recovers. Anyone reloading during this drill's
  outage would have seen their running job reported as failed.

Fix (in the `fix/attempts-not-receives` PR): one retry policy for both paths:
keep polling through transient errors, show a non-fatal "still trying" notice
only after ~30 s of consecutive failures, and reserve the failed state for the
job's own `failed` status or a 404.

**What it proves:** ECS self-heals the API without intervention and the
client-visible outage for a single task is ~20 s, dominated by Fargate start
time. The web UI did not handle that outage gracefully when opening a job.

## 6. Scale-in protection, run 1 (manual scale-in)

**Goal:** When the worker service scales in, ECS must stop an idle worker and
never one that is processing a job (the worker sets ECS task scale-in
protection while it holds a job).

**How it was run:** `scripts/chaos/test6_scale_in_protection.sh` (first
version): one 8-minute and two 31 s jobs give a backlog of 3, so autoscaling
runs 2 workers; when the short jobs are done and the long one is processing,
the drill reads both tasks' protection and forces the desired count from 2 to
1 with `update-service` (autoscaling not suspended).

**Expected:** ECS stops the idle (unprotected) task; the busy one finishes.

**Actual:** Inconclusive: autoscaling reverted the manual change before ECS
acted on it, and the long job finished before any scale-in happened.

```
14:13:33 worker service desired/running: 0/0; submitted 1 long + 2 short jobs
14:17:14 2 workers running 221s after submitting
14:17:30 busy task c70787ef protection=true; idle task b4f4ac27 protection=false
14:17:31 forced desired count 2 -> 1
scaling activities:
14:16:43 Setting desired count to 2. (alarm reelops-dev-worker-scale-out in ALARM)
14:17:43 Setting desired count to 2. (alarm reelops-dev-worker-scale-out in ALARM)
14:20:43 Setting desired count to 1. (alarm reelops-dev-worker-scale-out in ALARM)
long job 2953fc16-...: done at 14:18:17, attempts=1, 1 output
service events:
14:20:46 has stopped 1 running tasks: (task c70787ef...)
FAIL test6-scale-in-protection: timed out after 300s waiting for: ECS stops a task
```

The protection readings were right (busy `true`, idle `false`). The task ECS
stopped at 14:20:46 was the one that had been busy, but its job had finished
at 14:18:17, so both tasks were idle by then: correct behaviour, no
protection was violated.

**Finding: step scaling overrides manual desired-count changes.** Twelve
seconds after the drill set the desired count to 1, autoscaling set it back to
2: a step-scaling policy re-applies its adjustment on every evaluation (each
minute) while its alarm stays in ALARM, and the alarm still saw the 3-job
backlog. A manual scale-in during a backlog does not stick; an operator who
needs to override it must suspend dynamic scaling
(`register-scalable-target --suspended-state`) first.

Also fixed in the drill: its lookup of the busy task's log stream (for the
protection on/off lines) used `describe-log-streams` with a name filter, which
only searches the first page of streams and returned nothing; the stream name
now comes from the job's own "claimed" log event.

**Next:** rerun with autoscaling performing the scale-in (backlog drops from
3 to 1 while a ~40-minute job is mid-processing), after the fix deploy.

## After the fixes (PR #9, deployed 2026-10-24 15:04 UTC)

PR #9 (`fix/attempts-not-receives`) changed: the worker gives a job up after
3 real attempts (claims counted on the job item) and fails a job whose
attempts all died mid-job before claiming it again; SQS `maxReceiveCount`
3 -> 10 as a backstop; any ffprobe failure on an upload gives a clear message
(raw stderr only in a WARNING log); the web UI keeps polling through API
outages. Verified live: `api=18c6c5e`, `worker=0ec6fb3`, `maxReceiveCount=10`,
and `terraform plan` on main: "No changes".

### 1b after: worker crash (SIGKILL)

Drill worker on the deployed image `0ec6fb3`; same 8-minute input.

```
15:25:04 drill worker reelops-drill-worker started (hostname d2e153824208)
15:25:14 claimed by the drill worker after 7s: attempts=1
15:25:36 drill worker SIGKILLed 25s after the claim
15:30:13 re-claimed 300s after the first claim: attempts=2
15:32:06 done 388s after the kill: status=done attempts=2
ECS worker log:
15:30:05 01e9b2b3 job 5b35daa4-...: claimed by ip-10-20-1-224...-7-e26939 (attempt 2, receive 3)
15:32:02 01e9b2b3 job 5b35daa4-...: done -> s3://reelops-media-<account-id>/output/5b35daa4-....mp4
PASS test1b-worker-crash: ... taken over by ECS 300s after the claim ...,
done 388s after the kill; attempts=2, 1 output, no local worker left
```

| | Before | After |
| --- | --- | --- |
| Recovery (claim -> take-over -> done) | 300 s / 389 s after the kill | 300 s / 388 s after the kill |
| Take-over log | `(receive 3)` | `(attempt 2, receive 3)` |
| A transient error on this attempt would... | fail the job: receive 3 >= 3, "gave up after 3 attempts", message to the DLQ | retry it: attempt 2 < 3 |

The same situation occurred again (receive 3 on attempt 2), and the worker
now decides by the job's attempts.

**Open question:** SQS again counted two receives in the minute of the
first delivery (1 message sent), this time while ECS ran **no** workers, so
only the drill worker was consuming. The explanation given for the first run
(a scaling-in ECS worker released the message) is therefore unproven: the
release isn't logged, and this run had no such worker. The drill now keeps the
drill worker's full log, whose claim line ("attempt 1, receive N") will show
whether the extra receive happens before its claim. With the fix the extra
receive is harmless.

### 3 after: poison input

```
15:33:05 submitted eb15f517-... (text) and dbffecff-... (no audio)
15:33:05 01e9b2b3 job eb15f517-...: claimed by ...-7-e26939 (attempt 1, receive 1)
15:33:05 01e9b2b3 job eb15f517-...: failed: input.mp4 isn't an MP4, MOV or WebM video
         we can read. Export it as MP4 and upload it again.
15:33:06 01e9b2b3 job dbffecff-...: claimed by ...-7-e26939 (attempt 1, receive 1)
15:33:06 01e9b2b3 job dbffecff-...: failed: input.mp4 has no audio stream. ReelOps
         needs a narrated recording to transcribe; record with your microphone on.
operators' WARNING log:
15:33:05 reelops_worker.ffmpeg: ffprobe rejected upload input.mp4 (exit 1):
         [mov,mp4,m4a,3gp,3g2,mj2 @ 0x55ad8ef95fc0] moov atom not found
DLQ before=0 after=0; queue empty
PASS test3-poison-input: both poison inputs failed once with a clear error
within 7s; attempts=1, messages deleted, nothing in the DLQ, no output
```

| | Before | After |
| --- | --- | --- |
| Text file's job error | `ffprobe (input.mp4) failed (exit 1): [mov,mp4,... @ 0x563ed0112fc0] moov atom not found /tmp/job-u4m74srg/input.mp4: Invalid data...` | `input.mp4 isn't an MP4, MOV or WebM video we can read. Export it as MP4 and upload it again.` |
| Where ffprobe's details go | the job record (public API, web UI) | the worker's WARNING log only |
| Attempts / DLQ | 1 / none | 1 / none |

### 4 after: DLQ and alerting (maxReceiveCount 10)

```
15:57:04 queue: maxReceiveCount=10, visibility timeout 300s
15:57:05 sent malformed message (marker chaos-drill-bd7fc6db-...)
worker log (one line per receive):
16:01:23 ... 16:46:23  10 x "ValueError: not an S3 event message: KeyError('Records')", 300 s apart
16:51:40 message in the DLQ 3276s after sending
16:54:40 alarm ALARM 180s after the move (email sent via SNS)
16:54:43 DLQ message is the drill's (receive count 11, incl. this check)
16:54:49 DLQ purged
16:57:44 alarm OK 175s after the purge
alarm history:
2026-10-24T16:54:38 Alarm updated from OK to ALARM   (22:24:38 IST)
2026-10-24T16:57:38 Alarm updated from ALARM to OK   (22:27:38 IST)
PASS test4-dlq-alarm: 10 receives, in the DLQ 3276s after sending, alarm ALARM
180s later; purged, alarm OK 175s after the purge
```

Both SNS emails arrived (confirmed by the recipient): ALARM at 22:24 IST and
OK at 22:27 IST, matching the alarm history.

| | Before (maxReceiveCount 3) | After (maxReceiveCount 10) |
| --- | --- | --- |
| Receives before the DLQ | 3, 300 s apart | 10, 300 s apart |
| Sent -> DLQ | 1107 s (18.5 min) | 3276 s (54.6 min) |
| DLQ -> ALARM | 190 s | 180 s |
| Purge -> OK | 173 s | 175 s |

The trade-off of the fix: a message no worker can handle now reaches a human
~36 minutes later. In exchange, a real job is no longer pushed towards the
DLQ by harmless receives (1b), and jobs that exhaust their 3 real attempts
fail at once (the user sees "failed") instead of waiting for redrive. Jobs
that give up no longer reach the DLQ at all; an alarm on the worker's
"giving up" log lines is planned (Phase 9).

## 6. Scale-in protection, run 2 (autoscaling scale-in)

**How it was run:** The redesigned `scripts/chaos/test6_scale_in_protection.sh`
submits a 40-minute job (45 MB) and two 31 s jobs; autoscaling runs two
workers; when the short jobs finish, the backlog drops to 1 and autoscaling
itself scales in to one task while the long job is processing. The first
attempt hit a harness bug while identifying the busy task (its log-stream
lookup printed an extra `None` page under CLI pagination; fixed), so that run
was recorded by observing the service directly; a clean re-run of the fixed
script followed (below).

**Expected:** ECS stops the idle task (protection off) and keeps the busy one
(protection on), which finishes its job (attempts=1, one output) and turns
protection off; autoscaling then scales in to 0 by itself.

**Actual (clean re-run, 2026-10-24 17:23-18:00 UTC):** As expected; the
script printed PASS. Pre-checks: queue and DLQ empty, worker service at 0/0,
no local containers; live images `api=18c6c5e`, `worker=0ec6fb3`.

```
17:23:45 inputs: walkthrough-40min.mp4 (45 MB, 2483s) + 2 x 31 s
17:23:46 worker service desired/running: 0/0
17:23:47 submitted long eb86b545-... and short 5a00cd02-..., d8d6a2b2-...
17:27:23 2 workers running 217s after submitting
17:27:33 busy 82481463 protection=true; idle 29f8b4a6b8d5466e99a9f6f9b48fc9e8 protection=false
17:31:51 scale-in: ECS stopped the idle task 254s after the short jobs finished;
         busy task kept; long job: status=processing attempts=1
17:47:26 long job done 936s after the scale-in: status=done attempts=1, outputs=1
scaling activities:
17:26:43 Setting desired count to 2.
17:31:43 Setting desired count to 1.
17:59:51 Setting desired count to 0.
service events:
17:26:53 has started 2 tasks: (task 29f8b4a6...) (task 82481463...)
17:31:46 has stopped 1 running tasks: (task 29f8b4a6...)
busy task 82481463 log:
17:27:23 consumer: job eb86b545-...: claimed by ip-10-20-1-47...-7-258adb (attempt 1, receive 1)
17:27:23 protection: task protection on
17:47:23 consumer: job eb86b545-...: done -> s3://reelops-media-<account-id>/output/eb86b545-....mp4
17:47:23 protection: task protection off
18:00:05 workers at 0, 761s after the last job
PASS test6-scale-in-protection: autoscaling scale-in stopped the idle task and
kept the protected one, which finished its job (attempts=1, 1 output);
workers at 0 761s after the last job
```

The first, observed attempt (15:34-15:57 UTC) showed the same sequence:

```
15:34:09 submitted long 9c25d3a8-... (2483 s) and short e1b0f587-..., 251db9d6-...
15:37:21 2 workers running 193s after submitting
15:37:54 task 01e9b2b3: protection=True   (holds the long job)
         task 36a8231b: protection=False  (idle; short jobs done)
scaling activities:
15:36:43 Setting desired count to 2.
15:40:43 Setting desired count to 1.
15:56:51 Setting desired count to 0.
service events:
15:40:49 has stopped 1 running tasks: (task 36a8231b...)
watch: 15:40:50 desired=1 running=[01e9b2b3] long=processing
busy task 01e9b2b3 log:
15:34:09 consumer: job 9c25d3a8-...: claimed by ...-7-e26939 (attempt 1, receive 1)
15:34:09 protection: task protection on
15:44:36 consumer: job 9c25d3a8-...: done -> s3://reelops-media-<account-id>/output/9c25d3a8-....mp4
15:44:36 protection: task protection off
15:44:42 long job done: status=done attempts=1 outputs=1
15:44:58 busy task 01e9b2b3 protection after the job: False
15:56:55 workers at 0 (autoscaling, never suspended)
```

**What it proves:** When autoscaling scales in, ECS chooses the idle worker
and never the one holding a job (3 s from the scale-in decision to the idle
task stopping in the clean run, 6 s in the observed one); the protected job
finished on its first attempt, and its worker turned protection on at the
claim and off the moment the job was done. Autoscaling kept control
throughout (never suspended) and scaled to zero ~12 minutes after the last
job. The drill script now proves this end to end on its own.

## 7. Give-up alarm (end to end)

**Goal:** Since PR #9 a job that uses up its 3 real attempts is failed and its
message deleted, so it never reaches the DLQ alarm. The give-up alarm (PR #13)
must email when a worker gives up, and email again when it clears.

**How it was run:** After PR #13 was deployed, the drill confirmed the metric
filter (`reelops-dev-worker-gave-up`, pattern `?"; giving up" ?"attempts that
never finished"`, metric `ReelOps/WorkerGaveUp`, value 1, default 0) and the
alarm (Sum >= 1 over 60 s, 1 period, missing data = not breaching, email on
ALARM and OK) existed, waited for the new alarm to settle to OK, then wrote
**one** give-up line in the worker's exact format into a separate log stream
(`chaos-giveup-test`) in `/reelops/dev/worker` with `aws logs put-log-events`,
and deleted the stream afterwards. Before deploying, the pattern was checked
with `aws logs test-metric-filter`: it matched 3 of 3 real give-up lines (both
give-up paths) and 0 of 14 other real worker lines.

**Expected:** The metric records 1 for that minute; the alarm goes to ALARM
within about a minute and back to OK once no more matches arrive; one email
for each transition.

**Actual:** As expected.

```
18:16:38 UTC alarm settled: INSUFFICIENT_DATA -> OK (new alarm's first evaluation)
18:16:54 UTC wrote 1 line to /reelops/dev/worker/chaos-giveup-test:
  ... ERROR   reelops_worker.consumer: job chaos-giveup-test-8f30b6b6-...: failed on final attempt 3; giving up
metric ReelOps/WorkerGaveUp: 2026-10-24T18:16:00Z Sum 1.0
alarm history:
2026-10-24T18:17:37 Alarm updated from OK to ALARM   (23:47:37 IST)
2026-10-24T18:23:37 Alarm updated from ALARM to OK   (23:53:37 IST)
test stream deleted; alarm OK
```

The alarm published to the SNS alerts topic on both transitions (its email
subscription is confirmed); receipt of these two emails is still to be
confirmed by the recipient.

**What it proves:** A give-up anywhere in the worker reaches a human by email
within about a minute, without waiting for the DLQ. Recovery to OK took 6
minutes, not 1: for a sparse metric CloudWatch waits several periods for late
data before it treats the window as clear.
