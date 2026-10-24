# Project Directories

Generates `.envrc` files for project directories. Each configured directory has
a shell derivation and optional paths to prepend to `PATH`.

## Configuration and retention

Features such as `development`, `home.debian` and `work` use `lib/projects.nix`
to construct shells inside their Home Manager modules. Only features selected by
the host contribute project directories. The shells use the unstable package set
on every host, including hosts whose system and home packages use the stable
channel.

The resulting configuration has this form:

```nix
programs.projectDirectories = {
  enable = true;
  directories."dev/example" = {
    shell = pkgs.mkShellNoCC {packages = [pkgs.git];};
    extraPaths = ["$HOME/go/bin"];
  };
};
```

The module adds each realised shell output to `home.extraDependencies`. A
retained Home Manager generation therefore keeps its project tools available
after garbage collection. The generated files discard the string context of
derivation paths so the home closure does not retain build-time derivations.

## Loading and cache refresh

Each `.envrc` loads the nearest ancestor's environment before loading its own
shell. The flake installable selects the shell from this host's
`homeConfigurations.<user>@<host>.config.programs.projectDirectories.directories`
configuration. Additional `PATH` entries follow the shell environment.

The file includes the shell's derivation path in a comment. A shell change
therefore changes `.envrc`, and Home Manager approves the new contents through
`direnv allow`. nix-direnv then invalidates its cached environment.

`./just update` builds the shells through the home configuration, switches to
the new configuration and refreshes the directory caches. The next directory
entry uses those caches. `./just refresh-direnvs` refreshes caches separately;
it does not build a separate shell catalogue. A failed evaluation, a missing
`.envrc` or nix-direnv fallback causes refresh to fail.

Refresh evaluates the configured host checkout. That checkout must exist and
contain the configuration that has been deployed. Remote deployment retains the
shell outputs through Home Manager, but does not refresh the remote user's
caches.

## Migration from separate shell roots

Older configurations retain project shells under
`${XDG_STATE_HOME:-$HOME/.local/state}/nix/direnv-shells`. A successful
`./just update` removes that directory after switching the home configuration
and refreshing every configured cache. If switching or refreshing fails, the
script preserves the old roots. Standalone refresh also preserves them.

After a successful manual configuration switch, run
`./scripts/refresh-direnvs.bash --after-switch` to refresh the caches and retire
the legacy roots. nix-direnv continues to manage its own cache profiles.
