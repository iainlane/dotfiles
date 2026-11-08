# LibreChat runtime

Run LibreChat locally with persistent, isolated workspaces for conversations.
The [LibreChat feature] configures the application, its supporting services,
providers and tools.

[LibreChat feature]: ../../features/inference/librechat/README.md

## Create your account

After activating your dotfiles configuration, put your password in a private
text file and run:

```sh
chmod 600 ./password
librechatctl bootstrap \
  --email you@example.com \
  --name "Your Name" \
  --password-file ./password
```

Open <http://127.0.0.1:3080> and sign in. Delete the password file after
bootstrap succeeds.

Bootstrap creates your administrator account and personal agents. Running it
again updates your display name and repairs agent permissions without changing
your password or existing agent settings.

## Reset a conversation workspace

A reset permanently deletes the conversation's workspace files, including
unpushed work. Finish active calls before running:

```sh
librechatctl reset --conversation CONVERSATION_UUID
```

The next workspace operation creates a fresh workspace.

## Configuration and support

See the [LibreChat feature] for provider configuration, tools, workspace
retention, logs and backups.

To build, test or change this package, see [Development].

[Development]: docs/development.md
