// Small inline icons. Decorative: always aria-hidden, the text next to them
// carries the meaning.

const common = { "aria-hidden": true, focusable: false, fill: "none", stroke: "currentColor", strokeWidth: 1.8 } as const;

export function LogoMark() {
  return (
    <svg className="logo-mark" viewBox="0 0 28 28" width="28" height="28" aria-hidden="true" focusable="false">
      <rect width="28" height="28" rx="8" fill="currentColor" />
      <path d="M11 7.5v8l6.5-4z" fill="#fff" />
      <rect x="7" y="19" width="14" height="2.5" rx="1.25" fill="#fff" />
    </svg>
  );
}

export function UploadIcon() {
  return (
    <svg viewBox="0 0 24 24" width="24" height="24" {...common}>
      <path d="M12 16V4m0 0-4.5 4.5M12 4l4.5 4.5M4 15v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export function CheckIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" {...common} strokeWidth={2}>
      <path d="m3.5 8.5 3 3 6-7" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export function PlayIcon() {
  return (
    <svg viewBox="0 0 24 24" width="28" height="28" aria-hidden="true" focusable="false">
      <path d="M8 5.5v13l10.5-6.5z" fill="currentColor" />
    </svg>
  );
}
