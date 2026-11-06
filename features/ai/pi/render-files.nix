{
  inputs,
  pkgs,
}: files: let
  homeManager =
    if pkgs.lib.trivial.release == inputs.nixpkgs-stable.lib.trivial.release
    then inputs.home-manager-stable
    else inputs.home-manager;
  rendered = homeManager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      {
        home = {
          username = "pi-assets";
          homeDirectory = "/var/empty/pi-assets";
          stateVersion = "26.05";
          file = pkgs.lib.mkForce (files.home.file // pkgs.lib.mapAttrs' (path: file: pkgs.lib.nameValuePair ".config/${path}" file) files.xdg.configFile);
        };
      }
    ];
  };
in
  rendered.config.home-files
