import { gzipSync } from "node:zlib";
import { afterEach, describe, expect, it, vi } from "vitest";
import { moduleMain } from "../src/draw-module.js";
import { indexContent } from "../src/draw-plain.js";
import { guessOf } from "../src/guess.js";
import { gunzipped, isGzip } from "../src/gzip.js";
import { hashHref, parseHash } from "../src/hash-route.js";
import { type Linker, resolvedHref, tableHref } from "../src/links.js";
import { hasPage } from "../src/listed.js";
import { hashTarget, isVersionList, lostAt, moduleOfPage, rootCandidates } from "../src/lost.js";
import { moduleComponents, pagePath, sourceUrlAt } from "../src/names.js";
import { hrefIn, pageIn, pathHere, type Route, routeOf } from "../src/route.js";
import { linkSegments } from "../src/spans.js";
import type { ContentItem, PageFile, Ref, VersionFile } from "../src/store-types.js";
import { switchTarget, versionsAt } from "../src/versions.js";
import { destination, docNodes, wordLink } from "../src/words.js";

const linker: Linker = {
  at: (path) => `../../v1/${path}`,
  here: (anchor) => `#${anchor}`,
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
    const at = { at: (p: string) => `R/${p}`, here: (a: string) => `H:${a}` };
    expect(destination("##Nat", at, has(["Nat"]))).toBe("#Nat");
    expect(destination("##Nat.succ", at, has(["succ"]))).toBe("R/search.html?q=Nat.succ");
    expect(destination("##A.«b c»", at, has([]))).toBe("R/search.html?q=A.%C2%ABb%20c%C2%BB");
    expect(destination("#local", at, has([]))).toBe("H:local");
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

describe("routeOf", () => {
  const place = { root: "../", version: "v2", data: "a" };
  const nowhere = { search: "", hash: "" };

  it("tells each shell by its attributes and puts each at its path in the version", () => {
    const shells: [Record<string, string>, string][] = [
      [{ ...place, page: "p", usedBy: "u", module: "A.«b»" }, "A/b.html"],
      [{ ...place, references: "r" }, "references.html"],
      [{ ...place, kind: "search" }, "search.html"],
      [{ ...place, kind: "foundational" }, "foundational_types.html"],
      [place, "index.html"],
    ];
    for (const [ds, path] of shells) {
      const r = routeOf(ds, nowhere);
      expect(r === null ? null : pageIn(r)).toBe(path);
    }
    expect(routeOf({ version: "v2", data: "a" }, nowhere)).toBeNull();
  });

  it("takes the query and the decoded anchor from the address it arrived at", () => {
    const r = routeOf(place, { search: "?missing=A", hash: "#A.%C2%ABb%C2%BB" });
    expect(r?.query).toBe("?missing=A");
    expect(r?.anchor).toBe("A.«b»");
    expect(routeOf(place, { search: "", hash: "#" })?.anchor).toBeNull();
  });

  it("is the not-found page when the 404 bootstrap says so", () => {
    const r = routeOf({ ...place, kind: "not-found", asked: "/x.html", guess: "x" }, nowhere);
    expect(r?.kind).toBe("not-found");
    expect(r === null ? null : pageIn(r)).toBe("index.html");
  });
});

const hashed = (r: Route | null): Route => ({ ...(r as Route), mode: "hash" });

describe("hrefIn", () => {
  const module = routeOf(
    { root: "./", version: "v1", data: "a", page: "p", module: "A.B" },
    { search: "", hash: "" },
  ) as Route;

  it("climbs to the version root in path mode and builds a hash route in hash mode", () => {
    expect(hrefIn(module, "A/B.html#A.B.f")).toBe("./v1/A/B.html#A.B.f");
    expect(hrefIn(hashed(module), "A/B.html#A.B.f")).toBe("#/v1/A/B?id=A.B.f");
    expect(hrefIn(hashed(module), "index.html")).toBe("#/v1/");
    expect(hrefIn(hashed(module), "search.html?q=a b")).toBe("#/v1/search?q=a+b");
  });

  it("keeps an anchor on the page it is on in both modes", () => {
    expect(pathHere(module, "x")).toBe("A/B.html#x");
    const search = { ...module, kind: "search", query: "?q=z" } as Route;
    expect(hrefIn(hashed(search), pathHere(search, "content"))).toBe("#/v1/search?q=z&id=content");
  });
});

describe("hash routes", () => {
  it("parses back what it builds, a name with ? and & included", () => {
    for (const [path, page, query, anchor] of [
      ["A/B.html#Option.get?&x", "A/B", "", "Option.get?&x"],
      ["index.html", "", "", null],
      ["search.html?q=Nat.succ", "search", "?q=Nat.succ", null],
      ["references.html#ref_K", "references", "", "ref_K"],
      ["Dep-Aux/«Odd».html", "Dep-Aux/«Odd»", "", null],
    ] as const) {
      expect(parseHash(hashHref("v4.1", path))).toEqual({ version: "v4.1", page, query, anchor });
    }
  });

  it("reads a route the browser percent-encoded and refuses what is not a route", () => {
    expect(parseHash("#/v1/A/%C2%ABb%C2%BB?id=A.%C2%ABb%C2%BB")).toEqual({
      version: "v1",
      page: "A/«b»",
      query: "",
      anchor: "A.«b»",
    });
    expect(parseHash("#/v1")).toEqual({ version: "v1", page: "", query: "", anchor: null });
    expect(parseHash("#Example.x")).toBeNull();
    expect(parseHash("")).toBeNull();
    expect(parseHash("#//A")).toBeNull();
  });
});

describe("the version list", () => {
  const list = [
    { name: 'v<1"', data: "a", routes: "r" },
    { name: "v2", data: "b" },
  ];

  afterEach(() => {
    delete document.body.dataset.versions;
    vi.unstubAllGlobals();
  });

  it("is read with hash URLs from the root page's own attribute, fetching nothing", async () => {
    const fetched = vi.fn(() => Promise.reject(new Error("fetched")));
    vi.stubGlobal("fetch", fetched);
    document.body.dataset.versions = JSON.stringify(list);
    expect(await versionsAt("carried/", "hash")).toEqual(list);
    expect(fetched).not.toHaveBeenCalled();
  });

  it("is read with path URLs from versions.json, never from the attribute", async () => {
    const fetched = vi.fn(() => Promise.resolve(new Response(JSON.stringify(list))));
    vi.stubGlobal("fetch", fetched);
    document.body.dataset.versions = "[]";
    expect(await versionsAt("fetched/", "path")).toEqual(list);
    expect(fetched).toHaveBeenCalledTimes(1);
  });

  it("is absent with hash URLs when the attribute is missing or no version list", async () => {
    const fetched = vi.fn(() => Promise.resolve(new Response(JSON.stringify(list))));
    vi.stubGlobal("fetch", fetched);
    expect(await versionsAt("missing/", "hash")).toBeNull();
    document.body.dataset.versions = "[{";
    expect(await versionsAt("malformed/", "hash")).toBeNull();
    document.body.dataset.versions = "[]";
    expect(await versionsAt("empty/", "hash")).toBeNull();
    expect(fetched).not.toHaveBeenCalled();
  });
});

describe("the 404 page", () => {
  it("probes every directory above the missing path for the site root, shortest first", () => {
    expect(rootCandidates("/repo/Mathlib/Foo.html")).toEqual(["/", "/repo/", "/repo/Mathlib/"]);
    expect(rootCandidates("/x.html")).toEqual(["/"]);
  });

  it("takes only a list of named versions as a versions file", () => {
    expect(isVersionList([{ name: "v1", data: "a" }])).toBe(true);
    expect(isVersionList([])).toBe(false);
    expect(isVersionList({ name: "v1" })).toBe(false);
    expect(isVersionList([{ name: "v1" }])).toBe(false);
  });

  it("tells a versioned path from an unversioned one by the version list", () => {
    const vs = ["v1", "v2"];
    expect(lostAt("Example/Basic.html", vs)).toEqual({
      kind: "unversioned",
      path: "Example/Basic.html",
    });
    expect(lostAt("v2/Example/Interval.html", vs)).toEqual({
      kind: "versioned",
      version: "v2",
      path: "Example/Interval.html",
    });
    expect(lostAt("v9/Example/Basic.html", vs).kind).toBe("unversioned");
    expect(lostAt("", vs)).toEqual({ kind: "nothing" });
    expect(moduleOfPage("Example/Interval.html")).toBe("Example.Interval");
    expect(moduleOfPage("garbage")).toBeNull();
  });

  it("sends a hash-mode site's missing path to the route of the same page", () => {
    const asked = { search: "", hash: "#Example.Colour.name" };
    expect(hashTarget("/p/", lostAt("Example/Basic.html", ["v1"]), "v1", asked)).toBe(
      "/p/#/v1/Example/Basic?id=Example.Colour.name",
    );
    expect(
      hashTarget("/", lostAt("v1/search.html", ["v1", "v2"]), "v2", { search: "?q=x", hash: "" }),
    ).toBe("/#/v1/search?q=x");
  });

  it("guesses from the fragment first, then from the path read as a name", () => {
    expect(guessOf("Example/Basic.html", "Example.%C2%ABx%C2%BB")).toBe("Example.«x»");
    expect(guessOf("/Example/Basic.html", "")).toBe("Example.Basic");
  });
});

describe("hasPage", () => {
  const modules = [{ n: "A.B", p: "A/B.html" }];

  it("answers by the version's module list, and every version has its own four pages", () => {
    expect(hasPage(modules, "A/B.html")).toBe(true);
    expect(hasPage(modules, "A/C.html")).toBe(false);
    expect(hasPage([], "A/B.html")).toBe(false);
    for (const page of [
      "index.html",
      "references.html",
      "search.html",
      "foundational_types.html",
    ]) {
      expect(hasPage([], page)).toBe(true);
    }
    expect(hasPage(modules, "A/")).toBe(false);
  });
});

describe("switchTarget", () => {
  const module = routeOf(
    { root: "../../", version: "v1", data: "a", page: "p", module: "A.B" },
    { search: "?q=x", hash: "#A.B.f" },
  ) as Route;

  it("goes to the same module and anchor when the other version has the module", () => {
    expect(switchTarget(module, "v4", [{ n: "A.B", p: "A/B.html" }])).toBe(
      "../../v4/A/B.html#A.B.f",
    );
    expect(switchTarget(hashed(module), "v4", [{ n: "A.B", p: "A/B.html" }])).toBe(
      "#/v4/A/B?id=A.B.f",
    );
  });

  it("goes to the other version's module list, naming the module, when it has none", () => {
    expect(switchTarget(module, "v4", [{ n: "A.C", p: "A/C.html" }])).toBe(
      "../../v4/index.html?missing=A.B",
    );
    expect(switchTarget(hashed(module), "v4", [])).toBe("#/v4/?missing=A.B");
  });

  it("keeps the query of a search page and the path of every other page", () => {
    const at = { search: "?q=x", hash: "#A.B.f" };
    const search = routeOf({ root: "../", version: "v1", data: "a", kind: "search" }, at) as Route;
    expect(switchTarget(search, "v2", null)).toBe("../v2/search.html?q=x#A.B.f");
    const index = routeOf({ root: "./", version: "v1", data: "a" }, { search: "", hash: "" });
    expect(switchTarget(index as Route, "v2", null)).toBe("./v2/index.html");
  });
});

describe("indexContent", () => {
  const version = { title: "T", lean: "4" } as VersionFile;

  it("shows each module's summary and the declaration count when the list carries them", () => {
    const nodes = indexContent(
      linker,
      version,
      {
        modules: [
          { n: "A", p: "A.html", s: "<code>x</code> y" },
          { n: "B", p: "B.html" },
        ],
        declarations: 1234,
      },
      null,
    );
    const host = document.createElement("div");
    host.append(...nodes);
    expect(host.querySelector(".modlist")?.className).toBe("modlist modlist-described");
    expect([...host.querySelectorAll(".modsummary")].map((e) => e.innerHTML)).toEqual([
      "<code>x</code> y",
    ]);
    expect([...host.querySelectorAll(".stats dt")].map((e) => e.textContent)).toEqual([
      "Modules",
      "Declarations",
      "Lean",
    ]);
    expect(host.querySelectorAll(".stats dd")[1]?.textContent).toBe("1,234");
  });

  it("draws a plain list and no count from a list without them", () => {
    const host = document.createElement("div");
    host.append(...indexContent(linker, version, { modules: [{ n: "A", p: "A.html" }] }, null));
    expect(host.querySelector(".modlist")?.className).toBe("modlist");
    expect(host.querySelectorAll(".stats dt").length).toBe(2);
  });
});
