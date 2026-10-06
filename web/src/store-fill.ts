import { el, link } from "./dom.js";
import { findNames } from "./index-format.js";
import { declItem } from "./instances.js";
import { type Linker, pageHref } from "./links.js";
import { dataJson } from "./store-data.js";
import type { UsedByPairs, VersionFile } from "./store-types.js";
import { nest, treeHtml } from "./tree.js";
import type { InstancesFile, ModulesFile, SearchSource } from "./types.js";

export interface ModuleContext {
  readonly root: string;
  readonly module: string;
  readonly usedBy: string;
  readonly version: VersionFile;
  readonly linker: Linker;
  readonly source: SearchSource;
}

const note = (text: string): HTMLLIElement => el("li", "search-empty", text);

async function fillUsedBy(c: ModuleContext, name: string, ul: HTMLElement): Promise<void> {
  const pairs = await dataJson<UsedByPairs>(c.root, c.usedBy).catch(() => null);
  const users = pairs?.[name] ?? [];
  if (users.length === 0) {
    ul.replaceChildren(note(pairs ? "None" : "Index unavailable"));
    return;
  }
  ul.replaceChildren(
    ...users.map(([user, module]) =>
      el("li", "", link("", pageHref(c.linker, module, user), user)),
    ),
  );
}

async function fillInstances(
  c: ModuleContext,
  key: "instances" | "instancesFor",
  name: string,
  ul: HTMLElement,
): Promise<void> {
  const [maps, data] = await Promise.all([
    dataJson<InstancesFile>(c.root, c.version.instances).catch(() => null),
    c.source.data(),
  ]);
  const names = maps?.[key]?.[name] ?? [];
  if (names.length === 0) {
    ul.replaceChildren(note(maps ? "None" : "Index unavailable"));
    return;
  }
  const found = data ? findNames(data.index, names) : new Map<string, number>();
  ul.replaceChildren(...names.map((n) => declItem(data, n, found.get(n), c.source.href)));
}

export function initFills(host: ParentNode, c: ModuleContext): void {
  for (const block of host.querySelectorAll<HTMLDetailsElement>("details[data-fill]")) {
    const fill = block.dataset.fill;
    const name = block.dataset.name ?? "";
    const ul = block.querySelector("ul");
    if (!ul || fill === "imported-by") continue;
    block.addEventListener(
      "toggle",
      () => {
        if (fill === "used-by") void fillUsedBy(c, name, ul);
        else void fillInstances(c, fill === "instances" ? "instances" : "instancesFor", name, ul);
      },
      { once: true },
    );
  }
}

export function initTree(c: ModuleContext): void {
  const host = document.getElementById("module-tree");
  const block = host?.closest("details");
  if (!host || !block) return;
  block.addEventListener(
    "toggle",
    () => {
      void dataJson<ModulesFile>(c.root, c.version.modules).then((list) => {
        host.replaceChildren(treeHtml(nest(list.modules), "", c.module, c.linker.at));
        host.querySelector("[aria-current]")?.scrollIntoView({ block: "center" });
      });
    },
    { once: true },
  );
  document.getElementById("nav-toggle")?.addEventListener("click", () => {
    if (document.body.dataset.nav === "open") block.open = true;
  });
}
