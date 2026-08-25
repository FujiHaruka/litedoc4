/**
 * The one-letter field names are `litedoc4_global::artifacts`'s — every module
 * carries them and the file is fetched by every page. `n` is the module name,
 * `p` its page relative to the site root, `i` the subscripts of the modules
 * that import it.
 */

export interface ModuleEntry {
  readonly n: string;
  readonly p: string;
  readonly i?: readonly number[];
}

export interface ModulesFile {
  readonly modules: readonly ModuleEntry[];
}

/** Keyed by declaration name. */
export interface InstancesFile {
  readonly instances?: Readonly<Record<string, readonly string[]>>;
  readonly instancesFor?: Readonly<Record<string, readonly string[]>>;
}

/**
 * A name with no users is **absent**, not an empty array — the file is the
 * largest of the four and 81% of the target package's declarations have no
 * users (measured 2026-08-22).
 */
export type UsedByFile = Readonly<Record<string, readonly string[]>>;

/**
 * What the previous query matched, in file order, so that a query extending it
 * is answered from these rather than from another walk of the name section.
 * The names are folded copies: the buffer they were folded into is written
 * over by the next declaration.
 */
export interface Narrow {
  readonly query: string;
  readonly names: Uint8Array[];
  readonly starts: number[];
  readonly ids: number[];
}

/**
 * `search-index.bin`, read in place: the header and the two small tables are
 * decoded once, **the names stay in the buffer** and are decoded per query.
 * The layout is `crates/litedoc4-global/src/search_index.rs`.
 */
export interface SearchIndex {
  readonly bytes: Uint8Array;
  readonly count: number;
  /** Offset of the front-coded name section. */
  readonly names: number;
  /** Offset of the restart table: one u32 per block. */
  readonly restarts: number;
  /** Declarations per restart block. */
  readonly restart: number;
  /** Offset of the kind subscripts: one byte each. */
  readonly kindOf: number;
  /** Offset of the module subscripts: one u16 each. */
  readonly moduleOf: number;
  /** Badge labels, pointed at by `kindOf`. */
  readonly labels: string[];
  /** The names ASCII folding is wrong for, by subscript. Usually empty. */
  readonly folds: Map<number, Uint8Array>;

  narrow: Narrow | null;

  /**
   * Scored in place: allocated once per page, and sized to what they hold
   * rather than to a machine word. Three `Int32Array`s cost **55 KiB of the
   * 156 KiB** the index took in Chrome (measured 2026-08-19), against a file of
   * 106 KiB.
   */
  readonly score: Uint16Array;
  readonly length: Uint16Array;
  readonly id: Uint16Array | Uint32Array;
}

export interface SearchData {
  readonly modules: readonly ModuleEntry[];
  readonly index: SearchIndex;
}
