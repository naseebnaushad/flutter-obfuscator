import 'dart:io';

import 'package:flutter_obfuscator/src/config/cert_pinning_config.dart';
import 'package:flutter_obfuscator/src/pinning/pinned_http_client_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pinned_http_client_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  String generatedSource(CertPinningConfig config) {
    PinnedHttpClientGenerator.write(projectRoot: tempDir.path, config: config);
    final file = File(p.join(tempDir.path, 'lib', 'flutter_obfuscator',
        'pinned_http_client.g.dart'));
    expect(file.existsSync(), isTrue);
    return file.readAsStringSync();
  }

  test('writes host pins and defaults to blocking unpinned hosts', () {
    final source = generatedSource(const CertPinningConfig(
      enabled: true,
      unpinnedHostPolicy: UnpinnedHostPolicy.block,
      hosts: [
        HostPins(host: 'api.example.com', spkiSha256: ['AAAA=', 'BBBB=']),
      ],
    ));

    expect(source, contains('class PinnedHttpClient'));
    expect(source, contains('static HttpClient create()'));
    expect(source, contains("_HostPin('api.example.com', ['AAAA=', 'BBBB='])"));
    expect(
        source,
        contains('UnpinnedHostPolicy _unpinnedHostPolicy = '
            'UnpinnedHostPolicy.block'));
    expect(source, contains('SecurityContext(withTrustedRoots: false)'));
    expect(source, contains('_extractSpki'));
  });

  test('writes unpinned_hosts: allow', () {
    final source = generatedSource(const CertPinningConfig(
      enabled: true,
      unpinnedHostPolicy: UnpinnedHostPolicy.allow,
      hosts: [],
    ));

    expect(
        source,
        contains('UnpinnedHostPolicy _unpinnedHostPolicy = '
            'UnpinnedHostPolicy.allow'));
  });

  test('multiple hosts each get their own pin list', () {
    final source = generatedSource(const CertPinningConfig(
      enabled: true,
      unpinnedHostPolicy: UnpinnedHostPolicy.block,
      hosts: [
        HostPins(host: 'api.example.com', spkiSha256: ['AAAA=']),
        HostPins(host: 'cdn.example.com', spkiSha256: ['CCCC=']),
      ],
    ));

    expect(source, contains("_HostPin('api.example.com', ['AAAA='])"));
    expect(source, contains("_HostPin('cdn.example.com', ['CCCC='])"));
  });
}
