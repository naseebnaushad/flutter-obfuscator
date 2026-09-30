import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_obfuscator/src/verify/plaintext_verifier.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('plaintext_verifier_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  String writeArtifact(Map<String, String> entries) {
    final archive = Archive();
    for (final entry in entries.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    final zipped = ZipEncoder().encode(archive)!;
    final path = p.join(tempDir.path, 'artifact.apk');
    File(path).writeAsBytesSync(zipped);
    return path;
  }

  test('flags a secret whose plaintext value is still present in the artifact',
      () {
    final artifactPath = writeArtifact({
      'classes.dex':
          'this snapshot leaked sk_live_abcdef1234567890 by accident',
    });

    final results = PlaintextVerifier.verify(
      artifactPath: artifactPath,
      secrets: [
        (
          id: 'abc123',
          variableName: 'apiKey',
          plainText: 'sk_live_abcdef1234567890',
        ),
      ],
    );

    expect(results, hasLength(1));
    expect(results.single.leaked, isTrue);
    expect(results.single.leakedIn, 'classes.dex');
  });

  test('passes a secret whose plaintext value is absent from the artifact', () {
    final artifactPath = writeArtifact({
      'classes.dex': 'nothing sensitive in here',
    });

    final results = PlaintextVerifier.verify(
      artifactPath: artifactPath,
      secrets: [
        (
          id: 'abc123',
          variableName: 'apiKey',
          plainText: 'sk_live_abcdef1234567890',
        ),
      ],
    );

    expect(results.single.leaked, isFalse);
    expect(results.single.leakedIn, isNull);
  });

  test('does not false-positive on a value split across two archive entries',
      () {
    final artifactPath = writeArtifact({
      'a.dex': 'sk_live_abc',
      'b.dex': 'def1234567890',
    });

    final results = PlaintextVerifier.verify(
      artifactPath: artifactPath,
      secrets: [
        (
          id: 'abc123',
          variableName: 'apiKey',
          plainText: 'sk_live_abcdef1234567890',
        ),
      ],
    );

    expect(results.single.leaked, isFalse);
  });

  test('treats an empty plaintext (already-skipped secret) as never leaked',
      () {
    final artifactPath = writeArtifact({'a.dex': 'anything at all'});

    final results = PlaintextVerifier.verify(
      artifactPath: artifactPath,
      secrets: [
        (id: 'abc123', variableName: 'apiKey', plainText: ''),
      ],
    );

    expect(results.single.leaked, isFalse);
  });

  test('checks multiple secrets independently in one pass', () {
    final artifactPath = writeArtifact({
      'a.dex': 'contains only the first secret: leaked_value_one',
    });

    final results = PlaintextVerifier.verify(
      artifactPath: artifactPath,
      secrets: [
        (id: 'id1', variableName: 'first', plainText: 'leaked_value_one'),
        (id: 'id2', variableName: 'second', plainText: 'never_present_value'),
      ],
    );

    expect(results.firstWhere((r) => r.id == 'id1').leaked, isTrue);
    expect(results.firstWhere((r) => r.id == 'id2').leaked, isFalse);
  });
}
