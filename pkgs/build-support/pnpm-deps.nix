{
  fetchPnpmDeps,
  lib,
  localNpmPackages,
  writeText,
}: {
  npmRoot,
  pname,
  src,
  sourceRoot,
  pnpm,
  hash,
}: let
  npmPackages = import ../../lib/npm-packages.nix {inherit lib;};
  provided = npmPackages.providePnpm {
    packages = localNpmPackages;
    lockfile = builtins.readFile (npmRoot + "/pnpm-lock.yaml");
  };
  metadata = map (package: (npmPackages.npmPackage package) // {tarball = toString package.npmTarball;}) provided;
  providers = writeText "${pname}-npm-packages.json" (builtins.toJSON metadata);
  pnpmfile = writeText "${pname}-pnpmfile.cjs" (lib.replaceStrings ["module.exports = createHooks;"] [
    ''
      module.exports = createHooks([
        ${lib.concatMapStringsSep ",\n  " builtins.toJSON metadata}
      ]);
    ''
  ] (builtins.readFile ./pnpm-local-packages.cjs));
  pnpmDeps = fetchPnpmDeps {
    inherit pname src sourceRoot pnpm hash;
    fetcherVersion = 5;
    prePnpmInstall = ''
      if ! yq -e '.lockfileVersion == "9.0" and (.packages | type == "object") and (.snapshots | type == "object") and (.importers | type == "object")' pnpm-lock.yaml >/dev/null; then
        echo 'Unsupported pnpm lockfile. Regenerate it with pnpm 10.' >&2
        exit 1
      fi
      sha256sum pnpm-lock.yaml > pnpm-lock.sha256
      jq -c '.[]' ${providers} | while IFS= read -r provider; do
        name=$(jq -r .name <<< "$provider")
        version=$(jq -r .version <<< "$provider")
        tarball=$(jq -r .tarball <<< "$provider")
        tar -xOf "$tarball" package/package.json | jq -e --arg name "$name" --arg version "$version" '.name == $name and .version == $version' >/dev/null
        yq -e --arg name "$name" --arg version "$version" '(.packages | keys | map(select(startswith($name + "@")))) == [$name + "@" + $version]' pnpm-lock.yaml >/dev/null
      done
      cp ${pnpmfile} .pnpmfile.cjs
      pnpm install --lockfile-only --no-frozen-lockfile --ignore-scripts --force
    '';
    postInstall = ''
      # The generated lock and hook contain store paths, which fixed-output reference scanning rejects.
      tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner --zstd \
        -cf "$out/pnpm-config.tar.zst" pnpm-lock.yaml .pnpmfile.cjs pnpm-lock.sha256
    '';
  };
in {
  inherit pnpmDeps provided;

  prepare = ''
    if ! tar --zstd -xOf ${pnpmDeps}/pnpm-config.tar.zst pnpm-lock.sha256 | sha256sum --check --status; then
      echo 'The pnpm lockfile changed. Update the pnpm dependency hash.' >&2
      exit 1
    fi
    tar --zstd -xf ${pnpmDeps}/pnpm-config.tar.zst pnpm-lock.yaml .pnpmfile.cjs
    if ! cmp -s ${pnpmfile} .pnpmfile.cjs; then
      echo 'Local npm packages changed. Update the pnpm dependency hash.' >&2
      exit 1
    fi
  '';
}
