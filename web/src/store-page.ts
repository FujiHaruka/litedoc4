import { initDrawer } from "./drawer.js";
import { draw, routeOf } from "./route.js";
import { initTheme } from "./theme.js";

async function start(): Promise<void> {
  const body = document.body;
  const route = routeOf(body.dataset);
  if (!route) return;
  try {
    const drawn = await draw(route);
    document.title = drawn.title;
    body.classList.toggle("plain", drawn.plain);
    body.replaceChildren(...drawn.nodes);
  } catch (error) {
    const p = document.createElement("p");
    p.className = "lede";
    p.textContent = `This page's data could not be loaded (${error instanceof Error ? error.message : String(error)}).`;
    body.replaceChildren(p);
    body.dataset.drawn = "failed";
    return;
  }
  initTheme();
  initDrawer();
  body.dataset.drawn = "1";
  if (location.hash) location.replace(location.href);
}

void start();
