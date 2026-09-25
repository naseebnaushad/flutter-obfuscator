import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:glob/glob.dart';

import '../config/obfuscator_config.dart';
import '../crypto/vault_crypto.dart';
import '../secrets/entropy.dart';
import 'secret_finding.dart';

/// Scans a Flutter/Dart project for hardcoded secret-like string
/// declarations, encrypts them, and rewrites the source in place (on a
/// staged copy of the project — callers are responsible for staging).
class SecretScanner {
  SecretScanner(this.config, this.keyBytes, this.packageName);

  final ObfuscatorConfig config;
  final List<int> keyBytes;

  /// The target project's own package name (from its pubspec.yaml),
  /// used to build the `package:<name>/...` import for the generated
  /// vault so it works regardless of which file is being rewritten.
  final String packageName;

  final List<SecretFinding> findings = [];
  final List<SkippedCandidate> skipped = [];

  static const _minLiteralLength = 6;

  Future<void> scanDirectory(String libDir) async {
    if (!Directory(libDir).existsSync()) return;

    final excludeGlobs = config.excludeFiles.map((g) => Glob(g)).toList();

    final files = Directory(libDir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !excludeGlobs.any((g) => g.matches(f.path)))
        .toList();

    for (final file in files) {
      await _scanFile(file);
    }
  }

  Future<void> _scanFile(File file) async {
    final source = file.readAsStringSync();
    final parseResult = parseString(
      content: source,
      path: file.path,
      throwIfDiagnostics: false,
    );

    final edits = <_Edit>[];
    var needsImport = false;

    for (final declaration in parseResult.unit.declarations) {
      if (declaration is TopLevelVariableDeclaration) {
        final edit = await _tryTransform(
          file.path,
          declaration.variables,
          declaration.metadata,
          isStatic: false,
          nodeOffset: declaration.offset,
          nodeEnd: declaration.end,
        );
        if (edit != null) {
          edits.add(edit);
          needsImport = true;
        }
      } else if (declaration is ClassDeclaration) {
        for (final member in declaration.members) {
          if (member is FieldDeclaration) {
            final edit = await _tryTransform(
              file.path,
              member.fields,
              member.metadata,
              isStatic: member.isStatic,
              nodeOffset: member.offset,
              nodeEnd: member.end,
            );
            if (edit != null) {
              edits.add(edit);
              needsImport = true;
            }
          }
        }
      }
    }

    if (edits.isEmpty) return;

    edits.sort((a, b) => b.offset.compareTo(a.offset));
    var updated = source;
    for (final edit in edits) {
      updated = updated.replaceRange(edit.offset, edit.end, edit.replacement);
    }

    if (needsImport) {
      updated = _ensureVaultImport(updated, packageName);
    }

    file.writeAsStringSync(updated);
  }

  Future<_Edit?> _tryTransform(
    String filePath,
    VariableDeclarationList list,
    NodeList<Annotation> metadata, {
    required bool isStatic,
    required int nodeOffset,
    required int nodeEnd,
  }) async {
    if (list.variables.length != 1) {
      for (final v in list.variables) {
        if (config.nameLooksLikeSecret(v.name.lexeme)) {
          skipped.add(SkippedCandidate(
            filePath: filePath,
            variableName: v.name.lexeme,
            reason: 'multiple variables in one declaration; '
                'split into separate declarations to auto-obfuscate',
          ));
        }
      }
      return null;
    }

    final variable = list.variables.single;
    final initializer = variable.initializer;
    if (initializer is! SimpleStringLiteral) return null;

    final name = variable.name.lexeme;
    final value = initializer.value;
    final hasAnnotation = metadata.any(
      (a) => config.secretAnnotations.contains(a.name.name),
    );
    final looksLikeSecret = config.nameLooksLikeSecret(name);

    if (!hasAnnotation && !looksLikeSecret) return null;

    if (value.length < _minLiteralLength) {
      skipped.add(SkippedCandidate(
        filePath: filePath,
        variableName: name,
        reason: 'literal too short (${value.length} chars) to be a secret',
      ));
      return null;
    }

    if (!hasAnnotation && shannonEntropy(value) < config.minEntropy) {
      skipped.add(SkippedCandidate(
        filePath: filePath,
        variableName: name,
        reason: 'name matched a secret pattern but entropy '
            '(${shannonEntropy(value).toStringAsFixed(2)}) is below '
            'threshold (${config.minEntropy}); looks like a non-secret '
            'string',
      ));
      return null;
    }

    final id = _idFor(filePath, name, nodeOffset);
    final entry = await VaultCrypto.encryptString(value, keyBytes);

    findings.add(SecretFinding(
      id: id,
      filePath: filePath,
      variableName: name,
      plainText: value,
      entry: entry,
    ));

    final staticPrefix = isStatic ? 'static ' : '';
    final replacement = "$staticPrefix"
        "final String $name = SecretVault.get('$id');";

    return _Edit(offset: nodeOffset, end: nodeEnd, replacement: replacement);
  }

  static String _idFor(String filePath, String name, int offset) {
    final basis = '$filePath:$name:$offset';
    return basis.hashCode.toUnsigned(32).toRadixString(16).padLeft(8, '0');
  }

  static String _ensureVaultImport(String source, String packageName) {
    final importLine =
        "import 'package:$packageName/flutter_obfuscator/secret_vault.g.dart';";
    if (source.contains(importLine)) return source;

    final importExp = RegExp(r"^import\s+'[^']+';\s*$", multiLine: true);
    final matches = importExp.allMatches(source).toList();
    if (matches.isEmpty) {
      return '$importLine\n$source';
    }
    final lastMatch = matches.last;
    return source.replaceRange(
      lastMatch.end,
      lastMatch.end,
      '\n$importLine',
    );
  }
}

class _Edit {
  _Edit({required this.offset, required this.end, required this.replacement});
  final int offset;
  final int end;
  final String replacement;
}
