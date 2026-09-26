import 'dart:io';

import 'package:path/path.dart' as p;

/// Shared by [IosNativeKeyGenerator] (v2, Swift-only) and
/// [IosNdkKeyGenerator] (v6, compiled-C-backed) since both need to find
/// `AppDelegate.swift` and inject the same
/// `ObfuscatorKeyPlugin.register(with: ...)` call — only how
/// `ObfuscatorKeyPlugin` itself is implemented differs between the two.
class IosAppDelegateInjector {
  static const beginMarker = '// BEGIN FLUTTER_OBFUSCATOR KEY CHANNEL';
  static const endMarker = '// END FLUTTER_OBFUSCATOR KEY CHANNEL';
  static final _registrantCall =
      RegExp(r'GeneratedPluginRegistrant\.register\(with:\s*self\)[ \t]*\n?');

  /// Returns the located `AppDelegate.swift` file, or a `reason` string if
  /// it couldn't be found.
  static ({File? file, String? reason}) locate(String projectRoot) {
    final runnerDir = Directory(p.join(projectRoot, 'ios', 'Runner'));
    if (!runnerDir.existsSync()) {
      return (
        file: null,
        reason: 'no ios/Runner directory found — is this an iOS-enabled '
            'Flutter project?',
      );
    }

    final appDelegateFile = File(p.join(runnerDir.path, 'AppDelegate.swift'));
    if (!appDelegateFile.existsSync()) {
      return (
        file: null,
        reason: 'no ios/Runner/AppDelegate.swift found (an Objective-C '
            'AppDelegate.m project is not auto-wired — register '
            'ObfuscatorKeyPlugin manually, see README)',
      );
    }

    return (file: appDelegateFile, reason: null);
  }

  /// Returns the rewritten source with `ObfuscatorKeyPlugin` registered
  /// right after `GeneratedPluginRegistrant.register(with: self)`, or
  /// `null` if [source] doesn't match the standard `flutter create` shape.
  static String? inject(String source) {
    var working = source;

    final markerBlock = RegExp(
      '${RegExp.escape(beginMarker)}[\\s\\S]*?${RegExp.escape(endMarker)}\\n?',
    );
    working = working.replaceAll(markerBlock, '');

    final match = _registrantCall.firstMatch(working);
    if (match == null) return null;

    final registration = '''
    $beginMarker
    ObfuscatorKeyPlugin.register(with: self.registrar(forPlugin: "ObfuscatorKeyPlugin")!)
    $endMarker
''';

    return working.replaceRange(match.end, match.end, registration);
  }
}
