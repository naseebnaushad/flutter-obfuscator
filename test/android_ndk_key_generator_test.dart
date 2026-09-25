import 'dart:io';
import 'dart:math';

import 'package:flutter_obfuscator/src/native/android_ndk_key_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late List<int> keyBytes;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('android_ndk_key_test_');
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

  File buildGradle(String content, {bool kts = false}) {
    final dir = Directory(p.join(tempDir.path, 'android', 'app'))
      ..createSync(recursive: true);
    final file =
        File(p.join(dir.path, kts ? 'build.gradle.kts' : 'build.gradle'));
    file.writeAsStringSync(content);
    return file;
  }

  const freshMainActivity = '''
package com.example.sample_app

import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity()
''';

  test('wires a fresh project (Groovy build.gradle)', () {
    final activityFile = mainActivity(freshMainActivity);
    final gradleFile = buildGradle('''
android {
    namespace "com.example.sample_app"
    compileSdk 34
}
''');

    final result = AndroidNdkKeyGenerator.generate(
      projectRoot: tempDir.path,
      keyBytes: keyBytes,
    );

    expect(result.applied, isTrue);

    final updatedActivity = activityFile.readAsStringSync();
    expect(updatedActivity,
        contains('flutterEngine.plugins.add(ObfuscatorKeyPlugin())'));

    final pluginFile =
        File(p.join(p.dirname(activityFile.path), 'ObfuscatorKeyPlugin.kt'));
    final pluginSource = pluginFile.readAsStringSync();
    expect(pluginSource, contains('external fun nativeMaterializeKey()'));
    expect(pluginSource, contains('System.loadLibrary("obfuscator_key")'));

    final cppFile = File(p.join(tempDir.path, 'android', 'app', 'src', 'main',
        'cpp', 'flutter_obfuscator', 'obfuscator_key.cpp'));
    expect(cppFile.existsSync(), isTrue);
    final cppSource = cppFile.readAsStringSync();
    expect(cppSource, contains('JNI_OnLoad'));
    expect(cppSource, contains('RegisterNatives'));
    expect(cppSource,
        contains('FindClass("com/example/sample_app/ObfuscatorKeyPlugin")'));

    final cmakeFile = File(p.join(tempDir.path, 'android', 'app', 'src', 'main',
        'cpp', 'flutter_obfuscator', 'CMakeLists.txt'));
    expect(cmakeFile.existsSync(), isTrue);

    final updatedGradle = gradleFile.readAsStringSync();
    expect(updatedGradle, contains('externalNativeBuild'));
    expect(updatedGradle,
        contains('path "src/main/cpp/flutter_obfuscator/CMakeLists.txt"'));
  });

  test('wires a fresh project (Kotlin DSL build.gradle.kts)', () {
    mainActivity(freshMainActivity);
    final gradleFile = buildGradle('''
android {
    namespace = "com.example.sample_app"
    compileSdk = 34
}
''', kts: true);

    final result = AndroidNdkKeyGenerator.generate(
      projectRoot: tempDir.path,
      keyBytes: keyBytes,
    );

    expect(result.applied, isTrue);
    final updatedGradle = gradleFile.readAsStringSync();
    expect(
        updatedGradle,
        contains(
            'path = file("src/main/cpp/flutter_obfuscator/CMakeLists.txt")'));
  });

  test('re-running is idempotent (no duplicate externalNativeBuild blocks)',
      () {
    mainActivity(freshMainActivity);
    final gradleFile = buildGradle('''
android {
    namespace "com.example.sample_app"
}
''');

    AndroidNdkKeyGenerator.generate(
        projectRoot: tempDir.path, keyBytes: keyBytes);
    AndroidNdkKeyGenerator.generate(
        projectRoot: tempDir.path, keyBytes: keyBytes);

    final updatedGradle = gradleFile.readAsStringSync();
    final occurrences = 'externalNativeBuild'.allMatches(updatedGradle).length;
    expect(occurrences, 1);
  });

  test('skips gracefully when build.gradle already has externalNativeBuild',
      () {
    mainActivity(freshMainActivity);
    buildGradle('''
android {
    namespace "com.example.sample_app"
    externalNativeBuild {
        cmake {
            path "src/main/cpp/CMakeLists.txt"
        }
    }
}
''');

    final result = AndroidNdkKeyGenerator.generate(
      projectRoot: tempDir.path,
      keyBytes: keyBytes,
    );

    expect(result.applied, isFalse);
    expect(result.reason, contains('already configures externalNativeBuild'));
  });

  test('skips gracefully when no build.gradle exists', () {
    mainActivity(freshMainActivity);

    final result = AndroidNdkKeyGenerator.generate(
      projectRoot: tempDir.path,
      keyBytes: keyBytes,
    );

    expect(result.applied, isFalse);
    expect(result.reason, contains('build.gradle'));
  });
}
