{
  description = "Disposable Cupboard publication validation";

  inputs.dotfiles.url = "github:iainlane/dotfiles/f3f125f64022b41d61f67435d30296ae8ba0f8d7";

  outputs = {dotfiles, ...}: let
    system = "x86_64-linux";
    pkgs = dotfiles.inputs.nixpkgs.legacyPackages.${system};
    successful = pkgs.runCommand "cupboard-publication-validation-success-on-20261009" {} ''
      echo "Cupboard publication validation: native success on 20261009"
      mkdir -p "$out"
      printf '%s\n' 'Cupboard publication validation on 20261009' > "$out/control-marker"
    '';
    failing = pkgs.runCommand "cupboard-publication-validation-failure" {} ''
      echo >&2 "Cupboard publication validation: controlled failure"
      exit 17
    '';

    packages =
      dotfiles.packages
      // {
        ${system} =
          (dotfiles.packages.${system} or {})
          // {
            cupboard-publication-validation-failure = failing;
            cupboard-publication-validation-success = successful;
          };
      };

    successfulTarget = {
      attr = ".#packages.${system}.cupboard-publication-validation-success";
      rootDrvPath = successful.drvPath;
      rootSuffix = "${system}/validation-native-success-on";
      inherit system;
      os = "ubuntu-latest";
      remote = false;
      bestEffort = false;
      cohort = "validation-native-success-on";
      outputs = ["out"];
    };

    failureTarget = {
      attr = ".#packages.${system}.cupboard-publication-validation-failure";
      rootDrvPath = failing.drvPath;
      rootSuffix = "${system}/validation-controlled-failure";
      inherit system;
      os = "ubuntu-latest";
      remote = true;
      bestEffort = true;
      cohort = "validation-controlled-failure";
      outputs = ["out"];
    };
  in {
    inherit (dotfiles) deploy nix;
    inherit packages;

    cupboardValidationOriginal = dotfiles.cupboardOutputs;
    cupboardOutputs = dotfiles.cupboardOutputs ++ [successfulTarget failureTarget];
  };
}
