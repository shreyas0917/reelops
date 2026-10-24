import { useCallback, useEffect, useRef, useState } from "react";

import { HowItWorks } from "./components/HowItWorks";
import { Stage } from "./components/Stage";
import { TopBar } from "./components/TopBar";
import { UploadCard } from "./components/UploadCard";
import { VideoList } from "./components/VideoList";
import { createJob, getJob, uploadFile, UserFacingError, type Job } from "./lib/api";
import { copyText } from "./lib/clipboard";
import { jobIdFromSearch, withJobId } from "./lib/joblink";
import { probeDuration } from "./lib/media";
import { loadRecent, upsertRecent, type RecentJob } from "./lib/recent";
import { failureMessage, phaseFromStatus, type Phase, type StepId } from "./lib/status";
import { validateFile } from "./lib/validate";

const POLL_MS = 2000;

interface Current {
  id: string;
  title: string;
  queuedSince: number; // when it entered the queue (ms)
}

function messageOf(error: unknown): string {
  return error instanceof UserFacingError ? error.message : "Something stopped this job. Upload the recording again.";
}

/** Keep ?job=<id> in the address bar in step with the selected job, without adding history entries. */
function showJobInUrl(jobId: string | null) {
  const next = withJobId(window.location.href, jobId);
  if (next !== window.location.href) window.history.replaceState(null, "", next);
}

export function App() {
  const [phase, setPhase] = useState<Phase>("empty");
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<string>();
  const [failedAt, setFailedAt] = useState<StepId>();
  const [fileError, setFileError] = useState<string>(); // rejected before upload
  const [current, setCurrent] = useState<Current | null>(null);
  const [job, setJob] = useState<Job | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const [recent, setRecent] = useState<RecentJob[]>(() => loadRecent());
  const opened = useRef(false);

  const fail = useCallback((message: string, stage?: StepId) => {
    setError(message);
    setFailedAt(stage);
    setPhase("failed");
  }, []);

  const remember = useCallback(
    (entry: Partial<RecentJob> & { id: string }) =>
      setRecent((jobs) => {
        const existing = jobs.find((j) => j.id === entry.id);
        return upsertRecent(jobs, { ...(existing ?? { title: "", status: "pending", createdAt: Date.now() }), ...entry });
      }),
    [],
  );

  const applyJob = useCallback(
    (j: Job, fallbackTitle: string) => {
      // The API's name wins: a shared link opened on another device has no local title.
      const title = j.filename || fallbackTitle;
      setJob(j);
      setCurrent((c) => (c && c.id === j.job_id && c.title !== title ? { ...c, title } : c));
      remember({ id: j.job_id, title, status: j.status, createdAt: j.created_at * 1000 });
      const next = phaseFromStatus(j.status);
      if (next === "failed") fail(failureMessage(j.error), "processing");
      else setPhase(next);
    },
    [fail, remember],
  );

  function select(next: Current | null) {
    setCurrent(next);
    setJob(null);
    setError(undefined);
    setFailedAt(undefined);
    setFileError(undefined);
    showJobInUrl(next?.id ?? null);
  }

  async function start(file: File) {
    const check = validateFile(file.name, file.size);
    if (!check.ok) return setFileError(check.error);
    const duration = probeDuration(file); // in parallel; never delays the upload
    select({ id: "", title: file.name, queuedSince: Date.now() }); // no job id until the API answers
    setProgress(0);
    setPhase("uploading");
    let created;
    try {
      created = await createJob(file.name, check.contentType, file.size);
    } catch (e) {
      return fail(messageOf(e), "uploaded");
    }
    const entry: Current = { id: created.job_id, title: file.name, queuedSince: Date.now() };
    select(entry);
    setPhase("uploading");
    remember({ id: entry.id, title: file.name, status: "pending", createdAt: Date.now() });
    void duration.then((durationS) => durationS !== undefined && remember({ id: entry.id, durationS }));
    try {
      await uploadFile(created.upload_url, file, created.upload_headers, setProgress).done;
      setCurrent({ ...entry, queuedSince: Date.now() });
      setPhase("queued");
    } catch (e) {
      remember({ id: entry.id, status: "failed" });
      fail(messageOf(e), "uploaded");
    }
  }

  const open = useCallback(
    async (id: string, title: string) => {
      setCurrent({ id, title, queuedSince: Date.now() });
      setJob(null);
      setError(undefined);
      setFailedAt(undefined);
      setFileError(undefined);
      setPhase("queued");
      showJobInUrl(id);
      try {
        const j = await getJob(id);
        setCurrent({ id, title, queuedSince: j.updated_at * 1000 });
        applyJob(j, title);
      } catch (e) {
        fail(messageOf(e));
      }
    },
    [applyJob, fail],
  );

  function reset() {
    select(null);
    setPhase("empty");
    setProgress(0);
  }

  // A shared link (?job=<id>) opens that job on load, even on another device.
  useEffect(() => {
    if (opened.current) return;
    opened.current = true;
    const id = jobIdFromSearch(window.location.search);
    if (!id) return;
    const known = loadRecent().find((j) => j.id === id);
    void open(id, known?.title ?? `Video ${id.slice(0, 8)}`);
  }, [open]);

  // Poll while the job waits or runs.
  useEffect(() => {
    if (!current?.id || (phase !== "queued" && phase !== "processing")) return;
    let stopped = false;
    const tick = async () => {
      try {
        const j = await getJob(current.id);
        if (!stopped) applyJob(j, current.title);
      } catch {
        // Transient: keep polling; the stage keeps its last state.
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

  const selected = current ? recent.find((j) => j.id === current.id) : undefined;

  return (
    <>
      <TopBar />
      <main className="page" id="main" tabIndex={-1}>
        <div className="intro">
          <h1>Narrated screen recordings, finished as captioned demos.</h1>
          <p>Upload a narrated recording. ReelOps transcribes it, burns in captions and <span className="nowrap">re-voices it.</span></p>
        </div>

        <div className="workspace" data-has-job={Boolean(current)}>
          <div className="sidebar">
            <UploadCard large={!current} disabled={phase === "uploading"} error={fileError} onFile={start} />
            <VideoList jobs={recent} selectedId={current?.id || null} onOpen={(j) => void open(j.id, j.title)} />
          </div>
          <div className="main-col">
            {current ? (
              <Stage
                key={current.id || "upload"}
                title={current.title}
                durationS={selected?.durationS}
                phase={phase}
                job={job}
                progress={progress}
                queuedForMs={phase === "queued" ? Math.max(0, now - current.queuedSince) : 0}
                error={error}
                failedAt={failedAt}
                onDuration={(durationS) => remember({ id: current.id, durationS })}
                onReset={reset}
                onCopyLink={() => copyText(withJobId(window.location.href, current.id))}
              />
            ) : (
              <HowItWorks />
            )}
          </div>
        </div>

        {current && <HowItWorks />}

        <p className="footnote">Uploads are deleted after 3 days and finished videos after 14 days.</p>
      </main>
    </>
  );
}
