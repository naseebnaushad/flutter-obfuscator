import 'dart:math';

/// One chunk of a split/XOR-obfuscated key: `xored[i] == original[i] ^
/// pad[i]`. Shared by the Dart, Kotlin, and Swift key-material emitters
/// so all three encode a key the same (weak-but-better-than-one-constant)
/// way instead of duplicating this logic per language.
class KeySplitChunk {
  KeySplitChunk({required this.name, required this.xored, required this.pad});

  /// An innocuous-looking base name (e.g. `themeFlags`) the emitter turns
  /// into two identifiers, e.g. `_themeFlagsXor` / `_themeFlagsPad`.
  final String name;
  final List<int> xored;
  final List<int> pad;
}

class KeySplitPlan {
  KeySplitPlan(this.chunks);

  final List<KeySplitChunk> chunks;

  static const int chunkCount = 4;

  static const List<String> fakeNamePool = [
    'themeFlags',
    'layoutMetrics',
    'featureToggleTable',
    'localeFallbackOrder',
    'gridSpacingUnits',
    'animationCurveSeed',
    'cacheShardTable',
    'retryBackoffTable',
  ];

  /// Splits [keyBytes] into [chunkCount] chunks, each XORed with a random
  /// pad of the same length, so reconstructing the key means finding and
  /// combining several scattered constants instead of grepping one.
  factory KeySplitPlan.derive(List<int> keyBytes, {Random? random}) {
    final rnd = random ?? Random.secure();
    final chunkSize = keyBytes.length ~/ chunkCount;
    final pool = List<String>.from(fakeNamePool)..shuffle(rnd);

    final chunks = <KeySplitChunk>[];
    for (var i = 0; i < chunkCount; i++) {
      final start = i * chunkSize;
      final end = (i == chunkCount - 1) ? keyBytes.length : start + chunkSize;
      final chunk = keyBytes.sublist(start, end);
      final pad = List<int>.generate(chunk.length, (_) => rnd.nextInt(256));
      final xored = List<int>.generate(chunk.length, (j) => chunk[j] ^ pad[j]);
      chunks.add(
          KeySplitChunk(name: pool[i % pool.length], xored: xored, pad: pad));
    }
    return KeySplitPlan(chunks);
  }
}

List<int> generateKeyBytes({int lengthBytes = 32, Random? random}) {
  final rnd = random ?? Random.secure();
  return List<int>.generate(lengthBytes, (_) => rnd.nextInt(256));
}
