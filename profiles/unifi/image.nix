{
  pkgs,
  src,
  version ? "5.0.6",
}:
pkgs.stdenvNoCC.mkDerivation {
  pname = "unifi-os-server-image";
  inherit version src;

  nativeBuildInputs = with pkgs; [
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

  meta = with pkgs.lib; {
    description = "Extracted OCI image archive from the UniFi OS Server installer";
    homepage = "https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi";
    license = licenses.unfreeRedistributableFirmware;
    platforms = platforms.linux;
    sourceProvenance = with sourceTypes; [binaryNativeCode];
  };
}
