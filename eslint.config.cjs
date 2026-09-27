const js = require("@eslint/js");
const globals = require("globals");

module.exports = [
  {
    files: ["*.cjs", "scripts/*.{cjs,mjs}", "docs/javascripts/*.js"],
    linterOptions: {
      reportUnusedDisableDirectives: "error",
    },
    rules: js.configs.recommended.rules,
  },
  {
    files: ["*.cjs", "scripts/*.{cjs,mjs}"],
    languageOptions: { globals: globals.node },
  },
  {
    files: ["docs/javascripts/*.js"],
    languageOptions: {
      globals: { ...globals.browser, document$: "readonly" },
    },
  },
  {
    files: [
      "scripts/check-docs-accessibility.cjs",
      "scripts/check-web-export-browser.cjs",
    ],
    languageOptions: { globals: globals.browser },
  },
];
