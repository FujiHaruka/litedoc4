export const body = document.body;

/** The site root, relative to this page. `Litedoc4.Render.Page` writes it on
 * `<body>`. */
export const ROOT = body.dataset.root ?? "./";

export const MODULE = body.dataset.module ?? "";

export const url = (name: string): string => new URL(ROOT + name, location.href).href;
