import 'dart:math' as math;

/// Shannon entropy of [input], in bits per character.
///
/// Used as a heuristic to filter out short/low-entropy string literals
/// (e.g. `"ok"`, `"Loading..."`) that match a name pattern like `token`
/// but obviously aren't secrets.
double shannonEntropy(String input) {
  if (input.isEmpty) return 0;
  final counts = <int, int>{};
  for (final rune in input.runes) {
    counts[rune] = (counts[rune] ?? 0) + 1;
  }
  final length = input.length;
  var entropy = 0.0;
  for (final count in counts.values) {
    final p = count / length;
    entropy -= p * (math.log(p) / math.ln2);
  }
  return entropy;
}
