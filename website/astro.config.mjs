import starlight from "@astrojs/starlight";
import { defineConfig } from "astro/config";
import starlightLlmsTxt from "starlight-llms-txt";

export default defineConfig({
  site: "https://fujiharuka.github.io",
  base: "/litedoc4/",
  integrations: [
    starlight({
      title: "litedoc4",
      description:
        "HTML documentation for Lean 4 packages built on Mathlib: fast, and every version in one site.",
      defaultLocale: "root",
      locales: {
        root: { label: "English", lang: "en" },
        ja: { label: "日本語", lang: "ja" },
      },
      social: [
        { icon: "github", label: "GitHub", href: "https://github.com/FujiHaruka/litedoc4" },
      ],
      editLink: { baseUrl: "https://github.com/FujiHaruka/litedoc4/edit/main/website/" },
      sidebar: [
        {
          label: "Getting started",
          translations: { ja: "はじめに" },
          items: [
            { slug: "getting-started/quickstart" },
            { slug: "getting-started/github-pages" },
            { slug: "getting-started/from-doc-gen4" },
          ],
        },
        {
          label: "Guides",
          translations: { ja: "ガイド" },
          items: [
            { slug: "guides/versions" },
            { slug: "guides/watch" },
            { slug: "guides/configuration" },
            { slug: "guides/pages" },
          ],
        },
        {
          label: "Reference",
          translations: { ja: "リファレンス" },
          items: [
            { slug: "reference/commands" },
            { slug: "reference/action" },
            { slug: "reference/checkout" },
            { slug: "reference/compatibility" },
          ],
        },
        { slug: "performance" },
      ],
      plugins: [starlightLlmsTxt({ exclude: ["404"] })],
    }),
  ],
});
