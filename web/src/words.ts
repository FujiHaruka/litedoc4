import { link, markup } from "./dom.js";
import { type Linker, tableHref } from "./links.js";
import type { Table } from "./store-types.js";

export interface WordLink {
  readonly before: string;
  readonly linked: string;
  readonly href: string | null;
}

export function wordLink(word: string, hrefOf: (key: string) => string | null): WordLink {
  const whole = hrefOf(word);
  if (whole !== null) return { before: "", linked: word, href: whole };
  const dot = word.lastIndexOf(".");
  if (dot >= 0) {
    const tail = word.slice(dot + 1);
    const href = hrefOf(tail);
    if (href !== null) return { before: word.slice(0, dot + 1), linked: tail, href };
  }
  return { before: word, linked: "", href: null };
}

export function destination(
  dest: string,
  l: Pick<Linker, "at" | "here">,
  hrefOf: (key: string) => string | null,
): string {
  if (dest.startsWith("##")) {
    const name = dest.slice(2);
    return hrefOf(name) ?? l.at(`search.html?q=${encodeURIComponent(name)}`);
  }
  if (dest.startsWith("#")) return l.here(dest.slice(1));
  if (dest.startsWith("http")) return dest;
  return l.at(dest);
}

export function docNodes(html: string, words: Table, l: Linker): DocumentFragment {
  const hrefOf = (key: string): string | null => tableHref(l, words, key);
  const doc = markup(html);
  for (const a of doc.querySelectorAll("a[href]")) {
    a.setAttribute("href", destination(a.getAttribute("href") ?? "", l, hrefOf));
  }
  for (const w of [...doc.querySelectorAll("w")]) {
    const word = wordLink(w.textContent ?? "", hrefOf);
    const nodes: Node[] = [];
    if (word.before) nodes.push(document.createTextNode(word.before));
    if (word.href !== null) nodes.push(link("", word.href, word.linked));
    w.replaceWith(...nodes);
  }
  return doc;
}
