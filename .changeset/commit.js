/** @type {import('@changesets/types').CommitFunctions} */
module.exports = {
  getVersionMessage: ({ releases: [{ newVersion }] }) => Promise.resolve(`🔖 release: v${newVersion}`),
};
