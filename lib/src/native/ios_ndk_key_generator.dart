import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../crypto/key_split_plan.dart';
import 'ios_app_delegate_injector.dart';
import 'native_injection_result.dart';

/// Generates the iOS half of the v3 native key channel ("v6" in this
/// repo's own build order, since it shipped after certificate pinning):
/// the key material and its XOR-combine logic, plus the ptrace-detection
/// check, live in a compiled C library instead of Swift.
///
/// Swift already compiles to native machine code — there's no
/// bytecode-vs-native jump available here the way there is on Android
/// (DEX vs. a stripped `.so`). What a Swift binary *does* still carry is
/// rich compiler metadata (mangled type/method names, reflection info) a
/// decompiler leans on to reconstruct near-source pseudocode. Plain C —
/// no Objective-C runtime classes, `static` internal helpers so nothing
/// but the two entry points has a linker symbol at all, and
/// `GCC_SYMBOLS_PRIVATE_EXTERN` hiding those too — leaves a decompiler
/// with an anonymous stripped function and no naming/reflection
/// scaffolding to lean on, closer to the Android NDK jump in spirit.
///
/// Wired in as a local CocoaPods pod (`s.static_framework = true`, so
/// Swift can `import` it as a proper module without requiring
/// `use_frameworks!` project-wide) rather than by hand-editing
/// `project.pbxproj` — the same "generate a file, inject one line into
/// existing build config" pattern used for Gradle/CMake and the Android
/// manifest, instead of a fragile binary-plist rewrite.
///
/// Only the standard `flutter create` Podfile/AppDelegate shapes are
/// patched; anything else is reported as skipped with instructions.
class IosNdkKeyGenerator {
  static const _podName = 'FlutterObfuscatorKeyNative';
  static const _beginMarker = '# BEGIN FLUTTER_OBFUSCATOR NDK KEY STORE';
  static const _endMarker = '# END FLUTTER_OBFUSCATOR NDK KEY STORE';
  static final _runnerTarget = RegExp('''target\\s+['"]Runner['"]\\s+do''');

  static NativeInjectionResult generate({
    required String projectRoot,
    required List<int> keyBytes,
    Random? random,
  }) {
    final located = IosAppDelegateInjector.locate(projectRoot);
    if (located.file == null) {
      return NativeInjectionResult(
          platform: 'ios', applied: false, reason: located.reason);
    }
    final appDelegateFile = located.file!;

    final podfileFile = File(p.join(projectRoot, 'ios', 'Podfile'));
    if (!podfileFile.existsSync()) {
      return NativeInjectionResult(
        platform: 'ios',
        applied: false,
        entryPointPath: appDelegateFile.path,
        reason: 'no ios/Podfile found — is this a CocoaPods-enabled iOS '
            'Flutter project?',
      );
    }

    final podDir = Directory(p.join(projectRoot, 'ios', _podName, 'Sources'));
    podDir.createSync(recursive: true);
    File(p.join(podDir.path, 'obfuscator_key.h'))
        .writeAsStringSync(_headerSource());
    File(p.join(podDir.path, 'obfuscator_key.c'))
        .writeAsStringSync(_cSource(keyBytes, random: random));
    File(p.join(projectRoot, 'ios', _podName, '$_podName.podspec'))
        .writeAsStringSync(_podspecSource());

    final pluginFile = File(
        p.join(p.dirname(appDelegateFile.path), 'ObfuscatorKeyPlugin.swift'));
    pluginFile.writeAsStringSync(_pluginSource());

    final podfileSource = podfileFile.readAsStringSync();
    final injectedPodfile = _injectPodfile(podfileSource);
    if (injectedPodfile == null) {
      return NativeInjectionResult(
        platform: 'ios',
        applied: false,
        entryPointPath: appDelegateFile.path,
        pluginFilePath: pluginFile.path,
        reason: '${podfileFile.path} doesn\'t contain a `target \'Runner\' '
            'do` block in the standard `flutter create` shape — '
            '$_podName was generated under ios/$_podName, but you need '
            'to add `pod \'$_podName\', :path => \'$_podName\'` inside '
            'your Runner target yourself, then run `pod install`',
      );
    }
    podfileFile.writeAsStringSync(injectedPodfile);

    final appDelegateSource = appDelegateFile.readAsStringSync();
    final injectedAppDelegate =
        IosAppDelegateInjector.inject(appDelegateSource);
    if (injectedAppDelegate == null) {
      return NativeInjectionResult(
        platform: 'ios',
        applied: false,
        entryPointPath: appDelegateFile.path,
        pluginFilePath: pluginFile.path,
        reason: '${appDelegateFile.path} doesn\'t contain '
            '`GeneratedPluginRegistrant.register(with: self)` in the '
            'standard `flutter create` shape — $_podName and '
            'ObfuscatorKeyPlugin.swift were generated and '
            '${podfileFile.path} was wired, but you need to register the '
            'plugin yourself: call ObfuscatorKeyPlugin.register(with: '
            'self.registrar(forPlugin: "ObfuscatorKeyPlugin")!) inside '
            'application(_:didFinishLaunchingWithOptions:)',
      );
    }
    appDelegateFile.writeAsStringSync(injectedAppDelegate);

    return NativeInjectionResult(
      platform: 'ios',
      applied: true,
      entryPointPath: appDelegateFile.path,
      pluginFilePath: pluginFile.path,
    );
  }

  static String? _injectPodfile(String source) {
    var working = source;

    final markerBlock = RegExp(
      '${RegExp.escape(_beginMarker)}[\\s\\S]*?${RegExp.escape(_endMarker)}\\n?',
    );
    working = working.replaceAll(markerBlock, '');

    final match = _runnerTarget.firstMatch(working);
    if (match == null) return null;

    final podLine = '''

  $_beginMarker
  pod '$_podName', :path => '$_podName'
  $_endMarker
''';

    return working.replaceRange(match.end, match.end, podLine);
  }

  static String _podspecSource() {
    return '''
# GENERATED BY flutter_obfuscator. DO NOT EDIT.
Pod::Spec.new do |s|
  s.name             = '$_podName'
  s.version          = '1.0.0'
  s.summary          = 'Compiled key material store for flutter_obfuscator (key_strategy: native_ndk).'
  s.description      = 'Generated by flutter_obfuscator. Holds the split/XOR-obfuscated vault key and ptrace-detection check in a compiled C library so it carries no Swift/Objective-C metadata a decompiler can use.'
  s.homepage         = 'https://pub.dev/packages/flutter_obfuscator'
  s.license          = { :type => 'Unlicense' }
  s.author           = { 'flutter_obfuscator' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Sources/**/*.{h,c}'
  s.public_header_files = 'Sources/**/*.h'
  s.platform         = :ios, '12.0'
  # Forces this pod (only) to build as a proper framework with a module
  # map, so the generated Swift plugin can `import $_podName` without
  # requiring `use_frameworks!` project-wide.
  s.static_framework = true
  # Internal helpers are already `static` (no linker symbol at all); this
  # additionally strips any incidentally-exported symbol so only the
  # declared public API in obfuscator_key.h survives in the binary.
  s.pod_target_xcconfig = { 'GCC_SYMBOLS_PRIVATE_EXTERN' => 'YES' }
end
''';
  }

  static String _headerSource() {
    return '''
// GENERATED BY flutter_obfuscator. DO NOT EDIT.
#ifndef OBFUSCATOR_KEY_NATIVE_H
#define OBFUSCATOR_KEY_NATIVE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Length in bytes of the key [obfuscator_key_materialize] writes.
int obfuscator_key_length(void);

/// Writes the reconstructed vault key into [out], which must be at least
/// [obfuscator_key_length] bytes.
void obfuscator_key_materialize(uint8_t *out);

/// Nonzero if a debugger or ptrace-based tool (lldb, Frida) is attached
/// to this process.
int obfuscator_key_is_traced(void);

#ifdef __cplusplus
}
#endif

#endif
''';
  }

  static String _cSource(List<int> keyBytes, {Random? random}) {
    final plan = KeySplitPlan.derive(keyBytes, random: random);

    final buffer = StringBuffer();
    buffer.writeln('// GENERATED BY flutter_obfuscator. DO NOT EDIT.');
    buffer.writeln('#include "obfuscator_key.h"');
    buffer.writeln();
    buffer.writeln('#include <stddef.h>');
    buffer.writeln('#include <sys/sysctl.h>');
    buffer.writeln('#include <sys/proc.h>');
    buffer.writeln('#include <unistd.h>');
    buffer.writeln();

    final chunkNames = <String>[];
    final padNames = <String>[];
    for (final chunk in plan.chunks) {
      final chunkName = 'k${_capitalize(chunk.name)}Xor';
      final padName = 'k${_capitalize(chunk.name)}Pad';
      chunkNames.add(chunkName);
      padNames.add(padName);
      buffer.writeln(
          'static const uint8_t $chunkName[] = ${_cArrayLiteral(chunk.xored)};');
      buffer.writeln(
          'static const uint8_t $padName[] = ${_cArrayLiteral(chunk.pad)};');
    }

    buffer.writeln();
    buffer.writeln('int obfuscator_key_length(void) {');
    final sizeTerms = chunkNames.map((n) => 'sizeof($n)').join(' + ');
    buffer.writeln('    return (int)($sizeTerms);');
    buffer.writeln('}');
    buffer.writeln();
    buffer.writeln('void obfuscator_key_materialize(uint8_t *out) {');
    buffer.writeln('    size_t idx = 0;');
    for (var i = 0; i < chunkNames.length; i++) {
      buffer.writeln(
          '    for (size_t i = 0; i < sizeof(${chunkNames[i]}); ++i) {');
      buffer.writeln(
          '        out[idx++] = ${chunkNames[i]}[i] ^ ${padNames[i]}[i];');
      buffer.writeln('    }');
    }
    buffer.writeln('}');
    buffer.writeln();
    buffer.writeln('''
// P_TRACED is set on this process's kinfo_proc whenever a debugger or
// ptrace-based tool (lldb, Frida) is attached.
int obfuscator_key_is_traced(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return 0;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}
''');

    return buffer.toString();
  }

  static String _pluginSource() {
    return '''
// GENERATED BY flutter_obfuscator. DO NOT EDIT.
import Flutter
import Foundation
import $_podName

final class ObfuscatorKeyPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "flutter_obfuscator/key",
            binaryMessenger: registrar.messenger()
        )
        let instance = ObfuscatorKeyPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getKey":
            let length = Int(obfuscator_key_length())
            var buffer = [UInt8](repeating: 0, count: length)
            buffer.withUnsafeMutableBufferPointer { ptr in
                obfuscator_key_materialize(ptr.baseAddress)
            }
            result(FlutterStandardTypedData(bytes: Data(buffer)))
        case "isTraced":
            result(obfuscator_key_is_traced() != 0)
        default:
            result(FlutterMethodNotImplemented)
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
