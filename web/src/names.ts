const unescapeComponent = (s: string): string =>
  s.length >= 2 && s.startsWith("«") && s.endsWith("»") ? s.slice(1, -1) : s;

export function moduleComponents(module: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < module.length; i++) {
    const c = module[i];
    if (c === "«") depth++;
    else if (c === "»") depth--;
    else if (c === "." && depth === 0) {
      out.push(unescapeComponent(module.slice(start, i)));
      start = i + 1;
    }
  }
  out.push(unescapeComponent(module.slice(start)));
  return out;
}

export const modulePath = (module: string): string => moduleComponents(module).join("/");

export const pagePath = (module: string): string => `${modulePath(module)}.html`;

export const moduleSourceUrl = (base: string, module: string): string =>
  `${base}/${modulePath(module)}.lean`;

export const sourceUrlAt = (
  base: string,
  module: string,
  lines: readonly [number, number] | null,
): string => moduleSourceUrl(base, module) + (lines ? `#L${lines[0]}-L${lines[1]}` : "");

export const lastComponent = (name: string): string => name.slice(name.lastIndexOf(".") + 1);

export function kindDescription(kind: string, modifiers: readonly string[]): string {
  const has = (m: string): boolean => modifiers.includes(m);
  if (kind === "definition" || kind === "instance") {
    const a = has("unsafe") ? "unsafe " : "";
    const b = has("noncomputable") ? "noncomputable " : "";
    const c = kind === "instance" ? "instance" : has("abbrev") ? "abbrev" : "def";
    return a + b + c;
  }
  if (kind === "axiom" && has("unsafe")) return "unsafe axiom";
  if (kind === "opaque" && has("partial")) return "partial def";
  if (kind === "opaque" && has("unsafe")) return "unsafe opaque";
  if (kind === "inductive" && has("unsafe")) return "unsafe inductive";
  if (kind === "class_inductive") return "class inductive";
  return kind;
}

export function cssKind(kind: string): string {
  if (kind === "definition") return "def";
  if (kind === "class_inductive") return "class";
  if (kind === "constructor") return "ctor";
  return kind;
}

export const grouped = (n: number): string => String(n).replace(/\B(?=(\d{3})+$)/g, ",");
