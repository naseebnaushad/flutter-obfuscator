/// Parsed `identifiers:` section of `obfuscator.yaml` (v8, opt-in).
class IdentifierObfuscationConfig {
  const IdentifierObfuscationConfig({required this.enabled});

  final bool enabled;

  factory IdentifierObfuscationConfig.disabled() =>
      const IdentifierObfuscationConfig(enabled: false);
}
