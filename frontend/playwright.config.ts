import { defineConfig } from "@playwright/test";

// Screenshots of every UI state against a mocked API (no AWS).
// Run in the Playwright image after `npm run build`: npx playwright test
export default defineConfig({
  testDir: "e2e",
  outputDir: "test-results",
  reporter: "line",
  use: { baseURL: "http://127.0.0.1:4173", colorScheme: "light" },
  projects: [
    { name: "1280", use: { viewport: { width: 1280, height: 800 } } },
    { name: "380", use: { viewport: { width: 380, height: 800 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true } },
  ],
  webServer: {
    command: "npx vite preview --host 127.0.0.1 --port 4173 --strictPort",
    url: "http://127.0.0.1:4173",
    reuseExistingServer: false,
  },
});
