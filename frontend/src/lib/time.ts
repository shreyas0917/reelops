// Short relative times in sentence case: "Just now", "4 min ago", "Yesterday".

export function relativeTime(thenMs: number, nowMs: number = Date.now()): string {
  const s = Math.max(0, Math.round((nowMs - thenMs) / 1000));
  if (s < 45) return "Just now";
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} h ago`;
  const d = Math.round(h / 24);
  if (d === 1) return "Yesterday";
  if (d < 7) return `${d} days ago`;
  // Explicit "23 Sep": locale formatting varies by runtime ("Sep 23", "23 Sept").
  const date = new Date(thenMs);
  return `${date.getDate()} ${MONTHS[date.getMonth()]}`;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** Video length as a clock: 7 -> "0:07", 83.4 -> "1:23", 3725 -> "1:02:05". */
export function formatClock(seconds: number): string {
  const total = Math.max(0, Math.round(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = String(total % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`;
}

/** A span of work: 48 -> "48 s", 190 -> "3 min 10 s", 180 -> "3 min". */
export function formatElapsed(seconds: number): string {
  const total = Math.max(0, Math.round(seconds));
  if (total < 60) return `${total} s`;
  const m = Math.floor(total / 60);
  const s = total % 60;
  return s ? `${m} min ${s} s` : `${m} min`;
}
