/** @typedef {{name: string, version: string, tarball: string}} PackageProvider */
/**
 * @typedef {object} PackageManifest
 * @property {Record<string, string>} [dependencies]
 * @property {Record<string, string>} [devDependencies]
 * @property {Record<string, string>} [optionalDependencies]
 */

/** @param {PackageProvider[]} providers */
function createHooks(providers) {
  const packages = new Map(
    providers.map((provider) => [provider.name, provider]),
  );
  /** @type {(keyof PackageManifest)[]} */
  const fields = ["dependencies", "devDependencies", "optionalDependencies"];

  /**
   * @param {[string, string]} dependency
   * @returns {[string, string]}
   */
  function substitute([alias, specifier]) {
    const target = specifier.startsWith("npm:") ? specifier.slice(4) : alias;
    const separator = target.lastIndexOf("@");
    const name = separator > 0 ? target.slice(0, separator) : target;
    const provider = packages.get(name);

    return [
      alias,
      provider === undefined ? specifier : `file:${provider.tarball}`,
    ];
  }

  return {
    hooks: {
      /** @param {PackageManifest} manifest */
      readPackage(manifest) {
        for (const field of fields) {
          const dependencies = manifest[field];
          if (dependencies === undefined) {
            continue;
          }

          manifest[field] = Object.fromEntries(
            Object.entries(dependencies).map((dependency) =>
              substitute(dependency),
            ),
          );
        }

        return manifest;
      },
    },
  };
}

module.exports = createHooks;
