# AI tools

The `ai` feature installs coding assistants with shared [MCP servers],
instructions, skills and language tools.

[MCP servers]: https://modelcontextprotocol.io/

## Feature selection

Add `features.ai` to a host's feature list to install Antigravity CLI, Claude
Code, Codex, Copilot CLI, Crush, OpenCode 2, Pi, t3code and Herdr.

These children are optional:

| Feature                              | Purpose                                      |
| ------------------------------------ | -------------------------------------------- |
| `ai.claude-desktop`                  | Claude Desktop; included by `desktop`        |
| `ai.claude-code.teamclaude`          | Pool Claude accounts through a local proxy   |
| `ai.claude-code.teamclaude.frontend` | Add Claude API conversion before TeamClaude  |
| `ai.cloudflare-mcp`                  | Cloudflare account and documentation servers |
| `ai.rea`                             | Reverse-engineering tools and workflow       |

The `home` feature includes TeamClaude and the Cloudflare servers on hosts with
`ai`. Select REA or the TeamClaude frontend explicitly when needed.

Tool-specific guides:

- [Claude Code]: managed settings, skills and TeamClaude accounts
- [Codex]: system defaults and user overrides
- [OpenCode]: configuration and TUI plugins
- [Pi]: authentication, commands, permissions and temporary runs
- [Herdr]: workspaces, annotations and server management
- [REA]: reverse-engineering tools and platform support

[Claude Code]: claude-code/README.md
[Codex]: codex/README.md
[OpenCode]: opencode/README.md
[Pi]: pi/README.md
[Herdr]: herdr/README.md
[REA]: rea/README.md

## Shared MCP servers

Add servers through `dotfiles.ai.mcpServers` in a feature's Home Manager module.
Remote servers use `url` and optional `headers`; local servers use `command`,
optional `args` and optional `env`. Each harness converts these entries into its
own configuration format.

The built-in servers are defined in `mcp-server-definitions.nix`. Host-specific
secret files are declared through sops-nix and read at runtime. Harnesses may
exclude individual servers; see their guides for the relevant options.

MCP servers use packages from unstable on both stable and unstable hosts.
Language tools and wrappers follow the host's channel. Harness packages come
from the `llm-agents` input.

## Instructions, output styles and skills

Edit shared instructions under `instructions/`. Harnesses receive `AGENTS.md`
first, followed by the other Markdown files in lexicographic order. Claude
Code-specific instructions go under `instructions/claude-code/`; a file there
replaces the shared file with the same filename for Claude Code.

The default output style is `plain-technical-prose`. Add styles as Markdown
files with `name` and `description` frontmatter under `output-style/`. Each
style is also available as a skill for changing style during a session.

Shared skills are installed under `~/.agents/skills`. Add a skill through
`dotfiles.ai.skills`:

```nix
dotfiles.ai.skills.example.directory = ./example-skill;
```

A directory may contain one `SKILL.md` or several skill directories. For a
Nix-defined skill, use `skill.frontmatter` and `skill.body`; existing
definitions under `skills/` provide examples. Conflicting definitions with the
same skill name fail the build.

## Bundles

Use `dotfiles.ai.bundles.<name>` to group related `mcpServers` and `skills`.
Bundle contents join the shared configuration automatically.

A harness can exclude a whole bundle if the harness provides an exclusion
option. For example, `dotfiles.inference.librechat.excludeBundles = ["rea"];`
excludes both REA's server and its skill from LibreChat.

## Prose linting

Every harness receives `prose-lint`, Vale and the Vale language server. See the
[prose-lint guide] for commands and repository-specific rule overrides.

Portable rules apply everywhere. House rules report errors in repositories owned
by an account in `dotfiles.ai.proseLint.owners` and warnings elsewhere;
ownership is determined from Git remotes. Set
`dotfiles.ai.proseLint.enable = false` to disable this tooling.

[prose-lint guide]: ../../pkgs/prose-lint/README.md

## Adding a harness

1. Create `<harness>/default.nix` and register `dotfiles.features.ai.<harness>`
   with its Home Manager or system modules.
2. Read servers from `config.dotfiles.ai.mcpServers`. Home Manager modules also
   receive `instructions`, `outputStyles`, `skillTree` and `mcp` arguments. Use
   `mcp.wrapWithTools` when the executable needs shared language tools.
3. Import the directory from `default.nix`. Add the child to
   `dotfiles.features.ai.includes` only if it should be installed by default.
4. Document tool-specific configuration in `<harness>/README.md` and run
   `./just check` from the repository root.

AI integrations use Home Manager modules from unstable on both host channels.
Keep channel compatibility code in `unstable-hm-modules.nix` and `lib/home.nix`.
