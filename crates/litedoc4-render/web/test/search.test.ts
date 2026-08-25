import { describe, expect, it } from "vitest";
import { ENCODER, FOLD, nameAt } from "../src/index-format.js";
import { scoreBytes } from "../src/score.js";
import { search } from "../src/search.js";
import type { SearchIndex } from "../src/types.js";
import { freshIndex } from "./fixture.js";

const hits = (index: SearchIndex, query: string): string[] =>
  search(index, query).map((id) => nameAt(index, id));

const fold = (s: string): Uint8Array => {
  const bytes = ENCODER.encode(s);
  // biome-ignore lint/style/noNonNullAssertion: FOLD has all 256 entries
  return bytes.map((b) => FOLD[b]!);
};

describe("scoreBytes", () => {
  const q = ENCODER.encode("al");

  it("ranks a prefix of the last component above a prefix of the whole name", () => {
    const lastComponent = fold("pkg.alpha");
    const wholeName = fold("alpha.pkg");
    const asLast = scoreBytes(lastComponent, lastComponent.length, 4, q, q.length);
    const asWhole = scoreBytes(wholeName, wholeName.length, 6, q, q.length);
    expect(asLast).toBeGreaterThan(2000);
    expect(asWhole).toBeGreaterThan(1000);
    expect(asWhole).toBeLessThan(2000);
    expect(asLast).toBeGreaterThan(asWhole);
  });

  it("ranks a substring below both", () => {
    const name = fold("pkg.xxalpha");
    // `lastStart` past the match, so only the substring tier can fire.
    const score = scoreBytes(name, name.length, 4, q, q.length);
    expect(score).toBeGreaterThan(0);
    expect(score).toBeLessThan(1000 + 1);
  });

  it("does not match a subsequence", () => {
    const name = fold("pkg.a.l");
    const score = scoreBytes(name, name.length, name.length, ENCODER.encode("al"), 2);
    expect(score).toBe(-1);
  });

  it("prefers the shorter of two names in the same tier", () => {
    const short = fold("pkg.al");
    const long = fold("pkg.along");
    expect(scoreBytes(short, short.length, 4, q, q.length)).toBeGreaterThan(
      scoreBytes(long, long.length, 4, q, q.length),
    );
  });
});

describe("search", () => {
  it("puts the shortest last-component prefix first", () => {
    expect(hits(freshIndex(), "al")).toEqual(["Pkg.alpha", "Pkg.alphabet"]);
  });

  it("is case-insensitive through the fold table", () => {
    // `Pkg.Γamma` lowercases to `pkg.γamma`, which "add 32 to A-Z" does not
    // produce — the name is carried in the fold section and substituted.
    expect(hits(freshIndex(), "γamma")).toEqual(["Pkg.Γamma"]);
  });

  it("finds a name with no components", () => {
    expect(hits(freshIndex(), "nodot")).toEqual(["NoDot"]);
  });

  it("returns nothing for a query no name contains", () => {
    expect(hits(freshIndex(), "zzzz")).toEqual([]);
  });

  /**
   * `𝒜` is one code point, two UTF-16 units and four UTF-8 bytes, and the score
   * is `3000 - utf16Length(last component)`: counting bytes or code points
   * instead moves the name (measured 2026-08-19, browser gate).
   */
  it("scores an astral character as two units, not one and not four", () => {
    const q = ENCODER.encode("scr");
    const astral = fold("pkg.script\u{1D49C}"); // last component: 8 UTF-16 units, 10 bytes
    const same = fold("pkg.scriptum"); //           8 UTF-16 units, 8 bytes
    const shorter = fold("pkg.scripts"); //         7 UTF-16 units, 7 bytes
    expect(scoreBytes(astral, astral.length, 4, q, q.length)).toBe(3000 - 8);
    expect(scoreBytes(same, same.length, 4, q, q.length)).toBe(3000 - 8);
    expect(scoreBytes(shorter, shorter.length, 4, q, q.length)).toBe(3000 - 7);
  });
});

describe("the narrowed walk", () => {
  /**
   * The browser gate checks narrowing against a real site; this checks it
   * against every prefix of every query, which the gate cannot afford to.
   */
  for (const query of ["alphabet", "pkg.block.n1", "γamma", "nodot", "xxx"]) {
    it(`agrees with a cold walk while typing "${query}"`, () => {
      const typed = freshIndex();
      for (let n = 1; n <= query.length; n++) {
        const prefix = query.slice(0, n);
        expect(hits(typed, prefix), `after typing "${prefix}"`).toEqual(hits(freshIndex(), prefix));
      }
    });
  }

  it("does not reuse a cache the query does not extend", () => {
    const index = freshIndex();
    hits(index, "alpha");
    // `b` does not extend `alpha`; from that cache it would return nothing.
    expect(hits(index, "b")).toEqual(hits(freshIndex(), "b"));
  });

  it("remembers what the last query matched", () => {
    const index = freshIndex();
    hits(index, "alpha");
    expect(index.narrow?.query).toBe("alpha");
    expect(index.narrow?.ids.length).toBe(2);
  });
});
