/**
 * The names the two halves of the theme share. There are two because one of
 * them cannot wait: `theme-boot.ts` is inlined into every page's `<head>` and
 * runs **before the first paint**, while `theme.ts` arrives with the deferred
 * module.
 */

export const THEME_KEY = "litedoc4-theme";

export const THEMES = ["auto", "light", "dark"] as const;
export type Theme = (typeof THEMES)[number];

/** The themes that are an attribute on `<html>`; `auto` is the *absence* of one. */
export const PAINTED: readonly Theme[] = ["light", "dark"];
