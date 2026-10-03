import 'dart:io';
import 'dart:math';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'control_flow_result.dart';

/// Adds opaque-predicate noise to plain `if` conditions in `lib/**/*.dart`:
/// `if (cond) ...` becomes `if ((cond) || (<always-false expression>)) ...`.
///
/// The appended disjunct is a small arithmetic fact that's always false by
/// construction (a literal compared against the parity it doesn't have,
/// chosen fresh per site), and `||` only evaluates it when `cond` is
/// false — it has no side effects and never changes which branch runs, so
/// the rewrite is behavior-preserving. It just means a static reader (or a
/// decompiler) can no longer tell real conditions from noise without
/// actually evaluating each one, instead of skimming past an obviously
/// redundant check. `if (x case Pattern())` is left untouched, since its
/// condition is a pattern match rather than a plain boolean expression,
/// and bare `if (true)`/`if (false)` dead-code switches some projects rely
/// on are left as-is too — the appended disjunct only changes the
/// condition's *text*, never its truth value, so those still behave
/// exactly as before either way. A constant-folding compiler could still
/// strip this; see README "Known limitations".
class ControlFlowObfuscator {
  ControlFlowObfuscator({Random? random}) : _random = random ?? Random();

  final List<ObfuscatedControlFlowFileResult> obfuscatedFiles = [];
  final Random _random;

  void obfuscateDirectory(
    String libDir, {
    required List<String> excludeGlobs,
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

    final collector = _EligibleConditionCollector();
    parseResult.unit.accept(collector);
    if (collector.matches.isEmpty) return;

    collector.matches.sort((a, b) => b.offset.compareTo(a.offset));
    var updated = source;
    for (final condition in collector.matches) {
      final original = source.substring(condition.offset, condition.end);
      updated = updated.replaceRange(
        condition.offset,
        condition.end,
        '($original) || (${_opaqueFalsePredicate()})',
      );
    }
    file.writeAsStringSync(updated);

    obfuscatedFiles.add(ObfuscatedControlFlowFileResult(
      filePath: file.path,
      injectedCount: collector.matches.length,
    ));
  }

  /// A fresh, always-false expression: `n % 2 == r` where `r` is the
  /// residue `n % 2` never actually produces.
  String _opaqueFalsePredicate() {
    final n = _random.nextInt(1 << 20) + 1;
    final falseResidue = n.isEven ? 1 : 0;
    return '$n % 2 == $falseResidue';
  }
}

class _EligibleConditionCollector extends RecursiveAstVisitor<void> {
  final List<Expression> matches = [];

  @override
  void visitIfStatement(IfStatement node) {
    if (node.caseClause == null) {
      matches.add(node.expression);
    }
    super.visitIfStatement(node);
  }
}
