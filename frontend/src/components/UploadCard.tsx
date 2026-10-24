import { useRef, useState } from "react";

import { UploadIcon } from "./Icons";

const ACCEPT = ".mp4,.mov,.webm,video/mp4,video/quicktime,video/webm";

interface Props {
  large: boolean; // first visit: a bigger drop area
  disabled: boolean; // while an upload is running
  error?: string; // a file rejected before upload, already user-facing
  onFile: (file: File) => void;
}

/** Dashed drop area plus a real button that opens the file picker. */
export function UploadCard({ large, disabled, error, onFile }: Props) {
  const input = useRef<HTMLInputElement>(null);
  const depth = useRef(0); // dragenter/leave also fire for children; count them
  const [dragging, setDragging] = useState(false);

  return (
    <section className="card upload" aria-labelledby="upload-heading">
      <h2 id="upload-heading" className="card__title">
        New video
      </h2>
      <div
        className="dropzone"
        data-large={large}
        data-dragging={dragging}
        data-disabled={disabled}
        onDragEnter={(e) => {
          if (disabled) return;
          e.preventDefault();
          if (depth.current++ === 0) setDragging(true);
        }}
        onDragOver={(e) => {
          if (!disabled) e.preventDefault();
        }}
        onDragLeave={() => {
          if (!disabled && --depth.current === 0) setDragging(false);
        }}
        onDrop={(e) => {
          if (disabled) return;
          e.preventDefault();
          depth.current = 0;
          setDragging(false);
          const file = e.dataTransfer.files[0];
          if (file) onFile(file);
        }}
      >
        <span className="dropzone__icon">
          <UploadIcon />
        </span>
        <p className="dropzone__text">{dragging ? "Drop to upload" : "Drop a narrated screen recording here"}</p>
        <button
          type="button"
          className="button button--primary"
          disabled={disabled}
          onClick={() => input.current?.click()}
        >
          Choose a file
        </button>
        <p className="dropzone__limits">MP4, MOV or WebM · up to 200 MB · with spoken narration</p>
      </div>
      {error && (
        <p className="alert" role="alert">
          {error}
        </p>
      )}
      <input
        ref={input}
        type="file"
        accept={ACCEPT}
        className="visually-hidden"
        tabIndex={-1}
        aria-hidden="true"
        onChange={(e) => {
          const file = e.target.files?.[0];
          e.target.value = ""; // allow choosing the same file again
          if (file) onFile(file);
        }}
      />
    </section>
  );
}
