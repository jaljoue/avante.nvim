# Authentication code

`:AvanteLogin` calls `avante.api.login()`. The registry in
[providers/init.lua](providers/init.lua) finds providers with an `authenticate()`
entry point. Provider setup loads saved credentials and tells the user when
login is needed. Setup never opens the browser.

| Module | Responsibility |
| --- | --- |
| [providers/openai.lua](providers/openai.lua) | ChatGPT authorization, credential validation, refresh, and bearer headers |
| [oidc.lua](oidc.lua) | Verify OpenAI ID-token signatures and identity claims using JWKS and OpenSSL |
| [oauth_server.lua](oauth_server.lua) | One pending loopback callback, state verification, and a five-minute timeout |
| [pkce.lua](pkce.lua) | Cryptographic randomness and the PKCE verifier/challenge |
| [store.lua](store.lua) | Shared credential file, atomic writes, write lock, and directory watcher |
| [../providers/openai.lua](../providers/openai.lua) | Model choices, stateless Responses requests, tool history, and stream events |
| [providers/claude.lua](providers/claude.lua) | Claude's existing manual authorization flow |
| [../ui/oauth.lua](../ui/oauth.lua) | Browser/copy popup used by the manual flow |

## OpenAI sign-in and refresh

1. `authenticate()` creates fresh PKCE, state, and nonce values, then starts the
   listener on `127.0.0.1`. The initial authorization requests dynamic client
   registration with Avante's stable host ID. Later sign-ins reuse the saved
   issued client ID and ID-token hint.
2. The callback consumes the pending attempt once. The auth provider exchanges
   its code using the same redirect URI and verifier, validates the ID token,
   checks the direct-use scope, and saves the credentials. Failed sign-in leaves
   existing credentials intact.
3. The request provider sends the access token to the public Responses API.
   `store = false` requires full message and tool-call history on each request,
   without `previous_response_id` or references to stored reasoning items.
4. A timer checks expiry once a minute. Requests also refresh near expiry. An
   exclusive `openai-refresh.lock` covers reading the latest credentials,
   rotating the tokens, and persisting the replacement. Another process reloads
   the replacement instead of reusing the old refresh token.
5. `store.lua` watches the containing directory because atomic writes replace
   the file's inode. Writes preserve the other providers' credentials and use
   owner-only permissions on Unix. Cleanup stops timers, callbacks, and watchers.

The paths under `stdpath("data") .. "/avante/"` are `auth.json`, `auth.lock`,
`openai-refresh.lock`, and `device_id`. `device_id` is a stable host UUID retained
independently of credentials. Lock files contain a PID, and a dead owner's lock
can be reclaimed. Access, refresh, and ID tokens must stay out of logs and source
control, including authorization URLs containing `id_token_hint`.

This implementation keeps one OpenAI registration. Device-code login and an
account picker are outside this change. Model choices currently use a built-in
list rather than the account catalog.

The protocol reference is OpenAI's [registration and sign-in guide](https://developers.openai.com/siwc/token-sharing-open-source/sign-in),
with [refresh guidance](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
and the [inference contract](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference).

## Checks

Run `make luatest` after installing Neovim, ripgrep, silversearcher-ag, and
OpenSSL. The OpenAI lifecycle tests cover real credential persistence and watch
notifications while mocking the authorization browser and token endpoint.
Callback tests use a real loopback listener. ID-token tests sign locally with
OpenSSL and verify against a local JWKS response. No live account is required.

The request tests cover Responses formatting, tool-call history, and usage-limit
handling. Keep tests centered on these observable behaviors rather than separate
assertions about helper names, picker labels, or fixed delays.
