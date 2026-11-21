{
  lib,
  nodejs_24,
  openssl,
  package,
  pi,
  pi-integration-tests,
  runCommandLocal,
  writeText,
}: let
  support = "${pi-integration-tests}/${pi-integration-tests.packageRoot}";
  settings = writeText "pi-openai-context-settings.json" (builtins.toJSON {
    defaultProjectTrust = "never";
    packages = ["${package}/${package.packageRoot}"];
  });
  auth = writeText "pi-openai-context-test-auth.json" (builtins.toJSON {
    openai = {
      type = "oauth";
      access = "fixture";
      refresh = "fixture";
      expires = 4102444800000;
      clientId = "fixture";
      scopes = ["chatgpt.tokens.use.direct"];
    };
  });
in
  runCommandLocal "pi-openai-context-integration" {
    nativeBuildInputs = [openssl];
    __darwinAllowLocalNetworking = true;
  } ''
    export HOME="$TMPDIR/home"
    testRoot="$TMPDIR/fixtures"
    mkdir -p "$testRoot/node_modules/@dotfiles"
    cp ${./package.json} "$testRoot/package.json"
    cp -R ${./test/integration} "$testRoot/integration"
    ln -s ${support} "$testRoot/node_modules/@dotfiles/pi-integration-tests"
    ln -s ${support}/node_modules/typebox "$testRoot/node_modules/typebox"
    probe="$testRoot/integration/openai-context-check.ts"
    modes="$("${lib.getExe nodejs_24}" "$probe" --list-scenarios)"
    for mode in $modes; do
      export PI_CODING_AGENT_DIR="$HOME/$mode"
      install -Dm644 ${settings} "$PI_CODING_AGENT_DIR/settings.json"
      install -m600 ${auth} "$PI_CODING_AGENT_DIR/auth.json"
      if [[ "$mode" == api-key ]]; then
        printf '%s\n' '{"openai":{"type":"api_key","key":"fixture"}}' > "$PI_CODING_AGENT_DIR/auth.json"
      fi
      if ! timeout 60s ${lib.getExe nodejs_24} "$probe" ${lib.getExe pi} gpt-6.2-sol "$mode" "$PI_CODING_AGENT_DIR" >responses.jsonl 2>errors.txt || [[ -s errors.txt ]]; then
        echo "OpenAI context probe failed in $mode mode" >&2
        cat errors.txt responses.jsonl >&2
        exit 1
      fi
    done
    touch "$out"
  ''
