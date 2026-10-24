import { describe, expect, it } from "vitest";

import { MAX_BYTES, extensionOf, validateFile } from "./validate";

describe("validateFile", () => {
  it.each([
    ["demo.mp4", "video/mp4"],
    ["Demo Final.MOV", "video/quicktime"],
    ["clip.webm", "video/webm"],
  ])("accepts %s as %s", (name, contentType) => {
    expect(validateFile(name, 1000)).toEqual({ ok: true, contentType });
  });

  it("rejects other types and says which ones work", () => {
    expect(validateFile("talk.avi", 1000)).toEqual({
      ok: false,
      error: "That file is a .avi. Choose an MP4, MOV or WebM recording.",
    });
  });

  it("rejects files without an extension", () => {
    const r = validateFile("recording", 1000);
    expect(r.ok).toBe(false);
    expect(!r.ok && r.error).toMatch(/no extension/);
  });

  it("rejects empty files", () => {
    expect(validateFile("a.mp4", 0)).toMatchObject({ ok: false });
  });

  it("allows exactly 200 MB and rejects one byte more, naming the size", () => {
    expect(validateFile("a.mp4", MAX_BYTES).ok).toBe(true);
    const r = validateFile("a.mp4", MAX_BYTES + 1);
    expect(r).toEqual({ ok: false, error: "That recording is 200 MB. Choose one up to 200 MB." });
    expect(validateFile("a.mp4", 312 * 1024 * 1024)).toMatchObject({ error: expect.stringContaining("312 MB") });
  });
});

describe("extensionOf", () => {
  it("handles dots in names and hidden files", () => {
    expect(extensionOf("my.demo.v2.MP4")).toBe("mp4");
    expect(extensionOf(".mp4")).toBe("");
  });
});
