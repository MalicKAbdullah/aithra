import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../platform/native.dart';

/// `SpeechRecognizer.ERROR_*` codes that mean the on-device language pack
/// is missing.
const Set<int> languageMissingErrors = {12, 13};

/// Why the on-device recognizer could not get a speech model, from the
/// `SpeechRecognizer.ERROR_*` code it reported.
String downloadErrorMessage(int code) => switch (code) {
  1 || 2 => 'The speech model download needs an internet connection',
  4 || 11 => 'Android\'s speech service stopped before the download started',
  5 => 'Android\'s speech service could not be reached',
  10 => 'Android is busy with other speech downloads; try again shortly',
  12 => 'Android\'s on-device recognizer has no model for your language',
  13 => 'Android cannot download the speech model right now',
  14 => 'Android\'s speech service does not say which languages it has',
  _ => 'Android could not download the speech model (error $code)',
};

String speechErrorMessage(int code) => switch (code) {
  1 || 2 => 'Network error',
  3 => 'Microphone error',
  4 => 'Speech service error',
  5 => 'Speech recognition was interrupted',
  8 => 'Speech recognizer is busy',
  9 => 'Microphone permission is needed',
  11 => 'Speech service is unavailable',
  12 || 13 => 'The speech model for your language is not on this phone',
  _ => 'Speech recognition failed ($code)',
};

/// Latencies of one utterance, from the recognizer's own event times.
class SpeechMetrics {
  const SpeechMetrics({
    this.firstPartialMs,
    this.finalMs,
    required this.onDevice,
  });

  /// From the start of speech to the first partial result.
  final int? firstPartialMs;

  /// From the end of speech to the final result.
  final int? finalMs;
  final bool onDevice;
}

/// Computes [SpeechMetrics] from recognizer events (`t` = elapsed ms).
class SpeechClock {
  int? _begin;
  int? _end;
  int? _firstPartial;
  int? _final;
  bool onDevice = false;

  void reset() => _begin = _end = _firstPartial = _final = null;

  void on(String kind, int t) {
    switch (kind) {
      case 'begin':
        _begin ??= t;
      case 'partial':
        _firstPartial ??= t;
      case 'end':
        _end = t;
      case 'final':
        _final = t;
    }
  }

  SpeechMetrics get metrics => SpeechMetrics(
    firstPartialMs: _begin != null && _firstPartial != null
        ? _firstPartial! - _begin!
        : null,
    finalMs: _end != null && _final != null ? _final! - _end! : null,
    onDevice: onDevice,
  );
}

/// Where the on-device recognizer's model for the conversation language
/// stands (`SpeechBridge.status`).
enum SpeechModel {
  /// No on-device recognizer, or it cannot report its languages.
  unknown,
  checking,
  installed,

  /// A download is scheduled or running.
  pending,

  /// Downloadable, not downloaded.
  missing,

  /// The recognizer has no model for the language.
  unsupported;

  static SpeechModel parse(Object? wire) =>
      values.firstWhere((m) => m.name == wire, orElse: () => unknown);
}

enum DownloadPhase {
  idle,

  /// Asked Android; no answer yet.
  requesting,

  /// Android reports progress ([SpeechDownload.percent]).
  downloading,

  /// Android took the request but reports nothing back; the status is
  /// polled until the model shows up.
  waiting,

  /// Android will download later, not now. It sends no further updates.
  scheduled,

  /// The model is installed.
  done,
  failed,
}

/// The state of the last speech model download request.
class SpeechDownload {
  const SpeechDownload(this.phase, {this.percent, this.errorCode});

  static const idle = SpeechDownload(DownloadPhase.idle);

  final DownloadPhase phase;
  final int? percent;

  /// `SpeechRecognizer.ERROR_*` when [phase] is [DownloadPhase.failed]
  /// with a code; null when the model never showed up.
  final int? errorCode;

  bool get active => switch (phase) {
    DownloadPhase.requesting ||
    DownloadPhase.downloading ||
    DownloadPhase.waiting => true,
    _ => false,
  };
}

/// What the language tag sent to the recognizer was and what it reported
/// having, for the user to copy when recognition rejects the language.
class LanguageReport {
  const LanguageReport({
    required this.sent,
    this.installed,
    this.pending,
    this.supported,
  });

  /// From an event's `language` and `report` fields.
  static LanguageReport? from(Map<String, Object?> e) {
    final sent = e['language'] as String?;
    if (sent == null) return null;
    final report = e['report'] as Map<Object?, Object?>?;
    List<String>? list(String key) =>
        (report?[key] as List<Object?>?)?.cast<String>();
    return LanguageReport(
      sent: sent,
      installed: list('installed'),
      pending: list('pending'),
      supported: list('supported'),
    );
  }

  final String sent;

  /// Null when the recognizer has not reported its languages.
  final List<String>? installed;
  final List<String>? pending;
  final List<String>? supported;

  @override
  String toString() {
    String show(List<String>? tags) => tags == null
        ? 'not reported'
        : tags.isEmpty
        ? 'none'
        : tags.join(', ');
    return 'Language sent: $sent\n'
        'Installed: ${show(installed)}\n'
        'Downloading: ${show(pending)}\n'
        'Downloadable: ${show(supported)}';
  }
}

enum SpeechAction { download, openSpeechSettings }

/// A message about the speech model for the voice screens.
class SpeechNotice {
  const SpeechNotice(
    this.text, {
    this.action,
    this.progress,
    this.busy = false,
    this.error = false,
  });

  final String text;
  final SpeechAction? action;

  /// 0–1 when Android reports download progress.
  final double? progress;

  /// Waiting on Android with no progress to show.
  final bool busy;
  final bool error;
}

/// Android's built-in recognizer: live partial text, final results, and
/// continuous dictation. One listener at a time.
class SpeechService extends ChangeNotifier {
  SpeechService(
    this._native, {
    this.pollEvery = const Duration(seconds: 4),
    this.pollFor = const Duration(minutes: 3),
  }) {
    _subscriptions = [
      _native.eventsOf('speech').listen(_onEvent),
      _native.eventsOf('speechStatus').listen(_onStatus),
      _native.eventsOf('speechDownload').listen(_onDownload),
    ];
    _lifecycle = AppLifecycleListener(onResume: _onResume);
  }

  final NativeBridge _native;
  final SpeechClock _clock = SpeechClock();
  final StreamController<String> _finals = StreamController.broadcast();
  late final List<StreamSubscription<Map<String, Object?>>> _subscriptions;
  late final AppLifecycleListener _lifecycle;

  /// How often, and for how long, the status is re-checked after Android
  /// took a download request it reports nothing about.
  final Duration pollEvery;
  final Duration pollFor;
  Timer? _poll;
  DateTime? _pollUntil;

  bool listening = false;
  bool continuous = false;

  /// Text of the utterance in progress.
  String partial = '';

  /// Microphone level in dB (`onRmsChanged`, roughly -2 to 10). Its own
  /// notifier: it changes ~20 times a second and only the voice orb reads
  /// it, so it does not rebuild [SpeechService] listeners.
  final ValueNotifier<double> level = ValueNotifier(0);
  int? errorCode;

  /// The microphone was denied for good; only Settings can grant it now.
  bool micBlocked = false;
  bool? onDeviceAvailable;
  SpeechModel model = SpeechModel.unknown;

  /// The tag recognition runs in, as the recognizer listed it.
  String? language;
  SpeechDownload download = SpeechDownload.idle;

  /// The language sent and the recognizer's languages at the last language
  /// error or status check.
  LanguageReport? report;
  SpeechMetrics? lastMetrics;

  /// Each final result.
  Stream<String> get finals => _finals.stream;

  bool get languageMissing =>
      errorCode != null && languageMissingErrors.contains(errorCode);

  /// Where Android lets the user add a speech language by hand. Pixel's
  /// page cannot be opened directly, so the button lands one level up.
  static const addInSettings =
      'To add it yourself: Languages > Speech > On-device recognition > '
      'Add a language.';

  /// What the voice screens show about the speech model, if anything.
  SpeechNotice? get modelNotice {
    final lang = language == null ? 'your language' : language!;
    switch (download.phase) {
      case DownloadPhase.requesting:
        return const SpeechNotice(
          'Asking Android for the speech model…',
          busy: true,
        );
      case DownloadPhase.downloading:
        final percent = download.percent ?? 0;
        return SpeechNotice(
          'Downloading the speech model for $lang · $percent%',
          progress: percent / 100,
        );
      case DownloadPhase.waiting:
        return SpeechNotice(
          'Android is downloading the speech model for $lang. '
          'Voice starts working as soon as it is installed.',
          busy: true,
          action: SpeechAction.openSpeechSettings,
        );
      case DownloadPhase.scheduled:
        return SpeechNotice(
          'Android will download the speech model for $lang later, '
          'for example once the phone is on Wi-Fi. $addInSettings',
          action: SpeechAction.openSpeechSettings,
        );
      case DownloadPhase.failed:
        final code = download.errorCode;
        return SpeechNotice(
          '${code == null ? 'Android has not installed the speech model for $lang yet' : downloadErrorMessage(code)}. '
          '$addInSettings',
          action: SpeechAction.openSpeechSettings,
          error: true,
        );
      case DownloadPhase.done:
        return const SpeechNotice('Speech model installed. Tap to talk.');
      case DownloadPhase.idle:
        break;
    }
    if (!languageMissing) return null;
    return switch (model) {
      SpeechModel.unsupported => SpeechNotice(
        'Android\'s on-device recognizer has no model for $lang. '
        '$addInSettings',
        action: SpeechAction.openSpeechSettings,
        error: true,
      ),
      SpeechModel.pending => SpeechNotice(
        'Android is already downloading the speech model for $lang.',
        busy: true,
        action: SpeechAction.openSpeechSettings,
      ),
      // The error's status check is still running, or it found the model
      // installed and clears the error: the next start re-resolves the tag.
      SpeechModel.installed || SpeechModel.checking => null,
      _ => SpeechNotice(
        'The on-device speech model for $lang is not on this phone.',
        action: SpeechAction.download,
      ),
    };
  }

  Future<void> checkStatus() async {
    final s = await _native.speechStatus();
    onDeviceAvailable = s['onDevice'] as bool?;
    language = s['language'] as String?;
    _setModel(SpeechModel.parse(s['model']));
  }

  Future<bool> start({required bool continuous}) async {
    final mic = await _native.requestMicrophone();
    micBlocked = mic == 'blocked';
    if (mic != 'granted') {
      errorCode = 9;
      notifyListeners();
      return false;
    }
    unawaited(HapticFeedback.mediumImpact());
    errorCode = null;
    if (download.phase == DownloadPhase.done) download = SpeechDownload.idle;
    partial = '';
    this.continuous = continuous;
    listening = true;
    _clock.reset();
    notifyListeners();
    await _native.startListening(continuous: continuous);
    return true;
  }

  Future<void> stop() async {
    unawaited(HapticFeedback.lightImpact());
    await _native.stopListening();
  }

  Future<void> cancel() async {
    listening = false;
    partial = '';
    notifyListeners();
    await _native.cancelListening();
  }

  /// Asks Android for the speech model; phones whose recognizer cannot
  /// download go to its settings instead.
  Future<void> downloadLanguage() async {
    if (download.active) return;
    _stopPolling();
    download = const SpeechDownload(DownloadPhase.requesting);
    notifyListeners();
    if (!await _native.downloadSpeechModel()) {
      download = SpeechDownload.idle;
      notifyListeners();
      await _native.openVoiceSettings();
    }
  }

  Future<void> run(SpeechAction action) => switch (action) {
    SpeechAction.download => downloadLanguage(),
    SpeechAction.openSpeechSettings => openSettings(),
  };

  /// The on-device recognizer's settings, where languages are added.
  Future<void> openSettings() => _native.openVoiceSettings();

  Future<void> openAppSettings() => _native.openAppSettings();

  void _setModel(SpeechModel next) {
    model = next;
    if (next == SpeechModel.installed) {
      if (languageMissing) errorCode = null;
      if (download.phase != DownloadPhase.idle &&
          download.phase != DownloadPhase.done) {
        download = const SpeechDownload(DownloadPhase.done);
      }
      _stopPolling();
    }
    notifyListeners();
  }

  void _onStatus(Map<String, Object?> e) {
    onDeviceAvailable = e['onDevice'] as bool? ?? onDeviceAvailable;
    language = e['language'] as String?;
    report = LanguageReport.from(e);
    _setModel(SpeechModel.parse(e['model']));
  }

  void _onDownload(Map<String, Object?> e) {
    report = LanguageReport.from(e) ?? report;
    language = report?.sent ?? language;
    switch (e['kind']) {
      case 'progress':
        download = SpeechDownload(
          DownloadPhase.downloading,
          percent: e['percent']! as int,
        );
      case 'success':
        // The status check confirms the install and settles the tag.
        download = const SpeechDownload(DownloadPhase.done);
        if (languageMissing) errorCode = null;
        _stopPolling();
        unawaited(checkStatus());
      case 'scheduled':
        download = const SpeechDownload(DownloadPhase.scheduled);
      case 'requested':
        download = const SpeechDownload(DownloadPhase.waiting);
        _startPolling();
      case 'error':
        download = SpeechDownload(
          DownloadPhase.failed,
          errorCode: e['code']! as int,
        );
        _stopPolling();
    }
    notifyListeners();
  }

  void _startPolling() {
    _pollUntil = DateTime.now().add(pollFor);
    _poll?.cancel();
    _poll = Timer.periodic(pollEvery, (_) {
      if (DateTime.now().isAfter(_pollUntil!)) {
        _stopPolling();
        download = const SpeechDownload(DownloadPhase.failed);
        notifyListeners();
      } else {
        unawaited(checkStatus());
      }
    });
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  /// A language added in Settings while Aithra was in the background is
  /// picked up on return.
  void _onResume() {
    if (onDeviceAvailable == false) return;
    if (model != SpeechModel.installed || languageMissing) {
      unawaited(checkStatus());
    }
  }

  void _onEvent(Map<String, Object?> e) {
    final kind = e['kind']! as String;
    _clock.onDevice = e['onDevice'] as bool? ?? false;
    _clock.on(kind, e['t']! as int);
    if (kind == 'level') {
      level.value = (e['rms']! as num).toDouble();
      return;
    }
    switch (kind) {
      case 'partial':
        partial = e['text']! as String;
      case 'final':
        final text = e['text']! as String;
        lastMetrics = _clock.metrics;
        _clock.reset();
        partial = '';
        if (text.isNotEmpty) _finals.add(text);
      case 'idle':
        listening = false;
      case 'error':
        listening = false;
        errorCode = e['code']! as int;
        if (languageMissing) {
          report = LanguageReport.from(e);
          language = report?.sent ?? language;
          // The recognizer's answer decides between downloading and
          // pointing at Settings.
          unawaited(checkStatus());
        }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _stopPolling();
    _lifecycle.dispose();
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    super.dispose();
  }
}
