import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

// Tauri serves the dev build on a fixed port and loads the built pages from dist/.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: {
    target: "es2022",
    rollupOptions: {
      input: {
        main: "index.html",
        hud: "hud.html",
      },
    },
  },
  test: { include: ["test/**/*.test.ts"] },
});
