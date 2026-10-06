import { memberNames, moduleMain, upgradeImports } from "./draw-module.js";
import { indexContent, referencesContent } from "./draw-plain.js";
import { moduleFrame, plainFrame } from "./frame.js";
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

interface Place {
  readonly root: string;
  readonly version: string;
  readonly data: string;
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
  | (Place & { readonly kind: "foundational" });

export function routeOf(ds: DOMStringMap): Route | null {
  const { root, version, data } = ds;
  if (root === undefined || version === undefined || data === undefined) return null;
  const place: Place = { root, version, data };
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
  return { ...place, kind: "index" };
}

export const versionRoot = (r: Route): string => `${r.root}${r.version}/`;

export function pageIn(r: Route): string {
  if (r.kind === "module") return pagePath(r.module);
  if (r.kind === "references") return "references.html";
  if (r.kind === "search") return "search.html";
  if (r.kind === "foundational") return FOUNDATIONAL_TYPES;
  return "index.html";
}

const linkerOf = (r: Route, version: VersionFile, roots: readonly string[]): Linker => {
  const base = versionRoot(r);
  return { at: (path) => base + path, roots, bases: version.roots };
};

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
    nodes: moduleFrame({ title: version.title, at: l.at }, memberNames(content), main),
    plain: false,
    version,
    linker: l,
  };
}

async function drawIndex(r: Extract<Route, { kind: "index" }>): Promise<Drawn> {
  const version = await dataJson<VersionFile>(r.root, r.data);
  const [modules, front] = await Promise.all([
    dataJson<ModulesFile>(r.root, version.modules),
    version.front === null ? null : dataJson<FrontPageFile>(r.root, version.front),
  ]);
  const l = linkerOf(r, version, []);
  return {
    title: version.title,
    nodes: plainFrame(
      { title: version.title, at: l.at },
      ...indexContent(l, version, modules, front),
    ),
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
    nodes: plainFrame({ title: version.title, at: l.at }, ...referencesContent(l, items)),
    plain: true,
    version,
    linker: l,
  };
}

async function drawOwn(r: Route, name: string, own: readonly Node[]): Promise<Drawn> {
  const version = await dataJson<VersionFile>(r.root, r.data);
  const l = linkerOf(r, version, []);
  return {
    title: titled(name, version.title),
    nodes: plainFrame({ title: version.title, at: l.at }, ...own),
    plain: true,
    version,
    linker: l,
  };
}

export function draw(r: Route, name: string, own: readonly Node[]): Promise<Drawn> {
  if (r.kind === "module") return drawModule(r);
  if (r.kind === "references") return drawReferences(r);
  if (r.kind === "search" || r.kind === "foundational") return drawOwn(r, name, own);
  return drawIndex(r);
}
