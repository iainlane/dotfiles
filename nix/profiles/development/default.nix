{
  flake.homeManagerModules.development = {pkgs, ...}: {
    home.packages = with pkgs; [
      terraform

      kubectl
      kubernetes-helm
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
      golangci-lint

      cargo-generate
      stylua
      tokei
      twiggy

      tldr

      zizmor
    ];
  };
}
