{
  lib,
  pkgs,
  ...
}: {
  programs.zed-editor = {
    enable = true;

    extensions = [
      # Theme
      "catppuccin"

      # Languages
      "astro"
      "dockerfile"
      "hcl"
      "html"
      "lua"
      "make"
      "nix"
      "svelte"
      "toml"
      "xml"

      # Tools
      "editorconfig"
      "env"
      "git-firefly"
      "ruff"
    ];

    userSettings = {
      agent.dock = "right";

      auto_update = false;
      base_keymap = "VSCode";

      buffer_font_family = "MonaspiceNe Nerd Font Mono";
      buffer_font_fallbacks = ["FiraCode Nerd Font"];
      buffer_font_features = {
        calt = true;
        dlig = true;
        liga = true;
        ss01 = true;
        ss02 = true;
        ss03 = true;
        ss04 = true;
        ss05 = true;
        ss06 = true;
        ss07 = true;
        ss08 = true;
        ss09 = true;
      };
      buffer_font_size = 14;

      colorize_brackets = true;

      cursor_blink = true;
      cursor_shape = "block";

      edit_predictions.provider = "copilot";

      ensure_final_newline_on_save = true;
      format_on_save = "on";

      git.inline_blame.enabled = true;

      hard_tabs = false;

      indent_guides = {
        coloring = "indent_aware";
        enabled = true;
      };

      inlay_hints = {
        enabled = true;
        show_parameter_hints = false;
        show_type_hints = false;
      };

      languages = {
        Make.hard_tabs = true;
        Nix = {
          formatter.external = {
            arguments = ["--quiet" "--"];
            command = lib.getExe pkgs.alejandra;
          };
          language_servers = ["nixd"];
        };
        TypeScript.code_actions_on_format."source.fixAll.eslint" = true;
        YAML.tab_size = 2;
      };

      lsp = {
        nixd.binary.path = lib.getExe pkgs.nixd;
        rust-analyzer.initialization_options = {
          check.command = "clippy";
          diagnostics.styleLints.enable = true;
        };
      };

      minimap.show = "auto";

      preferred_line_length = 100;

      project_panel.dock = "left";

      remove_trailing_whitespace_on_save = true;

      show_whitespaces = "trailing";
      show_wrap_guides = true;

      tab_size = 2;

      tabs = {
        close_position = "right";
        file_icons = true;
        git_status = true;
      };

      telemetry = {
        diagnostics = false;
        metrics = false;
      };

      terminal = {
        blinking = "on";
        copy_on_select = false;
        cursor_shape = "block";
        font_family = "MonaspiceNe Nerd Font Mono";
        font_size = 13;
        toolbar.breadcrumbs = true;
      };

      theme = {
        dark = "Catppuccin Mocha";
        light = "Catppuccin Latte";
        mode = "system";
      };

      ui_font_family = "MonaspiceNe Nerd Font Mono";
      ui_font_size = 14;

      vim_mode = true;

      wrap_guides = [80 100];
    };
  };
}
