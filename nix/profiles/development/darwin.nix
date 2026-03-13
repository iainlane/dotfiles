{
  flake.profiles.development.os.darwin.homeManagerModule = {pkgs, ...}: {
    dotfiles.ssh.includes = ["~/.orbstack/ssh/config"];

    home.packages = with pkgs; [
      docker
    ];
  };

  flake.profiles.development.os.darwin.systemManagerModule = {
    homebrew.casks = [
      "orbstack"
    ];
  };
}
