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

At startup, the extension wraps Pi's OpenAI provider and uses the matching saved
catalogue for Responses models. This also applies to standalone
`pi --list-models`, which reads the cache during Pi's startup refresh and uses
Pi's configured limits on a cache miss. Pi's provider still handles sign-in,
requests and model discovery.

Session start, reload, model selection and turns check whether the [OpenAI
account catalogue] is due for a refresh. A successful response is fresh for five
minutes. Within a session, a failure delays the next attempt by 30 seconds. An
idle session makes no additional requests. A turn can wait up to four seconds
for the first fetch when there is no matching saved catalogue. Later turns use
the last matching windows during refresh. The extension updates the active model
so the footer and compaction use the same limit.

The cache is `openai-context-cache.json` in the Pi agent directory. OpenAI binds
the [issued OAuth client ID] to the user and workspace selected at sign-in. The
extension matches the cache to that registration. It uses Pi's credential
resolver for requests, so Pi can renew the access token before the request. An
offline session or a failed request uses a matching cache entry when available.

API-key sessions use Pi's configured limits. The extension detects an explicit
context window in `models.json` and applies that window and its optional output
limit to the active model before the next typed turn checks for compaction. Pi
owns the rest of the model configuration. Explicit model limits in `models.json`
take precedence in the registry.

Run `/openai-context` to see the active context window and the account window.
`/openai-context refresh` requests the account catalogue immediately, even if
the cache is fresh. The command respects offline mode and can run with any model
selected, provided Pi has a ChatGPT login for OpenAI.

Pi records an entry when the extension updates the active model. If Pi resets
the thinking level during the update, restoring the previous level produces a
second thinking-level event and transcript entry. This can happen while resuming
a session. When the first fetch is still pending, Pi can check whether to
compact before the account window is available.

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
