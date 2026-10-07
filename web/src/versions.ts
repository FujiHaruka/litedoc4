import { el } from "./dom.js";
import { decoded, parseHash } from "./hash-route.js";
import { MISSING } from "./lost.js";
import { hrefIn, pageIn, pathHere, type Route } from "./route.js";
import { isShell } from "./shell-probe.js";
import { dataJson } from "./store-data.js";
import type { VersionEntry, VersionFile } from "./store-types.js";
import type { ModuleEntry, ModulesFile } from "./types.js";

export function switchTarget(r: Route, to: string, modules: readonly ModuleEntry[] | null): string {
  const there = { ...r, version: to };
  if (r.kind !== "module") return hrefIn(there, pathHere(r, r.anchor));
  const entry = modules?.find((m) => m.n === r.module);
  return entry
    ? hrefIn(there, entry.p + (r.anchor === null ? "" : `#${r.anchor}`))
    : hrefIn(there, `index.html?${MISSING}=${encodeURIComponent(r.module)}`);
}

function now(r: Route): Route {
  if (r.mode === "hash") {
    const place = parseHash(location.hash);
    return { ...r, query: place?.query ?? "", anchor: place?.anchor ?? null };
  }
  const hash = location.hash.slice(1);
  return { ...r, query: location.search, anchor: hash ? decoded(hash) : null };
}

async function destinationIn(arrived: Route, to: VersionEntry): Promise<string> {
  const r = now(arrived);
  if (r.kind !== "module") return switchTarget(r, to.name, null);
  const version = await dataJson<VersionFile>(r.root, to.data);
  const list = await dataJson<ModulesFile>(r.root, version.modules);
  return switchTarget(r, to.name, list.modules);
}

const listed = new Map<string, Promise<VersionEntry[] | null>>();

export function versionsAt(root: string): Promise<VersionEntry[] | null> {
  let entries = listed.get(root);
  if (!entries) {
    entries = fetch(new URL(`${root}versions.json`, location.href))
      .then((res) => (res.ok ? (res.json() as Promise<VersionEntry[]>) : null))
      .catch(() => null);
    listed.set(root, entries);
  }
  return entries;
}

function notice(...children: (Node | string)[]): HTMLElement {
  const p = el("p", "results-note", ...children);
  p.setAttribute("role", "status");
  document.getElementById("content")?.prepend(p);
  return p;
}

const replaceAddress = (r: Route, path: string): void =>
  history.replaceState(history.state, "", hrefIn(r, path));

export function arrivalNotices(r: Route): void {
  const missing = new URLSearchParams(r.query).get(MISSING);
  if (r.kind === "index" && missing !== null) {
    notice(`The module ${missing} does not exist in version ${r.version}.`);
    replaceAddress(r, pathHere(r, r.anchor));
  }
  if (r.kind === "module" && r.anchor !== null && document.getElementById(r.anchor) === null) {
    notice(`The declaration ${r.anchor} does not exist in version ${r.version} of ${r.module}.`);
    replaceAddress(r, pathHere(r, null));
  }
}

async function go(r: Route, to: VersionEntry, select: HTMLSelectElement): Promise<void> {
  try {
    location.assign(new URL(await destinationIn(r, to), location.href).href);
  } catch {
    select.value = r.version;
  }
}

async function canonical(r: Route, newest: string): Promise<void> {
  document.querySelector('link[rel="canonical"]')?.remove();
  if (r.mode === "hash" || r.kind === "not-found") return;
  const href = new URL(hrefIn({ ...r, version: newest }, pageIn(r)), location.href).href;
  if (r.kind === "module" && r.version !== newest && !(await isShell(href))) return;
  const link = document.createElement("link");
  link.rel = "canonical";
  link.href = href;
  document.head.append(link);
}

export async function initVersions(r: Route): Promise<void> {
  const entries = await versionsAt(r.root);
  if (!entries || entries.length === 0) return;
  const select = el("select", "versions");
  select.setAttribute("aria-label", "Version");
  for (const e of [...entries].reverse()) {
    const option = el("option", "", e.name);
    option.value = e.name;
    option.selected = e.name === r.version;
    select.append(option);
  }
  select.addEventListener("change", () => {
    const to = entries.find((e) => e.name === select.value);
    if (to) void go(r, to, select);
  });
  document.querySelector(".topbar .home")?.after(select);
  const newest = entries[entries.length - 1];
  if (!newest) return;
  if (newest.name !== r.version) {
    const button = el("button", "", `Go to ${newest.name}`);
    button.type = "button";
    button.addEventListener("click", () => void go(r, newest, select));
    notice(`This is version ${r.version}; the newest is ${newest.name}. `, button);
  }
  void canonical(r, newest.name);
}
