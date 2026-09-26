import 'dart:io';

import 'package:yaml/yaml.dart';

import '../crypto/key_strategy.dart';
import 'tamper_config.dart';

/// Parsed contents of `obfuscator.yaml`.
class ObfuscatorConfig {
  ObfuscatorConfig({
    required this.secretPatterns,
    required this.secretAnnotations,
    required this.minEntropy,
    required this.excludeFiles,
    required this.assetIncludes,
    required this.assetExcludes,
    required this.keyStrategy,
    TamperConfig? tamperDetection,
  }) : tamperDetection = tamperDetection ?? TamperConfig.disabled();

  final List<RegExp> secretPatterns;
  final List<String> secretAnnotations;
  final double minEntropy;
  final List<String> excludeFiles;
  final List<String> assetIncludes;
  final List<String> assetExcludes;

  /// Where the vault key lives at runtime. Defaults to [KeyStrategy.dartSplit]
  /// (v1, unchanged behavior); set `key_strategy: native_channel` in
  /// obfuscator.yaml to opt into the v2 native platform-channel key.
  final KeyStrategy keyStrategy;

  /// v4, opt-in: root/jailbreak/Frida detection gating `SecretVault`/
  /// `AssetVault` decryption. Disabled by default.
  final TamperConfig tamperDetection;

  static const List<String> _defaultPatternStrings = [
    r'api[_-]?key',
    r'apikey',
    r'secret',
    r'token',
    r'password',
    r'auth[_-]?key',
    r'client[_-]?secret',
    r'access[_-]?key',
    r'private[_-]?key',
  ];

  factory ObfuscatorConfig.defaults() => ObfuscatorConfig(
        secretPatterns: _defaultPatternStrings
            .map((p) => RegExp(p, caseSensitive: false))
            .toList(),
        secretAnnotations: const ['Secret'],
        minEntropy: 3.0,
        excludeFiles: const ['**/*.g.dart', '**/*.freezed.dart'],
        assetIncludes: const [],
        assetExcludes: const [],
        keyStrategy: KeyStrategy.dartSplit,
      );

  /// Loads config from [path] if it exists, otherwise returns defaults.
  factory ObfuscatorConfig.load(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return ObfuscatorConfig.defaults();
    }

    final doc = loadYaml(file.readAsStringSync());
    if (doc == null) return ObfuscatorConfig.defaults();
    final map = Map<String, dynamic>.from(doc as YamlMap);

    final secrets = map['secrets'] is YamlMap
        ? Map<String, dynamic>.from(map['secrets'] as YamlMap)
        : <String, dynamic>{};
    final assets = map['assets'] is YamlMap
        ? Map<String, dynamic>.from(map['assets'] as YamlMap)
        : <String, dynamic>{};

    final patternStrings =
        _stringList(secrets['patterns']) ?? _defaultPatternStrings;
    final annotations = _stringList(secrets['annotations']) ?? const ['Secret'];
    final minEntropy = (secrets['min_entropy'] as num?)?.toDouble() ?? 3.0;
    final excludeFiles = _stringList(secrets['exclude_files']) ??
        const ['**/*.g.dart', '**/*.freezed.dart'];

    final assetIncludes = _stringList(assets['include']) ?? const [];
    final assetExcludes = _stringList(assets['exclude']) ?? const [];
    final keyStrategy = KeyStrategy.parse(map['key_strategy'] as String?);

    final tamperMap = map['tamper_detection'] is YamlMap
        ? Map<String, dynamic>.from(map['tamper_detection'] as YamlMap)
        : <String, dynamic>{};
    final tamperDetection = TamperConfig(
      enabled: tamperMap['enabled'] as bool? ?? false,
      mode: TamperMode.parse(tamperMap['mode'] as String?),
    );

    return ObfuscatorConfig(
      secretPatterns:
          patternStrings.map((p) => RegExp(p, caseSensitive: false)).toList(),
      secretAnnotations: annotations,
      minEntropy: minEntropy,
      excludeFiles: excludeFiles,
      assetIncludes: assetIncludes,
      assetExcludes: assetExcludes,
      keyStrategy: keyStrategy,
      tamperDetection: tamperDetection,
    );
  }

  static List<String>? _stringList(dynamic value) {
    if (value == null) return null;
    if (value is YamlList) {
      return value.map((e) => e.toString()).toList();
    }
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    return null;
  }

  bool nameLooksLikeSecret(String identifierName) {
    return secretPatterns.any((p) => p.hasMatch(identifierName));
  }
}
