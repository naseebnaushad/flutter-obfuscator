import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// v7: when `obfuscator.yaml` doesn't list `assets.include` explicitly,
/// [discoverSensitiveAssets] fills that gap from the project's own
/// `pubspec.yaml` `flutter: assets:` list instead of encrypting nothing.
///
/// Flutter bundles every path (and, for a bare directory entry, every
/// file directly inside it, non-recursively) listed under
/// `flutter: assets:` into the app; those are exactly the files a VAPT
/// review would pull out of the APK/IPA looking for hardcoded config.
/// Image/audio/video/font assets are excluded by default — they're rarely
/// where a secret lives, and encrypting large binary assets on every
/// build for no security benefit is pure cost — leaving JSON/XML/plist/
/// text/certificate/key-shaped files, which is where hardcoded API
/// endpoints, service-account blobs, and embedded certs actually turn up.
class PubspecAssetDiscovery {
  static const _sensitiveExtensions = {
    '.json',
    '.txt',
    '.xml',
    '.yaml',
    '.yml',
    '.plist',
    '.cer',
    '.crt',
    '.der',
    '.pem',
    '.key',
    '.p12',
    '.pfx',
    '.env',
    '.cfg',
    '.conf',
  };

  /// Returns relative paths (usable directly as [AssetEncryptor] include
  /// globs) of sensitive-looking files declared as Flutter assets in
  /// `<projectRoot>/pubspec.yaml`. Empty if there's no pubspec, no
  /// `flutter: assets:` section, or nothing declared looks sensitive.
  static List<String> discoverSensitiveAssets(String projectRoot) {
    final pubspecFile = File(p.join(projectRoot, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) return const [];

    final doc = loadYaml(pubspecFile.readAsStringSync());
    if (doc is! YamlMap) return const [];
    final flutterSection = doc['flutter'];
    if (flutterSection is! YamlMap) return const [];
    final assetsList = flutterSection['assets'];
    if (assetsList is! YamlList) return const [];

    final declared = assetsList.map((e) => e.toString()).toList();
    final result = <String>[];

    for (final entry in declared) {
      if (entry.endsWith('/')) {
        final dir = Directory(p.join(projectRoot, entry));
        if (!dir.existsSync()) continue;
        for (final child in dir.listSync().whereType<File>()) {
          if (_isSensitive(child.path)) {
            result.add(p.relative(child.path, from: projectRoot));
          }
        }
      } else if (_isSensitive(entry)) {
        final file = File(p.join(projectRoot, entry));
        if (file.existsSync()) result.add(entry);
      }
    }

    return result;
  }

  static bool _isSensitive(String path) =>
      _sensitiveExtensions.contains(p.extension(path).toLowerCase());
}
