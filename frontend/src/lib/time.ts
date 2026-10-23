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
