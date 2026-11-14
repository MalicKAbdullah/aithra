/// Counts and timings of one generation, as reported by the engine.
/// A null field was not reported, and is shown as "—", never estimated.
class RunMetrics {
  const RunMetrics({
    this.promptTokens,
    this.prefillMs,
    this.ttftMs,
    this.decodeTokens,
    this.decodeMs,
    this.contextTokens,
    this.peakRssMb,
    this.note,
    this.reusedTokens,
  });

  factory RunMetrics.fromMap(Map<String, Object?> m) => RunMetrics(
    promptTokens: m['promptTokens'] as int?,
    prefillMs: (m['prefillMs'] as num?)?.toDouble(),
    ttftMs: (m['ttftMs'] as num?)?.toDouble(),
    decodeTokens: m['decodeTokens'] as int?,
    decodeMs: (m['decodeMs'] as num?)?.toDouble(),
    contextTokens: m['contextTokens'] as int?,
    peakRssMb: (m['peakRssMb'] as num?)?.toDouble(),
    note: m['note'] as String?,
    reusedTokens: m['reusedTokens'] as int?,
  );

  /// Prompt tokens prefilled by this run; [reusedTokens] more were already
  /// in the engine's kept state for this chat.
  final int? promptTokens;
  final double? prefillMs;
  final double? ttftMs;
  final int? decodeTokens;
  final double? decodeMs;

  /// Tokens the conversation occupies in the KV cache after this run.
  final int? contextTokens;
  final double? peakRssMb;
  final String? note;

  /// Prompt tokens the engine kept from the previous turn and did not
  /// prefill again; 0 when it prefilled the whole prompt.
  final int? reusedTokens;

  double? get prefillTps => tokensPerSecond(promptTokens, prefillMs);
  double? get decodeTps => tokensPerSecond(decodeTokens, decodeMs);

  Map<String, Object?> toJson() => {
    'promptTokens': promptTokens,
    'prefillMs': prefillMs,
    'ttftMs': ttftMs,
    'decodeTokens': decodeTokens,
    'decodeMs': decodeMs,
    'contextTokens': contextTokens,
    'peakRssMb': peakRssMb,
    'note': note,
    'reusedTokens': reusedTokens,
  };
}

/// Tokens per second, or null when either input is missing or zero.
double? tokensPerSecond(int? tokens, double? ms) {
  if (tokens == null || ms == null || tokens <= 0 || ms <= 0) return null;
  return tokens / (ms / 1000);
}
