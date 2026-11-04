# Orders the repository's updaters by the derivation graph. `flake/updaters`
# passes it the nodes for one system.
{
  nix,
  pyright,
  python3,
  ruff,
  runCommandLocal,
  writeShellApplication,
}:
writeShellApplication {
  name = "update-plan";
  runtimeInputs = [nix python3];
  text = ''
    exec python3 ${./update_plan.py} "$@"
  '';

  passthru = {
    updateScript = null;
    tests.unit =
      runCommandLocal "update-plan-test" {
        nativeBuildInputs = [pyright python3 ruff];
        passthru.ci.runOnce = true;
      } ''
        cp ${./update_plan.py} update_plan.py
        cp ${./test_update_plan.py} test_update_plan.py
        ruff check update_plan.py test_update_plan.py
        ruff format --check update_plan.py test_update_plan.py
        pyright --project .
        python3 -m unittest -v
        touch "$out"
      '';
  };

  meta = {
    description = "Order the repository's updaters by the derivation graph";
    mainProgram = "update-plan";
  };
}
