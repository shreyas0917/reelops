// Maps where a job is to what the page shows: the stage message, the
// four-step progress row and the status chip in "Your videos".

export type Phase = "empty" | "uploading" | "queued" | "processing" | "done" | "failed";
export type StepId = "uploaded" | "waiting" | "processing" | "ready";
export type StepState = "todo" | "active" | "done" | "failed";

export const STEPS: { id: StepId; label: string }[] = [
  { id: "uploaded", label: "Uploaded" },
  { id: "waiting", label: "Waiting for a worker" },
  { id: "processing", label: "Processing" },
  { id: "ready", label: "Ready" },
];

/** After this long in the queue, explain that a worker is starting from zero. */
export const SLOW_QUEUE_MS = 30_000;

/** API job status -> phase. Unknown statuses count as still waiting. */
export function phaseFromStatus(status: string): Phase {
  switch (status) {
    case "processing":
      return "processing";
    case "done":
      return "done";
    case "failed":
      return "failed";
    default:
      return "queued";
  }
}

export type ChipTone = "ready" | "queued" | "processing" | "failed";

/** Status chip in "Your videos". */
export function chipFor(status: string): { label: string; tone: ChipTone } {
  switch (status) {
    case "pending":
      return { label: "Queued", tone: "queued" }; // uploading, or waiting for a worker
    case "done":
      return { label: "Ready", tone: "ready" };
    case "failed":
      return { label: "Failed", tone: "failed" };
    default:
      return { label: "Processing", tone: "processing" };
  }
}

const STEP_OF: Partial<Record<Phase, StepId>> = {
  uploading: "uploaded",
  queued: "waiting",
  processing: "processing",
  done: "ready",
};

/** State of each step for a phase; `failedAt` marks where a failed job stopped. */
export function stepStates(phase: Phase, failedAt?: StepId): StepState[] {
  const ids = STEPS.map((s) => s.id);
  if (phase === "done") return ids.map(() => "done");
  if (phase === "failed") {
    const f = failedAt ? ids.indexOf(failedAt) : -1;
    return ids.map((_, i) => (f < 0 ? "todo" : i < f ? "done" : i === f ? "failed" : "todo"));
  }
  const step = STEP_OF[phase];
  if (!step) return ids.map(() => "todo");
  const c = ids.indexOf(step);
  return ids.map((_, i) => (i < c ? "done" : i === c ? "active" : "todo"));
}

export interface StageMessage {
  title: string;
  detail?: string;
}

/** Headline and explanation shown on the dark stage while a job is under way. */
export function stageMessage(phase: Phase, opts: { progress?: number; queuedForMs?: number } = {}): StageMessage {
  switch (phase) {
    case "uploading":
      return {
        title: `Uploading ${Math.floor(opts.progress ?? 0)}%`,
        detail: "Keep this page open until the upload finishes.",
      };
    case "queued":
      return (opts.queuedForMs ?? 0) > SLOW_QUEUE_MS
        ? {
            title: "Starting a worker",
            detail:
              "Workers scale down to zero when idle, so the first job after a quiet spell waits about 3 minutes for one to start. Later jobs start right away.",
          }
        : { title: "Waiting for a worker", detail: "You can close this page. The job keeps running." };
    case "processing":
      return {
        title: "Transcribing, captioning and voicing",
        detail: "Usually about as long as the recording itself. You can close this page.",
      };
    case "done":
      return { title: "Ready" };
    case "failed":
      return { title: "This video didn't finish" };
    case "empty":
      return { title: "Drop a screen recording" };
  }
}

/** Server-side job error -> what went wrong and how to fix it. */
export function failureMessage(serverError: string | null | undefined): string {
  const e = (serverError ?? "").toLowerCase();
  if (e.includes("no audio stream")) {
    return "This recording has no sound. Record it again with your microphone on, then upload it.";
  }
  if (e.includes("no speech detected")) {
    return "No speech was found in this recording. Narrate while you record, then upload it again.";
  }
  if (e.includes("too large")) {
    return "That recording is over 200 MB. Trim it or record a shorter one, then upload it.";
  }
  if (e.includes("isn't an mp4, mov or webm")) {
    return "That file isn't a video ReelOps can read. Export it as MP4, MOV or WebM, then upload it.";
  }
  if (e.includes("gave up after")) {
    return "Processing failed three times. Wait a few minutes, then upload the recording again.";
  }
  return serverError ? `Processing failed: ${serverError}` : "Processing failed. Upload the recording again.";
}
