import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Preset } from "#footer/configuration/settings.ts";
import type { DemoFixture } from "./fixture.ts";

export interface DemoOptions {
  preset: Preset;
  theme: "dark" | "light";
}

export class DemoWorkspace {
  readonly cwd: string;
  readonly agent: string;
  readonly env: Record<string, string>;
  private readonly root: string;
  private readonly fixture: DemoFixture;

  private constructor(root: string, fixture: DemoFixture) {
    this.root = root;
    this.fixture = fixture;
    const home = join(root, "home");
    this.cwd = join(home, "workspace");
    this.agent = join(home, ".pi/agent");
    this.env = {
      PATH: process.env.PATH ?? "",
      HOME: home,
      XDG_CONFIG_HOME: join(home, ".config"),
      XDG_CACHE_HOME: join(home, ".cache"),
      XDG_STATE_HOME: join(home, ".local/state"),
      PI_CODING_AGENT_DIR: this.agent,
      PI_OFFLINE: "1",
      GIT_CONFIG_NOSYSTEM: "1",
      TERM: "xterm-256color",
      COLORTERM: "truecolor",
      LANG: "en_US.UTF-8",
    };
  }

  static create(fixture: DemoFixture): DemoWorkspace {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-footer-demo-")));
    const workspace = new DemoWorkspace(root, fixture);
    try {
      workspace.prepare();
      return workspace;
    } catch (error) {
      workspace.close();
      throw error;
    }
  }

  private git(...args: string[]): void {
    execFileSync("git", args, { cwd: this.cwd, env: this.env, stdio: "pipe" });
  }

  private file(path: string, content: string): void {
    const target = join(this.cwd, path);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, content);
  }

  private prepare(): void {
    mkdirSync(this.cwd, { recursive: true });
    mkdirSync(this.agent, { recursive: true });
    this.git("init", "-q", "-b", this.fixture.git.branch);
    for (const file of this.fixture.git.files) {
      if (file.kind === "modified") {
        this.file(file.path, file.before);
      }
    }
    this.git("add", "--", ".");
    this.git(
      "-c",
      "user.name=Footer Demo",
      "-c",
      "user.email=demo@example.invalid",
      "commit",
      "--allow-empty",
      "-qm",
      "Initial demo state",
    );
    for (const file of this.fixture.git.files) {
      this.file(
        file.path,
        file.kind === "modified" ? file.after : file.content,
      );
      if (file.kind === "staged") {
        this.git("add", "--", file.path);
      }
    }
  }

  configure(url: string, options: DemoOptions): void {
    const { provider, ...model } = this.fixture.model;
    const models = {
      providers: {
        [provider]: {
          baseUrl: url,
          api: "openai-completions",
          apiKey: "synthetic-demo-key",
          models: [{ ...model, input: ["text"] }],
        },
      },
    };
    const settings = {
      theme: options.theme,
      quietStartup: true,
      compaction: { enabled: false },
      retry: { enabled: false },
      cacheWarming: { enabled: false },
    };
    for (const [filename, value] of [
      ["settings.json", settings],
      ["models.json", models],
      ["session-footer.json", { preset: options.preset }],
    ] as const) {
      writeFileSync(join(this.agent, filename), `${JSON.stringify(value)}\n`);
    }
  }

  command(host: string): string[] {
    return [
      host,
      "--offline",
      "--no-extensions",
      "-e",
      fileURLToPath(new URL(import.meta.resolve("#footer-entry"))),
      "--no-mcp",
      "--no-skills",
      "--no-context-files",
      "--no-prompt-templates",
      "--no-tools",
      "--tui-mode",
      "fullscreen",
      "--provider",
      this.fixture.model.provider,
      "--model",
      this.fixture.model.id,
      "--thinking",
      "high",
    ];
  }

  close(): void {
    rmSync(this.root, { recursive: true, force: true });
  }
}
