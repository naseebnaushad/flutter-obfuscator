import 'dart:io';

import 'package:flutter_obfuscator/src/config/tamper_config.dart';
import 'package:flutter_obfuscator/src/crypto/key_material.dart';
import 'package:flutter_obfuscator/src/crypto/key_strategy.dart';
import 'package:flutter_obfuscator/src/secrets/secret_vault_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('secret_vault_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  String vaultSource() => File(p.join(
          tempDir.path, 'lib', 'flutter_obfuscator', 'secret_vault.g.dart'))
      .readAsStringSync();

  test('tamper detection disabled by default: no TamperGuard reference', () {
    SecretVaultGenerator.write(
      projectRoot: tempDir.path,
      findings: const [],
      keyStrategy: KeyStrategy.dartSplit,
      keyMaterial: VaultKeyMaterial.generate(),
    );

    final source = vaultSource();
    expect(source, isNot(contains('TamperGuard')));
  });

  test('mode: block throws TamperDetectedException before decrypting', () {
    SecretVaultGenerator.write(
      projectRoot: tempDir.path,
      findings: const [],
      keyStrategy: KeyStrategy.dartSplit,
      keyMaterial: VaultKeyMaterial.generate(),
      tamperConfig: const TamperConfig(enabled: true, mode: TamperMode.block),
    );

    final source = vaultSource();
    expect(source, contains("import 'tamper_guard.g.dart';"));
    expect(source, contains('throw TamperDetectedException(tamperReport);'));
    // The throw must happen before the key is fetched.
    expect(source.indexOf('TamperDetectedException'),
        lessThan(source.indexOf('_ObfKeyMaterial.materialize()')));
  });

  test('mode: log warns but still proceeds to decrypt', () {
    SecretVaultGenerator.write(
      projectRoot: tempDir.path,
      findings: const [],
      keyStrategy: KeyStrategy.dartSplit,
      keyMaterial: VaultKeyMaterial.generate(),
      tamperConfig: const TamperConfig(enabled: true, mode: TamperMode.log),
    );

    final source = vaultSource();
    expect(source, isNot(contains('throw TamperDetectedException')));
    expect(source, contains('tamper signals detected'));
  });
}
