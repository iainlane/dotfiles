{
  inputs,
  pkgs,
  modelCatalog,
  mcp,
  mcpServers,
  defaultModels ? modelCatalog.defaults,
  accent ? "blue",
  instructions ? (import ../agent-instructions.nix {inherit (pkgs) lib;}),
  skills ?
    (import ../skill-defaults.nix {
      inherit inputs;
      inherit (pkgs) lib;
    }).skills,
  skillRuntimeDependencies ?
    (import ../skill-defaults.nix {
      inherit inputs;
      inherit (pkgs) lib;
    }).runtimeDependencies,
  skillRuntimePackages ? null,
  proseLintEnabled ? true,
  proseLintOwners ? ["iainlane" "underwhelmingperformance"],
}: let
  inherit (pkgs) lib;
  skillTree = import ../skill-tree.nix {inherit pkgs lib;};
  runtimePackages =
    if skillRuntimePackages != null
    then skillRuntimePackages
    else pkgs // {inherit (inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}) agentsview;};
  dependencyNames = lib.unique (lib.concatLists (lib.attrValues (lib.filterAttrs (name: _: builtins.hasAttr name skills) skillRuntimeDependencies)));
  skillPackages = map (name: lib.attrByPath (lib.splitString "." name) (throw "Unknown skill runtime package: ${name}") runtimePackages) dependencyNames;
  filesFor = temporary: let
    files = import ./configuration.nix {
      inherit pkgs inputs modelCatalog defaultModels accent instructions mcpServers proseLintEnabled temporary;
      inherit lib;
    };
  in
    files
    // {
      home.file =
        files.home.file
        // {
          ".pi/agent/skills".source = skillTree {inherit skills;};
        };
      xdg.configFile =
        files.xdg.configFile
        // lib.optionalAttrs proseLintEnabled {
          "vale/.vale.ini".source = "${pkgs.prose-lint}/share/prose-lint/vale.ini";
          "prose-lint/config.toml".source = (pkgs.formats.toml {}).generate "prose-lint-config.toml" {owners = proseLintOwners;};
        };
    };
  normalFiles = filesFor false;
  previewFiles = filesFor true;
  render = import ./render-files.nix {inherit inputs pkgs;};
  normalAssets = render normalFiles;
  previewAssets = render previewFiles;
  collections = lib.genAttrs ["extensions" "managed-extensions" "packages" "prompts" "themes" "skills"] (name: "${normalAssets}/.pi/agent/${name}");
  wrapped = mcp.wrapWithTools {
    package = pkgs.pi;
    binName = "pi";
    extraWrapperArgs = ["--set" "PI_SKIP_VERSION_CHECK" "1" "--set" "PI_TELEMETRY" "0" "--set" "PI_LENS_DISABLE_TOOL_INSTALL" "1"];
  };
  executable = pkgs.writeShellApplication {
    name = "pi";
    runtimeInputs = [pkgs.nodejs pkgs.gh] ++ skillPackages ++ lib.optionals proseLintEnabled [pkgs.prose-lint pkgs.vale pkgs.vale-ls];
    text = ''exec ${lib.getExe wrapped} "$@"'';
  };
  package = pkgs.symlinkJoin {
    name = "pi-configured";
    paths = [executable];
    postBuild = ''
      mkdir -p "$out/share"
      ln -s ${normalAssets} "$out/share/pi"
    '';
    meta.mainProgram = "pi";
  };
  app = import ./temporary.nix {
    inherit pkgs package;
    assets = previewAssets;
  };
in {
  inherit package app normalFiles previewFiles normalAssets previewAssets collections;
}
