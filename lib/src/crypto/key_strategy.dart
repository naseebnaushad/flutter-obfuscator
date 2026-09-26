/// Where the AES key used by SecretVault/AssetVault lives at runtime.
enum KeyStrategy {
  /// v1: the key is split into several XORed, misleadingly-named Dart
  /// constants (`_obf_key_material.g.dart`). Still resident in the Dart
  /// snapshot — defeats plain strings/grep, not a Dart-snapshot-aware
  /// reverse-engineering tool.
  dartSplit,

  /// v2: the key is generated and held in native code (Kotlin on
  /// Android, Swift on iOS) and fetched over a MethodChannel. Removes
  /// the key from the Dart AOT snapshot entirely, so tools that dump
  /// Dart snapshot data (e.g. blutter-style extractors) no longer
  /// recover it — the key now has to be pulled from the native
  /// binary/DEX instead, which is a different attack surface than the
  /// Dart obfuscation this whole tool otherwise targets.
  nativeChannel,

  /// v3/v6: same MethodChannel shape as [nativeChannel], but the key
  /// material and its XOR-combine logic live in compiled C instead of
  /// Kotlin/Swift, on both platforms. On Android that's a jump from DEX
  /// (which JADX decompiles back to near-original source trivially) to a
  /// stripped `.so` requiring disassembly (objdump/Ghidra/IDA) instead —
  /// a meaningfully higher bar. Swift already compiles to native machine
  /// code, so there's no equivalent bytecode-vs-native jump on iOS; the
  /// gain there is denying a decompiler the rich Swift metadata
  /// (mangled type/method names, reflection info) it otherwise leans on
  /// — plain, `static`-internal C with hidden symbol visibility leaves
  /// only an anonymous stripped function.
  nativeNdk;

  static KeyStrategy parse(String? value) {
    switch (value) {
      case null:
      case 'dart_split':
        return KeyStrategy.dartSplit;
      case 'native_channel':
        return KeyStrategy.nativeChannel;
      case 'native_ndk':
        return KeyStrategy.nativeNdk;
      default:
        throw FormatException(
          'Unknown key_strategy "$value". Expected "dart_split", '
          '"native_channel", or "native_ndk".',
        );
    }
  }

  /// Whether the Dart-side vault should fetch the key over
  /// `NativeKeyChannel` (any native strategy) instead of reconstructing
  /// it from Dart constants ([dartSplit]).
  bool get usesNativeChannel => this != KeyStrategy.dartSplit;
}
