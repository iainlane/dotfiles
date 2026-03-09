{
  flake.profiles.base.os.nixos.homeManagerModule = {
    lib,
    ...
  }: {
    home.sessionPath = lib.mkForce [];
    targets.genericLinux.enable = false;
  };
}
