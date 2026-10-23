import { describe, expect, it } from "vitest";

import { SLOW_QUEUE_MS, caption, failureMessage, phaseFromStatus, stageState, type View } from "./status";

describe("caption", () => {
  it.each<[View, string]>([
    [{ phase: "empty" }, "Drop a screen recording here"],
    [{ phase: "uploading", progress: 42.7 }, "Uploading 42%"],
    [{ phase: "queued", queuedForMs: 5_000 }, "Waiting for a worker to start"],
    [{ phase: "processing" }, "Writing captions and voiceover"],
    [{ phase: "done" }, "Ready to watch"],
    [{ phase: "failed", error: "The upload link expired." }, "The upload link expired."],
    [{ phase: "empty", dragging: true }, "Drop to upload"],
  ])("%o -> %s", (view, text) => {
    expect(caption(view)).toBe(text);
  });

  it("explains a slow start after 30 s in the queue", () => {
    expect(caption({ phase: "queued", queuedForMs: SLOW_QUEUE_MS })).toBe("Waiting for a worker to start");
    expect(caption({ phase: "queued", queuedForMs: SLOW_QUEUE_MS + 1 })).toBe(
      "Starting a worker. The first job can take about 3 minutes.",
    );
  });
});

describe("phaseFromStatus", () => {
  it("maps API statuses", () => {
    expect(phaseFromStatus("pending")).toBe("queued");
    expect(phaseFromStatus("processing")).toBe("processing");
    expect(phaseFromStatus("done")).toBe("done");
    expect(phaseFromStatus("failed")).toBe("failed");
  });
});

describe("stageState", () => {
  const states = (view: View) =>
    (["upload", "queued", "processing", "done"] as const).map((s) => stageState(s, view));

  it("lights stages in order", () => {
    expect(states({ phase: "empty" })).toEqual(["todo", "todo", "todo", "todo"]);
    expect(states({ phase: "uploading" })).toEqual(["active", "todo", "todo", "todo"]);
    expect(states({ phase: "queued" })).toEqual(["done", "active", "todo", "todo"]);
    expect(states({ phase: "processing" })).toEqual(["done", "done", "active", "todo"]);
    expect(states({ phase: "done" })).toEqual(["done", "done", "done", "done"]);
  });

  it("marks where a job failed", () => {
    expect(states({ phase: "failed", failedAt: "upload" })).toEqual(["failed", "todo", "todo", "todo"]);
    expect(states({ phase: "failed", failedAt: "processing" })).toEqual(["done", "done", "failed", "todo"]);
    expect(states({ phase: "failed" })).toEqual(["todo", "todo", "todo", "todo"]); // validation error
  });
});

describe("failureMessage", () => {
  it("turns worker errors into what happened and what to do", () => {
    expect(failureMessage("input.mp4 has no audio stream. ReelOps needs...")).toMatch(/no sound.*microphone on/);
    expect(failureMessage("no speech detected in input.mp4")).toMatch(/No speech.*Narrate/);
    expect(failureMessage("gave up after 3 attempts: boom")).toMatch(/failed three times/);
    expect(failureMessage("weird")).toBe("Processing failed: weird");
    expect(failureMessage(null)).toMatch(/Drop the recording again/);
  });

  it("never apologises", () => {
    for (const e of ["no audio stream", "no speech detected", "too large", "gave up after", "x", null]) {
      expect(failureMessage(e).toLowerCase()).not.toMatch(/sorry|apolog|oops/);
    }
  });
});
