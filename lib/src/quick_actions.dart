import 'dart:async';

import 'package:flutter/foundation.dart';

import 'platform/native.dart';

/// Launcher shortcuts and the Quick Settings tile.
enum QuickAction { newChat, voiceMode, askPhoto, voiceNote }

/// The quick action the user just chose, until the home screen handles it.
/// Android holds an action until [check] takes it, so one chosen before
/// the app was running is handled once the home screen is up.
class QuickActions extends ChangeNotifier {
  QuickActions(this._native) {
    _events = _native.eventsOf('quickAction').listen((_) => check());
  }

  final NativeBridge _native;
  late final StreamSubscription<Map<String, Object?>> _events;
  QuickAction? _pending;

  /// The new chat opened for "Ask about a photo" still has to ask for the
  /// photo.
  bool photoRequested = false;

  /// Takes the action waiting on the Android side, if any.
  Future<void> check() async {
    final name = await _native.takeQuickAction();
    if (name == null) return;
    _pending = QuickAction.values.byName(name);
    notifyListeners();
  }

  /// The action to handle now, once.
  QuickAction? take() {
    final p = _pending;
    _pending = null;
    return p;
  }

  /// Hands the photo request to the chat on screen, once.
  bool takePhotoRequest() {
    if (!photoRequested) return false;
    photoRequested = false;
    return true;
  }

  void requestPhoto() {
    photoRequested = true;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    super.dispose();
  }
}
