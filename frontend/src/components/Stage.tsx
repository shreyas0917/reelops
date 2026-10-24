import { useEffect, useRef, useState, type RefObject } from "react";

import type { Job, Segment } from "../lib/api";
import { STEPS, stageMessage, stepStates, type Phase, type StepId } from "../lib/status";
import { formatClock, formatElapsed } from "../lib/time";
import { activeSegment, trackBlocks, trackLength } from "../lib/track";
import { CheckIcon, PlayIcon } from "./Icons";

type Source = "reelops" | "original";
type Resume = { time: number; playing: boolean };

interface Props {
  title: string;
  durationS?: number;
  phase: Phase;
  job: Job | null;
  progress: number;
  queuedForMs: number;
  error?: string;
  failedAt?: StepId;
  onDuration: (seconds: number) => void;
  onReset: () => void;
  onCopyLink: () => Promise<boolean>;
}

/** The right-hand card: everything about the selected job. */
export function Stage(props: Props) {
  const { title, durationS, phase, job, error, failedAt } = props;
  const [source, setSource] = useState<Source>("reelops");
  const video = useRef<HTMLVideoElement>(null);
  // Switching versions keeps your place. Read it here, before the switch:
  // changing a <video>'s src resets currentTime as soon as React commits.
  const resume = useRef<Resume | null>(null);
  const switchSource = (next: Source) => {
    const v = video.current;
    if (next === source) return;
    if (v && v.currentTime > 0) resume.current = { time: v.currentTime, playing: !v.paused };
    setSource(next);
  };
  const done = phase === "done" && job?.preview_url;
  const meta = [
    durationS !== undefined ? formatClock(durationS) : null,
    phase === "done" && job ? `Ready in ${formatElapsed(job.updated_at - job.created_at)}` : null,
  ].filter(Boolean);
  const message = stageMessage(phase, { progress: props.progress, queuedForMs: props.queuedForMs });

  return (
    <section className="card stage" aria-labelledby="stage-title">
      <header className="stage__header">
        <div className="stage__heading">
          <h2 id="stage-title" className="stage__title">
            {title}
          </h2>
          {meta.length > 0 && <p className="stage__meta">{meta.join(" · ")}</p>}
        </div>
        {done && <SourceToggle value={source} originalAvailable={Boolean(job.original_preview_url)} onChange={switchSource} />}
      </header>

      {/* Announce phase changes once, not every upload percentage. */}
      <p className="visually-hidden" role="status" aria-live="polite">
        {phase === "uploading" ? "Uploading" : message.title}
      </p>

      {done ? (
        <Finished job={job} source={source} video={video} resume={resume} onDuration={props.onDuration} />
      ) : phase === "failed" ? (
        <div className="failure" role="alert">
          <h3 className="failure__title">{message.title}</h3>
          <p>{error ?? "Processing failed. Upload the recording again."}</p>
        </div>
      ) : (
        <div className="screen screen--status">
          <div className="screen__message">
            <p className="screen__title" data-numeric={phase === "uploading"}>
              {message.title}
            </p>
            {message.detail && <p className="screen__detail">{message.detail}</p>}
          </div>
          <div className="screen__progress" data-indeterminate={phase !== "uploading"} aria-hidden="true">
            <span style={phase === "uploading" ? { width: `${props.progress}%` } : undefined} />
          </div>
        </div>
      )}

      {!done && <StepRow phase={phase} failedAt={failedAt} />}

      <div className="actions">
        {done && (
          <a className="button button--primary" href={job.download_url ?? undefined} download>
            Download video
          </a>
        )}
        {(done || phase === "failed") && (
          <button type="button" className="button button--outline" onClick={props.onReset}>
            Make another
          </button>
        )}
        {job && <CopyLinkButton onCopy={props.onCopyLink} />}
      </div>

      {done && <WhatReelOpsDid job={job} durationS={durationS} />}
    </section>
  );
}

function SourceToggle({
  value,
  originalAvailable,
  onChange,
}: {
  value: Source;
  originalAvailable: boolean;
  onChange: (s: Source) => void;
}) {
  const options: [Source, string][] = [
    ["reelops", "ReelOps version"],
    ["original", "Original"],
  ];
  return (
    <div className="segmented" role="group" aria-label="Which video to play">
      {options.map(([id, label]) => (
        <button
          key={id}
          type="button"
          aria-pressed={value === id}
          disabled={id === "original" && !originalAvailable}
          onClick={() => onChange(id)}
        >
          {label}
        </button>
      ))}
    </div>
  );
}

/** Player + caption track for a finished job. */
function Finished({
  job,
  source,
  video,
  resume,
  onDuration,
}: {
  job: Job;
  source: Source;
  video: RefObject<HTMLVideoElement | null>;
  resume: RefObject<Resume | null>;
  onDuration: (s: number) => void;
}) {
  const [started, setStarted] = useState(false);
  const [time, setTime] = useState(0);
  const [duration, setDuration] = useState<number>();
  const [failedSrc, setFailedSrc] = useState<string | null>(null);
  const url = source === "original" ? job.original_preview_url : job.preview_url;
  // "#t=0.001": mobile browsers paint no frame for preload="metadata" without
  // it. A fragment never reaches S3, so the presigned signature still matches.
  const src = url && `${url}#t=0.001`;
  const unplayable = src !== null && failedSrc === src; // per source: switching back clears it

  usePlaybackTime(video, setTime);

  return (
    <>
      <div className="screen">
        <video
          ref={video}
          src={src ?? undefined}
          controls={started}
          preload="metadata"
          playsInline
          aria-label={source === "original" ? "Original recording" : "Finished video"}
          onPlay={() => setStarted(true)}
          onError={() => setFailedSrc(src)}
          onLoadedMetadata={(e) => {
            const v = e.currentTarget;
            if (source === "reelops" && Number.isFinite(v.duration)) {
              setDuration(v.duration);
              onDuration(v.duration);
            }
            const r = resume.current;
            resume.current = null;
            if (r) {
              v.currentTime = r.time;
              if (r.playing) void v.play().catch(() => undefined);
            }
          }}
        />
        {!started && !unplayable && (
          <>
            <div className="screen__scrim" />
            <button
              type="button"
              className="play"
              aria-label="Play video"
              onClick={() => void video.current?.play().catch(() => undefined)}
            >
              <PlayIcon />
            </button>
          </>
        )}
        {unplayable && (
          <div className="screen__message">
            <p className="screen__title">This browser can't play the original file</p>
            <p className="screen__detail">Switch back to the ReelOps version, which plays everywhere.</p>
          </div>
        )}
      </div>
      <CaptionTrack
        segments={job.segments}
        total={trackLength(job.segments, duration)}
        time={time}
        onSeek={(t) => {
          const v = video.current;
          if (v) v.currentTime = t;
        }}
      />
    </>
  );
}

/** currentTime as state: every frame while playing, and on seeks. */
function usePlaybackTime(video: RefObject<HTMLVideoElement | null>, setTime: (t: number) => void) {
  useEffect(() => {
    const v = video.current;
    if (!v) return;
    let frame = 0;
    const tick = () => {
      setTime(v.currentTime);
      if (!v.paused && !v.ended) frame = requestAnimationFrame(tick);
    };
    const restart = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(tick);
    };
    const sync = () => setTime(v.currentTime);
    v.addEventListener("play", restart);
    v.addEventListener("seeked", sync);
    v.addEventListener("loadedmetadata", sync);
    return () => {
      cancelAnimationFrame(frame);
      v.removeEventListener("play", restart);
      v.removeEventListener("seeked", sync);
      v.removeEventListener("loadedmetadata", sync);
    };
  }, [video, setTime]);
}

/**
 * One block per caption, as wide as it is long; the one on screen is lit.
 * Visual only (the captions are burned into the video): hidden from screen
 * readers, and clicking it is a mouse shortcut for the video's own seek bar.
 */
function CaptionTrack({
  segments,
  total,
  time,
  onSeek,
}: {
  segments: Segment[];
  total: number;
  time: number;
  onSeek: (t: number) => void;
}) {
  if (segments.length === 0 || total <= 0) return null;
  const blocks = trackBlocks(segments, total);
  const active = activeSegment(segments, time);
  return (
    <div
      className="track"
      aria-hidden="true"
      onClick={(e) => {
        const box = e.currentTarget.getBoundingClientRect();
        onSeek(((e.clientX - box.left) / box.width) * total);
      }}
    >
      {segments.map((s, i) => (
        <span
          key={`${s.start}-${i}`}
          className="track__block"
          data-active={i === active}
          style={{ left: `${blocks[i].left}%`, width: `${blocks[i].width}%` }}
          title={s.text}
        >
          <span className="track__text">{s.text}</span>
        </span>
      ))}
      <span className="track__playhead" style={{ left: `${Math.min(100, (time / total) * 100)}%` }} />
    </div>
  );
}

const SR_STATE = { todo: "", active: " (in progress)", done: " (done)", failed: " (failed here)" } as const;

function StepRow({ phase, failedAt }: { phase: Phase; failedAt?: StepId }) {
  const states = stepStates(phase, failedAt);
  return (
    <ol className="steps" aria-label="Progress">
      {STEPS.map((step, i) => (
        <li key={step.id} data-state={states[i]} aria-current={states[i] === "active" ? "step" : undefined}>
          <span className="steps__dot" aria-hidden="true">
            {states[i] === "done" ? <CheckIcon /> : states[i] === "failed" ? "!" : i + 1}
          </span>
          <span className="steps__label">
            {step.label}
            <span className="visually-hidden">{SR_STATE[states[i]]}</span>
          </span>
        </li>
      ))}
    </ol>
  );
}

function CopyLinkButton({ onCopy }: { onCopy: () => Promise<boolean> }) {
  const [state, setState] = useState<"idle" | "copied" | "failed">("idle");
  useEffect(() => {
    if (state === "idle") return;
    const timer = window.setTimeout(() => setState("idle"), 2500);
    return () => window.clearTimeout(timer);
  }, [state]);
  return (
    <button
      type="button"
      className="button button--outline"
      onClick={async () => setState((await onCopy()) ? "copied" : "failed")}
    >
      <span aria-live="polite">
        {state === "copied" ? "Link copied" : state === "failed" ? "Copy failed: use the address bar" : "Copy job link"}
      </span>
    </button>
  );
}

function WhatReelOpsDid({ job, durationS }: { job: Job; durationS?: number }) {
  const n = job.segments.length;
  const tiles = [
    { title: "Transcribed", text: n ? `${n} caption segment${n === 1 ? "" : "s"}` : "Your narration" },
    { title: "Captioned", text: "Burned into the video" },
    { title: "Voiced", text: job.voice ? `${job.voice}, Amazon Polly` : "Amazon Polly" },
    { title: "Rendered", text: durationS !== undefined ? `MP4, ${formatClock(durationS)}` : "MP4" },
  ];
  return (
    <section className="did" aria-labelledby="did-heading">
      <h3 id="did-heading" className="did__title">
        What ReelOps did
      </h3>
      <ul className="did__tiles">
        {tiles.map((t) => (
          <li key={t.title}>
            <span className="did__check" aria-hidden="true">
              <CheckIcon />
            </span>
            <strong>{t.title}</strong>
            <span>{t.text}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}
