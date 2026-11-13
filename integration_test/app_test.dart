import 'dart:convert';
import 'dart:math';

import 'package:aithra/main.dart' as app;
import 'package:aithra/src/data/vault.dart';
import 'package:aithra/src/platform/native.dart';
import 'package:aithra/src/ui/screens/chat_screen.dart';
import 'package:aithra/src/ui/screens/home_screen.dart';
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
  testWidgets('launches through onboarding to a chat', (tester) async {
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
    await tester.tap(find.text('New chat'));
    await pumpUntil(tester, find.byType(ChatScreen));
    expect(tester.takeException(), isNull);
  });

  group('native channel', () {
    setUpAll(() async {
      final storage = await CachedSecureStorage.load(
        const SecureStorageImpl(FlutterSecureStorage()),
      );
      await native.dbOpen(await DataKeyStore(storage).obtainKey());
    });

    test('conversation and message writes round-trip', () async {
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

      await native.dbTruncate(id, 1);
      expect(await native.dbMessages(id, 1 << 30, 10), hasLength(1));
      expect(await native.dbSearch('harb', 10), isNotEmpty);

      await native.dbDeleteConversation(id);
      expect(await native.dbConversation(id), isNull);
    });

    test('images store and come back as thumbnails', () async {
      await native.dbPutImage('it-image', tinyJpeg);
      expect(await native.dbImage('it-image', thumb: false), tinyJpeg);
      expect(await native.dbImage('it-image', thumb: true), isNotEmpty);
    });

    test('device, storage and store diagnostics', () async {
      expect(await native.dataDir(), isNotEmpty);
      expect((await native.storageInfo())['freeBytes'], isA<int>());
      expect((await native.deviceInfo())['sdkInt'], isA<int>());
      expect(await native.runsLlama(), isA<bool>());
      final status = await native.dbVectorStatus();
      expect(status.total, greaterThanOrEqualTo(status.indexed));
      expect((await native.dbSelfTest(50))['messages'], 50);
      expect(await native.listModelFiles(), isA<List<Object?>>());
      expect(await native.queryDownloads(), isA<List<Object?>>());
    });

    test('engine calls with no model loaded', () async {
      await native.cancel();
      await native.unload();
      await expectLater(
        native.countTokens(const [EngineTurn('user', 'hi')]),
        throwsA(isA<PlatformException>()),
      );
    });

    test('crash report records, reads back and clears', () async {
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

    test('speech and voice output stop cleanly when idle', () async {
      await native.stopSpeaking();
      await native.cancelListening();
    });
  });
}
