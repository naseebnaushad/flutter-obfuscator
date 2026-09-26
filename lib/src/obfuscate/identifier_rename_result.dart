/// One file whose private identifiers were renamed.
class RenamedFileResult {
  RenamedFileResult({required this.filePath, required this.renameCount});

  final String filePath;

  /// Number of distinct private names renamed in this file (not the
  /// number of occurrences rewritten).
  final int renameCount;
}

/// A file the identifier obfuscator deliberately left untouched.
class SkippedFileResult {
  SkippedFileResult({required this.filePath, required this.reason});

  final String filePath;
  final String reason;
}
