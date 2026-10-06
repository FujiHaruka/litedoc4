import { gunzipped } from "./gzip.js";

export type DataExt = "json" | "bin";

const TEXT = new TextDecoder();
const fetched = new Map<string, Promise<Uint8Array>>();

export const dataPath = (address: string, ext: DataExt): string => `d/${address}.${ext}.gz`;

export function dataBytes(root: string, address: string, ext: DataExt): Promise<Uint8Array> {
  const url = new URL(root + dataPath(address, ext), location.href).href;
  let bytes = fetched.get(url);
  if (!bytes) {
    bytes = fetch(url)
      .then((r) => (r.ok ? r.arrayBuffer() : Promise.reject(new Error(`${r.status} ${url}`))))
      .then((buffer) => gunzipped(new Uint8Array(buffer)));
    fetched.set(url, bytes);
  }
  return bytes;
}

export async function dataJson<T>(root: string, address: string): Promise<T> {
  return JSON.parse(TEXT.decode(await dataBytes(root, address, "json"))) as T;
}
