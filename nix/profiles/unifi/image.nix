{
  pkgs,
  url,
  hash,
  version ? "5.0.6",
}:
pkgs.stdenvNoCC.mkDerivation {
  pname = "unifi-os-server-image";
  inherit version;

  src = pkgs.fetchurl {
    inherit url hash;
  };

  nativeBuildInputs = with pkgs; [
    binwalk
    unzip
  ];

  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    binwalk --extract --directory=extracted "$src" >/dev/null

    image_tar="$(find extracted -type f -name image.tar | head -n1)"
    if [ -z "$image_tar" ]; then
      echo "Could not find embedded image.tar in UniFi OS installer" >&2
      exit 1
    fi

    cp "$image_tar" image.tar

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp image.tar "$out/image.tar"

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Extracted OCI image archive from the UniFi OS Server installer";
    homepage = "https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi";
    license = licenses.unfreeRedistributableFirmware;
    platforms = platforms.linux;
    sourceProvenance = with sourceTypes; [binaryNativeCode];
  };
}
