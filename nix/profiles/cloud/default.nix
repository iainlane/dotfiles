{
  flake.profiles.cloud.homeManagerModule = {pkgs, ...}: {
    home.packages = with pkgs; [
      google-cloud-sdk
      azure-cli
      awscli2
    ];
  };
}
