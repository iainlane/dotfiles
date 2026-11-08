# LibreChat runtime

Run LibreChat locally with persistent, isolated workspaces for conversations.
The [LibreChat feature] configures the application, its supporting services,
providers and tools.

[LibreChat feature]: ../../features/inference/librechat/README.md

## Create your account

After activating your dotfiles configuration, run:

```sh
librechatctl bootstrap
```

Enter your email address, display name and password. Password entry is masked,
and you must enter the password twice.

For non-interactive use, put your password in a private text file and supply the
account details explicitly:

```sh
chmod 600 ./password
librechatctl bootstrap \
  --email you@example.com \
  --name "Your Name" \
  --password-file ./password
```

Open <http://127.0.0.1:3080> and sign in. If you used a password file, delete it
after bootstrap succeeds. Password files are UTF-8 text; one final LF or CRLF is
removed, and other whitespace is preserved.

Bootstrap creates your administrator account and personal agents. Running it
again updates your display name and repairs agent permissions without changing
your password or existing agent settings. Interactive prompts start with the
bound email address and current display name. Existing accounts do not need a
password file, and bootstrap does not read a supplied password file for an
existing account.

Prompts require terminal stdin and stderr, with CI mode off. Piped input never
supplies prompt answers. Use `librechatctl --help` or command-specific `--help`
for options and examples. Every command accepts `--yes` before or after the
command. This option accepts confirmations only; it does not supply missing
inputs or skip password verification.

## Reset a conversation workspace

A reset permanently deletes the conversation's workspace files, including
unpushed work. Finish active calls before running:

```sh
librechatctl reset --conversation CONVERSATION_UUID
```

Confirm deletion when prompted; the default is No. You can omit `--conversation`
to enter the UUID interactively. Non-interactive reset requires the UUID and
`--yes`:

```sh
librechatctl reset --conversation CONVERSATION_UUID --yes
```

The next workspace operation creates a fresh workspace.

## Configuration and support

See the [LibreChat feature] for provider configuration, tools, workspace
retention, logs and backups.

To build, test or change this package, see [Development].

[Development]: docs/development.md
