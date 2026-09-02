/**
 * The one bundle the generated site loads.
 *
 * `LITEDOC4_ASSET_OUT_DIR` is where the build writes; a bare `npm run build`
 * writes to `dist/` instead, which is gitignored. What the executable carries is
 * `assets/app.js`, committed, because Lean has no `include_str!` and
 * `tools/gen-assets.py` writes those bytes into `src/Litedoc4/Assets.lean`. A
 * committed build output cannot announce that it went stale, so
 * `tools/assets-gate.sh` rebuilds and compares it byte for byte.
 */
import { defineConfig } from "vitest/config";

const outDir = process.env.LITEDOC4_ASSET_OUT_DIR ?? "dist";

export default defineConfig({
  build: {
    outDir,
    // The output directory may hold other things: this writes into it, never
    // over it.
    emptyOutDir: false,
    // `lib` rather than an HTML entry: there is no HTML here — the pages are
    // written by the renderer — and they want one file with no imports to
    // resolve.
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
