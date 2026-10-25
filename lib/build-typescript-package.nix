{
  autoPatchelfHook,
  buildNpmPackage,
  importNpmLock,
  lib,
  stdenv,
}: {directory, ...} @ args: let
  root = ../.;
  relative = lib.path.removePrefix root directory;
in
  buildNpmPackage (removeAttrs args ["directory"]
    // {
      src = lib.fileset.toSource {
        inherit root;
        fileset = lib.fileset.unions [directory ../.oxlintrc.json ../.oxfmtrc.json];
      };
      sourceRoot = "source/${relative}";
      npmDeps = importNpmLock {npmRoot = directory;};
      inherit (importNpmLock) npmConfigHook;
      nativeBuildInputs = (args.nativeBuildInputs or []) ++ lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
      buildInputs = (args.buildInputs or []) ++ lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];
      preCheck =
        lib.optionalString stdenv.hostPlatform.isLinux ''
          autoPatchelf node_modules/@oxlint-tsgolint/linux-${stdenv.hostPlatform.node.arch}/tsgolint
        ''
        + (args.preCheck or "");
    })
