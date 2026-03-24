# SurProxy Agent Notes

## Project Goal

SurProxy is a native macOS wrapper around `CLIProxyAPIPlus`.

The product boundary is:

- `CLIProxyAPIPlus` remains the source of truth for proxy serving, OAuth flows, auth file management, config semantics, and management APIs.
- SurProxy is the native macOS host and control plane.
- SurProxy should not reimplement upstream OAuth logic, token formats, or provider-specific auth behavior.

## Upstream Dependency

- Upstream source is vendored as git submodule: `Vendor/CLIProxyAPIPlus`
- Current pinned tag: `v6.9.1-0`
- Purpose of the submodule:
  - inspect upstream capabilities and API contracts
  - optionally build local runtime binaries during development
  - track management endpoints and config behavior

Important upstream APIs currently used by SurProxy:

- `/v0/management/config`
- `/v0/management/config.yaml`
- `/v0/management/latest-version`
- `/v0/management/auth-files`
- `/v0/management/auth-files/models`
- `/v0/management/auth-files/status`
- `/v0/management/api-keys`
- `/v0/management/model-definitions/:channel`
- `/v0/management/gemini-api-key`
- `/v0/management/claude-api-key`
- `/v0/management/codex-api-key`
- `/v0/management/openai-compatibility`
- `/v0/management/vertex-api-key`
- `/v0/management/codex-auth-url`
- `/v0/management/anthropic-auth-url`
- `/v0/management/gemini-cli-auth-url`
- `/v0/management/gitlab-auth-url`
- `/v0/management/antigravity-auth-url`
- `/v0/management/qwen-auth-url`
- `/v0/management/kilo-auth-url`
- `/v0/management/kimi-auth-url`
- `/v0/management/iflow-auth-url`
- `/v0/management/kiro-auth-url`
- `/v0/management/github-auth-url`
- `/v0/management/get-auth-status`
- upstream auth-files response shape is defined in `Vendor/CLIProxyAPIPlus/internal/api/handlers/management/auth_files.go`

## Current Architecture

### macOS app

- App entry: `SurProxy/SurProxyApp.swift`
- Main UI: `SurProxy/ContentView.swift`
- View model: `SurProxy/AppViewModel.swift`
- Service boundary: `SurProxy/ProxyService.swift`

### Runtime coordination

- Runtime paths: `SurProxy/RuntimePaths.swift`
- Runtime manifest: `SurProxy/RuntimeManifest.swift`
- Runtime process management: `SurProxy/RuntimeManager.swift`
- Management API client: `SurProxy/ManagementAPIClient.swift`

### Current auth-file integration behavior

- Primary source: `GET /v0/management/auth-files`
- SurProxy parses the real upstream response shape rather than a guessed subset
- Current fields recognized include:
  - `id`
  - `auth_index`
  - `name`
  - `type`
  - `provider`
  - `label`
  - `status`
  - `status_message`
  - `disabled`
  - `unavailable`
  - `runtime_only`
  - `source`
  - `size`
  - `email`
  - `account_type`
  - `account`
  - `created_at`
  - `modtime`
  - `updated_at`
  - `last_refresh`
  - `next_retry_after`
  - `path`
  - `id_token`
  - `priority`
  - `note`
- Fallback source: direct scan of `~/.cli-proxy-api/*.json` when management API returns an empty list or parsing yields no usable auth entries
- This fallback exists because empty UI state is worse than partial local visibility when the runtime API shape drifts or returns incomplete data
- For model lists under each OAuth card:
  - primary source: `GET /v0/management/auth-files/models?name=...`
  - secondary source: dynamic probing of `GET /v0/management/model-definitions/:channel`
  - channel probing is derived from auth-provided identifiers such as `provider`, `type`, `id`, `account_type`, filename, and email prefix
  - do not reintroduce a hardcoded provider-to-channel mapping table unless upstream makes dynamic resolution impossible and the user explicitly approves that tradeoff

### Packaged runtime

- Bundled binary name: `cliproxyapiplus`
- App bundle resource path in practice: `SurProxy.app/Contents/Resources/cliproxyapiplus`
- Active runtime location: `~/Library/Application Support/SurProxy/runtime/cliproxyapiplus`

### Config and auth locations

This is the current intended split:

- SurProxy-managed runtime config: `~/Library/Application Support/SurProxy/config.yaml`
- SurProxy manifest: `~/Library/Application Support/SurProxy/runtime-manifest.json`
- Shared auth directory: `~/.cli-proxy-api/`

Important: only the auth directory is shared with upstream defaults.
The runtime config is intentionally app-managed to avoid conflicts with a user's existing `~/.cli-proxy-api/config.yaml`.

## Runtime Logic

### Startup flow

On app startup:

1. Resolve runtime paths.
2. Load or bootstrap runtime manifest.
3. Ensure bundled runtime exists and copy it to the writable runtime location if needed.
4. Ensure the SurProxy-managed config contains current manifest-owned values without deleting existing provider configuration.
5. Start the active `CLIProxyAPIPlus` binary if not already started in this app session.
6. Wait for the management API to become healthy.
7. Load runtime snapshot data from management endpoints.

### Why config is app-managed

This was an important correction during development.

Using `~/.cli-proxy-api/config.yaml` directly caused real failures because:

- users may already have an existing config with a different port
- users may already have different remote-management settings
- SurProxy was assuming its own generated management key and port

That mismatch produced connection errors such as:

- `NSURLErrorDomain Code=-1004`
- connection refused to `http://127.0.0.1:8787/v0/management/config`

The fix was:

- keep auth files in `~/.cli-proxy-api/`
- keep SurProxy runtime config separate and fully controlled by SurProxy

There was a later follow-up correction:

- SurProxy must not overwrite the whole app-managed `config.yaml` during prepare/start/reload
- provider blocks written through upstream management APIs must be preserved
- current `RuntimeManager.ensureConfig` only upserts the fields SurProxy owns

### Runtime install and reinstall

`Install Bundled Runtime` is intended to be a forced reinstall operation.

Current behavior:

1. Stop runtime
2. Remove active binary
3. Copy bundled binary to active location
4. Mark source as bundled in manifest
5. Rewrite config
6. Start runtime
7. Wait for health before returning control to UI

### Process handling

One important runtime bug already fixed:

- `CLIProxyAPIPlus` stdout/stderr was previously piped but never consumed
- that could block the child process when pipe buffers filled

Current logic consumes runtime output continuously and keeps a rolling recent log buffer in memory.

One additional runtime behavior to remember:

- `RuntimeManager.ensureConfig` runs during runtime preparation
- it keeps port, auth-dir, and management key aligned with the manifest
- it must preserve existing provider configuration and other non-owned config blocks

One additional startup sequencing fix already applied:

- SurProxy previously used `URLSession` to call `/v0/management/config` even before the runtime socket was listening
- that produced noisy `NSURLErrorDomain Code=-1004` connection-refused logs during startup
- `ManagementAPIClient.healthCheck` now first checks local TCP reachability for the target host and port, then issues the HTTP request only after the port is open

## OAuth Integration Boundary

OAuth is provided by `CLIProxyAPIPlus`, not SurProxy.

SurProxy currently does:

- call upstream `*-auth-url` endpoints
- open the returned auth URL in the browser
- poll `get-auth-status`
- refresh auth file state after completion

SurProxy now also supports native prompt sheets for upstream login flows that need extra input before the request can be started:

- GitLab:
  - OAuth mode with `client_id`, optional `client_secret`, and optional `base_url`
  - PAT import mode using upstream `POST /v0/management/gitlab-auth-url`
- iFlow:
  - browser auth
  - cookie import mode using upstream `POST /v0/management/iflow-auth-url`
- Kiro:
  - browser-oriented social login selection for Google or GitHub
  - do not silently default the UI to the AWS Builder ID device-code flow, because that requires a different UX than the current browser-first login path

SurProxy should continue to avoid:

- implementing provider OAuth flows itself
- storing provider tokens in a SurProxy-specific format
- duplicating upstream auth management rules

## UI State

Current UI sections:

- runtime status and actions
- runtime binary info
- OAuth login buttons
- OAuth file list
- provider routing summary
- API Key management for downstream callers
- left sidebar category navigation: `Status`, `OAuth`, `Provider`

Current actions exposed:

- Start
- Stop
- Reload Config
- Install Bundled Runtime
- Login Codex
- Login Anthropic
- Login Gemini
- Login GitLab
- Login Antigravity
- Login Qwen
- Login Kilo
- Login Kimi
- Login iFlow
- Login Kiro
- Login GitHub Copilot
- toggle auth file active/inactive
- add provider entries through upstream `config.yaml` management
- add, copy, and delete downstream API keys through upstream `/v0/management/api-keys`

Current display behavior:

- OAuth files prefer upstream management API state when available
- if the management API path fails, SurProxy still shows locally discovered auth files from disk
- each OAuth card can show copyable model IDs from upstream
- OAuth cards are rendered in an adaptive multi-column grid based on available window width
- model lists use a collapsed disclosure style by default to reduce vertical space
- provider cards are also rendered in an adaptive grid
- provider model lists are loaded lazily when a provider disclosure group is expanded
- provider model toggles render from the provider's selected model set, not from a stale per-row cache bit
- provider cards still expose the model disclosure even when zero models are currently enabled, so expanding can refresh the live catalog
- deprecated provider models that remain configured but disappear from the live remote catalog should stay visible and be marked as deprecated
- the main window is now a single `Window`, not a `WindowGroup`
- the app stays alive in the menu bar after the main window is closed
- the tray menu can reopen the main window, toggle service start/stop, and quit the app
- provider cards support add, rename where upstream allows it, delete with confirmation, and model selection persistence through management APIs
- provider summary depends on the real upstream config and management APIs, so if provider entries disappear after reload it usually indicates config was overwritten rather than a UI-only problem
- provider enabled-model state should come from management APIs rather than direct config file reads in the UI layer
- provider model saves should reread provider state from management APIs immediately after write completion instead of relying on arbitrary delays
- after provider model saves succeed, the app shows a short-lived floating notice instead of a persistent inline message because the final upstream-visible state may still settle shortly after the write; users can re-expand the model list to refresh on demand
- API Keys are managed as a plain upstream string list; when appending a key through `PATCH /v0/management/api-keys`, the request must include both `old` and `new` because upstream rejects a payload that only includes `new`

### Provider mutation details

- `openai-compatibility`, `claude-api-key`, `codex-api-key`, and `vertex-api-key` provider model saves currently use per-entry `PATCH`
- `gemini-api-key` still uses grouped `PUT` for model changes because upstream patch support does not expose equivalent `models` behavior there
- after provider writes complete, SurProxy refreshes provider state from management APIs and then refreshes the whole app snapshot
- UI mutations use a global loading overlay while API calls are in flight

## Important macOS Packaging Decision

App Sandbox is disabled for this target.

This is intentional and necessary for the current product design because SurProxy needs to:

- launch and manage a bundled local runtime binary
- access localhost management APIs
- read and write `~/.cli-proxy-api/`

Keeping App Sandbox enabled caused real failures such as:

- `NSPOSIXErrorDomain Code=1 "Operation not permitted"`
- localhost requests blocked on `lo0`

If sandboxing is reconsidered later, the product architecture will need to change substantially.

## Known Current Constraints

- Runtime state tracking is currently tied to the `Process` launched by this app session; it is not yet a full external process supervisor.
- Runtime update flow for downloading and switching to newer upstream binaries is not complete.
- The UI does not yet expose the in-memory recent runtime log buffer.
- Provider routing UI is still a lightweight summary mapped from management config, not a full native config editor.
- Provider routing toggles are intentionally not persisted yet; pretending they work would be incorrect.
- `Reload Config` currently means: rewrite SurProxy-managed config if needed and refresh management snapshot. It is not a dedicated upstream reload API integration.
- menu bar interaction is currently implemented with SwiftUI `MenuBarExtra`; if layout-recursion behavior resurfaces, the next escalation path is a lower-level `NSStatusItem` + `NSMenu` implementation

## Build and Packaging Workflow

Relevant scripts:

- `Scripts/build_cliproxy_runtime.sh`
- `Scripts/stage_runtime_binary.sh`

Typical development flow:

1. Build `CLIProxyAPIPlus`
2. Stage the binary into app resources
3. Build the Xcode app
4. Run SurProxy, which copies the runtime into the writable runtime directory on demand

## Verified Behaviors So Far

The following have been verified during development:

- the app builds successfully with `xcodebuild`
- the bundled runtime is copied into the app bundle resources
- the packaged runtime can be launched directly
- management endpoints respond when the runtime is healthy
- `GET http://127.0.0.1:8787/v0/management/config` returns `200 OK` when launched with the current SurProxy-managed config and manifest key
- `codex-auth-url?is_webui=true` returns a valid upstream OAuth URL and state
- auth files exist in `~/.cli-proxy-api/` and upstream runtime logs confirm they are loaded as clients
- SurProxy now has a local disk fallback for auth file visibility even if management auth-file parsing fails
- the main window can be reopened from the tray without creating duplicate main-window instances after switching to a single `Window` scene

## Recommended Next Work

- surface recent runtime log output in the UI
- add stronger startup diagnostics for:
  - bundled runtime missing
  - runtime exited early
  - localhost management API not reachable
  - config mismatch
- implement binary download/update/rollback flow
- expand native UI coverage for auth file details, logs, usage, and config editing
- add explicit diagnostics in UI showing whether auth files came from management API or local fallback
