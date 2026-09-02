/**
 * Applies the stored theme before the first paint.
 *
 * Inlined into `<head>` by `Litedoc4.Render.Frame` as a **classic** `<script>`, not a
 * module: a module is deferred, and a theme applied after paint is a flash of
 * the wrong one. That is also why this is a second bundle — it has to be the
 * smallest thing that can run first.
 */
import { PAINTED, THEME_KEY } from "./theme-key.js";

try {
  const stored = localStorage.getItem(THEME_KEY);
  if (stored !== null && (PAINTED as readonly string[]).includes(stored)) {
    document.documentElement.dataset.theme = stored;
  }
} catch {
  // Private mode, or storage disabled. The page renders in `auto`.
}
