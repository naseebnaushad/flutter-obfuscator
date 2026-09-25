import 'dart:io';

import 'package:flutter_obfuscator/src/config/obfuscator_config.dart';
import 'package:flutter_obfuscator/src/crypto/key_strategy.dart';
import 'package:test/test.dart';

void main() {
  test('defaults() flags common secret-like names', () {
    final config = ObfuscatorConfig.defaults();
    expect(config.nameLooksLikeSecret('apiKey'), isTrue);
    expect(config.nameLooksLikeSecret('authToken'), isTrue);
    expect(config.nameLooksLikeSecret('clientSecret'), isTrue);
    expect(config.nameLooksLikeSecret('baseUrl'), isFalse);
  });

  test('defaults() uses the dart_split key strategy', () {
    expect(ObfuscatorConfig.defaults().keyStrategy, KeyStrategy.dartSplit);
  });

  test('load() reads key_strategy: native_channel', () {
    final dir = Directory.systemTemp.createTempSync('obf_config_test_');
    final file = File('${dir.path}/obfuscator.yaml');
    file.writeAsStringSync('key_strategy: native_channel\n');

    final config = ObfuscatorConfig.load(file.path);
    expect(config.keyStrategy, KeyStrategy.nativeChannel);

    dir.deleteSync(recursive: true);
  });

  test('KeyStrategy.parse rejects unknown values', () {
    expect(() => KeyStrategy.parse('bogus'), throwsFormatException);
  });

  test('load() reads custom patterns and asset globs from yaml', () {
    final dir = Directory.systemTemp.createTempSync('obf_config_test_');
    final file = File('${dir.path}/obfuscator.yaml');
    file.writeAsStringSync('''
secrets:
  patterns:
    - "vendorId"
  min_entropy: 1.5
assets:
  include:
    - "assets/private/**"
  exclude:
    - "assets/private/readme.md"
''');

    final config = ObfuscatorConfig.load(file.path);
    expect(config.nameLooksLikeSecret('vendorId'), isTrue);
    expect(config.nameLooksLikeSecret('apiKey'), isFalse);
    expect(config.minEntropy, 1.5);
    expect(config.assetIncludes, ['assets/private/**']);
    expect(config.assetExcludes, ['assets/private/readme.md']);

    dir.deleteSync(recursive: true);
  });

  test('load() falls back to defaults when the file is missing', () {
    final config = ObfuscatorConfig.load('/nonexistent/obfuscator.yaml');
    expect(config.nameLooksLikeSecret('apiKey'), isTrue);
  });
}
