import { pagePath, sourceUrlAt } from "./names.js";
import type { DependencyTarget, OwnTarget, Resolved, Table } from "./store-types.js";

export interface Linker {
  readonly at: (path: string) => string;
  readonly here: (anchor: string) => string;
  readonly roots: readonly string[];
  readonly bases: Readonly<Record<string, string>>;
}

export const FOUNDATIONAL_TYPES = "foundational_types.html";

export const pageHref = (l: Linker, module: string, anchor: string | null): string =>
  l.at(pagePath(module) + (anchor === null ? "" : `#${anchor}`));

const isDependency = (r: Resolved): r is DependencyTarget => typeof r[0] === "number";

export function resolvedHref(l: Linker, key: string, r: Resolved): string | null {
  if (isDependency(r)) {
    const base = l.bases[l.roots[r[0]] ?? ""];
    if (base === undefined) return null;
    return sourceUrlAt(base, r[1], r.length === 4 ? [r[2], r[3]] : null);
  }
  const own: OwnTarget = r;
  return pageHref(l, own[0], own.length === 1 ? key : own[1]);
}

export function tableHref(l: Linker, table: Table, key: string): string | null {
  if (!Object.hasOwn(table, key)) return null;
  const r = table[key];
  return r === undefined ? null : resolvedHref(l, key, r);
}
