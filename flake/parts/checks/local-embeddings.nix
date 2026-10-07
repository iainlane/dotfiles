{
  config,
  featureResolver,
  lib,
  ...
}: let
  home = config.flake.homeConfigurations."${config.flake.username}@bonington".config;
  inherit (config.flake) features;
  common = import ../../../features/agentsview/common.nix {inherit lib features;};

  gateCases = [
    {
      features = [features.agentsview];
      enabled = false;
    }
    {
      features = [features.agentsview features.inference.provides.acceleration.provides.vulkan];
      enabled = true;
    }
    {
      features = [features.inference.provides.acceleration.provides.vulkan];
      enabled = false;
    }
    {
      features = [features.agentsview features.inference.provides.acceleration.provides.vulkan];
      excludes = [features.agentsview.provides.embeddings.provides.local];
      enabled = false;
    }
    {
      features = [features.agentsview features.agentsview.provides.embeddings.provides.local];
      enabled = true;
    }
    {
      features = [features.agentsview features.inference.provides.acceleration.provides.metal];
      os = "darwin";
      enabled = true;
    }
    {
      features = [features.agentsview features.inference.provides.acceleration.provides.metal];
      os = "darwin";
      excludes = [features.agentsview.provides.embeddings.provides.local];
      enabled = false;
    }
  ];

  gatePasses = lib.all (test: let
    names = featureResolver.featureNames {
      inherit (test) features;
      excludes = test.excludes or [];
      os = test.os or "nixos";
    };
  in
    lib.elem features.agentsview.provides.embeddings.provides.local.name names == test.enabled)
  gateCases;
in {
  perSystem = {pkgs, ...}: {
    checks = {
      local-embeddings =
        pkgs.runCommandLocal "local-embeddings" {
          preflight = home.systemd.user.services.agentsview-embed.Service.ExecStartPre;
          embeddingModel = common.embeddings.model;
          embeddingDimension = toString common.embeddings.dimension;
          nativeBuildInputs = [pkgs.python3];
        } ''
          if [ ${lib.boolToString gatePasses} != true ]; then
            printf 'Local embedding feature eligibility failed\n' >&2
            exit 1
          fi

          python3 <<'PY'
          import json
          import os
          import shlex
          import subprocess
          from http.server import BaseHTTPRequestHandler, HTTPServer
          from threading import Thread

          requests = []
          size_vram = 0
          model = os.environ["embeddingModel"]
          dimension = int(os.environ["embeddingDimension"])

          class Ollama(BaseHTTPRequestHandler):
              def reply(self, response):
                  body = json.dumps(response).encode()
                  self.send_response(200)
                  self.send_header("Content-Type", "application/json")
                  self.send_header("Content-Length", str(len(body)))
                  self.end_headers()
                  self.wfile.write(body)

              def do_POST(self):
                  payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                  requests.append((self.path, payload.get("model")))
                  self.reply({"data": [{"index": 0, "embedding": [1.0] * dimension}]})

              def do_GET(self):
                  requests.append((self.path, None))
                  self.reply({"models": [{"name": f"{model}:latest", "size_vram": size_vram}]})

              def log_message(self, *args):
                  pass

          server = HTTPServer(("127.0.0.1", 11434), Ollama)
          worker = Thread(target=server.serve_forever, daemon=True)
          worker.start()
          try:
              for size_vram, status in ((1024, 0), (0, 1)):
                  requests.clear()
                  result = subprocess.run(
                      shlex.split(os.environ["preflight"]), capture_output=True, text=True, timeout=10,
                  )
                  expected_requests = [
                      ("/v1/embeddings", model),
                      ("/api/ps", None),
                  ]
                  assert (result.returncode, requests) == (status, expected_requests), (
                      result.returncode, requests, result.stderr,
                  )
          finally:
              server.shutdown()
              worker.join()
              server.server_close()
          PY

          touch $out
        '';

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

        fixture = import ../../../features/inference/ollama/home-manager-linux.nix {
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

      ollama-embedding-probe =
        pkgs.runCommandLocal "ollama-embedding-probe" {
          nativeBuildInputs = [pkgs.python3 pkgs.ruff pkgs.pyright];
        } ''
          cp ${../../../features/agentsview/embeddings/local/check.py} check.py
          cp ${../../../features/agentsview/embeddings/local/test_check.py} test_check.py
          ruff check check.py test_check.py
          ruff format --check check.py test_check.py
          pyright --pythonversion ${pkgs.python3.pythonVersion} check.py test_check.py
          python3 -m unittest -v
          touch $out
        '';
    };
  };
}
