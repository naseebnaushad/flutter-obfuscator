import 'dart:io';
import 'dart:math';

import 'package:flutter_obfuscator/src/native/ios_native_key_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late List<int> keyBytes;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ios_native_key_test_');
    keyBytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  File appDelegate(String content) {
    final dir = Directory(p.join(tempDir.path, 'ios', 'Runner'))
      ..createSync(recursive: true);
    final file = File(p.join(dir.path, 'AppDelegate.swift'));
    file.writeAsStringSync(content);
    return file;
  }

  const freshAppDelegate = '''
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
''';

  test('wires a fresh AppDelegate.swift', () {
    final file = appDelegate(freshAppDelegate);

    final result = IosNativeKeyGenerator.generate(
      projectRoot: tempDir.path,
      keyBytes: keyBytes,
    );

    expect(result.applied, isTrue);
    expect(result.platform, 'ios');

    final updated = file.readAsStringSync();
    expect(updated, contains('GeneratedPluginRegistrant.register(with: self)'));
    expect(
      updated,
      contains('ObfuscatorKeyPlugin.register(with: self.registrar('
          'forPlugin: "ObfuscatorKeyPlugin")!)'),
    );

    final pluginFile =
        File(p.join(p.dirname(file.path), 'ObfuscatorKeyPlugin.swift'));
    expect(pluginFile.existsSync(), isTrue);
    final pluginSource = pluginFile.readAsStringSync();
    expect(pluginSource, contains('flutter_obfuscator/key'));
    expect(pluginSource, contains('static func materialize() -> [UInt8]'));
    expect(pluginSource, contains('case "isTraced":'));
    expect(pluginSource, contains('P_TRACED'));
  });

  test('re-running is idempotent (no duplicate registrations)', () {
    final file = appDelegate(freshAppDelegate);

    IosNativeKeyGenerator.generate(
        projectRoot: tempDir.path, keyBytes: keyBytes);
    IosNativeKeyGenerator.generate(
        projectRoot: tempDir.path, keyBytes: keyBytes);

    final updated = file.readAsStringSync();
    final occurrences =
        'ObfuscatorKeyPlugin.register'.allMatches(updated).length;
    expect(occurrences, 1);
  });

  test('skips gracefully when AppDelegate.swift is missing', () {
    Directory(p.join(tempDir.path, 'ios', 'Runner'))
        .createSync(recursive: true);

    final result = IosNativeKeyGenerator.generate(
      projectRoot: tempDir.path,
      keyBytes: keyBytes,
    );

    expect(result.applied, isFalse);
    expect(result.reason, contains('AppDelegate.swift'));
  });

  test('skips gracefully when GeneratedPluginRegistrant call is not found', () {
    appDelegate('''
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
}
''');

    final result = IosNativeKeyGenerator.generate(
      projectRoot: tempDir.path,
      keyBytes: keyBytes,
    );

    expect(result.applied, isFalse);
    expect(result.reason, contains('GeneratedPluginRegistrant'));
  });
}
