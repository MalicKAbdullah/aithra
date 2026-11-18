import 'package:aithra/src/platform/native.dart';

/// The visibility and reply-hold channel calls of a fake [NativeBridge]:
/// the app starts on screen, and every begun and ended hold is recorded.
mixin FakeReplies on NativeBridge {
  final List<int> begun = [];

  /// Ended holds as (id, chat, ready title).
  final List<(int, String?, String?)> ended = [];

  @override
  Future<bool> appVisible() async => true;

  @override
  Future<bool> appReplying() async => false;

  @override
  Future<void> replyBegin(int id) async => begun.add(id);

  @override
  Future<void> replyEnd(int id, {String? convId, String? readyTitle}) async =>
      ended.add((id, convId, readyTitle));
}
