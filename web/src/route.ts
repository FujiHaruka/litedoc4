import { memberNames, moduleMain, upgradeImports } from "./draw-module.js";
import { indexContent, referencesContent } from "./draw-plain.js";
import { moduleFrame, plainFrame } from "./frame.js";
import type { Linker } from "./links.js";
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
  | (Place & { readonly kind: "module"; readonly page: string; readonly usedBy: string })
  | (Place & { readonly kind: "index" })
  | (Place & { readonly kind: "references"; readonly references: string });

export function routeOf(ds: DOMStringMap): Route | null {
  const { root, version, data } = ds;
  if (root === undefined || version === undefined || data === undefined) return null;
  const place: Place = { root, version, data };
  if (ds.page !== undefined) {
    return { ...place, kind: "module", page: ds.page, usedBy: ds.usedBy ?? "" };
  }
  if (ds.references !== undefined)
    return { ...place, kind: "references", references: ds.references };
  return { ...place, kind: "index" };
}

export const versionRoot = (r: Route): string => `${r.root}${r.version}/`;

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
  const at = l.at;
  return {
    title: titled(page.module, version.title),
    nodes: moduleFrame({ title: version.title, at }, memberNames(content), main),
    plain: false,
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
      ...indexContent(l, version, modules.modules, front),
    ),
    plain: true,
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
  };
}

export function draw(r: Route): Promise<Drawn> {
  if (r.kind === "module") return drawModule(r);
  if (r.kind === "references") return drawReferences(r);
  return drawIndex(r);
}
