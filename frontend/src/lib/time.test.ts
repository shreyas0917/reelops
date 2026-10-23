import { describe, expect, it } from "vitest";

import { relativeTime } from "./time";

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
