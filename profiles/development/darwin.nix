{
  flake.features.development.os.darwin.homeManager = {pkgs, ...}: {
    dotfiles.ssh.includes = ["~/.orbstack/ssh/config"];

    home.packages = with pkgs; [
      docker
    ];
  };

  flake.features.development.darwin = {
    homebrew.casks = [
      "orbstack"
    ];
  };
}
