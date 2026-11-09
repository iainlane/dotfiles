# Claude Code

Run `claude` for Claude Code with shared instructions, skills, MCP servers and
language tools.

## Configuration

Nix writes user configuration under `~/.config/claude` and applies system-wide
managed settings. Add policy through `dotfiles.claudeCode.managedSettings`.
Permission lists and hooks from multiple modules are combined; other settings
merge recursively.

Use these Home Manager options for harness-specific changes:

- `dotfiles.claudeCode.excludeMcpServers`: omit shared MCP servers
- `dotfiles.claudeCode.excludeSkills`: omit shared skills
- `dotfiles.claudeCode.skills`: add or replace skills for Claude Code only

Unknown exclusions fail the build. A skill cannot be both defined and excluded.
The defaults exclude the `context7`, `git` and `playwright` servers and the
`asd-ste100`, `gh-stack` and `stacked-prs` skills.

Shared instructions also apply to subagents. Put Claude Code-specific
instruction overrides under `../instructions/claude-code/`.

## TeamClaude accounts

Select `features.ai.claude-code.teamclaude` to pool Claude subscriptions through
[TeamClaude]. The `home` feature already selects this child on personal hosts
with `ai`.

Add subscription accounts with `teamclaude login`. The user service starts after
the first account is added. The proxy rotates requests between accounts with
available quota. Claude Code still needs its own login and uses that login
directly when the proxy is not running.

[TeamClaude]: https://github.com/KarpelesLab/teamclaude

### API keys

Declare a shared Anthropic API-key file through Home Manager:

```nix
dotfiles.ai.anthropicApiKeyFile = config.sops.secrets.anthropic-api-key.path;
```

The option defaults to `null` and does not select TeamClaude. With the
TeamClaude feature enabled, the key becomes an account called `anthropic`. The
file must contain a single key and is read at runtime.

For TeamClaude-specific settings or additional API-key accounts:

```nix
dotfiles.claudeCode.teamclaude = {
  settings.switchThreshold = 0.98;
  apiKeyAccounts.fallback = {
    apiKeyFile = config.sops.secrets.anthropic-api-key.path;
    priority = 100;
  };
};
```

Lower priority values are preferred. API-key accounts default to `100`;
subscription accounts default to `0`.

### Account policy and writable settings

Declare policy for an existing subscription without storing OAuth tokens in Nix:

```nix
dotfiles.claudeCode.teamclaude = {
  accountSettings."me@example.com".allowExtraUsage = true;
  settings.quotaProbeSeconds = 300;
};
```

Account settings require exact TeamClaude account names. Missing accounts are
skipped until login adds them and activation or server startup applies the
configuration again. Subscription extra usage is a fallback after every eligible
account, including API-key accounts. The quota probe refreshes extra-usage
availability and spend every five minutes.

Activation and server startup apply declared settings without replacing OAuth
credentials or undeclared values. Arrays are replaced as a whole. Removing a
setting or account-policy declaration leaves its runtime value unchanged;
removing an API-key account deletes its managed entry. Accounts added through
TeamClaude remain unchanged.

Activate after changing a secret to update the saved API key and reload the
running proxy. Settings that cannot be reloaded, such as the listen port,
require a service restart.

### Claude API frontend

Select `features.ai.claude-code.teamclaude.frontend` to enable the [Claude API
frontend]. This feature includes TeamClaude. The `claude` launcher then requires
both user services to be available.

The frontend converts the Claude Code user agent, beta flag and system-prompt
billing attribution for API usage. TeamClaude continues to manage credentials.
Normal account rotation remains the default. To select an API-key account:

```nix
dotfiles.claudeCode.teamclaude.frontend.account = "anthropic";
```

The frontend listens on port `3457` by default; change
`dotfiles.claudeCode.teamclaude.frontend.port` to use another port. Its private
CA is stored under `$XDG_STATE_HOME/claude-api-frontend`.

Restart both user services after changing TeamClaude's listen port. Enabling the
frontend does not add an API key or test provider billing eligibility.

[Claude API frontend]: ../../../pkgs/claude-api-frontend/README.md
