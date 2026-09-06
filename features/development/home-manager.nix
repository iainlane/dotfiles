{pkgs, ...}: {
  home.packages = with pkgs; [
    terraform

    kubernetes-helm
    jq
    yq-go

    cosign
    crane
    dive
    docker-compose
    go-containerregistry
    grype
    oras
    podman
    podman-compose
    qemu
    syft

    act
    actionlint
    codeowners
    shellcheck

    stylua
    tokei
    twiggy

    tldr

    uv

    zizmor
  ];

  programs.mise = {
    enable = true;
    enableZshIntegration = true;

    globalConfig = {
      settings = {
        experimental = true;

        idiomatic_version_file_enable_tools = ["go" "node" "python"];

        not_found_auto_install = true;
      };
    };
  };
}
