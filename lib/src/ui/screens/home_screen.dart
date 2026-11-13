import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_session.dart';
import '../../models/catalog.dart';
import '../../models/download_state.dart';
import '../../services.dart';
import '../aithra_type.dart';
import '../widgets/chat_drawer.dart';
import 'chat_view.dart';
import 'models_screen.dart';
import 'voice_mode_screen.dart';

/// The app's home: always a chat, a new one at launch, with every other
/// chat in the drawer. Which chat shows is ChatSessions.current, so a chat
/// can be opened from anywhere (the drawer, voice mode).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    return ListenableBuilder(
      listenable: s.sessions,
      builder: (context, _) {
        final session = s.sessions.current;
        return Scaffold(
          drawer: const ChatDrawer(),
          drawerEdgeDragWidth: 32,
          appBar: AppBar(
            titleSpacing: 0,
            leading: Builder(
              builder: (context) => IconButton(
                tooltip: 'Chats',
                icon: const Icon(Icons.menu_rounded),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  Scaffold.of(context).openDrawer();
                },
              ),
            ),
            title: _Title(session),
            actions: [
              IconButton(
                tooltip: 'Voice mode',
                icon: const Icon(Icons.graphic_eq_rounded),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const VoiceModeScreen(),
                  ),
                ),
              ),
              ListenableBuilder(
                listenable: session,
                builder: (context, _) => session.conversation == null
                    ? const SizedBox.shrink()
                    : IconButton(
                        tooltip: 'New chat',
                        icon: const Icon(Icons.edit_square),
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          s.sessions.startNew();
                        },
                      ),
              ),
              _ChatMenu(session),
            ],
          ),
          body: Column(
            children: [
              const _StatusBanner(),
              Expanded(
                child: AnimatedSwitcher(
                  duration: AppMotion.fast,
                  switchInCurve: AppMotion.standard,
                  switchOutCurve: AppMotion.standard,
                  child: ChatView(key: ObjectKey(session), session: session),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The open chat's title over the model that answers.
class _Title extends StatelessWidget {
  const _Title(this.session);

  final ChatSession session;

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    final c = SuiteColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([session, s.chats, s.assistant]),
      builder: (context, _) {
        final id = session.conversation?.id;
        final title = id == null
            ? 'Aithra'
            : s.chats.items.where((x) => x.id == id).firstOrNull?.title ??
                  session.conversation!.title;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AithraType.chatTitle.copyWith(color: c.textPrimary),
            ),
            const SizedBox(height: 1),
            Text(
              _modelLine(s),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AithraType.caption.copyWith(color: c.textTertiary),
            ),
          ],
        );
      },
    );
  }

  static String _modelLine(Services s) {
    final m = s.assistant.activeModel;
    if (m == null) return 'No model';
    final b = s.assistant.backendFor(m);
    return b == null ? m.name : '${m.name} · ${b.label}';
  }
}

/// Rename and delete for the chat on screen, once it has been saved.
class _ChatMenu extends StatelessWidget {
  const _ChatMenu(this.session);

  final ChatSession session;

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final conv = session.conversation;
        if (conv == null) return const SizedBox.shrink();
        return PopupMenuButton<String>(
          onSelected: (action) async {
            final title =
                s.chats.items
                    .where((x) => x.id == conv.id)
                    .firstOrNull
                    ?.title ??
                conv.title;
            switch (action) {
              case 'rename':
                final renamed = await renameDialog(context, title);
                if (renamed != null && renamed.isNotEmpty) {
                  await s.chats.rename(conv.id, renamed);
                }
              case 'delete':
                if (await confirmDelete(context, title)) {
                  await s.sessions.delete(conv.id);
                }
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'delete', child: Text('Delete chat')),
          ],
        );
      },
    );
  }
}

/// What stands between the user and a reply: no model, a download, or tuning.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner();

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    return ListenableBuilder(
      listenable: Listenable.merge([s.models, s.assistant]),
      builder: (context, _) {
        if (!s.models.loaded) return const SizedBox.shrink();
        final tuning = s.assistant.calibrating;
        Widget banner(
          String title,
          String message, {
          VoidCallback? onTap,
          String? action,
        }) => Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            0,
            AppSpacing.gutter,
            AppSpacing.sm,
          ),
          child: AppBanner(
            title: title,
            message: message,
            actionLabel: action,
            onAction: onTap,
          ),
        );
        void openModels() => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const ModelsScreen()));
        if (tuning != null) {
          return banner(
            'Tuning for your phone',
            'Testing ${tuning.label} (${tuning.done + 1} of ${tuning.total}). Chats work once this finishes.',
          );
        }
        if (s.assistant.activeModel != null) return const SizedBox.shrink();
        final download = s.models.availability(defaultModel);
        if (download is Downloading) {
          final pct = ((download.fraction ?? 0) * 100).round();
          return banner(
            'Downloading ${defaultModel.name}',
            download.waitingReason ?? '$pct% · you can leave the app',
            onTap: openModels,
            action: 'Details',
          );
        }
        return banner(
          'No model yet',
          'Download one to start chatting.',
          onTap: openModels,
          action: 'Models',
        );
      },
    );
  }
}
