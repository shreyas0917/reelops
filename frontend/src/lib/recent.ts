// Recent jobs, kept in localStorage so a refresh keeps them. Storage can throw
// (private mode, quota, blocked site data): every call is wrapped, and the
// page simply works without persistence.

export interface RecentJob {
  id: string;
  title: string; // original filename (the API doesn't store it)
  status: string; // last known API status
  createdAt: number; // epoch ms
}

export const RECENT_KEY = "reelops.recent";
export const RECENT_MAX = 8;

type Storage = Pick<globalThis.Storage, "getItem" | "setItem">;

function defaultStorage(): Storage | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

export function loadRecent(storage: Storage | null = defaultStorage()): RecentJob[] {
  try {
    const parsed = JSON.parse(storage?.getItem(RECENT_KEY) ?? "[]");
    return Array.isArray(parsed)
      ? parsed.filter((j) => j && typeof j.id === "string" && typeof j.title === "string").slice(0, RECENT_MAX)
      : [];
  } catch {
    return [];
  }
}

/** Insert or update a job (newest first) and persist; returns the new list. */
export function upsertRecent(
  jobs: RecentJob[],
  job: RecentJob,
  storage: Storage | null = defaultStorage(),
): RecentJob[] {
  const existing = jobs.find((j) => j.id === job.id);
  const next = existing
    ? jobs.map((j) => (j.id === job.id ? { ...j, ...job } : j))
    : [job, ...jobs].slice(0, RECENT_MAX);
  try {
    storage?.setItem(RECENT_KEY, JSON.stringify(next));
  } catch {
    // Not persisted; the in-memory list still works.
  }
  return next;
}
