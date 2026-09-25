import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../crypto/key_split_plan.dart';
import 'native_injection_result.dart';

/// Generates the Android half of the v2 native key channel: a Kotlin
/// object holding a split/XOR-obfuscated copy of the vault key plus a
/// `FlutterPlugin` exposing it over the `flutter_obfuscator/key`
/// MethodChannel, and injects its registration into `MainActivity.kt`.
///
/// Only Kotlin `MainActivity` files matching the standard `flutter
/// create` shape are patched; anything else is reported as skipped with
/// instructions rather than risking a broken build.
class AndroidNativeKeyGenerator {
  static const _beginMarker = '// BEGIN FLUTTER_OBFUSCATOR KEY CHANNEL';
  static const _endMarker = '// END FLUTTER_OBFUSCATOR KEY CHANNEL';
  static const _engineImport =
      'import io.flutter.embedding.engine.FlutterEngine';

  static NativeInjectionResult generate({
    required String projectRoot,
    required List<int> keyBytes,
    Random? random,
  }) {
    final androidMainDir = Directory(
      p.join(projectRoot, 'android', 'app', 'src', 'main'),
    );
    if (!androidMainDir.existsSync()) {
      return NativeInjectionResult(
        platform: 'android',
        applied: false,
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
      return NativeInjectionResult(
        platform: 'android',
        applied: false,
        reason: hasJava
            ? 'MainActivity.java found, but only Kotlin MainActivity is '
                'auto-wired in v2 — port it to Kotlin, or register '
                'ObfuscatorKeyPlugin manually (see README)'
            : 'no MainActivity.kt found under android/app/src/main',
      );
    }

    final mainActivityFile = mainActivityKt.first;
    final activitySource = mainActivityFile.readAsStringSync();

    final packageMatch = RegExp(r'^package\s+([\w.]+)', multiLine: true)
        .firstMatch(activitySource);
    if (packageMatch == null) {
      return NativeInjectionResult(
        platform: 'android',
        applied: false,
        entryPointPath: mainActivityFile.path,
        reason: 'could not find a package declaration in '
            '${mainActivityFile.path}',
      );
    }
    final packageName = packageMatch.group(1)!;

    final pluginFile = File(
        p.join(p.dirname(mainActivityFile.path), 'ObfuscatorKeyPlugin.kt'));
    pluginFile.writeAsStringSync(
      _pluginSource(packageName, keyBytes, random: random),
    );

    final injected = _injectIntoMainActivity(activitySource);
    if (injected == null) {
      return NativeInjectionResult(
        platform: 'android',
        applied: false,
        entryPointPath: mainActivityFile.path,
        pluginFilePath: pluginFile.path,
        reason: '${mainActivityFile.path} doesn\'t match the standard '
            '`flutter create` MainActivity shape (class MainActivity : '
            'FlutterActivity() { ... }) — ObfuscatorKeyPlugin.kt was '
            'generated, but you need to register it yourself: override '
            'configureFlutterEngine and call '
            'flutterEngine.plugins.add(ObfuscatorKeyPlugin())',
      );
    }
    mainActivityFile.writeAsStringSync(injected);

    return NativeInjectionResult(
      platform: 'android',
      applied: true,
      entryPointPath: mainActivityFile.path,
      pluginFilePath: pluginFile.path,
    );
  }

  static String? _injectIntoMainActivity(String source) {
    var working = source;

    final markerBlock = RegExp(
      '${RegExp.escape(_beginMarker)}[\\s\\S]*?${RegExp.escape(_endMarker)}\\n?',
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
    $_beginMarker
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(ObfuscatorKeyPlugin())
    }
    $_endMarker
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

  static String _pluginSource(
    String packageName,
    List<int> keyBytes, {
    Random? random,
  }) {
    final plan = KeySplitPlan.derive(keyBytes, random: random);

    final buffer = StringBuffer();
    buffer.writeln('// GENERATED BY flutter_obfuscator. DO NOT EDIT.');
    buffer.writeln('package $packageName');
    buffer.writeln();
    buffer.writeln('import io.flutter.embedding.engine.plugins.FlutterPlugin');
    buffer.writeln('import io.flutter.plugin.common.MethodCall');
    buffer.writeln('import io.flutter.plugin.common.MethodChannel');
    buffer.writeln();
    buffer.writeln('private object ObfKeyMaterial {');

    final chunkNames = <String>[];
    final padNames = <String>[];
    for (final chunk in plan.chunks) {
      final chunkName = '_${chunk.name}Xor';
      final padName = '_${chunk.name}Pad';
      chunkNames.add(chunkName);
      padNames.add(padName);
      buffer.writeln(
          '    private val $chunkName = ${_byteArrayLiteral(chunk.xored)}');
      buffer.writeln(
          '    private val $padName = ${_byteArrayLiteral(chunk.pad)}');
    }

    buffer.writeln();
    buffer.writeln('    fun materialize(): ByteArray {');
    buffer.writeln('        val out = ArrayList<Byte>()');
    for (var i = 0; i < chunkNames.length; i++) {
      buffer.writeln('        for (i in ${chunkNames[i]}.indices) {');
      buffer.writeln(
          '            out.add((${chunkNames[i]}[i].toInt() xor ${padNames[i]}[i].toInt()).toByte())');
      buffer.writeln('        }');
    }
    buffer.writeln('        return out.toByteArray()');
    buffer.writeln('    }');
    buffer.writeln('}');
    buffer.writeln();
    buffer.writeln('''
class ObfuscatorKeyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "flutter_obfuscator/key")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "getKey") {
            result.success(ObfKeyMaterial.materialize())
        } else {
            result.notImplemented()
        }
    }
}
''');

    return buffer.toString();
  }

  static String _byteArrayLiteral(List<int> bytes) {
    final literals =
        bytes.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}.toByte()');
    return 'byteArrayOf(${literals.join(', ')})';
  }
}
