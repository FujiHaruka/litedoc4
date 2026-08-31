/** The ranking — the one place the order of the result list is decided. */
import { utf16Length } from "./index-format.js";
import type { SearchIndex } from "./types.js";

/** Hits kept for the next keystroke: past this, copying costs more than the
 * walk it saves. */
export const NARROW_MAX = 512;

/**
 * Ranks a folded name against a folded query, in bytes. Three tiers, cheapest
 * first: a prefix of the last component beats a prefix of the full name, which
 * beats a substring anywhere. Nothing else matches — a subsequence matcher
 * finds `Nat.add` for `nd` and buries the exact hit.
 */
export function scoreBytes(
  name: Uint8Array,
  end: number,
  lastStart: number,
  q: Uint8Array,
  qn: number,
): number {
  if (end - lastStart >= qn) {
    let ok = true;
    for (let k = 0; k < qn; k++)
      if (name[lastStart + k] !== q[k]) {
        ok = false;
        break;
      }
    if (ok) return 3000 - utf16Length(name, lastStart, end);
  }
  if (end < qn) return -1;
  let ok = true;
  for (let k = 0; k < qn; k++)
    if (name[k] !== q[k]) {
      ok = false;
      break;
    }
  if (ok) return 2000 - utf16Length(name, 0, end);
  for (let start = 1; start <= end - qn; start++) {
    let hit = true;
    for (let k = 0; k < qn; k++)
      if (name[start + k] !== q[k]) {
        hit = false;
        break;
      }
    if (hit) return 1000 - utf16Length(name, 0, start);
  }
  return -1;
}

export function rank(index: SearchIndex, hits: number): number[] {
  const order = Array.from({ length: hits }, (_, k) => k);
  order.sort(
    (a, b) =>
      // biome-ignore lint/style/noNonNullAssertion: `a` and `b` are below `hits`
      index.score[b]! - index.score[a]! ||
      // biome-ignore lint/style/noNonNullAssertion: `a` and `b` are below `hits`
      index.length[a]! - index.length[b]! ||
      // biome-ignore lint/style/noNonNullAssertion: `a` and `b` are below `hits`
      index.id[a]! - index.id[b]!,
  );
  // biome-ignore lint/style/noNonNullAssertion: `k` came out of the same range
  return order.map((k) => index.id[k]!);
}
