/// Which inference runtime runs a model file.
enum Runtime {
  /// LiteRT-LM (`.litertlm`), Google's on-device runtime for Gemma.
  litertlm,

  /// llama.cpp (`.gguf`) on the CPU.
  llamacpp;

  static Runtime forFileName(String name) =>
      name.toLowerCase().endsWith('.gguf') ? llamacpp : litertlm;
}

/// One way of running a model: a runtime backend plus its settings.
class BackendOption {
  const BackendOption(this.id, this.label, {this.threads});

  /// Sent to native code: `cpu`, `gpu`, `gpu_fp32`, `npu`, `tensor`,
  /// or `cpu4`/`cpu6` for llama.cpp.
  final String id;
  final String label;

  /// llama.cpp thread count; null for LiteRT-LM.
  final int? threads;

  /// The id native code understands (llama.cpp's backends are all `cpu`).
  String get nativeId => threads == null ? id : 'cpu';

  static const cpu = BackendOption('cpu', 'CPU');
  static const gpu = BackendOption('gpu', 'GPU');
  static const gpuFp32 = BackendOption('gpu_fp32', 'GPU (FP32)');
  static const npu = BackendOption('npu', 'NPU');
  static const tensor = BackendOption('tensor', 'Tensor NPU');
  static const cpu4 = BackendOption('cpu4', 'CPU · 4 threads', threads: 4);
  static const cpu6 = BackendOption('cpu6', 'CPU · 6 threads', threads: 6);

  static const all = [cpu, gpu, gpuFp32, npu, tensor, cpu4, cpu6];

  static BackendOption byId(String id) => all.firstWhere((b) => b.id == id);
}

/// What a model is for.
enum ModelKind {
  /// Answers in chats.
  chat,

  /// Turns text into vectors for recall across chats.
  embedding,
}

/// A model Aithra knows how to download and run.
class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.name,
    required this.summary,
    required this.url,
    required this.fileName,
    required this.sha256,
    required this.sizeBytes,
    required this.runtime,
    required this.backends,
    required this.vision,
    required this.contextTokens,
    this.recommended = false,
    this.experimental = false,
    this.kind = ModelKind.chat,
  });

  final String id;
  final String name;
  final String summary;
  final String url;
  final String fileName;

  /// SHA-256 of the published file, checked when a download finishes;
  /// null for imported files.
  final String? sha256;
  final int sizeBytes;
  final Runtime runtime;

  /// Candidates tried by auto-calibration, in order.
  final List<BackendOption> backends;

  /// Accepts images.
  final bool vision;

  /// KV-cache size requested at load; null keeps the size compiled into the
  /// model (required for the Tensor NPU bundles).
  final int? contextTokens;
  final bool recommended;
  final bool experimental;
  final ModelKind kind;

  /// A model the user imported from a file: run with the backends its
  /// runtime supports.
  factory ModelSpec.imported(String fileName, int size) {
    final runtime = Runtime.forFileName(fileName);
    return ModelSpec(
      id: 'file:$fileName',
      name: fileName.split('/').last,
      summary: 'Imported from a file',
      url: '',
      fileName: fileName,
      sha256: null,
      sizeBytes: size,
      runtime: runtime,
      backends: runtime == Runtime.llamacpp
          ? const [BackendOption.cpu4, BackendOption.cpu6]
          : const [BackendOption.gpu, BackendOption.gpuFp32, BackendOption.cpu],
      vision: false,
      contextTokens: 4096,
    );
  }
}

const _hf = 'https://huggingface.co';

/// Models offered in the app, pinned to a repository commit so the bytes,
/// size and SHA-256 cannot change under a download. Sizes are the exact
/// Hugging Face file sizes, used to tell a finished file from a partial one.
const List<ModelSpec> catalog = [
  ModelSpec(
    id: 'gemma4-e2b',
    name: 'Gemma 4 E2B',
    summary: 'Best balance of speed and quality. Understands images.',
    url:
        '$_hf/litert-community/gemma-4-E2B-it-litert-lm/resolve/2d74ac41a33d7da82f39f7d5720a04c68514a103/gemma-4-E2B-it.litertlm',
    fileName: 'gemma-4-E2B-it.litertlm',
    sha256: '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
    sizeBytes: 2588147712,
    runtime: Runtime.litertlm,
    backends: [BackendOption.gpu, BackendOption.gpuFp32, BackendOption.cpu],
    vision: true,
    contextTokens: 4096,
    recommended: true,
  ),
  ModelSpec(
    id: 'gemma4-e4b',
    name: 'Gemma 4 E4B',
    summary: 'Smarter, slower, needs more memory. Understands images.',
    url:
        '$_hf/litert-community/gemma-4-E4B-it-litert-lm/resolve/f254b5ba6e36f7d89cc7892e268e9877bc20f0a0/gemma-4-E4B-it.litertlm',
    fileName: 'gemma-4-E4B-it.litertlm',
    sha256: '0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0',
    sizeBytes: 3659530240,
    runtime: Runtime.litertlm,
    backends: [BackendOption.gpu, BackendOption.gpuFp32, BackendOption.cpu],
    vision: true,
    contextTokens: 4096,
  ),
  ModelSpec(
    id: 'gemma3-1b-g3-npu',
    name: 'Gemma 3 1B · Pixel 8 NPU',
    summary: 'Community build for the Tensor G3 NPU. Text only.',
    url:
        '$_hf/litert-community/Gemma3-1B-IT-Tensor-NPU/resolve/1e14d0b91070f0fab29071364412299b688e5b68/Gemma3-1B-IT_int4hadamard_aot_ekv4096_G3.litertlm',
    fileName: 'Gemma3-1B-IT_int4hadamard_aot_ekv4096_G3.litertlm',
    sha256: '43f1b935cc24fb2e636f3ef910ad02ee838cebe2393900da3d2a629ffd091c3e',
    sizeBytes: 874631968,
    runtime: Runtime.litertlm,
    backends: [BackendOption.npu, BackendOption.tensor],
    vision: false,
    contextTokens: null,
    experimental: true,
  ),
  ModelSpec(
    id: 'qwen35-2b-q4',
    name: 'Qwen 3.5 2B',
    summary: 'Runs on llama.cpp. Text only.',
    url:
        '$_hf/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_0.gguf',
    fileName: 'Qwen3.5-2B-Q4_0.gguf',
    sha256: 'cd70221bebaee0503e0f6717e174250cd7825aa88438b3aabec9ad55731d9bb1',
    sizeBytes: 1214873856,
    runtime: Runtime.llamacpp,
    backends: [BackendOption.cpu4, BackendOption.cpu6],
    vision: false,
    contextTokens: 4096,
    experimental: true,
  ),
  ModelSpec(
    id: 'gemma3-1b-q4',
    name: 'Gemma 3 1B',
    summary: 'Small and quick on llama.cpp. Text only.',
    url:
        '$_hf/unsloth/gemma-3-1b-it-GGUF/resolve/f0b45be0aac41bd6a100a4b5734cad5f67255bfb/gemma-3-1b-it-Q4_0.gguf',
    fileName: 'gemma-3-1b-it-Q4_0.gguf',
    sha256: '27ee88e03be02e9ba73def9a819d570d8ad73716e50769e87f374ae394b0276e',
    sizeBytes: 721918496,
    runtime: Runtime.llamacpp,
    backends: [BackendOption.cpu4, BackendOption.cpu6],
    vision: false,
    contextTokens: 4096,
    experimental: true,
  ),
];

ModelSpec get defaultModel => catalog.firstWhere((m) => m.recommended);

/// The optional model behind "Memory across chats": EmbeddingGemma, run by
/// llama.cpp in embedding mode. Without it, cross-chat recall is off.
const ModelSpec embeddingModel = ModelSpec(
  id: 'embeddinggemma-300m',
  name: 'Memory across chats',
  summary:
      'Lets Aithra bring up related things from your other chats. '
      'EmbeddingGemma, runs on this phone.',
  url:
      '$_hf/ggml-org/embeddinggemma-300M-GGUF/resolve/0f741b5a6585bd53aeb15cd1372c56f2a0f65e12/embeddinggemma-300M-Q8_0.gguf',
  fileName: 'embeddinggemma-300M-Q8_0.gguf',
  sha256: 'b5ce9d77a3fc4b3b39ccb5643c36777911cc4eb46a66962eadfa3f5f60490d63',
  sizeBytes: 333590944,
  runtime: Runtime.llamacpp,
  backends: [BackendOption.cpu4],
  vision: false,
  contextTokens: 2048,
  kind: ModelKind.embedding,
);
