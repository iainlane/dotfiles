# Pi OpenAI Context

Pi OpenAI Context uses the default context windows advertised by your ChatGPT
account. With Pi 1.5.2 or later, sign in with `/login openai` and choose **Sign
in with ChatGPT**. The extension needs no configuration file.

To install the package from this checkout, run the following from the repository
root in a Pi profile with writable settings.

```sh
pi install ./pkgs/pi-openai-context
```

The managed dotfiles profile loads the package through Nix. To build a tarball
that you can unpack and install locally, run
`nix build .#pi-openai-context.tarball`.

The extension applies a matching cached window when a session starts with a
ChatGPT model or you select one. It starts fetching the [OpenAI account
catalogue] at the same time. A turn can wait up to four seconds for the first
fetch when there is no matching cached catalogue. Input handlers can consume a
prompt before the extension waits for the request. Later turns use the last
window while the extension refreshes the catalogue after five minutes or retries
a failed request after 30 seconds.

The cache is `openai-context-cache.json` in the Pi agent directory. OpenAI binds
the [issued OAuth client ID] to the user and workspace selected at sign-in. The
extension matches the cache to that registration. It uses Pi's credential
resolver for requests, so Pi can renew the access token before the request. An
offline session or a failed request uses a matching cache entry when available.

API-key sessions and providers registered by another extension use Pi's
configured limits. The extension detects an explicit context window in
`models.json` and applies that window and its optional output limit to the
active model before the next typed turn checks for compaction. Pi owns the
registry and the rest of the model configuration. Restart Pi to reload the
registry after changing its configuration.

Run `/openai-context-status` to see the active context window and catalogue
status. Pi records an entry when the extension updates the active model. If Pi
resets the thinking level during the update, restoring the previous level
produces a second thinking-level event and transcript entry. This can happen
while resuming a session. The model picker and `--list-models` show the registry
limits. When the first fetch is still pending, Pi can check whether to compact
before the account window is available.

## Pi 1.5.2 limitations

Pi checks authentication asynchronously before writing a model selection. The
extension can discard work before requesting an update, but a selection made
while that write is pending can still be overwritten by Pi. Pi's credential
resolver can also finish a queued renewal after the catalogue deadline. The
extension discards catalogue work after cancellation. The cache uses the
standard Pi CLI agent directory and its file-backed registration.

[OpenAI account catalogue]:
  https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference#1-list-available-models
[issued OAuth client ID]:
  https://developers.openai.com/siwc/token-sharing-open-source#a-client-vs-an-agent-host

## Validation

Run `nix build .#pi-openai-context .#pi-openai-context.tests.integration` from
the repository root. The build runs TypeScript checks, lint and Vitest. The
integration check installs the package in temporary Pi profiles and streams
fixture Responses API replies. The `pi-openai-context-profile` check verifies
that the managed Pi profile loads the extension and applies its cached window
offline.
