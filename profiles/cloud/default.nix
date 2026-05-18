{
  flake.profiles.cloud.homeManagerModule = {pkgs, ...}: {
    home.packages = with pkgs; [
      (google-cloud-sdk.withExtraComponents [
        google-cloud-sdk.components.gke-gcloud-auth-plugin
      ])
      azure-cli
      awscli2

      kubectl
    ];
  };
}
