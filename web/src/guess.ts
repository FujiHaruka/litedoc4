import { decoded } from "./hash-route.js";
import { resultItem } from "./result-item.js";
import { search } from "./search.js";
import type { SearchSource } from "./types.js";

const MAX_ROWS = 20;

export const guessOf = (path: string, fragment: string): string =>
  decoded(fragment) ||
  decoded(path)
    .replace(/\.html$/, "")
    .split("/")
    .filter(Boolean)
    .join(".");

export async function showGuesses(source: SearchSource, guess: string): Promise<void> {
  const list = document.getElementById("how-about");
  const query = guess.trim().toLowerCase();
  if (!list || query.length < 2) return;
  const data = await source.data();
  if (!data) return;
  // A prefix of the *last* component is what a moved declaration matches on, so
  // the plain scorer is already the right one.
  const hits = search(data.index, query).slice(0, MAX_ROWS);
  if (hits.length === 0) return;
  for (const id of hits) list.append(resultItem(data, id, source.href));
  document.getElementById("how-about-heading")?.removeAttribute("hidden");
}
