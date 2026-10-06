import { el, link, nameParts, withId } from "./dom.js";
import { FOUNDATIONAL_TYPES, type Linker, pageHref, tableHref } from "./links.js";
import {
  cssKind,
  kindDescription,
  lastComponent,
  moduleComponents,
  moduleSourceUrl,
} from "./names.js";
import { linkSegments, textParts } from "./spans.js";
import type {
  Binder,
  ContentItem,
  CtorItem,
  DeclItem,
  FieldItem,
  ModuleDocItem,
  PageFile,
  Text,
  VersionFile,
} from "./store-types.js";
import type { ModuleEntry } from "./types.js";
import { docNodes } from "./words.js";

export interface ModuleView {
  readonly linker: Linker;
  readonly version: VersionFile;
  readonly page: PageFile;
  readonly content: readonly ContentItem[];
}

interface Ctx {
  readonly l: Linker;
  readonly page: PageFile;
  readonly sourceUrl: string;
}

function textNodes(c: Ctx, t: Text): Node[] {
  const [text, refs] = textParts(t);
  return linkSegments(text, refs, (ref) =>
    ref.length === 2 ? c.l.at(FOUNDATIONAL_TYPES) : tableHref(c.l, c.page.names, ref[2]),
  ).map((s) => (s.href === null ? document.createTextNode(s.text) : link("", s.href, s.text)));
}

const doc = (c: Ctx, html: string): DocumentFragment => docNodes(html, c.page.words, c.l);

function binderNodes(c: Ctx, binders: readonly Binder[] | undefined): Node[] {
  return (binders ?? []).flatMap(([implicit, t]) => [
    el("span", implicit ? "binder implicit" : "binder", el("span", "fn", ...textNodes(c, t))),
    document.createTextNode("\n"),
  ]);
}

function signature(c: Ctx, d: DeclItem): HTMLElement {
  const sig = el("div", "sig", ...binderNodes(c, d.b));
  if ((d.k === "structure" || d.k === "class") && d.p && d.p.length > 0) {
    sig.append(el("span", "extends", "extends"), " ");
    d.p.forEach(([name, t], i) => {
      if (i > 0) sig.append(", ");
      sig.append(withId(el("span", "", ...textNodes(c, t)), name));
    });
  }
  sig.append(el("span", "colon", " :"), el("div", "sig-type", ...textNodes(c, d.t)));
  return sig;
}

function head(c: Ctx, d: DeclItem, lines: readonly [number, number] | null): HTMLElement {
  const range = lines ? `#L${lines[0]}-L${lines[1]}` : "";
  return el(
    "header",
    "decl-head",
    el("span", "kind", kindDescription(d.k, d.mods ?? [])),
    el(
      "h2",
      "decl-name",
      link("break_within", pageHref(c.l, c.page.module, d.n), ...nameParts(d.n)),
    ),
    link("src", c.sourceUrl + range, "source"),
  );
}

function flag(kind: string, ...children: (Node | string)[]): HTMLSpanElement {
  const span = el("span", "flag", ...children);
  span.dataset.flag = kind;
  return span;
}

function flags(c: Ctx, d: DeclItem): HTMLElement | null {
  const pills: HTMLElement[] = [];
  if (d.sorry === "direct") pills.push(flag("sorry-direct", "uses ", el("code", "", "sorry")));
  if (d.sorry === "transitive") {
    pills.push(flag("sorry-transitive", "depends on ", el("code", "", "sorry")));
  }
  if (d.gen) {
    const [origin, source] = d.gen;
    const href = tableHref(c.l, c.page.names, source);
    const name = el("code", "", source);
    pills.push(
      flag(
        "generated",
        "realized by ",
        el("code", "", `@[${origin}]`),
        " from ",
        href === null ? name : link("", href, name),
      ),
    );
  }
  return pills.length === 0 ? null : el("div", "flags", ...pills);
}

function fillBlock(fill: string, name: string, summary: string): HTMLDetailsElement {
  const details = el("details", "extra", el("summary", "", summary), el("ul", ""));
  details.dataset.fill = fill;
  details.dataset.name = name;
  return details;
}

function equations(c: Ctx, d: DeclItem): HTMLElement | null {
  if (!d.eq && !d.eqOmitted) return null;
  const ul = el("ul", "equations");
  if (d.eqOmitted) {
    ul.append(el("li", "", "One or more equations did not get rendered due to their size."));
  }
  for (const t of d.eq ?? []) ul.append(el("li", "", ...textNodes(c, t)));
  return el("details", "extra", el("summary", "", "Equations"), ul);
}

function memberSig(c: Ctx, nameEl: HTMLElement, m: FieldItem | CtorItem): HTMLElement {
  return el(
    "div",
    "field-sig",
    nameEl,
    ...binderNodes(c, m.b),
    el("span", "colon", " : "),
    ...textNodes(c, m.t),
  );
}

function memberDoc(c: Ctx, li: HTMLElement, m: FieldItem | CtorItem): HTMLElement {
  if (m.doc) li.append(el("div", "field-doc", doc(c, m.doc)));
  return li;
}

function field(c: Ctx, d: DeclItem, f: FieldItem): HTMLElement {
  const short = lastComponent(f.n);
  if (!f.inh) {
    const li = withId(el("li", "field", memberSig(c, el("span", "field-name", short), f)), f.n);
    return memberDoc(c, li, f);
  }
  const href = tableHref(c.l, c.page.names, f.n);
  const nameEl = href === null ? el("span", "field-name", short) : link("field-name", href, short);
  const li = el("li", "field inherited", memberSig(c, nameEl, f));
  if (f.id) li.id = `${d.n}.${short}`;
  return li;
}

function structure(c: Ctx, d: DeclItem): Node[] {
  const ctor = d.ctor ?? `${d.n}.mk`;
  const short = lastComponent(ctor);
  const out: Node[] = [];
  if (short !== "mk") out.push(el("p", "ctor-note", "constructor ", el("code", "", short)));
  out.push(withId(el("ul", "fields", ...(d.f ?? []).map((f) => field(c, d, f))), ctor));
  return out;
}

function constructors(c: Ctx, d: DeclItem): Node[] {
  const ctors = d.c ?? [];
  if (ctors.length === 0) return [];
  const lis = ctors.map((k) =>
    memberDoc(
      c,
      withId(el("li", "ctor", memberSig(c, el("span", "field-name", lastComponent(k.n)), k)), k.n),
      k,
    ),
  );
  return [el("ul", "ctors", ...lis)];
}

function declSection(c: Ctx, d: DeclItem, lines: readonly [number, number] | null): HTMLElement {
  const section = withId(el("section", "decl"), d.n);
  section.dataset.kind = cssKind(d.k);
  section.append(head(c, d, lines));
  const f = flags(c, d);
  if (f) section.append(f);
  if (d.attrs && d.attrs.length > 0) section.append(el("div", "attrs", `@[${d.attrs.join(", ")}]`));
  section.append(signature(c, d));
  if (d.doc) section.append(el("div", "doc", doc(c, d.doc)));
  const extra: Node[] = [];
  const eq = (): void => {
    const block = equations(c, d);
    if (block) extra.push(block);
  };
  if (d.k === "structure" || d.k === "class") {
    section.append(...structure(c, d));
    extra.push(
      d.k === "class"
        ? fillBlock("instances", d.n, "Instances")
        : fillBlock("instances-for", d.n, "Instances For"),
    );
  } else if (d.k === "definition") {
    eq();
    extra.push(fillBlock("instances-for", d.n, "Instances For"));
  } else if (d.k === "instance") {
    eq();
  } else if (d.k === "inductive") {
    section.append(...constructors(c, d));
    extra.push(fillBlock("instances-for", d.n, "Instances For"));
  } else if (d.k === "class_inductive") {
    section.append(...constructors(c, d));
    extra.push(fillBlock("instances", d.n, "Instances"));
  }
  extra.push(fillBlock("used-by", d.n, "Used by"));
  section.append(...extra);
  return section;
}

function importItem(c: Ctx, module: string): HTMLLIElement {
  const base = c.l.bases[moduleComponents(module)[0] ?? ""];
  return el(
    "li",
    "",
    base === undefined ? module : link("", moduleSourceUrl(base, module), module),
  );
}

function moduleMeta(c: Ctx): HTMLElement {
  const imports = c.page.imports;
  const summary = el("summary", "", "Imports");
  if (imports.length > 0) summary.append(" ", el("span", "count", String(imports.length)));
  const own = el(
    "details",
    "imports",
    summary,
    el("ul", "", ...imports.map((m) => importItem(c, m))),
  );
  const importedBy = el("details", "imports", el("summary", "", "Imported by"), el("ul", ""));
  importedBy.dataset.fill = "imported-by";
  importedBy.hidden = true;
  return el("div", "modmeta", own, importedBy);
}

const isModuleDoc = (item: ContentItem): item is ModuleDocItem => "moddoc" in item;

export function memberNames(content: readonly ContentItem[]): string[] {
  return content.flatMap((item) => (isModuleDoc(item) ? [] : [item.n]));
}

export function moduleMain(v: ModuleView): HTMLElement {
  const module = v.page.module;
  const sourceUrl = moduleSourceUrl(v.version.source, module);
  const c: Ctx = { l: v.linker, page: v.page, sourceUrl };
  const main = el(
    "main",
    "content",
    el(
      "div",
      "modhead",
      el("h1", "", ...nameParts(module)),
      el("p", "modactions", link("src", sourceUrl, "source")),
    ),
    moduleMeta(c),
  );
  v.content.forEach((item, i) => {
    if (isModuleDoc(item)) {
      main.append(el("div", "moddoc", doc(c, item.moddoc)));
      return;
    }
    const lines = v.page.lines[i];
    main.append(declSection(c, item, lines === 0 || lines === undefined ? null : lines));
  });
  main.querySelectorAll<HTMLAnchorElement>("a[data-cite]").forEach((a, k) => {
    a.removeAttribute("data-cite");
    a.id = `_backref_${k}`;
  });
  return main;
}

export function upgradeImports(
  main: HTMLElement,
  l: Linker,
  modules: readonly ModuleEntry[],
  self: string,
): void {
  const byName = new Map(modules.map((m) => [m.n, m]));
  for (const li of main.querySelectorAll<HTMLLIElement>(".modmeta .imports:not([data-fill]) li")) {
    const m = li.querySelector("a") ? undefined : byName.get(li.textContent ?? "");
    if (m) li.replaceChildren(link("", l.at(m.p), m.n));
  }
  const host = main.querySelector<HTMLElement>('[data-fill="imported-by"]');
  const entry = byName.get(self);
  const importers = (entry?.i ?? [])
    .map((k) => modules[k])
    .filter((m): m is ModuleEntry => m !== undefined)
    .sort((a, b) => a.n.localeCompare(b.n));
  if (!host || importers.length === 0) return;
  host.querySelector("ul")?.append(...importers.map((m) => el("li", "", link("", l.at(m.p), m.n))));
  host.querySelector("summary")?.append(el("span", "count", ` ${importers.length}`));
  host.hidden = false;
}
