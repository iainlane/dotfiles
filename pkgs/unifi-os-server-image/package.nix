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

      # The updater reads the image tag from the arm64 installer alone, and the
      # quadlet uses the tag in sources.json on both platforms. Require this
      # installer to contain the same tag: otherwise the quadlet would refer to
      # an image that does not exist, and podman would report it only when the
      # container started.
      extracted_tag="$(cat extracted/image-tag)"
      if [ "$extracted_tag" != "${sources.imageTag}" ]; then
        echo "installer image is tagged $extracted_tag, sources.json says ${sources.imageTag}" >&2
        exit 1
      fi

      mkdir -p "$out"
      cp extracted/image.tar "$out/image.tar"
      cp extracted/image-tag "$out/image-tag"

      runHook postInstall
    '';

    passthru = {
      # The tag of the image in the archive. The quadlet that loads the archive
      # names the image by this tag. Both the tag and the installer URLs come
      # from `sources.json`, so the quadlet selects the image unpacked from
      # those installers.
      inherit (sources) imageTag;

      # The platform name UniFi OS expects of itself, taken from the same entry
      # that selects the installer.
      inherit (platform) firmwarePlatform;

      updateScript = updaters.mkScriptUpdater {
        pname = "unifi-os-server-image";
        script = ./update.sh;
        extraRuntimeInputs = [binwalk curl gnutar unzip];
      };
    };

    meta = {
      description = "Extracted OCI image archive from the UniFi OS Server installer";
      homepage = "https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi";
      license = lib.licenses.unfreeRedistributableFirmware;
      platforms = lib.platforms.linux;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
