{
  git,
  nix,
  python3,
  pyright,
  ruff,
  runCommandLocal,
  writeShellApplication,
  stdenv,
  lib,
}:
writeShellApplication {
  name = "update-runner";
  runtimeInputs = [git nix python3];
  text = ''exec python3 ${./update_runner.py} --system ${lib.escapeShellArg stdenv.hostPlatform.system} "$@"'';
  passthru = {
    updateScript = null;
    maintenance.source = "repository";
    tests.unit =
      runCommandLocal "update-runner-test" {
        nativeBuildInputs = [git python3 pyright ruff];
        passthru.ci.runOnce = true;
      } ''
        cp ${./update_runner.py} update_runner.py
        cp ${./test_update_runner.py} test_update_runner.py
        ruff check .
        ruff format --check .
        pyright --project .
        python3 -m unittest -v
        touch "$out"
      '';
  };
}
