// Polling GET /jobs/{id} through API outages. A 503 or a dropped connection
// says nothing about the job (drill 5: replacing the API task gave ~20 s of
// 503s), so keep polling quietly; only say something after ~30 s of
// consecutive failures, and only a 404 ends the job's view.

import { JobNotFound } from "./api";

export const POLL_MS = 2000;
/** Consecutive failed polls before the "still trying" notice: ~30 s. */
export const NOTICE_AFTER_FAILURES = Math.ceil(30_000 / POLL_MS);

/** A poll error is fatal only when the job is gone; anything else may pass. */
export function isFatalPollError(error: unknown): boolean {
  return error instanceof JobNotFound;
}

/** Consecutive failures after one more poll: reset by any success. */
export function nextFailureCount(failures: number, ok: boolean): number {
  return ok ? 0 : failures + 1;
}

export function showConnectionNotice(failures: number): boolean {
  return failures >= NOTICE_AFTER_FAILURES;
}
