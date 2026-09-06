# Project Directories

Generates `.envrc` files for project directories so each one gets its own
development environment via direnv.

## What it does

Features like `home` and `work` define projects, directories with custom
environment variables (git identity, signing keys, etc.). This module creates
`.envrc` files that load those environments.

For example, if a feature defines:

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

## Keeping the `.envrc` in step with its shell

An `.envrc` has to change when its shell definition changes. The generated file
records the shell's derivation path in a comment, with the string context
stripped so the shell is not pulled into the home closure. A changed shell has a
different `.drv` path, so the file changes and direnv treats its cache as stale.
Home Manager's `onChange` hook then runs `direnv allow` on the new contents.

`lib/projects.nix` defines `mkProjectShells`, which builds these shells and the
Home Manager module that writes the `.envrc` files.
