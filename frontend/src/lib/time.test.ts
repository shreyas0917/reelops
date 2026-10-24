import { describe, expect, it } from "vitest";

import { formatClock, formatElapsed, relativeTime } from "./time";

const now = Date.UTC(2026, 9, 23, 12, 0, 0);
const ago = (s: number) => relativeTime(now - s * 1000, now);

describe("relativeTime", () => {
  it("uses short sentence-case labels", () => {
    expect(ago(10)).toBe("Just now");
    expect(ago(4 * 60)).toBe("4 min ago");
    expect(ago(3 * 3600)).toBe("3 h ago");
    expect(ago(26 * 3600)).toBe("Yesterday");
    expect(ago(3 * 86400)).toBe("3 days ago");
    expect(ago(30 * 86400)).toMatch(/^\d{1,2} \w{3}$/);
  });
});

describe("formatClock", () => {
  it("formats video lengths", () => {
    expect(formatClock(7)).toBe("0:07");
    expect(formatClock(83.4)).toBe("1:23");
    expect(formatClock(59.6)).toBe("1:00");
    expect(formatClock(3725)).toBe("1:02:05");
  });
});

describe("formatElapsed", () => {
  it("formats processing time", () => {
    expect(formatElapsed(48)).toBe("48 s");
    expect(formatElapsed(190)).toBe("3 min 10 s");
    expect(formatElapsed(180)).toBe("3 min");
    expect(formatElapsed(-3)).toBe("0 s");
  });
});
