# Aithra

A private AI assistant for Android that runs entirely on the phone. Part of
the Offlyne family.

- **Chat** with streaming Markdown replies, conversation list (search, pin,
  rename, delete), stop, regenerate, edit last message, copy/share.
- **Images** from the system photo picker or camera, answered by Gemma 4.
- **Voice**: dictation with Android's on-device `SpeechRecognizer`, and a
  hands-free voice mode that answers with Android `TextToSpeech`.
- **Memory**: per-chat summaries when a conversation outgrows the model's
  context, cross-chat recall from an encrypted keyword index, and a
  Memories screen of saved facts.
- **Auto-calibration**: after a model downloads, Aithra tests each backend
  (GPU, GPU FP32, CPU, NPU, llama.cpp threads) for correctness and speed and
  uses the fastest correct one. Results: Settings → Performance.

## Engines

| Runtime | Version | Used for |
|---|---|---|
| LiteRT-LM (`com.google.ai.edge.litertlm:litertlm-android`) | 0.19.1 | `.litertlm` models: Gemma 4 E2B/E4B on CPU/GPU, Tensor NPU builds |
| LiteRT NPU runtime (`litert-npu-runtime-google-tensor`) | 2.3.2 | Google Tensor NPU dispatch library |
| llama.cpp (CMake FetchContent, tag) | b11935 | `.gguf` models on the CPU (arm64, dotprod + i8mm) |

## Privacy

The only network access is downloading model files from Hugging Face through
Android's DownloadManager. Chats, images and the keyword index live in
SQLite, with every text and image AES-256-GCM encrypted; settings and
memories are core_crypto vault files. The data key is held by core_storage
(Android Keystore). App lock is core_lock. Cloud backup is disabled.

## Build

```sh
flutter pub get
flutter build apk --release --target-platform android-arm64
```

Releases: push a `v*` tag; `.github/workflows/release.yml` builds
`aithra-<version>-arm64-v8a.apk`, signed when the `KEYSTORE_BASE64`,
`KEYSTORE_PASSWORD`, `KEY_ALIAS` and `KEY_PASSWORD` secrets exist.
