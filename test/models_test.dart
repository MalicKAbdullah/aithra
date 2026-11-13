import 'package:aithra/src/engine/run_metrics.dart';
import 'package:aithra/src/models/catalog.dart';
import 'package:aithra/src/models/download_state.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadRecord rec(
  int id,
  int status, {
  int reason = 0,
  int done = 0,
  int total = 100,
  String? file,
}) => DownloadRecord(
  id: id,
  fileName: file ?? defaultModel.fileName,
  status: status,
  reason: reason,
  downloaded: done,
  total: total,
);

void main() {
  final spec = defaultModel;
  LocalFile file(int size) =>
      LocalFile(path: '/m/${spec.fileName}', name: spec.fileName, size: size);

  group('availabilityOf', () {
    test('nothing on disk and no download is not downloaded', () {
      expect(availabilityOf(spec, const [], const []), isA<NotDownloaded>());
    });

    test('a running download reports progress', () {
      final a = availabilityOf(
        spec,
        [file(10)],
        [rec(1, DmStatus.running, done: 25, total: 100)],
      );
      expect(a, isA<Downloading>());
      expect((a as Downloading).fraction, 0.25);
      expect(a.waitingReason, isNull);
    });

    test('a paused download says why it waits', () {
      final a = availabilityOf(spec, const [], [
        rec(1, DmStatus.paused, reason: 2),
      ]);
      expect((a as Downloading).waitingReason, 'Waiting for network');
    });

    test('unknown total falls back to the published size', () {
      final a =
          availabilityOf(spec, const [], [rec(1, DmStatus.pending, total: -1)])
              as Downloading;
      expect(a.total, spec.sizeBytes);
    });

    test('a complete file is ready', () {
      final a = availabilityOf(
        spec,
        [file(spec.sizeBytes)],
        [rec(1, DmStatus.successful)],
      );
      expect(a, isA<Ready>());
      expect((a as Ready).path, '/m/${spec.fileName}');
    });

    test('a partial leftover file is not ready', () {
      expect(availabilityOf(spec, [file(5)], const []), isA<NotDownloaded>());
    });

    test('the newest download wins over older failures', () {
      final a = availabilityOf(spec, const [], [
        rec(1, DmStatus.failed, reason: 1004),
        rec(2, DmStatus.running, done: 1),
      ]);
      expect(a, isA<Downloading>());
    });

    test('a failed download explains the failure', () {
      final a = availabilityOf(spec, const [], [
        rec(3, DmStatus.failed, reason: 1006),
      ]);
      expect((a as DownloadFailed).message, 'Not enough storage space');
    });

    test('downloads of other files are ignored', () {
      expect(
        availabilityOf(spec, const [], [
          rec(1, DmStatus.running, file: 'other.gguf'),
        ]),
        isA<NotDownloaded>(),
      );
    });
  });

  test('failure reasons cover HTTP codes', () {
    expect(failureReason(404), 'Server error (HTTP 404)');
    expect(failureReason(1), 'Download failed');
  });

  test('formatBytes', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(874631968), '875 MB');
    expect(formatBytes(2588147712), '2.6 GB');
    expect(formatBytes(12345), '12.3 KB');
  });

  test('imported files pick backends by runtime', () {
    final gguf = ModelSpec.imported('x.gguf', 10);
    expect(gguf.runtime, Runtime.llamacpp);
    expect(gguf.backends.map((b) => b.id), ['cpu4', 'cpu6']);
    final lite = ModelSpec.imported('x.litertlm', 10);
    expect(lite.runtime, Runtime.litertlm);
    expect(lite.backends.first, BackendOption.gpu);
  });

  test('llama.cpp backends map to the native cpu backend', () {
    expect(BackendOption.cpu6.nativeId, 'cpu');
    expect(BackendOption.gpuFp32.nativeId, 'gpu_fp32');
  });

  group('metrics', () {
    test('tokens per second', () {
      expect(tokensPerSecond(256, 20000), 12.8);
      expect(tokensPerSecond(0, 100), isNull);
      expect(tokensPerSecond(10, null), isNull);
      expect(tokensPerSecond(10, 0), isNull);
    });

    test('round-trips through JSON', () {
      const m = RunMetrics(
        promptTokens: 512,
        prefillMs: 2000,
        decodeTokens: 128,
        decodeMs: 16000,
      );
      final back = RunMetrics.fromMap(m.toJson());
      expect(back.prefillTps, 256);
      expect(back.decodeTps, 8);
      expect(back.ttftMs, isNull);
    });
  });
}
