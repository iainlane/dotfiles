{
  flake.profiles.development.os.linux.homeManagerModule = {pkgs, ...}: {
    home.packages = import ./linux-packages.nix pkgs;

    home.file.".gdbinit".text = ''
      set debuginfod enabled on
    '';

    # The nix-built python's loader searches neither the system library
    # directories nor the nix-ld path, so manylinux wheels with native
    # libraries (grpcio, for example) fail to load under it. uv's managed
    # interpreters resolve those libraries, so make uv always use its own.
    xdg.configFile."uv/uv.toml".source = (pkgs.formats.toml {}).generate "uv.toml" {
      python-preference = "only-managed";
    };
  };
}
