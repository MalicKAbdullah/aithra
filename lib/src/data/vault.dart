import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_storage/core_storage.dart';

/// The random 256-bit key that encrypts everything Aithra stores. Generated
/// once with a secure RNG and kept in core_storage (Android Keystore backed);
/// never derived from a password and never written next to the data.
class DataKeyStore {
  const DataKeyStore(this._storage);

  static const String storageKey = 'aithra_data_key';

  final ISecureStorage _storage;

  Future<Uint8List> obtainKey() async {
    final existing = await _storage.read(key: storageKey);
    if (existing != null) return base64Decode(existing);
    final rng = Random.secure();
    final key = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
    await _storage.write(key: storageKey, value: base64Encode(key));
    return key;
  }
}

/// Small JSON documents (settings, memories, calibration results), each
/// AES-256-GCM encrypted with core_crypto into its own file. Writes go to a
/// temp file then rename, so an interrupted write never corrupts a document.
class Vault {
  Vault(this._dir, this._key, {CipherService cipher = const CipherService()})
    : _cipher = cipher;

  final String _dir;
  final Uint8List _key;
  final CipherService _cipher;

  File _file(String name) => File('$_dir/$name.vault');

  Future<Object?> read(String name) async {
    final file = _file(name);
    if (!file.existsSync()) return null;
    final plain = await _cipher.decrypt(
      payload: EncryptedPayload.fromBytes(await file.readAsBytes()),
      keyBytes: _key,
    );
    return jsonDecode(plain);
  }

  Future<void> write(String name, Object? value) async {
    final payload = await _cipher.encrypt(
      plaintext: jsonEncode(value),
      keyBytes: _key,
      salt: await _cipher.generateSalt(),
    );
    final file = _file(name);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(payload.toBytes(), flush: true);
    await tmp.rename(file.path);
  }
}
