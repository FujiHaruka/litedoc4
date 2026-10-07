import { decoded, hashHref } from "./hash-route.js";
import type { VersionEntry } from "./store-types.js";

export const MISSING = "missing";

export function rootCandidates(pathname: string): string[] {
  const parts = pathname.split("/");
  const out: string[] = [];
  for (let i = 1; i < parts.length; i++) out.push(`${parts.slice(0, i).join("/")}/`);
  return out;
}

export function isVersionList(value: unknown): value is VersionEntry[] {
  return (
    Array.isArray(value) &&
    value.length > 0 &&
    value.every(
      (e) =>
        typeof e === "object" &&
        e !== null &&
        typeof (e as VersionEntry).name === "string" &&
        typeof (e as VersionEntry).data === "string",
    )
  );
}

export type Lost =
  | { readonly kind: "unversioned"; readonly path: string }
  | { readonly kind: "versioned"; readonly version: string; readonly path: string }
  | { readonly kind: "nothing" };

export function lostAt(rest: string, versions: readonly string[]): Lost {
  const slash = rest.indexOf("/");
  const first = decoded(slash < 0 ? rest : rest.slice(0, slash));
  if (versions.includes(first)) {
    return { kind: "versioned", version: first, path: slash < 0 ? "" : rest.slice(slash + 1) };
  }
  return rest === "" ? { kind: "nothing" } : { kind: "unversioned", path: rest };
}

export const moduleOfPage = (path: string): string | null =>
  path.endsWith(".html") && path.length > 5
    ? decoded(path.slice(0, -5)).split("/").join(".")
    : null;

export interface Asked {
  readonly search: string;
  readonly hash: string;
}

export function hashTarget(root: string, lost: Lost, newest: string, asked: Asked): string {
  const anchor = asked.hash.length > 1 ? `#${decoded(asked.hash.slice(1))}` : "";
  const [version, path] =
    lost.kind === "versioned"
      ? [lost.version, lost.path]
      : [newest, lost.kind === "unversioned" ? lost.path : ""];
  return root + hashHref(version, decoded(path) + asked.search + anchor);
}
