// Talks to the ReelOps API (same origin) and uploads straight to S3.

export interface CreatedJob {
  job_id: string;
  upload_url: string;
  upload_method: string;
  upload_headers: Record<string, string>;
  expires_in: number;
}

/** One burned-in caption, in seconds from the start of the video. */
export interface Segment {
  start: number;
  end: number;
  text: string;
}

export interface Job {
  job_id: string;
  status: "pending" | "processing" | "done" | "failed";
  filename: string | null; // sanitized upload name; null for jobs from before it was stored
  error: string | null;
  attempts: number;
  created_at: number;
  updated_at: number;
  download_url: string | null;
  preview_url: string | null;
  original_preview_url: string | null; // the raw upload, once done
  segments: Segment[]; // empty until done
  voice: string | null; // Polly voice used, once done
}

/** An error whose message is already written for the user. */
export class UserFacingError extends Error {}

/** 404 from the API: the job doesn't exist (any more). Never transient. */
export class JobNotFound extends UserFacingError {}

const UNREACHABLE = "ReelOps isn't responding. Check your connection, then try again.";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(path, init);
  } catch {
    throw new UserFacingError(UNREACHABLE);
  }
  if (!response.ok) {
    const body = await response.json().catch(() => null);
    const detail = typeof body?.detail === "string" ? body.detail : null;
    if (response.status === 422) {
      // A string detail is our own message; a list is FastAPI's field validation.
      throw new UserFacingError(
        detail
          ? `${detail.charAt(0).toUpperCase()}${detail.slice(1)}.`
          : "That file can't be uploaded. Choose an MP4, MOV or WebM recording up to 200 MB.",
      );
    }
    if (response.status === 404) {
      throw new JobNotFound("That job no longer exists. Jobs are kept for 7 days.");
    }
    throw new UserFacingError(UNREACHABLE);
  }
  return response.json() as Promise<T>;
}

export function createJob(filename: string, contentType: string, size: number): Promise<CreatedJob> {
  return request<CreatedJob>("/jobs", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ filename, content_type: contentType, size }),
  });
}

export function getJob(jobId: string): Promise<Job> {
  return request<Job>(`/jobs/${encodeURIComponent(jobId)}`);
}

/**
 * PUT the file to the presigned S3 URL. XMLHttpRequest, not fetch: fetch has
 * no upload progress events, and xhr.upload.onprogress is what drives
 * "Uploading 42%".
 */
export function uploadFile(
  url: string,
  file: Blob,
  headers: Record<string, string>,
  onProgress: (percent: number) => void,
): { done: Promise<void>; abort: () => void } {
  const xhr = new XMLHttpRequest();
  const done = new Promise<void>((resolve, reject) => {
    xhr.open("PUT", url);
    for (const [name, value] of Object.entries(headers)) xhr.setRequestHeader(name, value);
    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable) onProgress((event.loaded / event.total) * 100);
    };
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) return resolve();
      reject(
        new UserFacingError(
          xhr.status === 403
            ? "The upload link expired. Drop the recording again to get a new one."
            : `The upload was refused (${xhr.status}). Drop the recording again.`,
        ),
      );
    };
    xhr.onerror = () =>
      reject(new UserFacingError("The upload stopped before it finished. Check your connection, then drop the file again."));
    xhr.onabort = () => reject(new UserFacingError("Upload cancelled."));
    xhr.send(file);
  });
  return { done, abort: () => xhr.abort() };
}
