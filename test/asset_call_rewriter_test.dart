import 'dart:io';

import 'package:flutter_obfuscator/src/assets/asset_call_rewriter.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir =
        Directory.systemTemp.createTempSync('asset_call_rewriter_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  File writeFile(String relativePath, String content) {
    final file = File(p.join(tempDir.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  test('rewrites matching rootBundle.load/loadString call sites and adds the import',
      () {
    final file = writeFile('lib/a.dart', '''
import 'package:flutter/services.dart' show rootBundle;

Future<void> loadStuff() async {
  final bytes = await rootBundle.load('assets/config/secret.json');
  final text = await rootBundle.loadString('assets/config/other.txt');
}
''');

    final unrewritten = AssetCallRewriter.rewriteDirectory(
      libDir: p.join(tempDir.path, 'lib'),
      encryptedAssetPaths: {
        'assets/config/secret.json',
        'assets/config/other.txt',
      },
      packageName: 'sample_app',
    );

    final rewritten = file.readAsStringSync();
    expect(rewritten, contains("AssetVault.load('assets/config/secret.json')"));
    expect(
        rewritten, contains("AssetVault.loadString('assets/config/other.txt')"));
    expect(
        rewritten,
        contains(
            "import 'package:sample_app/flutter_obfuscator/asset_vault.g.dart';"));
    expect(unrewritten, isEmpty);
  });

  test('leaves rootBundle calls untouched when their path is not encrypted', () {
    final file = writeFile('lib/a.dart', '''
Future<void> loadStuff() async {
  final bytes = await rootBundle.load('assets/public/logo.png');
}
''');

    AssetCallRewriter.rewriteDirectory(
      libDir: p.join(tempDir.path, 'lib'),
      encryptedAssetPaths: const {'assets/config/secret.json'},
      packageName: 'sample_app',
    );

    expect(file.readAsStringSync(), contains("rootBundle.load('assets/public/logo.png')"));
  });

  test('reports encrypted assets with no matching call site as unrewritten', () {
    writeFile('lib/a.dart', '''
Future<void> loadStuff() async {
  final bytes = await rootBundle.load('assets/config/found.json');
}
''');

    final unrewritten = AssetCallRewriter.rewriteDirectory(
      libDir: p.join(tempDir.path, 'lib'),
      encryptedAssetPaths: const {
        'assets/config/found.json',
        'assets/config/missing.json',
      },
      packageName: 'sample_app',
    );

    expect(unrewritten, {'assets/config/missing.json'});
  });

  test('does not rewrite a call built from a variable (documented limitation)',
      () {
    final file = writeFile('lib/a.dart', '''
Future<void> loadStuff(String path) async {
  final bytes = await rootBundle.load(path);
}
''');

    final unrewritten = AssetCallRewriter.rewriteDirectory(
      libDir: p.join(tempDir.path, 'lib'),
      encryptedAssetPaths: const {'assets/config/secret.json'},
      packageName: 'sample_app',
    );

    expect(file.readAsStringSync(), contains('rootBundle.load(path)'));
    expect(unrewritten, {'assets/config/secret.json'});
  });

  test('does not duplicate the import if already present', () {
    final file = writeFile('lib/a.dart', '''
import 'package:sample_app/flutter_obfuscator/asset_vault.g.dart';

Future<void> loadStuff() async {
  final bytes = await rootBundle.load('assets/config/secret.json');
}
''');

    AssetCallRewriter.rewriteDirectory(
      libDir: p.join(tempDir.path, 'lib'),
      encryptedAssetPaths: const {'assets/config/secret.json'},
      packageName: 'sample_app',
    );

    final occurrences =
        'asset_vault.g.dart'.allMatches(file.readAsStringSync()).length;
    expect(occurrences, 1);
  });

  test('returns all encrypted paths unrewritten when lib/ does not exist', () {
    final unrewritten = AssetCallRewriter.rewriteDirectory(
      libDir: p.join(tempDir.path, 'nonexistent_lib'),
      encryptedAssetPaths: const {'assets/config/secret.json'},
      packageName: 'sample_app',
    );

    expect(unrewritten, {'assets/config/secret.json'});
  });
}
