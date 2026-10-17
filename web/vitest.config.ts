import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Not a browser and not pretending to be: `tools/mv-pages-gate.sh` is what
    // answers "does the site work".
    environment: "happy-dom",
    include: ["test/**/*.test.ts"],
  },
});
