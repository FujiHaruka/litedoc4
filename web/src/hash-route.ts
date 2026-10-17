export interface HashPlace {
  readonly version: string;
  readonly page: string;
  readonly query: string;
  readonly anchor: string | null;
}

const ANCHOR = "id";

export const decoded = (s: string): string => {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
};

const split = (s: string, at: string): [string, string | null] => {
  const i = s.indexOf(at);
  return i < 0 ? [s, null] : [s.slice(0, i), s.slice(i + 1)];
};

export function hashHref(version: string, path: string): string {
  const [before, anchor] = split(path, "#");
  const [file, query] = split(before, "?");
  const params = new URLSearchParams(query ?? "");
  if (anchor !== null) params.set(ANCHOR, anchor);
  const page = file === "index.html" ? "" : file.replace(/\.html$/, "");
  const tail = params.toString();
  return `#/${version}/${page}${tail ? `?${tail}` : ""}`;
}

export function parseHash(hash: string): HashPlace | null {
  if (!hash.startsWith("#/")) return null;
  const [path, query] = split(hash.slice(2), "?");
  const params = new URLSearchParams(query ?? "");
  const anchor = params.get(ANCHOR);
  params.delete(ANCHOR);
  const rest = params.toString();
  const [version, page] = split(decoded(path), "/");
  if (version === "") return null;
  return { version, page: page ?? "", query: rest ? `?${rest}` : "", anchor };
}
