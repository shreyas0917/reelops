import { describe, expect, it } from "vitest";

import { JobNotFound, UserFacingError } from "./api";
import { NOTICE_AFTER_FAILURES, POLL_MS, isFatalPollError, nextFailureCount, showConnectionNotice } from "./poll";

/** Failure counts after each poll in a sequence of outcomes. */
const run = (outcomes: boolean[]) =>
  outcomes.reduce<number[]>((acc, ok) => [...acc, nextFailureCount(acc.at(-1) ?? 0, ok)], []);

describe("poll tolerance", () => {
  it("rides out drill 5's outage (10 x 503 over 20 s) without a notice", () => {
    const counts = run([true, ...Array(10).fill(false), true]);
    expect(counts.some(showConnectionNotice)).toBe(false);
    expect(counts.at(-1)).toBe(0); // recovered: counter reset
  });

  it("shows the notice after ~30 s of consecutive failures, and clears it on success", () => {
    expect(NOTICE_AFTER_FAILURES * POLL_MS).toBe(30_000);
    const counts = run([...Array(NOTICE_AFTER_FAILURES).fill(false), true]);
    expect(showConnectionNotice(counts[NOTICE_AFTER_FAILURES - 2])).toBe(false);
    expect(showConnectionNotice(counts[NOTICE_AFTER_FAILURES - 1])).toBe(true);
    expect(showConnectionNotice(counts.at(-1)!)).toBe(false);
  });

  it("needs the failures to be consecutive", () => {
    const flapping = run(Array.from({ length: 60 }, (_, i) => i % 5 === 0)); // 4 of every 5 fail, for 2 minutes
    expect(flapping.some(showConnectionNotice)).toBe(false);
  });

  it("treats only a missing job as fatal", () => {
    expect(isFatalPollError(new JobNotFound("That job no longer exists."))).toBe(true);
    expect(isFatalPollError(new UserFacingError("ReelOps isn't responding."))).toBe(false); // 503 / network
    expect(isFatalPollError(new TypeError("Failed to fetch"))).toBe(false);
  });
});
