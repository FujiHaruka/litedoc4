/**
 * Every bit of behaviour the site has, started from one place.
 *
 * Loaded as `type="module"`: deferred, strict, nothing leaked to globals.
 * **The page works without it** — navigation is links, the declarations are in
 * the HTML, the docstrings are already rendered. What this adds is the module
 * tree, search, the theme toggle, and the three lists that are facts about the
 * *whole* site rather than about the module being rendered.
 */
import { initDrawer } from "./drawer.js";
import { initImportedBy } from "./imported-by.js";
import { initInstances } from "./instances.js";
import { initNotFound } from "./not-found.js";
import { initSearch } from "./search-box.js";
import { initSearchPage } from "./search-page.js";
import { jumpToSource, openForPrint } from "./sundry.js";
import { initTheme } from "./theme.js";
import { initTree } from "./tree.js";

initTheme();
initDrawer();
initSearchPage(); // before `initSearch`: it removes the dropdown on that page
initSearch();
initInstances();
openForPrint();
jumpToSource();
void initTree();
void initImportedBy();
void initNotFound();
