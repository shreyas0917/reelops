import { describe, expect, it } from "vitest";

import { SLOW_QUEUE_MS, chipFor, failureMessage, phaseFromStatus, stageMessage, stepStates } from "./status";

describe("phaseFromStatus", () => {
  it("maps API statuses", () => {
    expect(phaseFromStatus("pending")).toBe("queued");
    expect(phaseFromStatus("processing")).toBe("processing");
    expect(phaseFromStatus("done")).toBe("done");
    expect(phaseFromStatus("failed")).toBe("failed");
    expect(phaseFromStatus("something-new")).toBe("queued");
  });
});

describe("chipFor", () => {
  it("shows four user-facing states", () => {
    expect(chipFor("pending")).toEqual({ label: "Queued", tone: "queued" });
    expect(chipFor("processing")).toEqual({ label: "Processing", tone: "processing" });
    expect(chipFor("done")).toEqual({ label: "Ready", tone: "ready" });
    expect(chipFor("failed")).toEqual({ label: "Failed", tone: "failed" });
    expect(chipFor("something-new")).toEqual({ label: "Processing", tone: "processing" });
  });
});

describe("stepStates", () => {
  it("lights steps in order", () => {
    expect(stepStates("empty")).toEqual(["todo", "todo", "todo", "todo"]);
    expect(stepStates("loading")).toEqual(["todo", "todo", "todo", "todo"]); // status unknown: claim nothing
    expect(stepStates("uploading")).toEqual(["active", "todo", "todo", "todo"]);
    expect(stepStates("queued")).toEqual(["done", "active", "todo", "todo"]);
    expect(stepStates("processing")).toEqual(["done", "done", "active", "todo"]);
    expect(stepStates("done")).toEqual(["done", "done", "done", "done"]);
  });

  it("marks where a job failed", () => {
    expect(stepStates("failed", "uploaded")).toEqual(["failed", "todo", "todo", "todo"]);
    expect(stepStates("failed", "processing")).toEqual(["done", "done", "failed", "todo"]);
    expect(stepStates("failed")).toEqual(["todo", "todo", "todo", "todo"]); // rejected before upload
  });
});

describe("stageMessage", () => {
  it("doesn't guess a job's state while it loads", () => {
    expect(stageMessage("loading").title).toBe("Loading this video");
  });

  it("shows upload progress as a whole percentage", () => {
    expect(stageMessage("uploading", { progress: 42.7 }).title).toBe("Uploading 42%");
  });

  it("explains the worker start after 30 s in the queue", () => {
    expect(stageMessage("queued", { queuedForMs: SLOW_QUEUE_MS }).title).toBe("Waiting for a worker");
    const slow = stageMessage("queued", { queuedForMs: SLOW_QUEUE_MS + 1 });
    expect(slow.title).toBe("Starting a worker");
    expect(slow.detail).toMatch(/about 3 minutes/);
  });
});

describe("failureMessage", () => {
  it("turns worker errors into what happened and what to do", () => {
    expect(failureMessage("input.mp4 has no audio stream. ReelOps needs...")).toMatch(/no sound.*microphone on/);
    expect(failureMessage("no speech detected in input.mp4")).toMatch(/No speech.*Narrate/);
    expect(failureMessage("upload too large: 300 bytes")).toMatch(/over 200 MB.*Trim/);
    expect(failureMessage("x.mp4 isn't an MP4, MOV or WebM video")).toMatch(/Export it as MP4/);
    expect(failureMessage("gave up after 3 attempts: boom")).toMatch(/failed three times/);
    expect(failureMessage("weird")).toBe("Processing failed: weird");
    expect(failureMessage(null)).toMatch(/Upload the recording again/);
  });

  it("never apologises", () => {
    for (const e of ["no audio stream", "no speech detected", "too large", "gave up after", "x", null]) {
      expect(failureMessage(e).toLowerCase()).not.toMatch(/sorry|apolog|oops/);
    }
  });
});
