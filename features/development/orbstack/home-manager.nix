{pkgs, ...}: {
  programs.ssh.includes = ["~/.orbstack/ssh/config"];

  home.packages = with pkgs; [
    docker
  ];
}
