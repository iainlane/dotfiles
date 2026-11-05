{
  inputs,
  lib,
  pkgs,
  flakeContexts,
  ...
}: let
  inherit (import ../../../lib/channels.nix {inherit inputs;}) channelFor;
  architecture = pkgs.stdenv.hostPlatform.parsed.cpu.name;
  workspace = channel: let
    guestChannel = channelFor {
      inherit channel;
      inherit (flakeContexts."${architecture}-linux") pkgs pkgs-stable;
    };
    guestPkgs = guestChannel.primary;
    inherit (guestChannel.unstable) librechat-code librechat-runtime;
    guest = import ./guest-image.nix {
      inherit (guestChannel) nixpkgs;
      inherit librechat-code librechat-runtime;
      pkgs = guestPkgs;
      servers = {};
      skills = guestPkgs.emptyDirectory;
      skillPackages = [];
      archiveCli = guestPkgs.writeShellScriptBin "agentsview" "exit 1";
    };
    configuration = pkgs.writeText "librechat-workspace-test.json" (builtins.toJSON {
      manifest = {
        programs = {
          qemu = lib.getExe' pkgs.qemu "qemu-system-${architecture}";
          socat = lib.getExe pkgs.socat;
          redis = lib.getExe' pkgs.redis "redis-server";
          rustfs = lib.getExe pkgs.rustfs;
          fileServer = lib.getExe' pkgs.librechat-code "librechat-code-file-server";
          egressGateway = lib.getExe' pkgs.librechat-code "librechat-code-egress-gateway";
          iron = lib.getExe pkgs.iron-proxy;
        };
        guest = {
          inherit (guest) image kernel initrd init;
          inherit architecture;
          accelerator =
            if pkgs.stdenv.hostPlatform.isDarwin
            then "auto"
            else "kvm";
        };
      };
      codeSource = pkgs.callPackage ../../../pkgs/librechat-code/source.nix {};
      bashVersion = builtins.replaceStrings ["p"] ["."] librechat-code.runtimes.bash.version;
      bash = lib.getExe guestPkgs.bash;
      coreutils = toString guestPkgs.coreutils;
      system = guestPkgs.stdenv.hostPlatform.system;
    });
  in
    pkgs.runCommand "librechat-workspace-${channel}" {
      requiredSystemFeatures = lib.optionals pkgs.stdenv.hostPlatform.isLinux ["kvm"];
      __darwinAllowLocalNetworking = true;
      passthru.configuration = configuration;
    } ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      mkdir -p runtime/test/fixtures
      cp ${../../../pkgs/librechat-runtime/test/fixtures/workspace.ts} runtime/test/fixtures/workspace.ts
      cp ${../../../pkgs/librechat-runtime/test/fixtures/accelerator.ts} runtime/test/fixtures/accelerator.ts
      ln -s ${pkgs.librechat-runtime}/lib/librechat-runtime/src runtime/src
      ln -s ${pkgs.librechat-runtime}/lib/librechat-runtime/node_modules runtime/node_modules
      cp ${pkgs.librechat-runtime}/lib/librechat-runtime/package.json runtime/package.json
      ${lib.getExe pkgs.nodejs_24} --disable-wasm-trap-handler runtime/test/fixtures/workspace.ts ${configuration}
      touch "$out"
    '';
in
  lib.listToAttrs (map (channel: lib.nameValuePair "librechat-workspace-${channel}" (workspace channel)) ["stable" "unstable"])
