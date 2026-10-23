# ReelOps learning notes

One entry per step: what we built, why this way (and the alternatives), problems
hit, and two likely interview questions.

---

## Phase 0 — Project setup

### Step 1 — Dev box tools

**Built:** Installed AWS CLI v2, Terraform, Docker Engine, gh, ffmpeg, unzip and
python3-venv on the Ubuntu dev box, each from its official source, and added the
`ubuntu` user to the `docker` group.

**Why / alternatives:** Vendor apt repos (HashiCorp, Docker, GitHub) give current
versions and security updates through normal `apt upgrade`; Ubuntu's own
`docker.io`/`terraform` packages lag behind or don't exist. Each repo's key is
stored in `/etc/apt/keyrings` and bound with `signed-by=`, so a key can only sign
its own repo (the old `apt-key` trusted every key for every repo). AWS CLI v2
isn't in apt at all; the official zip was GPG-verified before installing.
Alternatives: snap packages, `pip install awscli` (that's v1), or tfenv.

**Problems:**
- The box turned out to be Ubuntu 26.04, not 24.04. Checked that each vendor
  repo publishes a `resolute` suite before adding it; all did.
- The AWS installer suggested `aws configure ...`; skipped, because credentials
  come from the instance role.
- The `docker` group only applies to new logins, so a reconnect was needed.

**Interview questions:**
1. *Why is membership of the `docker` group a security concern?* Anyone who can
   talk to the Docker socket can start a privileged container that mounts the
   host's filesystem, which is effectively root. Fine on a single-user dev box;
   on shared hosts use rootless Docker or sudo.
2. *Why `signed-by` instead of `apt-key add`?* `apt-key` put keys in a global
   keyring trusted for every repo, so one compromised vendor key could sign
   packages for any repo. `signed-by` scopes each key to one repo.

### Step 2 — AWS access via the instance role

**Built:** Confirmed `aws sts get-caller-identity` returns
`assumed-role/reelops-devbox-role`, and set `AWS_REGION`/`AWS_DEFAULT_REGION` to
`ap-south-1` in `~/.bashrc`.

**Why / alternatives:** An EC2 instance role gives short-lived credentials that
rotate automatically through IMDSv2. Nothing is stored on disk, so nothing can
leak. The alternative, access keys in `~/.aws/credentials`, is long-lived and the
most common cause of AWS credential leaks. Both region variables are set because
different tools read different ones.

**Problems:** None.

**Interview questions:**
1. *How does the AWS CLI find credentials?* It checks in order: environment
   variables, `~/.aws` config/credentials files, container credentials (ECS),
   then instance metadata (IMDS). With none of the earlier ones set, it uses the
   instance role.
2. *What is IMDSv2 and why require it?* It makes you get a session token with a
   PUT before reading metadata. That blocks SSRF attacks that trick a server into
   making a simple GET to the metadata IP to steal role credentials.

### Step 3 — Repo skeleton

**Built:** Folders for app, worker, frontend, Terraform (bootstrap and main),
workflows, docs and samples; a `.gitignore`; a README stub.

**Why / alternatives:** A monorepo keeps app code, infrastructure and CI together
so one pull request can change all three. Alternative: separate repos per
component, which suits larger teams but adds overhead. `.gitignore` blocks state,
`.tfvars`, `.env` and media from day one, because removing a secret from Git
history later is painful. `.terraform.lock.hcl` is deliberately *not* ignored.

**Problems:** `git check-ignore` needs a repository, so testing the ignore rules
waited until `git init` in Step 7.

**Interview questions:**
1. *Should `.terraform.lock.hcl` be committed?* Yes. It pins exact provider
   versions and checksums so everyone and CI get identical providers. The
   `.terraform/` folder, which holds the downloaded plugins, is ignored.
2. *Why ignore `*.tfvars` but allow `*.tfvars.example`?* Real tfvars may hold
   secrets or environment-specific values; the example documents which variables
   exist without any real values.

### Step 4 — CLAUDE.md working rules

**Built:** A `CLAUDE.md` with the project's rules: no AI-run apply or destroy,
no secrets or account IDs in files, tagging, least-privilege IAM, cost limits,
and the dev box being out of Terraform's scope.

**Why / alternatives:** Rules in a checked-in file apply in every session and are
visible to anyone reading the repo, rather than living in someone's head or chat
history. It works like a CONTRIBUTING guide for both AI and humans.

**Problems:** None.

**Interview questions:**
1. *Why keep a human in the loop for `terraform apply`?* Apply changes real
   infrastructure and can destroy data. Reviewing the plan first is the control
   point, the same reason CI pipelines usually gate apply behind approval.
2. *Why tag every resource?* For cost allocation by project and environment, for
   ownership, for finding resources that weren't created by Terraform, and for
   tag-based IAM conditions.

### Step 5 — Terraform state bucket (bootstrap)

**Built:** `terraform/bootstrap/` creates `reelops-tfstate-<account-id>` with
versioning, SSE-S3 encryption, all public access blocked, an HTTPS-only bucket
policy and `prevent_destroy`. This folder uses local state.

**Why / alternatives:** Remote state needs a bucket, but that bucket can't store
its own state before it exists. That's the bootstrap problem, so this one small
folder keeps local state. The account ID comes from `aws_caller_identity` rather
than being hardcoded. Alternatives: create the bucket by hand (not reproducible),
HCP Terraform (hosted state), or a CloudFormation bootstrap.

**Problems:** The bucket name contains the account ID, but backend blocks can't
use variables, so hardcoding it in `backend.tf` would break the "no account IDs
in files" rule. Solved in Step 6 with a partial backend configuration.

**Interview questions:**
1. *Why does a policy with `Principal: "*"` and `Action: s3:*` not violate least
   privilege here?* It's a Deny with an `aws:SecureTransport = false` condition.
   It only takes access away (from non-HTTPS requests) and never grants anything.
2. *What protects the state bucket from deletion?* `prevent_destroy` makes
   Terraform refuse any plan that deletes it, and `force_destroy = false` means
   S3 won't delete it while it contains objects. Versioning also lets you recover
   overwritten state.

### Step 6 — S3 remote backend for `terraform/main`

**Built:** `backend.tf` (S3, key `reelops/main.tfstate`, `encrypt`,
`use_lockfile`) and `providers.tf` (AWS provider pinned `~> 6.0` with
`default_tags`). `terraform init` succeeded against the bucket.

**Why / alternatives:** Remote state is shared, durable and versioned.
`use_lockfile` (Terraform 1.10+) locks with a `.tflock` object in the same
bucket. Previously a DynamoDB table was needed for locking. The bucket name is
passed with `-backend-config` at init, so the account ID stays out of Git.

**Problems:** None. Terraform caches backend settings in
`.terraform/terraform.tfstate`, which is git-ignored.

**Interview questions:**
1. *What does state locking prevent?* Two applies running at once against the
   same state. That can corrupt it or produce conflicting changes. With
   `use_lockfile`, the second run fails to acquire the lock.
2. *What is a partial backend configuration?* Leaving some backend settings out
   of the code and supplying them at `terraform init` with `-backend-config`.
   It's used for values that differ per environment or shouldn't be committed.

### Step 7 — Git and GitHub

**Built:** Set the Git identity using the GitHub noreply email, logged in with
`gh auth login` (device code over HTTPS with gh as the credential helper), made
the first commit, and created a private GitHub repo.

**Why / alternatives:** The noreply email keeps a personal address out of public
commit history. gh as the credential helper avoids managing SSH keys or personal
access tokens on the box. Alternatives: SSH deploy keys, or fine-grained PATs.

**Problems:** The email was pasted as a placeholder; the exact noreply address
was derived from `gh api user` (`<id>+<login>@users.noreply.github.com`).
Before the first commit, `git grep` confirmed no account ID was in any file.

**Interview questions:**
1. *How did you make sure no secrets were committed?* `.gitignore` from the
   start, a dry-run `git add` to review the file list, and a `git grep` for the
   account ID before committing. In CI you'd add a scanner such as gitleaks.
2. *Why does the noreply address still credit your GitHub account?* GitHub maps
   the numeric user ID in the noreply address to the account.

---

## Phase 1 — Video pipeline worker

### Step 1 — Credentials inside containers

**Built:** Checked the instance's metadata options: `HttpTokens=required` and
`HttpPutResponseHopLimit=2` were already set. Proved a `python:3.12-slim`
container can get an IMDSv2 token and see the role.

**Why / alternatives:** The IMDSv2 token reply has an IP TTL equal to the hop
limit. On Docker's bridge network the container is one hop further away, so with
a limit of 1 the reply never arrives and the SDK finds no credentials. 2 allows
exactly one extra hop. Alternatives: `--network host` (weaker isolation) or
passing credentials into the container (they'd expire, and it's leak-prone).

**Problems:** Claude's shell got "permission denied" on the Docker socket. The VS
Code server process started before `ubuntu` joined the `docker` group, and Linux
fixes a process's groups at start-up. Worked around with `sg docker -c ...`, then
fixed properly with *Remote-SSH: Kill VS Code Server on Host* and a reconnect.

**Interview questions:**
1. *Why would the AWS SDK work on an EC2 host but fail in a container on it?*
   The IMDSv2 hop limit is 1, so the token reply expires crossing the Docker
   bridge. Set it to 2 with `modify-instance-metadata-options`.
2. *How do containers on ECS Fargate get AWS credentials?* From the task role,
   through the ECS credentials endpoint (`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`),
   which comes before IMDS in the SDK's credential chain. Fargate has no IMDS.

### Step 2 — Worker package layout

**Built:** The `reelops_worker` package: `config.py` (a frozen `Settings` read
from `REELOPS_*` environment variables and validated), a CLI in `__main__.py`, a
`PipelineError` base exception, stub stage modules, pinned `requirements.txt`
plus a `requirements-dev.txt` for pytest, and config tests.

**Why / alternatives:** Stages receive `Settings` as an argument instead of
reading globals, so the CLI, the Phase 3 queue consumer and the tests can each
build settings their own way. Only `__main__` configures logging and exit codes;
library code raises exceptions. Only direct dependencies are pinned; a full lock
file with hashes (pip-tools or uv) is the stricter alternative, worth adding in
CI. boto3 was pinned to a two-week-old release rather than yesterday's, to stay
clear of brand-new releases.

**Problems:** None.

**Interview questions:**
1. *Why validate configuration at start-up?* To fail fast with a message naming
   the bad variable, instead of failing minutes into a job with a confusing
   ffmpeg error.
2. *Why separate runtime and dev requirements?* The production image shouldn't
   ship test tools: smaller image, less attack surface.

### Step 3 — Pipeline stages

**Built:** audio (ffmpeg → 16 kHz mono WAV, a clear error when there's no audio),
transcribe (faster-whisper base, int8, VAD), captions (SRT, at most 42 characters
and 2 lines per caption), voiceover (one Polly clip per segment, atempo capped at
1.5×, mixed onto a track as long as the video), render (burned-in captions,
voice-over audio, H.264 + AAC, faststart), and the pipeline (temporary work
directory, timing for each stage). Plus a shared `ffmpeg.py` helper.

**Why / alternatives:**
- *Sync:* one long TTS clip drifts away from the screen; one clip per segment
  anchored at its start time resets drift every sentence. A slot runs to the
  next segment's start (not the segment's own end) to use pauses and avoid
  speed-ups. Overruns overlap rather than pushing later clips back, which would
  reintroduce drift.
- *Captions:* time is shared within a segment by character count; word-level
  timestamps would be more exact but slower.
- *Render:* ffmpeg runs inside the work directory so the subtitles filter gets a
  plain filename. Full paths in filter arguments need fragile escaping.
- The output is moved into place only once complete, so a half-written file
  never appears at the output path.

**Problems:** The smoke test's fixture (an odd-sized 641×361 video encoded as
yuv420p) failed. x264 can't encode odd dimensions in yuv420p, which is exactly
why `render.py` rounds dimensions down to even numbers. The fixture now uses
yuv444p, like real screen recordings. Known limitation: greedy wrapping can
leave a short last caption (0.47 s in the smoke test).

**Interview questions:**
1. *How do you keep an AI voice-over in sync with the video?* Synthesize one clip
   per transcript segment, delay each to its segment start, speed it up with
   atempo (pitch-preserving, capped) if it's longer than its slot, and mix them
   onto a silent base track exactly as long as the video.
2. *Why `-movflags +faststart`?* It moves the MP4 index (the `moov` atom) to the
   start of the file so browsers can begin playing before the download finishes.

### Step 4 — Worker Dockerfile

**Built:** A multi-stage Dockerfile: `deps` (pinned python:3.12-slim digest,
ffmpeg, fonts, pip packages, Whisper model baked into `/opt/models`), a `test`
stage, and `runtime` (non-root user `app`, exec-form ENTRYPOINT). Image:
1.75 GB uncompressed, ~477 MB compressed.

**Why / alternatives:** Layers go from least to most frequently changed, so a
code edit rebuilds only the last `COPY` (0.6 s versus 77 s cold). Baking the
model in plus `HF_HUB_OFFLINE=1` means no 150 MB download on every container
start and no runtime dependency on huggingface.co. Alternatives: download the
model at start-up (slow cold starts) or mount it from EFS or S3 (more moving
parts). `runtime` is the last stage, so a plain `docker build` produces the
production image without pytest.

**Problems:**
- The Hugging Face cache wrote a metadata file readable only by root, so the
  `app` user got a "Permission denied" warning. Fixed with
  `chmod -R a+rX /opt/models`.
- Size: Debian's ffmpeg pulls in GPU libraries (LLVM, Mesa, about 190 MB) that a
  headless worker never uses, and PyAV bundles a second ffmpeg. A static ffmpeg
  binary would save roughly 250–300 MB. Kept apt as specified.

**Interview questions:**
1. *Why does Dockerfile instruction order matter?* Each instruction is a cached
   layer; changing one invalidates it and every layer after it. Put rarely
   changing steps (OS packages, dependencies) first and code last.
2. *Why run as non-root and pin the base image by digest?* Non-root limits the
   damage if the process is exploited (for example through a malicious video
   file reaching ffmpeg). A digest makes builds reproducible because tags move.

### Step 5 — Sample input and unit tests

**Built:** `scripts/make_sample.sh`, which creates a 29 s Polly-narrated test
video; 33 pytest tests (captions, slot and atempo math, voice selection with a
fake Polly client, missing-audio error, config) that pass in the test image with
`--network none`.

**Why / alternatives:** Commit the recipe, not the video: media is large and
git-ignored, and the script makes the input repeatable. The sample is narrated by
Matthew so the change to Kajal is audible. The audio tests use real ffmpeg on
tiny generated clips, because faking ffprobe would only test the fake. Running
the tests with networking off proves they need neither AWS nor the internet.

**Problems:** `docker image prune` found nothing to remove. Docker 29 uses the
containerd image store, which keeps old layers in the BuildKit cache instead of
leaving dangling images. The cache was kept because it's what makes rebuilds
fast.

**Interview questions:**
1. *How do you unit-test code that calls AWS without calling AWS?* Inject the
   client: `resolve_voice` takes any object with `describe_voices`, so tests pass
   a small fake. Alternatives: botocore's `Stubber`, or moto.
2. *Why keep the pure logic (slots, atempo, wrapping) in separate functions?* It
   can be tested exhaustively in milliseconds, while the I/O shell (Polly,
   ffmpeg) is covered by a few integration and end-to-end runs.

### Step 6 — End-to-end run in the container

**Built:** Ran the worker image on `samples/synthetic.mp4` (29 s → 11.5 s) and a
real 2-minute screen recording (121 s → 27.6 s), mounting `./samples` and
passing `AWS_REGION`. Outputs: H.264/AAC, faststart, readable burned-in
captions, Kajal voice-over with no overrun warnings.

**Why / alternatives:** The container runs with `--user $(id -u):$(id -g)` so
files written to the bind mount are owned by the host user rather than an
unknown uid 10001 (alternatives: make the folder world-writable, or chown
afterwards). Still non-root. `HOME=/tmp` because that uid has no home directory
in the image. Credentials come from the instance role through IMDS (hop limit 2).
Rendering is the slowest stage (~60% of the time) because every frame is
re-encoded with the captions.

**Problems:**
- *Transitive dependency drift:* the first run crashed with
  `TypeError: open() got an unexpected keyword argument 'metadata_errors'`.
  faster-whisper 1.2.1 requires `av>=11` with no upper bound, and PyAV 19.0
  (released days earlier) removed that argument. Tested versions in throwaway
  containers to find the break (18.1.0 works, 19.0.0 doesn't), pinned
  `av==18.1.0` with a comment, and added a regression test that runs
  faster-whisper's `decode_audio` without the model. Forcing PyAV 19 back in
  makes the test fail with the production error. The lasting fix is a full lock
  file (pip-tools or uv) in Phase 7.
- *Reading a file mid-upload:* the first probe of the demo said
  `moov atom not found`. The file was still being uploaded, and MP4 writers put
  the `moov` index last. A few seconds later it was complete. In Phase 3, S3
  avoids this race because objects (and their events) appear only after the
  upload completes.
- *Accuracy:* Whisper `base` appears to have misheard at least one technical
  phrase. Options: `--build-arg WHISPER_MODEL=small` (slower, bigger image) or
  an `initial_prompt` with domain vocabulary.

**Interview questions:**
1. *Your tests passed but production crashed on a dependency. How do you prevent
   that?* Pin transitive dependencies too: a lock file with hashes, rebuilt and
   tested deliberately (for example via Dependabot PRs). Add a cheap test that
   exercises the integration boundary (here, faster-whisper decoding with PyAV),
   and run an end-to-end smoke test in CI.
2. *Why do files written by a container to a bind mount sometimes end up owned
   by a strange user?* Bind mounts preserve numeric uids, and the container's
   uid (10001) doesn't exist on the host. Run with `--user $(id -u):$(id -g)`,
   or use named volumes.

### Step 7 — Commit and push

**Built:** Six Conventional Commits for Phase 1 (`feat`, `feat`, `build`, `test`,
`fix`, `docs`) pushed to `main`.

**Why / alternatives:** One commit per logical change makes history reviewable
and revertible, and Conventional Commit types let tools generate changelogs.
The PyAV fix got its own `fix:` commit: the pre-fix `requirements.txt` was
staged with `git hash-object -w` + `git update-index --cacheinfo`, which stages
a chosen version of a file without touching the working copy (a non-interactive
alternative to `git add -p`). Alternative: one big "Phase 1" commit (simpler,
but hides the bug-fix story).

**Problems:** Step 7 was skipped before Phase 2 started; caught by checking
`git status` first and committed before any Phase 2 changes, so the phases stay
in separate commits. A scan for the account ID ran before pushing.

**Interview questions:**
1. *What are Conventional Commits for?* A `type(scope): summary` convention
   (feat, fix, build, test, docs, ...) that makes history scannable and lets
   tools derive changelogs and semantic version bumps (fix → patch, feat → minor).
2. *How would you stage only part of a file's changes?* Interactively with
   `git add -p`; non-interactively by writing the desired content as a blob
   (`git hash-object -w`) and staging it with `git update-index --cacheinfo`.

---

## Phase 2 — Data layer (terraform/main)

### Step 1 — Media bucket

**Built:** `main.tf` (account-ID data source, `reelops-dev` name prefix),
`variables.tf` (`allowed_origins`, validated) and `s3.tf`: the private media
bucket `reelops-media-<account-id>` with BucketOwnerEnforced, public access
block, SSE-S3, TLS-only policy, lifecycle rules and CORS. Plan: 7 to add.

**Why / alternatives:**
- *Lifecycle* (raw/ 3 days, output/ 14 days, abort multipart after 1 day) keeps
  cost near zero without a cron job. Abandoned multipart parts are invisible in
  listings but billed, which makes them a classic silent cost leak.
- *CORS* is needed because the Phase 6 browser app (localhost:5173) uploads
  cross-origin with presigned URLs; a PUT with Content-Type triggers an OPTIONS
  preflight that S3 must approve. CORS is browser-enforced only; authorization
  is still the presigned URL. Allowed headers are limited to `content-type` and
  `x-amz-*` rather than `*`.
- *BucketOwnerEnforced* disables ACLs so only policies control access (the AWS
  default for new buckets since 2023, set explicitly here).
- No versioning or `prevent_destroy`: media is short-lived working data.
  Alternative: CloudFront with origin access control for downloads (Phase 6+).

**Problems:** None. Added a `validation` block because an origin with a trailing
slash or path never matches the browser's exact `Origin` header and fails with
a confusing CORS error; confirmed it rejects `http://localhost:5173/`.

**Interview questions:**
1. *Why do browser uploads to S3 need CORS when the presigned URL already
   authorizes the request?* They solve different problems. The signature
   authorizes the request to S3; CORS is the browser asking S3 whether JavaScript
   from this origin may send it at all. Without a CORS rule the preflight fails
   and the browser never sends the PUT.
2. *How do you stop an S3 bucket from silently growing in cost?* Lifecycle rules
   to expire objects per prefix, abort incomplete multipart uploads, and (with
   versioning) expire noncurrent versions. Plus Storage Lens or a billing alarm.

### Step 2 — Queues and S3 event notification

**Built:** `sqs.tf`: main queue `reelops-dev-jobs` (visibility 300 s, long
polling 20 s, retention 4 days, SSE-SQS), DLQ `reelops-dev-jobs-dlq` (14 days)
with redrive after 3 receives, a redrive-allow policy limiting the DLQ to the
main queue, a queue policy letting S3 send from our bucket only, and an
`ObjectCreated:*` notification on `raw/`. Plan: 12 to add.

**Why / alternatives:**
- *Visibility timeout* is the retry mechanism: a crashed worker's message
  reappears after 300 s. Too short and a slow job gets processed twice; too
  long and crash recovery is slow. Phase 3 can heartbeat with
  `ChangeMessageVisibility` for long videos.
- *Long polling* (20 s) avoids paying for empty receives and reacts faster
  than sleep-and-retry; short polling also samples only some SQS servers.
- *DLQ retention > source retention* because standard queues keep the original
  enqueue timestamp when moving a message to the DLQ.
- *SSE-SQS over SSE-KMS*: S3 can't send to a queue using the AWS-managed
  `aws/sqs` key; SSE-KMS would need a customer-managed key (~$1/month) with a
  key policy for S3.
- *Alternatives to S3 → SQS:* S3 → EventBridge → SQS (richer filtering, many
  targets, multiple rules per bucket), or S3 → Lambda directly (no queue
  buffering or DLQ control for a long ffmpeg job).

**Problems:** Two classic traps avoided rather than hit: (1) a dependency
cycle between the queue's redrive policy and the DLQ's allow policy, solved
with the separate `aws_sqs_queue_redrive_allow_policy` resource; (2) S3's
destination validation failing because the queue policy isn't there yet,
solved with `depends_on` (confirmed in `terraform graph`).

**Interview questions:**
1. *What is the `s3:TestEvent` message and why does it matter?* When a bucket
   notification is created or changed, S3 sends a test message (with
   `"Event": "s3:TestEvent"` and no `Records`) to validate the destination. A
   consumer that doesn't skip and delete it will fail on it repeatedly and push
   it to the DLQ, causing a false alarm.
2. *Why put `aws:SourceArn` and `aws:SourceAccount` conditions on a queue
   policy for S3?* The principal is the whole S3 service, so without conditions
   any bucket in any account could send to the queue: the confused-deputy
   problem. SourceAccount also covers a bucket name being deleted and claimed
   by someone else.

### Step 3 — Jobs table

**Built:** `dynamodb.tf`: table `reelops-dev-jobs`, on-demand billing, partition
key `job_id` (S), TTL on `expires_at`, default encryption. The planned Phase 3
item shape (status, s3_key, etag, claimed_at lease, attempts, error,
timestamps) is documented in a comment next to the table. Plan: 13 to add.

**Why / alternatives:**
- *On-demand* fits spiky, low-volume traffic with zero idle cost; provisioned
  capacity (with auto scaling) is cheaper only at steady, predictable load.
- *Key design:* every Phase 3 access is by `job_id`, so no sort key or GSI yet;
  a status GSI can come in Phase 6 if the API lists jobs.
- *TTL* cleans up for free, mirroring the S3 lifecycle; it needs epoch seconds
  (Number) and deletes lazily, so reads must ignore expired items.
- *Encryption:* AWS-owned key (free, always on). Customer-managed KMS adds cost
  and is only needed for key-level control or audit. PITR and deletion
  protection off in dev, on in prod.
- *Lease (`claimed_at`)*: a conditional claim succeeds only for `pending` jobs
  or `processing` jobs whose lease (= visibility timeout) has expired, so jobs
  of killed workers are recovered and duplicates can't run in parallel.
  Alternatives: rely on SQS alone (no status for the API, and no protection
  against duplicate S3 events), or Step Functions for orchestration (more
  moving parts and cost).

**Problems:** None.

**Interview questions:**
1. *A worker is killed mid-job. How does your system recover?* The SQS message
   wasn't deleted, so it reappears after the visibility timeout. The next worker
   tries a conditional claim; because the dead worker's `claimed_at` is older
   than the lease, the claim succeeds and it reprocesses. `attempts` and the
   DLQ's `maxReceiveCount` cap retries for jobs that always fail.
2. *How do you make processing idempotent when SQS and S3 deliver at least
   once?* Conditional writes in DynamoDB (`attribute_not_exists` / status and
   lease checks) so only one worker claims a job; compare the stored `etag` to
   skip duplicates of already-done content; write outputs to deterministic keys
   so a retry overwrites instead of duplicating.

### Step 4 — DLQ alarm and email alerts

**Built:** `alarms.tf`: SNS topic `reelops-dev-alerts`, an email subscription
from `var.alert_email`, and a CloudWatch alarm that fires when the DLQ's
`ApproximateNumberOfMessagesVisible` Maximum is > 0 for one 60 s period (with
ALARM and OK notifications). The real email lives in git-ignored
`terraform.tfvars`; `terraform.tfvars.example` is committed. Plan: 16 to add.

**Why / alternatives:**
- *Alarm on the DLQ, not on errors in logs:* a DLQ message is a definitive "this
  job failed 3 times" signal with no false positives from transient retries.
  Alternatives: a metric filter on worker error logs, or alarming on
  `ApproximateAgeOfOldestMessage` on the main queue (catches a stalled worker,
  a good later addition).
- *Maximum* statistic so a single short-lived message isn't averaged away;
  `treat_missing_data = notBreaching` because idle SQS queues send no data.
- *SNS topic unencrypted:* CloudWatch can't publish to a topic encrypted with
  the AWS-managed `aws/sns` key; a customer-managed key would be needed, and
  alarm payloads hold no job data.
- *Variables:* `alert_email` has no default, so it must come from tfvars locally
  or `TF_VAR_alert_email` in CI; a validation block catches typos.

**Problems:** None. Two things to know: email subscriptions stay "pending
confirmation" until the link is clicked (Terraform can't confirm or delete
them), and SQS metrics can lag by several minutes, up to ~15 after a long-idle
period.

**Interview questions:**
1. *How do you get alerted when background jobs fail?* Redrive failing messages
   to a DLQ after N receives, then a CloudWatch alarm on the DLQ's visible
   message count (> 0) notifying SNS (email, Slack, PagerDuty). Add an
   oldest-message-age alarm on the main queue to catch a stuck consumer.
2. *Why might a CloudWatch alarm on an SQS metric be slow to fire?* SQS
   publishes metrics at one-minute granularity with some delay, longer for
   queues that were inactive; plus the alarm needs a full evaluation period.
   Expect minutes, not seconds.

### Step 5 — Outputs and the full plan

**Built:** `outputs.tf` (bucket name, queue URL/ARN, DLQ URL, table name, SNS
topic ARN). `fmt` and `validate` pass; the full plan is 16 to add, 0 to change,
0 to destroy, saved to `phase2.tfplan` (git-ignored) for the human to apply.

**Why / alternatives:** Outputs let verification scripts and, later, the worker
read values with `terraform output -raw` instead of copying ARNs by hand. In CI
they could feed the next job, or be published to SSM Parameter Store for apps
to read at runtime (a common alternative). A saved plan guarantees that what
gets applied is exactly what was reviewed.

**Problems:** None. Reviewing defaults I didn't set surfaced useful facts: S3
notifications can't target FIFO queues (so standard queues with at-least-once
delivery are the only option); the DLQ keeps SQS's default 30 s visibility;
lifecycle's `transition_default_minimum_object_size` only affects transitions.

**Interview questions:**
1. *Why review a plan for values you didn't set?* Provider defaults are part of
   the infrastructure. Reviewing them catches surprises (wrong timeouts, public
   settings, missing encryption) before they're live, and is how you learn
   service limits like "S3 can't notify FIFO queues".
2. *Why `terraform apply planfile` instead of plain `apply`?* A plain apply
   re-plans, and the infrastructure or code could have changed since review. A
   saved plan applies exactly the reviewed changes, and fails if the state
   changed in the meantime.

### Step 6 — Verification

**Built:** Verified the applied data layer with data-plane calls (no
infrastructure changes):
- *6a:* uploading `raw/verify-6a/hello.txt` produced an `ObjectCreated:Put`
  message (key, size 35, eTag); the `s3:TestEvent` from apply time was also in
  the queue (no `Records` key). Both messages deleted by receipt handle.
- *6c:* put, conditional duplicate put (rejected), lease claim by "worker A"
  (accepted), second claim by "worker B" (rejected with
  ConditionalCheckFailedException), consistent read, delete.
- *6b (DLQ → alarm → email):* sent a test message to the main queue, received
  it 3 times without deleting (visibility reset to 0 between receives,
  `ApproximateReceiveCount` 1 → 2 → 3); the 4th receive returned nothing
  because SQS moved it to the DLQ. The alarm went to ALARM ~3 min after the
  message reached the DLQ and emailed the alert. After purging the DLQ it
  returned to OK ~3.5 min later and emailed the OK notification. Both queues
  ended empty. Run after the commit in Step 7, once the subscription was
  confirmed (an alarm notification sent before confirmation is dropped).

**Why / alternatives:** Verifying with real messages proves the wiring that
`terraform plan` can't: the queue policy actually lets S3 send, the prefix
filter matches, and conditional writes behave as the lease design assumes.
Alternative: automated integration tests (e.g. pytest + boto3 in CI against a
dev stack), worth adding once the pipeline is deployed.

**Problems:**
- `get-queue-attributes` showed 0 messages while the TestEvent was actually
  present: the counts are approximate and lag. A real `receive-message` is the
  reliable check.
- The email subscription showed `PendingConfirmation` when first checked, so
  6b was held back; a later `list-subscriptions-by-topic` showed a real
  subscription ARN and no re-send was needed. Lesson: check the subscription
  ARN before relying on email alerts. (If it really is stuck, `aws sns
  subscribe` for the same endpoint re-sends the confirmation for the existing
  pending subscription.)
- Redrive happens on the receive *after* the limit: with `maxReceiveCount = 3`,
  the message moved to the DLQ on the 4th receive attempt, which returned
  empty. The receive count carries over into the DLQ.
- Peeking with `--visibility-timeout 0 --max-number-of-messages 10` returned
  the same single DLQ message 10 times, because it never becomes hidden.
  Trust `ApproximateNumberOfMessages` (1) over the batch size when peeking.
- Alarm latency was ~3 minutes in each direction (SQS metric lag plus the
  60 s evaluation period): expect minutes, not seconds.
- The eTag equals the MD5 only for single-part, non-KMS uploads; multipart
  eTags look like `<hash>-<parts>`. Treat it as an opaque identifier.

**Interview questions:**
1. *What's a receipt handle, and why can't you delete an SQS message by its
   message ID?* A receipt handle identifies one specific *receive* of a
   message. Deleting by handle ensures only the consumer currently holding the
   message (within its visibility timeout) can delete it; a stale handle from
   an earlier receive may fail.
2. *How did you prove only one worker can claim a job?* With a conditional
   `UpdateItem` (`status = pending OR lease expired`): the first claim
   succeeded and a second, immediate claim failed with
   ConditionalCheckFailedException. DynamoDB evaluates the condition and the
   write atomically.

### Step 7 — Commit and push

**Built:** One Conventional Commit per Phase 2 step plus the notes, pushed to
`main`. `terraform.tfvars` (real email), `phase2.tfplan` and `.terraform/` stay
uncommitted via `.gitignore`.

**Why / alternatives:** Per-step commits make each infrastructure change
reviewable and revertible on its own. `variables.tf` changed in two steps, so
its Step 1 version was staged with `git hash-object` + `update-index`, as in
Phase 1. Before pushing, the staged files were scanned for the account ID and
the alert email.

**Problems:** Committed with 6b still pending, at the user's request; 6b was
completed right after and the Step 6 entry updated.

**Interview questions:**
1. *What should never be committed from a Terraform project?* State files
   (`*.tfstate*`), `.terraform/`, real `*.tfvars`, saved plan files (they can
   contain sensitive values), and crash logs. Do commit `.terraform.lock.hcl`
   and `*.tfvars.example`.
2. *How do you keep personal or environment-specific values out of Git but
   still available to CI?* Git-ignored `terraform.tfvars` locally; in CI,
   `TF_VAR_<name>` environment variables from encrypted secrets (GitHub Actions
   secrets or variables), or values read from SSM Parameter Store.

---

## Phase 3 — Queue-driven pipeline (local, against real AWS)

### Step 1 — API

**Built:** `app/`: a FastAPI service (python:3.12-slim, non-root, pinned deps,
256 MB image). `POST /jobs` validates type and size, writes a `pending` item
(conditioned on `attribute_not_exists(job_id)`) and returns a 15-minute
presigned PUT bound to the Content-Type. `GET /jobs/{id}` returns status,
adding a presigned GET (attachment) when done. `GET /healthz` is liveness only.

**Why / alternatives:**
- *Presigned URLs* keep video bytes out of the API: the browser uploads
  straight to S3, so API tasks stay small, there's no double data transfer, and
  scaling follows request count, not upload size. Clients never get AWS
  credentials, only one URL for one action on one object for 15 minutes.
  Alternative: stream uploads through the API (simple, but heavy and slow).
- *Size* can't be enforced by a presigned PUT; the worker re-checks the real
  object size. Production upgrade: presigned POST with `content-length-range`.
- *Regional virtual-hosted S3 endpoint + SigV4*: the global endpoint may
  307-redirect, and browsers fail CORS preflights on redirects.
- *App factory + injected clients*, mirroring the worker, so moto can stand in
  for AWS in tests. Sync `def` routes because boto3 blocks (FastAPI runs them
  in a thread pool).
- `/healthz` makes no AWS calls: a DynamoDB blip shouldn't make the load
  balancer kill every task.

**Problems:** None. Verified against the real bucket and table without side
effects: a PUT with the wrong Content-Type got `403 SignatureDoesNotMatch` and
created no object (so no S3 event reached the queue); the test job item was
deleted afterwards. Note: with instance-role credentials the URL embeds a
session token and stops working at 15 minutes or at credential expiry,
whichever is first.

**Interview questions:**
1. *Why use presigned URLs for uploads instead of uploading through your API?*
   The API never handles the bytes: it hands out a short-lived URL scoped to one
   object and Content-Type, and the client uploads straight to S3. That avoids
   large request bodies, long timeouts, double bandwidth and API scaling driven
   by upload volume, and no AWS credentials ever reach the client.
2. *Can a presigned PUT limit the upload size?* No; it signs the method, key and
   chosen headers, not a size range. Use presigned POST with a
   `content-length-range` policy condition, and still validate size server-side
   (here, the worker checks the object size from the S3 event).

### Step 2 — Worker queue consumer

**Built:** `worker/reelops_worker/consumer.py`, run with
`python -m reelops_worker consume` (same image; the CLI still works). It loads
Whisper once, long-polls SQS one message at a time, ignores `s3:TestEvent`,
URL-decodes keys, claims jobs with a conditional DynamoDB update, heartbeats
(visibility + lease) every 60 s, uploads `output/<job_id>.mp4`, sets `done`
and only then deletes the message. SIGTERM stops intake and gives a running
job 20 s before handing it back.

**Why / alternatives:**
- *Delete last:* the SQS message is the job's retry ticket; deleting before
  the result is durable turns a crash into a lost job. Worst case with delete
  last is duplicate work, made harmless by the claim rules and a deterministic
  output key (at-least-once + idempotency).
- *Claim-failure cases:* `done` → duplicate event, delete; `processing` with
  a fresh lease → another live worker holds its own message, delete; `failed`
  → terminal, delete; `pending` → raced, leave for retry.
- *URL-decoding (`unquote_plus`):* S3 event keys are form-encoded (space →
  `+`); using them raw gives NoSuchKey for any filename with spaces or
  non-ASCII characters.
- *Owner-conditioned writes* (`worker_id = me AND status = processing`) stop a
  stalled worker overwriting the state of the worker that took over.
- *Graceful shutdown:* ECS sends SIGTERM, waits the stop timeout (default
  30 s), then SIGKILL. Without handling, a killed job waits ~5 min for its lease
  and visibility to expire; with it, the job finishes or is handed back at once
  (status `pending`, message visibility 0). `signal.alarm` raises `Shutdown`,
  which unwinds the pipeline (`subprocess.run` kills ffmpeg, temp files are
  removed).
- Alternatives: Celery or RQ (more machinery, needs a broker), Step Functions
  (managed orchestration, more cost), Lambda (15-minute and size limits awkward
  for ffmpeg and model loading).

**Problems:**
- *A race in the spec:* lease 300 s = visibility 300 s means a dead worker's
  message can reappear at the same instant its lease goes stale; if received a
  moment early, the redelivery looks like a duplicate, gets deleted, and the job
  is stuck in `processing` forever. Fixed by lease = 240 s (visibility −
  heartbeat interval), enforced in `config.py` as
  `heartbeat < lease < visibility`.
- *Unexpected errors* would leave a fresh lease and hit the same race on retry,
  so the worker releases the claim (`pending`), or marks `failed` on the final
  receive, so the API shows the failure while the message goes to the DLQ.
- Testing gotcha: `cmd | tail` reports tail's exit code; checked the container's
  real exit code (2 for missing settings) separately.

**Interview questions:**
1. *Why delete the SQS message only after processing succeeds?* The message is
   the only thing that guarantees a retry. Ack-after-commit means any crash
   leads to redelivery (at-least-once). Then make processing idempotent: claim
   with a conditional write, deterministic output keys, skip already-done jobs.
2. *How should a queue worker handle SIGTERM on ECS/Kubernetes?* Stop pulling
   new work, finish the current item within the stop timeout or hand it back
   (release the claim, set message visibility to 0), then exit 0. Run the
   process as PID 1 with an exec-form entrypoint so it actually receives the
   signal.

### Step 3 — Tests with moto

**Built:** moto-based tests run in both test images with `--network none`:
11 API tests (create/get, presigned URL shape, validation, done → attachment
download, failed, 404/422, expired) and 21 new consumer tests (claim rules,
TestEvent, URL-decoded keys, unknown/too-large, PipelineError, retry and final
attempt, lost lease, SIGTERM hand-back, heartbeat). Worker total: 55; API: 11.

**Why / alternatives:**
- *moto* fakes S3/SQS/DynamoDB in memory behind boto3, so the real calls run,
  including `ConditionExpression`, receipt handles and visibility changes,
  with no network or credentials (works offline and in CI). Alternatives:
  `botocore.Stubber` (you script every response: tests your script, not
  behaviour) or LocalStack (a container, closer to real AWS but heavier).
- *Fake credentials + `AWS_EC2_METADATA_DISABLED`* set in `conftest.py` before
  boto3 loads: otherwise boto3 hangs on IMDS without a network, or worse, finds
  the dev box's real role.
- *Controllable clock:* lease ages are exact (240 s = fresh, 241 s = stale) with
  no sleeping; the edge case `claimed_at == now - 240` is tested explicitly.
- *Fake pipeline:* consumer tests check decisions, not ffmpeg/Whisper, which
  have their own tests; fakes also inject failures (PipelineError,
  RuntimeError, Shutdown, a lease stolen mid-render).

**Problems:** None failing. A deprecation warning: Starlette's TestClient now
prefers `httpx2` over `httpx`; harmless, to fix at the next dependency bump.

**Interview questions:**
1. *How do you test code that depends on SQS and DynamoDB without AWS?* Inject
   the clients and use moto to emulate the services in memory, so real API calls
   (conditional writes, deletes by receipt handle) execute. Disable real
   credential lookup in tests so nothing can reach a real account.
2. *How do you test time-dependent logic like leases?* Inject a clock instead
   of calling `time.time()` directly, set it to exact values, and test both sides
   of each boundary. Keep only one short real-time test for the threaded
   heartbeat.

### Step 4 — Docker Compose and .env from Terraform

**Built:** `scripts/env_from_tf.sh` writes a git-ignored, `chmod 600` `.env`
(region, bucket, table, queue URL) from `terraform output`, atomically.
`docker-compose.yml` runs `api` (healthcheck on `/healthz`, published on
`127.0.0.1:8000`) and `worker` (`command: consume`, 30 s stop grace period).
Both get credentials from the instance role (`iam-role`), with no keys anywhere.

**Why / alternatives:**
- *Generate config from Terraform outputs* so it can't drift from what exists;
  alternatives: hand-edited `.env` (drifts), or SSM Parameter Store read at
  startup (the Phase 4+ cloud equivalent).
- *Localhost-only port:* Docker-published ports go on all interfaces and
  Docker's iptables rules bypass `ufw`, so `8000:8000` would expose the API if
  the security group ever allowed it. Reach it from Windows with VS Code port
  forwarding.
- `stop_grace_period: 30s` mirrors ECS's default stopTimeout, so `docker compose
  stop` rehearses a Fargate task stop. It must exceed the worker's 20 s job
  grace period.
- *Healthcheck via Python's urllib* because slim images have no `curl`; same
  probe as the Phase 4 load balancer.

**Problems:** None. A `git status | grep env` false alarm matched the new
script, not `.env`; `--untracked-files=all` confirmed `.env` is ignored.

**Interview questions:**
1. *Why bind a published container port to 127.0.0.1?* Docker publishes on
   0.0.0.0 by default and inserts iptables rules ahead of host firewalls like
   ufw, so a container port can be reachable from the internet even when the
   host firewall "blocks" it. Bind to localhost and tunnel, or rely on a
   security group that doesn't open the port.
2. *How do containers on an EC2 instance get AWS credentials without keys?*
   Through the instance role via IMDSv2. The hop limit must be 2 so the token
   response survives the extra hop across the Docker bridge network. On ECS the
   task role is used instead.

### Bug fix — SIGTERM lost during worker startup (found after Step 4)

**Built:** An early SIGTERM/SIGINT handler in `__main__` (installed before the
heavy imports and model load) that sets a shared `threading.Event` the
consumer then uses as its stop flag; `init: true` on the compose worker; a
subprocess regression test. Planned for Phase 4: `initProcessEnabled = true`
in the worker's ECS task definition (`linuxParameters`).

**Why / alternatives:**
- *Root cause:* the kernel doesn't deliver a signal to a PID namespace's PID 1
  unless it has a handler (protection for init). Python handles SIGINT by
  default but not SIGTERM, and our handler was installed only after ~1-2 s of
  imports and model loading. A SIGTERM in that window was dropped; Docker
  doesn't resend, so it waited the 30 s grace period and SIGKILLed (exit 137)
  a worker that had meanwhile started polling.
- *Two layers:* (1) handle the signal as early as possible, and carry the
  "stop requested" state into the consumer rather than losing it;
  (2) run an init (tini via `init: true`, or ECS `initProcessEnabled`) as
  PID 1, which forwards signals (the child, not being PID 1, dies by default
  even before a handler exists) and reaps orphaned processes such as ffmpeg.
- Alternatives: `exec` form plus `STOPSIGNAL SIGINT` (Python handles SIGINT by
  default; hacky), or a tini `ENTRYPOINT` baked into the image (works
  everywhere, but duplicates what compose/ECS provide).

**Problems:**
- Reproduced first, as reported: stop 0.5 s after start took 30.3 s, exit 137,
  and the log showed the worker went on to poll. After the fix: 0.3 s, exit 0,
  both with Python as PID 1 (no init) and with `init: true`.
- My first version of the test unpacked `communicate()` as (stderr, stdout)
  instead of (stdout, stderr). Verified the fixed test fails (return code -15)
  on a copy with the early handler removed, so it really guards the bug.
- An idle stop still takes up to ~20 s: the worker finishes the current long
  poll. Expected, and within the 30 s grace period.

**Interview questions:**
1. *Why might a container ignore `docker stop` and only die after the timeout?*
   Its main process is PID 1, which only receives signals it has a handler for;
   if it hasn't installed a SIGTERM handler (yet), or a shell wrapper is PID 1
   and doesn't forward signals, SIGTERM is dropped and Docker SIGKILLs after
   the grace period. Fix with exec-form entrypoints, early signal handlers and
   an init process (tini / `--init` / ECS `initProcessEnabled`).
2. *What does an init process like tini do in a container?* It runs as PID 1,
   forwards signals to the child process, and reaps zombie processes (orphans
   re-parented to PID 1), which a normal application doesn't do.

### Step 5 — End-to-end through the queue

**Built:** `scripts/e2e.sh`: `POST /jobs` → `curl` PUT to the presigned URL →
poll `GET /jobs/{id}` → download the output → re-send the same S3 event by hand
and check the worker logs "duplicate skipped" and the job stays `done` with
`attempts` unchanged. Run on `samples/synthetic.mp4`: create 0.1 s, upload
0.1 s, queue + processing 14.5 s (pending → processing in ~2 s, done at
14.5 s), download 0.1 s, total 14.8 s; duplicate handled in 0.8 s. Both queues
empty afterwards.

**Why / alternatives:** The script uses only HTTP and curl on the client side,
exactly what the Phase 6 browser will do, so it tests the real contract (the
presigned URL's signed Content-Type and the attachment
download; curl ignores CORS, so the bucket's CORS rules are only tested by the
browser in Phase 6). The duplicate is injected by rebuilding S3's event JSON, which
proves idempotency against at-least-once delivery without waiting for a real
duplicate. Alternatives: a pytest integration suite against the dev stack
(better for CI later), or testing through the browser (Phase 6).

**Problems:** None in this step. Processing took ~14 s vs ~11.5 s in Phase 1's
CLI run: the consumer adds an S3 download and upload plus the poll interval,
and the first stage timings include warm-up.

**Interview questions:**
1. *How do you prove a queue consumer is idempotent?* Inject a duplicate of a
   real message after the job completes and assert nothing changes: no second
   run (attempts unchanged), status still done, message deleted, and a log line
   that says why it was skipped.
2. *Why poll for job status instead of holding the HTTP request open until the
   video is ready?* Processing takes seconds to minutes; long-held requests tie
   up connections and break at load balancer and browser timeouts. Async job +
   status endpoint (or later WebSockets/SSE or a notification) decouples
   request time from processing time.

### Step 6 — Commit and push

**Built:** Conventional Commits for Phase 3, one per working step, with the
startup-SIGTERM bug as its own `fix:` commit, pushed to `main`. `.env` (account
ID in the queue URL and bucket name) stays uncommitted via `.gitignore`.
Before committing, `e2e.sh` gained a 60 s wait for `/healthz` and the usage
hints now say `docker compose up -d --build --wait`; verified by running
`e2e.sh` immediately after a plain `up`.

**Why / alternatives:** Keeping the bug fix separate makes the history tell
the true story (feature, then the bug found by testing, then the fix), and lets
the fix be reviewed or reverted on its own. Files touched by both were staged
at their pre-fix content with `git hash-object` + `update-index`, as before.

**Problems:** None.

**Interview questions:**
1. *Why make scripts wait for health instead of sleeping a fixed time?* Start-up
   time varies (image pulls, model loading); a fixed sleep is either too short
   (flaky) or too long (slow). Poll a readiness endpoint with a timeout, or use
   `docker compose up --wait`, which waits for healthchecks.
2. *What's the difference between `docker compose up --wait` and a healthcheck?*
   The healthcheck defines how Docker judges a container healthy; `--wait`
   makes the `up` command block until services are healthy (or just running,
   for services without a healthcheck).
