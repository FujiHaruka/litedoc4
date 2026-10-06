import { el } from "./dom.js";
import { pageIn, type Route } from "./route.js";
import { dataJson } from "./store-data.js";
import type { VersionEntry, VersionFile } from "./store-types.js";
import type { ModuleEntry, ModulesFile } from "./types.js";

export const MISSING = "missing";

export interface Here {
  readonly search: string;
  readonly hash: string;
}

export function switchTarget(
  r: Route,
  to: string,
  here: Here,
  modules: readonly ModuleEntry[] | null,
): string {
  const base = `${r.root}${to}/`;
  if (r.kind !== "module") {
    return base + pageIn(r) + (r.kind === "search" ? here.search : "") + here.hash;
  }
  const entry = modules?.find((m) => m.n === r.module);
  return entry
    ? base + entry.p + here.hash
    : `${base}index.html?${MISSING}=${encodeURIComponent(r.module)}`;
}

async function destinationIn(r: Route, to: VersionEntry): Promise<string> {
  const here: Here = { search: location.search, hash: location.hash };
  if (r.kind !== "module") return switchTarget(r, to.name, here, null);
  const version = await dataJson<VersionFile>(r.root, to.data);
  const list = await dataJson<ModulesFile>(r.root, version.modules);
  return switchTarget(r, to.name, here, list.modules);
}

function notice(...children: (Node | string)[]): HTMLElement {
  const p = el("p", "results-note", ...children);
  p.setAttribute("role", "status");
  document.getElementById("content")?.prepend(p);
  return p;
}

const decoded = (s: string): string => {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
};

export function arrivalNotices(r: Route): void {
  const missing = new URLSearchParams(location.search).get(MISSING);
  if (r.kind === "index" && missing !== null) {
    notice(`The module ${missing} does not exist in version ${r.version}.`);
    history.replaceState(history.state, "", location.pathname + location.hash);
  }
  if (r.kind === "module" && location.hash.length > 1) {
    const anchor = decoded(location.hash.slice(1));
    if (document.getElementById(anchor) === null) {
      notice(`The declaration ${anchor} does not exist in version ${r.version} of ${r.module}.`);
      history.replaceState(history.state, "", location.pathname + location.search);
    }
  }
}

async function go(r: Route, to: VersionEntry, select: HTMLSelectElement): Promise<void> {
  try {
    location.assign(await destinationIn(r, to));
  } catch {
    select.value = r.version;
  }
}

export async function initVersions(r: Route): Promise<void> {
  const entries = await fetch(new URL(`${r.root}versions.json`, location.href))
    .then((res) => (res.ok ? (res.json() as Promise<VersionEntry[]>) : null))
    .catch(() => null);
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
  if (newest && newest.name !== r.version) {
    const button = el("button", "", `Go to ${newest.name}`);
    button.type = "button";
    button.addEventListener("click", () => void go(r, newest, select));
    notice(`This is version ${r.version}; the newest is ${newest.name}. `, button);
  }
}
