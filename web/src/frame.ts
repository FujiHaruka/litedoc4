import { type Child, el, link, markup, nameParts, withId } from "./dom.js";

const ICON_MENU =
  '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 5h14M3 10h14M3 15h14"/></svg>';
const ICON_THEME =
  '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M10 3a7 7 0 1 0 7 7 5.5 5.5 0 0 1-7-7z"/></svg>';

export interface FrameText {
  readonly title: string;
  readonly at: (path: string) => string;
}

function iconButton(id: string, label: string, icon: string): HTMLButtonElement {
  const b = withId(el("button", "iconbtn", markup(icon)), id);
  b.setAttribute("aria-label", label);
  return b;
}

function topbar(f: FrameText, withNav: boolean): HTMLElement {
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
  form.setAttribute("action", f.at("search.html"));
  header.append(
    link("home", f.at("index.html"), f.title),
    form,
    iconButton("theme-toggle", "Theme", ICON_THEME),
  );
  return header;
}

const skip = (): HTMLAnchorElement => link("skip", "#content", "Skip to content");

export function plainFrame(f: FrameText, ...content: Child[]): Node[] {
  const main = withId(el("main", "content", ...content), "content");
  return [skip(), topbar(f, false), el("div", "shell", main)];
}

export function moduleFrame(f: FrameText, members: readonly string[], main: HTMLElement): Node[] {
  const scrim = withId(el("div", "scrim"), "scrim");
  scrim.hidden = true;
  const nav = withId(el("nav", "sidebar"), "sidebar");
  nav.setAttribute("aria-label", "Navigation");
  if (members.length > 0) {
    const toc = el(
      "ul",
      "toc",
      ...members.map((name) => el("li", "", link("", `#${name}`, ...nameParts(name)))),
    );
    nav.append(el("section", "side", el("h2", "side-title", "On this page"), toc));
  }
  nav.append(
    el(
      "section",
      "side",
      el("h2", "side-title", "Modules"),
      withId(el("div", "tree"), "module-tree"),
    ),
  );
  return [skip(), topbar(f, true), el("div", "shell", scrim, nav, withId(main, "content"))];
}
