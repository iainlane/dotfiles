# Summarises flake input changes for the automated flake-update pull request.
{
  jq,
  writeShellApplication,
}:
writeShellApplication {
  name = "flake-lock-summary";
  runtimeInputs = [jq];
  text = builtins.readFile ./flake-lock-summary.bash;

  meta = {
    description = "Summarise the input changes between two flake.lock files";
    mainProgram = "flake-lock-summary";
  };
}
