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

---

## Phase 4 — ECS Fargate

### Step 1 — Network

**Built:** `network.tf`: VPC `10.20.0.0/16` (DNS support and hostnames), public
subnets `10.20.0.0/24` (ap-south-1a) and `10.20.1.0/24` (ap-south-1b), an
internet gateway, a public route table, free S3 and DynamoDB gateway endpoints
on it, and the VPC's default security group emptied. Also declared
`enable_compute` (default true) for the nightly pause. Plan: 10 to add.

**Why / alternatives:**
- *Public IPs on tasks:* with no NAT, a task in a public subnet needs a public
  IP to reach ECR, SQS, Polly, Logs and STS through the internet gateway.
  Security groups block inbound, so it isn't an exposure. Each public IPv4
  address costs $0.005/hour.
- *Gateway endpoints* (S3, DynamoDB) are free route-table entries; ECR layers
  live in S3, so image pulls use it too. Every other service needs paid
  interface endpoints.
- *Production design:* tasks in private subnets with no public IPs, the ALB
  alone in public subnets, and outbound via NAT gateways (~$40/month each plus
  data) or interface endpoints (~$9/month per endpoint per AZ), plus HTTPS,
  WAF and flow logs.
- `map_public_ip_on_launch = false`: public IPs are requested explicitly per
  service. *Default SG locked down*: it allows all traffic between members, and
  anything launched without an SG lands in it (a common audit finding).

**Problems:** None in the config. A sloppy verification one-liner (`paste`)
paired plan lines wrongly and made `10.20.0.0/24` look like it was in 1b;
re-reading each subnet block showed the config was right. Lesson: verify plans
by resource block, not by flattened lines.

**Interview questions:**
1. *Why do Fargate tasks in a public subnet need `assign_public_ip`?* The
   internet gateway only routes traffic for addresses that have a public IP;
   without one (and without NAT) the task can't reach ECR, CloudWatch or other
   AWS APIs, and fails to start with image-pull errors.
2. *What's the difference between gateway and interface VPC endpoints?*
   Gateway endpoints (S3 and DynamoDB only) are route-table targets and free.
   Interface endpoints (PrivateLink) are ENIs with private IPs in your subnets,
   available for most services, billed hourly per AZ plus per GB.

### Step 2 — ECR and image pushes

**Built:** `ecr.tf`: repos `reelops-api` and `reelops-worker` (IMMUTABLE tags,
scan on push, lifecycle keeps 10 images, `force_delete` for dev), applied
early with a targeted plan. `scripts/push_images.sh` builds linux/amd64
single-manifest images, tags each with the short SHA of the last commit that
touched its folder, logs in via the instance role, skips tags already in ECR,
writes `images.auto.tfvars` (git-ignored) and reports scan results. Variables
`api_image_tag` / `worker_image_tag` have no default and reject `latest`.
Pushed `reelops-api:d52ab55` (63 MB) and `reelops-worker:41abfb9` (481 MB).

**Why / alternatives:**
- *Immutable SHA tags:* each tag is exactly one image traceable to a commit;
  rollback = deploy the previous tag; nothing can be silently replaced.
  `latest` says nothing about what's running.
- *Per-folder SHA:* unrelated commits don't create a new tag (and a redeploy)
  for identical code. Refuse to build with uncommitted changes in the folder.
- *Targeted apply for ECR first:* images must exist before task definitions
  reference them; `-target` is for one-off bootstraps like this, not routine.
- `force_delete` only in dev: in prod, deleting a repo deletes the images that
  running services and rollbacks need.
- *Credential helper* (`amazon-ecr-credential-helper`) would avoid storing the
  12-hour token in `~/.docker/config.json`; noted for later.

**Problems:**
- *OCI index instead of an image:* Docker 29 (containerd image store, BuildKit
  attestations) pushed each tag as an image index plus two untagged children
  (the platform manifest and a provenance attestation): 3 ECR entries per push.
  ECR's lifecycle "keep 10" would count all three, and could expire a child that
  a tagged index still points to. Fixed with `--provenance=false --sbom=false`
  (single `image.manifest`), deleted the 6 unused entries and re-pushed the same
  tags. Trade-off: no build provenance/SBOM attached; Phase 7 can generate an
  SBOM and sign images in CI instead.
- *"Scan not finished":* my first guess (index not scannable, then empty
  registry scan rules) was wrong. The scans ran; `aws ecr wait
  image-scan-complete` fails immediately with ScanNotFoundException when called
  right after a push, instead of waiting. Replaced with a polling loop (not yet
  exercised: both tags already existed on the re-run).
- I predicted the API tag would be the Phase 3 API commit, but the moto-tests
  commit also touched `app/` (tests), so the tag is `d52ab55`; correct
  behaviour, wrong prediction.
- *Findings:* API 3 HIGH (glibc, zlib, from the Debian base); worker 2 CRITICAL
  (tiff, brotli) + 14 HIGH, mostly from apt ffmpeg's dependencies. To fix by
  rebuilding on a patched base digest; Phase 7: Trivy in CI failing on
  CRITICAL, Dependabot bumping the base digest.

**Interview questions:**
1. *Why use immutable image tags?* So a tag always refers to the same image:
   deployments are reproducible and auditable, rollbacks are exact, and an
   attacker or mistake can't overwrite a deployed tag. Combine with SHA tags
   (or deploy by digest).
2. *What's an OCI image index and why might it surprise you in a registry?*
   A manifest that points to other manifests (per-platform images, and with
   BuildKit, attestations). Registries list the children as separate untagged
   artifacts, which affects scanning, lifecycle rules and image counts. For a
   single-platform service, build with attestations disabled or understand how
   your registry treats indexes.

### Step 3 — IAM for ECS tasks

**Built:** `iam_ecs.tf`: an execution role with the AWS-managed
`AmazonECSTaskExecutionRolePolicy`; an API task role (DynamoDB Put/GetItem on
the table, S3 PutObject `raw/*`, GetObject `output/*`); a worker task role (SQS
Receive/Delete/ChangeMessageVisibility/GetQueueAttributes on the main queue,
S3 GetObject `raw/*`, PutObject `output/*`, DynamoDB Get/UpdateItem, Polly
SynthesizeSpeech/DescribeVoices on `*` limited to ap-south-1). Trust policies
allow only `ecs-tasks.amazonaws.com` from this account. Plan: 16 to add.
Verified with the IAM policy simulator on the rendered policies before apply:
34/34 allow/deny checks pass, including denies on the tfstate bucket.

**Why / alternatives:**
- *Execution vs task role:* the execution role is for the ECS agent (pull
  image, write logs, fetch secrets); the task role is what the app's SDK uses.
  Separate so the app can't pull images/read start-up secrets and the agent
  can't touch data.
- *Presigned URLs* are requests signed with the API role's credentials, so S3
  evaluates that role's permissions when the browser uses them; the API needs
  PutObject/GetObject on the prefixes even though it never moves bytes.
- *`*` resources:* Polly's DescribeVoices has no ARN and SynthesizeSpeech can
  only be scoped to lexicons, so `*` plus an `aws:RequestedRegion` condition.
  The managed execution policy uses `*` too; tighter option: a custom policy
  for our two repos and log groups.
- *Trust conditions* (`aws:SourceAccount`, `aws:SourceArn`) prevent another
  account's ECS from assuming the roles (confused deputy).
- *Deliberately absent:* `s3:ListBucket` (missing keys give 403 instead of
  404, and no key enumeration).
- *Added after review:* `s3:AbortMultipartUpload` on `output/*`. I first left
  it out (outputs are below boto3's 8 MB multipart threshold, and the lifecycle
  rule removes orphaned parts after 1 day), but boto3's `upload_file` calls it
  on a failed multipart upload, and a lifecycle rule is a backstop, not a
  substitute. Simulator: allowed on `output/*`, denied on `raw/*` and the
  tfstate bucket.

**Problems:** My first simulator harness was broken: `--policy-input-list`
doesn't expand `file://` inside list items, every call failed with
InvalidInput, and the harness counted errors as DENY, so the "should deny"
rows falsely passed. Fixed by passing the JSON as a string and counting errors
as ERROR. Lesson: a negative test that passes when the tool fails proves
nothing; make failures loud.

**Interview questions:**
1. *What's the difference between an ECS task execution role and a task
   role?* The execution role is assumed by the ECS agent to pull the image from
   ECR, send logs to CloudWatch and fetch secrets for the container's
   environment. The task role is assumed by the application inside the
   container for its own AWS calls. Give each only what that party needs.
2. *How do you verify an IAM policy is least-privilege before deploying it?*
   Render it (e.g. from the Terraform plan) and run it through the IAM policy
   simulator (`simulate-custom-policy`) with both expected-allow and
   expected-deny cases, including sensitive resources like the state bucket;
   then confirm in the real environment, and use IAM Access Analyzer to review
   unused permissions over time.

### Step 4 — Log groups and ECS cluster

**Built:** `ecs.tf`: log groups `/reelops/dev/api` and `/reelops/dev/worker`
(7-day retention) and the `reelops-dev` ECS cluster with Container Insights
disabled; outputs `ecs_cluster_name` and `log_groups`. Plan: 19 to add.

**Why / alternatives:**
- *Terraform-managed log groups:* groups auto-created by the awslogs driver
  (`awslogs-create-group`) never expire by default and aren't owned by
  Terraform; here retention is set and `destroy` removes them. 7 days is enough
  for dev; prod might keep 30-90 days or export to S3.
- *Container Insights off:* the cluster itself is free on Fargate; Insights adds
  billed custom metrics and performance log events (more with enhanced
  observability). Free per-service CPU/memory metrics and SQS metrics are
  enough for dev and Phase 5 autoscaling. Turn it on to diagnose per-task
  performance.

**Problems:** None.

**Interview questions:**
1. *Why create CloudWatch log groups in Terraform instead of letting ECS create
   them?* To set retention (auto-created groups keep logs forever and keep
   costing), to manage encryption and tags, and so the infrastructure owns and
   cleans them up.
2. *What does Container Insights give you, and why might you leave it off?*
   Per-cluster/service/task/container metrics (CPU, memory, network, storage)
   and performance logs. It's billed as custom metrics plus log ingestion, so
   for small dev clusters the free service-level metrics are often enough.

### Step 5 — Task definitions

**Built:** `task_definitions.tf`: Fargate/X86_64/awsvpc task definitions.
`api`: 0.25 vCPU / 512 MB, port 8000, container health check on `/healthz`.
`worker`: 2 vCPU / 4 GB, `command = ["consume"]`, `initProcessEnabled`,
`stopTimeout = 30`, an ephemeral volume at `/tmp`. Both: images by immutable
SHA tag, env from Terraform references, awslogs (non-blocking, 25 MB buffer),
non-root as built, `readonlyRootFilesystem = true`. Plan: 21 to add.

**Why / alternatives:**
- *Read-only root, tested first:* `docker run --read-only` showed the API writes
  nothing, and the worker fails with "No usable temporary directory" until
  `/tmp` is writable; with `--tmpfs /tmp` both the CLI pipeline (12.0 s) and
  consume mode ran cleanly. On Fargate: a task `volume` with no host path,
  mounted at `/tmp`. A compromised process can't modify code or persist files.
- *Container health check vs ALB health check:* ECS uses the container check
  to replace unhealthy tasks; the ALB's check decides which targets get
  traffic. Both hit `/healthz`.
- *Non-blocking log mode:* stdout never blocks the app if CloudWatch is slow;
  trade-off: logs dropped if the buffer fills. Blocking mode guarantees
  delivery but can stall the app.
- *Sizes:* API is tiny (JSON only). Worker: Whisper int8 and ffmpeg want CPU;
  2 vCPU / 4 GB is a starting point; Step 9 timings will tell if it's right.

**Problems (found in Step 9):** The local test was not equivalent to Fargate.
`docker run --tmpfs /tmp` creates a world-writable (1777) mount, but Fargate
creates the task volume as `root:root 0755`, so the non-root worker could not
write to `/tmp` and every job failed ("No usable temporary directory"). Fixed
with a non-essential init container (same image, `user = "0"`,
`chmod 1777 /tmp`) that the worker `dependsOn` with condition SUCCESS; the root
filesystem stays read-only. Reproduced faithfully with a host directory owned
`root:root 0755` before applying. Lesson: a local stand-in must reproduce the
platform's actual behaviour (here ownership and mode), or the test proves
nothing.

**Interview questions:**
1. *How do you run a container with a read-only root filesystem when the app
   needs scratch space?* Set `readonlyRootFilesystem` and mount a writable
   volume only where needed (on Fargate a task-level ephemeral volume, on
   Kubernetes an `emptyDir`), after testing locally with `docker run
   --read-only --tmpfs /tmp`.
2. *What's the difference between `stopTimeout` and the application's own
   shutdown grace period?* `stopTimeout` is how long ECS waits after SIGTERM
   before SIGKILL; the app's grace period (20 s here) must be shorter so the app
   can finish or hand back its work before being killed.

### Step 6 — Security groups

**Built:** `security.tf`: ALB SG (80 from each `allowed_cidrs` entry; egress
8000 to the API SG only), API SG (8000 from the ALB SG only; egress 443),
worker SG (no inbound; egress 443). `allowed_cidrs` (home IP and dev box IP,
in git-ignored `terraform.tfvars`) has no default, must be valid CIDRs, and
rejects `0.0.0.0/0` / `::/0`. Plan: 30 to add.

**Why / alternatives:**
- *Not open to the internet yet:* the API is unauthenticated; anyone finding
  the ALB could upload 200 MB videos and burn Fargate/Polly/S3 spend. The
  validation makes that a rule, not a comment; later: auth, rate limiting, WAF.
- *SG-to-SG references* (ALB → API on 8000) instead of CIDRs: follows tasks as
  their IPs change, and nothing else in the VPC can reach the API.
- *Egress 443 to 0.0.0.0/0:* on Fargate the ECS agent (ECR pull, logs) uses the
  task ENI; SQS/Polly are public endpoints on large changing ranges. Narrowing
  the destination needs interface endpoints (cost) or prefix lists (S3/DynamoDB
  only). DNS, the ECS credentials endpoint (169.254.170.2) and time sync aren't
  filtered by SGs.
- *One resource per rule* (`aws_vpc_security_group_*_rule`): descriptions per
  rule, and changing one rule doesn't touch the others. Terraform removes AWS's
  default allow-all egress from groups it creates.

**Problems:** None. Noted: the dev box IP is auto-assigned (not an Elastic IP)
and changes on stop/start, and home IPs rotate; update `terraform.tfvars` and
apply when they do (symptom: requests to the ALB time out).

**Interview questions:**
1. *Why reference security groups instead of CIDRs between tiers?* Task IPs
   change constantly; an SG reference allows exactly the members of the source
   group, wherever they are, and nothing else in the subnet.
2. *Your Fargate task can't pull its image but the SG allows the app's
   traffic. What did you miss?* On Fargate the image pull and log delivery use
   the task's own ENI, so the task SG must allow outbound 443 (and the task
   needs a route out: public IP + IGW, NAT, or VPC endpoints for ECR, S3 and
   Logs).

### Step 7 — Load balancer and ECS services

**Built:** `alb.tf` (internet-facing ALB in both public subnets,
`drop_invalid_header_fields`; IP target group on 8000 with `/healthz` health
check and 30 s deregistration delay; HTTP :80 listener) and `services.tf` (api
and worker Fargate services, desired 1, public IPs, rolling deploy 100/200,
circuit breaker with rollback, 30 s health-check grace for the API,
`wait_for_steady_state`, `propagate_tags`). All five resources use
`count = var.enable_compute ? 1 : 0`. Output `api_url`. Plan: 35 to add with
compute, 30 with `enable_compute=false`.

**Why / alternatives:**
- *`count` gate for the pause:* the ALB (~$0.0239/h plus LCUs plus 2 public
  IPs) and running tasks are what cost money when idle; everything else is free
  or near-free at rest. Alternatives: scale services to 0 (the ALB still bills),
  or separate Terraform stacks (more complexity).
- *Rolling 100/200 + circuit breaker:* no capacity drop during deploys, and a
  bad image rolls back automatically instead of crash-looping. Alternatives:
  blue/green with CodeDeploy (traffic shifting, more setup).
- *IP target type:* Fargate tasks register by ENI IP. *30 s deregistration
  delay* instead of 300 s because API requests are milliseconds long.
- *`depends_on` the listener:* ECS rejects a target group not yet attached to a
  load balancer; the target group reference alone doesn't order it after the
  listener.
- *HTTPS* (ACM + domain, 80 → 443 redirect, WAF) is the production upgrade.

**Problems:** None. Phase 5 note: autoscaling will need
`ignore_changes = [desired_count]` on the services.

**Interview questions:**
1. *What does the ECS deployment circuit breaker do?* It watches a rolling
   deployment; if new tasks repeatedly fail to start or fail health checks, it
   marks the deployment failed and (with rollback enabled) returns the service
   to the last steady-state task definition, instead of retrying forever.
2. *Why set `health_check_grace_period_seconds` on an ECS service behind an
   ALB?* New tasks need time to start; without a grace period, early failed
   load balancer health checks can make ECS kill tasks before they're ready,
   causing a restart loop.

### Step 8 — Full plan and cost

**Built:** The full Phase 4 plan, saved to `phase4.tfplan`: 35 to add
(network 10, IAM 6, logs+cluster 3, task definitions 2, security groups 9, ALB
3, services 2), 0 to change, 0 to destroy; the 20 existing resources (Phase 2
plus ECR) are no-ops. With `enable_compute=false` it would be 30.

**Why / alternatives:** Reviewing defaults surfaced: `aws_default_security_group`
adopts (not creates) the VPC default SG; the S3 gateway endpoint policy is full
access by default (hardening: allow only our bucket and the ECR layer bucket);
ECS exec off and ALB desync mitigation "defensive" are good defaults.

*Running cost (approximate, ap-south-1, on-demand; verify on the pricing
pages):* worker 2 vCPU/4 GB ~$0.10/h, API 0.25 vCPU/0.5 GB ~$0.012/h, ALB
~$0.024/h plus LCUs (near zero idle), 4 public IPv4 (2 ALB + 2 tasks) $0.02/h
→ ~$0.16/h, ~$3.75/day, ~$110/month if left on 24/7. Paused: ECR storage
(~0.55 GB) plus idle S3/DynamoDB/SQS/logs, roughly $0.10/month. Per job: Polly
neural is the main variable cost (~$0.006 for the 29 s sample).

**Problems:** None.

**Interview questions:**
1. *What dominates the cost of a small Fargate stack, and how do you cut it?*
   vCPU and memory hours of running tasks, then the ALB's hourly charge and
   public IPv4 addresses. Right-size tasks from measurements, scale workers to
   zero when the queue is empty (Phase 5), pause dev at night, consider Fargate
   Spot or ARM (Graviton) for workers.
2. *Why does the AWS default security group appear as "create" in a Terraform
   plan?* `aws_default_security_group` is a special resource that adopts the
   existing default SG and enforces the rules you declare (here none); destroying
   it only removes it from state.

### Step 9 — Verification on Fargate

**Built / verified:**
- *9a:* both services steady (desired 1 / running 1, rollout COMPLETED); API
  target healthy; real SGs have exactly the 6 declared rules (no default
  allow-all egress).
- *9b:* `/healthz` via the ALB: 200 in 4 ms; the API task's public IP on 8000
  times out (SG allows only the ALB).
- *9c:* `API_URL=<alb> scripts/e2e.sh` passed: pending → processing (+2.1 s)
  → done (+8.2 s), duplicate skipped (read from CloudWatch). Proof it ran on
  Fargate with the task role: CloudTrail shows all 7 Polly calls by
  `assumed-role/reelops-dev-worker-task/<ecs-task-id>` from the worker task's
  public IP; ECS shows the log stream's task is FARGATE, `reelops-dev-worker:2`,
  and its private IP matches the worker ID in the log.
- *9d:* Fargate stages (2 vCPU): audio 0.1 s, transcribe 0.8 s, captions 0.0 s,
  voiceover 1.6 s, render 3.2 s (dev box: 0.1 / 2.3 / 0.0 / 1.9 / 7.1). Cold
  start 26.3 s from task created to polling: provisioning 11.4 s, image pull
  (481 MB) 8.6 s, init-tmp + container start 5.6 s, imports + model load
  0.5 s. Model load is negligible; Phase 5's scale-from-zero latency is
  dominated by Fargate provisioning and the image pull.
- *9e:* pause = `terraform apply -var enable_compute=false` (plan: exactly 5
  to destroy); resume = `terraform apply`.

**Why / alternatives:** Logs can't prove *which identity* made calls (botocore's
container credential provider logs nothing at INFO, unlike the instance-role
provider), so CloudTrail's `userIdentity` is the authoritative proof. Image
size matters for cold start: shrinking the worker image (static ffmpeg,
smaller base) or keeping one warm task are the levers for Phase 5.

**Problems:**
- *Read-only root + Fargate volume permissions:* the worker failed every job
  with "No usable temporary directory": Fargate creates the task volume as
  `root:root 0755`, unlike Docker's local `--tmpfs` (1777). Fixed with an
  init container (`chmod 1777 /tmp`, worker `dependsOn` SUCCESS); reproduced
  and verified locally with a `root:root 0755` host directory before applying.
  The failed test job behaved as designed: 3 attempts, status `failed` with
  the error, message to the DLQ, alarm email, then purged.
- *My verification scripts:* `filter-log-events` auto-paginates in text mode
  and printed an extra `None` per empty page, corrupting a variable; fixed by
  filtering `None` and taking the first line.
- A rollout showed IN_PROGRESS for a few seconds after the apply; ECS marks a
  deployment COMPLETED shortly after the old task stops.

**Interview questions:**
1. *How do you prove a container used its task role rather than some other
   credentials?* Check CloudTrail: `userIdentity.arn` shows
   `assumed-role/<task-role>/<task-id>` and `sourceIPAddress` the task's IP.
   Inside the task, `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` being set and
   `boto3.Session().get_credentials().method == "container-role"` confirm the
   source.
2. *What makes up a Fargate task's cold start, and how do you shorten it?*
   Capacity provisioning and ENI attachment, image pull, container start and
   app initialisation. Shrink the image (and use the same region / gateway
   endpoint for ECR layers), use SOCI lazy loading for large images, keep
   init fast, or keep a minimum number of warm tasks.

### Step 10 — Commit and push

**Built:** One Conventional Commit per Phase 4 step, with the two fixes found
along the way as separate `fix:` commits (worker AbortMultipartUpload
permission; Fargate `/tmp` init container), pushed to `main`. Git-ignored and
not committed: `terraform.tfvars` (email, IPs), `images.auto.tfvars`, saved
`*.tfplan` files.

**Why / alternatives:** Files that changed in several steps (`variables.tf`,
`outputs.tf`, `iam_ecs.tf`, `task_definitions.tf`) were staged at each step's
content, and every intermediate commit was checked with `terraform validate`
in a temporary worktree, so each commit is a working state.

**Problems:** None.

**Interview questions:**
1. *Why keep fixes as separate commits instead of squashing them into the
   feature?* The history records what broke and why (useful for reviews,
   `git blame`, and post-incident learning), and a fix can be reverted or
   cherry-picked on its own.
2. *How do you keep IP allowlists and other environment values out of a public
   repo while still versioning the infrastructure?* Commit the variable
   declarations and a `.tfvars.example`; keep real values in git-ignored tfvars
   locally and in CI secrets/variables (`TF_VAR_*`), or in SSM/Secrets Manager.

---

## Phase 5 — Worker autoscaling on SQS backlog

### Step 1 — Scalable target

**Built:** `autoscaling.tf`: an Application Auto Scaling target for the worker
service (`ecs:service:DesiredCount`, min 0, max 3), gated by `enable_compute`;
`lifecycle { ignore_changes = [desired_count] }` on the worker service.
Plan: 1 to add.

**Why / alternatives:**
- *ignore_changes:* Terraform and the autoscaler both write `desired_count`.
  Without it, any later apply would reset the autoscaler's value to the config
  (stopping busy workers after a scale-out, or starting one after scale-in).
  Now the config value only applies when the service is created (e.g. resume:
  one warm worker, scaled in after 10 idle minutes).
- *Service-linked role:* Application Auto Scaling uses
  `AWSServiceRoleForApplicationAutoScaling_ECSService`, created on first use.
- Alternatives: ECS capacity providers (cluster-level, for EC2 capacity), or a
  custom scaler (e.g. Lambda reading the queue), more code to own.

**Problems:** None. Proved `ignore_changes` by planning a scratch copy with
`desired_count = 3`: 0 changes to the worker service.

**Interview questions:**
1. *Why use `ignore_changes = [desired_count]` with ECS service autoscaling?*
   Both Terraform and Application Auto Scaling set the field; without ignoring
   it, every apply reverts the autoscaler's decision, causing unnecessary task
   churn or capacity at the wrong time.
2. *What does a scalable target define?* The resource and dimension
   (`ecs:service:DesiredCount`) Application Auto Scaling may change, and the
   min/max bounds; policies and alarms decide when and by how much.

### Step 2 — Backlog metric and scaling alarms

**Built:** Two CloudWatch alarms in `autoscaling.tf` (gated by
`enable_compute`), both on metric math `backlog = visible + inflight`
(`ApproximateNumberOfMessagesVisible` + `...NotVisible`, 60 s, Maximum):
scale-out at backlog >= 1 for 1 period (missing = notBreaching); scale-in at
backlog <= 0 for 10 consecutive periods (missing = breaching). Actions are
attached in Step 3. Plan: 3 to add. The expression was tested against real
CloudWatch data with `get-metric-data`.

**Why / alternatives:**
- *In-flight must count:* when a worker takes the last job, "visible" drops to
  0 while it's still processing; scaling in on visible alone would SIGTERM a
  busy worker. The real data showed it: the failed `/tmp` job was in flight
  for 15 minutes with visible = 0.
- *Maximum, not Average:* an 8 s job still registers 1 for its minute.
- *Missing data:* SQS stops publishing metrics for inactive queues, so for
  scale-in "no data" must mean idle (breaching), or the alarm sits in
  INSUFFICIENT_DATA and the worker never reaches 0; for scale-out, no data must
  never start tasks (notBreaching).
- *10 minutes before scale-in* avoids flapping (each scale-from-zero costs a
  ~26 s cold start).
- *Caveat:* after long inactivity SQS metrics can take up to ~15 minutes to
  resume, so the first job after a quiet period may wait for the scale-out
  alarm. Fixes for later: the API triggers scale-out directly, a custom metric
  published on job creation, or min 1 during working hours.

**Problems:** None.

**Interview questions:**
1. *Why scale SQS consumers on visible + in-flight messages rather than visible
   alone?* Visible messages drop to zero as soon as workers pick them up, while
   the work is still running; scaling in on that would kill busy workers. The
   sum is the number of unfinished messages.
2. *How should `treat_missing_data` be set for alarms on SQS metrics?* Idle
   queues may stop publishing metrics, so decide per alarm what "no data"
   means: breaching for scale-to-zero (idle), notBreaching for scale-out and
   for failure alerts like the DLQ alarm.

### Step 3 — Step scaling policies

**Built:** Two step scaling policies (ExactCapacity) wired to the Step 2
alarms: scale-out (backlog 1-2 → 1 task, 3-5 → 2, 6+ → 3; cooldown 60 s)
and scale-in (any value → 0; cooldown 300 s). Plan: 5 to add.

**Why / alternatives:**
- *Target tracking can't reach zero:* it tracks a per-task metric (CPU,
  backlog per task); at 0 tasks that metric doesn't exist, so it has no signal
  to scale out again, and it is designed to keep, not remove, the last task.
  Step scaling on alarms over the *queue* metric works at 0 tasks.
- *Step bounds* are relative to the alarm threshold (lower inclusive, upper
  exclusive): with threshold 1, backlog 1-2 is [0,2), 3-5 is [2,5), 6+ is [5,∞).
- *Scale-in step bounds (corrected):* I first wrote a single step with no bounds,
  reasoning that the alarm can be in ALARM on missing data and an unbounded step
  would always match. The API rejects that ("Both lower and upper bounds of a
  step adjustment cannot be left unspecified"); the step is now
  `metric_interval_upper_bound = 0`, i.e. (-inf, 0] relative to the threshold
  (below the threshold the upper bound is inclusive). Open question for the
  load test: how the policy behaves when the alarm fires on missing data.
- *ExactCapacity re-applied every minute while in ALARM* means the scale-out
  policy also lowers capacity as the backlog shrinks (e.g. 3 → 1). ECS may then
  stop a busy task (it hands its job back on SIGTERM, but work is lost), so
  Step 4 adds task scale-in protection.
- Alternatives: target tracking on a custom "backlog per task" metric for the
  1..N range plus a separate rule for 0; or KEDA-style scalers on Kubernetes.

**Problems:** None. Checked by text that each alarm points to its own policy
(the plan shows `alarm_actions` only as "known after apply").

**Interview questions:**
1. *Why can't ECS target tracking scale a service to zero and back?* Target
   tracking needs a per-task metric; with no tasks there's no metric (CPU) or
   it's undefined (backlog ÷ 0 tasks), so nothing triggers a scale-out from 0.
   Use step scaling on a queue-level alarm instead.
2. *What does a step scaling cooldown do?* After a scaling activity it blocks
   further activity from that policy (for scale-out, smaller or equal
   adjustments) for the cooldown period, so new tasks have time to start and
   affect the metric before the policy acts again.

### Step 4 — Task scale-in protection

**Built:** `worker/reelops_worker/protection.py`: the worker PUTs
`$ECS_AGENT_URI/task-protection/v1/state` (`ProtectionEnabled`, 60-minute
expiry) right after claiming a job and clears it on every exit path (done,
failed, retry, lost lease, SIGTERM hand-back); best-effort, disabled without
`ECS_AGENT_URI`. IAM: `ecs:UpdateTaskProtection` on
`task/reelops-dev/*` only. Tests: a fake agent HTTP server on loopback
(15 new tests; 71 total). Committed locally, pushed `reelops-worker:028d3a5`.

**Why / alternatives:**
- *Why:* with ExactCapacity re-applied every minute, capacity follows the
  backlog down (3 → 1); without protection ECS may stop a busy task, wasting
  its work (it hands the job back on SIGTERM). Protected tasks are skipped by
  scale-in and wait during deployments.
- *Expiry as a safety net:* a worker that dies holding protection doesn't pin
  its task forever. Long jobs could renew it from the heartbeat (future).
- *Best-effort:* protection must never be the reason a job fails.
- *IAM:* the agent calls the ECS API with the task role, so the task role needs
  `ecs:UpdateTaskProtection`; we never read protection, so no
  `ecs:GetTaskProtection`. Simulator 7/7; real confirmation in the load test.
- Alternatives: a longer scale-in interval only (doesn't protect busy tasks),
  or a queue-per-worker design (complex).

**Problems:** None. A mutation check (removing the `protected()` wrapper)
made 3 of 4 consumer protection tests fail, so they guard the behaviour.
Committed the worker change before pushing because `push_images.sh` refuses a
dirty `worker/` (the SHA tag must describe the code); GitHub push still waits
for Step 8. The scan-polling loop in `push_images.sh` ran for real this time.

**Interview questions:**
1. *How do you stop ECS from killing a busy worker during scale-in?* Use ECS
   task scale-in protection: the task sets protection through the agent
   endpoint while it has work and clears it after; scale-in only stops
   unprotected tasks. Give the task role `ecs:UpdateTaskProtection` and set an
   expiry as a safety net.
2. *Why make a side concern like task protection best-effort?* It improves
   efficiency but isn't required for correctness (jobs are already safe to hand
   back), so a failure should log a warning, not fail the job.

### Step 5 — CloudWatch dashboard

**Built:** `dashboard.tf`: dashboard `reelops-dev` (gated by `enable_compute`)
with 6 widgets: jobs backlog (visible + in flight, threshold line), worker
tasks running, DLQ depth, API 5xx (target and ALB), API target response time
(p50/p99), worker CPU (avg/max). Output `dashboard_url`. Free tier (3
dashboards, 50 metrics each); this one uses 11 metrics.

**Why / alternatives:**
- *Running tasks without Container Insights:* `RunningTaskCount` needs
  Insights (billed). The `SampleCount` of the service's `CPUUtilization` is one
  per running task per minute; verified against history (exactly 2 during the
  minutes two worker tasks overlapped in a deployment, 1 otherwise).
  `FILL(…, 0)` turns "no tasks, no data" into a visible 0.
- *Desired count* isn't published as a metric without Insights; the load test
  reads it from the ECS API.
- Alternatives: Container Insights (per-task detail, cost), Grafana/Prometheus
  (more to run), or embedding these graphs in the README via snapshots.

**Problems:** None. Metric math expressions checked with `get-metric-data`
before apply (CloudWatch has no validate-only API for dashboards).

**Interview questions:**
1. *How can you count running ECS tasks without Container Insights?* Use the
   `SampleCount` statistic of the service's `CPUUtilization` (one sample per task
   per period), or read `runningCount` from `DescribeServices`; wrap the metric
   with `FILL(m, 0)` so zero tasks shows as 0 instead of a gap.
2. *What belongs on an operations dashboard for a queue-driven worker?* The
   scaling signal (backlog incl. in-flight), capacity (running tasks), failures
   (DLQ depth, 5xx), latency (response time p50/p99) and saturation (CPU), so
   you can see cause and effect together.

### Step 6 — Phase 5 plan

**Built:** Saved plan `phase5.tfplan`: 7 to add (scalable target, 2 step
policies, 2 backlog alarms, dashboard), 2 in place (worker service: only
`task_definition` → new revision; worker task role policy: adds
`ecs:UpdateTaskProtection`), 1 replace (worker task definition, image
`41abfb9` → `028d3a5`; the "destroy" deregisters revision 2). 52 resources
unchanged, including the API, ALB and data layer.

**Why / alternatives:** The plan JSON's `after_unknown` explained an update with
"no changed attributes": the new task definition ARN is only known after
apply. Expected after apply: the worker rolls to revision 3; with an empty
queue the scale-in alarm reaches ALARM after 10 minutes and the service goes to
0. Pause now removes 11 resources (5 compute + target, 2 policies, 2 alarms,
dashboard). Cost: alarms fit the free tier (10 alarm metrics), dashboard free,
Application Auto Scaling free; an idle worker now costs nothing.

**Problems:** The apply partly failed: the scale-in policy was rejected with
"ValidationException: Both lower and upper bounds of a step adjustment cannot be
left unspecified", so its alarm (which references the policy) wasn't created
either; everything else was. My Step 3 claim that a single unbounded step was
allowed was wrong, and `terraform validate`/`plan` can't catch it (the provider
accepts it; only the AWS API rejects it). Fixed with
`metric_interval_upper_bound = 0`. A saved plan can't be reused after a partial
apply (state changed), so the stale `phase5.tfplan` was deleted and a fresh
plan made: 2 to add, 0 to change, 0 to destroy. Meanwhile the worker simply
stayed at desired 1 (scale-out policy present, no scale-in).

**Interview questions:**
1. *A Terraform plan shows a resource "updated in-place" but no attribute
   changes. Why?* The changed value is unknown until apply (e.g. a new ARN from
   a replaced dependency), so it appears as "(known after apply)"; in the JSON
   plan it's listed in `after_unknown`, not `after`.
2. *What happens to an ECS service's running tasks when its task definition
   changes?* ECS starts a rolling deployment to the new revision (within
   min/max healthy percent), replacing tasks; with scale-in protection, a
   protected task isn't replaced until its protection is cleared or expires.

### Step 7 — Load test: scale from 0 and back

**Built:** `scripts/load_test.sh` (submit N jobs through the ALB, sample queue
and task counts every 15 s to `samples/output/scaling.csv`, then compute exact
timings from ECS task timestamps, job `updated_at` and Application Auto Scaling
activities; `DRY_RUN=1` mode) and `scripts/plot_scaling.py` (chart, run with
matplotlib in a throwaway container). Results for 8 jobs on an idle stack
(first upload 16:13:42 UTC): all 8 done on the first attempt, 0 failed.
- *Cold start from 0:* 201.7 s from first upload to first worker task started.
- *Peak:* 3 running tasks at +204.5 s (scaled 0 → 3 in one step: backlog 8
  is in the 6+ band).
- *All jobs finished:* +233.0 s (about 30 s after the workers started).
- *Queue empty → desired 0:* 707.6 s; tasks fully stopped ~40 s later.
- *Task protection works on AWS:* 8 "task protection on" / 8 "off" log lines,
  one pair per job across the 3 tasks, no AccessDenied (the simulator couldn't
  prove ECS accepts the `task/reelops-dev/*` resource scoping; this did).

**Why / alternatives:** *Where the scale-from-zero latency goes* (exact
timestamps): SQS metric publication + alarm evaluation 166.8 s (83%: uploads at
16:13:42 first appear in the 16:14 data point, which the alarm acted on at
16:16:28), ECS scheduling 11 s, Fargate provisioning + image pull + start 24 s.
So **most of the latency is the SQS → CloudWatch metric delay, not Fargate
start-up**; a smaller image would save seconds, the metric path saves minutes.
Options: the API publishes a high-resolution custom metric or nudges the
service's desired count when it creates a job while the worker is at 0;
scheduled scaling to keep 1 warm worker during working hours; or an
event-driven trigger (EventBridge Pipes/Lambda on the queue). The 10-minute
scale-in window also keeps 3 idle tasks for ~12 minutes after a burst (about
$0.06), the price of not flapping.

**Problems:**
- *The user's run stalled* at 16:25:34 (CSV stopped growing; API, ECS and IP
  all fine, so the script process in the terminal stopped advancing) and never
  wrote its report. No second run: the four measurements were computed from
  AWS records with the script's own report code, and the chart's tail (after
  16:25:34) was reconstructed from ECS/App Auto Scaling records into
  `scaling_full.csv` and shaded in the PNG. Hardening: `curl` timeouts and a
  tmux/nohup note.
- *I overwrote the user's `scaling.csv`* with a `DRY_RUN` check (dry run
  started a fresh CSV). Restored all 43 rows exactly from `scaling_full.csv`;
  dry runs now write `scaling_dryrun.csv`.
- My `python -I` in the plot container ignored the `pip --user` install.
- Not exercised: stepping down 3 → 2 → 1 while busy (all 8 jobs finished within
  ~30 s, faster than the ~2.5-minute metric loop), so the case protection most
  matters for didn't occur; protection on/off itself was proven.

**Interview questions:**
1. *Your queue-based autoscaler takes 3 minutes to start the first worker. Where
   does the time go and how do you cut it?* Measure each segment with exact
   timestamps: here 83% was SQS metrics reaching CloudWatch and the alarm
   evaluating, not container start. Cut it by signalling scale-out directly
   (custom high-resolution metric or an UpdateService/desired-count nudge from
   the producer), keeping a warm minimum during busy hours, or event-driven
   triggers; image size and Fargate start-up are second-order.
2. *How do you load-test autoscaling credibly?* Start from a known idle state,
   generate a burst, sample queue depth and desired/running counts, and compute
   the key intervals (time to first worker, peak, drain time, time back to
   zero) from authoritative timestamps (task start/stop, scaling activities,
   job completion) rather than from coarse polling.

### Step 8 — Commit and push

**Built:** Conventional Commits for Phase 5, one per step, with the scale-in
step bound as its own `fix:` commit; the worker task-protection commit (made
locally in Step 4 so the image tag matched committed code) went out in the
same push. Not committed: `samples/output/` (CSV, report), `*.tfplan`,
`images.auto.tfvars`, `terraform.tfvars`.

**Why / alternatives:** `autoscaling.tf` changed in Steps 1, 2, 3 and in the
fix, so each commit stages that step's version (rebuilt from the final file)
and every intermediate commit is checked with `terraform validate`; note that
`validate` passes even for the pre-fix scale-in step, because only the AWS API
rejects it.

**Problems:** None.

**Interview questions:**
1. *Why commit before building an image whose tag is the commit SHA?* So the
   tag identifies exactly the code inside the image; building from uncommitted
   changes would make the tag lie and break traceability and rollbacks.
2. *Can `terraform validate` and `plan` catch every invalid configuration?* No:
   they check syntax, types and provider-side schema; many constraints are
   enforced only by the cloud API at apply time (like Application Auto
   Scaling's step bounds), so applies can still fail partway.
