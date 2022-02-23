/** @type {import('eslint').Linter.Config} */
module.exports = {
  parser: "@typescript-eslint/parser",
  parserOptions: { project: "./tsconfig.json" },
  settings: { "import/resolver": "typescript" },
  extends: [
    "eslint:recommended",
    "plugin:import/errors",
    "plugin:import/warnings",
    "plugin:node/recommended",
    "plugin:prettier/recommended",
    "plugin:eslint-comments/recommended",
    "plugin:@typescript-eslint/recommended",
  ],
  rules: {
    "node/no-missing-import": "off",
    "node/no-unpublished-import": "off",
    "@typescript-eslint/no-shadow": "error",
    "eslint-comments/no-unused-disable": "error",
    "@typescript-eslint/no-floating-promises": "error",
    "import/no-extraneous-dependencies": ["error", { devDependencies: true }],
    "@typescript-eslint/no-unused-vars": ["error", { ignoreRestSiblings: true }],
    "node/no-unsupported-features/es-syntax": ["error", { ignores: ["modules"] }],
  },
  overrides: [
    {
      files: ["test/**/*"],
      extends: ["plugin:mocha/recommended", "plugin:chai-expect/recommended", "plugin:chai-friendly/recommended"],
      rules: {
        "mocha/no-mocha-arrows": "off",
      },
    },
    {
      // TODO remove after refactor
      files: ["test/{4,5,6,8,9,10,11,12,13,14,15,16,17,18}_*", "test/*Env.ts", "test/*Utils.ts"],
      rules: {
        "no-var": "warn",
        "prefer-const": "warn",
        "mocha/no-sibling-hooks": "warn",
        "mocha/no-async-describe": "warn",
        "node/no-extraneous-import": "warn",
        "mocha/no-setup-in-describe": "warn",
        "@typescript-eslint/no-shadow": "warn",
        "import/no-extraneous-dependencies": "warn",
        "@typescript-eslint/no-explicit-any": "warn",
        "@typescript-eslint/no-inferrable-types": "warn",
      },
    },
  ],
};
