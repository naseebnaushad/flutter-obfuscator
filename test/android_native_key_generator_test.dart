import 'dart:io';
import 'dart:math';

import 'package:flutter_obfuscator/src/native/android_native_key_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late List<int> keyBytes;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('android_native_key_test_');
    keyBytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  File mainActivity(String content) {
    final dir = Directory(p.join(tempDir.path, 'android', 'app', 'src', 'main',
        'kotlin', 'com', 'example', 'sample_app'))
      ..createSync(recursive: true);
    final file = File(p.join(dir.path, 'MainActivity.kt'));
    file.writeAsStringSync(content);
    return file;
  }

  test('wires a fresh (body-less) MainActivity.kt', () {
    final file = mainActivity('''
package com.example.sample_app

import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity()
''');

    final result = AndroidNativeKeyGenerator.generate(
      projectRoot: tempDir.path,
      keyBytes: keyBytes,
    );

    expect(result.applied, isTrue);
    expect(result.platform, 'android');

    final updated = file.readAsStringSync();
    expect(
        updated, contains('import io.flutter.embedding.engine.FlutterEngine'));
    expect(updated, contains('override fun configureFlutterEngine'));
    expect(
        updated, contains('flutterEngine.plugins.add(ObfuscatorKeyPlugin())'));

    final pluginFile =
        File(p.join(p.dirname(file.path), 'ObfuscatorKeyPlugin.kt'));
    expect(pluginFile.existsSync(), isTrue);
    final pluginSource = pluginFile.readAsStringSync();
    expect(pluginSource, contains('package com.example.sample_app'));
    expect(pluginSource, contains('flutter_obfuscator/key'));
    expect(pluginSource, contains('fun materialize(): ByteArray'));
  });

  test('wires a MainActivity.kt that already has a body', () {
    final file = mainActivity('''
package com.example.sample_app

import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity() {
    // some custom code
}
''');

    final result = AndroidNativeKeyGenerator.generate(
      projectRoot: tempDir.path,
      keyBytes: keyBytes,
    );

    expect(result.applied, isTrue);
    final updated = file.readAsStringSync();
    expect(updated, contains('// some custom code'));
    expect(updated, contains('override fun configureFlutterEngine'));
  });

  test('re-running is idempotent (no duplicate overrides)', () {
    final file = mainActivity('''
package com.example.sample_app

import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity()
''');

    AndroidNativeKeyGenerator.generate(
        projectRoot: tempDir.path, keyBytes: keyBytes);
    AndroidNativeKeyGenerator.generate(
        projectRoot: tempDir.path, keyBytes: keyBytes);

    final updated = file.readAsStringSync();
    final occurrences =
        'override fun configureFlutterEngine'.allMatches(updated).length;
    expect(occurrences, 1);
  });

  test('skips gracefully when no MainActivity.kt exists', () {
    Directory(p.join(tempDir.path, 'android', 'app', 'src', 'main'))
        .createSync(recursive: true);

    final result = AndroidNativeKeyGenerator.generate(
      projectRoot: tempDir.path,
      keyBytes: keyBytes,
    );

    expect(result.applied, isFalse);
    expect(result.reason, contains('MainActivity.kt'));
  });
}
