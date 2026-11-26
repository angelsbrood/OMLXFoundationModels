# OMLXFoundationModels

Foundation Models, served from your Mac.

`OMLXLanguageModel` is a `LanguageModel` for the Foundation Models framework
backed by an [oMLX](https://github.com/jundot/omlx) server. Hand it to
`LanguageModelSession` and a model running on your Mac answers. Streaming,
reasoning, tools, images and `@Generable` output work the way they do with
the on-device model, and swapping back to `SystemLanguageModel` is one line.

```swift
import FoundationModels
import OMLXFoundationModels

let model = OMLXLanguageModel(
    name: "Qwen3.8-27B-oQ4e-mtp",
    url: URL(string: "http://my-mac.local:8000/v1")!,
    apiKey: apiKey // read from the Keychain
)
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "Hello!")
```

Built at Moon.

## The package

Swift package at the repo root; product `OMLXFoundationModels`; iOS, macOS and
visionOS 27+; no dependencies.

It's a fork of `ChatCompletionsLanguageModel` from Apple's
[foundation-models-utilities](https://github.com/apple/foundation-models-utilities)
1.1.0, kept as one file shaped like the original so Apple's updates can be
merged in by hand. Every change is marked with an `oMLX:` comment, and
Apple's tests are ported alongside new ones for the fork's behavior.

## What the fork changes

| Foundation Models | Upstream sends | This fork sends to oMLX |
|---|---|---|
| `apiKey:` | — (headers only) | `Authorization: Bearer <key>` |
| `ContextOptions.reasoningLevel` | ignored | `.light` → `reasoning_effort: "low"`, `.moderate` → `"medium"`, `.deep` → `"high"`, `.custom(x)` → `x`; `.custom("none")` → `enable_thinking: false` |
| `.greedy` sampling | `top_p: 0` (oMLX reads this as "off") | `temperature: 0` |
| `.random(top:seed:)` | throws | `top_k`, `seed` |
| `.random(probabilityThreshold:seed:)` | throws if seeded | `top_p`, `seed` |
| `@Generable` / schemas | `response_format`, which oMLX quietly stops enforcing if it can't compile the schema | `structured_outputs`, which fails with an error instead; the schema is also described in the latest user message unless `includeSchemaInPrompt` is `false` |
| `@Generable`, with `structuredOutput: .afterReasoning` | — | no grammar: the schema is described in the latest user message, the model reasons, and the JSON is read from its answer. A request with reasoning off gets the grammar |
| Context overflow | `RequestError.httpError` | `LanguageModelError.contextSizeExceeded` with the token counts |
| 429, or 503 when the queue is full | `RequestError.httpError` | `LanguageModelError.rateLimited`, with `resetDate` from `Retry-After` |
| `session.prewarm()` | no-op | one-token request that loads the model and caches the instructions and tools |
| Keep-alive chunks | appended as empty text | skipped |
| Blank lines after the thinking block | kept at the start of the response | dropped, so text starts with the first visible character |

It also copies oMLX's timing into each response's metadata, under
`OMLXLanguageModel.MetadataKey`: `model`, `timeToFirstToken`,
`promptTokensPerSecond` and `generationTokensPerSecond`.

```swift
let speed = try? response.metadata[OMLXLanguageModel.MetadataKey.generationTokensPerSecond]?
    .value(Double.self)
```

## Things to know about oMLX

- **Reasoning levels are the model's to interpret.** Qwen3.8's chat template
  accepts `low`, `medium` and `xhigh` (its default), so `.deep` lands on the
  same `xhigh` as passing no level. The template puts the level in the system
  prompt, so changing it mid-conversation means oMLX re-reads the whole
  history.
- **Inkling 2 skips its reasoning under a grammar.** At every reasoning
  level it goes straight to the constrained answer, and the answer suffers:
  asked whether 1,001 is prime, it said yes, with the field's guide copied in
  as the reason. Qwen3.8 thinks first. For Inkling, create the model with
  `structuredOutput: .afterReasoning`; it then reasons as usual and gets the
  answer right. Its reasoning streams, and the answer arrives once it's done.
- **Inkling 2 always thinks.** Its chat template doesn't turn thinking off, so
  `.custom("none")` has no effect on it.
- **Structured output turns off Lightning MTP.** Grammar-constrained decoding
  doesn't use MTP speculation, so `@Generable` requests run at plain decode
  speed.
- **`toolCallingMode: .required` isn't enforced.** It's sent as
  `tool_choice: "required"`, but oMLX's chat path only acts on `"none"`.
- **Requests share oMLX's slots** with every other client of the server.

## The demo

`OMLXDemo/` is a small SwiftUI chat app for iOS 27 that switches one session
between the Mac (oMLX) and Apple Intelligence on the iPhone. It shows the
model's thinking in a disclosure and oMLX's speed under each answer.

1. Open `OMLXDemo/OMLXDemo.xcodeproj` and choose your team under Signing &
   Capabilities.
2. In the simulator the default server, `http://localhost:8000/v1`, reaches
   oMLX on the same Mac. On an iPhone, set it in the app's Settings to the
   Mac's Bonjour name, like `http://name.local:8000/v1`
   (System Settings › General › Sharing shows it).
3. Paste an oMLX API key in Settings. It's kept in the Keychain.

oMLX needs to listen on the network (Host `0.0.0.0`), and the Mac needs to
stay awake.

## Networking on iPhone

- Use the Mac's `.local` name or its IP address. Names like `Mac.lan` aren't
  covered by App Transport Security's local-networking exception.
- Add `NSAppTransportSecurity › NSAllowsLocalNetworking = YES` and an
  `NSLocalNetworkUsageDescription` to the app's Info.plist.
- For use away from home, put the server behind HTTPS, for example with
  `tailscale serve`.

## Keys

An API key passed to `OMLXLanguageModel` is for development against your own
server. Make a dedicated API-only key in oMLX for each app so you can revoke
it on its own, keep it in the Keychain, and never put it in source, an
Info.plist, an `.xcconfig` or a bundled resource. An app you distribute
shouldn't hold a key at all; route requests through a backend that verifies
the app with App Attest.

## Tests

Open `Package.swift` in Xcode and choose Product › Test, or run `swift test`.
Live tests run against a real server when `OMLX_TEST_ENDPOINT` is set:

```
OMLX_TEST_ENDPOINT=http://127.0.0.1:8000/v1 OMLX_TEST_API_KEY=<key> swift test --filter Live
```

`OMLX_TEST_MODEL` picks the model. To keep the key out of your scheme, set
`OMLX_TEST_KEYCHAIN_SERVICE` to a Keychain item's service instead; its account
is the endpoint's `host:port`.

## License

Apache License 2.0; see `LICENSE.txt`. Based on work © Apple Inc. and the
Foundation Models project authors.
