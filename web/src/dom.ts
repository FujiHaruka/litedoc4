export type Child = Node | string;

export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  className: string,
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (className) e.className = className;
  e.append(...children);
  return e;
}

export function link(className: string, href: string, ...children: Child[]): HTMLAnchorElement {
  const a = el("a", className, ...children);
  a.setAttribute("href", href);
  return a;
}

export function withId<E extends HTMLElement>(e: E, id: string): E {
  e.id = id;
  return e;
}

export function nameParts(name: string): Node[] {
  const out: Node[] = [];
  name.split(".").forEach((part, i) => {
    if (i > 0) out.push(document.createTextNode("."));
    out.push(el("span", "name", part));
  });
  return out;
}

export function markup(html: string): DocumentFragment {
  const template = document.createElement("template");
  template.innerHTML = html;
  return template.content;
}
