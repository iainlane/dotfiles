# The `pnpm-providers.bash` commands for a list of pnpm overrides from
# `lib/npm-packages.nix`.
{lib}: overrides: let
  tarballs = lib.unique (map (override: {inherit (override) file npmTarball;}) overrides);
in {
  link = directory: "bash ${./pnpm-providers.bash} link ${directory} ${lib.escapeShellArgs (lib.concatMap (tarball: [tarball.file tarball.npmTarball]) tarballs)}";
  check = lockfile: "bash ${./pnpm-providers.bash} check ${lockfile} ${lib.escapeShellArgs (lib.concatMap (override: [override.name override.file]) overrides)}";
}
