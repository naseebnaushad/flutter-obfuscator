import 'dart:io';

/// Rewrites `rootBundle.load('path')` / `rootBundle.loadString('path')`
/// call sites to `AssetVault.load(...)` / `AssetVault.loadString(...)`
/// wherever the literal path argument matches one of the encrypted
/// asset paths.
///
/// v1 limitation: this only matches calls whose path argument is a plain
/// string literal (`rootBundle.loadString('assets/x.json')`), not one
/// built from a variable or interpolation. Those are reported so they can
/// be fixed by hand.
class AssetCallRewriter {
  static final RegExp _callPattern = RegExp(
    r'''rootBundle\.(loadString|load)\(\s*(['"])([^'"]+)\2\s*\)''',
  );

  /// Returns the set of encrypted asset paths that were *not* found at
  /// any rewritten call site (candidates for manual follow-up).
  static Set<String> rewriteDirectory({
    required String libDir,
    required Set<String> encryptedAssetPaths,
    required String packageName,
  }) {
    final touched = <String>{};
    if (!Directory(libDir).existsSync()) return encryptedAssetPaths;

    final files = Directory(libDir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    for (final file in files) {
      final source = file.readAsStringSync();
      var matchedAny = false;

      final updated = source.replaceAllMapped(_callPattern, (match) {
        final method = match.group(1)!;
        final quote = match.group(2)!;
        final path = match.group(3)!;
        if (!encryptedAssetPaths.contains(path)) return match.group(0)!;
        matchedAny = true;
        touched.add(path);
        return 'AssetVault.$method($quote$path$quote)';
      });

      if (!matchedAny) continue;

      final withImport = _ensureImport(updated, packageName);
      file.writeAsStringSync(withImport);
    }

    return encryptedAssetPaths.difference(touched);
  }

  static String _ensureImport(String source, String packageName) {
    final importLine =
        "import 'package:$packageName/flutter_obfuscator/asset_vault.g.dart';";
    if (source.contains(importLine)) return source;

    final importExp = RegExp(r"^import\s+'[^']+';\s*$", multiLine: true);
    final matches = importExp.allMatches(source).toList();
    if (matches.isEmpty) {
      return '$importLine\n$source';
    }
    final lastMatch = matches.last;
    return source.replaceRange(lastMatch.end, lastMatch.end, '\n$importLine');
  }
}
