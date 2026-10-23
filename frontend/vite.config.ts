import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

// In dev, /jobs and /healthz go to the API (docker compose on :8000, or set
// API_PROXY). In production the API serves the built files itself, so the
// browser only ever talks to one origin.
const api = process.env.API_PROXY ?? "http://localhost:8000";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: true,
    proxy: { "/jobs": api, "/healthz": api },
  },
  build: { outDir: "dist", sourcemap: false },
  test: { environment: "node", include: ["src/**/*.test.ts"] },
});
