import { defineConfig } from "vite";

const outDir = process.env.LITEDOC4_ASSET_OUT_DIR ?? "dist";

export default defineConfig({
  build: {
    outDir,
    emptyOutDir: false,
    lib: {
      entry: "src/redirect.ts",
      formats: ["iife"],
      name: "litedoc4Redirect",
      fileName: () => "redirect.js",
    },
    target: "es2022",
    minify: "oxc",
    modulePreload: false,
    reportCompressedSize: false,
  },
});
