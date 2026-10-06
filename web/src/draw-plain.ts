import { el, link, markup, nameParts, withId } from "./dom.js";
import { type Linker, pageHref } from "./links.js";
import { grouped } from "./names.js";
import type { FrontPageFile, ReferenceItem, VersionFile } from "./store-types.js";
import type { ModuleEntry } from "./types.js";
import { docNodes } from "./words.js";

const LEDE =
  "API documentation for every module of this package, generated from the compiled " +
  "environment. Declarations link to their pinned source; an import of a dependency links " +
  "to that dependency's source at the revision this package is built against.";

function stat(term: string, value: string): HTMLElement {
  return el("div", "", el("dt", "", term), el("dd", "", value));
}

export function indexContent(
  l: Linker,
  version: VersionFile,
  modules: readonly ModuleEntry[],
  front: FrontPageFile | null,
): Node[] {
  const out: Node[] = [el("div", "modhead", el("h1", "", version.title), el("p", "lede", LEDE))];
  if (front) {
    const frontLinker: Linker = { ...l, roots: front.roots };
    out.push(el("div", "intro doc", docNodes(front.html, front.words, frontLinker)));
  }
  const stats = el("dl", "stats", stat("Modules", grouped(modules.length)));
  if (version.lean) stats.append(stat("Lean", version.lean));
  out.push(
    stats,
    el("h2", "section-title", "Modules"),
    el(
      "ul",
      "modlist",
      ...modules.map((m) => el("li", "", link("", l.at(m.p), ...nameParts(m.n)))),
    ),
  );
  return out;
}

function backref(
  l: Linker,
  number: number,
  [module, index, funName]: ReferenceItem["by"][number],
): Node[] {
  const a = link("", pageHref(l, module, `_backref_${index}`), `[${number}]`);
  a.title = `File: ${module}${funName ? `\nLocation: ${funName}` : ""}`;
  return [document.createTextNode(" "), a];
}

export function referencesContent(l: Linker, items: readonly ReferenceItem[]): Node[] {
  const lis = items.map((item) => {
    const anchor = `ref_${item.key}`;
    const li = withId(
      el("li", "", link("", `#${anchor}`, item.tag), " ", markup(item.html)),
      anchor,
    );
    if (item.by.length > 0) {
      li.append(el("small", "", ...item.by.flatMap((b, i) => backref(l, i + 1, b))));
    }
    return li;
  });
  return [el("div", "modhead", el("h1", "", "References")), el("div", "doc", el("ul", "", ...lis))];
}
