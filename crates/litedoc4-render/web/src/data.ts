/**
 * The four data files, each fetched at most once and only once it is needed.
 *
 * None is cached in storage: they are ordinary GETs against the same origin
 * and the browser's HTTP cache is better at this than we are. (doc-gen4 tried
 * IndexedDB here and disabled it.)
 */
import { readIndex } from "./index-format.js";
import { url } from "./site.js";
import type { InstancesFile, ModulesFile, SearchData, SearchIndex, UsedByFile } from "./types.js";

let modulesPromise: Promise<ModulesFile | null> | null = null;
let declsPromise: Promise<SearchIndex | null> | null = null;
let instancesPromise: Promise<InstancesFile | null> | null = null;
let usedByPromise: Promise<UsedByFile | null> | null = null;

const fetchJson = <T>(name: string): Promise<T | null> =>
  fetch(url(name))
    .then((r) => (r.ok ? (r.json() as Promise<T>) : Promise.reject(new Error(String(r.status)))))
    .catch(() => null);

export function modules(): Promise<ModulesFile | null> {
  modulesPromise ??= fetchJson<ModulesFile>("modules.json");
  return modulesPromise;
}

export function decls(): Promise<SearchIndex | null> {
  declsPromise ??= fetch(url("search-index.bin"))
    .then((r) => (r.ok ? r.arrayBuffer() : Promise.reject(new Error(String(r.status)))))
    .then((buffer) => readIndex(new Uint8Array(buffer)))
    .catch(() => null);
  return declsPromise;
}

export function instanceMaps(): Promise<InstancesFile | null> {
  instancesPromise ??= fetchJson<InstancesFile>("instances.json");
  return instancesPromise;
}

export function usedByMap(): Promise<UsedByFile | null> {
  usedByPromise ??= fetchJson<UsedByFile>("declarations/used-by.json");
  return usedByPromise;
}

/**
 * The index and the module array it points into. They are separate files
 * because they are wanted at different times; a result row needs both.
 */
export async function searchData(): Promise<SearchData | null> {
  const [tree, index] = await Promise.all([modules(), decls()]);
  if (!tree?.modules || !index) return null;
  return { modules: tree.modules, index };
}
