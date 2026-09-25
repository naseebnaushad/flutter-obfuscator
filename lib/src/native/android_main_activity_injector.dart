import 'dart:io';

import 'package:path/path.dart' as p;

/// Result of locating the project's Kotlin `MainActivity.kt`.
class MainActivityLocation {
  MainActivityLocation({required this.file, required this.packageName});
  final File file;
  final String packageName;
}

/// Shared by [AndroidNativeKeyGenerator] (v2, Kotlin-only) and
/// [AndroidNdkKeyGenerator] (v3, JNI-backed) since both need to find
/// `MainActivity.kt` and inject the same
/// `flutterEngine.plugins.add(ObfuscatorKeyPlugin())` registration —
/// only how `ObfuscatorKeyPlugin` itself is implemented differs between
/// the two.
class AndroidMainActivityInjector {
  static const beginMarker = '// BEGIN FLUTTER_OBFUSCATOR KEY CHANNEL';
  static const endMarker = '// END FLUTTER_OBFUSCATOR KEY CHANNEL';
  static const _engineImport =
      'import io.flutter.embedding.engine.FlutterEngine';

  /// Returns the located file + package name, or a `reason` string if it
  /// couldn't be found/parsed.
  static ({MainActivityLocation? location, String? reason}) locate(
      String projectRoot) {
    final androidMainDir = Directory(
      p.join(projectRoot, 'android', 'app', 'src', 'main'),
    );
    if (!androidMainDir.existsSync()) {
      return (
        location: null,
        reason: 'no android/app/src/main directory found — is this an '
            'Android-enabled Flutter project?',
      );
    }

    final mainActivityKt = androidMainDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => p.basename(f.path) == 'MainActivity.kt')
        .toList();

    if (mainActivityKt.isEmpty) {
      final hasJava = androidMainDir
          .listSync(recursive: true)
          .whereType<File>()
          .any((f) => p.basename(f.path) == 'MainActivity.java');
      return (
        location: null,
        reason: hasJava
            ? 'MainActivity.java found, but only Kotlin MainActivity is '
                'auto-wired — port it to Kotlin, or register '
                'ObfuscatorKeyPlugin manually (see README)'
            : 'no MainActivity.kt found under android/app/src/main',
      );
    }

    final file = mainActivityKt.first;
    final source = file.readAsStringSync();
    final packageMatch =
        RegExp(r'^package\s+([\w.]+)', multiLine: true).firstMatch(source);
    if (packageMatch == null) {
      return (
        location: null,
        reason: 'could not find a package declaration in ${file.path}',
      );
    }

    return (
      location:
          MainActivityLocation(file: file, packageName: packageMatch.group(1)!),
      reason: null,
    );
  }

  /// Returns the rewritten source with `ObfuscatorKeyPlugin` registered,
  /// or `null` if [source] doesn't match a recognized `flutter create`
  /// shape.
  static String? inject(String source) {
    var working = source;

    final markerBlock = RegExp(
      '${RegExp.escape(beginMarker)}[\\s\\S]*?${RegExp.escape(endMarker)}\\n?',
    );
    working = working.replaceAll(markerBlock, '');

    if (!working.contains(_engineImport)) {
      final importExp = RegExp(r"^import\s+[\w.]+\s*$", multiLine: true);
      final matches = importExp.allMatches(working).toList();
      if (matches.isNotEmpty) {
        final lastImportEnd = matches.last.end;
        working = working.replaceRange(
            lastImportEnd, lastImportEnd, '\n$_engineImport');
      } else {
        working = '$_engineImport\n$working';
      }
    }

    final override = '''
    $beginMarker
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(ObfuscatorKeyPlugin())
    }
    $endMarker
''';

    final bodyMatch =
        RegExp(r'class\s+MainActivity\b[^{\n]*\{').firstMatch(working);
    if (bodyMatch != null) {
      final insertAt = bodyMatch.end;
      return working.replaceRange(insertAt, insertAt, '\n$override');
    }

    final noBodyMatch =
        RegExp(r'class\s+MainActivity\b[^{\n]*$', multiLine: true)
            .firstMatch(working);
    if (noBodyMatch != null) {
      final insertAt = noBodyMatch.end;
      return working.replaceRange(insertAt, insertAt, ' {\n$override}\n');
    }

    return null;
  }
}
