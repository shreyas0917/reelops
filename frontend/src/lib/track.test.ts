import { describe, expect, it } from "vitest";

import type { Segment } from "./api";
import { activeSegment, trackBlocks, trackLength } from "./track";

const seg = (start: number, end: number): Segment => ({ start, end, text: `${start}-${end}` });
const rounded = (blocks: { left: number; width: number }[]) =>
  blocks.map((b) => ({ left: +b.left.toFixed(4), width: +b.width.toFixed(4) }));

describe("trackBlocks", () => {
  it("sizes each block by its duration and places it at its start", () => {
    expect(rounded(trackBlocks([seg(0, 2), seg(2, 3), seg(5, 10)], 10))).toEqual([
      { left: 0, width: 20 },
      { left: 20, width: 10 },
      { left: 50, width: 50 }, // the 2-5 s pause stays a gap
    ]);
  });

  it("widths are proportional: twice as long, twice as wide", () => {
    const [a, b] = trackBlocks([seg(1, 2), seg(3, 5)], 8);
    expect(b.width).toBeCloseTo(2 * a.width);
  });

  it("clips captions that run past the end of the video", () => {
    expect(rounded(trackBlocks([seg(8, 12), seg(11, 13)], 10))).toEqual([
      { left: 80, width: 20 },
      { left: 100, width: 0 },
    ]);
  });

  it("returns zero-width blocks when the length is unknown or zero", () => {
    expect(trackBlocks([seg(0, 1)], 0)).toEqual([{ left: 0, width: 0 }]);
    expect(trackBlocks([seg(0, 1)], Number.NaN)).toEqual([{ left: 0, width: 0 }]);
    expect(trackBlocks([], 10)).toEqual([]);
  });
});

describe("trackLength", () => {
  it("uses the video duration, falling back to the last caption's end", () => {
    expect(trackLength([seg(0, 4), seg(5, 9)], 12.5)).toBe(12.5);
    expect(trackLength([seg(0, 4), seg(5, 9)])).toBe(9);
    expect(trackLength([seg(0, 4)], Number.NaN)).toBe(4);
    expect(trackLength([], undefined)).toBe(0);
  });
});

describe("activeSegment", () => {
  const segments = [seg(0.5, 2), seg(2, 3.5), seg(5, 6)];

  it("finds the caption on screen, start inclusive and end exclusive", () => {
    expect(activeSegment(segments, 0.5)).toBe(0);
    expect(activeSegment(segments, 1.99)).toBe(0);
    expect(activeSegment(segments, 2)).toBe(1); // hand-over at the boundary
    expect(activeSegment(segments, 5.5)).toBe(2);
  });

  it("is -1 before the first caption, in gaps and after the last", () => {
    expect(activeSegment(segments, 0)).toBe(-1);
    expect(activeSegment(segments, 4)).toBe(-1);
    expect(activeSegment(segments, 6)).toBe(-1);
  });
});
