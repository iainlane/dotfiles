# Claude API frontend

A loopback proxy that converts Claude Code inference requests before forwarding
them to TeamClaude. TeamClaude manages authentication, account selection and
upstream connections. The frontend reads TeamClaude's listen port but does not
read API keys into its configuration or logs.

For `POST /v1/messages`, the frontend changes `(external, cli)` to
`(external, sdk-cli)` in the user agent, removes `claude-code-20250219` from
`anthropic-beta`, and removes lines beginning `x-anthropic-billing-header:` from
system text. Other beta flags, tools, cache controls, user messages and response
streams are preserved. This behaviour depends on the upstream API's client
classification and can change independently of this package.

## Run

Build with `nix build .#claude-api-frontend` from the repository root. The Nix
package includes Node 24 and OpenSSL. To run from source, install those
runtimes, run `npm ci`, and invoke `node src/cli.ts`.

Create a configuration file:

```json
{
  "port": 3457,
  "teamclaudeConfigFile": "/home/user/.config/teamclaude.json",
  "stateDirectory": "/home/user/.local/state/claude-api-frontend",
  "account": null
}
```

Run `claude-api-frontend serve --config FILE`. The frontend listens only on
`127.0.0.1`. TeamClaude must accept loopback requests (`proxy.trustLoopback`
must be absent or `true`). Set `account` to a TeamClaude account name to pin
inference requests, or leave it `null` to retain TeamClaude's account rotation.
Configuration changes require a service restart. Restart both proxies after
changing TeamClaude's listen port.

Set these variables in the environment of the Claude process:

```sh
export HTTPS_PROXY=http://127.0.0.1:3457
export HTTP_PROXY="$HTTPS_PROXY" https_proxy="$HTTPS_PROXY" http_proxy="$HTTPS_PROXY"
export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
export NODE_EXTRA_CA_CERTS=/home/user/.local/state/claude-api-frontend/authority/ca.pem
unset ANTHROPIC_BASE_URL
```

The frontend terminates TLS for `api.anthropic.com:443`, with HTTP/1.1 and
HTTP/2 support. Plain HTTP proxy requests and WebSocket upgrades pass through
TeamClaude without inference rewriting. Other CONNECT tunnels also pass through
TeamClaude. Only inference requests are buffered, with a default limit of 32
MiB. Compressed inference requests return 415. Responses stream with
backpressure. For ordinary API requests, Fetch decodes compressed upstream
responses; the frontend removes their content-encoding and content-length
headers. `maxBodyBytes` and `timeoutMs` override the request size limit and
five-minute request timeout.

The state directory has mode `0700`. Its persistent CA private key has mode
`0600`; a fresh leaf certificate is issued on startup and renewed weekly. Trust
the CA only in the client process, not in the system trust store. To replace the
CA, stop the frontend, remove its `authority` directory, and restart the
frontend and Claude sessions. The frontend refuses to start when the CA expires
within a year.

`claude-api-frontend check --config FILE` verifies the running frontend's CA
fingerprint, account selection and upstream port, then checks the TeamClaude
HTTP listener. It does not make an inference request or test provider credits.
The service logs its listen ports, but no request bodies, credentials or
headers.

## Development

Run `npm run check` for type checking, lint and tests. Tests use local HTTP and
TLS listeners and require OpenSSL on `PATH`. Format with the repository's Oxfmt
configuration. The Nix build runs the same checks and verifies the installed CLI
with an empty `PATH`.
