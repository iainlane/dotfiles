{
  pkgs,
  lib,
  ...
}: {
  ollama-model-loader = let
    fakeOllama = pkgs.writeShellScriptBin "ollama" ''
      printf '%s %s\n' "$OLLAMA_HOST" "$*" >> "$OLLAMA_TEST_LOG"

      if [ "$1" = list ] && [ ! -e "$OLLAMA_TEST_READY" ]; then
        touch "$OLLAMA_TEST_READY"
        exit 1
      fi

      if [ "$OLLAMA_TEST_MODE" = fail ] && [ "$1" = pull ]; then
        exit 17
      fi
    '';

    fixture = import ./home-manager-linux.nix {
      inherit lib pkgs;
      pkgs-unstable = pkgs;
      hostConfig.os = "nixos";
      config = {
        services.ollama = {
          enable = false;
          package = fakeOllama;
          host = "127.0.0.1";
          port = 11434;
        };
        dotfiles.inference.ollama.models = [
          {
            name = "bge-m3";
            aliases = ["baai/bge-m3"];
          }
          {
            name = "another-model";
            aliases = [];
          }
        ];
      };
    };

    loader = fixture.systemd.user.services.ollama-model-loader.content.Service.ExecStart;
  in
    pkgs.runCommandLocal "ollama-model-loader-test" {
      nativeBuildInputs = [pkgs.diffutils];
    } ''
      export OLLAMA_TEST_LOG="$PWD/calls"
      export OLLAMA_TEST_READY="$PWD/ready"
      export OLLAMA_TEST_MODE=success

      ${loader}

      cat > expected <<'EOF'
      127.0.0.1:11434 list
      127.0.0.1:11434 list
      127.0.0.1:11434 pull bge-m3
      127.0.0.1:11434 cp bge-m3 baai/bge-m3
      127.0.0.1:11434 pull another-model
      EOF
      diff -u expected "$OLLAMA_TEST_LOG"

      export OLLAMA_TEST_MODE=fail
      : > "$OLLAMA_TEST_LOG"
      status=0
      ${loader} || status=$?
      test "$status" = 17

      cat > expected <<'EOF'
      127.0.0.1:11434 list
      127.0.0.1:11434 pull bge-m3
      EOF
      diff -u expected "$OLLAMA_TEST_LOG"

      touch $out
    '';
}
