{pkgs}: let
  source = pkgs.lib.fileset.toSource {
    root = ./extensions/session-footer;
    fileset = pkgs.lib.fileset.unions [
      ./extensions/session-footer/index.ts
      ./extensions/session-footer/src
      ./extensions/session-footer/package.json
    ];
  };
in
  pkgs.runCommand "pi-session-footer" {} ''
    mkdir -p "$out/node_modules"
    cp -R ${source}/. "$out/"
    ln -s ${pkgs.pi-prs}/${pkgs.pi-prs.packageRoot} "$out/node_modules/pi-prs"
  ''
