import { defineConfig } from "vite-plus"
export default defineConfig({
  lint: {
    options: {
      typeAware: true,
      typeCheck: true,
    },
  },
  fmt: {
    quoteProps: "consistent",
    semi: false,
    singleAttributePerLine: true,
    sortImports: true,
    sortTailwindcss: true,
  },
  test: {
    include: ["protocol/**/*.test.ts", "relay/**/*.test.ts"],
    testTimeout: 15000,
    hookTimeout: 15000,
  },
})
