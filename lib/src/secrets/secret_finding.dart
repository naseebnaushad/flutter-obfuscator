import '../crypto/vault_crypto.dart';

/// One hardcoded secret found and transformed in the source tree.
class SecretFinding {
  SecretFinding({
    required this.id,
    required this.filePath,
    required this.variableName,
    required this.plainText,
    required this.entry,
  });

  final String id;
  final String filePath;
  final String variableName;

  /// Original plaintext value. Kept in memory only for the post-build
  /// [PlaintextVerifier] pass — never written to disk.
  final String plainText;

  final EncryptedEntry entry;
}

/// A declaration the scanner looked at but did not transform, and why.
/// Surfaced in the report so a reviewer can decide whether to handle it
/// manually.
class SkippedCandidate {
  SkippedCandidate({
    required this.filePath,
    required this.variableName,
    required this.reason,
  });

  final String filePath;
  final String variableName;
  final String reason;
}
