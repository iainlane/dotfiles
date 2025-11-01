# Cloud profile - CLI tools for major cloud providers.
#
# Includes AWS, Azure, and Google Cloud SDKs. Add this to hosts where you need
# to interact with cloud infrastructure.
_: {
  flake.homeManagerModules.cloud = {pkgs, ...}: {
    home.packages = with pkgs; [
      google-cloud-sdk
      azure-cli
      awscli2
    ];
  };
}
