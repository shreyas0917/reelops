// Maps where a job is to what the screen says and which stage is lit.

export type Phase = "empty" | "uploading" | "queued" | "processing" | "done" | "failed";
export type StageId = "upload" | "queued" | "processing" | "done";
export type StageState = "todo" | "active" | "done" | "failed";

export const STAGES: { id: StageId; label: string }[] = [
  { id: "upload", label: "Upload" },
  { id: "queued", label: "Queued" },
  { id: "processing", label: "Processing" },
  { id: "done", label: "Done" },
];

export const SLOW_QUEUE_MS = 30_000;

export interface View {
  phase: Phase;
  progress?: number; // 0-100 while uploading
  queuedForMs?: number; // time spent queued so far
  error?: string; // already user-facing
  failedAt?: StageId; // stage that failed, if any
  dragging?: boolean;
}

/** API job status -> phase. */
export function phaseFromStatus(status: string): Phase {
  switch (status) {
    case "pending":
      return "queued";
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

export function caption(view: View): string {
  if (view.dragging) return "Drop to upload";
  switch (view.phase) {
    case "empty":
      return "Drop a screen recording here";
    case "uploading":
      return `Uploading ${Math.floor(view.progress ?? 0)}%`;
    case "queued":
      return (view.queuedForMs ?? 0) > SLOW_QUEUE_MS
        ? "Starting a worker. The first job can take about 3 minutes."
        : "Waiting for a worker to start";
    case "processing":
      return "Writing captions and voiceover";
    case "done":
      return "Ready to watch";
    case "failed":
      return view.error ?? "Something stopped this job. Choose the recording again.";
  }
}

const ORDER: StageId[] = ["upload", "queued", "processing", "done"];

function currentStage(phase: Phase): StageId | null {
  switch (phase) {
    case "uploading":
      return "upload";
    case "queued":
      return "queued";
    case "processing":
      return "processing";
    case "done":
      return "done";
    default:
      return null;
  }
}

/** State of one timeline stage for the current view. */
export function stageState(stage: StageId, view: View): StageState {
  const i = ORDER.indexOf(stage);
  if (view.phase === "failed") {
    if (!view.failedAt) return "todo";
    const f = ORDER.indexOf(view.failedAt);
    return i < f ? "done" : i === f ? "failed" : "todo";
  }
  const current = currentStage(view.phase);
  if (current === null) return "todo";
  const c = ORDER.indexOf(current);
  if (view.phase === "done") return "done";
  return i < c ? "done" : i === c ? "active" : "todo";
}

/** Server-side job error -> what went wrong and how to fix it. */
export function failureMessage(serverError: string | null | undefined): string {
  const e = (serverError ?? "").toLowerCase();
  if (e.includes("no audio stream")) {
    return "This recording has no sound. Record it with your microphone on, then drop it here.";
  }
  if (e.includes("no speech detected")) {
    return "No speech was found in this recording. Narrate while you record, then drop it here.";
  }
  if (e.includes("too large")) {
    return "That recording is over 200 MB. Choose a shorter one.";
  }
  if (e.includes("gave up after")) {
    return "Processing failed three times. Wait a few minutes, then drop the recording again.";
  }
  return serverError ? `Processing failed: ${serverError}` : "Processing failed. Drop the recording again.";
}
