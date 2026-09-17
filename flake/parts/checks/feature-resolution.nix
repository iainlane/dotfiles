# Checks feature resolution against fixtures, and the class-module merge
# against the option type that this flake declares.
#
# The fixtures are attribute sets shaped like evaluated `flake.features`
# entries, children included: a child is a feature value whose name is
# qualified by its parent's. Each assertion compares the complete module list
# returned by the resolver, including its order. Which definition of an option wins after
# resolution is decided by the module system and is not tested here.
#
# The merge assertion evaluates two fixture files against the real type of
# `flake.features`, so it covers the declaration in
# `flake/parts/features.nix` without depending on how any feature happens to
# be split across files today.
#
# Each assertion is a `{ name; pass; }` attribute set so the check can report
# all failures together.
{
  inputs,
  lib,
  featureResolver,
  ...
}: let
  mkFeature = name: attrs:
    {
      inherit name;
      includes = [];
      nixos = null;
      darwin = null;
      systemManager = null;
      homeManager = null;
      system = null;
      os = {};
      kernel = {};
      provides = {};
    }
    // attrs;

  # The resolver reads the kernel from the host's system string, so each OS
  # in the fixtures gets the system of its hosts.
  systemFor = {
    nixos = "x86_64-linux";
    "generic-linux" = "x86_64-linux";
    darwin = "aarch64-darwin";
  };

  resolveExcluding = excludes: class: os: features:
    featureResolver.resolveFeatures {
      inherit class;
      hostConfig = {
        name = "fixture";
        inherit os features excludes;
        system = systemFor.${os};
      };
    };

  resolve = resolveExcluding [];

  throws = expr: !(builtins.tryEval (builtins.deepSeq expr true)).success;

  git = mkFeature "git" {
    homeManager = "git-home";
    os."generic-linux".homeManager = "git-linux";
  };
  gh = mkFeature "gh" {
    includes = [git];
    homeManager = "gh-home";
  };
  borgmatic = mkFeature "borgmatic" {nixos = "borgmatic-nixos";};
  base = mkFeature "base" {
    includes = [gh git];
    nixos = "base-nixos";
    systemManager = "base-system-manager";
    system = "base-system";
    homeManager = "base-home";
    os.nixos.includes = [borgmatic];
  };

  # A feature and its children. `shell` includes `zsh` everywhere and `openssh`
  # on NixOS; `fzf` is a child that nothing includes by default.
  zsh = mkFeature "shell.zsh" {homeManager = "shell-zsh-home";};
  openssh = mkFeature "shell.openssh" {nixos = "shell-openssh-nixos";};
  fzf = mkFeature "shell.fzf" {homeManager = "shell-fzf-home";};
  shell = mkFeature "shell" {
    includes = [zsh];
    homeManager = "shell-home";
    os.nixos.includes = [openssh];
  };

  # A feature whose child includes a feature of its own, so excluding the
  # child has to leave `direnv` out as well.
  direnv = mkFeature "editor.direnv" {homeManager = "editor-direnv-home";};
  prompt = mkFeature "editor.prompt" {
    includes = [direnv];
    homeManager = "editor-prompt-home";
  };
  editor = mkFeature "editor" {
    includes = [prompt];
    homeManager = "editor-home";
  };

  terminal = mkFeature "terminal" {
    homeManager = "terminal-home";
    kernel = {
      linux.homeManager = "terminal-linux";
      darwin.homeManager = "terminal-darwin";
    };
  };

  # Two files defining one class of one feature, evaluated against the real
  # declaration in `flake/parts/features.nix`, so the merge and the file
  # tagging are the ones that the flake uses.
  mergedClassFiles = let
    evaluated = lib.evalModules {
      specialArgs = {inherit inputs;};
      modules = [
        ../features.nix
        {
          options.flake.operatingSystems = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = ["nixos" "generic-linux" "darwin"];
          };
        }
        {
          _file = "first.nix";
          flake.features.demo.homeManager = {home.first = true;};
        }
        {
          _file = "second.nix";
          flake.features.demo.homeManager = {home.second = true;};
        }
      ];
    };
  in
    map (module: module._file) evaluated.config.flake.features.demo.homeManager.imports;

  assertions = [
    {
      name = "a feature's includes come before it, and a feature reached twice appears once";
      pass = resolve "homeManager" "darwin" [base] == ["git-home" "gh-home" "base-home"];
    }
    {
      name = "an OS-scoped Home Manager module applies only on that OS";
      pass =
        resolve "homeManager" "generic-linux" [git]
        == ["git-home" "git-linux"]
        && resolve "homeManager" "darwin" [git] == ["git-home"];
    }
    {
      name = "OS-scoped includes are followed only on that OS";
      pass =
        resolve "nixos" "nixos" [base]
        == ["borgmatic-nixos" "base-nixos" "base-system"]
        && resolve "nixos" "generic-linux" [base] == ["base-nixos"];
    }
    {
      name = "the `system` module goes to the class that builds the host";
      pass =
        resolve "systemManager" "generic-linux" [base]
        == ["base-system-manager" "base-system"]
        && resolve "systemManager" "nixos" [base] == ["base-system-manager"];
    }
    {
      name = "feature names follow composition order";
      pass =
        featureResolver.featureNames {
          features = [base];
          os = "nixos";
        }
        == ["git" "gh" "borgmatic" "base"];
    }
    {
      name = "an include cycle is rejected";
      pass = let
        alpha = mkFeature "alpha" {includes = [beta];};
        beta = mkFeature "beta" {includes = [alpha];};
      in
        throws (resolve "nixos" "nixos" [alpha]);
    }
    {
      name = "a child its parent includes is resolved before the parent";
      pass = resolve "homeManager" "darwin" [shell] == ["shell-zsh-home" "shell-home"];
    }
    {
      name = "a child under os.<os>.includes is resolved only on that OS";
      pass =
        resolve "nixos" "nixos" [shell]
        == ["shell-openssh-nixos"]
        && resolve "nixos" "darwin" [shell] == [];
    }
    {
      name = "a child its parent does not include is resolved when something else lists it";
      pass =
        resolve "homeManager" "darwin" [fzf shell]
        == ["shell-fzf-home" "shell-zsh-home" "shell-home"];
    }
    {
      name = "children are named by their parent and appear in featureNames";
      pass =
        featureResolver.featureNames {
          features = [shell];
          os = "nixos";
        }
        == ["shell.zsh" "shell.openssh" "shell"];
    }
    {
      name = "a kernel-scoped Home Manager module follows the host's kernel, not its OS";
      pass =
        resolve "homeManager" "nixos" [terminal]
        == ["terminal-home" "terminal-linux"]
        && resolve "homeManager" "generic-linux" [terminal] == ["terminal-home" "terminal-linux"]
        && resolve "homeManager" "darwin" [terminal] == ["terminal-home" "terminal-darwin"];
    }
    {
      name = "hasFeature is true for a listed or included feature and false for an absent one";
      pass = let
        hostConfig = {
          featureNames = featureResolver.featureNames {
            features = [base];
            os = "darwin";
          };
        };
      in
        featureResolver.hasFeature hostConfig base
        && featureResolver.hasFeature hostConfig git
        && !(featureResolver.hasFeature hostConfig borgmatic);
    }
    {
      name = "an excluded child is dropped and its parent still resolves";
      pass = resolveExcluding [zsh] "homeManager" "darwin" [shell] == ["shell-home"];
    }
    {
      name = "an excluded feature's own includes are not followed";
      pass = resolveExcluding [prompt] "homeManager" "darwin" [editor] == ["editor-home"];
    }
    {
      name = "an excluded top-level feature is dropped wherever it is reached";
      pass = resolveExcluding [git] "homeManager" "darwin" [base] == ["gh-home" "base-home"];
    }
    {
      name = "a feature both listed and excluded is refused";
      pass = throws (resolveExcluding [base] "homeManager" "darwin" [base]);
    }
    {
      name = "an exclude the closure never reaches is refused";
      pass = throws (resolveExcluding [borgmatic] "homeManager" "darwin" [shell]);
    }
    {
      name = "hasFeature is false for an excluded feature and for an include only it reached";
      pass = let
        hostConfig = {
          featureNames = featureResolver.featureNames {
            features = [editor];
            os = "darwin";
            excludes = [prompt];
          };
        };
      in
        featureResolver.hasFeature hostConfig editor
        && !(featureResolver.hasFeature hostConfig prompt)
        && !(featureResolver.hasFeature hostConfig direnv);
    }
    {
      name = "a class defined in several files merges every file's modules, each tagged with its file";
      pass =
        mergedClassFiles
        == [
          "first.nix, via option flake.features.demo.homeManager"
          "second.nix, via option flake.features.demo.homeManager"
        ];
    }
  ];

  failures = lib.filter (assertion: !assertion.pass) assertions;
  report = lib.concatMapStringsSep "\n" (assertion: "  ✗ ${assertion.name}") failures;
in {
  perSystem = {pkgs, ...}: {
    # A failed assertion builds a derivation that prints the report and exits
    # non-zero. Throwing during evaluation would take down every other check in
    # the same `nix flake check` run.
    checks.feature-resolution =
      pkgs.runCommandLocal "feature-resolution" {inherit report;}
      (
        if failures == []
        then "touch $out"
        else ''
          echo "feature resolution checks failed:" >&2
          printf '%s\n' "$report" >&2
          exit 1
        ''
      );
  };
}
