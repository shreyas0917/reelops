// Read a local video's length before it's uploaded, so "Your videos" can show
// it while the job runs. Best effort: undefined if the browser can't decode it
// (e.g. some .mov codecs) or takes too long.

export function probeDuration(file: Blob, timeoutMs = 3000): Promise<number | undefined> {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const video = document.createElement("video");
    const finish = (value: number | undefined) => {
      window.clearTimeout(timer);
      video.removeAttribute("src");
      video.load(); // release the decoder
      URL.revokeObjectURL(url);
      resolve(value);
    };
    const timer = window.setTimeout(() => finish(undefined), timeoutMs);
    video.preload = "metadata";
    video.muted = true;
    video.onloadedmetadata = () => finish(Number.isFinite(video.duration) ? video.duration : undefined);
    video.onerror = () => finish(undefined);
    video.src = url;
  });
}
