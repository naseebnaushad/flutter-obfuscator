import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'identifier_rename_result.dart';

/// Renames private (`_`-prefixed) Dart declarations — classes, mixins,
/// enums, extensions, top-level functions/variables, and class members —
/// to short meaningless names, so a decompiled/deobfuscated build doesn't
/// hand an attacker readable internal type and method names.
///
/// Dart privacy is scoped to the *library* (normally one file per
/// library), so every occurrence of a given private name in a file
/// refers to the same declaration and can be renamed as one unit — this
/// runs a single per-file pass rather than whole-program resolution.
/// Public API (anything not prefixed with `_`) is never touched, so
/// nothing outside the file's own privacy boundary can be affected.
class IdentifierObfuscator {
  final List<RenamedFileResult> renamedFiles = [];
  final List<SkippedFileResult> skippedFiles = [];

  void obfuscateDirectory(String libDir, {required List<String> excludeGlobs}) {
    if (!Directory(libDir).existsSync()) return;

    final globs = excludeGlobs.map((g) => Glob(g)).toList();
    // excludeFiles globs (e.g. `**/*.g.dart`) are written relative to the
    // project root, so match against that rather than the absolute path
    // `listSync` returns.
    final projectRoot = p.dirname(libDir);
    final files = Directory(libDir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) =>
            !globs.any((g) => g.matches(p.relative(f.path, from: projectRoot))))
        .toList();

    for (final file in files) {
      _obfuscateFile(file);
    }
  }

  void _obfuscateFile(File file) {
    final source = file.readAsStringSync();
    final parseResult = parseString(
      content: source,
      path: file.path,
      throwIfDiagnostics: false,
    );
    final unit = parseResult.unit;

    if (unit.directives
        .any((d) => d is PartDirective || d is PartOfDirective)) {
      skippedFiles.add(SkippedFileResult(
        filePath: file.path,
        reason: 'uses part/part-of directives — privacy spans multiple '
            'files, so this file is left untouched to stay safe',
      ));
      return;
    }

    final renameMap = <String, String>{};
    final matches = <Token>[];
    var counter = 0;

    var token = unit.beginToken;
    while (true) {
      if (token.type == TokenType.IDENTIFIER && _isPrivate(token.lexeme)) {
        matches.add(token);
        renameMap.putIfAbsent(token.lexeme, () => '_o${counter++}');
      }
      if (token.type == TokenType.EOF) break;
      token = token.next!;
    }

    if (matches.isEmpty) return;

    matches.sort((a, b) => b.offset.compareTo(a.offset));
    var updated = source;
    for (final t in matches) {
      final newName = renameMap[t.lexeme]!;
      updated = updated.replaceRange(t.offset, t.offset + t.length, newName);
    }
    file.writeAsStringSync(updated);

    renamedFiles.add(
      RenamedFileResult(filePath: file.path, renameCount: renameMap.length),
    );
  }

  static bool _isPrivate(String lexeme) =>
      lexeme.length > 1 && lexeme.startsWith('_');
}
