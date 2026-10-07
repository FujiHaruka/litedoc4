import { FOUNDATIONAL_TYPES } from "./links.js";
import { dataJson } from "./store-data.js";
import type { VersionEntry, VersionFile } from "./store-types.js";
import type { ModuleEntry, ModulesFile } from "./types.js";

const VERSION_PAGES: readonly string[] = [
  "index.html",
  "references.html",
  "search.html",
  FOUNDATIONAL_TYPES,
];

export async function modulesIn(
  root: string,
  entry: VersionEntry,
): Promise<readonly ModuleEntry[]> {
  const version = await dataJson<VersionFile>(root, entry.data);
  return (await dataJson<ModulesFile>(root, version.modules)).modules;
}

export const hasPage = (modules: readonly ModuleEntry[], page: string): boolean =>
  VERSION_PAGES.includes(page) || modules.some((m) => m.p === page);
