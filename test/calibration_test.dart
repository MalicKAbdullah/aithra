import 'package:aithra/src/calibration/calibration.dart';
import 'package:aithra/src/calibration/correctness.dart';
import 'package:aithra/src/calibration/report.dart';
import 'dart:async';

import 'package:aithra/src/engine/engine_service.dart';
import 'package:aithra/src/engine/run_metrics.dart';
import 'package:aithra/src/models/catalog.dart';
import 'package:aithra/src/platform/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

BackendResult result(
  String id,
  List<String> answers, {
  double? decodeTps,
  String? error,
}) => BackendResult(
  backendId: id,
  loadMs: 3200,
  loadPeakRssMb: 1900,
  answers: answers,
  error: error,
  speed: decodeTps == null
      ? null
      : RunMetrics(
          promptTokens: 500,
          prefillMs: 1000,
          ttftMs: 1100,
          decodeTokens: 128,
          decodeMs: 128 / decodeTps * 1000,
          peakRssMb: 2100,
        ),
);

/// Loads instantly; every generation reports [cancelled].
class CancellingEngine extends NativeBridge {
  CancellingEngine()
    : super(
        channel: const MethodChannel('fake'),
        events: StreamController<Object?>.broadcast().stream,
      );

  bool cancelled = true;

  @override
  Future<Map<String, Object?>> load({
    required String runtime,
    required String path,
    required String backend,
    required int? threads,
    required bool vision,
    required int? maxTokens,
  }) async => {
    'contextSize': 4096,
    'loadMs': 1.0,
    'peakRssMb': 1.0,
    'cacheWrittenMb': 0.0,
  };

  @override
  Future<Map<String, Object?>> generate({
    required int requestId,
    required List<EngineTurn> turns,
    required int maxTokens,
    required double temperature,
    required bool ignoreEos,
  }) async => {'cancelled': cancelled, 'promptTokens': 10};

  @override
  Future<void> unload() async {}
}

const right = ['42', 'Paris.', 'The answer is 72'];
const wrong = ['<pad><pad>', 'Paris', '7 2'];

void main() {
  group('probes', () {
    test('accept correct answers in common forms', () {
      expect(probes[0].passes('42'), isTrue);
      expect(probes[0].passes('17 + 25 = 42.'), isTrue);
      expect(probes[1].passes('PARIS'), isTrue);
      expect(probes[2].passes('<think>9*8</think>72'), isTrue);
    });

    test('reject wrong or garbled answers', () {
      expect(probes[0].passes('142'), isFalse);
      expect(probes[0].passes('4 2'), isFalse);
      expect(probes[1].passes('Lyon'), isFalse);
      expect(probes[2].passes('<think>72'), isFalse);
    });
  });

  group('pickBackend', () {
    test('fastest correct backend wins', () {
      expect(
        pickBackend([
          result('gpu', wrong, decodeTps: 14),
          result('gpu_fp32', right, decodeTps: 13),
          result('cpu', right, decodeTps: 6),
        ]),
        'gpu_fp32',
      );
    });

    test('with no fully correct backend, most correct then fastest', () {
      expect(
        pickBackend([
          result('gpu', wrong, decodeTps: 14),
          result('cpu', const ['42', 'Paris', 'no'], decodeTps: 6),
        ]),
        'cpu',
      );
    });

    test('failed loads are never chosen', () {
      expect(
        pickBackend([
          result('npu', const [], error: 'dispatch library missing'),
          result('tensor', const [], error: 'unsupported'),
        ]),
        isNull,
      );
    });
  });

  test('calibration round-trips through JSON', () {
    final c = Calibration(
      modelId: 'gemma4-e2b',
      fileSize: 10,
      results: [
        result('gpu', right, decodeTps: 12),
        result('cpu', const [], error: 'x'),
      ],
      chosenBackend: 'gpu',
      finishedAt: DateTime(2026, 11, 13),
    );
    final back = Calibration.fromJson(c.toJson());
    expect(back.chosenBackend, 'gpu');
    expect(back.chosenIsCorrect, isTrue);
    expect(back.results[0].speed!.decodeTps, closeTo(12, 0.001));
    expect(back.results[1].error, 'x');
  });

  test('report has device facts, a row per backend and raw answers', () {
    final report = calibrationReport(
      device: const DeviceFacts({
        'manufacturer': 'Google',
        'model': 'Pixel 8',
        'androidRelease': '17',
        'sdkInt': 37,
        'socManufacturer': 'Google',
        'socModel': 'Tensor G3',
        'totalRamMb': 7680,
        'appVersion': '0.1.0',
        'appBuild': 1,
      }),
      calibrations: [
        Calibration(
          modelId: 'gemma4-e2b',
          fileSize: 1,
          results: [
            result('gpu', wrong, decodeTps: 14),
            result('gpu_fp32', right, decodeTps: 13),
            result('npu', const [], error: 'no NPU'),
          ],
          chosenBackend: 'gpu_fp32',
          finishedAt: DateTime(2026),
        ),
      ],
      modelName: (_) => 'Gemma 4 E2B',
      dbSelfTest: {
        'messages': 10000,
        'insertMs': 900,
        'pageMs': 1.2,
        'searchMs': 3.4,
        'recallMs': 5.6,
      },
    );
    expect(report, contains('Aithra 0.1.0 (1)'));
    expect(
      report,
      contains(
        'Google Pixel 8 · Android 17 (SDK 37) · SoC Google Tensor G3 · RAM 7.5 GB',
      ),
    );
    expect(
      report,
      contains(
        '| Gemma 4 E2B | GPU | 3.20 | 1.10 | 500.0 (500) | 14.0 (128) | 2100 | ✗ 1/3 |  |',
      ),
    );
    expect(
      report,
      contains(
        '| Gemma 4 E2B | GPU (FP32) | 3.20 | 1.10 | 500.0 (500) | 13.0 (128) | 2100 | ✓ 3/3 | ★ |',
      ),
    );
    expect(report, contains('- Gemma 4 E2B / NPU: no NPU'));
    expect(report, contains('42 → "<pad><pad>"'));
    expect(report, contains('search 3.4 ms'));
  });

  group('calibration run', () {
    test('an interrupted run gives no verdict', () async {
      final runner = CalibrationRunner(EngineService(CancellingEngine()));
      final result = await runner.run(
        catalog.first,
        '/m',
        1,
        onProgress: (_, _, _) {},
      );
      expect(result, isNull);
    });

    test('a run that completes gives one result per backend', () async {
      final engine = CancellingEngine()..cancelled = false;
      final spec = catalog.first;
      final result = await CalibrationRunner(
        EngineService(engine),
      ).run(spec, '/m', 1, onProgress: (_, _, _) {});
      expect(result!.results, hasLength(spec.backends.length));
    });
  });
}
