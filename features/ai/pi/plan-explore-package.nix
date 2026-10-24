{pkgs}: let
  source = pkgs.lib.fileset.toSource {
    root = ./extensions/plan-explore;
    fileset = pkgs.lib.fileset.unions [
      ./extensions/plan-explore/index.ts
      ./extensions/plan-explore/src
      ./extensions/plan-explore/package.json
    ];
  };
in
  pkgs.runCommand "pi-plan-explore" {} ''
    mkdir -p "$out/node_modules"
    cp -R ${source}/. "$out/"
    ln -s ${pkgs.pi-subagents}/${pkgs.pi-subagents.packageRoot} "$out/node_modules/pi-subagents"
  ''
