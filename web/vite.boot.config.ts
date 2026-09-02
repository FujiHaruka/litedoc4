/**
 * The second bundle: the theme boot script `Litedoc4.Render.Frame` inlines into
 * `<head>`.
 *
 * A separate config rather than a second entry in `vite.config.ts`, because it
 * has to be a classic script (`iife` — a module in `<head>` is deferred and
 * would paint the wrong theme first) and standalone: one build with two entries
 * would emit the shared `theme-key.ts` as a third chunk, which cannot be
 * inlined into a `<script>` tag. The ~30 bytes are duplicated at runtime so
 * that the storage key has one place to be renamed.
 */
import { defineConfig } from "vite";

const outDir = process.env.LITEDOC4_ASSET_OUT_DIR ?? "dist";

export default defineConfig({
  build: {
    outDir,
    emptyOutDir: false,
    lib: {
      entry: "src/theme-boot.ts",
      formats: ["iife"],
      name: "litedoc4ThemeBoot",
      fileName: () => "theme-boot.js",
    },
    target: "es2022",
    minify: "oxc",
    modulePreload: false,
    reportCompressedSize: false,
  },
});
