/**
 * The one bundle the generated site loads.
 *
 * `build.rs` runs this and hands cargo's `OUT_DIR` in `LITEDOC4_ASSET_OUT_DIR`,
 * so what `include_str!` picks up is always built from the sources next to it —
 * there is no committed copy to go stale. A bare `npm run build` writes to
 * `dist/` instead, which is gitignored.
 */
import { defineConfig } from "vitest/config";

const outDir = process.env.LITEDOC4_ASSET_OUT_DIR ?? "dist";

export default defineConfig({
  build: {
    outDir,
    // `OUT_DIR` is cargo's, and it has other things in it.
    emptyOutDir: false,
    // `lib` rather than an HTML entry: there is no HTML here — the pages are
    // written by Rust — and they want one file with no imports to resolve.
    lib: {
      entry: "src/main.ts",
      formats: ["es"],
      fileName: () => "app.js",
    },
    target: "es2022",
    minify: "oxc",
    // Nothing is code-split, so there is nothing to preload.
    modulePreload: false,
    reportCompressedSize: true,
  },
  test: {
    // Not a browser and not pretending to be: `tools/browser-gate.sh` is what
    // answers "does the site work".
    environment: "happy-dom",
    include: ["test/**/*.test.ts"],
  },
});
