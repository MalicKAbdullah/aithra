import 'catalog.dart';

/// Android DownloadManager status codes (`DownloadManager.STATUS_*`).
abstract final class DmStatus {
  static const pending = 1;
  static const running = 2;
  static const paused = 4;
  static const successful = 8;
  static const failed = 16;
}

/// A row from DownloadManager, as sent by native code.
class DownloadRecord {
  const DownloadRecord({
    required this.id,
    required this.fileName,
    required this.status,
    required this.reason,
    required this.downloaded,
    required this.total,
  });

  factory DownloadRecord.fromMap(Map<String, Object?> m) => DownloadRecord(
    id: m['id']! as int,
    fileName: (m['fileName'] as String?) ?? '',
    status: m['status']! as int,
    reason: m['reason']! as int,
    downloaded: m['downloaded']! as int,
    total: m['total']! as int,
  );

  final int id;
  final String fileName;
  final int status;
  final int reason;
  final int downloaded;

  /// -1 until the server has answered.
  final int total;

  bool get isActive =>
      status == DmStatus.pending ||
      status == DmStatus.running ||
      status == DmStatus.paused;
}

/// A file in the models folder.
class LocalFile {
  const LocalFile({required this.path, required this.name, required this.size});

  factory LocalFile.fromMap(Map<String, Object?> m) => LocalFile(
    path: m['path']! as String,
    name: m['name']! as String,
    size: m['size']! as int,
  );

  final String path;
  final String name;
  final int size;
}

sealed class ModelAvailability {
  const ModelAvailability();
}

class NotDownloaded extends ModelAvailability {
  const NotDownloaded();
}

class Downloading extends ModelAvailability {
  const Downloading({
    required this.downloadId,
    required this.downloaded,
    required this.total,
    required this.waitingReason,
  });

  final int downloadId;
  final int downloaded;
  final int total;

  /// Why a paused download is waiting, in plain words; null while it runs.
  final String? waitingReason;

  /// 0..1, or null while the size is unknown.
  double? get fraction => total > 0 ? (downloaded / total).clamp(0, 1) : null;
}

class DownloadFailed extends ModelAvailability {
  const DownloadFailed(this.downloadId, this.message);

  final int downloadId;
  final String message;
}

/// The phone cannot run this model's runtime.
class Unsupported extends ModelAvailability {
  const Unsupported(this.reason);

  final String reason;
}

class Ready extends ModelAvailability {
  const Ready(this.path);

  final String path;
}

/// Decides what state a catalog model is in from the files on disk and the
/// system's download list. A file whose size differs from the published size
/// with no live download is a leftover partial file, so it counts as not
/// downloaded.
ModelAvailability availabilityOf(
  ModelSpec spec,
  List<LocalFile> files,
  List<DownloadRecord> downloads,
) {
  final mine = downloads.where((d) => d.fileName == spec.fileName).toList()
    ..sort((a, b) => b.id.compareTo(a.id));
  final latest = mine.isEmpty ? null : mine.first;
  if (latest != null && latest.isActive) {
    return Downloading(
      downloadId: latest.id,
      downloaded: latest.downloaded,
      total: latest.total > 0 ? latest.total : spec.sizeBytes,
      waitingReason: latest.status == DmStatus.paused
          ? pausedReason(latest.reason)
          : null,
    );
  }
  final file = files.where((f) => f.name == spec.fileName).firstOrNull;
  if (file != null && file.size == spec.sizeBytes) return Ready(file.path);
  if (latest != null && latest.status == DmStatus.failed) {
    return DownloadFailed(latest.id, failureReason(latest.reason));
  }
  return const NotDownloaded();
}

/// `DownloadManager.PAUSED_*`.
String pausedReason(int reason) => switch (reason) {
  1 => 'Retrying shortly',
  2 => 'Waiting for network',
  3 => 'Waiting for Wi-Fi',
  _ => 'Paused',
};

/// `DownloadManager.ERROR_*`, or an HTTP status code.
String failureReason(int reason) => switch (reason) {
  1001 => 'Could not write the file',
  1002 => 'Unexpected response from the server',
  1004 => 'Network error',
  1005 => 'Too many redirects',
  1006 => 'Not enough storage space',
  1007 => 'No storage available',
  1008 => 'Download cannot resume',
  1009 => 'File already exists',
  2001 => 'The downloaded file was damaged; try again',
  >= 400 && < 600 => 'Server error (HTTP $reason)',
  _ => 'Download failed',
};

/// Human-readable size: "2.6 GB", "875 MB", "12 KB".
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
