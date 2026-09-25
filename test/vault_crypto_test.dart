import 'dart:math';

import 'package:flutter_obfuscator/src/crypto/vault_crypto.dart';
import 'package:test/test.dart';

void main() {
  group('VaultCrypto', () {
    test('encryptString/decryptBytes round-trips', () async {
      final key = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      final entry =
          await VaultCrypto.encryptString('super-secret-value-123', key);

      final decrypted = await VaultCrypto.decryptBytes(entry, key);
      expect(String.fromCharCodes(decrypted), 'super-secret-value-123');
    });

    test('ciphertext does not contain the plaintext', () async {
      final key = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      const plain = 'sk_live_should_not_appear_anywhere';
      final entry = await VaultCrypto.encryptString(plain, key);

      expect(entry.cipherTextB64.contains(plain), isFalse);
    });

    test('decrypting with the wrong key fails', () async {
      final key = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      final wrongKey =
          List<int>.generate(32, (_) => Random.secure().nextInt(256));
      final entry = await VaultCrypto.encryptString('hello', key);

      expect(
        () => VaultCrypto.decryptBytes(entry, wrongKey),
        throwsA(anything),
      );
    });
  });
}
