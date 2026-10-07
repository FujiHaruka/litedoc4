export type Ref = readonly [number, number] | readonly [number, number, string];

export type Text = string | readonly [string, readonly Ref[]];

export type Binder = readonly [0 | 1, Text];

export type OwnTarget = readonly [string] | readonly [string, string | null];

export type DependencyTarget =
  | readonly [number, string]
  | readonly [number, string, number, number];

export type Resolved = OwnTarget | DependencyTarget;

export type Table = Readonly<Record<string, Resolved>>;

export interface VersionFile {
  readonly version: string;
  readonly title: string;
  readonly commit: string;
  readonly lean: string;
  readonly source: string;
  readonly roots: Readonly<Record<string, string>>;
  readonly modules: string;
  readonly search: string;
  readonly instances: string;
  readonly references: string;
  readonly front: string | null;
}

export interface PageFile {
  readonly module: string;
  readonly imports: readonly string[];
  readonly content: string | null;
  readonly lines: readonly (0 | readonly [number, number])[];
  readonly roots: readonly string[];
  readonly names: Table;
  readonly words: Table;
}

export interface FieldItem {
  readonly n: string;
  readonly b?: readonly Binder[];
  readonly t: Text;
  readonly doc?: string;
  readonly inh?: 1;
  readonly id?: 1;
}

export interface CtorItem {
  readonly n: string;
  readonly b?: readonly Binder[];
  readonly t: Text;
  readonly doc?: string;
}

export interface DeclItem {
  readonly n: string;
  readonly k: string;
  readonly mods?: readonly string[];
  readonly attrs?: readonly string[];
  readonly sorry?: "direct" | "transitive";
  readonly gen?: readonly [string, string];
  readonly b?: readonly Binder[];
  readonly p?: readonly (readonly [string, Text])[];
  readonly t: Text;
  readonly doc?: string;
  readonly eq?: readonly Text[];
  readonly eqOmitted?: 1;
  readonly ctor?: string;
  readonly f?: readonly FieldItem[];
  readonly c?: readonly CtorItem[];
}

export interface ModuleDocItem {
  readonly moddoc: string;
}

export type ContentItem = DeclItem | ModuleDocItem;

export interface FrontPageFile {
  readonly html: string;
  readonly roots: readonly string[];
  readonly words: Table;
}

export interface ReferenceItem {
  readonly key: string;
  readonly tag: string;
  readonly html: string;
  readonly by: readonly (readonly [string, number, string])[];
}

export type UsedByPairs = Readonly<Record<string, readonly (readonly [string, string])[]>>;

export interface VersionEntry {
  readonly name: string;
  readonly data: string;
  readonly routes?: string;
}

export type RoutesFile = Readonly<Record<string, readonly [string, string]>>;
