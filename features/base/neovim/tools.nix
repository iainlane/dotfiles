{pkgs}: {
  inherit
    (pkgs)
    alejandra
    ansible-lint
    bacon
    biome
    deadnix
    delve
    gofumpt
    golangci-lint
    hadolint
    markdown-toc
    markdownlint-cli2
    prettier
    regal
    shellcheck
    shfmt
    statix
    stylua
    tflint
    ;

  inherit (pkgs.rubyPackages) htmlbeautifier;

  codelldb = pkgs.vscode-extensions.vadimcn.vscode-lldb;
  goimports = pkgs.gotools;
  js-debug-adapter = pkgs.vscode-js-debug;
}
