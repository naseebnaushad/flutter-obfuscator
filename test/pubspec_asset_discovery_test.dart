import 'dart:io';

import 'package:flutter_obfuscator/src/assets/pubspec_asset_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir =
        Directory.systemTemp.createTempSync('pubspec_asset_discovery_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  void writePubspec(String assetsYaml) {
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: sample_app
flutter:
  assets:
$assetsYaml
''');
  }

  test('discovers a sensitive file declared directly', () {
    writePubspec("    - assets/config.json");
    Directory(p.join(tempDir.path, 'assets')).createSync(recursive: true);
    File(p.join(tempDir.path, 'assets', 'config.json')).writeAsStringSync('{}');

    final found = PubspecAssetDiscovery.discoverSensitiveAssets(tempDir.path);
    expect(found, ['assets/config.json']);
  });

  test('expands a directory entry to its sensitive files only', () {
    writePubspec("    - assets/config/");
    final dir = Directory(p.join(tempDir.path, 'assets', 'config'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'secrets.json')).writeAsStringSync('{}');
    File(p.join(dir.path, 'logo.png')).writeAsStringSync('not-a-png');

    final found = PubspecAssetDiscovery.discoverSensitiveAssets(tempDir.path);
    expect(found, [p.join('assets', 'config', 'secrets.json')]);
  });

  test('ignores image/font assets', () {
    writePubspec("    - assets/logo.png");
    Directory(p.join(tempDir.path, 'assets')).createSync(recursive: true);
    File(p.join(tempDir.path, 'assets', 'logo.png'))
        .writeAsStringSync('not-a-png');

    final found = PubspecAssetDiscovery.discoverSensitiveAssets(tempDir.path);
    expect(found, isEmpty);
  });

  test('returns empty when there is no flutter.assets section', () {
    File(p.join(tempDir.path, 'pubspec.yaml'))
        .writeAsStringSync('name: sample_app\n');

    final found = PubspecAssetDiscovery.discoverSensitiveAssets(tempDir.path);
    expect(found, isEmpty);
  });
}
