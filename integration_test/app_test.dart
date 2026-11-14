import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:aithra/main.dart' as app;
import 'package:aithra/src/data/vault.dart';
import 'package:aithra/src/models/catalog.dart';
import 'package:aithra/src/platform/native.dart';
import 'package:aithra/src/ui/screens/chat_view.dart';
import 'package:aithra/src/ui/screens/home_screen.dart';
import 'package:aithra/src/ui/widgets/chat_drawer.dart';
import 'package:aithra/src/ui/widgets/greeting.dart';
import 'package:core_storage/core_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// An 8×8 JPEG: db.putImage decodes it natively to make the thumbnail.
final Uint8List tinyJpeg = base64Decode(
  '/9j/4AAQSkZJRgABAQAASABIAAD/4QCARXhpZgAATU0AKgAAAAgABAEaAAUAAAAB'
  'AAAAPgEbAAUAAAABAAAARgEoAAMAAAABAAIAAIdpAAQAAAABAAAATgAAAAAAAABI'
  'AAAAAQAAAEgAAAABAAOgAQADAAAAAQABAACgAgAEAAAAAQAAAAigAwAEAAAAAQAA'
  'AAgAAAAA/+0AOFBob3Rvc2hvcCAzLjAAOEJJTQQEAAAAAAAAOEJJTQQlAAAAAAAQ'
  '1B2M2Y8AsgTpgAmY7PhCfv/AABEIAAgACAMBIgACEQEDEQH/xAAfAAABBQEBAQEB'
  'AQAAAAAAAAAAAQIDBAUGBwgJCgv/xAC1EAACAQMDAgQDBQUEBAAAAX0BAgMABBEF'
  'EiExQQYTUWEHInEUMoGRoQgjQrHBFVLR8CQzYnKCCQoWFxgZGiUmJygpKjQ1Njc4'
  'OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoOEhYaHiImKkpOUlZaX'
  'mJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4eLj5OXm5+jp'
  '6vHy8/T19vf4+fr/xAAfAQADAQEBAQEBAQEBAAAAAAAAAQIDBAUGBwgJCgv/xAC1'
  'EQACAQIEBAMEBwUEBAABAncAAQIDEQQFITEGEkFRB2FxEyIygQgUQpGhscEJIzNS'
  '8BVictEKFiQ04SXxFxgZGiYnKCkqNTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZn'
  'aGlqc3R1dnd4eXqCg4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrC'
  'w8TFxsfIycrS09TV1tfY2dri4+Tl5ufo6ery8/T19vf4+fr/2wBDAAICAgICAgMC'
  'AgMFAwMDBQYFBQUFBggGBgYGBggKCAgICAgICgoKCgoKCgoMDAwMDAwODg4ODg8P'
  'Dw8PDw8PDw//2wBDAQICAgQEBAcEBAcQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQ'
  'EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/3QAEAAH/2gAMAwEAAhEDEQA/'
  'AOTooor+Tz+7D//Z',
);

/// Pumps frames until [finder] matches; the app keeps animations running,
/// so pumpAndSettle would never return.
Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final native = NativeBridge();

  // Expects a fresh install: onboarding shows only until it is finished.
  testWidgets('launches through onboarding to a new chat and its drawer', (
    tester,
  ) async {
    // main() installs the app's error reporters; the test framework
    // requires its own back when the test ends.
    final testOnError = FlutterError.onError;
    addTearDown(() => FlutterError.onError = testOnError);

    await native.crashClear();
    await app.main();

    await pumpUntil(tester, find.text('Meet Aithra'));
    await tester.tap(find.text('Next'));
    await pumpUntil(tester, find.text('Private by design'));
    await tester.tap(find.text('Next'));
    await pumpUntil(tester, find.text('Download later'));
    await tester.tap(find.text('Download later'));
    await pumpUntil(tester, find.byType(HomeScreen));
    expect(find.byType(ChatView), findsOneWidget);
    expect(find.byType(Greeting), findsOneWidget);
    await tester.tap(find.byTooltip('Chats'));
    await pumpUntil(tester, find.byType(ChatDrawer));
    await tester.enterText(find.byType(TextField).first, 'harbour');
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  // testWidgets, not test: the native instrumentation runner only sees
  // results the integration_test binding records, and it records only
  // testWidgets outcomes.
  group('native channel', () {
    setUpAll(() async {
      final storage = await CachedSecureStorage.load(
        const SecureStorageImpl(FlutterSecureStorage()),
      );
      await native.dbOpen(
        await DataKeyStore(storage).obtainKey(dataExists: native.hasData),
      );
    });

    testWidgets('conversation and message writes round-trip', (_) async {
      final id = 'it-${Random().nextInt(1 << 31)}';
      final now = DateTime.now().millisecondsSinceEpoch;
      await native.dbCreateConversation(id, 'Harbour trip', now);
      await native.dbUpdateConversation(id, {'title': 'Harbour plans'});
      expect((await native.dbConversation(id))!['title'], 'Harbour plans');
      expect(
        (await native.dbConversations(0, 50)).map((c) => c['id']),
        contains(id),
      );

      final first = await native.dbAddMessage(
        convId: id,
        role: 'user',
        content: 'When does the ferry leave?',
        images: const [],
        stats: null,
        now: now,
      );
      await native.dbAddMessage(
        convId: id,
        role: 'model',
        content: 'At nine.',
        images: const [],
        stats: null,
        now: now + 1,
      );
      final msgId = first['id']! as int;
      await native.dbUpdateMessage(msgId, 'When does the ferry sail?', '{}');
      await native.dbSetTokens({msgId: 7}, 'test-model');
      final range = await native.dbMessageRange(id, 0, 10);
      expect(range.first['content'], 'When does the ferry sail?');
      expect(range.first['tokens'], 7);

      final hits = await native.dbSearchText('FERRY SAIL', 10);
      final hit = hits.singleWhere((h) => h['id'] == id);
      expect(hit['snippet'], 'When does the ferry sail?');
      expect(hit['title'], 'Harbour plans');
      expect(hit['seq'], 0);
      expect(await native.dbSearchText('no message says this', 10), isEmpty);

      await native.dbTruncate(id, 1);
      expect(await native.dbMessages(id, 1 << 30, 10), hasLength(1));
      expect(await native.dbSearch('harb', 10), isNotEmpty);

      await native.dbDeleteConversation(id);
      expect(await native.dbConversation(id), isNull);
    });

    testWidgets('an edited message keeps its photo through truncate', (
      _,
    ) async {
      final id = 'it-edit-${Random().nextInt(1 << 31)}';
      final now = DateTime.now().millisecondsSinceEpoch;
      await native.dbCreateConversation(id, 'Photo', now);
      await native.dbPutImage('$id-photo', tinyJpeg);
      await native.dbAddMessage(
        convId: id,
        role: 'user',
        content: 'What is this?',
        images: ['$id-photo'],
        stats: null,
        now: now,
      );
      await native.dbTruncate(id, 0, keepImages: ['$id-photo']);
      expect(await native.dbMessages(id, 1 << 30, 10), isEmpty);
      expect(await native.dbImage('$id-photo', thumb: true), isNotNull);
      await native.dbDeleteConversation(id);
    });

    testWidgets('the message index finds word prefixes and follows edits', (
      _,
    ) async {
      final id = 'it-find-${Random().nextInt(1 << 31)}';
      final now = DateTime.now().millisecondsSinceEpoch;
      await native.dbCreateConversation(id, 'Trip', now);
      Future<int> add(String text) async =>
          (await native.dbAddMessage(
                convId: id,
                role: 'user',
                content: text,
                images: const [],
                stats: null,
                now: now,
              ))['id']!
              as int;
      final first = await add('Pack the telescope');
      await add('The ferry leaves at nine');
      await add('Ferret racing on Sunday');

      expect(await native.dbFindInChat(id, 'ferr'), [2, 1]);
      expect(await native.dbFindInChat(id, 'FERRY nine'), [1]);
      // A word's inside is not its start.
      expect(await native.dbFindInChat(id, 'erry'), isEmpty);

      await native.dbUpdateMessage(first, 'Pack the binoculars', null);
      expect(await native.dbFindInChat(id, 'telescope'), isEmpty);
      expect(await native.dbFindInChat(id, 'binoc'), [0]);

      await native.dbTruncate(id, 2);
      expect(await native.dbFindInChat(id, 'ferr'), [1]);
      await native.dbDeleteConversation(id);
      expect(await native.dbFindInChat(id, 'ferr'), isEmpty);
    });

    testWidgets('a regenerated reply keeps its versions', (_) async {
      final id = 'it-versions-${Random().nextInt(1 << 31)}';
      final now = DateTime.now().millisecondsSinceEpoch;
      await native.dbCreateConversation(id, 'Colours', now);
      Future<Map<String, Object?>> add(String role, String text) =>
          native.dbAddMessage(
            convId: id,
            role: role,
            content: text,
            images: const [],
            stats: null,
            now: now,
          );
      await add('user', 'Name a colour');
      await add('model', 'Blue.');
      await native.dbTruncate(id, 1, archive: true);
      final green = await add('model', 'Green.');
      expect(green['version'], 1);
      expect(green['versionCount'], 2);

      final reply = (await native.dbMessageRange(id, 1, 2)).single;
      expect(reply['version'], 1);
      expect(reply['versionCount'], 2);
      var versions = await native.dbMessageVersions(id, 1);
      expect([for (final v in versions) v['content']], ['Blue.', 'Green.']);
      expect([for (final v in versions) v['current']], [false, true]);

      await native.dbSelectVersion(id, 1, 0);
      expect(
        (await native.dbMessageRange(id, 1, 2)).single['content'],
        'Blue.',
      );
      versions = await native.dbMessageVersions(id, 1);
      expect([for (final v in versions) v['content']], ['Blue.', 'Green.']);
      expect([for (final v in versions) v['current']], [true, false]);
      expect(await native.dbFindInChat(id, 'blue'), [1]);
      expect(await native.dbFindInChat(id, 'green'), isEmpty);

      // A failed regenerate followed by a new question drops the versions.
      await native.dbTruncate(id, 1, archive: true);
      expect((await add('user', 'And another?'))['versionCount'], 1);
      expect(await native.dbMessageVersions(id, 1), hasLength(1));

      // An edit replaces the question, and with it every version after.
      await native.dbTruncate(id, 0);
      await add('user', 'Name a fruit');
      await add('model', 'Apple.');
      expect((await native.dbMessageRange(id, 1, 2)).single['versionCount'], 1);
      expect(await native.dbMessageVersions(id, 1), hasLength(1));
      await native.dbDeleteConversation(id);
    });

    testWidgets('a private chat is stored private and can be made normal', (
      _,
    ) async {
      final id = 'it-private-${Random().nextInt(1 << 31)}';
      final now = DateTime.now().millisecondsSinceEpoch;
      await native.dbCreateConversation(id, 'Secret', now, private: true);
      expect((await native.dbConversation(id))!['private'], isTrue);
      await native.dbUpdateConversation(id, {'private': false});
      expect((await native.dbConversation(id))!['private'], isFalse);
      await native.dbDeleteConversation(id);
    });

    testWidgets('a chat exports as Markdown and as PDF', (_) async {
      final md = await native.exportMarkdown('Harbour/plans', '# Plans\n');
      expect(md, endsWith('Harbour_plans.md'));
      expect(await File(md).readAsString(), '# Plans\n');

      final pdf = await native.exportPdf('Harbour plans', 'Harbour plans', [
        for (var i = 0; i < 40; i++)
          {
            'role': i.isEven ? 'user' : 'model',
            'created': DateTime(2026, 11, 15).millisecondsSinceEpoch,
            'blocks': [
              {'kind': 'heading', 'text': 'Day $i'},
              {'kind': 'text', 'text': 'The ferry leaves at nine. ' * 20},
              {'kind': 'item', 'text': '•  Pack the telescope'},
              {'kind': 'code', 'text': 'tide(t) = sin(t)'},
              {'kind': 'rule', 'text': ''},
            ],
          },
      ]);
      final bytes = await File(pdf).readAsBytes();
      expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
      // Forty long messages cannot fit one page.
      expect(
        RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(bytes)).length,
        greaterThan(1),
      );
      // Each export clears the last: the files are plaintext.
      expect(File(md).existsSync(), isFalse);
    });

    testWidgets('images store and come back as thumbnails', (_) async {
      await native.dbPutImage('it-image', tinyJpeg);
      expect(await native.dbImage('it-image', thumb: false), tinyJpeg);
      expect(await native.dbImage('it-image', thumb: true), isNotEmpty);
    });

    testWidgets('device, storage and store diagnostics', (_) async {
      expect(await native.dataDir(), isNotEmpty);
      expect((await native.storageInfo())['freeBytes'], isA<int>());
      expect((await native.deviceInfo())['sdkInt'], isA<int>());
      expect(await native.runsLlama(), isA<bool>());
      final status = await native.dbVectorStatus();
      expect(status.total, greaterThanOrEqualTo(status.indexed));
      final selfTest = await native.dbSelfTest(50);
      expect(selfTest['messages'], 50);
      expect(selfTest['textSearchMs'], isA<double>());
      expect(await native.listModelFiles(), isA<List<Object?>>());
      expect(await native.queryDownloads(), isA<List<Object?>>());
      expect(await native.hasData(), isTrue);
    });

    testWidgets('a download starts once, and removing it forgets it', (
      _,
    ) async {
      final spec = embeddingModel;
      Future<int> start() => native.startDownload(
        url: spec.url,
        fileName: spec.fileName,
        title: spec.name,
        size: spec.sizeBytes,
        sha256: spec.sha256!,
      );
      final id = await start();
      expect(await start(), id);
      expect((await native.queryDownloads()).map((d) => d['id']), contains(id));
      await native.removeDownload(id);
      expect(
        (await native.queryDownloads()).map((d) => d['id']),
        isNot(contains(id)),
      );
    });

    testWidgets('embedding without the model file fails cleanly', (_) async {
      await expectLater(
        native.embed('/nonexistent/embedding.gguf', ['hello'], query: true),
        throwsA(isA<PlatformException>()),
      );
    });

    testWidgets('engine calls with no model loaded', (_) async {
      // Cancelling a request the engine never received is a no-op.
      await native.cancel(1 << 30);
      await native.unload();
      await expectLater(
        native.countTokens(const [EngineTurn('user', 'hi')]),
        throwsA(isA<PlatformException>()),
      );
    });

    testWidgets('crash report records, reads back and clears', (_) async {
      await native.crashClear();
      expect(await native.crashRead(), isNull);
      await native.crashRecord('Test entry', 'detail line');
      final report = (await native.crashRead())!;
      expect(report, contains('Aithra '));
      expect(report, contains('Test entry'));
      expect(report, contains('detail line'));
      await native.crashClear();
      expect(await native.crashRead(), isNull);
    });

    testWidgets('speech and voice output stop cleanly when idle', (_) async {
      await native.stopSpeaking();
      await native.cancelListening();
    });
  });
}
