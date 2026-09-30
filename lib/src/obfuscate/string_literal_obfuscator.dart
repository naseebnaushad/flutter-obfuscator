import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'string_obfuscation_result.dart';

/// Rewrites plain string literals in `lib/**/*.dart` into lookups against
/// a generated runtime table (`strings.g.dart`), so a `strings`/grep pass
/// over a decompiled build doesn't recover UI text, log messages, URLs,
/// and other literal content that isn't shaped like a credential (those
/// are already handled, with real AES-GCM encryption, by `SecretScanner`).
///
/// Only rewrites literals it can prove are safe to move to runtime:
/// literals inside import/export/part/library directives, annotations,
/// const contexts, pattern matching, constructor initializers, default
/// parameter values, and adjacent-string concatenation are left
/// untouched — some of those must stay compile-time constants, and this
/// pass works syntactically (no full semantic resolution), so it only
/// acts where that's provably safe.
class StringLiteralObfuscator {
  final List<ObfuscatedStringFileResult> obfuscatedFiles = [];

  /// Distinct plaintext values collected across the whole run, in
  /// first-seen order — index into this list is the id embedded at each
  /// rewritten call site.
  final List<String> literalValues = [];
  final Map<String, int> _valueToIndex = {};

  void obfuscateDirectory(
    String libDir, {
    required List<String> excludeGlobs,
    required int minLength,
    required String packageName,
  }) {
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
      _obfuscateFile(file, minLength: minLength, packageName: packageName);
    }
  }

  void _obfuscateFile(
    File file, {
    required int minLength,
    required String packageName,
  }) {
    final source = file.readAsStringSync();
    final parseResult = parseString(
      content: source,
      path: file.path,
      throwIfDiagnostics: false,
    );

    final collector = _EligibleLiteralCollector(minLength: minLength);
    parseResult.unit.accept(collector);

    if (collector.matches.isEmpty) return;

    collector.matches.sort((a, b) => b.offset.compareTo(a.offset));
    var updated = source;
    for (final literal in collector.matches) {
      final index = _valueToIndex.putIfAbsent(literal.value, () {
        literalValues.add(literal.value);
        return literalValues.length - 1;
      });
      updated =
          updated.replaceRange(literal.offset, literal.end, 'obfS($index)');
    }

    updated = _ensureImport(updated, packageName);
    file.writeAsStringSync(updated);

    obfuscatedFiles.add(ObfuscatedStringFileResult(
      filePath: file.path,
      literalCount: collector.matches.length,
    ));
  }

  static String _ensureImport(String source, String packageName) {
    final importLine =
        "import 'package:$packageName/flutter_obfuscator/strings.g.dart';";
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

class _EligibleLiteralCollector extends RecursiveAstVisitor<void> {
  _EligibleLiteralCollector({required this.minLength});

  final int minLength;
  final List<SimpleStringLiteral> matches = [];

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    if (node.value.length >= minLength && !_isExcluded(node)) {
      matches.add(node);
    }
    super.visitSimpleStringLiteral(node);
  }

  static bool _isExcluded(AstNode node) {
    AstNode? current = node;
    while (current != null) {
      if (current is Directive ||
          current is Annotation ||
          current is ConstructorInitializer ||
          current is DefaultFormalParameter ||
          current is SwitchPatternCase ||
          current is GuardedPattern ||
          current is ConstantPattern ||
          current is EnumConstantArguments ||
          current is AdjacentStrings) {
        return true;
      }
      if (current is VariableDeclarationList && current.isConst) return true;
      if (current is InstanceCreationExpression && current.isConst) {
        return true;
      }
      if (current is TypedLiteral && current.isConst) return true;
      if (current is ConstructorDeclaration && current.constKeyword != null) {
        return true;
      }
      current = current.parent;
    }
    return false;
  }
}
