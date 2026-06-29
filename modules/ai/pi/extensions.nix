# Build pinned Pi extensions as Nix derivations.
#
# Pi's local-path package source loads a directory containing `package.json`
# plus the files listed in the package's `files` field, optionally with a
# populated `node_modules/`. Each extension here pulls the registry tarball with
# `fetchurl` and grafts on a `node_modules/` built from a committed lockfile.
#
# `node_modules` is built with `importNpmLock` from the peer/dev-stripped
# `package-lock.json` under `npm-deps/<safeName>/`. Resolution is therefore
# pinned by the lockfile's per-dependency integrity hashes and cannot drift with
# the registry, unlike a build-time `npm install`. Optional dependencies are
# omitted, which keeps platform-specific native binaries (koffi, esbuild, ...)
# out of the closure so the result is identical on every system.
#
# Refreshing after a version bump:
#   - update `version` and `tarballHash` (set `tarballHash` to `lib.fakeHash`
#     and rebuild to learn the new value)
#   - regenerate `npm-deps/<safeName>/` from the new tarball: extract its
#     `package.json`, drop `devDependencies`, `peerDependencies` and
#     `optionalDependencies`, run `npm install --package-lock-only`, and commit
#     the resulting `package.json` and `package-lock.json`
{
  pkgs,
  lib,
}: let
  mkPiExtension = {
    name,
    version,
    tarballHash,
  }: let
    basename = lib.last (lib.splitString "/" name);
    safeName = lib.replaceStrings ["@" "/"] ["" "-"] name;

    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/${name}/-/${basename}-${version}.tgz";
      hash = tarballHash;
    };

    nodeModules = pkgs.importNpmLock.buildNodeModules {
      npmRoot = ./npm-deps + "/${safeName}";
      inherit (pkgs) nodejs;
      derivationArgs.npmFlags = ["--omit=optional"];
    };
  in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "pi-extension-${safeName}";
      inherit version src;

      # The npm tarball layout puts everything under `package/`.
      sourceRoot = "package";

      dontConfigure = true;
      dontBuild = true;

      # Pi loads these files through Node, which ignores shebangs and RPATHs, so
      # there is nothing for the fixup phase to usefully rewrite.
      dontFixup = true;

      installPhase = ''
        runHook preInstall

        mkdir -p $out
        cp -r . $out/

        # Extensions with no runtime dependencies produce no node_modules.
        if [ -d ${nodeModules}/node_modules ]; then
          cp -r ${nodeModules}/node_modules $out/node_modules
        fi

        runHook postInstall
      '';
    };
in {
  inherit mkPiExtension;

  extensions = {
    pi-mcp-adapter = mkPiExtension {
      name = "pi-mcp-adapter";
      version = "2.8.0";
      tarballHash = "sha256-kSjvMGShpuRb+ImdzY9PPbIAZahOTtA+SoOlPLTvg2w=";
    };

    # Web search, URL fetching, GitHub repository cloning, PDF extraction,
    # YouTube understanding, and local video analysis. The builtin
    # pi-subagents researcher uses this package when it is available.
    pi-web-access = mkPiExtension {
      name = "pi-web-access";
      version = "0.10.7";
      tarballHash = "sha256-v0CQxc2TySwdlGYCha3cazQpMgHQCaipjGVpW49H2Pk=";
    };

    # Claude-style permission modes, including a read-only plan mode and
    # Shift+Tab mode cycling.
    pi-claude-permissions = mkPiExtension {
      name = "@zackify/pi-claude-permissions";
      version = "1.0.6";
      tarballHash = "sha256-Huyi1yJM0PnhZ4GCvKqPBm8cmuoNojh40qBo4NQt4/0=";
    };

    # Persistent cross-session memory for preferences, corrections,
    # project patterns, and tool habits. It stores data locally and can
    # be curated through its memory tools and /memory-consolidate command.
    pi-memory = mkPiExtension {
      name = "@samfp/pi-memory";
      version = "1.3.2";
      tarballHash = "sha256-RyuzjzuaL0ruHPuskMRBGjZMWjgFeAhXkOgg0nVTQW4=";
    };

    # Reviews changed code for clarity, consistency, and maintainability
    # through the /simplify command.
    pi-simplify = mkPiExtension {
      name = "pi-simplify";
      version = "0.2.2";
      tarballHash = "sha256-2SFjI0hE3eVu76BUtRwnr0Q9owE5WBIVp0uPSEOE89Q=";
    };

    pi-subagents = mkPiExtension {
      name = "pi-subagents";
      version = "0.25.0";
      tarballHash = "sha256-V/fdxzOrdDJlSaJnMNOeWFihACrxK3LDkMkSgaGBzRY=";
    };

    pi-footer = mkPiExtension {
      name = "pi-footer";
      version = "0.3.0";
      tarballHash = "sha256-oUMIPlx+eqIfGolZqcqSS5vSYwniSc1boV8MVt17Np8=";
    };

    pi-sub-core = mkPiExtension {
      name = "@marckrenn/pi-sub-core";
      version = "1.5.0";
      tarballHash = "sha256-duR1dafk4MhRde3VSfU3m8UFAKE9h3Gxj6oXkTgUTTQ=";
    };

    # Cross-platform auto dark/light switcher. On Linux it polls
    # `gsettings get org.gnome.desktop.interface color-scheme` every
    # `pollMs`; on macOS it reads `AppleInterfaceStyle`. Both arms accept
    # custom theme names via `~/.pi/agent/system-theme.json`, which lets
    # us map the detected mode to the matching Catppuccin theme rendered
    # alongside this module.
    pi-system-theme = mkPiExtension {
      name = "pi-system-theme";
      version = "0.4.0";
      tarballHash = "sha256-8S5EVzEroElZhtEuzr+w5CHYpC5qoTFVWpX+j8eqSlY=";
    };

    # Git-ref snapshots of the working tree at every agent turn, with
    # restore commands for files+conversation, conversation only, or
    # files only. Cheap undo when the agent wanders off-track.
    checkpoint-pi = mkPiExtension {
      name = "checkpoint-pi";
      version = "1.0.5";
      tarballHash = "sha256-Zg57yjMUEnhq9NbPpwtrMs87IazszhYr6Gnor9ioJR4=";
    };

    # Runs LSP diagnostics on touched files after agent runs end, and
    # adds on-demand symbol/reference tools. Reuses the language servers
    # that `mcp.wrapWithTools` puts on PATH.
    lsp-pi = mkPiExtension {
      name = "lsp-pi";
      version = "1.0.5";
      tarballHash = "sha256-6xtaXAseK9d/zowUlOvUjIV2v+KOWFtolLJNn8MaAjg=";
    };

    # Desktop notification on agent_end via terminal escape sequences
    # (OSC 777/9/99 + tmux passthrough). No `libnotify` shell-out.
    pi-notify = mkPiExtension {
      name = "pi-notify";
      version = "1.3.0";
      tarballHash = "sha256-sX2/fI2QGUsrGnDZvljBJ4BZO403B0vqFcPJSF0hAKI=";
    };

    # Lets a prompt template's frontmatter declare `model`, `skill`, and
    # `thinking`, switching them for the prompt and restoring them after.
    pi-prompt-template-model = mkPiExtension {
      name = "pi-prompt-template-model";
      version = "0.9.3";
      tarballHash = "sha256-dVtmBT2zjJEQy1f/rt2+yNbW0TufQbl9sbMq3zX42Ac=";
    };
  };
}
