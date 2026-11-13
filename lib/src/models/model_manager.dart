import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/native.dart';
import 'catalog.dart';
import 'download_state.dart';

/// Model files on the phone and their downloads. Downloads run in Android's
/// DownloadManager, so they continue with the app closed; this class only
/// polls their progress while one is active.
class ModelManager extends ChangeNotifier {
  ModelManager(this._native) {
    _native.eventsOf('import').listen((e) {
      final total = e['total']! as int;
      importProgress = total > 0 ? (e['copied']! as int) / total : null;
      notifyListeners();
    });
  }

  final NativeBridge _native;
  List<LocalFile> _files = const [];
  List<DownloadRecord> _downloads = const [];
  Timer? _poll;
  int freeBytes = 0;
  bool loaded = false;

  /// Non-null while a model file is being imported (0..1).
  double? importProgress;
  bool importing = false;

  ModelAvailability availability(ModelSpec spec) =>
      availabilityOf(spec, _files, _downloads);

  /// Imported files that are not catalog models.
  List<ModelSpec> get importedModels => [
    for (final f in _files)
      if (!f.name.endsWith('.importing') &&
          !catalog.any((m) => m.fileName == f.name) &&
          (f.name.endsWith('.litertlm') || f.name.endsWith('.gguf')))
        ModelSpec.imported(f.name, f.size),
  ];

  List<ModelSpec> get allModels => [...catalog, ...importedModels];

  ModelSpec? byId(String? id) =>
      id == null ? null : allModels.where((m) => m.id == id).firstOrNull;

  List<ModelSpec> get readyModels => [
    for (final m in allModels)
      if (availability(m) is Ready) m,
  ];

  String? pathOf(ModelSpec spec) => switch (availability(spec)) {
    Ready(:final path) => path,
    _ => null,
  };

  int sizeOf(ModelSpec spec) =>
      _files.where((f) => f.name == spec.fileName).firstOrNull?.size ??
      spec.sizeBytes;

  int get usedBytes => _files.fold(0, (sum, f) => sum + f.size);

  Future<void> refresh() async {
    final results = await Future.wait([
      _native.listModelFiles(),
      _native.queryDownloads(),
      _native.storageInfo(),
    ]);
    _files = [
      for (final m in results[0] as List<Map<String, Object?>>)
        LocalFile.fromMap(m),
    ];
    _downloads = [
      for (final m in results[1] as List<Map<String, Object?>>)
        DownloadRecord.fromMap(m),
    ];
    freeBytes = (results[2] as Map<String, Object?>)['freeBytes']! as int;
    loaded = true;
    notifyListeners();
    final active = _downloads.any((d) => d.isActive);
    if (active && _poll == null) {
      _poll = Timer.periodic(
        const Duration(milliseconds: 800),
        (_) => refresh(),
      );
    } else if (!active) {
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> download(ModelSpec spec) async {
    await _native.startDownload(
      spec.url,
      spec.fileName,
      'Aithra · ${spec.name}',
    );
    await refresh();
  }

  Future<void> cancelDownload(ModelSpec spec) async {
    final a = availability(spec);
    if (a is Downloading) await _native.removeDownload(a.downloadId);
    await refresh();
  }

  Future<void> delete(ModelSpec spec) async {
    for (final d in _downloads.where((d) => d.fileName == spec.fileName)) {
      await _native.removeDownload(d.id);
    }
    for (final f in _files.where((f) => f.name == spec.fileName)) {
      await _native.deleteFile(f.path);
    }
    await refresh();
  }

  /// Returns the imported model, or null when the picker was dismissed.
  Future<ModelSpec?> import() async {
    importing = true;
    importProgress = null;
    notifyListeners();
    try {
      final path = await _native.importModel();
      if (path == null) return null;
      await refresh();
      final name = path.split('/').last;
      return allModels.where((m) => m.fileName == name).firstOrNull;
    } finally {
      importing = false;
      importProgress = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}
