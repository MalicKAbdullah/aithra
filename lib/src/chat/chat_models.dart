import 'dart:convert';

import '../engine/run_metrics.dart';

class ConversationInfo {
  const ConversationInfo({
    required this.id,
    required this.title,
    required this.created,
    required this.updated,
    required this.pinned,
    required this.summary,
    required this.summarizedUpto,
    required this.draft,
    required this.scroll,
    required this.messageCount,
  });

  factory ConversationInfo.fromMap(Map<String, Object?> m) => ConversationInfo(
    id: m['id']! as String,
    title: m['title']! as String,
    created: DateTime.fromMillisecondsSinceEpoch(m['created']! as int),
    updated: DateTime.fromMillisecondsSinceEpoch(m['updated']! as int),
    pinned: m['pinned']! as bool,
    summary: m['summary'] as String?,
    summarizedUpto: m['summarizedUpto']! as int,
    draft: m['draft'] as String?,
    scroll: (m['scroll']! as num).toDouble(),
    messageCount: m['messageCount']! as int,
  );

  final String id;
  final String title;
  final DateTime created;
  final DateTime updated;
  final bool pinned;

  /// Summary of messages with seq < [summarizedUpto], replacing them in the
  /// prompt once the conversation outgrows the model's context.
  final String? summary;
  final int summarizedUpto;
  final String? draft;

  /// Scroll offset to restore when the chat is reopened.
  final double scroll;
  final int messageCount;

  ConversationInfo copyWith({String? title, bool? pinned, DateTime? updated}) =>
      ConversationInfo(
        id: id,
        title: title ?? this.title,
        created: created,
        updated: updated ?? this.updated,
        pinned: pinned ?? this.pinned,
        summary: summary,
        summarizedUpto: summarizedUpto,
        draft: draft,
        scroll: scroll,
        messageCount: messageCount,
      );
}

enum Role {
  user,
  model;

  static Role parse(String s) => s == 'user' ? user : model;
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.seq,
    required this.role,
    required this.content,
    required this.imageIds,
    required this.created,
    this.stats,
  });

  factory ChatMessage.fromMap(Map<String, Object?> m) => ChatMessage(
    id: m['id']! as int,
    seq: m['seq']! as int,
    role: Role.parse(m['role']! as String),
    content: m['content']! as String,
    imageIds: [for (final i in m['images']! as List) i as String],
    created: DateTime.fromMillisecondsSinceEpoch(m['created']! as int),
    stats: m['stats'] == null
        ? null
        : RunMetrics.fromMap(
            Map<String, Object?>.from(jsonDecode(m['stats']! as String) as Map),
          ),
  );

  final int id;
  final int seq;
  final Role role;
  final String content;
  final List<String> imageIds;
  final DateTime created;
  final RunMetrics? stats;
}

/// Title for a new chat: the first line of its first message, shortened.
String titleFrom(String text) {
  final line = text.trim().split('\n').first.trim();
  if (line.isEmpty) return 'Image';
  return line.length <= 48 ? line : '${line.substring(0, 47).trimRight()}…';
}
