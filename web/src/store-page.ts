import { initDrawer } from "./drawer.js";
import { showGuesses } from "./guess.js";
import { decoded, hashHref, parseHash } from "./hash-route.js";
import { MISSING } from "./lost.js";
import { openForPrint } from "./print.js";
import { draw, hrefIn, type Place, type Route, routeOf, sameView } from "./route.js";
import { initSearch } from "./search-box.js";
import { initSearchPage } from "./search-page.js";
import { dataJson } from "./store-data.js";
import { initFills, initTree } from "./store-fill.js";
import { versionSource } from "./store-search.js";
import type { PageFile, RoutesFile, VersionEntry, VersionFile } from "./store-types.js";
import { initTheme } from "./theme.js";
import { arrivalNotices, initVersions, versionsAt } from "./versions.js";

const body = document.body;

function failed(error: unknown): void {
  const p = document.createElement("p");
  p.className = "lede";
  p.textContent = `This page's data could not be loaded (${error instanceof Error ? error.message : String(error)}).`;
  body.replaceChildren(p);
  body.dataset.drawn = "failed";
}

function showAnchor(r: Route): void {
  for (const e of document.querySelectorAll(".targeted")) e.classList.remove("targeted");
  const target = r.anchor === null ? null : document.getElementById(r.anchor);
  if (!target) {
    scrollTo(0, 0);
    return;
  }
  target.classList.add("targeted");
  target.scrollIntoView();
}

function arrive(r: Route): void {
  if (r.mode === "hash") showAnchor(r);
  else if (location.hash) location.replace(location.href);
}

function searchByRoute(r: Route, signal: AbortSignal): void {
  const input = document.getElementById("search-input") as HTMLInputElement | null;
  input?.form?.addEventListener(
    "submit",
    (e) => {
      e.preventDefault();
      location.hash = hrefIn(r, `search.html?q=${encodeURIComponent(input.value)}`);
    },
    { signal },
  );
}

async function show(r: Route, own: readonly Node[], signal: AbortSignal): Promise<void> {
  delete body.dataset.drawn;
  let drawn: Awaited<ReturnType<typeof draw>>;
  try {
    drawn = await draw(r, own);
  } catch (error) {
    failed(error);
    return;
  }
  if (signal.aborted) return;
  document.title = drawn.title;
  body.classList.toggle("plain", drawn.plain);
  body.replaceChildren(...drawn.nodes);
  initTheme();
  initDrawer(signal);
  const source = versionSource(r.root, drawn.version, drawn.linker.at);
  if (r.kind === "search") initSearchPage(source, r.query);
  else if (r.mode === "hash") searchByRoute(r, signal);
  initSearch(source, signal);
  if (r.kind === "module") {
    const c = { ...r, version: drawn.version, linker: drawn.linker, source };
    initFills(body, c);
    initTree(c);
  }
  if (r.kind === "not-found") void showGuesses(source, r.guess);
  arrivalNotices(r);
  body.dataset.drawn = "1";
  arrive(r);
  void initVersions(r).then(() => {
    if (!signal.aborted && r.mode === "hash" && r.anchor !== null) showAnchor(r);
  });
}

const nodesOf = (selector: string): Node[] => {
  const t = document.querySelector<HTMLTemplateElement>(selector);
  return t ? [...t.content.childNodes] : [];
};

async function routeOfHash(root: string, entries: readonly VersionEntry[]): Promise<Route> {
  const newest = entries[entries.length - 1] as VersionEntry;
  const place = parseHash(location.hash);
  if (place === null) {
    history.replaceState(history.state, "", hashHref(newest.name, "index.html"));
    return {
      root,
      version: newest.name,
      data: newest.data,
      mode: "hash",
      query: "",
      anchor: null,
      kind: "index",
    };
  }
  const entry = entries.find((e) => e.name === place.version);
  if (!entry) {
    const asked = decoded(location.hash);
    const at: Place = {
      root,
      version: newest.name,
      data: newest.data,
      mode: "hash",
      query: "",
      anchor: null,
    };
    return {
      ...at,
      kind: "not-found",
      asked,
      guess: place.anchor ?? place.page.split("/").join("."),
    };
  }
  const at: Place = {
    root,
    version: entry.name,
    data: entry.data,
    mode: "hash",
    query: place.query,
    anchor: place.anchor,
  };
  void dataJson<VersionFile>(root, entry.data).catch(() => null);
  if (place.page === "") return { ...at, kind: "index" };
  if (place.page === "search") return { ...at, kind: "search" };
  if (place.page === "foundational_types") return { ...at, kind: "foundational" };
  if (place.page === "references") {
    const version = await dataJson<VersionFile>(root, entry.data);
    return { ...at, kind: "references", references: version.references };
  }
  const routes = entry.routes === undefined ? {} : await dataJson<RoutesFile>(root, entry.routes);
  const hit = Object.hasOwn(routes, place.page) ? routes[place.page] : undefined;
  if (!hit) {
    const module = place.page.split("/").join(".");
    return {
      ...at,
      kind: "index",
      query: `?${MISSING}=${encodeURIComponent(module)}`,
      anchor: null,
    };
  }
  const [page, usedBy] = hit;
  const file = await dataJson<PageFile>(root, page);
  return { ...at, kind: "module", module: file.module, page, usedBy };
}

async function hashSite(root: string): Promise<void> {
  const own = {
    search: nodesOf("template#search-body"),
    foundational: nodesOf("template#foundational-body"),
  };
  const entries = await versionsAt(root, "hash");
  if (!entries) {
    failed(new Error("the version list"));
    return;
  }
  let current: Route | null = null;
  let drawing: AbortController | null = null;
  const go = async (): Promise<void> => {
    let r: Route;
    try {
      r = await routeOfHash(root, entries);
    } catch (error) {
      failed(error);
      return;
    }
    if (current !== null && sameView(current, r)) {
      current = r;
      showAnchor(r);
      return;
    }
    drawing?.abort();
    drawing = new AbortController();
    current = r;
    const nodes =
      r.kind === "search" ? own.search : r.kind === "foundational" ? own.foundational : [];
    await show(
      r,
      nodes.map((n) => n.cloneNode(true)),
      drawing.signal,
    );
  };
  addEventListener("hashchange", () => void go());
  await go();
}

function start(): void {
  openForPrint();
  if (body.dataset.mode === "hash") {
    void hashSite(body.dataset.root ?? "./");
    return;
  }
  const route = routeOf(body.dataset, location);
  if (route) void show(route, [...body.childNodes], new AbortController().signal);
}

start();
