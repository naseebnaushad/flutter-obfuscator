import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// One encrypted entry stored in a generated `*_vault_data.g.dart` file.
class EncryptedEntry {
  EncryptedEntry({
    required this.nonceB64,
    required this.cipherTextB64,
    required this.macB64,
  });

  final String nonceB64;
  final String cipherTextB64;
  final String macB64;
}

/// Build-time AES-256-GCM encrypt/decrypt used for both the secret vault
/// and the asset vault. The key itself is handled by [VaultKey] — this
/// class only does the AEAD work.
class VaultCrypto {
  VaultCrypto._();

  static final AesGcm _algorithm = AesGcm.with256bits();

  static Future<EncryptedEntry> encryptBytes(
    List<int> plainBytes,
    List<int> keyBytes,
  ) async {
    final secretKey = SecretKey(keyBytes);
    final nonce = _algorithm.newNonce();
    final box = await _algorithm.encrypt(
      plainBytes,
      secretKey: secretKey,
      nonce: nonce,
    );
    return EncryptedEntry(
      nonceB64: base64Encode(box.nonce),
      cipherTextB64: base64Encode(box.cipherText),
      macB64: base64Encode(box.mac.bytes),
    );
  }

  static Future<EncryptedEntry> encryptString(
    String plainText,
    List<int> keyBytes,
  ) =>
      encryptBytes(utf8.encode(plainText), keyBytes);

  static Future<Uint8List> decryptBytes(
    EncryptedEntry entry,
    List<int> keyBytes,
  ) async {
    final secretKey = SecretKey(keyBytes);
    final box = SecretBox(
      base64Decode(entry.cipherTextB64),
      nonce: base64Decode(entry.nonceB64),
      mac: Mac(base64Decode(entry.macB64)),
    );
    final clear = await _algorithm.decrypt(box, secretKey: secretKey);
    return Uint8List.fromList(clear);
  }
}
