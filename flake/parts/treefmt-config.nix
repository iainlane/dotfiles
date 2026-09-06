{pkgs}: let
  inherit (pkgs) lib;
in {
  programs = {
    actionlint.enable = true;
    alejandra.enable = true;
    deadnix.enable = true;
    # Markdown is linted by the custom `markdownlint` formatter below.
    mdformat.enable = false;
    nixf-diagnose = {
      enable = true;
      variableLookup = true;
    };
    shellcheck = {
      enable = true;
      severity = "style";
      external-sources = true;
      source-path = "SCRIPTDIR";
    };
    shfmt = {
      enable = true;
      useEditorConfig = true;
    };
    statix.enable = true;
    stylua.enable = true;
    prettier = {
      enable = true;
      settings.proseWrap = "always";
    };
    zizmor.enable = true;
  };

  projectRootFile = "flake.nix";

  settings = {
    excludes = ["**/lazy-lock.json"];

    formatter = {
      zizmor.options = ["--persona" "pedantic"];

      markdownlint = {
        command = lib.getExe pkgs.markdownlint-cli2;
        options = ["--fix" "--"];
        includes = ["*.md"];
      };

      # Strict Lua linting. Globals are limited to known Neovim/LazyVim runtime
      # symbols that are intentionally available at runtime.
      luacheck = {
        command = lib.getExe pkgs.luaPackages.luacheck;
        options = [
          "--globals"
          "vim"
          "LazyVim"
          "Snacks"
          "--no-max-line-length"
          "--"
        ];
        includes = ["*.lua"];
      };

      # shellcheck and shfmt do not read zsh, so the zsh files are checked for
      # syntax with the shell itself. `zsh -n` takes one script per call.
      zsh-syntax = {
        command = lib.getExe (pkgs.writeShellScriptBin "zsh-syntax" ''
          for file; do
            ${lib.getExe pkgs.zsh} -n "$file"
          done
        '');
        includes = [
          "features/base/zsh/*.zsh"
          "features/base/zsh/functions/*"
          "features/base/zsh/plugins/*.zsh"
        ];
      };
    };
  };
}
