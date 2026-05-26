# Build pinned Pi extensions as Nix derivations.
#
# Pi's local-path package source loads a directory containing `package.json`
# plus the files listed in the package's `files` field, optionally with a
# populated `node_modules/`. Each extension here is a fixed-output derivation:
# `fetchurl` pulls the registry tarball deterministically, `npm install`
# materialises the runtime dependency tree (peers are skipped because Pi
# bundles `@earendil-works/*`), and `outputHash` pins the result so the FOD
# stays reproducible even though `npm` is allowed network access during the
# build.
#
# Refreshing a hash after a version bump:
#   - update the version field on the extension below
#   - set `tarballHash` to `lib.fakeHash` and rebuild to learn the new value
#   - set `outputHash` to `lib.fakeHash` and rebuild again to learn that one
{
  pkgs,
  lib,
}: let
  mkPiExtension = {
    name,
    version,
    tarballHash,
    outputHash,
  }: let
    basename = lib.last (lib.splitString "/" name);
    safeName = lib.replaceStrings ["@" "/"] ["" "-"] name;
  in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "pi-extension-${safeName}";
      inherit version;

      src = pkgs.fetchurl {
        url = "https://registry.npmjs.org/${name}/-/${basename}-${version}.tgz";
        hash = tarballHash;
      };

      nativeBuildInputs = [pkgs.nodejs pkgs.cacert];

      # The npm tarball layout puts everything under `package/`.
      sourceRoot = "package";

      dontConfigure = true;
      dontBuild = true;

      # Skip Nix's fixup pass. Pi loads these files through Node, which
      # ignores shebangs and RPATHs. The fixup phase would rewrite, say,
      # `node_modules/open/xdg-open` to point at a Nix-store bash; that's
      # a store reference, and this is a fixed-output derivation, whose
      # output hash has to capture content downloaded from the network and
      # nothing else. Embedding store refs breaks that contract and Nix
      # refuses the build.
      dontFixup = true;

      installPhase = ''
        runHook preInstall

        mkdir -p $out
        cp -r . $out/

        cd $out
        export HOME="$(mktemp -d)"
        export npm_config_cache="$HOME/.npm"
        export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        export NODE_EXTRA_CA_CERTS="$SSL_CERT_FILE"

        # Peer deps are supplied by Pi itself; omit them so the extension
        # does not carry a duplicate copy of `@earendil-works/*`.
        npm install \
          --omit=dev \
          --omit=peer \
          --omit=optional \
          --no-audit \
          --no-fund \
          --no-progress \
          --loglevel=error

        runHook postInstall
      '';

      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      inherit outputHash;
    };
in {
  inherit mkPiExtension;

  extensions = {
    pi-mcp-adapter = mkPiExtension {
      name = "pi-mcp-adapter";
      version = "2.8.0";
      tarballHash = "sha256-kSjvMGShpuRb+ImdzY9PPbIAZahOTtA+SoOlPLTvg2w=";
      outputHash = "sha256-cE4nUtGUJP7jJ0oVa72HJPE42eHtgfBKiUmMlVOsRmo=";
    };

    # Web search, URL fetching, GitHub repository cloning, PDF extraction,
    # YouTube understanding, and local video analysis. The builtin
    # pi-subagents researcher uses this package when it is available.
    pi-web-access = mkPiExtension {
      name = "pi-web-access";
      version = "0.10.7";
      tarballHash = "sha256-v0CQxc2TySwdlGYCha3cazQpMgHQCaipjGVpW49H2Pk=";
      outputHash = "sha256-nSXl26ifMIxO2Sl0fw/NyfDu4FSxM+SwSEas+g17KW0=";
    };

    # Claude-style permission modes, including a read-only plan mode and
    # Shift+Tab mode cycling.
    pi-claude-permissions = mkPiExtension {
      name = "@zackify/pi-claude-permissions";
      version = "1.0.6";
      tarballHash = "sha256-Huyi1yJM0PnhZ4GCvKqPBm8cmuoNojh40qBo4NQt4/0=";
      outputHash = "sha256-bY7ZS55yQ7lMTcTsPiwMg9Tvz0sWJSU7yLAo6v0Dpe4=";
    };

    # Persistent cross-session memory for preferences, corrections,
    # project patterns, and tool habits. It stores data locally and can
    # be curated through its memory tools and /memory-consolidate command.
    pi-memory = mkPiExtension {
      name = "@samfp/pi-memory";
      version = "1.3.2";
      tarballHash = "sha256-RyuzjzuaL0ruHPuskMRBGjZMWjgFeAhXkOgg0nVTQW4=";
      outputHash = "sha256-qhSVSC0xWI3fvTrHxfO+smNOi1KMSdCJ+I9wCC7+DKg=";
    };

    # Reviews changed code for clarity, consistency, and maintainability
    # through the /simplify command.
    pi-simplify = mkPiExtension {
      name = "pi-simplify";
      version = "0.2.2";
      tarballHash = "sha256-2SFjI0hE3eVu76BUtRwnr0Q9owE5WBIVp0uPSEOE89Q=";
      outputHash = "sha256-Vcm6xn27VUWc4QMpN+H3kCVQ5E+EDKdE/5gTVsFrFGM=";
    };

    pi-subagents = mkPiExtension {
      name = "pi-subagents";
      version = "0.25.0";
      tarballHash = "sha256-V/fdxzOrdDJlSaJnMNOeWFihACrxK3LDkMkSgaGBzRY=";
      outputHash = "sha256-NIvjzv1Nl9GwTFEZZQZkPkziMJTQ5aG41xeTLwj6klg=";
    };

    pi-footer = mkPiExtension {
      name = "pi-footer";
      version = "0.3.0";
      tarballHash = "sha256-oUMIPlx+eqIfGolZqcqSS5vSYwniSc1boV8MVt17Np8=";
      outputHash = "sha256-zGlv3dEZT32VPlR6X89o9Oi1O/FCBQYamLtat6C8ueM=";
    };

    pi-sub-core = mkPiExtension {
      name = "@marckrenn/pi-sub-core";
      version = "1.5.0";
      tarballHash = "sha256-duR1dafk4MhRde3VSfU3m8UFAKE9h3Gxj6oXkTgUTTQ=";
      outputHash = "sha256-Nbl2I/KZIUdt6AHfq0hrW1g0MxhwSImhMtwyy6Bof5E=";
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
      outputHash = "sha256-cz4hBmb69WD/GhMU2aX1hQaYmEpq00kMNbTr8GZ7zjw=";
    };

    # Git-ref snapshots of the working tree at every agent turn, with
    # restore commands for files+conversation, conversation only, or
    # files only. Cheap undo when the agent wanders off-track.
    checkpoint-pi = mkPiExtension {
      name = "checkpoint-pi";
      version = "1.0.5";
      tarballHash = "sha256-Zg57yjMUEnhq9NbPpwtrMs87IazszhYr6Gnor9ioJR4=";
      outputHash = "sha256-qmPYH0mcf1bN1FwG+f+yTd+ajbA3p7Q828Su7EBPh6M=";
    };

    # Runs LSP diagnostics on touched files after agent runs end, and
    # adds on-demand symbol/reference tools. Reuses the language servers
    # that `mcp.wrapWithTools` puts on PATH.
    lsp-pi = mkPiExtension {
      name = "lsp-pi";
      version = "1.0.5";
      tarballHash = "sha256-6xtaXAseK9d/zowUlOvUjIV2v+KOWFtolLJNn8MaAjg=";
      outputHash = "sha256-9OkIb6W19XzN19Ad8RlBMfyUImRcuU11rykJVGlCtkM=";
    };

    # Desktop notification on agent_end via terminal escape sequences
    # (OSC 777/9/99 + tmux passthrough). No `libnotify` shell-out.
    pi-notify = mkPiExtension {
      name = "pi-notify";
      version = "1.3.0";
      tarballHash = "sha256-sX2/fI2QGUsrGnDZvljBJ4BZO403B0vqFcPJSF0hAKI=";
      outputHash = "sha256-snd50ttijD2YCiDizmjRq8E0dxtT4ot9uPYdDeIaWhk=";
    };

    # Lets a prompt template's frontmatter declare `model`, `skill`, and
    # `thinking`, switching them for the prompt and restoring them after.
    pi-prompt-template-model = mkPiExtension {
      name = "pi-prompt-template-model";
      version = "0.9.3";
      tarballHash = "sha256-dVtmBT2zjJEQy1f/rt2+yNbW0TufQbl9sbMq3zX42Ac=";
      outputHash = "sha256-zoLZuF8wAnH38CF7jkCeagG4Kc62tu1C3DNtsC/lA58=";
    };
  };
}
