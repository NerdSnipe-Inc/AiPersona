# Testing AiPersona

## Package tests (no model)

`swift test` cannot load MLX's Metal shaders, so run the suite through Xcode's build system:

```sh
cd AiPersona
FORCE_REMOTE_PACKAGES=1 xcodebuild test -scheme AiPersona -destination 'platform=macOS' \
  -derivedDataPath /tmp/aipersona-dd -skipMacroValidation
```

`FORCE_REMOTE_PACKAGES=1` makes `Package.swift` resolve AIChatKit/AIChatKitMLX from GitHub instead of
the sibling checkouts (whose `mlx-swift-lm` folder can be in a broken state). 170 tests, ~3 s.

The parser has a fixture set for hostile model output in
`Tests/AiPersonaTests/Providers/MemoryProviderTests.swift` (fences, thinking prefixes, truncation,
one bad element among good ones, wrapper/bare objects, braces inside strings, 200k-char garbage).

## Live tests against the real model (host app)

`AICompleteChat/AICompleteChatTests/LivePersonaTests.swift` drives AiPersona end-to-end with the real
`mlx-community/gemma-4-e4b-it-4bit` through `MLXProvider` + `ChatSession` + `PersonaChatCoordinator`.
They are skipped (not failed) when the weights are absent from
`~/.cache/huggingface/hub/models--mlx-community--gemma-4-e4b-it-4bit`.

```sh
cd AICompleteChat
scripts/generate-local-project.sh          # wires the sibling packages, needed after adding files
FORCE_REMOTE_PACKAGES=1 xcodebuild test -project AICompleteChat.xcodeproj -scheme AICompleteChat \
  -destination 'platform=macOS' -derivedDataPath /tmp/aicc-dd \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:AICompleteChatTests/LivePersonaTests \
  -only-testing:AICompleteChatTests/PersonaPipelineTests | grep -E "error:|\[live|✘|􁁛|Test run"
```

* `PersonaPipelineTests` — no model: hostile raw output → parser → `IngestionActor` → graph;
  correction / user-edited protection; empty and 2,000-fact retrieval latency; coordinator guards
  (model not ready, empty/busy send, failed turn not ingested); load-failure wording.
* `LivePersonaTests` — extraction from a realistic statement (raw model output is printed as
  `[live/ingest] raw=…`), small talk yields nothing, live correction flow, "Where do I work?"
  end-to-end (asserts the system prompt *and* the answer), persona name/tone, load failure of a
  nonexistent model, and a chat turn started while the previous turn's ingestion is still running.

All live tests use `temperature: 0`, in-memory `MemoryGraphStore(inMemory: true)` and isolated
`UserDefaults` suites — they never touch the real store, Keychain or Notion. Assertions on model text
are deliberately loose (`contains "acme"`), not exact strings. Diagnostics are prefixed `[live/…]`.
A model download is not required for `PersonaPipelineTests`.

If a live assertion fails, read the `[live/ingest] raw=` line first: it is the exact text the model
produced, which tells you whether the model, the parser, or the merge logic is at fault.
