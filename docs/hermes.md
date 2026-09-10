# Hermes operator notes

The Hermes feature runs the agent in a rootful Podman container. Its child
features add platforms and integrations. Selecting a child records that the host
intends to use it, while integrations backed by optional secrets remain inactive
until those secrets exist.

## Provisioning integrations

Select the required children from `features.hermes.provides` in the host's
`features` list. Each integration's `secretsFile` option defaults to
`dotfiles.hermes.secretsFile` and refers to an encrypted YAML file in the
`secrets` flake input.

- `webhook`: add `webhook_secret` to the configured secrets file and give the
  sender the same value. Configure `dotfiles.hermes.webhook.expose` to serve the
  listener through the reverse proxy. Each request must carry a signature which
  Hermes accepts. The AgentMail inbox uses its own signing secret, as described
  below.
- `identity`: set `dotfiles.hermes.identity.name` and `email`, and add an
  Ed25519 private key under `ssh_private_key` in the configured secrets file.
  Register its public key on the agent's forge account for authentication and
  signing. The setup service derives the public key inside the Hermes home
  volume. SSH signatures for commits and tags are enabled by default.
- `agentsview`: configure an AgentsView server and generate a client certificate
  for the machine name `<host>-hermes`. Commit its public certificate as
  `hosts/<host>/agentsview-hermes.pem`. Store its private key under
  `agentsview_client_key` in the configured secrets file, and store the database
  password under `password` in `agentsview-postgres/<host>-hermes.yaml`. The
  server creates the role, and `hermes-agentsview.service` pushes the agent's
  sessions.

Run `just generate-agentsview-secrets <host>` to generate missing credentials
for both the host and its Hermes identity. The wrapper commits and pushes the
encrypted secrets repository. To inspect the changes in a local secrets checkout
without publishing them, run
`scripts/generate-agentsview-secrets.bash <host> <secrets-directory>` directly.
Commit the generated public certificate to this repository separately.

## AgentMail inbox

Add the inbox child to the host's `features` list:

```nix
features.hermes.provides.inbox
```

Configure its required Matrix values on the host. `boardId` and `assignee`
default to `"default"`, so set them only when the intake should use another
board or assignee.

```nix
dotfiles.hermes.inbox = {
  matrixRoomId = "<Matrix room ID>";
  matrixUserId = "<authorised Matrix user ID>";
  boardId = "default";
  assignee = "default";
};
```

Store the AgentMail inbox ID as `agentmail_inbox_id` in the configured Hermes
secrets file. Create an inbox-scoped API key and store it as `agentmail_api_key`
in the same file. Create an inbox-scoped webhook for `message.received` which
sends to `/webhooks/agentmail` on the public HTTPS origin configured through
`dotfiles.hermes.webhook.expose`. AgentMail returns the signing secret when it
creates the webhook; store that value as `agentmail_webhook_secret`. The
`webhook_secret` key is for a standalone Hermes webhook without the inbox child.
AgentMail documents both [inbox API keys][agentmail-api-key] and [inbox
webhooks][agentmail-webhook].

Set `dotfiles.hermes.webhook.expose.domain` to the public hook hostname and
`auth = false` to allow webhook senders through without browser sign-in. If the
host enables Caddy's Cloudflare origin authentication, the hostname must use the
Cloudflare proxy with Authenticated Origin Pulls enabled. Caddy then requires
Cloudflare's client certificate for public requests; `auth = false` does not
disable that requirement.

[agentmail-api-key]:
  https://docs.agentmail.to/api-reference/inboxes/api-keys/create
[agentmail-webhook]:
  https://docs.agentmail.to/api-reference/inboxes/webhooks/create

After deployment, the plugin sends approval digests at 09:00 and 17:00 in the
Europe/London time zone. Send `/inbox` in the configured Matrix room to request
a digest immediately. Reply to a digest with `/inbox approve N` or
`/inbox dismiss N`. A numbered reaction approves the corresponding proposal.
Only `matrixUserId` can approve or dismiss proposals.

To stop intake, disable the inbox feature and delete or disable the AgentMail
webhook subscription. The SQLite state remains at `$PLUGIN_DATA/inbox.sqlite3`,
so enabling the feature again resumes from the retained state. An occasional
delivery or classification failure does not create a Kanban job. The plugin
records the failure and logs it for manual handling; it does not reconcile
failed messages automatically. Send a new email if the proposal still needs to
enter the intake queue.

### Intake behaviour and trust boundary

Each new message is classified by a fresh structured LLM call which has no agent
conversation memory or tools. The classifier can ignore the message, associate
it with an existing card, or propose a new triage card. Association first uses
recorded references, then falls back to an LLM choice among board candidates.
The plugin does not assign or start proposed work before the authorised Matrix
user approves it, and `kanban.auto_decompose` remains off.

Association appends incoming text to an existing card. A worker already running
that card can therefore read untrusted email content before another approval.
This workflow constrains new work creation; it does not isolate an approved
agent task from all later untrusted content. The plugin stores message-to-card
correlation in its SQLite database. It preserves the complete readable message
body, using an attachment when the body is too large for the card text.

## Before deployment

1. Choose the Matrix room ID, authorised Matrix user ID, board, and assignee.
   Add the inbox child and those settings to the host.
2. Provision `agentmail_api_key` and `agentmail_webhook_secret`, then create the
   inbox-scoped AgentMail webhook. Store its inbox ID as `agentmail_inbox_id`.
   Configure DNS and TLS for the hook hostname, including any origin
   authentication required by the reverse proxy.
3. Ensure the host can decrypt its SOPS files. Commit the encrypted secrets and
   update the `secrets` flake input so evaluation sees them. Commit the host
   configuration and any public certificates.
4. Run the flake checks and build the host's complete configured system and
   container image. Package and module checks do not replace a build of the
   deployed configuration.
5. Deploy the host and verify one test email from webhook receipt through the
   Matrix digest and approval flow before relying on the intake.

## MCP credentials

Hermes takes the local Git and NixOS servers from the same evaluated MCP
registry as the coding harnesses. It enables MCP sampling for each server.
Remote endpoints also come from the shared registry.

The Exa server defaults to the `exa_api_key` entry in the Hermes secrets file.
Browser Rendering uses `cloudflare_browser_token` when that key is present. The
Cloudflare account server needs an interactive OAuth flow, so Hermes omits it. A
token entry is accepted only for a server whose registry entry defines
static-token authentication.
