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
/// Dart privacy is scoped to the *library*, which is normally one file —
/// but a `part`/`part of` group is a single library spread across
/// several files, and every occurrence of a given private name anywhere
/// in that group refers to the same declaration. This resolves those
/// groups (a file's `part '...';` list, matched against files actually
/// present in this run) and renames each group as one unit with a single
/// shared rename map, rather than risk two different names in different
/// part files for what is really the same symbol. A file whose parts
/// can't all be resolved (e.g. one is excluded by `exclude_files`, or
/// missing) is left untouched, along with the rest of its group, rather
/// than guess; the run summary lists anything skipped this way. Public
/// API (anything not prefixed with `_`) is never touched.
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

    final sources = <String, String>{};
    final units = <String, CompilationUnit>{};
    for (final file in files) {
      final path = p.normalize(file.path);
      final source = file.readAsStringSync();
      sources[path] = source;
      units[path] = parseString(
        content: source,
        path: path,
        throwIfDiagnostics: false,
      ).unit;
    }

    for (final group in _resolveGroups(units)) {
      _obfuscateGroup(group, units, sources);
    }
  }

  /// Splits the parsed files into library groups: a `part`-directive head
  /// plus its resolved parts, or a lone file with neither directive. A
  /// `part`-of file with no matching head, or a head whose parts can't
  /// all be resolved within [units], is reported as skipped instead of
  /// forming a group.
  List<List<String>> _resolveGroups(Map<String, CompilationUnit> units) {
    final groups = <List<String>>[];
    final consumed = <String>{};

    for (final headPath in units.keys) {
      final partDirectives =
          units[headPath]!.directives.whereType<PartDirective>().toList();
      if (partDirectives.isEmpty) continue;

      final partPaths = <String>[];
      var allResolved = true;
      for (final directive in partDirectives) {
        final uri = directive.uri.stringValue;
        final partPath =
            uri == null ? null : p.normalize(p.join(p.dirname(headPath), uri));
        if (partPath == null || !units.containsKey(partPath)) {
          allResolved = false;
          break;
        }
        partPaths.add(partPath);
      }

      consumed.add(headPath);
      if (!allResolved) {
        skippedFiles.add(SkippedFileResult(
          filePath: headPath,
          reason: 'declares part(s) that could not be resolved within the '
              'files being obfuscated (excluded, or missing) — left '
              'untouched, along with its part files, to stay safe',
        ));
        continue;
      }
      consumed.addAll(partPaths);
      groups.add([headPath, ...partPaths]);
    }

    for (final path in units.keys) {
      if (consumed.contains(path)) continue;
      final isPartOf = units[path]!.directives.any((d) => d is PartOfDirective);
      if (isPartOf) {
        skippedFiles.add(SkippedFileResult(
          filePath: path,
          reason: 'uses a part-of directive but no library file with a '
              'matching part directive was found — left untouched to stay '
              'safe',
        ));
        continue;
      }
      groups.add([path]);
    }

    return groups;
  }

  void _obfuscateGroup(
    List<String> groupPaths,
    Map<String, CompilationUnit> units,
    Map<String, String> sources,
  ) {
    final renameMap = <String, String>{};
    final matchesByFile = <String, List<Token>>{};
    var counter = 0;

    for (final path in groupPaths) {
      final matches = <Token>[];
      var token = units[path]!.beginToken;
      while (true) {
        if (token.type == TokenType.IDENTIFIER && _isPrivate(token.lexeme)) {
          matches.add(token);
          renameMap.putIfAbsent(token.lexeme, () => '_o${counter++}');
        }
        if (token.type == TokenType.EOF) break;
        token = token.next!;
      }
      matchesByFile[path] = matches;
    }

    if (renameMap.isEmpty) return;

    for (final path in groupPaths) {
      final matches = matchesByFile[path]!;
      if (matches.isEmpty) continue;

      matches.sort((a, b) => b.offset.compareTo(a.offset));
      var updated = sources[path]!;
      final distinctNames = <String>{};
      for (final t in matches) {
        final newName = renameMap[t.lexeme]!;
        updated = updated.replaceRange(t.offset, t.offset + t.length, newName);
        distinctNames.add(t.lexeme);
      }
      File(path).writeAsStringSync(updated);

      renamedFiles.add(
        RenamedFileResult(filePath: path, renameCount: distinctNames.length),
      );
    }
  }

  static bool _isPrivate(String lexeme) =>
      lexeme.length > 1 && lexeme.startsWith('_');
}
