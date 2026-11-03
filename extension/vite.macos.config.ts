import { resolve } from "node:path"

import { defineConfig } from "vite-plus"

export default defineConfig({
  build: {
    outDir: resolve(import.meta.dirname, "../mac/.generated"),
    target: "safari17",
    lib: {
      entry: resolve(import.meta.dirname, "src/macos-content.ts"),
      name: "ChessTVAdapter",
      formats: ["iife"],
      fileName: () => "adapter.js",
    },
  },
})
