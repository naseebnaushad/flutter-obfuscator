/// One file whose `if` conditions had opaque-predicate noise injected.
class ObfuscatedControlFlowFileResult {
  ObfuscatedControlFlowFileResult({
    required this.filePath,
    required this.injectedCount,
  });

  final String filePath;

  /// Number of `if` conditions rewritten in this file.
  final int injectedCount;
}
