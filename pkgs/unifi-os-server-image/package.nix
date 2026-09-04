# Ubiquiti publish UniFi OS Server as a firmware installer rather than a
# container image, so the OCI archive is unpacked out of the installer at
# build time.
{
  lib,
  stdenvNoCC,
  fetchurl,
  binwalk,
  gnutar,
  jq,
  unzip,
  curl,
  updaters,
}: let
  sources = lib.importJSON ./sources.json;
  inherit (stdenvNoCC.hostPlatform) system;
  platform =
    sources.platforms.${system}
    or (throw "unifi-os-server-image: unsupported system ${system}");
in
  stdenvNoCC.mkDerivation {
    pname = "unifi-os-server-image";
    inherit (sources) version;

    src = fetchurl {inherit (platform) url hash;};

    nativeBuildInputs = [
      binwalk
      gnutar
      jq
      unzip
    ];

    dontUnpack = true;

    buildPhase = ''
      runHook preBuild

      bash ${./extract-image.sh} "$src" extracted

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      cp extracted/image.tar "$out/image.tar"
      cp extracted/image-tag "$out/image-tag"

      runHook postInstall
    '';

    passthru = {
      # The tag the archive carries. The quadlet that loads the archive names
      # the image by it, so it is read from the same file the installer URLs
      # come from.
      inherit (sources) imageTag;

      updateScript = updaters.mkScriptUpdater {
        pname = "unifi-os-server-image";
        script = ./update.sh;
        extraRuntimeInputs = [binwalk curl gnutar unzip];
      };
    };

    meta = with lib; {
      description = "Extracted OCI image archive from the UniFi OS Server installer";
      homepage = "https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi";
      license = licenses.unfreeRedistributableFirmware;
      platforms = platforms.linux;
      sourceProvenance = with sourceTypes; [binaryNativeCode];
    };
  }
