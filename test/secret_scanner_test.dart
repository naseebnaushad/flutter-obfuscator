import 'dart:io';
import 'dart:math';

import 'package:flutter_obfuscator/src/config/obfuscator_config.dart';
import 'package:flutter_obfuscator/src/crypto/vault_crypto.dart';
import 'package:flutter_obfuscator/src/secrets/secret_scanner.dart';
import 'package:path/path.dart' as p;
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

  test('replaces a secret-like const field and it decrypts back correctly',
      () async {
    final libDir = Directory(p.join(tempDir.path, 'lib'))
      ..createSync(recursive: true);
    final file = File(p.join(libDir.path, 'config.dart'));
    file.writeAsStringSync('''
class RemoteConfig {
  static const String authToken = 'zY8f2QpL9wR3kM7nT1vX5jH0cB6sD4gE';
  static const String baseUrl = 'https://api.example.com';
}
''');

    final config = ObfuscatorConfig.defaults();
    final scanner = SecretScanner(config, keyBytes, 'sample_app');
    await scanner.scanDirectory(libDir.path);

    expect(scanner.findings, hasLength(1));
    final finding = scanner.findings.single;
    expect(finding.variableName, 'authToken');
    expect(finding.plainText, 'zY8f2QpL9wR3kM7nT1vX5jH0cB6sD4gE');

    final decrypted = await VaultCrypto.decryptBytes(finding.entry, keyBytes);
    expect(String.fromCharCodes(decrypted), finding.plainText);

    final rewritten = file.readAsStringSync();
    expect(rewritten, contains("SecretVault.get('${finding.id}')"));
    expect(rewritten, isNot(contains('zY8f2QpL9wR3kM7nT1vX5jH0cB6sD4gE')));
    expect(
        rewritten,
        contains("import 'package:sample_app/flutter_obfuscator/"
            "secret_vault.g.dart';"));
    // baseUrl doesn't match a secret pattern and must be left untouched.
    expect(rewritten, contains("static const String baseUrl"));
  });

  test('skips multi-variable declarations and reports why', () async {
    final libDir = Directory(p.join(tempDir.path, 'lib'))
      ..createSync(recursive: true);
    final file = File(p.join(libDir.path, 'config.dart'));
    file.writeAsStringSync('''
const apiToken = 'zY8f2QpL9wR3kM7nT1vX5jH0cB6sD4gE', other = 'x';
''');

    final config = ObfuscatorConfig.defaults();
    final scanner = SecretScanner(config, keyBytes, 'sample_app');
    await scanner.scanDirectory(libDir.path);

    expect(scanner.findings, isEmpty);
    expect(scanner.skipped, hasLength(1));
    expect(scanner.skipped.single.variableName, 'apiToken');
  });

  test(
      'flags a value matching a known secret format even with an '
      'innocuous variable name', () async {
    final libDir = Directory(p.join(tempDir.path, 'lib'))
      ..createSync(recursive: true);
    final file = File(p.join(libDir.path, 'config.dart'));
    // Built at runtime, not as a contiguous literal in this source file,
    // so a secret scanner over the repo (GitHub push protection included)
    // doesn't mistake this inert fixture value for a real Google API key.
    const keyValue = 'AIza' 'SyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWQ';
    file.writeAsStringSync("const String mapsUrl = '$keyValue';\n");

    final config = ObfuscatorConfig.defaults();
    final scanner = SecretScanner(config, keyBytes, 'sample_app');
    await scanner.scanDirectory(libDir.path);

    expect(scanner.findings, hasLength(1));
    expect(scanner.findings.single.variableName, 'mapsUrl');
  });

  test('low-entropy value matching a name pattern is skipped', () async {
    final libDir = Directory(p.join(tempDir.path, 'lib'))
      ..createSync(recursive: true);
    final file = File(p.join(libDir.path, 'config.dart'));
    file.writeAsStringSync('''
const String apiToken = 'aaaaaaaaaaaaaaaaaaaa';
''');

    final config = ObfuscatorConfig.defaults();
    final scanner = SecretScanner(config, keyBytes, 'sample_app');
    await scanner.scanDirectory(libDir.path);

    expect(scanner.findings, isEmpty);
    expect(scanner.skipped, hasLength(1));
  });
}
