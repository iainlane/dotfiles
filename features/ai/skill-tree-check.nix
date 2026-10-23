{pkgs, ...}: let
  inherit (pkgs) lib;

  skillTree = import ./skill-tree.nix {inherit lib pkgs;};

  # A user-only skill from elsewhere, which brings its own Codex policy.
  directorySkill = pkgs.runCommandLocal "directory-skill" {} ''
    install -D --mode=0444 ${pkgs.writeText "SKILL.md" ''
      ---
      name: directory
      description: A fixture skill.
      disable-model-invocation: true
      ---

      # directory
    ''} "$out"/SKILL.md

    install -D --mode=0444 ${pkgs.writeText "openai.yaml" ''
      policy:
        allow_implicit_invocation: false
    ''} "$out"/agents/openai.yaml
  '';

  bundledSkill = name:
    pkgs.writeText "SKILL.md" ''
      ---
      name: ${name}
      description: A fixture skill.
      ---

      # ${name}
    '';

  # A directory of skills, with no SKILL.md at its top.
  skillBundle = pkgs.runCommandLocal "skill-bundle" {} ''
    install -D --mode=0444 ${bundledSkill "bundled"} "$out"/bundled/SKILL.md
    install -D --mode=0444 ${bundledSkill "unwanted"} "$out"/unwanted/SKILL.md
  '';

  skills =
    (lib.evalModules {
      modules = [
        {
          options.skills = lib.mkOption {
            type = lib.types.attrsOf (import ./skill-type.nix {inherit lib;});
          };
        }
        {config.skills = fixtures;}
      ];
    }).config.skills;

  tree = skillTree {
    inherit skills;
    excludes = ["unwanted"];
  };

  fixtures = {
    manual.skill = {
      frontmatter = {
        description = "A fixture skill.";
        disable-model-invocation = true;
        allowed-tools = ["Read"];
      };
      body = "# manual\n";
    };

    automatic.skill = {
      frontmatter.description = "A fixture skill.";
      body = "# automatic\n";
    };

    directory.directory = "${directorySkill}";

    bundle.directory = "${skillBundle}";
  };

  # The whole tree that `tree` should produce. A directory skill is linked
  # unchanged, with its own Codex policy. The skills in `bundle` keep their own
  # names, and `excludes` removes `unwanted`.
  expected = pkgs.linkFarm "skill-tree-expected" {
    "manual/SKILL.md" = pkgs.writeText "SKILL.md" ''
      ---
      allowed-tools: ["Read"]
      description: "A fixture skill."
      disable-model-invocation: true
      name: "manual"
      ---

      # manual
    '';

    "manual/agents/openai.yaml" = pkgs.writeText "openai.yaml" ''
      {"policy":{"allow_implicit_invocation":false}}
    '';

    "automatic/SKILL.md" = pkgs.writeText "SKILL.md" ''
      ---
      description: "A fixture skill."
      disable-model-invocation: false
      name: "automatic"
      ---

      # automatic
    '';

    "directory/SKILL.md" = "${directorySkill}/SKILL.md";

    "directory/agents/openai.yaml" = "${directorySkill}/agents/openai.yaml";

    "bundled/SKILL.md" = "${skillBundle}/bundled/SKILL.md";
  };
in {
  skill-tree-rendering = pkgs.runCommandLocal "skill-tree-rendering" {} ''
    diff --recursive --unified ${expected} ${tree}

    links=$(find ${tree}/*/ -type l)

    if [ -n "$links" ]; then
      echo "symlinks inside skill directories:" >&2
      echo "$links" >&2
      exit 1
    fi

    touch "$out"
  '';

  skill-tree-unmatched-exclusion = pkgs.testers.testBuildFailure' {
    drv = skillTree {
      inherit skills;
      excludes = ["missing"];
    };
    expectedBuilderLogEntries = ["skill exclusion missing matches no skill in the tree"];
  };
}
