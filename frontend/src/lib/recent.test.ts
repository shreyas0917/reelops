import { describe, expect, it } from "vitest";

import { RECENT_KEY, RECENT_MAX, loadRecent, upsertRecent, type RecentJob } from "./recent";

class MemoryStorage {
  data = new Map<string, string>();
  getItem(k: string) {
    return this.data.get(k) ?? null;
  }
  setItem(k: string, v: string) {
    this.data.set(k, v);
  }
}

const throwing = {
  getItem(): string | null {
    throw new Error("SecurityError");
  },
  setItem(): void {
    throw new Error("QuotaExceededError");
  },
};

const job = (id: string, status = "pending"): RecentJob => ({ id, title: `${id}.mp4`, status, createdAt: 1 });

describe("recent jobs", () => {
  it("inserts newest first, updates in place, caps the list and persists", () => {
    const s = new MemoryStorage();
    let list: RecentJob[] = [];
    for (let i = 0; i < RECENT_MAX + 2; i++) list = upsertRecent(list, job(`j${i}`), s);
    expect(list).toHaveLength(RECENT_MAX);
    expect(list[0].id).toBe(`j${RECENT_MAX + 1}`);

    list = upsertRecent(list, job(`j${RECENT_MAX + 1}`, "done"), s);
    expect(list[0]).toMatchObject({ id: `j${RECENT_MAX + 1}`, status: "done" });
    expect(list).toHaveLength(RECENT_MAX);
    expect(loadRecent(s)).toEqual(list);
  });

  it("ignores corrupt or foreign data", () => {
    const s = new MemoryStorage();
    s.setItem(RECENT_KEY, "{not json");
    expect(loadRecent(s)).toEqual([]);
    s.setItem(RECENT_KEY, JSON.stringify([{ id: 1 }, job("ok")]));
    expect(loadRecent(s)).toEqual([job("ok")]);
  });

  it("keeps working when storage throws", () => {
    expect(loadRecent(throwing)).toEqual([]);
    expect(upsertRecent([], job("a"), throwing)).toEqual([job("a")]);
    expect(loadRecent(null)).toEqual([]);
  });
});
