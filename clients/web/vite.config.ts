import { resolve } from "node:path";
import { defineConfig } from "vite";

// Multi-page build; the service worker must end up as /sw.js at the root so its scope
// covers the whole app.
export default defineConfig({
  build: {
    target: "es2022",
    rollupOptions: {
      input: {
        index: resolve(__dirname, "index.html"),
        probe: resolve(__dirname, "probe.html"),
        sw: resolve(__dirname, "src/sw.ts"),
      },
      output: {
        entryFileNames: (chunk) => (chunk.name === "sw" ? "sw.js" : "assets/[name]-[hash].js"),
      },
    },
  },
});
