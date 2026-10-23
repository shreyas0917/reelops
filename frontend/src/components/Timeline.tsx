import { STAGES, stageState, type View } from "../lib/status";

const SR_STATE = { todo: "", active: " (current)", done: " (done)", failed: " (failed)" } as const;

/** The job's real stages, with the current one highlighted. */
export function Timeline({ view }: { view: View }) {
  return (
    <ol className="timeline" aria-label="Job progress">
      {STAGES.map((stage) => {
        const state = stageState(stage.id, view);
        return (
          <li key={stage.id} data-state={state} aria-current={state === "active" ? "step" : undefined}>
            <span className="timeline__dot" aria-hidden="true" />
            <span>
              {stage.label}
              <span className="visually-hidden">{SR_STATE[state]}</span>
            </span>
          </li>
        );
      })}
    </ol>
  );
}
