import 'dart:io';

import 'package:flutter_obfuscator/src/config/cert_pinning_config.dart';
import 'package:flutter_obfuscator/src/config/obfuscator_config.dart';
import 'package:flutter_obfuscator/src/config/tamper_config.dart';
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

  test('load() reads key_strategy: native_ndk', () {
    final dir = Directory.systemTemp.createTempSync('obf_config_test_');
    final file = File('${dir.path}/obfuscator.yaml');
    file.writeAsStringSync('key_strategy: native_ndk\n');

    final config = ObfuscatorConfig.load(file.path);
    expect(config.keyStrategy, KeyStrategy.nativeNdk);

    dir.deleteSync(recursive: true);
  });

  test('KeyStrategy.usesNativeChannel is true for both native strategies', () {
    expect(KeyStrategy.dartSplit.usesNativeChannel, isFalse);
    expect(KeyStrategy.nativeChannel.usesNativeChannel, isTrue);
    expect(KeyStrategy.nativeNdk.usesNativeChannel, isTrue);
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

  test('defaults() has tamper detection disabled', () {
    final config = ObfuscatorConfig.defaults();
    expect(config.tamperDetection.enabled, isFalse);
    expect(config.tamperDetection.mode, TamperMode.block);
  });

  test('load() reads tamper_detection.enabled and mode', () {
    final dir = Directory.systemTemp.createTempSync('obf_config_test_');
    final file = File('${dir.path}/obfuscator.yaml');
    file.writeAsStringSync('''
tamper_detection:
  enabled: true
  mode: log
''');

    final config = ObfuscatorConfig.load(file.path);
    expect(config.tamperDetection.enabled, isTrue);
    expect(config.tamperDetection.mode, TamperMode.log);

    dir.deleteSync(recursive: true);
  });

  test('TamperMode.parse rejects unknown values', () {
    expect(() => TamperMode.parse('bogus'), throwsFormatException);
  });

  test('defaults() has certificate pinning disabled', () {
    final config = ObfuscatorConfig.defaults();
    expect(config.certPinning.enabled, isFalse);
    expect(config.certPinning.unpinnedHostPolicy, UnpinnedHostPolicy.block);
    expect(config.certPinning.hosts, isEmpty);
  });

  test('load() reads certificate_pinning with multiple hosts/pins', () {
    final dir = Directory.systemTemp.createTempSync('obf_config_test_');
    final file = File('${dir.path}/obfuscator.yaml');
    file.writeAsStringSync('''
certificate_pinning:
  enabled: true
  unpinned_hosts: allow
  pins:
    - host: api.example.com
      spki_sha256:
        - "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        - "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
    - host: cdn.example.com
      spki_sha256:
        - "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC="
''');

    final config = ObfuscatorConfig.load(file.path);
    expect(config.certPinning.enabled, isTrue);
    expect(config.certPinning.unpinnedHostPolicy, UnpinnedHostPolicy.allow);
    expect(config.certPinning.hosts, hasLength(2));
    expect(config.certPinning.hosts[0].host, 'api.example.com');
    expect(config.certPinning.hosts[0].spkiSha256, hasLength(2));
    expect(config.certPinning.hosts[1].host, 'cdn.example.com');

    dir.deleteSync(recursive: true);
  });

  test('UnpinnedHostPolicy.parse rejects unknown values', () {
    expect(() => UnpinnedHostPolicy.parse('bogus'), throwsFormatException);
  });

  test('load() rejects a pin entry missing spki_sha256', () {
    final dir = Directory.systemTemp.createTempSync('obf_config_test_');
    final file = File('${dir.path}/obfuscator.yaml');
    file.writeAsStringSync('''
certificate_pinning:
  enabled: true
  pins:
    - host: api.example.com
''');

    expect(() => ObfuscatorConfig.load(file.path), throwsFormatException);

    dir.deleteSync(recursive: true);
  });

  test('load() rejects a pin entry missing host', () {
    final dir = Directory.systemTemp.createTempSync('obf_config_test_');
    final file = File('${dir.path}/obfuscator.yaml');
    file.writeAsStringSync('''
certificate_pinning:
  enabled: true
  pins:
    - spki_sha256: ["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="]
''');

    expect(() => ObfuscatorConfig.load(file.path), throwsFormatException);

    dir.deleteSync(recursive: true);
  });
}
