import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_obfuscator/src/assets/asset_encryptor.dart';
import 'package:flutter_obfuscator/src/crypto/vault_crypto.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late List<int> keyBytes;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('flutter_obfuscator_test_');
    keyBytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('encrypts a matched asset in place with the FOB1 container', () async {
    final assetDir = Directory('${tempDir.path}/assets/config')
      ..createSync(recursive: true);
    final assetFile = File('${assetDir.path}/secrets.json');
    const originalContent = '{"internalEndpoint": "https://internal"}';
    assetFile.writeAsStringSync(originalContent);

    final encryptor = AssetEncryptor(keyBytes);
    await encryptor.encryptDirectory(
      projectRoot: tempDir.path,
      includeGlobs: ['assets/config/**'],
      excludeGlobs: [],
    );

    expect(encryptor.findings, hasLength(1));
    expect(
        encryptor.findings.single.relativePath, 'assets/config/secrets.json');

    final rawBytes = assetFile.readAsBytesSync();
    expect(utf8.decode(rawBytes.sublist(0, 4)), 'FOB1');
    expect(
      utf8.decode(rawBytes, allowMalformed: true),
      isNot(contains('internalEndpoint')),
    );

    final nonceLen = rawBytes[4];
    final macLen = rawBytes[5];
    var offset = 6;
    final nonce = rawBytes.sublist(offset, offset + nonceLen);
    offset += nonceLen;
    final mac = rawBytes.sublist(offset, offset + macLen);
    offset += macLen;
    final cipherText = rawBytes.sublist(offset);

    final entry = EncryptedEntry(
      nonceB64: base64Encode(nonce),
      cipherTextB64: base64Encode(cipherText),
      macB64: base64Encode(mac),
    );
    final decrypted = await VaultCrypto.decryptBytes(entry, keyBytes);
    expect(utf8.decode(decrypted), originalContent);
  });

  test('leaves files not matching the include glob untouched', () async {
    final otherDir = Directory('${tempDir.path}/assets/images')
      ..createSync(recursive: true);
    final imageFile = File('${otherDir.path}/logo.png')
      ..writeAsStringSync('not-really-a-png');

    final encryptor = AssetEncryptor(keyBytes);
    await encryptor.encryptDirectory(
      projectRoot: tempDir.path,
      includeGlobs: ['assets/config/**'],
      excludeGlobs: [],
    );

    expect(encryptor.findings, isEmpty);
    expect(imageFile.readAsStringSync(), 'not-really-a-png');
  });
}
