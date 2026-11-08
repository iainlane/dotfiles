{
  bash,
  bun,
  nodejs_24,
  python314,
  bun2nix,
  callPackage,
  lib,
  makeWrapper,
}:
bun2nix.mkDerivation {
  pname = "librechat-code";
  version = "1.10.13";
  src = callPackage ./source.nix {};
  sourceRoot = "source/service";
  patches = [./loopback-services.patch];

  postPatch = ''
    substituteInPlace src/config.ts src/preamble.ts \
      --replace-fail "version: '5.2.0'" "version: '${builtins.replaceStrings ["p"] ["."] bash.version}'" \
      --replace-fail "version: '3.14.4'" "version: '${python314.version}'"
    substituteInPlace src/config.ts \
      --replace-fail "version: '24.22.1'" "version: '${nodejs_24.version}'"

    substituteInPlace src/payload.ts \
      --replace-fail "path.join(__dirname, 'matplotlib.py')" "'${placeholder "out"}/lib/librechat-code/templates/matplotlib.py'"
    substituteInPlace src/preamble.ts \
      --replace-fail "path.join(__dirname, 'matplotlib-async.py')" "'${placeholder "out"}/lib/librechat-code/templates/matplotlib-async.py'"
  '';

  bunDeps = bun2nix.fetchBunDeps {bunNix = ./service-bun.nix;};
  nativeBuildInputs = [bun makeWrapper];
  dontStrip = true;

  buildPhase = ''
    runHook preBuild

    for entry in service-api worker-server file-server tool-call-server egress-gateway; do
      bun build "src/$entry.ts" --outdir .build --target bun --packages external
    done

    cp ${./bridge-entry.mts} bridge-entry.mts
    cp ${./bridge-tsconfig.json} bridge-tsconfig.json
    bun build bridge-entry.mts --outfile .build/bridge/bridge-worker.mjs --target node --format esm
    ${lib.getExe nodejs_24} node_modules/typescript/bin/tsc -p bridge-tsconfig.json

    cp -R .build/bridge-types .build/bridge/types
    cp ../packages/code/package.json .build/bridge/types/packages/code/package.json
    cp package.json .build/bridge/types/service/package.json

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/librechat-code/templates" "$out/bin"
    cp -r .build node_modules "$out/lib/librechat-code/"
    cp src/matplotlib.py src/matplotlib-async.py "$out/lib/librechat-code/templates/"
    for entry in service-api worker-server file-server tool-call-server egress-gateway; do
      makeWrapper ${lib.getExe bun} "$out/bin/librechat-code-$entry" \
        --add-flags "$out/lib/librechat-code/.build/$entry.js"
    done

    runHook postInstall
  '';

  passthru = {
    updateScript = null;
    runtimes = {
      inherit bash bun nodejs_24;
      python314 = python314.withPackages (packages: with packages; [matplotlib numpy pandas pillow requests]);
    };
    runner = callPackage ./runner.nix {inherit bun bun2nix;};
  };

  meta = {
    description = "LibreChat CodeAPI services and worker extension";
    homepage = "https://github.com/LibreChat-AI/code-interpreter";
    license = lib.licenses.asl20;
    platforms = lib.platforms.unix;
  };
}
