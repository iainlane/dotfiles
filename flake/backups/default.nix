{lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks = lib.mkMerge [
      ((import ./checks/backup.nix {inherit lib;}) {inherit pkgs;})
      ((import ./checks/verify.nix {}) {inherit pkgs;})
    ];
  };
}
