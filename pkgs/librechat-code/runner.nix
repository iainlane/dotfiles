{
  bun,
  bun2nix,
  callPackage,
  lib,
  makeWrapper,
  nodejs_24,
  nsjail,
  stdenv,
}:
bun2nix.mkDerivation {
  pname = "librechat-code-runner";
  version = "1.10.13";
  src = callPackage ./source.nix {};
  patches = [./conversation-network.patch];

  postPatch = ''
    cd api

    substituteInPlace src/nsjail.ts \
      --replace-fail "'--rlimit_stack', 'soft'" "'--rlimit_stack', '8'"
  '';

  bunDeps = bun2nix.fetchBunDeps {bunNix = ./runner-bun.nix;};
  nativeBuildInputs = [bun makeWrapper stdenv.cc];
  dontStrip = true;
  doInstallCheck = true;
  buildPhase = ''
    runHook preBuild

    bun build src/index.ts --outdir .build --target bun --packages external
    cc -O2 src/spec-guard.c -o .build/spec-guard
    cc -shared -fPIC -O2 -Wall -Wextra -Werror \
      -I${nodejs_24}/include/node src/anonymous-pipes.c \
      -o .build/anonymous-pipes.node

    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/librechat-code-runner" "$out/bin"
    cp -r .build node_modules "$out/lib/librechat-code-runner/"
    install -m755 .build/spec-guard "$out/bin/spec-guard"
    makeWrapper ${lib.getExe bun} "$out/bin/librechat-code-runner" \
      --add-flags "$out/lib/librechat-code-runner/.build/index.js" \
      --set SANDBOX_PIPE_ADDON "$out/lib/librechat-code-runner/.build/anonymous-pipes.node" \
      --set-default NSJAIL_PATH ${lib.getExe nsjail}

    runHook postInstall
  '';
  installCheckPhase = ''
    runHook preInstallCheck
    ${lib.getExe bun} -e '
      const fs = require("node:fs");
      const [reader, writer] = require("${placeholder "out"}/lib/librechat-code-runner/.build/anonymous-pipes.node").createPipe();

      fs.writeSync(writer, "ready");

      const buffer = Buffer.alloc(5);

      if (fs.readSync(reader, buffer) !== 5 || buffer.toString() !== "ready") {
        process.exit(1);
      }

      fs.closeSync(reader);
      fs.closeSync(writer);
    '
    runHook postInstallCheck
  '';
  meta = {
    description = "CodeAPI execution runner for a dedicated conversation VM";
    license = lib.licenses.asl20;
    mainProgram = "librechat-code-runner";
    platforms = lib.platforms.linux;
  };
}
