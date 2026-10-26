# Summarises flake input changes for the automated flake-update pull request.
{
  bash,
  jq,
  runCommandLocal,
  writeShellApplication,
}:
writeShellApplication {
  name = "flake-lock-summary";
  runtimeInputs = [jq];
  text = builtins.readFile ./flake-lock-summary.bash;

  passthru = {
    updateScript = null;
    tests.follows =
      runCommandLocal "flake-lock-summary-follows" {
        nativeBuildInputs = [bash jq];
      } ''
        bash ${./test.bash} ${./flake-lock-summary.bash}
        touch "$out"
      '';
  };

  meta = {
    description = "Summarise the input changes between two flake.lock files";
    mainProgram = "flake-lock-summary";
  };
}
