import { type Child, el, link, markup, nameParts, withId } from "./dom.js";
import type { Linker } from "./links.js";

const ICON_MENU =
  '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 5h14M3 10h14M3 15h14"/></svg>';
const ICON_THEME =
  '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M10 3a7 7 0 1 0 7 7 5.5 5.5 0 0 1-7-7z"/></svg>';

function iconButton(id: string, label: string, icon: string): HTMLButtonElement {
  const b = withId(el("button", "iconbtn", markup(icon)), id);
  b.setAttribute("aria-label", label);
  return b;
}

function topbar(l: Linker, title: string, withNav: boolean): HTMLElement {
  const header = el("header", "topbar");
  if (withNav) {
    const toggle = iconButton("nav-toggle", "Modules", ICON_MENU);
    toggle.setAttribute("aria-expanded", "false");
    toggle.setAttribute("aria-controls", "sidebar");
    header.append(toggle);
  }
  const input = withId(el("input", ""), "search-input");
  input.type = "search";
  input.name = "q";
  input.autocomplete = "off";
  input.spellcheck = false;
  input.placeholder = "Search declarations";
  input.setAttribute("aria-label", "Search declarations");
  const results = withId(el("ul", "search-results"), "search-results");
  results.hidden = true;
  const form = el("form", "search", input, results);
  form.setAttribute("role", "search");
  form.setAttribute("action", l.at("search.html"));
  header.append(
    link("home", l.at("index.html"), title),
    form,
    iconButton("theme-toggle", "Theme", ICON_THEME),
  );
  return header;
}

const skip = (l: Linker): HTMLAnchorElement => link("skip", l.here("content"), "Skip to content");

export function plainFrame(l: Linker, title: string, ...content: Child[]): Node[] {
  const main = withId(el("main", "content", ...content), "content");
  return [skip(l), topbar(l, title, false), el("div", "shell", main)];
}

export function moduleFrame(
  l: Linker,
  title: string,
  members: readonly string[],
  main: HTMLElement,
): Node[] {
  const scrim = withId(el("div", "scrim"), "scrim");
  scrim.hidden = true;
  const nav = withId(el("nav", "sidebar"), "sidebar");
  nav.setAttribute("aria-label", "Navigation");
  if (members.length > 0) {
    const toc = el(
      "ul",
      "toc",
      ...members.map((name) => el("li", "", link("", l.here(name), ...nameParts(name)))),
    );
    nav.append(el("section", "side", el("h2", "side-title", "On this page"), toc));
  }
  nav.append(
    el(
      "details",
      "side",
      el("summary", "side-title", "Modules"),
      withId(el("div", "tree"), "module-tree"),
    ),
  );
  return [skip(l), topbar(l, title, true), el("div", "shell", scrim, nav, withId(main, "content"))];
}
