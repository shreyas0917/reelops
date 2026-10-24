// ?job=<id> in the address bar: a link that reopens a job on any device
// (for as long as the API keeps it: 7 days).

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The job id from a query string ("?job=..."), or null if absent or not a job id. */
export function jobIdFromSearch(search: string): string | null {
  const id = new URLSearchParams(search).get("job")?.trim().toLowerCase() ?? "";
  return UUID.test(id) ? id : null;
}

/** `href` with ?job set to `jobId`, or removed when null; other parameters kept. */
export function withJobId(href: string, jobId: string | null): string {
  const url = new URL(href);
  if (jobId) url.searchParams.set("job", jobId);
  else url.searchParams.delete("job");
  return url.toString();
}
