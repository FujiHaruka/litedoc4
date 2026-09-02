/**
 * `search-index.bin`, read in place: the page holds the file, not a parsed copy
 * of it. The layout is `src/Litedoc4/Global/SearchIndex.lean`, and the
 * JSON this replaces cost 860 KiB of JS heap for a 405,402 B file
 * (measured → `benchmarks/results/search-design-2026-08-19.txt`).
 *
 * `tsconfig.json`'s `noUncheckedIndexedAccess` is wrong here: every byte read
 * below is at an offset the format guarantees, and a truncated file fails the
 * header check in `readIndex` and never reaches these walks. So the reads
 * assert, and `biome.json` allows that in this file and in `search.ts` only.
 */
import { room, scratch } from "./scratch.js";
import type { SearchIndex } from "./types.js";

const MAGIC = 0x53_34_44_4c; // "LD4S" read little-endian
const VERSION = 2;
const HEADER = 52;

export const TEXT = new TextDecoder();
export const ENCODER = new TextEncoder();
export const DOT = 46;

/** ASCII lowering. The names it is wrong for are carried in the file. */
export const FOLD = new Uint8Array(256);
for (let i = 0; i < 256; i++) FOLD[i] = i >= 65 && i <= 90 ? i + 32 : i;

export function readIndex(bytes: Uint8Array): SearchIndex | null {
  const u32 = (at: number): number =>
    // biome-ignore lint/style/noNonNullAssertion: offsets the format guarantees
    (bytes[at]! | (bytes[at + 1]! << 8) | (bytes[at + 2]! << 16)) + bytes[at + 3]! * 0x100_0000;
  // biome-ignore lint/style/noNonNullAssertion: offsets the format guarantees
  const u16 = (at: number): number => bytes[at]! | (bytes[at + 1]! << 8);
  if (bytes.length < HEADER || u32(0) !== MAGIC || u32(4) !== VERSION) return null;

  const count = u32(8);
  const index: SearchIndex = {
    bytes,
    count,
    names: u32(16),
    restarts: u32(24),
    restart: u32(12),
    kindOf: u32(36),
    moduleOf: u32(40),
    labels: [],
    folds: new Map(),
    narrow: null,
    score: new Uint16Array(count),
    length: new Uint16Array(count),
    id: count < 65536 ? new Uint16Array(count) : new Uint32Array(count),
  };

  const labelsAt = u32(28);
  let at = labelsAt + 4;
  for (let i = 0, n = u32(labelsAt); i < n; i++) {
    // biome-ignore lint/style/noNonNullAssertion: offsets the format guarantees
    const len = bytes[at]!;
    index.labels.push(TEXT.decode(bytes.subarray(at + 1, at + 1 + len)));
    at += 1 + len;
  }

  // The names `toLowerCase()` does something to that adding 32 to `A`-`Z` does
  // not — `Γ` and its like. Empty for every package measured so far.
  const foldsAt = u32(44);
  at = foldsAt + 4;
  for (let i = 0, n = u32(foldsAt); i < n; i++) {
    const len = u16(at + 4);
    index.folds.set(u32(at), bytes.subarray(at + 6, at + 6 + len));
    at += 6 + len;
  }
  return index;
}

/**
 * UTF-16 length, which is what the scoring counts (`String.prototype.length`)
 * and **not** the code point count: a character above the BMP is two units, so
 * a 4-byte UTF-8 sequence counts twice. The score is `2000 - length`, so one
 * unit is one place in the list (measured 2026-08-19, browser gate).
 */
export function utf16Length(bytes: Uint8Array, from: number, to: number): number {
  let n = 0;
  for (let i = from; i < to; i++) {
    // biome-ignore lint/style/noNonNullAssertion: `from`..`to` is a decoded name
    const byte = bytes[i]!;
    if ((byte & 0xc0) !== 0x80) n += byte >= 0xf0 ? 2 : 1;
  }
  return n;
}

export function nameAt(index: SearchIndex, id: number): string {
  const bytes = index.bytes;
  const block = Math.floor(id / index.restart);
  const restartAt = index.restarts + block * 4;
  let at =
    index.names +
    // biome-ignore lint/style/noNonNullAssertion: the restart table has one entry per block
    ((bytes[restartAt]! | (bytes[restartAt + 1]! << 8) | (bytes[restartAt + 2]! << 16)) +
      // biome-ignore lint/style/noNonNullAssertion: the restart table has one entry per block
      bytes[restartAt + 3]! * 0x100_0000);
  let out = new Uint8Array(256);
  let end = 0;
  for (let i = block * index.restart; i <= id; i++) {
    // biome-ignore lint/style/noNonNullAssertion: offsets the format guarantees
    const shared = bytes[at++]!;
    // biome-ignore lint/style/noNonNullAssertion: offsets the format guarantees
    let len = bytes[at++]!;
    if (len === 255) {
      // biome-ignore lint/style/noNonNullAssertion: offsets the format guarantees
      len = bytes[at]! | (bytes[at + 1]! << 8);
      at += 2;
    }
    if (shared + len > out.length) {
      const grown = new Uint8Array(Math.max(shared + len, out.length * 2));
      grown.set(out);
      out = grown;
    }
    out.set(bytes.subarray(at, at + len), shared);
    at += len;
    end = shared + len;
  }
  return TEXT.decode(out.subarray(0, end));
}

export const kindAt = (index: SearchIndex, id: number): string =>
  // biome-ignore lint/style/noNonNullAssertion: one kind byte per declaration
  index.labels[index.bytes[index.kindOf + id]!] ?? "";

/** The subscript, into `modules.json`'s array, of `id`'s module. */
export const moduleAt = (index: SearchIndex, id: number): number =>
  // biome-ignore lint/style/noNonNullAssertion: one u16 per declaration
  index.bytes[index.moduleOf + id * 2]! | (index.bytes[index.moduleOf + id * 2 + 1]! << 8);

/**
 * Where each of `names` is, as one walk of the index: front coding is read
 * forwards, so a lookup per name would read the section once per name.
 */
export function findNames(index: SearchIndex, names: readonly string[]): Map<string, number> {
  const wanted = new Set(names);
  const found = new Map<string, number>();
  const bytes = index.bytes;
  let at = index.names;
  for (let i = 0; i < index.count && found.size < wanted.size; i++) {
    // biome-ignore lint/style/noNonNullAssertion: offsets the format guarantees
    const shared = bytes[at++]!;
    // biome-ignore lint/style/noNonNullAssertion: offsets the format guarantees
    let len = bytes[at++]!;
    if (len === 255) {
      // biome-ignore lint/style/noNonNullAssertion: offsets the format guarantees
      len = bytes[at]! | (bytes[at + 1]! << 8);
      at += 2;
    }
    room(shared + len);
    scratch.set(bytes.subarray(at, at + len), shared);
    at += len;
    const name = TEXT.decode(scratch.subarray(0, shared + len));
    if (wanted.has(name)) found.set(name, i);
  }
  return found;
}
