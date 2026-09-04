{pkgs, ...}: {
  home.packages = [
    (pkgs.writeShellApplication {
      name = "nix-store-info";
      runtimeInputs = with pkgs; [coreutils findutils gawk gnugrep gnused nix];
      text = builtins.readFile ./nix-store-info.bash;
    })
    (pkgs.writeShellApplication {
      name = "is-dark-mode";
      runtimeInputs = [pkgs.dbus];
      text = builtins.readFile ./is-dark-mode.bash;
    })
  ];
}
