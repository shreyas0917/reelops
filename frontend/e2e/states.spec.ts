import { appendFileSync, readFileSync } from "node:fs";

import { expect, test, type Page } from "@playwright/test";

const JOB_ID = "6f1d2c3a-4b5e-4f60-8a71-92b3c4d5e6f7";
const NOW = Date.now();
const H = 3600_000;

// Realistic recent jobs, so the list isn't empty in the screenshots.
const SEEDED = [
  { id: "a1", title: "billing-settings-walkthrough.mp4", status: "failed", createdAt: NOW - 3 * H },
  { id: "a2", title: "onboarding-tour.mov", status: "done", createdAt: NOW - 26 * H },
  { id: "a3", title: "q3-roadmap-demo.webm", status: "done", createdAt: NOW - 4 * 24 * H },
];

const job = (status: string, extra: Record<string, unknown> = {}) => ({
  job_id: JOB_ID,
  status,
  error: null,
  attempts: status === "pending" ? 0 : 1,
  created_at: Math.floor(NOW / 1000),
  updated_at: Math.floor(NOW / 1000),
  download_url: null,
  preview_url: null,
  ...extra,
});

/** Mock the API and the S3 upload; `upload` = "hold" stops at 42%. */
async function setup(page: Page, upload: "hold" | "complete", jobJson?: object) {
  await page.addInitScript(
    ({ seeded, mode }) => {
      localStorage.setItem("reelops.recent", JSON.stringify(seeded));
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
    { seeded: SEEDED, mode: upload },
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
  await page.route("https://mock-media.example/**", (route) =>
    route.fulfill({ body: readFileSync("e2e/fixtures/done.webm"), contentType: "video/webm" }),
  );
}

async function pickFile(page: Page) {
  await page.locator('input[type="file"]').setInputFiles({
    name: "product-tour-final.mp4",
    mimeType: "video/mp4",
    buffer: Buffer.alloc(2048),
  });
}

async function shot(page: Page, name: string) {
  await page.evaluate(() => document.fonts.ready);
  // Quality floor: no horizontal scrolling at any width.
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow, `${name}: page is ${overflow}px wider than the viewport`).toBeLessThanOrEqual(0);
  // Layout-shift check: the timeline must sit at the same y in every state.
  const top = await page.locator(".timeline").evaluate((el) => Math.round(el.getBoundingClientRect().top + window.scrollY));
  appendFileSync("screenshots/positions.txt", `${test.info().project.name} ${name} ${top}\n`);
  await page.screenshot({ path: `screenshots/${test.info().project.name}-${name}.png`, fullPage: true, animations: "disabled" });
}

const caption = (page: Page) => page.locator(".caption");

test("empty", async ({ page }) => {
  await setup(page, "hold");
  await page.goto("/");
  await expect(caption(page)).toHaveText("Drop a screen recording here");
  await shot(page, "empty");
});

test("uploading", async ({ page }) => {
  await setup(page, "hold");
  await page.goto("/");
  await pickFile(page);
  await expect(caption(page)).toHaveText("Uploading 42%");
  await shot(page, "uploading");
});

test("queued", async ({ page }) => {
  await setup(page, "complete", job("pending"));
  await page.goto("/");
  await pickFile(page);
  await expect(caption(page)).toHaveText("Waiting for a worker to start");
  await shot(page, "queued");
});

test("processing", async ({ page }) => {
  await setup(page, "complete", job("processing"));
  await page.goto("/");
  await pickFile(page);
  await expect(caption(page)).toHaveText("Writing captions and voiceover");
  await shot(page, "processing");
});

test("done", async ({ page }) => {
  await setup(
    page,
    "complete",
    job("done", {
      preview_url: "https://mock-media.example/preview.webm",
      download_url: "https://mock-media.example/download.mp4",
    }),
  );
  await page.goto("/");
  await pickFile(page);
  await expect(caption(page)).toHaveText("Ready to watch");
  const video = page.locator("video");
  await expect(video).toBeVisible();
  await video.evaluate(
    (v: HTMLVideoElement) =>
      new Promise<void>((resolve) => {
        if (v.readyState >= 2) return resolve();
        v.addEventListener("loadeddata", () => resolve(), { once: true });
      }),
  );
  await expect(page.getByRole("link", { name: "Download video" })).toBeVisible();
  await shot(page, "done");

  // Pressing play: playback starts, our caption, scrim and blur go, controls appear.
  await page.getByRole("button", { name: "Play video" }).press("Enter");
  await expect(caption(page)).toHaveCount(0);
  await expect(video).toHaveAttribute("controls", "");
  expect(await video.evaluate((v: HTMLVideoElement) => v.paused)).toBe(false);
  await expect(page.locator(".screen__scrim")).toHaveCount(0);
});

test("clicking the finished video doesn't open the file picker", async ({ page }) => {
  await setup(page, "complete", job("done", { preview_url: "https://mock-media.example/p.webm", download_url: "https://mock-media.example/d.mp4" }));
  await page.goto("/");
  await pickFile(page);
  await expect(caption(page)).toHaveText("Ready to watch");
  const chooser = page.waitForEvent("filechooser", { timeout: 1000 }).then(() => true, () => false);
  await page.locator(".screen").click();
  expect(await chooser).toBe(false);
});

test("failed", async ({ page }) => {
  await setup(
    page,
    "complete",
    job("failed", {
      error: "product-tour-final.mp4 has no audio stream. ReelOps needs a narrated recording to transcribe.",
    }),
  );
  await page.goto("/");
  await pickFile(page);
  await expect(caption(page)).toContainText("This recording has no sound");
  await shot(page, "failed");
});

test("keyboard: tab order, visible focus ring, reopen a recent job", async ({ page }) => {
  await setup(page, "hold");
  await page.route("**/jobs/a1", (route) =>
    route.fulfill({ json: { ...job("failed", { error: "no speech detected in input.mp4" }), job_id: "a1" } }),
  );
  await page.goto("/");

  await page.keyboard.press("Tab");
  const choose = page.getByRole("button", { name: "Choose a recording" });
  await expect(choose).toBeFocused();
  const ring = await choose.evaluate((el) => getComputedStyle(el).outlineStyle + " " + getComputedStyle(el).outlineColor);
  expect(ring).toBe("solid rgb(242, 214, 75)"); // 2 px yellow focus ring

  await page.keyboard.press("Tab");
  const firstRow = page.locator(".recent__row").first();
  await expect(firstRow).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(caption(page)).toContainText("No speech was found");
});
