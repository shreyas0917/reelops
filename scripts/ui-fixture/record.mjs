// Record the Fernhill walkthrough (walkthrough.json) at 1280x720 with
// Playwright. Run by scripts/make_ui_fixture.sh in the Playwright image:
//   node record.mjs <frontend dir> <work dir>
// Writes <work>/screen.webm and <work>/timing.json ({ leadInS }): the seconds
// of blank video before the page was ready, for ffmpeg to trim.

import { copyFileSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const [frontend, work] = process.argv.slice(2);
const here = dirname(fileURLToPath(import.meta.url));
const { chromium } = await import(join(frontend, "node_modules/playwright-core/index.mjs"));

const plan = JSON.parse(readFileSync(join(here, "walkthrough.json"), "utf8"));
let html = readFileSync(join(here, "fernhill.html"), "utf8");
for (const weight of [400, 500, 600, 700]) {
  const font = readFileSync(
    join(frontend, `node_modules/@fontsource/hanken-grotesk/files/hanken-grotesk-latin-${weight}-normal.woff2`),
  );
  html = html.replace(`__FONT_${weight}__`, `data:font/woff2;base64,${font.toString("base64")}`);
}

const size = { width: 1280, height: 720 };
const browser = await chromium.launch();
const context = await browser.newContext({ viewport: size, recordVideo: { dir: work, size } });
const recordingFrom = Date.now();
const page = await context.newPage();
await page.setContent(html);
await page.evaluate(() => document.fonts.ready);
const t0 = Date.now();
const mouse = { x: 640, y: 360 };
await page.mouse.move(mouse.x, mouse.y);

const sleep = (ms) => new Promise((r) => setTimeout(r, Math.max(0, ms)));
const until = (s) => sleep(s * 1000 - (Date.now() - t0));

/** Move the pointer like a hand: eased, ~60 fps, over `ms`. */
async function glide(x, y, ms = 700) {
  const from = { ...mouse };
  const frames = Math.max(1, Math.round(ms / 16));
  for (let i = 1; i <= frames; i++) {
    const t = i / frames;
    const e = t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2; // easeInOutCubic
    await page.mouse.move(from.x + (x - from.x) * e, from.y + (y - from.y) * e);
    await sleep(16);
  }
  Object.assign(mouse, { x, y });
}

async function center(selector) {
  const box = await page.locator(selector).boundingBox();
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
}

async function clickOn(selector) {
  const c = await center(selector);
  await glide(c.x, c.y, 900);
  await sleep(250);
  await page.mouse.down();
  await sleep(90);
  await page.mouse.up();
}

const ACTIONS = {
  async overview() {
    const k = await center("#kpi-revenue");
    await glide(k.x, k.y, 1200);
    await sleep(900);
    const r = await center("#recent");
    await glide(r.x - 120, r.y + 20, 1300);
  },
  async openSettings() {
    await sleep(600);
    await clickOn("#nav-settings");
  },
  async openBilling() {
    await sleep(500);
    await clickOn("#tab-billing");
    await sleep(700);
    const p = await center("#plan");
    await glide(p.x, p.y, 1000);
  },
  async editEmail() {
    await sleep(300);
    const f = await center("#email");
    await glide(f.x + 60, f.y, 900);
    await sleep(200);
    await page.mouse.click(f.x + 60, f.y, { clickCount: 3 }); // select the old address
    await sleep(300);
    await page.keyboard.type("finance@example.com", { delay: 85 });
  },
  async save() {
    await sleep(500);
    await clickOn("#save");
  },
  async outro() {
    await sleep(800);
    await glide(900, 300, 1400);
  },
};

for (const step of plan.steps) {
  await until(step.at);
  await ACTIONS[step.do]();
}
await until(plan.durationS);

const leadInS = (t0 - recordingFrom) / 1000;
const video = page.video();
await context.close(); // finishes writing the video
copyFileSync(await video.path(), join(work, "screen.webm"));
writeFileSync(join(work, "timing.json"), JSON.stringify({ leadInS }));
await browser.close();
console.log(`recorded ${plan.durationS}s walkthrough (lead-in ${leadInS.toFixed(2)}s)`);
