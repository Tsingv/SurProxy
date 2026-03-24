Place the compiled `CLIProxyAPIPlus` release binary here as:

- `cliproxyapiplus`

Expected path inside the app bundle:

- `SurProxy.app/Contents/Resources/Runtime/cliproxyapiplus`

Recommended workflow:

1. Build or download the desired `CLIProxyAPIPlus` binary.
2. Run `Scripts/stage_runtime_binary.sh /path/to/cliproxyapiplus`.
3. Build the macOS app.

At runtime, SurProxy copies the bundled binary into its writable application support runtime directory and launches that copied binary.
