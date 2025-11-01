_: {
  flake.homeManagerModules.cloud = {pkgs, ...}: {
    home.packages = with pkgs; [
      google-cloud-sdk
      azure-cli
      awscli2
    ];
  };
}
