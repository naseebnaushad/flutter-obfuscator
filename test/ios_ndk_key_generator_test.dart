import 'dart:io';
import 'dart:math';

import 'package:flutter_obfuscator/src/native/ios_ndk_key_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late List<int> keyBytes;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ios_ndk_key_test_');
    keyBytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

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

  const freshPodfile = '''
platform :ios, '13.0'

target 'Runner' do
  use_frameworks!
  use_modular_headers!

  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
end
''';

  File appDelegate(String content) {
    final dir = Directory(p.join(tempDir.path, 'ios', 'Runner'))
      ..createSync(recursive: true);
    final file = File(p.join(dir.path, 'AppDelegate.swift'));
    file.writeAsStringSync(content);
    return file;
  }

  File podfile(String content) {
    final dir = Directory(p.join(tempDir.path, 'ios'))
      ..createSync(recursive: true);
    final file = File(p.join(dir.path, 'Podfile'));
    file.writeAsStringSync(content);
    return file;
  }

  test('wires a fresh project (Podfile + AppDelegate.swift)', () {
    final delegateFile = appDelegate(freshAppDelegate);
    final podfileFile = podfile(freshPodfile);

    final result = IosNdkKeyGenerator.generate(
      projectRoot: tempDir.path,
      keyBytes: keyBytes,
    );

    expect(result.applied, isTrue);
    expect(result.platform, 'ios');

    final updatedDelegate = delegateFile.readAsStringSync();
    expect(updatedDelegate,
        contains('GeneratedPluginRegistrant.register(with: self)'));
    expect(
      updatedDelegate,
      contains('ObfuscatorKeyPlugin.register(with: self.registrar('
          'forPlugin: "ObfuscatorKeyPlugin")!)'),
    );

    final updatedPodfile = podfileFile.readAsStringSync();
    expect(
        updatedPodfile,
        contains("pod 'FlutterObfuscatorKeyNative', :path => "
            "'FlutterObfuscatorKeyNative'"));

    final pluginFile =
        File(p.join(p.dirname(delegateFile.path), 'ObfuscatorKeyPlugin.swift'));
    expect(pluginFile.existsSync(), isTrue);
    final pluginSource = pluginFile.readAsStringSync();
    expect(pluginSource, contains('import FlutterObfuscatorKeyNative'));
    expect(pluginSource, contains('flutter_obfuscator/key'));
    expect(pluginSource, contains('obfuscator_key_materialize'));
    expect(pluginSource, contains('case "isTraced":'));

    final podRoot =
        Directory(p.join(tempDir.path, 'ios', 'FlutterObfuscatorKeyNative'));
    expect(
        File(p.join(podRoot.path, 'FlutterObfuscatorKeyNative.podspec'))
            .existsSync(),
        isTrue);
    final headerFile =
        File(p.join(podRoot.path, 'Sources', 'obfuscator_key.h'));
    final cFile = File(p.join(podRoot.path, 'Sources', 'obfuscator_key.c'));
    expect(headerFile.existsSync(), isTrue);
    expect(cFile.existsSync(), isTrue);

    final headerSource = headerFile.readAsStringSync();
    expect(headerSource, contains('int obfuscator_key_length(void)'));
    expect(headerSource, contains('void obfuscator_key_materialize'));
    expect(headerSource, contains('int obfuscator_key_is_traced(void)'));

    final cSource = cFile.readAsStringSync();
    expect(cSource, contains('static const uint8_t'));
    expect(cSource, contains('P_TRACED'));

    final podspecSource =
        File(p.join(podRoot.path, 'FlutterObfuscatorKeyNative.podspec'))
            .readAsStringSync();
    expect(podspecSource, contains('s.static_framework = true'));
    expect(podspecSource, contains('GCC_SYMBOLS_PRIVATE_EXTERN'));
  });

  test('re-running is idempotent (no duplicate pod line or registration)', () {
    appDelegate(freshAppDelegate);
    final podfileFile = podfile(freshPodfile);

    IosNdkKeyGenerator.generate(projectRoot: tempDir.path, keyBytes: keyBytes);
    IosNdkKeyGenerator.generate(projectRoot: tempDir.path, keyBytes: keyBytes);

    final updatedPodfile = podfileFile.readAsStringSync();
    expect("pod 'FlutterObfuscatorKeyNative'".allMatches(updatedPodfile).length,
        1);

    final delegateFile =
        File(p.join(tempDir.path, 'ios', 'Runner', 'AppDelegate.swift'));
    final updatedDelegate = delegateFile.readAsStringSync();
    expect(
        'ObfuscatorKeyPlugin.register'.allMatches(updatedDelegate).length, 1);
  });

  test('skips gracefully when AppDelegate.swift is missing', () {
    Directory(p.join(tempDir.path, 'ios', 'Runner'))
        .createSync(recursive: true);

    final result = IosNdkKeyGenerator.generate(
      projectRoot: tempDir.path,
      keyBytes: keyBytes,
    );

    expect(result.applied, isFalse);
    expect(result.reason, contains('AppDelegate.swift'));
  });

  test('skips gracefully when no Podfile exists', () {
    appDelegate(freshAppDelegate);

    final result = IosNdkKeyGenerator.generate(
      projectRoot: tempDir.path,
      keyBytes: keyBytes,
    );

    expect(result.applied, isFalse);
    expect(result.reason, contains('Podfile'));
  });

  test(
      'skips gracefully but still generates the pod when Podfile has no '
      "Runner target block", () {
    appDelegate(freshAppDelegate);
    podfile('# custom Podfile with no target block\n');

    final result = IosNdkKeyGenerator.generate(
      projectRoot: tempDir.path,
      keyBytes: keyBytes,
    );

    expect(result.applied, isFalse);
    expect(result.reason, contains("target 'Runner' do"));

    final podspec = File(p.join(tempDir.path, 'ios',
        'FlutterObfuscatorKeyNative', 'FlutterObfuscatorKeyNative.podspec'));
    expect(podspec.existsSync(), isTrue);
  });
}
