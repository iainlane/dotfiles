{inputs, ...}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    themes = import ../../../features/ai/pi/catppuccin-themes.nix {
      inherit (pkgs) lib;
      catppuccinPaletteSource = inputs.catppuccin-palette;
      accent = "blue";
    };
    contrastThemes = pkgs.writeText "pi-contrast-themes.json" (builtins.toJSON [themes.themes.latte themes.themes.mocha]);
    packageRoot = "${pkgs.pi-pretty}/${pkgs.pi-pretty.packageRoot}";
    probe = pkgs.writeText "pi-pretty-theme-probe.ts" ''
      import assert from "node:assert/strict";
      import { writeFileSync } from "node:fs";
      import { createReadTool, highlightCode, initTheme } from "@earendil-works/pi-coding-agent";
      import { renderFileContent } from "${packageRoot}/src/render.ts";
      import { registerReadTool } from "${packageRoot}/src/tools/read.ts";

      export default function (pi) {
        pi.on("session_start", async (_event, ctx) => {
          let tool;
          registerReadTool({ registerTool: value => { tool = value; } }, process.cwd(), undefined, createReadTool(process.cwd()));
          const content = "const answer = 42; // comment";
          const result = {
            content: [{ type: "text", text: content }],
            details: { _type: "readFile", filePath: "fixture.ts", content, offset: 0, lineCount: 1 },
          };
          const reused = { state: {}, expanded: true };
          const render = async context => {
            const component = tool.renderResult(result, {}, ctx.ui.theme, context);
            await new Promise(resolve => setTimeout(resolve, 0));
            context.lastComponent = component;
            return component.render(100);
          };
          const outputs = [];
          for (const appearance of ["dark", "light", "dark"]) {
            initTheme(appearance);
            const expected = highlightCode(content, "typescript").join("\n");
            assert.match(expected, /\x1b\[/);
            assert.equal(await renderFileContent(content, "fixture.ts", 0, 10, 100), expected);
            const actual = await render(reused);
            assert.deepStrictEqual(actual, await render({ state: {}, expanded: true }));
            outputs.push(actual);
          }
          assert.notDeepStrictEqual(outputs[0], outputs[1]);
          assert.deepStrictEqual(outputs[0], outputs[2]);
          writeFileSync("theme-probe-ok", "");
        });
      }
    '';
  in {
    checks.pi-theme-contrast = pkgs.runCommandLocal "pi-theme-contrast" {} ''
      ${pkgs.python3}/bin/python - ${contrastThemes} <<'PY'
      import json
      import sys

      def luminance(value):
          channels = [int(value[i:i + 2], 16) / 255 for i in (1, 3, 5)]
          linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in channels]
          return sum(v * weight for v, weight in zip(linear, (0.2126, 0.7152, 0.0722)))

      failures = []
      for theme in json.load(open(sys.argv[1])):
          colors = theme["colors"]
          variables = theme["vars"]
          backgrounds = ["base", colors["userMessageBg"], colors["toolSuccessBg"]]
          foregrounds = {role: value for role, value in colors.items() if not role.endswith("Bg") and not role.startswith("border") and role not in ("mdHr", "mdQuoteBorder", "mdCodeBlockBorder")}
          for role, value in foregrounds.items():
              foreground = luminance(variables.get(value, value))
              for background in backgrounds:
                  level = luminance(variables[background])
                  contrast = (max(foreground, level) + 0.05) / (min(foreground, level) + 0.05)
                  if contrast < 4.5:
                      failures.append(f"{theme['name']}: {role} on {background}: {contrast:.2f}:1")
      assert not failures, "\n".join(failures)
      PY
      touch "$out"
    '';
    checks.pi-pretty-theme = pkgs.runCommandLocal "pi-pretty-theme" {} ''
      export HOME="$TMPDIR/home"
      export PI_CODING_AGENT_DIR="$HOME/.pi/agent"
      export PI_OFFLINE=1
      export TERM=xterm-256color
      export COLORTERM=truecolor
      export FORCE_COLOR=3
      mkdir -p "$PI_CODING_AGENT_DIR"
      printf '%s\n' '{"defaultProjectTrust":"never","packages":[]}' > "$PI_CODING_AGENT_DIR/settings.json"
      printf '%s\n' '{"type":"get_state","id":"theme"}' | \
        ${inputs.llm-agents.packages.${system}.pi}/bin/pi --mode rpc --no-session --no-context-files --no-skills --no-prompt-templates --no-extensions -e ${probe} > rpc-output
      test -f theme-probe-ok || { cat rpc-output >&2; exit 1; }
      touch "$out"
    '';
  };
}
