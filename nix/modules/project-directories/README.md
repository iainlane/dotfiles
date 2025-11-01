# Project Directories

Generates `.envrc` files for project directories so each one gets its own
development environment via direnv.

## What it does

Profiles like `home` and `work` define projects - directories with custom
environment variables (git identity, signing keys, etc.). This module creates
`.envrc` files that load those environments.

For example, if a profile defines:

```nix
projects = {
  dev-debian = {
    directory = "dev/debian";
    email = "laney@debian.org";
  };
};
```

This module generates `~/dev/debian/.envrc` pointing to a flake shell with
`EMAIL=laney@debian.org` set.

## The derivation tracking trick

The tricky bit: we want `.envrc` to update when the shell definition changes. We
do this by embedding the shell's derivation path as a comment in the `.envrc`.
When the shell changes, the `.drv` path changes, so the file changes, triggering
home-manager's `onChange` hook to clear the direnv cache.

See `lib/helpers.nix` for `mkProjectShells` which wires this up.
