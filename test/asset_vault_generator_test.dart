import 'dart:io';

import 'package:flutter_obfuscator/src/assets/asset_vault_generator.dart';
import 'package:flutter_obfuscator/src/config/tamper_config.dart';
import 'package:flutter_obfuscator/src/crypto/key_material.dart';
import 'package:flutter_obfuscator/src/crypto/key_strategy.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('asset_vault_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  String vaultSource() => File(p.join(
          tempDir.path, 'lib', 'flutter_obfuscator', 'asset_vault.g.dart'))
      .readAsStringSync();

  test('dartSplit: writes an AssetVault that imports _obf_key_material.g.dart',
      () {
    AssetVaultGenerator.write(
      projectRoot: tempDir.path,
      keyStrategy: KeyStrategy.dartSplit,
    );

    final source = vaultSource();
    expect(source, contains("import '_obf_key_material.g.dart';"));
    expect(source, contains('class AssetVault'));
    expect(source, contains('static Future<Uint8List> load('));
    expect(source, contains('static Future<String> loadString('));
  });

  test('nativeChannel: imports native_key_channel.g.dart instead', () {
    AssetVaultGenerator.write(
      projectRoot: tempDir.path,
      keyStrategy: KeyStrategy.nativeChannel,
    );

    final source = vaultSource();
    expect(source, contains("import 'native_key_channel.g.dart';"));
    expect(source, contains('NativeKeyChannel.fetchKey()'));
  });

  test('tamper detection disabled by default: no TamperGuard reference', () {
    AssetVaultGenerator.write(
      projectRoot: tempDir.path,
      keyStrategy: KeyStrategy.dartSplit,
    );

    expect(vaultSource(), isNot(contains('TamperGuard')));
  });

  test('mode: block throws TamperDetectedException before decrypting', () {
    AssetVaultGenerator.write(
      projectRoot: tempDir.path,
      keyStrategy: KeyStrategy.dartSplit,
      tamperConfig: const TamperConfig(enabled: true, mode: TamperMode.block),
    );

    final source = vaultSource();
    expect(source, contains("import 'tamper_guard.g.dart';"));
    expect(source, contains('throw TamperDetectedException(tamperReport);'));
  });

  test(
      'dartSplit: the key material class it imports is not private '
      '(regression — a private class is invisible across a plain import, '
      'which previously made every dartSplit-strategy project fail to '
      'compile)', () {
    final keyMaterial = VaultKeyMaterial.generate();
    AssetVaultGenerator.write(
      projectRoot: tempDir.path,
      keyStrategy: KeyStrategy.dartSplit,
    );

    final classMatch =
        RegExp(r'class (\w+) \{').firstMatch(keyMaterial.generatedSource);
    expect(classMatch, isNotNull);
    final className = classMatch!.group(1)!;
    expect(className.startsWith('_'), isFalse,
        reason: 'asset_vault.g.dart references this class from a '
            "different file via a plain 'import' (not part/part-of), so "
            'Dart privacy rules make a leading underscore here invisible '
            'to its caller.');

    final source = vaultSource();
    expect(source, contains('$className.materialize()'));
  });
}
