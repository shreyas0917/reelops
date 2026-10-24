import { useCallback, useEffect, useRef, useState } from "react";

import { RecentJobs } from "./components/RecentJobs";
import { Screen } from "./components/Screen";
import { Timeline } from "./components/Timeline";
import { createJob, getJob, uploadFile, UserFacingError, type Job } from "./lib/api";
import { loadRecent, upsertRecent, type RecentJob } from "./lib/recent";
import { failureMessage, phaseFromStatus, type Phase, type StageId, type View } from "./lib/status";
import { validateFile } from "./lib/validate";

const POLL_MS = 2000;
const ACCEPT = ".mp4,.mov,.webm,video/mp4,video/quicktime,video/webm";

interface Current {
  id: string;
  title: string;
  queuedSince: number; // when it entered the queue (ms)
}

function messageOf(error: unknown): string {
  return error instanceof UserFacingError ? error.message : "Something stopped this job. Choose the recording again.";
}

export function App() {
  const [phase, setPhase] = useState<Phase>("empty");
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<string>();
  const [failedAt, setFailedAt] = useState<StageId>();
  const [dragging, setDragging] = useState(false);
  const [current, setCurrent] = useState<Current | null>(null);
  const [job, setJob] = useState<Job | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const [recent, setRecent] = useState<RecentJob[]>(() => loadRecent());
  const input = useRef<HTMLInputElement>(null);

  const busy = phase === "uploading" || phase === "queued" || phase === "processing";

  const fail = useCallback((message: string, stage?: StageId) => {
    setError(message);
    setFailedAt(stage);
    setPhase("failed");
  }, []);

  const remember = useCallback((entry: RecentJob) => setRecent((jobs) => upsertRecent(jobs, entry)), []);

  const applyJob = useCallback(
    (j: Job, title: string) => {
      setJob(j);
      remember({ id: j.job_id, title, status: j.status, createdAt: j.created_at * 1000 });
      const next = phaseFromStatus(j.status);
      if (next === "failed") fail(failureMessage(j.error), "processing");
      else setPhase(next);
    },
    [fail, remember],
  );

  async function start(file: File) {
    const check = validateFile(file.name, file.size);
    if (!check.ok) return fail(check.error);
    setError(undefined);
    setFailedAt(undefined);
    setJob(null);
    setProgress(0);
    setPhase("uploading");
    try {
      const created = await createJob(file.name, check.contentType, file.size);
      setCurrent({ id: created.job_id, title: file.name, queuedSince: Date.now() });
      remember({ id: created.job_id, title: file.name, status: "pending", createdAt: Date.now() });
      await uploadFile(created.upload_url, file, created.upload_headers, setProgress).done;
      setCurrent({ id: created.job_id, title: file.name, queuedSince: Date.now() });
      setPhase("queued");
    } catch (e) {
      fail(messageOf(e), "upload");
    }
  }

  async function open(entry: RecentJob) {
    if (busy && entry.id === current?.id) return;
    setError(undefined);
    setFailedAt(undefined);
    setJob(null);
    try {
      const j = await getJob(entry.id);
      setCurrent({ id: j.job_id, title: entry.title, queuedSince: j.updated_at * 1000 });
      applyJob(j, entry.title);
    } catch (e) {
      setCurrent({ id: entry.id, title: entry.title, queuedSince: Date.now() });
      fail(messageOf(e));
    }
  }

  function reset() {
    setPhase("empty");
    setError(undefined);
    setFailedAt(undefined);
    setJob(null);
    setCurrent(null);
    setProgress(0);
  }

  // Poll while the job waits or runs.
  useEffect(() => {
    if (!current || (phase !== "queued" && phase !== "processing")) return;
    let stopped = false;
    const tick = async () => {
      try {
        const j = await getJob(current.id);
        if (!stopped) applyJob(j, current.title);
      } catch {
        // Transient: keep polling; the caption keeps its last state.
      }
    };
    const timer = window.setInterval(tick, POLL_MS);
    void tick();
    return () => {
      stopped = true;
      window.clearInterval(timer);
    };
  }, [current, phase, applyJob]);

  // A clock for "queued for more than 30 s".
  useEffect(() => {
    if (phase !== "queued") return;
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [phase]);

  const view: View = {
    phase,
    progress,
    error,
    failedAt,
    dragging,
    queuedForMs: phase === "queued" && current ? now - current.queuedSince : 0,
  };

  return (
    <main className="page">
      <p className="wordmark">ReelOps</p>

      <div className="intro">
        <h1>
          Turn a screen recording into a captioned, <span className="nowrap">AI-voiced</span> demo.
        </h1>
        <p>Drop a narrated recording on the screen. ReelOps transcribes it, burns in captions and re-voices it.</p>
      </div>

      <Screen
        key={current?.id ?? "empty"}
        view={view}
        videoUrl={job?.preview_url ?? null}
        canDrop={!busy}
        pickOnClick={phase === "empty" || phase === "failed"}
        onFile={start}
        onDraggingChange={setDragging}
        onPick={() => input.current?.click()}
      />

      <input
        ref={input}
        type="file"
        accept={ACCEPT}
        className="visually-hidden"
        tabIndex={-1}
        aria-hidden="true"
        onChange={(e) => {
          const file = e.target.files?.[0];
          e.target.value = ""; // allow choosing the same file again
          if (file) void start(file);
        }}
      />

      <div className="actions">
        {(phase === "empty" || phase === "failed") && (
          <>
            <button type="button" className="button button--primary" onClick={() => input.current?.click()}>
              Choose a recording
            </button>
            <p className="actions__hint">MP4, MOV or WebM, up to 200 MB, with narration.</p>
          </>
        )}
        {phase === "uploading" && <p className="actions__hint">Keep this page open until the upload finishes.</p>}
        {(phase === "queued" || phase === "processing") && (
          <p className="actions__hint">You can close this page. The job keeps running and stays in Recent jobs.</p>
        )}
        {phase === "done" && job?.download_url && (
          <>
            <a className="button button--primary" href={job.download_url} download>
              Download video
            </a>
            <button type="button" className="button" onClick={reset}>
              Make another
            </button>
          </>
        )}
      </div>

      <Timeline view={view} />

      <RecentJobs jobs={recent} currentId={current?.id ?? null} onOpen={open} />

      <p className="footer">Uploads are deleted after 3 days and finished videos after 14 days.</p>
    </main>
  );
}
