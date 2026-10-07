/**
 * `404.html`: says what was asked for and offers the nearest declarations. The
 * guess is the fragment when there is one — the page moved but the reader knows
 * the name — and otherwise the file name with its separators read back as dots.
 */
import { siteSource } from "./data.js";
import { guessOf, showGuesses } from "./guess.js";

export async function initNotFound(): Promise<void> {
  const shown = document.getElementById("missing-path");
  if (shown) shown.textContent = location.pathname + location.hash;
  await showGuesses(siteSource, guessOf(location.pathname, location.hash.slice(1)));
}
