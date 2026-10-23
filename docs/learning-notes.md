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
