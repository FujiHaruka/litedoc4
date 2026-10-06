import { initDrawer } from "./drawer.js";
import { draw, routeOf } from "./route.js";
import { initSearch } from "./search-box.js";
import { initSearchPage } from "./search-page.js";
import { initFills, initTree } from "./store-fill.js";
import { versionSource } from "./store-search.js";
import { initTheme } from "./theme.js";
import { arrivalNotices, initVersions } from "./versions.js";

async function start(): Promise<void> {
  const body = document.body;
  const route = routeOf(body.dataset);
  if (!route) return;
  const own = [...body.childNodes];
  let drawn: Awaited<ReturnType<typeof draw>>;
  try {
    drawn = await draw(route, document.title, own);
  } catch (error) {
    const p = document.createElement("p");
    p.className = "lede";
    p.textContent = `This page's data could not be loaded (${error instanceof Error ? error.message : String(error)}).`;
    body.replaceChildren(p);
    body.dataset.drawn = "failed";
    return;
  }
  document.title = drawn.title;
  body.classList.toggle("plain", drawn.plain);
  body.replaceChildren(...drawn.nodes);
  initTheme();
  initDrawer();
  const source = versionSource(route.root, drawn.version, drawn.linker.at);
  if (route.kind === "search") initSearchPage(source);
  initSearch(source);
  if (route.kind === "module") {
    const c = { ...route, version: drawn.version, linker: drawn.linker, source };
    initFills(body, c);
    initTree(c);
  }
  arrivalNotices(route);
  body.dataset.drawn = "1";
  if (location.hash) location.replace(location.href);
  void initVersions(route);
}

void start();
