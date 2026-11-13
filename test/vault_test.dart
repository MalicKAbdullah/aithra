import 'package:aithra/src/data/vault.dart';
import 'package:core_storage/core_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryStorage implements ISecureStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      values[key] = value;

  @override
  Future<void> delete({required String key}) async => values.remove(key);

  @override
  Future<void> deleteAll() async => values.clear();

  @override
  Future<Map<String, String>> readAll() async => {...values};
}

void main() {
  group('data key', () {
    test('first launch makes a key and keeps returning it', () async {
      final store = DataKeyStore(MemoryStorage());
      final key = await store.obtainKey(dataExists: () async => false);
      expect(key, hasLength(32));
      expect(await store.obtainKey(dataExists: () async => true), key);
    });

    test(
      'a lost key with data on the phone is reported, not replaced',
      () async {
        final storage = MemoryStorage();
        await expectLater(
          DataKeyStore(storage).obtainKey(dataExists: () async => true),
          throwsA(isA<DataKeyLost>()),
        );
        expect(storage.values, isEmpty);
      },
    );
  });
}
