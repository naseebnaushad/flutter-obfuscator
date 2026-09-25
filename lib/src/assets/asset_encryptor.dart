import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import '../crypto/vault_crypto.dart';
import 'asset_finding.dart';

/// Container format used for encrypted assets: `FOB1` magic, followed by
/// 1-byte nonce length, 1-byte mac length, then nonce || mac || cipherText.
///
/// Encrypting in place at the asset's original logical path (instead of
/// renaming/moving it) means pubspec.yaml's `assets:` list never needs to
/// change — `rootBundle.load(path)` still resolves the same path, it just
/// now returns bytes that need `AssetVault` to unwrap.
class AssetEncryptor {
  AssetEncryptor(this.keyBytes);

  final List<int> keyBytes;
  final List<AssetFinding> findings = [];

  static final List<int> magic = utf8.encode('FOB1');

  Future<void> encryptDirectory({
    required String projectRoot,
    required List<String> includeGlobs,
    required List<String> excludeGlobs,
  }) async {
    if (includeGlobs.isEmpty) return;

    final included = includeGlobs.map((g) => Glob(g)).toList();
    final excluded = excludeGlobs.map((g) => Glob(g)).toList();

    final allFiles = Directory(projectRoot)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>();

    for (final file in allFiles) {
      final rel = p.relative(file.path, from: projectRoot);
      if (!included.any((g) => g.matches(rel))) continue;
      if (excluded.any((g) => g.matches(rel))) continue;
      await _encryptFile(file, rel);
    }
  }

  Future<void> _encryptFile(File file, String relPath) async {
    final original = file.readAsBytesSync();
    final entry = await VaultCrypto.encryptBytes(original, keyBytes);

    final nonce = base64Decode(entry.nonceB64);
    final mac = base64Decode(entry.macB64);
    final cipherText = base64Decode(entry.cipherTextB64);

    final container = BytesBuilder()
      ..add(magic)
      ..addByte(nonce.length)
      ..addByte(mac.length)
      ..add(nonce)
      ..add(mac)
      ..add(cipherText);

    file.writeAsBytesSync(container.toBytes());

    findings.add(AssetFinding(
      relativePath: relPath,
      originalByteLength: original.length,
    ));
  }
}
