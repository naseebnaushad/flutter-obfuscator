import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../crypto/key_split_plan.dart';
import 'android_main_activity_injector.dart';
import 'native_injection_result.dart';

/// Generates the Android half of the v3 native key channel: the key
/// material and its XOR-combine logic live in a compiled C++ library
/// (JNI, built via CMake/NDK) instead of Kotlin.
///
/// Kotlin compiles to DEX, which JADX decompiles back to near-original
/// source in seconds; a stripped `.so` requires disassembly
/// (objdump/Ghidra/IDA) instead — meaningfully higher effort, though
/// still not out of reach for a determined reverse engineer, and this
/// still does nothing against a Frida hook on the JNI call at runtime.
///
/// Reuses [AndroidMainActivityInjector] for the `MainActivity.kt` wiring
/// (identical to v2's [AndroidNativeKeyGenerator]); only
/// `ObfuscatorKeyPlugin`'s implementation differs.
///
/// Writes its own isolated CMake project under
/// `android/app/src/main/cpp/flutter_obfuscator/` rather than touching
/// any existing native code the project has, and uses JNI's
/// `RegisterNatives` (via `JNI_OnLoad`) instead of the mangled
/// `Java_pkg_Class_method` naming convention, so it works regardless of
/// underscores in the package name. Since Android Gradle Plugin only
/// supports one `externalNativeBuild` per module, a project that already
/// configures one is left untouched and reported as skipped.
class AndroidNdkKeyGenerator {
  static const _cmakeRelPath = 'src/main/cpp/flutter_obfuscator/CMakeLists.txt';
  static const _beginMarker = '// BEGIN FLUTTER_OBFUSCATOR NDK KEY STORE';
  static const _endMarker = '// END FLUTTER_OBFUSCATOR NDK KEY STORE';

  static NativeInjectionResult generate({
    required String projectRoot,
    required List<int> keyBytes,
    Random? random,
  }) {
    final located = AndroidMainActivityInjector.locate(projectRoot);
    if (located.location == null) {
      return NativeInjectionResult(
          platform: 'android', applied: false, reason: located.reason);
    }
    final mainActivityFile = located.location!.file;
    final packageName = located.location!.packageName;
    final classPath = packageName.replaceAll('.', '/');

    final buildGradle = _findBuildGradle(projectRoot);
    if (buildGradle == null) {
      return NativeInjectionResult(
        platform: 'android',
        applied: false,
        entryPointPath: mainActivityFile.path,
        reason: 'no android/app/build.gradle(.kts) found to wire the NDK '
            'build into',
      );
    }
    final gradleSource = buildGradle.readAsStringSync();
    if (gradleSource.contains('externalNativeBuild') &&
        !gradleSource.contains(_beginMarker)) {
      return NativeInjectionResult(
        platform: 'android',
        applied: false,
        entryPointPath: mainActivityFile.path,
        reason: '${buildGradle.path} already configures '
            'externalNativeBuild — Android Gradle Plugin only supports '
            'one CMake project per module, so flutter_obfuscator left it '
            'alone. Merge the generated CMakeLists.txt at '
            'android/app/$_cmakeRelPath into your existing native build '
            'manually.',
      );
    }

    final cppDir = Directory(p.join(projectRoot, 'android', 'app', 'src',
        'main', 'cpp', 'flutter_obfuscator'));
    cppDir.createSync(recursive: true);
    File(p.join(cppDir.path, 'obfuscator_key.cpp'))
        .writeAsStringSync(_cppSource(classPath, keyBytes, random: random));
    File(p.join(cppDir.path, 'CMakeLists.txt'))
        .writeAsStringSync(_cmakeSource());

    final pluginFile = File(
        p.join(p.dirname(mainActivityFile.path), 'ObfuscatorKeyPlugin.kt'));
    pluginFile.writeAsStringSync(_pluginSource(packageName));

    final injectedGradle = _injectBuildGradle(gradleSource,
        isKts: buildGradle.path.endsWith('.kts'));
    buildGradle.writeAsStringSync(injectedGradle);

    final injectedActivity =
        AndroidMainActivityInjector.inject(mainActivityFile.readAsStringSync());
    if (injectedActivity == null) {
      return NativeInjectionResult(
        platform: 'android',
        applied: false,
        entryPointPath: mainActivityFile.path,
        pluginFilePath: pluginFile.path,
        reason: '${mainActivityFile.path} doesn\'t match the standard '
            '`flutter create` MainActivity shape — CMake/JNI files and '
            'ObfuscatorKeyPlugin.kt were generated and wired into '
            '${buildGradle.path}, but you need to register the plugin '
            'yourself: override configureFlutterEngine and call '
            'flutterEngine.plugins.add(ObfuscatorKeyPlugin())',
      );
    }
    mainActivityFile.writeAsStringSync(injectedActivity);

    return NativeInjectionResult(
      platform: 'android',
      applied: true,
      entryPointPath: mainActivityFile.path,
      pluginFilePath: pluginFile.path,
    );
  }

  static File? _findBuildGradle(String projectRoot) {
    final kts = File(p.join(projectRoot, 'android', 'app', 'build.gradle.kts'));
    if (kts.existsSync()) return kts;
    final groovy = File(p.join(projectRoot, 'android', 'app', 'build.gradle'));
    if (groovy.existsSync()) return groovy;
    return null;
  }

  static String _injectBuildGradle(String source, {required bool isKts}) {
    var working = source;
    final markerBlock = RegExp(
      '${RegExp.escape(_beginMarker)}[\\s\\S]*?${RegExp.escape(_endMarker)}\\n?',
    );
    working = working.replaceAll(markerBlock, '');

    final block = isKts
        ? '''
    $_beginMarker
    externalNativeBuild {
        cmake {
            path = file("$_cmakeRelPath")
        }
    }
    $_endMarker
'''
        : '''
    $_beginMarker
    externalNativeBuild {
        cmake {
            path "$_cmakeRelPath"
        }
    }
    $_endMarker
''';

    final androidBlock =
        RegExp(r'^android\s*\{', multiLine: true).firstMatch(working);
    if (androidBlock == null) {
      // No recognizable `android {` block — append at the end as a
      // last resort; Gradle will surface a clear error if this doesn't
      // parse, which is preferable to silently doing nothing given we
      // already generated the native files.
      return '$working\n$block';
    }
    final insertAt = androidBlock.end;
    return working.replaceRange(insertAt, insertAt, '\n$block');
  }

  static String _cmakeSource() {
    return '''
# GENERATED BY flutter_obfuscator. DO NOT EDIT.
cmake_minimum_required(VERSION 3.10.2)
project("obfuscator_key")
add_library(obfuscator_key SHARED obfuscator_key.cpp)
''';
  }

  static String _cppSource(
    String classPath,
    List<int> keyBytes, {
    Random? random,
  }) {
    final plan = KeySplitPlan.derive(keyBytes, random: random);

    final buffer = StringBuffer();
    buffer.writeln('// GENERATED BY flutter_obfuscator. DO NOT EDIT.');
    buffer.writeln('#include <jni.h>');
    buffer.writeln('#include <cstdint>');
    buffer.writeln('#include <vector>');
    buffer.writeln();
    buffer.writeln('namespace {');
    buffer.writeln();

    final chunkNames = <String>[];
    final padNames = <String>[];
    for (final chunk in plan.chunks) {
      final chunkName = 'k${_capitalize(chunk.name)}Xor';
      final padName = 'k${_capitalize(chunk.name)}Pad';
      chunkNames.add(chunkName);
      padNames.add(padName);
      buffer.writeln(
          'const uint8_t $chunkName[] = ${_cArrayLiteral(chunk.xored)};');
      buffer
          .writeln('const uint8_t $padName[] = ${_cArrayLiteral(chunk.pad)};');
    }

    buffer.writeln();
    buffer.writeln('std::vector<uint8_t> Materialize() {');
    buffer.writeln('    std::vector<uint8_t> out;');
    for (var i = 0; i < chunkNames.length; i++) {
      buffer.writeln(
          '    for (size_t i = 0; i < sizeof(${chunkNames[i]}); ++i) {');
      buffer.writeln(
          '        out.push_back(${chunkNames[i]}[i] ^ ${padNames[i]}[i]);');
      buffer.writeln('    }');
    }
    buffer.writeln('    return out;');
    buffer.writeln('}');
    buffer.writeln();
    buffer.writeln('''
jbyteArray NativeMaterializeKey(JNIEnv* env, jobject /* thiz */) {
    std::vector<uint8_t> key = Materialize();
    jbyteArray result = env->NewByteArray(static_cast<jsize>(key.size()));
    env->SetByteArrayRegion(result, 0, static_cast<jsize>(key.size()),
                             reinterpret_cast<const jbyte*>(key.data()));
    return result;
}

const JNINativeMethod kMethods[] = {
    {const_cast<char*>("nativeMaterializeKey"), const_cast<char*>("()[B"),
     reinterpret_cast<void*>(NativeMaterializeKey)},
};

}  // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /* reserved */) {
    JNIEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }
    jclass clazz = env->FindClass("$classPath/ObfuscatorKeyPlugin");
    if (clazz == nullptr) {
        return JNI_ERR;
    }
    if (env->RegisterNatives(clazz, kMethods, 1) != JNI_OK) {
        return JNI_ERR;
    }
    return JNI_VERSION_1_6;
}
''');

    return buffer.toString();
  }

  static String _pluginSource(String packageName) {
    return '''
// GENERATED BY flutter_obfuscator. DO NOT EDIT.
package $packageName

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class ObfuscatorKeyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    private external fun nativeMaterializeKey(): ByteArray

    companion object {
        init {
            System.loadLibrary("obfuscator_key")
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "flutter_obfuscator/key")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "getKey") {
            result.success(nativeMaterializeKey())
        } else {
            result.notImplemented()
        }
    }
}
''';
  }

  static String _cArrayLiteral(List<int> bytes) {
    final literals =
        bytes.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}');
    return '{${literals.join(', ')}}';
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}
