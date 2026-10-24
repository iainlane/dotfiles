{
  hostConfig,
  homeConfig,
}: {
  pkgs,
  lib,
  ...
}: let
  common = import ../../common.nix {inherit lib;};
in {
  "host-evaluation-local-embeddings-${hostConfig.name}" =
    pkgs.runCommandLocal "local-embeddings" {
      preflight = homeConfig.systemd.user.services.agentsview-embed.Service.ExecStartPre;
      agentsviewConfig = homeConfig.sops.templates."agentsview-config.toml".content;
      embeddingModel = common.embeddings.defaultModel.name;
      embeddingDimension = toString common.embeddings.defaultModel.dimension;
      nativeBuildInputs = [pkgs.python3];
    } ''
      python3 <<'PY'
      import json
      import os
      import shlex
      import subprocess
      import sys
      import tomllib
      from http.server import BaseHTTPRequestHandler, HTTPServer
      from threading import Thread

      servers = tomllib.loads(os.environ["agentsviewConfig"])["vector"]["embeddings"]["servers"]
      expected_servers = {
          "local": {
              "endpoint": "http://localhost:11434/v1",
              "timeout": "120s",
              "batch_size": 8,
              "concurrency": 1,
          },
      }
      assert servers == expected_servers, servers

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

      server = HTTPServer(("127.0.0.1", 0), Ollama)
      endpoint = f"http://127.0.0.1:{server.server_port}"
      command = shlex.split(os.environ["preflight"])
      command[0] = sys.executable
      command[command.index("--endpoint") + 1] = endpoint
      worker = Thread(target=server.serve_forever, daemon=True)
      worker.start()
      try:
          for size_vram, status in ((1024, 0), (0, 1)):
              requests.clear()
              result = subprocess.run(
                  command, capture_output=True, text=True, timeout=10,
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
}
