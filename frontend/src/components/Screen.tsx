import { useRef, useState } from "react";

import { caption, type View } from "../lib/status";

interface Props {
  view: View;
  videoUrl: string | null;
  canDrop: boolean;
  pickOnClick: boolean; // only empty/failed: in the done state a click plays
  onFile: (file: File) => void;
  onDraggingChange: (dragging: boolean) => void;
  onPick: () => void;
}

/** The 16:9 screen: drop zone, status caption, and the finished video. */
export function Screen({ view, videoUrl, canDrop, pickOnClick, onFile, onDraggingChange, onPick }: Props) {
  const video = useRef<HTMLVideoElement>(null);
  const depth = useRef(0); // dragenter/leave fire for children too; count them
  const [started, setStarted] = useState(false);
  const text = caption(view);
  const showCaption = !(view.phase === "done" && started);
  // Announce changes once ("Uploading"), not every percentage step.
  const announcement = view.phase === "uploading" ? "Uploading" : text;

  return (
    <div
      className="screen"
      data-droppable={pickOnClick}
      data-dragging={Boolean(view.dragging)}
      onClick={pickOnClick ? onPick : undefined}
      onDragEnter={(e) => {
        if (!canDrop) return;
        e.preventDefault();
        if (depth.current++ === 0) onDraggingChange(true);
      }}
      onDragOver={(e) => {
        if (canDrop) e.preventDefault();
      }}
      onDragLeave={() => {
        if (canDrop && --depth.current === 0) onDraggingChange(false);
      }}
      onDrop={(e) => {
        if (!canDrop) return;
        e.preventDefault();
        depth.current = 0;
        onDraggingChange(false);
        const file = e.dataTransfer.files[0];
        if (file) onFile(file);
      }}
    >
      {view.phase === "done" && videoUrl && (
        <>
          <video
            ref={video}
            src={videoUrl}
            controls={started}
            preload="metadata"
            playsInline
            data-started={started}
            onPlay={() => setStarted(true)}
            aria-label="Finished video"
          />
          {!started && (
            <>
              <div className="screen__scrim" />
              <button
                type="button"
                className="screen__play"
                aria-label="Play video"
                onClick={() => void video.current?.play().catch(() => undefined)}
              />
            </>
          )}
        </>
      )}

      {showCaption && (
        <p
          className="caption"
          data-tone={view.phase === "failed" ? "error" : "normal"}
          data-numeric={view.phase === "uploading"}
          aria-hidden="true"
        >
          <span key={text} className="caption__text">
            {text}
          </span>
        </p>
      )}

      {view.phase === "uploading" && (
        <div className="screen__progress" style={{ width: `${view.progress ?? 0}%` }} aria-hidden="true" />
      )}

      <p className="visually-hidden" role="status" aria-live="polite">
        {announcement}
      </p>
    </div>
  );
}
