import 'dart:io';

import 'package:flutter_obfuscator/src/crypto/key_strategy.dart';
import 'package:flutter_obfuscator/src/tamper/tamper_guard_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('tamper_guard_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('dart_split: writes tamper_guard.g.dart without a native import', () {
    TamperGuardGenerator.write(
      projectRoot: tempDir.path,
      keyStrategy: KeyStrategy.dartSplit,
    );

    final file = File(p.join(
        tempDir.path, 'lib', 'flutter_obfuscator', 'tamper_guard.g.dart'));
    expect(file.existsSync(), isTrue);
    final source = file.readAsStringSync();

    expect(source, contains('class TamperGuard'));
    expect(source, contains('class TamperReport'));
    expect(source, contains('class TamperDetectedException'));
    expect(source, isNot(contains("import 'native_key_channel.g.dart';")));
    expect(source, isNot(contains('NativeKeyChannel.isTraced')));
  });

  test('native_channel: also consults NativeKeyChannel.isTraced()', () {
    TamperGuardGenerator.write(
      projectRoot: tempDir.path,
      keyStrategy: KeyStrategy.nativeChannel,
    );

    final file = File(p.join(
        tempDir.path, 'lib', 'flutter_obfuscator', 'tamper_guard.g.dart'));
    final source = file.readAsStringSync();

    expect(source, contains("import 'native_key_channel.g.dart';"));
    expect(source, contains('NativeKeyChannel.isTraced()'));
  });

  test('checks root, jailbreak, and Frida heuristics', () {
    TamperGuardGenerator.write(
      projectRoot: tempDir.path,
      keyStrategy: KeyStrategy.dartSplit,
    );
    final source = File(p.join(
            tempDir.path, 'lib', 'flutter_obfuscator', 'tamper_guard.g.dart'))
        .readAsStringSync();

    expect(source, contains('/sbin/su'));
    expect(source, contains('Cydia.app'));
    expect(source, contains('27042'));
    expect(source, contains('/proc/self/maps'));
  });
}
