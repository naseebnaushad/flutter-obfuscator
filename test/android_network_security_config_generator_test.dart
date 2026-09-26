import 'dart:io';

import 'package:flutter_obfuscator/src/config/cert_pinning_config.dart';
import 'package:flutter_obfuscator/src/native/android_network_security_config_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  const config = CertPinningConfig(
    enabled: true,
    unpinnedHostPolicy: UnpinnedHostPolicy.block,
    hosts: [
      HostPins(host: 'api.example.com', spkiSha256: ['AAAA=', 'BBBB=']),
    ],
  );

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('android_nsc_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  File manifest(String content) {
    final dir = Directory(p.join(tempDir.path, 'android', 'app', 'src', 'main'))
      ..createSync(recursive: true);
    final file = File(p.join(dir.path, 'AndroidManifest.xml'));
    file.writeAsStringSync(content);
    return file;
  }

  const freshManifest = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="sample_app"
        android:name="\${applicationName}"
        android:icon="@mipmap/ic_launcher">
        <activity android:name=".MainActivity"/>
    </application>
</manifest>
''';

  test('wires a fresh manifest and writes the pin-set xml', () {
    final file = manifest(freshManifest);

    final result = AndroidNetworkSecurityConfigGenerator.generate(
      projectRoot: tempDir.path,
      config: config,
    );

    expect(result.applied, isTrue);
    expect(result.platform, 'android');

    final updated = file.readAsStringSync();
    expect(
        updated,
        contains(
            'android:networkSecurityConfig="@xml/network_security_config"'));

    final xmlFile = File(p.join(tempDir.path, 'android', 'app', 'src', 'main',
        'res', 'xml', 'network_security_config.xml'));
    expect(xmlFile.existsSync(), isTrue);
    final xmlSource = xmlFile.readAsStringSync();
    expect(
        xmlSource,
        contains('<domain includeSubdomains="true">api.example.com'
            '</domain>'));
    expect(xmlSource, contains('<pin digest="SHA-256">AAAA=</pin>'));
    expect(xmlSource, contains('<pin digest="SHA-256">BBBB=</pin>'));
  });

  test('re-running is idempotent (no duplicate attribute)', () {
    manifest(freshManifest);

    AndroidNetworkSecurityConfigGenerator.generate(
        projectRoot: tempDir.path, config: config);
    AndroidNetworkSecurityConfigGenerator.generate(
        projectRoot: tempDir.path, config: config);

    final updated = File(p.join(tempDir.path, 'android', 'app', 'src', 'main',
            'AndroidManifest.xml'))
        .readAsStringSync();
    final occurrences =
        'android:networkSecurityConfig'.allMatches(updated).length;
    expect(occurrences, 1);
  });

  test('skips gracefully when manifest already sets networkSecurityConfig', () {
    manifest('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="sample_app"
        android:networkSecurityConfig="@xml/my_custom_config">
    </application>
</manifest>
''');

    final result = AndroidNetworkSecurityConfigGenerator.generate(
      projectRoot: tempDir.path,
      config: config,
    );

    expect(result.applied, isFalse);
    expect(result.reason, contains('already declares'));
  });

  test('skips gracefully when no AndroidManifest.xml exists', () {
    final result = AndroidNetworkSecurityConfigGenerator.generate(
      projectRoot: tempDir.path,
      config: config,
    );

    expect(result.applied, isFalse);
    expect(result.reason, contains('AndroidManifest.xml'));
  });
}
