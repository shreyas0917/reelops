import { readFileSync } from "node:fs";

import { expect, test, type Page } from "@playwright/test";

import { formatClock } from "../src/lib/time";

const JOB_ID = "6f1d2c3a-4b5e-4f60-8a71-92b3c4d5e6f7";
const NOW = Date.now();
const H = 3600_000;
const FILE = "billing-settings-walkthrough.mp4";
// The "finished video" is real ReelOps output: a scripted walkthrough of an
// invented app, narrated with Polly and run through the worker pipeline. The
// segments, duration and voice come from that run. All git-ignored; rebuild
// with scripts/make_ui_fixture.sh.
const VIDEO = readFileSync("e2e/fixtures/done.webm");
const ORIGINAL = readFileSync("e2e/fixtures/original.webm");
const FIXTURE: { durationS: number; voice: string; segments: { start: number; end: number; text: string }[] } =
  JSON.parse(readFileSync("e2e/fixtures/fixture.json", "utf8"));
const SEGMENTS = FIXTURE.segments;
// Screenshot moment: late in "Save the changes...", when the saved toast shows.
const SHOT = SEGMENTS.findIndex((seg) => /confirmation/i.test(seg.text));
const SHOT_T = SEGMENTS[SHOT].end - 0.8;

// Realistic history, so "Your videos" isn't empty (except on a first visit).
const SEEDED = [
  { id: "a2", title: "onboarding-tour.mov", status: "done", createdAt: NOW - 26 * H, durationS: 94 },
  { id: "a3", title: "q3-roadmap-demo.webm", status: "failed", createdAt: NOW - 4 * 24 * H },
  { id: "a4", title: "team-invites.mp4", status: "done", createdAt: NOW - 6 * 24 * H, durationS: 47 },
];

const job = (status: string, extra: Record<string, unknown> = {}) => ({
  job_id: JOB_ID,
  status,
  filename: FILE,
  error: null,
  attempts: status === "pending" ? 0 : 1,
  created_at: Math.floor(NOW / 1000) - 190,
  updated_at: Math.floor(NOW / 1000),
  download_url: null,
  preview_url: null,
  original_preview_url: null,
  segments: [],
  voice: null,
  ...extra,
});

const DONE = job("done", {
  preview_url: "https://mock-media.example/preview.webm",
  download_url: "https://mock-media.example/download.mp4",
  original_preview_url: "https://mock-media.example/original.webm",
  segments: SEGMENTS,
  voice: FIXTURE.voice,
});

/** Mock the API and the S3 upload; `upload` = "hold" stops at 42%. */
async function setup(page: Page, opts: { upload?: "hold" | "complete"; jobJson?: object; seeded?: object[] } = {}) {
  const { upload = "complete", jobJson, seeded = SEEDED } = opts;
  await page.addInitScript(
    ({ seeded, mode }) => {
      if (!sessionStorage.getItem("seeded")) {
        localStorage.setItem("reelops.recent", JSON.stringify(seeded));
        sessionStorage.setItem("seeded", "1");
      }
      // Fake XHR for the presigned PUT: report 42%, then hold or finish.
      class FakeXHR {
        upload: { onprogress: ((e: ProgressEvent) => void) | null } = { onprogress: null };
        status = 0;
        onload: (() => void) | null = null;
        onerror: (() => void) | null = null;
        onabort: (() => void) | null = null;
        open() {}
        setRequestHeader() {}
        abort() {}
        send() {
          setTimeout(() => {
            this.upload.onprogress?.({ lengthComputable: true, loaded: 42, total: 100 } as ProgressEvent);
            if (mode === "complete") {
              this.status = 200;
              setTimeout(() => this.onload?.(), 50);
            }
          }, 50);
        }
      }
      (window as unknown as { XMLHttpRequest: unknown }).XMLHttpRequest = FakeXHR;
    },
    { seeded, mode: upload },
  );
  await page.route("**/jobs", (route) =>
    route.fulfill({
      status: 201,
      json: {
        job_id: JOB_ID,
        upload_url: "https://mock-s3.example/upload",
        upload_method: "PUT",
        upload_headers: { "Content-Type": "video/mp4" },
        expires_in: 900,
      },
    }),
  );
  if (jobJson) await page.route(`**/jobs/${JOB_ID}`, (route) => route.fulfill({ json: jobJson }));
  // Media "S3" with Range support: Chrome can only seek a video whose server answers 206.
  await page.route("https://mock-media.example/**", (route) => {
    const media = route.request().url().includes("original") ? ORIGINAL : VIDEO;
    const range = /bytes=(\d+)-(\d*)/.exec(route.request().headers()["range"] ?? "");
    const headers = { "Accept-Ranges": "bytes", "Content-Type": "video/webm" };
    if (!range) return route.fulfill({ body: media, headers });
    const start = Number(range[1]);
    const end = range[2] ? Math.min(Number(range[2]), media.length - 1) : media.length - 1;
    return route.fulfill({
      status: 206,
      body: media.subarray(start, end + 1),
      headers: { ...headers, "Content-Range": `bytes ${start}-${end}/${media.length}` },
    });
  });
}

async function pickFile(page: Page) {
  await page.locator('input[type="file"]').setInputFiles({ name: FILE, mimeType: "video/mp4", buffer: Buffer.alloc(2048) });
}

async function videoReady(page: Page) {
  await page.locator(".screen video").evaluate(
    (v: HTMLVideoElement) =>
      new Promise<void>((resolve) => {
        if (v.readyState >= 2) return resolve();
        v.addEventListener("loadeddata", () => resolve(), { once: true });
      }),
  );
}

/** Pause at `t` and wait until that frame is painted, so the screenshot shows it. */
async function seekAndPaint(page: Page, t: number) {
  await page.locator(".screen video").evaluate(
    (v: HTMLVideoElement, t: number) =>
      new Promise<void>((resolve) => {
        v.pause();
        v.requestVideoFrameCallback(() => resolve());
        v.currentTime = t;
      }),
    t,
  );
}

/**
 * Screenshots show a clean paused frame: the app shows native controls once a
 * video has started, and their bar would cover the burned-in caption.
 */
async function hideControls(page: Page) {
  await page.locator(".screen video").evaluate((v: HTMLVideoElement) => (v.controls = false));
}

/** Quality floor for every state, then a full-page screenshot. */
async function shot(page: Page, name: string) {
  await page.evaluate(() => document.fonts.ready);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow, `${name}: page is ${overflow}px wider than the viewport`).toBeLessThanOrEqual(0);
  // Touch targets: every visible button and button-styled link is at least 44 px tall.
  const small = await page
    .locator("button:visible, a.button:visible, .topbar a:visible")
    .evaluateAll((els) =>
      els
        .map((el) => ({ text: (el.textContent || el.getAttribute("aria-label") || "").trim(), h: el.getBoundingClientRect().height }))
        .filter((t) => t.h < 44),
    );
  expect(small, `${name}: controls under 44 px`).toEqual([]);
  await page.screenshot({ path: `screenshots/${test.info().project.name}-${name}.png`, fullPage: true, animations: "disabled" });
}

/**
 * The README image: the first-visit screen at 1280 px, cropped just below the
 * upload and "How it works" cards (so "Your videos" stays out). Written next
 * to the other screenshots; copied to docs/ui.png by hand.
 */
async function readmeShot(page: Page) {
  if (test.info().project.name !== "1280") return;
  const bottom = await page
    .locator(".upload, .how")
    .evaluateAll((els) => Math.max(...els.map((el) => el.getBoundingClientRect().bottom + window.scrollY)));
  await page.screenshot({
    path: "screenshots/docs-ui.png",
    clip: { x: 0, y: 0, width: 1280, height: Math.ceil(bottom) + 16 },
    animations: "disabled",
  });
}

const stageTitle = (page: Page) => page.locator(".screen__title");
const chips = (page: Page) => page.locator(".videos__row .chip").allInnerTexts();

test("first visit", async ({ page }) => {
  await setup(page, { seeded: [] });
  await page.goto("/");
  await expect(page.locator(".dropzone")).toHaveAttribute("data-large", "true");
  await expect(page.getByRole("heading", { name: "How it works" })).toBeVisible();
  await expect(page.locator(".how__steps li")).toHaveCount(4);
  await expect(page.locator(".videos__empty")).toBeVisible();
  await shot(page, "first-visit");
  await readmeShot(page);
});

test("uploading", async ({ page }) => {
  await setup(page, { upload: "hold" });
  await page.goto("/");
  await pickFile(page);
  await expect(stageTitle(page)).toHaveText("Uploading 42%");
  await expect(page.locator(".steps li").first()).toHaveAttribute("data-state", "active");
  await expect(page.getByRole("button", { name: "Choose a file" })).toBeDisabled();
  await shot(page, "uploading");
});

test("queued", async ({ page }) => {
  await setup(page, { jobJson: job("pending") });
  await page.goto("/");
  await pickFile(page);
  await expect(stageTitle(page)).toHaveText("Waiting for a worker");
  expect((await chips(page))[0]).toBe("Queued");
  await expect(page).toHaveURL(new RegExp(`\\?job=${JOB_ID}$`));
  await shot(page, "queued");
});

test("queued over 30 s explains the worker start", async ({ page }) => {
  // Opened from a link: queued since its last update, 45 s ago.
  await setup(page, { jobJson: job("pending", { updated_at: Math.floor(NOW / 1000) - 45 }) });
  await page.goto(`/?job=${JOB_ID}`);
  await expect(stageTitle(page)).toHaveText("Starting a worker");
  await expect(page.locator(".screen__detail")).toContainText("about 3 minutes");
  await expect(page.locator(".stage__title")).toHaveText(FILE); // name from the API, not this device
  await shot(page, "queued-slow");
});

test("processing", async ({ page }) => {
  await setup(page, { jobJson: job("processing") });
  await page.goto("/");
  await pickFile(page);
  await expect(stageTitle(page)).toHaveText("Transcribing, captioning and voicing");
  const states = await page.locator(".steps li").evaluateAll((els) => els.map((el) => el.getAttribute("data-state")));
  expect(states).toEqual(["done", "done", "active", "todo"]);
  expect((await chips(page))[0]).toBe("Processing");
  await shot(page, "processing");
});

test("ready", async ({ page }) => {
  await setup(page, { jobJson: DONE });
  await page.goto("/");
  await pickFile(page);
  await expect(page.getByRole("link", { name: "Download video" })).toBeVisible();
  await videoReady(page);
  await expect(page.locator(".stage__meta")).toHaveText(`${formatClock(FIXTURE.durationS)} · Ready in 3 min 10 s`);
  await expect(page.locator(".track__block")).toHaveCount(SEGMENTS.length);
  await expect(page.locator(".did__tiles li")).toHaveText([
    new RegExp(`Transcribed\\s*${SEGMENTS.length} caption segments`),
    /Captioned\s*Burned into the video/,
    new RegExp(`Voiced\\s*${FIXTURE.voice}, Amazon Polly`),
    new RegExp(`Rendered\\s*MP4, ${formatClock(FIXTURE.durationS)}`),
  ]);
  expect((await chips(page))[0]).toBe("Ready");
  await shot(page, "ready");
});

test("ready, playing: the caption track follows playback", async ({ page }) => {
  await setup(page, { jobJson: DONE });
  await page.goto(`/?job=${JOB_ID}`);
  await videoReady(page);
  await page.getByRole("button", { name: "Play video" }).click();
  const video = page.locator(".screen video");
  await expect(video).toHaveAttribute("controls", "");
  // Pause inside a caption, then after the last one (the video runs on past it).
  await seekAndPaint(page, SHOT_T);
  await expect(page.locator('.track__block[data-active="true"]')).toHaveText(SEGMENTS[SHOT].text);
  await hideControls(page);
  await shot(page, "ready-playing");
  await video.evaluate((v: HTMLVideoElement, t: number) => (v.currentTime = t), SEGMENTS[SEGMENTS.length - 1].end + 0.5);
  await expect(page.locator('.track__block[data-active="true"]')).toHaveCount(0);
});

test("toggle switches to the original and keeps the position", async ({ page }) => {
  await setup(page, { jobJson: DONE });
  await page.goto(`/?job=${JOB_ID}`);
  await videoReady(page);
  const reelops = page.getByRole("button", { name: "ReelOps version" });
  const original = page.getByRole("button", { name: "Original" });
  await expect(reelops).toHaveAttribute("aria-pressed", "true");
  await page.getByRole("button", { name: "Play video" }).click();
  const video = page.locator(".screen video");
  await video.evaluate((v: HTMLVideoElement) => {
    v.pause();
    v.currentTime = 5;
  });
  await original.click();
  await expect(original).toHaveAttribute("aria-pressed", "true");
  await expect(reelops).toHaveAttribute("aria-pressed", "false");
  await expect(video).toHaveAttribute("src", /original\.webm/);
  await expect.poll(() => video.evaluate((v: HTMLVideoElement) => Math.round(v.currentTime))).toBe(5);
});

test("failed", async ({ page }) => {
  await setup(page, {
    jobJson: job("failed", { error: `${FILE} has no audio stream. ReelOps needs a narrated recording to transcribe.` }),
  });
  await page.goto("/");
  await pickFile(page);
  await expect(page.getByRole("alert")).toContainText("This recording has no sound");
  await expect(page.getByRole("alert")).toContainText("microphone on");
  const states = await page.locator(".steps li").evaluateAll((els) => els.map((el) => el.getAttribute("data-state")));
  expect(states).toEqual(["done", "done", "failed", "todo"]);
  expect((await chips(page))[0]).toBe("Failed");
  await shot(page, "failed");
});

test("a rejected file explains how to fix it", async ({ page }) => {
  await setup(page);
  await page.goto("/");
  await page.locator('input[type="file"]').setInputFiles({ name: "notes.pdf", mimeType: "application/pdf", buffer: Buffer.alloc(10) });
  await expect(page.locator(".upload .alert")).toHaveText("That file is a .pdf. Choose an MP4, MOV or WebM recording.");
});

test("copy job link puts the ?job= URL on the clipboard", async ({ page, context, browserName }) => {
  test.skip(browserName !== "chromium");
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await setup(page, { jobJson: DONE });
  await page.goto(`/?job=${JOB_ID}`);
  await page.getByRole("button", { name: "Copy job link" }).click();
  await expect(page.getByRole("button", { name: "Link copied" })).toBeVisible();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(`http://127.0.0.1:4173/?job=${JOB_ID}`);
});

test("keyboard: skip link, visible focus ring, reopen a video", async ({ page }) => {
  await setup(page);
  await page.route("**/jobs/a2", (route) =>
    route.fulfill({ json: { ...job("failed", { error: "no speech detected in input.mp4" }), job_id: "a2", filename: null } }),
  );
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible(); // rendered before the first Tab

  await page.keyboard.press("Tab");
  await expect(page.getByRole("link", { name: "Skip to content" })).toBeFocused();
  for (let i = 0; i < 4; i++) await page.keyboard.press("Tab"); // brand, 2 links, Choose a file
  const choose = page.getByRole("button", { name: "Choose a file" });
  await expect(choose).toBeFocused();
  const ring = await choose.evaluate((el) => `${getComputedStyle(el).outlineStyle} ${getComputedStyle(el).outlineColor}`);
  expect(ring).toBe("solid rgb(16, 19, 24)"); // 2 px ink ring

  await page.keyboard.press("Tab");
  await expect(page.locator(".videos__row").first()).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(page.getByRole("alert")).toContainText("No speech was found");
  await expect(page.locator(".videos__row").first()).toHaveAttribute("aria-current", "true");
  await expect(page.locator(".stage__title")).toHaveText("onboarding-tour.mov"); // no API name: the local one
});

// ---- API outages (drill 5: replacing the only API task gave ~20 s of 503s) ----

test("opening a job during an API outage waits instead of failing", async ({ page }) => {
  await setup(page);
  let calls = 0;
  await page.route(`**/jobs/${JOB_ID}`, (route) =>
    ++calls <= 3 ? route.fulfill({ status: 503, body: "Service Unavailable" }) : route.fulfill({ json: DONE }),
  );
  await page.goto(`/?job=${JOB_ID}`);
  await expect(stageTitle(page)).toHaveText("Loading this video");
  await expect(page.getByRole("link", { name: "Download video" })).toBeVisible({ timeout: 15_000 });
  expect(calls).toBeGreaterThan(3);
  await expect(page.locator(".failure")).toHaveCount(0);
  await expect(page.locator(".notice")).toHaveCount(0); // a short outage stays quiet
});

test("a long outage shows a non-fatal notice and keeps polling", async ({ page }) => {
  await page.clock.install();
  await setup(page);
  let down = true;
  await page.route(`**/jobs/${JOB_ID}`, (route) =>
    down ? route.fulfill({ status: 503, body: "Service Unavailable" }) : route.fulfill({ json: job("processing") }),
  );
  await page.goto(`/?job=${JOB_ID}`);
  for (let i = 0; i < 16; i++) {
    await page.clock.runFor(2_000); // one poll interval
    await page.waitForTimeout(30); // let that poll's request settle
  }
  await expect(page.locator(".notice")).toHaveText("Having trouble reaching ReelOps. Still trying…");
  await expect(page.locator(".failure")).toHaveCount(0);
  down = false;
  await page.clock.runFor(2_000);
  await expect(stageTitle(page)).toHaveText("Transcribing, captioning and voicing");
  await expect(page.locator(".notice")).toHaveCount(0);
});

test("a job that no longer exists still says so", async ({ page }) => {
  await setup(page);
  await page.route(`**/jobs/${JOB_ID}`, (route) => route.fulfill({ status: 404, json: { detail: "job not found" } }));
  await page.goto(`/?job=${JOB_ID}`);
  await expect(page.getByRole("alert")).toContainText("That job no longer exists");
});
