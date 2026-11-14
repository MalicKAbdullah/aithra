import 'dart:async';

import 'package:aithra/src/chat/chat_models.dart';
import 'package:aithra/src/data/settings_store.dart';
import 'package:aithra/src/voice/read_aloud.dart';
import 'package:aithra/src/voice/tts_service.dart';
import 'package:aithra/src/ui/aithra_type.dart';
import 'package:aithra/src/ui/widgets/message_actions.dart';
import 'package:aithra/src/ui/widgets/markdown_view.dart';
import 'package:aithra/src/ui/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_sessions_test.dart' show Harness, MemVault;

final _paragraphs = find.byWidgetPredicate((w) => w is RichText);

void main() {
  Widget app(Widget child) => MaterialApp(
    theme: aithraTheme(Brightness.light),
    home: Scaffold(body: child),
  );

  testWidgets('a reply keeps its laid-out text when it finishes streaming', (
    tester,
  ) async {
    final h = await tester.runAsync(Harness.start);
    final session = h!.sessions.current;
    await tester.runAsync(() async {
      unawaited(session.send('Hi', const []));
      await h.settle();
    });
    Widget list() => app(
      ListView(
        reverse: true,
        children: [
          if (session.busy)
            ModelTurn(key: const ValueKey(1), session: session)
          else
            ModelTurn(
              key: const ValueKey(1),
              session: session,
              message: session.messages.first,
            ),
        ],
      ),
    );
    session.streaming.add('Hello **there**.\n\nSecond paragraph.');
    await tester.pumpWidget(list());
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpWidget(list());
    final before = tester.renderObject<RenderParagraph>(_paragraphs.first);
    await tester.runAsync(() async {
      h.native.finish('');
      await h.settle();
    });
    expect(session.busy, isFalse);
    await tester.pumpWidget(list());
    final after = tester.renderObject<RenderParagraph>(_paragraphs.first);
    expect(after, same(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the newest item growing keeps the reader in place', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var height = 300.0;
    late StateSetter grow;
    await tester.pumpWidget(
      app(
        CustomScrollView(
          controller: scroll,
          reverse: true,
          slivers: [
            SliverKeepReadingPlace(
              child: StatefulBuilder(
                builder: (context, setState) {
                  grow = setState;
                  return SizedBox(height: height);
                },
              ),
            ),
            SliverList.list(
              children: [
                for (var i = 0; i < 20; i++)
                  SizedBox(height: 100, child: Text('$i')),
              ],
            ),
          ],
        ),
      ),
    );
    scroll.jumpTo(150);
    await tester.pump();
    final top = tester.getTopLeft(find.text('3')).dy;
    grow(() => height = 420);
    await tester.pump();
    expect(scroll.offset, 270);
    expect(tester.getTopLeft(find.text('3')).dy, top);

    // At the newest end the list follows the growth instead.
    scroll.jumpTo(0);
    await tester.pump();
    grow(() => height = 500);
    await tester.pump();
    expect(scroll.offset, 0);
  });

  testWidgets('a link opens a sheet with its address', (tester) async {
    await tester.pumpWidget(
      app(const MarkdownView('Read [the docs](https://example.com/d) now.')),
    );
    final paragraph = tester.renderObject<RenderParagraph>(_paragraphs.first);
    final box = paragraph
        .getBoxesForSelection(
          const TextSelection(baseOffset: 6, extentOffset: 12),
        )
        .first;
    await tester.tapAt(paragraph.localToGlobal(box.toRect().center));
    await tester.pumpAndSettle();
    expect(find.text('https://example.com/d'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('reply text joins a selection area', (tester) async {
    await tester.pumpWidget(
      app(const SelectionArea(child: MarkdownView('Select **this** text.'))),
    );
    final paragraph = tester.renderObject<RenderParagraph>(_paragraphs.first);
    expect(paragraph.registrar, isNotNull);
  });

  testWidgets('a table scrolls sideways and copies as TSV', (tester) async {
    await tester.pumpWidget(
      app(
        MarkdownView(
          '| ${List.filled(12, 'Column').join(' | ')} |\n'
          '|${List.filled(12, '---').join('|')}|\n'
          '| ${List.filled(12, 'value').join(' | ')} |',
        ),
      ),
    );
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('Copy table'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a regenerated reply shows its version pager', (tester) async {
    final h = await tester.runAsync(Harness.start);
    final session = h!.sessions.current;
    final reply = ChatMessage(
      id: 1,
      seq: 1,
      role: Role.model,
      content: 'Blue.',
      imageIds: const [],
      created: DateTime(2026),
      version: 1,
      versionCount: 3,
    );
    await tester.pumpWidget(
      app(
        ReplyActions(
          message: reply,
          session: session,
          canRegenerate: true,
          reader: ReadAloud(
            tts: TtsService(h.native),
            native: h.native,
            settings: SettingsStore(MemVault()),
          ),
        ),
      ),
    );
    expect(find.text('2/3'), findsOneWidget);
    expect(find.byTooltip('Previous answer'), findsOneWidget);
    expect(find.byTooltip('Next answer'), findsOneWidget);
    expect(find.byTooltip('Regenerate'), findsOneWidget);
  });
}
