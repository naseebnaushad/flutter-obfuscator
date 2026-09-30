/// Parsed `strings:` section of `obfuscator.yaml` (v9, opt-in).
class StringObfuscationConfig {
  const StringObfuscationConfig(
      {required this.enabled, required this.minLength});

  final bool enabled;

  /// String literals shorter than this (by character count) are left
  /// alone — not worth the runtime indirection for `''`/`' '`/single
  /// punctuation.
  final int minLength;

  factory StringObfuscationConfig.disabled() =>
      const StringObfuscationConfig(enabled: false, minLength: 4);
}
