---
title: Long-term memory for iOS and macOS chat apps, on-device, in one Swift package
published: false
description: AiPersona is an MIT-licensed Swift package that extracts facts from chat turns, stores them in a local temporal knowledge graph, and feeds them back into your system prompt.
tags: swift, ios, ai, opensource
---

Most chat apps forget you the moment the session ends. The usual fix is a backend with accounts, a vector database, and a privacy policy. If you ship a small iOS or macOS app, that is a lot to take on for "remember that I prefer short answers."

I built [AiPersona](https://github.com/NerdSnipe-Inc/AiPersona) so the memory can live on the device. It is a Swift Package that pulls facts out of conversations, keeps them in a small local knowledge graph, and hands you prompt fragments that make your next conversation start with context. No server, no account system. User data leaves the device only if you pick an external LLM provider.

It is a from-scratch Swift reimplementation of the cognitive core of [synapse-cortex](https://github.com/juandastic/synapse-cortex): a temporal knowledge graph, hybrid BM25 plus embedding retrieval, and LLM-driven fact extraction and correction. synapse-cortex is a multi-tenant FastAPI server. AiPersona is single-user and embedded.

## What it does

It is headless. It stores and retrieves memory, and it does not run your chat loop. Your app keeps its own UI, its own LLM call, and its own tool-use instructions. AiPersona gives you three things:

1. Extraction. After each turn, a `MemoryProvider` turns the conversation into structured facts.
2. Storage. Facts go into a SwiftData-backed graph of entities, episodes, and fact edges.
3. Retrieval. Before the next turn, you ask for a memory block and paste it into your system prompt.

```swift
// After a turn
let episode = ChatEpisode(userText: "I prefer short answers", assistantText: "Got it.", occurredAt: .now)
let result = await IngestionActor.shared.enqueue(episode, provider: someMemoryProvider, store: .shared)

// Before the next one
let retrieval = RetrievalService.shared
let compilation = retrieval.sessionCompilation()
let topUp = retrieval.perTurnMemoryBlock(forQuery: userMessage, excluding: compilation)

let systemPrompt = PersonaPromptBuilder.identityPreamble(name: "Nova", personality: "Warm, witty, and to the point.")
    + "\n\n" + yourAppsOwnInstructions
    + PersonaPromptBuilder.memorySection(compilation + (topUp.map { "\n" + $0 } ?? ""))
```

`sessionCompilation()` returns the most recent 20 active facts and caches them for the session. `perTurnMemoryBlock` runs a hybrid search for anything relevant that the compilation missed, and returns `nil` when there is nothing to add.

## Facts are never deleted

Every fact is a bi-temporal edge with a `validAt` and an `invalidAt`. When a user corrects something, the old fact gets an `invalidAt` timestamp. Nothing is removed, so `allFacts()` can always reconstruct what the app believed and when.

Corrections are conservative on purpose. A correction rarely shares a predicate with the fact it fixes ("wants" becomes "no longer wants"), so matching on predicate strings does not work. AiPersona matches by cosine similarity instead, and when there is no clear subject-object pair it invalidates only the single closest active fact above a similarity threshold. It would rather miss a correction than wipe an unrelated fact. `invalidateFacts` returns a `Bool`, so your app can say "I'm not sure what to update" instead of silently doing nothing.

If a person hand-edited a fact, `enqueue` will not overwrite it automatically. It returns a `PendingCorrection` that pairs the proposed change with the live fact, and your UI decides whether to accept or discard.

## Things I found by running it

**Word embeddings cannot match names.** Local embeddings come from `NLEmbedding.wordEmbedding(.english)`, which has no coverage for proper nouns. When I tested it, cosine similarity between two names was always 0. So entity resolution does not use embeddings. `EntityNameMatcher` does deterministic token-subset and initials matching, which maps "Juan" onto "Juan Gómez" and "JG" onto the same node. A fuzzy match is stored as an alias, so the original spelling survives.

**Small models deny having memory.** If the system prompt does not say the model has persistent memory, an on-device model will tell the user it cannot remember anything the moment they say "remember X", even before a fact has been extracted. `PersonaPromptBuilder.identityPreamble` states it unconditionally.

**Models are inconsistent about who "the user" is.** In live testing, gemma alternated between "Sam" and "the user" for the same person, so a later correction could not find facts stored under the other name. `IngestionActor` now maps the "the user" stand-in to a host-supplied `knownUserName`.

**Model output is messy.** The extraction parser scans for balanced JSON objects instead of trusting a `[...]` substring. A stray `[` in a preamble, a truncated reply, or one malformed element no longer costs you every fact in the response. It also handles code fences and `<think>` blocks.

## Providers

Extraction and chat generation are selected independently between on-device MLX, Gemini, OpenAI, and Anthropic.

```swift
MemorySettingsStore.shared.selectExtractionProvider(.gemini)
MemorySettingsStore.shared.selectChatProvider(.local)
MemorySettingsStore.shared.setAPIKey("...", for: .gemini)
```

All memory embeddings come from the same on-device `LocalEmbedder`, whichever provider does the extraction. The whole graph shares one embedding space, so hybrid search still makes sense after the user switches providers. Anthropic has no embeddings API, which is part of why I did it this way. API keys live in the Keychain through a small wrapper that has no dependency on your app's own Keychain code. If a selected external provider has no key, extraction falls back to local rather than failing the pipeline.

## Extras

- Notion export and correction import. Export creates a Notion database with one page per active fact. A user can tick "Needs Review" and write a correction in Notion, and the import routes it through the same ingestion path as a chat correction.
- Graph visualization export, as `react-force-graph`-shaped JSON.
- Gemini context caching, so repeated turns in a session stop resending the full compilation.

These are direct REST calls from the device. No backend is needed for any of them.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/NerdSnipe-Inc/AiPersona.git", from: "1.1.1"),
],
targets: [
    .target(name: "YourApp", dependencies: ["AiPersona"]),
]
```

It needs Swift 5.10, iOS 17 or macOS 14, and depends on [AIChatKit](https://github.com/NerdSnipe-Inc/AIChatKit) and [AIChatKitMLX](https://github.com/NerdSnipe-Inc/AIChatKitMLX). The package ships 170 tests that run in about 3 seconds without a model. [`docs/ARCHITECTURE.md`](https://github.com/NerdSnipe-Inc/AiPersona/blob/master/docs/ARCHITECTURE.md) covers the concurrency model and a `log stream` recipe for debugging extraction.

## See it working

[AICompleteChat](https://github.com/NerdSnipe-Inc/AICompleteChat) is a full-source macOS chat app that uses AiPersona for its memory. It runs `gemma-4-e4b-it-4bit` through MLX, so after the first launch downloads the model, everything works offline. Set your name once and it becomes a fact in the graph. Then open Settings, Memory, Browse memory to see what it extracted, correct it, or delete it. If you only want to try it, download the signed, notarized build from the [latest release](https://github.com/NerdSnipe-Inc/AICompleteChat/releases/latest), unzip, and run it. It needs macOS 15 and an Apple Silicon Mac. If you want to read how the pieces connect, `Engine/AppEnvironment.swift` is the place to start. Building from source requires a [DesignFoundationPro](https://nerdsnipe.cc/design-foundation-pro) license, because the UI is assembled from it, but the source is public and readable without one.

AiPersona is MIT licensed. If you try it, I want to hear where the extraction or correction matching breaks for you, so open an issue. If it saves you time, [sponsoring NerdSnipe Inc](https://github.com/sponsors/NerdSnipe-Inc) pays for the fixes and releases.

Repo: https://github.com/NerdSnipe-Inc/AiPersona
