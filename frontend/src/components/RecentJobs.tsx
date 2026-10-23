import type { RecentJob } from "../lib/recent";
import { relativeTime } from "../lib/time";

const STATUS_LABEL: Record<string, string> = {
  pending: "Queued",
  processing: "Processing",
  done: "Done",
  failed: "Failed",
};

interface Props {
  jobs: RecentJob[];
  currentId: string | null;
  onOpen: (job: RecentJob) => void;
}

/** A quiet list of recent jobs on this device; each row reopens its job. */
export function RecentJobs({ jobs, currentId, onOpen }: Props) {
  return (
    <section className="recent" aria-labelledby="recent-heading">
      <h2 id="recent-heading">Recent jobs</h2>
      {jobs.length === 0 ? (
        <p className="recent__empty">Jobs you start appear here, on this device.</p>
      ) : (
        <ol>
          {jobs.map((job) => (
            <li key={job.id}>
              <button
                type="button"
                className="recent__row"
                aria-current={job.id === currentId ? "true" : undefined}
                onClick={() => onOpen(job)}
              >
                <span className="recent__title">{job.title}</span>
                <span className="recent__status" data-status={job.status}>
                  {STATUS_LABEL[job.status] ?? job.status}
                </span>
                <span className="recent__time">{relativeTime(job.createdAt)}</span>
              </button>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}
