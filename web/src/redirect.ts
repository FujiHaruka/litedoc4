import { guessOf } from "./guess.js";
import { decoded } from "./hash-route.js";
import { hasPage, modulesIn } from "./listed.js";
import {
  hashTarget,
  isVersionList,
  lostAt,
  MISSING,
  moduleOfPage,
  rootCandidates,
} from "./lost.js";
import type { VersionEntry } from "./store-types.js";

interface Site {
  readonly root: string;
  readonly versions: readonly VersionEntry[];
}

async function versionsAt(root: string): Promise<Site | null> {
  const response = await fetch(`${root}versions.json`).catch(() => null);
  if (!response?.ok) return null;
  const list: unknown = await response.json().catch(() => null);
  return isVersionList(list) ? { root, versions: list } : null;
}

async function siteOf(pathname: string): Promise<Site | null> {
  // Not Promise.all over the candidates: every wrong root would answer 404 in the reader's console.
  for (const root of rootCandidates(pathname)) {
    const site = await versionsAt(root);
    if (site !== null) return site;
  }
  return null;
}

function drawNotFound(
  site: Site,
  newest: VersionEntry,
  below: string,
  icon: HTMLLinkElement,
): void {
  Object.assign(document.body.dataset, {
    root: site.root,
    version: newest.name,
    data: newest.data,
    kind: "not-found",
    asked: decoded(location.pathname + location.hash),
    guess: guessOf(below, location.hash.slice(1)),
  });
  const head = document.head;
  const add = (tag: string, attrs: Record<string, string>): void => {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
    head.append(e);
  };
  add("link", { rel: "stylesheet", href: `${site.root}assets/style.css` });
  icon.setAttribute("href", `${site.root}assets/favicon.svg`);
  add("script", { type: "module", src: `${site.root}assets/site.js` });
}

async function lost(hashMode: boolean, icon: HTMLLinkElement): Promise<void> {
  const site = await siteOf(location.pathname);
  const newest = site?.versions[site.versions.length - 1];
  if (!site || !newest) return;
  const below = location.pathname.slice(site.root.length);
  const at = lostAt(
    below,
    site.versions.map((v) => v.name),
  );
  if (hashMode) {
    location.replace(hashTarget(site.root, at, newest.name, location));
    return;
  }
  if (at.kind === "unversioned") {
    const modules = await modulesIn(site.root, newest).catch(() => null);
    if (modules !== null && hasPage(modules, decoded(at.path))) {
      location.replace(`${site.root}${newest.name}/${at.path}${location.search}${location.hash}`);
      return;
    }
  }
  const module = at.kind === "versioned" ? moduleOfPage(at.path) : null;
  if (at.kind === "versioned" && module !== null) {
    location.replace(
      `${site.root}${at.version}/index.html?${MISSING}=${encodeURIComponent(module)}`,
    );
    return;
  }
  drawNotFound(site, newest, at.kind === "nothing" ? below : at.path, icon);
}

const script = document.currentScript as HTMLScriptElement | null;
const toNewest = script?.dataset.newest;
if (toNewest !== undefined) {
  location.replace(`${toNewest}/index.html${location.search}${location.hash}`);
} else {
  // Declared before load, not with the stylesheet: a page with no icon by then makes the browser ask the host for /favicon.ico.
  const icon = document.createElement("link");
  icon.setAttribute("rel", "icon");
  icon.setAttribute("href", "data:,");
  document.head.append(icon);
  void lost(script?.dataset.mode === "hash", icon);
}
