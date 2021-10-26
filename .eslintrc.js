module.exports = {
  root: true,
  parser: "@typescript-eslint/parser",
  plugins: ["prettier", "@typescript-eslint"],
  env: { node: true, mocha: true },
  globals: { contract: true, artifacts: true, web3: true, BigInt: true },
  rules: {
    "prettier/prettier": "error",
    "no-unused-vars": "off",
    "@typescript-eslint/no-unused-vars": "error",
  },
  extends: ["eslint:recommended", "plugin:prettier/recommended"],
};
