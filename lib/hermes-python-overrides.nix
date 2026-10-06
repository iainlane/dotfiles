{
  fetchpatch,
  lib,
  stdenv,
}: _: prev: {
  anyio =
    if prev.anyio.version != "4.14.2"
    then prev.anyio
    else
      prev.anyio.overridePythonAttrs (old: {
        patches =
          (old.patches or [])
          ++ [
            (fetchpatch {
              url = "https://github.com/agronholm/anyio/commit/818e4ac441fa27e9fac893496fc5a4fbe0a58689.patch";
              hunks = [2];
              hash = "sha256-/WnPB376mOZm1Er5H0k4s0T1jEVvl8ohHRXt2VEjh9w=";
            })
          ];
      });
  psutil =
    if
      prev.psutil.version
      == "7.2.2"
      && stdenv.hostPlatform.isLinux
      && stdenv.hostPlatform.isAarch64
      && lib.versionOlder prev.python.version "3.13"
      && !(lib.elem "test_heap_info" (prev.psutil.disabledTests or []))
    then
      prev.psutil.overridePythonAttrs (old: {
        disabledTests = (old.disabledTests or []) ++ ["test_heap_info"];
      })
    else prev.psutil;
}
