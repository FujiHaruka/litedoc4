/**
 * The page script every generated page loads.
 *
 * `LITEDOC4_ASSET_OUT_DIR` is where the build writes; a bare `npm run build`
 * writes to `dist/` instead, which is gitignored. What the executable carries is
 * `assets/site.js`, committed, because Lean has no `include_str!` and
 * `tools/gen-assets.py` writes those bytes into `src/Litedoc4/Assets.lean`. A
 * committed build output cannot announce that it went stale, so
 * `tools/assets-gate.sh` rebuilds and compares it byte for byte.
 */
import { defineConfig } from "vite";

const outDir = process.env.LITEDOC4_ASSET_OUT_DIR ?? "dist";

export default defineConfig({
  build: {
    outDir,
    emptyOutDir: false,
    lib: {
      entry: "src/store-page.ts",
      formats: ["es"],
      fileName: () => "site.js",
    },
    target: "es2022",
    minify: "oxc",
    modulePreload: false,
    reportCompressedSize: true,
  },
});
