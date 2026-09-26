/// What to do when [TamperGuard] (the generated runtime checker) sees a
/// root/jailbreak/Frida signal.
enum TamperMode {
  /// Refuse to decrypt (`SecretVault`/`AssetVault` throw
  /// `TamperDetectedException`) — the default once tamper detection is on.
  block,

  /// Print a warning and decrypt anyway. Useful while rolling this out,
  /// so a false positive on one device doesn't brick the app.
  log;

  static TamperMode parse(String? value) {
    switch (value) {
      case null:
      case 'block':
        return TamperMode.block;
      case 'log':
        return TamperMode.log;
      default:
        throw FormatException(
          'Unknown tamper_detection.mode "$value" (expected "block" or '
          '"log")',
        );
    }
  }
}

/// Parsed `tamper_detection:` section of `obfuscator.yaml` (v4, opt-in).
class TamperConfig {
  const TamperConfig({required this.enabled, required this.mode});

  final bool enabled;
  final TamperMode mode;

  factory TamperConfig.disabled() =>
      const TamperConfig(enabled: false, mode: TamperMode.block);
}
