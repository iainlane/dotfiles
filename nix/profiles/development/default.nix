# Development profile - tools for software development workflows.
#
# Covers infrastructure (Terraform, Kubernetes), containers (Docker tooling,
# security scanners), CI/CD (GitHub Actions linting), and code analysis.
# Also includes mise for managing language runtimes (Node, Python, etc.).
#
# This is general dev tooling; language-specific tools go in project shells.
{
  flake.homeManagerModules.development = {pkgs, ...}: {
    home.packages = with pkgs; [
      terraform

      kubectl
      kubernetes-helm
      jq
      yq-go

      cosign
      crane
      dive
      go-containerregistry
      grype
      oras
      syft

      act
      actionlint
      codeowners
      shellcheck

      stylua
      tokei
      twiggy

      tldr

      zizmor
    ];

    programs.mise = {
      enable = true;
      enableZshIntegration = true;

      globalConfig = {
        settings = {
          experimental = true;

          idiomatic_version_file_enable_tools = ["node" "python"];

          not_found_auto_install = true;
        };
      };
    };
  };
}
