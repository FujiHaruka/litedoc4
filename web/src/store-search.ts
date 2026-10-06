import { readIndex } from "./index-format.js";
import { dataBytes, dataJson } from "./store-data.js";
import type { VersionFile } from "./store-types.js";
import type { ModulesFile, SearchData, SearchSource } from "./types.js";

export function versionSource(
  root: string,
  version: VersionFile,
  at: (page: string) => string,
): SearchSource {
  let loaded: Promise<SearchData | null> | null = null;
  const load = async (): Promise<SearchData | null> => {
    const [list, bytes] = await Promise.all([
      dataJson<ModulesFile>(root, version.modules),
      dataBytes(root, version.search, "bin"),
    ]);
    const index = readIndex(bytes);
    return index ? { modules: list.modules, index } : null;
  };
  return {
    data: () => {
      loaded ??= load().catch(() => null);
      return loaded;
    },
    href: at,
  };
}
