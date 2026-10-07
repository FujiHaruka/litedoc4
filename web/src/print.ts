/** A `<details>` that is closed on paper is a paragraph the reader cannot get. */
export function openForPrint(): void {
  addEventListener("beforeprint", () => {
    for (const d of document.querySelectorAll<HTMLDetailsElement>("details:not([open])")) {
      d.open = true;
      d.dataset.printOpened = "1";
    }
  });
  addEventListener("afterprint", () => {
    for (const d of document.querySelectorAll<HTMLDetailsElement>("details[data-print-opened]")) {
      d.open = false;
      delete d.dataset.printOpened;
    }
  });
}
