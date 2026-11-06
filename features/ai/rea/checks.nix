{
  features,
  featureResolver,
}: {pkgs, ...}: let
  rea = import ./runtime.nix {inherit pkgs;};
  nativeFixture = pkgs.runCommandCC "rea-native-fixture" {} ''
    mkdir -p "$out/bin"
    $CC -O0 -g ${./native-fixture.c} -o "$out/bin/rea-native-fixture"
  '';
  entrypoints = pkgs.symlinkJoin {
    name = "rea-entrypoint-fixture";
    paths = map (command:
      pkgs.writeShellScriptBin command ''
        printf '%s\n' ${pkgs.lib.escapeShellArg command} "$@"
      '') ["rea" "rea-agents"];
    meta = pkgs.rea.meta;
  };
  wrappedEntrypoints = import ./runtime.nix {
    pkgs = pkgs // {rea = entrypoints;};
  };
in {
  imports = [(import ./registration-check.nix {inherit features featureResolver;})];

  rea-entrypoints = pkgs.runCommand "rea-entrypoints" {} ''
    for command in rea rea-agents; do
      printf '%s\n' "$command" 'argument with spaces' --flag > expected
      ${wrappedEntrypoints}/bin/"$command" 'argument with spaces' --flag > actual
      diff -u expected actual
    done
    touch "$out"
  '';

  rea-toolchain =
    pkgs.runCommand "rea-toolchain" {
      nativeBuildInputs = [pkgs.python3 pkgs.pyright];
    } ''
      pyright --pythonversion ${pkgs.python3.pythonVersion} ${./semantic.test.py}
      python3 ${./semantic.test.py} ${rea}/bin/rea \
        ${rea.environment.REA_BROWSER_EXECUTABLE} ${pkgs.hello}/bin/hello \
        ${pkgs.lib.escapeShellArg pkgs.wakaru.version} \
        ${nativeFixture}/bin/rea-native-fixture \
        ${pkgs.lib.escapeShellArg (builtins.toJSON [
        {
          id = "ghidra";
          name = "Ghidra";
          version = pkgs.ghidra.version;
        }
        {
          id = "kuna";
          name = "Kuna";
          version = pkgs.kuna.version;
        }
      ])}
      touch "$out"
    '';
}
