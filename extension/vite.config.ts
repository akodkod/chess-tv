import { resolve } from "node:path"

import tailwindcss from "@tailwindcss/vite"
import { build, defineConfig, type Plugin } from "vite-plus"

import { buildSettings } from "./config"

export default defineConfig(({ mode }) => {
  const settings = buildSettings(mode, process.env.RELAY_URL)
  const root = import.meta.dirname
  const outDir = resolve(root, "dist")
  return {
    root,
    base: "./",
    define: { __SETTINGS__: JSON.stringify(settings) },
    plugins: [
      // Tailwind types reference upstream Vite; Vite+ supplies the compatible runtime.
      ...(tailwindcss() as unknown as Plugin[]),
      {
        name: "extension-assets",
        generateBundle() {
          this.emitFile({
            type: "asset",
            fileName: "manifest.json",
            source: JSON.stringify(settings.manifest, null, 2),
          })
        },
        async closeBundle() {
          await build({
            configFile: false,
            root,
            define: { __SETTINGS__: JSON.stringify(settings) },
            build: {
              outDir,
              emptyOutDir: false,
              target: "chrome116",
              lib: {
                entry: resolve(root, "src/content.ts"),
                name: "ChessTVContent",
                formats: ["iife"],
                fileName: () => "content.js",
              },
            },
          })
        },
      },
    ],
    build: {
      outDir,
      target: "chrome116",
      rolldownOptions: {
        input: { popup: resolve(root, "popup.html"), worker: resolve(root, "src/worker.ts") },
        output: { entryFileNames: "[name].js" },
      },
    },
  }
})
