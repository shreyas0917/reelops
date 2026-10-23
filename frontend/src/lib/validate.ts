// Same rules as the API (app/reelops_api/jobs.py validate_upload), checked
// before uploading so the user gets an answer immediately.

export const MAX_BYTES = 200 * 1024 * 1024;

// Extension -> the Content-Type the presigned upload is signed for. Derived
// from the extension, not File.type, which browsers report inconsistently
// (e.g. empty for some .mov files).
export const CONTENT_TYPES: Record<string, string> = {
  mp4: "video/mp4",
  mov: "video/quicktime",
  webm: "video/webm",
};

export type Validation = { ok: true; contentType: string } | { ok: false; error: string };

export function extensionOf(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
}

export function formatMB(bytes: number): string {
  return `${Math.max(1, Math.round(bytes / (1024 * 1024)))} MB`;
}

export function validateFile(name: string, size: number): Validation {
  const ext = extensionOf(name);
  const contentType = CONTENT_TYPES[ext];
  if (!contentType) {
    const what = ext ? `That file is a .${ext}.` : "That file has no extension.";
    return { ok: false, error: `${what} Choose an mp4, mov or webm recording.` };
  }
  if (size <= 0) {
    return { ok: false, error: "That file is empty. Choose a recording with narration." };
  }
  if (size > MAX_BYTES) {
    return { ok: false, error: `That recording is ${formatMB(size)}. Choose one up to 200 MB.` };
  }
  return { ok: true, contentType };
}
