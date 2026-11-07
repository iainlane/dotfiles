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
}
