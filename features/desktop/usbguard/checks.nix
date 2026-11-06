{
  lib,
  pkgs,
  ...
}: let
  serial = "serial \"quoted\" \\ backslash\nnext";
  label = "device\tlabel";
  hash = "zgRuBkoOVD6C344a7PjQ3uuHeE3wzslavAxqm8ENJRI=";

  evaluated = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      ./options.nix
      ./nixos.nix
      {
        nixpkgs.pkgs = pkgs;
        system.stateVersion = "26.05";
        dotfiles.usbguard.staticRules = {
          "10-devices.conf" = [
            {
              target = "allow";
              id = "1235:8219";
              inherit serial hash label;
            }
            {
              target = "block";
              id = "1235:*";
              serial = "";
            }
          ];
          "20-fallback.conf" = [
            {
              target = "reject";
              id = "*:*";
            }
          ];
        };
      }
    ];
  };

  actual = lib.mapAttrs (_: file: file.text) (
    lib.filterAttrs (path: _: lib.hasPrefix "usbguard/rules.d/" path) evaluated.config.environment.etc
  );
  expected = {
    "usbguard/rules.d/10-devices.conf" = ''
      allow id 1235:8219 serial "serial \"quoted\" \\ backslash\x0anext" hash "${hash}" label "device\x09label"
      block id 1235:* serial ""
    '';
    "usbguard/rules.d/20-fallback.conf" = ''
      reject id *:*
    '';
  };

  validRule = {
    target = "allow";
    id = "1235:8219";
  };
  invalidRules = [
    ["allow id 1235:8219"]
    [(removeAttrs validRule ["target"])]
    [(removeAttrs validRule ["id"])]
    [(validRule // {target = "alow";})]
    [(validRule // {id = "1235:821";})]
    [(validRule // {id = "1235:8219\nallow";})]
    [(validRule // {hash = "not-a-hash";})]
    [(validRule // {serial = false;})]
    [(validRule // {lable = "typo";})]
  ];
  rejected = rules: let
    fixture = lib.evalModules {
      modules = [
        ./options.nix
        {dotfiles.usbguard.staticRules."test.conf" = rules;}
      ];
    };
  in
    !(builtins.tryEval (builtins.deepSeq fixture.config.dotfiles.usbguard.staticRules true)).success;
in {
  usbguard-rules = assert lib.assertMsg (actual == expected) "USBGuard rendered policy differs: ${builtins.toJSON actual}";
  assert lib.assertMsg (lib.all rejected invalidRules) "USBGuard accepted an invalid typed rule";
    pkgs.runCommandCC "usbguard-rules" {
      nativeBuildInputs = [pkgs.pkg-config];
      buildInputs = [pkgs.usbguard pkgs.libqb];
    } ''
      flags=$(pkg-config --cflags --libs libusbguard)
      $CXX -std=c++17 -Wall -Wextra -Werror ${./rules-test.cpp} \
        $flags -o rules-test
      ./rules-test \
        ${pkgs.writeText "usbguard-test.rules" (lib.concatStrings (lib.attrValues actual))} \
        ${lib.escapeShellArgs [serial label hash]}
      touch "$out"
    '';
}
