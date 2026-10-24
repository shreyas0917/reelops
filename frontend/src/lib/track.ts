// The caption track under the player: one block per caption, positioned and
// sized by time, so pauses between captions show as gaps.

import type { Segment } from "./api";

export interface Block {
  left: number; // % of the track
  width: number; // % of the track
}

const clampPct = (n: number) => Math.min(100, Math.max(0, n));

/** Track length: the video's duration once known, else the last caption's end. */
export function trackLength(segments: Segment[], durationS?: number): number {
  if (durationS && Number.isFinite(durationS) && durationS > 0) return durationS;
  return segments.reduce((max, s) => Math.max(max, s.end), 0);
}

/** Left offset and width of each caption, in % of `total` seconds, clipped to the track. */
export function trackBlocks(segments: Segment[], total: number): Block[] {
  if (!(total > 0)) return segments.map(() => ({ left: 0, width: 0 }));
  return segments.map((s) => {
    const left = clampPct((s.start / total) * 100);
    const right = clampPct((s.end / total) * 100);
    return { left, width: Math.max(0, right - left) };
  });
}

/** Index of the caption on screen at time t (start inclusive, end exclusive), or -1 in a gap. */
export function activeSegment(segments: Segment[], t: number): number {
  // Captions are in order and short lists (hundreds at most): a scan is plenty.
  return segments.findIndex((s) => t >= s.start && t < s.end);
}
