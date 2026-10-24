import type { RecentJob } from "../lib/recent";
import { chipFor } from "../lib/status";
import { formatClock, relativeTime } from "../lib/time";

interface Props {
  jobs: RecentJob[];
  selectedId: string | null;
  onOpen: (job: RecentJob) => void;
}

/** Jobs started on this device (localStorage); each row reopens its job. */
export function VideoList({ jobs, selectedId, onOpen }: Props) {
  return (
    <section className="card videos" aria-labelledby="videos-heading">
      <h2 id="videos-heading" className="card__title">
        Your videos
      </h2>
      {jobs.length === 0 ? (
        <p className="videos__empty">Videos you make appear here, on this device.</p>
      ) : (
        <ul className="videos__list">
          {jobs.map((job) => {
            const chip = chipFor(job.status);
            return (
              <li key={job.id}>
                <button
                  type="button"
                  className="videos__row"
                  aria-current={job.id === selectedId ? "true" : undefined}
                  onClick={() => onOpen(job)}
                >
                  <span className="videos__name">{job.title}</span>
                  <span className="videos__meta">
                    {job.durationS !== undefined && <>{formatClock(job.durationS)} · </>}
                    {relativeTime(job.createdAt)}
                  </span>
                  <span className="chip" data-tone={chip.tone}>
                    {chip.label}
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
