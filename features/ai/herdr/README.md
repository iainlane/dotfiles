# Herdr

Run `herdr` to open a terminal workspace for coding agents. The `ai` feature
installs [Herdr], configures its agent integrations and enables plugins for
context usage, model information and annotations.

Nix manages `config.toml`. Invalid settings fail the build because Herdr would
otherwise discard the configuration and start with defaults.

[Herdr]: https://herdr.dev

## Annotations and document review

Bindings use Herdr's prefix, which defaults to Ctrl+B:

| Key       | Action                                                                  |
| --------- | ----------------------------------------------------------------------- |
| `a`       | Comment on selected terminal text; Ctrl+S saves the comment             |
| `Shift+A` | Copy annotations as feedback                                            |
| `Ctrl+A`  | Copy and archive annotations                                            |
| `Ctrl+V`  | Paste feedback into the agent's prompt without submitting, then archive |
| `Ctrl+S`  | Submit feedback to the agent, then archive                              |
| `m`       | Manage annotations                                                      |
| `o`       | Review documents in the focused pane's folder                           |
| `Shift+L` | Choose a recent agent reply to review                                   |
| `Ctrl+L`  | Review the newest agent reply                                           |

Feedback becomes a message to the agent; sending feedback does not itself edit
the reviewed file. Annotations and feedback history persist outside the Nix
store.

For standalone document reviews, run `plannotator-tui <file-or-folder>`.

## Plugins

`dotfiles.herdr.plugins` lists the plugin packages to enable. The defaults are:

- [Context Bar]: context-window usage below each agent in the sidebar
- [Model Display]: the agent's model and reasoning effort
- [Annotate]: comments on terminal selections and reviews of documents, folders
  and agent replies
- [Annotate Links]: Ctrl-clicked `file://` links to Markdown documents open in
  Annotate; other links use Herdr's normal file opener

Each package must specify its plugin directory in `passthru.pluginRoot`.
Activation links and enables the listed plugins and removes previously managed
links that are no longer listed. Plugins linked from outside the Nix store are
left unchanged.

Reload changed bindings with `herdr server reload-config`. Plugin startup
commands run only when the server starts. After an update, restart the server to
use a new Context Bar daemon.

[Context Bar]: https://github.com/pdalinis/herdr-ctx-bar
[Model Display]: https://github.com/pdalinis/herdr-disp-model
[Annotate]: https://github.com/plannotator/herdr-annotate
[Annotate Links]: https://github.com/plannotator/herdr-annotate/tree/main/links

## Server management

A user service starts the server: `herdr.service` under systemd on Linux, or a
launchd agent on macOS.

On Linux, activating a new configuration does not restart a running server. To
run the new version, use `systemctl --user restart herdr`. Restarting the server
ends every process in its panes.

A `herdr` client can start a server when none is running. If a client-started
server is already running, the user service skips startup. To switch to the user
service, detach clients, run `herdr server stop`, then start the service.

On Linux, a zsh shell in a pane without display variables imports them from the
user manager. This allows GUI commands to work when the server started before
the desktop session.

## Agent integrations

Nix configures integrations for the installed Claude Code, Codex, Pi and
OpenCode harnesses. Do not run `herdr integration install`; another installation
could duplicate the configured hooks.

OpenCode 2 uses a TUI plugin because its background server runs outside the
pane. See the [OpenCode guide] when adding other TUI plugins.

[OpenCode guide]: ../opencode/README.md
