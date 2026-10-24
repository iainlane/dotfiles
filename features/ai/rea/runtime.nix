{pkgs}: let
  inherit (pkgs) lib;
  linux = pkgs.stdenv.hostPlatform.isLinux;
  linuxX64 = linux && pkgs.stdenv.hostPlatform.isx86_64;
  python = pkgs.python3.withPackages (packages: [packages.pwntools]);
  browser = pkgs.playwright-driver.components.chromium-headless-shell;
  browserDirectory =
    {
      x86_64-linux = "linux64";
      aarch64-linux = "linux-arm64";
      aarch64-darwin = "mac-arm64";
    }.${
      pkgs.stdenv.hostPlatform.system
    };
  chromium = pkgs.writeShellScriptBin "rea-chromium" ''
    exec ${browser}/chrome-headless-shell-${browserDirectory}/chrome-headless-shell "$@"
  '';
  environment =
    {
      REA_BROWSER_EXECUTABLE = "${chromium}/bin/rea-chromium";
      REA_TSHARK_COMMAND = "${pkgs.wireshark-cli}/bin/tshark";
      REA_CAPINFOS_COMMAND = "${pkgs.wireshark-cli}/bin/capinfos";
      REA_OBJDUMP_COMMAND = "${pkgs.binutils}/bin/objdump";
    }
    // lib.optionalAttrs linux {
      REA_GDB_COMMAND = "${pkgs.gdb}/bin/gdb";
      REA_BINWALK_COMMAND = "${pkgs.binwalk}/bin/binwalk";
      REA_UNBLOB_COMMAND = "${pkgs.unblob}/bin/unblob";
      REA_MITMDUMP_COMMAND = "${pkgs.mitmproxy}/bin/mitmdump";
      REA_TSHARK_PRLIMIT_COMMAND = "${lib.getBin pkgs.util-linux}/bin/prlimit";
      REA_FIRMWARE_PRLIMIT_COMMAND = "${lib.getBin pkgs.util-linux}/bin/prlimit";
    }
    // lib.optionalAttrs linuxX64 {
      REA_PWNTOOLS_PYTHON = "${python}/bin/python3";
      REA_WAKARU_COMMAND = "${pkgs.wakaru}/bin/wakaru";
      REA_JAVASCRIPT_PRLIMIT_COMMAND = "${lib.getBin pkgs.util-linux}/bin/prlimit";
    };
  helpers = [pkgs.bash pkgs.coreutils pkgs.procps];
  flags = lib.concatStringsSep " " (lib.mapAttrsToList (key: value: "--set ${key} ${lib.escapeShellArg value}") environment);
in
  pkgs.symlinkJoin {
    name = "${pkgs.rea.name}-configured";
    paths = [pkgs.rea];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      for command in rea rea-agents; do
        rm "$out/bin/$command"
        makeWrapper ${pkgs.rea}/bin/$command "$out/bin/$command" \
          --prefix PATH : ${lib.makeBinPath helpers} \
          ${flags}
      done
    '';
    passthru = {
      inherit environment;
      unconfigured = pkgs.rea;
    };
    meta = pkgs.rea.meta;
  }
