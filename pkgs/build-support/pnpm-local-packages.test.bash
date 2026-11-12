set -euo pipefail

node --input-type=commonjs - "$1" <<'JS'
const assert = require('node:assert/strict');
const createHooks = require(process.argv[2]);
const providers = [{ name: '@scope/local', version: '1.0.0', tarball: '/nix/store/local.tgz' }];
const { readPackage } = createHooks(providers).hooks;

for (const name of ['root', 'transitive-parent']) {
  const manifest = {
    name,
    version: '1.0.0',
    dependencies: {
      '@scope/local': '^1.0.0',
      aliased: 'npm:@scope/local@^1.0.0',
      unversioned: 'npm:@scope/local',
      other: 'npm:other@^1.0.0',
    },
    devDependencies: { '@scope/local': '1.0.0' },
    optionalDependencies: { '@scope/local': '1.0.0' },
    peerDependencies: { '@scope/local': '^1.0.0' },
    peerDependenciesMeta: { '@scope/local': { optional: true } },
  };
  assert.deepStrictEqual(readPackage(structuredClone(manifest)), {
    ...manifest,
    dependencies: {
      '@scope/local': 'file:/nix/store/local.tgz',
      aliased: 'file:/nix/store/local.tgz',
      unversioned: 'file:/nix/store/local.tgz',
      other: 'npm:other@^1.0.0',
    },
    devDependencies: { '@scope/local': 'file:/nix/store/local.tgz' },
    optionalDependencies: { '@scope/local': 'file:/nix/store/local.tgz' },
  });
}

const peerOnly = {
  name: 'peer-only',
  version: '1.0.0',
  peerDependencies: { '@scope/local': '^1.0.0' },
};
assert.deepStrictEqual(readPackage(structuredClone(peerOnly)), peerOnly);
assert.deepStrictEqual(createHooks([]).hooks.readPackage(structuredClone(peerOnly)), peerOnly);
console.log('Local pnpm substitutions preserve aliases, dependency kinds and peers.');
JS
