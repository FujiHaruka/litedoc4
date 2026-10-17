import type { Ref, Text } from "./store-types.js";

export interface Segment {
  readonly text: string;
  readonly href: string | null;
}

export const textParts = (t: Text): readonly [string, readonly Ref[]] =>
  typeof t === "string" ? [t, []] : t;

export function linkSegments(
  text: string,
  refs: readonly Ref[],
  hrefOf: (ref: Ref) => string | null,
): Segment[] {
  const kids: number[][] = refs.map(() => []);
  const roots: number[] = [];
  const stack: number[] = [];
  refs.forEach((ref, me) => {
    while (stack.length > 0 && ref[0] >= (refs[stack[stack.length - 1] ?? 0]?.[1] ?? 0)) {
      stack.pop();
    }
    const parent = stack[stack.length - 1];
    if (parent === undefined) roots.push(me);
    else kids[parent]?.push(me);
    stack.push(me);
  });

  const href: (string | null)[] = refs.map(() => null);
  const anchored: boolean[] = refs.map(() => false);
  for (let me = refs.length - 1; me >= 0; me--) {
    const below = (kids[me] ?? []).some((c) => anchored[c]);
    const ref = refs[me];
    const own = below || ref === undefined ? null : hrefOf(ref);
    href[me] = own;
    anchored[me] = below || own !== null;
  }

  const out: Segment[] = [];
  const plain = (from: number, to: number): void => {
    if (to <= from) return;
    const last = out[out.length - 1];
    if (last && last.href === null)
      out[out.length - 1] = { text: last.text + text.slice(from, to), href: null };
    else out.push({ text: text.slice(from, to), href: null });
  };
  const emit = (from: number, to: number, nodes: readonly number[]): void => {
    let pos = from;
    for (const c of nodes) {
      const ref = refs[c];
      if (ref === undefined) continue;
      plain(pos, ref[0]);
      const link = href[c] ?? null;
      if (link !== null) out.push({ text: text.slice(ref[0], ref[1]), href: link });
      else emit(ref[0], ref[1], kids[c] ?? []);
      pos = ref[1];
    }
    plain(pos, to);
  };
  emit(0, text.length, roots);
  return out;
}
