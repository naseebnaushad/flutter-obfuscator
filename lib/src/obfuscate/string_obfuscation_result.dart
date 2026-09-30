/// One file whose string literals were rewritten into vault lookups.
class ObfuscatedStringFileResult {
  ObfuscatedStringFileResult(
      {required this.filePath, required this.literalCount});

  final String filePath;

  /// Number of string literal occurrences rewritten in this file (not
  /// deduplicated — the same repeated literal counts once per occurrence).
  final int literalCount;
}
