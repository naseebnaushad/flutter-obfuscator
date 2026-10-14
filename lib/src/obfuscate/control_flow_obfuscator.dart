import 'dart:io';
import 'dart:math';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'control_flow_result.dart';

/// Adds opaque-predicate noise around `if` branch bodies in
/// `lib/**/*.dart`: `if (cond) body` becomes
/// `if (cond) { if (<always-true expression>) body }`, and likewise for
/// an `else` branch.
///
/// The nested guard's condition is a small arithmetic fact that's always
/// true by construction (a literal compared against the parity it
/// actually has, chosen fresh per site), so the branch still always runs
/// exactly when it did before — the rewrite only adds a layer a static
/// reader has to evaluate to confirm is a no-op, instead of skimming
/// past.
///
/// Deliberately never touches the `if`'s own condition (or its
/// `case` clause, for pattern matching): Dart's flow analysis promotes
/// a variable's type from a condition's exact syntactic shape (`x !=
/// null`, `x is T`, a pattern match, `&&`-chains of those) and loses
/// that promotion the moment the condition's text changes shape — an
/// earlier version of this pass rewrote the condition itself
/// (`cond` -> `(cond) || (<always-false expression>)`) and that silently
/// broke compilation of any real `if (x != null) { ...use x... }`
/// pattern, which is extremely common in real Dart/Flutter code. Wrapping
/// the *body* instead of the condition sidesteps this entirely: the
/// original condition, and therefore any promotion it grants, is never
/// modified.
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

    final collector = _EligibleBranchCollector();
    parseResult.unit.accept(collector);
    if (collector.matches.isEmpty) return;

    // Insertions only (never a range replace): each branch gets an open
    // tag at its start offset and a close tag at its end offset. Unlike
    // replacing a whole range with new text, point insertions stay safe
    // under arbitrary nesting — an `if` inside another `if`'s branch is
    // completely ordinary — because inserting at one offset never
    // invalidates another pending offset, as long as inserts are applied
    // from the highest offset down.
    final insertions = <(int, String)>[];
    for (final branch in collector.matches) {
      insertions.add((branch.offset, '{ if (${_opaqueTruePredicate()}) '));
      insertions.add((branch.end, ' }'));
    }
    insertions.sort((a, b) => b.$1.compareTo(a.$1));

    var updated = source;
    for (final (offset, text) in insertions) {
      updated = updated.replaceRange(offset, offset, text);
    }
    file.writeAsStringSync(updated);

    obfuscatedFiles.add(ObfuscatedControlFlowFileResult(
      filePath: file.path,
      injectedCount: collector.matches.length,
    ));
  }

  /// A fresh, always-true expression: `n % 2 == r` where `r` is the
  /// residue `n % 2` actually produces.
  String _opaqueTruePredicate() {
    final n = _random.nextInt(1 << 20) + 1;
    return '$n % 2 == ${n % 2}';
  }
}

class _EligibleBranchCollector extends RecursiveAstVisitor<void> {
  final List<Statement> matches = [];

  @override
  void visitIfStatement(IfStatement node) {
    matches.add(node.thenStatement);
    final elseStatement = node.elseStatement;
    if (elseStatement != null) {
      matches.add(elseStatement);
    }
    super.visitIfStatement(node);
  }
}
