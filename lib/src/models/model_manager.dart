import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/native.dart';
import 'catalog.dart';
import 'download_state.dart';

/// Model files on the phone and their downloads. Downloads run in Android's
/// DownloadManager, so they continue with the app closed; this class only
/// polls their progress while one is active.
class ModelManager extends ChangeNotifier {
  ModelManager(this._native, {required this.runsLlama}) {
    _native.eventsOf('import').listen((e) {
      final total = e['total']! as int;
      importProgress = total > 0 ? (e['copied']! as int) / total : null;
      notifyListeners();
    });
  }

  final NativeBridge _native;

  /// False on CPUs without the Arm instructions llama.cpp is built for.
  final bool runsLlama;
  List<LocalFile> _files = const [];
  List<DownloadRecord> _downloads = const [];
  Timer? _poll;
  int freeBytes = 0;
  bool loaded = false;

  /// Non-null while a model file is being imported (0..1).
  double? importProgress;
  bool importing = false;

  ModelAvailability availability(ModelSpec spec) =>
      spec.runtime == Runtime.llamacpp && !runsLlama
      ? const Unsupported(
          "This phone's processor lacks the instructions llama.cpp needs",
        )
      : availabilityOf(spec, _files, _downloads);

  /// Imported model files: those in `imported/`, and model files from
  /// before imports had their own folder that are not catalog files.
  List<ModelSpec> get importedModels => [
    for (final f in _files)
      if (f.name.startsWith('imported/') ||
          (!catalog.any((m) => m.fileName == f.name) &&
              f.name != embeddingModel.fileName &&
              (f.name.endsWith('.litertlm') || f.name.endsWith('.gguf'))))
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

  /// Whether [spec]'s file is on the phone, whatever its state.
  bool onDisk(ModelSpec spec) => _files.any((f) => f.name == spec.fileName);

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

  final Set<String> _starting = {};

  /// A download of [spec] is being started (the button stays disabled).
  bool starting(ModelSpec spec) => _starting.contains(spec.id);

  /// Starts downloading [spec]; a second call while one runs returns it.
  /// Throws when it cannot start (not enough free space).
  Future<void> download(ModelSpec spec) async {
    if (!_starting.add(spec.id)) return;
    notifyListeners();
    try {
      await _start(spec);
    } finally {
      _starting.remove(spec.id);
      notifyListeners();
    }
  }

  Future<void> _start(ModelSpec spec) async {
    await _native.startDownload(
      url: spec.url,
      fileName: spec.fileName,
      title: 'Aithra · ${spec.name}',
      size: spec.sizeBytes,
      sha256: spec.sha256!,
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
