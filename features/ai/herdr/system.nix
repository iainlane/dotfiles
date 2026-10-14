# The Herdr hooks of Claude Code and Codex. Both read their hooks from system
# configuration, which the `claude-code` and `codex` children write.
#
# Each harness gets two sets of hooks. Herdr's own hook reports the agent's
# session when it starts, and Context Bar reads that session's transcript.
# The Model Display hooks report the model and reasoning effort. Their events
# and timeouts match the hooks that the plugin's own setup actions register.
{hasHarness}: {
  hostConfig,
  inputs,
  lib,
  pkgs,
  ...
}: let
  inherit (inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}) herdr;

  packages = pkgs.callPackage ./packages.nix {};

  hookGroup = command: timeout: {
    hooks = [
      {
        type = "command";
        inherit command timeout;
      }
    ];
  };

  sessionHook = agent: hookGroup "${lib.getExe (packages.agentStateHook {inherit herdr agent;})} session" 10;

  modelDisplayHooks = harness: events: timeout:
    lib.genAttrs events (event: [
      (hookGroup "${pkgs.herdr-disp-model.hookCommand} ${harness}-hook" (timeout event))
    ]);

  mergeHooks = lib.zipAttrsWith (_event: lib.concatLists);

  claudeCodeHooks = mergeHooks [
    {
      SessionStart = [
        # Herdr registers its hook for these sources only.
        ({matcher = "^(startup|resume|clear|compact|fork)$";} // sessionHook "claude")
      ];
    }
    (modelDisplayHooks "claude" ["SessionStart" "UserPromptSubmit" "PostModelSwitch" "SessionEnd"] (_: 5))
  ];

  codexHooks = mergeHooks [
    {SessionStart = [(sessionHook "codex")];}
    (modelDisplayHooks "codex" ["SessionStart" "UserPromptSubmit" "SessionEnd"] (
      event:
        if event == "SessionEnd"
        then 3
        else 5
    ))
  ];
in {
  config = lib.mkMerge [
    (lib.optionalAttrs (hasHarness hostConfig "claude-code") {
      dotfiles.claudeCode.managedSettings.hooks = claudeCodeHooks;
    })

    (lib.optionalAttrs (hasHarness hostConfig "codex") {
      dotfiles.codex.hooks = codexHooks;
    })
  ];
}
