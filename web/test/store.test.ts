import { gzipSync } from "node:zlib";
import { describe, expect, it } from "vitest";
import { moduleMain } from "../src/draw-module.js";
import { gunzipped, isGzip } from "../src/gzip.js";
import { type Linker, resolvedHref, tableHref } from "../src/links.js";
import { moduleComponents, pagePath, sourceUrlAt } from "../src/names.js";
import { linkSegments } from "../src/spans.js";
import type { ContentItem, PageFile, Ref, VersionFile } from "../src/store-types.js";
import { destination, docNodes, wordLink } from "../src/words.js";

const linker: Linker = {
  at: (path) => `../../v1/${path}`,
  roots: ["Init", "Std"],
  bases: { Init: "https://core/src" },
};

describe("gunzipped", () => {
  const raw = new TextEncoder().encode('{"a":1}');

  it("inflates bytes that start with the gzip magic", async () => {
    const zipped = new Uint8Array(gzipSync(raw));
    expect(isGzip(zipped)).toBe(true);
    expect(await gunzipped(zipped)).toEqual(raw);
  });

  it("passes through bytes the host already decoded", async () => {
    expect(isGzip(raw)).toBe(false);
    expect(await gunzipped(raw)).toBe(raw);
  });

  it("does not read one byte as the magic", () => {
    expect(isGzip(new Uint8Array([0x1f]))).toBe(false);
  });
});

describe("moduleComponents", () => {
  it("splits outside guillemets only, and unescapes each component", () => {
    expect(moduleComponents("Alpha.«Odd.Name».Beta")).toEqual(["Alpha", "Odd.Name", "Beta"]);
    expect(pagePath("«Dep-Aux».Basic")).toBe("Dep-Aux/Basic.html");
  });
});

describe("resolvedHref", () => {
  it("takes the key as the anchor of a one-element own target", () => {
    expect(resolvedHref(linker, "A.f", ["A.B"])).toBe("../../v1/A/B.html#A.f");
  });

  it("links a module with no anchor and an anchor that differs from the key", () => {
    expect(resolvedHref(linker, "A.f", ["A.B", null])).toBe("../../v1/A/B.html");
    expect(resolvedHref(linker, "A.f._x", ["A.B", "A.f"])).toBe("../../v1/A/B.html#A.f");
  });

  it("builds a dependency's pinned source from the page's root and the version's base", () => {
    expect(resolvedHref(linker, "Nat", [0, "Init.Prelude", 10, 20])).toBe(
      "https://core/src/Init/Prelude.lean#L10-L20",
    );
    expect(resolvedHref(linker, "Nat", [0, "Init.Prelude"])).toBe(
      "https://core/src/Init/Prelude.lean",
    );
    expect(sourceUrlAt("b", "X", null)).toBe("b/X.lean");
  });

  it("draws no link to a root the version has no base for", () => {
    expect(resolvedHref(linker, "x", [1, "Std.Data"])).toBeNull();
  });

  it("answers no link for a key the table lacks, inherited names included", () => {
    expect(tableHref(linker, { a: ["M"] }, "b")).toBeNull();
    expect(tableHref(linker, {}, "constructor")).toBeNull();
  });
});

describe("linkSegments", () => {
  const text = "f = { g := toString n }";
  const refs: Ref[] = [
    [0, 23, "Eq"],
    [0, 1, "f"],
    [2, 3, "Eq"],
    [4, 23, "mk"],
    [4, 5, "mk"],
    [11, 21, "toString"],
    [11, 19, "toString"],
    [22, 23, "mk"],
  ];
  const known = new Set(["Eq", "f", "mk", "toString"]);
  const hrefOf = (ref: Ref): string | null =>
    ref.length === 2 ? "sort" : known.has(ref[2]) ? `#${ref[2]}` : null;

  it("links the innermost resolving references and never one that holds a link", () => {
    expect(linkSegments(text, refs, hrefOf)).toEqual([
      { text: "f", href: "#f" },
      { text: " ", href: null },
      { text: "=", href: "#Eq" },
      { text: " ", href: null },
      { text: "{", href: "#mk" },
      { text: " g := ", href: null },
      { text: "toString", href: "#toString" },
      { text: " n ", href: null },
      { text: "}", href: "#mk" },
    ]);
  });

  it("lets an outer reference link when nothing under it does", () => {
    const outer = (ref: Ref): string | null => (ref.length === 3 && ref[2] === "Eq" ? "#Eq" : null);
    expect(
      linkSegments(
        "a = b",
        [
          [0, 5, "Eq"],
          [0, 1, "a"],
        ],
        outer,
      ),
    ).toEqual([{ text: "a = b", href: "#Eq" }]);
  });

  it("treats touching references as siblings and links a sort without a name", () => {
    expect(
      linkSegments(
        "Type→Prop",
        [
          [0, 4],
          [4, 5, "x"],
          [5, 9],
        ],
        hrefOf,
      ),
    ).toEqual([
      { text: "Type", href: "sort" },
      { text: "→", href: null },
      { text: "Prop", href: "sort" },
    ]);
  });

  it("counts offsets in UTF-16 units", () => {
    expect(linkSegments("𝔽 x", [[0, 2, "f"]], hrefOf)).toEqual([
      { text: "𝔽", href: "#f" },
      { text: " x", href: null },
    ]);
  });
});

describe("the docstring rule", () => {
  const has = (keys: string[]) => (k: string) => (keys.includes(k) ? `#${k}` : null);

  it("links a whole word, else its tail, else nothing", () => {
    expect(wordLink("Nat.succ", has(["Nat.succ"]))).toEqual({
      before: "",
      linked: "Nat.succ",
      href: "#Nat.succ",
    });
    expect(wordLink("Foo.succ", has(["succ"]))).toEqual({
      before: "Foo.",
      linked: "succ",
      href: "#succ",
    });
    expect(wordLink("succ", has([]))).toEqual({ before: "succ", linked: "", href: null });
  });

  it("resolves a destination as written", () => {
    const at = (p: string) => `R/${p}`;
    expect(destination("##Nat", at, has(["Nat"]))).toBe("#Nat");
    expect(destination("##Nat.succ", at, has(["succ"]))).toBe("R/find/?pattern=Nat.succ#doc");
    expect(destination("#local", at, has([]))).toBe("#local");
    expect(destination("https://x", at, has([]))).toBe("https://x");
    expect(destination("references.html#ref_K", at, has([]))).toBe("R/references.html#ref_K");
  });

  it("replaces every marked word and rewrites every href of a docstring", () => {
    const host = document.createElement("div");
    host.append(
      docNodes(
        '<p><code><w>Foo.Nat</w> <w>x</w></code> <a href="##Nat">n</a> <a href="Example/B.lean">s</a></p>',
        { Nat: [0, "Init.Prelude", 1, 2] },
        linker,
      ),
    );
    expect(host.querySelector("w")).toBeNull();
    expect(host.querySelector("code")?.innerHTML).toBe(
      'Foo.<a href="https://core/src/Init/Prelude.lean#L1-L2">Nat</a> x',
    );
    const hrefs = [...host.querySelectorAll("p > a")].map((a) => a.getAttribute("href"));
    expect(hrefs).toEqual(["https://core/src/Init/Prelude.lean#L1-L2", "../../v1/Example/B.lean"]);
  });
});

describe("moduleMain", () => {
  const version: VersionFile = {
    version: "v1",
    title: "T",
    commit: "c",
    lean: "4",
    source: "https://repo/blob/c",
    roots: { Init: "https://core/src" },
    modules: "m",
    search: "s",
    instances: "i",
    references: "r",
    front: null,
  };
  const page: PageFile = {
    module: "A.B",
    imports: ["Init"],
    content: "c",
    lines: [0, [3, 5], [7, 9]],
    roots: ["Init"],
    names: { "A.S.mk": ["A.B"], "Base.x": ["A.B"] },
    words: {},
  };
  const content: ContentItem[] = [
    {
      moddoc:
        '<h1 id="Top" class="markdown-heading">Top</h1><p><a href="references.html#ref_K" title="t" data-cite>[K]</a></p>',
    },
    {
      n: "A.S",
      k: "structure",
      p: [["A.S.toBase", "Base"]],
      t: ["Type", [[0, 4]]],
      ctor: "A.S.make",
      f: [
        { n: "Base.x", t: "Nat", inh: 1, id: 1 },
        { n: "A.S.y", t: "Nat", doc: '<p><a href="references.html#ref_K" data-cite>[K]</a></p>' },
      ],
    },
    { n: "A.I", k: "inductive", t: "Type", c: [{ n: "A.I.z", t: "A.I" }] },
  ];
  const main = moduleMain({ linker, version, page, content });
  const ids = [...main.querySelectorAll("[id]")].map((e) => e.id);

  it("gives every anchor today's page has its id, citations numbered in document order", () => {
    expect(ids).toEqual([
      "Top",
      "_backref_0",
      "A.S",
      "A.S.toBase",
      "A.S.make",
      "A.S.x",
      "A.S.y",
      "_backref_1",
      "A.I",
      "A.I.z",
    ]);
    expect(main.querySelector("[data-cite]")).toBeNull();
  });

  it("links the source of a declaration with its line range", () => {
    expect(main.querySelector("#A\\.S .src")?.getAttribute("href")).toBe(
      "https://repo/blob/c/A/B.lean#L3-L5",
    );
    expect(main.querySelector(".ctor-note code")?.textContent).toBe("make");
    expect(main.querySelector(".field.inherited a.field-name")?.getAttribute("href")).toBe(
      "../../v1/A/B.html#Base.x",
    );
  });
});
