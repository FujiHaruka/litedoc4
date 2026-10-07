import { guessOf } from "./guess.js";
import { decoded } from "./hash-route.js";
import {
  hashTarget,
  isVersionList,
  lostAt,
  MISSING,
  moduleOfPage,
  rootCandidates,
} from "./lost.js";
import { isShell } from "./shell-probe.js";
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
  const found = await Promise.all(rootCandidates(pathname).map(versionsAt));
  return found.find((s) => s !== null) ?? null;
}

function drawNotFound(site: Site, newest: VersionEntry, below: string): void {
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
  add("link", { rel: "icon", href: `${site.root}assets/favicon.svg` });
  add("script", { type: "module", src: `${site.root}assets/site.js` });
}

async function lost(hashMode: boolean): Promise<void> {
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
    const target = `${site.root}${newest.name}/${at.path}`;
    if (await isShell(target)) {
      location.replace(target + location.search + location.hash);
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
  drawNotFound(site, newest, at.kind === "nothing" ? below : at.path);
}

const script = document.currentScript as HTMLScriptElement | null;
const toNewest = script?.dataset.newest;
if (toNewest !== undefined) {
  location.replace(`${toNewest}/index.html${location.search}${location.hash}`);
} else {
  void lost(script?.dataset.mode === "hash");
}
