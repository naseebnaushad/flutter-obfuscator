import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Copies a Flutter project into a staging directory so obfuscation
/// transforms never touch the developer's working tree (reversible,
/// diffable, safe to re-run).
class ProjectStager {
  static const _skipDirs = {'.git', '.dart_tool', 'build', '.idea', '.vscode'};

  /// Copies [sourceRoot] into [stagingRoot] (which is wiped first if it
  /// already exists) and returns the pubspec-declared package name.
  static String stage({
    required String sourceRoot,
    required String stagingRoot,
  }) {
    final stagingDir = Directory(stagingRoot);
    if (stagingDir.existsSync()) {
      stagingDir.deleteSync(recursive: true);
    }
    stagingDir.createSync(recursive: true);

    _copyDir(Directory(sourceRoot), stagingDir);

    return readPackageName(stagingRoot);
  }

  static String readPackageName(String projectRoot) {
    final pubspecFile = File(p.join(projectRoot, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) {
      throw StateError('No pubspec.yaml found at $projectRoot — is this a '
          'Flutter/Dart project?');
    }
    final doc = loadYaml(pubspecFile.readAsStringSync()) as YamlMap;
    final name = doc['name'];
    if (name == null) {
      throw StateError('pubspec.yaml at $projectRoot has no "name" field.');
    }
    return name.toString();
  }

  /// Ensures the staged project's pubspec.yaml declares a dependency on
  /// `cryptography`, which the generated SecretVault/AssetVault runtime
  /// needs. No-ops if it's already present (any version constraint).
  static void ensureRuntimeDependency(String projectRoot) {
    _ensureDependency(projectRoot, 'cryptography', '^2.7.0');
  }

  /// Ensures the staged project's pubspec.yaml declares a dependency on
  /// `crypto`, which the generated `PinnedHttpClient` (v5, certificate
  /// pinning) needs for a synchronous SHA-256 (the `badCertificateCallback`
  /// it hooks into is synchronous, ruling out `package:cryptography`'s
  /// async API). No-ops if it's already present.
  static void ensureCryptoDependency(String projectRoot) {
    _ensureDependency(projectRoot, 'crypto', '^3.0.3');
  }

  static void _ensureDependency(
    String projectRoot,
    String packageName,
    String versionConstraint,
  ) {
    final pubspecFile = File(p.join(projectRoot, 'pubspec.yaml'));
    final source = pubspecFile.readAsStringSync();
    if (RegExp('^\\s*$packageName\\s*:', multiLine: true).hasMatch(source)) {
      return;
    }

    final depsHeader = RegExp(r'^dependencies:\s*$', multiLine: true);
    final match = depsHeader.firstMatch(source);
    if (match == null) {
      throw StateError(
          'pubspec.yaml at $projectRoot has no top-level "dependencies:" '
          'section to add the "$packageName" runtime dependency to.');
    }
    final insertAt = match.end;
    final updated = source.replaceRange(
      insertAt,
      insertAt,
      '\n  $packageName: $versionConstraint',
    );
    pubspecFile.writeAsStringSync(updated);
  }

  static void _copyDir(Directory source, Directory destination) {
    for (final entity in source.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        if (_skipDirs.contains(name)) continue;
        final newDir = Directory(p.join(destination.path, name));
        newDir.createSync();
        _copyDir(entity, newDir);
      } else if (entity is File) {
        final newFile = File(p.join(destination.path, name));
        entity.copySync(newFile.path);
      }
    }
  }
}
