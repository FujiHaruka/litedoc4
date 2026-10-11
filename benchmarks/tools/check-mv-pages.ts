#!/usr/bin/env node
/**
 * The page-path and anchor promise of a site `litedoc4 store render` wrote, as a
 * reader meets it: in a browser, after the page has been drawn from data.
 * tools/mv-pages-gate.sh is the gate and its header says what each item means;
 * this file is the driver.
 *
 * usage:
 *   node check-mv-pages.ts --site <path-URL render> --hash <hash-URL render>
 *                     --frozen <frozen site> [--chrome PATH] [--port N]
 *   node check-mv-pages.ts --url <site root URL> [--chrome PATH]
 *     the smoke over a served path-URL site; tools/live-smoke-gate.sh is that gate
 */

import { spawn } from "node:child_process";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { readFile, realpath } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import puppeteer, { type Browser, type ElementHandle, type Page } from "puppeteer-core";
import { listen } from "./serve.ts";

const CHROME_CANDIDATES = [
  process.env.CHROME_PATH,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/usr/bin/google-chrome",
  "/usr/bin/google-chrome-stable",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
];

const FROZEN_HOST_PAGE = "404.html";
const INDEX_READER = fileURLToPath(new URL("./check-store-render.py", import.meta.url));
const MONO_CHARSET = new URL("./mono-charset.json", import.meta.url);
const FROZEN_NO_ID_ARM = "search.html";
const DRAW_TIMEOUT_MS = 10000;

function findChrome(explicit?: string): string {
  const candidates = explicit ? [explicit] : CHROME_CANDIDATES;
  for (const path of candidates) {
    if (!path) continue;
    if (isFile(path)) return path;
  }
  console.error(
    "no Chrome found. Set CHROME_PATH or pass --chrome; tried:\n  " +
      candidates.filter(Boolean).join("\n  "),
  );
  process.exit(2);
}

const isFile = (path: string): boolean => {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
};

function htmlFiles(dir: string, rel = ""): string[] {
  const out: string[] = [];
  for (const e of readdirSync(`${dir}/${rel}`, { withFileTypes: true })) {
    const r = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...htmlFiles(dir, r));
    else if (e.name.endsWith(".html")) out.push(r);
  }
  return out.sort();
}

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
};

const DATA_DELAY_TYPED_MS = 300;
let dataDelayMs = 0;

function serve(root: string, port: number) {
  return listen({ port, hostname: "127.0.0.1" }, async (request) => {
    let path = decodeURIComponent(new URL(request.url).pathname);
    if (path.endsWith("/")) path += "index.html";
    if (dataDelayMs && path.includes("/d/")) await new Promise((r) => setTimeout(r, dataDelayMs));
    try {
      const body = await readFile(`${root}${path}`);
      const type = TYPES[path.slice(path.lastIndexOf("."))] ?? "application/octet-stream";
      return new Response(body, { headers: { "content-type": type } });
    } catch {
      try {
        const body = await readFile(`${root}/404.html`);
        return new Response(body, { status: 404, headers: { "content-type": TYPES[".html"] } });
      } catch {
        return new Response("not found", { status: 404 });
      }
    }
  });
}

function textOfHtml(html: string): string {
  return html
    .replace(/<[^>]+>/g, "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ")
    .trim();
}

async function gunzipJson<T>(path: string): Promise<T> {
  const stream = new Blob([await readFile(path)])
    .stream()
    .pipeThrough(new DecompressionStream("gzip"));
  return JSON.parse(await new Response(stream).text()) as T;
}

const decoded = (s: string): string => {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
};

const unescapeHtml = (s: string): string =>
  s.replace(/&(amp|lt|gt|quot|#39|#x27);/g, (_, e: string) =>
    ({ amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'", "#x27": "'" })[e] ?? "");

function frozenIds(path: string): string[] {
  const html = readFileSync(path, "utf8").replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, "");
  return [...html.matchAll(/<[a-zA-Z][^>]*?\sid="([^"]*)"/g)].map((m) => unescapeHtml(m[1]));
}

function missingFrom(want: readonly string[], have: readonly string[]): string[] {
  const left = new Map<string, number>();
  for (const id of have) left.set(id, (left.get(id) ?? 0) + 1);
  const missing: string[] = [];
  for (const id of want) {
    const n = left.get(id) ?? 0;
    if (n === 0) missing.push(id);
    else left.set(id, n - 1);
  }
  return missing;
}

interface VersionEntry {
  name: string;
  data: string;
  routes?: string;
}
interface VersionFile {
  modules: string;
  title: string;
  footer: { html: string } | null;
}
interface ModuleEntry {
  n: string;
  p: string;
}
type Resolved = readonly (string | number | null)[];
interface PageFile {
  module: string;
  content: string | null;
  names: Record<string, Resolved>;
}

type IndexNames = Record<string, [string, string | null][]>;

function output(command: string, args: string[]): Promise<{ success: boolean; stdout: Buffer; stderr: Buffer }> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.on("error", reject);
    child.on("close", (code) =>
      resolve({ success: code === 0, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr) }),
    );
  });
}

async function indexNames(root: string): Promise<IndexNames> {
  const out = await output("python3", ["-I", "-X", "utf8", INDEX_READER, "--site", root, "--print-index"]);
  if (!out.success) {
    throw new Error(`check-store-render.py --print-index: ${new TextDecoder().decode(out.stderr).slice(-300)}`);
  }
  return JSON.parse(new TextDecoder().decode(out.stdout)) as IndexNames;
}

// FROZEN: the string scorer the byte searcher replaced. Never edited to agree with a change in
// the searcher.
const frozenScore = (name: string, query: string): number => {
  const lower = name.toLowerCase();
  const last = lower.slice(lower.lastIndexOf(".") + 1);
  if (last.startsWith(query)) return 3000 - last.length;
  if (lower.startsWith(query)) return 2000 - lower.length;
  const at = lower.indexOf(query);
  if (at >= 0) return 1000 - at;
  return -1;
};
const frozenSearch = (names: readonly string[], query: string): string[] =>
  names
    .map((name, i) => [frozenScore(name, query), name, i] as [number, string, number])
    .filter(([score]) => score > 0)
    .sort((a, b) => b[0] - a[0] || a[1].length - b[1].length || a[2] - b[2])
    .map(([, name]) => name);

interface SiteData {
  versions: VersionEntry[];
  pageOf: Map<string, Map<string, string>>;
  pageFiles: Map<string, { version: string; page: string; file: PageFile }>;
}

async function siteData(
  root: string,
  pageAddress: (v: VersionEntry, m: ModuleEntry) => Promise<string | null>,
): Promise<SiteData> {
  const versions = JSON.parse(readFileSync(`${root}/versions.json`, "utf8")) as VersionEntry[];
  const pageOf = new Map<string, Map<string, string>>();
  const pageFiles = new Map<string, { version: string; page: string; file: PageFile }>();
  for (const v of versions) {
    const vf = await gunzipJson<VersionFile>(`${root}/d/${v.data}.json.gz`);
    const list = await gunzipJson<{ modules: ModuleEntry[] }>(`${root}/d/${vf.modules}.json.gz`);
    const byName = new Map<string, string>();
    for (const m of list.modules) {
      byName.set(m.n, m.p);
      const address = await pageAddress(v, m);
      if (address === null) continue;
      const file = await gunzipJson<PageFile>(`${root}/d/${address}.json.gz`);
      pageFiles.set(`${v.name}/${m.p}`, { version: v.name, page: m.p, file });
    }
    pageOf.set(v.name, byName);
  }
  return { versions, pageOf, pageFiles };
}

function shellAttr(root: string, rel: string, key: string): string {
  const m = new RegExp(` data-${key}="([0-9a-f]+)"`).exec(readFileSync(`${root}/${rel}`, "utf8"));
  if (!m) throw new Error(`${rel} has no data-${key}`);
  return m[1];
}

interface Visit {
  ids: string[];
  decls: string[];
  title: string;
  footer: string | null;
  flags: [string, string[], string][];
  hrefs: { href: string; from: string }[];
  onDemand: Record<string, number>;
  drawn: string;
  where: string;
}

const ON_DEMAND: Record<string, string> = {
  tree: "#module-tree a[href]",
  imports: ".modmeta .imports a[href]",
  "used-by": 'details[data-fill="used-by"] a[href]',
  instances: 'details[data-fill="instances"] a[href], details[data-fill="instances-for"] a[href]',
};

class Run {
  readonly errors: string[] = [];
  readonly failedRequests: string[] = [];
  readonly deliberate = new Map<string, number>();
  page!: Page;

  readonly timeout: number;

  constructor(timeout = DRAW_TIMEOUT_MS) {
    this.timeout = timeout;
  }

  watch(page: Page): void {
    this.page = page;
    page.on("console", (m) => {
      if (m.type() !== "error") return;
      const at = (m.location()?.url ?? "").split("#")[0];
      if (this.deliberate.has(at) && m.text().startsWith("Failed to load resource")) return;
      this.errors.push(`console: ${m.text()} (${m.location()?.url ?? "?"})`);
    });
    page.on("pageerror", (e) =>
      this.errors.push(`pageerror: ${e instanceof Error ? e.message : String(e)} (${page.url()})`),
    );
    page.on("requestfailed", (r) =>
      this.failedRequests.push(`${r.url()}: ${r.failure()?.errorText ?? "failed"}`),
    );
    page.on("response", (r) => {
      const url = r.url().split("#")[0];
      if (r.request().resourceType() === "document" && this.deliberate.has(url)) {
        this.deliberate.set(url, r.status());
        return;
      }
      if (r.status() >= 400) this.failedRequests.push(`${r.url()}: HTTP ${r.status()}`);
    });
  }

  async fresh(url: string): Promise<string> {
    await this.page.goto("about:blank");
    await this.page.goto(url, { waitUntil: "load" });
    await this.page.waitForSelector("body[data-drawn]", { timeout: this.timeout });
    await this.page.waitForNetworkIdle({ idleTime: 150, timeout: this.timeout });
    return await this.page.evaluate(() => document.body.dataset.drawn ?? "");
  }

  async collect(where: string, drawn: string): Promise<Visit> {
    const page = this.page;
    const ids = await page.evaluate(() => [...document.querySelectorAll("[id]")].map((e) => e.id));
    const decls = await page.evaluate(() =>
      [...document.querySelectorAll("section.decl[id]")].map((e) => e.id),
    );
    const title = await page.evaluate(() => document.title);
    const footer = await page.evaluate(() => {
      const f = document.querySelector("main#content > footer.site-footer:last-child");
      return f === null ? null : (f.textContent ?? "").replace(/\s+/g, " ").trim();
    });
    const flags = await page.evaluate(() =>
      [...document.querySelectorAll("section.decl[id]")].map(
        (s) =>
          [
            s.id,
            [...s.querySelectorAll<HTMLElement>("[data-flag]")].map((f) => f.dataset.flag ?? ""),
            s.querySelector('[data-flag="generated"]')?.textContent ?? "",
          ] as [string, string[], string],
      ),
    );
    const asDrawn = await page.evaluate(() =>
      [...document.querySelectorAll<HTMLAnchorElement>("a[href]")].map((a) => a.href),
    );
    await page.evaluate(() => {
      for (const d of document.querySelectorAll("details")) (d as HTMLDetailsElement).open = true;
    });
    await page.waitForNetworkIdle({ idleTime: 150, timeout: DRAW_TIMEOUT_MS });
    await page
      .waitForFunction(
        () =>
          [...document.querySelectorAll('details[data-fill]:not([hidden]) > ul, #module-tree')].every(
            (e) => e.childElementCount > 0,
          ),
        { timeout: DRAW_TIMEOUT_MS },
      )
      .catch(() => this.errors.push(`${where}: an on-demand section stayed empty after opening`));
    const opened = await page.evaluate(() =>
      [...document.querySelectorAll<HTMLAnchorElement>("a[href]")].map((a) => a.href),
    );
    const onDemand: Record<string, number> = {};
    for (const [kind, selector] of Object.entries(ON_DEMAND)) {
      onDemand[kind] = await page.evaluate((s) => document.querySelectorAll(s).length, selector);
    }
    const seen = new Set<string>();
    const hrefs: { href: string; from: string }[] = [];
    for (const href of [...asDrawn, ...opened]) {
      if (seen.has(href)) continue;
      seen.add(href);
      hrefs.push({ href, from: where });
    }
    return { ids, decls, title, footer, flags, hrefs, onDemand, drawn, where };
  }
}

interface Item {
  name: string;
  ok: boolean;
  what: string;
}

const items: Item[] = [];
const reason = (e: unknown): string => {
  if (!(e instanceof Error)) return String(e);
  const cause = (e as Error & { cause?: { code?: string; message?: string } }).cause;
  return cause ? `${e.message} (${cause.code ?? cause.message ?? "no cause given"})` : e.message;
};
function item(name: string, body: () => [boolean, string]): void {
  try {
    const [ok, what] = body();
    items.push({ name, ok, what });
  } catch (e) {
    items.push({ name, ok: false, what: `could not be asked: ${reason(e)}` });
  }
}
async function itemAsync(name: string, body: () => Promise<[boolean, string]>): Promise<void> {
  try {
    const [ok, what] = await body();
    items.push({ name, ok, what });
  } catch (e) {
    items.push({ name, ok: false, what: `could not be asked: ${reason(e)}` });
  }
}

const few = (xs: readonly string[], n = 4): string =>
  xs.slice(0, n).join("; ") + (xs.length > n ? `; and ${xs.length - n} more` : "");

function ownAnchors(data: SiteData): { version: string; from: string; target: string; anchor: string | null; key: string }[] {
  const out: { version: string; from: string; target: string; anchor: string | null; key: string }[] = [];
  for (const { version, page, file } of data.pageFiles.values()) {
    for (const [key, r] of Object.entries(file.names)) {
      if (typeof r[0] === "number") continue;
      const anchor = r.length === 1 ? key : (r[1] as string | null);
      out.push({ version, from: page, target: r[0] as string, anchor, key });
    }
  }
  return out;
}

function namesItem(name: string, data: SiteData, idsAt: (version: string, page: string) => string[] | undefined): void {
  item(name, () => {
    const bad: string[] = [];
    let checked = 0;
    for (const n of ownAnchors(data)) {
      checked++;
      const page = data.pageOf.get(n.version)?.get(n.target);
      if (page === undefined) {
        bad.push(`${n.version}/${n.from} lists ${n.key} on module ${n.target}, which ${n.version} does not have`);
        continue;
      }
      if (n.anchor === null) continue;
      const ids = idsAt(n.version, page);
      if (ids === undefined) bad.push(`${n.version}/${n.from} lists ${n.key} on ${page}, which was never drawn`);
      else if (!ids.includes(n.anchor)) bad.push(`${n.version}/${n.from} lists ${n.key} as id ${n.anchor} on ${page}, which has no such id once drawn`);
    }
    if (bad.length) return [false, `${bad.length} of ${checked} own names in the page files: ${few(bad)}`];
    return [true, `all ${checked} own names in ${data.pageFiles.size} page files have a drawn page, and an id on it where they name one`];
  });
}

function onDemandItem(name: string, visits: Visit[]): void {
  item(name, () => {
    const total: Record<string, number> = {};
    for (const v of visits) for (const [k, n] of Object.entries(v.onDemand)) total[k] = (total[k] ?? 0) + n;
    const said = Object.entries(total).map(([k, n]) => `${k} ${n}`).join(", ");
    const none = Object.keys(ON_DEMAND).filter((k) => !total[k]);
    if (none.length) return [false, `opening every <details> drew no links for ${none.join(", ")} (${said}): their links went unchecked`];
    return [true, `opening every <details> on every page drew links, all in the href items: ${said}`];
  });
}

function drawnItem(name: string, visits: Visit[]): void {
  item(name, () => {
    const bad = visits.filter((v) => v.drawn !== "1").map((v) => `${v.where} (${v.drawn || "never"})`);
    if (bad.length) return [false, `${bad.length} of ${visits.length} pages did not draw: ${few(bad)}`];
    return [true, `${visits.length} pages drawn`];
  });
}

const VERSION_SELECT = "select.versions";
const NEWER_CONTROL = '#content [role="status"] button, #content [role="status"] a[href]';

interface Fixture {
  version: string;
  module: string;
  page: string;
  anchor: string | null;
}
interface Fixtures {
  same: Fixture | null;
  missingModule: Fixture | null;
  missingDecl: Fixture | null;
}

function switchFixtures(
  older: readonly string[],
  newest: string,
  pageOf: Map<string, Map<string, string>>,
  declsAt: (version: string, page: string) => string[] | undefined,
): Fixtures {
  const newestPages = pageOf.get(newest) ?? new Map<string, string>();
  const out: Fixtures = { same: null, missingModule: null, missingDecl: null };
  let sharedMost = 0;
  for (const version of older) {
    for (const [module, page] of pageOf.get(version) ?? []) {
      if (!newestPages.has(module)) {
        out.missingModule ??= { version, module, page, anchor: null };
        continue;
      }
      const here = declsAt(version, page) ?? [];
      const there = declsAt(newest, newestPages.get(module)!) ?? [];
      const shared = here.filter((d) => there.includes(d));
      if (shared.length > sharedMost) {
        sharedMost = shared.length;
        out.same = { version, module, page, anchor: shared[shared.length - 1] };
      }
      const gone = here.filter((d) => !there.includes(d));
      if (gone.length) out.missingDecl ??= { version, module, page, anchor: gone[gone.length - 1] };
    }
  }
  return out;
}

const need = (f: Fixture | null, what: string): Fixture => {
  if (f === null) throw new Error(`the sample offers no ${what}`);
  return f;
};

interface Landing {
  path: string;
  hash: string;
  scrollY: number;
  target: string | null;
  targeted: string | null;
  notes: string[];
  newer: string[];
}

interface SwitchMode {
  name: "path" | "hash";
  at: (version: string, page: string, anchor: string | null) => string;
  key: (version: string, page: string) => string;
  where: (l: Landing) => { key: string; anchor: string | null };
  targetSelector: string;
  fixtures: Fixtures;
}

const landing = (page: Page): Promise<Landing> =>
  page.evaluate(() => {
    const status = [...document.querySelectorAll<HTMLElement>('#content [role="status"]')];
    const control = (e: HTMLElement) => e.querySelector("button, a[href]") !== null;
    const text = (e: HTMLElement) => (e.textContent ?? "").replace(/\s+/g, " ").trim();
    return {
      path: location.pathname,
      hash: location.hash,
      scrollY: Math.round(scrollY),
      target: document.querySelector(":target")?.id ?? null,
      targeted: document.querySelector(".targeted")?.id ?? null,
      notes: status.filter((e) => !control(e)).map(text),
      newer: status.filter(control).map(text),
    };
  });

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  let site = "";
  let hashSite = "";
  let frozen = "";
  let live = "";
  let chrome: string | undefined;
  let port = 8930;
  while (args.length) {
    const arg = args.shift()!;
    if (arg === "--url") live = args.shift() ?? "";
    else if (arg === "--site") site = args.shift() ?? "";
    else if (arg === "--hash") hashSite = args.shift() ?? "";
    else if (arg === "--frozen") frozen = args.shift() ?? "";
    else if (arg === "--chrome") chrome = args.shift();
    else if (arg === "--port") port = Number(args.shift());
    else {
      console.error(`unexpected argument: ${arg}`);
      process.exit(2);
    }
  }
  if (live) {
    if (site || hashSite || frozen) {
      console.error("--url reads a served site and nothing else: no --site, --hash or --frozen beside it");
      process.exit(2);
    }
    await liveSmoke(live, findChrome(chrome));
    return;
  }
  if (!site || !hashSite || !frozen) {
    console.error("usage: check-mv-pages.ts --site DIR --hash DIR --frozen DIR [--chrome PATH] [--port N]\n       check-mv-pages.ts --url <site root URL> [--chrome PATH]");
    process.exit(2);
  }
  site = await realpath(site);
  hashSite = await realpath(hashSite);
  frozen = await realpath(frozen);
  const executablePath = findChrome(chrome);
  const frozenPages = htmlFiles(frozen);
  const declared = [
    "frozen-shells",
    ...frozenPages.filter((p) => p !== FROZEN_HOST_PAGE && p !== FROZEN_NO_ID_ARM).map((p) => `frozen-ids/${p}`),
    ...["drawn", "hrefs", "anchors", "names", "on-demand"].map((k) => `path-${k}`),
    ...["drawn", "routes", "anchors", "names", "on-demand"].map((k) => `hash-${k}`),
    "path-arrival",
    "hash-arrival",
    "path-root",
    "hash-root",
    "path-old-link",
    "hash-old-link",
    ...["switch-same", "switch-missing-module", "switch-missing-decl", "newer-line"].flatMap((k) => [`path-${k}`, `hash-${k}`]),
    "path-index-ids",
    "path-decls-indexed",
    "path-backrefs",
    "path-titles",
    "path-footer",
    "hash-footer",
    "path-flags",
    "search-dropdown",
    "search-page",
    "search-ranking",
    "theme-toggle",
    "contrast",
    "no-horizontal-scroll",
    "mathml",
    "mono-glyphs",
    "console",
    "requests",
  ];

  const P = `http://127.0.0.1:${port}`;
  const H = `http://127.0.0.1:${port + 1}`;
  const servers = await Promise.all([serve(site, port), serve(hashSite, port + 1)]);

  const pathData = await siteData(site, (v, m) => {
    const shell = `${v.name}/${m.p}`;
    return Promise.resolve(isFile(`${site}/${shell}`) ? shellAttr(site, shell, "page") : null);
  });
  const routesOf = new Map<string, Record<string, [string, string]>>();
  const hashData = await siteData(hashSite, async (v, m) => {
    let routes = routesOf.get(v.name);
    if (!routes) {
      routes = v.routes ? await gunzipJson<Record<string, [string, string]>>(`${hashSite}/d/${v.routes}.json.gz`) : {};
      routesOf.set(v.name, routes);
    }
    const hit = routes[m.p.replace(/\.html$/, "")];
    if (!hit) throw new Error(`${v.name}: the routes table has no ${m.p}`);
    return hit[0];
  });
  const newest = hashData.versions[hashData.versions.length - 1].name;
  let index: IndexNames | null = null;
  let indexFailure = "";
  try {
    index = await indexNames(site);
  } catch (e) {
    indexFailure = e instanceof Error ? e.message : String(e);
  }
  const needIndex = (): IndexNames => {
    if (index === null) throw new Error(indexFailure);
    return index;
  };
  const titles = new Map<string, string>();
  const footers = new Map<string, string | null>();
  for (const v of pathData.versions) {
    const file = await gunzipJson<VersionFile>(`${site}/d/${v.data}.json.gz`);
    titles.set(v.name, file.title);
    footers.set(v.name, file.footer === null ? null : textOfHtml(file.footer.html));
  }
  const contents = new Map<string, Record<string, unknown>[]>();
  for (const [key, { file }] of pathData.pageFiles) {
    contents.set(key, file.content === null ? [] : await gunzipJson<Record<string, unknown>[]>(`${site}/d/${file.content}.json.gz`));
  }

  let browser: Browser | undefined;
  const run = new Run();
  try {
    browser = await puppeteer.launch({
      executablePath,
      headless: true,
      args: ["--no-sandbox", "--disable-dev-shm-usage", "--no-first-run"],
    });
    console.log(`browser           ${await browser.version()} (${executablePath})`);
    const page = await browser.newPage();
    await page.emulateMediaFeatures([{ name: "prefers-reduced-motion", value: "reduce" }]);
    await page.setCacheEnabled(false);
    run.watch(page);

    const pathPages = htmlFiles(site).filter((p) => p !== "index.html");
    const pathVisits = new Map<string, Visit>();
    for (const rel of pathPages) {
      let drawn = "";
      try {
        drawn = await run.fresh(`${P}/${rel}`);
      } catch (e) {
        run.errors.push(`${rel}: ${e instanceof Error ? e.message : String(e)}`);
      }
      pathVisits.set(rel, await run.collect(rel, drawn));
    }
    const pathIds = (rel: string): string[] | undefined => pathVisits.get(rel)?.ids;

    item("frozen-shells", () => {
      const pages = frozenPages.filter((p) => p !== FROZEN_HOST_PAGE);
      const absent = pages.filter((p) => !isFile(`${site}/v1/${p}`));
      const host = isFile(`${site}/${FROZEN_HOST_PAGE}`);
      if (absent.length || !host) {
        return [false, `of ${pages.length} frozen page paths, no shell at v1/ for ${absent.join(", ") || "none"}${host ? "" : `; no ${FROZEN_HOST_PAGE} at the site root`}`];
      }
      return [true, `all ${pages.length} frozen page paths have a shell at v1/<same path>, and ${FROZEN_HOST_PAGE} is at the site root`];
    });
    const frozenRows: string[] = [];
    for (const rel of frozenPages.filter((p) => p !== FROZEN_HOST_PAGE && p !== FROZEN_NO_ID_ARM)) {
      item(`frozen-ids/${rel}`, () => {
        const want = frozenIds(`${frozen}/${rel}`);
        const have = pathIds(`v1/${rel}`);
        if (have === undefined) return [false, `v1/${rel} has no shell, so none of its ${want.length} frozen ids can be met`];
        const missing = missingFrom(want, have);
        const extra = missingFrom(have, want);
        frozenRows.push(`  ${rel}: frozen ${want.length}, present ${want.length - missing.length}, extra ${extra.length}${extra.length ? ` (${few(extra, 6)})` : ""}`);
        if (missing.length) return [false, `v1/${rel} drawn lacks ${missing.length} of ${want.length} frozen ids: ${few(missing, 8)}`];
        return [true, `all ${want.length} frozen ids present on v1/${rel} drawn; ${extra.length} extra`];
      });
    }

    const pv = [...pathVisits.values()];
    drawnItem("path-drawn", pv);
    let anchored = 0;
    item("path-hrefs", () => {
      const bad: string[] = [];
      let intra = 0;
      for (const v of pv) {
        for (const { href, from } of v.hrefs) {
          const u = new URL(href);
          if (u.origin !== P) continue;
          intra++;
          let path = decoded(u.pathname);
          if (path.endsWith("/")) path += "index.html";
          if (!isFile(`${site}${path}`)) bad.push(`${from} -> ${u.pathname}${u.hash}`);
        }
      }
      if (bad.length) return [false, `${bad.length} of ${intra} intra-site hrefs name no file the render wrote: ${few(bad)}`];
      return [true, `all ${intra} intra-site hrefs on ${pv.length} drawn pages (every <details> open) name a file the render wrote`];
    });
    item("path-anchors", () => {
      const bad: string[] = [];
      for (const v of pv) {
        for (const { href, from } of v.hrefs) {
          const u = new URL(href);
          if (u.origin !== P || u.hash.length <= 1) continue;
          anchored++;
          const target = decoded(u.pathname).slice(1);
          const anchor = decoded(u.hash.slice(1));
          const ids = pathIds(target);
          if (ids === undefined) bad.push(`${from} -> ${target}#${anchor}: that page was never drawn`);
          else if (!ids.includes(anchor)) bad.push(`${from} -> ${target}#${anchor}: no such id once drawn`);
        }
      }
      if (bad.length) return [false, `${bad.length} of ${anchored} hrefs with an anchor miss it: ${few(bad)}`];
      return [true, `all ${anchored} hrefs with an anchor name an id on their target page once drawn`];
    });
    namesItem("path-names", pathData, (version, rel) => pathIds(`${version}/${rel}`));
    onDemandItem("path-on-demand", pv);

    const routeKey = (hash: string): { key: string; anchor: string | null } | null => {
      if (!hash.startsWith("#/")) return null;
      const q = hash.indexOf("?");
      const path = decoded(q < 0 ? hash.slice(2) : hash.slice(2, q));
      const params = new URLSearchParams(q < 0 ? "" : hash.slice(q + 1));
      return { key: path, anchor: params.get("id") };
    };
    const hashVisits = new Map<string, Visit & { accepted: string | null }>();
    const queue: string[] = [];
    for (const v of hashData.versions) {
      queue.push(`${v.name}/`, `${v.name}/search`, `${v.name}/references`, `${v.name}/foundational_types`);
      for (const p of routesOf.get(v.name) ? Object.keys(routesOf.get(v.name)!) : []) queue.push(`${v.name}/${p}`);
    }
    while (queue.length) {
      const key = queue.shift()!;
      if (hashVisits.has(key)) continue;
      let drawn = "";
      try {
        drawn = await run.fresh(`${H}/index.html#/${key}`);
      } catch (e) {
        run.errors.push(`#/${key}: ${e instanceof Error ? e.message : String(e)}`);
      }
      const shown = await page.evaluate(() => ({
        hash: location.hash,
        lost: document.querySelector("#content code.missing-path") !== null,
      }));
      const at = routeKey(shown.hash);
      const accepted =
        drawn !== "1" ? `did not draw (${drawn || "never"})`
        : shown.lost ? "drew the not-found page"
        : at?.key !== key ? `was sent on to ${shown.hash}`
        : null;
      const visit = { ...(await run.collect(`#/${key}`, drawn)), accepted };
      hashVisits.set(key, visit);
      for (const { href } of visit.hrefs) {
        const u = new URL(href);
        const r = u.origin === H ? routeKey(u.hash) : null;
        if (r && !hashVisits.has(r.key)) queue.push(r.key);
      }
    }
    const hv = [...hashVisits.values()];
    const hashIds = (key: string): string[] | undefined => {
      const v = hashVisits.get(key);
      return v && v.accepted === null ? v.ids : undefined;
    };
    drawnItem("hash-drawn", hv);
    let hashAnchored = 0;
    item("hash-routes", () => {
      const bad: string[] = [];
      let intra = 0;
      for (const v of hv) {
        for (const { href, from } of v.hrefs) {
          const u = new URL(href);
          if (u.origin !== H) continue;
          intra++;
          const r = routeKey(u.hash);
          if (r === null) {
            const path = decoded(u.pathname);
            if (!isFile(`${hashSite}${path.endsWith("/") ? `${path}index.html` : path}`) || u.hash.length > 1) {
              bad.push(`${from} -> ${u.pathname}${u.hash}: neither a route nor a file`);
            }
            continue;
          }
          const seen = hashVisits.get(r.key);
          if (!seen) bad.push(`${from} -> #/${r.key}: never visited`);
          else if (seen.accepted !== null) bad.push(`${from} -> #/${r.key}: the route ${seen.accepted}`);
        }
      }
      const refused = hv.filter((v) => v.accepted !== null).map((v) => `${v.where} ${v.accepted}`);
      if (bad.length || refused.length) {
        return [false, `${bad.length} of ${intra} intra-site hrefs are not a route the draw code accepts: ${few(bad)}${refused.length ? `; routes refused: ${few(refused)}` : ""}`];
      }
      return [true, `all ${intra} intra-site hrefs on ${hv.length} drawn routes (every <details> open) are routes the draw code accepts and draws`];
    });
    item("hash-anchors", () => {
      const bad: string[] = [];
      for (const v of hv) {
        for (const { href, from } of v.hrefs) {
          const u = new URL(href);
          const r = u.origin === H ? routeKey(u.hash) : null;
          if (!r || r.anchor === null) continue;
          hashAnchored++;
          const ids = hashIds(r.key);
          if (ids === undefined) bad.push(`${from} -> #/${r.key} id ${r.anchor}: that route was not drawn`);
          else if (!ids.includes(r.anchor)) bad.push(`${from} -> #/${r.key} id ${r.anchor}: no such id once drawn`);
        }
      }
      if (bad.length) return [false, `${bad.length} of ${hashAnchored} routes with an id miss it: ${few(bad)}`];
      return [true, `all ${hashAnchored} routes with an id name an id on their page once drawn`];
    });
    namesItem("hash-names", hashData, (version, rel) => hashIds(`${version}/${rel.replace(/\.html$/, "")}`));
    onDemandItem("hash-on-demand", hv);

    const lastDecl = (visits: Iterable<Visit>, prefix: string): { where: string; id: string } => {
      let best: Visit | null = null;
      for (const v of visits) {
        if (!v.where.startsWith(prefix) || v.decls.length === 0) continue;
        if (best === null || v.decls.length > best.decls.length) best = v;
      }
      if (best === null) throw new Error(`no drawn page under ${prefix} carries a declaration`);
      return { where: best.where, id: best.decls[best.decls.length - 1] };
    };
    const targetIs = async (want: string, selector: string): Promise<string | null> => {
      const got = await page
        .waitForFunction((s: string, w: string) => document.querySelector(s)?.id === w, { timeout: 5000 }, selector, want)
        .then(() => want)
        .catch(async () => await page.evaluate((s: string) => document.querySelector(s)?.id ?? null, selector));
      return got;
    };
    await itemAsync("path-arrival", async () => {
      const said: string[] = [];
      const bad: string[] = [];
      for (const v of pathData.versions) {
        const { where, id } = lastDecl(pathVisits.values(), `${v.name}/`);
        const url = `${P}/${where}#${encodeURIComponent(id)}`;
        const drawn = await run.fresh(url);
        const got = await targetIs(id, ":target");
        if (drawn !== "1" || got !== id) bad.push(`${where}#${id} from outside: :target is ${got ?? "nothing"}`);
        else said.push(`${where}#${id}`);
      }
      if (bad.length || said.length === 0) return [false, bad.join("; ") || "no version to arrive at"];
      return [true, `a #name URL from outside sets :target on that declaration once drawn, in every version: ${said.join(", ")}`];
    });
    await itemAsync("hash-arrival", async () => {
      const said: string[] = [];
      const bad: string[] = [];
      for (const v of hashData.versions) {
        const { where, id } = lastDecl(hashVisits.values(), `#/${v.name}/`);
        const params = new URLSearchParams({ id });
        const drawn = await run.fresh(`${H}/index.html${where}?${params}`);
        const got = await targetIs(id, ".targeted");
        if (drawn !== "1" || got !== id) bad.push(`${where}?id=${id}: .targeted is ${got ?? "nothing"}`);
        else said.push(`${where}?id=${id}`);
      }
      if (bad.length || said.length === 0) return [false, bad.join("; ") || "no version to arrive at"];
      return [true, `a route naming a declaration marks it .targeted once drawn, in every version: ${said.join(", ")}`];
    });
    await itemAsync("path-root", async () => {
      const drawn = await run.fresh(`${P}/`);
      const at = await page.evaluate(() => location.pathname);
      if (drawn !== "1" || at !== `/${newest}/index.html`) return [false, `the site root went to ${at} (drawn ${drawn}), not /${newest}/index.html`];
      return [true, `the site root sends the reader to /${newest}/index.html, drawn`];
    });
    await itemAsync("hash-root", async () => {
      const drawn = await run.fresh(`${H}/`);
      const at = await page.evaluate(() => location.hash);
      if (drawn !== "1" || at !== `#/${newest}/`) return [false, `the site root went to ${at || "no route"} (drawn ${drawn}), not #/${newest}/`];
      return [true, `the site root draws #/${newest}/`];
    });
    const oldLink = async (base: string, landing: (rel: string, id: string) => string, selector: string): Promise<[boolean, string]> => {
      const { where, id } = lastDecl(pathVisits.values(), `${newest}/`);
      const rel = where.slice(newest.length + 1);
      const asked = `${base}/${rel}`;
      run.deliberate.set(asked, 0);
      const drawn = await run.fresh(`${asked}#${encodeURIComponent(id)}`);
      const got = await targetIs(id, selector);
      const at = await page.evaluate(() => location.pathname + location.hash);
      const status = run.deliberate.get(asked);
      const want = landing(rel, id);
      if (status !== 404) return [false, `/${rel} (no file) was answered ${status}, not the host's 404`];
      if (drawn !== "1" || decoded(at) !== want || got !== id) {
        return [false, `the old link /${rel}#${id} landed on ${decoded(at)} with ${selector} ${got ?? "nothing"}, not ${want}`];
      }
      return [true, `the old link /${rel}#${id} (404 from the host) lands on ${want}, ${id} ${selector === ":target" ? ":target" : ".targeted"}`];
    };
    await itemAsync("path-old-link", () => oldLink(P, (rel, id) => `/${newest}/${rel}#${id}`, ":target"));
    await itemAsync("hash-old-link", () =>
      oldLink(H, (rel, id) => `/#/${newest}/${rel.replace(/\.html$/, "")}?id=${id}`, ".targeted"),
    );

    const older = pathData.versions.slice(0, -1).map((v) => v.name);
    const switchModes: SwitchMode[] = [
      {
        name: "path",
        at: (v, page, anchor) => `${P}/${v}/${page}${anchor === null ? "" : `#${encodeURIComponent(anchor)}`}`,
        key: (v, page) => `${v}/${page}`,
        where: (l) => ({ key: decoded(l.path).slice(1), anchor: l.hash.length > 1 ? decoded(l.hash.slice(1)) : null }),
        targetSelector: ":target",
        fixtures: switchFixtures(older, newest, pathData.pageOf, (v, page) => pathVisits.get(`${v}/${page}`)?.decls),
      },
      {
        name: "hash",
        at: (v, page, anchor) =>
          `${H}/index.html#/${v}/${page === "index.html" ? "" : page.replace(/\.html$/, "")}${anchor === null ? "" : `?${new URLSearchParams({ id: anchor })}`}`,
        key: (v, page) => `${v}/${page === "index.html" ? "" : page.replace(/\.html$/, "")}`,
        where: (l) => routeKey(l.hash) ?? { key: `(no route: ${l.hash})`, anchor: null },
        targetSelector: ".targeted",
        fixtures: switchFixtures(older, newest, hashData.pageOf, (v, page) => hashVisits.get(`${v}/${page.replace(/\.html$/, "")}`)?.decls),
      },
    ];
    const settled = async (): Promise<void> => {
      await page.waitForSelector(VERSION_SELECT, { timeout: DRAW_TIMEOUT_MS });
      await page.waitForNetworkIdle({ idleTime: 150, timeout: DRAW_TIMEOUT_MS });
    };
    const after = async (what: string, act: () => Promise<unknown>): Promise<Landing> => {
      const left = page.url();
      const marked = await page.evaluate(() => {
        const content = document.getElementById("content");
        if (content) content.dataset.gateLeft = "1";
        return content !== null;
      });
      if (!marked) throw new Error(`${page.url()} has no #content to tell the page left from the page arrived at`);
      await act();
      await page
        .waitForFunction(
          () => document.body.dataset.drawn === "1" && document.getElementById("content") !== null && document.querySelector("[data-gate-left]") === null,
          { timeout: DRAW_TIMEOUT_MS },
        )
        .catch(() => {
          throw new Error(`${what} on ${left} drew no new page within ${DRAW_TIMEOUT_MS} ms; the browser is at ${page.url()}`);
        });
      await settled();
      return await landing(page);
    };
    const shown = (l: Landing, m: SwitchMode): string => {
      const at = m.where(l);
      return `${at.key}${at.anchor === null ? "" : `#${at.anchor}`}`;
    };
    const SWITCH_VIEWPORT = { width: 800, height: 400 };
    await page.setViewport(SWITCH_VIEWPORT);
    try {
      for (const m of switchModes) {
        await itemAsync(`${m.name}-switch-same`, async () => {
          const f = need(m.fixtures.same, "module page of an older version that the newest also has, with a declaration on both");
          const from = m.key(f.version, f.page);
          await run.fresh(m.at(f.version, f.page, f.anchor));
          await settled();
          const l = await after(`choosing ${newest} in the switcher`, () => page.select(VERSION_SELECT, newest));
          const got = await targetIs(f.anchor!, m.targetSelector);
          const at = m.where(l);
          const want = m.key(newest, f.page);
          if (at.key !== want || at.anchor !== f.anchor || got !== f.anchor) {
            return [false, `choosing ${newest} on ${from}#${f.anchor} landed on ${shown(l, m)} with ${m.targetSelector} ${got ?? "nothing"}, not ${want}#${f.anchor}`];
          }
          return [true, `choosing ${newest} in the switcher on ${from}#${f.anchor} lands on ${want}, drawn, ${f.anchor} ${m.targetSelector}`];
        });
        await itemAsync(`${m.name}-switch-missing-module`, async () => {
          const f = need(m.fixtures.missingModule, "module an older version has and the newest lacks");
          const from = m.key(f.version, f.page);
          await run.fresh(m.at(f.version, f.page, null));
          await settled();
          const l = await after(`choosing ${newest} in the switcher`, () => page.select(VERSION_SELECT, newest));
          const want = m.key(newest, "index.html");
          const said = l.notes.find((n) => n.includes(f.module) && n.includes(newest) && /does not exist/.test(n));
          if (m.where(l).key !== want || said === undefined) {
            return [false, `choosing ${newest} on ${from} landed on ${shown(l, m)} saying ${JSON.stringify(l.notes)}, not ${want} saying ${f.module} does not exist in ${newest}`];
          }
          return [true, `choosing ${newest} on ${from} (${f.module}, absent from ${newest}) lands on ${want}, drawn, saying "${said}"`];
        });
        await itemAsync(`${m.name}-switch-missing-decl`, async () => {
          const f = need(m.fixtures.missingDecl, "declaration on an older version's page that the newest's same page lacks");
          const from = m.key(f.version, f.page);
          await run.fresh(m.at(f.version, f.page, f.anchor));
          await settled();
          const before = await targetIs(f.anchor!, m.targetSelector);
          const scrolled = await page.evaluate(() => Math.round(scrollY));
          if (before !== f.anchor || scrolled === 0) {
            return [false, `${from}#${f.anchor} drawn has ${m.targetSelector} ${before ?? "nothing"} at scrollY ${scrolled}: a landing at the top could not be told from never having moved`];
          }
          const l = await after(`choosing ${newest} in the switcher`, () => page.select(VERSION_SELECT, newest));
          const at = m.where(l);
          const want = m.key(newest, f.page);
          const said = l.notes.find((n) => n.includes(f.anchor!) && n.includes(newest) && /does not exist/.test(n));
          const target = m.targetSelector === ":target" ? l.target : l.targeted;
          if (at.key !== want || at.anchor !== null || l.scrollY !== 0 || target !== null || said === undefined) {
            return [false, `choosing ${newest} on ${from}#${f.anchor} landed on ${shown(l, m)} at scrollY ${l.scrollY}, ${m.targetSelector} ${target ?? "nothing"}, saying ${JSON.stringify(l.notes)}; not ${want} at the top saying ${f.anchor} does not exist`];
          }
          return [true, `choosing ${newest} on ${from}#${f.anchor} (scrollY ${scrolled}) lands on ${want} at scrollY 0, nothing targeted, saying "${said}"`];
        });
        await itemAsync(`${m.name}-newer-line`, async () => {
          const bad: string[] = [];
          for (const v of pathData.versions.map((e) => e.name)) {
            await run.fresh(m.at(v, "index.html", null));
            await settled();
            const l = await landing(page);
            if (v === newest ? l.newer.length !== 0 : l.newer.length !== 1 || !l.newer[0].includes(newest)) {
              bad.push(`${m.key(v, "index.html")} shows ${l.newer.length} lines with a control (${JSON.stringify(l.newer)})`);
            }
          }
          const f = need(m.fixtures.same, "module page of an older version that the newest also has");
          const from = m.key(f.version, f.page);
          await run.fresh(m.at(f.version, f.page, null));
          await settled();
          const there = await landing(page);
          if (there.newer.length !== 1 || !there.newer[0].includes(newest)) {
            return [false, `${from} shows ${JSON.stringify(there.newer)}, not one line naming ${newest} with a control${bad.length ? `; ${few(bad)}` : ""}`];
          }
          const l = await after("following the newer-version line", () => page.click(NEWER_CONTROL));
          const want = m.key(newest, f.page);
          if (m.where(l).key !== want) bad.push(`following the line on ${from} landed on ${shown(l, m)}, not ${want}`);
          if (l.newer.length !== 0) bad.push(`${want} shows ${JSON.stringify(l.newer)}`);
          if (bad.length) return [false, few(bad)];
          return [true, `every older version's index and ${from} show one line naming ${newest} with a control ("${there.newer[0]}"), ${newest}'s index none; following it on ${from} lands on ${want}, drawn, with no such line`];
        });
      }
    } finally {
      await page.setViewport({ width: 800, height: 600 });
    }

    const modulePageOf = (rel: string): { version: string; module: string } | null => {
      const slash = rel.indexOf("/");
      const version = rel.slice(0, slash);
      for (const [module, p] of pathData.pageOf.get(version) ?? []) if (p === rel.slice(slash + 1)) return { version, module };
      return null;
    };
    item("path-index-ids", () => {
      const ix = needIndex();
      const bad: string[] = [];
      let n = 0;
      for (const [v, rows] of Object.entries(ix)) {
        for (const [name, module] of rows) {
          n++;
          const page = module === null ? undefined : pathData.pageOf.get(v)?.get(module);
          const ids = page === undefined ? undefined : pathIds(`${v}/${page}`);
          if (ids === undefined) bad.push(`${v} ${name}: module ${module} has no drawn page`);
          else if (!ids.includes(name)) bad.push(`${v}/${page} drawn has no id ${name}`);
        }
      }
      const versions = Object.keys(ix).join(",");
      if (versions !== pathData.versions.map((v) => v.name).join(",")) return [false, `the indexes are of ${versions}, the site's versions ${pathData.versions.map((v) => v.name).join(",")}`];
      if (n === 0) return [false, "the search indexes hold no name"];
      if (bad.length) return [false, `${bad.length} of ${n} index names are no id on their module's drawn page: ${few(bad)}`];
      return [true, `all ${n} names of the ${Object.keys(ix).length} search indexes (declarations and members) are an id on their module's drawn page`];
    });
    item("path-decls-indexed", () => {
      const ix = needIndex();
      const listed = new Set(Object.entries(ix).flatMap(([v, rows]) => rows.map(([n, m]) => `${v} ${m} ${n}`)));
      const bad: string[] = [];
      let n = 0;
      for (const visit of pv) {
        const at = modulePageOf(visit.where);
        if (at === null) continue;
        for (const id of visit.decls) {
          n++;
          if (!listed.has(`${at.version} ${at.module} ${id}`)) bad.push(`${visit.where}: ${id}`);
        }
      }
      if (n === 0) return [false, "no declaration section on any drawn module page"];
      if (bad.length) return [false, `${bad.length} of ${n} declaration sections drawn are not in their version's index under their module: ${few(bad)}`];
      return [true, `all ${n} declaration sections on the drawn module pages are in their version's index under their module`];
    });
    item("path-backrefs", () => {
      const bad: string[] = [];
      let n = 0;
      for (const v of pathData.versions) {
        const refs = pathVisits.get(`${v.name}/references.html`);
        if (!refs) {
          bad.push(`${v.name}/references.html was never drawn`);
          continue;
        }
        const listed = new Set<string>();
        for (const { href } of refs.hrefs) {
          const u = new URL(href);
          if (u.origin === P && u.hash.startsWith("#_backref_")) listed.add(`${decoded(u.pathname).slice(1)}${decoded(u.hash)}`);
        }
        for (const visit of pv) {
          if (!visit.where.startsWith(`${v.name}/`) || visit.where === `${v.name}/references.html`) continue;
          for (const id of visit.ids.filter((i) => i.startsWith("_backref_"))) {
            n++;
            if (!listed.has(`${visit.where}#${id}`)) bad.push(`${visit.where}#${id}`);
          }
        }
      }
      if (n === 0) return [false, "no citation anchor on any drawn page: nothing was compared"];
      if (bad.length) return [false, `${bad.length} of ${n} citation anchors drawn are linked from no back-reference on their version's references.html: ${few(bad)}`];
      return [true, `all ${n} citation anchors on the drawn pages are linked from a back-reference on their version's references.html (the other direction is path-anchors)`];
    });
    item("path-titles", () => {
      const bad: string[] = [];
      let n = 0;
      for (const visit of pv) {
        const version = visit.where.slice(0, visit.where.indexOf("/"));
        const want = titles.get(version);
        if (want === undefined) continue;
        n++;
        if (!visit.title.endsWith(want)) bad.push(`${visit.where}: "${visit.title}"`);
      }
      if (n === 0) return [false, "no drawn page under a version"];
      if (bad.length) return [false, `${bad.length} of ${n} drawn pages have a document title that does not end in their version file's title: ${few(bad)}`];
      return [true, `all ${n} drawn pages under a version end their document title in that version's title (${[...new Set(titles.values())].join(", ")})`];
    });
    const notFoundVisit = async (url: string, where: string, deliberate: boolean): Promise<Visit> => {
      if (deliberate) run.deliberate.set(url, 0);
      let drawn = "";
      try {
        drawn = await run.fresh(url);
      } catch (e) {
        run.errors.push(`${where}: ${e instanceof Error ? e.message : String(e)}`);
      }
      const lost = await page.evaluate(() => document.querySelector("#content code.missing-path") !== null);
      return { ...(await run.collect(where, drawn)), drawn: lost ? drawn : `not the not-found page (${drawn})` };
    };
    const footerItem = (name: string, visits: Visit[], versionOf: (where: string) => string, lost: Visit): void => {
      item(name, () => {
        const bad: string[] = [];
        let n = 0;
        if (lost.drawn !== "1") bad.push(`${lost.where}: ${lost.drawn}`);
        for (const visit of [...visits, lost]) {
          const want = footers.get(visit === lost ? newest : versionOf(visit.where));
          if (want === undefined) continue;
          n++;
          if (want === null) bad.push(`${visit.where}: its version file carries no footer`);
          else if (visit.footer === null) bad.push(`${visit.where}: no footer.site-footer is the last element of main#content`);
          else if (visit.footer !== want) bad.push(`${visit.where}: the footer reads "${visit.footer}", not "${want}"`);
        }
        if (n === 0) return [false, "no drawn page under a version"];
        if (bad.length) return [false, `${bad.length} of ${n} drawn pages do not end main#content with their version's footer: ${few(bad)}`];
        return [true, `all ${n} drawn pages, ${lost.where} among them, end main#content with their version file's footer ("${[...new Set(footers.values())].join('", "')}")`];
      });
    };
    footerItem(
      "path-footer",
      pv,
      (where) => where.slice(0, where.indexOf("/")),
      await notFoundVisit(`${P}/No/Such/Page.html`, "/No/Such/Page.html (404, the not-found page)", true),
    );
    footerItem(
      "hash-footer",
      hv,
      (where) => where.slice(2, where.indexOf("/", 2)),
      await notFoundVisit(`${H}/index.html#/no-such-version/Page`, "#/no-such-version/Page (the not-found page)", false),
    );
    item("path-flags", () => {
      const bad: string[] = [];
      let n = 0;
      for (const [key, items] of contents) {
        const visit = pathVisits.get(key);
        if (!visit) {
          bad.push(`${key} was never drawn`);
          continue;
        }
        const drawn = new Map(visit.flags.map(([id, f, text]) => [id, { f: f.join(" "), text }]));
        for (const it of items) {
          if (typeof it.n !== "string") continue;
          n++;
          const sorry = it.sorry === "direct" ? ["sorry-direct"] : it.sorry === "transitive" ? ["sorry-transitive"] : [];
          const gen = it.gen as [string, string] | undefined;
          const want = [...sorry, ...(gen ? ["generated"] : [])].join(" ");
          const got = drawn.get(it.n);
          if (!got) bad.push(`${key}: ${it.n} has no section`);
          else if (got.f !== want) bad.push(`${key}: ${it.n} drawn with [${got.f}], content says [${want}]`);
          else if (gen && got.text !== `realized by @[${gen[0]}] from ${gen[1]}`) bad.push(`${key}: ${it.n}'s origin pill reads "${got.text}"`);
        }
      }
      const flagged = [...contents.values()].flat().filter((it) => it.sorry || it.gen).length;
      if (flagged === 0) return [false, "no content declaration carries sorry or an origin: nothing was compared"];
      if (bad.length) return [false, `${bad.length} of ${n} declarations: ${few(bad)}`];
      return [true, `the pills on all ${n} drawn declaration sections are exactly their content's sorry and origin (${flagged} carry one), each origin pill naming its attribute and source`];
    });

    const richest = lastDecl(pathVisits.values(), `${newest}/`).where;
    const firstDecl = pathVisits.get(richest)!.decls[0];
    const searchHit = async (from: string, into: string): Promise<[boolean, string]> => {
      const term = firstDecl.slice(firstDecl.lastIndexOf(".") + 1);
      await run.fresh(`${P}/${from}`);
      const input = await page.$("#search-input");
      if (!input) return [false, `${from} has no #search-input`];
      await input.click();
      await input.type(term, { delay: 30 });
      const found = await page
        .waitForFunction(
          (name: string, selector: string) =>
            [...document.querySelectorAll<HTMLAnchorElement>(`${selector} a[href]`)].some(
              (a) => a.children[1]?.textContent === name && decodeURIComponent(new URL(a.href).hash.slice(1)) === name,
            ),
          { timeout: 8000 },
          firstDecl,
          into,
        )
        .then(() => true)
        .catch(() => false);
      if (!found) {
        const shown = await page.evaluate((selector: string) => (document.querySelector(selector)?.textContent ?? "<absent>").slice(0, 160), into);
        return [false, `typed "${term}" on ${from}, wanted a row linking ${firstDecl}; ${into} shows "${shown}"`];
      }
      return [true, `typing "${term}" on ${from} lists ${firstDecl} in ${into}, linking its page#id`];
    };
    await itemAsync("search-dropdown", () => searchHit(richest, "#search-results"));
    await itemAsync("search-page", () => searchHit(`${newest}/search.html`, "#page-results"));
    await itemAsync("search-ranking", async () => {
      const names = needIndex()[newest].map(([n]) => n).sort();
      const queries: string[] = [];
      for (const name of names.slice(0, 6)) {
        const last = (name.split(".").pop() ?? "").toLowerCase();
        if (last.length >= 2) queries.push(last.slice(0, Math.min(4, last.length)));
        const whole = name.toLowerCase();
        if (whole.length >= 3) queries.push(whole.slice(0, 3));
        if (last.length >= 4) queries.push(last.slice(1, 4));
      }
      queries.push("zzqq");
      const asked = [...new Set(queries)].filter((q) => q.length >= 2).slice(0, 12);
      const disagreements: string[] = [];
      let compared = 0;
      for (const [i, query] of asked.entries()) {
        if (i < 3) {
          await run.fresh(`${P}/${newest}/search.html`);
          const box = await page.$("#search-input");
          if (!box) {
            disagreements.push(`${query}: no #search-input`);
            continue;
          }
          dataDelayMs = DATA_DELAY_TYPED_MS;
          try {
            await box.click();
            await box.type(query, { delay: 130 });
            await new Promise((r) => setTimeout(r, 500 + 2 * DATA_DELAY_TYPED_MS));
          } finally {
            dataDelayMs = 0;
          }
        } else {
          await run.fresh(`${P}/${newest}/search.html?q=${encodeURIComponent(query)}`);
        }
        const settled = await page
          .waitForFunction(() => (document.querySelector("#page-note")?.textContent ?? "").length > 0, { timeout: 8000 })
          .then(() => true)
          .catch(() => false);
        if (!settled) {
          disagreements.push(`${query}: the page never reported a result`);
          continue;
        }
        const shown = await page.$$eval("#page-results li a", (rows) => rows.map((row) => row.children[1]?.textContent ?? ""));
        const note = await page.$eval("#page-note", (el) => el.textContent ?? "");
        const want = frozenSearch(names, query);
        compared++;
        if (shown.length !== Math.min(want.length, 200)) disagreements.push(`${query}: ${shown.length} rows listed for the frozen scorer's ${want.length} hits`);
        const top = Math.min(30, want.length, shown.length);
        for (let k = 0; k < top; k++) {
          if (shown[k] !== want[k]) {
            disagreements.push(`${query}: row ${k} is ${shown[k]}, the frozen scorer says ${want[k]}`);
            break;
          }
        }
        const counted = /^(\d+) match/.exec(note);
        const total = counted ? Number(counted[1]) : /No matching/.test(note) ? 0 : want.length;
        if (total !== want.length) disagreements.push(`${query}: the page counted ${total}, the frozen scorer ${want.length}`);
      }
      if (compared === 0) return [false, "no query was compared"];
      if (disagreements.length) return [false, `${disagreements.length} of ${compared}: ${few(disagreements, 3)}`];
      return [true, `${compared} queries on ${newest}/search.html rank and count as the frozen scorer over the ${names.length} indexed names, 3 typed one character at a time while each data file takes ${DATA_DELAY_TYPED_MS} ms`];
    });
    await itemAsync("theme-toggle", async () => {
      await run.fresh(`${P}/${richest}`);
      const moved = await page.evaluate(async () => {
        const before = document.documentElement.getAttribute("data-theme");
        document.querySelector<HTMLElement>("#theme-toggle")?.click();
        await new Promise((r) => setTimeout(r, 100));
        return [before, document.documentElement.getAttribute("data-theme")];
      });
      if (moved[0] === moved[1]) return [false, `#theme-toggle on ${richest} left data-theme at ${moved[0]}`];
      return [true, `#theme-toggle on ${richest} moves data-theme from ${moved[0]} to ${moved[1]}`];
    });
    await itemAsync("contrast", async () => {
      const bad: string[] = [];
      const said: string[] = [];
      for (const theme of ["light", "dark"]) {
        await run.fresh(`${P}/${richest}`);
        const rows = await page.evaluate((wanted: string) => {
          document.documentElement.setAttribute("data-theme", wanted);
          const parse = (value: string): number[] | null => {
            const inside = value.match(/rgba?\(([^)]+)\)/);
            if (!inside) return null;
            const parts = inside[1].split(",").map((v) => parseFloat(v.trim()));
            return [parts[0], parts[1], parts[2], parts.length > 3 ? parts[3] : 1];
          };
          const channel = (v: number) => {
            const c = v / 255;
            return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
          };
          const luminance = (rgb: number[]) => 0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2]);
          const background = (el: Element): number[] => {
            let node: Element | null = el;
            while (node) {
              const rgba = parse(getComputedStyle(node).backgroundColor);
              if (rgba && rgba[3] > 0) return rgba;
              node = node.parentElement;
            }
            return [255, 255, 255, 1];
          };
          const contrast = (fg: number[], bg: number[]) => {
            const pair = [luminance(fg), luminance(bg)].sort((a, b) => b - a);
            return (pair[0] + 0.05) / (pair[1] + 0.05);
          };
          const visible = (el: Element) => {
            const box = el.getBoundingClientRect();
            return box.width > 0 && box.height > 0;
          };
          return ["body", ".doc", ".decl-name", ".fn", ".src", "main a"].map((selector) => {
            const el = [...document.querySelectorAll(selector)].find(visible);
            if (!el) return { selector, found: false, ratio: 0, fg: "", bg: "" };
            const style = getComputedStyle(el);
            const fg = parse(style.color) ?? [0, 0, 0, 1];
            const bg = background(el);
            return { selector, found: true, ratio: Math.round(contrast(fg, bg) * 100) / 100, fg: style.color, bg: `rgb(${bg[0]}, ${bg[1]}, ${bg[2]})` };
          });
        }, theme);
        for (const row of rows) {
          if (!row.found) bad.push(`${theme} ${row.selector}: no element matched`);
          else if (row.ratio < 4.5) bad.push(`${theme} ${row.selector}: ${row.ratio}:1 (${row.fg} on ${row.bg})`);
          else said.push(`${theme} ${row.selector} ${row.ratio}:1`);
        }
      }
      if (bad.length) return [false, `under 4.5:1 or absent on ${richest}: ${few(bad, 6)}`];
      return [true, `on ${richest}, every named element is at least 4.5:1 in both themes: ${said.join(", ")}`];
    });
    await itemAsync("no-horizontal-scroll", async () => {
      const bad: string[] = [];
      const pages = pathPages.filter((p) => p.startsWith(`${newest}/`));
      try {
        for (const width of [375, 1440]) {
          await page.setViewport({ width, height: 800 });
          for (const rel of pages) {
            await run.fresh(`${P}/${rel}`);
            const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
            if (overflow > 1) bad.push(`${rel} at ${width}px: ${overflow}px`);
          }
        }
      } finally {
        await page.setViewport({ width: 800, height: 600 });
      }
      if (pages.length === 0) return [false, `no drawn page under ${newest}/`];
      if (bad.length) return [false, `${bad.length} of ${pages.length * 2} page widths scroll sideways: ${few(bad)}`];
      return [true, `none of ${newest}'s ${pages.length} drawn pages scrolls sideways at 375 px or 1440 px`];
    });
    await itemAsync("mathml", async () => {
      const rel = pathPages.find((p) => p.startsWith(`${newest}/`) && p.endsWith("/Math.html"));
      if (!rel) return [false, `no Math.html under ${newest}/: the sample lost its math page`];
      await run.fresh(`${P}/${rel}`);
      const boxes = await page.$$eval("math", (nodes) =>
        nodes.map((node) => {
          const rect = node.getBoundingClientRect();
          return { width: rect.width, height: rect.height, children: node.childElementCount };
        }),
      );
      const flat = boxes.filter((b) => b.width < 1 || b.height < 1).length;
      const bare = boxes.filter((b) => b.children === 0).length;
      if (boxes.length === 0) return [false, `${rel} drawn holds no <math>`];
      if (flat || bare) return [false, `of ${boxes.length} <math> on ${rel}, ${flat} have no box and ${bare} no child element: this browser is not laying out MathML`];
      return [true, `${boxes.length} <math> on ${rel} drawn, each laid out with a box and children, widest ${Math.max(...boxes.map((b) => b.width)).toFixed(0)} px`];
    });
    await itemAsync("mono-glyphs", async () => {
      const charset = JSON.parse(await readFile(MONO_CHARSET, "utf8")) as { chars: string };
      await run.fresh(`${P}/${richest}`);
      const measured = await page.evaluate((chars: string) => {
        const probe = document.querySelector(".sig, code, pre, .decl-name") ?? document.body;
        const style = getComputedStyle(probe);
        const font = `${style.fontSize} ${style.fontFamily}`;
        const box = Math.ceil(parseFloat(style.fontSize) * 2) || 32;
        const canvas = document.createElement("canvas");
        canvas.width = box;
        canvas.height = box;
        const g = canvas.getContext("2d", { willReadFrequently: true })!;
        const paint = () => {
          g.font = font;
          g.fillStyle = "#000";
          g.textBaseline = "middle";
        };
        paint();
        const unit = g.measureText("M").width;
        const blank: string[] = [];
        let offWidth = 0;
        let total = 0;
        for (const ch of chars) {
          total += 1;
          const width = g.measureText(ch).width;
          g.clearRect(0, 0, box, box);
          paint();
          g.fillText(ch, 1, box / 2);
          const pixels = g.getImageData(0, 0, box, box).data;
          let inked = false;
          for (let i = 3; i < pixels.length; i += 4) {
            if (pixels[i] !== 0) {
              inked = true;
              break;
            }
          }
          if (!inked) blank.push(ch);
          if (Math.abs(width - unit) > 0.5) offWidth++;
        }
        return { font, total, blank, offWidth };
      }, charset.chars);
      if (measured.total === 0) return [false, "mono-charset.json holds no character"];
      if (measured.blank.length) return [false, `${measured.blank.length} of ${measured.total} characters draw nothing in ${measured.font}: ${measured.blank.slice(0, 20).join("")}`];
      return [true, `all ${measured.total} characters of mono-charset.json draw in ${measured.font} on ${richest}; ${measured.offWidth} off the monospace advance (counted, never failed)`];
    });

    item("console", () => {
      if (run.errors.length) return [false, `${run.errors.length} console errors or page errors: ${few(run.errors, 3)}`];
      return [true, `no console error and no page error over ${pv.length + hv.length} drawn pages and the arrivals`];
    });
    item("requests", () => {
      if (run.failedRequests.length) return [false, `${run.failedRequests.length} failed requests: ${few(run.failedRequests, 3)}`];
      return [true, `no request failed or was answered >= 400, besides the ${run.deliberate.size} deliberate 404s (the old links and the footer's not-found page), which those items judge`];
    });

    console.log("frozen ids (v1, one-directional):");
    for (const row of frozenRows) console.log(row);
    console.log(`path URLs: ${pv.length} pages, ${pv.reduce((n, v) => n + v.hrefs.length, 0)} distinct hrefs per page summed, ${anchored} with an anchor`);
    console.log(`hash URLs: ${hv.length} routes, ${hv.reduce((n, v) => n + v.hrefs.length, 0)} distinct hrefs per route summed, ${hashAnchored} with an id`);
  } finally {
    await browser?.close();
    for (const s of servers) await s.shutdown();
  }
  verdict("MV-PAGES GATE", declared);
}

function verdict(gate: string, declared: readonly string[]): void {
  for (const i of items) console.log(`${i.ok ? "ok" : "FAIL"} ${i.name}: ${i.what}`);
  const ran = items.map((i) => i.name);
  const never = declared.filter((d) => !ran.includes(d));
  const unknown = ran.filter((r, k) => !declared.includes(r) || ran.indexOf(r) !== k);
  const failed = items.filter((i) => !i.ok).length;
  if (never.length || unknown.length) {
    console.error(`the items that reported are not the items declared: never reported ${never.join(", ") || "none"}; not declared or twice ${unknown.join(", ") || "none"}`);
    console.error(`${gate} FAIL: ${ran.length} of ${declared.length} reported, ${failed} failed`);
    process.exitCode = 1;
    return;
  }
  if (failed) {
    console.error(`${gate} FAIL: ${failed} of ${declared.length} failed (${ran.length} of ${declared.length} ran)`);
    process.exitCode = 1;
    return;
  }
  console.log(`${gate}: ok, ${ran.length} of ${declared.length} items ran and passed`);
}

const LIVE_DRAW_TIMEOUT_MS = 60000;
const LIVE_SCANNED_MODULES = 40;

async function fetched(url: URL): Promise<Buffer> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url.href} answered ${res.status}`);
  return Buffer.from(await res.arrayBuffer());
}

async function liveJson<T>(root: URL, address: string): Promise<T> {
  const bytes = await fetched(new URL(`d/${address}.json.gz`, root));
  const plain = bytes[0] === 0x1f && bytes[1] === 0x8b ? gunzipSync(bytes) : bytes;
  return JSON.parse(plain.toString("utf8")) as T;
}

async function liveSmoke(url: string, executablePath: string): Promise<void> {
  const root = new URL(url.endsWith("/") ? url : `${url}/`);
  const declared = ["live-root", "live-module", "live-search", "console", "requests"];
  const run = new Run(LIVE_DRAW_TIMEOUT_MS);
  let newest: VersionEntry | null = null;
  let module: { at: string; decls: string[] } | null = null;
  let visits = 0;
  let browser: Browser | undefined;
  try {
    browser = await puppeteer.launch({
      executablePath,
      headless: true,
      args: ["--no-sandbox", "--disable-dev-shm-usage", "--no-first-run"],
    });
    console.log(`browser           ${await browser.version()} (${executablePath})`);
    const page = await browser.newPage();
    await page.setCacheEnabled(false);
    run.watch(page);
    const visit = async (at: string): Promise<string> => {
      visits++;
      return await run.fresh(at);
    };

    await itemAsync("live-root", async () => {
      const list = JSON.parse((await fetched(new URL("versions.json", root))).toString("utf8")) as VersionEntry[];
      const last = Array.isArray(list) ? list[list.length - 1] : undefined;
      if (last === undefined || typeof last.name !== "string" || typeof last.data !== "string") {
        return [false, `${root.href}versions.json is not a non-empty version list`];
      }
      if (last.routes !== undefined) return [false, `${root.href}versions.json names a routes file: a hash-URL site, and --url drives path URLs`];
      newest = last;
      const drawn = await visit(root.href);
      const at = await page.evaluate(() => location.pathname);
      const want = `${root.pathname}${last.name}/index.html`;
      if (drawn !== "1" || at !== want) return [false, `${root.href} went to ${at} (drawn ${drawn || "never"}), not ${want}, the newest of ${list.length} in versions.json`];
      return [true, `${root.href} lands on ${want}, drawn; ${last.name} is the newest of ${list.length} in versions.json`];
    });

    await itemAsync("live-module", async () => {
      const v: VersionEntry | null = newest;
      if (v === null) throw new Error("live-root read no version list");
      const version = await liveJson<VersionFile>(root, v.data);
      const list = (await liveJson<{ modules: ModuleEntry[] }>(root, version.modules)).modules;
      const scanned = list.slice(0, LIVE_SCANNED_MODULES);
      let best: { m: ModuleEntry; n: number } | null = null;
      for (const m of scanned) {
        const shell = (await fetched(new URL(`${v.name}/${m.p}`, root))).toString("utf8");
        const address = / data-page="([0-9a-f]+)"/.exec(shell)?.[1];
        if (address === undefined) return [false, `${v.name}/${m.p} carries no data-page`];
        const lines = (await liveJson<{ lines: unknown[] }>(root, address)).lines;
        const n = lines.filter((x) => x !== 0).length;
        if (best === null || n > best.n) best = { m, n };
      }
      if (best === null) return [false, `${v.name}'s module list is empty`];
      const at = `${v.name}/${best.m.p}`;
      const drawn = await visit(new URL(at, root).href);
      const decls = await page.evaluate(() => [...document.querySelectorAll("section.decl[id]")].map((e) => e.id));
      if (drawn !== "1") return [false, `${at} did not draw (${drawn || "never"})`];
      if (decls.length === 0) return [false, `${at} drew no declaration section, though its page file places ${best.n}`];
      module = { at, decls };
      return [true, `${at} draws ${decls.length} declaration sections (the most placed declarations of the first ${scanned.length} of ${list.length} modules)`];
    });

    await itemAsync("live-search", async () => {
      const m: { at: string; decls: string[] } | null = module;
      if (m === null) throw new Error("live-module drew no declaration to search for");
      const lastOf = (name: string) => name.slice(name.lastIndexOf(".") + 1);
      const name = m.decls.reduce((a, b) => (lastOf(b).length > lastOf(a).length ? b : a));
      const term = lastOf(name);
      await visit(new URL(m.at, root).href);
      const input = await page.$("#search-input");
      if (!input) return [false, `${m.at} has no #search-input`];
      await input.click();
      await input.type(term, { delay: 30 });
      const row = await page
        .waitForFunction(
          (want: string) =>
            [...document.querySelectorAll<HTMLAnchorElement>("#search-results a[href]")].find(
              (a) => a.children[1]?.textContent === want && decodeURIComponent(new URL(a.href).hash.slice(1)) === want,
            ) ?? null,
          { timeout: LIVE_DRAW_TIMEOUT_MS },
          name,
        )
        .catch(() => null);
      const link = row?.asElement() ?? null;
      if (link === null) {
        const shown = await page.evaluate(() => (document.querySelector("#search-results")?.textContent ?? "<absent>").slice(0, 160));
        return [false, `typed "${term}" on ${m.at}, wanted a row linking ${name}; #search-results shows "${shown}"`];
      }
      await (link as ElementHandle<Element>).click();
      const arrived = await page
        .waitForFunction(
          (want: string) =>
            document.body.dataset.drawn === "1" &&
            decodeURIComponent(location.hash.slice(1)) === want &&
            document.querySelector(":target")?.id === want,
          { timeout: LIVE_DRAW_TIMEOUT_MS },
          name,
        )
        .then(() => true)
        .catch(() => false);
      const at = await page.evaluate(() => ({ path: location.pathname, hash: location.hash, target: document.querySelector(":target")?.id ?? null }));
      const want = new URL(m.at, root).pathname;
      if (!arrived || at.path !== want) {
        return [false, `clicking the row for ${name} landed on ${at.path}${decoded(at.hash)} with :target ${at.target ?? "nothing"}, not ${want}#${name}`];
      }
      return [true, `typing "${term}" on ${m.at} lists ${name}; clicking it lands on ${want}#${name}, :target`];
    });

    item("console", () => {
      if (visits === 0) return [false, "no page was loaded, so no console was watched"];
      if (run.errors.length) return [false, `${run.errors.length} console errors or page errors: ${few(run.errors, 3)}`];
      return [true, `no console error and no page error over ${visits} page loads`];
    });
    item("requests", () => {
      if (visits === 0) return [false, "no page was loaded, so no request was watched"];
      if (run.failedRequests.length) return [false, `${run.failedRequests.length} failed requests: ${few(run.failedRequests, 3)}`];
      return [true, `no request failed or was answered >= 400 over ${visits} page loads`];
    });
  } finally {
    await browser?.close();
  }
  verdict("LIVE-SMOKE GATE", declared);
}

await main();
