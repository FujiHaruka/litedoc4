import { memberNames, moduleMain, upgradeImports } from "./draw-module.js";
import { indexContent, notFoundContent, referencesContent } from "./draw-plain.js";
import { moduleFrame, plainFrame } from "./frame.js";
import { decoded, hashHref } from "./hash-route.js";
import { FOUNDATIONAL_TYPES, type Linker } from "./links.js";
import { pagePath } from "./names.js";
import { dataJson } from "./store-data.js";
import type {
  ContentItem,
  FrontPageFile,
  PageFile,
  ReferenceItem,
  VersionFile,
} from "./store-types.js";
import type { ModulesFile } from "./types.js";

export type Mode = "path" | "hash";

export interface Place {
  readonly root: string;
  readonly version: string;
  readonly data: string;
  readonly mode: Mode;
  readonly query: string;
  readonly anchor: string | null;
}

export type Route =
  | (Place & {
      readonly kind: "module";
      readonly module: string;
      readonly page: string;
      readonly usedBy: string;
    })
  | (Place & { readonly kind: "index" })
  | (Place & { readonly kind: "references"; readonly references: string })
  | (Place & { readonly kind: "search" })
  | (Place & { readonly kind: "foundational" })
  | (Place & { readonly kind: "not-found"; readonly asked: string; readonly guess: string });

export interface Arrival {
  readonly search: string;
  readonly hash: string;
}

export function routeOf(ds: DOMStringMap, at: Arrival): Route | null {
  const { root, version, data } = ds;
  if (root === undefined || version === undefined || data === undefined) return null;
  const place: Place = {
    root,
    version,
    data,
    mode: "path",
    query: at.search,
    anchor: at.hash.length > 1 ? decoded(at.hash.slice(1)) : null,
  };
  if (ds.page !== undefined) {
    return {
      ...place,
      kind: "module",
      module: ds.module ?? "",
      page: ds.page,
      usedBy: ds.usedBy ?? "",
    };
  }
  if (ds.references !== undefined)
    return { ...place, kind: "references", references: ds.references };
  if (ds.kind === "search") return { ...place, kind: "search" };
  if (ds.kind === "foundational") return { ...place, kind: "foundational" };
  if (ds.kind === "not-found") {
    return { ...place, kind: "not-found", asked: ds.asked ?? "", guess: ds.guess ?? "" };
  }
  return { ...place, kind: "index" };
}

export function pageIn(r: Route): string {
  if (r.kind === "module") return pagePath(r.module);
  if (r.kind === "references") return "references.html";
  if (r.kind === "search") return "search.html";
  if (r.kind === "foundational") return FOUNDATIONAL_TYPES;
  return "index.html";
}

export const hrefIn = (r: Place, path: string): string =>
  r.mode === "hash" ? hashHref(r.version, path) : `${r.root}${r.version}/${path}`;

export const pathHere = (r: Route, anchor: string | null): string =>
  pageIn(r) + (r.kind === "search" ? r.query : "") + (anchor === null ? "" : `#${anchor}`);

export const sameView = (a: Route, b: Route): boolean =>
  a.kind === b.kind &&
  a.mode === b.mode &&
  a.version === b.version &&
  pathHere(a, null) === pathHere(b, null) &&
  (a.kind !== "not-found" || b.kind !== "not-found" || a.asked === b.asked);

const linkerOf = (r: Route, version: VersionFile, roots: readonly string[]): Linker => ({
  at: (path) => hrefIn(r, path),
  here: (anchor) => (r.mode === "hash" ? hrefIn(r, pathHere(r, anchor)) : `#${anchor}`),
  roots,
  bases: version.roots,
});

const titled = (page: string, title: string): string =>
  title && title !== page ? `${page} · ${title}` : page;

export interface Drawn {
  readonly title: string;
  readonly nodes: Node[];
  readonly plain: boolean;
  readonly version: VersionFile;
  readonly linker: Linker;
}

async function drawModule(r: Extract<Route, { kind: "module" }>): Promise<Drawn> {
  const [version, page] = await Promise.all([
    dataJson<VersionFile>(r.root, r.data),
    dataJson<PageFile>(r.root, r.page),
  ]);
  const content =
    page.content === null ? [] : await dataJson<readonly ContentItem[]>(r.root, page.content);
  const l = linkerOf(r, version, page.roots);
  const main = moduleMain({ linker: l, version, page, content });
  main.querySelector<HTMLDetailsElement>(".modmeta .imports:not([data-fill])")?.addEventListener(
    "toggle",
    () => {
      void dataJson<ModulesFile>(r.root, version.modules).then((m) =>
        upgradeImports(main, l, m.modules, page.module),
      );
    },
    { once: true },
  );
  return {
    title: titled(page.module, version.title),
    nodes: moduleFrame(l, version.title, memberNames(content), main),
    plain: false,
    version,
    linker: l,
  };
}

async function drawIndex(r: Route): Promise<Drawn> {
  const version = await dataJson<VersionFile>(r.root, r.data);
  const [modules, front] = await Promise.all([
    dataJson<ModulesFile>(r.root, version.modules),
    version.front === null ? null : dataJson<FrontPageFile>(r.root, version.front),
  ]);
  const l = linkerOf(r, version, []);
  return {
    title: version.title,
    nodes: plainFrame(l, version.title, ...indexContent(l, version, modules, front)),
    plain: true,
    version,
    linker: l,
  };
}

async function drawReferences(r: Extract<Route, { kind: "references" }>): Promise<Drawn> {
  const [version, items] = await Promise.all([
    dataJson<VersionFile>(r.root, r.data),
    dataJson<readonly ReferenceItem[]>(r.root, r.references),
  ]);
  const l = linkerOf(r, version, []);
  return {
    title: titled("References", version.title),
    nodes: plainFrame(l, version.title, ...referencesContent(l, items)),
    plain: true,
    version,
    linker: l,
  };
}

async function drawOwn(r: Route, name: string, own: (l: Linker) => Node[]): Promise<Drawn> {
  const version = await dataJson<VersionFile>(r.root, r.data);
  const l = linkerOf(r, version, []);
  return {
    title: titled(name, version.title),
    nodes: plainFrame(l, version.title, ...own(l)),
    plain: true,
    version,
    linker: l,
  };
}

export function draw(r: Route, own: readonly Node[]): Promise<Drawn> {
  if (r.kind === "module") return drawModule(r);
  if (r.kind === "references") return drawReferences(r);
  if (r.kind === "search") return drawOwn(r, "Search", () => [...own]);
  if (r.kind === "foundational") return drawOwn(r, "Foundational types", () => [...own]);
  if (r.kind === "not-found") {
    return drawOwn(r, "Not found", (l) => notFoundContent(l, r.asked, r.version));
  }
  return drawIndex(r);
}
