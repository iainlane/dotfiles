{
  flake.profiles.development.os.linux.homeManagerModule = {pkgs, ...}: {
    home.packages = import ./linux-packages.nix pkgs;

    home.file.".gdbinit".text = ''
      set debuginfod enabled on
    '';
  };
}
