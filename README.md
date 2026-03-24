# SurProxy

SurProxy is a native macOS control plane for `CLIProxyAPIPlus`.

## Runtime Source

The repository vendors `CLIProxyAPIPlus` as a git submodule at:

- `Vendor/CLIProxyAPIPlus`

The current pinned source version is:

- tag: `v6.9.1-0`
- commit: `1dc4ecb1b8a6412954dd37ce4bfe0610478edcbc`

This submodule is used for:

- understanding upstream capabilities and integration points
- optional local builds during development
- tracking upstream config, management API, and auth behavior

The final macOS app should still package a compiled release binary as a separate runtime artifact, and allow the user to replace that runtime binary later from inside SurProxy.

## Packaging Workflow

Two helper scripts are included:

- [build_cliproxy_runtime.sh](/Users/clearain/Programs/Xcode/SurProxy/Scripts/build_cliproxy_runtime.sh): builds `Vendor/CLIProxyAPIPlus/cmd/server` into `build/runtime/cliproxyapiplus`
- [stage_runtime_binary.sh](/Users/clearain/Programs/Xcode/SurProxy/Scripts/stage_runtime_binary.sh): copies a compiled binary into the app resource location

The expected bundled runtime location is:

- [README.md](/Users/clearain/Programs/Xcode/SurProxy/SurProxy/Resources/Runtime/README.md)

The app is intended to:

- study `CLIProxyAPIPlus` source as the integration contract
- ship a compiled `CLIProxyAPIPlus` release binary inside the app bundle
- copy that binary into an app-managed writable runtime location and launch it from there
- allow the user to fetch newer `CLIProxyAPIPlus` releases and replace the active binary in-app
- reuse `CLIProxyAPIPlus` management APIs, config handling, and OAuth flows instead of reimplementing them
- keep feature parity with the web UI where practical while using native macOS components

## Current Status

The repository now contains a working native macOS host for `CLIProxyAPIPlus` with:

- `AppViewModel` driving app state and runtime actions
- `ProxyService` coordinating runtime launch, health checks, management API reads, and auth toggles
- `RuntimeManager` handling bundled runtime installation, process start/stop, config generation, and in-memory runtime logs
- dashboard sections for runtime state, packaged runtime binary, OAuth login, OAuth file list, and provider routing summary
- OAuth cards that can show upstream model IDs and copy them directly from the native UI

Current runtime layout:

- bundled runtime: `SurProxy.app/Contents/Resources/cliproxyapiplus`
- active runtime: `~/Library/Application Support/SurProxy/runtime/cliproxyapiplus`
- SurProxy-managed config: `~/Library/Application Support/SurProxy/config.yaml`
- runtime manifest: `~/Library/Application Support/SurProxy/runtime-manifest.json`
- shared auth directory: `~/.cli-proxy-api/`

Important behavior:

- SurProxy does not implement OAuth itself. It delegates provider login and auth status to `CLIProxyAPIPlus`.
- SurProxy uses the management API as the primary integration surface.
- For auth files, SurProxy now parses the real `CLIProxyAPIPlus` `GET /v0/management/auth-files` response shape based on upstream source.
- If the management API returns an empty auth list or the response cannot be interpreted, SurProxy falls back to scanning `~/.cli-proxy-api/*.json` directly so the UI does not collapse to an empty state.
- SurProxy preserves existing provider configuration in its app-managed `config.yaml` and only upserts the runtime fields it must own.
- SurProxy health checks now avoid sending `GET /v0/management/config` before `127.0.0.1:8787` is actually listening, which prevents noisy early `NSURLErrorDomain Code=-1004` failures during startup.
- For models, SurProxy first uses `GET /v0/management/auth-files/models?name=...` and then does a dynamic channel probe against `GET /v0/management/model-definitions/:channel` using auth-provided identifiers rather than a hardcoded provider-to-channel table.
- OAuth cards are shown in an adaptive multi-column grid and model lists are collapsed by default to reduce space usage.
- The app now runs as a menu bar host: closing the main window keeps SurProxy alive in the system status bar, and the tray menu can reopen the single main window, start or stop the service, or quit the app.
- Provider cards are also shown in an adaptive grid and load live model lists lazily when each disclosure section is expanded.
- Provider model enablement is sourced from `CLIProxyAPIPlus` management APIs, not by directly reading the local config file from the UI layer.
- Deprecated provider models that still exist in configured `models` but no longer appear in the remote provider catalog remain visible in the list and are marked with an orange `Deprecated` badge.
- Saving provider model changes now writes back upstream configuration and then immediately rereads provider state from management APIs so the UI reflects the real saved state.
- Provider model save strategy currently uses per-entry `PATCH` for `openai-compatibility`, `claude-api-key`, `codex-api-key`, and `vertex-api-key`; `gemini-api-key` still uses grouped `PUT` because upstream patch support for `models` is not available there.
- The UI shows a global loading overlay during management API mutations so users do not continue interacting with stale state while writes are in flight.
- After provider model saves finish, SurProxy now shows a short-lived floating notice instead of a persistent message because upstream state can still take a few seconds to settle; users can re-expand the model list to force a refresh.

## Upstream APIs In Active Use

- `/v0/management/config`
- `/v0/management/config.yaml`
- `/v0/management/latest-version`
- `/v0/management/auth-files`
- `/v0/management/auth-files/models`
- `/v0/management/auth-files/status`
- `/v0/management/model-definitions/:channel`
- `/v0/management/gemini-api-key`
- `/v0/management/claude-api-key`
- `/v0/management/codex-api-key`
- `/v0/management/openai-compatibility`
- `/v0/management/vertex-api-key`
- `/v0/management/codex-auth-url`
- `/v0/management/anthropic-auth-url`
- `/v0/management/gemini-cli-auth-url`
- `/v0/management/get-auth-status`

## Important Packaging Note

The app target has `App Sandbox` disabled.

That is currently required because the product needs to:

- launch and manage a bundled local binary
- call localhost management endpoints
- read and write `~/.cli-proxy-api/`

Leaving sandbox enabled caused localhost `Operation not permitted` failures.

## Recent Debugging Findings

- Provider entries disappearing after `Reload Config` or runtime restart was caused by SurProxy overwriting the full app-managed `config.yaml`. This has been fixed so provider blocks survive prepare, reload, and restart paths.
- The management endpoint `http://127.0.0.1:8787/v0/management/config` has been manually verified to return `200 OK` when the runtime is launched with the current SurProxy config and management key.
- Repeated console noise for `Could not connect to the server` against `/v0/management/config` was caused by health probing before the runtime socket was listening. The probe now checks TCP reachability first and only issues HTTP once the port is open.
- A tray-opening crash caused by touching `NSApp` too early in `App.init()` was fixed by moving activation policy setup into `applicationDidFinishLaunching`.
- Tray reopening previously created multiple main windows; this was fixed by switching the main scene from `WindowGroup` to a single `Window`.
- Menu bar opening now defers `openWindow` and `NSApp.activate` to the next main-thread turn to avoid AppKit layout recursion warnings while the menu is still collapsing.
- Provider save behavior previously looked stale because UI toggles were reading old per-model state instead of the provider's selected model set. The provider model rows are now rendered from the provider's selected models, and save completion rereads provider state from management APIs.

## Remaining Work

- expose runtime logs in the UI instead of only surfacing them through thrown errors
- implement binary download/update/rollback flow for newer upstream releases
- add native config editing through upstream management endpoints such as `/v0/management/config.yaml`
- expand auth file details and editing support beyond toggle state
